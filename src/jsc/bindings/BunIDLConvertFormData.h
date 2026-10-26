#pragma once
#include "BunIDLExternalRefs.h"
#include "BunIDLConvertBase.h"
#include "JSDOMFormData.h"

template<> struct WebCore::Converter<Bun::IDLDOMFormDataRef> : Bun::DefaultTryConverter<Bun::IDLDOMFormDataRef> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<typename Bun::IDLDOMFormDataRef::ImplementationType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx&)
    {
        auto* wrapper = WTF::dynamicDowncast<WebCore::JSDOMFormData>(value);
        if (!wrapper)
            return std::nullopt;
        return WebCore::protectedFormData(&globalObject, wrapper);
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwTypeMustBe(globalObject, scope, "a FormData"_s);
    }
};

namespace Bun::Bindgen::ExternalRefs {

inline bool matchesFormData(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSDOMFormData>(value);
}

}
