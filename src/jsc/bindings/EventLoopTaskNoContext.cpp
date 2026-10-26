#include "EventLoopTaskNoContext.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

namespace Bun {

EventLoopTaskNoContext::EventLoopTaskNoContext(JSC::JSGlobalObject* global)
    : m_createdInBunVm(defaultGlobalObject(global)->bunVM())
{
}

void Bindgen::Engine::releaseEventLoopTaskNoContext(EventLoopTaskNoContext* task)
{
    delete task;
}

void Bindgen::Engine::bunBindgenEngine_EventLoop_eventLoopTaskNoContextPerform(
    const Bindgen::Engine::BunBindgenEngine_EventLoop_eventLoopTaskNoContextPerform_Arguments& args)
{
    args.task->performTask();
}

std::optional<VirtualMachine*> Bindgen::Engine::bunBindgenEngine_EventLoop_eventLoopTaskNoContextCreatedInBunVM(
    const Bindgen::Engine::BunBindgenEngine_EventLoop_eventLoopTaskNoContextCreatedInBunVM_Arguments& args)
{
    return static_cast<VirtualMachine*>(args.task->createdInBunVm());
}

} // namespace Bun
