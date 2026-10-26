#pragma once

#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/MarkedVector.h>
#include <JavaScriptCore/PropertyName.h>
#include <JavaScriptCore/WriteBarrier.h>

namespace Bun::Bindgen {

namespace Detail {
struct CppAnyAccess;
}
class CppAnySequenceView;
class CppResultContext;
class CppTracedAny;

class CppAny final {
public:
    // Default construction reserves conversion storage without creating a JavaScript value.
    CppAny() = default;

    void appendTo(JSC::MarkedArgumentBuffer& values) const
    {
        RELEASE_ASSERT(!m_value.isEmpty());
        values.append(m_value);
    }
    void defineOwnDataProperty(JSC::VM&, JSC::JSObject&, JSC::PropertyName, unsigned attributes) const;
    void storeIn(JSC::VM&, JSC::JSCell& owner, JSC::WriteBarrier<JSC::Unknown>&) const;
    bool protectResult(CppResultContext&) const;

private:
    explicit CppAny(JSC::JSValue value)
        : m_value(value)
    {
        RELEASE_ASSERT(!value.isEmpty());
    }

    JSC::JSValue m_value {};
    friend struct Detail::CppAnyAccess;
    friend class CppAnySequenceView;
    friend class CppTracedAny;
};

}
