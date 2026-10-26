#pragma once

#include "Any.h"
#include "JSValueInWrappedObject.h"
#include <optional>

namespace Bun::Bindgen {

class CppTracedAny final {
public:
    CppTracedAny() = default;
    explicit CppTracedAny(const std::optional<CppAny>& value)
    {
        if (value)
            set(*value);
    }

    void set(CppAny value)
    {
        RELEASE_ASSERT(!value.m_value.isEmpty());
        m_value.setWeakly(value.m_value);
    }

    std::optional<CppAny> get() const
    {
        auto value = m_value.getValue({});
        if (value.isEmpty())
            return std::nullopt;
        return CppAny(value);
    }

    template<typename Visitor> void visit(Visitor& visitor) const { m_value.visit(visitor); }

private:
    WebCore::JSValueInWrappedObject m_value;
};

}
