#include "BakeGlobalObject.h"
#include "BunPanic.h"
#include "SchemaBindings.h"
#include "BakeSourceProvider.h"
#include "JSNextTickQueue.h"
#include "JavaScriptCore/GlobalObjectMethodTable.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/JSModuleLoader.h"
#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/JSSourceCode.h"

namespace Bake {
using namespace JSC;

JSC::JSPromise*
bakeModuleLoaderImportModule(JSC::JSGlobalObject* global,
    JSC::JSModuleLoader* moduleLoader, JSC::JSString* moduleNameValue,
    RefPtr<JSC::ScriptFetchParameters> parameters,
    const JSC::SourceOrigin& sourceOrigin,
    bool deferred)
{
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    WTF::String keyString = moduleNameValue->getString(global);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (keyString.startsWith("bake:/"_s)) {
        RELEASE_AND_RETURN(scope, JSC::importModule(global, JSC::Identifier::fromString(vm, keyString),
                                      JSC::Identifier(), WTF::move(parameters), nullptr));
    }

    if (!sourceOrigin.isNull() && sourceOrigin.string().startsWith("bake:/"_s)) {
        WTF::String refererString = sourceOrigin.string();

        auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BakeProduction_bakeProdResolve(global, refererString, keyString);
        RETURN_IF_EXCEPTION(scope, nullptr);

        RELEASE_AND_RETURN(scope, JSC::importModule(global, JSC::Identifier::fromString(vm, result),
                                      JSC::Identifier(), WTF::move(parameters), nullptr));
    }

    RELEASE_AND_RETURN(scope, Zig::GlobalObject::moduleLoaderImportModule(global, moduleLoader, moduleNameValue, WTF::move(parameters), sourceOrigin, deferred));
}

JSC::Identifier bakeModuleLoaderResolve(JSC::JSGlobalObject* jsGlobal,
    JSC::JSModuleLoader* loader, JSC::JSValue key,
    JSC::JSValue referrer, RefPtr<JSC::ScriptFetcher> origin, bool useImportMap)
{
    Bake::GlobalObject* global = uncheckedDowncast<Bake::GlobalObject>(jsGlobal);
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto string = dynamicDowncast<JSC::JSString>(referrer)) {
        WTF::String refererString = string->getString(global);
        RETURN_IF_EXCEPTION(scope, vm.propertyNames->emptyIdentifier);

        WTF::String keyString = key.toWTFString(global);
        RETURN_IF_EXCEPTION(scope, vm.propertyNames->emptyIdentifier);

        if (refererString.startsWith("bake:/"_s) || (refererString == "."_s && keyString.startsWith("bake:/"_s))) {
            auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BakeProduction_bakeProdResolve(global, refererString, keyString);
            RETURN_IF_EXCEPTION(scope, vm.propertyNames->emptyIdentifier);

            return JSC::Identifier::fromString(vm, result);
        }
    }

    if (auto string = dynamicDowncast<JSC::JSString>(key)) {
        auto keyView = string->getString(global);
        RETURN_IF_EXCEPTION(scope, vm.propertyNames->emptyIdentifier);

        if (keyView.startsWith("bake:/"_s)) {
            auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BakeProduction_bakeProdResolve(
                global, "bake:/"_s, keyView.substringSharingImpl("bake:"_s.length()));
            RETURN_IF_EXCEPTION(scope, vm.propertyNames->emptyIdentifier);

            return JSC::Identifier::fromString(vm, result);
        }
    }

    // Use Zig::GlobalObject's function
    RELEASE_AND_RETURN(scope, Zig::GlobalObject::moduleLoaderResolve(jsGlobal, loader, key, referrer, WTF::move(origin), useImportMap));
}

static JSC::JSPromise* rejectedInternalPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto& vm = JSC::getVM(globalObject);
    JSC::JSPromise* promise = JSC::JSPromise::create(vm, globalObject->promiseStructure());
    promise->rejectAsHandled(vm, value);
    return promise;
}

static JSC::JSPromise* resolvedInternalPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    return JSC::JSPromise::resolvedPromise(globalObject, value);
}

JSC::JSPromise* bakeModuleLoaderFetch(JSC::JSGlobalObject* globalObject,
    JSC::JSModuleLoader* loader, JSC::JSValue key,
    RefPtr<JSC::ScriptFetchParameters> parameters, RefPtr<JSC::ScriptFetcher> script)
{
    Bake::GlobalObject* global = uncheckedDowncast<Bake::GlobalObject>(globalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto moduleKey = key.toWTFString(globalObject);
    if (scope.exception()) [[unlikely]]
        RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, scope.exception()->value()));

    if (moduleKey.startsWith("bake:/"_s)) {
        if (global->m_perThreadData) [[likely]] {
            auto loaded = Bun::Bindgen::ZigExports::bunBindgenZig_BakeProduction_bakeProdLoad(global->m_perThreadData, moduleKey);
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!loaded) {
                JSC::throwOutOfMemoryError(globalObject, scope);
                return nullptr;
            }
            if (auto& source = *loaded) {
                JSC::SourceOrigin origin = JSC::SourceOrigin(WTF::URL(moduleKey));
                auto provider = Bake::SourceProvider::create(
                    globalObject,
                    *source,
                    origin,
                    WTF::move(moduleKey),
                    WTF::TextPosition(),
                    JSC::SourceProviderSourceType::Module);
                RETURN_IF_EXCEPTION(scope, nullptr);
                JSC::SourceCode sourceCode(provider.releaseNonNull());
                RELEASE_AND_RETURN(scope, resolvedInternalPromise(globalObject, JSC::JSSourceCode::create(vm, WTF::move(sourceCode))));
            }

            // Production resolution unconditionally prefixes the key with "bake:".
            //
            // But if someone does: `await import(resolve(import.meta.dir, "nav.ts"))`
            // we don't actually want to load it from the Bake production module
            // map and instead make it go through the normal codepath.
            auto bakePrefixRemoved = moduleKey.substringSharingImpl("bake:"_s.length());

#ifdef _WIN32
            // We normalize paths to contain forward slashes in bake so we don't
            // have to worry about platform paths. Now we have to worry about
            // it, because `moduleLoaderFetch(...)` may read the path from disk
            // and so we need to give a Windows path to it.
            auto windowsPath = Bun::Bindgen::ZigExports::bunBindgenZig_BakeProduction_bakeToWindowsPath(bakePrefixRemoved);
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!windowsPath) {
                JSC::throwOutOfMemoryError(globalObject, scope);
                return nullptr;
            }
            bakePrefixRemoved = WTF::move(*windowsPath);
#endif
            JSString* bakePrefixRemovedString = jsNontrivialString(vm, bakePrefixRemoved);
            JSValue bakePrefixRemovedJsvalue = bakePrefixRemovedString;
            RELEASE_AND_RETURN(scope, Zig::GlobalObject::moduleLoaderFetch(globalObject, loader, bakePrefixRemovedJsvalue, WTF::move(parameters), WTF::move(script)));
        }
        RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, createTypeError(globalObject, "BakeGlobalObject does not have per-thread data configured"_s)));
    }

    auto result = Zig::GlobalObject::moduleLoaderFetch(globalObject, loader, key, WTF::move(parameters), WTF::move(script));
    if (scope.exception()) [[unlikely]]
        RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, scope.exception()->value()));
    return result;
}

GlobalObject* GlobalObject::create(JSC::VM& vm, JSC::Structure* structure,
    const JSC::GlobalObjectMethodTable* methodTable)
{
    Bake::GlobalObject* ptr = new (NotNull, JSC::allocateCell<Bake::GlobalObject>(vm))
        Bake::GlobalObject(vm, structure, methodTable);
    ptr->finishCreation(vm);
    return ptr;
}

void GlobalObject::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

JSC::Structure* GlobalObject::createStructure(JSC::VM& vm)
{
    auto* structure = JSC::Structure::create(vm, nullptr, jsNull(), JSC::TypeInfo(JSC::GlobalObjectType, StructureFlags & ~IsImmutablePrototypeExoticObject), info());
    structure->setTransitionWatchpointIsLikelyToBeFired(true);
    return structure;
}

const JSC::GlobalObjectMethodTable& GlobalObject::globalObjectMethodTable()
{
    const auto& parent = Zig::GlobalObject::globalObjectMethodTable();
#define INHERIT_HOOK_METHOD(name) \
    parent.name

    static const JSC::GlobalObjectMethodTable table = {
        INHERIT_HOOK_METHOD(supportsRichSourceInfo),
        INHERIT_HOOK_METHOD(shouldInterruptScript),
        INHERIT_HOOK_METHOD(javaScriptRuntimeFlags),
        INHERIT_HOOK_METHOD(shouldInterruptScriptBeforeTimeout),
        bakeModuleLoaderImportModule,
        bakeModuleLoaderResolve,
        bakeModuleLoaderFetch,
        INHERIT_HOOK_METHOD(moduleLoaderCreateImportMetaProperties),
        INHERIT_HOOK_METHOD(moduleLoaderEvaluate),
        INHERIT_HOOK_METHOD(moduleLoaderAnalyzeTranspiledModule),
        INHERIT_HOOK_METHOD(promiseRejectionTracker),
        INHERIT_HOOK_METHOD(reportUncaughtExceptionAtEventLoop),
        INHERIT_HOOK_METHOD(currentScriptExecutionOwner),
        INHERIT_HOOK_METHOD(scriptExecutionStatus),
        INHERIT_HOOK_METHOD(reportViolationForUnsafeEval),
        INHERIT_HOOK_METHOD(defaultLanguage),
        INHERIT_HOOK_METHOD(compileStreaming),
        INHERIT_HOOK_METHOD(instantiateStreaming),
        INHERIT_HOOK_METHOD(deriveShadowRealmGlobalObject),
        INHERIT_HOOK_METHOD(codeForEval),
        INHERIT_HOOK_METHOD(canCompileStrings),
        INHERIT_HOOK_METHOD(trustedScriptStructure),
    };
#undef INHERIT_HOOK_METHOD
    return table;
}

static GlobalObject* createProductionGlobal()
{
    RefPtr<JSC::VM> vmPtr = JSC::VM::tryCreate(JSC::HeapType::Large);
    if (!vmPtr) [[unlikely]] {
        BUN_PANIC("Failed to allocate JavaScriptCore Virtual Machine. Did your computer run out of memory? Or maybe you compiled Bun with a mismatching libc++ version or compiler?");
    }
    // We need to unsafely ref this so it stays alive; global-object exit teardown calls
    // `vm.derefSuppressingSaferCPPChecking()` to free it.
    vmPtr->refSuppressingSaferCPPChecking();
    JSC::VM& vm = *vmPtr;

    vm.heap.acquireAccess();
    JSC::JSLockHolder locker(vm);
    auto* bunVM = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_getVirtualMachine();
    WebCore::JSVMClientData::create(&vm, bunVM);

    JSC::Structure* structure = Bake::GlobalObject::createStructure(vm);
    Bake::GlobalObject* global = Bake::GlobalObject::create(
        vm, structure, &Bake::GlobalObject::globalObjectMethodTable());
    if (!global)
        BUN_PANIC("Failed to create BakeGlobalObject");

    global->m_bunVM = bunVM;

    JSC::gcProtect(global);

    global->setConsole();
    global->setStackTraceLimit(10); // Node.js defaults to 10
    global->isThreadLocalDefaultGlobalObject = true;

    // if (shouldDisableStopIfNecessaryTimer) {
    vm.heap.disableStopIfNecessaryTimer();
    // }

    // if you process.nextTick on a microtask we need thsi
    // TODO: it segfaults! process.nextTick is scoped out for now i guess!
    // vm.setOnComputeErrorInfo(computeErrorInfoWrapper);
    // vm.setOnEachMicrotaskTick([global](JSC::VM &vm) -> void {
    //   if (auto nextTickQueue = global->m_nextTickQueue.get()) {
    //     global->resetOnEachMicrotaskTick();
    //     // Bun::JSNextTickQueue *queue =
    //     //     uncheckedDowncast<Bun::JSNextTickQueue>(nextTickQueue);
    //     // queue->drain(vm, global);
    //     return;
    //   }
    // });

    return global;
}

const JSC::ClassInfo Bake::GlobalObject::s_info = { "GlobalObject"_s, &Base::s_info, nullptr, nullptr,
    CREATE_METHOD_TABLE(Bake::GlobalObject) };

}; // namespace Bake

JSC::JSGlobalObject* Bun::Bindgen::Engine::bunBindgenEngine_BakeProduction_createBakeProductionGlobal(
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_createBakeProductionGlobal_Arguments& args)
{
    return Bake::createProductionGlobal();
}

void Bun::Bindgen::Engine::bunBindgenEngine_BakeProduction_bakeGlobalObjectSetPerThreadData(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_bakeGlobalObjectSetPerThreadData_Arguments& args)
{
    auto* global = uncheckedDowncast<Bake::GlobalObject>(&context.globalObject);
    global->m_perThreadData = args.perThreadData.value_or(nullptr);
}
