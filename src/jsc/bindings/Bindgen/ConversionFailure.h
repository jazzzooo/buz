#pragma once

#include "root.h"
#include "ErrorCode.h"
#include "BindingStringLiteral.h"
#include "ExceptionCode.h"
#include <JavaScriptCore/ExceptionHelpers.h>

namespace Bun {

JSC::JSValue createBindingDOMException(JSC::JSGlobalObject&, WebCore::ExceptionCode, const WTF::String&);

template<WebCore::ExceptionCode Code, Bindgen::BindingFixedString Message>
struct BindgenDOMConversionFailure {
    template<typename MessageType = WTF::ASCIILiteral>
    static void raise(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, const MessageType& message = Bindgen::bindingLiteral<Message>())
    {
        auto exception = createBindingDOMException(globalObject, Code, message);
        RETURN_IF_EXCEPTION(scope, void());
        scope.throwException(&globalObject, exception);
    }
};

enum class BindgenConversionErrorKind { Error,
    TypeError,
    RangeError,
    Code };

template<BindgenConversionErrorKind Kind, ErrorCode Code, Bindgen::BindingFixedString Message>
struct BindgenConversionFailure {
    template<typename MessageType = WTF::ASCIILiteral>
    static void raise(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, const MessageType& message = Bindgen::bindingLiteral<Message>())
    {
        if constexpr (Kind == BindgenConversionErrorKind::Code)
            Bun::throwError(&globalObject, scope, Code, message);
        else if constexpr (Kind == BindgenConversionErrorKind::TypeError)
            JSC::throwTypeError(&globalObject, scope, message);
        else if constexpr (Kind == BindgenConversionErrorKind::RangeError)
            JSC::throwRangeError(&globalObject, scope, message);
        else
            JSC::throwException(&globalObject, scope, JSC::createError(&globalObject, message));
    }
};

}
