#include "BunPlugin.h"

#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/JSCast.h"
#include "helpers.h"
#include "ZigGlobalObject.h"

#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>
#include <JavaScriptCore/JSModuleLoader.h>
#include <JavaScriptCore/ModuleRegistryEntry.h>
#include <JavaScriptCore/CyclicModuleRecord.h>
#include <JavaScriptCore/JSModuleNamespaceObject.h>
#include <JavaScriptCore/JSModuleRecord.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSTypeInfo.h>
#include <JavaScriptCore/JavaScript.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/RegularExpression.h>
#include <JavaScriptCore/SourceOrigin.h>
#include <JavaScriptCore/Structure.h>
#include <wtf/text/WTFString.h>

#include "BunClientData.h"
#include "JSCommonJSModule.h"
#include "isBuiltinModule.h"
#include "AsyncContextFrame.h"
#include "ImportMetaObject.h"
#include "SchemaBindings.h"

namespace Zig {

#define BUN_BINDGEN_OBJECT_SURFACE_BunPluginBuilder
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_BunPluginBuilder

static bool isValidNamespaceString(const String& namespaceString)
{
    static JSC::Yarr::RegularExpression* namespaceRegex = nullptr;
    if (!namespaceRegex) {
        namespaceRegex = new JSC::Yarr::RegularExpression("^([/@a-zA-Z0-9_\\-]+)$"_s);
    }
    return namespaceRegex->match(namespaceString) > -1;
}

static void appendPlugin(
    JSC::JSGlobalObject* globalObject,
    const Bun::Bindgen::PluginRegistrationInput& registration,
    JSC::JSObject* callback,
    BunPlugin::Base& plugin)
{
    auto& vm = JSC::getVM(globalObject);
    String namespaceString = registration.namespaceString;
    plugin.append(vm, uncheckedDowncast<JSC::RegExpObject>(registration.filter)->regExp(), callback, namespaceString);
    Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_onDidAppendPlugin(globalObject);
}

static void appendVirtualModule(
    JSC::JSGlobalObject* globalObject,
    const String& moduleId,
    JSC::JSObject* callback)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (moduleId.isEmpty()) {
        throwException(globalObject, scope, createError(globalObject, "virtual module cannot be blank"_s));
        return;
    }

    if (Bun::isBuiltinModule(moduleId)) {
        throwException(globalObject, scope, createError(globalObject, makeString("module() cannot be used to override builtin module \""_s, moduleId, "\""_s)));
        return;
    }

    if (moduleId.startsWith("."_s)) {
        throwException(globalObject, scope, createError(globalObject, "virtual module cannot start with \".\""_s));
        return;
    }

    Zig::GlobalObject* global = defaultGlobalObject(globalObject);

    if (global->onLoadPlugins.virtualModules == nullptr) {
        global->onLoadPlugins.virtualModules = new BunPlugin::VirtualModuleMap;
    }
    auto* virtualModules = global->onLoadPlugins.virtualModules;

    virtualModules->set(moduleId, BunPlugin::VirtualModule { JSC::Strong<JSC::JSObject> { vm, callback }, false });

    auto* requireMap = global->requireMap();
    RETURN_IF_EXCEPTION(scope, void());
    JSValue moduleIdValue = jsString(vm, moduleId);
    requireMap->remove(globalObject, moduleIdValue);
    RETURN_IF_EXCEPTION(scope, void());

    auto idIdent = JSC::Identifier::fromString(vm, moduleId);
    RETURN_IF_EXCEPTION(scope, void());
    global->moduleLoader()->removeEntry(idIdent);
}

static std::optional<JSC::JSValue> setupBunPlugin(
    JSC::JSGlobalObject* globalObject,
    JSC::JSObject* function)
{
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    JSObject* builderObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 4);
    bunBindgenObjectSurface_BunPluginBuilder_install(vm, builderObject->classInfo(), *builderObject);

    JSC::MarkedArgumentBuffer args;
    args.append(builderObject);

    JSC::CallData callData = JSC::getCallData(function);
    JSValue result = call(globalObject, function, callData, JSC::jsUndefined(), args);

    RETURN_IF_EXCEPTION(throwScope, std::nullopt);

    if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
        return JSC::JSValue(promise);
    }

    return std::nullopt;
}

void BunPlugin::Group::append(JSC::VM& vm, JSC::RegExp* filter, JSC::JSObject* func)
{
    filters.append(JSC::Strong<JSC::RegExp> { vm, filter });
    callbacks.append(JSC::Strong<JSC::JSObject> { vm, func });
}

void BunPlugin::Base::append(JSC::VM& vm, JSC::RegExp* filter, JSC::JSObject* func, String& namespaceString)
{
    if (namespaceString.isEmpty() || namespaceString == "file"_s) {
        this->fileNamespace.append(vm, filter, func);
    } else if (auto found = this->group(namespaceString)) {
        found->append(vm, filter, func);
    } else {
        Group newGroup;
        newGroup.append(vm, filter, func);
        this->groups.append(WTF::move(newGroup));
        this->namespaces.append(namespaceString);
    }
}

JSC::JSObject* BunPlugin::Group::find(JSC::JSGlobalObject* globalObject, const String& path)
{
    size_t count = filters.size();
    for (size_t i = 0; i < count; i++) {
        if (filters[i].get()->match(globalObject, path, 0)) {
            return callbacks[i].get();
        }
    }

    return nullptr;
}

void BunPlugin::OnLoad::addModuleMock(JSC::VM& vm, const String& path, JSC::JSObject* mockObject)
{
    if (!virtualModules)
        virtualModules = new BunPlugin::VirtualModuleMap;
    virtualModules->set(path, BunPlugin::VirtualModule { JSC::Strong<JSC::JSObject> { vm, mockObject }, true });
}

static void registerModuleMock(
    JSC::JSGlobalObject* lexicalGlobalObject,
    WTF::String specifier,
    JSC::JSObject* callback,
    const JSC::SourceOrigin& sourceOrigin)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    Zig::GlobalObject* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!globalObject) [[unlikely]] {
        scope.throwException(lexicalGlobalObject, JSC::createTypeError(lexicalGlobalObject, "Cannot run mock from a different global context"_s));
        return;
    }

    JSC::JSString* specifierString = jsString(vm, specifier);
    bool requiresRelativeLookup = false;

    auto resolveSpecifier = [&]() -> void {
        if (sourceOrigin.isNull())
            return;
        const URL& url = sourceOrigin.url();

        if (specifier.startsWith("file:"_s)) {
            URL fileURL = URL(url, specifier);
            if (fileURL.isValid()) {
                specifier = fileURL.fileSystemPath();
                specifierString = jsString(vm, specifier);
                requiresRelativeLookup = true;
                return;
            } else {
                scope.throwException(lexicalGlobalObject, JSC::createTypeError(lexicalGlobalObject, "Invalid \"file:\" URL"_s));
                return;
            }
        }

        if (url.isValid() && url.protocolIsFile()) {
            auto fromString = url.fileSystemPath();
            auto topExceptionScope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
            auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_resolveSyncWithSource(globalObject, specifierString, fromString, true, false);
            if (topExceptionScope.exception()) {
                if (!topExceptionScope.tryClearException())
                    return;
            }

            if (!result.isEmpty()) {
                specifierString = jsString(vm, result);
                specifier = result;
            } else if (specifier.startsWith("./"_s) || specifier.startsWith(".."_s)) {
                // If module resolution fails, we try to resolve it relative to the current file
                auto relativeURL = URL(url, specifier);

                if (relativeURL.isValid()) {
                    requiresRelativeLookup = true;

                    if (relativeURL.protocolIsFile())
                        specifier = relativeURL.fileSystemPath();
                    else
                        specifier = relativeURL.string();

                    specifierString = jsString(vm, specifier);
                }
            }
        }
    };

    resolveSpecifier();
    RETURN_IF_EXCEPTION(scope, void());

    auto factory = bun_bindgen_source_function_RuntimeFunctions_createModuleMock_value(globalObject);
    RETURN_IF_EXCEPTION(scope, void());
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(callback);
    arguments.append(specifierString);
    if (arguments.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }
    auto mockValue = JSC::profiledCall(globalObject, ProfilingReason::Other, factory, getCallData(factory), jsUndefined(), arguments);
    RETURN_IF_EXCEPTION(scope, void());
    auto* mock = asObject(mockValue);

    auto specifierIdent = JSC::Identifier::fromString(vm, specifier);
    bool needsEvaluation = false;
    if (auto* entry = globalObject->moduleLoader()->registryEntry(specifierIdent)) {
        bool linked = false;
        if (auto* mod = entry->record()) {
            linked = true;
            if (auto* cyclic = dynamicDowncast<JSC::CyclicModuleRecord>(mod))
                linked = cyclic->status() >= JSC::CyclicModuleRecord::Status::Linked;
        }
        if (linked)
            needsEvaluation = true;
        else
            globalObject->moduleLoader()->removeEntry(specifierIdent);
    }

    auto* requireMap = globalObject->requireMap();
    RETURN_IF_EXCEPTION(scope, void());
    JSValue entryValue = requireMap->get(globalObject, specifierString);
    RETURN_IF_EXCEPTION(scope, void());
    if (dynamicDowncast<Bun::JSCommonJSModule>(entryValue))
        needsEvaluation = true;
    else {
        requireMap->remove(globalObject, specifierString);
        RETURN_IF_EXCEPTION(scope, void());
    }

    globalObject->onLoadPlugins.addModuleMock(vm, specifier, mock);
    globalObject->onLoadPlugins.mustDoExpensiveRelativeLookup |= requiresRelativeLookup;
    if (needsEvaluation) {
        JSC::profiledCall(globalObject, ProfilingReason::API, mock, getCallData(mock), jsUndefined(), ArgList());
        RETURN_IF_EXCEPTION(scope, void());
    }
}

EncodedJSValue BunPlugin::OnLoad::run(JSC::JSGlobalObject* globalObject, const String& namespaceString, const String& path)
{
    Group* groupPtr = this->group(namespaceString);
    if (groupPtr == nullptr) {
        return JSValue::encode(jsUndefined());
    }
    auto* function = groupPtr->find(globalObject, path);
    if (!function) {
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC::MarkedArgumentBuffer arguments;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    scope.assertNoExceptionExceptTermination();

    JSC::JSObject* paramsObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 1);
    const auto& builtinNames = WebCore::builtinNames(vm);
    paramsObject->putDirect(
        vm, builtinNames.pathPublicName(),
        jsString(vm, path));
    arguments.append(paramsObject);

    auto result = AsyncContextFrame::call(globalObject, function, JSC::jsUndefined(), arguments);
    RETURN_IF_EXCEPTION(scope, {});

    if (auto* promise = dynamicDowncast<JSPromise>(result)) {
        switch (promise->status()) {
        case JSPromise::Status::Rejected:
        case JSPromise::Status::Pending: {
            return JSValue::encode(promise);
        }
        case JSPromise::Status::Fulfilled: {
            result = promise->result();
            break;
        }
        }
    }

    if (!result.isObject()) {
        JSC::throwTypeError(globalObject, scope, "onLoad() expects an object returned"_s);
        return {};
    }

    RELEASE_AND_RETURN(scope, JSValue::encode(result));
}

std::optional<String> BunPlugin::OnLoad::resolveVirtualModule(const String& path, const String& from)
{
    ASSERT(virtualModules);

    if (this->mustDoExpensiveRelativeLookup) {
        String joinedPath = path;

        if (path.startsWith("./"_s) || path.startsWith(".."_s)) {
            auto url = WTF::URL::fileURLWithFileSystemPath(from);
            ASSERT(url.isValid());
            joinedPath = URL(url, path).fileSystemPath();
        }

        return virtualModules->contains(joinedPath) ? std::optional<String> { joinedPath } : std::nullopt;
    }

    return virtualModules->contains(path) ? std::optional<String> { path } : std::nullopt;
}

EncodedJSValue BunPlugin::OnResolve::run(JSC::JSGlobalObject* globalObject, const String& namespaceString, const String& path, const String& importer)
{
    Group* groupPtr = this->group(namespaceString);
    if (groupPtr == nullptr) {
        return JSValue::encode(jsUndefined());
    }
    // Callbacks can clear or extend the registry during resolution.
    Group group = *groupPtr;
    auto& filters = group.filters;

    if (filters.size() == 0) {
        return JSValue::encode(jsUndefined());
    }

    auto& callbacks = group.callbacks;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    for (size_t i = 0; i < filters.size(); i++) {
        if (!filters[i].get()->match(globalObject, path, 0)) {
            continue;
        }
        auto* function = callbacks[i].get();
        if (!function) [[unlikely]] {
            continue;
        }

        JSC::MarkedArgumentBuffer arguments;

        JSC::JSObject* paramsObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 2);
        const auto& builtinNames = WebCore::builtinNames(vm);
        paramsObject->putDirect(
            vm, builtinNames.pathPublicName(),
            jsString(vm, path));
        paramsObject->putDirect(
            vm, builtinNames.importerPublicName(),
            jsString(vm, importer));
        arguments.append(paramsObject);

        auto result = AsyncContextFrame::call(globalObject, function, JSC::jsUndefined(), arguments);
        RETURN_IF_EXCEPTION(scope, {});

        if (result.isUndefinedOrNull()) {
            continue;
        }

        if (auto* promise = dynamicDowncast<JSPromise>(result)) {
            switch (promise->status()) {
            case JSPromise::Status::Pending: {
                JSC::throwTypeError(globalObject, scope, "onResolve() doesn't support pending promises yet"_s);
                return {};
            }
            case JSPromise::Status::Rejected: {
                promise->markAsHandled();
                scope.throwException(globalObject, promise->result());
                return {};
            }
            case JSPromise::Status::Fulfilled: {
                result = promise->result();
                break;
            }
            }
        }

        // Check again after promise resolution
        if (result.isUndefinedOrNull()) {
            continue;
        }

        if (!result.isObject()) {
            JSC::throwTypeError(globalObject, scope, "onResolve() expects an object returned"_s);
            return {};
        }

        RELEASE_AND_RETURN(scope, JSValue::encode(result));
    }

    return JSValue::encode(JSC::jsUndefined());
}

} // namespace Zig

WTF::String Bun::Bindgen::Custom::bunBindgenPluginNamespace(
    JSC::JSGlobalObject& globalObject,
    const WTF::String& value,
    WTF::ASCIILiteral)
{
    if (!Zig::isValidNamespaceString(value)) {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        throwException(&globalObject, scope, createError(&globalObject, "namespace can only contain letters, numbers, dashes, or underscores"_s));
        return {};
    }
    return value;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnLoadPluginNode(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnLoadPluginNode_Arguments& args)
{
    Zig::appendPlugin(&context.globalObject, args.options, JSC::asObject(args.callback), defaultGlobalObject(&context.globalObject)->onLoadPlugins);
    return args.bindingThis;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnLoadPluginBun(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnLoadPluginBun_Arguments& args)
{
    Zig::appendPlugin(&context.globalObject, args.options, JSC::asObject(args.callback), defaultGlobalObject(&context.globalObject)->onLoadPlugins);
    return args.bindingThis;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnLoadPluginBrowser(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnLoadPluginBrowser_Arguments& args)
{
    Zig::appendPlugin(&context.globalObject, args.options, JSC::asObject(args.callback), defaultGlobalObject(&context.globalObject)->onLoadPlugins);
    return args.bindingThis;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnResolvePluginNode(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnResolvePluginNode_Arguments& args)
{
    Zig::appendPlugin(&context.globalObject, args.options, JSC::asObject(args.callback), defaultGlobalObject(&context.globalObject)->onResolvePlugins);
    return args.bindingThis;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnResolvePluginBun(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnResolvePluginBun_Arguments& args)
{
    Zig::appendPlugin(&context.globalObject, args.options, JSC::asObject(args.callback), defaultGlobalObject(&context.globalObject)->onResolvePlugins);
    return args.bindingThis;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendVirtualModule(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendVirtualModule_Arguments& args)
{
    if (!args.moduleId.is_module_id()) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwException(&context.globalObject, scope, createError(&context.globalObject, "module() expects first argument to be a string for the module ID"_s));
        return args.bindingThis;
    }
    Zig::appendVirtualModule(&context.globalObject, args.moduleId.module_id(), JSC::asObject(args.callback));
    return args.bindingThis;
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnResolvePluginBrowser(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionAppendOnResolvePluginBrowser_Arguments& args)
{
    Zig::appendPlugin(&context.globalObject, args.options, JSC::asObject(args.callback), defaultGlobalObject(&context.globalObject)->onResolvePlugins);
    return args.bindingThis;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_JSMock__jsModuleMock(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_JSMock__jsModuleMock_Arguments& args)
{
    RELEASE_ASSERT(context.callerSourceOrigin);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (args.specifier.is_undefined_value()) {
        scope.throwException(&context.globalObject, JSC::createTypeError(&context.globalObject, "mock(module, fn) requires a module and function"_s));
        return;
    }
    if (!args.specifier.is_specifier()) {
        scope.throwException(&context.globalObject, JSC::createTypeError(&context.globalObject, "mock(module, fn) requires a module name string"_s));
        return;
    }
    const auto& specifier = args.specifier.specifier();
    if (specifier.isEmpty()) {
        scope.throwException(&context.globalObject, JSC::createTypeError(&context.globalObject, "mock(module, fn) requires a module and function"_s));
        return;
    }
    scope.release();
    Zig::registerModuleMock(
        &context.globalObject,
        specifier,
        JSC::asObject(args.callback),
        *context.callerSourceOrigin);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_applyModuleMock(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_applyModuleMock_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto isCurrent = [&] {
        auto* modules = globalObject->onLoadPlugins.virtualModules;
        if (!modules)
            return false;
        auto entry = modules->find(args.specifier);
        return entry != modules->end() && entry->value.isMock && entry->value.callback.get() == JSC::asObject(args.callback);
    };
    if (!isCurrent())
        return;

    auto identifier = JSC::Identifier::fromString(vm, args.specifier);
    auto linkedRecord = [&]() -> JSC::AbstractModuleRecord* {
        auto* entry = globalObject->moduleLoader()->registryEntry(identifier);
        if (!entry)
            return nullptr;
        auto* record = entry->record();
        if (auto* cyclic = dynamicDowncast<JSC::CyclicModuleRecord>(record)) {
            if (cyclic->status() < JSC::CyclicModuleRecord::Status::Linked)
                return nullptr;
        }
        return record;
    };
    JSC::Strong<JSC::AbstractModuleRecord> record(vm, linkedRecord());
    auto* exports = JSC::asObject(args.exports);
    JSC::PropertyNameArrayBuilder names(vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
    JSC::MarkedArgumentBuffer values;
    if (record) {
        JSC::JSObject::getOwnPropertyNames(exports, globalObject, names, JSC::DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(scope, void());
        if (!isCurrent())
            return;
        for (auto& name : names) {
            auto value = exports->get(globalObject, name);
            RETURN_IF_EXCEPTION(scope, void());
            if (!isCurrent())
                return;
            values.append(value);
            if (values.hasOverflowed()) {
                throwOutOfMemoryError(globalObject, scope);
                return;
            }
        }
        if (linkedRecord() == record.get()) {
            auto* moduleNamespace = record->getModuleNamespace(globalObject);
            RETURN_IF_EXCEPTION(scope, void());
            size_t index = 0;
            for (auto& name : names) {
                moduleNamespace->overrideExportValue(globalObject, name, values.at(index++));
                RETURN_IF_EXCEPTION(scope, void());
            }
        }
    }

    auto* requireMap = globalObject->requireMap();
    RETURN_IF_EXCEPTION(scope, void());
    auto moduleValue = requireMap->get(globalObject, JSC::jsString(vm, args.specifier));
    RETURN_IF_EXCEPTION(scope, void());
    if (auto* module = dynamicDowncast<Bun::JSCommonJSModule>(moduleValue)) {
        module->putDirect(vm, Bun::builtinNames(vm).exportsPublicName(), exports, 0);
        module->hasEvaluated = true;
    }
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_ModuleLoader_runOnResolvePlugins(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ModuleLoader_runOnResolvePlugins_Arguments& args)
{
    UNUSED_PARAM(args.target);
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return JSC::JSValue::decode(globalObject->onResolvePlugins.run(globalObject, args.namespaceName, args.path, args.source));
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_ModuleLoader_runOnLoadPlugins(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ModuleLoader_runOnLoadPlugins_Arguments& args)
{
    UNUSED_PARAM(args.target);
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto result = JSC::JSValue::decode(globalObject->onLoadPlugins.run(globalObject, args.namespaceName, args.path));
    if (result.isUndefinedOrNull())
        return std::nullopt;
    return result;
}

namespace Bun {

std::optional<JSC::JSValue> runVirtualModule(Zig::GlobalObject* globalObject, const WTF::String& specifier, bool& wasModuleMock)
{
    auto fallback = [&]() -> std::optional<JSC::JSValue> {
        return Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_runVirtualModule(globalObject, specifier);
    };

    if (!globalObject->onLoadPlugins.hasVirtualModules()) {
        return fallback();
    }
    auto& virtualModules = *globalObject->onLoadPlugins.virtualModules;

    if (auto entry = virtualModules.find(specifier); entry != virtualModules.end()) {
        auto& vm = JSC::getVM(globalObject);
        JSC::Strong<JSC::JSObject> function = entry->value.callback;
        wasModuleMock = entry->value.isMock;
        auto throwScope = DECLARE_THROW_SCOPE(vm);

        JSC::MarkedArgumentBuffer arguments;
        JSC::CallData callData = JSC::getCallData(function.get());
        RELEASE_ASSERT(callData.type != JSC::CallData::Type::None);
        JSValue result = call(globalObject, function.get(), callData, JSC::jsUndefined(), arguments);

        RETURN_IF_EXCEPTION(throwScope, std::nullopt);

        if (auto* promise = dynamicDowncast<JSPromise>(result)) {
            switch (promise->status()) {
            case JSPromise::Status::Rejected:
            case JSPromise::Status::Pending: {
                return promise;
            }
            case JSPromise::Status::Fulfilled: {
                result = promise->result();
                break;
            }
            }
        }

        if (!result.isObject()) {
            JSC::throwTypeError(globalObject, throwScope, "virtual module expects an object returned"_s);
            return {};
        }

        return result;
    }

    return fallback();
}

} // namespace Bun

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionBunPlugin(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionBunPlugin_Arguments& args)
{
    if (!args.setup) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        JSC::throwTypeError(&context.globalObject, scope, "plugin needs at least one argument (an object)"_s);
        return std::nullopt;
    }
    return Zig::setupBunPlugin(&context.globalObject, JSC::asObject(args.setup->setup));
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionBunPluginClear(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionBunPluginClear_Arguments&)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    global->onLoadPlugins.clear();
    global->onResolvePlugins.clear();
}
