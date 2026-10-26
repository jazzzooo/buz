// clang-format off
#include "root.h"
#include "ModuleLoader.h"
#include "PathInlines.h"
#include "SchemaBindings.h"
#include "JSCommonJSModule.h"

#include <JavaScriptCore/JSBoundFunction.h>
#include <JavaScriptCore/PropertySlot.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SourceCode.h>

#include "ZigGlobalObject.h"
#include "InternalModuleRegistry.h"

#pragma push_macro("assert")
#undef assert

#define FOREACH_EXPOSED_BUILTIN_IMR(v)     \
    v(ffi,                    BunFFI) \
    v(assert,                 NodeAssert) \
    v(async_hooks,            NodeAsyncHooks) \
    v(child_process,          NodeChildProcess) \
    v(cluster,                NodeCluster) \
    v(dgram,                  NodeDgram) \
    v(diagnostics_channel,    NodeDiagnosticsChannel) \
    v(dns,                    NodeDNS) \
    v(domain,                 NodeDomain) \
    v(events,                 NodeEvents) \
    v(fs,                     NodeFS) \
    v(http,                   NodeHttp) \
    v(http2,                  NodeHttp2) \
    v(https,                  NodeHttps) \
    v(inspector,              NodeInspector) \
    v(net,                    NodeNet) \
    v(os,                     NodeOS) \
    v(path,                   NodePath) \
    v(perf_hooks,             NodePerfHooks) \
    v(punycode,               NodePunycode) \
    v(querystring,            NodeQuerystring) \
    v(readline,               NodeReadline) \
    v(stream,                 NodeStream) \
    v(sys,                    NodeUtil) \
    v(timers,                 NodeTimers) \
    v(tls,                    NodeTLS) \
    v(trace_events,           NodeTraceEvents) \
    v(tty,                    NodeTty) \
    v(url,                    NodeUrl) \
    v(util,                   NodeUtil) \
    v(v8,                     NodeV8) \
    v(vm,                     NodeVM) \
    v(wasi,                   NodeWasi) \
    v(sqlite,                 BunSqlite) \
    v(worker_threads,         NodeWorkerThreads) \
    v(zlib,                   NodeZlib) \
    v(constants,              NodeConstants) \
    v(string_decoder,         NodeStringDecoder) \
    v(buffer,                 NodeBuffer) \
    v(jsc,                    BunJSC) \

#define DECL_GETTER(id, field)                                                                                  \
    JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_ExposeNodeModuleGlobalsHost_##id(                            \
        Bun::Bindgen::CppCallContext& context,                                                                 \
        const Bun::Bindgen::Cpp::BunBindgenCpp_ExposeNodeModuleGlobalsHost_##id##_Arguments&)                  \
    {                                                                                                          \
        auto* globalObject = defaultGlobalObject(&context.globalObject);                                       \
        return globalObject->internalModuleRegistry()->requireId(globalObject, globalObject->vm(), Bun::Bindgen::InternalModuleId::field); \
    }
FOREACH_EXPOSED_BUILTIN_IMR(DECL_GETTER)
#undef DECL_GETTER

#define BUN_BINDGEN_OBJECT_SURFACE_ExposedNodeModuleGlobals
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ExposedNodeModuleGlobals

void Bun::Bindgen::Engine::bunBindgenEngine_ExposeNodeModuleGlobalsHost_exposeNodeModuleGlobals(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ExposeNodeModuleGlobalsHost_exposeNodeModuleGlobals_Arguments& args)
{
    UNUSED_PARAM(args);
    auto* globalObject = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    auto& vm = JSC::getVM(globalObject);
    bunBindgenObjectSurface_ExposedNodeModuleGlobals_install(vm, globalObject->classInfo(), *globalObject);
}

// Set up require(), module, __filename, __dirname on globalThis for the REPL.
// Creates a CommonJS module object rooted at the given directory so require() resolves correctly.
void Bun::Bindgen::Engine::bunBindgenEngine_ExposeNodeModuleGlobalsHost_setupGlobalRequire(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ExposeNodeModuleGlobalsHost_setupGlobalRequire_Arguments& args)
{
    using namespace JSC;
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto& vm = getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto& cwdStr = args.cwd;
    auto* filename = jsString(vm, makeString(cwdStr, PLATFORM_SEP_s, "[repl]"_s));
    auto* dirname = jsString(vm, WTF::String(cwdStr));

    auto* moduleObject = Bun::JSCommonJSModule::create(vm,
        globalObject->CommonJSModuleObjectStructure(),
        filename, filename, dirname, SourceCode());
    moduleObject->hasEvaluated = true;

    auto* resolveFunction = JSBoundFunction::create(vm, globalObject,
        globalObject->requireResolveFunctionUnbound(), filename,
        ArgList(), 1, globalObject->commonStrings().resolveString(globalObject),
        makeSource("resolve"_s, SourceOrigin(), SourceTaintedOrigin::Untainted));
    RETURN_IF_EXCEPTION(scope, );

    auto* requireFunction = JSBoundFunction::create(vm, globalObject,
        globalObject->requireFunctionUnbound(), moduleObject,
        ArgList(), 1, globalObject->commonStrings().requireString(globalObject),
        makeSource("require"_s, SourceOrigin(), SourceTaintedOrigin::Untainted));
    RETURN_IF_EXCEPTION(scope, );

    requireFunction->putDirect(vm, vm.propertyNames->resolve, resolveFunction, 0);
    moduleObject->putDirect(vm, WebCore::clientData(vm)->builtinNames().requirePublicName(), requireFunction, 0);

    globalObject->putDirect(vm, WebCore::builtinNames(vm).requirePublicName(), requireFunction, 0);
    globalObject->putDirect(vm, Identifier::fromString(vm, "module"_s), moduleObject, 0);
    globalObject->putDirect(vm, Identifier::fromString(vm, "__filename"_s), filename, 0);
    globalObject->putDirect(vm, Identifier::fromString(vm, "__dirname"_s), dirname, 0);
}

#pragma pop_macro("assert")
