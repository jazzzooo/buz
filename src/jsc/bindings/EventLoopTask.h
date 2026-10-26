#pragma once
#include "root.h"
#include "ScriptExecutionContext.h"

namespace WebCore {

class EventLoopTask : public ScriptExecutionContext::NativeLifetime {
    WTF_MAKE_TZONE_ALLOCATED(EventLoopTask);

public:
    ~EventLoopTask() override { detach(); }

    template<typename T, typename = typename std::enable_if<!std::is_base_of<EventLoopTask, T>::value && std::is_convertible<T, Function<void(ScriptExecutionContext&)>>::value>::type>
    EventLoopTask(T task)
        : m_task(WTF::move(task))
    {
    }

    EventLoopTask(Function<void()>&& task)
        : m_task([task = WTF::move(task)](ScriptExecutionContext&) { task(); })
    {
    }

    bool attachToContext(ScriptExecutionContext& context)
    {
        return attach(context);
    }

    void performTask(ScriptExecutionContext& context)
    {
        auto* owner = this->context();
        detach();
        auto task = WTF::move(m_task);
        if (task)
            task(owner ? *owner : context);
    }

private:
    void contextClosed() noexcept final
    {
        // Capture destruction may re-enter task disposal; empty the queued task first.
        auto task = WTF::move(m_task);
    }

    Function<void(ScriptExecutionContext&)> m_task;
};

}
