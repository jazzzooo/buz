#include "config.h"
#include "SchemaBindings.h"

#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSGlobalObjectInlines.h>
#include <cstring>


namespace Bun::Bindgen::Cpp {

void bunBindgenCpp_WebCoreStreams_copyByteStreamBytes(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_copyByteStreamBytes_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto* destination = uncheckedDowncast<JSC::JSArrayBuffer>(args.destination)->impl();
    auto* source = uncheckedDowncast<JSC::JSArrayBuffer>(args.source)->impl();
    if (destination->isShared() || source->isShared() || destination->isDetached() || source->isDetached()) {
        JSC::throwTypeError(&globalObject, scope, "Byte stream copies require attached, unshared buffers"_s);
        return;
    }
    if (args.destinationOffset > destination->byteLength() || args.sourceOffset > source->byteLength()
        || args.length > destination->byteLength() - args.destinationOffset
        || args.length > source->byteLength() - args.sourceOffset) {
        JSC::throwRangeError(&globalObject, scope, "Byte stream copy exceeds the buffer bounds"_s);
        return;
    }
    if (args.length)
        std::memmove(static_cast<uint8_t*>(destination->data()) + args.destinationOffset,
            static_cast<const uint8_t*>(source->data()) + args.sourceOffset, args.length);
}

ByteStreamViewInfoResult bunBindgenCpp_WebCoreStreams_byteStreamViewInfo(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_byteStreamViewInfo_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* view = uncheckedDowncast<JSC::JSArrayBufferView>(args.view);
    if (view->isOutOfBounds()) {
        JSC::throwTypeError(&globalObject, scope, "The byte stream view is detached or out of bounds"_s);
        return {};
    }
    auto* buffer = view->possiblySharedJSBuffer(&globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    if (buffer->isShared()) {
        JSC::throwTypeError(&globalObject, scope, "Byte streams require an unshared ArrayBuffer"_s);
        return {};
    }
    auto* constructor = globalObject.typedArrayConstructor(JSC::typedArrayType(view->type()));
    RETURN_IF_EXCEPTION(scope, {});
    return { buffer, buffer->impl()->byteLength(), view->byteOffset(), view->byteLength(),
        static_cast<uint8_t>(JSC::elementSize(view->type())), constructor };
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_transferByteStreamBuffer(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_transferByteStreamBuffer_Arguments& args)
{
    auto* buffer = uncheckedDowncast<JSC::JSArrayBuffer>(args.buffer)->impl();
    return JSC::JSArrayBuffer::transferToFixedLength(&context.globalObject, *buffer);
}

JSC::JSObject* bunBindgenCpp_WebCoreStreams_ReadableByteStreamController_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableByteStreamController_construct_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    args.underlyingByteSource.source_identity.appendTo(arguments);
    arguments.append(JSC::jsNumber(args.highWaterMark));
    arguments.append(args.underlyingByteSource.autoAllocateChunkSize
            ? JSC::jsNumber(*args.underlyingByteSource.autoAllocateChunkSize)
            : JSC::jsUndefined());
    arguments.append(args.underlyingByteSource.start.value_or(JSC::jsUndefined()));
    arguments.append(args.underlyingByteSource.pull.value_or(JSC::jsUndefined()));
    arguments.append(args.underlyingByteSource.cancel.value_or(JSC::jsUndefined()));
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* executable = WebCore::readableByteStreamControllerInitializeReadableByteStreamControllerCodeGenerator(vm);
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
        "ReadableByteStreamController initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

void bunBindgenCpp_WebCoreStreams_ReadableByteStreamController_method_enqueue(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableByteStreamController_method_enqueue_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.buffer);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return;
    }

    auto* executable = WebCore::readableByteStreamControllerEnqueueCodeGenerator(vm);
    RETURN_IF_EXCEPTION(scope, void());
    auto* function = JSC::JSFunction::create(
        vm,
        &globalObject,
        executable,
        &globalObject);
    RETURN_IF_EXCEPTION(scope, void());
    JSC::call(
        &globalObject,
        function,
        args.bindingThis,
        arguments,
        "ReadableByteStreamController.enqueue failed"_s);
    RETURN_IF_EXCEPTION(scope, void());
}

} // namespace Bun::Bindgen::Cpp
