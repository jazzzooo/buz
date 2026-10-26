/*
 * Copyright (C) 2009, 2013, 2016 Apple Inc. All rights reserved.
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

#pragma once

#include "root.h"
// #include "Blob.h"
// #include "DetachedRTCDataChannel.h"
#include "ExceptionOr.h"
#include "Bindgen/SharedCloneResource.h"
#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/Strong.h>
#include <variant>
#include <limits>
#include <wtf/Forward.h>
#include <wtf/Function.h>
#include <wtf/FastMalloc.h>
#include <wtf/text/WTFString.h>
#include "JavaScriptCore/WasmModule.h"

#if ENABLE(WEB_CODECS)
#include "WebCodecsEncodedVideoChunk.h"
#include "WebCodecsVideoFrame.h"
#endif

typedef const struct OpaqueJSContext* JSContextRef;
typedef const struct OpaqueJSValue* JSValueRef;

#if ENABLE(WEBASSEMBLY)
namespace JSC {
namespace Wasm {
class Module;
class MemoryHandle;
}
}
#endif

namespace WebCore {

// Shared value type for fast path cloning: primitives (JSValue) or strings.
using SimpleCloneableValue = std::variant<JSC::JSValue, WTF::String>;

class SimpleInMemoryPropertyTableEntry {
public:
    using Value = SimpleCloneableValue;

    WTF::String propertyName;
    Value value;
};

// A flat object whose property values are only primitives or strings (no nesting).
struct SimpleCloneableObject {
    WTF::Vector<SimpleInMemoryPropertyTableEntry> properties;
};

// Array element: primitive (JSValue), string, or a flat object.
using DenseArrayElement = std::variant<JSC::JSValue, WTF::String, SimpleCloneableObject>;

enum class FastPath : uint8_t {
    None,
    String,
    SimpleObject,
    Int32Array,
    DoubleArray,
    DenseArray,
};

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
class DetachedOffscreenCanvas;
class OffscreenCanvas;
#endif
#if ENABLE(WEB_RTC)
class RTCDataChannel;
#endif
// class IDBValue;
class MessagePort;
// class ImageBitmapBacking;
class CloneSerializer;
class CloneDeserializer;
class FragmentedSharedBuffer;
enum class SerializationReturnCode;
using DeserializationResult = std::pair<JSC::JSValue, SerializationReturnCode>;

enum class SerializationErrorMode { NonThrowing,
    Throwing };
enum class SerializationContext { Default,
    WorkerPostMessage,
    WindowPostMessage };
enum class SerializationForStorage : bool { No,
    Yes };
enum class SerializationForCrossProcessTransfer : bool { No,
    Yes };

using ArrayBufferContentsArray = Vector<JSC::ArrayBufferContents>;
#if ENABLE(WEBASSEMBLY)
using WasmModuleArray = Vector<RefPtr<JSC::Wasm::Module>>;
using WasmMemoryHandleArray = Vector<RefPtr<JSC::SharedArrayBufferContents>>;
#endif

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(SerializedScriptValue);
class SerializedScriptValue : public ThreadSafeRefCounted<SerializedScriptValue> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(SerializedScriptValue, SerializedScriptValue);

public:
    class Prepared {
        WTF_MAKE_NONCOPYABLE(Prepared);

    public:
        Prepared(Prepared&&) noexcept;
        ~Prepared();
        ExceptionOr<void> validateTransfers() const;
        // Validation follows the last observable operation; commit must not invoke JS.
        Ref<SerializedScriptValue> commit(JSC::VM&);

    private:
        friend class SerializedScriptValue;
        explicit Prepared(Ref<SerializedScriptValue>&&);
        static ExceptionOr<Prepared> fromResult(ExceptionOr<Ref<SerializedScriptValue>>&&);
        RefPtr<SerializedScriptValue> m_value;
        Vector<RefPtr<JSC::ArrayBuffer>> m_arrayBuffers;
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        Vector<RefPtr<OffscreenCanvas>> m_offscreenCanvases;
#endif
#if ENABLE(WEB_RTC)
        Vector<Ref<RTCDataChannel>> m_dataChannels;
#endif
#if ENABLE(WEB_CODECS)
        Vector<Ref<WebCodecsVideoFrame>> m_videoFrames;
#endif
    };

    static ExceptionOr<Prepared> prepare(JSC::JSGlobalObject&, JSC::JSValue, Vector<JSC::Strong<JSC::JSObject>>&& transfer, Vector<RefPtr<MessagePort>>&, SerializationForStorage = SerializationForStorage::No, SerializationContext = SerializationContext::Default, SerializationForCrossProcessTransfer = SerializationForCrossProcessTransfer::No);

    static bool writeBytesForBindgen(CloneSerializer*, const uint8_t*, uint32_t);
    static bool writeSharedResourceForBindgen(CloneSerializer*, Bun::Bindgen::SharedCloneResource&&);
    static void* sharedResourceForBindgen(CloneDeserializer*, uint8_t tag, const uint8_t*& cursor, const uint8_t* end);

    WEBCORE_EXPORT static ExceptionOr<Ref<SerializedScriptValue>> create(JSC::JSGlobalObject&, JSC::JSValue, Vector<JSC::Strong<JSC::JSObject>>&& transfer, Vector<RefPtr<MessagePort>>&, SerializationForStorage = SerializationForStorage::No, SerializationContext = SerializationContext::Default, SerializationForCrossProcessTransfer = SerializationForCrossProcessTransfer::No);
    // WEBCORE_EXPORT static ExceptionOr<Ref<SerializedScriptValue>> create(JSC::JSGlobalObject&, JSC::JSValue, Vector<JSC::Strong<JSC::JSObject>>&& transfer, SerializationForStorage = SerializationForStorage::No, SerializationContext = SerializationContext::Default);

    WEBCORE_EXPORT static RefPtr<SerializedScriptValue> create(JSC::JSGlobalObject&, JSC::JSValue, SerializationForStorage = SerializationForStorage::No, SerializationErrorMode = SerializationErrorMode::Throwing, SerializationContext = SerializationContext::Default, SerializationForCrossProcessTransfer = SerializationForCrossProcessTransfer::No);

    static RefPtr<SerializedScriptValue> convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value) { return create(globalObject, value, SerializationForStorage::Yes); }

    WEBCORE_EXPORT static RefPtr<SerializedScriptValue> create(StringView);

    WEBCORE_EXPORT JSC::JSValue deserialize(JSC::JSGlobalObject&, JSC::JSGlobalObject*, SerializationErrorMode = SerializationErrorMode::Throwing, bool* didFail = nullptr);
    WEBCORE_EXPORT JSC::JSValue deserialize(JSC::JSGlobalObject&, JSC::JSGlobalObject*, const Vector<RefPtr<MessagePort>>&, SerializationErrorMode = SerializationErrorMode::Throwing, bool* didFail = nullptr);

    // JSC::JSValue deserialize(JSC::JSGlobalObject&, JSC::JSGlobalObject*, const Vector<String>& blobURLs, const Vector<String>& blobFilePaths, SerializationErrorMode = SerializationErrorMode::Throwing, bool* didFail = nullptr);

    static uint32_t wireFormatVersion();

    WEBCORE_EXPORT String toString() const;

    WEBCORE_EXPORT Ref<JSC::ArrayBuffer> toArrayBuffer();
    static JSC::JSValue fromBytes(JSC::JSGlobalObject&, std::span<const uint8_t>);

    // API implementation helpers. These don't expose special behavior for ArrayBuffers or MessagePorts.
    WEBCORE_EXPORT static RefPtr<SerializedScriptValue> create(JSContextRef, JSValueRef, JSValueRef* exception);
    WEBCORE_EXPORT JSValueRef deserialize(JSContextRef, JSValueRef* exception);

    // bool hasBlobURLs() const { return !m_blobHandles.isEmpty(); }

    // Vector<String> blobURLs() const;
    // Vector<URLKeepingBlobAlive> blobHandles() const { return crossThreadCopy(m_blobHandles); }
    // void writeBlobsToDiskForIndexedDB(CompletionHandler<void(IDBValue&&)>&&);
    // IDBValue writeBlobsToDiskForIndexedDBSynchronously();
    const Vector<uint8_t>& wireBytes() const { return m_data; }

    template<class Encoder> void encode(Encoder&) const;
    template<class Decoder> static RefPtr<SerializedScriptValue> decode(Decoder&);

    size_t memoryCost() const { return m_memoryCost; }

    WEBCORE_EXPORT ~SerializedScriptValue();

private:
    static ExceptionOr<Ref<SerializedScriptValue>> createStringFastPath(JSC::VM&, const String&);
    static ExceptionOr<Ref<SerializedScriptValue>> createObjectFastPath(WTF::Vector<SimpleInMemoryPropertyTableEntry>&&);
    static ExceptionOr<Ref<SerializedScriptValue>> createInt32ArrayFastPath(Vector<uint8_t>&&, uint32_t);
    static ExceptionOr<Ref<SerializedScriptValue>> createDoubleArrayFastPath(Vector<uint8_t>&&, uint32_t);
    static ExceptionOr<Ref<SerializedScriptValue>> createDenseArrayFastPath(WTF::Vector<DenseArrayElement>&&);

    template<typename... Args> static ExceptionOr<Ref<SerializedScriptValue>> createWithArgs(Args&&... args)
    {
        auto* memory = SerializedScriptValueMalloc::tryMalloc(sizeof(SerializedScriptValue));
        if (!memory)
            return Exception { OutOfMemoryError };
        return adoptRef(*new (NotNull, memory) SerializedScriptValue(std::forward<Args>(args)...));
    }

    static ExceptionOr<Ref<SerializedScriptValue>> create(JSC::JSGlobalObject&, JSC::JSValue, Vector<JSC::Strong<JSC::JSObject>>&& transfer, Vector<RefPtr<MessagePort>>&, SerializationForStorage, SerializationErrorMode, SerializationContext, SerializationForCrossProcessTransfer);
    SerializedScriptValue(Vector<uint8_t>&&, ArrayBufferContentsArray = {}, ArrayBufferContentsArray sharedBuffers = {}
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        ,
        Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& = {}
#endif
#if ENABLE(WEB_RTC)
        ,
        Vector<std::unique_ptr<DetachedRTCDataChannel>>&& = {}
#endif
#if ENABLE(WEBASSEMBLY)
        ,
        WasmModuleArray = {}, WasmMemoryHandleArray = {}
#endif
#if ENABLE(WEB_CODECS)
        ,
        Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& = {}, Vector<WebCodecsVideoFrameData>&& = {}
#endif
    );

    // Constructor for string fast path
    explicit SerializedScriptValue(const String& fastPathString);
    explicit SerializedScriptValue(WTF::Vector<SimpleInMemoryPropertyTableEntry>&& object);
    // Constructor for Int32Array/DoubleArray butterfly memcpy fast path
    SerializedScriptValue(Vector<uint8_t>&& butterflyData, uint32_t length, FastPath fastPath);
    // Constructor for DenseArray fast path
    explicit SerializedScriptValue(WTF::Vector<DenseArrayElement>&& denseElements);

    size_t computeMemoryCost() const;
    DeserializationResult deserializeFastPath(JSC::JSGlobalObject&, JSC::JSGlobalObject*);

    Vector<unsigned char> m_data;
    ArrayBufferContentsArray m_arrayBufferContentsArray;
    ArrayBufferContentsArray m_sharedBufferContentsArray;
    Bun::Bindgen::SharedCloneResources m_sharedNativeResources;
    // Vector<std::optional<ImageBitmapBacking>> m_backingStores;
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    Vector<std::unique_ptr<DetachedOffscreenCanvas>> m_detachedOffscreenCanvases;
#endif
#if ENABLE(WEB_RTC)
    Vector<std::unique_ptr<DetachedRTCDataChannel>> m_detachedRTCDataChannels;
#endif
#if ENABLE(WEBASSEMBLY)
    WasmModuleArray m_wasmModulesArray;
    WasmMemoryHandleArray m_wasmMemoryHandlesArray;
#endif
#if ENABLE(WEB_CODECS)
    Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>> m_serializedVideoChunks;
    Vector<WebCodecsVideoFrameData> m_serializedVideoFrames;
#endif
    // Vector<URLKeepingBlobAlive> m_blobHandles;

    // Fast path for postMessage with pure strings - avoids serialization overhead
    String m_fastPathString;
    FastPath m_fastPath { FastPath::None };
    size_t m_memoryCost { 0 };

    Vector<SimpleInMemoryPropertyTableEntry> m_simpleInMemoryPropertyTable;

    // Int32Array / DoubleArray fast path: raw butterfly data
    Vector<uint8_t> m_arrayButterflyData {};
    uint32_t m_arrayLength { 0 };

    // DenseArray fast path: array of primitives/strings/simple objects
    Vector<DenseArrayElement> m_denseArrayElements;
};

template<class Encoder>
void SerializedScriptValue::encode(Encoder& encoder) const
{
    encoder << m_data;

    bool hasArray = !m_arrayBufferContentsArray.isEmpty();
    encoder << hasArray;

    if (hasArray) {
        encoder << static_cast<uint64_t>(m_arrayBufferContentsArray.size());
        for (const auto& arrayBufferContents : m_arrayBufferContentsArray)
            encoder << std::span(reinterpret_cast<const uint8_t*>(arrayBufferContents.data()), arrayBufferContents.sizeInBytes());
    }

#if ENABLE(WEB_RTC)
    encoder << static_cast<uint64_t>(m_detachedRTCDataChannels.size());
    for (const auto& channel : m_detachedRTCDataChannels)
        encoder << *channel;
#endif

#if ENABLE(WEB_CODECS)
    encoder << static_cast<uint64_t>(m_serializedVideoChunks.size());
    for (const auto& videoChunk : m_serializedVideoChunks)
        encoder << videoChunk->data();

    // FIXME: encode video frames
#endif
}

template<class Decoder>
RefPtr<SerializedScriptValue> SerializedScriptValue::decode(Decoder& decoder)
{
    Vector<uint8_t> data;
    if (!decoder.decode(data))
        return nullptr;

    bool hasArray;
    if (!decoder.decode(hasArray))
        return nullptr;

    ArrayBufferContentsArray arrayBufferContentsArray;
    if (hasArray) {
        uint64_t arrayLength;
        if (!decoder.decode(arrayLength))
            return nullptr;
        if (!arrayLength || arrayLength > std::numeric_limits<unsigned>::max() || !arrayBufferContentsArray.tryReserveInitialCapacity(arrayLength))
            return nullptr;
        while (arrayLength--) {
            std::span<const uint8_t> data;
            if (!decoder.decode(data))
                return nullptr;

            auto buffer = Gigacage::tryMalloc(Gigacage::Primitive, data.size_bytes());
            if (!buffer)
                return nullptr;

            static_assert(sizeof(std::span<const uint8_t>::element_type) == 1);
            memcpy(buffer, data.data(), data.size_bytes());
            JSC::ArrayBufferDestructorFunction destructor = ArrayBuffer::primitiveGigacageDestructor();
            arrayBufferContentsArray.append({ buffer, data.size_bytes(), std::nullopt, WTF::move(destructor) });
        }
    }

#if ENABLE(WEB_RTC)
    uint64_t detachedRTCDataChannelsSize;
    if (!decoder.decode(detachedRTCDataChannelsSize))
        return nullptr;

    Vector<std::unique_ptr<DetachedRTCDataChannel>> detachedRTCDataChannels;
    while (detachedRTCDataChannelsSize--) {
        std::optional<DetachedRTCDataChannel> detachedRTCDataChannel;
        decoder >> detachedRTCDataChannel;
        if (!detachedRTCDataChannel)
            return nullptr;
        detachedRTCDataChannels.append(makeUnique<DetachedRTCDataChannel>(WTF::move(*detachedRTCDataChannel)));
    }
#endif
#if ENABLE(WEB_CODECS)
    uint64_t serializedVideoChunksSize;
    if (!decoder.decode(serializedVideoChunksSize))
        return nullptr;

    Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>> serializedVideoChunks;
    while (serializedVideoChunksSize--) {
        std::optional<WebCodecsEncodedVideoChunkData> videoChunkData;
        decoder >> videoChunkData;
        if (!videoChunkData)
            return nullptr;
        serializedVideoChunks.append(WebCodecsEncodedVideoChunkStorage::create(WTF::move(*videoChunkData)));
    }
    // FIXME: decode video frames
    Vector<WebCodecsVideoFrameData> serializedVideoFrames;
#endif

    auto result = createWithArgs(WTF::move(data), WTF::move(arrayBufferContentsArray), ArrayBufferContentsArray {}
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        ,
        Vector<std::unique_ptr<DetachedOffscreenCanvas>> {}
#endif
#if ENABLE(WEB_RTC)
        ,
        WTF::move(detachedRTCDataChannels)
#endif
#if ENABLE(WEBASSEMBLY)
            ,
        WasmModuleArray {}, WasmMemoryHandleArray {}
#endif
#if ENABLE(WEB_CODECS)
        ,
        WTF::move(serializedVideoChunks)
#endif
#if ENABLE(WEB_CODECS)
            ,
        WTF::move(serializedVideoFrames)
#endif
    );
    if (result.hasException())
        return nullptr;
    return result.releaseReturnValue();
}

}
