#pragma once
#include "BunIDLExternalRefs.h"
#include "BunIDLConvertBase.h"
#include "webcore/JSFetchHeaders.h"

template<> struct WebCore::Converter<Bun::IDLFetchHeadersRef> : Bun::DefaultTryConverter<Bun::IDLFetchHeadersRef> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<typename Bun::IDLFetchHeadersRef::ImplementationType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx&)
    {
        auto* wrapper = WTF::dynamicDowncast<WebCore::JSFetchHeaders>(value);
        if (!wrapper)
            return std::nullopt;
        return WebCore::protectedFetchHeaders(&globalObject, wrapper);
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwTypeMustBe(globalObject, scope, "Headers"_s);
    }
};

namespace Bun::Bindgen::ExternalRefs {

inline bool matchesFetchHeaders(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSFetchHeaders>(value);
}

}
