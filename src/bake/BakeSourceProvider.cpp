// clang-format off
#include "BakeSourceProvider.h"
#include "DevServerSourceProvider.h"
#include "BakeGlobalObject.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/Identifier.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSLock.h"
#include "JavaScriptCore/JSMap.h"
#include "JavaScriptCore/JSModuleLoader.h"
#include "JavaScriptCore/ModuleRegistryEntry.h"
#include "JavaScriptCore/JSModuleRecord.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/JSModuleNamespaceObject.h"
#include "ImportMetaObject.h"
#include "SchemaBindings.h"

namespace Bake {

static JSC::JSValue loadInitialServerCode(JSC::JSGlobalObject* global, const WTF::String& source, bool separateSSRGraph) {
  auto& vm = JSC::getVM(global);
  auto scope = DECLARE_THROW_SCOPE(vm);

  String string = "bake://server-runtime.js"_s;
  JSC::SourceOrigin origin = JSC::SourceOrigin(WTF::URL(string));
  auto provider = SourceProvider::create(
    global,
    source,
    origin,
    WTF::move(string),
    WTF::TextPosition(),
    JSC::SourceProviderSourceType::Program
  );
  RETURN_IF_EXCEPTION(scope, {});
  JSC::SourceCode sourceCode(provider.releaseNonNull());

  JSC::JSValue fnValue = vm.interpreter.executeProgram(sourceCode, global, global);
  RETURN_IF_EXCEPTION(scope, {});

  RELEASE_ASSERT(fnValue);

  JSC::JSFunction* fn = uncheckedDowncast<JSC::JSFunction>(fnValue);
  JSC::CallData callData = JSC::getCallData(fn);

  auto* importMeta = Zig::ImportMetaObject::create(global, "bake://server-runtime.js"_s);
  RETURN_IF_EXCEPTION(scope, {});

  JSC::MarkedArgumentBuffer args;
  args.append(JSC::jsBoolean(separateSSRGraph));
  args.append(importMeta);
  if (args.hasOverflowed()) {
    JSC::throwOutOfMemoryError(global, scope);
    return {};
  }

  RELEASE_AND_RETURN(scope, JSC::profiledCall(global, JSC::ProfilingReason::API, fn, callData, JSC::jsUndefined(), args));
}

static JSC::JSValue loadServerHmrPatch(JSC::JSGlobalObject* global, const WTF::String& source) {
  JSC::VM&vm = global->vm();
  auto scope = DECLARE_THROW_SCOPE(vm);

  String string = "bake://server.patch.js"_s;
  JSC::SourceOrigin origin = JSC::SourceOrigin(WTF::URL(string));
  auto provider = SourceProvider::create(
    global,
    source,
    origin,
    WTF::move(string),
    WTF::TextPosition(),
    JSC::SourceProviderSourceType::Program
  );
  RETURN_IF_EXCEPTION(scope, {});
  JSC::SourceCode sourceCode(provider.releaseNonNull());

  JSC::JSValue result = vm.interpreter.executeProgram(sourceCode, global, global);
  RETURN_IF_EXCEPTION(scope, {});

  RELEASE_ASSERT(result);
  return result;
}

static JSC::JSValue loadServerHmrPatchWithSourceMap(JSC::JSGlobalObject* global, const WTF::String& source, std::span<const uint8_t> sourceMapJSON) {
  JSC::VM&vm = global->vm();
  auto scope = DECLARE_THROW_SCOPE(vm);

  String string = "bake://server.patch.js"_s;
  JSC::SourceOrigin origin = JSC::SourceOrigin(WTF::URL(string));
  
  // Use DevServerSourceProvider with the source map JSON
  auto provider = DevServerSourceProvider::create(
    global,
    source,
    sourceMapJSON,
    origin,
    WTF::move(string),
    WTF::TextPosition(),
    JSC::SourceProviderSourceType::Program
  );
  
  RETURN_IF_EXCEPTION(scope, {});
  JSC::SourceCode sourceCode(provider.releaseNonNull());

  JSC::JSValue result = vm.interpreter.executeProgram(sourceCode, global, global);
  RETURN_IF_EXCEPTION(scope, {});

  RELEASE_ASSERT(result);
  return result;
}

static JSC::JSModuleNamespaceObject* getModuleNamespace(JSC::JSGlobalObject* global, const WTF::String& moduleName) {
  auto& vm = JSC::getVM(global);
  auto scope = DECLARE_THROW_SCOPE(vm);
  auto keyIdent = JSC::Identifier::fromString(vm, moduleName);
  auto* entry = global->moduleLoader()->registryEntry(keyIdent);
  ASSERT(entry);
  auto* module = entry ? entry->record() : nullptr;
  ASSERT(module);
  JSC::JSModuleNamespaceObject* namespaceObject = global->moduleLoader()->getModuleNamespaceObject(global, module);
  RETURN_IF_EXCEPTION(scope, nullptr);
  ASSERT(namespaceObject);
  return namespaceObject;
}

static JSC::JSValue getDefaultExportFromModule(JSC::JSGlobalObject* global, const WTF::String& moduleName) {
  auto& vm = JSC::getVM(global);
  auto scope = DECLARE_THROW_SCOPE(vm);
  auto* moduleNamespace = getModuleNamespace(global, moduleName);
  RETURN_IF_EXCEPTION(scope, {});
  RELEASE_AND_RETURN(scope, moduleNamespace->get(global, vm.propertyNames->defaultKeyword));
}

static std::optional<JSC::JSValue> getCallableExport(
  JSC::JSGlobalObject* global,
  const WTF::String& moduleName,
  Bun::Bindgen::BakeProductionCallableExport kind
) {
  auto& vm = JSC::getVM(global);
  auto scope = DECLARE_THROW_SCOPE(vm);
  auto* moduleNamespace = getModuleNamespace(global, moduleName);
  RETURN_IF_EXCEPTION(scope, std::nullopt);
  JSC::JSValue value;
  switch (kind) {
  case Bun::Bindgen::BakeProductionCallableExport::prerender:
    value = moduleNamespace->get(global, JSC::Identifier::fromString(vm, "prerender"_s));
    break;
  case Bun::Bindgen::BakeProductionCallableExport::get_params:
    value = moduleNamespace->get(global, JSC::Identifier::fromString(vm, "getParams"_s));
    break;
  }
  RETURN_IF_EXCEPTION(scope, std::nullopt);
  if (!value.isCallable())
    return std::nullopt;
  return value;
}

} // namespace Bake

Bun::Bindgen::Engine::BunBindgenEngine_DevServer_bakeLoadInitialServerCode_Return Bun::Bindgen::Engine::bunBindgenEngine_DevServer_bakeLoadInitialServerCode(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_DevServer_bakeLoadInitialServerCode_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto interfaceValue = Bake::loadInitialServerCode(globalObject, args.source, args.separateSSRGraph);
    RETURN_IF_EXCEPTION(scope, {});
    auto* interfaceObject = interfaceValue.getObject();
    RELEASE_ASSERT(interfaceObject);

    auto handleRequest = interfaceObject->get(globalObject, JSC::Identifier::fromString(vm, "handleRequest"_s));
    RETURN_IF_EXCEPTION(scope, {});
    auto registerUpdate = interfaceObject->get(globalObject, JSC::Identifier::fromString(vm, "registerUpdate"_s));
    RETURN_IF_EXCEPTION(scope, {});
    return { .handleRequest = handleRequest, .registerUpdate = registerUpdate };
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_DevServer_bakeLoadServerHmrPatch(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_DevServer_bakeLoadServerHmrPatch_Arguments& args)
{
    return Bake::loadServerHmrPatch(&context.globalObject, args.source);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_DevServer_bakeLoadServerHmrPatchWithSourceMap(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_DevServer_bakeLoadServerHmrPatchWithSourceMap_Arguments& args)
{
    return Bake::loadServerHmrPatchWithSourceMap(&context.globalObject, args.source, args.sourceMapJSON);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_BakeProduction_bakeGetDefaultExportFromModule(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_bakeGetDefaultExportFromModule_Arguments& args)
{
    return Bake::getDefaultExportFromModule(&context.globalObject, args.moduleName);
}

Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_getCallableExport_Return Bun::Bindgen::Engine::bunBindgenEngine_BakeProduction_getCallableExport(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_getCallableExport_Arguments& args)
{
    return Bake::getCallableExport(&context.globalObject, args.moduleName, args.kind);
}
