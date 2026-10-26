#include "root.h"

#include "ErrorBindings.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSCInlines.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSArrayBufferView.h"
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/WTFString.h>

#if ASAN_ENABLED
#include <sanitizer/lsan_interface.h>
#endif

namespace Bun::Bindgen::Custom {

WTF::String bunBindgenTestPrefixLabel(JSC::JSGlobalObject&, WTF::String const& value, WTF::ASCIILiteral)
{
    return WTF::makeString("custom:"_s, value);
}

std::optional<WTF::String> bunBindgenTestNullableLabel(
    JSC::JSGlobalObject&,
    const std::optional<WTF::String>& value,
    WTF::ASCIILiteral)
{
    if (!value)
        return std::nullopt;
    return WTF::makeString("nullable:"_s, *value);
}

}

namespace Bun::Bindgen::Cpp {

void bunBindgenCpp_bindgen_test_settlePromiseWithPendingException(
    CppCallContext& context,
    const BunBindgenCpp_bindgen_test_settlePromiseWithPendingException_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    scope.throwException(&context.globalObject, args.failure);
    RELEASE_ASSERT(scope.exception());
    scope.release();
    EngineCallContext engineContext { context.globalObject, nullptr };
    using Settlement = decltype(args.settlement);
    switch (args.settlement) {
    case Settlement::resolve:
        Engine::bunBindgenEngine_promises_promiseResolve(engineContext, { .promise = args.promise, .value = JSC::jsUndefined() });
        return;
    case Settlement::reject:
        Engine::bunBindgenEngine_promises_promiseReject(engineContext, { .promise = args.promise, .value = JSC::jsUndefined() });
        return;
    case Settlement::rejectHandled:
        Engine::bunBindgenEngine_promises_promiseRejectAsHandled(engineContext, { .promise = args.promise, .value = JSC::jsUndefined() });
        return;
    }
}

void bunBindgenCpp_bindgen_test_throwOutOfMemoryWithPendingException(
    CppCallContext& context,
    const BunBindgenCpp_bindgen_test_throwOutOfMemoryWithPendingException_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (args.failure) {
        scope.throwException(&context.globalObject, *args.failure);
        RELEASE_ASSERT(scope.exception());
    }
    scope.release();
    EngineCallContext engineContext { context.globalObject, nullptr };
    Engine::bunBindgenEngine_errors_throwOutOfMemory(engineContext, {});
}

int32_t bunBindgenCpp_bindgen_test_cppAdd(CppCallContext&, const BunBindgenCpp_bindgen_test_cppAdd_Arguments& args)
{
    return args.a + args.b;
}

int32_t bunBindgenCpp_bindgen_test_cppOverload_overload_integer(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppOverload_overload_integer_Arguments& args)
{
    return args.value;
}

int32_t bunBindgenCpp_bindgen_test_cppOverload_overload_string(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppOverload_overload_string_Arguments& args)
{
    return args.value.length();
}

WTF::String bunBindgenCpp_bindgen_test_cppEchoString(CppCallContext&, const BunBindgenCpp_bindgen_test_cppEchoString_Arguments& args)
{
    return args.input;
}

bool bunBindgenCpp_bindgen_test_cppExternalRefPresent(CppCallContext&, const BunBindgenCpp_bindgen_test_cppExternalRefPresent_Arguments& args)
{
    return !!args.input;
}

uint64_t bunBindgenCpp_bindgen_test_cppExternalRefSequenceLength(CppCallContext&, const BunBindgenCpp_bindgen_test_cppExternalRefSequenceLength_Arguments& args)
{
    return args.input.size();
}

uint64_t bunBindgenCpp_bindgen_test_cppDictionarySourceSequenceLength(CppCallContext&, const BunBindgenCpp_bindgen_test_cppDictionarySourceSequenceLength_Arguments& args)
{
    for (const auto& entry : args.input)
        RELEASE_ASSERT(entry.source.object());
    return args.input.size();
}

bool bunBindgenCpp_bindgen_test_cppOptionalUnionPresent(CppCallContext&, const BunBindgenCpp_bindgen_test_cppOptionalUnionPresent_Arguments& args)
{
    return args.input.is_string() && args.input.string().has_value();
}

uint64_t bunBindgenCpp_bindgen_test_cppLazyStringLength(CppCallContext& context, const BunBindgenCpp_bindgen_test_cppLazyStringLength_Arguments& args)
{
    if (!args.convert)
        return 0;
    const auto* input = args.input.convert();
    if (!input)
        return 0;
    RELEASE_ASSERT(args.input.convert() == input);
    return Bun::Bindgen::ZigExports::bunBindgenZig_bindgen_test_nativeLazyStringLength(&context.globalObject, JSC::jsString(context.globalObject.vm(), *input));
}

uint64_t bunBindgenCpp_bindgen_test_retryCppLazyString(CppCallContext& context, const BunBindgenCpp_bindgen_test_retryCppLazyString_Arguments& args)
{
    const auto* first = args.input.convert();
    if (!first) {
        if (!DECLARE_TOP_EXCEPTION_SCOPE(context.globalObject.vm()).clearExceptionExceptTermination())
            return 0;
        const auto* retried = args.input.convert();
        return retried ? retried->length() : 0;
    }
    const auto* second = args.input.convert();
    return second ? first->length() + second->length() : 0;
}

uint64_t bunBindgenCpp_bindgen_test_cppBufferLength(CppCallContext&, const BunBindgenCpp_bindgen_test_cppBufferLength_Arguments& args)
{
    return args.input.size();
}

int32_t bunBindgenCpp_bindgen_test_cppClassifyNullablePresence(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppClassifyNullablePresence_Arguments& args)
{
    if (!args.input.has_value())
        return 0;
    if (!args.input->has_value())
        return 1;
    return args.input->value() + 2;
}

int32_t bunBindgenCpp_bindgen_test_cppClassifyNullableFieldPresence(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppClassifyNullableFieldPresence_Arguments& args)
{
    if (!args.options.input.has_value())
        return 0;
    if (!args.options.input->has_value())
        return 1;
    return args.options.input->value() + 2;
}

uint64_t bunBindgenCpp_bindgen_test_cppInspectStringRest(CppCallContext&, const BunBindgenCpp_bindgen_test_cppInspectStringRest_Arguments& args)
{
    uint64_t length = 0;
    for (const auto& value : args.values)
        length += value.length();
    return length;
}

uint64_t bunBindgenCpp_bindgen_test_cppInspectRest(CppCallContext&, const BunBindgenCpp_bindgen_test_cppInspectRest_Arguments& args)
{
    return args.values;
}

Bun::Bindgen::CppBytes bunBindgenCpp_bindgen_test_cppEchoBuffer(CppCallContext&, const BunBindgenCpp_bindgen_test_cppEchoBuffer_Arguments& args)
{
    WTF::Vector<uint8_t> result;
    result.append(args.input);
    return result;
}

int64_t bunBindgenCpp_bindgen_test_cppSumIntegerWidths(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppSumIntegerWidths_Arguments& args)
{
    return static_cast<int64_t>(args.signed8)
        + static_cast<int64_t>(args.signed16)
        + static_cast<int64_t>(args.unsigned16)
        + static_cast<int64_t>(args.unsigned32)
        + args.signed64
        + static_cast<int64_t>(args.unsigned64);
}

int32_t bunBindgenCpp_bindgen_test_cppCallZigExport(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppCallZigExport_Arguments& args)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_bindgen_test_multiplyAdd(args.a, args.b, args.bias);
}

WTF::String bunBindgenCpp_bindgen_test_cppCallZigNativeString(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_cppCallZigNativeString_Arguments& args)
{
    uint8_t marker = 0;
    return Bun::Bindgen::ZigExports::bunBindgenZig_bindgen_test_nativeStringBufferHandle(args.label, args.input, &marker);
}

CppResultSequence<std::pair<WTF::String, BindgenNativeRecordItemResult>> bunBindgenCpp_bindgen_test_cppCallZigNativeRecord(
    CppCallContext& context,
    const BunBindgenCpp_bindgen_test_cppCallZigNativeRecord_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_bindgen_test_nativeCallbackRecord(&context.globalObject, args.factory, args.input);
    RETURN_IF_EXCEPTION(scope, {});
    vm.heap.collectNow(JSC::Sync, JSC::CollectionScope::Full);
    RETURN_IF_EXCEPTION(scope, {});
    scope.release();
    return result;
}

int32_t bunBindgenCpp_bindgen_test_Counter_method_incrementViaCpp(
    CppCallContext& context,
    const BunBindgenCpp_bindgen_test_Counter_method_incrementViaCpp_Arguments& args)
{
    RELEASE_ASSERT(context.nativeReceiver);
    return args.delta * 3;
}

bool bunBindgenCpp_bindgen_test_arrayBufferViewHasBuffer(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_arrayBufferViewHasBuffer_Arguments& args)
{
    if (!args.value.is_view())
        return false;
    auto* view = dynamicDowncast<WebCore::JSArrayBufferView>(args.value.view());
    return view && view->hasArrayBuffer();
}

bool bunBindgenCpp_bindgen_test_hasNonReifiedStatic(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_hasNonReifiedStatic_Arguments& args)
{
    return args.value.is_object() && args.value.object().getObject()->hasNonReifiedStaticProperties();
}

JSC::JSValue bunBindgenCpp_bindgen_test_lsanDoLeakCheck(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_lsanDoLeakCheck_Arguments&)
{
#if ASAN_ENABLED
    return JSC::jsNumber(__lsan_do_recoverable_leak_check());
#endif
    return JSC::jsUndefined();
}

}

namespace Bun::Bindgen::Engine {

void releaseBindgenTestTransfer(WTF::StringImpl* handle)
{
    handle->deref();
}

WTF::StringImpl* bunBindgenEngine_bindgen_test_createTransferHandle(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_createTransferHandle_Arguments&)
{
    return WTF::makeString("bindgen"_s, " transfer"_s).releaseImpl().leakRef();
}

void bunBindgenEngine_bindgen_test_consumeTransferredValue(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_consumeTransferredValue_Arguments& args)
{
    auto handle = adoptRef(*args.input.handle);
    RELEASE_ASSERT(handle->length() == 16);
    RELEASE_ASSERT(args.input.value.isObject());
}

BunBindgenEngine_bindgen_test_isolatedStringResult_Return bunBindgenEngine_bindgen_test_isolatedStringResult(
    const BunBindgenEngine_bindgen_test_isolatedStringResult_Arguments& args)
{
    if (args.fail)
        return nativeAllocationFailure();
    return args.input;
}

uint64_t bunBindgenEngine_bindgen_test_forceLazyIterable(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_forceLazyIterable_Arguments& args)
{
    const auto* input = args.input.convert();
    return input && input->has_value() ? input->value().size() : 0;
}

uint64_t bunBindgenEngine_bindgen_test_forceLazyString(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_forceLazyString_Arguments& args)
{
    const auto* input = args.input.convert();
    return input ? input->length() : 0;
}

uint64_t bunBindgenEngine_bindgen_test_forceCoercedLazyString(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_forceCoercedLazyString_Arguments& args)
{
    const auto* input = args.input.convert();
    return input ? input->length() : 0;
}

JSC::JSValue bunBindgenEngine_bindgen_test_getIndex(
    EngineCallContext& context,
    const BunBindgenEngine_bindgen_test_getIndex_Arguments& args)
{
    return args.target.get(&context.globalObject, static_cast<unsigned>(args.index));
}

int64_t bunBindgenEngine_bindgen_test_sumIntegerWidths(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_sumIntegerWidths_Arguments& args)
{
    return static_cast<int64_t>(args.signed8)
        + static_cast<int64_t>(args.signed16)
        + static_cast<int64_t>(args.unsigned16)
        + static_cast<int64_t>(args.unsigned32)
        + args.signed64
        + static_cast<int64_t>(args.unsigned64);
}

BunBindgenEngine_bindgen_test_bufferSequence_Return bunBindgenEngine_bindgen_test_bufferSequence(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_bufferSequence_Arguments&)
{
    BunBindgenEngine_bindgen_test_bufferSequence_Return result;
    WTF::Vector<uint8_t> first;
    first.append(1);
    first.append(2);
    result.append(WTF::move(first));
    WTF::Vector<uint8_t> second;
    second.append(3);
    second.append(4);
    second.append(5);
    result.append(WTF::move(second));
    return result;
}

uint64_t bunBindgenEngine_bindgen_test_nodePathLength(
    EngineCallContext&,
    const BunBindgenEngine_bindgen_test_nodePathLength_Arguments& args)
{
    return args.input.size();
}

}
