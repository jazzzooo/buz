#pragma once

#include <cstddef>
#include <wtf/text/ASCIILiteral.h>

namespace Bun::Bindgen {

template<size_t N>
struct BindingFixedString {
    char value[N] {};

    consteval BindingFixedString() = default;
    consteval BindingFixedString(const char (&input)[N])
    {
        for (size_t index = 0; index < N; ++index)
            value[index] = input[index];
    }

    static constexpr size_t length = N - 1;
};

template<BindingFixedString Value>
constexpr WTF::ASCIILiteral bindingLiteral()
{
    return WTF::ASCIILiteral::fromLiteralUnsafe(Value.value);
}

}
