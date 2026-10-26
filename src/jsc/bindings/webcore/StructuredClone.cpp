/*
 * Copyright (C) 2016 Apple Inc. All Rights Reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include "config.h"
#include "StructuredClone.h"

#include "SchemaBindings.h"
#include "JSDOMBinding.h"
#include "JSDOMExceptionHandling.h"
#include <JavaScriptCore/JSTypedArrays.h>
#include "SerializedScriptValue.h"
#include "StructuredSerializeBinding.h"
#include "MessagePort.h"

namespace WebCore {
using namespace JSC;

static JSC::JSValue cloneArrayBuffer(JSGlobalObject* globalObject, JSC::ArrayBuffer* buffer, int32_t srcByteOffset, int32_t srcLength)
{
    return JSArrayBuffer::create(globalObject->vm(), globalObject->arrayBufferStructure(ArrayBufferSharingMode::Default), buffer->slice(srcByteOffset, srcByteOffset + srcLength));
}

static JSC::JSValue structuredCloneForStream(JSGlobalObject* globalObject, JSC::JSValue value)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (value.isPrimitive())
        return value;

    if (value.inherits<JSArrayBuffer>()) {
        auto* buffer = toUnsharedArrayBuffer(vm, value);
        if (!buffer) {
            throwDataCloneError(*globalObject, scope);
            return {};
        }
        return JSArrayBuffer::create(globalObject->vm(), globalObject->arrayBufferStructure(ArrayBufferSharingMode::Default), buffer->slice(0));
    }

    if (value.inherits<JSArrayBufferView>()) {
        auto* bufferView = uncheckedDowncast<JSArrayBufferView>(value);
        ASSERT(bufferView);

        auto* buffer = bufferView->unsharedBuffer();
        if (!buffer) {
            throwDataCloneError(*globalObject, scope);
            return {};
        }
        auto bufferClone = buffer->slice(0);
        Structure* structure = bufferView->structure();

#define CLONE_TYPED_ARRAY(name)                                                                                                                                                   \
    do {                                                                                                                                                                          \
        if (bufferView->inherits<JS##name##Array>())                                                                                                                              \
            RELEASE_AND_RETURN(scope, JS##name##Array::create(globalObject, structure, WTF::move(bufferClone), bufferView->byteOffset(), bufferView->length()));                  \
    } while (0);

        FOR_EACH_TYPED_ARRAY_TYPE_EXCLUDING_DATA_VIEW(CLONE_TYPED_ARRAY)

#undef CLONE_TYPED_ARRAY

        if (value.inherits<JSDataView>())
            RELEASE_AND_RETURN(scope, JSDataView::create(globalObject, structure, WTF::move(bufferClone), bufferView->byteOffset(), bufferView->length()));
    }

    throwTypeError(globalObject, scope, "structuredClone not implemented for non-ArrayBuffer / non-ArrayBufferView"_s);
    return {};
}

static JSC::JSValue structuredClone(
    JSC::JSGlobalObject* globalObject,
    JSC::JSValue value,
    Vector<JSC::Strong<JSC::JSObject>> transferList)
{
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    Vector<RefPtr<MessagePort>> ports;
    auto serialized = SerializedScriptValue::create(*globalObject, value, WTF::move(transferList), ports);
    RETURN_IF_EXCEPTION(throwScope, {});
    if (serialized.hasException()) {
        propagateException(*globalObject, throwScope, serialized.releaseException());
        RELEASE_AND_RETURN(throwScope, {});
    }
    JSValue deserialized = serialized.releaseReturnValue()->deserialize(*globalObject, globalObject, ports);
    RETURN_IF_EXCEPTION(throwScope, {});
    return deserialized;
}

} // namespace WebCore

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_WebCoreFunctions_cloneArrayBuffer(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_WebCoreFunctions_cloneArrayBuffer_Arguments& args)
{
    auto* buffer = JSC::toUnsharedArrayBuffer(context.globalObject.vm(), args.buffer);
    RELEASE_ASSERT(buffer);
    return WebCore::cloneArrayBuffer(&context.globalObject, buffer, args.srcByteOffset, args.srcLength);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFunctions_structuredCloneForStream(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFunctions_structuredCloneForStream_Arguments& args)
{
    return WebCore::structuredCloneForStream(&context.globalObject, args.value);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFunctions_structuredClone(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFunctions_structuredClone_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    auto options = Bun::Bindgen::structuredSerializeOptionsFromTransfer(
        *globalObject, args.options && args.options->transfer ? &*args.options->transfer : nullptr);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(options);
    RELEASE_AND_RETURN(scope, WebCore::structuredClone(globalObject, args.value, WTF::move(options->transfer)));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_bindgen_test_structuredCloneAdvanced(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_bindgen_test_structuredCloneAdvanced_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto serializationContext = [&] {
        auto context = args.serialization_context.value_or(Bun::Bindgen::StructuredCloneSerializationContext::default_context);
        switch (context) {
        case Bun::Bindgen::StructuredCloneSerializationContext::worker:
            return WebCore::SerializationContext::WorkerPostMessage;
        case Bun::Bindgen::StructuredCloneSerializationContext::window:
            return WebCore::SerializationContext::WindowPostMessage;
        case Bun::Bindgen::StructuredCloneSerializationContext::default_context:
            return WebCore::SerializationContext::Default;
        }
    }();

    auto forTransfer = args.for_transfer ? WebCore::SerializationForCrossProcessTransfer::Yes : WebCore::SerializationForCrossProcessTransfer::No;
    auto forStorage = args.for_storage ? WebCore::SerializationForStorage::Yes : WebCore::SerializationForStorage::No;
    auto options = Bun::Bindgen::structuredSerializeOptionsFromTransfer(*globalObject, &args.transfer_list);
    RETURN_IF_EXCEPTION(throwScope, {});
    RELEASE_ASSERT(options);

    WTF::Vector<RefPtr<WebCore::MessagePort>> ports;
    auto serialized = WebCore::SerializedScriptValue::create(
        *globalObject,
        args.value,
        WTF::move(options->transfer),
        ports,
        forStorage,
        serializationContext,
        forTransfer);
    RETURN_IF_EXCEPTION(throwScope, {});
    if (serialized.hasException()) {
        WebCore::propagateException(*globalObject, throwScope, serialized.releaseException());
        return {};
    }

    RELEASE_AND_RETURN(throwScope, serialized.releaseReturnValue()->deserialize(*globalObject, globalObject, ports));
}
