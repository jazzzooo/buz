#include "root.h"

#include "BunPanic.h"
#include "JavaScriptCore/CallData.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include "InternalModuleRegistry.h"
#include "ModuleLoader.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSPromise.h>
namespace Bun {
using namespace JSC;
JSC::JSValue Bindgen::Engine::bunBindgenEngine_html_entry_point_loadHTMLEntryPoint(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_html_entry_point_loadHTMLEntryPoint_Arguments&)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSValue htmlModule = globalObject->internalModuleRegistry()->requireId(globalObject, vm, InternalModuleRegistry::Field::InternalHtml);
    if (scope.exception()) [[unlikely]] {
        return JSPromise::rejectedPromiseWithCaughtException(globalObject, scope);
    }

    JSObject* htmlModuleObject = htmlModule.getObject();
    if (!htmlModuleObject) [[unlikely]] {
        BUN_PANIC("Failed to load HTML entry point");
    }

    MarkedArgumentBuffer args;
    JSValue result = JSC::call(globalObject, htmlModuleObject, args, "Failed to load HTML entry point"_s);
    if (scope.exception()) [[unlikely]] {
        return JSPromise::rejectedPromiseWithCaughtException(globalObject, scope);
    }

    if (result.isUndefined()) {
        return JSPromise::resolvedPromise(globalObject, result);
    }

    JSPromise* promise = dynamicDowncast<JSC::JSPromise>(result);
    if (!promise) [[unlikely]] {
        BUN_PANIC("Failed to load HTML entry point");
    }
    return promise;
}

}
