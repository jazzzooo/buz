#include "root.h"
#include <array>
#include <charconv>
#include <limits>

#include "AsyncContextFrame.h"
#include "Bindgen/IDLConvertBase.h"
#include "BunIDLConvertNumbers.h"
#include "BunPanic.h"
#include "BunBuiltinNames.h"
#include "BunClientData.h"
#include "BunProcess.h"
#include "ErrorStackTrace.h"
#include "ErrorStackFrame.h"
#include "ErrorBindings.h"
#include "JSFFIFunction.h"
#include "JSBuffer.h"
#include "JSDOMExceptionHandling.h"
#include "ObjectBindings.h"
#include "ScriptExecutionContext.h"
#include "SchemaBindings.h"
#include "StrongRef.h"
#include "WebCoreJSBuiltins.h"
#include "blob.h"
#include "wtf-bindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/AggregateError.h>
#include <JavaScriptCore/CustomGetterSetter.h>
#include <JavaScriptCore/BigIntObject.h>
#include <JavaScriptCore/BooleanObject.h>
#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/DeleteAllCodeEffort.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/InternalFieldTuple.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/GlobalObjectMethodTable.h>
#include <JavaScriptCore/HeapSnapshotBuilder.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSBigInt.h>
#include <JavaScriptCore/JSBoundFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGlobalProxy.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/JSMicrotask.h>
#include <JavaScriptCore/JSModuleLoader.h>
#include <JavaScriptCore/JSModuleNamespaceObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/MarkedVector.h>
#include <JavaScriptCore/MathCommon.h>
#include <JavaScriptCore/MicrotaskQueueInlines.h>
#include <JavaScriptCore/ModuleRegistryEntry.h>
#include <JavaScriptCore/NumberObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyDescriptor.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/ProxyObject.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/StringObject.h>
#include <wtf/text/StringImpl.h>
#include <JavaScriptCore/SourceProvider.h>
#include <JavaScriptCore/StackVisitor.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/Symbol.h>
#include <JavaScriptCore/JSWrapperObject.h>
#include <JavaScriptCore/Watchdog.h>
#include <wtf/DateMath.h>
#include <wtf/GregorianDateTime.h>
#include <wtf/RAMSize.h>
#include <wtf/TimeZone.h>
#include <wtf/WallTime.h>
#include <wtf/text/OrdinalNumber.h>
#include <wtf/text/MakeString.h>
#include <atomic>
#include <cstring>
#include "mimalloc.h"
#include <span>

#if OS(DARWIN) && ASSERT_ENABLED && !__has_feature(address_sanitizer)
#include <malloc/malloc.h>
#define BUN_BINDGEN_MALLOC_DEBUGGING_ENABLED 1
#else
#define BUN_BINDGEN_MALLOC_DEBUGGING_ENABLED 0
#endif

#if ASSERT_ENABLED
#include <JavaScriptCore/IntegrityInlines.h>
#endif

void Bun::Bindgen::Cpp::bunBindgenCpp_garbage_collection_jsGc(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_garbage_collection_jsGc_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    Bun::Bindgen::ZigExports::bunBindgenZig_garbage_collection_garbageCollect(globalObject, true);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_js_value_conversions_unwrapBoxedPrimitive(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_js_value_conversions_unwrapBoxedPrimitive_Arguments& args)
{
    if (!args.value.isObject())
        return args.value;

    auto* object = JSC::asObject(args.value);
    if (object->inherits<JSC::NumberObject>()) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        RELEASE_AND_RETURN(scope, JSC::jsNumber(object->toNumber(&context.globalObject)));
    }
    if (object->inherits<JSC::StringObject>()) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        RELEASE_AND_RETURN(scope, object->toString(&context.globalObject));
    }
    if (object->inherits<JSC::BooleanObject>() || object->inherits<JSC::BigIntObject>())
        return uncheckedDowncast<JSC::JSWrapperObject>(object)->internalValue();

    return object;
}

namespace Bun::Bindgen::Engine {

std::span<const uint8_t> externalBytesOwnerBytes(BindByteOwnerHandle* owner)
{
    BindConstByteSlice bytes;
    bun_bindgen_byte_owner_view(owner, &bytes);
    return { bytes.ptr, bytes.len };
}

void releaseExternalBytesOwner(BindByteOwnerHandle* owner)
{
    bun_bindgen_byte_owner_release(owner);
}

void bunBindgenEngine_WTFTimer_wtfTimerFire(
    const BunBindgenEngine_WTFTimer_wtfTimerFire_Arguments& args)
{
    args.timer->fired();
}

std::optional<JSC::JSValue> bunBindgenEngine_js_arrays_tryCastArrayValue(
    EngineCallContext&,
    const BunBindgenEngine_js_arrays_tryCastArrayValue_Arguments& args)
{
    return args.value;
}

bool bunBindgenEngine_js_value_inspection_jsValueIsAnyInt(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsAnyInt_Arguments& args)
{
    return args.value.isAnyInt();
}

bool bunBindgenEngine_bigints_jsValueIsBigInt(
    EngineCallContext&,
    const BunBindgenEngine_bigints_jsValueIsBigInt_Arguments& args)
{
    return args.value.isBigInt();
}

bool bunBindgenEngine_bigints_jsValueIsBigInt32(
    EngineCallContext&,
    const BunBindgenEngine_bigints_jsValueIsBigInt32_Arguments& args)
{
    return args.value.isBigInt32();
}

bool bunBindgenEngine_js_value_inspection_jsValueIsCallable(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsCallable_Arguments& args)
{
    return args.value.isCallable();
}

bool bunBindgenEngine_js_value_inspection_jsValueIsConstructor(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsConstructor_Arguments& args)
{
    return args.value.isConstructor();
}

bool bunBindgenEngine_js_value_inspection_jsValueIsInt32AsAnyInt(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsInt32AsAnyInt_Arguments& args)
{
    return args.value.isInt32AsAnyInt();
}

bool bunBindgenEngine_js_value_inspection_jsValueIsPrimitive(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsPrimitive_Arguments& args)
{
    return args.value.isPrimitive();
}

bool bunBindgenEngine_AsyncHooks_jsValueIsAsyncContextFrame(
    EngineCallContext&,
    const BunBindgenEngine_AsyncHooks_jsValueIsAsyncContextFrame_Arguments& args)
{
    return dynamicDowncast<AsyncContextFrame>(args.value) != nullptr;
}

bool bunBindgenEngine_AsyncHooks_callbackIdentityEquals(
    EngineCallContext&,
    const BunBindgenEngine_AsyncHooks_callbackIdentityEquals_Arguments& args)
{
    auto left = args.left;
    auto right = args.right;
    while (auto* frame = dynamicDowncast<AsyncContextFrame>(left))
        left = frame->callback.get();
    while (auto* frame = dynamicDowncast<AsyncContextFrame>(right))
        right = frame->callback.get();
    return left == right;
}

JSC::JSValue bunBindgenEngine_AsyncHooks_asyncContextFrameWithAsyncContextIfNeeded(
    EngineCallContext& context,
    const BunBindgenEngine_AsyncHooks_asyncContextFrameWithAsyncContextIfNeeded_Arguments& args)
{
    return AsyncContextFrame::withAsyncContextIfNeeded(&context.globalObject, args.value);
}

uint64_t bunBindgenEngine_js_strings_jsStringLength(
    EngineCallContext&,
    const BunBindgenEngine_js_strings_jsStringLength_Arguments& args)
{
    return JSC::asString(args.value)->length();
}

void bunBindgenEngine_source_providers_sourceProviderDeref(
    const BunBindgenEngine_source_providers_sourceProviderDeref_Arguments& args)
{
    args.provider->deref();
}

bool bunBindgenEngine_js_value_inspection_jsValueIsSymbol(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsSymbol_Arguments& args)
{
    return args.value.isSymbol();
}

uint64_t bunBindgenEngine_system_resources_ramSize(
    const BunBindgenEngine_system_resources_ramSize_Arguments&)
{
    return WTF::ramSize();
}

double bunBindgenEngine_date_time_currentUnixTimeMilliseconds(
    const BunBindgenEngine_date_time_currentUnixTimeMilliseconds_Arguments&)
{
    return WTF::WallTime::now().secondsSinceEpoch().milliseconds();
}

double bunBindgenEngine_date_time_currentDateMilliseconds(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_currentDateMilliseconds_Arguments&)
{
    return context.globalObject.jsDateNow();
}

void bunBindgenEngine_date_time_setOverriddenDateNow(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_setOverriddenDateNow_Arguments& args)
{
    context.globalObject.overridenDateNow = args.milliseconds;
}

bool bunBindgenEngine_js_value_inspection_jsValueStrictEqual(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueStrictEqual_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::JSValue::strictEqual(&context.globalObject, args.operands.left, args.operands.right));
}

bool bunBindgenEngine_js_value_inspection_jsValueSameValue(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueSameValue_Arguments& args)
{
    return JSC::sameValue(&context.globalObject, args.operands.left, args.operands.right);
}

int32_t bunBindgenEngine_js_value_conversions_jsValueCoerceToInt32(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_conversions_jsValueCoerceToInt32_Arguments& args)
{
    return WebCore::Converter<Bun::IDLLooseInteger<int32_t>>::convert(context.globalObject, args.value);
}

int64_t bunBindgenEngine_js_value_conversions_jsValueCoerceToInt64(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_conversions_jsValueCoerceToInt64_Arguments& args)
{
    return WebCore::Converter<Bun::IDLLooseInteger<int64_t>>::convert(context.globalObject, args.value);
}

double bunBindgenEngine_js_value_conversions_jsValueToNumber(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_conversions_jsValueToNumber_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, args.value.toNumber(&context.globalObject));
}

uint8_t bunBindgenEngine_js_value_inspection_jsValueType(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueType_Arguments& args)
{
    if (!args.value.isCell())
        return 0;
    return args.value.asCell()->type();
}

std::optional<JSC::JSValue> bunBindgenEngine_js_value_inspection_jsValueProxyTarget(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueProxyTarget_Arguments& args)
{
    auto* object = args.value.getObject();
    if (!object)
        return std::nullopt;
    if (auto* proxy = dynamicDowncast<JSC::JSGlobalProxy>(object))
        return proxy->target();
    if (auto* proxy = dynamicDowncast<JSC::ProxyObject>(object))
        return proxy->target();
    return std::nullopt;
}

bool bunBindgenEngine_errors_jsValueIsAnyError(
    EngineCallContext&,
    const BunBindgenEngine_errors_jsValueIsAnyError_Arguments& args)
{
    if (!args.value.isCell())
        return false;

    auto* cell = args.value.asCell();
    if (cell->type() == JSC::CellType)
        return cell->inherits<JSC::Exception>();
    return cell->type() == JSC::ErrorInstanceType;
}

std::optional<JSC::JSValue> bunBindgenEngine_promises_jsValueAsPromise(
    EngineCallContext&,
    const BunBindgenEngine_promises_jsValueAsPromise_Arguments& args)
{
    auto* promise = dynamicDowncast<JSC::JSPromise>(args.value);
    if (!promise)
        return std::nullopt;
    return promise;
}

bool bunBindgenEngine_errors_jsValueIsTerminationException(
    EngineCallContext&,
    const BunBindgenEngine_errors_jsValueIsTerminationException_Arguments& args)
{
    auto* exception = dynamicDowncast<JSC::Exception>(args.value);
    return exception && exception->vm().isTerminationException(exception);
}

bool bunBindgenEngine_js_value_inspection_jsValueEqual(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueEqual_Arguments& args)
{
    return args.operands.left == args.operands.right;
}

double bunBindgenEngine_date_time_jsValueDateMilliseconds(
    EngineCallContext&,
    const BunBindgenEngine_date_time_jsValueDateMilliseconds_Arguments& args)
{
    auto* date = dynamicDowncast<JSC::DateInstance>(args.value);
    return date ? date->internalNumber() : PNaN;
}

bool bunBindgenEngine_js_value_conversions_jsValuePureToBoolean(
    EngineCallContext&,
    const BunBindgenEngine_js_value_conversions_jsValuePureToBoolean_Arguments& args)
{
    return args.value.pureToBoolean() != TriState::False;
}

bool bunBindgenEngine_js_value_inspection_jsValueIsClass(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueIsClass_Arguments& args)
{
    if (!args.value.isCell())
        return false;

    auto callData = JSC::getCallData(args.value);
    switch (callData.type) {
    case JSC::CallData::Type::JS:
        return callData.js.functionExecutable->isClassConstructorFunction();
    case JSC::CallData::Type::Native:
        return !callData.native.isBoundFunction && args.value.isConstructor();
    default:
        return false;
    }
}

bool bunBindgenEngine_errors_jsValueIsAggregateError(
    EngineCallContext&,
    const BunBindgenEngine_errors_jsValueIsAggregateError_Arguments& args)
{
    auto* error = dynamicDowncast<JSC::ErrorInstance>(args.value);
    return error && error->errorType() == JSC::ErrorType::AggregateError;
}

JSC::JSValue bunBindgenEngine_js_value_inspection_jsValueGetPrototype(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueGetPrototype_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, args.value.getPrototype(&context.globalObject));
}

JSC::JSValue bunBindgenEngine_date_time_dateInstanceFromNumber(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_dateInstanceFromNumber_Arguments& args)
{
    return JSC::DateInstance::create(
        context.globalObject.vm(),
        context.globalObject.dateStructure(),
        args.value);
}

WTF::String bunBindgenEngine_date_time_dateToISOString(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_dateToISOString_Arguments& args)
{
    auto* date = dynamicDowncast<JSC::DateInstance>(args.value);
    if (!date || !std::isfinite(date->internalNumber()))
        return {};

    return Bun::toISOString(context.globalObject.vm(), date->internalNumber());
}

std::optional<WTF::String> bunBindgenEngine_json_serialization_jsonStringify(
    EngineCallContext& context,
    const BunBindgenEngine_json_serialization_jsonStringify_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = JSC::JSONStringify(&context.globalObject, args.input.value, static_cast<unsigned>(args.input.indent));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (result.isNull())
        return std::nullopt;
    return result;
}

std::optional<WTF::String> bunBindgenEngine_json_serialization_jsonStringifyFast(
    EngineCallContext& context,
    const BunBindgenEngine_json_serialization_jsonStringifyFast_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = JSC::JSONStringify(&context.globalObject, args.value, JSC::jsUndefined());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (result.isNull())
        return std::nullopt;
    return result;
}

JSC::JSValue bunBindgenEngine_symbols_symbolFor(
    EngineCallContext& context,
    const BunBindgenEngine_symbols_symbolFor_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    return JSC::Symbol::create(vm, vm.symbolRegistry().symbolForKey(args.key));
}

WTF::String bunBindgenEngine_symbols_jsValueSymbolDescription(
    EngineCallContext&,
    const BunBindgenEngine_symbols_jsValueSymbolDescription_Arguments& args)
{
    if (!args.value.isSymbol())
        return {};
    auto& uid = JSC::asSymbol(args.value)->uid();
    if (uid.isNullSymbol() || uid.isEmpty())
        return {};
    return WTF::String(static_cast<WTF::StringImpl&>(uid));
}

bool bunBindgenEngine_js_value_inspection_jsValueIsInstanceOf(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueIsInstanceOf_Arguments& args)
{
    if (!args.input.value.isCell())
        return false;

    auto* constructor = args.input.constructor.getObject();
    if (!constructor || !constructor->structure()->typeInfo().implementsHasInstance())
        return false;

    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, constructor->hasInstance(&context.globalObject, args.input.value));
}

bool bunBindgenEngine_js_value_inspection_jsValueIsIterable(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueIsIterable_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::hasIteratorMethod(&context.globalObject, args.value));
}

bool bunBindgenEngine_js_strings_jsValueStringIncludes(
    EngineCallContext& context,
    const BunBindgenEngine_js_strings_jsValueStringIncludes_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto value = args.value.toWTFString(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    auto search = args.search.toWTFString(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    RELEASE_AND_RETURN(scope, value.find(search) != WTF::notFound);
}

bool bunBindgenEngine_errors_jsValueIsException(
    EngineCallContext&,
    const BunBindgenEngine_errors_jsValueIsException_Arguments& args)
{
    return dynamicDowncast<JSC::Exception>(args.value) != nullptr;
}

JSC::JSValue bunBindgenEngine_errors_exceptionThrownValue(
    EngineCallContext&,
    const BunBindgenEngine_errors_exceptionThrownValue_Arguments& args)
{
    auto* exception = dynamicDowncast<JSC::Exception>(args.exception);
    RELEASE_ASSERT(exception);
    return exception->value();
}

double bunBindgenEngine_numeric_conversions_operationMathPow(
    const BunBindgenEngine_numeric_conversions_operationMathPow_Arguments& args)
{
    return JSC::operationMathPow(args.base, args.exponent);
}

bool bunBindgenEngine_regular_expressions_jsValueToMatch(
    EngineCallContext& context,
    const BunBindgenEngine_regular_expressions_jsValueToMatch_Arguments& args)
{
    auto* regex = dynamicDowncast<JSC::RegExpObject>(args.regex);
    auto* value = args.value.isString() ? JSC::asString(args.value) : nullptr;
    if (!regex || !value)
        return false;
    return !!regex->match(&context.globalObject, value);
}

class IterableIterator {
public:
    IterableIterator(JSC::VM& vm, JSC::IterationRecord record)
        : iterator(vm, record.iterator)
        , nextMethod(vm, record.nextMethod)
    {
    }

    JSC::IterationRecord record() const
    {
        return { iterator.get(), nextMethod.get() };
    }

    JSC::Strong<JSC::Unknown> iterator;
    JSC::Strong<JSC::Unknown> nextMethod;
    bool done = false;

    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(IterableIterator);
};

std::optional<IterableIterator*> bunBindgenEngine_iterable_iterators_iterableIteratorCreate(
    EngineCallContext& context,
    const BunBindgenEngine_iterable_iterators_iterableIteratorCreate_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto record = JSC::iteratorForIterable(&context.globalObject, args.value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return new IterableIterator(context.globalObject.vm(), {
                                                               record.iterator,
                                                               record.nextMethod,
                                                           });
}

std::optional<JSC::JSValue> bunBindgenEngine_iterable_iterators_iterableIteratorNext(
    EngineCallContext& context,
    const BunBindgenEngine_iterable_iterators_iterableIteratorNext_Arguments& args)
{
    if (args.iterator->done)
        return std::nullopt;

    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto next = JSC::iteratorStep(globalObject, args.iterator->record());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (next.isFalse()) {
        args.iterator->done = true;
        return std::nullopt;
    }

    auto value = JSC::iteratorValue(globalObject, next);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return value;
}

void bunBindgenEngine_iterable_iterators_iterableIteratorClose(
    EngineCallContext& context,
    const BunBindgenEngine_iterable_iterators_iterableIteratorClose_Arguments& args)
{
    if (args.iterator->done)
        return;
    args.iterator->done = true;
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    JSC::iteratorClose(&context.globalObject, args.iterator->iterator.get());
    RETURN_IF_EXCEPTION(scope, void());
}

void bunBindgenEngine_iterable_iterators_iterableIteratorDestroy(
    const BunBindgenEngine_iterable_iterators_iterableIteratorDestroy_Arguments& args)
{
    delete args.iterator;
}

void bunBindgenEngine_microtasks_queueMicrotaskJob(
    EngineCallContext& context,
    const BunBindgenEngine_microtasks_queueMicrotaskJob_Arguments& args)
{
    auto* globalObject = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    JSC::JSValue microtaskArgs[] = {
        args.function,
        globalObject->m_asyncContextData.get()->getInternalField(0),
        args.first.value_or(JSC::jsUndefined()),
        args.second.value_or(JSC::jsUndefined()),
    };

    JSC::QueuedTask task { nullptr, JSC::InternalMicrotask::BunPerformMicrotaskJob, 0, globalObject, WTF::move(microtaskArgs[0]), WTF::move(microtaskArgs[1]), WTF::move(microtaskArgs[2]), WTF::move(microtaskArgs[3]) };
    globalObject->vm().queueMicrotask(WTF::move(task));
}

void releaseNativeMicrotask(Bun::NativeMicrotask* task)
{
    ZigExports::bunBindgenZig_microtasks_discardQueuedMicrotask(task);
}

bool bunBindgenEngine_microtasks_discardQueuedTasks(
    const BunBindgenEngine_microtasks_discardQueuedTasks_Arguments& args)
{
    auto& queue = args.vm->defaultMicrotaskQueue();
    bool hadTasks = !queue.isEmpty();
    queue.clear();
    return hadTasks;
}

void bunBindgenEngine_microtasks_queueMicrotaskTask(
    EngineCallContext& context,
    const BunBindgenEngine_microtasks_queueMicrotaskTask_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    RELEASE_ASSERT(args.task);
    auto* methods = globalObject->globalObjectMethodTable();
    RELEASE_ASSERT(methods->runNativeMicrotask && methods->destroyNativeMicrotask);
    JSC::QueuedTask task = JSC::QueuedTask::createBunNativeTask(globalObject, args.task);
    globalObject->vm().defaultMicrotaskQueue().enqueue(WTF::move(task));
}

}

namespace Bun::Bindgen::Engine {

JSC::JSValue bunBindgenEngine_errors_createAggregateError(
    EngineCallContext& context,
    const BunBindgenEngine_errors_createAggregateError_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* errors = JSC::constructArray(&globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), args.errors.data(), args.errors.size());
    RETURN_IF_EXCEPTION(scope, {});
    auto* structure = globalObject.errorStructure(JSC::ErrorType::AggregateError);
    RELEASE_AND_RETURN(scope, JSC::createAggregateError(vm, structure, errors, args.message, JSC::jsUndefined(), nullptr, JSC::TypeNothing, false));
}

void bunBindgenEngine_ModuleLoader_deleteModuleRegistryEntry(
    EngineCallContext& context,
    const BunBindgenEngine_ModuleLoader_deleteModuleRegistryEntry_Arguments& args)
{
    auto identifier = JSC::Identifier::fromString(context.globalObject.vm(), args.name);
    context.globalObject.moduleLoader()->removeEntry(identifier);
}

JSC::JSValue bunBindgenEngine_ModuleLoader_loadAndEvaluateModule(
    EngineCallContext& context,
    const BunBindgenEngine_ModuleLoader_loadAndEvaluateModule_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* promise = JSC::loadAndEvaluateModule(&context.globalObject, makeAtomString(args.moduleName), nullptr, nullptr);
    EXCEPTION_ASSERT(!!promise == !scope.exception());
    return promise;
}

JSC::JSValue bunBindgenEngine_ModuleLoader_importModule(
    EngineCallContext& context,
    const BunBindgenEngine_ModuleLoader_importModule_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* promise = JSC::importModule(&context.globalObject, JSC::Identifier::fromString(vm, args.moduleName), JSC::Identifier(), nullptr, nullptr);
    EXCEPTION_ASSERT(!!scope.exception() == !promise);
    return promise;
}

JSC::JSValue bunBindgenEngine_ModuleLoader_getMacroExport(
    EngineCallContext& context,
    const BunBindgenEngine_ModuleLoader_getMacroExport_Arguments& args)
{
    auto& global = context.globalObject;
    auto& vm = global.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* promise = uncheckedDowncast<JSC::JSPromise>(args.loadedModule);
    if (promise->status() != JSC::JSPromise::Status::Fulfilled) {
        JSC::throwTypeError(&global, scope, "Macro module has not finished loading"_s);
        return {};
    }
    // Non-dynamic module loading fulfills with the resolved key, without consulting a namespace's `then` export.
    auto key = promise->result().toPropertyKey(&global);
    RETURN_IF_EXCEPTION(scope, {});
    auto* entry = global.moduleLoader()->registryEntry(key);
    if (!entry || !entry->record()) {
        JSC::throwTypeError(&global, scope, "Macro module is no longer available"_s);
        return {};
    }
    auto* moduleNamespace = global.moduleLoader()->getModuleNamespaceObject(&global, entry->record());
    RETURN_IF_EXCEPTION(scope, {});
    auto value = moduleNamespace->get(&global, JSC::Identifier::fromString(vm, args.exportName));
    RETURN_IF_EXCEPTION(scope, {});
    if (JSC::getCallData(value).type == JSC::CallData::Type::None) {
        auto message = tryMakeString("Macro export \""_s, args.exportName, "\" must be callable"_s);
        if (message.isNull()) {
            JSC::throwOutOfMemoryError(&global, scope);
            return {};
        }
        JSC::throwTypeError(&global, scope, message);
        return {};
    }
    return value;
}

void bunBindgenEngine_microtasks_handleRejectedPromises(
    EngineCallContext& context,
    const BunBindgenEngine_microtasks_handleRejectedPromises_Arguments&)
{
    uncheckedDowncast<::Zig::GlobalObject>(&context.globalObject)->handleRejectedPromises();
}

void bunBindgenEngine_microtasks_drainMicrotasks(
    EngineCallContext& context,
    const BunBindgenEngine_microtasks_drainMicrotasks_Arguments&)
{
    auto* globalObject = uncheckedDowncast<::Zig::GlobalObject>(&context.globalObject);
    auto result = globalObject->drainMicrotasks();
    RELEASE_ASSERT(!result || context.globalObject.vm().hasPendingTerminationException());
}

template<typename Arguments>
static std::optional<JSC::JSValue> assignToStream(
    EngineCallContext& context,
    const Arguments& args)
{
    auto* globalObject = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    auto result = JSC::JSValue::decode(globalObject->assignToStream(args.stream, context.classValue(args.controller)));
    if (!result || result.isUndefinedOrNull())
        return std::nullopt;
    RELEASE_ASSERT(result.template inherits<JSC::JSPromise>());
    return result;
}

#define BUN_DEFINE_ASSIGN_TO_STREAM(sinkName)                                                 \
    std::optional<JSC::JSValue> bunBindgenEngine_readable_streams_assignTo##sinkName##Stream( \
        EngineCallContext& context,                                                           \
        const BunBindgenEngine_readable_streams_assignTo##sinkName##Stream_Arguments& args)   \
    {                                                                                         \
        return assignToStream(context, args);                                                 \
    }

BUN_DEFINE_ASSIGN_TO_STREAM(ArrayBufferSink)
BUN_DEFINE_ASSIGN_TO_STREAM(FileSink)
BUN_DEFINE_ASSIGN_TO_STREAM(HTTPResponseSink)
BUN_DEFINE_ASSIGN_TO_STREAM(HTTPSResponseSink)
BUN_DEFINE_ASSIGN_TO_STREAM(H3ResponseSink)
BUN_DEFINE_ASSIGN_TO_STREAM(NetworkSink)

#undef BUN_DEFINE_ASSIGN_TO_STREAM

void bunBindgenEngine_UpgradedDuplex_upgradedDuplexCall(
    EngineCallContext& context,
    const BunBindgenEngine_UpgradedDuplex_upgradedDuplexCall_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    if (args.data) {
        auto* buffer = WebCore::createBuffer(&globalObject, *args.data);
        RETURN_IF_EXCEPTION(scope, void());
        arguments.append(buffer);
    } else {
        arguments.append(JSC::jsNull());
    }
    auto property = JSC::Identifier::fromString(vm, args.write ? "write"_s : "end"_s);
    auto function = args.duplex.get(&globalObject, property);
    RETURN_IF_EXCEPTION(scope, void());
    auto callData = JSC::getCallData(function);
    if (callData.type == JSC::CallData::Type::None)
        return;
    JSC::profiledCall(&globalObject, JSC::ProfilingReason::API, function, callData, args.duplex, arguments);
    RETURN_IF_EXCEPTION(scope, void());
}

JSC::JSValue bunBindgenEngine_AsyncHooks_createAsyncContextFrame(
    EngineCallContext& context,
    const BunBindgenEngine_AsyncHooks_createAsyncContextFrame_Arguments& args)
{
    return AsyncContextFrame::create(&context.globalObject, args.callback, args.context);
}

void bunBindgenEngine_global_objects_reloadGlobalObject(
    EngineCallContext& context,
    const BunBindgenEngine_global_objects_reloadGlobalObject_Arguments& args)
{
    UNUSED_PARAM(args);
    static_cast<::Zig::GlobalObject*>(&context.globalObject)->reload();
}

#define BUN_BINDGEN_OBJECT_SURFACE_GarbageCollectionGlobal
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_GarbageCollectionGlobal

void bunBindgenEngine_garbage_collection_addGc(
    EngineCallContext& context,
    const BunBindgenEngine_garbage_collection_addGc_Arguments& args)
{
    UNUSED_PARAM(args);
    auto& globalObject = context.globalObject;
    bunBindgenObjectSurface_GarbageCollectionGlobal_install(globalObject.vm(), globalObject.classInfo(), globalObject);
}

JSC::JSValue bunBindgenEngine_readable_streams_readableStreamEmpty(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamEmpty_Arguments& args)
{
    UNUSED_PARAM(args);
    auto* globalObject = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = globalObject->builtinInternalFunctions().readableStreamInternals().m_createEmptyReadableStreamFunction.get();
    auto emptyStream = JSC::call(globalObject, function, JSC::ArgList(), "ReadableStream.create"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return emptyStream;
}

JSC::JSValue bunBindgenEngine_readable_streams_readableStreamUsed(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamUsed_Arguments& args)
{
    UNUSED_PARAM(args);
    auto* globalObject = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = globalObject->builtinInternalFunctions().readableStreamInternals().m_createUsedReadableStreamFunction.get();
    auto usedStream = JSC::call(globalObject, function, JSC::ArgList(), "ReadableStream.create"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return usedStream;
}

double bunBindgenEngine_date_time_gregorianDateTimeToMS(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_gregorianDateTimeToMS_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    WTF::GregorianDateTime dateTime;
    dateTime.setYear(args.year);
    dateTime.setMonth(args.month - 1);
    dateTime.setMonthDay(args.day);
    dateTime.setHour(args.hour);
    dateTime.setMinute(args.minute);
    dateTime.setSecond(args.second);
    return vm.dateCache.gregorianDateTimeToMS(dateTime, args.millisecond, args.localTime ? WTF::TimeType::LocalTime : WTF::TimeType::UTCTime);
}

int64_t bunBindgenEngine_js_value_conversions_jsValueToInt64(
    EngineCallContext&,
    const BunBindgenEngine_js_value_conversions_jsValueToInt64_Arguments& args)
{
    RELEASE_ASSERT(args.value.isHeapBigInt());
    auto* heapBigInt = args.value.asHeapBigInt();
    return heapBigInt->toBigInt64(heapBigInt);
}

BunBindgenEngine_property_accessors_inspectCustomGetterSetter_Return bunBindgenEngine_property_accessors_inspectCustomGetterSetter(
    EngineCallContext&,
    const BunBindgenEngine_property_accessors_inspectCustomGetterSetter_Arguments& args)
{
    auto* accessor = WTF::downcast<JSC::CustomGetterSetter>(args.value.asCell());
    return { .getter = !!accessor->getter(), .setter = !!accessor->setter() };
}

BunBindgenEngine_property_accessors_inspectGetterSetter_Return bunBindgenEngine_property_accessors_inspectGetterSetter(
    EngineCallContext&,
    const BunBindgenEngine_property_accessors_inspectGetterSetter_Arguments& args)
{
    auto* accessor = WTF::downcast<JSC::GetterSetter>(args.value.asCell());
    return { .getter = !accessor->isGetterNull(), .setter = !accessor->isSetterNull() };
}

WTF::String bunBindgenEngine_js_strings_stringFromJS(
    EngineCallContext& context,
    const BunBindgenEngine_js_strings_stringFromJS_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, args.value.toWTFString(&context.globalObject));
}

JSC::JSValue bunBindgenEngine_js_strings_stringToJS(
    EngineCallContext& context,
    const BunBindgenEngine_js_strings_stringToJS_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    if (args.value.isEmpty())
        return JSC::jsEmptyString(vm);
    return JSC::jsString(vm, args.value);
}

JSC::JSValue bunBindgenEngine_errors_createError(
    EngineCallContext& context,
    const BunBindgenEngine_errors_createError_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::createError(&context.globalObject, args.message));
}

JSC::JSValue bunBindgenEngine_errors_createTypeError(
    EngineCallContext& context,
    const BunBindgenEngine_errors_createTypeError_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::createTypeError(&context.globalObject, args.message));
}

JSC::JSValue bunBindgenEngine_errors_createRangeError(
    EngineCallContext& context,
    const BunBindgenEngine_errors_createRangeError_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::createRangeError(&context.globalObject, args.message));
}

JSC::JSValue bunBindgenEngine_errors_createSyntaxError(
    EngineCallContext& context,
    const BunBindgenEngine_errors_createSyntaxError_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::createSyntaxError(&context.globalObject, args.message));
}

void bunBindgenEngine_errors_errorSetName(
    EngineCallContext& context,
    const BunBindgenEngine_errors_errorSetName_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* error = dynamicDowncast<JSC::ErrorInstance>(args.errorValue);
    RELEASE_ASSERT(error);
    error->putDirect(vm, vm.propertyNames->name, JSC::jsString(vm, args.name));
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

void bunBindgenEngine_errors_errorSetCode(
    EngineCallContext& context,
    const BunBindgenEngine_errors_errorSetCode_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* error = dynamicDowncast<JSC::ErrorInstance>(args.errorValue);
    RELEASE_ASSERT(error);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "code"_s), JSC::jsString(vm, args.code));
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

void bunBindgenEngine_errors_errorSetErrno(
    EngineCallContext& context,
    const BunBindgenEngine_errors_errorSetErrno_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* error = dynamicDowncast<JSC::ErrorInstance>(args.errorValue);
    RELEASE_ASSERT(error);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "errno"_s), JSC::jsNumber(args.errorNumber));
}

JSC::JSValue bunBindgenEngine_js_strings_parseJSONFromString(
    EngineCallContext& context,
    const BunBindgenEngine_js_strings_parseJSONFromString_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto result = JSC::JSONParse(globalObject, args.value);
    RETURN_IF_EXCEPTION(scope, {});
    if (!result)
        scope.throwException(globalObject, JSC::createSyntaxError(globalObject, args.value.isEmpty() ? "Unexpected end of JSON input"_s : "Failed to parse JSON"_s));
    return result;
}

double bunBindgenEngine_date_time_parseDate(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_parseDate_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    return vm.dateCache.parseDate(globalObject, vm, args.value);
}

bool bunBindgenEngine_date_time_setTimeZone(
    EngineCallContext& context,
    const BunBindgenEngine_date_time_setTimeZone_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    Bun::PreparedTimeZoneOverride prepared;
    switch (prepared.prepare(args.timeZone)) {
    case Bun::PreparedTimeZoneOverride::Result::Invalid:
        return false;
    case Bun::PreparedTimeZoneOverride::Result::OutOfMemory:
        throwOutOfMemoryError(&context.globalObject, scope);
        return false;
    case Bun::PreparedTimeZoneOverride::Result::Valid:
        break;
    }

    prepared.commit();
    WTF::timeZoneDidChange();
    vm.dateCache.clearForTimeZoneChange();
    return true;
}

uint32_t bunBindgenEngine_global_objects_scriptExecutionContextIdentifier(
    EngineCallContext& context,
    const BunBindgenEngine_global_objects_scriptExecutionContextIdentifier_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->scriptExecutionContext()->identifier();
}

void bunBindgenEngine_global_objects_detachBindgenWrappers(
    const BunBindgenEngine_global_objects_detachBindgenWrappers_Arguments& args)
{
    auto* data = WebCore::clientData(args.global->vm());
    if (data->bindgenWrapperRegistry)
        data->bindgenWrapperRegistry->detachAll();
}

static JSC::JSPromise* bindingPromise(JSC::JSValue value)
{
    RELEASE_ASSERT(value.inherits<JSC::JSPromise>());
    return uncheckedDowncast<JSC::JSPromise>(value.asCell());
}

void bunBindgenEngine_promises_promiseResolve(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseResolve_Arguments& args)
{
    auto* promise = bindingPromise(args.promise);
    RELEASE_ASSERT(promise->status() == JSC::JSPromise::Status::Pending);
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
    promise->resolve(&context.globalObject, vm, args.value);
}

void bunBindgenEngine_promises_promiseReject(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseReject_Arguments& args)
{
    auto* promise = bindingPromise(args.promise);
    RELEASE_ASSERT(promise->status() == JSC::JSPromise::Status::Pending);
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
    promise->reject(vm, args.value);
}

void bunBindgenEngine_promises_promiseRejectAsHandled(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseRejectAsHandled_Arguments& args)
{
    auto* promise = bindingPromise(args.promise);
    RELEASE_ASSERT(promise->status() == JSC::JSPromise::Status::Pending);
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
    promise->rejectAsHandled(vm, args.value);
}

BunBindgenEngine_promises_promiseStatus_Return bunBindgenEngine_promises_promiseStatus(
    EngineCallContext&,
    const BunBindgenEngine_promises_promiseStatus_Arguments& args)
{
    using Status = BunBindgenEngine_promises_promiseStatus_Return;
    switch (bindingPromise(args.promise)->status()) {
    case JSC::JSPromise::Status::Pending:
        return Status::pending;
    case JSC::JSPromise::Status::Fulfilled:
        return Status::fulfilled;
    case JSC::JSPromise::Status::Rejected:
        return Status::rejected;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void bunBindgenEngine_promises_promiseSetHandled(
    EngineCallContext&,
    const BunBindgenEngine_promises_promiseSetHandled_Arguments& args)
{
    bindingPromise(args.promise)->markAsHandled();
}

uint64_t bunBindgenEngine_property_accessors_jsValueGetIndexedLength(
    EngineCallContext& context,
    const BunBindgenEngine_property_accessors_jsValueGetIndexedLength_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* object = args.value.toObject(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, 0);
    RELEASE_AND_RETURN(scope, JSC::toLength(&context.globalObject, object));
}

JSC::JSValue bunBindgenEngine_property_accessors_jsValueGetIndex(
    EngineCallContext& context,
    const BunBindgenEngine_property_accessors_jsValueGetIndex_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* object = args.value.toObject(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, object->getIndex(&context.globalObject, args.index));
}

std::optional<JSC::JSValue> bunBindgenEngine_property_accessors_jsObjectGetOwnIndex(
    EngineCallContext& context,
    const BunBindgenEngine_property_accessors_jsObjectGetOwnIndex_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* object = JSC::asObject(args.object);
    if (args.index <= std::numeric_limits<uint32_t>::max()) {
        auto result = object->getDirectIndex(global, static_cast<uint32_t>(args.index));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (result.isEmpty())
            return std::nullopt;
        return result;
    }
    std::array<char, std::numeric_limits<uint64_t>::digits10 + 1> digits;
    auto [end, error] = std::to_chars(digits.data(), digits.data() + digits.size(), args.index);
    RELEASE_ASSERT(error == std::errc {});
    auto name = JSC::Identifier::fromString(vm, std::span<const Latin1Character>(reinterpret_cast<const Latin1Character*>(digits.data()), end - digits.data()));
    JSC::PropertySlot slot(object, JSC::PropertySlot::InternalMethodType::Get);
    bool found = object->getOwnPropertySlotInline(global, name, slot);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!found)
        return std::nullopt;
    RELEASE_AND_RETURN(scope, slot.getValue(global, name));
}

std::optional<JSC::JSValue> bunBindgenEngine_errors_jsValueGetErrorsProperty(
    EngineCallContext& context,
    const BunBindgenEngine_errors_jsValueGetErrorsProperty_Arguments& args)
{
    auto* object = args.value.getObject();
    RELEASE_ASSERT(object);
    auto& vm = context.globalObject.vm();
    auto value = object->getDirect(vm, vm.propertyNames->errors);
    if (!value || value.isGetterSetter() || value.isCustomGetterSetter())
        return std::nullopt;
    return value;
}

JSC::JSValue bunBindgenEngine_property_accessors_jsValueKeys(
    EngineCallContext& context,
    const BunBindgenEngine_property_accessors_jsValueKeys_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* object = args.value.toObject(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, JSC::ownPropertyKeys(&context.globalObject, object, JSC::PropertyNameMode::Strings, JSC::DontEnumPropertiesMode::Exclude));
}

JSC::JSValue bunBindgenEngine_property_accessors_jsValueValues(
    EngineCallContext& context,
    const BunBindgenEngine_property_accessors_jsValueValues_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* object = args.value.toObject(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, JSC::objectValues(context.globalObject.vm(), &context.globalObject, object));
}

JSC::JSValue bunBindgenEngine_js_value_conversions_jsValueToObject(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_conversions_jsValueToObject_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, args.value.toObject(&context.globalObject));
}

JSC::JSValue bunBindgenEngine_array_buffers_createUninitializedUint8Array(
    EngineCallContext& context,
    const BunBindgenEngine_array_buffers_createUninitializedUint8Array_Arguments& args)
{
    return JSC::JSUint8Array::createUninitialized(
        &context.globalObject,
        context.globalObject.m_typedArrayUint8.get(&context.globalObject),
        args.length);
}

JSC::JSValue bunBindgenEngine_UpgradedDuplex_createHandlerArray(
    EngineCallContext& context,
    const BunBindgenEngine_UpgradedDuplex_createHandlerArray_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    JSC::MarkedArgumentBuffer handlers;
    args.onData.appendTo(handlers);
    args.onEnd.appendTo(handlers);
    args.onWritable.appendTo(handlers);
    args.onClose.appendTo(handlers);
    RELEASE_AND_RETURN(scope, JSC::constructArray(&context.globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), handlers));
}

JSC::JSValue bunBindgenEngine_NodeSocket_socketDuplexUpgradeResult(
    EngineCallContext& context,
    const BunBindgenEngine_NodeSocket_socketDuplexUpgradeResult_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    JSC::JSValue values[] = { context.classValue(args.socket), args.events };
    RELEASE_AND_RETURN(scope, JSC::constructArray(&context.globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), values, 2));
}

JSC::JSValue bunBindgenEngine_Socket_socketTLSUpgradeResult(
    EngineCallContext& context,
    const BunBindgenEngine_Socket_socketTLSUpgradeResult_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    JSC::JSValue values[] = { context.classValue(args.raw), context.classValue(args.tls) };
    RELEASE_AND_RETURN(scope, JSC::constructArray(&context.globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), values, 2));
}

std::optional<JSC::JSValue> bunBindgenEngine_property_accessors_jsValueGetOwnString(
    EngineCallContext& context,
    const BunBindgenEngine_property_accessors_jsValueGetOwnString_Arguments& args)
{
    auto* object = args.value.getObject();
    if (!object)
        return std::nullopt;
    auto& globalObject = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto identifier = JSC::Identifier::fromString(globalObject.vm(), args.key);
    JSC::PropertySlot slot(object, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
    if (!JSC::JSObject::getOwnPropertySlot(object, &globalObject, identifier, slot)) {
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        scope.release();
        return std::nullopt;
    }
    RELEASE_AND_RETURN(scope, std::optional<JSC::JSValue> { slot.getValue(&globalObject, identifier) });
}

static WTF::String jsValueNameProperty(JSC::JSGlobalObject& global, JSC::JSValue value, JSC::ThrowScope& scope)
{
    auto* object = value.getObject();
    if (!object)
        return {};

    auto& vm = global.vm();
    if (auto* function = dynamicDowncast<JSC::JSFunction>(object)) {
        auto actualName = function->name(vm);
        RETURN_IF_EXCEPTION(scope, {});
        if (!actualName.isEmpty() || function->isHostOrBuiltinFunction())
            return actualName;
        return function->jsExecutable()->ecmaName().string();
    }
    if (auto* function = dynamicDowncast<JSC::InternalFunction>(object))
        return function->name();

    auto name = object->getIfPropertyExists(&global, vm.propertyNames->toStringTagSymbol);
    RETURN_IF_EXCEPTION(scope, {});
    if (name && name.isString()) {
        auto string = name.toWTFString(&global);
        RETURN_IF_EXCEPTION(scope, {});
        if (!string.isEmpty())
            return string;
    }

    return {};
}

WTF::String bunBindgenEngine_js_value_inspection_jsValueGetName(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueGetName_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = jsValueNameProperty(context.globalObject, args.value, scope);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, result);
}

WTF::String bunBindgenEngine_js_value_inspection_jsValueGetDeclaredName(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueGetDeclaredName_Arguments& args)
{
    if (auto* function = dynamicDowncast<JSC::JSFunction>(args.value); function && !function->isHostOrBuiltinFunction())
        return function->jsExecutable()->name().string();
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = jsValueNameProperty(context.globalObject, args.value, scope);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, result);
}

bool bunBindgenEngine_js_value_inspection_jsValueIsConstructorPrototype(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueIsConstructorPrototype_Arguments& args)
{
    auto* object = args.value.getObject();
    if (!object)
        return false;

    auto& global = context.globalObject;
    auto& vm = global.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::PropertySlot constructorSlot(object, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
    bool hasConstructor = object->methodTable()->getOwnPropertySlot(object, &global, vm.propertyNames->constructor, constructorSlot);
    RETURN_IF_EXCEPTION(scope, false);
    if (!hasConstructor || !constructorSlot.isValue())
        return false;
    auto* constructor = constructorSlot.getPureResult().getObject();
    if (!constructor)
        return false;

    JSC::PropertySlot prototypeSlot(constructor, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
    bool hasPrototype = constructor->methodTable()->getOwnPropertySlot(constructor, &global, vm.propertyNames->prototype, prototypeSlot);
    RETURN_IF_EXCEPTION(scope, false);
    return hasPrototype && prototypeSlot.isValue() && prototypeSlot.getPureResult() == args.value;
}

WTF::String bunBindgenEngine_js_value_inspection_jsValueClassName(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsValueClassName_Arguments& args)
{
    auto* cell = args.value.isCell() ? args.value.asCell() : nullptr;
    if (!cell || !cell->isObject())
        return "[not a class]"_s;

    auto className = WTF::StringView(cell->className());
    if (className.isEmpty() || className == "Function"_s) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        auto result = jsValueNameProperty(context.globalObject, args.value, scope);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, result);
    }

    auto calculated = JSC::JSObject::calculatedClassName(args.value.getObject());
    if (!calculated.isEmpty())
        return calculated;
    return className.toString();
}

std::optional<WTF::String> bunBindgenEngine_js_value_inspection_jsValueClassInfoName(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_jsValueClassInfoName_Arguments& args)
{
    auto* info = args.value.classInfoOrNull();
    if (!info)
        return std::nullopt;
    return WTF::String(info->className.span8());
}

WTF::String bunBindgenEngine_js_value_inspection_jsTypeStringForValue(
    EngineCallContext& context,
    const BunBindgenEngine_js_value_inspection_jsTypeStringForValue_Arguments& args)
{
    return JSC::jsTypeStringForValue(&context.globalObject, args.value)->value(&context.globalObject);
}

std::optional<JSC::JSValue> bunBindgenEngine_js_value_inspection_proxyObjectGetInternalField(
    EngineCallContext&,
    const BunBindgenEngine_js_value_inspection_proxyObjectGetInternalField_Arguments& args)
{
    auto* proxy = dynamicDowncast<JSC::ProxyObject>(args.value);
    RELEASE_ASSERT(proxy);
    JSC::JSValue result = proxy->internalField(static_cast<JSC::ProxyObject::Field>(args.field)).get();
    if (result.isEmpty())
        return std::nullopt;
    return result;
}

JSC::JSValue bunBindgenEngine_js_strings_jsValueToString(
    EngineCallContext& context,
    const BunBindgenEngine_js_strings_jsValueToString_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, args.value.toString(&context.globalObject));
}

JSC::JSValue bunBindgenEngine_js_functions_jsValueBind(
    EngineCallContext& context,
    const BunBindgenEngine_js_functions_jsValueBind_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.function.isCallable() || !args.function.isObject()) {
        JSC::throwTypeError(&globalObject, scope, "bind() called on non-callable"_s);
        RELEASE_AND_RETURN(scope, {});
    }
    auto* function = args.function.getObject();

    JSC::MarkedArgumentBuffer arguments;
    arguments.ensureCapacity(args.arguments.size());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        RELEASE_AND_RETURN(scope, {});
    }
    for (auto value : args.arguments)
        arguments.append(value);

    auto bindSourceCode = JSC::makeSource("bind"_s, JSC::SourceOrigin(), JSC::SourceTaintedOrigin::Untainted);
    auto* boundFunction = JSC::JSBoundFunction::create(
        vm,
        &globalObject,
        function,
        args.bindThis,
        JSC::ArgList(arguments),
        args.length,
        JSC::jsString(vm, args.name),
        bindSourceCode);
    RELEASE_AND_RETURN(scope, boundFunction);
}

void bunBindgenEngine_promises_queueHandledPromiseNotification(
    EngineCallContext& context,
    const BunBindgenEngine_promises_queueHandledPromiseNotification_Arguments& args)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    Bun::StrongRef promise(Bun::createStrongRef(global, args.promise));
    RETURN_IF_EXCEPTION(scope, );
    if (auto* scriptContext = global->scriptExecutionContext()) {
        scriptContext->postTask([promise = WTF::move(promise)](WebCore::ScriptExecutionContext&) {
            Bun::Bindgen::ZigExports::bunBindgenZig_promises_deliverHandledPromiseNotification(promise->globalObject(), promise->value());
        });
    }
}

std::optional<JSC::JSValue> bunBindgenEngine_promises_promiseResult(
    EngineCallContext&,
    const BunBindgenEngine_promises_promiseResult_Arguments& args)
{
    auto* promise = bindingPromise(args.promise);
    switch (promise->status()) {
    case JSC::JSPromise::Status::Rejected:
    case JSC::JSPromise::Status::Fulfilled:
        return promise->result();
    case JSC::JSPromise::Status::Pending:
        return std::nullopt;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<JSC::JSValue> bunBindgenEngine_promises_promiseRejectionReason(
    EngineCallContext&,
    const BunBindgenEngine_promises_promiseRejectionReason_Arguments& args)
{
    auto* promise = bindingPromise(args.promise);
    RELEASE_ASSERT(promise->status() == JSC::JSPromise::Status::Rejected);
    promise->markAsHandled();
    auto reason = promise->result();
    if (reason.isUndefinedOrNull())
        return std::nullopt;
    return reason;
}

JSC::JSValue bunBindgenEngine_promises_promiseCreate(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseCreate_Arguments&)
{
    return JSC::JSPromise::create(context.globalObject.vm(), context.globalObject.promiseStructure());
}

JSC::JSValue bunBindgenEngine_promises_promiseCreateResolvedUndefined(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseCreateResolvedUndefined_Arguments&)
{
    auto& vm = context.globalObject.vm();
    auto* promise = JSC::JSPromise::create(vm, context.globalObject.promiseStructure());
    promise->fulfill(vm, JSC::jsUndefined());
    return promise;
}

JSC::JSValue bunBindgenEngine_promises_promiseCreateResolved(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseCreateResolved_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* promise = JSC::JSPromise::create(vm, context.globalObject.promiseStructure());
    promise->resolve(&context.globalObject, vm, args.value);
    RETURN_IF_EXCEPTION(scope, {});
    return promise;
}

JSC::JSValue bunBindgenEngine_promises_promiseCreateResolvedSize(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseCreateResolvedSize_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* promise = JSC::JSPromise::create(vm, context.globalObject.promiseStructure());
    promise->fulfill(vm, JSC::jsNumber(args.value));
    return promise;
}

JSC::JSValue bunBindgenEngine_promises_promiseCreateRejectedWithoutNotifying(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseCreateRejectedWithoutNotifying_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* promise = JSC::JSPromise::create(vm, context.globalObject.promiseStructure());
    promise->rejectAsHandled(vm, args.value);
    return promise;
}

JSC::JSValue bunBindgenEngine_promises_promiseWrapPendingException(
    EngineCallContext& context,
    const BunBindgenEngine_promises_promiseWrapPendingException_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* exception = scope.exception();
    RELEASE_ASSERT(exception);
    (void)scope.tryClearException();
    RELEASE_AND_RETURN(scope, JSC::JSPromise::rejectedPromise(globalObject, exception->value()));
}

std::optional<WTF::String> bunBindgenEngine_js_strings_jsFunctionSourceCode(
    EngineCallContext& context,
    const BunBindgenEngine_js_strings_jsFunctionSourceCode_Arguments& args)
{
    auto* function = dynamicDowncast<JSC::JSFunction>(args.value);
    if (!function)
        return std::nullopt;
    auto* sourceCode = function->sourceCode();
    if (!sourceCode)
        return std::nullopt;
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto copy = [&]<typename Character>(std::span<const Character> source) -> std::optional<WTF::String> {
        std::span<Character> output;
        auto impl = WTF::StringImpl::tryCreateUninitialized(source.size(), output);
        if (!impl) {
            JSC::throwOutOfMemoryError(&context.globalObject, scope);
            return std::nullopt;
        }
        WTF::StringImpl::copyCharacters(output, source);
        return WTF::String { WTF::move(impl) };
    };
    auto source = sourceCode->view();
    return source.is8Bit() ? copy(source.span8()) : copy(source.span16());
}

JSC::VM* bunBindgenEngine_virtual_machine_globalObjectVM(
    const BunBindgenEngine_virtual_machine_globalObjectVM_Arguments& args)
{
    return &args.global->vm();
}

VirtualMachine* bunBindgenEngine_virtual_machine_globalObjectBunVM(
    const BunBindgenEngine_virtual_machine_globalObjectBunVM_Arguments& args)
{
    return reinterpret_cast<VirtualMachine*>(WebCore::clientData(args.global->vm())->bunVM);
}

void bunBindgenEngine_virtual_machine_vmSetControlFlowProfiler(
    const BunBindgenEngine_virtual_machine_vmSetControlFlowProfiler_Arguments& args)
{
    if (args.enabled)
        args.vm->enableControlFlowProfiler();
    else
        args.vm->disableControlFlowProfiler();
}

bool bunBindgenEngine_virtual_machine_vmHasExecutionTimeLimit(
    const BunBindgenEngine_virtual_machine_vmHasExecutionTimeLimit_Arguments& args)
{
    JSC::JSLockHolder lock(args.vm);
    return args.vm->watchdog() && args.vm->watchdog()->hasTimeLimit();
}

void bunBindgenEngine_virtual_machine_vmGetAPILock(
    const BunBindgenEngine_virtual_machine_vmGetAPILock_Arguments& args)
{
    args.vm->apiLock().lock();
}

void bunBindgenEngine_virtual_machine_vmReleaseAPILock(
    const BunBindgenEngine_virtual_machine_vmReleaseAPILock_Arguments& args)
{
    WTF::RefPtr<JSC::JSLock> apiLock(&args.vm->apiLock());
    apiLock->unlock();
}

void bunBindgenEngine_BunDebugger_debuggerRunWithAPILock(
    const BunBindgenEngine_BunDebugger_debuggerRunWithAPILock_Arguments& args)
{
    JSC::JSLockHolder lock(args.vm);
    ZigExports::bunBindgenZig_BunDebugger_debuggerStart(args.owner);
}

void bunBindgenEngine_virtual_machine_vmReportExtraMemory(
    const BunBindgenEngine_virtual_machine_vmReportExtraMemory_Arguments& args)
{
    args.vm->heap.deprecatedReportExtraMemory(args.size);
}

void bunBindgenEngine_virtual_machine_vmShrinkFootprint(
    const BunBindgenEngine_virtual_machine_vmShrinkFootprint_Arguments& args)
{
    args.vm->shrinkFootprintWhenIdle();
}

uint64_t bunBindgenEngine_virtual_machine_vmRunGC(
    const BunBindgenEngine_virtual_machine_vmRunGC_Arguments& args)
{
    JSC::JSLockHolder lock(args.vm);

#if BUN_BINDGEN_MALLOC_DEBUGGING_ENABLED
    if (!malloc_zone_check(nullptr))
        BUN_PANIC("Heap corruption detected!!");
#endif

    args.vm->finalizeSynchronousJSExecution();
    if (args.sync) {
        args.vm->clearSourceProviderCaches();
        args.vm->heap.deleteAllUnlinkedCodeBlocks(JSC::PreventCollectionAndDeleteAllCode);
        args.vm->heap.collectNow(JSC::Sync, JSC::CollectionScope::Full);
#if BUN_BINDGEN_MALLOC_DEBUGGING_ENABLED
        malloc_zone_pressure_relief(nullptr, 0);
#endif
    } else {
        args.vm->heap.deleteAllUnlinkedCodeBlocks(JSC::DeleteAllCodeIfNotCollecting);
        args.vm->heap.collectSync(JSC::CollectionScope::Full);
    }
    args.vm->finalizeSynchronousJSExecution();

#if BUN_BINDGEN_MALLOC_DEBUGGING_ENABLED
    if (!malloc_zone_check(nullptr))
        BUN_PANIC("Heap corruption detected after GC!!");
#endif

    return args.vm->heap.sizeAfterLastFullCollection();
}

uint64_t bunBindgenEngine_virtual_machine_vmHeapSize(
    const BunBindgenEngine_virtual_machine_vmHeapSize_Arguments& args)
{
    return args.vm->heap.size();
}

void bunBindgenEngine_virtual_machine_vmCollectAsync(
    const BunBindgenEngine_virtual_machine_vmCollectAsync_Arguments& args)
{
    JSC::JSLockHolder lock(*args.vm);
    args.vm->heap.collectAsync();
}

bool bunBindgenEngine_virtual_machine_vmExecutionForbidden(
    const BunBindgenEngine_virtual_machine_vmExecutionForbidden_Arguments& args)
{
    return args.vm->executionForbidden();
}

void bunBindgenEngine_virtual_machine_vmNotifyNeedTermination(
    const BunBindgenEngine_virtual_machine_vmNotifyNeedTermination_Arguments& args)
{
    bool heldLock = args.vm->currentThreadIsHoldingAPILock();
    if (heldLock)
        args.vm->apiLock().unlock();
    args.vm->notifyNeedTermination();
    if (heldLock)
        args.vm->apiLock().lock();
}

void bunBindgenEngine_virtual_machine_vmClearHasTerminationRequest(
    const BunBindgenEngine_virtual_machine_vmClearHasTerminationRequest_Arguments& args)
{
    args.vm->clearHasTerminationRequest();
}

JSC::JSValue bunBindgenEngine_global_objects_globalObjectValue(
    EngineCallContext& context,
    const BunBindgenEngine_global_objects_globalObjectValue_Arguments&)
{
    return JSC::JSValue(&context.globalObject);
}

void bunBindgenEngine_global_objects_globalObjectThrowValue(
    EngineCallContext& context,
    const BunBindgenEngine_global_objects_globalObjectThrowValue_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    scope.assertNoException();

    auto* exception = args.value.inherits<JSC::Exception>()
        ? uncheckedDowncast<JSC::Exception>(args.value.asCell())
        : JSC::Exception::create(vm, args.value, JSC::Exception::StackCaptureAction::CaptureStack);
    scope.throwException(&context.globalObject, exception);
}

void bunBindgenEngine_virtual_machine_vmReleaseWeakRefs(
    const BunBindgenEngine_virtual_machine_vmReleaseWeakRefs_Arguments& args)
{
    args.vm->finalizeSynchronousJSExecution();
}

void bunBindgenEngine_microtasks_vmDrainMicrotasks(
    const BunBindgenEngine_microtasks_vmDrainMicrotasks_Arguments& args)
{
    args.vm->drainMicrotasks();
}

uint64_t bunBindgenEngine_virtual_machine_vmBlockBytesAllocated(
    const BunBindgenEngine_virtual_machine_vmBlockBytesAllocated_Arguments& args)
{
#if ENABLE(RESOURCE_USAGE)
    return args.vm->heap.blockBytesAllocated() + args.vm->heap.extraMemorySize();
#else
    return 0;
#endif
}

JSC::JSValue bunBindgenEngine_js_functions_jsValueCall(
    EngineCallContext& context,
    const BunBindgenEngine_js_functions_jsValueCall_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT_WITH_MESSAGE(!vm.isCollectorBusyOnCurrentThread(), "Cannot call function inside a finalizer or while GC is running on same thread.");

    auto* wrapper = dynamicDowncast<AsyncContextFrame>(args.function);
    JSC::JSValue function = wrapper ? wrapper->callback.get() : args.function;
    RELEASE_ASSERT(function.isCallable());
    JSC::JSValue thisValue = args.this_value.value_or(globalObject.globalThis());

    JSC::MarkedArgumentBuffer arguments;
    for (auto argument : args.arguments)
        argument.appendTo(arguments);
    if (arguments.hasOverflowed()) {
        throwOutOfMemoryError(&globalObject, scope);
        return {};
    }

    JSC::JSValue restoreAsyncContext;
    JSC::InternalFieldTuple* asyncContextData = nullptr;
    if (wrapper) {
        asyncContextData = globalObject.m_asyncContextData.get();
        restoreAsyncContext = asyncContextData->getInternalField(0);
        asyncContextData->putInternalField(vm, 0, wrapper->context.get());
    }

#if ASSERT_ENABLED
    JSC::Integrity::auditCellFully(vm, function.asCell());
#endif

    auto callData = JSC::getCallData(function);
    RELEASE_ASSERT_WITH_MESSAGE(function.isCallable() && callData.type != JSC::CallData::Type::None, "Function passed to JSValue.call must be callable.");
    auto result = JSC::profiledCall(&globalObject, JSC::ProfilingReason::API, function, callData, thisValue, arguments);

    if (asyncContextData)
        asyncContextData->putInternalField(vm, 0, restoreAsyncContext);

    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

BunBindgenEngine_errors_jsValueToError_Return bunBindgenEngine_errors_jsValueToError(
    EngineCallContext&,
    const BunBindgenEngine_errors_jsValueToError_Arguments& args)
{
    return Bun::extractErrorValue(args.value);
}

struct ArrayBufferViewData {
    std::span<const uint8_t> bytes;
    bool shared;
};

static std::optional<ArrayBufferViewData> arrayBufferViewData(JSC::JSValue value)
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value))
        return ArrayBufferViewData { view->span(), view->isShared() };
    if (auto* jsBuffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        if (auto* buffer = jsBuffer->impl())
            return ArrayBufferViewData { buffer->span(), buffer->isShared() };
    }
    return std::nullopt;
}

BunBindgenEngine_array_buffers_jsValueCopyArrayBufferView_Return bunBindgenEngine_array_buffers_jsValueCopyArrayBufferView(
    EngineCallContext& context,
    const BunBindgenEngine_array_buffers_jsValueCopyArrayBufferView_Arguments& args)
{
    auto view = arrayBufferViewData(args.value);
    if (!view)
        return std::nullopt;

    WTF::Vector<uint8_t> bytes;
    if (!view->bytes.empty()) {
        RELEASE_ASSERT(view->bytes.data());
        if (!bytes.tryAppend(view->bytes)) {
            auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
            JSC::throwOutOfMemoryError(&context.globalObject, scope);
            return std::nullopt;
        }
    }

    return bytes;
}

bool bunBindgenEngine_array_buffers_jsValueArrayBufferIsShared(
    EngineCallContext&,
    const BunBindgenEngine_array_buffers_jsValueArrayBufferIsShared_Arguments& args)
{
    auto view = arrayBufferViewData(args.value);
    return view && view->shared;
}

bool bunBindgenEngine_errors_globalObjectHasException(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectHasException_Arguments&)
{
    return DECLARE_TOP_EXCEPTION_SCOPE(context.globalObject.vm()).exception();
}

bool bunBindgenEngine_errors_globalObjectHasExceptionIncludingTraps(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectHasExceptionIncludingTraps_Arguments&)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(context.globalObject.vm());
    RETURN_IF_EXCEPTION(scope, true);
    return false;
}

BunBindgenEngine_errors_globalObjectPendingExceptionKind_Return bunBindgenEngine_errors_globalObjectPendingExceptionKind(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectPendingExceptionKind_Arguments&)
{
    using Return = BunBindgenEngine_errors_globalObjectPendingExceptionKind_Return;
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    auto* exception = scope.exception();
    if (!exception)
        return Return::none;
    return vm.isTerminationException(exception) ? Return::termination : Return::other;
}

void bunBindgenEngine_errors_globalObjectClearException(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectClearException_Arguments&)
{
    (void)DECLARE_TOP_EXCEPTION_SCOPE(context.globalObject.vm()).tryClearException();
}

bool bunBindgenEngine_errors_globalObjectClearExceptionExceptTermination(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectClearExceptionExceptTermination_Arguments&)
{
    return DECLARE_TOP_EXCEPTION_SCOPE(context.globalObject.vm()).clearExceptionExceptTermination();
}

void bunBindgenEngine_errors_globalObjectClearTerminationException(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectClearTerminationException_Arguments&)
{
    auto& vm = context.globalObject.vm();
    vm.clearHasTerminationRequest();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    if (scope.exception() && vm.isTerminationException(scope.exception()))
        scope.clearException();
}

BunBindgenEngine_errors_globalObjectTryTakeException_Return bunBindgenEngine_errors_globalObjectTryTakeException(
    EngineCallContext& context,
    const BunBindgenEngine_errors_globalObjectTryTakeException_Arguments&)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(context.globalObject.vm());
    auto* exception = scope.exception();
    if (!exception)
        return std::nullopt;
    (void)scope.tryClearException();
    return exception;
}

JSC::JSValue bunBindgenEngine_heap_profiling_generateHeapSnapshot(
    EngineCallContext& context,
    const BunBindgenEngine_heap_profiling_generateHeapSnapshot_Arguments&)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();

    JSC::JSLockHolder lock(vm);
    auto scope = DECLARE_THROW_SCOPE(vm);

    Bun::Bindgen::ZigExports::bunBindgenZig_Analytics_recordHeapSnapshot();

    JSC::HeapSnapshotBuilder snapshotBuilder(vm.ensureHeapProfiler());
    snapshotBuilder.buildSnapshot();

    WTF::String jsonString = snapshotBuilder.json();
    auto result = JSONParse(&globalObject, jsonString);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(result.isObject());
    return result;
}

JSC::JSValue bunBindgenEngine_Expect_expectMatcherUtilsObject(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_Expect_expectMatcherUtilsObject_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    if (auto* cached = globalObject->m_testMatcherUtilsObject.get())
        return cached;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectMatcherUtilsCreate(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto* object = result.getObject();
    RELEASE_ASSERT(object);
    globalObject->m_testMatcherUtilsObject.set(vm, globalObject, object);
    return object;
}

BunBindgenEngine_call_frames_callFrameGetCallerSourceLocation_Return bunBindgenEngine_call_frames_callFrameGetCallerSourceLocation(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_call_frames_callFrameGetCallerSourceLocation_Arguments& args)
{
    auto* callFrame = args.callFrame;
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    JSC::LineColumn lineColumn;
    String sourceURL;

    Bun::RemappableStackFrame remappedFrame;

    JSC::StackVisitor::visit(callFrame, vm, [&](JSC::StackVisitor& visitor) -> WTF::IterationStatus {
        if (Zig::isImplementationVisibilityPrivate(visitor))
            return WTF::IterationStatus::Continue;

        if (visitor->hasLineAndColumnInfo()) {

            lineColumn = visitor->computeLineAndColumn();

            sourceURL = Zig::sourceURL(visitor);

            return WTF::IterationStatus::Done;
        }

        return WTF::IterationStatus::Continue;
    });

    if (!sourceURL.isEmpty() and lineColumn.line > 0) {
        OrdinalNumber originalLine = OrdinalNumber::fromOneBasedInt(lineColumn.line);
        OrdinalNumber originalColumn = OrdinalNumber::fromOneBasedInt(lineColumn.column);

        remappedFrame.position.lineZeroBased = originalLine.zeroBasedInt();
        remappedFrame.position.columnZeroBased = originalColumn.zeroBasedInt();
        remappedFrame.sourceURL = sourceURL;

        Bun::remapStackFramePosition(Bun::vm(globalObject), remappedFrame);

        sourceURL = remappedFrame.sourceURL;
        lineColumn.line = OrdinalNumber::fromZeroBasedInt(remappedFrame.position.lineZeroBased).oneBasedInt();
        lineColumn.column = OrdinalNumber::fromZeroBasedInt(remappedFrame.position.columnZeroBased).oneBasedInt();
    }

    return {
        .sourceURL = WTF::move(sourceURL),
        .line = lineColumn.line,
        .column = lineColumn.column,
    };
}

uint32_t bunBindgenEngine_call_frames_callFrameGetLineNumber(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_call_frames_callFrameGetLineNumber_Arguments& args)
{
    auto* callFrame = args.callFrame;
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    JSC::LineColumn lineColumn;
    String sourceURL;

    JSC::StackVisitor::visit(callFrame, vm, [&](JSC::StackVisitor& visitor) -> WTF::IterationStatus {
        if (Zig::isImplementationVisibilityPrivate(visitor))
            return WTF::IterationStatus::Continue;

        if (visitor->hasLineAndColumnInfo()) {
            String currentSourceURL = Zig::sourceURL(visitor);

            if (!currentSourceURL.startsWith("builtin://"_s) && !currentSourceURL.startsWith("node:"_s)) {
                lineColumn = visitor->computeLineAndColumn();
                sourceURL = currentSourceURL;
                return WTF::IterationStatus::Done;
            }
        }
        return WTF::IterationStatus::Continue;
    });

    if (!sourceURL.isEmpty() && lineColumn.line > 0) {
        Bun::RemappableStackFrame remappedFrame;
        remappedFrame.position.lineZeroBased = lineColumn.line - 1;
        remappedFrame.position.columnZeroBased = lineColumn.column;
        remappedFrame.sourceURL = sourceURL;

        Bun::remapStackFramePosition(Bun::vm(globalObject), remappedFrame);

        return remappedFrame.position.lineZeroBased + 1;
    }

    return lineColumn.line;
}

BunBindgenEngine_Repl_evaluate_Return bunBindgenEngine_Repl_evaluate(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_Repl_evaluate_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    JSC::SourceCode sourceCode = JSC::makeSource(
        args.source,
        JSC::SourceOrigin {},
        JSC::SourceTaintedOrigin::Untainted,
        args.filename,
        WTF::TextPosition(),
        JSC::SourceProviderSourceType::Program);

    WTF::NakedPtr<JSC::Exception> evalException;
    JSC::JSValue result = JSC::evaluate(globalObject, sourceCode, globalObject->globalThis(), evalException);

    auto* exception = evalException ? evalException.get() : scope.exception();
    if (exception) {
        if (vm.isTerminationException(exception)) {
            auto throwScope = DECLARE_THROW_SCOPE(vm);
            throwScope.throwException(globalObject, exception);
            return { .result = JSC::jsUndefined(), .exception = std::nullopt };
        }
        auto value = exception->value();
        scope.clearException();
        return {
            .result = JSC::jsUndefined(),
            .exception = std::optional<JSC::JSValue> { value },
        };
    }

    return {
        .result = result,
        .exception = std::nullopt,
    };
}

WTF::Vector<WTF::String> bunBindgenEngine_Repl_getCompletions(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_Repl_getCompletions_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSObject* object = globalObject->globalThis();
    JSC::PropertyNameArrayBuilder propertyNames(vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
    object->getPropertyNames(globalObject, propertyNames, DontEnumPropertiesMode::Include);
    RETURN_IF_EXCEPTION(scope, {});

    WTF::Vector<WTF::String> completions;
    for (const auto& propertyName : propertyNames) {
        WTF::String name = propertyName.string();
        if (args.prefix.isEmpty() || name.startsWith(args.prefix)) {
            if (!completions.tryAppend(name)) {
                JSC::throwOutOfMemoryError(globalObject, scope);
                return {};
            }
        }
    }

    scope.release();
    return completions;
}

static void setReplGlobalProperty(
    Bun::Bindgen::EngineCallContext& context,
    JSC::JSValue value,
    WTF::ASCIILiteral propertyName)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    globalObject.putDirect(vm, JSC::Identifier::fromString(vm, propertyName), value);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

void bunBindgenEngine_Repl_setLastResult(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_Repl_setLastResult_Arguments& args)
{
    setReplGlobalProperty(context, args.value, "_"_s);
}

void bunBindgenEngine_Repl_setLastError(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_Repl_setLastError_Arguments& args)
{
    setReplGlobalProperty(context, args.value, "_error"_s);
}

}
