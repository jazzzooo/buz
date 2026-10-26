#include "config.h"

#include "BunWorkerGlobalScope.h"
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(WorkerGlobalScope);

JSC::JSGlobalObject* WorkerGlobalScope::globalObject() const
{
    Locker locker { m_globalLock };
    return m_globalObject.get();
}

template<typename Visitor>
void WorkerGlobalScope::visitGlobalObject(Visitor& visitor) const
{
    Locker locker { m_globalLock };
    visitor.append(m_globalObject);
}

template void WorkerGlobalScope::visitGlobalObject(JSC::AbstractSlotVisitor&) const;
template void WorkerGlobalScope::visitGlobalObject(JSC::SlotVisitor&) const;

void WorkerGlobalScope::releaseMessageActivity(ScriptExecutionContext* context)
{
    if (m_hasMessageActivity) {
        m_hasMessageActivity = false;
        if (context)
            context->unrefEventLoop();
    }
}

void WorkerGlobalScope::detachGlobalObject()
{
    releaseMessageActivity(scriptExecutionContext());
    observeContext(nullptr);
    Locker locker { m_globalLock };
    m_globalObject.clear();
}

void WorkerGlobalScope::contextDestroyed(ScriptExecutionContext& context)
{
    releaseMessageActivity(&context);
    detachGlobalObject();
}

void WorkerGlobalScope::onDidChangeListenerImpl(EventTarget& self, const AtomString& eventType, OnDidChangeListenerKind)
{
    if (eventType != eventNames().messageEvent)
        return;
    auto& global = static_cast<WorkerGlobalScope&>(self);
    auto* context = global.scriptExecutionContext();
    const bool hasActivity = context && global.hasEventListeners(eventType);
    if (hasActivity == global.m_hasMessageActivity)
        return;
    global.m_hasMessageActivity = hasActivity;
    if (!context)
        return;
    if (hasActivity)
        context->refEventLoop();
    else
        context->unrefEventLoop();
}

}
