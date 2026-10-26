#include "ErrorCode.h"
#include "root.h"

#include "ImportMetaObject.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "DOMClientIsoSubspaces.h"
#include "DOMIsoSubspaces.h"
#include "JSDOMBinding.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMGlobalObject.h"
#include "JSDOMOperation.h"
#include "JSDOMWrapperCache.h"
#include "ScriptExecutionContext.h"
#include "WebCoreJSClientData.h"
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/CallData.h>

#include <JavaScriptCore/JSDestructibleObjectHeapCellType.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/SubspaceInlines.h>
#include <wtf/GetPtr.h>
#include <wtf/PointerPreparations.h>
#include <wtf/URL.h>
#include <wtf/text/MakeString.h>
#include <JavaScriptCore/BuiltinNames.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>

#include "JSBufferEncodingType.h"
#include <JavaScriptCore/JSBase.h>

#include "JSDOMURL.h"
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/LazyProperty.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include "JSCommonJSModule.h"
#include <JavaScriptCore/JSPromise.h>
#include "PathInlines.h"
#include "wtf/text/StringView.h"

#include "isBuiltinModule.h"
#include "WebCoreJSBuiltins.h"

namespace Zig {

using namespace JSC;
using namespace WebCore;

ImportMetaObject* ImportMetaObject::create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, const WTF::String& url)
{
    ImportMetaObject* ptr = new (NotNull, JSC::allocateCell<ImportMetaObject>(vm)) ImportMetaObject(vm, structure);
    ptr->finishCreation(vm, url);
    return ptr;
}

ImportMetaObject* ImportMetaObject::create(JSC::JSGlobalObject* globalObject, const WTF::String& url)
{
    VM& vm = globalObject->vm();
    Zig::GlobalObject* zigGlobalObject = uncheckedDowncast<Zig::GlobalObject>(globalObject);
    bool isBake = url.startsWith("bake:"_s);

    // Get the appropriate structure
    Structure* structure = isBake
        ? zigGlobalObject->ImportMetaBakeObjectStructure()
        : zigGlobalObject->ImportMetaObjectStructure();

    return create(vm, globalObject, structure, url);
}

ImportMetaObject* ImportMetaObject::create(JSC::JSGlobalObject* globalObject, JSValue specifierOrURL)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (dynamicDowncast<WebCore::JSDOMURL>(specifierOrURL)) {
        auto url = WebCore::protectedDOMURL(globalObject, specifierOrURL);
        RETURN_IF_EXCEPTION(scope, nullptr);
        RELEASE_ASSERT(url);
        auto snapshot = url->href();
        if (snapshot.hasException()) {
            WebCore::propagateException(*globalObject, scope, snapshot.releaseException());
            return nullptr;
        }
        String href = snapshot.releaseReturnValue().string();
        RELEASE_AND_RETURN(scope, create(globalObject, href));
    }

    WTF::String specifier = specifierOrURL.toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, nullptr);
    RELEASE_AND_RETURN(scope, ImportMetaObject::createFromSpecifier(globalObject, specifier));
}

ImportMetaObject* ImportMetaObject::createFromSpecifier(JSC::JSGlobalObject* globalObject, const String& specifier)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    const auto index = specifier.find('?');
    const StringView view = specifier;
    auto url = URL::fileURLWithFileSystemPath(index == notFound ? view : view.left(index));
    if (index != notFound)
        url.setQuery(view.substring(index + 1));
    RELEASE_AND_RETURN(scope, create(globalObject, url.string()));
}

template<typename Input>
static std::optional<WTF::String> importMetaParent(
    JSC::JSGlobalObject& globalObject,
    const Input& input,
    std::optional<bool>* esmOverride)
{
    if constexpr (requires { input.is_boolean(); }) {
        if (esmOverride && input.is_boolean()) {
            *esmOverride = input.boolean();
            return std::nullopt;
        }
    }

    if (input.is_string())
        return input.string();
    if (!input.is_object())
        return std::nullopt;

    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto paths = input.object().getObject()->getIfPropertyExists(&globalObject, WebCore::builtinNames(globalObject.vm()).pathsPublicName());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (auto* pathsArray = dynamicDowncast<JSC::JSArray>(paths); pathsArray && pathsArray->length() > 0) {
        paths = pathsArray->getIndex(&globalObject, 0);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    if (!paths.isString())
        return std::nullopt;
    auto result = paths.toWTFString(&globalObject);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    scope.release();
    return result;
}

template<typename Input>
static JSC::JSValue importMetaModuleNameSource(JSC::VM& vm, const Input& input)
{
    if (input.is_string())
        return JSC::jsString(vm, input.string());
    if (input.is_undefined_value())
        return JSC::jsUndefined();
    if (input.is_null_value())
        return JSC::jsNull();
    RELEASE_ASSERT(input.is_other());
    return input.other();
}

template<typename Input>
static std::optional<WTF::String> importMetaModuleName(const Input& input)
{
    if (input.is_string())
        return input.string();
    return std::nullopt;
}

template<typename Input>
static JSC::JSValue importMetaUserPathsSource(const Input& input)
{
    if (input.is_array())
        return input.array();
    if (input.is_undefined_value())
        return JSC::jsUndefined();
    if (input.is_null_value())
        return JSC::jsNull();
    RELEASE_ASSERT(input.is_invalid());
    return input.invalid();
}

#define BUN_BINDGEN_OBJECT_SURFACE_ImportMetaObjectPrototype
#define BUN_BINDGEN_OBJECT_SURFACE_ImportMetaObjectBakePrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ImportMetaObjectBakePrototype
#undef BUN_BINDGEN_OBJECT_SURFACE_ImportMetaObjectPrototype

class ImportMetaObjectPrototype : public JSC::JSNonFinalObject {
public:
    DECLARE_INFO;
    using Base = JSC::JSNonFinalObject;

    static Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        return Structure::create(vm, globalObject, globalObject->objectPrototype(), TypeInfo(ObjectType, StructureFlags), info());
    }

    static ImportMetaObjectPrototype* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, bool isBake = false)
    {
        ImportMetaObjectPrototype* prototype = new (NotNull, JSC::allocateCell<ImportMetaObjectPrototype>(vm)) ImportMetaObjectPrototype(vm, structure);
        prototype->finishCreation(vm, globalObject, isBake);
        return prototype;
    }

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(ImportMetaObjectPrototype, Base);
        return &vm.plainObjectSpace();
    }

    void finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject, bool isBake)
    {
        Base::finishCreation(vm);

        if (isBake) {
            bunBindgenObjectSurface_ImportMetaObjectBakePrototype_install(vm, ImportMetaObject::info(), *this);
        } else {
            bunBindgenObjectSurface_ImportMetaObjectPrototype_install(vm, ImportMetaObject::info(), *this);
        }
    }

    ImportMetaObjectPrototype(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }
};

const ClassInfo ImportMetaObjectPrototype::s_info = {
    "ImportMeta"_s,

    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(ImportMetaObjectPrototype)
};

JSC::Structure* ImportMetaObject::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, bool isBake)
{
    ImportMetaObjectPrototype* prototype = ImportMetaObjectPrototype::create(vm,
        globalObject,
        ImportMetaObjectPrototype::createStructure(vm, globalObject),
        isBake);

    return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), ImportMetaObject::info());
}

void ImportMetaObject::finishCreation(VM& vm, const String& url)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    urlProperty.set(vm, this, jsString(vm, url));
}

static std::optional<String> importMetaPathString(const String& input, bool allowFileSystemPath)
{
    URL url = allowFileSystemPath && isAbsolutePath(input) ? URL::fileURLWithFileSystemPath(input) : URL(input);
    if (!url.isValid())
        return allowFileSystemPath ? input : String(emptyString());
    if (url.protocolIsFile()) {
        auto path = url.fileSystemPath();
        return path.isNull() ? String(emptyString()) : WTF::move(path);
    }
    auto path = tryMakeString(url.path());
    if (path.isNull())
        return std::nullopt;
    return path;
}

JSString* ImportMetaObject::getStringProperty(JSGlobalObject* global, StringProperty property)
{
    auto& slot = [&]() -> WriteBarrier<JSString>& {
        switch (property) {
        case StringProperty::URL: return urlProperty;
        case StringProperty::Path: return pathProperty;
        case StringProperty::Directory: return dirProperty;
        case StringProperty::File: return fileProperty;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }();
    if (auto* cached = slot.get())
        return cached;
    auto scope = DECLARE_THROW_SCOPE(vm());
    ASSERT(property != StringProperty::URL);
    auto source = urlProperty.get()->value(global);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto path = importMetaPathString(source, false);
    if (!path) {
        throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    String value;
    if (property == StringProperty::Path)
        value = WTF::move(*path);
    else {
        StringView view = *path;
        if (property == StringProperty::Directory) {
            if (view.endsWith(PLATFORM_SEP_s))
                view = view.left(view.length() - 1);
            else if (auto separator = view.reverseFind(PLATFORM_SEP); separator != notFound)
                view = view.left(separator);
        } else if (view.endsWith(PLATFORM_SEP_s) && view.length() <= 1)
            view = { };
        else {
            const auto separator = view.endsWith(PLATFORM_SEP_s)
                ? view.reverseFind(PLATFORM_SEP, view.length() - 2)
                : view.reverseFind(PLATFORM_SEP);
            if (separator != notFound)
                view = view.substring(separator + 1);
        }
        value = tryMakeString(view);
        if (value.isNull()) {
            throwOutOfMemoryError(global, scope);
            return nullptr;
        }
    }
    auto* result = jsString(vm(), value);
    slot.set(vm(), this, result);
    return result;
}

JSCell* ImportMetaObject::getRequire(JSGlobalObject* global)
{
    if (auto* cached = requireProperty.get())
        return cached;
    auto scope = DECLARE_THROW_SCOPE(vm());
    auto source = urlProperty.get()->value(global);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto path = importMetaPathString(source, true);
    if (!path) {
        throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    auto* result = Bun::JSCommonJSModule::createBoundRequireFunction(vm(), globalObject(), *path);
    RETURN_IF_EXCEPTION(scope, nullptr);
    RELEASE_ASSERT(result);
    requireProperty.set(vm(), this, result);
    return result;
}

template<typename Visitor>
void ImportMetaObject::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    ImportMetaObject* fn = uncheckedDowncast<ImportMetaObject>(cell);
    ASSERT_GC_OBJECT_INHERITS(fn, info());
    Base::visitChildren(fn, visitor);

    visitor.append(fn->requireProperty);
    visitor.append(fn->urlProperty);
    visitor.append(fn->dirProperty);
    visitor.append(fn->fileProperty);
    visitor.append(fn->pathProperty);
}

DEFINE_VISIT_CHILDREN(ImportMetaObject);

JSValue ImportMetaObject::getPrototype(JSObject* object, JSC::JSGlobalObject* globalObject)
{
    ASSERT(object->inherits(info()));
    return jsNull();
}

const JSC::ClassInfo ImportMetaObject::s_info = { "ImportMeta"_s, &Base::s_info, nullptr, nullptr,
    CREATE_METHOD_TABLE(ImportMetaObject) };
}

static Zig::ImportMetaObject* importMetaObject(const std::optional<JSC::JSValue>& value)
{
    if (!value)
        return nullptr;
    auto* object = dynamicDowncast<Zig::ImportMetaObject>(*value);
    RELEASE_ASSERT(object);
    return object;
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaURL(
    CppCallContext& context,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaURL_Arguments& args)
{
    auto* object = importMetaObject(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto* result = object->getStringProperty(&context.globalObject, Zig::ImportMetaObject::StringProperty::URL);
    return result ? std::optional<JSC::JSValue>(result) : std::nullopt;
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaDir(
    CppCallContext& context,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaDir_Arguments& args)
{
    auto* object = importMetaObject(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto* result = object->getStringProperty(&context.globalObject, Zig::ImportMetaObject::StringProperty::Directory);
    return result ? std::optional<JSC::JSValue>(result) : std::nullopt;
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaFile(
    CppCallContext& context,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaFile_Arguments& args)
{
    auto* object = importMetaObject(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto* result = object->getStringProperty(&context.globalObject, Zig::ImportMetaObject::StringProperty::File);
    return result ? std::optional<JSC::JSValue>(result) : std::nullopt;
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaPath(
    CppCallContext& context,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaPath_Arguments& args)
{
    auto* object = importMetaObject(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto* result = object->getStringProperty(&context.globalObject, Zig::ImportMetaObject::StringProperty::Path);
    return result ? std::optional<JSC::JSValue>(result) : std::nullopt;
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaRequire(
    CppCallContext& context,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaRequire_Arguments& args)
{
    auto* object = importMetaObject(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto* require = object->getRequire(&context.globalObject);
    if (!require)
        return std::nullopt;
    return require;
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaSetRequire(
    CppCallContext&,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaSetRequire_Arguments& args)
{
    auto* object = importMetaObject(args.bindingThis);
    if (!object) [[unlikely]]
        return false;

    // https://github.com/oven-sh/bun/issues/11754#issuecomment-2452626172
    // This setter supports libraries that wrap the require function.
    if (!args.value)
        return true;

    object->requireProperty.set(object->vm(), object, args.value->asCell());
    return true;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_importMetaEnv(
    CppCallContext& context,
    const BunBindgenCpp_ModuleObjectSurfaceHost_importMetaEnv_Arguments&)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    return globalObject->m_processEnvObject.getInitializedOnMainThread(globalObject);
}

WTF::String Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_functionImportMeta__resolve(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_functionImportMeta__resolve_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    const auto& specifier = args.specifier;
    std::optional<WTF::String> from = importMetaParent(*globalObject, args.parent, nullptr);
    RETURN_IF_EXCEPTION(scope, {});

    if (!from) {
        auto* thisObject = args.bindingThis.is_object() ? JSC::asObject(args.bindingThis.object()) : nullptr;
        if (!thisObject) [[unlikely]] {
            JSC::throwTypeError(globalObject, scope, "import.meta.resolve must be bound to an import.meta object"_s);
            return {};
        }

        auto clientData = WebCore::clientData(vm);
        JSValue pathProperty = thisObject->getIfPropertyExists(globalObject, clientData->builtinNames().pathPublicName());
        RETURN_IF_EXCEPTION(scope, {});

        if (pathProperty && pathProperty.isString()) [[likely]] {
            from = pathProperty.toWTFString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            JSC::throwTypeError(globalObject, scope, "import.meta.resolve must be bound to an import.meta object"_s);
            return {};
        }
    }
    ASSERT(from);
    const auto& fromWTFString = *from;

    // Try to resolve it to a relative file path. This path is not meant to throw module resolution errors.
    if (specifier.startsWith("./"_s) || specifier.startsWith("../"_s) || specifier.startsWith("/"_s) || specifier.startsWith("file://"_s)
#if OS(WINDOWS)
        || specifier.startsWith(".\\"_s) || specifier.startsWith("..\\"_s) || specifier.startsWith("\\"_s)
#endif
    ) {
        WTF::URL fromURL;
        if (fromWTFString.startsWith("file://"_s)) {
            WTF::URL parsed { fromWTFString };
            if (parsed.isValid())
                fromURL = WTF::move(parsed);
        } else {
            fromURL = WTF::URL::fileURLWithFileSystemPath(fromWTFString);
        }
        if (!fromURL.isValid()) {
            JSC::throwTypeError(globalObject, scope, "`parent` is not a valid Filepath / URL"_s);
            return {};
        }

        WTF::URL url { fromURL, specifier };
        if (!url.isValid())
            return specifier;
        return url.string();
    }

    // In Node.js, `node:doesnotexist` resolves to `node:doesnotexist`
    if (specifier.startsWith("node:"_s) || specifier.startsWith("bun:"_s)) [[unlikely]] {
        return specifier;
    }

    // Run it through the module resolver, errors at this point are actual errors.
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_resolveSyncWithStrings(globalObject, specifier, fromWTFString, true);
    RETURN_IF_EXCEPTION(scope, {});

    if (isAbsolutePath(result)) {
        return WTF::URL::fileURLWithFileSystemPath(result).string();
    }
    return result;
}

WTF::String Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_functionImportMeta__resolveSync(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_functionImportMeta__resolveSync_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    const auto& moduleNameInput = args.specifier;
    JSValue moduleNameSource = importMetaModuleNameSource(vm, moduleNameInput);
    auto moduleName = importMetaModuleName(moduleNameInput);
    if (moduleNameInput.is_undefined_value() || moduleNameInput.is_null_value()) {
        JSC::throwTypeError(globalObject, scope, "expects a string"_s);
        return {};
    }
    std::optional<WTF::String> from;
    bool isESM = true;

    if (args.isESM && *args.isESM)
        isESM = **args.isESM;

    if (args.parent) {
        std::optional<bool> esmOverride;
        from = importMetaParent(*globalObject, *args.parent, &esmOverride);
        RETURN_IF_EXCEPTION(scope, {});
        if (esmOverride)
            isESM = *esmOverride;
        if (!from && args.bindingThis.is_string())
            from = args.bindingThis.string();
    } else if (args.bindingThis.is_string()) {
        from = args.bindingThis.string();
    } else {
        JSC::JSObject* thisObject = args.bindingThis.is_object() ? JSC::asObject(args.bindingThis.object()) : nullptr;
        if (!thisObject) [[unlikely]] {
            JSC::throwTypeError(globalObject, scope, "import.meta.resolveSync must be bound to an import.meta object"_s);
            return {};
        }

        auto clientData = WebCore::clientData(vm);
        JSValue pathProperty = thisObject->getIfPropertyExists(globalObject, clientData->builtinNames().pathPublicName());
        RETURN_IF_EXCEPTION(scope, {});

        if (pathProperty && pathProperty.isString()) {
            from = pathProperty.toWTFString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    if (globalObject->onLoadPlugins.hasVirtualModules()) {
        if (moduleName) {
            const auto& moduleString = *moduleName;
            const WTF::String virtualModuleParent = from.value_or("undefined"_s);
            if (auto resolvedString = globalObject->onLoadPlugins.resolveVirtualModule(moduleString, virtualModuleParent)) {
                return *resolvedString;
            }
        }
    }

    JSValue fromValue = from ? JSValue(jsString(vm, *from)) : jsUndefined();
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_resolveSync(globalObject, moduleNameSource, fromValue, isESM, false);
    RETURN_IF_EXCEPTION(scope, {});

    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_functionImportMeta__resolveSyncPrivate(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_functionImportMeta__resolveSyncPrivate_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = dynamicDowncast<Zig::GlobalObject>(lexicalGlobalObject);

    const auto& moduleNameInput = args.specifier;
    JSValue moduleNameSource = importMetaModuleNameSource(vm, moduleNameInput);
    auto moduleName = importMetaModuleName(moduleNameInput);
    const auto& from = args.parent;
    JSValue parentSource = jsString(vm, from);
    bool isESM = args.isESM;
    bool isRequireDotResolve = args.isRequireDotResolve;
    const auto& userPaths = args.paths;
    JSValue userPathsSource = importMetaUserPathsSource(userPaths);
    const bool userPathsPresent = userPaths.is_array() || userPaths.is_invalid();

    RETURN_IF_EXCEPTION(scope, {});

    if (globalObject->onLoadPlugins.hasVirtualModules()) {
        if (moduleName) {
            const auto& moduleString = *moduleName;
            if (auto resolvedString = globalObject->onLoadPlugins.resolveVirtualModule(moduleString, from)) {
                if (moduleString == resolvedString.value())
                    return moduleNameSource;
                return jsString(vm, resolvedString.value());
            }
        }
    }

    if (!isESM) {
        if (globalObject) [[likely]] {
            if (globalObject->hasOverriddenModuleResolveFilenameFunction) [[unlikely]] {
                JSC::JSValue overrideHandler = globalObject->m_moduleResolveFilenameFunction.getInitializedOnMainThread(globalObject);
                if (overrideHandler) [[likely]] {
                    auto callData = JSC::getCallData(overrideHandler);
                    if (callData.type == JSC::CallData::Type::None) {
                        JSC::throwTypeError(lexicalGlobalObject, scope, "Module._resolveFilename is not a function"_s);
                        return {};
                    }
                    JSValue parentModuleObject = globalObject->requireMap()->get(globalObject, parentSource);
                    RETURN_IF_EXCEPTION(scope, {});

                    JSValue parentID = jsUndefined();
                    if (auto* parent = dynamicDowncast<Bun::JSCommonJSModule>(parentModuleObject)) {
                        parentID = parent->filename();
                    } else {
                        parentID = parentSource;
                    }

                    JSC::MarkedArgumentBuffer arguments;
                    arguments.append(moduleNameSource);
                    arguments.append(parentModuleObject);
                    auto parentIdStr = parentID.toWTFString(globalObject);
                    RETURN_IF_EXCEPTION(scope, {});
                    arguments.append(jsBoolean(Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_isBunMain(lexicalGlobalObject, parentIdStr)));
                    RETURN_IF_EXCEPTION(scope, {});

                    // Pass options object with paths if provided
                    if (userPathsPresent) {
                        JSObject* options = JSC::constructEmptyObject(globalObject);
                        options->putDirect(vm, JSC::Identifier::fromString(vm, "paths"_s), userPathsSource);
                        RETURN_IF_EXCEPTION(scope, {});
                        arguments.append(options);
                    }

                    if (arguments.hasOverflowed()) {
                        JSC::throwOutOfMemoryError(globalObject, scope);
                        return {};
                    }

                    JSValue result = JSC::profiledCall(lexicalGlobalObject, ProfilingReason::API, overrideHandler, callData, parentModuleObject, arguments);
                    RETURN_IF_EXCEPTION(scope, {});
                    if (!isRequireDotResolve) {
                        JSString* string = result.toString(globalObject);
                        RETURN_IF_EXCEPTION(scope, {});
                        auto str = string->value(globalObject);
                        RETURN_IF_EXCEPTION(scope, {});
                        WTF::String prefixed = Bun::isUnprefixedNodeBuiltin(str);
                        if (!prefixed.isNull()) {
                            return jsString(vm, prefixed);
                        }
                        return string;
                    }
                    return result;
                }
            }
        }

        if (userPathsPresent) {
            if (userPaths.is_array()) {
                if (!moduleName) {
                    Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, "id"_s, "string"_s, moduleNameSource);
                    scope.release();
                    return {};
                }

                RELEASE_ASSERT(args.convertedPaths);
                const auto* paths = args.convertedPaths->convert();
                RETURN_IF_EXCEPTION(scope, {});
                if (!paths)
                    return {};
                auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_resolveSyncWithPaths(lexicalGlobalObject, moduleNameSource, parentSource, isESM, isRequireDotResolve, paths->span());
                RETURN_IF_EXCEPTION(scope, {});

                RELEASE_AND_RETURN(scope, jsString(vm, result));
            } else {
                Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, "option.paths"_s, userPathsSource);
                scope.release();
                return {};
            }
        }
    }

    if (!moduleName) {
        Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, isRequireDotResolve ? "request"_s : "id"_s, "string"_s, moduleNameSource);
        scope.release();
        return {};
    }

    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_resolveSync(lexicalGlobalObject, moduleNameSource, parentSource, isESM, isRequireDotResolve);
    RETURN_IF_EXCEPTION(scope, {});

    RELEASE_AND_RETURN(scope, jsString(vm, result));
}
