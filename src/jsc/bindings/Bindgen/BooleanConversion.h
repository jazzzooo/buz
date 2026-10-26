#pragma once

#include "root.h"
#include "IDLTypes.h"
#include "BunIDLConvertBase.h"
#include "ConversionFailure.h"
#include <JavaScriptCore/OperationsInlines.h>

namespace Bun {

template<typename Failure>
struct BindgenStrictBoolean : WebCore::IDLBoolean { };

template<Bindgen::BindingFixedString Name>
struct BindgenNodePropertyBoolean : WebCore::IDLBoolean { };

}

namespace WebCore {

template<typename Failure>
struct Converter<Bun::BindgenStrictBoolean<Failure>> : Bun::DefaultTryConverter<Bun::BindgenStrictBoolean<Failure>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<bool> tryConvert(JSC::JSGlobalObject&, JSC::JSValue value, Ctx&)
    {
        if (!value.isBoolean())
            return std::nullopt;
        return value.asBoolean();
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, Ctx&)
    {
        Failure::raise(globalObject, scope);
    }
};

template<Bun::Bindgen::BindingFixedString Name>
struct Converter<Bun::BindgenNodePropertyBoolean<Name>> : Bun::DefaultContextConverter<Bun::BindgenNodePropertyBoolean<Name>> {
    using Bun::DefaultContextConverter<Bun::BindgenNodePropertyBoolean<Name>>::convert;

    template<Bun::IDLConversionContext Ctx>
    static bool convert(JSC::JSGlobalObject& global, JSC::JSValue value, Ctx&)
    {
        if (value.isBoolean())
            return value.asBoolean();
        auto scope = DECLARE_THROW_SCOPE(global.vm());
        WTF::String type = JSC::jsTypeStringForValue(&global, value)->value(&global);
        RETURN_IF_EXCEPTION(scope, false);
        Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE,
            WTF::makeString("The \""_s, Bun::Bindgen::bindingLiteral<Name>(), "\" property must be of type boolean, got "_s, type));
        return false;
    }
};

}
