#include "BakeAdditionsToGlobalObject.h"
#include "SchemaBindings.h"
#include "JSBakeResponse.h"
#include "JSBunRequest.h"
#include "JavaScriptCore/SlotVisitorMacros.h"
#include "WebCoreJSBuiltins.h"

namespace Bun {

static JSBunRequest* bunRequest(JSC::JSValue value)
{
    auto* request = dynamicDowncast<JSBunRequest>(value);
    RELEASE_ASSERT(request);
    return request;
}

JSC::JSFunction* BakeAdditionsToGlobalObject::wrapComponent(JSGlobalObject* globalObject)
{
    auto* function = m_wrapComponent.get();
    if (!function) {
        auto& vm = globalObject->vm();
        function = JSC::JSFunction::create(vm, globalObject, WebCore::bakeSSRResponseWrapComponentCodeGenerator(vm), globalObject);
        m_wrapComponent.set(vm, globalObject, function);
    }
    return function;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_DevServer_bakeGetEnsureAsyncLocalStorageInstanceFunction(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_DevServer_bakeGetEnsureAsyncLocalStorageInstanceFunction_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto* zig = static_cast<Zig::GlobalObject*>(globalObject);
    return zig->bakeAdditions().ensureAsyncLocalStorageInstanceJSFunction(globalObject);
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_BakeInternal_getAsyncLocalStorage(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BakeInternal_getAsyncLocalStorage_Arguments&)
{
    auto* globalObject = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    auto* storage = globalObject->bakeAdditions().getAsyncLocalStorage();
    if (!storage)
        return std::nullopt;
    return JSC::JSValue(storage);
}

void Bindgen::Cpp::bunBindgenCpp_BakeInternal_jsFunctionBakeEnsureAsyncLocalStorage(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BakeInternal_jsFunctionBakeEnsureAsyncLocalStorage_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    globalObject->bakeAdditions().ensureAsyncLocalStorageInstance(globalObject, args.storage.getObject());
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_DevServer_bakeGetBundleNewRouteFunction(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_DevServer_bakeGetBundleNewRouteFunction_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto* zig = static_cast<Zig::GlobalObject*>(globalObject);
    return zig->bakeAdditions().getBundleNewRouteJSFunction(zig);
}

Bindgen::DevServerBundleNewRouteResultResult Bindgen::Cpp::bunBindgenCpp_BakeInternal_jsFunctionBakeGetBundleNewRouteJSFunction(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BakeInternal_jsFunctionBakeGetBundleNewRouteJSFunction_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* request = bunRequest(args.request);
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_DevServer_bakeBundleNewRoute(globalObject, request->native(), args.url);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_DevServer_bakeGetNewRouteParamsFunction(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_DevServer_bakeGetNewRouteParamsFunction_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto* zig = static_cast<Zig::GlobalObject*>(globalObject);
    return zig->bakeAdditions().getNewRouteParamsJSFunction(zig);
}

} // namespace Bun
