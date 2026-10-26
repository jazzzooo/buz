#include "config.h"
#include "Bindgen/Optional.h"
#include "SchemaBindings.h"

#include "JSWritableStream.h"
#include "WebCoreJSBuiltins.h"
#include "WritableStream.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>

namespace Bun::Bindgen::Cpp {

ReadableStreamIteratorStateResult bunBindgenCpp_WebCoreStreams_createReadableStreamIterator(
    CppCallContext&,
    const BunBindgenCpp_WebCoreStreams_createReadableStreamIterator_Arguments& args)
{
    return { true, std::nullopt, args.preventCancel, std::nullopt, false };
}

static JSC::JSObject* readableStreamObject(JSC::JSValue value)
{
    auto* stream = dynamicDowncast<JSC::JSObject>(value);
    RELEASE_ASSERT(stream);
    return stream;
}

enum class ReadableStreamSourceKind : uint8_t {
    Default,
    Bytes,
    Direct,
    Lazy,
    InternalDefault,
};

static JSC::JSValue callReadableStreamBuiltin(
    JSC::JSGlobalObject& globalObject,
    JSC::JSObject& receiver,
    JSC::FunctionExecutable* (*codeGenerator)(JSC::VM&),
    JSC::MarkedArgumentBuffer& arguments,
    WTF::ASCIILiteral failureMessage)
{
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return {};
    }

    auto* executable = codeGenerator(vm);
    RETURN_IF_EXCEPTION(scope, {});
    auto* function = JSC::JSFunction::create(vm, &globalObject, executable, &globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto result = JSC::call(&globalObject, function, &receiver, arguments, failureMessage);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSObject* bunBindgenCpp_WebCoreStreams_ReadableStream_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_construct_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto* source = nestedOptionalValue(args.underlyingSource);
    const auto* strategy = nestedOptionalValue(args.strategy);
    ReadableStreamSourceKind kind = ReadableStreamSourceKind::Default;
    std::optional<double> autoAllocateChunkSize;
    std::optional<JSC::JSValue> start;
    std::optional<JSC::JSValue> pull;
    std::optional<JSC::JSValue> cancel;

    if (source) {
        const bool direct = source->type && *source->type == ReadableStreamSourceType::direct;
        const bool bytes = source->type && *source->type == ReadableStreamSourceType::bytes;
        if (direct) {
            kind = ReadableStreamSourceKind::Direct;
        } else if (source->deferred_native_source.value_or(false)) {
            kind = ReadableStreamSourceKind::Lazy;
            const auto* converted = source->autoAllocateChunkSize.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(converted);
            autoAllocateChunkSize = *converted;
        } else if (source->internal_pull_present.has_value()) {
            kind = ReadableStreamSourceKind::InternalDefault;
            const auto* convertedStart = source->internal_start.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(convertedStart);
            start = *convertedStart;
            const auto* convertedPull = source->internal_pull.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(convertedPull);
            pull = *convertedPull;
            const auto* convertedCancel = source->internal_cancel.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(convertedCancel);
            cancel = *convertedCancel;
        } else if (bytes) {
            kind = ReadableStreamSourceKind::Bytes;
        } else {
            const auto* convertedStart = source->start.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(convertedStart);
            start = *convertedStart;
            const auto* convertedPull = source->pull.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(convertedPull);
            pull = *convertedPull;
            const auto* convertedCancel = source->cancel.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            RELEASE_ASSERT(convertedCancel);
            cancel = *convertedCancel;
        }
    }

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsNumber(static_cast<uint8_t>(kind)));
    JSC::Strong<JSC::JSObject> defaultSource;
    if (source) {
        source->source_identity.appendTo(arguments);
    } else {
        auto* sourceObject = JSC::constructEmptyObject(&globalObject);
        RETURN_IF_EXCEPTION(scope, nullptr);
        defaultSource.set(vm, sourceObject);
        arguments.append(sourceObject);
    }
    JSC::JSValue nativeSource = JSC::jsUndefined();
    if (source && source->native_source) {
        const auto& native = *source->native_source;
        if (native.is_blob())
            nativeSource = native.blob();
        else if (native.is_bytes())
            nativeSource = native.bytes();
        else {
            RELEASE_ASSERT(native.is_file());
            nativeSource = native.file();
        }
    }
    arguments.append(nativeSource);
    arguments.append(autoAllocateChunkSize
            ? JSC::jsNumber(*autoAllocateChunkSize)
            : JSC::jsUndefined());
    arguments.append(start.value_or(JSC::jsUndefined()));
    arguments.append(pull.value_or(JSC::jsUndefined()));
    arguments.append(cancel.value_or(JSC::jsUndefined()));
    arguments.append(strategy && strategy->highWaterMark
            ? JSC::jsNumber(*strategy->highWaterMark)
            : JSC::jsUndefined());
    arguments.append(strategy && strategy->size ? *strategy->size : JSC::jsUndefined());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* executable = WebCore::readableStreamInitializeReadableStreamCodeGenerator(vm);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(
        vm,
        &globalObject,
        executable,
        &globalObject);
    RETURN_IF_EXCEPTION(scope, nullptr);
    JSC::call(
        &globalObject,
        initialize,
        object,
        arguments,
        "ReadableStream initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_text(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_text_Arguments& args)
{
    return Bun::readableStreamToText(defaultGlobalObject(&context.globalObject), readableStreamObject(args.bindingThis));
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_bytes(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_bytes_Arguments& args)
{
    return Bun::readableStreamToBytes(defaultGlobalObject(&context.globalObject), readableStreamObject(args.bindingThis));
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_json(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_json_Arguments& args)
{
    return Bun::readableStreamToJSON(defaultGlobalObject(&context.globalObject), readableStreamObject(args.bindingThis));
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_blob(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_blob_Arguments& args)
{
    return Bun::readableStreamToBlob(defaultGlobalObject(&context.globalObject), readableStreamObject(args.bindingThis));
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_cancel(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_cancel_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto* receiver = readableStreamObject(args.bindingThis);

    JSC::MarkedArgumentBuffer arguments;
    if (args.reason)
        args.reason->appendTo(arguments);
    else
        arguments.append(JSC::jsUndefined());
    return callReadableStreamBuiltin(
        globalObject,
        *receiver,
        WebCore::readableStreamCancelCodeGenerator,
        arguments,
        "ReadableStream.cancel failed"_s);
}

ReadableStreamReaderResult bunBindgenCpp_WebCoreStreams_ReadableStream_method_getReader(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_getReader_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const auto* options = nestedOptionalValue(args.options);
    const bool byob = options && options->mode.has_value();
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsBoolean(byob));
    auto value = callReadableStreamBuiltin(
        context.globalObject,
        *readableStreamObject(args.bindingThis),
        WebCore::readableStreamGetReaderCodeGenerator,
        arguments,
        "ReadableStream.getReader failed"_s);
    RETURN_IF_EXCEPTION(scope, {});
    ReadableStreamReaderResult result;
    if (byob)
        result.set_byob(value);
    else
        result.set_default_reader(value);
    return result;
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_pipeThrough(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_pipeThrough_Arguments& args)
{
    const ReadableStreamPipeOptionsInput defaultOptions {};
    const auto* providedOptions = nestedOptionalValue(args.options);
    const auto& options = providedOptions ? *providedOptions : defaultOptions;
    auto* writableWrapper = WTF::dynamicDowncast<WebCore::JSWritableStream>(args.transform.writable);
    RELEASE_ASSERT(writableWrapper);
    JSC::JSValue internalWritable = writableWrapper->wrapped().internalWritableStream();
    RELEASE_ASSERT(internalWritable.isObject());
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.transform.readable);
    arguments.append(internalWritable);
    arguments.append(JSC::jsBoolean(options.preventClose));
    arguments.append(JSC::jsBoolean(options.preventAbort));
    arguments.append(JSC::jsBoolean(options.preventCancel));
    arguments.append(options.signal.value_or(JSC::jsUndefined()));
    return callReadableStreamBuiltin(
        context.globalObject,
        *readableStreamObject(args.bindingThis),
        WebCore::readableStreamPipeThroughCodeGenerator,
        arguments,
        "ReadableStream.pipeThrough failed"_s);
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_pipeTo(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_pipeTo_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto* receiver = readableStreamObject(args.bindingThis);
    const ReadableStreamPipeOptionsInput defaultOptions {};
    const auto* providedOptions = nestedOptionalValue(args.options);
    const auto& options = providedOptions ? *providedOptions : defaultOptions;
    auto* writableWrapper = WTF::dynamicDowncast<WebCore::JSWritableStream>(args.destination);
    RELEASE_ASSERT(writableWrapper);
    JSC::JSValue internalWritable = writableWrapper->wrapped().internalWritableStream();
    RELEASE_ASSERT(internalWritable.isObject());

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(internalWritable);
    arguments.append(JSC::jsBoolean(options.preventClose));
    arguments.append(JSC::jsBoolean(options.preventAbort));
    arguments.append(JSC::jsBoolean(options.preventCancel));
    arguments.append(options.signal.value_or(JSC::jsUndefined()));
    return callReadableStreamBuiltin(
        globalObject,
        *receiver,
        WebCore::readableStreamPipeToCodeGenerator,
        arguments,
        "ReadableStream.pipeTo failed"_s);
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStream_method_values(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStream_method_values_Arguments& args)
{
    const auto* options = nestedOptionalValue(args.options);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsBoolean(options && options->preventCancel));
    return callReadableStreamBuiltin(
        context.globalObject,
        *readableStreamObject(args.bindingThis),
        WebCore::readableStreamValuesCodeGenerator,
        arguments,
        "ReadableStream iterator creation failed"_s);
}

} // namespace Bun::Bindgen::Cpp
