#pragma once

namespace Bun::Bindgen::Engine {

static void attachPromiseReaction(
    JSC::JSPromise* promise,
    Zig::GlobalObject* globalObject,
    JSC::JSValue reactionContext,
    BunBindgenHostFunction resolverFunction,
    BunBindgenHostFunction rejecterFunction)
{
    auto* performPromiseThenFunction = globalObject->performPromiseThenFunction();
    auto callData = JSC::getCallData(performPromiseThenFunction);
    ASSERT(callData.type != JSC::CallData::Type::None);

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(promise);
    arguments.append(globalObject->thenable(resolverFunction));
    arguments.append(globalObject->thenable(rejecterFunction));
    arguments.append(JSC::jsUndefined());
    arguments.append(reactionContext);
    ASSERT(!arguments.hasOverflowed());
    JSC::profiledCall(
        globalObject,
        JSC::ProfilingReason::Microtask,
        performPromiseThenFunction,
        callData,
        JSC::jsUndefined(),
        arguments);
}

}
