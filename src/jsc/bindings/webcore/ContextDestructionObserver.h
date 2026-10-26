

#pragma once

#include "root.h"
#include "ScriptExecutionContext.h"
#include <atomic>

namespace WebCore {

class ContextDestructionObserver {
    WTF_MAKE_NONCOPYABLE(ContextDestructionObserver);

public:
    ScriptExecutionContext* scriptExecutionContext() const { return m_context.load(std::memory_order_relaxed); }

protected:
    WEBCORE_EXPORT ContextDestructionObserver(ScriptExecutionContext*);
    WEBCORE_EXPORT virtual ~ContextDestructionObserver();
    void observeContext(ScriptExecutionContext*);
    // The observer is detached before this callback; context is borrowed for cleanup.
    WEBCORE_EXPORT virtual void contextDestroyed(ScriptExecutionContext&);

private:
    friend class ScriptExecutionContext;
    void notifyContextDestroyed();
    std::atomic<ScriptExecutionContext*> m_context { nullptr };
    ContextDestructionObserver* m_previous { nullptr };
    ContextDestructionObserver* m_next { nullptr };
};

}
