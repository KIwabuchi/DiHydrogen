#include "distconv/tensor/tensor.hpp"
#include "distconv/tensor/tensor_mpi.hpp"
#include "distconv/tensor/tensor_cuda.hpp"
#include "distconv/tensor/tensor_mpi_cuda.hpp"
#include "test_tensor.hpp"
#include "distconv/util/util_cuda.hpp"
#include "distconv/util/util_mpi.hpp"

#include <assert.h>
#include <iostream>
#include <vector>

using namespace distconv;
using namespace distconv::tensor;
using namespace distconv::util;

template <>
inline LocaleMPI get_locale() {
  LocaleMPI loc(MPI_COMM_WORLD);
  return loc;
}

__global__ void init_tensor(int *buf, Array<3> local_shape, Array<3> head_halo,
                            Array<3> tail_halo, index_t pitch, Array<3> global_shape,
                            Array<3> global_index_base) {
  Array<3> local_real_shape = local_shape + head_halo + tail_halo;
  for (index_t k = blockIdx.x; k < local_shape[2]; k += gridDim.x) {
    for (index_t j = 0; j < local_shape[1]; ++j) {
      for (index_t i = threadIdx.x; i < local_shape[0]; i += blockDim.x) {
        Array<3> local_idx = {i, j, k};
        size_t local_offset =
            get_offset(local_idx + head_halo, local_real_shape, pitch); // TODO: check
        Array<3> global_idx = global_index_base + local_idx;
        size_t global_offset = get_offset(
            global_idx, global_shape);
        buf[local_offset] = global_offset;
      }
    }
  }
}

__global__ void check_tensor(const int *buf, Array<3> local_shape,
                             Array<3> head_halo, Array<3> tail_halo, index_t pitch,
                             Array<3> global_shape, Array<3> global_index_base,
                             int *error_counter) {
  Array<3> local_real_shape = local_shape + head_halo + tail_halo;
  for (index_t k = blockIdx.x; k < local_shape[2]; k += gridDim.x) {
    for (index_t j = 0; j < local_shape[1]; ++j) {
      for (index_t i = threadIdx.x; i < local_shape[0]; i += blockDim.x) {
        Array<3> local_idx = {i, j, k};
        size_t local_offset =
            get_offset(local_idx + head_halo, local_real_shape, pitch); // todo: check
        Array<3> global_idx = global_index_base + local_idx;
        int global_offset = get_offset(global_idx, global_shape);
        int stored = buf[local_offset];
        if (stored != global_offset) {
          atomicAdd(error_counter, 1);
          printf("Error at (%lu, %lu, %lu)@(%lu, %lu, %lu); ref: %d, stored: %d\n",
                 global_idx[0], global_idx[1], global_idx[2],
                 i, j, k, global_offset, stored);
        }
      }
    }
  }
}

template <typename TensorType>
inline int test_data_access_mpi_cuda(const Shape &shape,
                                     const Distribution &dist) {
  using LocaleType = typename TensorType::locale_type;
  LocaleType loc = get_locale<LocaleType>();
  TensorType t = get_tensor<TensorType>(shape, loc, dist);
  MPIRootPrintStreamDebug() << "Shape: " << t.get_shape();
  MPIRootPrintStreamDebug() << "Distribution: " << t.get_distribution();
  MPIPrintStreamDebug() << "Local real shape: " << t.get_local_real_shape();

  assert0(t.allocate());

  //Array<3> local_shape = t.get_local_shape();
  index_t base_offset = t.get_local_offset();
  int *buf = t.get_buffer();
  assert_always(buf != nullptr);
  size_t pitch = t.get_pitch();
  util::MPIPrintStreamDebug() << "Base offset: " << base_offset
                              << ", global offset: " << t.get_global_index()
                              << ", pitch: " << pitch;

  init_tensor<<<4, 4>>>(buf, t.get_local_shape(), dist.get_head_overlap(),
                        dist.get_tail_overlap(), t.get_pitch(), t.get_shape(),
                        t.get_global_index());
  cudaDeviceSynchronize();

  int error_counter = 0;
  int *error_counter_d;
  cudaMalloc(&error_counter_d, sizeof(int));
  cudaMemcpy(error_counter_d, &error_counter, sizeof(int),
             cudaMemcpyDefault);
  check_tensor<<<1, 1>>>(buf, t.get_local_shape(), dist.get_head_overlap(),
                         dist.get_tail_overlap(), t.get_pitch(), t.get_shape(),
                         t.get_global_index(), error_counter_d);

  cudaMemcpy(&error_counter, error_counter_d, sizeof(int),
             cudaMemcpyDefault);
  assert0(error_counter);

  return 0;
}

template <typename TensorType>
int test_view_raw_ptr(const Shape &shape,
                      const Distribution &dist) {
  auto loc = get_locale<typename TensorType::locale_type>();
  auto t = get_tensor<TensorType>(shape, loc, dist);
  assert0(t.allocate());

  index_t base_offset = t.get_local_offset();
  int *buf = t.get_buffer();
  assert_always(buf);
  init_tensor<<<4, 4>>>(buf, t.get_local_shape(), dist.get_head_overlap(),
                        dist.get_tail_overlap(), t.get_pitch(), t.get_shape(),
                        t.get_global_index());
  cudaDeviceSynchronize();
  using ConstTensorType = Tensor<typename TensorType::data_type,
                                 typename TensorType::locale_type,
                                 typename TensorType::allocator_type>;
  auto const_tensor_view = get_tensor<ConstTensorType>(shape, loc, dist);
  View(const_tensor_view, (const int*)buf);
  assert_always(const_tensor_view.get_const_buffer() == buf);
  int error_counter = 0;
  int *error_counter_d;
  cudaMalloc(&error_counter_d, sizeof(int));
  cudaMemcpy(error_counter_d, &error_counter, sizeof(int),
             cudaMemcpyDefault);
  check_tensor<<<1, 1>>>(
      const_tensor_view.get_const_buffer(), const_tensor_view.get_local_shape(),
      dist.get_head_overlap(), dist.get_tail_overlap(), const_tensor_view.get_pitch(),
      const_tensor_view.get_shape(), const_tensor_view.get_global_index(),
      error_counter_d);
  cudaMemcpy(&error_counter, error_counter_d, sizeof(int),
             cudaMemcpyDefault);
  assert0(error_counter);
  return 0;
}

template <int ND, typename DataType>
__global__ void check_clear_halo(const DataType *buf, Array<ND> local_shape,
                                 int dim, int head_halo, int tail_halo,
                                 DataType default_value, int *error_counter) {
  const int tid = threadIdx.x;
  const int num_threads = blockDim.x;
  Array<ND> idx;
  idx[1] = blockIdx.x;
  idx[2] = blockIdx.y;
  if (ND == 4) {
    idx[3] = blockIdx.z;
  }

  for (int x = tid; x < local_shape[0]; x += num_threads) {
    idx[0] = x;
    int offset = get_offset(idx, local_shape);
    DataType v = buf[offset];
    if (idx[dim] < head_halo || idx[dim] >= local_shape[dim] - head_halo) { // TODO: check
      if (v != 0) {
        atomicAdd(error_counter, 1);
      }
    } else {
      if (v != default_value) {
        atomicAdd(error_counter, 1);
      }
    }
  }
}

template <int ND, typename TensorType>
int test_clear_halo(const Shape &shape,
                    const Distribution &dist) {
  const int num_dims = shape.num_dims();
  using DataType = typename TensorType::data_type;
  using LocaleType = typename TensorType::locale_type;
  LocaleType loc = get_locale<LocaleType>();
  TensorType t = get_tensor<TensorType>(shape, loc, dist);
  const auto local_real_shape = t.get_local_real_shape();
  util::MPIPrintStreamDebug() << "Shape: " << t.get_shape()
                              << ", local real shape: " << local_real_shape
                              << ", distribution: " << t.get_distribution();

  int error_counter = 0;
  int *error_counter_d;
  cudaMalloc(&error_counter_d, sizeof(int));
  cudaMemcpy(error_counter_d, &error_counter, sizeof(int),
             cudaMemcpyDefault);

  assert0(t.allocate());
  auto *buf = t.get_buffer();
  DataType *h = new DataType[t.get_local_real_size()];
  DataType default_value = 1;
  for (size_t i = 0; i < t.get_local_real_size(); ++i) {
    h[i] = default_value;
  }
  for (int i = 0; i < num_dims; ++i) {
    cudaMemcpy(buf, h, t.get_local_real_size() * sizeof(DataType),
               cudaMemcpyDefault);
    t.clear_halo(i);
    dim3 gsize(local_real_shape[1], local_real_shape[2]);
    if (num_dims == 4) {
      gsize.z = local_real_shape[3];
    }
    check_clear_halo<ND, DataType>
        <<<gsize, 128>>>(buf, local_real_shape, i, dist.get_head_overlap(i),
                         dist.get_tail_overlap(i), 1, error_counter_d);
    cudaMemcpy(&error_counter, error_counter_d, sizeof(int), cudaMemcpyDefault);
    if (error_counter != 0) {
      util::MPIPrintStreamError() << error_counter << " errors at dimension ";
      DISTCONV_CHECK_CUDA(cudaMemcpy(h, buf, sizeof(DataType) *
                                     t.get_local_real_size(), cudaMemcpyDefault));
      std::ofstream out;
      std::stringstream file_path;
      file_path << "clear_halo_test_" << loc.get_rank();
      out.open(file_path.str(), std::ios::out | std::ios::trunc);
      for (size_t i = 0; i < t.get_local_real_size(); ++i) {
        out << h[i] << "\n";
      }
      out.close();
      return -1;
    }
#if 0
    DataType *result_h = new DataType[t.get_local_real_size()];
    DISTCONV_CHECK_CUDA(cudaMemcpy(result_h, buf, sizeof(DataType) *
                                   t.get_local_real_size(), cudaMemcpyDefault));
    std::ofstream out;
    std::stringstream file_path;
    file_path << "clear_halo_test_" << i << "_" << loc.get_rank();
    out.open(file_path.str(), std::ios::out | std::ios::trunc);
    for (size_t i = 0; i < t.get_local_real_size(); ++i) {
      out << result_h[i] << "\n";
    }
    out.close();
#endif
  }

  return 0;
}

/*
  Usage: mpirun -np N ./test_tensor_mpi_cuda, where N must be >= 8 and
  divisible by 8.
 */
int main(int argc, char *argv[]) {
  int dev = util::choose_gpu();
  cudaSetDevice(dev);
  MPI_Init(&argc, &argv);
  int pid;
  int np;
  MPI_Comm_rank(MPI_COMM_WORLD, &pid);
  MPI_Comm_size(MPI_COMM_WORLD, &np);

  MPIPrintStreamInfo() << "Using device " << dev;

  constexpr int ND = 3;
  using DataType = int;

  using TensorMPI = Tensor<DataType, LocaleMPI, CUDAAllocator>;
  auto dist3 = Distribution::make_overlapped_distribution({2, 2, np / 4},
                                                          {1, 1, 0}, {1, 1, 0});
  auto dist4 = Distribution::make_overlapped_distribution(
      {2, 2, 2, np / 8}, {1, 1, 0, 0}, {1, 1, 0, 0});
  assert_always((np % 8) == 0 && (np >= 8));
  //Distribution<3> dist({1, 1, np}, {1, 1, 0});

  assert0(test_alloc<TensorMPI>(Shape({2, 2, 2}), dist3));
  MPIRootPrintStreamInfo() << "test_alloc success";

  assert0(test_data_access_mpi_cuda<TensorMPI>(Shape({2, 2, 2}), dist3));
  MPIRootPrintStreamInfo() << "test_data_access_mpi_cuda success";

  // Doesn't work with Spectrum-MPI
#if 0
  assert0(test_data_access_mpi_cuda<Tensor<DataType, LocaleMPI,
          CUDAPitchedAllocator>>(Shape({32, 32, 4}), dist3));
  MPIRootPrintStreamInfo() << "test_data_access_mpi_cuda with pitched memory success\n";
#endif

  assert0(test_view_raw_ptr<TensorMPI>(Shape({32, 32, 4}), dist3));

  MPIRootPrintStreamInfo() << "test_view_raw_ptr success";

  assert0(test_clear_halo<ND, TensorMPI>(Shape({32, 31, 4}), dist3));
  MPIRootPrintStreamInfo() << "test_clear_halo success";

  assert0(test_clear_halo<4, TensorMPI>(Shape({32, 31, 4, 8}), dist4));
  MPIRootPrintStreamInfo() << "test_clear_halo with 4D tensor success";

  MPI_Finalize();

  cudaDeviceReset();
  return 0;
}
