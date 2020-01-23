// @H2_LICENSE_TEXT@

#ifndef H2_META_CORE_VALUEASTYPE_HPP_
#define H2_META_CORE_VALUEASTYPE_HPP_

#include "Lazy.hpp"
namespace h2
{
namespace meta
{

/** @brief A constexpr value represented as a type. */
template <typename T, T Value>
struct ValueAsTypeT
{
    static constexpr T value = Value;
    using value_type = T;
    using type = ValueAsTypeT;
    constexpr operator value_type() const noexcept { return value; }
    constexpr value_type operator()() const noexcept { return value; }
};

/** @brief A constexpr value represented as a type. */
template <typename T, T Value>
using ValueAsType = Force<ValueAsTypeT<T, Value>>;

/** @brief A representation of boolean `true` values as a type. */
using TrueType = ValueAsType<bool, true>;

/** @brief A representation of boolean `false` values as a type. */
using FalseType = ValueAsType<bool, false>;

}// namespace meta
}// namespace h2
#endif // H2_META_CORE_VALUEASTYPE_HPP_