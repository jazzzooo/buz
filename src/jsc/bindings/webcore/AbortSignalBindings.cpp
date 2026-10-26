#include "root.h"

#include "AbortSignal.h"
#include "JSAbortSignal.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

using namespace JSC;
using namespace WebCore;

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalToClassRef(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_abort_signals_abortSignalToClassRef_Arguments& args)
{
    auto* global = &context.globalObject;
    return WebCore::toJS(global, uncheckedDowncast<WebCore::JSDOMGlobalObject>(global), args.signal);
}

WebCore::AbortSignal* Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalNew(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_abort_signals_abortSignalNew_Arguments&)
{
    Zig::GlobalObject* thisObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto* scriptContext = thisObject->scriptExecutionContext();
    RefPtr<WebCore::AbortSignal> abortSignal = WebCore::AbortSignal::create(scriptContext);
    return abortSignal.leakRef();
}

void Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalIncrementPendingActivity(
    const BunBindgenEngine_abort_signals_abortSignalIncrementPendingActivity_Arguments& args)
{
    args.signal->incrementPendingActivityCount();
}

void Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalDecrementPendingActivity(
    const BunBindgenEngine_abort_signals_abortSignalDecrementPendingActivity_Arguments& args)
{
    args.signal->decrementPendingActivityCount();
}

void Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalSignal(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_abort_signals_abortSignalSignal_Arguments& args)
{
    args.signal->signalAbort(
        &context.globalObject,
        static_cast<WebCore::CommonAbortReason>(args.reason));
}

bool Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalIsAborted(
    const BunBindgenEngine_abort_signals_abortSignalIsAborted_Arguments& args)
{
    return args.signal->aborted();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalReason(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_abort_signals_abortSignalReason_Arguments& args)
{
    return args.signal->jsReason(context.globalObject);
}

std::optional<WebCore::AbortSignalTimeout> Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalTimeout(
    const BunBindgenEngine_abort_signals_abortSignalTimeout_Arguments& args)
{
    if (!args.signal->hasActiveTimeoutTimer())
        return std::nullopt;
    return args.signal->getTimeout();
}

WebCore::AbortSignal* Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalRef(
    const BunBindgenEngine_abort_signals_abortSignalRef_Arguments& args)
{
    args.signal->ref();
    return args.signal;
}

void Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalCancelTimeout(
    const BunBindgenEngine_abort_signals_abortSignalCancelTimeout_Arguments& args)
{
    args.signal->cancelTimer();
}

void Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalUnref(
    const BunBindgenEngine_abort_signals_abortSignalUnref_Arguments& args)
{
    args.signal->deref();
}

void Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalRemoveListener(
    const BunBindgenEngine_abort_signals_abortSignalRemoveListener_Arguments& args)
{
    args.signal->removeNativeListener(args.listener);
}

WebCore::AbortSignal* Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalAddListener(
    EngineCallContext& context,
    const BunBindgenEngine_abort_signals_abortSignalAddListener_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (args.signal->aborted()) {
        auto reason = args.signal->jsReason(context.globalObject);
        RETURN_IF_EXCEPTION(scope, nullptr);
        scope.release();
        Bun::Bindgen::ZigExports::bunBindgenZig_abort_signals_abortSignalRunListener(
            &context.globalObject,
            args.listener,
            reason);
        return args.signal;
    }
    if (!args.signal->addNativeListener(args.listener)) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return nullptr;
    }
    return args.signal;
}
