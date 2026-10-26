#include "JSCommonJSExtensions.h"
#include "ZigGlobalObject.h"
#include "BunProcess.h"
#include "ModuleLoader.h"
#include "JSCommonJSModule.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/Interpreter.h>
#include <JavaScriptCore/StackFrame.h>

namespace Bun {
using namespace JSC;

#define BUN_BINDGEN_OBJECT_SURFACE_JSCommonJSExtensions
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSCommonJSExtensions

const JSC::ClassInfo JSCommonJSExtensions::s_info = { "CommonJSExtensions"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSCommonJSExtensions) };

JSC::JSValue builtinLoader(JSC::JSGlobalObject* globalObject, Bun::JSCommonJSModule* module, const WTF::String& filename, BunLoaderType loaderType);

// These functions are separate so that assigning one to the other can be
// detected and use the corresponding loader.
JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_jsLoaderJS(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_jsLoaderJS_Arguments& args)
{
    auto* module = dynamicDowncast<Bun::JSCommonJSModule>(args.module);
    RELEASE_ASSERT(module);
    return builtinLoader(
        &context.globalObject,
        module,
        args.filename,
        BunLoaderType::js);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_jsLoaderTS(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_jsLoaderTS_Arguments& args)
{
    auto* module = dynamicDowncast<Bun::JSCommonJSModule>(args.module);
    RELEASE_ASSERT(module);
    return builtinLoader(
        &context.globalObject,
        module,
        args.filename,
        BunLoaderType::ts);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeModuleModule_jsLoaderJSON(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeModuleModule_jsLoaderJSON_Arguments& args)
{
    auto* module = dynamicDowncast<Bun::JSCommonJSModule>(args.module);
    RELEASE_ASSERT(module);
    return builtinLoader(
        &context.globalObject,
        module,
        args.filename,
        BunLoaderType::json);
}
#define jsLoaderNode bun_bindgen_host_ProcessHost_dlopen

static bool isAllowedToMutateExtensions(JSC::JSGlobalObject* globalObject)
{
    auto& vm = globalObject->vm();
    WTF::Vector<JSC::StackFrame> frames;
    vm.interpreter.getStackTrace(globalObject, frames, 0, 1);
    if (frames.isEmpty()) return true;
    const auto url = frames[0].sourceURL(vm);

    // Bun already loads the ESM and TypeScript handled by these Node transpiler hooks.
#if OS(WINDOWS)
    return !url.contains("dist\\build\\next-config-ts\\"_s) && !url.contains("@meteorjs\\babel"_s);
#else
    return !url.contains("dist/build/next-config-ts/"_s) && !url.contains("@meteorjs/babel"_s);
#endif
}

void JSCommonJSExtensions::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    bunBindgenObjectSurface_JSCommonJSExtensions_install(vm, info(), *this);
}

static CommonJSExtensionUpdate* prepareExtensionUpdate(Zig::GlobalObject* globalObject, JSC::PropertyName propertyName, JSC::JSValue value)
{
    if (propertyName.isSymbol()) return nullptr;
    auto* name = propertyName.publicName();
    if (!name->startsWith('.')) return nullptr;
    WTF::String extension(name);
    JSC::CallData callData = JSC::getCallData(value);
    if (callData.type == JSC::CallData::Type::None) {
        return Bindgen::ZigExports::bunBindgenZig_ModuleLoader_prepareCommonJSExtensionUpdate(globalObject, extension, std::nullopt, std::nullopt);
    }

    std::optional<Bindgen::CommonJSBuiltinLoader> loader;
    if (callData.type == JSC::CallData::Type::Native) {
        auto* untaggedPtr = callData.native.function.untaggedPtr();
        if (untaggedPtr == &bun_bindgen_host_NodeModuleModule_jsLoaderJS) {
            loader = Bindgen::CommonJSBuiltinLoader::js;
        } else if (untaggedPtr == &bun_bindgen_host_NodeModuleModule_jsLoaderJSON) {
            loader = Bindgen::CommonJSBuiltinLoader::json;
        } else if (untaggedPtr == &jsLoaderNode) {
            loader = Bindgen::CommonJSBuiltinLoader::napi;
        } else if (untaggedPtr == &bun_bindgen_host_NodeModuleModule_jsLoaderTS) {
            loader = Bindgen::CommonJSBuiltinLoader::ts;
        }
    }
    return Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_prepareCommonJSExtensionUpdate(
        globalObject, extension, loader, value);
}

class ExtensionUpdateScope {
public:
    ExtensionUpdateScope(const ExtensionUpdateScope&) = delete;
    ExtensionUpdateScope& operator=(const ExtensionUpdateScope&) = delete;

    explicit ExtensionUpdateScope(CommonJSExtensionUpdate* update)
        : m_update(update)
    {
    }

    ~ExtensionUpdateScope() { finish(false); }

    void finish(bool commit)
    {
        if (!m_update)
            return;
        Bindgen::ZigExports::bunBindgenZig_ModuleLoader_finishCommonJSExtensionUpdate(m_update, commit);
        m_update = nullptr;
    }

private:
    CommonJSExtensionUpdate* m_update;
};

bool JSCommonJSExtensions::defineOwnProperty(JSC::JSObject* object, JSC::JSGlobalObject* globalObject, JSC::PropertyName propertyName, const JSC::PropertyDescriptor& descriptor, bool shouldThrow)
{
    if (!isAllowedToMutateExtensions(globalObject)) return true;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* global = defaultGlobalObject(globalObject);
    JSValue candidate = descriptor.value();
    if (!candidate && descriptor.isDataDescriptor()) {
        PropertyDescriptor previous;
        bool own = object->getOwnPropertyDescriptor(globalObject, propertyName, previous);
        RETURN_IF_EXCEPTION(scope, false);
        if (!own || previous.isAccessorDescriptor())
            candidate = jsUndefined();
    }
    if (descriptor.isAccessorDescriptor() && !propertyName.isSymbol() && propertyName.publicName()->startsWith('.')) {
        auto factory = bun_bindgen_source_function_NodeModuleModule_createExtensionAccessor_value(global);
        MarkedArgumentBuffer arguments;
        arguments.append(object);
        arguments.append(jsString(globalObject->vm(), String(propertyName.publicName())));
        if (arguments.hasOverflowed()) {
            throwOutOfMemoryError(globalObject, scope);
            return false;
        }
        candidate = profiledCall(globalObject, ProfilingReason::Other, factory.asCell(), getCallData(factory.asCell()), jsUndefined(), arguments);
        RETURN_IF_EXCEPTION(scope, false);
    }
    ExtensionUpdateScope update(candidate ? prepareExtensionUpdate(global, propertyName, candidate) : nullptr);
    RETURN_IF_EXCEPTION(scope, false);
    bool defined = Base::defineOwnProperty(object, globalObject, propertyName, descriptor, shouldThrow);
    RETURN_IF_EXCEPTION(scope, false);
    if (defined)
        update.finish(true);
    return defined;
}

bool JSCommonJSExtensions::put(JSC::JSCell* cell, JSC::JSGlobalObject* globalObject, JSC::PropertyName propertyName, JSC::JSValue value, JSC::PutPropertySlot& slot)
{
    if (!isAllowedToMutateExtensions(globalObject)) return true;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (slot.thisValue() != cell)
        RELEASE_AND_RETURN(scope, Base::put(cell, globalObject, propertyName, value, slot));
    auto* global = defaultGlobalObject(globalObject);
    ExtensionUpdateScope update(prepareExtensionUpdate(global, propertyName, value));
    RETURN_IF_EXCEPTION(scope, false);
    bool written = Base::put(cell, globalObject, propertyName, value, slot);
    RETURN_IF_EXCEPTION(scope, false);
    if (written) {
        PropertyDescriptor descriptor;
        bool own = asObject(cell)->getOwnPropertyDescriptor(globalObject, propertyName, descriptor);
        RETURN_IF_EXCEPTION(scope, false);
        if (own && !descriptor.isAccessorDescriptor() && descriptor.value() == value)
            update.finish(true);
    }
    return written;
}

bool JSCommonJSExtensions::deleteProperty(JSC::JSCell* cell, JSC::JSGlobalObject* globalObject, JSC::PropertyName propertyName, JSC::DeletePropertySlot& slot)
{
    if (!isAllowedToMutateExtensions(globalObject)) return true;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* global = defaultGlobalObject(globalObject);
    ExtensionUpdateScope update(prepareExtensionUpdate(global, propertyName, jsUndefined()));
    RETURN_IF_EXCEPTION(scope, false);
    bool deleted = Base::deleteProperty(cell, globalObject, propertyName, slot);
    RETURN_IF_EXCEPTION(scope, false);
    if (deleted) {
        update.finish(true);
    }
    return deleted;
}

// This implements `Module._extensions['.js']`, which
// - Loads source code from a file
//     - [not supported] Calls `fs.readFileSync`, which is usually not overridden.
// - Evaluates the module
//     - Calls `module._compile(code, filename)`, which is often overridden.
// - Returns `undefined`
JSC::JSValue builtinLoader(JSC::JSGlobalObject* globalObject, Bun::JSCommonJSModule* mod, const WTF::String& specifierWtfString, BunLoaderType loaderType)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    Zig::GlobalObject* global = defaultGlobalObject(globalObject);
    JSC::VM& vm = globalObject->vm();
    JSC::JSValue specifier = JSC::jsString(vm, specifierWtfString);
    ResolvedSourceResult res {};

    JSValue result = fetchCommonJSModuleNonBuiltin<true>(
        global->bunVM(),
        vm,
        global,
        specifierWtfString,
        specifier,
        WTF::emptyString(),
        std::nullopt,
        res,
        mod,
        loaderType,
        scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (result == jsNumber(-1)) {
        // ESM
        JSC::JSFunction* requireESM = global->requireESMFromHijackedExtension();
        JSC::MarkedArgumentBuffer args;
        args.append(specifier);
        JSC::CallData callData = JSC::getCallData(requireESM);
        ASSERT(callData.type == JSC::CallData::Type::JS);
        JSC::profiledCall(global, JSC::ProfilingReason::API, requireESM, callData, mod, args);
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_AND_RETURN(scope, jsUndefined());
}

} // namespace Bun

namespace Bun::Bindgen::Engine {

void releaseCommonJSExtensionUpdate(Bun::CommonJSExtensionUpdate* update)
{
    ZigExports::bunBindgenZig_ModuleLoader_finishCommonJSExtensionUpdate(update, false);
}

}
