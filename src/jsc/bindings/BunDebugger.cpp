#include "root.h"

#include "BunDebugger.h"
#include "BunClientData.h"
#include "AsyncContextFrame.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

#include <JavaScriptCore/InspectorFrontendChannel.h>
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/JSGlobalObjectDebugger.h>
#include <JavaScriptCore/Debugger.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <wtf/Condition.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <new>
#include "ScriptExecutionContext.h"
#include "debug-helpers.h"
#include "BunInjectedScriptHost.h"
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>

#include "InspectorLifecycleAgent.h"
#include "InspectorTestReporterAgent.h"
#include "InspectorBunFrontendDevServerAgent.h"
#include "InspectorHTTPServerAgent.h"

namespace Bun {
using namespace JSC;
using namespace WebCore;

class BunInspectorConnection;
struct InspectorTarget;
static JSC::JSValue debuggerCallback(JSC::VM&, const BunInspectorConnection&);
static void removeDebuggerCallback(JSC::VM&, const BunInspectorConnection&);
static void removeInspectorConnection(ScriptExecutionContextIdentifier, const BunInspectorConnection&);
static RefPtr<BunInspectorConnection> firstInspectorConnection(ScriptExecutionContextIdentifier);
enum class InspectorWork { NoConnections, Idle, Ready };
static InspectorWork inspectorWorkForContext(ScriptExecutionContextIdentifier);

static WTF::Lock inspectorConnectionsLock = WTF::Lock();
static InspectorTarget* inspectorTargets = nullptr;

// When the inspected JS thread is paused at a breakpoint (inside runWhilePaused),
// it waits on this condition for the debugger thread to deliver new messages or
// for a connection status change. This replaces a busy spin loop that would pin
// one core at 100% CPU while paused. Wrapped in a function-local static so it
// doesn't add a static initializer to the binary.
struct PausedWait {
    WTF::Lock lock;
    WTF::Condition condition;
};

static PausedWait& pausedWait()
{
    static PausedWait instance;
    return instance;
}

class BunJSGlobalObjectDebuggable final : public JSC::JSGlobalObjectDebuggable {
public:
    using Base = JSC::JSGlobalObjectDebuggable;

    BunJSGlobalObjectDebuggable(JSC::JSGlobalObject& globalObject)
        : Base(globalObject)
    {
    }

    ~BunJSGlobalObjectDebuggable() final
    {
    }

    static Ref<BunJSGlobalObjectDebuggable> create(JSGlobalObject& globalObject)
    {
        return adoptRef(*new BunJSGlobalObjectDebuggable(globalObject));
    }

    void pauseWaitingForAutomaticInspection() override
    {
    }
    void unpauseForResolvedAutomaticInspection() override
    {
        if (waitingForConnection) {
            waitingForConnection = false;
            Bun::Bindgen::ZigExports::bunBindgenZig_BunDebugger_debuggerDidConnect();
        }
    }

    bool waitingForConnection { false };
};

static BunJSGlobalObjectDebuggable& initializeDebugger(Zig::GlobalObject& globalObject)
{
    if (!globalObject.bunInspectorInitialized) {
        globalObject.m_inspectorController = makeUnique<Inspector::JSGlobalObjectInspectorController>(globalObject, Bun::BunInjectedScriptHost::create());
        globalObject.m_inspectorDebuggable = BunJSGlobalObjectDebuggable::create(globalObject);
        globalObject.m_inspectorDebuggable->init();
        globalObject.bunInspectorInitialized = true;
        globalObject.setInspectable(true);
        globalObject.inspectorDebuggable().setInspectable(true);
    }
    return static_cast<BunJSGlobalObjectDebuggable&>(globalObject.inspectorDebuggable());
}

enum class ConnectionStatus : int32_t {
    Pending = 0,
    Connected = 1,
    Disconnecting = 2,
    Disconnected = 3,
};

class BunInspectorConnection : public Inspector::FrontendChannel, public ThreadSafeRefCounted<BunInspectorConnection> {

public:
    BunInspectorConnection(ScriptExecutionContextIdentifier identifier, bool shouldRefEventLoop, ScriptExecutionContextIdentifier debuggerContextIdentifier)
        : Inspector::FrontendChannel()
        , scriptExecutionContextIdentifier(identifier)
        , debuggerContextIdentifier(debuggerContextIdentifier)
        , unrefOnDisconnect(shouldRefEventLoop)
    {
    }

    ~BunInspectorConnection()
    {
        ASSERT(!nextInTarget);
    }

    static RefPtr<BunInspectorConnection> create(ScriptExecutionContextIdentifier identifier, bool shouldRefEventLoop, ScriptExecutionContextIdentifier debuggerContextIdentifier)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(BunInspectorConnection)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) BunInspectorConnection(identifier, shouldRefEventLoop, debuggerContextIdentifier));
    }

    ConnectionType connectionType() const override
    {
        return ConnectionType::Remote;
    }

    void doConnect(WebCore::ScriptExecutionContext& context)
    {
        auto expected = ConnectionStatus::Pending;
        if (!status.compare_exchange_strong(expected, ConnectionStatus::Connected))
            return;
        auto* globalObject = static_cast<Zig::GlobalObject*>(context.jsGlobalObject());
        if (this->unrefOnDisconnect) {
            Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopRefConcurrently(static_cast<Zig::GlobalObject*>(globalObject)->bunVM());
        }
        initializeDebugger(*globalObject);

        if (!globalObject->inspectorAlternateAgentsRegistered) {
            globalObject->inspectorController().registerAlternateAgent(
                WTF::makeUniqueRef<Inspector::InspectorLifecycleAgent>(*globalObject));
            globalObject->inspectorController().registerAlternateAgent(
                WTF::makeUniqueRef<Inspector::InspectorTestReporterAgent>(*globalObject));
            globalObject->inspectorController().registerAlternateAgent(
                WTF::makeUniqueRef<Inspector::InspectorBunFrontendDevServerAgent>(*globalObject));
            globalObject->inspectorController().registerAlternateAgent(
                WTF::makeUniqueRef<Inspector::InspectorHTTPServerAgent>(*globalObject));
            globalObject->inspectorAlternateAgentsRegistered = true;
        }

        this->hasEverConnected = true;
        globalObject->inspectorController().connectFrontend(*this, true, false);

        Inspector::JSGlobalObjectDebugger* debugger = reinterpret_cast<Inspector::JSGlobalObjectDebugger*>(globalObject->debugger());
        if (debugger) {
            debugger->runWhilePausedCallback = [](JSC::JSGlobalObject& globalObject, bool& isDoneProcessingEvents) -> void {
                BunInspectorConnection::runWhilePaused(globalObject, isDoneProcessingEvents);
            };
        }

        this->receiveMessagesOnInspectorThread(context, static_cast<Zig::GlobalObject*>(globalObject), false);
    }

    bool connect()
    {
        switch (this->status) {
        case ConnectionStatus::Disconnected:
        case ConnectionStatus::Disconnecting: {
            return false;
        }
        default: {
            break;
        }
        }

        notifyPausedThread();

        return ScriptExecutionContext::ensureOnContextThread(scriptExecutionContextIdentifier, [connection = Ref { *this }](ScriptExecutionContext& context) {
            switch (connection->status) {
            case ConnectionStatus::Pending: {
                connection->doConnect(context);
                break;
            }
            default: {
                break;
            }
            }
        });
    }

    void disconnect()
    {
        auto previous = status.load();
        for (;;) {
            if (previous == ConnectionStatus::Disconnected || previous == ConnectionStatus::Disconnecting)
                return;
            if (status.compare_exchange_weak(previous, ConnectionStatus::Disconnecting))
                break;
        }
        notifyPausedThread();

        if (!ScriptExecutionContext::ensureOnContextThread(scriptExecutionContextIdentifier, [connection = Ref { *this }](ScriptExecutionContext& context) {
            connection->finishDisconnect(context);
        })) {
            status.store(ConnectionStatus::Disconnected);
            discardMessages();
            removeInspectorConnection(scriptExecutionContextIdentifier, *this);
            releaseCallback();
        }
    }

    void finishDisconnect(ScriptExecutionContext& context)
    {
        if (status.exchange(ConnectionStatus::Disconnected) == ConnectionStatus::Disconnected)
            return;
        if (hasEverConnected) {
            context.jsGlobalObject()->inspectorDebuggable().disconnect(*this);
            hasEverConnected = false;
            if (unrefOnDisconnect) {
                unrefOnDisconnect = false;
                Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopUnrefConcurrently(static_cast<Zig::GlobalObject*>(context.jsGlobalObject())->bunVM());
            }
        }
        discardMessages();
        removeInspectorConnection(scriptExecutionContextIdentifier, *this);
        releaseCallback();
        notifyPausedThread();
    }

    void releaseCallback()
    {
        ScriptExecutionContext::ensureOnContextThread(debuggerContextIdentifier, [connection = Ref { *this }](ScriptExecutionContext& callbackContext) {
            removeDebuggerCallback(callbackContext.vm(), connection.get());
        });
    }

    void discardMessages()
    {
        {
            Locker<Lock> locker(debuggerThreadMessagesLock);
            debuggerThreadMessages.clear();
        }
        {
            Locker<Lock> locker(jsThreadMessagesLock);
            jsThreadMessages.clear();
        }
    }

    void sendMessageToFrontend(const String& message) override
    {
        if (message.length() == 0)
            return;

        this->sendMessageToDebuggerThread(message.isolatedCopy());
    }

    static void runWhilePaused(JSGlobalObject& globalObject, bool& isDoneProcessingEvents)
    {
        Zig::GlobalObject* global = static_cast<Zig::GlobalObject*>(&globalObject);
        const auto identifier = global->scriptExecutionContext()->identifier();

        while (!isDoneProcessingEvents) {
            auto connection = firstInspectorConnection(identifier);
            while (connection) {
                RefPtr<BunInspectorConnection> next;
                {
                    Locker<Lock> locker(inspectorConnectionsLock);
                    next = connection->nextInTarget;
                }
                connection->receiveMessagesOnInspectorThread(*global->scriptExecutionContext(), global, true);
                if (isDoneProcessingEvents)
                    break;
                connection = WTF::move(next);
            }

            if (isDoneProcessingEvents)
                break;

            InspectorWork work;
            {
                auto& wait = pausedWait();
                Locker<Lock> waitLocker(wait.lock);
                work = inspectorWorkForContext(identifier);
                if (work == InspectorWork::Idle)
                    wait.condition.waitFor(wait.lock, Seconds(1));
            }
            if (work == InspectorWork::NoConnections) {
                if (global->debugger() && global->debugger()->isPaused()) {
                    global->debugger()->continueProgram();
                }
                break;
            }
        }
    }

    // Wake the inspected thread if it is blocked inside runWhilePaused.
    // Safe to call from any thread; cheap when nobody is waiting.
    static void notifyPausedThread()
    {
        auto& wait = pausedWait();
        Locker<Lock> locker(wait.lock);
        wait.condition.notifyAll();
    }

    void receiveMessagesOnInspectorThread(ScriptExecutionContext& context, Zig::GlobalObject* globalObject, bool connectIfNeeded)
    {
        if (status.load() >= ConnectionStatus::Disconnecting)
            return;
        if (status.load() == ConnectionStatus::Pending) {
            if (connectIfNeeded)
                doConnect(context);
            return;
        }
        this->jsThreadMessageScheduledCount.store(0);
        WTF::Vector<WTF::String, 12> messages;

        {
            Locker<Lock> locker(jsThreadMessagesLock);
            this->jsThreadMessages.swap(messages);
        }

        auto& dispatcher = globalObject->inspectorDebuggable();
        Inspector::JSGlobalObjectDebugger* debugger = reinterpret_cast<Inspector::JSGlobalObjectDebugger*>(globalObject->debugger());

        for (auto& message : messages) {
            if (status.load() >= ConnectionStatus::Disconnecting)
                break;
            dispatcher.dispatchMessageFromRemote(WTF::move(message));
            if (!debugger) {
                debugger = reinterpret_cast<Inspector::JSGlobalObjectDebugger*>(globalObject->debugger());
                if (debugger) {
                    debugger->runWhilePausedCallback = [](JSC::JSGlobalObject& globalObject, bool& isDoneProcessingEvents) -> void {
                        runWhilePaused(globalObject, isDoneProcessingEvents);
                    };
                }
            }
        }
    }

    void receiveMessagesOnDebuggerThread(ScriptExecutionContext& context, Zig::GlobalObject* debuggerGlobalObject)
    {
        if (status.load() >= ConnectionStatus::Disconnecting)
            return;
        debuggerThreadMessageScheduledCount.store(0);
        WTF::Vector<WTF::String, 12> messages;

        {
            Locker<Lock> locker(debuggerThreadMessagesLock);
            this->debuggerThreadMessages.swap(messages);
        }

        const JSValue callback = debuggerCallback(debuggerGlobalObject->vm(), *this);
        if (!callback)
            return;
        auto& vm = debuggerGlobalObject->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        MarkedArgumentBuffer arguments;
        arguments.ensureCapacity(messages.size());
        if (arguments.hasOverflowed()) {
            throwOutOfMemoryError(debuggerGlobalObject, scope);
            return;
        }

        for (auto& message : messages) {
            arguments.append(jsString(vm, message));
        }

        messages.clear();

        if (arguments.hasOverflowed()) {
            throwOutOfMemoryError(debuggerGlobalObject, scope);
            return;
        }
        AsyncContextFrame::call(debuggerGlobalObject, callback, jsUndefined(), arguments);
        RETURN_IF_EXCEPTION(scope, void());
    }

    void sendMessageToDebuggerThread(WTF::String&& inputMessage)
    {
        {
            Locker<Lock> locker(debuggerThreadMessagesLock);
            if (status.load() >= ConnectionStatus::Disconnecting)
                return;
            debuggerThreadMessages.append(WTF::move(inputMessage));
        }

        if (this->debuggerThreadMessageScheduledCount++ == 0) {
            if (!ScriptExecutionContext::postTaskTo(debuggerContextIdentifier, [connection = Ref { *this }](ScriptExecutionContext& context) {
                connection->receiveMessagesOnDebuggerThread(context, static_cast<Zig::GlobalObject*>(context.jsGlobalObject()));
            })) {
                Locker<Lock> locker(debuggerThreadMessagesLock);
                debuggerThreadMessages.clear();
                debuggerThreadMessageScheduledCount.store(0);
            }
        }
    }

    bool sendMessageToInspectorFromDebuggerThread(Vector<WTF::String, 12>&& inputMessages)
    {
        {
            Locker<Lock> locker(jsThreadMessagesLock);
            if (status.load() >= ConnectionStatus::Disconnecting)
                return true;
            if (inputMessages.size() > std::numeric_limits<size_t>::max() - jsThreadMessages.size()
                || !jsThreadMessages.tryReserveCapacity(jsThreadMessages.size() + inputMessages.size()))
                return false;
            jsThreadMessages.appendVector(WTF::move(inputMessages));
        }

        notifyPausedThread();

        if (this->jsThreadMessageScheduledCount++ == 0) {
            if (!ScriptExecutionContext::postTaskTo(scriptExecutionContextIdentifier, [connection = Ref { *this }](ScriptExecutionContext& context) {
                connection->receiveMessagesOnInspectorThread(context, static_cast<Zig::GlobalObject*>(context.jsGlobalObject()), true);
            }))
                disconnect();
        }
        return true;
    }

    WTF::Vector<WTF::String, 12> debuggerThreadMessages;
    WTF::Lock debuggerThreadMessagesLock = WTF::Lock();
    std::atomic<uint32_t> debuggerThreadMessageScheduledCount { 0 };

    WTF::Vector<WTF::String, 12> jsThreadMessages;
    WTF::Lock jsThreadMessagesLock = WTF::Lock();
    std::atomic<uint32_t> jsThreadMessageScheduledCount { 0 };

    ScriptExecutionContextIdentifier scriptExecutionContextIdentifier;
    const ScriptExecutionContextIdentifier debuggerContextIdentifier;

    std::atomic<ConnectionStatus> status = ConnectionStatus::Pending;

    bool unrefOnDisconnect = false;

    bool hasEverConnected = false;
    RefPtr<BunInspectorConnection> nextInTarget;
};

struct InspectorTarget {
    ScriptExecutionContextIdentifier identifier;
    RefPtr<BunInspectorConnection> connections { nullptr };
    InspectorTarget* next { nullptr };
    InspectorTarget* nextForVM { nullptr };
};

static InspectorTarget* findInspectorTargetLocked(ScriptExecutionContextIdentifier identifier)
{
    for (auto* target = inspectorTargets; target; target = target->next) {
        if (target->identifier == identifier)
            return target;
    }
    return nullptr;
}

static RefPtr<BunInspectorConnection> firstInspectorConnection(ScriptExecutionContextIdentifier identifier)
{
    Locker<Lock> locker(inspectorConnectionsLock);
    if (auto* target = findInspectorTargetLocked(identifier))
        return target->connections;
    return { };
}

static InspectorWork inspectorWorkForContext(ScriptExecutionContextIdentifier identifier)
{
    Locker<Lock> locker(inspectorConnectionsLock);
    auto* target = findInspectorTargetLocked(identifier);
    if (!target)
        return InspectorWork::NoConnections;
    auto result = InspectorWork::NoConnections;
    for (auto* connection = target->connections.get(); connection; connection = connection->nextInTarget.get()) {
        auto status = connection->status.load();
        if (status >= ConnectionStatus::Disconnecting)
            continue;
        if (status == ConnectionStatus::Pending)
            return InspectorWork::Ready;
        result = InspectorWork::Idle;
        Locker<Lock> messagesLocker(connection->jsThreadMessagesLock);
        if (!connection->jsThreadMessages.isEmpty())
            return InspectorWork::Ready;
    }
    return result;
}

static void removeInspectorConnection(ScriptExecutionContextIdentifier identifier, const BunInspectorConnection& connection)
{
    Locker<Lock> locker(inspectorConnectionsLock);
    auto* target = findInspectorTargetLocked(identifier);
    if (!target)
        return;
    auto* entry = &target->connections;
    while (*entry) {
        if (entry->get() == &connection) {
            auto removed = WTF::move(*entry);
            *entry = WTF::move(removed->nextInTarget);
            return;
        }
        entry = &(*entry)->nextInTarget;
    }
}

struct DebuggerCallback {
    DebuggerCallback(JSC::VM& vm, BunInspectorConnection& connection, JSValue callback)
        : connection(connection)
        , callback(vm, callback)
    {
    }

    Ref<BunInspectorConnection> connection;
    JSC::Strong<JSC::Unknown> callback;
    DebuggerCallback* next { nullptr };
};

static JSC::JSValue debuggerCallback(JSC::VM& vm, const BunInspectorConnection& connection)
{
    for (auto* entry = WebCore::clientData(vm)->debuggerCallbacksHead; entry; entry = entry->next) {
        if (&entry->connection.get() == &connection)
            return entry->callback.get();
    }
    return {};
}

static void removeDebuggerCallback(JSC::VM& vm, const BunInspectorConnection& connection)
{
    auto** entry = &WebCore::clientData(vm)->debuggerCallbacksHead;
    while (*entry) {
        if (&(*entry)->connection.get() == &connection) {
            auto* removed = *entry;
            *entry = removed->next;
            delete removed;
            return;
        }
        entry = &(*entry)->next;
    }
}

void clearDebuggerCallbacksForVM(WebCore::JSVMClientData& clientData)
{
    while (auto* entry = clientData.debuggerCallbacksHead) {
        clientData.debuggerCallbacksHead = entry->next;
        entry->connection->disconnect();
        delete entry;
    }
}

void Bindgen::Engine::releaseInspectorConnection(BunInspectorConnection* connection)
{
    connection->releaseCallback();
    connection->disconnect();
    connection->deref();
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_sendInspectorMessages(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_sendInspectorMessages_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    Vector<WTF::String, 12> messages;
    if (!messages.tryReserveCapacity(args.messages.size())) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    for (const auto& message : args.messages)
        messages.append(message.isolatedCopy());
    if (!args.connection->sendMessageToInspectorFromDebuggerThread(WTF::move(messages)))
        throwOutOfMemoryError(&context.globalObject, scope);
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_disconnectInspectorConnection(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_disconnectInspectorConnection_Arguments& args)
{
    removeDebuggerCallback(context.globalObject.vm(), *args.connection);
    args.connection->disconnect();
}

uint32_t Bindgen::Engine::bunBindgenEngine_BunDebugger_createJSDebugger(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_createJSDebugger_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* clientData = WebCore::clientData(globalObject->vm());
    const auto identifier = globalObject->scriptExecutionContext()->identifier();
    initializeDebugger(*globalObject).waitingForConnection = args.pauseOnStart;
    {
        Locker<Lock> locker(inspectorConnectionsLock);
        if (findInspectorTargetLocked(identifier))
            return identifier;
    }

    auto target = std::unique_ptr<InspectorTarget>(new (std::nothrow) InspectorTarget { identifier });
    if (!target) {
        auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
        throwOutOfMemoryError(globalObject, scope);
        return 0;
    }
    {
        Locker<Lock> locker(inspectorConnectionsLock);
        RELEASE_ASSERT(!findInspectorTargetLocked(identifier));
        target->next = inspectorTargets;
        target->nextForVM = clientData->inspectorTargetsHead;
        clientData->inspectorTargetsHead = target.get();
        inspectorTargets = target.release();
    }

    return identifier;
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_disconnectInspectorConnections(
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_disconnectInspectorConnections_Arguments& args)
{
    auto* clientData = WebCore::clientData(*args.vm);
    while (auto* target = clientData->inspectorTargetsHead) {
        clientData->inspectorTargetsHead = target->nextForVM;
        const auto identifier = target->identifier;
        RefPtr<BunInspectorConnection> connections;
        {
            Locker<Lock> locker(inspectorConnectionsLock);
            auto** entry = &inspectorTargets;
            while (*entry != target) {
                RELEASE_ASSERT(*entry);
                entry = &(*entry)->next;
            }
            *entry = target->next;
            connections = WTF::move(target->connections);
        }
        delete target;
        if (!connections)
            continue;
        auto* context = ScriptExecutionContext::getScriptExecutionContext(identifier);
        while (connections) {
            auto connection = WTF::move(connections);
            {
                Locker<Lock> locker(inspectorConnectionsLock);
                connections = WTF::move(connection->nextInTarget);
            }
            if (context)
                connection->finishDisconnect(*context);
            else {
                connection->status.store(ConnectionStatus::Disconnected);
                connection->discardMessages();
                connection->releaseCallback();
            }
        }
    }
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_debuggerWillHotReload(
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_debuggerWillHotReload_Arguments& args)
{
    Locker<Lock> locker(inspectorConnectionsLock);
    auto* target = findInspectorTargetLocked(args.scriptId);
    if (!target)
        return;
    for (auto* connection = target->connections.get(); connection; connection = connection->nextInTarget.get())
        connection->sendMessageToFrontend("{\"method\":\"Bun.canReload\"}"_s);
}

std::optional<BunInspectorConnection*> Bindgen::Engine::bunBindgenEngine_BunDebugger_createInspectorConnection(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_createInspectorConnection_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* debuggerGlobalObject = dynamicDowncast<Zig::GlobalObject>(globalObject);
    if (!debuggerGlobalObject)
        return std::nullopt;

    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    bool shouldRef = !args.shouldNotRef;
    auto connection = BunInspectorConnection::create(
        static_cast<ScriptExecutionContextIdentifier>(args.scriptId),
        shouldRef, debuggerGlobalObject->scriptExecutionContext()->identifier());
    if (!connection) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    auto callback = std::unique_ptr<DebuggerCallback>(new (std::nothrow) DebuggerCallback(vm, *connection, args.onMessage));
    if (!callback) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }

    {
        Locker<Lock> locker(inspectorConnectionsLock);
        auto* target = findInspectorTargetLocked(connection->scriptExecutionContextIdentifier);
        if (!target)
            return std::nullopt;
        connection->nextInTarget = WTF::move(target->connections);
        target->connections = connection;
    }
    auto* clientData = WebCore::clientData(vm);
    callback->next = clientData->debuggerCallbacksHead;
    clientData->debuggerCallbacksHead = callback.release();
    if (!connection->connect()) {
        removeDebuggerCallback(vm, *connection);
        removeInspectorConnection(connection->scriptExecutionContextIdentifier, *connection);
        return std::nullopt;
    }

    return connection.leakRef();
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_startJSDebuggerThread(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_startJSDebuggerThread_Arguments& args)
{
    auto* debuggerGlobalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    JSC::VM& vm = debuggerGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue defaultValue = debuggerGlobalObject->internalModuleRegistry()->requireId(debuggerGlobalObject, vm, InternalModuleRegistry::Field::InternalDebugger);
    RETURN_IF_EXCEPTION(scope, void());
    JSFunction* debuggerDefaultFn = uncheckedDowncast<JSFunction>(defaultValue.asCell());

    MarkedArgumentBuffer arguments;

    arguments.append(jsNumber(args.scriptId));
    arguments.append(jsString(vm, args.portOrPath));
    arguments.append(JSFunction::create(vm, debuggerGlobalObject, 3, String(), bun_bindgen_host_BunDebugger_createConnection, ImplementationVisibility::Public));
    arguments.append(JSFunction::create(vm, debuggerGlobalObject, 1, String("send"_s), bun_bindgen_host_BunDebugger_send, ImplementationVisibility::Public));
    arguments.append(JSFunction::create(vm, debuggerGlobalObject, 0, String("disconnect"_s), bun_bindgen_host_BunDebugger_disconnect, ImplementationVisibility::Public));
    arguments.append(jsBoolean(args.isAutomatic));
    arguments.append(jsBoolean(args.isURLServer));
    if (arguments.hasOverflowed()) {
        throwOutOfMemoryError(debuggerGlobalObject, scope);
        return;
    }

    JSC::call(debuggerGlobalObject, debuggerDefaultFn, arguments, "Bun__initJSDebuggerThread - debuggerDefaultFn"_s);
    RETURN_IF_EXCEPTION(scope, void());
}

template<typename CallType>
static Inspector::InspectorDebuggerAgent::AsyncCallType getCallType(CallType callType)
{
    switch (callType) {
    case CallType::DOMTimer:
        return Inspector::InspectorDebuggerAgent::AsyncCallType::DOMTimer;
    case CallType::EventListener:
        return Inspector::InspectorDebuggerAgent::AsyncCallType::EventListener;
    case CallType::PostMessage:
        return Inspector::InspectorDebuggerAgent::AsyncCallType::PostMessage;
    case CallType::RequestAnimationFrame:
        return Inspector::InspectorDebuggerAgent::AsyncCallType::RequestAnimationFrame;
    case CallType::Microtask:
        return Inspector::InspectorDebuggerAgent::AsyncCallType::Microtask;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_debuggerDidScheduleAsyncCall(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_debuggerDidScheduleAsyncCall_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* agent = debuggerAgent(globalObject);
    if (!agent)
        return;

    agent->didScheduleAsyncCall(globalObject, getCallType(args.callType), args.callbackId, args.singleShot);
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_debuggerDidCancelAsyncCall(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_debuggerDidCancelAsyncCall_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* agent = debuggerAgent(globalObject);
    if (!agent)
        return;

    agent->didCancelAsyncCall(getCallType(args.callType), args.callbackId);
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_debuggerDidDispatchAsyncCall(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_debuggerDidDispatchAsyncCall_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* agent = debuggerAgent(globalObject);
    if (!agent)
        return;

    agent->didDispatchAsyncCall(getCallType(args.callType), args.callbackId);
}

void Bindgen::Engine::bunBindgenEngine_BunDebugger_debuggerWillDispatchAsyncCall(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunDebugger_debuggerWillDispatchAsyncCall_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* agent = debuggerAgent(globalObject);
    if (!agent)
        return;

    agent->willDispatchAsyncCall(getCallType(args.callType), args.callbackId);
}
}
