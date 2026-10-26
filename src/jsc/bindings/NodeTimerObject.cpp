
#include "root.h"

#include "JavaScriptCore/InternalFieldTuple.h"
#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/Heap.h"
#include "ZigGlobalObject.h"
#include "BunProcess.h"

#include "SchemaBindings.h"
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include "JavaScriptCore/JSCJSValue.h"
#include "AsyncContextFrame.h"
#include <cmath>
#include <limits>
#include <optional>
#include <wtf/Scope.h>
#include <wtf/text/MakeString.h>

namespace Bun::Bindgen::Custom {

std::optional<int32_t> bunBindgenTimerIdentifierString(const WTF::String& value, WTF::ASCIILiteral)
{
    if (value.isEmpty() || value.length() > 10 || value[0] == '0')
        return std::nullopt;
    int32_t id = 0;
    for (unsigned index = 0; index < value.length(); ++index) {
        auto character = value[index];
        if (character < '0' || character > '9')
            return std::nullopt;
        int32_t digit = character - '0';
        if (id > (std::numeric_limits<int32_t>::max() - digit) / 10)
            return std::nullopt;
        id = id * 10 + digit;
    }
    return id;
}

}

namespace Bun {
using namespace JSC;

static JSValue makeTimerArguments(JSGlobalObject* global, std::span<const Bindgen::CppAny> values)
{
    if (values.empty()) return jsUndefined();
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    if (values.size() > std::numeric_limits<unsigned>::max()) {
        throwOutOfMemoryError(global, scope);
        return {};
    }
    MarkedArgumentBuffer arguments;
    arguments.ensureCapacity(static_cast<unsigned>(values.size()));
    if (arguments.hasOverflowed()) {
        throwOutOfMemoryError(global, scope);
        return {};
    }
    for (const auto& value : values) value.appendTo(arguments);
    RELEASE_AND_RETURN(scope, constructArray(global, static_cast<ArrayAllocationProfile*>(nullptr), arguments));
}

static bool call(
    JSGlobalObject* globalObject,
    JSValue timerObject,
    JSValue callbackValue,
    JSValue argumentArray)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    JSValue restoreAsyncContext {};
    JSC::InternalFieldTuple* asyncContextData = nullptr;

    auto* asyncContext = dynamicDowncast<AsyncContextFrame>(callbackValue);
    if (asyncContext) {
        callbackValue = asyncContext->callback.get();
        asyncContextData = globalObject->m_asyncContextData.get();
        restoreAsyncContext = asyncContextData->getInternalField(0);
        asyncContextData->putInternalField(vm, 0, asyncContext->context.get());
    }
    auto restoreContext = WTF::makeScopeExit([&] {
        if (asyncContextData)
            asyncContextData->putInternalField(vm, 0, restoreAsyncContext);
    });

    if (auto* promise = dynamicDowncast<JSC::JSPromise>(callbackValue)) {
        promise->resolve(globalObject, vm, jsUndefined());
    } else {
        auto callData = JSC::getCallData(callbackValue);
        if (callData.type == CallData::Type::None) {
            auto throwScope = DECLARE_THROW_SCOPE(vm);
            throwScope.throwException(globalObject, createNotAFunctionError(globalObject, callbackValue));
        } else {
            MarkedArgumentBuffer args;
            if (!argumentArray.isUndefined()) {
                auto* array = uncheckedDowncast<JSArray>(argumentArray);
                unsigned length = array->length();
                args.ensureCapacity(length);
                if (!args.hasOverflowed()) {
                    for (unsigned i = 0; i < length; ++i) {
                        auto value = array->getDirectIndex(globalObject, i);
                        RELEASE_ASSERT(value);
                        args.append(value);
                    }
                }
            }
            if (args.hasOverflowed()) {
                auto throwScope = DECLARE_THROW_SCOPE(vm);
                throwOutOfMemoryError(globalObject, throwScope);
            } else
                JSC::profiledCall(globalObject, ProfilingReason::API, callbackValue, callData, timerObject, args);
        }
    }

    bool hadException = false;

    if (scope.exception()) [[unlikely]] {
        auto* exception = scope.exception();
        if (!scope.clearExceptionExceptTermination()) return true;
        Zig::GlobalObject::reportUncaughtExceptionAtEventLoop(globalObject, exception);
        hadException = true;
    }

    return hadException;
}

static bool shouldReschedule(JSValue repeat, JSValue idleTimeout, bool isInterval)
{
    if (isInterval && repeat.isNull())
        return false;
    return !idleTimeout.isNumber() || idleTimeout.asNumber() != -1;
}

static uint32_t repeatInterval(JSValue repeat)
{
    if (!repeat.isNumber())
        return 1;
    double value = repeat.asNumber();
    if (!std::isfinite(value) || value < 1 || value > std::numeric_limits<int32_t>::max())
        return 1;
    return static_cast<uint32_t>(value);
}

}

void Bun::Bindgen::Engine::bunBindgenEngine_timers_emitCountdownWarning(
    EngineCallContext& context,
    const BunBindgenEngine_timers_emitCountdownWarning_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* process = defaultGlobalObject(global)->processObject();
    auto emit = process->get(global, Identifier::fromString(vm, "emitWarning"_s));
    RETURN_IF_EXCEPTION(scope, void());

    auto value = jsNumber(args.countdown).toWTFString(global);
    RETURN_IF_EXCEPTION(scope, void());
    ASCIILiteral suffix = ""_s;
    ASCIILiteral name = ""_s;
    switch (args.kind) {
    case TimerWarningKind::overflow:
        suffix = " does not fit into a 32-bit signed integer"_s;
        name = "TimeoutOverflowWarning"_s;
        break;
    case TimerWarningKind::negative:
        suffix = " is a negative number"_s;
        name = "TimeoutNegativeWarning"_s;
        break;
    case TimerWarningKind::nan:
        suffix = " is not a number"_s;
        name = "TimeoutNaNWarning"_s;
        break;
    }
    auto message = tryMakeString(value, suffix, ".\nTimeout duration was set to 1."_s);
    if (message.isNull()) {
        throwOutOfMemoryError(global, scope);
        return;
    }
    auto* messageValue = jsString(vm, WTF::move(message));
    RETURN_IF_EXCEPTION(scope, void());
    auto* nameValue = jsString(vm, WTF::String(name));
    RETURN_IF_EXCEPTION(scope, void());
    MarkedArgumentBuffer callArgs;
    callArgs.append(messageValue);
    callArgs.append(nameValue);
    auto callData = JSC::getCallData(emit);
    if (callData.type == CallData::Type::None) {
        scope.throwException(global, createNotAFunctionError(global, emit));
        return;
    }
    JSC::call(global, emit, callData, process, callArgs);
    RETURN_IF_EXCEPTION(scope, void());
}

void Bun::Bindgen::Engine::bunBindgenEngine_timers_timerInitializeTimeout(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerInitializeTimeout_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto arguments = Bun::makeTimerArguments(globalObject, args.arguments);
    RETURN_IF_EXCEPTION(scope, void());
    auto interval = JSC::jsNumber(args.interval);
    auto timer = context.classValue(args.timer);
    bun_bindgen_class_Timeout_Timeout_slot_arguments_set_value(globalObject, timer, arguments);
    bun_bindgen_class_Timeout_Timeout_slot_idleTimeout_set_value(globalObject, timer, interval);
    bun_bindgen_class_Timeout_Timeout_slot_repeat_set_value(globalObject, timer, args.repeats ? interval : JSC::jsNull());
}

void Bun::Bindgen::Engine::bunBindgenEngine_timers_timerInitializeImmediate(
    EngineCallContext& context,
    const BunBindgenEngine_timers_timerInitializeImmediate_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto arguments = Bun::makeTimerArguments(global, args.arguments);
    RETURN_IF_EXCEPTION(scope, void());
    bun_bindgen_class_Immediate_Immediate_slot_arguments_set_value(global, context.classValue(args.timer), arguments);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_timers_timerPrepareReschedule(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerPrepareReschedule_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto timer = context.classValue(args.timer);
    auto repeat = bun_bindgen_class_Timeout_Timeout_slot_repeat_get_value(timer);
    auto idleTimeout = bun_bindgen_class_Timeout_Timeout_slot_idleTimeout_get_value(timer);
    if (!Bun::shouldReschedule(repeat, idleTimeout, args.isInterval))
        return false;
    bun_bindgen_class_Timeout_Timeout_slot_idleStart_set_value(globalObject, timer, JSC::jsNumber(static_cast<double>(args.idleStart)));
    return true;
}

bool Bun::Bindgen::Engine::bunBindgenEngine_timers_timerTimeoutCallbackPresent(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerTimeoutCallbackPresent_Arguments& args)
{
    auto callback = bun_bindgen_class_Timeout_Timeout_slot_callback_get_value(context.classValue(args.timer));
    return callback.toBoolean(&context.globalObject);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_timers_timerImmediateCallbackPresent(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerImmediateCallbackPresent_Arguments& args)
{
    auto callback = bun_bindgen_class_Immediate_Immediate_slot_callback_get_value(context.classValue(args.timer));
    return callback.toBoolean(&context.globalObject);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_timers_timerInvokeTimeoutCallback(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerInvokeTimeoutCallback_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    if (vm.hasPendingTerminationException()) [[unlikely]]
        return true;

    auto timer = context.classValue(args.timer);
    auto callback = bun_bindgen_class_Timeout_Timeout_slot_callback_get_value(timer);
    auto arguments = bun_bindgen_class_Timeout_Timeout_slot_arguments_get_value(timer);
    return Bun::call(globalObject, timer, callback, arguments);
}

Bun::Bindgen::Engine::BunBindgenEngine_timers_timerTimeoutPostDispatch_Return Bun::Bindgen::Engine::bunBindgenEngine_timers_timerTimeoutPostDispatch(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerTimeoutPostDispatch_Arguments& args)
{
    using Return = Bun::Bindgen::Engine::BunBindgenEngine_timers_timerTimeoutPostDispatch_Return;
    auto* globalObject = &context.globalObject;
    auto timer = context.classValue(args.timer);
    auto repeat = bun_bindgen_class_Timeout_Timeout_slot_repeat_get_value(timer);
    auto idleTimeout = bun_bindgen_class_Timeout_Timeout_slot_idleTimeout_get_value(timer);
    Return result {
        .shouldReschedule = args.isInterval && Bun::shouldReschedule(repeat, idleTimeout, true),
        .convertToInterval = false,
        .repeatInterval = 1,
    };
    if (args.isInterval || repeat.isNull() || !idleTimeout.isNumber() || idleTimeout.asNumber() == -1)
        return result;

    result.convertToInterval = true;
    result.repeatInterval = Bun::repeatInterval(repeat);
    bun_bindgen_class_Timeout_Timeout_slot_idleTimeout_set_value(globalObject, timer, repeat);
    result.shouldReschedule = Bun::shouldReschedule(repeat, repeat, true);
    return result;
}

bool Bun::Bindgen::Engine::bunBindgenEngine_timers_timerInvokeImmediateCallback(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_timers_timerInvokeImmediateCallback_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto timer = context.classValue(args.timer);
    auto callback = bun_bindgen_class_Immediate_Immediate_slot_callback_get_value(timer);
    auto arguments = bun_bindgen_class_Immediate_Immediate_slot_arguments_get_value(timer);
    bun_bindgen_class_Immediate_Immediate_slot_callback_set_value(globalObject, timer, JSC::jsUndefined());
    bun_bindgen_class_Immediate_Immediate_slot_arguments_set_value(globalObject, timer, JSC::jsUndefined());
    if (vm.hasPendingTerminationException()) [[unlikely]]
        return true;
    return Bun::call(globalObject, timer, callback, arguments);
}
