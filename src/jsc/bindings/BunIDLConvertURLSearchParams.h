#pragma once
#include "BunIDLExternalRefs.h"
#include "BunIDLConvertBase.h"
#include "JSURLSearchParams.h"

template<> struct WebCore::Converter<Bun::IDLURLSearchParamsRef> : Bun::DefaultTryConverter<Bun::IDLURLSearchParamsRef> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<typename Bun::IDLURLSearchParamsRef::ImplementationType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx&)
    {
        auto* wrapper = WTF::dynamicDowncast<WebCore::JSURLSearchParams>(value);
        if (!wrapper)
            return std::nullopt;
        return WebCore::protectedURLSearchParams(&globalObject, wrapper);
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwTypeMustBe(globalObject, scope, "a URLSearchParams"_s);
    }
};

namespace Bun::Bindgen::ExternalRefs {

inline bool matchesURLSearchParams(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSURLSearchParams>(value);
}

}
