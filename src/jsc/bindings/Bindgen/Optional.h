#pragma once

#include <optional>

namespace Bun::Bindgen {

template<typename T>
const T* nestedOptionalValue(const std::optional<std::optional<T>>& value)
{
    if (!value || !value->has_value())
        return nullptr;
    return &value->value();
}

}
