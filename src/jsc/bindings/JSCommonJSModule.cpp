/**
 * How this works
 *
 * CommonJS modules are transpiled by Bun's transpiler to the following:
 *
 * (function (exports, require, module) { ... code })(exports, require, module)
 *
 * Then, at runtime, we create a JSCommonJSModule object.
 *
 * On this special object, we override the setter for the "exports" property in
 * a non-observable way using a CustomGetterSetter.
 *
 * When the setter is called, we set the internal "exports" property to the
 * value passed in and we also update the requireMap with the new value.
 *
 * After the CommonJS module is executed, we:
 * - Store the exports value in the requireMap (again)
 * - Loop through the keys of the exports object and re-export as ES Module
 *   named exports
 *
 * If an exception occurs, we remove the entry from the requireMap.
 *
 * How cyclical dependencies are handled:
 *
 * Before executing the CommonJS module, we set the exports object in the
 * requireMap to an empty object. When the CommonJS module is required again, we
 * return the exports object from the requireMap. The values should be in sync
 * while the module is being executed, unless module.exports is re-assigned to a
 * different value. In that case, it will have a stale value.
 */

#include "root.h"
#include "StringConversion.h"
#include "UTF8View.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/Synchronousness.h"
#include "JavaScriptCore/JSCast.h"
#include <JavaScriptCore/JSMapInlines.h>
#include "JavaScriptCore/SourceCode.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSSourceCode.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/OptionsList.h>
#include <JavaScriptCore/ParserError.h>
#include <JavaScriptCore/ScriptExecutable.h>
#include <JavaScriptCore/SourceOrigin.h>
#include <JavaScriptCore/StackFrame.h>
#include <JavaScriptCore/StackVisitor.h>
#include "BunClientData.h"
#include "IsolatedModuleCache.h"
#include <JavaScriptCore/Identifier.h>
#include "ImportMetaObject.h"
#include "NodeModuleModule.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/JSWeakMap.h>
#include <JavaScriptCore/JSWeakMapInlines.h>
#include <JavaScriptCore/JSWithScope.h>

#include <JavaScriptCore/DFGAbstractHeap.h>
#include <JavaScriptCore/Completion.h>
#include "ModuleLoader.h"
#include <JavaScriptCore/JSMap.h>

#include <JavaScriptCore/JSMapInlines.h>
#include <JavaScriptCore/GetterSetter.h>
#include "ZigSourceProvider.h"
#include <JavaScriptCore/FunctionPrototype.h>
#include "JSCommonJSModule.h"
#include <JavaScriptCore/JSModuleNamespaceObject.h>
#include <JavaScriptCore/JSSourceCode.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/HeapAnalyzer.h>
#include "PathInlines.h"
#include "wtf/URL.h"
#include "wtf/text/StringImpl.h"
#include "JSCommonJSExtensions.h"

#include "ErrorCode.h"
#include "WebCoreJSBuiltins.h"

namespace Bun {
using namespace JSC;

static JSCommonJSModule* commonJSModule(const std::optional<JSValue>& value)
{
    return value ? dynamicDowncast<JSCommonJSModule>(*value) : nullptr;
}

static JSCommonJSModule* commonJSModule(JSValue value)
{
    return dynamicDowncast<JSCommonJSModule>(value);
}

static bool canPerformFastEnumeration(Structure* s)
{
    if (s->typeInfo().overridesGetOwnPropertySlot())
        return false;
    if (s->typeInfo().overridesAnyFormOfGetOwnPropertyNames())
        return false;
    if (hasIndexedProperties(s->indexingType()))
        return false;
    if (s->hasAnyKindOfGetterSetterProperties())
        return false;
    if (s->isUncacheableDictionary())
        return false;
    if (s->hasUnderscoreProtoPropertyExcludingOriginalProto())
        return false;
    return true;
}

static bool evaluateCommonJSModuleOnce(JSC::VM& vm, Zig::GlobalObject* globalObject, JSCommonJSModule* moduleObject, JSString* dirname, JSValue filename)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    SourceCode code = WTF::move(moduleObject->sourceCode);

    // If an exception occurred somewhere else, we might have cleared the source code.
    if (code.isNull()) [[unlikely]] {
        throwException(globalObject, scope, createError(globalObject, "Failed to evaluate module"_s));
        return false;
    }

    JSFunction* resolveFunction = nullptr;
    JSFunction* requireFunction = nullptr;
    const auto initializeModuleObject = [&]() {
        SourceCode resolveSourceCode = makeSource("resolve"_s, SourceOrigin(), SourceTaintedOrigin::Untainted);
        resolveFunction = JSC::JSBoundFunction::create(vm,
            globalObject,
            globalObject->requireResolveFunctionUnbound(),
            moduleObject->filename(),
            ArgList(), 1, globalObject->commonStrings().resolveString(globalObject), resolveSourceCode);
        RETURN_IF_EXCEPTION(scope, );

        SourceCode requireSourceCode = makeSource("require"_s, SourceOrigin(), SourceTaintedOrigin::Untainted);
        requireFunction = JSC::JSBoundFunction::create(vm,
            globalObject,
            globalObject->requireFunctionUnbound(),
            moduleObject,
            ArgList(), 1, globalObject->commonStrings().requireString(globalObject), requireSourceCode);
        RETURN_IF_EXCEPTION(scope, );
        requireFunction->putDirect(vm, vm.propertyNames->resolve, resolveFunction, 0);
        RETURN_IF_EXCEPTION(scope, );
        moduleObject->putDirect(vm, WebCore::clientData(vm)->builtinNames().requirePublicName(), requireFunction, 0);
        RETURN_IF_EXCEPTION(scope, );
        moduleObject->hasEvaluated = true;
    };

    bool isEvalEntryPoint = Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_specifierIsEvalEntryPoint(globalObject, filename);
    RETURN_IF_EXCEPTION(scope, false);
    if (isEvalEntryPoint) [[unlikely]] {
        initializeModuleObject();
        scope.assertNoExceptionExceptTermination();

        // Using same approach as node, `arguments` in the entry point isn't defined
        // https://github.com/nodejs/node/blob/592c6907bfe1922f36240e9df076be1864c3d1bd/lib/internal/process/execution.js#L92
        auto exports = moduleObject->exportsObject();
        RETURN_IF_EXCEPTION(scope, {});
        globalObject->putDirect(vm, builtinNames(vm).exportsPublicName(), exports, 0);
        globalObject->putDirect(vm, builtinNames(vm).requirePublicName(), requireFunction, 0);
        globalObject->putDirect(vm, Identifier::fromString(vm, "module"_s), moduleObject, 0);
        globalObject->putDirect(vm, Identifier::fromString(vm, "__filename"_s), filename, 0);
        globalObject->putDirect(vm, Identifier::fromString(vm, "__dirname"_s), dirname, 0);

        JSValue result = JSC::evaluate(globalObject, code, jsUndefined());
        RETURN_IF_EXCEPTION(scope, false);
        ASSERT(result);

        Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_setEntryPointEvalResultCJS(globalObject, result);

        RELEASE_AND_RETURN(scope, true);
    }

    JSValue fnValue = JSC::evaluate(globalObject, code, jsUndefined());
    RETURN_IF_EXCEPTION(scope, false);
    ASSERT(fnValue);

    JSObject* fn = fnValue.getObject();
    if (!fn) [[unlikely]] {
        scope.throwException(globalObject, createTypeError(globalObject, "Expected CommonJS module to have a function wrapper. If you weren't messing around with Bun's internals, this is a bug in Bun"_s));
        RELEASE_AND_RETURN(scope, false);
    }

    JSC::CallData callData = JSC::getCallData(fn);
    if (callData.type == CallData::Type::None) [[unlikely]] {
        scope.throwException(globalObject, createTypeError(globalObject, "Expected CommonJS module to have a function wrapper. If you weren't messing around with Bun's internals, this is a bug in Bun"_s));
        RELEASE_AND_RETURN(scope, false);
    }

    initializeModuleObject();
    RETURN_IF_EXCEPTION(scope, false);

    MarkedArgumentBuffer args;
    auto exports = moduleObject->exportsObject();
    RETURN_IF_EXCEPTION(scope, false);
    args.append(exports); // exports
    args.append(requireFunction); // require
    args.append(moduleObject); // module
    args.append(filename); // filename
    args.append(dirname); // dirname

    if (auto* jsFunction = dynamicDowncast<JSC::JSFunction>(fn)) {
        if (jsFunction->jsExecutable()->parameterCount() > 5) {
            // it expects ImportMetaObject
            args.append(Zig::ImportMetaObject::create(globalObject, filename));
            RETURN_IF_EXCEPTION(scope, false);
        }
    }

    // Clear the source code as early as possible.
    code = {};

    // Call the CommonJS module wrapper function.
    //
    //    fn(exports, require, module, __filename, __dirname) { /* code */ }(exports, require, module, __filename, __dirname)
    //
    JSC::profiledCall(globalObject, ProfilingReason::API, fn, callData, moduleObject, args);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

bool JSCommonJSModule::load(JSC::VM& vm, Zig::GlobalObject* globalObject)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (this->hasEvaluated || this->sourceCode.isNull()) {
        return true;
    }

    evaluateCommonJSModuleOnce(
        globalObject->vm(),
        globalObject,
        this,
        this->m_dirname.get(),
        this->m_filename.get());

    if (auto exception = scope.exception()) {
        (void)scope.tryClearException();

        // On error, remove the module from the require map/
        // so that it can be re-evaluated on the next require.
        bool wasRemoved = globalObject->requireMap()->remove(globalObject, this->filename());
        ASSERT(wasRemoved);

        scope.throwException(globalObject, exception);
        return false;
    }

    return true;
}

static std::optional<WTF::Vector<WTF::String>> requireResolvePaths(
    JSGlobalObject* globalObject,
    const Bun::Bindgen::Cpp::BunBindgenCpp_RuntimeFunctions_requireResolvePathsFunction_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    const auto& requestStr = args.request;
    {
        UTF8View utf8(requestStr);
        auto span = utf8.span();
        if (Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_moduleLoaderIsBuiltin(
                std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(span.data()), span.size()))) {
            return std::nullopt;
        }
    }

    RETURN_IF_EXCEPTION(scope, {});

    // resolve.paths shares the filename captured by the bound resolve function.
    auto* requireResolveBound = args.bindingThis ? dynamicDowncast<JSBoundFunction>(*args.bindingThis) : nullptr;
    if (!requireResolveBound) [[unlikely]] {
        return WTF::Vector<WTF::String> {};
    }
    JSValue boundThis = requireResolveBound->boundThis();
    JSString* filename = dynamicDowncast<JSString>(boundThis);
    if (!filename) [[unlikely]] {
        return WTF::Vector<WTF::String> {};
    }
    const auto filenameValue = filename->value(globalObject);
    RETURN_IF_EXCEPTION(scope, std::nullopt);

    WTF::Vector<WTF::String> paths;
    if (Bun::usesNodeModuleLookupPaths(requestStr)) {
        auto pathStrings = Bindgen::ZigExports::bunBindgenZig_Path_resolverNodeModulePaths(globalObject, filenameValue, true);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!paths.tryAppend(pathStrings.span())) {
            throwOutOfMemoryError(globalObject, scope);
            return std::nullopt;
        }
    } else {
#if OS(WINDOWS)
        auto dirname = Bindgen::ZigExports::bunBindgenZig_Path_dirnameWindows(globalObject, filenameValue);
#else
        auto dirname = Bindgen::ZigExports::bunBindgenZig_Path_dirnamePosix(globalObject, filenameValue);
#endif
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!paths.tryAppend(WTF::move(dirname))) {
            throwOutOfMemoryError(globalObject, scope);
            return std::nullopt;
        }
    }
    return paths;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_requireCache(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_requireCache_Arguments&)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    return globalObject->lazyRequireCacheObject();
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setRequireCache(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setRequireCache_Arguments& args)
{
    auto* object = args.bindingThis ? JSC::asObject(*args.bindingThis) : nullptr;
    if (!object)
        return false;

    auto& vm = context.globalObject.vm();
    args.value.defineOwnDataProperty(vm, *object, Identifier::fromString(vm, "cache"_s), 0);
    return true;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_requireExtensions(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_requireExtensions_Arguments&)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    return globalObject->lazyRequireExtensionsObject();
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setRequireExtensions(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setRequireExtensions_Arguments& args)
{
    auto* object = args.bindingThis ? JSC::asObject(*args.bindingThis) : nullptr;
    if (!object)
        return false;

    auto& vm = context.globalObject.vm();
    args.value.defineOwnDataProperty(vm, *object, Identifier::fromString(vm, "extensions"_s), 0);
    return true;
}

#define BUN_BINDGEN_OBJECT_SURFACE_RequireResolveFunctionPrototype
#define BUN_BINDGEN_OBJECT_SURFACE_RequireFunctionPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_RequireFunctionPrototype
#undef BUN_BINDGEN_OBJECT_SURFACE_RequireResolveFunctionPrototype

Structure* RequireFunctionPrototype::createStructure(
    JSC::VM& vm,
    JSC::JSGlobalObject* globalObject)
{
    auto* structure = Structure::create(vm, globalObject, globalObject->functionPrototype(), TypeInfo(ObjectType, StructureFlags), info());
    structure->setMayBePrototype(true);
    return structure;
}

Structure* RequireResolveFunctionPrototype::createStructure(
    JSC::VM& vm,
    JSC::JSGlobalObject* globalObject)
{
    auto* structure = Structure::create(vm, globalObject, globalObject->functionPrototype(), TypeInfo(ObjectType, StructureFlags), info());
    structure->setMayBePrototype(true);
    return structure;
}

RequireResolveFunctionPrototype* RequireResolveFunctionPrototype::create(JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);

    auto* structure = RequireResolveFunctionPrototype::createStructure(vm, globalObject);
    RequireResolveFunctionPrototype* prototype = new (NotNull, JSC::allocateCell<RequireResolveFunctionPrototype>(vm)) RequireResolveFunctionPrototype(vm, structure);
    prototype->finishCreation(vm);
    return prototype;
}

RequireFunctionPrototype* RequireFunctionPrototype::create(
    JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);

    auto* structure = RequireFunctionPrototype::createStructure(vm, globalObject);
    RequireFunctionPrototype* prototype = new (NotNull, JSC::allocateCell<RequireFunctionPrototype>(vm)) RequireFunctionPrototype(vm, structure);
    prototype->finishCreation(vm);

    return prototype;
}

void RequireFunctionPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));

    bunBindgenObjectSurface_RequireFunctionPrototype_install(vm, info(), *this);
}

std::optional<Bindgen::CommonJSModuleFilenameResult> Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleFilename(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleFilename_Arguments& args)
{
    auto* object = commonJSModule(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto value = object->m_filename.get();
    if (!value)
        return std::nullopt;
    Bindgen::CommonJSModuleFilenameResult result;
    if (value.isNull())
        result.set_nulled(false);
    else
        result.set_string(value);
    return result;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleId(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleId_Arguments& args)
{
    auto* object = commonJSModule(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto value = object->m_id.get();
    if (!value)
        return std::nullopt;
    return value;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModulePath(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModulePath_Arguments& args)
{
    auto* object = commonJSModule(args.bindingThis);
    if (!object) [[unlikely]]
        return std::nullopt;
    auto value = object->m_dirname.get();
    if (!value)
        return std::nullopt;
    return value;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleParent(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleParent_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject) [[unlikely]] {
        return jsUndefined();
    }

    if (thisObject->m_overriddenParent) {
        return thisObject->m_overriddenParent.get();
    }

    if (thisObject->m_parent) {
        auto* parent = thisObject->m_parent.get();
        return parent;
    }

    // initialize parent by checking if it is the main module. we do this lazily because most people
    // dont need `module.parent` and creating commonjs module records is done a ton.
    auto idValue = thisObject->m_id.get();
    if (idValue) {
        auto id = idValue->view(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        if (id == "."_s) {
            thisObject->m_overriddenParent.set(globalObject->vm(), thisObject, jsNull());
            return jsNull();
        }
    }

    return jsUndefined();
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModulePath(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModulePath_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;

    auto& vm = context.globalObject.vm();
    thisObject->m_dirname.set(vm, thisObject, jsString(vm, args.value));
    return true;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModulePaths(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModulePaths_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject) [[unlikely]] {
        return jsUndefined();
    }

    if (!thisObject->m_paths) {
        JSValue filename = thisObject->filename();
        ASSERT(filename);
        auto filenameWtfStr = filename.toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        auto pathStrings = Bun::Bindgen::ZigExports::bunBindgenZig_Path_resolverNodeModulePaths(globalObject, filenameWtfStr, true);
        RETURN_IF_EXCEPTION(scope, {});
        JSValue paths = Bun::toJSArray(globalObject, pathStrings.span());
        RETURN_IF_EXCEPTION(scope, {});
        thisObject->m_paths.set(globalObject->vm(), thisObject, paths);
        return paths;
    }

    return thisObject->m_paths.get();
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleChildren(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleChildren_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;
    {
        WTF::Locker locker { thisObject->cellLock() };
        thisObject->m_children.clear();
    }
    args.value.storeIn(context.globalObject.vm(), *thisObject, thisObject->m_childrenValue);
    return true;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleChildren(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleChildren_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* mod = commonJSModule(args.bindingThis);
    if (!mod) [[unlikely]] {
        return jsUndefined();
    }

    if (!mod->m_childrenValue) {
        auto throwScope = DECLARE_THROW_SCOPE(globalObject->vm());
        MarkedArgumentBuffer children;
        children.ensureCapacity(mod->m_children.size());

        // Deduplicate children while preserving insertion order.
        JSCommonJSModule* last = nullptr;
        int n = -1;
        for (WriteBarrier<Unknown> childBarrier : mod->m_children) {
            JSCommonJSModule* child = uncheckedDowncast<JSCommonJSModule>(childBarrier.get());
            // Check the last module since duplicate imports, if any, will
            // probably be adjacent. Then just do a linear scan.
            if (last == child) [[unlikely]]
                continue;
            int i = 0;
            while (i < n) {
                if (children.at(i).asCell() == child) [[unlikely]]
                    goto next;
                i += 1;
            }
            children.append(child);
            last = child;
            n += 1;
        next: {
        }
        }

        // Construct the array
        JSArray* array = JSC::constructArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), children);
        RETURN_IF_EXCEPTION(throwScope, {});
        mod->m_childrenValue.set(globalObject->vm(), mod, array);

        {
            WTF::Locker locker { mod->cellLock() };
            mod->m_children.clear();
        }

        return array;
    }

    return mod->m_childrenValue.get();
}

std::optional<bool> Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleLoaded(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleLoaded_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject) [[unlikely]]
        return std::nullopt;
    return thisObject->hasEvaluated;
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModulePaths(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModulePaths_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;

    args.value.storeIn(context.globalObject.vm(), *thisObject, thisObject->m_paths);
    return true;
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleFilename(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleFilename_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;

    auto& vm = context.globalObject.vm();
    thisObject->m_filename.set(vm, thisObject, jsString(vm, args.value));
    return true;
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleId(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleId_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;

    auto& vm = context.globalObject.vm();
    thisObject->m_id.set(vm, thisObject, jsString(vm, args.value));
    return true;
}
bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleParent(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleParent_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;

    if (auto* parent = commonJSModule(args.value)) {
        thisObject->m_parent = parent;
        thisObject->m_overriddenParent.clear();
    } else {
        thisObject->m_parent = {};
    }

    return true;
}
bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleLoaded(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleLoaded_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;

    thisObject->hasEvaluated = args.value;
    return true;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleCompile(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_commonJSModuleCompile_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject) [[unlikely]] {
        return jsUndefined();
    }
    if (thisObject->m_overriddenCompile) {
        return thisObject->m_overriddenCompile.get();
    }
    return defaultGlobalObject(&context.globalObject)->modulePrototypeUnderscoreCompileFunction();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_requireResolveFunction(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_requireResolveFunction_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->requireResolveFunctionUnbound();
}

bool Bindgen::Cpp::bunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleCompile(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ModuleObjectSurfaceHost_setCommonJSModuleCompile_Arguments& args)
{
    auto* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject)
        return false;
    args.value.storeIn(context.globalObject.vm(), *thisObject, thisObject->m_overriddenCompile);
    return true;
}

#define BUN_BINDGEN_OBJECT_SURFACE_JSCommonJSModulePrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSCommonJSModulePrototype

class JSCommonJSModulePrototype final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;
    static JSCommonJSModulePrototype* create(
        JSC::VM& vm,
        JSC::JSGlobalObject* globalObject,
        JSC::Structure* structure)
    {
        JSCommonJSModulePrototype* prototype = new (NotNull, JSC::allocateCell<JSCommonJSModulePrototype>(vm)) JSCommonJSModulePrototype(vm, structure);
        prototype->finishCreation(vm, globalObject);
        return prototype;
    }

    static JSC::Structure* createStructure(
        JSC::VM& vm,
        JSC::JSGlobalObject* globalObject,
        JSC::JSValue prototype)
    {
        auto* structure = JSC::Structure::create(vm, globalObject, prototype, TypeInfo(JSC::ObjectType, StructureFlags), info());
        structure->setMayBePrototype(true);
        return structure;
    }

    DECLARE_INFO;

    JSCommonJSModulePrototype(
        JSC::VM& vm,
        JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSCommonJSModulePrototype, Base);
        return &vm.plainObjectSpace();
    }

    void finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        bunBindgenObjectSurface_JSCommonJSModulePrototype_install(vm, info(), *this);
    }
};

const JSC::ClassInfo JSCommonJSModulePrototype::s_info = { "Module"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSCommonJSModulePrototype) };

void JSCommonJSModule::finishCreation(JSC::VM& vm, const JSC::SourceCode& sourceCode)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    this->sourceCode = sourceCode;
}

JSC::Structure* JSCommonJSModule::createStructure(
    JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);

    auto* prototype = JSCommonJSModulePrototype::create(vm, globalObject, JSCommonJSModulePrototype::createStructure(vm, globalObject, globalObject->objectPrototype()));

    // Do not set the number of inline properties on this structure
    // there may be an off-by-one error in the Structure which causes `require.id` to become the require
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info(), NonArray);
}

JSCommonJSModule* JSCommonJSModule::create(
    JSC::VM& vm,
    JSC::Structure* structure,
    JSC::JSString* id,
    JSValue filename,
    JSC::JSString* dirname,
    const JSC::SourceCode& sourceCode)
{
    JSCommonJSModule* cell = new (NotNull, JSC::allocateCell<JSCommonJSModule>(vm)) JSCommonJSModule(vm, structure, id, filename, dirname);
    cell->finishCreation(vm, sourceCode);
    return cell;
}

static JSCommonJSModule* createCommonJSModule(
    JSGlobalObject* globalObject,
    const Bun::Bindgen::Cpp::BunBindgenCpp_RuntimeFunctions_jsFunctionCreateCommonJSModule_Arguments& args)
{
    JSValue parent = jsUndefined();
    if (args.parent.is_module())
        parent = args.parent.module();
    else if (args.parent.is_overridden())
        parent = args.parent.overridden();

    return JSCommonJSModule::create(
        uncheckedDowncast<Zig::GlobalObject>(globalObject),
        jsString(globalObject->vm(), args.id),
        args.exports,
        args.hasEvaluated,
        parent);
}

JSCommonJSModule* JSCommonJSModule::create(
    Zig::GlobalObject* globalObject,
    JSC::JSString* requireMapKey,
    JSValue exportsObject,
    bool hasEvaluated,
    JSValue parent)
{
    auto& vm = JSC::getVM(globalObject);
    auto key = requireMapKey->value(globalObject);
    auto index = key->reverseFind(PLATFORM_SEP, key->length());

    JSString* dirname;
    if (index != WTF::notFound) {
        dirname = JSC::jsSubstring(globalObject, requireMapKey, 0, index);
    } else {
        dirname = jsEmptyString(vm);
    }

    auto* out = JSCommonJSModule::create(
        vm,
        globalObject->CommonJSModuleObjectStructure(),
        requireMapKey, requireMapKey, dirname, SourceCode());

    out->putDirect(
        vm,
        WebCore::clientData(vm)->builtinNames().exportsPublicName(),
        exportsObject,
        0);
    out->hasEvaluated = hasEvaluated;
    if (parent && parent.isCell()) {
        if (auto* parentModule = dynamicDowncast<JSCommonJSModule>(parent)) {
            out->m_parent = JSC::Weak<JSCommonJSModule>(parentModule);
        } else {
            out->m_overriddenParent.set(vm, out, parent);
        }
    } else if (parent) {
        out->m_overriddenParent.set(vm, out, parent);
    }

    return out;
}

JSCommonJSModule* JSCommonJSModule::create(
    Zig::GlobalObject* globalObject,
    const WTF::String& key,
    JSValue exportsObject,
    bool hasEvaluated,
    JSValue parent)
{
    auto& vm = JSC::getVM(globalObject);
    auto* requireMapKey = JSC::jsStringWithCache(vm, key);
    return JSCommonJSModule::create(globalObject, requireMapKey, exportsObject, hasEvaluated, parent);
}

size_t JSCommonJSModule::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
{
    auto* thisObject = uncheckedDowncast<JSCommonJSModule>(cell);
    size_t additionalSize = 0;
    if (!thisObject->sourceCode.isNull() && !thisObject->sourceCode.view().isEmpty()) {
        additionalSize += thisObject->sourceCode.view().length();
        if (!thisObject->sourceCode.view().is8Bit()) {
            additionalSize *= 2;
        }
    }
    return Base::estimatedSize(cell, vm) + additionalSize;
}

void JSCommonJSModule::destroy(JSC::JSCell* cell)
{
    static_cast<JSCommonJSModule*>(cell)->JSCommonJSModule::~JSCommonJSModule();
}

JSCommonJSModule::~JSCommonJSModule()
{
}

void populateESMExports(
    JSC::JSGlobalObject* globalObject,
    JSValue result,
    Vector<JSC::Identifier, 4>& exportNames,
    JSC::MarkedArgumentBuffer& exportValues,
    bool ignoreESModuleAnnotation)
{
    auto& vm = JSC::getVM(globalObject);
    const Identifier& esModuleMarker = vm.propertyNames->__esModule;

    // Bun's interpretation of the "__esModule" annotation:
    //
    //   - If a "default" export does not exist OR the __esModule annotation is not present, then we
    //   set the default export to the exports object
    //
    //   - If a "default" export also exists, then we set the default export
    //   to the value of it (matching Babel behavior)
    //
    // https://stackoverflow.com/questions/50943704/whats-the-purpose-of-object-definepropertyexports-esmodule-value-0
    // https://github.com/nodejs/node/issues/40891
    // https://github.com/evanw/bundler-esm-cjs-tests
    // https://github.com/evanw/esbuild/issues/1591
    // https://github.com/oven-sh/bun/issues/3383
    //
    // Note that this interpretation is slightly different
    //
    //    -  We do not ignore when "type": "module" or when the file
    //       extension is ".mjs". Build tools determine that based on the
    //       caller's behavior, but in a JS runtime, there is only one ModuleNamespaceObject.
    //
    //       It would be possible to match the behavior at runtime, but
    //       it would need further engine changes which do not match the ES Module spec
    //
    //   -   We ignore the value of the annotation. We only look for the
    //       existence of the value being set. This is for performance reasons, but also
    //       this annotation is meant for tooling and the only usages of setting
    //       it to something that does NOT evaluate to "true" I could find were in
    //       unit tests of build tools. Happy to revisit this if users file an issue.
    bool needsToAssignDefault = true;
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto* exports = result.getObject()) {
        bool hasESModuleMarker = false;
        if (!ignoreESModuleAnnotation) {
            PropertySlot slot(exports, PropertySlot::InternalMethodType::VMInquiry, &vm);
            auto has = exports->getPropertySlot(globalObject, esModuleMarker, slot);
            scope.assertNoException();
            if (has) {
                JSValue value = slot.getValue(globalObject, esModuleMarker);
                (void)scope.tryClearException();
                if (!value.isUndefinedOrNull()) {
                    if (value.pureToBoolean() == TriState::True) {
                        hasESModuleMarker = true;
                    }
                }
            }
        }

        auto* structure = exports->structure();

        uint32_t size = structure->inlineSize() + structure->outOfLineSize();
        exportNames.reserveCapacity(size + 2);
        exportValues.ensureCapacity(size + 2);

        (void)scope.tryClearException();

        if (hasESModuleMarker) {
            if (canPerformFastEnumeration(structure)) {
                exports->structure()->forEachProperty(vm, [&](const PropertyTableEntry& entry) -> bool {
                    auto key = entry.key();
                    if (key->isSymbol() || key == esModuleMarker)
                        return true;

                    needsToAssignDefault = needsToAssignDefault && key != vm.propertyNames->defaultKeyword;

                    JSValue value = exports->getDirect(entry.offset());

                    exportNames.append(Identifier::fromUid(vm, key));
                    exportValues.append(value);
                    return true;
                });
            } else {
                JSC::PropertyNameArrayBuilder properties(vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
                exports->methodTable()->getOwnPropertyNames(exports, globalObject, properties, DontEnumPropertiesMode::Exclude);
                if (scope.exception()) [[unlikely]] {
                    if (!vm.hasPendingTerminationException()) (void)scope.tryClearException();
                    return;
                }

                for (auto property : properties) {
                    if (property.isEmpty() || property.isNull() || property == esModuleMarker || property.isPrivateName() || property.isSymbol()) [[unlikely]]
                        continue;

                    // ignore constructor
                    if (property == vm.propertyNames->constructor)
                        continue;

                    JSC::PropertySlot slot(exports, PropertySlot::InternalMethodType::Get);
                    auto has = exports->getPropertySlot(globalObject, property, slot);
                    RETURN_IF_EXCEPTION(scope, );
                    if (!has) continue;

                    // Allow DontEnum properties which are not getter/setters
                    // https://github.com/oven-sh/bun/issues/4432
                    if (slot.attributes() & PropertyAttribute::DontEnum) {
                        if (!(slot.isValue() || slot.isCustom())) {
                            continue;
                        }
                    }

                    exportNames.append(property);

                    JSValue getterResult = slot.getValue(globalObject, property);

                    // If it throws, we keep them in the exports list, but mark it as undefined
                    // This is consistent with what Node.js does.
                    if (scope.exception()) [[unlikely]] {
                        (void)scope.tryClearException();
                        getterResult = jsUndefined();
                    }

                    exportValues.append(getterResult);

                    needsToAssignDefault = needsToAssignDefault && property != vm.propertyNames->defaultKeyword;
                }
            }

        } else if (canPerformFastEnumeration(structure)) {
            exports->structure()->forEachProperty(vm, [&](const PropertyTableEntry& entry) -> bool {
                auto key = entry.key();
                if (key->isSymbol() || key == vm.propertyNames->defaultKeyword)
                    return true;

                JSValue value = exports->getDirect(entry.offset());

                exportNames.append(Identifier::fromUid(vm, key));
                exportValues.append(value);
                return true;
            });
        } else {
            JSC::PropertyNameArrayBuilder properties(vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
            exports->methodTable()->getOwnPropertyNames(exports, globalObject, properties, DontEnumPropertiesMode::Include);
            if (scope.exception()) [[unlikely]] {
                if (!vm.hasPendingTerminationException()) (void)scope.tryClearException();
                return;
            }

            for (auto property : properties) {
                if (property.isEmpty() || property.isNull() || property == vm.propertyNames->defaultKeyword || property.isPrivateName() || property.isSymbol()) [[unlikely]]
                    continue;

                // ignore constructor
                if (property == vm.propertyNames->constructor)
                    continue;

                JSC::PropertySlot slot(exports, PropertySlot::InternalMethodType::Get);
                auto has = exports->getPropertySlot(globalObject, property, slot);
                RETURN_IF_EXCEPTION(scope, );
                if (!has) continue;

                if (slot.attributes() & PropertyAttribute::DontEnum) {
                    // Allow DontEnum properties which are not getter/setters
                    // https://github.com/oven-sh/bun/issues/4432
                    if (!(slot.isValue() || slot.isCustom())) {
                        continue;
                    }
                }

                exportNames.append(property);

                JSValue getterResult = slot.getValue(globalObject, property);

                // If it throws, we keep them in the exports list, but mark it as undefined
                // This is consistent with what Node.js does.
                if (scope.exception()) [[unlikely]] {
                    (void)scope.tryClearException();
                    getterResult = jsUndefined();
                }

                exportValues.append(getterResult);
            }
        }
    }

    if (needsToAssignDefault) {
        exportNames.append(vm.propertyNames->defaultKeyword);
        exportValues.append(result);
    }
}

void JSCommonJSModule::toSyntheticSource(JSC::JSGlobalObject* globalObject,
    const JSC::Identifier& moduleKey,
    Vector<JSC::Identifier, 4>& exportNames,
    JSC::MarkedArgumentBuffer& exportValues)
{
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(globalObject));
    auto result = this->exportsObject();
    RETURN_IF_EXCEPTION(scope, );

    RELEASE_AND_RETURN(scope, populateESMExports(globalObject, result, exportNames, exportValues, this->ignoreESModuleAnnotation));
}

void JSCommonJSModule::setExportsObject(JSC::JSValue exportsObject)
{
    this->putDirect(vm(), JSC::PropertyName(clientData(vm())->builtinNames().exportsPublicName()), exportsObject, 0);
}

Structure* createCommonJSModuleStructure(
    Zig::GlobalObject* globalObject)
{
    return JSCommonJSModule::createStructure(globalObject);
}

template<typename Visitor>
void JSCommonJSModule::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSCommonJSModule* thisObject = uncheckedDowncast<JSCommonJSModule>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);

    // Use appendHidden so it doesn't show up in the heap snapshot twice.
    visitor.appendHidden(thisObject->m_id);
    visitor.appendHidden(thisObject->m_filename);
    visitor.appendHidden(thisObject->m_dirname);
    visitor.appendHidden(thisObject->m_paths);
    visitor.appendHidden(thisObject->m_overriddenParent);
    visitor.appendHidden(thisObject->m_overriddenCompile);
    visitor.appendHidden(thisObject->m_childrenValue);
    {
        WTF::Locker locker { thisObject->cellLock() };
        visitor.appendValues(thisObject->m_children.begin(), thisObject->m_children.size());
    }
}

DEFINE_VISIT_CHILDREN(JSCommonJSModule);

void JSCommonJSModule::analyzeHeap(JSCell* cell, HeapAnalyzer& analyzer)
{
    auto* thisObject = uncheckedDowncast<JSCommonJSModule>(cell);

    analyzer.setLabelForCell(cell, "Module (CommonJS)"_s);

    Base::analyzeHeap(cell, analyzer);
    auto& vm = cell->vm();
    auto& builtinNames = Bun::builtinNames(vm);
    if (auto* id = thisObject->m_id.get()) {
        analyzer.analyzePropertyNameEdge(cell, id, vm.propertyNames->id.impl());
    }

    if (thisObject->m_filename) {
        JSValue filename = thisObject->m_filename.get();
        if (filename.isCell()) {
            analyzer.analyzePropertyNameEdge(cell, filename.asCell(), builtinNames.filenamePublicName().impl());
        }
    }

    if (thisObject->m_dirname) {
        JSValue dirname = thisObject->m_dirname.get();
        if (dirname.isCell()) {
            analyzer.analyzePropertyNameEdge(cell, dirname.asCell(), builtinNames.dirnamePublicName().impl());
        }
    }

    if (thisObject->m_paths) {
        JSValue paths = thisObject->m_paths.get();
        if (paths.isCell()) {
            analyzer.analyzePropertyNameEdge(cell, paths.asCell(), builtinNames.pathsPublicName().impl());
        }
    }

    if (thisObject->m_overriddenParent) {
        JSValue overriddenParent = thisObject->m_overriddenParent.get();
        if (overriddenParent.isCell()) {
            const Identifier overriddenParentIdentifier = Identifier::fromString(vm, "parent"_s);
            analyzer.analyzePropertyNameEdge(cell, overriddenParent.asCell(), overriddenParentIdentifier.impl());
        }
    }
}

const JSC::ClassInfo JSCommonJSModule::s_info = { "Module"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSCommonJSModule) };
const JSC::ClassInfo RequireResolveFunctionPrototype::s_info = { "resolve"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(RequireResolveFunctionPrototype) };
const JSC::ClassInfo RequireFunctionPrototype::s_info = { "require"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(RequireFunctionPrototype) };

ALWAYS_INLINE JSValue finishRequireWithError(Zig::GlobalObject* globalObject, JSC::ThrowScope& throwScope, JSC::JSValue specifierValue)
{
    JSC::JSValue exception = throwScope.exception();
    ASSERT(exception);
    (void)throwScope.tryClearException();

    // On error, remove the module from the require map/
    // so that it can be re-evaluated on the next require.
    bool wasRemoved = globalObject->requireMap()->remove(globalObject, specifierValue);
    ASSERT(wasRemoved);

    throwScope.throwException(globalObject, exception);
    RELEASE_AND_RETURN(throwScope, {});
}

// JSCommonJSModule.$require(resolvedId, newModule, userArgumentCount, userOptions)

void RequireResolveFunctionPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));

    bunBindgenObjectSurface_RequireResolveFunctionPrototype_install(vm, info(), *this);
}

void JSCommonJSModule::evaluate(
    Zig::GlobalObject* globalObject,
    const WTF::String& key,
    ResolvedSource& source,
    bool isBuiltIn)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (globalObject->hasOverriddenModuleWrapper) [[unlikely]] {
        auto string = source.sourceCode;
        auto trimStart = string.find('\n');
        if (trimStart != WTF::notFound) {
            auto wrapperStart = globalObject->m_moduleWrapperStart;
            auto wrapperEnd = globalObject->m_moduleWrapperEnd;
            source.sourceCode = makeString(
                wrapperStart,
                string.substring(trimStart, string.length() - trimStart - 4),
                wrapperEnd);
        }
    }

    const bool ignoreESModuleAnnotation = resolvedSourceHasKind(source, Bindgen::ResolvedSourceKind::package_json_type_module);
    auto sourceProvider = Zig::SourceProvider::create(globalObject, WTF::move(source), JSC::SourceProviderSourceType::Program, isBuiltIn);
    RETURN_IF_EXCEPTION(scope, );
    this->ignoreESModuleAnnotation = ignoreESModuleAnnotation;
    if (!isBuiltIn && !globalObject->hasOverriddenModuleWrapper && Bun::IsolatedModuleCache::canUse(vm, globalObject->bunVM())) {
        Bun::IsolatedModuleCache::insert(vm, key, *sourceProvider);
    }
    if (this->hasEvaluated)
        return;

    this->sourceCode = JSC::SourceCode(sourceProvider.releaseNonNull());

    scope.release();
    evaluateCommonJSModuleOnce(vm, globalObject, this, this->m_dirname.get(), this->m_filename.get());
}

void JSCommonJSModule::evaluate(
    Zig::GlobalObject* globalObject,
    Ref<JSC::SourceProvider>&& sourceProvider,
    bool ignoreESModuleAnnotation)
{
    auto& vm = JSC::getVM(globalObject);
    this->ignoreESModuleAnnotation = ignoreESModuleAnnotation;
    if (this->hasEvaluated)
        return;
    this->sourceCode = JSC::SourceCode(WTF::move(sourceProvider));
    evaluateCommonJSModuleOnce(vm, globalObject, this, this->m_dirname.get(), this->m_filename.get());
}

void JSCommonJSModule::evaluateWithPotentiallyOverriddenCompile(
    Zig::GlobalObject* globalObject,
    const WTF::String& key,
    JSValue keyJSString,
    ResolvedSource& source)
{
    if (JSValue compileFunction = this->m_overriddenCompile.get()) {
        auto& vm = globalObject->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!compileFunction) {
            throwTypeError(globalObject, scope, "overridden module._compile is not a function (called from overridden Module._extensions)"_s);
            return;
        }
        JSC::CallData callData = JSC::getCallData(compileFunction.asCell());
        if (callData.type == JSC::CallData::Type::None) {
            throwTypeError(globalObject, scope, "overridden module._compile is not a function (called from overridden Module._extensions)"_s);
            return;
        }
        WTF::String sourceString = source.sourceCode;
        RETURN_IF_EXCEPTION(scope, );
        // Remove the wrapper from the source string, since the transpiler has added it.
        auto trimStart = sourceString.find('\n');
        WTF::String sourceStringWithoutWrapper;
        if (trimStart != WTF::notFound) {
            auto wrapperStart = globalObject->m_moduleWrapperStart;
            auto wrapperEnd = globalObject->m_moduleWrapperEnd;
            sourceStringWithoutWrapper = sourceString.substring(trimStart, sourceString.length() - trimStart - 4);
        } else {
            sourceStringWithoutWrapper = sourceString;
        }
        RETURN_IF_EXCEPTION(scope, );

        // _compile(source, filename)
        MarkedArgumentBuffer arguments;
        arguments.append(jsString(vm, sourceStringWithoutWrapper));
        arguments.append(keyJSString);
        JSC::profiledCall(globalObject, ProfilingReason::API, compileFunction, callData, this, arguments);
        RETURN_IF_EXCEPTION(scope, );
        return;
    }
    this->evaluate(globalObject, key, source, false);
}

static JSC::SourceCode commonJSModuleSyntheticSourceCode(const SourceOrigin& sourceOrigin, const WTF::String& sourceURL);

std::optional<JSC::SourceCode> createCommonJSModule(
    Zig::GlobalObject* globalObject,
    JSString* requireMapKey,
    ResolvedSource& source,
    bool isBuiltIn)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSCommonJSModule* moduleObject = nullptr;
    WTF::String sourceURL = source.sourceURL;

    JSValue entry = globalObject->requireMap()->get(globalObject, requireMapKey);
    RETURN_IF_EXCEPTION(scope, {});
    bool ignoreESModuleAnnotation = resolvedSourceHasKind(source, Bindgen::ResolvedSourceKind::package_json_type_module);
    SourceOrigin sourceOrigin;

    if (entry) {
        moduleObject = dynamicDowncast<JSCommonJSModule>(entry);
    }

    if (!moduleObject) {
        size_t index = sourceURL.reverseFind(PLATFORM_SEP, sourceURL.length());
        JSString* dirname;
        JSString* filename = requireMapKey;
        if (index != WTF::notFound) {
            dirname = JSC::jsSubstring(globalObject, requireMapKey, 0, index);
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            dirname = jsEmptyString(vm);
        }
        auto requireMap = globalObject->requireMap();
        if (requireMap->size() == 0) {
            requireMapKey = JSC::jsString(vm, WTF::String("."_s));
        }

        if (globalObject->hasOverriddenModuleWrapper) [[unlikely]] {
            source.sourceCode = makeString(
                globalObject->m_moduleWrapperStart,
                source.sourceCode,
                globalObject->m_moduleWrapperEnd);
        }

        auto sourceProvider = Zig::SourceProvider::create(globalObject, WTF::move(source), JSC::SourceProviderSourceType::Program, isBuiltIn);
        RETURN_IF_EXCEPTION(scope, {});
        if (!isBuiltIn && !globalObject->hasOverriddenModuleWrapper && Bun::IsolatedModuleCache::canUse(vm, globalObject->bunVM())) {
            Bun::IsolatedModuleCache::insert(vm, sourceURL, *sourceProvider);
        }
        sourceOrigin = sourceProvider->sourceOrigin();
        moduleObject = JSCommonJSModule::create(
            vm,
            globalObject->CommonJSModuleObjectStructure(),
            requireMapKey, filename, dirname, JSC::SourceCode(sourceProvider.releaseNonNull()));

        moduleObject->putDirect(vm,
            WebCore::clientData(vm)->builtinNames().exportsPublicName(),
            JSC::constructEmptyObject(globalObject, globalObject->objectPrototype()), 0);

        requireMap->set(globalObject, filename, moduleObject);
        RETURN_IF_EXCEPTION(scope, {});
    } else {
        sourceOrigin = Zig::toSourceOrigin(sourceURL, isBuiltIn);
    }

    moduleObject->ignoreESModuleAnnotation = ignoreESModuleAnnotation;

    return commonJSModuleSyntheticSourceCode(sourceOrigin, sourceURL);
}

static JSC::SourceCode commonJSModuleSyntheticSourceCode(const SourceOrigin& sourceOrigin, const WTF::String& sourceURL)
{
    return JSC::SourceCode(
        JSC::SyntheticSourceProvider::create(
            [](JSC::JSGlobalObject* lexicalGlobalObject,
                const JSC::Identifier& moduleKey,
                Vector<JSC::Identifier, 4>& exportNames,
                JSC::MarkedArgumentBuffer& exportValues) -> void {
                auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
                auto& vm = JSC::getVM(globalObject);
                auto scope = DECLARE_THROW_SCOPE(vm);

                JSValue keyValue = identifierToJSValue(vm, moduleKey);
                JSValue entry = globalObject->requireMap()->get(globalObject, keyValue);
                RETURN_IF_EXCEPTION(scope, );

                if (entry) {
                    if (auto* moduleObject = dynamicDowncast<JSCommonJSModule>(entry)) {
                        if (!moduleObject->hasEvaluated) {
                            evaluateCommonJSModuleOnce(
                                vm,
                                globalObject,
                                moduleObject,
                                moduleObject->m_dirname.get(),
                                moduleObject->m_filename.get());
                            if (auto exception = scope.exception()) {
                                (void)scope.tryClearException();

                                // On error, remove the module from the require map
                                // so that it can be re-evaluated on the next require.
                                globalObject->requireMap()->remove(globalObject, moduleObject->filename());
                                RETURN_IF_EXCEPTION(scope, );

                                scope.throwException(globalObject, exception);
                                return;
                            }
                        }

                        moduleObject->toSyntheticSource(globalObject, moduleKey, exportNames, exportValues);
                        RETURN_IF_EXCEPTION(scope, );
                    }
                } else {
                    // require map was cleared of the entry
                }
            },
            sourceOrigin,
            sourceURL));
}

std::optional<JSC::SourceCode> createCommonJSModule(
    Zig::GlobalObject* globalObject,
    JSC::JSString* requireMapKey,
    Ref<JSC::SourceProvider>&& sourceProvider,
    bool ignoreESModuleAnnotation)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSCommonJSModule* moduleObject = nullptr;
    WTF::String sourceURL = sourceProvider->sourceURL();
    SourceOrigin sourceOrigin = sourceProvider->sourceOrigin();

    JSValue entry = globalObject->requireMap()->get(globalObject, requireMapKey);
    RETURN_IF_EXCEPTION(scope, {});

    if (entry) {
        moduleObject = dynamicDowncast<JSCommonJSModule>(entry);
    }

    if (!moduleObject) {
        size_t index = sourceURL.reverseFind(PLATFORM_SEP, sourceURL.length());
        JSString* dirname;
        JSString* filename = requireMapKey;
        if (index != WTF::notFound) {
            dirname = JSC::jsSubstring(globalObject, requireMapKey, 0, index);
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            dirname = jsEmptyString(vm);
        }
        auto requireMap = globalObject->requireMap();
        if (requireMap->size() == 0) {
            requireMapKey = JSC::jsString(vm, WTF::String("."_s));
        }

        moduleObject = JSCommonJSModule::create(
            vm,
            globalObject->CommonJSModuleObjectStructure(),
            requireMapKey, filename, dirname, JSC::SourceCode(WTF::move(sourceProvider)));

        moduleObject->putDirect(vm,
            WebCore::clientData(vm)->builtinNames().exportsPublicName(),
            JSC::constructEmptyObject(globalObject, globalObject->objectPrototype()), 0);

        requireMap->set(globalObject, filename, moduleObject);
        RETURN_IF_EXCEPTION(scope, {});
    }

    moduleObject->ignoreESModuleAnnotation = ignoreESModuleAnnotation;

    return commonJSModuleSyntheticSourceCode(sourceOrigin, sourceURL);
}

JSObject* JSCommonJSModule::createBoundRequireFunction(VM& vm, JSGlobalObject* lexicalGlobalObject, const WTF::String& pathString)
{
    ASSERT(!pathString.startsWith("file://"_s));

    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSString* filename = JSC::jsStringWithCache(vm, pathString);
    auto index = pathString.reverseFind(PLATFORM_SEP, pathString.length());
    JSString* dirname;
    if (index != WTF::notFound) {
        dirname = JSC::jsSubstring(globalObject, filename, 0, index);
        RETURN_IF_EXCEPTION(scope, nullptr);
    } else {
        dirname = jsEmptyString(vm);
    }

    auto moduleObject = Bun::JSCommonJSModule::create(
        vm,
        globalObject->CommonJSModuleObjectStructure(),
        filename, filename, dirname, SourceCode());

    SourceCode requireSourceCode = makeSource("require"_s, SourceOrigin(), SourceTaintedOrigin::Untainted);

    JSFunction* requireFunction = JSC::JSBoundFunction::create(vm,
        globalObject,
        globalObject->requireFunctionUnbound(),
        moduleObject,
        ArgList(), 1, globalObject->commonStrings().requireString(globalObject), requireSourceCode);
    RETURN_IF_EXCEPTION(scope, nullptr);

    SourceCode resolveSourceCode = makeSource("resolve"_s, SourceOrigin(), SourceTaintedOrigin::Untainted);

    JSFunction* resolveFunction = JSC::JSBoundFunction::create(vm,
        globalObject,
        globalObject->requireResolveFunctionUnbound(),
        moduleObject->filename(),
        ArgList(), 1, globalObject->commonStrings().resolveString(globalObject), resolveSourceCode);
    RETURN_IF_EXCEPTION(scope, nullptr);

    requireFunction->putDirect(vm, vm.propertyNames->resolve, resolveFunction, 0);

    return requireFunction;
}

} // namespace Bun

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionEvaluateCommonJSModule(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionEvaluateCommonJSModule_Arguments& args)
{
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    JSCommonJSModule* moduleObject = commonJSModule(args.module);
    JSCommonJSModule* referrer = commonJSModule(args.referrer);
    if (!moduleObject) [[unlikely]] {
        RELEASE_AND_RETURN(throwScope, jsUndefined());
    }

    JSValue returnValue = jsNull();
    if (referrer) [[likely]] {
        if (referrer->m_childrenValue) [[unlikely]] {
            // It's too hard to append from native code:
            // referrer.children.indexOf(moduleObject) === -1 && referrer.children.push(moduleObject)
            returnValue = referrer->m_childrenValue.get();
        } else {
            WTF::Locker locker { referrer->cellLock() };
            referrer->m_children.append(WriteBarrier<Unknown>());
            referrer->m_children.last().set(vm, referrer, moduleObject);
        }
    }

    moduleObject->load(vm, globalObject);
    RETURN_IF_EXCEPTION(throwScope, {});

    RELEASE_AND_RETURN(throwScope, returnValue);
}

std::optional<WTF::Vector<WTF::String>> Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_requireResolvePathsFunction(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_requireResolvePathsFunction_Arguments& args)
{
    return Bun::requireResolvePaths(&context.globalObject, args);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_functionJSCommonJSModule_compile(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_functionJSCommonJSModule_compile_Arguments& args)
{
    JSGlobalObject* globalObject = &context.globalObject;
    auto* moduleObject = commonJSModule(args.bindingThis);
    if (!moduleObject) {
        return;
    }

    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    const auto* sourceString = args.source.convert();
    RETURN_IF_EXCEPTION(throwScope, void());
    if (!sourceString)
        return;

    const auto* filenameString = args.filename.convert();
    RETURN_IF_EXCEPTION(throwScope, void());
    if (!filenameString)
        return;

    String wrappedString;
    auto* zigGlobalObject = uncheckedDowncast<Zig::GlobalObject>(globalObject);
    if (zigGlobalObject->hasOverriddenModuleWrapper) [[unlikely]] {
        wrappedString = makeString(
            zigGlobalObject->m_moduleWrapperStart,
            *sourceString,
            zigGlobalObject->m_moduleWrapperEnd);
    } else {
        wrappedString = makeString(
            "(function(exports,require,module,__filename,__dirname){"_s,
            *sourceString,
            "\n})"_s);
    }

    moduleObject->sourceCode = makeSource(
        WTF::move(wrappedString),
        SourceOrigin(URL::fileURLWithFileSystemPath(*filenameString)),
        JSC::SourceTaintedOrigin::Untainted,
        *filenameString,
        WTF::TextPosition(),
        JSC::SourceProviderSourceType::Program);

#if OS(WINDOWS)
    String dirnameString = Bun::Bindgen::ZigExports::bunBindgenZig_Path_dirnameWindows(globalObject, *filenameString);
#else
    String dirnameString = Bun::Bindgen::ZigExports::bunBindgenZig_Path_dirnamePosix(globalObject, *filenameString);
#endif
    RETURN_IF_EXCEPTION(throwScope, void());

    evaluateCommonJSModuleOnce(
        vm,
        uncheckedDowncast<Zig::GlobalObject>(globalObject),
        moduleObject,
        jsString(vm, dirnameString),
        jsString(vm, *filenameString));
    RETURN_IF_EXCEPTION(throwScope, void());
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionCreateCommonJSModule(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionCreateCommonJSModule_Arguments& args)
{
    return Bun::createCommonJSModule(&context.globalObject, args);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionRequireCommonJS(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionRequireCommonJS_Arguments& args)
{
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    JSCommonJSModule* referrerModule = commonJSModule(args.bindingThis);
    if (!referrerModule) {
        throwVMTypeError(globalObject, throwScope);
        return {};
    }
    const WTF::String& specifier = args.specifier;
    JSValue specifierValue = jsString(vm, specifier);
    // If this.filename is overridden, this could cause this to be a non-string
    WTF::String referrer = referrerModule->filename().toWTFString(globalObject);
    if (throwScope.exception()) [[unlikely]]
        return finishRequireWithError(globalObject, throwScope, specifierValue);

    // This is always a new JSCommonJSModule object; cast cannot fail.
    JSCommonJSModule* child = commonJSModule(args.child);
    RELEASE_ASSERT(child);

    std::optional<WTF::String> typeAttribute;

    // We need to be able to wire in the "type" import attribute from bundled code..
    // So we do it via CommonJS require().
    // $argumentCount() always returns a Int32 JSValue
    int32_t userArgumentCount = args.userArgumentCount;
    // If they called require(id), skip the check for the type attribute
    if (userArgumentCount >= 2) [[unlikely]] {
        const auto* typeInput = args.options.convert();
        if (throwScope.exception()) [[unlikely]]
            return finishRequireWithError(globalObject, throwScope, specifierValue);
        if (!typeInput)
            return {};
        if (typeInput->is_options() && typeInput->options().type) {
            typeAttribute = *typeInput->options().type;
        }
    }

    // Load the module
    JSValue fetchResult = Bun::fetchCommonJSModule(
        globalObject,
        child,
        specifierValue,
        specifier,
        referrer,
        typeAttribute);
    if (throwScope.exception()) [[unlikely]]
        return finishRequireWithError(globalObject, throwScope, specifierValue);
    RELEASE_AND_RETURN(throwScope, fetchResult);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionRequireNativeModule(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionRequireNativeModule_Arguments& args)
{
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    JSCommonJSModule* thisObject = commonJSModule(args.bindingThis);
    if (!thisObject) {
        throwVMTypeError(globalObject, throwScope);
        return {};
    }

    const auto* specifier = args.specifier.convert();
    RETURN_IF_EXCEPTION(throwScope, {});
    if (!specifier)
        return {};
    ResolvedSourceResult res {};
    auto result = fetchBuiltinModuleWithoutResolution(globalObject, *specifier, res);
    RETURN_IF_EXCEPTION(throwScope, {});
    if (result) {
        if (res.tag() != ResolvedSourceResult::Tag::none)
            return result;
    }
    throwScope.assertNoExceptionExceptTermination();
    {
        throwVMError(globalObject, throwScope, "Failed to fetch builtin module"_s);
        return {};
    }
}
