#include "InspectorHTTPServerAgent.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/InspectorFrontendRouter.h>
#include <JavaScriptCore/InspectorBackendDispatcher.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include <wtf/TZoneMallocInlines.h>
#include "ZigGlobalObject.h"

namespace Inspector {

WTF_MAKE_TZONE_ALLOCATED_IMPL(InspectorHTTPServerAgent);

InspectorHTTPServerAgent::InspectorHTTPServerAgent(JSC::JSGlobalObject& globalObject)
    : InspectorAgentBase("HTTPServer"_s)
    , m_backendDispatcher(HTTPServerBackendDispatcher::create(globalObject.inspectorController().backendDispatcher(), this))
    , m_frontendDispatcher(makeUnique<HTTPServerFrontendDispatcher>(const_cast<FrontendRouter&>(globalObject.inspectorController().frontendRouter())))
    , m_enabled(false)
{
}

InspectorHTTPServerAgent::~InspectorHTTPServerAgent()
{
    if (m_enabled) {
        Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorHTTPServerAgent(this, false);
    }
}

void InspectorHTTPServerAgent::didCreateFrontendAndBackend()
{
}

void InspectorHTTPServerAgent::willDestroyFrontendAndBackend(DisconnectReason)
{
    disable();
}

Protocol::ErrorStringOr<void> InspectorHTTPServerAgent::enable()
{
    if (m_enabled)
        return {};

    m_enabled = true;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorHTTPServerAgent(this, true);
    return {};
}

Protocol::ErrorStringOr<void> InspectorHTTPServerAgent::disable()
{
    if (!m_enabled)
        return {};

    m_enabled = false;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorHTTPServerAgent(this, false);
    return {};
}

Protocol::ErrorStringOr<void> InspectorHTTPServerAgent::startListening(int serverId)
{
    if (!m_enabled)
        return {};

    return {};
}

Protocol::ErrorStringOr<void> InspectorHTTPServerAgent::stopListening(int serverId)
{
    if (!m_enabled)
        return {};

    // TODO:
    // Bun__HTTPServerAgentStopListening(this, serverId);
    return {};
}

Protocol::ErrorStringOr<void> InspectorHTTPServerAgent::getRequestBody(int requestId, int serverId)
{
    if (!m_enabled)
        return {};

    // TODO:
    // Bun__HTTPServerAgentGetRequestBody(this, requestId, serverId);
    return {};
}

Protocol::ErrorStringOr<void> InspectorHTTPServerAgent::getResponseBody(int requestId, int serverId)
{
    if (!m_enabled)
        return {};
    // TODO:
    // Bun__HTTPServerAgentGetResponseBody(this, requestId, serverId);
    return {};
}

// Event dispatchers

void InspectorHTTPServerAgent::serverStarted(int serverId, const String& url, double startTime, AnyServerPtr serverInstance)
{
    this->m_serverIdToServerInstance.set(serverId, serverInstance);
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->listen(serverId, url, startTime);
}
void InspectorHTTPServerAgent::serverStopped(int serverId, double timestamp)
{
    this->m_serverIdToServerInstance.remove(serverId);

    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->close(serverId, timestamp);
}
void InspectorHTTPServerAgent::serverRoutesUpdated(int serverId, int hotReloadId, Ref<JSON::ArrayOf<Protocol::HTTPServer::Route>>&& routes)
{
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->serverRoutesUpdated(serverId, hotReloadId, WTF::move(routes));
}
void InspectorHTTPServerAgent::requestWillBeSent(Ref<Protocol::HTTPServer::Request>&& request)
{
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->requestWillBeSent(WTF::move(request));
}
void InspectorHTTPServerAgent::responseReceived(Ref<Protocol::HTTPServer::Response>&& response)
{
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->responseReceived(WTF::move(response));
}
void InspectorHTTPServerAgent::bodyChunkReceived(Ref<Protocol::HTTPServer::BodyChunk>&& chunk)
{
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->bodyChunkReceived(WTF::move(chunk));
}
void InspectorHTTPServerAgent::requestFinished(int requestId, int serverId, double timestamp, std::optional<double>&& opt_duration)
{
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->requestFinished(requestId, serverId, timestamp, WTF::move(opt_duration));
}
void InspectorHTTPServerAgent::requestHandlerException(Ref<Protocol::HTTPServer::RequestHandlerError>&& error)
{
    if (!m_enabled || !m_frontendDispatcher) {
        return;
    }

    this->m_frontendDispatcher->requestHandlerException(WTF::move(error));
}

}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerStarted(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerStarted_Arguments& args)
{
    args.agent->serverStarted(args.serverId, args.address, args.startTime, args.serverInstance);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerStopped(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerStopped_Arguments& args)
{
    args.agent->serverStopped(args.serverId, args.timestamp);
}

Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerRoutesUpdated_Return Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerRoutesUpdated(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorHTTPServerAgentNotifyServerRoutesUpdated_Arguments& args)
{
    auto routes = JSON::ArrayOf<Inspector::Protocol::HTTPServer::Route>::create();
    for (const auto& route : args.routes) {

        auto route_type = Inspector::Protocol::HTTPServer::RouteType::Default;
        switch (route.type) {
        case decltype(route.type)::api:
            route_type = Inspector::Protocol::HTTPServer::RouteType::API;
            break;
        case decltype(route.type)::html:
            route_type = Inspector::Protocol::HTTPServer::RouteType::HTML;
            break;
        case decltype(route.type)::static_route:
            route_type = Inspector::Protocol::HTTPServer::RouteType::Static;
            break;
        default:
            route_type = Inspector::Protocol::HTTPServer::RouteType::Default;
            break;
        }

        auto object = Inspector::Protocol::HTTPServer::Route::create()
                          .setRouteId(route.routeId)
                          .setPath(route.path)
                          .setType(route_type)
                          .setScriptLine(route.scriptLine)
                          .release();

        if (!route.filePath.isEmpty()) {
            object->setFilePath(route.filePath);
        }

        if (!route.scriptUrl.isEmpty()) {
            object->setScriptUrl(route.scriptUrl);
        }

        routes->addItem(WTF::move(object));
    }

    args.agent->serverRoutesUpdated(args.serverId, args.hotReloadId, WTF::move(routes));
    return {};
}
