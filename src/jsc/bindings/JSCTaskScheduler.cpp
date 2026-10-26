#include "config.h"
#include <JavaScriptCore/VM.h>
#include "JSCTaskScheduler.h"
#include "BunClientData.h"
#include "SchemaBindings.h"

using Ticket = JSC::DeferredWorkTimer::Ticket;
using Task = JSC::DeferredWorkTimer::Task;

namespace Bun {
using namespace JSC;

class JSCDeferredWorkTask {
public:
    JSCDeferredWorkTask(VM& vm, Ref<Ticket> ticket, Task&& task)
        : vm(vm)
        , ticket(WTF::move(ticket))
        , task(WTF::move(task))
    {
    }

    VM& vm;
    Ref<Ticket> ticket;
    Task task;
    WTF_MAKE_TZONE_ALLOCATED(JSCDeferredWorkTask);
};

void JSCTaskScheduler::onAddPendingWork(WebCore::JSVMClientData* clientData, Ref<Ticket>&& ticket, JSC::DeferredWorkTimer::WorkType kind)
{
    auto& scheduler = clientData->deferredWorkTimer;
    Locker<Lock> holder { scheduler.m_lock };
    if (kind == DeferredWorkTimer::WorkType::ImminentlyScheduled) {
        Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopRefConcurrently(clientData->bunVM);
        scheduler.m_pendingTicketsKeepingEventLoopAlive.add(WTF::move(ticket));
    } else {
        scheduler.m_pendingTicketsOther.add(WTF::move(ticket));
    }
}
void JSCTaskScheduler::onScheduleWorkSoon(VM& vm, WebCore::JSVMClientData* clientData, Ref<Ticket>&& ticket, Task&& task)
{
    auto* job = new JSCDeferredWorkTask(vm, WTF::move(ticket), WTF::move(task));
    Bindgen::ZigExports::bunBindgenZig_EventLoop_queueJSCDeferredWorkTaskConcurrently(clientData->bunVM, job);
}

void JSCTaskScheduler::onCancelPendingWork(WebCore::JSVMClientData* clientData, Ticket& ticket)
{
    auto* bunVM = clientData->bunVM;
    auto& scheduler = clientData->deferredWorkTimer;

    Locker<Lock> holder { scheduler.m_lock };
    bool isKeepingEventLoopAlive = scheduler.m_pendingTicketsKeepingEventLoopAlive.removeIf([&ticket](auto pendingTicket) {
        return pendingTicket.ptr() == &ticket;
    });
    // -- At this point, ticket may be an invalid pointer.

    if (isKeepingEventLoopAlive) {
        holder.unlockEarly();
        Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopUnrefConcurrently(bunVM);
    } else {
        scheduler.m_pendingTicketsOther.removeIf([&ticket](auto pendingTicket) {
            return pendingTicket.ptr() == &ticket;
        });
    }
}

static RefPtr<Ticket> takePendingWork(VirtualMachine* bunVM, Bun::JSCTaskScheduler& scheduler, JSCDeferredWorkTask* job)
{
    Locker<Lock> holder { scheduler.m_lock };
    auto pendingTicket = scheduler.m_pendingTicketsKeepingEventLoopAlive.take(job->ticket);
    if (!pendingTicket) {
        pendingTicket = scheduler.m_pendingTicketsOther.take(job->ticket);
    } else {
        Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopUnrefConcurrently(bunVM);
    }
    holder.unlockEarly();
    return pendingTicket;
}

static void runPendingWork(VirtualMachine* bunVM, Bun::JSCTaskScheduler& scheduler, JSCDeferredWorkTask* job)
{
    auto pendingTicket = takePendingWork(bunVM, scheduler, job);
    if (pendingTicket && !pendingTicket->isCancelled()) {
        job->task(job->ticket.get());
    }
}

void Bindgen::Engine::bunBindgenEngine_EventLoop_runJSCDeferredWork(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_EventLoop_runJSCDeferredWork_Arguments& args)
{
    auto* job = args.task;
    auto& vm = context.globalObject.vm();
    RELEASE_ASSERT(&job->vm == &vm);
    auto clientData = WebCore::clientData(vm);

    runPendingWork(clientData->bunVM, clientData->deferredWorkTimer, job);
}

void Bindgen::Engine::releaseJSCDeferredWorkTask(JSCDeferredWorkTask* job)
{
    auto& vm = job->vm;
    auto* clientData = WebCore::clientData(vm);
    vm.deferredWorkTimer->cancelPendingWork(job->ticket.get());
    auto pendingTicket = takePendingWork(clientData->bunVM, clientData->deferredWorkTimer, job);
    delete job;
}

}
