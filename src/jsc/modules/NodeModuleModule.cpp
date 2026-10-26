#include "root.h"
#include "NodeModuleModule.h"
#include "WebCoreJSBuiltins.h"

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <JavaScriptCore/CallData.h>
#include <JavaScriptCore/JSPromise.h>
#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/JSNativeStdFunction.h"
#include "JSCommonJSExtensions.h"

#include "PathInlines.h"
#include "Bindgen/FileURL.h"
#include "ZigGlobalObject.h"
#include "ErrorCode.h"

#include "SchemaBindings.h"
#include <wtf/URL.h>

namespace Bun {

using namespace JSC;

// This is a list of builtin module names that do not have the node prefix. It
// also includes Bun's builtin modules, as well as Bun's thirdparty overrides.
// The reason for overstuffing this list is so that uses that use these as the
// 'external' option to a bundler will properly exclude things like 'ws' which
// only work with Bun's native 'ws' implementation and not the JS one on NPM.
static constexpr ASCIILiteral builtinModuleNames[] = {
    "_http_agent"_s,
    "_http_client"_s,
    "_http_common"_s,
    "_http_incoming"_s,
    "_http_outgoing"_s,
    "_http_server"_s,
    "_stream_duplex"_s,
    "_stream_passthrough"_s,
    "_stream_readable"_s,
    "_stream_transform"_s,
    "_stream_wrap"_s,
    "_stream_writable"_s,
    "_tls_common"_s,
    "_tls_wrap"_s,
    "assert"_s,
    "assert/strict"_s,
    "async_hooks"_s,
    "buffer"_s,
    "bun:ffi"_s,
    "bun:jsc"_s,
    "bun:sqlite"_s,
    "bun:test"_s,
    "bun:wrap"_s,
    "bun"_s,
    "child_process"_s,
    "cluster"_s,
    "console"_s,
    "constants"_s,
    "crypto"_s,
    "dgram"_s,
    "diagnostics_channel"_s,
    "dns"_s,
    "dns/promises"_s,
    "domain"_s,
    "events"_s,
    "fs"_s,
    "fs/promises"_s,
    "http"_s,
    "http2"_s,
    "https"_s,
    "inspector"_s,
    "inspector/promises"_s,
    "module"_s,
    "net"_s,
    "os"_s,
    "path"_s,
    "path/posix"_s,
    "path/win32"_s,
    "perf_hooks"_s,
    "process"_s,
    "punycode"_s,
    "querystring"_s,
    "readline"_s,
    "readline/promises"_s,
    "repl"_s,
    "stream"_s,
    "stream/consumers"_s,
    "stream/promises"_s,
    "stream/web"_s,
    "string_decoder"_s,
    "sys"_s,
    "timers"_s,
    "timers/promises"_s,
    "tls"_s,
    "trace_events"_s,
    "tty"_s,
    "undici"_s,
    "url"_s,
    "util"_s,
    "util/types"_s,
    "v8"_s,
    "vm"_s,
    "wasi"_s,
    "worker_threads"_s,
    "ws"_s,
    "zlib"_s,
};

template<std::size_t N, class T> consteval std::size_t countof(T (&)[N])
{
    return N;
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_moduleCall(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_moduleCall_Arguments&)
{
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_moduleConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_moduleConstruct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    JSString* idString = jsString(vm, WTF::String("."_s));
    JSString* dirname = jsEmptyString(vm);

    if (args.id && args.id->is_string()) {
        const auto& id = args.id->string();
        idString = jsString(vm, id);
        auto index = id.reverseFind('/');
        if (index != WTF::notFound)
            dirname = jsString(vm, id.left(index));
    }

    auto* structure = static_cast<Zig::GlobalObject*>(globalObject)->CommonJSModuleObjectStructure();
    auto* module = JSCommonJSModule::create(vm, structure, idString, jsNull(), dirname, SourceCode());

    if (args.parent)
        args.parent->defineOwnDataProperty(vm, *module, Identifier::fromString(vm, "parent"_s), 0);

    module->putDirect(vm, Identifier::fromString(vm, "exports"_s),
        constructEmptyObject(globalObject, globalObject->objectPrototype(), 0), 0);
    return module;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_isBuiltin(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_isBuiltin_Arguments& args)
{
    return args.moduleName && args.moduleName->is_string() && Bun::isBuiltinModule(args.moduleName->string());
}

WTF::String Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_wrap(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_wrap_Arguments& args)
{
    return makeString("(function (exports, require, module, __filename, __dirname) { "_s, args.code, "\n});"_s);
}

std::optional<WTF::String> Bindgen::Engine::bunBindgenEngine_NodeModuleModule_commonJSModuleSourceFilename(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeModuleModule_commonJSModuleSourceFilename_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* module = dynamicDowncast<Bun::JSCommonJSModule>(args.module);
    RELEASE_ASSERT(module);
    auto filename = module->filename();
    if (!filename)
        return std::nullopt;
    auto source = filename.toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return source;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_createRequire(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_createRequire_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto filename = args.filename;
    if (!isAbsolutePath(filename)) {
        WTF::URL url { filename };
        if (!url.isValid() || !url.protocolIsFile()) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "filename"_s, args.original_filename,
                "must be a file URL object, file URL string, or absolute path string"_s);
            return {};
        }
        filename = Bun::Bindgen::fileURLToPath(*globalObject, url);
        RETURN_IF_EXCEPTION(scope, {});
    }
    bool trailingSlash = filename.endsWith('/');
#if OS(WINDOWS)
    trailingSlash |= filename.endsWith('\\');
#endif
    if (trailingSlash) {
        filename = ZigExports::bunBindgenZig_Path_nodePathJoinCurrentPlatform(
            globalObject, filename, "noop.js"_s);
        RETURN_IF_EXCEPTION(scope, {});
    }
    RELEASE_AND_RETURN(scope, JSCommonJSModule::createBoundRequireFunction(globalObject->vm(), globalObject, filename));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getResolveFilename(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getResolveFilename_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    return globalObject->m_moduleResolveFilenameFunction.getInitializedOnMainThread(globalObject);
}

bool Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_setResolveFilename(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_setResolveFilename_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    if (args.value) {
        auto value = *args.value;
        bool isOriginal = false;
        if (value.isCallable()) {
            JSC::CallData callData = JSC::getCallData(value);

            if (callData.type == JSC::CallData::Type::Native) {
                if (callData.native.function.untaggedPtr() == &bun_bindgen_host_NodeModuleModule_resolveFilename) {
                    isOriginal = true;
                }
            }
        }
        globalObject->hasOverriddenModuleResolveFilenameFunction = !isOriginal;
        globalObject->m_moduleResolveFilenameFunction.set(
            lexicalGlobalObject->vm(), globalObject, value.asCell());
    }

    return true;
}

std::optional<Bindgen::CppResultSequence<Bindgen::NodeModuleLookupPathResultResult>> Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_resolveLookupPaths(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_resolveLookupPaths_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    const Bindgen::NodeModuleLookupParent* parent = nullptr;
    if (args.parent && args.parent->is_parent())
        parent = &args.parent->parent();

    auto utf8 = args.request.utf8();
    if (Bindgen::ZigExports::bunBindgenZig_ModuleLoader_moduleLoaderIsBuiltin(
            std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(utf8.data()), utf8.length()))) {
        return std::nullopt;
    }

    if (usesNodeModuleLookupPaths(args.request)) {
        if (parent && parent->paths.is_paths()) {
            const auto& paths = parent->paths.paths();
            Bindgen::CppResultSequence<Bindgen::NodeModuleLookupPathResultResult> result;
            if (!result.reserveCapacity(context.results(), paths.size()))
                return std::nullopt;
            for (auto path : paths) {
                Bindgen::NodeModuleLookupPathResultResult item;
                item.set_value(path);
                if (!result.append(context.results(), WTF::move(item)))
                    return std::nullopt;
            }
            return result;
        }

        return Bindgen::CppResultSequence<Bindgen::NodeModuleLookupPathResultResult> {};
    }

    WTF::String dirname;
    if (parent && parent->filename.is_string()) {
        const auto& filename = parent->filename.string();
#if OS(WINDOWS)
        dirname = Bindgen::ZigExports::bunBindgenZig_Path_dirnameWindows(globalObject, filename);
#else
        dirname = Bindgen::ZigExports::bunBindgenZig_Path_dirnamePosix(globalObject, filename);
#endif
        RETURN_IF_EXCEPTION(scope, {});
    } else
        dirname = "."_s;

    Bindgen::CppResultSequence<Bindgen::NodeModuleLookupPathResultResult> result;
    Bindgen::NodeModuleLookupPathResultResult item;
    item.set_string(WTF::move(dirname));
    if (!result.append(context.results(), WTF::move(item)))
        return std::nullopt;
    return result;
}

bool usesNodeModuleLookupPaths(const WTF::String& request)
{
    if (request.isEmpty() || request.codeUnitAt(0) != '.')
        return true;
    if (request.length() == 1)
        return false;
    auto second = request.codeUnitAt(1);
    if (second == '.' || second == '/')
        return false;
#if OS(WINDOWS)
    if (second == '\\')
        return false;
#endif
    return true;
}

// These two setters are only used if you directly hit
// `Module.prototype.require` or `module.require`. When accessing the cjs
// require argument, this is a bound version of `require`, which calls into the
// overridden one.
//
// This require function also intentionally does not have .resolve on it, nor
// does it have any of the other properties.
//
// Note: allowing require to be overridable at all is only needed for Next.js to
// work (they do Module.prototype.require = ...)

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getRequireFunction(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getRequireFunction_Arguments&)
{
    auto* globalObject = &context.globalObject;
    return globalObject->getDirect(
        globalObject->vm(), WebCore::clientData(globalObject->vm())->builtinNames().overridableRequirePrivateName());
}

bool Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_setRequireFunction(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_setRequireFunction_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    args.value.defineOwnDataProperty(globalObject->vm(), *globalObject,
        WebCore::clientData(globalObject->vm())
            ->builtinNames()
            .overridableRequirePrivateName(),
        0);
    return true;
}

static JSValue getModuleCacheObject(VM& vm, JSObject* moduleObject)
{
    return uncheckedDowncast<Zig::GlobalObject>(moduleObject->globalObject())
        ->lazyRequireCacheObject();
}

static JSValue getModuleExtensionsObject(VM& vm, JSObject* moduleObject)
{
    return uncheckedDowncast<Zig::GlobalObject>(moduleObject->globalObject())
        ->lazyRequireExtensionsObject();
}

WTF::Vector<WTF::String> Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getBuiltinModulesObject(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getBuiltinModulesObject_Arguments&)
{
    WTF::Vector<WTF::String> modules;
    modules.reserveInitialCapacity(countof(builtinModuleNames));

    for (auto name : builtinModuleNames)
        modules.append(WTF::String(name));

    return modules;
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_setCJSWrapperItem(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_setCJSWrapperItem_Arguments& args)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    global->m_moduleWrapperStart = args.prefix;
    global->m_moduleWrapperEnd = args.suffix;
    global->hasOverriddenModuleWrapper = true;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getWrapper(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getWrapper_Arguments&)
{
    auto* global = &context.globalObject;
    // This does not cache anything because it is assumed nobody reads it more than once.
    VM& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSFunction* cb = JSC::JSFunction::create(vm, global, WebCore::commonJSGetWrapperArrayProxyCodeGenerator(vm), global);
    JSC::CallData callData = JSC::getCallData(cb);

    JSC::MarkedArgumentBuffer args;
    args.append(JSFunction::create(
        vm, global, 1, "onMutate"_s,
        bun_bindgen_host_NodeModuleModule_setCJSWrapperItem, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic));

    auto result = JSC::profiledCall(global, JSC::ProfilingReason::API, cb, callData, JSC::jsUndefined(), args);
    RETURN_IF_EXCEPTION(scope, {});
    ASSERT(result.isCell());
    RELEASE_AND_RETURN(scope, result);
}

bool Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_setWrapper(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_setWrapper_Arguments& args)
{
    if (!args.value.is_wrapper())
        return false;
    const auto& wrapper = args.value.wrapper();
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    globalObject->m_moduleWrapperStart = wrapper.prefix;
    globalObject->m_moduleWrapperEnd = wrapper.suffix;
    globalObject->hasOverriddenModuleWrapper = true;

    return true;
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_load(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_load_Arguments&)
{
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_runMain(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_runMain_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto name = makeAtomString(args.specifier);

    auto* promise = JSC::loadAndEvaluateModule(globalObject, name, nullptr, nullptr);
    RETURN_IF_EXCEPTION(scope, void());
    Bindgen::ZigExports::bunBindgenZig_module_run_main_setOverrideModuleRunMainPromise(
        defaultGlobalObject(globalObject), promise);
    RELEASE_AND_RETURN(scope, void());
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getRunMain(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getRunMain_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    return globalObject->m_moduleRunMainFunction.getInitializedOnMainThread(globalObject);
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_NodeModuleModule_callOverriddenRunMain(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeModuleModule_callOverriddenRunMain_Arguments& args)
{
    auto* global = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    JSC::JSValue overrideHandler = global->m_moduleRunMainFunction.get(global);
    auto callData = JSC::getCallData(overrideHandler);
    if (callData.type == JSC::CallData::Type::None) {
        JSC::throwTypeError(global, scope, "Module.runMain is not a function"_s);
        return {};
    }
    MarkedArgumentBuffer arguments;
    arguments.append(args.argument);
    RELEASE_AND_RETURN(scope, JSC::profiledCall(global, JSC::ProfilingReason::API, overrideHandler, callData, global, arguments));
}

bool Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_setRunMain(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_setRunMain_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    if (args.value) {
        auto value = *args.value;
        bool isOriginal = false;
        if (value.isCallable()) {
            JSC::CallData callData = JSC::getCallData(value);
            if (callData.type == JSC::CallData::Type::Native) {
                if (callData.native.function.untaggedPtr() == &bun_bindgen_host_NodeModuleModule_runMain) {
                    isOriginal = true;
                }
            }
        }
        Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_setOverrideModuleRunMain(globalObject, !isOriginal);
        globalObject->m_moduleRunMainFunction.set(
            lexicalGlobalObject->vm(), globalObject, value.asCell());
    }

    return true;
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_preloadModules(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_preloadModules_Arguments&)
{
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_syncBuiltinESMExports(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_syncBuiltinESMExports_Arguments&)
{
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_register(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_register_Arguments&)
{
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_enableCompileCache(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_enableCompileCache_Arguments&)
{
}

void Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getCompileCacheDir(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getCompileCacheDir_Arguments&)
{
}

#define BUN_BINDGEN_OBJECT_SURFACE_NodeModuleConstructor
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_NodeModuleConstructor

class JSModuleConstructor : public JSC::InternalFunction {
    using Base = JSC::InternalFunction;

public:
    DECLARE_EXPORT_INFO;
    static constexpr JSC::DestructionMode needsDestruction = DoesNotNeedDestruction;
    static constexpr unsigned StructureFlags = Base::StructureFlags | HasStaticPropertyTable;

    static JSC::Structure* createStructure(JSC::VM& vm,
        JSC::JSGlobalObject* globalObject,
        JSC::JSValue prototype)
    {
        ASSERT(globalObject);
        return JSC::Structure::create(
            vm, globalObject, prototype,
            JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
    }

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSModuleConstructor, Base);
        return &vm.internalFunctionSpace();
    }

    static JSModuleConstructor* create(JSC::VM& vm,
        Zig::GlobalObject* globalObject)
    {
        auto* structure = createStructure(vm, globalObject, globalObject->functionPrototype());

        auto* moduleConstructor = new (NotNull, JSC::allocateCell<JSModuleConstructor>(vm))
            JSModuleConstructor(vm, structure);
        moduleConstructor->finishCreation(vm);
        return moduleConstructor;
    }

private:
    JSModuleConstructor(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure, bun_bindgen_host_NodeModuleModule_moduleCall,
              bun_bindgen_host_NodeModuleModule_moduleConstruct)
    {
    }

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm, 1, "Module"_s,
            PropertyAdditionMode::WithoutStructureTransition);
        bunBindgenObjectSurface_NodeModuleConstructor_install(vm, info(), *this);
    }
};

const JSC::ClassInfo JSModuleConstructor::s_info = {
    "Module"_s, &Base::s_info, &bunBindgenObjectSurface_NodeModuleConstructorTable, nullptr,
    CREATE_METHOD_TABLE(JSModuleConstructor)
};

void addNodeModuleConstructorProperties(JSC::VM& vm,
    Zig::GlobalObject* globalObject)
{
    globalObject->m_nodeModuleConstructor.initLater(
        [](const Zig::GlobalObject::Initializer<JSObject>& init) {
            JSObject* moduleConstructor = JSModuleConstructor::create(
                init.vm, static_cast<Zig::GlobalObject*>(init.owner));
            init.set(moduleConstructor);
        });

    globalObject->m_moduleRunMainFunction.initLater(
        [](const Zig::GlobalObject::Initializer<JSCell>& init) {
            JSFunction* runMainFunction = JSFunction::create(
                init.vm, init.owner, 2, "runMain"_s,
                bun_bindgen_host_NodeModuleModule_runMain, JSC::ImplementationVisibility::Public,
                JSC::NoIntrinsic, bun_bindgen_host_NodeModuleModule_runMain);
            init.set(runMainFunction);
        });

    globalObject->m_moduleResolveFilenameFunction.initLater(
        [](const Zig::GlobalObject::Initializer<JSCell>& init) {
            JSFunction* resolveFilenameFunction = JSFunction::create(
                init.vm, init.owner, 2, "_resolveFilename"_s,
                bun_bindgen_host_NodeModuleModule_resolveFilename, JSC::ImplementationVisibility::Public,
                JSC::NoIntrinsic, bun_bindgen_host_NodeModuleModule_resolveFilename);
            init.set(resolveFilenameFunction);
        });

    globalObject->m_modulePrototypeUnderscoreCompileFunction.initLater(
        [](const Zig::GlobalObject::Initializer<JSFunction>& init) {
            JSFunction* resolveFilenameFunction = JSFunction::create(
                init.vm, init.owner, 2, "_compile"_s,
                bun_bindgen_host_RuntimeFunctions_functionJSCommonJSModule_compile, JSC::ImplementationVisibility::Public,
                JSC::NoIntrinsic, bun_bindgen_host_RuntimeFunctions_functionJSCommonJSModule_compile);
            init.set(resolveFilenameFunction);
        });

    globalObject->m_commonJSRequireESMFromHijackedExtensionFunction.initLater(
        [](const Zig::GlobalObject::Initializer<JSFunction>& init) {
            JSC::JSFunction* requireESM = JSC::JSFunction::create(init.vm, init.owner, commonJSRequireESMFromHijackedExtensionCodeGenerator(init.vm), init.owner);
            init.set(requireESM);
        });

    globalObject->m_lazyRequireCacheObject.initLater(
        [](const Zig::GlobalObject::Initializer<JSObject>& init) {
            JSC::VM& vm = init.vm;
            JSC::JSGlobalObject* globalObject = init.owner;

            auto scope = DECLARE_THROW_SCOPE(vm);
            auto* function = JSFunction::create(vm, globalObject, static_cast<JSC::FunctionExecutable*>(commonJSCreateRequireCacheCodeGenerator(vm)), globalObject);
            auto result = JSC::profiledCall(globalObject, ProfilingReason::API, function, JSC::getCallData(function), globalObject, ArgList());
            RETURN_IF_EXCEPTION(scope, );
            auto* resultObject = result.toObject(globalObject);
            RETURN_IF_EXCEPTION(scope, );
            init.set(resultObject);
        });

    globalObject->m_lazyRequireExtensionsObject.initLater(
        [](const Zig::GlobalObject::Initializer<Bun::JSCommonJSExtensions>& init) {
            JSC::VM& vm = init.vm;
            JSC::JSGlobalObject* globalObject = init.owner;

            init.set(JSCommonJSExtensions::create(vm, globalObject, JSCommonJSExtensions::createStructure(vm, globalObject, globalObject->nullPrototype())));
        });
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_moduleConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_moduleConstructor_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    return globalObject->m_nodeModuleConstructor.getInitializedOnMainThread(globalObject);
}

bool Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_isResolveFilenameSlowPathEnabled(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_isResolveFilenameSlowPathEnabled_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->hasOverriddenModuleResolveFilenameFunction;
}

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, Callback)                                      \
    JSC::JSValue Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                                      \
        Bindgen::CppCallContext& context,                                                               \
        const Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)                       \
    {                                                                                                   \
        return Callback(context.globalObject.vm(), JSC::asObject(args.bindingThis));                     \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(NodeModuleModule, getModuleCacheObject, getModuleCacheObject)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(NodeModuleModule, getModuleExtensionsObject, getModuleExtensionsObject)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_getModulePrototypeCompileFunction(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_getModulePrototypeCompileFunction_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->modulePrototypeUnderscoreCompileFunction();
}

} // namespace Bun
