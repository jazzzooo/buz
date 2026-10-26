#include "root.h"

#include "JavaScriptCore/JSGlobalObject.h"
#include "ModuleLoader.h"
#include "SchemaBindings.h"
#include "JavaScriptCore/Identifier.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/JSPromise.h>

#include "ZigSourceProvider.h"

#include <JavaScriptCore/JSSourceCode.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/OptionsList.h>
#include <JavaScriptCore/ParserError.h>
#include <JavaScriptCore/ScriptExecutable.h>
#include <JavaScriptCore/SourceOrigin.h>
#include <JavaScriptCore/StackFrame.h>
#include <JavaScriptCore/StackVisitor.h>
#include <JavaScriptCore/JSONObject.h>

#include "EventEmitter.h"
#include "JSEventEmitter.h"

#include <JavaScriptCore/JSModuleLoader.h>
#include <JavaScriptCore/ModuleRegistryEntry.h>
#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/JSModuleNamespaceObject.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>

#include "../modules/ObjectModule.h"
#include "JSCommonJSModule.h"
#include "IsolatedModuleCache.h"
#include "NativeModuleRegistry.h"

#include "JSCommonJSExtensions.h"

#include "BunProcess.h"
#include <atomic>

namespace Bun {
using namespace JSC;
using namespace Zig;
using namespace WebCore;

static std::atomic_bool bunTestMode { false };

bool isBunTest()
{
    return bunTestMode.load(std::memory_order_relaxed);
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_ModuleLoader_createEmptyExportObject(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_ModuleLoader_createEmptyExportObject_Arguments&)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::constructEmptyObject(&context.globalObject, context.globalObject.objectPrototype(), 0));
}

void Bindgen::Engine::bunBindgenEngine_ModuleLoader_installWasmSourceBytes(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_ModuleLoader_installWasmSourceBytes_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* bytes = JSC::JSUint8Array::createUninitialized(&globalObject, globalObject.typedArrayStructureWithTypedArrayType<JSC::TypeUint8>(), args.bytes.size());
    RETURN_IF_EXCEPTION(scope, );
    if (!args.bytes.empty())
        memcpy(bytes->vector(), args.bytes.data(), args.bytes.size());
    globalObject.putDirect(vm, JSC::Identifier::fromString(vm, "wasmSourceBytes"_s), bytes);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

void Bindgen::Engine::bunBindgenEngine_ModuleLoader_setBunTestMode(
    const BunBindgenEngine_ModuleLoader_setBunTestMode_Arguments& args)
{
    bunTestMode.store(args.enabled, std::memory_order_relaxed);
}

static JSC::JSPromise* rejectedInternalPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto& vm = JSC::getVM(globalObject);
    JSPromise* promise = JSPromise::create(vm, globalObject->promiseStructure());
    auto scope = DECLARE_THROW_SCOPE(vm);
    scope.throwException(globalObject, value);
    return promise->rejectWithCaughtException(vm, scope);
}

static JSC::JSPromise* resolvedInternalPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto& vm = JSC::getVM(globalObject);
    JSPromise* promise = JSPromise::create(vm, globalObject->promiseStructure());
    promise->fulfill(vm, value);
    return promise;
}

static bool bindgenResolveAndFetchBuiltinModule(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    ResolvedSourceResult& result)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    result.reset();
    auto outcome = Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_resolveAndFetchBuiltinModule(
        globalObject,
        specifier);
    RETURN_IF_EXCEPTION(scope, false);
    if (!outcome)
        return false;
    result = WTF::move(*outcome);
    return true;
}

static bool bindgenFetchBuiltinModule(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    const WTF::String& referrer,
    ResolvedSourceResult& result)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    result.reset();
    auto outcome = Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_fetchBuiltinModule(
        globalObject,
        specifier,
        referrer);
    RETURN_IF_EXCEPTION(scope, false);
    if (!outcome)
        return false;
    result = WTF::move(*outcome);
    return true;
}

static std::optional<JSC::JSPromise*> bindgenTranspileFile(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute,
    ResolvedSourceResult& result,
    bool allowPromise,
    bool isCommonJSRequire,
    BunLoaderType forceLoaderType)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    result.reset();
    auto outcome = Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_transpileFile(
        globalObject,
        specifier,
        referrer,
        typeAttribute,
        allowPromise,
        isCommonJSRequire,
        forceLoaderType);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (outcome.result) {
        result = WTF::move(*outcome.result);
    } else {
        result.reset();
    }
    if (outcome.promise) {
        auto* promise = dynamicDowncast<JSC::JSPromise>(*outcome.promise);
        RELEASE_ASSERT(promise);
        return promise;
    }
    return std::nullopt;
}

// Converts an object from InternalModuleRegistry into { ...obj, default: obj }
static JSC::SyntheticSourceProvider::SyntheticSourceGenerator generateInternalModuleSourceCode(JSC::JSGlobalObject* globalObject, InternalModuleRegistry::Field moduleId)
{
    return [moduleId](JSC::JSGlobalObject* lexicalGlobalObject,
               JSC::Identifier moduleKey,
               Vector<JSC::Identifier, 4>& exportNames,
               JSC::MarkedArgumentBuffer& exportValues) -> void {
        auto& vm = JSC::getVM(lexicalGlobalObject);
        GlobalObject* globalObject = uncheckedDowncast<GlobalObject>(lexicalGlobalObject);
        auto throwScope = DECLARE_THROW_SCOPE(vm);

        JSValue requireResult = globalObject->internalModuleRegistry()->requireId(globalObject, vm, moduleId);
        RETURN_IF_EXCEPTION(throwScope, void());
        auto* object = requireResult.getObject();
        ASSERT_WITH_MESSAGE(object, "Expected object from requireId %s", moduleKey.string().string().utf8().data());

        JSC::EnsureStillAliveScope stillAlive(object);

        PropertyNameArrayBuilder properties(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude);
        object->getOwnPropertyNames(object, globalObject, properties, DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(throwScope, void());

        auto len = properties.size() + 1;
        exportNames.reserveCapacity(len);
        exportValues.ensureCapacity(len);

        bool hasDefault = false;
        const bool objectDefault = Bindgen::internalModuleUsesObjectDefault(moduleId);

        for (auto& entry : properties) {
            if (entry == vm.propertyNames->defaultKeyword) [[unlikely]] {
                if (objectDefault)
                    continue;
                hasDefault = true;
            }
            exportNames.append(entry);
            JSValue value = object->get(globalObject, entry);
            RETURN_IF_EXCEPTION(throwScope, void());
            exportValues.append(value);
        }

        if (!hasDefault) {
            exportNames.append(vm.propertyNames->defaultKeyword);
            exportValues.append(object);
        }
    };
}

static JSC::JSValue sourceForVirtualObject(
    Zig::GlobalObject* globalObject,
    JSC::JSObject* object,
    const WTF::String& specifier,
    JSCommonJSModule* commonJSModule)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (commonJSModule) {
        auto esModuleValue = object->getIfPropertyExists(globalObject, vm.propertyNames->__esModule);
        RETURN_IF_EXCEPTION(scope, {});
        if (esModuleValue && esModuleValue.toBoolean(globalObject)) {
            auto defaultValue = object->getIfPropertyExists(globalObject, vm.propertyNames->defaultKeyword);
            RETURN_IF_EXCEPTION(scope, {});
            if (defaultValue && !defaultValue.isUndefined()) {
                commonJSModule->setExportsObject(defaultValue);
                commonJSModule->hasEvaluated = true;
                return commonJSModule;
            }
        }
    }
    auto function = generateObjectModuleSourceCode(globalObject, object);
    RETURN_IF_EXCEPTION(scope, {});
    auto source = JSC::SourceCode(JSC::SyntheticSourceProvider::create(WTF::move(function), JSC::SourceOrigin(), specifier));
    JSC::ensureStillAliveHere(object);
    return JSC::JSSourceCode::create(vm, WTF::move(source));
}

template<bool allowPromise>
static JSValue handleVirtualModuleResult(
    Zig::GlobalObject* globalObject,
    JSValue virtualModuleResult,
    const WTF::String& specifier,
    const WTF::String& referrer,
    bool wasModuleMock = false,
    JSCommonJSModule* commonJSModule = nullptr)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto rejectOrResolve = [&](JSValue code) -> JSValue {
        if (auto* exception = scope.exception()) {
            if constexpr (allowPromise) {
                auto value = exception->value();
                if (!scope.tryClearException())
                    return {};
                RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, value));
            } else {
                return exception->value();
            }
        }

        if constexpr (allowPromise) {
            scope.release();
            return resolvedInternalPromise(globalObject, code);
        } else {
            return code;
        }
    };

    if (auto* exception = dynamicDowncast<JSC::Exception>(virtualModuleResult)) {
        scope.throwException(globalObject, exception->value());
        return rejectOrResolve({});
    }
    bool isPromise = !!dynamicDowncast<JSC::JSPromise>(virtualModuleResult);
    if (!isPromise && wasModuleMock) {
        auto* object = virtualModuleResult.getObject();
        if (!object) {
            throwTypeError(globalObject, scope, "Expected module mock to return an object"_s);
            return rejectOrResolve({});
        }
        auto result = sourceForVirtualObject(globalObject, object, specifier, commonJSModule);
        if (scope.exception())
            return rejectOrResolve({});
        if (commonJSModule && result == commonJSModule)
            return result;
        return rejectOrResolve(result);
    }

    auto factory = isPromise
        ? bun_bindgen_source_function_RuntimeFunctions_chainVirtualModule_value(globalObject)
        : bun_bindgen_source_function_RuntimeFunctions_prepareVirtualModule_value(globalObject);
    if (scope.exception())
        return rejectOrResolve({});
    MarkedArgumentBuffer arguments;
    arguments.append(virtualModuleResult);
    arguments.append(jsString(vm, specifier));
    arguments.append(jsString(vm, referrer));
    arguments.append(isPromise ? jsBoolean(wasModuleMock) : (commonJSModule ? JSValue(commonJSModule) : jsNull()));
    if (arguments.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto result = JSC::profiledCall(globalObject, ProfilingReason::API, factory, getCallData(factory), jsUndefined(), arguments);
    if (scope.exception())
        return rejectOrResolve({});
    if (isPromise || (commonJSModule && result == commonJSModule))
        return result;
    return rejectOrResolve(result);
}

void Bindgen::Engine::bunBindgenEngine_AsyncModule_fulfill(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_AsyncModule_fulfill_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* promise = dynamicDowncast<JSC::JSPromise>(args.promise);
    RELEASE_ASSERT(promise);

    if (args.result.is_errorValue()) {
        RELEASE_AND_RETURN(scope, promise->reject(vm, args.result.errorValue()));
    }
    const auto& source = args.result.value();
    ResolvedSource resolvedSource {
        .sourceCode = source.sourceCode,
        .sourceURL = source.sourceURL,
        .isCommonJSModule = source.isCommonJSModule,
        .cjsCustomExtension = source.cjsCustomExtension,
        .jsvalueForExport = source.jsvalueForExport,
        .alreadyBundled = source.alreadyBundled,
        .bytecodeCache = source.bytecodeCache,
        .moduleInfo = source.moduleInfo,
        .bytecodeOriginPath = source.bytecodeOriginPath,
    };
    if (source.tag.is_source()) {
        resolvedSource.tag.set_source(source.tag.source());
    } else {
        RELEASE_ASSERT(source.tag.is_builtin());
        resolvedSource.tag.set_builtin(source.tag.builtin());
    }
    auto resolvedSourceOwner = WTF::makeScopeExit([&] {
        releaseResolvedSourceResources(resolvedSource);
    });

    auto* specifierValue = jsString(vm, args.specifier);
    RETURN_IF_EXCEPTION(scope, );

    // The new C++ module loader does not create a registry entry until *after*
    // this fetch promise resolves (provideFetch runs inside the
    // ModuleLoadTopSettled microtask). Two concurrent dynamic imports of the
    // same key therefore each get their own embedder fetch promise, and the
    // loser of that race must still resolve so its loadModule chain can reach
    // the (idempotent) provideFetch and reuse the already-loaded record.
    // The old #6946/#12910 short-circuit was for the JS loader's *shared*
    // entry.fetch promise; under the new loader returning here would strand
    // the loser's promise pending forever.
    //
    // FIXME(module-loader): the loser still re-transpiled the file. The right
    // fix is for JSModuleLoader::loadModule to ensureRegistered() *before*
    // calling fetch so concurrent importers share the entry's fetchPromise
    // instead of each round-tripping through the embedder.

    if (resolvedSource.isCommonJSModule) {
        auto created = Bun::createCommonJSModule(globalObject, specifierValue, resolvedSource);
        EXCEPTION_ASSERT(created.has_value() == !scope.exception());
        if (created.has_value()) {
            JSSourceCode* code = JSSourceCode::create(vm, WTF::move(created.value()));
            promise->resolve(globalObject, vm, code);
            scope.assertNoExceptionExceptTermination();
        } else {
            auto* exception = scope.exception();
            if (!vm.isTerminationException(exception)) {
                (void)scope.tryClearException();
                promise->reject(vm, exception);
                scope.assertNoExceptionExceptTermination();
            }
        }
    } else {
        auto provider = Zig::SourceProvider::create(globalObject, WTF::move(resolvedSource));
        if (auto* exception = scope.exception()) {
            if (!vm.isTerminationException(exception)) {
                (void)scope.tryClearException();
                promise->reject(vm, exception);
            }
            scope.assertNoExceptionExceptTermination();
            return;
        }
        if (Bun::IsolatedModuleCache::canUse(vm, globalObject->bunVM())) {
            Bun::IsolatedModuleCache::insert(vm, args.specifier, *provider);
        }
        promise->resolve(globalObject, vm, JSC::JSSourceCode::create(vm, JSC::SourceCode(provider.releaseNonNull())));
        scope.assertNoExceptionExceptTermination();
    }
}

static JSValue requireResolvedBuiltin(Zig::GlobalObject* globalObject, Bindgen::InternalModuleId id)
{
    switch (id) {
    case Bindgen::InternalModuleId::NodeModule:
        return globalObject->m_nodeModuleConstructor.getInitializedOnMainThread(globalObject);
    case Bindgen::InternalModuleId::NodeProcess:
        return globalObject->processObject();
    default:
        return globalObject->internalModuleRegistry()->requireId(globalObject, globalObject->vm(), id);
    }
}

JSValue fetchBuiltinModuleWithoutResolution(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    ResolvedSourceResult& res)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    bool found = bindgenFetchBuiltinModule(globalObject, specifier, WTF::emptyString(), res);
    RETURN_IF_EXCEPTION(scope, {});
    if (found) {
        if (res.is_errorValue()) {
            throwException(globalObject, scope, res.errorValue());
            RELEASE_AND_RETURN(scope, {});
        }
        if (!res.is_value()) {
            return {};
        }

        if (res.value().tag.is_builtin()) {
            auto result = requireResolvedBuiltin(globalObject, res.value().tag.builtin());
            RETURN_IF_EXCEPTION(scope, {});
            return result;
        }
        res.reset();
        RELEASE_AND_RETURN(scope, jsNumber(-1));
    }
    return {};
}

JSValue resolveAndFetchBuiltinModule(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    ResolvedSourceResult res {};
    bool found = bindgenResolveAndFetchBuiltinModule(globalObject, specifier, res);
    RETURN_IF_EXCEPTION(scope, {});
    if (found) {
        ASSERT(res.is_value());

        if (res.value().tag.is_builtin()) {
            auto result = requireResolvedBuiltin(globalObject, res.value().tag.builtin());
            RETURN_IF_EXCEPTION(scope, {});
            return result;
        }
    }
    return {};
}

void evaluateCommonJSCustomExtension(
    Zig::GlobalObject* globalObject,
    JSCommonJSModule* target,
    String filename,
    JSValue filenameValue,
    JSValue extension)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::CallData callData = JSC::getCallData(extension.asCell());
    if (callData.type == JSC::CallData::Type::None) {
        throwTypeError(globalObject, scope, makeString("require.extension is not a function"_s));
        return;
    }
    MarkedArgumentBuffer arguments;
    arguments.append(target);
    arguments.append(filenameValue);
    JSC::profiledCall(globalObject, ProfilingReason::API, extension, callData, target, arguments);
    RETURN_IF_EXCEPTION(scope, );
}

JSValue fetchCommonJSModule(
    Zig::GlobalObject* globalObject,
    JSCommonJSModule* target,
    JSValue specifierValue,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute)
{
    void* bunVM = globalObject->bunVM();
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    ResolvedSourceResult resValue {};
    ResolvedSourceResult& res = resValue;

    bool wasModuleMock = false;

    // When "bun test" is enabled, allow users to override builtin modules
    // This is important for being able to trivially mock things like the filesystem.
    if (isBunTest()) {
        auto virtualModuleResult = Bun::runVirtualModule(globalObject, specifier, wasModuleMock);
        RETURN_IF_EXCEPTION(scope, {});
        if (virtualModuleResult) {
            JSValue promiseOrCommonJSModule = handleVirtualModuleResult<true>(globalObject, *virtualModuleResult, specifier, referrer, wasModuleMock, target);
            RETURN_IF_EXCEPTION(scope, {});

            // If we assigned module.exports to the virtual module, we're done here.
            if (promiseOrCommonJSModule == target) {
                RELEASE_AND_RETURN(scope, target);
            }
            JSPromise* promise = uncheckedDowncast<JSPromise>(promiseOrCommonJSModule);
            switch (promise->status()) {
            case JSPromise::Status::Rejected: {
                promise->markAsHandled();
                JSC::throwException(globalObject, scope, promise->result());
                RELEASE_AND_RETURN(scope, JSValue {});
            }
            case JSPromise::Status::Pending: {
                JSC::throwTypeError(globalObject, scope, makeString("require() async module \""_s, specifier, "\" is unsupported. use \"await import()\" instead."_s));
                RELEASE_AND_RETURN(scope, JSValue {});
            }
            case JSPromise::Status::Fulfilled: {
                if (!wasModuleMock) {
                    auto* jsSourceCode = uncheckedDowncast<JSSourceCode>(promise->result());
                    JSC::VM::SynchronousModuleQueue queue;
                    queue.prev = vm.m_synchronousModuleQueue;
                    vm.m_synchronousModuleQueue = &queue;
                    globalObject->moduleLoader()->provideFetch(globalObject, JSC::Identifier::fromString(vm, specifier), JSC::ScriptFetchParameters::Type::JavaScript, jsSourceCode);
                    if (!scope.exception()) JSC::JSModuleLoader::drainSynchronousModuleQueue(globalObject);
                    vm.m_synchronousModuleQueue = queue.prev;
                    RETURN_IF_EXCEPTION(scope, {});
                }
                RELEASE_AND_RETURN(scope, jsNumber(-1));
            }
            }
        }
    }

    auto builtin = fetchBuiltinModuleWithoutResolution(globalObject, specifier, res);
    RETURN_IF_EXCEPTION(scope, {});
    if (builtin) {
        if (!res.is_value()) {
            RELEASE_AND_RETURN(scope, builtin);
        }
        target->setExportsObject(builtin);
        target->hasEvaluated = true;
        RELEASE_AND_RETURN(scope, target);
    }

    // When "bun test" is NOT enabled, disable users from overriding builtin modules
    if (!isBunTest()) {
        auto virtualModuleResult = Bun::runVirtualModule(globalObject, specifier, wasModuleMock);
        RETURN_IF_EXCEPTION(scope, {});
        if (virtualModuleResult) {
            JSValue promiseOrCommonJSModule = handleVirtualModuleResult<true>(globalObject, *virtualModuleResult, specifier, referrer, wasModuleMock, target);
            RETURN_IF_EXCEPTION(scope, {});

            // If we assigned module.exports to the virtual module, we're done here.
            if (promiseOrCommonJSModule == target) {
                RELEASE_AND_RETURN(scope, target);
            }
            JSPromise* promise = uncheckedDowncast<JSPromise>(promiseOrCommonJSModule);
            switch (promise->status()) {
            case JSPromise::Status::Rejected: {
                promise->markAsHandled();
                JSC::throwException(globalObject, scope, promise->result());
                RELEASE_AND_RETURN(scope, JSValue {});
            }
            case JSPromise::Status::Pending: {
                JSC::throwTypeError(globalObject, scope, makeString("require() async module \""_s, specifier, "\" is unsupported. use \"await import()\" instead."_s));
                RELEASE_AND_RETURN(scope, JSValue {});
            }
            case JSPromise::Status::Fulfilled: {
                if (!wasModuleMock) {
                    auto* jsSourceCode = uncheckedDowncast<JSSourceCode>(promise->result());
                    JSC::VM::SynchronousModuleQueue queue;
                    queue.prev = vm.m_synchronousModuleQueue;
                    vm.m_synchronousModuleQueue = &queue;
                    globalObject->moduleLoader()->provideFetch(globalObject, JSC::Identifier::fromString(vm, specifier), JSC::ScriptFetchParameters::Type::JavaScript, jsSourceCode);
                    if (!scope.exception()) JSC::JSModuleLoader::drainSynchronousModuleQueue(globalObject);
                    vm.m_synchronousModuleQueue = queue.prev;
                    RETURN_IF_EXCEPTION(scope, {});
                }
                RELEASE_AND_RETURN(scope, jsNumber(-1));
            }
            }
        }
    }

    bool hasAlreadyLoadedESMVersionSoWeShouldntTranspileItTwice = [&]() -> bool {
        auto* entry = globalObject->moduleLoader()->registryEntry(JSC::Identifier::fromString(vm, specifier));
        return entry && entry->status() >= JSC::ModuleRegistryEntry::Status::Fetched;
    }();

    if (hasAlreadyLoadedESMVersionSoWeShouldntTranspileItTwice) {
        RELEASE_AND_RETURN(scope, jsNumber(-1));
    }

    if (Bun::IsolatedModuleCache::canUse(vm, bunVM, typeAttribute)) {
        if (auto* cached = Bun::IsolatedModuleCache::lookup(vm, specifier)) {
            if (cached->sourceType() == JSC::SourceProviderSourceType::Program) {
                // The wrapper override only affects CJS evaluation; if it's
                // active, fall through and re-transpile so the override can run.
                if (!globalObject->hasOverriddenModuleWrapper) {
                    target->evaluate(globalObject, Ref(*cached), resolvedSourceHasKind(cached->m_resolvedSource, Bindgen::ResolvedSourceKind::package_json_type_module));
                    RETURN_IF_EXCEPTION(scope, {});
                    RELEASE_AND_RETURN(scope, target);
                }
            } else {
                JSC::VM::SynchronousModuleQueue queue;
                queue.prev = vm.m_synchronousModuleQueue;
                vm.m_synchronousModuleQueue = &queue;
                globalObject->moduleLoader()->provideFetch(globalObject, JSC::Identifier::fromString(vm, specifier), JSC::ScriptFetchParameters::Type::JavaScript, JSC::SourceCode(Ref(*cached)));
                if (!scope.exception()) JSC::JSModuleLoader::drainSynchronousModuleQueue(globalObject);
                vm.m_synchronousModuleQueue = queue.prev;
                RETURN_IF_EXCEPTION(scope, {});
                RELEASE_AND_RETURN(scope, jsNumber(-1));
            }
        }
    }

    return fetchCommonJSModuleNonBuiltin<false>(bunVM, vm, globalObject, specifier, specifierValue, referrer, typeAttribute, res, target, BunLoaderType::_none, scope);
}

template<bool isExtension>
JSValue fetchCommonJSModuleNonBuiltin(
    void* bunVM,
    JSC::VM& vm,
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    JSC::JSValue specifierValue,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute,
    ResolvedSourceResult& res,
    JSCommonJSModule* target,
    BunLoaderType forceLoaderType,
    JSC::ThrowScope& scope)
{
    bindgenTranspileFile(globalObject, specifier, referrer, typeAttribute, res, false, !isExtension, forceLoaderType);
    RETURN_IF_EXCEPTION(scope, {});
    if (res.is_value() && res.value().isCommonJSModule) {
        if constexpr (isExtension) {
            target->evaluateWithPotentiallyOverriddenCompile(globalObject, specifier, specifierValue, res.value());
        } else {
            target->evaluate(globalObject, specifier, res.value());
        }
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, target);
    }

    if (res.is_errorValue()) {
        throwException(globalObject, scope, res.errorValue());
        RELEASE_AND_RETURN(scope, {});
    }

    RELEASE_ASSERT(res.is_value());

    // The JSONForObjectLoader tag is source code returned from Bun that needs
    // to go through the JSON parser in JSC.
    //
    // We don't use JSON.parse directly in JS because we want the top-level keys of the JSON
    // object to be accessible as named imports.
    //
    // We don't use Bun's JSON parser because JSON.parse is faster and
    // handles stack overflow better.
    //
    // When parsing tsconfig.*.json or jsconfig.*.json, we go through Bun's JSON
    // parser instead to support comments and trailing commas.
    if (resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::json_for_object_loader)) {
        WTF::String jsonSource = res.value().sourceCode;
        JSC::JSValue value = JSC::JSONParseWithException(globalObject, jsonSource);
        RETURN_IF_EXCEPTION(scope, {});

        target->putDirect(vm, WebCore::clientData(vm)->builtinNames().exportsPublicName(), value, 0);
        target->hasEvaluated = true;
        RELEASE_AND_RETURN(scope, target);

    }
    // TOML and JSONC may go through here
    else if (resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::exports_object) || resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::export_default_object)) {
        if (!res.value().jsvalueForExport) {
            JSC::throwException(globalObject, scope, JSC::createSyntaxError(globalObject, "Failed to parse Object"_s));
            RELEASE_AND_RETURN(scope, {});
        }
        JSC::JSValue value = *res.value().jsvalueForExport;

        target->putDirect(vm, WebCore::clientData(vm)->builtinNames().exportsPublicName(), value, 0);
        target->hasEvaluated = true;
        RELEASE_AND_RETURN(scope, target);
    } else if (resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::common_js_custom_extension)) {
        if constexpr (isExtension) {
            ASSERT_NOT_REACHED();
            JSC::throwException(globalObject, scope, JSC::createSyntaxError(globalObject, "Recursive extension. This is a bug in Bun"_s));
            RELEASE_AND_RETURN(scope, {});
        }
        if (!res.value().cjsCustomExtension) {
            JSC::throwException(globalObject, scope, JSC::createTypeError(globalObject, "require.extension is not a function"_s));
            RELEASE_AND_RETURN(scope, {});
        }
        evaluateCommonJSCustomExtension(globalObject, target, specifier, specifierValue, *res.value().cjsCustomExtension);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, target);
    }

    auto provider = Zig::SourceProvider::create(globalObject, WTF::move(res.value()));
    RETURN_IF_EXCEPTION(scope, {});
    if (Bun::IsolatedModuleCache::canUse(vm, bunVM, typeAttribute))
        Bun::IsolatedModuleCache::insert(vm, specifier, *provider);
    // provideFetch() now drives the C++ loader pipeline (parse -> module record)
    // via internal microtasks. We're about to hand this entry to require(esm)'s
    // synchronous load path, so run those reactions through the loader's
    // private queue instead of leaving them on the user microtask queue we're
    // currently inside of.
    {
        JSC::VM::SynchronousModuleQueue queue;
        queue.prev = vm.m_synchronousModuleQueue;
        vm.m_synchronousModuleQueue = &queue;
        globalObject->moduleLoader()->provideFetch(globalObject, JSC::Identifier::fromString(vm, specifier), JSC::ScriptFetchParameters::Type::JavaScript, JSC::SourceCode(provider.releaseNonNull()));
        if (!scope.exception()) JSC::JSModuleLoader::drainSynchronousModuleQueue(globalObject);
        vm.m_synchronousModuleQueue = queue.prev;
    }
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, jsNumber(-1));
}

// Explicit instantiations of fetchCommonJSModuleNonBuiltin
template JSValue fetchCommonJSModuleNonBuiltin<true>(
    void* bunVM,
    JSC::VM& vm,
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    JSC::JSValue specifierValue,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute,
    ResolvedSourceResult& res,
    JSCommonJSModule* target,
    BunLoaderType forceLoaderType,
    JSC::ThrowScope& scope);
template JSValue fetchCommonJSModuleNonBuiltin<false>(
    void* bunVM,
    JSC::VM& vm,
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    JSC::JSValue specifierValue,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute,
    ResolvedSourceResult& res,
    JSCommonJSModule* target,
    BunLoaderType forceLoaderType,
    JSC::ThrowScope& scope);

template<bool allowPromise>
static JSValue fetchESMSourceCode(
    Zig::GlobalObject* globalObject,
    JSC::JSString* specifierJS,
    ResolvedSourceResult& res,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute)
{
    void* bunVM = globalObject->bunVM();
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto reject = [&](JSC::JSValue exception) -> JSValue {
        if constexpr (allowPromise) {
            RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, exception));
        } else {
            throwException(globalObject, scope, exception);
            return {};
        }
    };

    const auto rejectOrResolve = [&](JSValue code) -> JSValue {
        if (auto* exception = scope.exception()) {
            if constexpr (!allowPromise) {
                scope.release();
                return {};
            }

            (void)scope.tryClearException();
            RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, exception));
        }

        if constexpr (allowPromise) {
            auto* ret = resolvedInternalPromise(globalObject, code);
            scope.release();
            return ret;
        } else {
            return code;
        }
    };

    bool wasModuleMock = false;

    // When "bun test" is enabled, allow users to override builtin modules
    // This is important for being able to trivially mock things like the filesystem.
    if (isBunTest()) {
        auto virtualModuleResult = Bun::runVirtualModule(globalObject, specifier, wasModuleMock);
        RETURN_IF_EXCEPTION(scope, {});
        if (virtualModuleResult) {
            RELEASE_AND_RETURN(scope, handleVirtualModuleResult<allowPromise>(globalObject, *virtualModuleResult, specifier, referrer, wasModuleMock));
        }
    }

    bool foundBuiltin = bindgenFetchBuiltinModule(globalObject, specifier, referrer, res);
    RETURN_IF_EXCEPTION(scope, {});
    if (foundBuiltin) {
        if (res.is_errorValue()) {
            throwException(globalObject, scope, res.errorValue());
            auto* exception = scope.exception();
            (void)scope.tryClearException();
            RELEASE_AND_RETURN(scope, reject(exception));
        }

        RELEASE_ASSERT(res.is_value());

        // This can happen if it's a `bun build --compile`'d CommonJS file
        if (res.value().isCommonJSModule) {
            auto created = Bun::createCommonJSModule(globalObject, specifierJS, res.value());
            EXCEPTION_ASSERT(created.has_value() == !scope.exception());
            if (created.has_value()) {
                RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(vm, WTF::move(created.value()))));
            }

            if constexpr (allowPromise) {
                auto* exception = scope.exception();
                (void)scope.tryClearException();
                RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, exception));
            } else {
                scope.release();
                return {};
            }
        }

        auto moduleKey = specifier;

        // bun:wrap and a few other builtins return real JS source (not a
        // synthetic generator). Their providers are identical across globals,
        // so check the isolation cache before re-creating one.
        const bool useIsolationCacheForBuiltin = Bun::IsolatedModuleCache::canUse(vm, bunVM, typeAttribute);
        if (useIsolationCacheForBuiltin) {
            if (auto* cached = Bun::IsolatedModuleCache::lookup(vm, moduleKey)) {
                RELEASE_AND_RETURN(scope, rejectOrResolve(JSC::JSSourceCode::create(vm, JSC::SourceCode(Ref(*cached)))));
            }
        }

        if (auto generator = Bindgen::findNativeModuleGenerator(moduleKey)) {
            auto source = JSC::SourceCode(JSC::SyntheticSourceProvider::create(generator, JSC::SourceOrigin(), WTF::move(moduleKey)));
            RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(vm, WTF::move(source))));
        }

        if (res.value().tag.is_builtin()) {
            auto source = JSC::SourceCode(JSC::SyntheticSourceProvider::create(generateInternalModuleSourceCode(globalObject, res.value().tag.builtin()), JSC::SourceOrigin(URL(makeString("builtins://"_s, moduleKey))), moduleKey));
            RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(vm, WTF::move(source))));
        }
        auto provider = Zig::SourceProvider::create(globalObject, WTF::move(res.value()), JSC::SourceProviderSourceType::Module, true);
        if (scope.exception()) [[unlikely]]
            return rejectOrResolve({});
        if (useIsolationCacheForBuiltin)
            Bun::IsolatedModuleCache::insert(vm, moduleKey, *provider);
        RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(vm, JSC::SourceCode(provider.releaseNonNull()))));
    }

    // When "bun test" is NOT enabled, disable users from overriding builtin modules
    if (!isBunTest()) {
        auto virtualModuleResult = Bun::runVirtualModule(globalObject, specifier, wasModuleMock);
        RETURN_IF_EXCEPTION(scope, {});
        if (virtualModuleResult) {
            RELEASE_AND_RETURN(scope, handleVirtualModuleResult<allowPromise>(globalObject, *virtualModuleResult, specifier, referrer, wasModuleMock));
        }
    }

    const bool useIsolationCache = Bun::IsolatedModuleCache::canUse(vm, bunVM, typeAttribute);
    if (useIsolationCache) {
        if (auto* cached = Bun::IsolatedModuleCache::lookup(vm, specifier)) {
            if (cached->sourceType() != JSC::SourceProviderSourceType::Program) {
                RELEASE_AND_RETURN(scope, rejectOrResolve(JSC::JSSourceCode::create(vm, JSC::SourceCode(Ref(*cached)))));
            }
            // Mirror the guard in fetchCommonJSModule: a Module.wrap override only
            // affects CJS evaluation, so don't serve a cached Program-type provider
            // when one is active in this global — fall through to re-transpile.
            if (!globalObject->hasOverriddenModuleWrapper) {
                auto created = Bun::createCommonJSModule(globalObject, specifierJS, Ref(*cached), resolvedSourceHasKind(cached->m_resolvedSource, Bindgen::ResolvedSourceKind::package_json_type_module));
                EXCEPTION_ASSERT(created.has_value() == !scope.exception());
                if (created.has_value()) {
                    RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(vm, WTF::move(created.value()))));
                }
                if constexpr (allowPromise) {
                    auto* exception = scope.exception();
                    (void)scope.tryClearException();
                    RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, exception));
                } else {
                    scope.release();
                    return {};
                }
            }
        }
    }

    auto pendingCtx = bindgenTranspileFile(globalObject, specifier, referrer, typeAttribute, res, allowPromise, false, BunLoaderType::_none);
    if constexpr (allowPromise) {
        RETURN_IF_EXCEPTION(scope, JSC::JSPromise::rejectedPromiseWithCaughtException(globalObject, scope));
        if (pendingCtx) {
            return *pendingCtx;
        }
    } else {
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_ASSERT(!pendingCtx);
    }

    if (res.is_value() && res.value().isCommonJSModule) {
        auto created = Bun::createCommonJSModule(globalObject, specifierJS, res.value());
        EXCEPTION_ASSERT(created.has_value() == !scope.exception());
        if (created.has_value()) {
            RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(vm, WTF::move(created.value()))));
        }

        if constexpr (allowPromise) {
            auto* exception = scope.exception();
            (void)scope.tryClearException();
            RELEASE_AND_RETURN(scope, rejectedInternalPromise(globalObject, exception));
        } else {
            scope.release();
            return {};
        }
    }

    if (res.is_errorValue()) {
        throwException(globalObject, scope, res.errorValue());
        auto* exception = scope.exception();
        (void)scope.tryClearException();
        RELEASE_AND_RETURN(scope, reject(exception));
    }

    RELEASE_ASSERT(res.is_value());

    // The JSONForObjectLoader tag is source code returned from Bun that needs
    // to go through the JSON parser in JSC.
    //
    // We don't use JSON.parse directly in JS because we want the top-level keys of the JSON
    // object to be accessible as named imports.
    //
    // We don't use Bun's JSON parser because JSON.parse is faster and
    // handles stack overflow better.
    //
    // When parsing tsconfig.*.json or jsconfig.*.json, we go through Bun's JSON
    // parser instead to support comments and trailing commas.
    if (resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::json_for_object_loader)) {
        WTF::String jsonSource = res.value().sourceCode;
        JSC::JSValue value = JSC::JSONParseWithException(globalObject, jsonSource);
        if (scope.exception()) [[unlikely]] {
            auto* exception = scope.exception();
            (void)scope.tryClearException();
            RELEASE_AND_RETURN(scope, reject(exception));
        }

        // JSON can become strings, null, numbers, booleans so we must handle "export default 123"
        auto function = generateJSValueModuleSourceCode(
            globalObject,
            value);
        RETURN_IF_EXCEPTION(scope, rejectOrResolve({}));
        auto source = JSC::SourceCode(
            JSC::SyntheticSourceProvider::create(WTF::move(function),
                JSC::SourceOrigin(), specifier));
        JSC::ensureStillAliveHere(value);
        RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(globalObject->vm(), WTF::move(source))));
    }
    // TOML and JSONC may go through here
    else if (resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::exports_object)) {
        if (!res.value().jsvalueForExport) {
            RELEASE_AND_RETURN(scope, reject(JSC::createSyntaxError(globalObject, "Failed to parse Object"_s)));
        }
        JSC::JSValue value = *res.value().jsvalueForExport;
        auto function = generateJSValueModuleSourceCode(globalObject, value);
        RETURN_IF_EXCEPTION(scope, rejectOrResolve({}));
        auto source = JSC::SourceCode(
            JSC::SyntheticSourceProvider::create(WTF::move(function),
                JSC::SourceOrigin(), specifier));
        JSC::ensureStillAliveHere(value);
        RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(globalObject->vm(), WTF::move(source))));
    } else if (resolvedSourceHasKind(res.value(), Bindgen::ResolvedSourceKind::export_default_object)) {
        if (!res.value().jsvalueForExport) {
            RELEASE_AND_RETURN(scope, reject(JSC::createSyntaxError(globalObject, "Failed to parse Object"_s)));
        }
        JSC::JSValue value = *res.value().jsvalueForExport;

        // JSON can become strings, null, numbers, booleans so we must handle "export default 123"
        auto function = generateJSValueExportDefaultObjectSourceCode(globalObject, value);
        RETURN_IF_EXCEPTION(scope, rejectOrResolve({}));
        auto source = JSC::SourceCode(
            JSC::SyntheticSourceProvider::create(WTF::move(function),
                JSC::SourceOrigin(), specifier));
        JSC::ensureStillAliveHere(value);
        RELEASE_AND_RETURN(scope, rejectOrResolve(JSSourceCode::create(globalObject->vm(), WTF::move(source))));
    }

    auto provider = Zig::SourceProvider::create(globalObject, WTF::move(res.value()));
    if (scope.exception()) [[unlikely]]
        return rejectOrResolve({});
    if (useIsolationCache) {
        Bun::IsolatedModuleCache::insert(vm, specifier, *provider);
    }
    RELEASE_AND_RETURN(scope, rejectOrResolve(JSC::JSSourceCode::create(vm, JSC::SourceCode(provider.releaseNonNull()))));
}

JSValue fetchESMSourceCodeSync(
    Zig::GlobalObject* globalObject,
    JSC::JSString* specifierJS,
    ResolvedSourceResult& res,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute)
{
    return fetchESMSourceCode<false>(globalObject, specifierJS, res, specifier, referrer, typeAttribute);
}

JSValue fetchESMSourceCodeAsync(
    Zig::GlobalObject* globalObject,
    JSC::JSString* specifierJS,
    ResolvedSourceResult& res,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute)
{
    return fetchESMSourceCode<true>(globalObject, specifierJS, res, specifier, referrer, typeAttribute);
}
}

using namespace Bun;

Bun::Bindgen::PreparedVirtualModuleResult Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_prepareVirtualModule(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_prepareVirtualModule_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    Bun::Bindgen::PreparedVirtualModuleResult result;
    const auto& input = args.result;
    if (input.loader == RuntimeVirtualModuleLoader::object) {
        const auto* exports = input.exports.convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!exports)
            return {};
        auto* commonJSModule = args.commonJSModule ? dynamicDowncast<Bun::JSCommonJSModule>(*args.commonJSModule) : nullptr;
        auto prepared = sourceForVirtualObject(globalObject, JSC::asObject(*exports), args.specifier, commonJSModule);
        RETURN_IF_EXCEPTION(scope, {});
        if (commonJSModule && prepared == commonJSModule)
            result.set_module(prepared);
        else
            result.set_source(prepared);
        return result;
    }

    std::optional<BunLoaderType> loader;
    if (input.loader) {
        switch (*input.loader) {
        case RuntimeVirtualModuleLoader::js: loader = BunLoaderType::js; break;
        case RuntimeVirtualModuleLoader::jsx: loader = BunLoaderType::jsx; break;
        case RuntimeVirtualModuleLoader::ts: loader = BunLoaderType::ts; break;
        case RuntimeVirtualModuleLoader::tsx: loader = BunLoaderType::tsx; break;
        case RuntimeVirtualModuleLoader::json: loader = BunLoaderType::json; break;
        case RuntimeVirtualModuleLoader::toml: loader = BunLoaderType::toml; break;
        case RuntimeVirtualModuleLoader::yaml: loader = BunLoaderType::yaml; break;
        case RuntimeVirtualModuleLoader::md: loader = BunLoaderType::md; break;
        case RuntimeVirtualModuleLoader::object: RELEASE_ASSERT_NOT_REACHED();
        }
    }
    const auto* contents = input.contents.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!contents)
        return {};
    auto sourceCode = contents->is_string()
        ? contents->string()
        : WTF::String::fromUTF8ReplacingInvalidSequences(contents->buffer());
    ResolvedSourceResult resolved(Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_transpileVirtualModuleCode(
        globalObject, args.specifier, args.referrer, sourceCode, loader));
    RETURN_IF_EXCEPTION(scope, {});
    if (resolved.is_errorValue()) {
        scope.throwException(globalObject, resolved.errorValue());
        return {};
    }
    RELEASE_ASSERT(resolved.is_value());
    auto provider = Zig::SourceProvider::create(globalObject, WTF::move(resolved.value()));
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(provider);
    result.set_source(JSC::JSSourceCode::create(vm, JSC::SourceCode(provider.releaseNonNull())));
    return result;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionEvictIsolationSourceProviderCache(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionEvictIsolationSourceProviderCache_Arguments& args)
{
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const std::optional<WTF::String>& specifier = args.specifier;
    auto& vm = JSC::getVM(globalObject);
    if (!specifier) {
        Bun::IsolatedModuleCache::clear(vm);
        return;
    }
    Bun::IsolatedModuleCache::evict(vm, *specifier);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_completeVirtualModule(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_completeVirtualModule_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    return handleVirtualModuleResult<true>(globalObject, args.result, args.specifier, args.referrer, args.wasModuleMock);
}
