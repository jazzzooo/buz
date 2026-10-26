#include "InspectorBunFrontendDevServerAgent.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/InspectorFrontendRouter.h>
#include <JavaScriptCore/InspectorBackendDispatcher.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/ScriptCallStackFactory.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <JavaScriptCore/ConsoleMessage.h>
#include <JavaScriptCore/InspectorConsoleAgent.h>
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include <wtf/TZoneMallocInlines.h>
#include "ZigGlobalObject.h"

namespace Inspector {

WTF_MAKE_TZONE_ALLOCATED_IMPL(InspectorBunFrontendDevServerAgent);

InspectorBunFrontendDevServerAgent::InspectorBunFrontendDevServerAgent(JSC::JSGlobalObject& globalObject)
    : InspectorAgentBase("BunFrontendDevServer"_s)
    // , m_globalobject(globalObject)
    , m_backendDispatcher(BunFrontendDevServerBackendDispatcher::create(globalObject.inspectorController().backendDispatcher(), this))
    , m_frontendDispatcher(makeUnique<BunFrontendDevServerFrontendDispatcher>(const_cast<FrontendRouter&>(globalObject.inspectorController().frontendRouter())))
    , m_enabled(false)
{
    UNUSED_PARAM(globalObject);
}

InspectorBunFrontendDevServerAgent::~InspectorBunFrontendDevServerAgent()
{
    if (m_enabled)
        Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorBunFrontendDevServerAgent(this, false);
}

void InspectorBunFrontendDevServerAgent::didCreateFrontendAndBackend()
{
}

void InspectorBunFrontendDevServerAgent::willDestroyFrontendAndBackend(DisconnectReason)
{
    disable();
}

Protocol::ErrorStringOr<void> InspectorBunFrontendDevServerAgent::enable()
{
    if (m_enabled)
        return {};

    m_enabled = true;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorBunFrontendDevServerAgent(this, true);
    return {};
}

Protocol::ErrorStringOr<void> InspectorBunFrontendDevServerAgent::disable()
{
    if (!m_enabled)
        return {};

    m_enabled = false;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorBunFrontendDevServerAgent(this, false);
    return {};
}

void InspectorBunFrontendDevServerAgent::clientConnected(int devServerId, int connectionId)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->clientConnected(devServerId, connectionId);
}

void InspectorBunFrontendDevServerAgent::clientDisconnected(int devServerId, int connectionId)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->clientDisconnected(devServerId, connectionId);
}

void InspectorBunFrontendDevServerAgent::bundleStart(int devServerId, Ref<JSON::ArrayOf<String>>&& triggerFiles)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->bundleStart(devServerId, WTF::move(triggerFiles));
}

void InspectorBunFrontendDevServerAgent::bundleComplete(int devServerId, double durationMs)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->bundleComplete(devServerId, durationMs);
}

void InspectorBunFrontendDevServerAgent::bundleFailed(int devServerId, const String& buildErrorsPayloadBase64)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->bundleFailed(devServerId, buildErrorsPayloadBase64);
}

void InspectorBunFrontendDevServerAgent::clientNavigated(int devServerId, int connectionId, const String& url, std::optional<int> routeBundleId)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->clientNavigated(devServerId, connectionId, url, WTF::move(routeBundleId));
}

void InspectorBunFrontendDevServerAgent::clientErrorReported(int devServerId, const String& clientErrorPayloadBase64)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->clientErrorReported(devServerId, clientErrorPayloadBase64);
}

void InspectorBunFrontendDevServerAgent::graphUpdate(int devServerId, const String& visualizerPayloadBase64)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    // m_frontendDispatcher->graphUpdate(devServerId, visualizerPayloadBase64);
}

void InspectorBunFrontendDevServerAgent::consoleLog(int devServerId, char kind, const String& data)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->consoleLog(devServerId, kind, data);
}

} // namespace Inspector

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerClientConnected(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerClientConnected_Arguments& args)
{
    args.agent->clientConnected(args.devServerId, args.connectionId);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerClientDisconnected(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerClientDisconnected_Arguments& args)
{
    args.agent->clientDisconnected(args.devServerId, args.connectionId);
}

Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerBundleStart_Return Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerBundleStart(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerBundleStart_Arguments& args)
{
    auto files = JSON::ArrayOf<WTF::String>::create();
    for (const auto& file : args.triggerFiles) {
        files->addItem(file);
    }

    args.agent->bundleStart(args.devServerId, WTF::move(files));
    return {};
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerBundleComplete(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerBundleComplete_Arguments& args)
{
    args.agent->bundleComplete(args.devServerId, args.durationMs);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerBundleFailed(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerBundleFailed_Arguments& args)
{
    args.agent->bundleFailed(args.devServerId, args.payload);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerClientNavigated(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerClientNavigated_Arguments& args)
{
    args.agent->clientNavigated(args.devServerId, args.connectionId, args.url, args.routeBundleId);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerClientErrorReported(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerClientErrorReported_Arguments& args)
{
    args.agent->clientErrorReported(args.devServerId, args.payload);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerGraphUpdate(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerGraphUpdate_Arguments& args)
{
    args.agent->graphUpdate(args.devServerId, args.payload);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorDevServerConsoleLog(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorDevServerConsoleLog_Arguments& args)
{
    args.agent->consoleLog(args.devServerId, static_cast<char>(args.kind), args.data);
}
