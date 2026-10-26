#include "InspectorTestReporterAgent.h"
#include "ErrorStackFrame.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/InspectorFrontendRouter.h>
#include <JavaScriptCore/InspectorBackendDispatcher.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include "ErrorStackTrace.h"
#include "ZigGlobalObject.h"

#include "ModuleLoader.h"
#include <wtf/TZoneMallocInlines.h>

using namespace JSC;
using namespace Inspector;

namespace Inspector {

WTF_MAKE_TZONE_ALLOCATED_IMPL(InspectorTestReporterAgent);

InspectorTestReporterAgent::InspectorTestReporterAgent(JSC::JSGlobalObject& globalObject)
    : InspectorAgentBase("TestReporter"_s)
    , m_globalObject(globalObject)
    , m_backendDispatcher(TestReporterBackendDispatcher::create(globalObject.inspectorController().backendDispatcher(), this))
    , m_frontendDispatcher(makeUnique<TestReporterFrontendDispatcher>(const_cast<FrontendRouter&>(globalObject.inspectorController().frontendRouter())))
{
}

InspectorTestReporterAgent::~InspectorTestReporterAgent()
{
    if (m_enabled) {
        Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorTestReporterAgent(this, false);
    }
}

void InspectorTestReporterAgent::didCreateFrontendAndBackend()
{
}

void InspectorTestReporterAgent::willDestroyFrontendAndBackend(DisconnectReason)
{
    disable();
}

Protocol::ErrorStringOr<void> InspectorTestReporterAgent::enable()
{
    if (m_enabled)
        return {};

    m_enabled = true;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorTestReporterAgent(this, true);
    return {};
}

Protocol::ErrorStringOr<void> InspectorTestReporterAgent::disable()
{
    if (!m_enabled)
        return {};

    m_enabled = false;
    Bun::Bindgen::ZigExports::bunBindgenZig_inspector_agents_setInspectorTestReporterAgent(this, false);
    return {};
}

void InspectorTestReporterAgent::reportTestFound(JSC::CallFrame* callFrame, int testId, const String& name, Protocol::TestReporter::TestType type, int parentId)
{
    if (!m_enabled)
        return;

    JSC::LineColumn lineColumn;
    JSC::SourceID sourceID = 0;
    String sourceURL;

    Bun::RemappableStackFrame remappedFrame;

    auto* globalObject = &m_globalObject;
    auto& vm = JSC::getVM(globalObject);

    JSC::StackVisitor::visit(callFrame, vm, [&](JSC::StackVisitor& visitor) -> WTF::IterationStatus {
        if (Zig::isImplementationVisibilityPrivate(visitor))
            return WTF::IterationStatus::Continue;

        if (visitor->hasLineAndColumnInfo()) {
            lineColumn = visitor->computeLineAndColumn();

            String sourceURLForFrame = Zig::sourceURL(visitor);

            // Sometimes, the sourceURL is empty.
            // For example, pages in Next.js.
            if (sourceURLForFrame.isEmpty()) {
                auto* codeBlock = visitor->codeBlock();
                ASSERT(codeBlock);

                // hasLineAndColumnInfo() checks codeBlock(), so this is safe to access here.
                const auto& source = codeBlock->source();

                // source.isNull() is true when the SourceProvider is a null pointer.
                if (!source.isNull()) {
                    auto* provider = source.provider();
                    sourceID = provider->asID();
                }
            }

            sourceURL = sourceURLForFrame;

            return WTF::IterationStatus::Done;
        }

        return WTF::IterationStatus::Continue;
    });

    if (!sourceURL.isEmpty() and lineColumn.line > 0) {
        OrdinalNumber originalLine = OrdinalNumber::fromOneBasedInt(lineColumn.line);
        OrdinalNumber originalColumn = OrdinalNumber::fromOneBasedInt(lineColumn.column);

        remappedFrame.position.lineZeroBased = originalLine.zeroBasedInt();
        remappedFrame.position.columnZeroBased = originalColumn.zeroBasedInt();
        remappedFrame.sourceURL = sourceURL;

        Bun::remapStackFramePosition(Bun::vm(globalObject), remappedFrame);

        sourceURL = remappedFrame.sourceURL;
        lineColumn.line = OrdinalNumber::fromZeroBasedInt(remappedFrame.position.lineZeroBased).oneBasedInt();
        lineColumn.column = OrdinalNumber::fromZeroBasedInt(remappedFrame.position.columnZeroBased).oneBasedInt();
    }

    m_frontendDispatcher->found(
        testId,
        sourceID > 0 ? String::number(sourceID) : String(),
        sourceURL,
        lineColumn.line,
        name,
        type,
        parentId > 0 ? parentId : std::optional<int>());
}

void InspectorTestReporterAgent::reportTestFoundWithLocation(int testId, const String& name, Protocol::TestReporter::TestType type, int parentId, const String& sourceURL, int line)
{
    if (!m_enabled)
        return;

    m_frontendDispatcher->found(
        testId,
        String(), // sourceID - not available for retroactively reported tests
        sourceURL,
        line,
        name,
        type,
        parentId > 0 ? parentId : std::optional<int>());
}

void InspectorTestReporterAgent::reportTestStart(int testId)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->start(testId);
}

void InspectorTestReporterAgent::reportTestEnd(int testId, Protocol::TestReporter::TestStatus status, double elapsed)
{
    if (!m_enabled || !m_frontendDispatcher)
        return;

    m_frontendDispatcher->end(testId, status, elapsed);
}

} // namespace Inspector

template<typename InspectorTestType>
static Inspector::Protocol::TestReporter::TestType inspectorTestType(InspectorTestType type)
{
    switch (type) {
    case decltype(type)::test:
        return Inspector::Protocol::TestReporter::TestType::Test;
    case decltype(type)::describe:
        return Inspector::Protocol::TestReporter::TestType::Describe;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestFound(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestFound_Arguments& args)
{
    args.agent->reportTestFound(args.callFrame, args.testId, args.name, inspectorTestType(args.itemType), args.parentId);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestFoundWithLocation(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestFoundWithLocation_Arguments& args)
{
    args.agent->reportTestFoundWithLocation(args.testId, args.name, inspectorTestType(args.itemType), args.parentId, args.sourceURL, args.line);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestStart(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestStart_Arguments& args)
{
    args.agent->reportTestStart(args.testId);
}

void Bun::Bindgen::Engine::bunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestEnd(
    const Bun::Bindgen::Engine::BunBindgenEngine_inspector_agents_inspectorTestReporterAgentReportTestEnd_Arguments& args)
{
    Protocol::TestReporter::TestStatus status;
    switch (args.status) {
    case decltype(args.status)::pass:
        status = Protocol::TestReporter::TestStatus::Pass;
        break;
    case decltype(args.status)::fail:
        status = Protocol::TestReporter::TestStatus::Fail;
        break;
    case decltype(args.status)::timeout:
        status = Protocol::TestReporter::TestStatus::Timeout;
        break;
    case decltype(args.status)::skip:
        status = Protocol::TestReporter::TestStatus::Skip;
        break;
    case decltype(args.status)::todo:
        status = Protocol::TestReporter::TestStatus::Todo;
        break;
    case decltype(args.status)::skipped_because_label:
        status = Protocol::TestReporter::TestStatus::Skipped_because_label;
        break;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }

    args.agent->reportTestEnd(args.testId, status, args.elapsed);
}
