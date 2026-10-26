#pragma once

#include "root.h"
#include "wtf/text/ASCIILiteral.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/Identifier.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ThrowScope.h>
#include <JavaScriptCore/VM.h>

namespace Zig {
class GlobalObject;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

void throwSystemError(JSC::ThrowScope&, JSC::JSGlobalObject*, ASCIILiteral syscall, int err);
void throwSystemError(JSC::ThrowScope&, JSC::JSGlobalObject*, ASCIILiteral message, ASCIILiteral syscall, int err);

template<typename WebCoreType, typename OutType>
OutType* WebCoreCast(JSC::EncodedJSValue JSValue0)
{
    // we must use jsDynamicCast here so that we check that the type is correct
    WebCoreType* jsdomURL = dynamicDowncast<WebCoreType>(JSC::JSValue::decode(JSValue0));
    if (jsdomURL == nullptr) {
        return nullptr;
    }

    return reinterpret_cast<OutType*>(&jsdomURL->wrapped());
}

#pragma clang diagnostic pop
