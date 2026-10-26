#pragma once

#include "root.h"
#include <wtf/CrossThreadTask.h>
#include <wtf/Function.h>
#include <wtf/ObjectIdentifier.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>
#include <wtf/CompletionHandler.h>
#include "CachedScript.h"
#include "wtf/ThreadSafeWeakPtr.h"
#include <wtf/URL.h>

namespace uWS {
template<bool isServer, bool isClient, typename UserData>
struct WebSocketContext;
}

struct us_socket_t;
struct us_socket_group_t;
struct us_loop_t;

namespace WebCore {

class WebSocket;

class ScriptExecutionContext;
class EventLoopTask;

class ContextDestructionObserver;
class MessagePortContext;

using ScriptExecutionContextIdentifier = uint32_t;

#if ENABLE(MALLOC_BREAKDOWN)
DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(ScriptExecutionContext);
#endif
class ScriptExecutionContext : public CanMakeWeakPtr<ScriptExecutionContext>, public RefCounted<ScriptExecutionContext> {
#if ENABLE(MALLOC_BREAKDOWN)
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(ScriptExecutionContext, ScriptExecutionContext);
#else
    WTF_MAKE_TZONE_ALLOCATED(ScriptExecutionContext);
#endif

public:
    ScriptExecutionContext(JSC::VM* vm, JSC::JSGlobalObject* globalObject);
    ScriptExecutionContext(JSC::VM* vm, JSC::JSGlobalObject* globalObject, ScriptExecutionContextIdentifier identifier);

    ~ScriptExecutionContext();

    static ScriptExecutionContextIdentifier generateIdentifier();

    JSC::JSGlobalObject* jsGlobalObject()
    {
        return m_globalObject;
    }

    static ScriptExecutionContext* getScriptExecutionContext(ScriptExecutionContextIdentifier identifier);
    void refEventLoop();
    void unrefEventLoop();
    using RefCounted::deref;
    using RefCounted::ref;

    const WTF::URL& url() const
    {
        return m_url;
    }
    bool isMainThread() const { return m_identifier == 1; }
    bool activeDOMObjectsAreSuspended() { return false; }
    bool activeDOMObjectsAreStopped() { return false; }
    bool isContextThread();
    bool isDocument() { return false; }
    bool isWorkerGlobalScope() { return true; }
    bool isJSExecutionForbidden();
    void reportException(const String& errorMessage, int lineNumber, int columnNumber, const String& sourceURL, JSC::Exception* exception, RefPtr<void*>&&, CachedScript* = nullptr, bool = false)
    {
    }
    // void reportUnhandledPromiseRejection(JSC::JSGlobalObject&, JSC::JSPromise&, RefPtr<Inspector::ScriptCallStack>&&)
    // {
    // }



    WEBCORE_EXPORT static bool postTaskTo(ScriptExecutionContextIdentifier identifier, Function<void(ScriptExecutionContext&)>&& task);
    WEBCORE_EXPORT static bool ensureOnContextThread(ScriptExecutionContextIdentifier, Function<void(ScriptExecutionContext&)>&& task);
    WEBCORE_EXPORT static bool ensureOnMainThread(Function<void(ScriptExecutionContext&)>&& task);

    WEBCORE_EXPORT JSC::JSGlobalObject* globalObject();
    RefPtr<MessagePortContext> messagePortContext();

    class NativeLifetime {
    public:
        NativeLifetime() = default;
        NativeLifetime(const NativeLifetime&) = delete;
        NativeLifetime& operator=(const NativeLifetime&) = delete;
        virtual ~NativeLifetime();
        bool attach(ScriptExecutionContext&) noexcept;
        void detach() noexcept;
        ScriptExecutionContext* context() const { return m_context; }

    protected:
        virtual void contextClosed() noexcept = 0;

    private:
        friend class ScriptExecutionContext;
        ScriptExecutionContext* m_context { nullptr };
        NativeLifetime* m_previous { nullptr };
        NativeLifetime* m_next { nullptr };
    };

    void checkConsistency() const;

    void inheritIdentifierFrom(ScriptExecutionContext&);
    void addToContextsMap();
    void removeFromContextsMap();

    void postTaskConcurrently(Function<void(ScriptExecutionContext&)>&& lambda);
    // Executes the task on context's thread asynchronously.
    void postTask(Function<void(ScriptExecutionContext&)>&& lambda);
    // Executes the task on context's thread asynchronously.
    void postTask(EventLoopTask* task);

    template<typename... Arguments>
    void postCrossThreadTask(Arguments&&... arguments)
    {
        postTask([crossThreadTask = createCrossThreadTask(arguments...)](ScriptExecutionContext&) mutable {
            crossThreadTask.performTask();
        });
    }

    JSC::VM& vm() { return *m_vm; }
    ScriptExecutionContextIdentifier identifier() const { return m_identifier; }

    bool isWorker = false;
    void setGlobalObject(JSC::JSGlobalObject* globalObject)
    {
        m_globalObject = globalObject;
        m_vm = &globalObject->vm();
    }

    static ScriptExecutionContext* getMainThreadScriptExecutionContext();

private:
    friend class ContextDestructionObserver;
    void didCreateDestructionObserver(ContextDestructionObserver&);
    void willDestroyDestructionObserver(ContextDestructionObserver&);
    void closeNativeLifetimes() noexcept;
    NativeLifetime* m_nativeLifetimes { nullptr };
    bool m_nativeLifetimesOpen { true };
    RefPtr<MessagePortContext> m_messagePortContext;
    JSC::VM* m_vm = nullptr;
    JSC::JSGlobalObject* m_globalObject = nullptr;
    WTF::URL m_url = WTF::URL();
    ScriptExecutionContextIdentifier m_identifier;

    ContextDestructionObserver* m_destructionObservers { nullptr };
    bool m_inScriptExecutionContextDestructor = false;
};

ScriptExecutionContext* executionContext(JSC::JSGlobalObject*);

}
