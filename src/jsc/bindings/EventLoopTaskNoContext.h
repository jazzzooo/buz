#pragma once

#include "root.h"
#include <memory>
#include <utility>
#include <wtf/FastMalloc.h>

namespace JSC {
class JSGlobalObject;
}

namespace Bun {

class EventLoopTaskNoContext {
public:
    explicit EventLoopTaskNoContext(JSC::JSGlobalObject*);
    virtual ~EventLoopTaskNoContext() = default;
    virtual void performTask() = 0;

    void* createdInBunVm() const { return m_createdInBunVm; }

private:
    void* m_createdInBunVm;
};

template<typename Callable>
class EventLoopFunctionTask final : public EventLoopTaskNoContext {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(EventLoopFunctionTask);

public:
    template<typename Function>
    static std::unique_ptr<EventLoopFunctionTask> tryCreate(JSC::JSGlobalObject* global, Function&& function)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(EventLoopFunctionTask)).getValue(allocation))
            return nullptr;
        return std::unique_ptr<EventLoopFunctionTask>(new (NotNull, allocation) EventLoopFunctionTask(global, std::forward<Function>(function)));
    }

    void performTask() final { m_function(); }

private:
    template<typename Function>
    EventLoopFunctionTask(JSC::JSGlobalObject* global, Function&& function)
        : EventLoopTaskNoContext(global)
        , m_function(std::forward<Function>(function))
    {
    }

    Callable m_function;
};

} // namespace Bun
