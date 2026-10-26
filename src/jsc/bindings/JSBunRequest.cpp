#include "root.h"

#include <JavaScriptCore/JSCell.h>
#include <JavaScriptCore/Structure.h>
#include <JavaScriptCore/JSObject.h>
#include "JSBunRequest.h"
#include "ZigGlobalObject.h"
#include "AsyncContextFrame.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include "JSFetchHeaders.h"
#include "JSCookieMap.h"
#include "Cookie.h"
#include "CookieMap.h"
#include "ErrorCode.h"
#include "Bindgen/IDLConvertBase.h"
#include "SchemaBindings.h"
#include "JSDOMExceptionHandling.h"
#include <bun-uws/src/App.h>
#include <wtf/Scope.h>

namespace Bun {

static JSBunRequest* bunRequest(JSC::JSValue value)
{
    auto* request = dynamicDowncast<JSBunRequest>(value);
    RELEASE_ASSERT(request);
    return request;
}

void Bindgen::Engine::releaseNativeRequest(BunBindgen_Request_Request_Native* request)
{
    Bindgen::ZigExports::bunBindgenZig_Request_requestReleaseNative(request);
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_Request_requestCreateForBake(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_Request_requestCreateForBake_Arguments& args)
{
    auto releaseRequestOnFailure = WTF::makeScopeExit([&] {
        Bindgen::Engine::releaseNativeRequest(args.request);
    });
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* structure = globalObject->m_JSBunRequestStructure.get(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    auto* paramsPrototype = globalObject->m_JSBunRequestParamsPrototype.get(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    // the params are passed into the page component as a prop so we'll make
    // this empty for now
    auto* emptyParams = JSC::constructEmptyObject(globalObject, paramsPrototype);
    RETURN_IF_EXCEPTION(scope, {});

    releaseRequestOnFailure.release();
    JSBunRequest* request
        = JSBunRequest::create(vm, globalObject, structure, args.request, emptyParams);
    RETURN_IF_EXCEPTION(scope, {});

    return request;
}

#define BUN_BINDGEN_OBJECT_SURFACE_JSBunRequestPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSBunRequestPrototype

JSBunRequest* JSBunRequest::create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, void* sinkPtr, JSObject* params)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSBunRequest* ptr = new (NotNull, JSC::allocateCell<JSBunRequest>(vm)) JSBunRequest(vm, structure, params);
    ptr->finishCreation(vm);
    ptr->adoptExternalNative(globalObject, sinkPtr);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return ptr;
}

JSC::Structure* JSBunRequest::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(static_cast<JSC::JSType>(0b11101110), StructureFlags), info());
}

JSC::GCClient::IsoSubspace* JSBunRequest::subspaceForImpl(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<JSBunRequest, WebCore::UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForBunRequest.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForBunRequest = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForBunRequest.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForBunRequest = std::forward<decltype(space)>(space); });
}

JSObject* JSBunRequest::params() const
{
    if (m_params) {
        return m_params.get();
    }
    return nullptr;
}

void JSBunRequest::setParams(JSObject* params)
{
    m_params.set(Base::vm(), this, params);
}

JSObject* JSBunRequest::cookies() const
{
    return m_cookies.get();
}

JSBunRequest* JSBunRequest::clone(JSC::VM& vm, JSGlobalObject* globalObject)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto* structure = defaultGlobalObject(globalObject)->m_JSBunRequestStructure.getInitializedOnMainThread(globalObject);
    auto raw = Bindgen::ZigExports::bunBindgenZig_Request_requestClone(globalObject, this->native());
    EXCEPTION_ASSERT(!!raw == !throwScope.exception());
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    auto* clone = this->create(vm, globalObject, structure, raw.value(), nullptr);
    RETURN_IF_EXCEPTION(throwScope, nullptr);

    // Cookies and params are deep copied as they can be changed between the clone and original
    if (auto* params = this->params()) {
        // TODO: Use JSC's internal `cloneObject()` if/when it's exposed
        // https://github.com/oven-sh/WebKit/blob/c5e9b9e327194f520af2c28679adb0ea1fa902ad/Source/JavaScriptCore/runtime/JSGlobalObjectFunctions.cpp#L1018-L1099
        auto* prototype = defaultGlobalObject(globalObject)->m_JSBunRequestParamsPrototype.get(globalObject);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        auto* paramsClone = JSC::constructEmptyObject(globalObject, prototype);
        RETURN_IF_EXCEPTION(throwScope, nullptr);

        auto propertyNames = PropertyNameArrayBuilder(vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
        JSObject::getOwnPropertyNames(params, globalObject, propertyNames, JSC::DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(throwScope, nullptr);

        for (auto& property : propertyNames) {
            auto value = params->get(globalObject, property);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            paramsClone->putDirect(vm, property, value);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
        }

        clone->setParams(paramsClone);
    }

    if (auto* cookiesObject = cookies()) {
        if (auto* wrapper = dynamicDowncast<JSCookieMap>(cookiesObject)) {
            auto cookies = Bindgen::ZigExports::bunBindgenZig_cookie_map_cookieMapCloneWrapper(globalObject, wrapper);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            clone->setCookies(globalObject, cookies.getObject());
            RETURN_IF_EXCEPTION(throwScope, nullptr);
        }
    }

    RELEASE_AND_RETURN(throwScope, clone);
}

void JSBunRequest::setCookies(JSGlobalObject* global, JSObject* cookies)
{
    auto scope = DECLARE_THROW_SCOPE(Base::vm());
    RefPtr<WebCore::CookieMap> map;
    if (dynamicDowncast<JSCookieMap>(cookies)) {
        map = WebCore::protectedCookieMap(global, cookies);
        RETURN_IF_EXCEPTION(scope, void());
        RELEASE_ASSERT(map);
    }
    m_cookies.set(Base::vm(), this, cookies);
    if (map)
        Bindgen::ZigExports::bunBindgenZig_Request_requestSetCookies(this->native(), map.get());
    else
        Bindgen::ZigExports::bunBindgenZig_Request_requestSetCookies(this->native(), std::nullopt);
}

JSBunRequest::JSBunRequest(JSC::VM& vm, JSC::Structure* structure, JSC::JSObject* params)
    : Base(vm, structure, nullptr, nullptr, nullptr, WebCore::clientData(vm), {})
    , m_params(params, JSC::WriteBarrierEarlyInit)
    , m_cookies(nullptr, JSC::WriteBarrierEarlyInit)
{
}
void JSBunRequest::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
}

template<typename Visitor>
void JSBunRequest::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSBunRequest* thisCallSite = uncheckedDowncast<JSBunRequest>(cell);
    Base::visitChildren(thisCallSite, visitor);
    visitor.append(thisCallSite->m_params);
    visitor.append(thisCallSite->m_cookies);
}

DEFINE_VISIT_CHILDREN(JSBunRequest);

void JSBunRequest::destroy(JSC::JSCell* cell)
{
    destroyCell<JSBunRequest>(cell);
}

class JSBunRequestPrototype final : public JSNonFinalObject {
public:
    using Base = JSNonFinalObject;

    static JSBunRequestPrototype* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure)
    {
        auto* ptr = new (NotNull, JSC::allocateCell<JSBunRequestPrototype>(vm)) JSBunRequestPrototype(vm, structure);
        ptr->finishCreation(vm, globalObject);
        return ptr;
    }

    static Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        auto* structure = Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info(), NonArray);
        structure->setMayBePrototype(true);
        return structure;
    }

    DECLARE_INFO;

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSBunRequestPrototype, Base);
        return &vm.plainObjectSpace();
    }

private:
    JSBunRequestPrototype(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        Base::finishCreation(vm);
        bunBindgenObjectSurface_JSBunRequestPrototype_install(vm, JSBunRequest::info(), *this);
    }
};

const JSC::ClassInfo JSBunRequestPrototype::s_info = { "BunRequest"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSBunRequestPrototype) };
const JSC::ClassInfo JSBunRequest::s_info = { "BunRequest"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSBunRequest) };

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_Request_bunRequestParams(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_Request_bunRequestParams_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSBunRequest* request = bunRequest(args.bindingThis);

    auto* params = request->params();
    if (!params) {
        auto* prototype = defaultGlobalObject(globalObject)->m_JSBunRequestParamsPrototype.get(globalObject);
        params = JSC::constructEmptyObject(globalObject, prototype);
        request->setParams(params);
    }

    return params;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_Request_bunRequestCookies(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_Request_bunRequestCookies_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSBunRequest* request = bunRequest(args.bindingThis);

    auto* cookies = request->cookies();
    if (!cookies) {
        auto& vm = globalObject->vm();
        auto throwScope = DECLARE_THROW_SCOPE(vm);
        auto& names = builtinNames(vm);
        JSC::JSValue headersValue = request->get(globalObject, names.headersPublicName());
        RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        auto* headers = dynamicDowncast<WebCore::JSFetchHeaders>(headersValue);
        if (!headers)
            return std::nullopt;

        auto fetchHeaders = WebCore::protectedFetchHeaders(globalObject, headers);
        RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        RELEASE_ASSERT(fetchHeaders);
        auto cookieHeader = fetchHeaders->internalHeaders().get(HTTPHeaderName::Cookie);

        // Create a CookieMap from the cookie header
        auto cookieMapResult = WebCore::CookieMap::create(cookieHeader);
        RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        if (cookieMapResult.hasException()) {
            WebCore::propagateException(*globalObject, throwScope, cookieMapResult.releaseException());
            RELEASE_AND_RETURN(throwScope, std::nullopt);
        }

        auto cookieMap = cookieMapResult.releaseReturnValue();

        auto cookies = Bindgen::ZigExports::bunBindgenZig_cookie_map_cookieMapWrap(globalObject, cookieMap.ptr());
        RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        request->setCookies(globalObject, cookies.getObject());
        RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        return cookies;
    }

    return cookies;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_Request_bunRequestClone(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_Request_bunRequestClone_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto clone = bunRequest(args.bindingThis)->clone(vm, globalObject);
    RETURN_IF_EXCEPTION(throwScope, {});
    return clone;
}

Structure* createJSBunRequestStructure(JSC::VM& vm, Zig::GlobalObject* globalObject)
{
    auto prototypeStructure = JSBunRequestPrototype::createStructure(vm, globalObject, globalObject->BunBindgen_Request_RequestPrototype());
    auto* prototype = JSBunRequestPrototype::create(vm, globalObject, prototypeStructure);
    return JSBunRequest::createStructure(vm, globalObject, prototype);
}

bool Bindgen::Engine::bunBindgenEngine_Request_jsValueIsBunRequest(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_Request_jsValueIsBunRequest_Arguments& args)
{
    return !!dynamicDowncast<JSBunRequest>(context.classValue(args.value));
}

std::optional<JSC::JSValue> Bindgen::Engine::bunBindgenEngine_Request_bunRequestParams(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_Request_bunRequestParams_Arguments& args)
{
    if (auto* request = dynamicDowncast<JSBunRequest>(context.classValue(args.value))) {
        if (auto* params = request->params())
            return params;
    }
    return std::nullopt;
}

} // namespace Bun
