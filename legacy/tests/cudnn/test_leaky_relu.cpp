#include <vector>
#include <iostream>
#include <fstream>
#include <algorithm>
#include <numeric>
#include <cstdlib>

#include "distconv/tensor/tensor.hpp"
#include "distconv/tensor/tensor_mpi.hpp"
#include "distconv/distconv.hpp"
#include "distconv/util/util_mpi.hpp"
#ifdef DISTCONV_HAS_CUDA
#include "distconv/tensor/tensor_cuda.hpp"
#include "distconv/util/util_cuda.hpp"
#endif
#ifdef DISTCONV_HAS_CUDNN
#include "distconv/util/util_cudnn.hpp"
#endif
#include "test_common.hpp"

using namespace distconv;

using distconv::tensor::Shape;

using DataType = float;
constexpr DataType negative_slope = 0.01;

template <typename Backend>
struct TensorType;

#ifdef DISTCONV_HAS_CUDNN
template <>
struct TensorType<cudnn::BackendCUDNN> {
  using type =
      tensor::Tensor<DataType, tensor::LocaleMPI,
                     tensor::CUDAAllocator>;
};
#endif

template <>
struct TensorType<ref::Backend> {
  using type =
      tensor::Tensor<DataType, tensor::LocaleMPI,
                     tensor::BaseAllocator>;
};

template <typename Backend>
class Data {
 public:
  typename TensorType<Backend>::type input;
  typename TensorType<Backend>::type d_input;
  typename TensorType<Backend>::type output;
  typename TensorType<Backend>::type d_output;
};

template <typename Backend>
int setup(const test::Config &cfg, MPI_Comm comm,
          Data<Backend> &d) {
  using Tensor = typename TensorType<Backend>::type;

  int pid;
  int np;
  MPI_Comm_rank(comm, &pid);
  MPI_Comm_size(comm, &np);

  Shape input_shape({cfg.i_w, cfg.i_h, cfg.i_c, cfg.i_n});
  // Overlap is not necessary; just for testing
  IntVector overlap({1, 1, 0, 0});

  auto dist = tensor::Distribution::make_overlapped_distribution(
      tensor::Shape({cfg.p_w, cfg.p_h, cfg.p_c, cfg.p_n}), overlap);

  tensor::LocaleMPI loc(comm);
  d.input = Tensor(input_shape, loc, dist);
  d.d_input = Tensor(input_shape, loc, dist);
  d.output = Tensor(input_shape, loc, dist);
  d.d_output = Tensor(input_shape, loc, dist);

  // Allocate
  assert0(d.input.allocate());
  d.input.zero();
  assert0(d.output.allocate());
  d.output.zero();
  assert0(d.d_input.allocate());
  d.d_input.zero();
  assert0(d.d_output.allocate());
  d.d_output.zero();

  // Initialization
  test::init_tensor_random(d.input, 0, -0.5);
  test::init_tensor_random(d.d_output, 1);

  return 0;
}

template <typename Backend>
int test_forward(Data<Backend> &d,
                 const test::Config &cfg,
                 MPI_Comm comm,
                 Backend &be) {
  int pid;
  MPI_Comm_rank(comm, &pid);

  util::MPIRootPrintStreamInfo()
      << "Executing test_forward with "
      << be.get_name();

  LeakyReLU<Backend> leaky_relu(be);
  DISTCONV_CHECK_MPI(MPI_Barrier(comm));
  leaky_relu.forward(d.input, negative_slope, d.output);
  be.wait();
  DISTCONV_CHECK_MPI(MPI_Barrier(comm));
  util::MPIRootPrintStreamInfo() << "Test done";

  return 0;
}

template <typename Backend>
int test_backward(Data<Backend> &d,
                  const test::Config &cfg,
                  MPI_Comm comm,
                  Backend &be) {
  int pid;
  MPI_Comm_rank(comm, &pid);

  util::MPIRootPrintStreamInfo()
      << "Executing test_backward with "
      << be.get_name();

  LeakyReLU<Backend> leaky_relu(be);
  DISTCONV_CHECK_MPI(MPI_Barrier(comm));
  leaky_relu.backward(d.input, d.d_output, negative_slope,
                      d.d_input);
  be.wait();
  DISTCONV_CHECK_MPI(MPI_Barrier(comm));
  util::MPIRootPrintStreamInfo() << "Test done";

  return 0;
}

template <typename Backend>
int test_all(Data<Backend> &d, const test::Config &cfg,
             MPI_Comm comm);

#ifdef DISTCONV_HAS_CUDNN
template <>
int test_all<cudnn::BackendCUDNN>(Data<cudnn::BackendCUDNN> &d,
                                  const test::Config &cfg,
                                  MPI_Comm comm) {
  int pid;
  DISTCONV_CHECK_MPI(MPI_Comm_rank(MPI_COMM_WORLD, &pid));
  cudnnHandle_t cudnn_h;
  DISTCONV_CHECK_CUDNN(cudnnCreate(&cudnn_h));
  cudnn::BackendCUDNN be(comm, cudnn_h);
  test_forward<cudnn::BackendCUDNN>(d, cfg, comm, be);
  test_backward<cudnn::BackendCUDNN>(d, cfg, comm, be);
  be.wait();
  return 0;
}
#endif


template <typename Backend>
int run(const test::Config &cfg, MPI_Comm comm) {
  int pid;
  int np;
  DISTCONV_CHECK_MPI(MPI_Comm_rank(MPI_COMM_WORLD, &pid));
  DISTCONV_CHECK_MPI(MPI_Comm_size(MPI_COMM_WORLD, &np));

  Data<Backend> d;
  setup<Backend>(cfg, MPI_COMM_WORLD, d);

  // Dump input and filter tensors
  if (cfg.dump_input) {
    util::MPIRootPrintStreamDebug() << "Dumping input tensors";
    dump_tensor(d.input, "input_tensor");
    dump_tensor(d.d_output, "d_output_tensor");
  }

  util::MPIRootPrintStreamDebug() << "Start testing";
  test_all<Backend>(d, cfg, MPI_COMM_WORLD);

  util::MPIRootPrintStreamDebug() << "Testing done";

  // Dump result
  if (cfg.dump_output) {
    dump_tensor(d.output, "output_tensor");
    dump_tensor(d.d_input, "d_input_tensor");
  }

  return 0;
}

int main(int argc, char *argv[]) {
  int dev = distconv::util::choose_gpu();
  DISTCONV_CHECK_CUDA(cudaSetDevice(dev));
  int pid;
  int np;
  Al::Initialize(argc, argv);
  DISTCONV_CHECK_MPI(MPI_Comm_rank(MPI_COMM_WORLD, &pid));
  DISTCONV_CHECK_MPI(MPI_Comm_size(MPI_COMM_WORLD, &np));

  test::Config cfg = test::process_opt(argc, argv, pid);
  if (pid == 0) {
    std::cout << cfg << std::endl;
  }

  if (cfg.p_n * cfg.p_c * cfg.p_h * cfg.p_w != np) {
    util::MPIRootPrintStreamError()
        << "Number of ranks does not match with the number of tensor partitions";
    DISTCONV_CHECK_MPI(MPI_Finalize());
    std::exit(1);
  }

  if (cfg.backend == "Ref") {
    //run<ref::Backend>(cfg, MPI_COMM_WORLD);
    util::MPIRootPrintStreamError() << "Ref backend not implemented";
#ifdef DISTCONV_HAS_CUDNN
  } else if (cfg.backend == "CUDNN") {
    run<cudnn::BackendCUDNN>(cfg, MPI_COMM_WORLD);
#endif
  } else {
    util::MPIRootPrintStreamError() << "Unknown backend name";
    abort();
  }

  util::MPIRootPrintStreamInfo() << "Finishing";

  DISTCONV_CHECK_MPI(MPI_Finalize());
  return 0;
}
