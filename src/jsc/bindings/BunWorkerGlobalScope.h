#pragma once

#include "root.h"

#include "EventNames.h"
#include "EventTarget.h"
#include "ContextDestructionObserver.h"
#include "ExceptionOr.h"
#include <JavaScriptCore/WriteBarrier.h>
#include <wtf/URL.h>
#include <wtf/HashSet.h>
#include <wtf/Lock.h>

namespace WebCore {

class WorkerGlobalScope : public RefCounted<WorkerGlobalScope>, public EventTargetWithInlineData, private ContextDestructionObserver {
    WTF_MAKE_TZONE_ALLOCATED(WorkerGlobalScope);

    bool m_hasMessageActivity { false };
    mutable Lock m_globalLock;
    JSC::WriteBarrier<JSC::JSGlobalObject> m_globalObject;

    static void onDidChangeListenerImpl(EventTarget&, const AtomString&, OnDidChangeListenerKind);
    void releaseMessageActivity(ScriptExecutionContext*);

public:
    WorkerGlobalScope(ScriptExecutionContext* context)
        : EventTargetWithInlineData()
        , ContextDestructionObserver(context)
    {
        m_globalObject.setWithoutWriteBarrier(context->globalObject());
        this->onDidChangeListener = &onDidChangeListenerImpl;
    }

    using RefCounted::deref;
    using RefCounted::ref;

    static Ref<WorkerGlobalScope> create(ScriptExecutionContext* context)
    {
        return adoptRef(*new WorkerGlobalScope(context));
    }

    ~WorkerGlobalScope() = default;

    EventTargetInterface eventTargetInterface() const final { return EventTargetInterface::DOMWindowEventTargetInterfaceType; }
    ScriptExecutionContext* scriptExecutionContext() const final { return ContextDestructionObserver::scriptExecutionContext(); }
    void refEventTarget() final { ref(); }
    void derefEventTarget() final { deref(); }
    void eventListenersDidChange() final {}

    JSC::JSGlobalObject* globalObject() const;
    void detachGlobalObject();
    void contextDestroyed(ScriptExecutionContext&) final;
    template<typename Visitor> void visitGlobalObject(Visitor&) const;
};
}
