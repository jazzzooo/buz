#include "root.h"
#include "ScriptExecutionContext.h"
#include "SchemaBindings.h"
#include "ContextDestructionObserver.h"
#include "MessagePortPipe.h"

#include "libusockets.h"
#include "_libusockets.h"
#include "BunClientData.h"
#include "EventLoopTask.h"
#include <wtf/HashMap.h>

namespace WebCore {
static constexpr ScriptExecutionContextIdentifier INITIAL_IDENTIFIER_INTERNAL = 1;

static std::atomic<unsigned> lastUniqueIdentifier = INITIAL_IDENTIFIER_INTERNAL;

#if ASSERT_ENABLED
static ScriptExecutionContextIdentifier initialIdentifier()
{
    static bool hasCalledInitialIdentifier = false;
    ASSERT_WITH_MESSAGE(!hasCalledInitialIdentifier, "ScriptExecutionContext::initialIdentifier() cannot be called more than once. Use generateIdentifier() instead.");
    hasCalledInitialIdentifier = true;
    return INITIAL_IDENTIFIER_INTERNAL;
}
#else
static ScriptExecutionContextIdentifier initialIdentifier()
{
    return INITIAL_IDENTIFIER_INTERNAL;
}
#endif

#if ENABLE(MALLOC_BREAKDOWN)
DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(ScriptExecutionContext);
#endif

ScriptExecutionContext::ScriptExecutionContext(JSC::VM* vm, JSC::JSGlobalObject* globalObject)
    : m_vm(vm)
    , m_globalObject(globalObject)
    , m_identifier(initialIdentifier())
{
    relaxAdoptionRequirement();
    addToContextsMap();
}

ScriptExecutionContext::ScriptExecutionContext(JSC::VM* vm, JSC::JSGlobalObject* globalObject, ScriptExecutionContextIdentifier identifier)
    : m_vm(vm)
    , m_globalObject(globalObject)
    , m_identifier(identifier == std::numeric_limits<int32_t>::max() ? ++lastUniqueIdentifier : identifier)
{
    relaxAdoptionRequirement();
    addToContextsMap();
}

static Lock allScriptExecutionContextsMapLock;
static HashMap<ScriptExecutionContextIdentifier, ScriptExecutionContext*>& allScriptExecutionContextsMap() WTF_REQUIRES_LOCK(allScriptExecutionContextsMapLock)
{
    static NeverDestroyed<HashMap<ScriptExecutionContextIdentifier, ScriptExecutionContext*>> contexts;
    ASSERT(allScriptExecutionContextsMapLock.isLocked());
    return contexts;
}

ScriptExecutionContext* ScriptExecutionContext::getScriptExecutionContext(ScriptExecutionContextIdentifier identifier)
{
    if (identifier == 0) {
        return nullptr;
    }
    Locker locker { allScriptExecutionContextsMapLock };
    return allScriptExecutionContextsMap().getOptional(identifier).value_or(nullptr);
}

JSGlobalObject* ScriptExecutionContext::globalObject()
{
    return m_globalObject;
}

RefPtr<MessagePortContext> ScriptExecutionContext::messagePortContext()
{
    ASSERT(isContextThread());
    if (!m_messagePortContext)
        m_messagePortContext = MessagePortContext::tryCreate(*this);
    return m_messagePortContext;
}

void ScriptExecutionContext::refEventLoop()
{
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopRefConcurrently(WebCore::clientData(vm())->bunVM);
}
void ScriptExecutionContext::unrefEventLoop()
{
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopUnrefConcurrently(WebCore::clientData(vm())->bunVM);
}

ScriptExecutionContext::~ScriptExecutionContext()
{
    closeNativeLifetimes();
    checkConsistency();

#if ASSERT_ENABLED
    {
        Locker locker { allScriptExecutionContextsMapLock };
        ASSERT_WITH_MESSAGE(!allScriptExecutionContextsMap().contains(m_identifier), "A ScriptExecutionContext subclass instance implementing postTask should have already removed itself from the map");
    }
#endif // ASSERT_ENABLED

    m_inScriptExecutionContextDestructor = true;
    while (auto* destructionObserver = m_destructionObservers)
        destructionObserver->notifyContextDestroyed();
}

bool ScriptExecutionContext::postTaskTo(ScriptExecutionContextIdentifier identifier, Function<void(ScriptExecutionContext&)>&& task)
{
    Locker locker { allScriptExecutionContextsMapLock };
    auto* context = allScriptExecutionContextsMap().get(identifier);

    if (!context)
        return false;

    context->postTaskConcurrently(WTF::move(task));
    return true;
}

ScriptExecutionContext::NativeLifetime::~NativeLifetime()
{
    detach();
}

bool ScriptExecutionContext::NativeLifetime::attach(ScriptExecutionContext& context) noexcept
{
    ASSERT(context.isContextThread());
    RELEASE_ASSERT(!m_context);
    if (!context.m_nativeLifetimesOpen)
        return false;
    m_context = &context;
    m_next = context.m_nativeLifetimes;
    if (m_next)
        m_next->m_previous = this;
    context.m_nativeLifetimes = this;
    return true;
}

void ScriptExecutionContext::NativeLifetime::detach() noexcept
{
    if (!m_context)
        return;
    if (m_previous)
        m_previous->m_next = m_next;
    else
        m_context->m_nativeLifetimes = m_next;
    if (m_next)
        m_next->m_previous = m_previous;
    m_context = nullptr;
    m_previous = nullptr;
    m_next = nullptr;
}

void ScriptExecutionContext::closeNativeLifetimes() noexcept
{
    m_nativeLifetimesOpen = false;
    while (auto* lifetime = m_nativeLifetimes) {
        lifetime->detach();
        lifetime->contextClosed();
    }
}

void ScriptExecutionContext::didCreateDestructionObserver(ContextDestructionObserver& observer)
{
    ASSERT(!observer.scriptExecutionContext());
    ASSERT(!observer.m_previous && !observer.m_next);
    if (m_inScriptExecutionContextDestructor)
        return;
    observer.m_context.store(this, std::memory_order_relaxed);
    observer.m_next = m_destructionObservers;
    if (m_destructionObservers)
        m_destructionObservers->m_previous = &observer;
    m_destructionObservers = &observer;
}

void ScriptExecutionContext::willDestroyDestructionObserver(ContextDestructionObserver& observer)
{
    ASSERT(observer.scriptExecutionContext() == this);
    if (observer.m_previous)
        observer.m_previous->m_next = observer.m_next;
    else {
        ASSERT(m_destructionObservers == &observer);
        m_destructionObservers = observer.m_next;
    }
    if (observer.m_next)
        observer.m_next->m_previous = observer.m_previous;
    observer.m_previous = nullptr;
    observer.m_next = nullptr;
    observer.m_context.store(nullptr, std::memory_order_relaxed);
}

bool ScriptExecutionContext::isJSExecutionForbidden()
{
    return !m_vm || m_vm->executionForbidden();
}

bool ScriptExecutionContext::isContextThread()
{
    auto clientData = WebCore::clientData(vm());
    return clientData && clientData->bunVM == Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_getVirtualMachine();
}

bool ScriptExecutionContext::ensureOnContextThread(ScriptExecutionContextIdentifier identifier, Function<void(ScriptExecutionContext&)>&& task)
{
    ScriptExecutionContext* context = nullptr;
    {
        Locker locker { allScriptExecutionContextsMapLock };
        context = allScriptExecutionContextsMap().get(identifier);

        if (!context)
            return false;

        if (!context->isContextThread()) {
            context->postTaskConcurrently(WTF::move(task));
            return true;
        }
    }

    task(*context);
    return true;
}

bool ScriptExecutionContext::ensureOnMainThread(Function<void(ScriptExecutionContext&)>&& task)
{
    auto* context = ScriptExecutionContext::getMainThreadScriptExecutionContext();

    if (!context) {
        return false;
    }

    context->postTaskConcurrently(WTF::move(task));
    return true;
}

ScriptExecutionContext* ScriptExecutionContext::getMainThreadScriptExecutionContext()
{
    Locker locker { allScriptExecutionContextsMapLock };
    return allScriptExecutionContextsMap().get(1);
}

void ScriptExecutionContext::checkConsistency() const
{
#if ASSERT_ENABLED
    for (auto* destructionObserver = m_destructionObservers; destructionObserver; destructionObserver = destructionObserver->m_next)
        ASSERT(destructionObserver->scriptExecutionContext() == this);
#endif // ASSERT_ENABLED
}

ScriptExecutionContextIdentifier ScriptExecutionContext::generateIdentifier()
{
    return ++lastUniqueIdentifier;
}

void ScriptExecutionContext::inheritIdentifierFrom(ScriptExecutionContext& previous)
{
    RELEASE_ASSERT(this != &previous && m_vm == previous.m_vm);
    ASSERT(isContextThread());
    // Concurrent senders must observe a registered context throughout the handoff.
    {
        Locker locker { allScriptExecutionContextsMapLock };
        auto& contexts = allScriptExecutionContextsMap();
        auto currentEntry = contexts.find(m_identifier);
        auto previousEntry = contexts.find(previous.m_identifier);
        RELEASE_ASSERT(currentEntry != contexts.end() && currentEntry->value == this);
        RELEASE_ASSERT(previousEntry != contexts.end() && previousEntry->value == &previous);
        currentEntry->value = &previous;
        previousEntry->value = this;
        std::swap(m_identifier, previous.m_identifier);
    }
    previous.closeNativeLifetimes();
}

void ScriptExecutionContext::addToContextsMap()
{
    Locker locker { allScriptExecutionContextsMapLock };
    ASSERT(!allScriptExecutionContextsMap().contains(m_identifier));
    allScriptExecutionContextsMap().add(m_identifier, this);
}

void ScriptExecutionContext::removeFromContextsMap()
{
    {
        Locker locker { allScriptExecutionContextsMapLock };
        ASSERT(allScriptExecutionContextsMap().contains(m_identifier));
        allScriptExecutionContextsMap().remove(m_identifier);
    }
    closeNativeLifetimes();
}

ScriptExecutionContext* executionContext(JSC::JSGlobalObject* globalObject)
{
    if (!globalObject || !globalObject->inherits<JSDOMGlobalObject>())
        return nullptr;
    return uncheckedDowncast<JSDOMGlobalObject>(globalObject)->scriptExecutionContext();
}

void ScriptExecutionContext::postTaskConcurrently(Function<void(ScriptExecutionContext&)>&& lambda)
{
    auto* task = new EventLoopTask(WTF::move(lambda));
    if (isContextThread() && !task->attachToContext(*this)) {
        delete task;
        return;
    }
    static_cast<Zig::GlobalObject*>(m_globalObject)->queueTaskConcurrently(task);
}
// Executes the task on context's thread asynchronously.
void ScriptExecutionContext::postTask(Function<void(ScriptExecutionContext&)>&& lambda)
{
    postTask(new EventLoopTask(WTF::move(lambda)));
}
// Executes the task on context's thread asynchronously.
void ScriptExecutionContext::postTask(EventLoopTask* task)
{
    if (!isContextThread()) {
        static_cast<Zig::GlobalObject*>(m_globalObject)->queueTaskConcurrently(task);
        return;
    }
    if (!task->attachToContext(*this)) {
        delete task;
        return;
    }
    static_cast<Zig::GlobalObject*>(m_globalObject)->queueTask(task);
}

} // namespace WebCore

bool Bun::Bindgen::Engine::bunBindgenEngine_global_objects_scriptExecutionContextExists(
    const Bun::Bindgen::Engine::BunBindgenEngine_global_objects_scriptExecutionContextExists_Arguments& args)
{
    return WebCore::ScriptExecutionContext::getScriptExecutionContext(args.identifier);
}
