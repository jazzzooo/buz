#pragma once
#include "BunIDLExternalRefs.h"
#include "BunIDLConvertBase.h"
#include "JSAbortSignal.h"

template<> struct WebCore::Converter<Bun::IDLAbortSignalRef> : Bun::DefaultTryConverter<Bun::IDLAbortSignalRef> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<typename Bun::IDLAbortSignalRef::ImplementationType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        auto* wrapper = WTF::dynamicDowncast<WebCore::JSAbortSignal>(value);
        if (!wrapper)
            return std::nullopt;
        return WTF::RefPtr<WebCore::AbortSignal> { &wrapper->wrapped() };
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwTypeMustBe(globalObject, scope, "an AbortSignal"_s);
    }
};

namespace Bun::Bindgen::ExternalRefs {

inline bool matchesAbortSignal(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSAbortSignal>(value);
}

}
