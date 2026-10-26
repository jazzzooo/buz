#pragma once

#include "BindingRuntimeDeclarations.h"

namespace Bun::Bindgen::Detail {

struct CppAnyAccess final {
    static CppAny fromJS(JSC::JSValue value) { return CppAny(value); }
    static const JSC::JSValue& toJS(const CppAny& value)
    {
        RELEASE_ASSERT(!value.m_value.isEmpty());
        return value.m_value;
    }
    static JSC::JSValue toJS(JSC::JSValue value) { return value; }
    static CppAnySequenceView fromSpan(std::span<const JSC::JSValue> values) { return CppAnySequenceView(values); }
};

}
