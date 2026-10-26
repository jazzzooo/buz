#include "InspectorLifecycleAgent.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/InspectorFrontendRouter.h>
#include <JavaScriptCore/InspectorBackendDispatcher.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSModuleLoader.h>
#include <JavaScriptCore/ModuleRegistryEntry.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/ScriptCallStackFactory.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <JavaScriptCore/ConsoleMessage.h>
#include <JavaScriptCore/InspectorConsoleAgent.h>
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include "ConsoleObject.h"
#include <wtf/TZoneMallocInlines.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSMapIterator.h>
#include <JavaScriptCore/IterationKind.h>
#include "BunProcess.h"

namespace Inspector {

WTF_MAKE_TZONE_ALLOCATED_IMPL(InspectorLifecycleAgent);

InspectorLifecycleAgent::InspectorLifecycleAgent(JSC::JSGlobalObject& globalObject)
    : InspectorAgentBase("LifecycleReporter"_s)
    , m_globalObject(globalObject)
    , m_backendDispatcher(LifecycleReporterBackendDispatcher::create(globalObject.inspectorController().backendDispatcher(), this))
    , m_frontendDispatcher(makeUnique<LifecycleReporterFrontendDispatcher>(const_cast<FrontendRouter&>(globalObject.inspectorController().frontendRouter())))
{
}

InspectorLifecycleAgent::~InspectorLifecycleAgent()
{
    if (m_enabled) {
        Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorLifecycleAgent(this, false);
    }
}

void InspectorLifecycleAgent::didCreateFrontendAndBackend()
{
}

void InspectorLifecycleAgent::willDestroyFrontendAndBackend(DisconnectReason)
{
    disable();
}

Protocol::ErrorStringOr<void> InspectorLifecycleAgent::enable()
{
    if (m_enabled)
        return {};

    m_enabled = true;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorLifecycleAgent(this, true);
    return {};
}

Protocol::ErrorStringOr<void> InspectorLifecycleAgent::disable()
{
    if (!m_enabled)
        return {};

    m_enabled = false;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorLifecycleAgent(this, false);
    return {};
}

void InspectorLifecycleAgent::reportReload()
{
    if (!m_enabled)
        return;

    m_frontendDispatcher->reload();
}

void InspectorLifecycleAgent::reportError(
    const WTF::String& message,
    const WTF::String& name,
    std::span<const Bun::Bindgen::ExceptionStackFrame> frames,
    std::span<const Bun::Bindgen::ExceptionSourceLine> sourceLineValues)
{
    if (!m_enabled)
        return;

    Ref<JSON::ArrayOf<String>> urls = JSON::ArrayOf<String>::create();
    Ref<JSON::ArrayOf<int>> lineColumns = JSON::ArrayOf<int>::create();
    Ref<JSON::ArrayOf<String>> sourceLines = JSON::ArrayOf<String>::create();

    for (const auto& sourceLine : sourceLineValues)
        sourceLines->addItem(sourceLine.text);

    for (const auto& frame : frames) {
        lineColumns->addItem(frame.line ? static_cast<int>(*frame.line) + 1 : 0);
        lineColumns->addItem(frame.column ? static_cast<int>(*frame.column) + 1 : 0);
        urls->addItem(frame.sourceURL);
    }

    m_frontendDispatcher->error(message, name, WTF::move(urls), WTF::move(lineColumns), WTF::move(sourceLines));
}

Protocol::ErrorStringOr<void> InspectorLifecycleAgent::preventExit()
{
    m_preventingExit = true;
    return {};
}

Protocol::ErrorStringOr<void> InspectorLifecycleAgent::stopPreventingExit()
{
    m_preventingExit = false;
    return {};
}

using ModuleGraph = std::tuple<Ref<JSON::ArrayOf<String>> /* esm */, Ref<JSON::ArrayOf<String>> /* cjs */, String /* cwd */, String /* main */, Ref<JSON::ArrayOf<String>> /* argv */>;

Protocol::ErrorStringOr<ModuleGraph> InspectorLifecycleAgent::getModuleGraph()
{
    auto& vm = m_globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* global = defaultGlobalObject(&m_globalObject);
    auto* cjsMap = global->requireMap();

    Ref<JSON::ArrayOf<String>> esm = JSON::ArrayOf<String>::create();
    {
        Vector<String> keys;
        for (auto& [key, entry] : global->moduleLoader()->moduleMap()) {
            if (key.first)
                keys.append(String { key.first });
        }
        // ModuleMap is hash-ordered; sort so the inspector output is stable.
        std::sort(keys.begin(), keys.end(), WTF::codePointCompareLessThan);
        for (auto& k : keys)
            esm->addItem(k);
    }

    Ref<JSON::ArrayOf<String>> cjs = JSON::ArrayOf<String>::create();
    {
        auto iter2 = JSC::JSMapIterator::create(vm, global->mapIteratorStructure(), cjsMap, JSC::IterationKind::Keys);
        RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to create iterator"_s)));
        JSC::JSValue value;
        while (iter2->next(global, value)) {
            cjs->addItem(value.toWTFString(global));
            RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to add item to cjs array"_s)));
        }
        RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to iterate over cjs map"_s)));
    }

    auto* process = global->processObject();

    Ref<JSON::ArrayOf<String>> argv = JSON::ArrayOf<String>::create();
    {

        auto value = process->get(global, JSC::Identifier::fromString(vm, "argv"_s));
        RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to get argv"_s)));
        auto* array = dynamicDowncast<JSC::JSArray>(value);
        if (!array)
            return makeUnexpected(ErrorString("process.argv must be an array"_s));
        for (size_t i = 0, length = array->length(); i < length; i++) {
            auto value = array->getIndex(global, i);
            RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to get value at index"_s)));
            auto string = value.toWTFString(global);
            RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to convert value to string"_s)));
            argv->addItem(string);
        }
    }

    String main;
    {
        auto& builtinNames = Bun::builtinNames(vm);
        auto value = global->bunObject()->get(global, builtinNames.mainPublicName());
        RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to get main"_s)));
        main = value.toWTFString(global);
        RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to convert value to string"_s)));
    }

    String cwd;
    {
        cwd = Bun::Bindgen::ZigExports::bunBindgenZig_Process_getCwd(&m_globalObject);
        RETURN_IF_EXCEPTION(scope, makeUnexpected(ErrorString("Failed to get cwd"_s)));
    }

    return ModuleGraph { WTF::move(esm), WTF::move(cjs), WTF::move(cwd), WTF::move(main), WTF::move(argv) };
}

}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorLifecycleAgentReportReload(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorLifecycleAgentReportReload_Arguments& args)
{
    args.agent->reportReload();
}

Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorLifecycleAgentReportError_Return Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorLifecycleAgentReportError(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorLifecycleAgentReportError_Arguments& args)
{
    ASSERT(args.agent);
    args.agent->reportError(args.message, args.name, args.frames, args.sourceLines);
    return {};
}
