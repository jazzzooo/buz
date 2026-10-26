#include "root.h"
#include <JavaScriptCore/JSCell.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include "ZigGlobalObject.h"
#include <JavaScriptCore/Structure.h>
#include <bun-uws/src/App.h>
#include <bun-uws/src/Http3Request.h>
#include "SchemaBindings.h"
#include "ServerRouteList.h"
#include "decodeURIComponentSIMD.h"
#include "JSBunRequest.h"
#include <JavaScriptCore/PropertyName.h>
#include <wtf/text/MakeString.h>

namespace Bun {
using namespace JSC;
using namespace WebCore;

class ServerRouteList final : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;
    struct IdentifierRange {
        size_t start;
        size_t count;
    };

    static ServerRouteList* create(
        JSC::JSGlobalObject& globalObject,
        JSC::Structure* structure,
        std::span<const JSValue> callbacks,
        std::span<const WTF::String> paths)
    {
        auto& vm = globalObject.vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* routeList = new (NotNull, JSC::allocateCell<ServerRouteList>(vm)) ServerRouteList(vm, structure);
        if (!routeList->finishCreation(vm, callbacks, paths)) {
            throwOutOfMemoryError(&globalObject, scope);
            return nullptr;
        }
        return routeList;
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        return JSC::Structure::create(vm, globalObject, globalObject->nullPrototype(), JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static void destroy(JSCell* cell)
    {
        static_cast<ServerRouteList*>(cell)->~ServerRouteList();
    }

    ~ServerRouteList()
    {
        m_routes.clear();
        m_pathIdentifiers.clear();
        m_pathIdentifierRanges.clear();
    }

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<ServerRouteList, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForServerRouteList.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForServerRouteList = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForServerRouteList.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForServerRouteList = std::forward<decltype(space)>(space); });
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    template<typename Req>
    Bindgen::Engine::BunBindgenEngine_ServerRouteList_prepareRoute_Return prepareRoute(Zig::GlobalObject* globalObject, uint32_t index, void* requestPtr, Req* req);

private:
    template<typename Req>
    JSObject* paramsObjectForRoute(JSC::VM& vm, JSC::JSGlobalObject* globalObject, uint32_t index, Req* req);

    ServerRouteList(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    WTF::Vector<JSC::WriteBarrier<JSC::JSCell>> m_routes;
    WTF::Vector<IdentifierRange> m_pathIdentifierRanges;
    WTF::Vector<Identifier> m_pathIdentifiers;

    bool finishCreation(JSC::VM& vm, std::span<const JSValue> callbacks, std::span<const WTF::String> paths)
    {
        Base::finishCreation(vm);
        RELEASE_ASSERT(callbacks.size() == paths.size());
        if (!m_routes.tryReserveInitialCapacity(callbacks.size()) || !m_pathIdentifierRanges.tryReserveInitialCapacity(paths.size()))
            return false;
        for (auto callback : callbacks) {
            m_routes.append(JSC::WriteBarrier<JSC::JSCell>());
            m_routes.last().set(vm, this, callback.asCell());
        }
        for (const auto& path : paths) {
            const size_t start = m_pathIdentifiers.size();
            size_t identifierStart = 0;
            auto appendIdentifier = [&](size_t end) {
                if (!identifierStart || identifierStart >= end) return true;
                auto text = WTF::tryMakeString(StringView(path).substring(identifierStart, end - identifierStart));
                if (text.isNull()) return false;
                return m_pathIdentifiers.tryAppend(Identifier::fromString(vm, text));
            };
            for (size_t i = 0; i < path.length(); ++i) {
                if (path[i] == '/') {
                    if (!appendIdentifier(i)) return false;
                    identifierStart = 0;
                } else if (path[i] == ':') {
                    identifierStart = i + 1;
                }
            }
            if (!appendIdentifier(path.length())) return false;
            m_pathIdentifierRanges.append(IdentifierRange{start, m_pathIdentifiers.size() - start});
        }
        return true;
    }

};

const JSC::ClassInfo ServerRouteList::s_info = { "ServerRouteList"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(ServerRouteList) };

template<typename Visitor>
void ServerRouteList::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    ServerRouteList* thisCallSite = uncheckedDowncast<ServerRouteList>(cell);
    Base::visitChildren(thisCallSite, visitor);

    for (unsigned i = 0; i < thisCallSite->m_routes.size(); i++) {
        if (thisCallSite->m_routes[i]) visitor.append(thisCallSite->m_routes[i]);
    }
}
DEFINE_VISIT_CHILDREN(ServerRouteList);

ServerRouteList* serverRouteListCast(JSC::JSValue value)
{
    return dynamicDowncast<ServerRouteList>(value);
}

bool isServerRouteList(JSC::JSValue value) noexcept
{
    return !!serverRouteListCast(value);
}

template<typename Req>
JSObject* ServerRouteList::paramsObjectForRoute(JSC::VM& vm, JSC::JSGlobalObject* globalObject, uint32_t index, Req* req)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Ensure that the object doesn't get GC'd before we've had a chance to initialize it.
    MarkedArgumentBuffer args;
    IdentifierRange range = m_pathIdentifierRanges.at(index);
    size_t offset = range.start;
    size_t identifierCount = range.count;
    if (!identifierCount)
        return constructEmptyObject(vm, globalObject->nullPrototypeObjectStructure());
    args.ensureCapacity(identifierCount);
    if (args.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    for (size_t i = 0; i < identifierCount; i++) {
        auto param = req->getParameter(static_cast<unsigned short>(i));
        if (!param.empty()) {
            const std::span<const uint8_t> paramBytes(reinterpret_cast<const uint8_t*>(param.data()), param.size());
            auto decoded = decodeURIComponentSIMD(paramBytes);
            if (!decoded) {
                throwOutOfMemoryError(globalObject, scope);
                return nullptr;
            }
            args.append(jsString(vm, WTF::move(*decoded)));
        } else {
            args.append(jsEmptyString(vm));
        }
    }
    if (args.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    const std::span<const Identifier> identifiers = m_pathIdentifiers.subspan(offset, identifierCount);

    auto* prototype = defaultGlobalObject(globalObject)->m_JSBunRequestParamsPrototype.get(globalObject);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* object = constructEmptyObject(globalObject, prototype,
        std::min(identifierCount, static_cast<size_t>(JSFinalObject::maxInlineCapacity)));
    RETURN_IF_EXCEPTION(scope, nullptr);
    const unsigned attributes = identifierCount < JSFinalObject::maxInlineCapacity ? static_cast<unsigned>(PropertyAttribute::DontDelete) : 0;
    for (size_t i = 0; i < identifierCount; ++i) {
        object->putDirect(vm, identifiers[i], args.at(i), attributes);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }

    return object;
}

template<typename Req>
Bindgen::Engine::BunBindgenEngine_ServerRouteList_prepareRoute_Return ServerRouteList::prepareRoute(Zig::GlobalObject* globalObject, uint32_t index, void* requestPtr, Req* req)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* structure = globalObject->m_JSBunRequestStructure.get(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    auto* params = paramsObjectForRoute(vm, globalObject, index, req);
    RETURN_IF_EXCEPTION(scope, {});

    JSBunRequest* request = JSBunRequest::create(vm, globalObject, structure, requestPtr, params);
    RETURN_IF_EXCEPTION(scope, {});

    JSValue callback = m_routes.at(index).get();
    ASSERT(callback);
    Bindgen::Engine::BunBindgenEngine_ServerRouteList_prepareRoute_Return result;
    result.callback = callback;
    result.request = request;
    return result;
}

Bindgen::Engine::BunBindgenEngine_ServerRouteList_prepareRoute_Return Bindgen::Engine::bunBindgenEngine_ServerRouteList_prepareRoute(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_ServerRouteList_prepareRoute_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* routeList = serverRouteListCast(args.routeList);
    RELEASE_ASSERT(routeList);
    switch (args.kind) {
    case decltype(args.kind)::http:
        return routeList->prepareRoute(
            globalObject,
            args.index,
            args.requestNative,
            reinterpret_cast<uWS::HttpRequest*>(args.request));
    case decltype(args.kind)::h3:
        return routeList->prepareRoute(
            globalObject,
            args.index,
            args.requestNative,
            reinterpret_cast<uWS::Http3Request*>(args.request));
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_ServerRouteList_create(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_ServerRouteList_create_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* structure = globalObject->m_ServerRouteListStructure.get(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, ServerRouteList::create(*globalObject, structure, args.callbacks, args.paths));
}

Structure* createServerRouteListStructure(JSC::VM& vm, Zig::GlobalObject* globalObject)
{
    return ServerRouteList::createStructure(vm, globalObject);
}

JSObject* createJSBunRequestParamsPrototype(JSC::VM& vm, Zig::GlobalObject* globalObject)
{
    auto* prototype = constructEmptyObject(vm, globalObject->nullPrototypeObjectStructure());
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, jsString(vm, String("RequestParams"_s)), JSC::PropertyAttribute::DontEnum | 0);
    auto* structure = Structure::create(vm, globalObject, prototype, TypeInfo(FinalObjectType, JSC::JSFinalObject::StructureFlags), JSFinalObject::info(), NonArray);
    structure->setMayBePrototype(true);
    return JSC::constructEmptyObject(vm, structure);
}

} // namespace Bun
