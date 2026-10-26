#include "JSBundlerPlugin.h"
#include "Bindgen/IDLConvertBase.h"
#include "Bindgen/EnumerationConversion.h"
#include "SchemaBindings.h"
#include "StringConversion.h"

#include "BunProcess.h"
#include "../../../packages/bun-native-bundler-plugin-api/bundler_plugin.h"
#include "JavaScriptCore/CallData.h"
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSTypeInfo.h>
#include <JavaScriptCore/Structure.h>
#include "helpers.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JavaScript.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/JSCInlines.h>
#include "JSFFIFunction.h"

#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SubspaceInlines.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <cstring>
#include <limits>
#include "BunClientData.h"
#include "ModuleLoader.h"
#include <JavaScriptCore/RegularExpression.h>
#include <JavaScriptCore/LazyProperty.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <JavaScriptCore/YarrMatchingContextHolder.h>
#include "ErrorCode.h"
#include "napi_external.h"
#include "WebCoreJSBuiltins.h"

#include <JavaScriptCore/JSPromise.h>

#if OS(WINDOWS)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace Bun {

static JSBundlerPlugin* bundlerPlugin(JSC::JSValue value)
{
    auto* plugin = dynamicDowncast<JSBundlerPlugin>(value);
    RELEASE_ASSERT(plugin);
    return plugin;
}

static NapiExternal* optionalNapiExternal(const std::optional<JSC::JSValue>& value)
{
    if (!value)
        return nullptr;
    auto* external = dynamicDowncast<NapiExternal>(*value);
    RELEASE_ASSERT(external);
    return external;
}

static bool anyMatchesForNamespace(JSC::VM& vm, BundlerPlugin::FilterList& list, const String& namespaceString, const String& path)
{
    if (list.isEmpty())
        return false;

    auto* group = list.group(namespaceString);
    if (group == nullptr) {
        return false;
    }

    auto& filters = *group;
    for (auto& filter : filters) {
        if (filter.match(vm, path)) {
            return true;
        }
    }

    return false;
}
bool BundlerPlugin::anyMatchesCrossThread(JSC::VM& vm, const String& namespaceString, const String& path, bool isOnLoad)
{
    if (isOnLoad) {
        return anyMatchesForNamespace(vm, this->onLoad, namespaceString, path);
    } else {
        return anyMatchesForNamespace(vm, this->onResolve, namespaceString, path);
    }
}

#define BUN_BINDGEN_OBJECT_SURFACE_JSBundlerPlugin
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSBundlerPlugin

template<typename Visitor>
void JSBundlerPlugin::visitAdditionalChildrenInGCThread(Visitor& visitor)
{
    this->onLoadFunction.visit(visitor);
    this->onResolveFunction.visit(visitor);
    this->setupFunction.visit(visitor);
    WTF::Locker locker { this->cellLock() };
    for (auto& external : this->nativePluginExternals)
        visitor.append(external);
}

template<typename Visitor>
void JSBundlerPlugin::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSBundlerPlugin* thisObject = uncheckedDowncast<JSBundlerPlugin>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
    thisObject->visitAdditionalChildrenInGCThread(visitor);
}
DEFINE_VISIT_CHILDREN(JSBundlerPlugin);
DEFINE_VISIT_ADDITIONAL_CHILDREN_IN_GC_THREAD(JSBundlerPlugin);

template<typename Visitor>
void JSBundlerPlugin::visitOutputConstraintsImpl(JSCell* cell, Visitor& visitor)
{
    JSBundlerPlugin* thisObject = uncheckedDowncast<JSBundlerPlugin>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    thisObject->visitAdditionalChildrenInGCThread(visitor);
}
DEFINE_VISIT_OUTPUT_CONSTRAINTS(JSBundlerPlugin);

const JSC::ClassInfo JSBundlerPlugin::s_info = { "BundlerPlugin"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSBundlerPlugin) };

/// `BundlerPlugin.prototype.addFilter(filter: RegExp, namespace: string, isOnLoad: 0 | 1): void`
void Bindgen::Cpp::bunBindgenCpp_JSBundlerPlugin_jsBundlerPluginFunction_addFilter(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_JSBundlerPlugin_jsBundlerPluginFunction_addFilter_Arguments& args)
{
    auto* thisObject = bundlerPlugin(args.bindingThis);
    if (thisObject->plugin.tombstoned) {
        return;
    }

    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto* regExpInput = args.filter.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!regExpInput)
        return;
    auto* regExp = uncheckedDowncast<JSC::RegExpObject>(*regExpInput);

    const auto* namespaceInput = args.namespaceString.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!namespaceInput)
        return;
    WTF::String namespaceStr = *namespaceInput;
    if (namespaceStr == "file"_s) {
        namespaceStr = String();
    }

    const auto* isOnLoadInput = args.isOnLoad.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!isOnLoadInput)
        return;

    if (thisObject->plugin.tombstoned)
        return;

    auto& filters = *isOnLoadInput ? thisObject->plugin.onLoad : thisObject->plugin.onResolve;
    auto* regexp = regExp->regExp();
    if (!filters.tryAppend(namespaceStr, BundlerPlugin::FilterRegExp(regexp->pattern(), regexp->flags())))
        throwOutOfMemoryError(&globalObject, scope);
}

bool BundlerPlugin::FilterRegExp::match(JSC::VM& vm, const String& path)
{
    WTF::Locker locker { lock };
    Yarr::MatchingContextHolder regExpContext(vm, nullptr, Yarr::MatchFrom::CompilerThread);
    return regex.match(path) != -1;
}

Bindgen::NativeAllocationResult<uint32_t> BundlerPlugin::NativePluginList::call(JSC::VM& vm, JSBundlerPluginParseContext* bunContext, const String& namespaceString, const String& path, OnBeforeParseArguments* onBeforeParseArgs, OnBeforeParseResult* onBeforeParseResult)
{
    auto* groupPtr = this->group(namespaceString);
    if (groupPtr == nullptr) {
        return 0;
    }
    auto& entries = *groupPtr;

    uint32_t count = 0;
    for (size_t i = 0, total = entries.size(); i < total; ++i) {

        if (i > 0) {
            Bindgen::ZigExports::bunBindgenZig_JSBundlerPlugin_onBeforeParseResultReset(onBeforeParseResult);
        }

        if (entries[i].filter.match(vm, path)) {
            ASSERT(onBeforeParseArgs != nullptr);
            onBeforeParseArgs->external = entries[i].callback.external;

            JSBundlerPluginNativeOnBeforeParseCallback callback = entries[i].callback.callback;
            const char* name = entries[i].callback.name ? entries[i].callback.name : "<unknown>";
            {
                auto crashScopeResult = Bindgen::ZigExports::bunBindgenZig_CrashHandlerBindings_crashHandlerBeginNativePlugin(
                    std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(name), std::strlen(name) });
                if (!crashScopeResult)
                    return Bindgen::nativeAllocationFailure();
                Bindgen::ByteOwner crashScope { std::exchange(*crashScopeResult, nullptr) };
                callback(onBeforeParseArgs, onBeforeParseResult);
            }

            count++;
        }

        if (Bindgen::ZigExports::bunBindgenZig_JSBundlerPlugin_onBeforeParsePluginIsDone(bunContext)) {
            return count;
        }
    }

    return count;
}
void Bindgen::Cpp::bunBindgenCpp_JSBundlerPlugin_jsBundlerPluginFunction_onBeforeParse(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_JSBundlerPlugin_jsBundlerPluginFunction_onBeforeParse_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* thisObject = bundlerPlugin(args.bindingThis);
    if (thisObject->plugin.tombstoned) {
        return;
    }

    const auto* filterInput = args.filter.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!filterInput)
        return;
    auto* jsRegexp = uncheckedDowncast<JSC::RegExpObject>(*filterInput);
    const String filterPattern = jsRegexp->regExp()->pattern();
    const auto filterFlags = jsRegexp->regExp()->flags();

    const auto* namespaceInput = args.namespaceString.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!namespaceInput)
        return;
    WTF::String namespaceStr = *namespaceInput;
    if (namespaceStr == "file"_s) {
        namespaceStr = String();
    }

    const auto* nodeAddonInput = args.nodeAddon.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!nodeAddonInput)
        return;
    JSC::JSValue nodeAddon = *nodeAddonInput;

    const auto* symbolInput = args.symbol.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!symbolInput)
        return;
    const WTF::String& onBeforeParseSymbol = *symbolInput;

    // The dlopen *void handle is attached to the node_addon as a NapiExternal
    auto* napiExternal = dynamicDowncast<NapiExternal>(nodeAddon.getObject()->get(&globalObject, WebCore::builtinNames(vm).napiDlopenHandlePrivateName()));
    RETURN_IF_EXCEPTION(scope, void());
    if (!napiExternal) [[unlikely]] {
        Bun::throwError(&globalObject, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "Expected node_addon (2nd argument) to have a napiDlopenHandle property"_s);
        return;
    }
    auto* meta = static_cast<NapiModuleMeta*>(napiExternal->value());
    if (!meta || !meta->dlopenHandle) {
        Bun::throwError(&globalObject, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "Expected node_addon to have an active native module handle"_s);
        return;
    }
    void* dlopen_handle = meta->dlopenHandle;
    if (onBeforeParseSymbol.contains(static_cast<char16_t>(0))) {
        Bun::throwError(&globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "Native plugin symbol must not contain null bytes"_s);
        return;
    }
    auto utf8 = encodeUTF8ReplacingInvalidSequences(onBeforeParseSymbol, UTF8Termination::Null);
    if (!utf8) {
        throwOutOfMemoryError(&globalObject, scope);
        return;
    }
    const auto* symbolName = reinterpret_cast<const char*>(utf8->span().data());

#if OS(WINDOWS)
    void* on_before_parse_symbol_ptr = GetProcAddress((HMODULE)dlopen_handle, symbolName);
    const char** native_plugin_name = (const char**)GetProcAddress((HMODULE)dlopen_handle, "BUN_PLUGIN_NAME");
#else
    void* on_before_parse_symbol_ptr = dlsym(dlopen_handle, symbolName);
    const char** native_plugin_name = (const char**)dlsym(dlopen_handle, "BUN_PLUGIN_NAME");
#endif

    if (!on_before_parse_symbol_ptr) {
        auto message = WTF::tryMakeString("Could not find the symbol \""_s, onBeforeParseSymbol, "\" in the given napi module."_s);
        if (message.isNull()) {
            throwOutOfMemoryError(&globalObject, scope);
            return;
        }
        Bun::throwError(&globalObject, scope, ErrorCode::ERR_INVALID_ARG_TYPE, message);
        return;
    }

    JSBundlerPluginNativeOnBeforeParseCallback callback = reinterpret_cast<JSBundlerPluginNativeOnBeforeParseCallback>(on_before_parse_symbol_ptr);

    const auto* externalInput = args.external.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!externalInput)
        return;
    auto* external = optionalNapiExternal(*externalInput);

    if (thisObject->plugin.tombstoned)
        return;

    auto& retainedExternals = thisObject->nativePluginExternals;
    bool reserved;
    {
        WTF::Locker locker { thisObject->cellLock() };
        const size_t additional = external ? 2 : 1;
        reserved = retainedExternals.size() <= std::numeric_limits<size_t>::max() - additional
            && retainedExternals.tryReserveCapacity(retainedExternals.size() + additional);
    }
    if (!reserved) {
        throwOutOfMemoryError(&globalObject, scope);
        return;
    }

    BundlerPlugin::FilterRegExp filter(filterPattern, filterFlags);
    if (!thisObject->plugin.onBeforeParse.tryAppend(namespaceStr, {
            WTF::move(filter),
            {
                callback,
                external ? external->value() : nullptr,
                native_plugin_name ? *native_plugin_name : nullptr,
            },
        })) {
        throwOutOfMemoryError(&globalObject, scope);
        return;
    }
    {
        WTF::Locker locker { thisObject->cellLock() };
        retainedExternals.append(JSC::WriteBarrier<NapiExternal>(vm, thisObject, napiExternal));
        if (external)
            retainedExternals.append(JSC::WriteBarrier<NapiExternal>(vm, thisObject, external));
    }
}

void JSBundlerPlugin::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    this->onLoadFunction.initLater(
        [](const JSC::LazyProperty<JSBundlerPlugin, JSC::JSFunction>::Initializer& init) {
            auto& vm = init.vm;
            auto* globalObject = init.owner->globalObject();

            init.set(
                JSC::JSFunction::create(vm, globalObject, WebCore::bundlerPluginRunOnLoadPluginsCodeGenerator(vm), globalObject));
        });

    this->onResolveFunction.initLater(
        [](const JSC::LazyProperty<JSBundlerPlugin, JSC::JSFunction>::Initializer& init) {
            auto& vm = init.vm;
            auto* globalObject = init.owner->globalObject();

            init.set(
                JSC::JSFunction::create(vm, globalObject, WebCore::bundlerPluginRunOnResolvePluginsCodeGenerator(vm), globalObject));
        });

    this->setupFunction.initLater(
        [](const JSC::LazyProperty<JSBundlerPlugin, JSC::JSFunction>::Initializer& init) {
            auto& vm = init.vm;
            auto* globalObject = init.owner->globalObject();

            init.set(
                JSC::JSFunction::create(vm, globalObject, WebCore::bundlerPluginRunSetupFunctionCodeGenerator(vm), globalObject));
        });

    this->putDirect(vm, Identifier::fromString(vm, String("onLoad"_s)), jsUndefined(), 0);
    this->putDirect(vm, Identifier::fromString(vm, String("onResolve"_s)), jsUndefined(), 0);
    bunBindgenObjectSurface_JSBundlerPlugin_install(vm, JSBundlerPlugin::info(), *this);
}

bool Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_anyMatches(
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_anyMatches_Arguments& args)
{
    return args.state->anyMatchesCrossThread(args.state->vm(), args.namespaceString, args.path, args.isOnLoad);
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_matchOnLoad(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_matchOnLoad_Arguments& args)
{
    auto* plugin = bundlerPlugin(args.plugin);
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const WTF::String& namespaceStringStr = args.namespaceString;
    const WTF::String& pathStr = args.path;
    auto& vm = plugin->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSFunction* function = plugin->onLoadFunction.get(plugin);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(function);

    JSC::CallData callData = JSC::getCallData(function);
    RELEASE_ASSERT(callData.type != JSC::CallData::Type::None);

    auto loaderString = Bindgen::enumerationString(args.defaultLoader);
    if (!loaderString) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(context.classValue(args.deferContext));
    arguments.append(JSC::jsString(vm, pathStr));
    arguments.append(JSC::jsString(vm, namespaceStringStr));
    arguments.append(JSC::jsString(vm, WTF::move(*loaderString)));
    arguments.append(JSC::jsBoolean(args.isServerSide));

    if (arguments.hasOverflowed()) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    RETURN_IF_EXCEPTION(scope, {});
    auto result = call(globalObject, function, callData, plugin, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_matchOnResolve(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_matchOnResolve_Arguments& args)
{
    auto* plugin = bundlerPlugin(args.plugin);
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    WTF::String namespaceStringStr = args.namespaceString;
    if (namespaceStringStr.length() == 0) {
        namespaceStringStr = WTF::String("file"_s);
    }
    const WTF::String& pathStr = args.path;
    const WTF::String& importerStr = args.importer;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSFunction* function = plugin->onResolveFunction.get(plugin);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(function);

    JSC::CallData callData = JSC::getCallData(function);
    RELEASE_ASSERT(callData.type != JSC::CallData::Type::None);

    auto kindString = Bindgen::enumerationString(args.kind);
    if (!kindString) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsString(vm, pathStr));
    arguments.append(JSC::jsString(vm, namespaceStringStr));
    arguments.append(JSC::jsString(vm, importerStr));
    arguments.append(JSC::jsString(vm, WTF::move(*kindString)));
    if (arguments.hasOverflowed()) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    RETURN_IF_EXCEPTION(scope, {});
    auto result = call(globalObject, function, callData, plugin, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_create(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_create_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* plugin = JSBundlerPlugin::create(
        globalObject->vm(),
        // TODO: cache this structure on the global object
        JSBundlerPlugin::createStructure(
            globalObject->vm(),
            globalObject,
            globalObject->objectPrototype()),
        args.target);
    return plugin;
}

Bun::BundlerPlugin* Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_pluginState(
    Bindgen::EngineCallContext&,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_pluginState_Arguments& args)
{
    return &bundlerPlugin(args.plugin)->plugin;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_loadAndResolvePluginsForServe(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_loadAndResolvePluginsForServe_Arguments& args)
{
    auto* plugin = bundlerPlugin(args.plugin);
    auto& vm = plugin->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = &context.globalObject;

    auto* loadAndResolvePluginsForServeBuiltinFn = JSC::JSFunction::create(vm, globalObject, WebCore::bundlerPluginLoadAndResolvePluginsForServeCodeGenerator(vm), globalObject);

    auto* runSetupFn = plugin->setupFunction.get(plugin);

    JSC::CallData callData = JSC::getCallData(loadAndResolvePluginsForServeBuiltinFn);
    RELEASE_ASSERT(callData.type != JSC::CallData::Type::None);

    MarkedArgumentBuffer arguments;
    arguments.append(Bun::toJSArray(globalObject, args.plugins));
    RETURN_IF_EXCEPTION(scope, {});
    arguments.append(JSC::jsString(vm, args.bunfigFolder));
    arguments.append(runSetupFn);

    RELEASE_AND_RETURN(scope, JSC::profiledCall(globalObject, ProfilingReason::API, loadAndResolvePluginsForServeBuiltinFn, callData, plugin, arguments));
}

std::optional<JSC::JSValue> Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_runSetupFunction(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_runSetupFunction_Arguments& args)
{
    auto* plugin = bundlerPlugin(args.plugin);
    auto& vm = plugin->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* setupFunction = plugin->setupFunction.get(plugin);
    if (!setupFunction) [[unlikely]]
        return std::nullopt;

    JSC::CallData callData = JSC::getCallData(setupFunction);
    if (callData.type == JSC::CallData::Type::None) [[unlikely]]
        return std::nullopt;

    MarkedArgumentBuffer arguments;
    auto* setupRealm = JSC::getFunctionRealm(&context.globalObject, args.setupFunction.getObject());
    RETURN_IF_EXCEPTION(scope, {});

    arguments.append(args.setupFunction);
    if (args.config)
        args.config->appendTo(arguments);
    else
        arguments.append(JSC::constructEmptyObject(&context.globalObject));
    arguments.append(JSC::jsBoolean(args.isFirst));
    arguments.append(JSC::jsBoolean(args.isLast));
    arguments.append(JSC::jsBoolean(args.isBake));

    auto result = JSC::profiledCall(setupRealm, ProfilingReason::API, setupFunction, callData, plugin, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(result))
        return promise;
    if (dynamicDowncast<JSC::ErrorInstance>(result))
        JSC::throwException(&context.globalObject, scope, result);
    return std::nullopt;
}

void Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_tombstone(
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_tombstone_Arguments& args)
{
    args.state->tombstone();
}

std::optional<Bindgen::CppResultSequence<JSC::JSValue>> Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_onEndCallbacks(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_onEndCallbacks_Arguments& args)
{
    auto* plugin = bundlerPlugin(args.plugin);
    auto& vm = plugin->vm();
    auto value = plugin->getDirect(vm, JSC::Identifier::fromString(vm, "onEndCallbacks"_s));
    if (!value || value.isUndefined())
        return std::nullopt;

    auto* callbacks = dynamicDowncast<JSC::JSArray>(value);
    RELEASE_ASSERT(callbacks);
    Bindgen::CppResultSequence<JSC::JSValue> result;
    for (unsigned index = 0; index < callbacks->length(); ++index) {
        auto callback = callbacks->getDirectIndex(&context.globalObject, index);
        RELEASE_ASSERT(callback && JSC::getCallData(callback).type != JSC::CallData::Type::None);
        if (!result.append(context.results(), callback))
            return std::nullopt;
    }
    return result;
}

Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_callOnBeforeParsePlugins_Return Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_callOnBeforeParsePlugins(
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_callOnBeforeParsePlugins_Arguments& args)
{
    return args.state->onBeforeParse.call(
        args.state->vm(),
        args.bunContext,
        args.namespaceString,
        args.path,
        args.onBeforeParseArguments.value_or(nullptr),
        args.onBeforeParseResult.value_or(nullptr));
}

bool Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_hasOnBeforeParsePlugins(
    const Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_hasOnBeforeParsePlugins_Arguments& args)
{
    return !args.state->onBeforeParse.isEmpty();
}

} // namespace Bun
