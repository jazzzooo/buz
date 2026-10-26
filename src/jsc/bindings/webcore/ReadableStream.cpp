/*
 * Copyright (C) 2017-2021 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY CANON INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL CANON INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "root.h"

#include "config.h"
#include "ReadableStream.h"
#include "JSDOMExceptionHandling.h"

#include "BunBuiltinNames.h"
#include "SchemaBindings.h"
#include "Exception.h"
#include "ExceptionCode.h"
#include "WebCoreJSClientData.h"
#include "WebCoreJSBuiltins.h"
#include "ZigGlobalObject.h"
#include "helpers.h"
#include "BunClientData.h"
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/ThrowScope.h>
#include <JavaScriptCore/CallData.h>
#include <JavaScriptCore/ArgList.h>

namespace WebCore {
using namespace JSC;

bool isReadableStream(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).readableStreamBrandPrivateName()).isTrue();
}

JSC::JSValue readableStreamNativePtr(JSC::JSObject& stream)
{
    auto& vm = stream.vm();
    auto& names = WebCore::builtinNames(vm);
    auto transferred = stream.getDirect(vm, names.nativeTransferredPrivateName());
    if (transferred.isTrue())
        return stream.getDirect(vm, names.transferredNativePtrPrivateName());
    return stream.getDirect(vm, names.bunNativePtrPrivateName());
}

int32_t readableStreamNativeType(JSC::JSObject& stream)
{
    auto& vm = stream.vm();
    auto value = stream.getDirect(vm, WebCore::builtinNames(vm).bunNativeTypePrivateName());
    return value.isInt32() ? value.asInt32() : 0;
}

bool readableStreamIsTransferred(JSC::JSObject& stream)
{
    auto& vm = stream.vm();
    return stream.getDirect(vm, WebCore::builtinNames(vm).nativeTransferredPrivateName()).isTrue();
}

bool readableStreamIsDisturbed(JSC::JSObject& stream)
{
    auto& vm = stream.vm();
    return stream.getDirect(vm, WebCore::builtinNames(vm).disturbedPrivateName()).isTrue();
}

void setReadableStreamNativePtr(JSC::JSGlobalObject& globalObject, JSC::JSObject& stream, JSC::JSValue value)
{
    stream.putDirect(globalObject.vm(), WebCore::builtinNames(globalObject.vm()).bunNativePtrPrivateName(), value, 0);
}

void setReadableStreamNativeType(JSC::JSGlobalObject& globalObject, JSC::JSObject& stream, int32_t value)
{
    stream.putDirect(globalObject.vm(), WebCore::builtinNames(globalObject.vm()).bunNativeTypePrivateName(), JSC::jsNumber(value), 0);
}

void setReadableStreamTransferred(JSC::JSGlobalObject& globalObject, JSC::JSObject& stream)
{
    auto& vm = globalObject.vm();
    auto& names = WebCore::builtinNames(vm);
    stream.putDirect(vm, names.transferredNativePtrPrivateName(), stream.getDirect(vm, names.bunNativePtrPrivateName()), 0);
    stream.putDirect(vm, names.nativeTransferredPrivateName(), JSC::jsBoolean(true), 0);
    stream.putDirect(vm, names.bunNativePtrPrivateName(), JSC::jsNumber(-1), 0);
}

void setReadableStreamDisturbed(JSC::JSGlobalObject& globalObject, JSC::JSObject& stream, bool value)
{
    stream.putDirect(globalObject.vm(), WebCore::builtinNames(globalObject.vm()).disturbedPrivateName(), JSC::jsBoolean(value), 0);
}

static JSC::JSValue invokeReadableStreamFunction(JSC::JSGlobalObject& lexicalGlobalObject, JSC::JSFunction* function, JSC::MarkedArgumentBuffer& arguments)
{
    JSC::VM& vm = lexicalGlobalObject.vm();
    JSC::JSLockHolder lock(vm);

    auto scope = DECLARE_THROW_SCOPE(vm);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&lexicalGlobalObject, scope);
        return {};
    }
    RELEASE_ASSERT(function);
    auto result = JSC::profiledCall(&lexicalGlobalObject, JSC::ProfilingReason::API, function, JSC::getCallData(function), JSC::jsUndefined(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

bool ReadableStream::isLocked() const
{
    return isLocked(m_globalObject.get(), readableStream());
}

bool ReadableStream::isLocked(JSGlobalObject* globalObject, JSC::JSObject* readableStream)
{
    auto& names = WebCore::builtinNames(globalObject->vm());
    auto reader = readableStream->getDirect(globalObject->vm(), names.readerPrivateName());
    if (reader && !reader.isUndefinedOrNull())
        return true;
    auto nativePtr = readableStream->getDirect(globalObject->vm(), names.bunNativePtrPrivateName());
    return nativePtr.isInt32() && nativePtr.asInt32() == -1;
}

bool ReadableStream::isDisturbed(JSGlobalObject*, JSC::JSObject* readableStream)
{
    return readableStreamIsDisturbed(*readableStream);
}

bool ReadableStream::isDisturbed() const
{
    return readableStreamIsDisturbed(*readableStream());
}

} // namespace WebCore

template<typename Source>
static std::optional<Source> nativeReadableStreamSource(JSC::JSObject& stream)
{
    auto value = WebCore::readableStreamNativePtr(stream);
    if (value.isEmpty() || !value.isCell())
        return std::nullopt;
    std::optional<Source> source;
    if (bun_bindgen_class_ReadableStreamSource_BlobInternalReadableStreamSource_try_cast_value(value))
        source.emplace().set_blob(value);
    else if (bun_bindgen_class_ReadableStreamSource_FileInternalReadableStreamSource_try_cast_value(value))
        source.emplace().set_file(value);
    else if (bun_bindgen_class_ReadableStreamSource_BytesInternalReadableStreamSource_try_cast_value(value))
        source.emplace().set_bytes(value);
    return source;
}

Bun::Bindgen::Cpp::BunBindgenCpp_NativeReadable_transfer_Return::Type Bun::Bindgen::Cpp::bunBindgenCpp_NativeReadable_transfer(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_NativeReadable_transfer_Arguments& args)
{
    using Return = BunBindgenCpp_NativeReadable_transfer_Return;
    using Source = Return::Type::value_type::value_type;
    auto* readableStream = dynamicDowncast<JSC::JSObject>(args.readable_stream);
    RELEASE_ASSERT(readableStream);
    if (WebCore::ReadableStream::isLocked(&context.globalObject, readableStream))
        return std::unexpected(Return::Errors::locked {});

    auto source = nativeReadableStreamSource<Source>(*readableStream);
    if (!source) {
        auto& vm = context.globalObject.vm();
        auto state = readableStream->getDirect(vm, WebCore::builtinNames(vm).statePrivateName());
        auto native = WebCore::readableStreamNativePtr(*readableStream);
        // The builtin stream-state protocol defines $streamClosed as 1.
        constexpr int32_t closedState = 1;
        if (!native.isUndefined() || !state.isInt32() || state.asInt32() != closedState)
            return std::unexpected(Return::Errors::invalid_source {});
    }
    WebCore::setReadableStreamTransferred(context.globalObject, *readableStream);
    WebCore::setReadableStreamDisturbed(context.globalObject, *readableStream, true);
    return source;
}

using namespace JSC;
using namespace WebCore;

static JSC::JSObject* engineReadableStream(JSC::JSValue value)
{
    auto* stream = dynamicDowncast<JSC::JSObject>(value);
    RELEASE_ASSERT(stream && WebCore::isReadableStream(stream));
    return stream;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamTee(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamTee_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(JSC::jsBoolean(true));
    return invokeReadableStreamFunction(*globalObject, defaultGlobalObject(globalObject)->builtinInternalFunctions().readableStreamInternals().m_readableStreamTeeFunction.get(), arguments);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamCancel(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamCancel_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* readableStream = engineReadableStream(args.stream);
    if (!readableStream) [[unlikely]]
        return {};

    WebCore::Exception exception { Bun::AbortError };
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto reason = WebCore::createDOMException(globalObject, exception.code(), exception.message());
    RETURN_IF_EXCEPTION(scope, {});
    MarkedArgumentBuffer arguments;
    arguments.append(readableStream);
    arguments.append(reason);
    auto result = invokeReadableStreamFunction(*globalObject, defaultGlobalObject(globalObject)->builtinInternalFunctions().readableStreamInternals().m_readableStreamCancelFunction.get(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamCancelWithReason(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamCancelWithReason_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* readableStream = engineReadableStream(args.stream);
    if (!readableStream) [[unlikely]]
        return {};

    MarkedArgumentBuffer arguments;
    arguments.append(readableStream);
    args.reason.appendTo(arguments);
    return invokeReadableStreamFunction(*globalObject, defaultGlobalObject(globalObject)->builtinInternalFunctions().readableStreamInternals().m_readableStreamCancelFunction.get(), arguments);
}

void Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamDetach(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamDetach_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* readableStream = engineReadableStream(args.stream);
    if (!readableStream)
        return;
    WebCore::setReadableStreamNativePtr(*globalObject, *readableStream, jsNumber(-1));
    WebCore::setReadableStreamNativeType(*globalObject, *readableStream, 0);
    WebCore::setReadableStreamDisturbed(*globalObject, *readableStream, true);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamCanConsumeNative(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamCanConsumeNative_Arguments& args)
{
    auto* stream = engineReadableStream(args.stream);
    auto& vm = context.globalObject.vm();
    auto controller = stream->getDirect(vm, WebCore::builtinNames(vm).readableStreamControllerPrivateName());
    return controller.isUndefinedOrNull()
        && WebCore::readableStreamNativePtr(*stream).isCell()
        && !WebCore::ReadableStream::isDisturbed(&context.globalObject, stream)
        && !WebCore::ReadableStream::isLocked(&context.globalObject, stream);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamIsDisturbed(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamIsDisturbed_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* stream = engineReadableStream(args.stream);
    return stream && WebCore::ReadableStream::isDisturbed(globalObject, stream);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamIsLocked(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamIsLocked_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* stream = engineReadableStream(args.stream);
    return stream && WebCore::ReadableStream::isLocked(globalObject, stream);
}

template<typename Description>
static Description describeReadableStream(JSC::JSObject* object)
{
    ASSERT(WebCore::isReadableStream(object));
    Description description {};
    using Source = typename decltype(description.source)::value_type;
    description.source = nativeReadableStreamSource<Source>(*object);
    if (!description.source)
        description.tag = decltype(description.tag)::JavaScript;
    else if (description.source->is_blob())
        description.tag = decltype(description.tag)::Blob;
    else if (description.source->is_file())
        description.tag = decltype(description.tag)::File;
    else
        description.tag = decltype(description.tag)::Bytes;
    return description;
}

Bun::Bindgen::Engine::BunBindgenEngine_readable_streams_readableStreamCoerce_Return Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamCoerce(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamCoerce_Arguments& args)
{
    JSC::JSObject* object = args.value.getObject();
    if (!object)
        return std::nullopt;

    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto& vm = globalObject->vm();
    if (!WebCore::isReadableStream(object)) {
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSC::JSValue target = object;
        JSC::JSValue iteratorFunction;
        auto* function = WTF::dynamicDowncast<JSC::JSFunction>(object);
        if (function && !function->isHostFunction() && function->jsExecutable() && function->jsExecutable()->isAsyncGenerator()) {
            iteratorFunction = object;
            target = JSC::jsUndefined();
        } else {
            auto iterator = object->getIfPropertyExists(globalObject, vm.propertyNames->asyncIteratorSymbol);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            if (iterator && iterator.isCallable())
                iteratorFunction = iterator;
        }

        if (iteratorFunction.isEmpty()) {
            scope.release();
            return std::nullopt;
        }

        auto* createIterator = globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamFromAsyncIteratorFunction.get();
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(target);
        arguments.append(iteratorFunction);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return std::nullopt;
        }

        auto result = JSC::profiledCall(
            globalObject,
            JSC::ProfilingReason::API,
            createIterator,
            JSC::getCallData(createIterator),
            JSC::jsUndefined(),
            arguments);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        object = result.getObject();
        if (!object || !WebCore::isReadableStream(object)) {
            scope.release();
            return std::nullopt;
        }
        scope.release();
    }

    return object;
}

Bun::Bindgen::Engine::BunBindgenEngine_readable_streams_readableStreamDescribe_Return Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamDescribe(
    EngineCallContext&,
    const BunBindgenEngine_readable_streams_readableStreamDescribe_Arguments& args)
{
    using Return = BunBindgenEngine_readable_streams_readableStreamDescribe_Return;
    return describeReadableStream<Return>(engineReadableStream(args.stream));
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamCreateNative(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamCreateNative_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSValue native;
    if (args.native.is_blob())
        native = context.classValue(args.native.blob());
    else if (args.native.is_bytes())
        native = context.classValue(args.native.bytes());
    else {
        RELEASE_ASSERT(args.native.is_file());
        native = context.classValue(args.native.file());
    }

    JSC::MarkedArgumentBuffer arguments = JSC::MarkedArgumentBuffer();
    arguments.append(native);

    auto result = invokeReadableStreamFunction(*globalObject, defaultGlobalObject(globalObject)->builtinInternalFunctions().readableStreamInternals().m_createNativeReadableStreamFunction.get(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::readableStreamToBytes(Zig::GlobalObject* globalObject, JSC::JSValue readableStreamValue)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    MarkedArgumentBuffer arguments;
    arguments.append(readableStreamValue);
    auto result = invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToBytesFunction.get(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    if (!result || result.isUndefinedOrNull())
        return result;
    auto* object = result.getObject();
    if (!object) {
        throwTypeError(globalObject, scope, "Expected object"_s);
        return {};
    }
    auto* promise = dynamicDowncast<JSC::JSPromise>(object);
    if (!promise) {
        throwTypeError(globalObject, scope, "Expected promise"_s);
        return {};
    }
    return promise;
}

JSC::JSValue Bun::readableStreamToText(Zig::GlobalObject* globalObject, JSC::JSValue readableStreamValue)
{
    MarkedArgumentBuffer arguments;
    arguments.append(readableStreamValue);
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToTextFunction.get(), arguments);
}

JSC::JSValue Bun::readableStreamToJSON(Zig::GlobalObject* globalObject, JSC::JSValue readableStreamValue)
{
    MarkedArgumentBuffer arguments;
    arguments.append(readableStreamValue);
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToJSONFunction.get(), arguments);
}

JSC::JSValue Bun::readableStreamToBlob(Zig::GlobalObject* globalObject, JSC::JSValue readableStreamValue)
{
    MarkedArgumentBuffer arguments;
    arguments.append(readableStreamValue);
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToBlobFunction.get(), arguments);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamConsumeArrayBuffer(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamConsumeArrayBuffer_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(JSC::jsBoolean(true));
    auto result = invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToArrayBufferInternalFunction.get(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    if (!result || result.isUndefinedOrNull())
        return result;
    auto* object = result.getObject();
    if (!object) {
        throwTypeError(globalObject, scope, "Expected object"_s);
        return {};
    }
    auto* promise = dynamicDowncast<JSC::JSPromise>(object);
    if (!promise) {
        throwTypeError(globalObject, scope, "Expected promise"_s);
        return {};
    }
    return promise;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamConsumeBytes(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamConsumeBytes_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(JSC::jsBoolean(true));
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToBytesInternalFunction.get(), arguments);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamConsumeText(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamConsumeText_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(JSC::jsBoolean(true));
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToTextInternalFunction.get(), arguments);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamConsumeFormData(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamConsumeFormData_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(args.content_type ? JSC::jsString(vm, *args.content_type) : JSC::jsUndefined());
    RETURN_IF_EXCEPTION(scope, {});
    arguments.append(JSC::jsBoolean(true));
    RELEASE_AND_RETURN(scope, invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToFormDataInternalFunction.get(), arguments));
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamConsumeJSON(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamConsumeJSON_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(JSC::jsBoolean(true));
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToJSONInternalFunction.get(), arguments);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_readable_streams_readableStreamConsumeBlob(
    EngineCallContext& context,
    const BunBindgenEngine_readable_streams_readableStreamConsumeBlob_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    arguments.append(JSC::jsBoolean(true));
    return invokeReadableStreamFunction(*globalObject, globalObject->builtinInternalFunctions().readableStreamInternals().m_readableStreamToBlobInternalFunction.get(), arguments);
}
