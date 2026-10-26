#pragma once
#include "BunIDLExternalRefs.h"
#include "BunIDLConvertBase.h"
#include "blob.h"

template<> struct WebCore::Converter<Bun::IDLBlobRef> : Bun::DefaultTryConverter<Bun::IDLBlobRef> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<typename Bun::IDLBlobRef::ImplementationType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        auto impl = Blob::retain(value);
        if (!impl)
            return std::nullopt;
        return WTF::move(impl);
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotBlob(globalObject, scope);
    }
};

namespace Bun::Bindgen::ExternalRefs {

inline bool matchesBlob(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    return WebCore::Blob::isInstance(value);
}

}
