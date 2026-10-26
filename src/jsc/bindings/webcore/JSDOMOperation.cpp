#include "root.h"

#include "BunClientData.h"
#include <JavaScriptCore/Error.h>
#include "JSDOMOperation.h"
#include "BunBuiltinNames.h"

// Temporarily undefine the macro to call JSC directly, then restore it for
// subsequent files in unified builds.
#pragma push_macro("createNotEnoughArgumentsError")
#undef createNotEnoughArgumentsError

namespace WebCore {

JSC::JSObject* createNotEnoughArgumentsErrorBun(JSC::JSGlobalObject* globalObject)
{
    JSC::JSObject* error = JSC::createNotEnoughArgumentsError(globalObject);
    if (error) [[likely]] {
        auto& vm = JSC::getVM(globalObject);
        const auto& names = WebCore::builtinNames(vm);
        error->putDirect(vm, names.codePublicName(), JSC::jsString(vm, WTF::String("ERR_MISSING_ARGS"_s)), 0);
    }

    return error;
}

#pragma pop_macro("createNotEnoughArgumentsError")

void throwNodeRangeError(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, const String& message)
{
    auto* error = JSC::createRangeError(lexicalGlobalObject, message);
    if (error) [[likely]] {
        auto& vm = JSC::getVM(lexicalGlobalObject);
        auto& builtinNames = Bun::builtinNames(vm);
        error->putDirect(vm, builtinNames.codePublicName(), JSC::jsString(vm, String("ERR_OUT_OF_RANGE"_s)));
        scope.throwException(lexicalGlobalObject, error);
    }
}

void throwNodeRangeError(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, ASCIILiteral message)
{
    auto* error = JSC::createRangeError(lexicalGlobalObject, message);
    if (error) [[likely]] {
        auto& vm = JSC::getVM(lexicalGlobalObject);
        auto& builtinNames = Bun::builtinNames(vm);
        error->putDirect(vm, builtinNames.codePublicName(), JSC::jsString(vm, String("ERR_OUT_OF_RANGE"_s)));
        scope.throwException(lexicalGlobalObject, error);
    }
}

}
