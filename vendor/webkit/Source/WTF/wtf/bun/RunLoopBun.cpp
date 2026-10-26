#include "config.h"
#include "SchemaBindings+WTFTimer.h"
#include <wtf/RunLoop.h>

// We need the definition of RunLoop::TimerBase::ScheduledTask, as well as the definitions of
// RunLoopGeneric member functions (which we redefine to be on RunLoopGenericState instead)
#include <wtf/generic/RunLoopGeneric.cpp>

// Ensure we cleaned up the mess in RunLoopGeneric.cpp
#if defined(RunLoop)
#error RunLoop was not undef'd
#elif defined(m_runLoop)
#error m_runLoop was not undef'd
#elif defined(m_scheduledTask)
#error m_scheduledTask was not undef'd
#endif

namespace WTF {

RunLoop::TimerBase::TimerBase(Ref<RunLoop>&& loop, ASCIILiteral description)
    : m_runLoop(WTF::move(loop))
    , m_description(description)
    // We need to init this here since there's no default constructor. We init with a nullptr
    // WTFTimer. The body of the constructor always initializes it with a proper value.
    , m_impl(NullWTFTimer)
{
    switch (m_runLoop->kind()) {
    case Kind::Generic:
        m_impl.emplace<Ref<ScheduledTask>>(ScheduledTask::create(*this));
        break;
    case Kind::Bun:
        auto* maybe_timer = Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerCreate(this).value_or(nullptr);
        if (maybe_timer) {
            m_impl.emplace<std::reference_wrapper<Bun__WTFTimer>>(std::ref(*maybe_timer));
        } else {
            m_impl.emplace<NullWTFTimerTag>(NullWTFTimer);
        }
        break;
    }
}

// Bun might start a JSC::VM without intending to create a Timer.
// An example case is bytecode caching.
// In such cases, we should avoid calling the function.

RunLoop::TimerBase::~TimerBase()
{
    switch (kind()) {
    case Kind::Generic:
        destructGeneric();
        break;
    case Kind::Bun:
        if (auto* ref = std::get_if<std::reference_wrapper<Bun__WTFTimer>>(&m_impl)) {
            Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerDestroy(&ref->get());
        }
        break;
    }
}

void RunLoop::TimerBase::stop()
{
    switch (kind()) {
    case Kind::Generic:
        return stopGeneric();
    case Kind::Bun:
        if (auto* ref = std::get_if<std::reference_wrapper<Bun__WTFTimer>>(&m_impl)) {
            Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerCancel(&ref->get());
        }
        return;
    }
}

bool RunLoop::TimerBase::isActive() const
{
    switch (kind()) {
    case Kind::Generic:
        return isActiveGeneric();
    case Kind::Bun:
        if (auto* ref = std::get_if<std::reference_wrapper<Bun__WTFTimer>>(&m_impl)) {
            return Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerIsActive(&ref->get());
        }
        return false;
    }
}

Seconds RunLoop::TimerBase::secondsUntilFire() const
{
    switch (kind()) {
    case Kind::Generic:
        return secondsUntilFireGeneric();
    case Kind::Bun:
        if (auto* ref = std::get_if<std::reference_wrapper<Bun__WTFTimer>>(&m_impl)) {
            return Seconds(Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerSecondsUntilFire(&ref->get()));
        }
        return -1.0_s;
    }
}

void RunLoop::TimerBase::start(Seconds interval, bool repeat)
{
    switch (kind()) {
    case Kind::Generic:
        return startGeneric(interval, repeat);
    case Kind::Bun:
        if (auto* ref = std::get_if<std::reference_wrapper<Bun__WTFTimer>>(&m_impl)) {
            Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerUpdate(&ref->get(), interval.value(), repeat);
        }
        return;
    }
}

// probably more Bun-specific TimerBase methods

RunLoop::RunLoop()
{
    if (!(isMainThread() || Bun::Bindgen::ZigExports::bunBindgenZig_WTFTimer_wtfTimerThisThreadHasVM()))
        m_genericState.emplace(*this);
}

RunLoop::~RunLoop()
{
    // if m_genericState has a value, ~RunLoopGenericState() will be called, so we don't need
    // to do anything else here
}

void RunLoop::run()
{
    switch (RunLoop::currentSingleton().kind()) {
    case Kind::Generic:
        // matches RunLoopGeneric implementation
        RunLoop::currentSingleton().m_genericState->runImpl(RunLoopGenericState::RunMode::Drain);
        return;
    case Kind::Bun:
        // Our event loop should not call this function
        ASSERT_NOT_REACHED();
    }
}

void RunLoop::stop()
{
    switch (kind()) {
    case Kind::Generic:
        m_genericState->stop();
        return;
    case Kind::Bun:
        // Our event loop should not call this function
        ASSERT_NOT_REACHED();
    }
}

void RunLoop::wakeUp()
{
    switch (kind()) {
    case Kind::Generic:
        m_genericState->wakeUp();
        return;
    case Kind::Bun:
        // Do nothing. This means that JSRunLoopTimer::Manager::PerVMData's RunLoop::Timer leaks instead
        // of being freed.
    }
}

RunLoop::CycleResult RunLoop::cycle(RunLoopMode)
{
    switch (RunLoop::currentSingleton().kind()) {
    case Kind::Generic:
        // matches RunLoopGeneric implementation
        RunLoop::currentSingleton().m_genericState->runImpl(RunLoopGenericState::RunMode::Iterate);
        return CycleResult::Continue;
    case Kind::Bun:
        // Our event loop should not call this function
        ASSERT_NOT_REACHED();
        return RunLoop::CycleResult::Stop;
    }
}

} // namespace WTF
