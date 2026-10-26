#include "root.h"

#include <JavaScriptCore/JSCell.h>
#include <JavaScriptCore/Structure.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/Symbol.h>
#include <JavaScriptCore/SymbolTable.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/LazyClassStructure.h>
#include "JSBakeResponse.h"
#include "ZigGlobalObject.h"
#include "SchemaBindings.h"
#include <wtf/Scope.h>

namespace Bun {

static bool validateBakeResponseStreamingMode(JSC::JSGlobalObject* globalObject, ASCIILiteral displayFunction)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = static_cast<Zig::GlobalObject*>(globalObject);
    auto* asyncLocalStorage = zigGlobal->bakeAdditions().getAsyncLocalStorage();
    if (!asyncLocalStorage)
        return false;

    auto getStore = asyncLocalStorage->getIfPropertyExists(globalObject, JSC::Identifier::fromString(vm, "getStore"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (!getStore) {
        JSC::throwTypeError(globalObject, scope, "store value must have a \"getStore\" field"_s);
        return false;
    }

    auto callData = JSC::getCallData(getStore);
    if (callData.type == JSC::CallData::Type::None) {
        JSC::throwTypeError(globalObject, scope, "\"getStore\" must be a function"_s);
        return false;
    }

    JSC::MarkedArgumentBuffer arguments;
    auto store = JSC::call(globalObject, getStore, callData, asyncLocalStorage, arguments);
    RETURN_IF_EXCEPTION(scope, false);
    if (!store.isObject()) {
        JSC::throwTypeError(globalObject, scope, "store value must be an object"_s);
        return false;
    }

    auto streaming = store.getObject()->getIfPropertyExists(globalObject, JSC::Identifier::fromString(vm, "streaming"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (!streaming) {
        JSC::throwTypeError(globalObject, scope, "store value must have a \"streaming\" field"_s);
        return false;
    }
    if (!streaming.isBoolean()) {
        JSC::throwTypeError(globalObject, scope, "\"streaming\" field must be a boolean"_s);
        return false;
    }
    if (streaming.asBoolean()) {
        JSC::throwTypeError(globalObject, scope, makeString('"', displayFunction, "\" is not available when `export const streaming = true`"_s));
        return false;
    }

    return true;
}

void Bindgen::Engine::releaseBakeResponseNativeResponse(BunBindgen_Response_Response_Native* response)
{
    Bindgen::ZigExports::bunBindgenZig_BakeResponse_releaseNativeResponse(response);
}

static bool isJSXElement(JSC::JSValue value, JSC::JSGlobalObject* globalObject)
{

    auto* zigGlobal = static_cast<Zig::GlobalObject*>(globalObject);
    auto& vm = JSC::getVM(globalObject);

    // React does this:
    // export const REACT_LEGACY_ELEMENT_TYPE: symbol = Symbol.for('react.element');
    // export const REACT_ELEMENT_TYPE: symbol = renameElementSymbol
    //   ? Symbol.for('react.transitional.element')
    //   : REACT_LEGACY_ELEMENT_TYPE;

    // TODO: primitive values (strings, numbers, booleans, null, undefined) are also valid
    if (value.isObject()) {
        auto scope = DECLARE_THROW_SCOPE(vm);

        JSC::JSObject* object = value.getObject();
        auto typeofProperty = JSC::Identifier::fromString(vm, "$$typeof"_s);
        JSC::JSValue typeofValue = object->get(globalObject, typeofProperty);
        RETURN_IF_EXCEPTION(scope, false);

        if (typeofValue.isSymbol() && (typeofValue == zigGlobal->bakeAdditions().reactLegacyElementSymbol(zigGlobal) || typeofValue == zigGlobal->bakeAdditions().reactElementSymbol(zigGlobal))) {
            return true;
        }
    }

    return false;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_BakeResponse_createForSSR(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BakeResponse_createForSSR_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto releaseResponseOnFailure = WTF::makeScopeExit([&] {
        Bindgen::Engine::releaseBakeResponseNativeResponse(args.response);
    });
    Structure* structure = globalObject->bakeAdditions().JSBakeResponseStructure(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSBakeResponse* instance = JSBakeResponse::create(vm, globalObject, structure);
    RETURN_IF_EXCEPTION(scope, {});

    switch (args.kind) {
    case decltype(args.kind)::redirect:
        instance->kind(JSBakeResponseKind::Redirect);
        break;
    case decltype(args.kind)::render:
        instance->kind(JSBakeResponseKind::Render);
        break;
    }

    instance->setToThrow(globalObject, vm);
    RETURN_IF_EXCEPTION(scope, {});

    releaseResponseOnFailure.release();
    instance->adoptExternalNative(globalObject, args.response);
    RETURN_IF_EXCEPTION(scope, {});

    return instance;
}

bool Bindgen::Engine::bunBindgenEngine_BakeResponse_validateStreamingMode(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BakeResponse_validateStreamingMode_Arguments& args)
{
    switch (args.caller) {
    case decltype(args.caller)::constructor:
        return validateBakeResponseStreamingMode(&context.globalObject, "new Response(<jsx />, { ... })"_s);
    case decltype(args.caller)::redirect:
        return validateBakeResponseStreamingMode(&context.globalObject, "Response.redirect"_s);
    case decltype(args.caller)::render:
        return validateBakeResponseStreamingMode(&context.globalObject, "Response.render"_s);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

#define BUN_BINDGEN_OBJECT_SURFACE_JSBakeResponseConstructor
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSBakeResponseConstructor

JSBakeResponse* JSBakeResponse::create(JSC::VM& vm, Zig::GlobalObject* globalObject, JSC::Structure* structure)
{
    JSBakeResponse* ptr = new (NotNull, JSC::allocateCell<JSBakeResponse>(vm)) JSBakeResponse(vm, structure);
    ptr->finishCreation(vm);

    auto& builtinNames = WebCore::builtinNames(vm);

    // $$typeof = Symbol.for("react.transitional.element")
    ptr->putDirect(vm, builtinNames.$$typeofPublicName(), JSC::Symbol::create(vm, vm.symbolRegistry().symbolForKey("react.transitional.element"_s)), 0);
    // type = false
    ptr->putDirect(vm, builtinNames.typePublicName(), JSC::jsNull(), 0);
    // key = null
    ptr->putDirect(vm, builtinNames.keyPublicName(), JSC::jsNull(), 0);
    // props = {}
    ptr->putDirect(vm, builtinNames.propsPublicName(), JSC::constructEmptyObject(globalObject), 0);

    // _store = { _validated: 0 }
    JSObject* storeObject = JSC::constructEmptyObject(globalObject);
    auto validatedIdent = JSC::Identifier::fromString(vm, "validated"_s);
    storeObject->putDirect(vm, builtinNames.validatedPublicName(), jsNumber(0), 0);
    ptr->putDirect(vm, builtinNames._storePublicName(), storeObject, 0);

    // _owner = null
    ptr->putDirect(vm, builtinNames._ownerPublicName(), JSC::jsNull(), 0);
    // _debugInfo = null
    ptr->putDirect(vm, builtinNames._debugInfoPublicName(), JSC::jsNull(), 0);
    // _debugStack = null
    ptr->putDirect(vm, builtinNames._debugStackPublicName(), JSC::jsNull(), 0);
    // _debugTask = null
    ptr->putDirect(vm, builtinNames._debugTaskPublicName(), JSC::jsNull(), 0);

    return ptr;
}

JSC::Structure* JSBakeResponse::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(static_cast<JSC::JSType>(0b11101110), StructureFlags), info());
}

JSC::GCClient::IsoSubspace* JSBakeResponse::subspaceForImpl(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<JSBakeResponse, WebCore::UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForBakeResponse.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForBakeResponse = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForBakeResponse.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForBakeResponse = std::forward<decltype(space)>(space); });
}

JSBakeResponse::JSBakeResponse(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure, nullptr, nullptr, nullptr, WebCore::clientData(vm), {})
{
}

void JSBakeResponse::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
}

template<typename Visitor>
void JSBakeResponse::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSBakeResponse* thisObject = uncheckedDowncast<JSBakeResponse>(cell);
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(JSBakeResponse);

void JSBakeResponse::destroy(JSC::JSCell* cell)
{
    destroyCell<JSBakeResponse>(cell);
}

class JSBakeResponseConstructor final : public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static JSBakeResponseConstructor* create(JSC::VM& vm, JSC::Structure* structure, JSC::JSObject* prototype)
    {
        JSBakeResponseConstructor* constructor = new (NotNull, JSC::allocateCell<JSBakeResponseConstructor>(vm)) JSBakeResponseConstructor(vm, structure);
        constructor->finishCreation(vm, prototype);
        return constructor;
    }

    DECLARE_INFO;
    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.internalFunctionSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
    }

private:
    JSBakeResponseConstructor(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure, bun_bindgen_host_BakeResponse_constructorCall, bun_bindgen_host_BakeResponse_constructorConstruct)
    {
    }

    void finishCreation(JSC::VM& vm, JSC::JSObject* prototype)
    {
        Base::finishCreation(vm, 0, "Response"_s);
        putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly);
        bunBindgenObjectSurface_JSBakeResponseConstructor_install(vm, info(), *this);
    }
};

static JSC::JSValue constructBakeResponse(
    Zig::GlobalObject* globalObject,
    const std::optional<JSC::JSValue>& body,
    const std::optional<Bindgen::CppAny>& init,
    JSC::JSObject* newTarget)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* structure = globalObject->bakeAdditions().JSBakeResponseStructure(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    if (newTarget) {
        auto* constructor = globalObject->bakeAdditions().JSBakeResponseConstructor(globalObject);
        if (constructor != newTarget) [[unlikely]] {
            auto* functionGlobalObject = defaultGlobalObject(getFunctionRealm(globalObject, newTarget));
            RETURN_IF_EXCEPTION(scope, {});
            structure = InternalFunction::createSubclassStructure(
                globalObject,
                newTarget,
                functionGlobalObject->bakeAdditions().JSBakeResponseStructure(functionGlobalObject));
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    auto* instance = JSBakeResponse::create(vm, globalObject, structure);
    RETURN_IF_EXCEPTION(scope, {});

    bool isJSXBody = body && isJSXElement(*body, globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    if (isJSXBody) {
        validateBakeResponseStreamingMode(globalObject, "new Response(<jsx />, { ... })"_s);
        RETURN_IF_EXCEPTION(scope, {});
    }

    JSC::MarkedArgumentBuffer responseArguments;
    responseArguments.append(body.value_or(JSC::jsUndefined()));
    if (init)
        init->appendTo(responseArguments);
    else
        responseArguments.append(JSC::jsUndefined());
    auto* responseConstructor = globalObject->BunBindgen_Response_ResponseConstructor();
    RETURN_IF_EXCEPTION(scope, {});
    auto constructData = JSC::getConstructData(responseConstructor);
    auto responseValue = JSC::construct(
        globalObject,
        responseConstructor,
        constructData,
        JSC::ArgList(responseArguments));
    RETURN_IF_EXCEPTION(scope, {});

    auto* responseObject = dynamicDowncast<BunBindgen_Response_Response>(responseValue);
    RELEASE_ASSERT(responseObject);
    instance->adoptConstructionFrom(*responseObject);
    RETURN_IF_EXCEPTION(scope, {});

    if (isJSXBody) {
        instance->wrapInnerComponent(
            globalObject,
            vm,
            *body,
            init);
        RETURN_IF_EXCEPTION(scope, {});
    }

    return instance;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_BakeResponse_construct(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BakeResponse_construct_Arguments& args)
{
    auto* newTarget = args.newTarget ? JSC::asObject(*args.newTarget) : nullptr;
    return constructBakeResponse(
        newTarget ? defaultGlobalObject(&context.globalObject) : static_cast<Zig::GlobalObject*>(&context.globalObject),
        args.body,
        args.init,
        newTarget);
}

const JSC::ClassInfo JSBakeResponse::s_info = { "Response"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSBakeResponse) };
const JSC::ClassInfo JSBakeResponseConstructor::s_info = { ""_s, &JSC::InternalFunction::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSBakeResponseConstructor) };

void setupJSBakeResponseClassStructure(JSC::LazyClassStructure::Initializer& init)
{
    auto* zigGlobal = static_cast<Zig::GlobalObject*>(init.global);
    auto* prototype = JSC::constructEmptyObject(zigGlobal, zigGlobal->BunBindgen_Response_ResponsePrototype());

    auto* constructorStructure = JSBakeResponseConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());
    auto* constructor = JSBakeResponseConstructor::create(init.vm, constructorStructure, prototype);

    auto* structure = JSBakeResponse::createStructure(init.vm, zigGlobal, prototype);
    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

} // namespace Bun
