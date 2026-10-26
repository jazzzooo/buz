/*
 * Copyright (C) 2009-2023 Apple Inc. All rights reserved.
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
#include "SerializedScriptValue.h"
#include "CryptoKeySerialization.h"
// #include "BlobRegistry.h"
// #include "ByteArrayPixelBuffer.h"
// #include "IDBValue.h"
// #include "ImageBitmapBacking.h"
// #include "JSAudioWorkletGlobalScope.h"
#include "JSDOMBinding.h"
#include "JSBufferSource.h"
#include "JSDOMException.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMGlobalObject.h"
// #include "JSDOMMatrix.h"
// #include "JSDOMPoint.h"
// #include "JSDOMQuad.h"
// #include "JSDOMRect.h"
// #include "JSExecState.h"
// #include "JSFile.h"
// #include "JSFileList.h"
// #include "JSIDBSerializationGlobalObject.h"
// #include "JSImageBitmap.h"
// #include "JSImageData.h"
#include "JSMessagePort.h"
// #include "JSNavigator.h"
// #include "JSRTCCertificate.h"
// #include "JSRTCDataChannel.h"
// #include "JSWebCodecsEncodedVideoChunk.h"
// #include "JSWebCodecsVideoFrame.h"
#include "ScriptExecutionContext.h"
// #include "WebCodecsEncodedVideoChunk.h"
#include "WebCoreJSClientData.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/BigIntObject.h>
#include <JavaScriptCore/BooleanObject.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/IterationKind.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include <JavaScriptCore/ButterflyInlines.h>
#include <JavaScriptCore/ObjectInitializationScope.h>
#include <JavaScriptCore/JSDataView.h>
#include <JavaScriptCore/JSMapInlines.h>
#include <JavaScriptCore/JSMapIterator.h>
#include <JavaScriptCore/JSSetInlines.h>
#include <JavaScriptCore/JSSetIterator.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/JSWebAssemblyMemory.h>
#include <JavaScriptCore/JSWebAssemblyModule.h>
#include <JavaScriptCore/NumberObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/RegExp.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/TypedArrays.h>
#include <JavaScriptCore/WasmModule.h>
#include <JavaScriptCore/YarrFlags.h>
#include <limits>
#include <wtf/CheckedArithmetic.h>
#include <wtf/CompletionHandler.h>
#include <wtf/MainThread.h>
#include <wtf/RunLoop.h>
#include <wtf/Vector.h>
#include <wtf/text/StringHash.h>
#include <wtf/threads/BinarySemaphore.h>

#include "ZigGlobalObject.h"
#include "blob.h"
#include "SchemaBindings.h"
#include "JSX509Certificate.h"
#include "ncrypto.h"
#include "JSKeyObject.h"
#include "JSSecretKeyObject.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"
#include "CryptoKeyType.h"
#include "JSNodePerformanceHooksHistogram.h"
#include "../napi.h"
#include <limits>
#include <algorithm>

#if USE(CG)
#include <CoreGraphics/CoreGraphics.h>
#endif

#if PLATFORM(COCOA)
#include <CoreFoundation/CoreFoundation.h>
#endif

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
#include "JSOffscreenCanvas.h"
#include "OffscreenCanvas.h"
#endif

#if CPU(BIG_ENDIAN) || CPU(MIDDLE_ENDIAN) || CPU(NEEDS_ALIGNED_ACCESS)
#define ASSUME_LITTLE_ENDIAN 0
#else
#define ASSUME_LITTLE_ENDIAN 1
#endif

namespace WebCore {

using namespace JSC;
using namespace Bun;

DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(SerializedScriptValue);

static constexpr unsigned maximumFilterRecursion = 40000;
static constexpr uint64_t autoLengthMarker = UINT64_MAX;

enum class SerializationReturnCode {
    SuccessfullyCompleted,
    StackOverflowError,
    InterruptedExecutionError,
    ValidationError,
    ExistingExceptionError,
    OutOfMemoryError,
    DataCloneError,
    UnspecifiedError
};

static SerializationReturnCode cryptoSerializationFailure(SerializationReturnCode fallback)
{
    return ncrypto::takeAllocationFailure() ? SerializationReturnCode::OutOfMemoryError : fallback;
}

enum WalkerState { StateUnknown,
    ArrayStartState,
    ArrayStartVisitMember,
    ArrayEndVisitMember,
    ObjectStartState,
    ObjectStartVisitMember,
    ObjectEndVisitMember,
    MapDataStartVisitEntry,
    MapDataEndVisitKey,
    MapDataEndVisitValue,
    SetDataStartVisitEntry,
    SetDataEndVisitKey };

// These can't be reordered, and any new types must be added to the end of the list
// When making changes to these lists please cover your new type(s) in the API test "IndexedDB.StructuredCloneBackwardCompatibility"
enum SerializationTag {
    ArrayTag = 1,
    ObjectTag = 2,
    UndefinedTag = 3,
    NullTag = 4,
    IntTag = 5,
    ZeroTag = 6,
    OneTag = 7,
    FalseTag = 8,
    TrueTag = 9,
    DoubleTag = 10,
    DateTag = 11,
    FileTag = 12,
    FileListTag = 13,
    ImageDataTag = 14,
    BlobTag = 15,
    StringTag = 16,
    EmptyStringTag = 17,
    RegExpTag = 18,
    ObjectReferenceTag = 19,
    MessagePortReferenceTag = 20,
    ArrayBufferTag = 21,
    ArrayBufferViewTag = 22,
    ArrayBufferTransferTag = 23,
    TrueObjectTag = 24,
    FalseObjectTag = 25,
    StringObjectTag = 26,
    EmptyStringObjectTag = 27,
    NumberObjectTag = 28,
    SetObjectTag = 29,
    MapObjectTag = 30,
    NonMapPropertiesTag = 31,
    NonSetPropertiesTag = 32,
    LegacyCryptoKeyTag = 33,
    SharedArrayBufferTag = 34,
#if ENABLE(WEBASSEMBLY)
    WasmModuleTag = 35,
#endif
    DOMPointReadOnlyTag = 36,
    DOMPointTag = 37,
    DOMRectReadOnlyTag = 38,
    DOMRectTag = 39,
    DOMMatrixReadOnlyTag = 40,
    DOMMatrixTag = 41,
    DOMQuadTag = 42,
    ImageBitmapTransferTag = 43,
#if ENABLE(WEB_RTC)
    RTCCertificateTag = 44,
#endif
    ImageBitmapTag = 45,
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    OffscreenCanvasTransferTag = 46,
#endif
    BigIntTag = 47,
    BigIntObjectTag = 48,
#if ENABLE(WEBASSEMBLY)
    WasmMemoryTag = 49,
#endif
#if ENABLE(WEB_RTC)
    RTCDataChannelTransferTag = 50,
#endif
    DOMExceptionTag = 51,
#if ENABLE(WEB_CODECS)
    WebCodecsEncodedVideoChunkTag = 52,
    WebCodecsVideoFrameTag = 53,
#endif
    ResizableArrayBufferTag = 54,
    ErrorInstanceTag = 55,

    Bun__BlobTag = 254,
    // bun types start at 254 and decrease with each addition
    Bun__X509CertificateTag = 253,
    Bun__KeyObjectTag = 252,
    Bun__nodenet_BlockList = 251,
    Bun__NodePerformanceHooksHistogramTag = 250,

    ErrorTag = 255
};

enum ArrayBufferViewSubtag {
    DataViewTag = 0,
    Int8ArrayTag = 1,
    Uint8ArrayTag = 2,
    Uint8ClampedArrayTag = 3,
    Int16ArrayTag = 4,
    Uint16ArrayTag = 5,
    Int32ArrayTag = 6,
    Uint32ArrayTag = 7,
    Float32ArrayTag = 8,
    Float64ArrayTag = 9,
    BigInt64ArrayTag = 10,
    BigUint64ArrayTag = 11,
    Float16ArrayTag = 12,
};

static unsigned typedArrayElementSize(ArrayBufferViewSubtag tag)
{
    switch (tag) {
    case DataViewTag:
    case Int8ArrayTag:
    case Uint8ArrayTag:
    case Uint8ClampedArrayTag:
        return 1;
    case Int16ArrayTag:
    case Uint16ArrayTag:
    case Float16ArrayTag:
        return 2;
    case Int32ArrayTag:
    case Uint32ArrayTag:
    case Float32ArrayTag:
        return 4;
    case Float64ArrayTag:
    case BigInt64ArrayTag:
    case BigUint64ArrayTag:
        return 8;
    default:
        return 0;
    }
}

enum class SerializableErrorType : uint8_t {
    Error,
    EvalError,
    RangeError,
    ReferenceError,
    SyntaxError,
    TypeError,
    URIError,
    Last = URIError
};

static SerializableErrorType errorNameToSerializableErrorType(const String& name)
{
    if (equalLettersIgnoringASCIICase(name, "evalerror"_s))
        return SerializableErrorType::EvalError;
    if (equalLettersIgnoringASCIICase(name, "rangeerror"_s))
        return SerializableErrorType::RangeError;
    if (equalLettersIgnoringASCIICase(name, "referenceerror"_s))
        return SerializableErrorType::ReferenceError;
    if (equalLettersIgnoringASCIICase(name, "syntaxerror"_s))
        return SerializableErrorType::SyntaxError;
    if (equalLettersIgnoringASCIICase(name, "typeerror"_s))
        return SerializableErrorType::TypeError;
    if (equalLettersIgnoringASCIICase(name, "urierror"_s))
        return SerializableErrorType::URIError;
    return SerializableErrorType::Error;
}

static ErrorType toErrorType(SerializableErrorType value)
{
    switch (value) {
    case SerializableErrorType::Error:
        return ErrorType::Error;
    case SerializableErrorType::EvalError:
        return ErrorType::EvalError;
    case SerializableErrorType::RangeError:
        return ErrorType::RangeError;
    case SerializableErrorType::ReferenceError:
        return ErrorType::ReferenceError;
    case SerializableErrorType::SyntaxError:
        return ErrorType::SyntaxError;
    case SerializableErrorType::TypeError:
        return ErrorType::TypeError;
    case SerializableErrorType::URIError:
        return ErrorType::URIError;
    }
    return ErrorType::Error;
}

enum class PredefinedColorSpaceTag : uint8_t {
    SRGB = 0
#if ENABLE(PREDEFINED_COLOR_SPACE_DISPLAY_P3)
    ,
    DisplayP3 = 1
#endif
};

enum DestinationColorSpaceTag {
    DestinationColorSpaceSRGBTag = 0,
#if ENABLE(DESTINATION_COLOR_SPACE_LINEAR_SRGB)
    DestinationColorSpaceLinearSRGBTag = 1,
#endif
#if ENABLE(DESTINATION_COLOR_SPACE_DISPLAY_P3)
    DestinationColorSpaceDisplayP3Tag = 2,
#endif
#if PLATFORM(COCOA)
    DestinationColorSpaceCGColorSpaceNameTag = 3,
    DestinationColorSpaceCGColorSpacePropertyListTag = 4,
#endif
};

#if ENABLE(WEBASSEMBLY)
static String agentClusterIDFromGlobalObject(JSGlobalObject& globalObject)
{
    if (!globalObject.inherits<JSDOMGlobalObject>())
        return JSDOMGlobalObject::defaultAgentClusterID();
    return uncheckedDowncast<JSDOMGlobalObject>(&globalObject)->agentClusterID();
}
#endif

/* CurrentVersion tracks the serialization version so that persistent stores
 * are able to correctly bail out in the case of encountering newer formats.
 *
 * Initial version was 1.
 * Version 2. added the ObjectReferenceTag and support for serialization of cyclic graphs.
 * Version 3. added the FalseObjectTag, TrueObjectTag, NumberObjectTag, StringObjectTag
 * and EmptyStringObjectTag for serialization of Boolean, Number and String objects.
 * Version 4. added support for serializing non-index properties of arrays.
 * Version 5. added support for Map and Set types.
 * Version 6. added support for 8-bit strings.
 * Version 7. added support for File's lastModified attribute.
 * Version 8. added support for ImageData's colorSpace attribute.
 * Version 9. added support for ImageBitmap color space.
 * Version 10. changed the length (and offsets) of ArrayBuffers (and ArrayBufferViews) from 32 to 64 bits.
 * Version 11. added support for Blob's memory cost.
 * Version 12. added support for agent cluster ID.
 * Version 13. added support for ErrorInstance objects.
 */
[[maybe_unused]] static constexpr unsigned CurrentVersion = 13;
[[maybe_unused]] static constexpr unsigned TerminatorTag = 0xFFFFFFFF;
[[maybe_unused]] static constexpr unsigned StringPoolTag = 0xFFFFFFFE;
[[maybe_unused]] static constexpr unsigned NonIndexPropertiesTag = 0xFFFFFFFD;
[[maybe_unused]] static constexpr uint32_t ImageDataPoolTag = 0xFFFFFFFE;

// The high bit of a StringData's length determines the character size.
static constexpr unsigned StringDataIs8BitFlag = 0x80000000;

/*
 * Object serialization is performed according to the following grammar, all tags
 * are recorded as a single uint8_t.
 *
 * IndexType (used for the object pool and StringData's constant pool) is the
 * minimum sized unsigned integer type required to represent the maximum index
 * in the constant pool.
 *
 * SerializedValue :- <CurrentVersion:uint32_t> Value
 * Value :- Array | Object | Map | Set | Terminal
 *
 * Array :-
 *     ArrayTag <length:uint32_t>(<index:uint32_t><value:Value>)* TerminatorTag
 *
 * Object :-
 *     ObjectTag (<name:StringData><value:Value>)* TerminatorTag
 *
 * Map :- MapObjectTag MapData
 *
 * Set :- SetObjectTag SetData
 *
 * MapData :- (<key:Value><value:Value>)* NonMapPropertiesTag (<name:StringData><value:Value>)* TerminatorTag
 * SetData :- (<key:Value>)* NonSetPropertiesTag (<name:StringData><value:Value>)* TerminatorTag
 *
 * Terminal :-
 *      UndefinedTag
 *    | NullTag
 *    | IntTag <value:int32_t>
 *    | ZeroTag
 *    | OneTag
 *    | FalseTag
 *    | TrueTag
 *    | FalseObjectTag
 *    | TrueObjectTag
 *    | DoubleTag <value:double>
 *    | NumberObjectTag <value:double>
 *    | DateTag <value:double>
 *    | String
 *    | EmptyStringTag
 *    | EmptyStringObjectTag
 *    | BigInt
 *    | File
 *    | FileList
 *    | ImageData
 *    | Blob
 *    | ObjectReference
 *    | MessagePortReferenceTag <value:uint32_t>
 *    | ArrayBuffer
 *    | ArrayBufferViewTag ArrayBufferViewSubtag <byteOffset:uint64_t> <byteLength:uint64_t> (ArrayBuffer | ObjectReference)
 *    | DOMPoint
 *    | DOMRect
 *    | DOMMatrix
 *    | DOMQuad
 *    | ImageBitmapTransferTag <value:uint32_t>
 *    | RTCCertificateTag
 *    | ImageBitmapTag <originClean:uint8_t> <logicalWidth:int32_t> <logicalHeight:int32_t> <resolutionScale:double> DestinationColorSpace <byteLength:uint32_t>(<imageByteData:uint8_t>)
 *    | OffscreenCanvasTransferTag <value:uint32_t>
 *    | WasmMemoryTag <value:uint32_t>
 *    | RTCDataChannelTransferTag <identifier:uint32_t>
 *    | DOMExceptionTag <message:String> <name:String>
 *    | WebCodecsEncodedVideoChunkTag <identifier:uint32_t>
 *
 * Inside certificate, data is serialized in this format as per spec:
 *
 * <expires:double> <certificate:StringData> <origin:StringData> <keyingMaterial:StringData>
 * We also add fingerprints to make sure we expose to JavaScript the same information.
 *
 * String :-
 *      EmptyStringTag
 *      StringTag StringData
 *
 * StringObject:
 *      EmptyStringObjectTag
 *      StringObjectTag StringData
 *
 * StringData :-
 *      StringPoolTag <cpIndex:IndexType>
 *      (not (TerminatorTag | StringPoolTag))<is8Bit:uint32_t:1><length:uint32_t:31><characters:CharType{length}> // Added to constant pool when seen, string length 0xFFFFFFFF is disallowed
 *
 * BigInt :-
 *      BigIntTag BigIntData
 *      BigIntObjectTag BigIntData
 *
 * BigIntData :-
 *      <sign:uint8_t> <lengthInUint64:uint32_t> <contents:uint64_t{lengthInUint64}>
 *
 * File :-
 *    FileTag FileData
 *
 * FileData :-
 *    <path:StringData> <url:StringData> <type:StringData> <name:StringData> <lastModified:double>
 *
 * FileList :-
 *    FileListTag <length:uint32_t>(<file:FileData>){length}
 *
 * ImageData :-
 *    ImageDataTag <width:int32_t> <height:int32_t> <length:uint32_t> <data:uint8_t{length}> <colorSpace:PredefinedColorSpaceTag>
 *
 * Blob :-
 *    BlobTag <url:StringData><type:StringData><size:long long><memoryCost:long long>
 *
 * RegExp :-
 *    RegExpTag <pattern:StringData><flags:StringData>
 *
 * ObjectReference :-
 *    ObjectReferenceTag <opIndex:IndexType>
 *
 * ArrayBuffer :-
 *    ArrayBufferTag <byteLength:uint64_t> <contents:byte{length}>
 *    ResizableArrayBufferTag <byteLength:uint64_t> <maxLength:uint64_t> <contents:byte{length}>
 *    ArrayBufferTransferTag <value:uint32_t>
 *    SharedArrayBufferTag <value:uint32_t>
 *
 * DOMPoint :-
 *        DOMPointReadOnlyTag DOMPointData
 *      | DOMPointTag DOMPointData
 *
 * DOMPointData :-
 *      <x:double> <y:double> <z:double> <w:double>
 *
 * DOMRect :-
 *        DOMRectReadOnlyTag DOMRectData
 *      | DOMRectTag DOMRectData
 *
 * DOMRectData :-
 *      <x:double> <y:double> <width:double> <height:double>
 *
 * DOMMatrix :-
 *        DOMMatrixReadOnlyTag DOMMatrixData
 *      | DOMMatrixTag DOMMatrixData
 *
 * DOMMatrixData :-
 *        <is2D:uint8_t:true> <m11:double> <m12:double> <m21:double> <m22:double> <m41:double> <m42:double>
 *      | <is2D:uint8_t:false> <m11:double> <m12:double> <m13:double> <m14:double> <m21:double> <m22:double> <m23:double> <m24:double> <m31:double> <m32:double> <m33:double> <m34:double> <m41:double> <m42:double> <m43:double> <m44:double>
 *
 * DOMQuad :-
 *      DOMQuadTag DOMQuadData
 *
 * DOMQuadData :-
 *      <p1:DOMPointData> <p2:DOMPointData> <p3:DOMPointData> <p4:DOMPointData>
 *
 * DestinationColorSpace :-
 *        DestinationColorSpaceSRGBTag
 *      | DestinationColorSpaceLinearSRGBTag
 *      | DestinationColorSpaceDisplayP3Tag
 *      | DestinationColorSpaceCGColorSpaceNameTag <nameDataLength:uint32_t> <nameData:uint8_t>{nameDataLength}
 *      | DestinationColorSpaceCGColorSpacePropertyListTag <propertyListDataLength:uint32_t> <propertyListData:uint8_t>{propertyListDataLength}
 */

class CloneBase {
    WTF_FORBID_HEAP_ALLOCATION;

protected:
    CloneBase(JSGlobalObject* lexicalGlobalObject)
        : m_lexicalGlobalObject(lexicalGlobalObject)
    {
    }

    JSGlobalObject* const m_lexicalGlobalObject;
};

template<typename T> [[nodiscard]] static bool writeLittleEndian(Vector<uint8_t>& buffer, T value)
{
#if ASSUME_LITTLE_ENDIAN
    return buffer.tryAppend(std::span { reinterpret_cast<const uint8_t*>(&value), sizeof(value) });
#else
    std::array<uint8_t, sizeof(T)> bytes;
    auto bits = static_cast<std::make_unsigned_t<T>>(value);
    for (unsigned i = 0; i < sizeof(T); i++) {
        bytes[i] = static_cast<uint8_t>(bits & 0xFF);
        bits >>= 8;
    }
    return buffer.tryAppend(std::span { bytes });
#endif
}

template<typename T> [[nodiscard]] static bool writeLittleEndian(Vector<uint8_t>& buffer, const T* values, size_t length)
{
    if (length > std::numeric_limits<size_t>::max() / sizeof(T))
        return false;

#if ASSUME_LITTLE_ENDIAN
    return buffer.tryAppend(std::span { reinterpret_cast<const uint8_t*>(values), length * sizeof(T) });
#else
    for (size_t i = 0; i < length; i++) {
        if (!writeLittleEndian(buffer, values[i]))
            return false;
    }
    return true;
#endif
}

template<typename Key, typename Hash> class CloneConstantPool {
public:
    std::optional<uint32_t> find(const Key& key) const
    {
        ASSERT(key);
        if (m_buckets.isEmpty())
            return std::nullopt;
        size_t mask = m_buckets.size() - 1;
        for (size_t index = Hash::hash(key) & mask; m_buckets[index].key; index = (index + 1) & mask) {
            if (Hash::equal(m_buckets[index].key, key))
                return m_buckets[index].value;
        }
        return std::nullopt;
    }

    [[nodiscard]] bool add(Key key, uint32_t value)
    {
        ASSERT(key);
        ASSERT(!find(key));
        if (m_size == m_buckets.size() / 2) {
            if (m_buckets.size() > std::numeric_limits<unsigned>::max() / 2)
                return false;
            Vector<Entry> buckets;
            if (!buckets.tryGrow(m_buckets.isEmpty() ? 16 : m_buckets.size() * 2))
                return false;
            for (auto& entry : m_buckets) {
                if (entry.key)
                    insert(buckets, WTF::move(entry.key), entry.value);
            }
            m_buckets = WTF::move(buckets);
        }
        insert(m_buckets, WTF::move(key), value);
        ++m_size;
        return true;
    }

    uint32_t size() const { return m_size; }

private:
    struct Entry {
        Key key {};
        uint32_t value { 0 };
    };

    static void insert(Vector<Entry>& buckets, Key key, uint32_t value)
    {
        size_t mask = buckets.size() - 1;
        size_t index = Hash::hash(key) & mask;
        while (buckets[index].key)
            index = (index + 1) & mask;
        buckets[index] = { WTF::move(key), value };
    }

    Vector<Entry> m_buckets;
    uint32_t m_size { 0 };
};

class CloneSerializer : public CloneBase {
    WTF_FORBID_HEAP_ALLOCATION;

public:
    [[nodiscard]] bool writeBytes(const uint8_t* data, uint64_t length)
    {
        if (!prepareWrite(length))
            return false;
        if (!m_buffer.tryAppend(std::span { data, static_cast<size_t>(length) }))
            fail(SerializationReturnCode::OutOfMemoryError);
        return !failed();
    }

    bool writeSharedResource(Bun::Bindgen::SharedCloneResource&& resource)
    {
        if (failed())
            return false;
        auto index = m_sharedNativeResources.size();
        if (index > std::numeric_limits<uint32_t>::max()) {
            fail(SerializationReturnCode::DataCloneError);
            return false;
        }
        if (!m_sharedNativeResources.tryAppend(WTF::move(resource))) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        write(static_cast<uint32_t>(index));
        return !failed();
    }

    void write(const uint8_t* data, uint64_t length)
    {
        if (!writeBytes(data, length))
            return;
    }
    //     static SerializationReturnCode serialize(JSGlobalObject* lexicalGlobalObject, JSValue value, Vector<RefPtr<MessagePort>>& messagePorts, Vector<RefPtr<JSC::ArrayBuffer>>& arrayBuffers, const Vector<RefPtr<ImageBitmap>>& imageBitmaps,
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         const Vector<RefPtr<OffscreenCanvas>>& offscreenCanvases,
    // #endif
    // #if ENABLE(WEB_RTC)
    //         const Vector<Ref<RTCDataChannel>>& rtcDataChannels,
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>& serializedVideoChunks,
    //         Vector<RefPtr<WebCodecsVideoFrame>>& serializedVideoFrames,
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         WasmModuleArray& wasmModules,
    //         WasmMemoryHandleArray& wasmMemoryHandles,
    // #endif
    //         Vector<URLKeepingBlobAlive>& blobHandles, Vector<uint8_t>& out, SerializationContext context, ArrayBufferContentsArray& sharedBuffers,
    //         SerializationForStorage forStorage)
    //     {
    //         CloneSerializer serializer(lexicalGlobalObject, messagePorts, arrayBuffers, imageBitmaps,
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //             offscreenCanvases,
    // #endif
    // #if ENABLE(WEB_RTC)
    //             rtcDataChannels,
    // #endif
    // #if ENABLE(WEB_CODECS)
    //             serializedVideoChunks,
    //             serializedVideoFrames,
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //             wasmModules,
    //             wasmMemoryHandles,
    // #endif
    //             blobHandles, out, context, sharedBuffers, forStorage);
    //         return serializer.serialize(value);
    //     }

    static SerializationReturnCode serialize(JSGlobalObject* lexicalGlobalObject, JSValue value, Vector<RefPtr<MessagePort>>& messagePorts, Vector<RefPtr<JSC::ArrayBuffer>>& arrayBuffers,
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        const Vector<RefPtr<OffscreenCanvas>>& offscreenCanvases,
#endif
#if ENABLE(WEB_RTC)
        const Vector<Ref<RTCDataChannel>>& rtcDataChannels,
#endif
#if ENABLE(WEB_CODECS)
        Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>& serializedVideoChunks,
        Vector<RefPtr<WebCodecsVideoFrame>>& serializedVideoFrames,
#endif
#if ENABLE(WEBASSEMBLY)
        WasmModuleArray& wasmModules,
        WasmMemoryHandleArray& wasmMemoryHandles,
#endif
        Vector<uint8_t>& out, SerializationContext context, ArrayBufferContentsArray& sharedBuffers,
        SerializationForStorage forStorage, SerializationForCrossProcessTransfer forTransfer, Bun::Bindgen::SharedCloneResources& sharedNativeResources)
    {
        auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
        CloneSerializer serializer(lexicalGlobalObject, messagePorts, arrayBuffers,
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
            offscreenCanvases,
#endif
#if ENABLE(WEB_RTC)
            rtcDataChannels,
#endif
#if ENABLE(WEB_CODECS)
            serializedVideoChunks,
            serializedVideoFrames,
#endif
#if ENABLE(WEBASSEMBLY)
            wasmModules,
            wasmMemoryHandles,
#endif
            out, context, sharedBuffers, forStorage, forTransfer, sharedNativeResources);
        RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
        RELEASE_AND_RETURN(scope, serializer.serialize(value));
    }

    static bool serialize(StringView string, Vector<uint8_t>& out)
    {
        if (!writeLittleEndian(out, CurrentVersion))
            return false;
        if (string.isEmpty())
            return writeLittleEndian<uint8_t>(out, EmptyStringTag);
        if (!writeLittleEndian<uint8_t>(out, StringTag))
            return false;
        const auto length = string.length();
        if (length > (std::numeric_limits<uint32_t>::max() - sizeof(uint32_t)) / sizeof(char16_t))
            return false;
        if (string.is8Bit()) {
            const auto span = string.span8();
            return writeLittleEndian(out, length | StringDataIs8BitFlag)
                && writeLittleEndian(out, span.data(), length);
        }
        const auto span = string.span16();
        return writeLittleEndian(out, length)
            && writeLittleEndian(out, span.data(), length);
    }

private:
    using ObjectPool = CloneConstantPool<JSObject*, PtrHash<JSObject*>>;

    //     CloneSerializer(JSGlobalObject* lexicalGlobalObject, Vector<RefPtr<MessagePort>>& messagePorts, Vector<RefPtr<JSC::ArrayBuffer>>& arrayBuffers, const Vector<RefPtr<ImageBitmap>>& imageBitmaps,
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         const Vector<RefPtr<OffscreenCanvas>>& offscreenCanvases,
    // #endif
    // #if ENABLE(WEB_RTC)
    //         const Vector<Ref<RTCDataChannel>>& rtcDataChannels,
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>& serializedVideoChunks,
    //         Vector<RefPtr<WebCodecsVideoFrame>>& serializedVideoFrames,
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         WasmModuleArray& wasmModules,
    //         WasmMemoryHandleArray& wasmMemoryHandles,
    // #endif
    //         Vector<URLKeepingBlobAlive>& blobHandles, Vector<uint8_t>& out, SerializationContext context, ArrayBufferContentsArray& sharedBuffers, SerializationForStorage forStorage)
    //         : CloneBase(lexicalGlobalObject)
    //         , m_buffer(out)
    //         , m_blobHandles(blobHandles)
    //         , m_emptyIdentifier(Identifier::fromString(lexicalGlobalObject->vm(), emptyString()))
    //         , m_context(context)
    //         , m_sharedBuffers(sharedBuffers)
    // #if ENABLE(WEBASSEMBLY)
    //         , m_wasmModules(wasmModules)
    //         , m_wasmMemoryHandles(wasmMemoryHandles)
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         , m_serializedVideoChunks(serializedVideoChunks)
    //         , m_serializedVideoFrames(serializedVideoFrames)
    // #endif
    //         , m_forStorage(forStorage)
    //     {
    //         write(CurrentVersion);
    //         fillTransferMap(messagePorts, m_transferredMessagePorts);
    //         fillTransferMap(arrayBuffers, m_transferredArrayBuffers);
    //         fillTransferMap(imageBitmaps, m_transferredImageBitmaps);
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         fillTransferMap(offscreenCanvases, m_transferredOffscreenCanvases);
    // #endif
    // #if ENABLE(WEB_RTC)
    //         fillTransferMap(rtcDataChannels, m_transferredRTCDataChannels);
    // #endif
    //     }

    CloneSerializer(JSGlobalObject* lexicalGlobalObject, Vector<RefPtr<MessagePort>>& messagePorts, Vector<RefPtr<JSC::ArrayBuffer>>& arrayBuffers,
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        const Vector<RefPtr<OffscreenCanvas>>& offscreenCanvases,
#endif
#if ENABLE(WEB_RTC)
        const Vector<Ref<RTCDataChannel>>& rtcDataChannels,
#endif
#if ENABLE(WEB_CODECS)
        Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>& serializedVideoChunks,
        Vector<RefPtr<WebCodecsVideoFrame>>& serializedVideoFrames,
#endif
#if ENABLE(WEBASSEMBLY)
        WasmModuleArray& wasmModules,
        WasmMemoryHandleArray& wasmMemoryHandles,
#endif
        Vector<uint8_t>& out, SerializationContext context, ArrayBufferContentsArray& sharedBuffers, SerializationForStorage forStorage, SerializationForCrossProcessTransfer forTransfer, Bun::Bindgen::SharedCloneResources& sharedNativeResources)
        : CloneBase(lexicalGlobalObject)
        , m_buffer(out)
        , m_context(context)
        , m_sharedBuffers(sharedBuffers)
        , m_sharedNativeResources(sharedNativeResources)
#if ENABLE(WEBASSEMBLY)
        , m_wasmModules(wasmModules)
        , m_wasmMemoryHandles(wasmMemoryHandles)
#endif
#if ENABLE(WEB_CODECS)
        , m_serializedVideoChunks(serializedVideoChunks)
        , m_serializedVideoFrames(serializedVideoFrames)
#endif
        , m_forStorage(forStorage)
        , m_forTransfer(forTransfer)
    {
        auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
        write(CurrentVersion);
        fillTransferMap(messagePorts, m_transferredMessagePorts);
        RETURN_IF_EXCEPTION(scope, );
        fillTransferMap(arrayBuffers, m_transferredArrayBuffers);
        RETURN_IF_EXCEPTION(scope, );
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        fillTransferMap(offscreenCanvases, m_transferredOffscreenCanvases);
        RETURN_IF_EXCEPTION(scope, );
#endif
#if ENABLE(WEB_RTC)
        fillTransferMap(rtcDataChannels, m_transferredRTCDataChannels);
        RETURN_IF_EXCEPTION(scope, );
#endif
    }

    template<class T>
    void fillTransferMap(const Vector<T>& input, ObjectPool& result)
    {
        auto scope = DECLARE_THROW_SCOPE(m_lexicalGlobalObject->vm());
        RETURN_IF_EXCEPTION(scope, void());
        if (failed() || input.isEmpty())
            return;
        JSDOMGlobalObject* globalObject = uncheckedDowncast<JSDOMGlobalObject>(m_lexicalGlobalObject);
        for (size_t i = 0; i < input.size(); i++) {
            JSC::JSValue value = toJS(m_lexicalGlobalObject, globalObject, input[i].get());
            RETURN_IF_EXCEPTION(scope, void());
            JSC::JSObject* obj = value.getObject();
            if (obj && !result.find(obj)) {
                if (i > std::numeric_limits<uint32_t>::max()) {
                    fail(SerializationReturnCode::DataCloneError);
                    return;
                }
                if (!result.add(obj, static_cast<uint32_t>(i))) {
                    fail(SerializationReturnCode::OutOfMemoryError);
                    return;
                }
            }
        }
    }

    SerializationReturnCode serialize(JSValue in);

    bool isArray(JSValue value)
    {
        if (!value.isObject())
            return false;
        JSObject* object = asObject(value);
        return object->inherits<JSArray>();
    }

    bool isMap(JSValue value)
    {
        if (!value.isObject())
            return false;
        JSObject* object = asObject(value);
        return object->inherits<JSMap>();
    }
    bool isSet(JSValue value)
    {
        if (!value.isObject())
            return false;
        JSObject* object = asObject(value);
        return object->inherits<JSSet>();
    }

    bool checkForDuplicate(JSObject* object)
    {
        // Record object for graph reconstruction
        auto found = m_objectPool.find(object);

        // Handle duplicate references
        if (found) {
            write(ObjectReferenceTag);
            ASSERT(*found < m_objectPool.size());
            writeObjectIndex(*found);
            return true;
        }

        return false;
    }

    [[nodiscard]] bool retain(JSValue value)
    {
        m_gcBuffer.append(value);
        if (m_gcBuffer.hasOverflowed()) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        return true;
    }

    [[nodiscard]] bool recordObject(JSObject* object)
    {
        if (!retain(object))
            return false;
        if (!m_objectPool.add(object, m_objectPool.size())) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        return true;
    }

    bool startObjectInternal(JSObject* object)
    {
        if (failed() || checkForDuplicate(object))
            return false;
        return recordObject(object);
    }

    bool startObject(JSObject* object)
    {
        if (!startObjectInternal(object))
            return false;
        write(ObjectTag);
        return !failed();
    }

    bool startArray(JSArray* array)
    {
        if (!startObjectInternal(array))
            return false;

        unsigned length = array->length();
        write(ArrayTag);
        write(length);
        return !failed();
    }

    bool startSet(JSSet* set)
    {
        if (!startObjectInternal(set))
            return false;

        write(SetObjectTag);
        return !failed();
    }

    bool startMap(JSMap* map)
    {
        if (!startObjectInternal(map))
            return false;

        write(MapObjectTag);
        return !failed();
    }

    void endObject()
    {
        write(TerminatorTag);
    }

    JSValue getProperty(JSObject* object, const Identifier& propertyName)
    {
        PropertySlot slot(object, PropertySlot::InternalMethodType::Get);
        if (object->methodTable()->getOwnPropertySlot(object, m_lexicalGlobalObject, propertyName, slot))
            return slot.getValue(m_lexicalGlobalObject, propertyName);
        return JSValue();
    }

    void dumpImmediate(JSValue value, SerializationReturnCode& code)
    {
        if (value.isNull()) {
            write(NullTag);
            return;
        }
        if (value.isUndefined()) {
            write(UndefinedTag);
            return;
        }
        if (value.isNumber()) {
            if (value.isInt32()) {
                if (!value.asInt32())
                    write(ZeroTag);
                else if (value.asInt32() == 1)
                    write(OneTag);
                else {
                    write(IntTag);
                    write(static_cast<uint32_t>(value.asInt32()));
                }
            } else {
                write(DoubleTag);
                write(value.asDouble());
            }
            return;
        }
        if (value.isBoolean()) {
            if (value.isTrue())
                write(TrueTag);
            else
                write(FalseTag);
            return;
        }
#if USE(BIGINT32)
        if (value.isBigInt32()) {
            write(BigIntTag);
            dumpBigIntData(value);
            return;
        }
#endif

        // Make any new primitive extension safe by throwing an error.
        code = SerializationReturnCode::DataCloneError;
    }

    void dumpString(const String& string)
    {
        if (string.isEmpty())
            write(EmptyStringTag);
        else {
            write(StringTag);
            write(string);
        }
    }

    void dumpStringObject(const String& string)
    {
        if (string.isEmpty())
            write(EmptyStringObjectTag);
        else {
            write(StringObjectTag);
            write(string);
        }
    }

    void dumpBigIntData(JSValue value)
    {
        ASSERT(value.isBigInt());
#if USE(BIGINT32)
        if (value.isBigInt32()) {
            dumpBigInt32Data(value.bigInt32AsInt32());
            return;
        }
#endif
        dumpHeapBigIntData(uncheckedDowncast<JSBigInt>(value));
    }

#if USE(BIGINT32)
    void dumpBigInt32Data(int32_t integer)
    {
        write(static_cast<uint8_t>(integer < 0));
        if (!integer) {
            write(static_cast<uint32_t>(0)); // Length-in-uint64_t
            return;
        }
        write(static_cast<uint32_t>(1)); // Length-in-uint64_t
        int64_t value = static_cast<int64_t>(integer);
        if (value < 0)
            value = -value;
        write(static_cast<uint64_t>(value));
    }
#endif

    void dumpHeapBigIntData(JSBigInt* bigInt)
    {
        write(static_cast<uint8_t>(bigInt->sign()));
        if constexpr (sizeof(JSBigInt::Digit) == sizeof(uint64_t)) {
            write(static_cast<uint32_t>(bigInt->length()));
            for (unsigned index = 0; index < bigInt->length(); ++index)
                write(static_cast<uint64_t>(bigInt->digit(index)));
        } else {
            ASSERT(sizeof(JSBigInt::Digit) == sizeof(uint32_t));
            uint32_t lengthInUint64 = bigInt->length() / 2;
            if (bigInt->length() & 0x1)
                ++lengthInUint64;
            write(lengthInUint64);
            uint64_t value = 0;
            for (unsigned index = 0; index < bigInt->length(); ++index) {
                if (!(index & 0x1))
                    value = bigInt->digit(index);
                else {
                    value = (static_cast<uint64_t>(bigInt->digit(index)) << 32) | value;
                    write(static_cast<uint64_t>(value));
                    value = 0;
                }
            }
            if (bigInt->length() & 0x1)
                write(static_cast<uint64_t>(value));
        }
    }

    JSC::JSValue toJSArrayBuffer(ArrayBuffer& arrayBuffer)
    {
        auto& vm = m_lexicalGlobalObject->vm();
        auto* globalObject = m_lexicalGlobalObject;
        if (globalObject->inherits<JSDOMGlobalObject>())
            return toJS(globalObject, uncheckedDowncast<JSDOMGlobalObject>(globalObject), &arrayBuffer);

        if (auto* buffer = arrayBuffer.m_wrapper.get())
            return buffer;

        return JSC::JSArrayBuffer::create(vm, globalObject->arrayBufferStructure(arrayBuffer.sharingMode()), &arrayBuffer);
    }

    bool dumpArrayBufferView(JSObject* obj, SerializationReturnCode& code)
    {
        VM& vm = m_lexicalGlobalObject->vm();
        write(ArrayBufferViewTag);
        if (obj->inherits<JSDataView>())
            write(DataViewTag);
        else if (obj->inherits<JSUint8ClampedArray>())
            write(Uint8ClampedArrayTag);
        else if (obj->inherits<JSInt8Array>())
            write(Int8ArrayTag);
        else if (obj->inherits<JSUint8Array>())
            write(Uint8ArrayTag);
        else if (obj->inherits<JSInt16Array>())
            write(Int16ArrayTag);
        else if (obj->inherits<JSUint16Array>())
            write(Uint16ArrayTag);
        else if (obj->inherits<JSInt32Array>())
            write(Int32ArrayTag);
        else if (obj->inherits<JSUint32Array>())
            write(Uint32ArrayTag);
        else if (obj->inherits<JSFloat16Array>())
            write(Float16ArrayTag);
        else if (obj->inherits<JSFloat32Array>())
            write(Float32ArrayTag);
        else if (obj->inherits<JSFloat64Array>())
            write(Float64ArrayTag);
        else if (obj->inherits<JSBigInt64Array>())
            write(BigInt64ArrayTag);
        else if (obj->inherits<JSBigUint64Array>())
            write(BigUint64ArrayTag);
        else
            return false;

        if (uncheckedDowncast<JSArrayBufferView>(obj)->isOutOfBounds()) [[unlikely]] {
            code = SerializationReturnCode::DataCloneError;
            return true;
        }

        RefPtr<ArrayBufferView> arrayBufferView = toPossiblySharedArrayBufferView(vm, obj);
        if (arrayBufferView->isResizableOrGrowableShared()) {
            uint64_t byteOffset = arrayBufferView->byteOffsetRaw();
            write(byteOffset);
            uint64_t byteLength = arrayBufferView->byteLengthRaw();
            if (arrayBufferView->isAutoLength())
                byteLength = autoLengthMarker;
            write(byteLength);
        } else {
            uint64_t byteOffset = arrayBufferView->byteOffset();
            write(byteOffset);
            uint64_t byteLength = arrayBufferView->byteLength();
            write(byteLength);
        }
        RefPtr<ArrayBuffer> arrayBuffer = arrayBufferView->possiblySharedBuffer();
        if (!arrayBuffer) {
            code = SerializationReturnCode::ValidationError;
            return true;
        }

        return dumpIfTerminal(toJSArrayBuffer(*arrayBuffer), code);
    }

    // void dumpDOMPoint(const DOMPointReadOnly& point)
    // {
    //     write(point.x());
    //     write(point.y());
    //     write(point.z());
    //     write(point.w());
    // }

    // void dumpDOMPoint(JSObject* obj)
    // {
    //     if (obj->inherits<JSDOMPoint>())
    //         write(DOMPointTag);
    //     else
    //         write(DOMPointReadOnlyTag);

    //     dumpDOMPoint(uncheckedDowncast<JSDOMPointReadOnly>(obj)->wrapped());
    // }

    // void dumpDOMRect(JSObject* obj)
    // {
    //     if (obj->inherits<JSDOMRect>())
    //         write(DOMRectTag);
    //     else
    //         write(DOMRectReadOnlyTag);

    //     auto& rect = uncheckedDowncast<JSDOMRectReadOnly>(obj)->wrapped();
    //     write(rect.x());
    //     write(rect.y());
    //     write(rect.width());
    //     write(rect.height());
    // }

    // void dumpDOMMatrix(JSObject* obj)
    // {
    //     if (obj->inherits<JSDOMMatrix>())
    //         write(DOMMatrixTag);
    //     else
    //         write(DOMMatrixReadOnlyTag);

    //     auto& matrix = uncheckedDowncast<JSDOMMatrixReadOnly>(obj)->wrapped();
    //     bool is2D = matrix.is2D();
    //     write(static_cast<uint8_t>(is2D));
    //     if (is2D) {
    //         write(matrix.m11());
    //         write(matrix.m12());
    //         write(matrix.m21());
    //         write(matrix.m22());
    //         write(matrix.m41());
    //         write(matrix.m42());
    //     } else {
    //         write(matrix.m11());
    //         write(matrix.m12());
    //         write(matrix.m13());
    //         write(matrix.m14());
    //         write(matrix.m21());
    //         write(matrix.m22());
    //         write(matrix.m23());
    //         write(matrix.m24());
    //         write(matrix.m31());
    //         write(matrix.m32());
    //         write(matrix.m33());
    //         write(matrix.m34());
    //         write(matrix.m41());
    //         write(matrix.m42());
    //         write(matrix.m43());
    //         write(matrix.m44());
    //     }
    // }

    // void dumpDOMQuad(JSObject* obj)
    // {
    //     write(DOMQuadTag);

    //     auto& quad = uncheckedDowncast<JSDOMQuad>(obj)->wrapped();
    //     dumpDOMPoint(quad.p1());
    //     dumpDOMPoint(quad.p2());
    //     dumpDOMPoint(quad.p3());
    //     dumpDOMPoint(quad.p4());
    // }

    // void dumpImageBitmap(JSObject* obj, SerializationReturnCode& code)
    // {
    //     auto index = m_transferredImageBitmaps.find(obj);
    //     if (index != m_transferredImageBitmaps.end()) {
    //         write(ImageBitmapTransferTag);
    //         write(index->value);
    //         return;
    //     }

    //     auto& imageBitmap = uncheckedDowncast<JSImageBitmap>(obj)->wrapped();
    //     if (!imageBitmap.originClean()) {
    //         code = SerializationReturnCode::DataCloneError;
    //         return;
    //     }

    //     auto* buffer = imageBitmap.buffer();
    //     if (!buffer) {
    //         code = SerializationReturnCode::ValidationError;
    //         return;
    //     }

    //     // FIXME: We should try to avoid converting pixel format.
    //     PixelBufferFormat format { AlphaPremultiplication::Premultiplied, PixelFormat::RGBA8, buffer->colorSpace() };
    //     const IntSize& logicalSize = buffer->truncatedLogicalSize();
    //     auto pixelBuffer = buffer->getPixelBuffer(format, { IntPoint::zero(), logicalSize });
    //     if (!is<ByteArrayPixelBuffer>(pixelBuffer)) {
    //         code = SerializationReturnCode::ValidationError;
    //         return;
    //     }

    //     auto arrayBuffer = downcast<ByteArrayPixelBuffer>(*pixelBuffer).data().possiblySharedBuffer();
    //     if (!arrayBuffer) {
    //         code = SerializationReturnCode::ValidationError;
    //         return;
    //     }

    //     write(ImageBitmapTag);
    //     write(static_cast<uint8_t>(imageBitmap.serializationState().toRaw()));
    //     write(static_cast<int32_t>(logicalSize.width()));
    //     write(static_cast<int32_t>(logicalSize.height()));
    //     write(static_cast<double>(buffer->resolutionScale()));
    //     write(buffer->colorSpace());

    //     CheckedUint32 byteLength = arrayBuffer->byteLength();
    //     if (byteLength.hasOverflowed()) {
    //         code = SerializationReturnCode::ValidationError;
    //         return;
    //     }
    //     write(byteLength);
    //     write(static_cast<const uint8_t*>(arrayBuffer->data()), byteLength);
    // }

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    void dumpOffscreenCanvas(JSObject* obj, SerializationReturnCode& code)
    {
        auto index = m_transferredOffscreenCanvases.find(obj);
        if (index) {
            write(OffscreenCanvasTransferTag);
            write(*index);
            return;
        }

        code = SerializationReturnCode::DataCloneError;
    }
#endif

#if ENABLE(WEB_RTC)
    void dumpRTCDataChannel(JSObject* obj, SerializationReturnCode& code)
    {
        auto index = m_transferredRTCDataChannels.find(obj);
        if (index) {
            write(RTCDataChannelTransferTag);
            write(*index);
            return;
        }

        code = SerializationReturnCode::DataCloneError;
    }
#endif
#if ENABLE(WEB_CODECS)
    void dumpWebCodecsEncodedVideoChunk(JSObject* obj)
    {
        auto& videoChunk = uncheckedDowncast<JSWebCodecsEncodedVideoChunk>(obj)->wrapped();

        auto index = m_serializedVideoChunks.find(&videoChunk.storage());
        if (index == notFound) {
            index = m_serializedVideoChunks.size();
            m_serializedVideoChunks.append(&videoChunk.storage());
        }

        write(WebCodecsEncodedVideoChunkTag);
        write(static_cast<uint32_t>(index));
    }

    bool dumpWebCodecsVideoFrame(JSObject* obj)
    {
        Ref videoFrame = uncheckedDowncast<JSWebCodecsVideoFrame>(obj)->wrapped();
        if (videoFrame->isDetached())
            return false;

        auto index = m_serializedVideoFrames.find(videoFrame.ptr());
        if (index == notFound) {
            index = m_serializedVideoChunks.size();
            m_serializedVideoFrames.append(WTF::move(videoFrame));
        }
        write(WebCodecsVideoFrameTag);
        write(static_cast<uint32_t>(index));
        return true;
    }
#endif

    void dumpDOMException(JSObject* obj, SerializationReturnCode& code)
    {
        if (auto* exception = JSDOMException::toWrapped(m_lexicalGlobalObject->vm(), obj)) {
            write(DOMExceptionTag);
            write(exception->message());
            write(exception->name());
            return;
        }

        code = SerializationReturnCode::DataCloneError;
    }

    bool dumpIfTerminal(JSValue value, SerializationReturnCode& code)
    {
        if (failed()) {
            code = m_failure;
            return true;
        }
        bool result = dumpTerminal(value, code);
        if (failed()) {
            code = m_failure;
            return true;
        }
        return result;
    }

    bool dumpTerminal(JSValue value, SerializationReturnCode& code)
    {
        if (!value.isCell()) {
            dumpImmediate(value, code);
            return true;
        }
        ASSERT(value.isCell());

        if (value.isString()) {
            dumpString(asString(value)->value(m_lexicalGlobalObject));
            return true;
        }

        if (value.isHeapBigInt()) {
            write(BigIntTag);
            dumpBigIntData(value);
            return true;
        }

        if (value.isSymbol()) {
            code = SerializationReturnCode::DataCloneError;
            return true;
        }

        VM& vm = m_lexicalGlobalObject->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        if (isArray(value))
            return false;

        if (value.isObject()) {
            auto* obj = asObject(value);
            if (auto* dateObject = dynamicDowncast<DateInstance>(obj)) {
                write(DateTag);
                write(dateObject->internalNumber());
                return true;
            }
            if (auto* booleanObject = dynamicDowncast<BooleanObject>(obj)) {
                if (!startObjectInternal(booleanObject)) // handle duplicates
                    return true;
                write(booleanObject->internalValue().toBoolean(m_lexicalGlobalObject) ? TrueObjectTag : FalseObjectTag);
                return true;
            }
            if (auto* stringObject = dynamicDowncast<StringObject>(obj)) {
                if (!startObjectInternal(stringObject)) // handle duplicates
                    return true;
                String str = asString(stringObject->internalValue())->value(m_lexicalGlobalObject);
                if (scope.exception()) {
                    code = SerializationReturnCode::ExistingExceptionError;
                    return true;
                }
                dumpStringObject(str);
                return true;
            }
            if (auto* numberObject = dynamicDowncast<NumberObject>(obj)) {
                if (!startObjectInternal(numberObject)) // handle duplicates
                    return true;
                write(NumberObjectTag);
                write(numberObject->internalValue().asNumber());
                return true;
            }
            if (auto* bigIntObject = dynamicDowncast<BigIntObject>(obj)) {
                if (!startObjectInternal(bigIntObject)) // handle duplicates
                    return true;
                JSValue bigIntValue = bigIntObject->internalValue();
                ASSERT(bigIntValue.isBigInt());
                write(BigIntObjectTag);
                dumpBigIntData(bigIntValue);
                return true;
            }
            // if (auto* file = JSFile::toWrapped(vm, obj)) {
            //     write(FileTag);
            //     write(*file);
            //     return true;
            // }
            // if (auto* list = JSFileList::toWrapped(vm, obj)) {
            //     write(FileListTag);
            //     write(list->length());
            //     for (auto& file : list->files())
            //         write(file.get());
            //     return true;
            // }

            // if (auto* data = JSImageData::toWrapped(vm, obj)) {
            //     write(ImageDataTag);
            //     auto addResult = m_imageDataPool.add(*data, m_imageDataPool.size());
            //     if (!addResult.isNewEntry) {
            //         write(ImageDataPoolTag);
            //         writeImageDataIndex(addResult.iterator->value);
            //         return true;
            //     }
            //     write(static_cast<uint32_t>(data->width()));
            //     write(static_cast<uint32_t>(data->height()));
            //     CheckedUint32 dataLength = data->data().length();
            //     if (dataLength.hasOverflowed()) {
            //         code = SerializationReturnCode::DataCloneError;
            //         return true;
            //     }
            //     write(dataLength);
            //     write(data->data().data(), dataLength);
            //     write(data->colorSpace());
            //     return true;
            // }
            if (auto* regExp = dynamicDowncast<RegExpObject>(obj)) {
                write(RegExpTag);
                write(regExp->regExp()->pattern());
                write(String::fromLatin1(JSC::Yarr::flagsString(regExp->regExp()->flags()).data()));
                return true;
            }
            if (auto* errorInstance = dynamicDowncast<ErrorInstance>(obj)) {
                auto& vm = m_lexicalGlobalObject->vm();
                auto errorTypeValue = errorInstance->get(m_lexicalGlobalObject, vm.propertyNames->name);
                RETURN_IF_EXCEPTION(scope, false);
                auto errorTypeString = errorTypeValue.toWTFString(m_lexicalGlobalObject);
                RETURN_IF_EXCEPTION(scope, false);

                String message;
                PropertyDescriptor messageDescriptor;
                if (errorInstance->getOwnPropertyDescriptor(m_lexicalGlobalObject, vm.propertyNames->message, messageDescriptor) && messageDescriptor.isDataDescriptor()) {
                    scope.assertNoException();
                    message = messageDescriptor.value().toWTFString(m_lexicalGlobalObject);
                }
                RETURN_IF_EXCEPTION(scope, false);

                unsigned line = 0;
                PropertyDescriptor lineDescriptor;
                if (errorInstance->getOwnPropertyDescriptor(m_lexicalGlobalObject, vm.propertyNames->line, lineDescriptor) && lineDescriptor.isDataDescriptor()) {
                    scope.assertNoException();
                    line = lineDescriptor.value().toNumber(m_lexicalGlobalObject);
                }
                RETURN_IF_EXCEPTION(scope, false);

                unsigned column = 0;
                PropertyDescriptor columnDescriptor;
                if (errorInstance->getOwnPropertyDescriptor(m_lexicalGlobalObject, vm.propertyNames->column, columnDescriptor) && columnDescriptor.isDataDescriptor()) {
                    scope.assertNoException();
                    column = columnDescriptor.value().toNumber(m_lexicalGlobalObject);
                }
                RETURN_IF_EXCEPTION(scope, false);

                String sourceURL;
                PropertyDescriptor sourceURLDescriptor;
                if (errorInstance->getOwnPropertyDescriptor(m_lexicalGlobalObject, vm.propertyNames->sourceURL, sourceURLDescriptor) && sourceURLDescriptor.isDataDescriptor()) {
                    scope.assertNoException();
                    sourceURL = sourceURLDescriptor.value().toWTFString(m_lexicalGlobalObject);
                }
                RETURN_IF_EXCEPTION(scope, false);

                String stack;
                PropertyDescriptor stackDescriptor;
                if (errorInstance->getOwnPropertyDescriptor(m_lexicalGlobalObject, vm.propertyNames->stack, stackDescriptor) && stackDescriptor.isDataDescriptor()) {
                    scope.assertNoException();
                    stack = stackDescriptor.value().toWTFString(m_lexicalGlobalObject);
                }
                RETURN_IF_EXCEPTION(scope, false);

                write(ErrorInstanceTag);
                write(errorNameToSerializableErrorType(errorTypeString));
                writeNullableString(message);
                write(line);
                write(column);
                writeNullableString(sourceURL);
                writeNullableString(stack);
                return true;
            }
            if (obj->inherits<JSMessagePort>()) {
                auto index = m_transferredMessagePorts.find(obj);
                if (index) {
                    write(MessagePortReferenceTag);
                    write(*index);
                    return true;
                }
                // MessagePort object could not be found in transferred message ports
                code = SerializationReturnCode::ValidationError;
                return true;
            }
            if (auto* arrayBuffer = toPossiblySharedArrayBuffer(vm, obj)) {
                if (arrayBuffer->isDetached()) {
                    code = SerializationReturnCode::ValidationError;
                    return true;
                }
                auto index = m_transferredArrayBuffers.find(obj);
                if (index) {
                    write(ArrayBufferTransferTag);
                    write(*index);
                    return true;
                }
                if (!startObjectInternal(obj)) // handle duplicates
                    return true;

                if (arrayBuffer->isShared() && m_context == SerializationContext::WorkerPostMessage) {
                    // https://html.spec.whatwg.org/multipage/structured-data.html#structuredserializeinternal
                    if (!JSC::Options::useSharedArrayBuffer()) {
                        code = SerializationReturnCode::DataCloneError;
                        return true;
                    }
                    auto index = m_sharedBuffers.size();
                    ArrayBufferContents contents;
                    if (arrayBuffer->shareWith(contents)) {
                        if (index > std::numeric_limits<uint32_t>::max()) {
                            fail(SerializationReturnCode::DataCloneError);
                            return true;
                        }
                        if (!m_sharedBuffers.tryAppend(WTF::move(contents))) {
                            fail(SerializationReturnCode::OutOfMemoryError);
                            return true;
                        }
                        write(SharedArrayBufferTag);
                        write(static_cast<uint32_t>(index));
                        return true;
                    }
                }

                if (arrayBuffer->isResizableOrGrowableShared()) {
                    uint64_t byteLength = arrayBuffer->byteLength();
                    write(ResizableArrayBufferTag);
                    write(byteLength);
                    uint64_t maxByteLength = arrayBuffer->maxByteLength().value_or(0);
                    write(maxByteLength);
                    write(static_cast<const uint8_t*>(arrayBuffer->data()), byteLength);
                    return true;
                }

                uint64_t byteLength = arrayBuffer->byteLength();
                write(ArrayBufferTag);
                write(byteLength);
                write(static_cast<const uint8_t*>(arrayBuffer->data()), byteLength);
                return true;
            }
            if (obj->inherits<JSArrayBufferView>()) {
                if (checkForDuplicate(obj))
                    return true;
                bool success = dumpArrayBufferView(obj, code);
                RETURN_IF_EXCEPTION(scope, false);
                if (!recordObject(obj))
                    return true;
                return success;
            }

#if ENABLE(WEB_RTC)
            if (auto* rtcCertificate = JSRTCCertificate::toWrapped(vm, obj)) {
                write(RTCCertificateTag);
                write(rtcCertificate->expires());
                write(rtcCertificate->pemCertificate());
                write(rtcCertificate->origin().toString());
                write(rtcCertificate->pemPrivateKey());
                write(static_cast<unsigned>(rtcCertificate->getFingerprints().size()));
                for (const auto& fingerprint : rtcCertificate->getFingerprints()) {
                    write(fingerprint.algorithm);
                    write(fingerprint.value);
                }
                return true;
            }
#endif
#if ENABLE(WEBASSEMBLY)
            if (JSWebAssemblyModule* module = dynamicDowncast<JSWebAssemblyModule>(obj)) {
                if (m_context != SerializationContext::WorkerPostMessage && m_context != SerializationContext::WindowPostMessage)
                    return false;

                auto index = m_wasmModules.size();
                if (index > std::numeric_limits<uint32_t>::max()) {
                    fail(SerializationReturnCode::DataCloneError);
                    return true;
                }
                if (!m_wasmModules.tryAppend(&module->module())) {
                    fail(SerializationReturnCode::OutOfMemoryError);
                    return true;
                }
                write(WasmModuleTag);
                write(agentClusterIDFromGlobalObject(*m_lexicalGlobalObject));
                write(static_cast<uint32_t>(index));
                return true;
            }
            if (JSWebAssemblyMemory* memory = dynamicDowncast<JSWebAssemblyMemory>(obj)) {
                if (!JSC::Options::useSharedArrayBuffer() || memory->memory().sharingMode() != JSC::MemorySharingMode::Shared) {
                    code = SerializationReturnCode::DataCloneError;
                    return true;
                }
                if (m_context != SerializationContext::WorkerPostMessage) {
                    code = SerializationReturnCode::DataCloneError;
                    return true;
                }
                auto index = m_wasmMemoryHandles.size();
                if (index > std::numeric_limits<uint32_t>::max()) {
                    fail(SerializationReturnCode::DataCloneError);
                    return true;
                }
                if (!m_wasmMemoryHandles.tryAppend(memory->memory().shared())) {
                    fail(SerializationReturnCode::OutOfMemoryError);
                    return true;
                }
                write(WasmMemoryTag);
                write(agentClusterIDFromGlobalObject(*m_lexicalGlobalObject));
                write(static_cast<uint32_t>(index));
                return true;
            }
#endif
            // if (obj->inherits<JSDOMPointReadOnly>()) {
            //     dumpDOMPoint(obj);
            //     return true;
            // }
            // if (obj->inherits<JSDOMRectReadOnly>()) {
            //     dumpDOMRect(obj);
            //     return true;
            // }
            // if (obj->inherits<JSDOMMatrixReadOnly>()) {
            //     dumpDOMMatrix(obj);
            //     return true;
            // }
            // if (obj->inherits<JSDOMQuad>()) {
            //     dumpDOMQuad(obj);
            //     return true;
            // }
            // if (obj->inherits<JSImageBitmap>()) {
            //     dumpImageBitmap(obj, code);
            //     return true;
            // }
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
            if (obj->inherits<JSOffscreenCanvas>()) {
                dumpOffscreenCanvas(obj, code);
                return true;
            }
#endif
#if ENABLE(WEB_RTC)
            if (obj->inherits<JSRTCDataChannel>()) {
                dumpRTCDataChannel(obj, code);
                return true;
            }
#endif
            if (obj->inherits<JSDOMException>()) {
                dumpDOMException(obj, code);
                return true;
            }
#if ENABLE(WEB_CODECS)
            if (obj->inherits<JSWebCodecsEncodedVideoChunk>()) {
                if (m_forStorage == SerializationForStorage::Yes)
                    return false;
                dumpWebCodecsEncodedVideoChunk(obj);
                return true;
            }
            if (obj->inherits<JSWebCodecsVideoFrame>()) {
                if (m_forStorage == SerializationForStorage::Yes)
                    return false;
                return dumpWebCodecsVideoFrame(obj);
            }
#endif

            StructuredCloneableSerialize cloneable;
            if (Bun::bindgenStructuredCloneSerialize(value, cloneable)) {
                if ((m_forTransfer == SerializationForCrossProcessTransfer::Yes && !cloneable.isForTransfer)
                    || (m_forStorage == SerializationForStorage::Yes && !cloneable.isForStorage)) {
                    if (cloneable.unsupportedContext == StructuredCloneableSerialize::UnsupportedContext::Reject)
                        code = SerializationReturnCode::DataCloneError;
                    else if (startObject(obj))
                        write(TerminatorTag);
                    return true;
                }
                if (!startObjectInternal(obj))
                    return true;
                write(cloneable.tag);
                if (!failed())
                    cloneable.write(this, m_lexicalGlobalObject);
                if (scope.exception()) {
                    code = SerializationReturnCode::ExistingExceptionError;
                    return true;
                }
                return true;
            }

            if (auto* x509 = dynamicDowncast<Bun::JSX509Certificate>(obj)) {
                write(Bun__X509CertificateTag);
                X509* cert = x509->m_x509.get();

                // Get the size needed for the DER encoding
                int size = i2d_X509(cert, nullptr);
                if (size <= 0)
                    return false;

                Vector<uint8_t> der;
                if (!der.tryGrow(size)) {
                    fail(SerializationReturnCode::OutOfMemoryError);
                    return true;
                }

                // Get pointer to where we should write
                unsigned char* der_ptr = der.begin();

                // Write the DER encoding
                if (i2d_X509(cert, &der_ptr) != size) {
                    return false;
                }

                write(der);

                return true;
            }

            if (auto* keyObject = dynamicDowncast<Bun::JSKeyObject>(obj)) {
                write(Bun__KeyObjectTag);

                auto& handle = keyObject->handle();

                write(static_cast<uint8_t>(handle.type()));

                switch (handle.type()) {
                case CryptoKeyType::Secret: {
                    write(handle.symmetricKey());
                    return true;
                }
                case CryptoKeyType::Public:
                case CryptoKeyType::Private: {
                    auto* pkey = handle.asymmetricKey().get();
                    ncrypto::ClearErrorOnReturn clearError;
                    auto bio = ncrypto::BIOPointer::NewMem();
                    if (!bio) {
                        code = SerializationReturnCode::OutOfMemoryError;
                        return true;
                    }
                    bool written = handle.type() == CryptoKeyType::Public
                        ? PEM_write_bio_PUBKEY(bio.get(), pkey)
                        : PEM_write_bio_PrivateKey(bio.get(), pkey, nullptr, nullptr, 0, nullptr, nullptr);
                    if (!written) {
                        code = cryptoSerializationFailure(SerializationReturnCode::DataCloneError);
                        return true;
                    }

                    const uint8_t* pemData = nullptr;
                    size_t pemSize = 0;
                    if (!BIO_mem_contents(bio.get(), &pemData, &pemSize)) {
                        code = cryptoSerializationFailure(SerializationReturnCode::DataCloneError);
                        return true;
                    }

                    write(static_cast<uint64_t>(pemSize));
                    write(pemData, pemSize);

                    return true;
                }
                }
            }

            if (auto* histogram = dynamicDowncast<Bun::JSNodePerformanceHooksHistogram>(obj)) {
                if (m_context != SerializationContext::WorkerPostMessage && m_context != SerializationContext::WindowPostMessage) {
                    // Don't allow cloning of histograms if it's not a simple .postMessage().
                    code = SerializationReturnCode::DataCloneError;
                    return true;
                }

                // Serialize histogram configuration
                hdr_histogram* hdr = histogram->m_histogramData.histogram;
                if (!hdr) {
                    // Histogram is not initialized
                    code = SerializationReturnCode::DataCloneError;
                    return true;
                }

                write(Bun__NodePerformanceHooksHistogramTag);
                // TODO: write the index into the histograms vector on SerializedScriptValue
                // make it ThreadSafeRefCounted
                // and then we can just write the index
                code = SerializationReturnCode::DataCloneError;

                return true;
            }

            return false;
        }
        code = SerializationReturnCode::DataCloneError;
        return true;
    }

    bool failed() const
    {
        return m_failure != SerializationReturnCode::SuccessfullyCompleted;
    }

    void fail(SerializationReturnCode failure)
    {
        ASSERT(failure != SerializationReturnCode::SuccessfullyCompleted);
        if (!failed())
            m_failure = failure;
    }

    bool prepareWrite(uint64_t length)
    {
        if (failed())
            return false;
        if (length > std::numeric_limits<size_t>::max() - m_buffer.size()
            || !WTF::isValidCapacityForVector<uint8_t>(m_buffer.size() + static_cast<size_t>(length))) {
            fail(SerializationReturnCode::DataCloneError);
            return false;
        }
        return true;
    }

    template<typename T> void writeInteger(T value)
    {
        if (prepareWrite(sizeof(T)) && !writeLittleEndian(m_buffer, value))
            fail(SerializationReturnCode::OutOfMemoryError);
    }

    void write(SerializationTag tag)
    {
        write(static_cast<uint8_t>(tag));
    }

    void write(ArrayBufferViewSubtag tag)
    {
        write(static_cast<uint8_t>(tag));
    }

    void write(DestinationColorSpaceTag tag)
    {
        write(static_cast<uint8_t>(tag));
    }

    void write(bool b)
    {
        write(static_cast<int32_t>(b));
    }

    void write(uint8_t c)
    {
        writeInteger(c);
    }

    void write(uint32_t i)
    {
        writeInteger(i);
    }

    void write(double d)
    {
        write(std::bit_cast<uint64_t>(d));
    }

    void write(int32_t i)
    {
        writeInteger(i);
    }

    void write(uint64_t i)
    {
        writeInteger(i);
    }

    void write(uint16_t ch)
    {
        writeInteger(ch);
    }

    void writeStringIndex(unsigned i)
    {
        writeConstantPoolIndex(m_constantPool, i);
    }

    // void writeImageDataIndex(unsigned i)
    // {
    //     writeConstantPoolIndex(m_imageDataPool, i);
    // }

    void writeObjectIndex(unsigned i)
    {
        writeConstantPoolIndex(m_objectPool, i);
    }

    template<class T> void writeConstantPoolIndex(const T& constantPool, unsigned i)
    {
        ASSERT(i < constantPool.size());
        if (constantPool.size() <= 0xFF)
            write(static_cast<uint8_t>(i));
        else if (constantPool.size() <= 0xFFFF)
            write(static_cast<uint16_t>(i));
        else
            write(static_cast<uint32_t>(i));
    }

    void write(const Identifier& ident)
    {
        write(ident.string());
    }

    void write(const String& string)
    {
        if (failed())
            return;
        const String& str = string.isNull() ? emptyString() : string;
        if (auto index = m_constantPool.find(str.impl())) {
            write(StringPoolTag);
            writeStringIndex(*index);
            return;
        }
        if (!m_constantPool.add(str.impl(), m_constantPool.size())) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return;
        }

        unsigned length = str.length();

        // Guard against overflow
        if (length > (std::numeric_limits<uint32_t>::max() - sizeof(uint32_t)) / sizeof(char16_t)) {
            fail(SerializationReturnCode::DataCloneError);
            return;
        }

        if (str.is8Bit())
            write(static_cast<uint32_t>(length | StringDataIs8BitFlag));
        else
            write(static_cast<uint32_t>(length));

        if (!length || !prepareWrite(uint64_t { length } * (str.is8Bit() ? sizeof(uint8_t) : sizeof(char16_t))))
            return;
        if (str.is8Bit()) {
            if (!writeLittleEndian(m_buffer, str.span8().data(), length))
                fail(SerializationReturnCode::OutOfMemoryError);
            return;
        }
        if (!writeLittleEndian(m_buffer, str.span16().data(), length))
            fail(SerializationReturnCode::OutOfMemoryError);
    }

    void writeNullableString(const String& str)
    {
        bool isNull = str.isNull();
        write(isNull);
        if (!isNull)
            write(str);
    }

    void write(const Vector<uint8_t>& vector)
    {
        if (vector.size() > std::numeric_limits<uint32_t>::max()) {
            fail(SerializationReturnCode::DataCloneError);
            return;
        }
        write(static_cast<uint32_t>(vector.size()));
        write(vector.span().data(), vector.size());
    }

    // void write(const File& file)
    // {
    //     m_blobHandles.append(file.handle().isolatedCopy());
    //     write(file.path());
    //     write(file.url().string());
    //     write(file.type());
    //     write(file.name());
    //     write(static_cast<double>(file.lastModifiedOverride().value_or(-1)));
    // }

    //     void write(PredefinedColorSpace colorSpace)
    //     {
    //         switch (colorSpace) {
    //         case PredefinedColorSpace::SRGB:
    //             writeLittleEndian<uint8_t>(m_buffer, static_cast<uint8_t>(PredefinedColorSpaceTag::SRGB));
    //             break;
    // #if ENABLE(PREDEFINED_COLOR_SPACE_DISPLAY_P3)
    //         case PredefinedColorSpace::DisplayP3:
    //             writeLittleEndian<uint8_t>(m_buffer, static_cast<uint8_t>(PredefinedColorSpaceTag::DisplayP3));
    //             break;
    // #endif
    //         }
    //     }

#if PLATFORM(COCOA)
    void write(const RetainPtr<CFDataRef>& data)
    {
        uint32_t dataLength = CFDataGetLength(data.get());
        write(dataLength);
        write(CFDataGetBytePtr(data.get()), dataLength);
    }
#endif

    //     void write(DestinationColorSpace destinationColorSpace)
    //     {
    //         if (destinationColorSpace == DestinationColorSpace::SRGB()) {
    //             write(DestinationColorSpaceSRGBTag);
    //             return;
    //         }

    // #if ENABLE(DESTINATION_COLOR_SPACE_LINEAR_SRGB)
    //         if (destinationColorSpace == DestinationColorSpace::LinearSRGB()) {
    //             write(DestinationColorSpaceLinearSRGBTag);
    //             return;
    //         }
    // #endif

    // #if ENABLE(DESTINATION_COLOR_SPACE_DISPLAY_P3)
    //         if (destinationColorSpace == DestinationColorSpace::DisplayP3()) {
    //             write(DestinationColorSpaceDisplayP3Tag);
    //             return;
    //         }
    // #endif

    // #if PLATFORM(COCOA)
    //         auto colorSpace = destinationColorSpace.platformColorSpace();

    //         if (auto name = CGColorSpaceGetName(colorSpace)) {
    //             auto data = adoptCF(CFStringCreateExternalRepresentation(nullptr, name, kCFStringEncodingUTF8, 0));
    //             if (!data) {
    //                 write(DestinationColorSpaceSRGBTag);
    //                 return;
    //             }

    //             write(DestinationColorSpaceCGColorSpaceNameTag);
    //             write(data);
    //             return;
    //         }

    //         if (auto propertyList = adoptCF(CGColorSpaceCopyPropertyList(colorSpace))) {
    //             auto data = adoptCF(CFPropertyListCreateData(nullptr, propertyList.get(), kCFPropertyListBinaryFormat_v1_0, 0, nullptr));
    //             if (!data) {
    //                 write(DestinationColorSpaceSRGBTag);
    //                 return;
    //             }

    //             write(DestinationColorSpaceCGColorSpacePropertyListTag);
    //             write(data);
    //             return;
    //         }
    // #endif

    //         ASSERT_NOT_REACHED();
    //         write(DestinationColorSpaceSRGBTag);
    //     }

    void write(SerializableErrorType errorType)
    {
        write(std::to_underlying(errorType));
    }

    // Vector<URLKeepingBlobAlive>& m_blobHandles;
    MarkedArgumentBuffer m_gcBuffer;
    ObjectPool m_objectPool;
    ObjectPool m_transferredMessagePorts;
    ObjectPool m_transferredArrayBuffers;
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    ObjectPool m_transferredOffscreenCanvases;
#endif
#if ENABLE(WEB_RTC)
    ObjectPool m_transferredRTCDataChannels;
#endif
    using StringConstantPool = CloneConstantPool<RefPtr<StringImpl>, StringHash>;
    StringConstantPool m_constantPool;
    // using ImageDataPool = HashMap<Ref<ImageData>, uint32_t>;
    // ImageDataPool m_imageDataPool;
    Vector<uint8_t>& m_buffer;
    SerializationReturnCode m_failure { SerializationReturnCode::SuccessfullyCompleted };
    SerializationContext m_context;
    ArrayBufferContentsArray& m_sharedBuffers;
    Bun::Bindgen::SharedCloneResources& m_sharedNativeResources;
#if ENABLE(WEBASSEMBLY)
    WasmModuleArray& m_wasmModules;
    WasmMemoryHandleArray& m_wasmMemoryHandles;
#endif
#if ENABLE(WEB_CODECS)
    Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>& m_serializedVideoChunks;
    Vector<RefPtr<WebCodecsVideoFrame>>& m_serializedVideoFrames;
#endif
    SerializationForStorage m_forStorage;
    SerializationForCrossProcessTransfer m_forTransfer;
};

bool SerializedScriptValue::writeBytesForBindgen(CloneSerializer* serializer, const uint8_t* data, uint32_t size)
{
    return serializer->writeBytes(data, size);
}

bool SerializedScriptValue::writeSharedResourceForBindgen(CloneSerializer* serializer, Bun::Bindgen::SharedCloneResource&& resource)
{
    return serializer->writeSharedResource(WTF::move(resource));
}

SerializationReturnCode CloneSerializer::serialize(JSValue in)
{
    VM& vm = m_lexicalGlobalObject->vm();
    Vector<uint32_t, 16> indexStack;
    Vector<uint32_t, 16> lengthStack;
    Vector<PropertyNameArrayBuilder, 16> propertyStack;
    Vector<JSObject*, 32> inputObjectStack;
    Vector<JSMapIterator*, 4> mapIteratorStack;
    Vector<JSSetIterator*, 4> setIteratorStack;
    Vector<JSValue, 4> mapIteratorValueStack;
    Vector<WalkerState, 16> stateStack;
    WalkerState state = StateUnknown;
    JSValue inValue = in;
    auto scope = DECLARE_THROW_SCOPE(vm);
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
    if (failed())
        return m_failure;
    while (1) {
        switch (state) {
        arrayStartState:
        case ArrayStartState: {
            ASSERT(isArray(inValue));
            if (inputObjectStack.size() > maximumFilterRecursion)
                return SerializationReturnCode::StackOverflowError;

            JSArray* inArray = asArray(inValue);
            unsigned length = inArray->length();
            if (!startArray(inArray))
                break;
            if (!inputObjectStack.tryAppend(inArray) || !indexStack.tryAppend(0) || !lengthStack.tryAppend(length))
                return SerializationReturnCode::OutOfMemoryError;
        }
        arrayStartVisitMember:
            [[fallthrough]];
        case ArrayStartVisitMember: {
            if (failed())
                return m_failure;
            JSObject* array = inputObjectStack.last();
            uint32_t index = indexStack.last();
            if (index == lengthStack.last()) {
                indexStack.removeLast();
                lengthStack.removeLast();

                if (!propertyStack.tryConstructAndAppend(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude))
                    return SerializationReturnCode::OutOfMemoryError;
                array->getOwnNonIndexPropertyNames(m_lexicalGlobalObject, propertyStack.last(), DontEnumPropertiesMode::Exclude);
                RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
                if (propertyStack.last().size()) {
                    write(NonIndexPropertiesTag);
                    if (!indexStack.tryAppend(0))
                        return SerializationReturnCode::OutOfMemoryError;
                    goto objectStartVisitMember;
                }
                propertyStack.removeLast();

                endObject();
                inputObjectStack.removeLast();
                break;
            }
            inValue = array->getDirectIndex(m_lexicalGlobalObject, index);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
            if (!inValue) {
                indexStack.last()++;
                goto arrayStartVisitMember;
            }

            write(index);
            auto terminalCode = SerializationReturnCode::SuccessfullyCompleted;
            auto dumped = dumpIfTerminal(inValue, terminalCode);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
            if (dumped) {
                if (terminalCode != SerializationReturnCode::SuccessfullyCompleted)
                    return terminalCode;
                indexStack.last()++;
                goto arrayStartVisitMember;
            }
            if (!stateStack.tryAppend(ArrayEndVisitMember))
                return SerializationReturnCode::OutOfMemoryError;
            goto stateUnknown;
        }
        case ArrayEndVisitMember: {
            indexStack.last()++;
            goto arrayStartVisitMember;
        }
        objectStartState:
        case ObjectStartState: {
            ASSERT(inValue.isObject());
            if (inputObjectStack.size() > maximumFilterRecursion)
                return SerializationReturnCode::StackOverflowError;
            JSObject* inObject = asObject(inValue);
            if (!startObject(inObject))
                break;
            // At this point, all supported objects other than Object
            // objects have been handled. If we reach this point and
            // the input is not an Object object then we should throw
            // a DataCloneError.
            // NapiPrototype is allowed because napi_create_object should behave
            // like a plain object from JS's perspective (matches Node.js).
            if (inObject->classInfo() != JSFinalObject::info() && inObject->classInfo() != Zig::NapiPrototype::info())
                return SerializationReturnCode::DataCloneError;
            if (!inputObjectStack.tryAppend(inObject) || !indexStack.tryAppend(0)
                || !propertyStack.tryConstructAndAppend(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude))
                return SerializationReturnCode::OutOfMemoryError;
            inObject->methodTable()->getOwnPropertyNames(inObject, m_lexicalGlobalObject, propertyStack.last(), DontEnumPropertiesMode::Exclude);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
        }
        objectStartVisitMember:
            [[fallthrough]];
        case ObjectStartVisitMember: {
            if (failed())
                return m_failure;
            JSObject* object = inputObjectStack.last();
            uint32_t index = indexStack.last();
            PropertyNameArrayBuilder& properties = propertyStack.last();
            if (index == properties.size()) {
                endObject();
                inputObjectStack.removeLast();
                indexStack.removeLast();
                propertyStack.removeLast();
                break;
            }
            inValue = getProperty(object, properties[index]);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);

            if (!inValue) {
                // Property was removed during serialisation
                indexStack.last()++;
                goto objectStartVisitMember;
            }
            write(properties[index]);

            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);

            auto terminalCode = SerializationReturnCode::SuccessfullyCompleted;
            auto dumped = dumpIfTerminal(inValue, terminalCode);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
            if (!dumped) {
                if (!stateStack.tryAppend(ObjectEndVisitMember))
                    return SerializationReturnCode::OutOfMemoryError;
                goto stateUnknown;
            }
            if (terminalCode != SerializationReturnCode::SuccessfullyCompleted)
                return terminalCode;
            [[fallthrough]];
        }
        case ObjectEndVisitMember: {
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);

            indexStack.last()++;
            goto objectStartVisitMember;
        }
        mapStartState: {
            ASSERT(inValue.isObject());
            if (inputObjectStack.size() > maximumFilterRecursion)
                return SerializationReturnCode::StackOverflowError;
            JSMap* inMap = uncheckedDowncast<JSMap>(inValue);
            if (!startMap(inMap))
                break;
            JSMapIterator* iterator = JSMapIterator::create(vm, m_lexicalGlobalObject->mapIteratorStructure(), inMap, IterationKind::Entries);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
            if (!retain(iterator) || !mapIteratorStack.tryAppend(iterator) || !inputObjectStack.tryAppend(inMap))
                return SerializationReturnCode::OutOfMemoryError;
            goto mapDataStartVisitEntry;
        }
        mapDataStartVisitEntry:
        case MapDataStartVisitEntry: {
            if (failed())
                return m_failure;
            JSMapIterator* iterator = mapIteratorStack.last();
            JSValue key, value;
            if (!iterator->nextKeyValue(m_lexicalGlobalObject, key, value)) {
                mapIteratorStack.removeLast();
                JSObject* object = inputObjectStack.last();
                ASSERT(dynamicDowncast<JSMap>(object));
                if (!propertyStack.tryConstructAndAppend(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude))
                    return SerializationReturnCode::OutOfMemoryError;
                object->methodTable()->getOwnPropertyNames(object, m_lexicalGlobalObject, propertyStack.last(), DontEnumPropertiesMode::Exclude);
                RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
                write(NonMapPropertiesTag);
                if (!indexStack.tryAppend(0))
                    return SerializationReturnCode::OutOfMemoryError;
                goto objectStartVisitMember;
            }
            inValue = key;
            if (!retain(value) || !mapIteratorValueStack.tryAppend(value) || !stateStack.tryAppend(MapDataEndVisitKey))
                return SerializationReturnCode::OutOfMemoryError;
            goto stateUnknown;
        }
        case MapDataEndVisitKey: {
            inValue = mapIteratorValueStack.last();
            mapIteratorValueStack.removeLast();
            if (!stateStack.tryAppend(MapDataEndVisitValue))
                return SerializationReturnCode::OutOfMemoryError;
            goto stateUnknown;
        }
        case MapDataEndVisitValue: {
            goto mapDataStartVisitEntry;
        }

        setStartState: {
            ASSERT(inValue.isObject());
            if (inputObjectStack.size() > maximumFilterRecursion)
                return SerializationReturnCode::StackOverflowError;
            JSSet* inSet = uncheckedDowncast<JSSet>(inValue);
            if (!startSet(inSet))
                break;
            JSSetIterator* iterator = JSSetIterator::create(vm, m_lexicalGlobalObject->setIteratorStructure(), inSet, IterationKind::Keys);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
            if (!retain(iterator) || !setIteratorStack.tryAppend(iterator) || !inputObjectStack.tryAppend(inSet))
                return SerializationReturnCode::OutOfMemoryError;
            goto setDataStartVisitEntry;
        }
        setDataStartVisitEntry:
        case SetDataStartVisitEntry: {
            if (failed())
                return m_failure;
            JSSetIterator* iterator = setIteratorStack.last();
            JSValue key;
            if (!iterator->next(m_lexicalGlobalObject, key)) {
                setIteratorStack.removeLast();
                JSObject* object = inputObjectStack.last();
                ASSERT(dynamicDowncast<JSSet>(object));
                if (!propertyStack.tryConstructAndAppend(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude))
                    return SerializationReturnCode::OutOfMemoryError;
                object->methodTable()->getOwnPropertyNames(object, m_lexicalGlobalObject, propertyStack.last(), DontEnumPropertiesMode::Exclude);
                RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
                write(NonSetPropertiesTag);
                if (!indexStack.tryAppend(0))
                    return SerializationReturnCode::OutOfMemoryError;
                goto objectStartVisitMember;
            }
            inValue = key;
            if (!stateStack.tryAppend(SetDataEndVisitKey))
                return SerializationReturnCode::OutOfMemoryError;
            goto stateUnknown;
        }
        case SetDataEndVisitKey: {
            goto setDataStartVisitEntry;
        }

        stateUnknown:
        case StateUnknown: {
            auto terminalCode = SerializationReturnCode::SuccessfullyCompleted;
            auto dumped = dumpIfTerminal(inValue, terminalCode);
            RETURN_IF_EXCEPTION(scope, SerializationReturnCode::ExistingExceptionError);
            if (dumped) {
                if (terminalCode != SerializationReturnCode::SuccessfullyCompleted)
                    return terminalCode;
                break;
            }

            if (isArray(inValue))
                goto arrayStartState;
            if (isMap(inValue))
                goto mapStartState;
            if (isSet(inValue))
                goto setStartState;
            goto objectStartState;
        }
        }
        if (failed())
            return m_failure;
        if (stateStack.isEmpty())
            break;

        state = stateStack.last();
        stateStack.removeLast();
    }
    return SerializationReturnCode::SuccessfullyCompleted;
}

class CloneDeserializer : public CloneBase {
    WTF_FORBID_HEAP_ALLOCATION;

public:
    static String deserializeString(const Vector<uint8_t>& buffer)
    {
        if (buffer.isEmpty())
            return String();
        const uint8_t* ptr = buffer.begin();
        const uint8_t* end = buffer.end();
        uint32_t version;
        if (!readLittleEndian(ptr, end, version) || version > CurrentVersion)
            return String();
        uint8_t tag;
        if (!readLittleEndian(ptr, end, tag) || tag != StringTag)
            return String();
        uint32_t length;
        if (!readLittleEndian(ptr, end, length))
            return String();
        bool is8Bit = length & StringDataIs8BitFlag;
        length &= ~StringDataIs8BitFlag;
        String str;
        if (readString(ptr, end, str, length, is8Bit) != SerializationReturnCode::SuccessfullyCompleted)
            return String();
        return str;
    }

    void* sharedResource(uint8_t tag, const uint8_t*& cursor, const uint8_t* end) const
    {
        auto* next = cursor;
        uint32_t index;
        if (!readLittleEndian(next, end, index) || index >= m_sharedNativeResources.size())
            return nullptr;
        auto* resource = m_sharedNativeResources[index].get(tag);
        if (resource)
            cursor = next;
        return resource;
    }

    //     static DeserializationResult deserialize(JSGlobalObject* lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<RefPtr<MessagePort>>& messagePorts, Vector<std::optional<ImageBitmapBacking>>&& backingStores
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         ,
    //         Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& detachedOffscreenCanvases
    // #endif
    // #if ENABLE(WEB_RTC)
    //         ,
    //         Vector<std::unique_ptr<DetachedRTCDataChannel>>&& detachedRTCDataChannels
    // #endif
    //         ,
    //         ArrayBufferContentsArray* arrayBufferContentsArray, const Vector<uint8_t>& buffer, const Vector<String>& blobURLs, const Vector<String> blobFilePaths, ArrayBufferContentsArray* sharedBuffers
    // #if ENABLE(WEBASSEMBLY)
    //         ,
    //         WasmModuleArray* wasmModules, WasmMemoryHandleArray* wasmMemoryHandles
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         ,
    //         Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& serializedVideoChunks, Vector<WebCodecsVideoFrameData>&& serializedVideoFrames
    // #endif
    //     )
    //     {
    //         if (!buffer.size())
    //             return std::make_pair(jsNull(), SerializationReturnCode::UnspecifiedError);
    //         CloneDeserializer deserializer(lexicalGlobalObject, globalObject, messagePorts, arrayBufferContentsArray, buffer, blobURLs, blobFilePaths, sharedBuffers, WTF::move(backingStores)
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //                                                                                                                                                                       ,
    //             WTF::move(detachedOffscreenCanvases)
    // #endif
    // #if ENABLE(WEB_RTC)
    //                 ,
    //             WTF::move(detachedRTCDataChannels)
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //                 ,
    //             wasmModules, wasmMemoryHandles
    // #endif
    // #if ENABLE(WEB_CODECS)
    //             ,
    //             WTF::move(serializedVideoChunks), WTF::move(serializedVideoFrames)
    // #endif
    //         );
    //         if (!deserializer.isValid())
    //             return std::make_pair(JSValue(), SerializationReturnCode::ValidationError);
    //         return deserializer.deserialize();
    //     }

    static DeserializationResult deserialize(JSGlobalObject* lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<RefPtr<MessagePort>>& messagePorts
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        ,
        Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& detachedOffscreenCanvases
#endif
#if ENABLE(WEB_RTC)
        ,
        Vector<std::unique_ptr<DetachedRTCDataChannel>>&& detachedRTCDataChannels
#endif
        ,
        ArrayBufferContentsArray* arrayBufferContentsArray, std::span<const uint8_t> buffer, ArrayBufferContentsArray* sharedBuffers
#if ENABLE(WEBASSEMBLY)
        ,
        WasmModuleArray* wasmModules, WasmMemoryHandleArray* wasmMemoryHandles
#endif
#if ENABLE(WEB_CODECS)
        ,
        Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& serializedVideoChunks, Vector<WebCodecsVideoFrameData>&& serializedVideoFrames
#endif
        , std::span<const Bun::Bindgen::SharedCloneResource> sharedNativeResources = {})
    {
        if (buffer.empty())
            return std::make_pair(JSValue(), SerializationReturnCode::ValidationError);
        CloneDeserializer deserializer(lexicalGlobalObject, globalObject, messagePorts.span(), arrayBufferContentsArray, buffer, sharedBuffers
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
            ,
            WTF::move(detachedOffscreenCanvases)
#endif
#if ENABLE(WEB_RTC)
                ,
            WTF::move(detachedRTCDataChannels)
#endif
#if ENABLE(WEBASSEMBLY)
                ,
            wasmModules, wasmMemoryHandles
#endif
#if ENABLE(WEB_CODECS)
            ,
            WTF::move(serializedVideoChunks), WTF::move(serializedVideoFrames)
#endif
            , sharedNativeResources);
        if (deserializer.failed())
            return std::make_pair(JSValue(), deserializer.m_failure);
        return deserializer.deserialize();
    }

private:
    struct CachedString {
        CachedString(const String& string)
            : m_string(string)
        {
        }

        Identifier identifier(JSC::VM& vm)
        {
            if (m_identifier.isEmpty())
                m_identifier = Identifier::fromString(vm, string());
            return m_identifier;
        }

        JSValue jsString(JSGlobalObject* lexicalGlobalObject)
        {
            return JSC::jsString(lexicalGlobalObject->vm(), m_string);
        }
        const String& string() { return m_string; }

    private:
        String m_string;
        Identifier m_identifier;
    };

    struct CachedStringRef {
        CachedStringRef()
            : m_base(0)
            , m_index(0)
        {
        }
        CachedStringRef(Vector<CachedString>* base, size_t index)
            : m_base(base)
            , m_index(index)
        {
        }

        CachedString* operator->()
        {
            ASSERT(m_base);
            return &m_base->at(m_index);
        }

    private:
        Vector<CachedString>* m_base;
        size_t m_index;
    };

    //     CloneDeserializer(JSGlobalObject* lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<RefPtr<MessagePort>>& messagePorts, ArrayBufferContentsArray* arrayBufferContents, Vector<std::optional<ImageBitmapBacking>>&& backingStores, const Vector<uint8_t>& buffer
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         ,
    //         Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& detachedOffscreenCanvases = {}
    // #endif
    // #if ENABLE(WEB_RTC)
    //         ,
    //         Vector<std::unique_ptr<DetachedRTCDataChannel>>&& detachedRTCDataChannels = {}
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         ,
    //         WasmModuleArray* wasmModules = nullptr, WasmMemoryHandleArray* wasmMemoryHandles = nullptr
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         ,
    //         Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& serializedVideoChunks = {}, Vector<WebCodecsVideoFrameData>&& serializedVideoFrames = {}
    // #endif
    //         )
    //         : CloneBase(lexicalGlobalObject)
    //         , m_globalObject(globalObject)
    //         , m_isDOMGlobalObject(globalObject->inherits<JSDOMGlobalObject>())
    //         , m_canCreateDOMObject(m_isDOMGlobalObject && !globalObject->inherits<JSIDBSerializationGlobalObject>())
    //         , m_ptr(buffer.data())
    //         , m_end(buffer.data() + buffer.size())
    //         , m_version(0xFFFFFFFF)
    //         , m_messagePorts(messagePorts)
    //         , m_arrayBufferContents(arrayBufferContents)
    //         , m_arrayBuffers(arrayBufferContents ? arrayBufferContents->size() : 0)
    //         , m_backingStores(WTF::move(backingStores))
    //         , m_imageBitmaps(m_backingStores.size())
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         , m_detachedOffscreenCanvases(WTF::move(detachedOffscreenCanvases))
    //         , m_offscreenCanvases(m_detachedOffscreenCanvases.size())
    // #endif
    // #if ENABLE(WEB_RTC)
    //         , m_detachedRTCDataChannels(WTF::move(detachedRTCDataChannels))
    //         , m_rtcDataChannels(m_detachedRTCDataChannels.size())
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         , m_wasmModules(wasmModules)
    //         , m_wasmMemoryHandles(wasmMemoryHandles)
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         , m_serializedVideoChunks(WTF::move(serializedVideoChunks))
    //         , m_videoChunks(m_serializedVideoChunks.size())
    //         , m_serializedVideoFrames(WTF::move(serializedVideoFrames))
    //         , m_videoFrames(m_serializedVideoFrames.size())
    // #endif
    //     {
    //         if (!read(m_version))
    //             m_version = 0xFFFFFFFF;
    //     }

    CloneDeserializer(JSGlobalObject* lexicalGlobalObject, JSGlobalObject* globalObject, std::span<const RefPtr<MessagePort>> messagePorts, ArrayBufferContentsArray* arrayBufferContents, std::span<const uint8_t> buffer, ArrayBufferContentsArray* sharedBuffers = nullptr
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        ,
        Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& detachedOffscreenCanvases = {}
#endif
#if ENABLE(WEB_RTC)
        ,
        Vector<std::unique_ptr<DetachedRTCDataChannel>>&& detachedRTCDataChannels = {}
#endif
#if ENABLE(WEBASSEMBLY)
        ,
        WasmModuleArray* wasmModules = nullptr, WasmMemoryHandleArray* wasmMemoryHandles = nullptr
#endif
#if ENABLE(WEB_CODECS)
        ,
        Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& serializedVideoChunks = {}, Vector<WebCodecsVideoFrameData>&& serializedVideoFrames = {}
#endif
        , std::span<const Bun::Bindgen::SharedCloneResource> sharedNativeResources = {})
        : CloneBase(lexicalGlobalObject)
        , m_globalObject(globalObject)
        , m_isDOMGlobalObject(globalObject->inherits<JSDOMGlobalObject>())
        // , m_canCreateDOMObject(m_isDOMGlobalObject)
        , m_ptr(buffer.data())
        , m_end(buffer.empty() ? buffer.data() : buffer.data() + buffer.size())
        , m_version(0xFFFFFFFF)
        , m_messagePorts(messagePorts)
        , m_arrayBufferContents(arrayBufferContents)
        , m_sharedBuffers(sharedBuffers)
        , m_sharedNativeResources(sharedNativeResources)
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        , m_detachedOffscreenCanvases(WTF::move(detachedOffscreenCanvases))
#endif
#if ENABLE(WEB_RTC)
        , m_detachedRTCDataChannels(WTF::move(detachedRTCDataChannels))
#endif
#if ENABLE(WEBASSEMBLY)
        , m_wasmModules(wasmModules)
        , m_wasmMemoryHandles(wasmMemoryHandles)
#endif
#if ENABLE(WEB_CODECS)
        , m_serializedVideoChunks(WTF::move(serializedVideoChunks))
        , m_serializedVideoFrames(WTF::move(serializedVideoFrames))
#endif
    {
        if (!read(m_version) || m_version > CurrentVersion) {
            fail();
            return;
        }
        if (!m_arrayBuffers.tryGrow(arrayBufferContents ? arrayBufferContents->size() : 0)
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
            || !m_offscreenCanvases.tryGrow(m_detachedOffscreenCanvases.size())
#endif
#if ENABLE(WEB_RTC)
            || !m_rtcDataChannels.tryGrow(m_detachedRTCDataChannels.size())
#endif
#if ENABLE(WEB_CODECS)
            || !m_videoChunks.tryGrow(m_serializedVideoChunks.size())
            || !m_videoFrames.tryGrow(m_serializedVideoFrames.size())
#endif
        )
            fail(SerializationReturnCode::OutOfMemoryError);
    }

    //     CloneDeserializer(JSGlobalObject* lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<RefPtr<MessagePort>>& messagePorts, ArrayBufferContentsArray* arrayBufferContents, const Vector<uint8_t>& buffer, const Vector<String>& blobURLs, const Vector<String> blobFilePaths, ArrayBufferContentsArray* sharedBuffers, Vector<std::optional<ImageBitmapBacking>>&& backingStores
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         ,
    //         Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& detachedOffscreenCanvases
    // #endif
    // #if ENABLE(WEB_RTC)
    //         ,
    //         Vector<std::unique_ptr<DetachedRTCDataChannel>>&& detachedRTCDataChannels
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         ,
    //         WasmModuleArray* wasmModules, WasmMemoryHandleArray* wasmMemoryHandles
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         ,
    //         Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& serializedVideoChunks = {}, Vector<WebCodecsVideoFrameData>&& serializedVideoFrames = {}
    // #endif
    //         )
    //         : CloneBase(lexicalGlobalObject)
    //         , m_globalObject(globalObject)
    //         , m_isDOMGlobalObject(globalObject->inherits<JSDOMGlobalObject>())
    //         , m_canCreateDOMObject(m_isDOMGlobalObject && !globalObject->inherits<JSIDBSerializationGlobalObject>())
    //         , m_ptr(buffer.data())
    //         , m_end(buffer.data() + buffer.size())
    //         , m_version(0xFFFFFFFF)
    //         , m_messagePorts(messagePorts)
    //         , m_arrayBufferContents(arrayBufferContents)
    //         , m_arrayBuffers(arrayBufferContents ? arrayBufferContents->size() : 0)
    //         , m_blobURLs(blobURLs)
    //         , m_blobFilePaths(blobFilePaths)
    //         , m_sharedBuffers(sharedBuffers)
    //         , m_backingStores(WTF::move(backingStores))
    //         , m_imageBitmaps(m_backingStores.size())
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         , m_detachedOffscreenCanvases(WTF::move(detachedOffscreenCanvases))
    //         , m_offscreenCanvases(m_detachedOffscreenCanvases.size())
    // #endif
    // #if ENABLE(WEB_RTC)
    //         , m_detachedRTCDataChannels(WTF::move(detachedRTCDataChannels))
    //         , m_rtcDataChannels(m_detachedRTCDataChannels.size())
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         , m_wasmModules(wasmModules)
    //         , m_wasmMemoryHandles(wasmMemoryHandles)
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         , m_serializedVideoChunks(WTF::move(serializedVideoChunks))
    //         , m_videoChunks(m_serializedVideoChunks.size())
    //         , m_serializedVideoFrames(WTF::move(serializedVideoFrames))
    //         , m_videoFrames(m_serializedVideoFrames.size())
    // #endif
    //     {
    //         if (!read(m_version))
    //             m_version = 0xFFFFFFFF;
    //     }

    DeserializationResult deserialize();

    bool failed() const { return m_failure != SerializationReturnCode::SuccessfullyCompleted; }

    void fail(SerializationReturnCode code = SerializationReturnCode::ValidationError)
    {
        if (!failed())
            m_failure = code;
    }

    JSValue recordObject(JSValue object)
    {
        if (!object) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return {};
        }
        RELEASE_ASSERT(object.isObject());
        m_objectPool.append(object);
        if (m_objectPool.hasOverflowed()) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return {};
        }
        return object;
    }

    template<typename T> bool readLittleEndian(T& value)
    {
        if (failed() || !readLittleEndian(m_ptr, m_end, value)) {
            fail();
            return false;
        }
        return true;
    }
    template<typename T> static bool readLittleEndian(const uint8_t*& ptr, const uint8_t* end, T& value)
    {
        if (ptr == end || static_cast<size_t>(end - ptr) < sizeof(value))
            return false;
#if ASSUME_LITTLE_ENDIAN
        memcpy(&value, ptr, sizeof(value));
        ptr += sizeof(value);
#else
        std::make_unsigned_t<T> bits = 0;
        for (unsigned i = 0; i < sizeof(T); ++i)
            bits |= static_cast<std::make_unsigned_t<T>>(*ptr++) << (i * 8);
        value = std::bit_cast<T>(bits);
#endif
        return true;
    }

    bool read(bool& b)
    {
        int32_t integer;
        if (!readLittleEndian(integer))
            return false;
        if (integer < 0 || integer > 1) {
            fail();
            return false;
        }
        b = !!integer;
        return true;
    }

    bool read(uint32_t& i)
    {
        return readLittleEndian(i);
    }

    bool read(int32_t& i)
    {
        return readLittleEndian(i);
    }

    bool read(uint16_t& i)
    {
        return readLittleEndian(i);
    }

    bool read(uint8_t& i)
    {
        return readLittleEndian(i);
    }

    bool read(double& d)
    {
        uint64_t bits;
        if (!readLittleEndian(bits))
            return false;
        d = std::bit_cast<double>(bits);
        return true;
    }

    bool read(uint64_t& i)
    {
        return readLittleEndian(i);
    }

    std::optional<uint32_t> readStringIndex()
    {
        return readConstantPoolIndex(m_constantPool);
    }

    // std::optional<uint32_t> readImageDataIndex()
    // {
    //     return readConstantPoolIndex(m_imageDataPool);
    // }

    template<typename T> std::optional<uint32_t> readConstantPoolIndex(const T& constantPool)
    {
        if (constantPool.size() <= 0xFF) {
            uint8_t i8;
            if (!read(i8))
                return std::nullopt;
            return i8;
        }
        if (constantPool.size() <= 0xFFFF) {
            uint16_t i16;
            if (!read(i16))
                return std::nullopt;
            return i16;
        }
        uint32_t i;
        if (!read(i))
            return std::nullopt;
        return i;
    }

    static SerializationReturnCode readString(const uint8_t*& ptr, const uint8_t* end, String& str, unsigned length, bool is8Bit)
    {
        CheckedSize checkedByteLength = length;
        checkedByteLength *= is8Bit ? sizeof(Latin1Character) : sizeof(char16_t);
        if (checkedByteLength.hasOverflowed())
            return SerializationReturnCode::ValidationError;
        size_t byteLength = checkedByteLength.value();
        if (byteLength > static_cast<size_t>(end - ptr))
            return SerializationReturnCode::ValidationError;
        if (!length) {
            str = emptyString();
            return SerializationReturnCode::SuccessfullyCompleted;
        }

        if (is8Bit) {
            std::span<Latin1Character> characters;
            auto impl = StringImpl::tryCreateUninitialized(length, characters);
            if (!impl)
                return SerializationReturnCode::OutOfMemoryError;
            memcpy(characters.data(), ptr, byteLength);
            str = String(WTF::move(impl));
            ptr += length;
            return SerializationReturnCode::SuccessfullyCompleted;
        }

        std::span<char16_t> characters;
        auto impl = StringImpl::tryCreateUninitialized(length, characters);
        if (!impl)
            return SerializationReturnCode::OutOfMemoryError;
#if ASSUME_LITTLE_ENDIAN
        memcpy(characters.data(), ptr, byteLength);
        ptr += byteLength;
#else
        for (unsigned i = 0; i < length; ++i) {
            uint16_t c;
            RELEASE_ASSERT(readLittleEndian(ptr, end, c));
            characters[i] = c;
        }
#endif
        str = String(WTF::move(impl));
        return SerializationReturnCode::SuccessfullyCompleted;
    }

    bool readNullableString(String& nullableString)
    {
        bool isNull;
        if (!read(isNull))
            return false;
        if (isNull)
            return true;
        CachedStringRef stringData;
        if (!readStringData(stringData))
            return false;
        nullableString = stringData->string();
        return true;
    }

    bool readStringData(CachedStringRef& cachedString)
    {
        bool scratch;
        return readStringData(cachedString, scratch);
    }

    bool readStringData(CachedStringRef& cachedString, bool& wasTerminator)
    {
        if (failed())
            return false;
        wasTerminator = false;
        uint32_t length = 0;
        if (!read(length))
            return false;
        if (length == TerminatorTag) {
            wasTerminator = true;
            return false;
        }
        if (length == StringPoolTag) {
            auto index = readStringIndex();
            if (!index || *index >= m_constantPool.size()) {
                fail();
                return false;
            }
            cachedString = CachedStringRef(&m_constantPool, *index);
            return true;
        }
        bool is8Bit = length & StringDataIs8BitFlag;
        length &= ~StringDataIs8BitFlag;
        String str;
        auto code = readString(m_ptr, m_end, str, length, is8Bit);
        if (code != SerializationReturnCode::SuccessfullyCompleted) {
            fail(code);
            return false;
        }
        if (!m_constantPool.tryAppend(str)) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        cachedString = CachedStringRef(&m_constantPool, m_constantPool.size() - 1);
        return true;
    }

    SerializationTag readTag()
    {
        if (m_ptr >= m_end)
            return ErrorTag;
        return static_cast<SerializationTag>(*m_ptr++);
    }

    bool readArrayBufferViewSubtag(ArrayBufferViewSubtag& tag)
    {
        if (m_ptr >= m_end)
            return false;
        tag = static_cast<ArrayBufferViewSubtag>(*m_ptr++);
        return true;
    }

    void putProperty(JSObject* object, unsigned index, JSValue value)
    {
        object->putDirectIndex(m_lexicalGlobalObject, index, value);
    }

    void putProperty(JSObject* object, const Identifier& property, JSValue value)
    {
        object->putDirectMayBeIndex(m_lexicalGlobalObject, property, value);
    }

    // bool readFile(RefPtr<File>& file)
    // {
    //     CachedStringRef path;
    //     if (!readStringData(path))
    //         return false;
    //     CachedStringRef url;
    //     if (!readStringData(url))
    //         return false;
    //     CachedStringRef type;
    //     if (!readStringData(type))
    //         return false;
    //     CachedStringRef name;
    //     if (!readStringData(name))
    //         return false;
    //     std::optional<int64_t> optionalLastModified;
    //     if (m_version > 6) {
    //         double lastModified;
    //         if (!read(lastModified))
    //             return false;
    //         if (lastModified >= 0)
    //             optionalLastModified = lastModified;
    //     }

    //     // If the blob URL for this file has an associated blob file path, prefer that one over the "built-in" path.
    //     String filePath = blobFilePathForBlobURL(url->string());
    //     if (filePath.isEmpty())
    //         filePath = path->string();

    //     if (!m_canCreateDOMObject)
    //         return true;

    //     file = File::deserialize(executionContext(m_lexicalGlobalObject), filePath, URL { url->string() }, type->string(), name->string(), optionalLastModified);
    //     return true;
    // }

    template<typename LengthType>
    bool readArrayBufferImpl(RefPtr<ArrayBuffer>& arrayBuffer)
    {
        LengthType length;
        if (!read(length))
            return false;
        if (length > static_cast<size_t>(m_end - m_ptr))
            return false;
        arrayBuffer = ArrayBuffer::tryCreate({ m_ptr, length });
        if (!arrayBuffer) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        m_ptr += length;
        return true;
    }

    bool readArrayBuffer(RefPtr<ArrayBuffer>& arrayBuffer)
    {
        if (m_version < 10)
            return readArrayBufferImpl<uint32_t>(arrayBuffer);
        return readArrayBufferImpl<uint64_t>(arrayBuffer);
    }

    bool readResizableNonSharedArrayBuffer(RefPtr<ArrayBuffer>& arrayBuffer)
    {
        uint64_t byteLength;
        if (!read(byteLength))
            return false;
        uint64_t maxByteLength;
        if (!read(maxByteLength))
            return false;
        if (byteLength > maxByteLength || byteLength > static_cast<size_t>(m_end - m_ptr))
            return false;
        arrayBuffer = ArrayBuffer::tryCreate(byteLength, 1, maxByteLength);
        if (!arrayBuffer) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        ASSERT(arrayBuffer->isResizableNonShared());
        memcpy(arrayBuffer->data(), m_ptr, byteLength);
        m_ptr += byteLength;
        return true;
    }

    template<typename LengthType>
    bool readArrayBufferViewImpl(VM& vm, JSValue& arrayBufferView)
    {
        ArrayBufferViewSubtag arrayBufferViewSubtag;
        if (!readArrayBufferViewSubtag(arrayBufferViewSubtag))
            return false;
        LengthType byteOffset;
        if (!read(byteOffset))
            return false;
        LengthType byteLength;
        if (!read(byteLength))
            return false;
        JSValue arrayBufferValue = readTerminal();
        if (!arrayBufferValue || !arrayBufferValue.inherits<JSArrayBuffer>())
            return false;
        JSObject* arrayBufferObj = asObject(arrayBufferValue);

        unsigned elementSize = typedArrayElementSize(arrayBufferViewSubtag);
        if (!elementSize)
            return false;

        RefPtr<ArrayBuffer> arrayBuffer = toPossiblySharedArrayBuffer(vm, arrayBufferObj);
        if (!arrayBuffer || byteOffset % elementSize || byteOffset > arrayBuffer->byteLength())
            return false;

        std::optional<size_t> length;
        if (byteLength != autoLengthMarker) {
            if (byteLength > arrayBuffer->byteLength() - byteOffset)
                return false;
            LengthType computedLength = byteLength / elementSize;
            if (computedLength * elementSize != byteLength)
                return false;
            length = computedLength;
        } else {
            if (!arrayBuffer->isResizableOrGrowableShared())
                return false;
        }

        bool isResizableOrGrowableShared = arrayBuffer->isResizableOrGrowableShared();
        switch (arrayBufferViewSubtag) {
        case DataViewTag:
            arrayBufferView = JSDataView::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeDataView, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Int8ArrayTag:
            arrayBufferView = JSInt8Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeInt8, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Uint8ArrayTag:
            arrayBufferView = JSUint8Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeUint8, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Uint8ClampedArrayTag:
            arrayBufferView = JSUint8ClampedArray::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeUint8Clamped, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Int16ArrayTag:
            arrayBufferView = JSInt16Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeInt16, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Uint16ArrayTag:
            arrayBufferView = JSUint16Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeUint16, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Int32ArrayTag:
            arrayBufferView = JSInt32Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeInt32, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Uint32ArrayTag:
            arrayBufferView = JSUint32Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeUint32, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Float16ArrayTag:
            arrayBufferView = JSFloat16Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeFloat16, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Float32ArrayTag:
            arrayBufferView = JSFloat32Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeFloat32, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case Float64ArrayTag:
            arrayBufferView = JSFloat64Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeFloat64, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case BigInt64ArrayTag:
            arrayBufferView = JSBigInt64Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeBigInt64, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        case BigUint64ArrayTag:
            arrayBufferView = JSBigUint64Array::create(m_lexicalGlobalObject, m_globalObject->typedArrayStructure(TypeBigUint64, isResizableOrGrowableShared), WTF::move(arrayBuffer), byteOffset, length);
            break;
        default:
            return false;
        }
        if (!arrayBufferView) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        return true;
    }

    bool readArrayBufferView(VM& vm, JSValue& arrayBufferView)
    {
        if (m_version < 10)
            return readArrayBufferViewImpl<uint32_t>(vm, arrayBufferView);
        return readArrayBufferViewImpl<uint64_t>(vm, arrayBufferView);
    }

    bool read(Vector<uint8_t>& result)
    {
        ASSERT(result.isEmpty());
        uint32_t size;
        if (!read(size))
            return false;
        if (size > static_cast<size_t>(m_end - m_ptr))
            return false;
        if (!result.tryAppend(std::span { m_ptr, size })) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        m_ptr += size;
        return true;
    }

    //     bool read(PredefinedColorSpace& result)
    //     {
    //         uint8_t tag;
    //         if (!read(tag))
    //             return false;

    //         switch (static_cast<PredefinedColorSpaceTag>(tag)) {
    //         case PredefinedColorSpaceTag::SRGB:
    //             result = PredefinedColorSpace::SRGB;
    //             return true;
    // #if ENABLE(PREDEFINED_COLOR_SPACE_DISPLAY_P3)
    //         case PredefinedColorSpaceTag::DisplayP3:
    //             result = PredefinedColorSpace::DisplayP3;
    //             return true;
    // #endif
    //         default:
    //             return false;
    //         }
    //     }

    // bool read(DestinationColorSpaceTag& tag)
    // {
    //     if (m_ptr >= m_end)
    //         return false;
    //     tag = static_cast<DestinationColorSpaceTag>(*m_ptr++);
    //     return true;
    // }

#if PLATFORM(COCOA)
    bool read(RetainPtr<CFDataRef>& data)
    {
        uint32_t dataLength;
        if (!read(dataLength) || static_cast<uint32_t>(m_end - m_ptr) < dataLength)
            return false;

        data = adoptCF(CFDataCreateWithBytesNoCopy(nullptr, m_ptr, dataLength, kCFAllocatorNull));
        if (!data)
            return false;

        m_ptr += dataLength;
        return true;
    }
#endif

    //     bool read(DestinationColorSpace& destinationColorSpace)
    //     {
    //         DestinationColorSpaceTag tag;
    //         if (!read(tag))
    //             return false;

    //         switch (tag) {
    //         case DestinationColorSpaceSRGBTag:
    //             destinationColorSpace = DestinationColorSpace::SRGB();
    //             return true;
    // #if ENABLE(DESTINATION_COLOR_SPACE_LINEAR_SRGB)
    //         case DestinationColorSpaceLinearSRGBTag:
    //             destinationColorSpace = DestinationColorSpace::LinearSRGB();
    //             return true;
    // #endif
    // #if ENABLE(DESTINATION_COLOR_SPACE_DISPLAY_P3)
    //         case DestinationColorSpaceDisplayP3Tag:
    //             destinationColorSpace = DestinationColorSpace::DisplayP3();
    //             return true;
    // #endif
    // #if PLATFORM(COCOA)
    //         case DestinationColorSpaceCGColorSpaceNameTag: {
    //             RetainPtr<CFDataRef> data;
    //             if (!read(data))
    //                 return false;

    //             auto name = adoptCF(CFStringCreateFromExternalRepresentation(nullptr, data.get(), kCFStringEncodingUTF8));
    //             if (!name)
    //                 return false;

    //             auto colorSpace = adoptCF(CGColorSpaceCreateWithName(name.get()));
    //             if (!colorSpace)
    //                 return false;

    //             destinationColorSpace = DestinationColorSpace(colorSpace.get());
    //             return true;
    //         }
    //         case DestinationColorSpaceCGColorSpacePropertyListTag: {
    //             RetainPtr<CFDataRef> data;
    //             if (!read(data))
    //                 return false;

    //             auto propertyList = adoptCF(CFPropertyListCreateWithData(nullptr, data.get(), kCFPropertyListImmutable, nullptr, nullptr));
    //             if (!propertyList)
    //                 return false;

    //             auto colorSpace = adoptCF(CGColorSpaceCreateWithPropertyList(propertyList.get()));
    //             if (!colorSpace)
    //                 return false;

    //             destinationColorSpace = DestinationColorSpace(colorSpace.get());
    //             return true;
    //         }
    // #endif
    //         }

    //         ASSERT_NOT_REACHED();
    //         return false;
    //     }

    bool read(CryptoKeyType& result)
    {
        uint8_t type;
        if (!read(type))
            return false;
        if (type > cryptoKeyTypeMaximumValue) {
            return false;
        }
        result = static_cast<CryptoKeyType>(type);
        return true;
    }

    bool read(ncrypto::BIOPointer& bio, uint64_t length)
    {
        if (length > static_cast<size_t>(m_end - m_ptr) || length > INT_MAX)
            return false;
        bio.reset(BIO_new_mem_buf(m_ptr, static_cast<int>(length)));
        if (!bio) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return false;
        }
        m_ptr += length;
        return true;
    }

    bool read(SerializableErrorType& errorType)
    {
        std::underlying_type_t<SerializableErrorType> errorTypeInt;
        if (!read(errorTypeInt) || errorTypeInt > std::to_underlying(SerializableErrorType::Last))
            return false;

        errorType = static_cast<SerializableErrorType>(errorTypeInt);
        return true;
    }

    template<class T>
    JSValue getJSValue(T&& nativeObj)
    {
        return toJS(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), std::forward<T>(nativeObj));
    }

    // template<class T>
    // JSValue readDOMPoint()
    // {
    //     double x;
    //     if (!read(x))
    //         return {};
    //     double y;
    //     if (!read(y))
    //         return {};
    //     double z;
    //     if (!read(z))
    //         return {};
    //     double w;
    //     if (!read(w))
    //         return {};

    //     return toJSNewlyCreated(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), T::create(x, y, z, w));
    // }

    // template<class T>
    // JSValue readDOMMatrix()
    // {
    //     uint8_t is2D;
    //     if (!read(is2D))
    //         return {};

    //     if (is2D) {
    //         double m11;
    //         if (!read(m11))
    //             return {};
    //         double m12;
    //         if (!read(m12))
    //             return {};
    //         double m21;
    //         if (!read(m21))
    //             return {};
    //         double m22;
    //         if (!read(m22))
    //             return {};
    //         double m41;
    //         if (!read(m41))
    //             return {};
    //         double m42;
    //         if (!read(m42))
    //             return {};

    //         TransformationMatrix matrix(m11, m12, m21, m22, m41, m42);
    //         return toJSNewlyCreated(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), T::create(WTF::move(matrix), DOMMatrixReadOnly::Is2D::Yes));
    //     } else {
    //         double m11;
    //         if (!read(m11))
    //             return {};
    //         double m12;
    //         if (!read(m12))
    //             return {};
    //         double m13;
    //         if (!read(m13))
    //             return {};
    //         double m14;
    //         if (!read(m14))
    //             return {};
    //         double m21;
    //         if (!read(m21))
    //             return {};
    //         double m22;
    //         if (!read(m22))
    //             return {};
    //         double m23;
    //         if (!read(m23))
    //             return {};
    //         double m24;
    //         if (!read(m24))
    //             return {};
    //         double m31;
    //         if (!read(m31))
    //             return {};
    //         double m32;
    //         if (!read(m32))
    //             return {};
    //         double m33;
    //         if (!read(m33))
    //             return {};
    //         double m34;
    //         if (!read(m34))
    //             return {};
    //         double m41;
    //         if (!read(m41))
    //             return {};
    //         double m42;
    //         if (!read(m42))
    //             return {};
    //         double m43;
    //         if (!read(m43))
    //             return {};
    //         double m44;
    //         if (!read(m44))
    //             return {};

    //         TransformationMatrix matrix(m11, m12, m13, m14, m21, m22, m23, m24, m31, m32, m33, m34, m41, m42, m43, m44);
    //         return toJSNewlyCreated(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), T::create(WTF::move(matrix), DOMMatrixReadOnly::Is2D::No));
    //     }
    // }

    // template<class T>
    // JSValue readDOMRect()
    // {
    //     double x;
    //     if (!read(x))
    //         return {};
    //     double y;
    //     if (!read(y))
    //         return {};
    //     double width;
    //     if (!read(width))
    //         return {};
    //     double height;
    //     if (!read(height))
    //         return {};

    //     return toJSNewlyCreated(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), T::create(x, y, width, height));
    // }

    // std::optional<DOMPointInit> readDOMPointInit()
    // {
    //     DOMPointInit point;
    //     if (!read(point.x))
    //         return std::nullopt;
    //     if (!read(point.y))
    //         return std::nullopt;
    //     if (!read(point.z))
    //         return std::nullopt;
    //     if (!read(point.w))
    //         return std::nullopt;

    //     return point;
    // }

    // JSValue readDOMQuad()
    // {
    //     auto p1 = readDOMPointInit();
    //     if (!p1)
    //         return JSValue();
    //     auto p2 = readDOMPointInit();
    //     if (!p2)
    //         return JSValue();
    //     auto p3 = readDOMPointInit();
    //     if (!p3)
    //         return JSValue();
    //     auto p4 = readDOMPointInit();
    //     if (!p4)
    //         return JSValue();

    //     return toJSNewlyCreated(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), DOMQuad::create(p1.value(), p2.value(), p3.value(), p4.value()));
    // }

    // JSValue readTransferredImageBitmap()
    // {
    //     uint32_t index;
    //     bool indexSuccessfullyRead = read(index);
    //     if (!indexSuccessfullyRead || index >= m_backingStores.size()) {
    //         fail();
    //         return JSValue();
    //     }

    //     if (!m_imageBitmaps[index]) {
    //         m_backingStores.at(index)->connect(*executionContext(m_lexicalGlobalObject));
    //         m_imageBitmaps[index] = ImageBitmap::create(WTF::move(m_backingStores.at(index)));
    //     }

    //     auto bitmap = m_imageBitmaps[index].get();
    //     return getJSValue(bitmap);
    // }

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    JSValue readOffscreenCanvas()
    {
        uint32_t index;
        bool indexSuccessfullyRead = read(index);
        if (!indexSuccessfullyRead || index >= m_detachedOffscreenCanvases.size()) {
            fail();
            return JSValue();
        }

        if (!m_offscreenCanvases[index])
            m_offscreenCanvases[index] = OffscreenCanvas::create(*executionContext(m_lexicalGlobalObject), WTF::move(m_detachedOffscreenCanvases.at(index)));

        auto offscreenCanvas = m_offscreenCanvases[index].get();
        return getJSValue(offscreenCanvas);
    }
#endif

#if ENABLE(WEB_RTC)
    JSValue readRTCCertificate()
    {
        double expires;
        if (!read(expires)) {
            fail();
            return JSValue();
        }
        CachedStringRef certificate;
        if (!readStringData(certificate)) {
            fail();
            return JSValue();
        }
        CachedStringRef origin;
        if (!readStringData(origin)) {
            fail();
            return JSValue();
        }
        CachedStringRef keyedMaterial;
        if (!readStringData(keyedMaterial)) {
            fail();
            return JSValue();
        }
        unsigned size = 0;
        if (!read(size))
            return JSValue();

        Vector<RTCCertificate::DtlsFingerprint> fingerprints;
        fingerprints.reserveInitialCapacity(size);
        for (unsigned i = 0; i < size; i++) {
            CachedStringRef algorithm;
            if (!readStringData(algorithm))
                return JSValue();
            CachedStringRef value;
            if (!readStringData(value))
                return JSValue();
            fingerprints.unsafeAppendWithoutCapacityCheck(RTCCertificate::DtlsFingerprint { algorithm->string(), value->string() });
        }

        if (!m_canCreateDOMObject)
            return constructEmptyObject(m_lexicalGlobalObject, m_globalObject->objectPrototype());

        auto rtcCertificate = RTCCertificate::create(SecurityOrigin::createFromString(origin->string()), expires, WTF::move(fingerprints), String { certificate->string() }, String { keyedMaterial->string() });
        return toJSNewlyCreated(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), WTF::move(rtcCertificate));
    }

    JSValue readRTCDataChannel()
    {
        uint32_t index;
        bool indexSuccessfullyRead = read(index);
        if (!indexSuccessfullyRead || index >= m_detachedRTCDataChannels.size()) {
            fail();
            return JSValue();
        }

        if (!m_rtcDataChannels[index]) {
            auto detachedChannel = WTF::move(m_detachedRTCDataChannels.at(index));
            m_rtcDataChannels[index] = RTCDataChannel::create(*executionContext(m_lexicalGlobalObject), detachedChannel->identifier, WTF::move(detachedChannel->label), WTF::move(detachedChannel->options), detachedChannel->state);
        }

        return getJSValue(m_rtcDataChannels[index].get());
    }
#endif

#if ENABLE(WEB_CODECS)
    JSValue readWebCodecsEncodedVideoChunk()
    {
        uint32_t index;
        bool indexSuccessfullyRead = read(index);
        if (!indexSuccessfullyRead || index >= m_serializedVideoChunks.size()) {
            fail();
            return JSValue();
        }

        if (!m_videoChunks[index])
            m_videoChunks[index] = WebCodecsEncodedVideoChunk::create(m_serializedVideoChunks.at(index).releaseNonNull());

        return getJSValue(m_videoChunks[index].get());
    }
    JSValue readWebCodecsVideoFrame()
    {
        uint32_t index;
        bool indexSuccessfullyRead = read(index);
        if (!indexSuccessfullyRead || index >= m_serializedVideoFrames.size()) {
            fail();
            return JSValue();
        }

        if (!m_videoFrames[index])
            m_videoFrames[index] = WebCodecsVideoFrame::create(*executionContext(m_lexicalGlobalObject), WTF::move(m_serializedVideoFrames.at(index)));

        return getJSValue(m_videoFrames[index].get());
    }
#endif

    // JSValue readImageBitmap()
    // {
    //     uint8_t serializationState;
    //     int32_t logicalWidth;
    //     int32_t logicalHeight;
    //     double resolutionScale;
    //     auto colorSpace = DestinationColorSpace::SRGB();
    //     RefPtr<ArrayBuffer> arrayBuffer;

    //     if (!read(serializationState) || !read(logicalWidth) || !read(logicalHeight) || !read(resolutionScale) || (m_version > 8 && !read(colorSpace)) || !readArrayBufferImpl<uint32_t>(arrayBuffer)) {
    //         fail();
    //         return JSValue();
    //     }

    //     auto logicalSize = IntSize(logicalWidth, logicalHeight);
    //     auto imageDataSize = logicalSize;
    //     imageDataSize.scale(resolutionScale);

    //     auto buffer = ImageBitmap::createImageBuffer(*executionContext(m_lexicalGlobalObject), logicalSize, RenderingMode::Unaccelerated, colorSpace, resolutionScale);
    //     if (!buffer) {
    //         fail();
    //         return JSValue();
    //     }

    //     PixelBufferFormat format { AlphaPremultiplication::Premultiplied, PixelFormat::RGBA8, colorSpace };
    //     auto pixelBuffer = ByteArrayPixelBuffer::tryCreate(format, imageDataSize, arrayBuffer.releaseNonNull());
    //     if (!pixelBuffer) {
    //         fail();
    //         return JSValue();
    //     }

    //     buffer->putPixelBuffer(*pixelBuffer, { IntPoint::zero(), logicalSize });

    //     auto bitmap = ImageBitmap::create(ImageBitmapBacking(WTF::move(buffer), OptionSet<SerializationState>::fromRaw(serializationState)));
    //     return getJSValue(bitmap);
    // }

    JSValue readX509Certificate()
    {
        Vector<uint8_t> buffer;

        if (!read(buffer)) {
            fail();
            return JSValue();
        }

        if (buffer.size() == 0) {
            return Bun::JSX509Certificate::create(m_lexicalGlobalObject->vm(), defaultGlobalObject(m_globalObject)->m_JSX509CertificateClassStructure.get(m_globalObject));
        }
        ncrypto::ClearErrorOnReturn clear_error_on_return;
        X509* ptr = nullptr;
        const uint8_t* data = buffer.begin();

        auto cert = d2i_X509(&ptr, &data, buffer.size());
        if (!cert) {
            fail(cryptoSerializationFailure(SerializationReturnCode::ValidationError));
            return JSValue();
        }

        auto cert_ptr = ncrypto::X509Pointer(cert);
        auto* domGlobalObject = defaultGlobalObject(m_globalObject);
        auto* cert_obj = Bun::JSX509Certificate::create(m_lexicalGlobalObject->vm(), domGlobalObject->m_JSX509CertificateClassStructure.get(domGlobalObject), m_globalObject, WTF::move(cert_ptr));

        return cert_obj;
    }

    JSValue readKeyObject()
    {
        VM& vm = m_globalObject->vm();
        auto* globalObject = defaultGlobalObject(m_globalObject);

        CryptoKeyType keyType;
        if (!read(keyType)) {
            fail();
            return JSValue();
        }

        switch (keyType) {
        case CryptoKeyType::Secret: {
            Vector<uint8_t> keyData;
            if (!read(keyData)) {
                fail();
                return JSValue();
            }

            auto keyObject = KeyObject::create(WTF::move(keyData));
            if (keyObject.hasException()) {
                fail(SerializationReturnCode::OutOfMemoryError);
                return {};
            }
            Structure* structure = globalObject->m_JSSecretKeyObjectClassStructure.get(m_globalObject);
            return JSSecretKeyObject::create(vm, structure, m_globalObject, keyObject.releaseReturnValue());
        }
        case CryptoKeyType::Public:
        case CryptoKeyType::Private: {
            uint64_t pemSize = 0;
            if (!read(pemSize)) {
                fail();
                return JSValue();
            }

            ncrypto::ClearErrorOnReturn clearError;
            ncrypto::BIOPointer bio;
            if (!read(bio, pemSize)) {
                fail();
                return JSValue();
            }

            if (keyType == CryptoKeyType::Public) {
                EVP_PKEY* pkey = PEM_read_bio_PUBKEY(bio.get(), nullptr, nullptr, nullptr);
                if (!pkey) {
                    fail(cryptoSerializationFailure(SerializationReturnCode::ValidationError));
                    return JSValue();
                }
                auto keyObject = KeyObject::create(CryptoKeyType::Public, ncrypto::EVPKeyPointer(pkey));
                if (keyObject.hasException()) {
                    fail(SerializationReturnCode::OutOfMemoryError);
                    return {};
                }
                Structure* structure = globalObject->m_JSPublicKeyObjectClassStructure.get(m_globalObject);
                return JSPublicKeyObject::create(vm, structure, m_globalObject, keyObject.releaseReturnValue());
            }

            EVP_PKEY* pkey = PEM_read_bio_PrivateKey(bio.get(), nullptr, nullptr, nullptr);
            if (!pkey) {
                fail(cryptoSerializationFailure(SerializationReturnCode::ValidationError));
                return JSValue();
            }
            auto keyObject = KeyObject::create(CryptoKeyType::Private, ncrypto::EVPKeyPointer(pkey));
            if (keyObject.hasException()) {
                fail(SerializationReturnCode::OutOfMemoryError);
                return {};
            }
            Structure* structure = globalObject->m_JSPrivateKeyObjectClassStructure.get(m_globalObject);
            return JSPrivateKeyObject::create(vm, structure, m_globalObject, keyObject.releaseReturnValue());
        }
        }
    }

    JSValue readDOMException()
    {
        CachedStringRef message;
        if (!readStringData(message))
            return JSValue();
        CachedStringRef name;
        if (!readStringData(name))
            return JSValue();
        auto exception = DOMException::create(message->string(), name->string());
        return getJSValue(exception);
    }

    JSValue readBigInt()
    {
        uint8_t sign = 0;
        if (!read(sign))
            return JSValue();
        if (sign > 1) {
            fail();
            return {};
        }
        uint32_t lengthInUint64 = 0;
        if (!read(lengthInUint64))
            return JSValue();
        if (lengthInUint64 > static_cast<size_t>(m_end - m_ptr) / sizeof(uint64_t)) {
            fail();
            return {};
        }

        if (!lengthInUint64) {
#if USE(BIGINT32)
            return jsBigInt32(0);
#else
            JSBigInt* bigInt = JSBigInt::tryCreateZero(m_lexicalGlobalObject->vm());
            if (!bigInt) [[unlikely]] {
                fail(SerializationReturnCode::OutOfMemoryError);
                return JSValue();
            }
            return bigInt;
#endif
        }

#if USE(BIGINT32)
        static_assert(sizeof(JSBigInt::Digit) == sizeof(uint64_t));
        if (lengthInUint64 == 1) {
            uint64_t digit64 = 0;
            if (!read(digit64))
                return JSValue();
            if (sign) {
                if (digit64 <= static_cast<uint64_t>(-static_cast<int64_t>(INT32_MIN)))
                    return jsBigInt32(static_cast<int32_t>(-static_cast<int64_t>(digit64)));
            } else {
                if (digit64 <= INT32_MAX)
                    return jsBigInt32(static_cast<int32_t>(digit64));
            }
            ASSERT(digit64 != 0);
            JSBigInt* bigInt = JSBigInt::tryCreateWithLength(m_lexicalGlobalObject->vm(), 1);
            if (!bigInt) {
                fail(SerializationReturnCode::OutOfMemoryError);
                return JSValue();
            }
            bigInt->setDigit(0, digit64);
            bigInt->setSign(sign);
            bigInt = bigInt->tryRightTrim(m_lexicalGlobalObject->vm());
            if (!bigInt) {
                fail(SerializationReturnCode::OutOfMemoryError);
                return JSValue();
            }
            return tryConvertToBigInt32(bigInt);
        }
#endif
        Vector<JSBigInt::Digit, 16> digits;
        CheckedSize digitCount = lengthInUint64;
        digitCount *= sizeof(uint64_t) / sizeof(JSBigInt::Digit);
        if (digitCount.hasOverflowed() || !digits.tryReserveInitialCapacity(digitCount.value())) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return {};
        }
        if constexpr (sizeof(JSBigInt::Digit) == sizeof(uint64_t)) {
            for (uint32_t index = 0; index < lengthInUint64; ++index) {
                uint64_t digit64 = 0;
                if (!read(digit64))
                    return JSValue();
                digits.append(digit64);
            }
        } else {
            ASSERT(sizeof(JSBigInt::Digit) == sizeof(uint32_t));
            for (uint32_t index = 0; index < lengthInUint64; ++index) {
                uint64_t digit64 = 0;
                if (!read(digit64))
                    return JSValue();
                digits.append(static_cast<uint32_t>(digit64));
                digits.append(static_cast<uint32_t>(digit64 >> 32));
            }
        }

        auto* bigInt = JSBigInt::tryCreateFrom(nullptr, m_lexicalGlobalObject->vm(), sign, digits.span());
        if (!bigInt) {
            fail(SerializationReturnCode::OutOfMemoryError);
            return JSValue();
        }
        return tryConvertToBigInt32(bigInt);
    }

    JSValue readTerminal()
    {
        if (failed())
            return {};
        if (m_ptr == m_end) {
            fail();
            return {};
        }
        auto nextTag = static_cast<SerializationTag>(*m_ptr);
        if (nextTag == ArrayTag || nextTag == ObjectTag || nextTag == MapObjectTag || nextTag == SetObjectTag)
            return {};
        SerializationTag tag = readTag();
        // if (!isTypeExposedToGlobalObject(*m_globalObject, tag))
        //     return JSValue();

        // read bun types
        JSC::EncodedJSValue encodedValue {};
        if (Bun::bindgenStructuredCloneDeserialize(tag, m_lexicalGlobalObject, m_ptr, m_end, encodedValue, this)) {
            JSValue deserialized = JSValue::decode(encodedValue);
            if (deserialized.isEmpty()) {
                fail();
                return JSValue();
            }
            RELEASE_ASSERT(deserialized.isObject());
            return recordObject(deserialized);
        }

        switch (tag) {
        case UndefinedTag:
            return jsUndefined();
        case NullTag:
            return jsNull();
        case IntTag: {
            int32_t i;
            if (!read(i))
                return JSValue();
            return jsNumber(i);
        }
        case ZeroTag:
            return jsNumber(0);
        case OneTag:
            return jsNumber(1);
        case FalseTag:
            return jsBoolean(false);
        case TrueTag:
            return jsBoolean(true);
        case FalseObjectTag: {
            BooleanObject* obj = BooleanObject::create(m_lexicalGlobalObject->vm(), m_globalObject->booleanObjectStructure());
            obj->setInternalValue(m_lexicalGlobalObject->vm(), jsBoolean(false));
            return recordObject(obj);
        }
        case TrueObjectTag: {
            BooleanObject* obj = BooleanObject::create(m_lexicalGlobalObject->vm(), m_globalObject->booleanObjectStructure());
            obj->setInternalValue(m_lexicalGlobalObject->vm(), jsBoolean(true));
            return recordObject(obj);
        }
        case DoubleTag: {
            double d;
            if (!read(d))
                return JSValue();
            return jsNumber(purifyNaN(d));
        }
        case BigIntTag:
            return readBigInt();
        case NumberObjectTag: {
            double d;
            if (!read(d))
                return JSValue();
            NumberObject* obj = constructNumber(m_globalObject, jsNumber(purifyNaN(d)));
            return recordObject(obj);
        }
        case BigIntObjectTag: {
            JSValue bigInt = readBigInt();
            if (!bigInt)
                return JSValue();
            ASSERT(bigInt.isBigInt());
            BigIntObject* obj = BigIntObject::create(m_lexicalGlobalObject->vm(), m_globalObject, bigInt);
            return recordObject(obj);
        }
        case DateTag: {
            double d;
            if (!read(d))
                return JSValue();
            return DateInstance::create(m_lexicalGlobalObject->vm(), m_globalObject->dateStructure(), d);
        }
        // case FileTag: {
        //     RefPtr<File> file;
        //     if (!readFile(file))
        //         return JSValue();
        //     if (!m_canCreateDOMObject)
        //         return jsNull();
        //     return toJS(m_lexicalGlobalObject, uncheckedDowncast<JSDOMGlobalObject>(m_globalObject), file.get());
        // }
        // case FileListTag: {
        //     unsigned length = 0;
        //     if (!read(length))
        //         return JSValue();
        //     ASSERT(m_globalObject->inherits<JSDOMGlobalObject>());
        //     Vector<Ref<File>> files;
        //     for (unsigned i = 0; i < length; i++) {
        //         RefPtr<File> file;
        //         if (!readFile(file))
        //             return JSValue();
        //         if (m_canCreateDOMObject)
        //             files.append(file.releaseNonNull());
        //     }
        //     if (!m_canCreateDOMObject)
        //         return jsNull();
        //     return getJSValue(FileList::create(WTF::move(files)).get());
        // }
        // case ImageDataTag: {
        //     uint32_t width;
        //     if (!read(width))
        //         return JSValue();
        //     if (width == ImageDataPoolTag) {
        //         auto index = readImageDataIndex();
        //         if (!index || *index >= m_imageDataPool.size()) {
        //             fail();
        //             return JSValue();
        //         }
        //         return getJSValue(m_imageDataPool[*index]);
        //     }
        //     uint32_t height;
        //     if (!read(height))
        //         return JSValue();
        //     uint32_t length;
        //     if (!read(length))
        //         return JSValue();
        //     if (static_cast<uint32_t>(m_end - m_ptr) < length) {
        //         fail();
        //         return JSValue();
        //     }
        //     auto bufferStart = m_ptr;
        //     m_ptr += length;

        //     auto resultColorSpace = PredefinedColorSpace::SRGB;
        //     if (m_version > 7) {
        //         if (!read(resultColorSpace))
        //             return JSValue();
        //     }

        //     if (length && (IntSize(width, height).area() * 4) != length) {
        //         fail();
        //         return JSValue();
        //     }

        //     if (!m_isDOMGlobalObject)
        //         return jsNull();

        //     auto result = ImageData::createUninitialized(width, height, resultColorSpace);
        //     if (result.hasException()) {
        //         fail();
        //         return JSValue();
        //     }
        //     if (length)
        //         memcpy(result.returnValue()->data().data(), bufferStart, length);
        //     else
        //         result.returnValue()->data().zeroFill();
        //     m_imageDataPool.append(result.returnValue().copyRef());
        //     return getJSValue(result.releaseReturnValue());
        // }
        // case BlobTag: {
        //     CachedStringRef url;
        //     if (!readStringData(url))
        //         return JSValue();
        //     CachedStringRef type;
        //     if (!readStringData(type))
        //         return JSValue();
        //     uint64_t size = 0;
        //     if (!read(size))
        //         return JSValue();
        //     uint64_t memoryCost = 0;
        //     if (m_version >= 11 && !read(memoryCost))
        //         return JSValue();
        //     if (!m_canCreateDOMObject)
        //         return jsNull();
        //     return getJSValue(Blob::deserialize(executionContext(m_lexicalGlobalObject), URL { url->string() }, type->string(), size, memoryCost, blobFilePathForBlobURL(url->string())).get());
        // }
        case StringTag: {
            CachedStringRef cachedString;
            if (!readStringData(cachedString))
                return JSValue();
            return cachedString->jsString(m_lexicalGlobalObject);
        }
        case EmptyStringTag:
            return jsEmptyString(m_lexicalGlobalObject->vm());
        case StringObjectTag: {
            CachedStringRef cachedString;
            if (!readStringData(cachedString))
                return JSValue();
            StringObject* obj = constructString(m_lexicalGlobalObject->vm(), m_globalObject, cachedString->jsString(m_lexicalGlobalObject));
            return recordObject(obj);
        }
        case EmptyStringObjectTag: {
            VM& vm = m_lexicalGlobalObject->vm();
            StringObject* obj = constructString(vm, m_globalObject, jsEmptyString(vm));
            return recordObject(obj);
        }
        case RegExpTag: {
            CachedStringRef pattern;
            if (!readStringData(pattern))
                return JSValue();
            CachedStringRef flags;
            if (!readStringData(flags))
                return JSValue();
            auto reFlags = Yarr::parseFlags(flags->string());
            if (!reFlags) {
                fail();
                return {};
            }
            VM& vm = m_lexicalGlobalObject->vm();
            RegExp* regExp = RegExp::create(vm, pattern->string(), reFlags.value());
            if (!regExp->isValid()) {
                fail();
                return {};
            }
            return RegExpObject::create(vm, m_globalObject->regExpStructure(), regExp);
        }
        case ErrorInstanceTag: {
            SerializableErrorType serializedErrorType;
            if (!read(serializedErrorType)) {
                fail();
                return JSValue();
            }
            String message;
            if (!readNullableString(message)) {
                fail();
                return JSValue();
            }
            uint32_t line;
            if (!read(line)) {
                fail();
                return JSValue();
            }
            uint32_t column;
            if (!read(column)) {
                fail();
                return JSValue();
            }
            String sourceURL;
            if (!readNullableString(sourceURL)) {
                fail();
                return JSValue();
            }
            String stackString;
            if (!readNullableString(stackString)) {
                fail();
                return JSValue();
            }
            return ErrorInstance::create(m_lexicalGlobalObject, WTF::move(message), toErrorType(serializedErrorType), { line, column }, WTF::move(sourceURL), WTF::move(stackString));
        }
        case ObjectReferenceTag: {
            auto index = readConstantPoolIndex(m_objectPool);
            if (!index || *index >= m_objectPool.size()) {
                fail();
                return JSValue();
            }
            return m_objectPool.at(*index);
        }
        case MessagePortReferenceTag: {
            uint32_t index;
            bool indexSuccessfullyRead = read(index);
            if (!indexSuccessfullyRead || index >= m_messagePorts.size()) {
                fail();
                return JSValue();
            }
            return getJSValue(m_messagePorts[index].get());
        }
#if ENABLE(WEBASSEMBLY)
        case WasmModuleTag: {
            if (m_version >= 12) {
                // https://webassembly.github.io/spec/web-api/index.html#serialization
                CachedStringRef agentClusterID;
                bool agentClusterIDSuccessfullyRead = readStringData(agentClusterID);
                if (!agentClusterIDSuccessfullyRead || agentClusterID->string() != agentClusterIDFromGlobalObject(*m_globalObject)) {
                    fail();
                    return JSValue();
                }
            }
            uint32_t index;
            bool indexSuccessfullyRead = read(index);
            if (!indexSuccessfullyRead || !m_wasmModules || index >= m_wasmModules->size()) {
                fail();
                return JSValue();
            }
            return JSC::JSWebAssemblyModule::create(m_lexicalGlobalObject->vm(), m_globalObject->webAssemblyModuleStructure(), Ref { *m_wasmModules->at(index) });
        }
        case WasmMemoryTag: {
            if (m_version >= 12) {
                CachedStringRef agentClusterID;
                bool agentClusterIDSuccessfullyRead = readStringData(agentClusterID);
                if (!agentClusterIDSuccessfullyRead || agentClusterID->string() != agentClusterIDFromGlobalObject(*m_globalObject)) {
                    fail();
                    return JSValue();
                }
            }
            uint32_t index;
            bool indexSuccessfullyRead = read(index);
            if (!indexSuccessfullyRead || !m_wasmMemoryHandles || index >= m_wasmMemoryHandles->size() || !JSC::Options::useSharedArrayBuffer()) {
                fail();
                return JSValue();
            }

            auto& vm = m_lexicalGlobalObject->vm();
            auto scope = DECLARE_THROW_SCOPE(vm);
            JSWebAssemblyMemory* result = JSC::JSWebAssemblyMemory::create(vm, m_globalObject->webAssemblyMemoryStructure());
            // Since we are cloning a JSWebAssemblyMemory, it's impossible for that
            // module to not have been a valid module. Therefore, createStub should
            // not throw.
            scope.releaseAssertNoException();

            RefPtr<Wasm::Memory> memory;
            auto handler = [&vm, result](Wasm::Memory::GrowSuccess, PageCount oldPageCount, PageCount newPageCount) { result->growSuccessCallback(vm, oldPageCount, newPageCount); };
            // Memory64 is not yet serialized in WasmMemoryTag, so we only
            // support I32 address type for structured clone. Upstream WebKit
            // has the same limitation (it calls result->memory().addressType()
            // on an uninitialized stub here, which happens to return I32).
            constexpr auto addressType = Wasm::AddressType::I32;
            if (RefPtr<SharedArrayBufferContents> contents = m_wasmMemoryHandles->at(index)) {
                if (!contents->memoryHandle()) {
                    fail();
                    return JSValue();
                }
                memory = Wasm::Memory::create(contents.releaseNonNull(), addressType, WTF::move(handler));
            } else {
                // zero size & max-size.
                memory = Wasm::Memory::createZeroSized(JSC::MemorySharingMode::Shared, addressType, WTF::move(handler));
            }

            result->adopt(memory.releaseNonNull());
            return result;
        }
#endif
        case ArrayBufferTag: {
            RefPtr<ArrayBuffer> arrayBuffer;
            if (!readArrayBuffer(arrayBuffer)) {
                fail();
                return JSValue();
            }
            Structure* structure = m_globalObject->arrayBufferStructure(arrayBuffer->sharingMode());
            // A crazy RuntimeFlags mismatch could mean that we are not equipped to handle shared
            // array buffers while the sender is. In that case, we would see a null structure here.
            if (!structure) [[unlikely]] {
                fail();
                return JSValue();
            }
            JSValue result = JSArrayBuffer::create(m_lexicalGlobalObject->vm(), structure, WTF::move(arrayBuffer));
            return recordObject(result);
        }
        case ResizableArrayBufferTag: {
            RefPtr<ArrayBuffer> arrayBuffer;
            if (!readResizableNonSharedArrayBuffer(arrayBuffer)) {
                fail();
                return JSValue();
            }
            Structure* structure = m_globalObject->arrayBufferStructure(arrayBuffer->sharingMode());
            // A crazy RuntimeFlags mismatch could mean that we are not equipped to handle shared
            // array buffers while the sender is. In that case, we would see a null structure here.
            if (!structure) [[unlikely]] {
                fail();
                return JSValue();
            }
            JSValue result = JSArrayBuffer::create(m_lexicalGlobalObject->vm(), structure, WTF::move(arrayBuffer));
            return recordObject(result);
        }
        case ArrayBufferTransferTag: {
            uint32_t index;
            bool indexSuccessfullyRead = read(index);
            if (!indexSuccessfullyRead || index >= m_arrayBuffers.size()) {
                fail();
                return JSValue();
            }

            if (!m_arrayBuffers[index])
                m_arrayBuffers[index] = ArrayBuffer::create(WTF::move(m_arrayBufferContents->at(index)));

            return getJSValue(m_arrayBuffers[index].get());
        }
        case SharedArrayBufferTag: {
            // https://html.spec.whatwg.org/multipage/structured-data.html#structureddeserialize
            uint32_t index = UINT_MAX;
            bool indexSuccessfullyRead = read(index);
            if (!indexSuccessfullyRead || !m_sharedBuffers || index >= m_sharedBuffers->size() || !JSC::Options::useSharedArrayBuffer()) {
                fail();
                return JSValue();
            }

            RELEASE_ASSERT(m_sharedBuffers->at(index));
            ArrayBufferContents arrayBufferContents;
            m_sharedBuffers->at(index).shareWith(arrayBufferContents);
            auto buffer = ArrayBuffer::create(WTF::move(arrayBufferContents));
            JSValue result = getJSValue(buffer.get());
            return recordObject(result);
        }
        case ArrayBufferViewTag: {
            JSValue arrayBufferView;
            if (!readArrayBufferView(m_lexicalGlobalObject->vm(), arrayBufferView)) {
                fail();
                return JSValue();
            }
            return recordObject(arrayBufferView);
        }
        case LegacyCryptoKeyTag: {
            Vector<uint8_t> bytes;
            if (!read(bytes)) {
                fail();
                return {};
            }
            auto key = deserializeLegacyCryptoKey(bytes.span(), CurrentVersion);
            if (!key) {
                fail(SerializationReturnCode::OutOfMemoryError);
                return {};
            }
            if (!*key) {
                fail();
                return {};
            }
            auto throwScope = DECLARE_THROW_SCOPE(m_globalObject->vm());
            auto value = Bun::Bindgen::ZigExports::bunBindgenZig_WebCryptoKey_adopt(m_globalObject, &key->releaseNonNull().leakRef());
            RETURN_IF_EXCEPTION(throwScope, {});
            return value;
        }

        // case DOMPointReadOnlyTag:
        //     return readDOMPoint<DOMPointReadOnly>();
        // case DOMPointTag:
        //     return readDOMPoint<DOMPoint>();
        // case DOMRectReadOnlyTag:
        //     return readDOMRect<DOMRectReadOnly>();
        // case DOMRectTag:
        //     return readDOMRect<DOMRect>();
        // case DOMMatrixReadOnlyTag:
        //     return readDOMMatrix<DOMMatrixReadOnly>();
        // case DOMMatrixTag:
        //     return readDOMMatrix<DOMMatrix>();
        // case DOMQuadTag:
        //     return readDOMQuad();
        // case ImageBitmapTransferTag:
        //     return readTransferredImageBitmap();
#if ENABLE(WEB_RTC)
        case RTCCertificateTag:
            return readRTCCertificate();

#endif
            // case ImageBitmapTag:
            //     return readImageBitmap();
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        case OffscreenCanvasTransferTag:
            return readOffscreenCanvas();
#endif
#if ENABLE(WEB_RTC)
        case RTCDataChannelTransferTag:
            return readRTCDataChannel();
#endif
#if ENABLE(WEB_CODECS)
        case WebCodecsEncodedVideoChunkTag:
            return readWebCodecsEncodedVideoChunk();
        case WebCodecsVideoFrameTag:
            return readWebCodecsVideoFrame();
#endif
        case DOMExceptionTag:
            return readDOMException();

        case Bun__X509CertificateTag:
            return readX509Certificate();

        case Bun__KeyObjectTag:
            return readKeyObject();

            // case Bun__NodePerformanceHooksHistogramTag:
            // ?

        default:
            fail();
            return JSValue();
        }
    }

    template<SerializationTag Tag>
    bool consumeCollectionDataTerminationIfPossible()
    {
        if (m_ptr == m_end || *m_ptr != Tag)
            return false;
        ++m_ptr;
        return true;
    }

    JSGlobalObject* const m_globalObject;
    const bool m_isDOMGlobalObject;
    // const bool m_canCreateDOMObject;
    const uint8_t* m_ptr;
    const uint8_t* const m_end;
    unsigned m_version;
    Vector<CachedString> m_constantPool;
    // Vector<Ref<ImageData>> m_imageDataPool;
    std::span<const RefPtr<MessagePort>> m_messagePorts;
    ArrayBufferContentsArray* m_arrayBufferContents;
    Vector<RefPtr<JSC::ArrayBuffer>> m_arrayBuffers;
    ArrayBufferContentsArray* m_sharedBuffers;
    std::span<const Bun::Bindgen::SharedCloneResource> m_sharedNativeResources;
    MarkedArgumentBuffer m_objectPool;
    SerializationReturnCode m_failure { SerializationReturnCode::SuccessfullyCompleted };
// Vector<std::optional<ImageBitmapBacking>> m_backingStores;
// Vector<RefPtr<ImageBitmap>> m_imageBitmaps;
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    Vector<std::unique_ptr<DetachedOffscreenCanvas>> m_detachedOffscreenCanvases;
    Vector<RefPtr<OffscreenCanvas>> m_offscreenCanvases;
#endif
#if ENABLE(WEB_RTC)
    Vector<std::unique_ptr<DetachedRTCDataChannel>> m_detachedRTCDataChannels;
    Vector<RefPtr<RTCDataChannel>> m_rtcDataChannels;
#endif
#if ENABLE(WEBASSEMBLY)
    WasmModuleArray* const m_wasmModules;
    WasmMemoryHandleArray* const m_wasmMemoryHandles;
#endif
#if ENABLE(WEB_CODECS)
    Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>> m_serializedVideoChunks;
    Vector<RefPtr<WebCodecsEncodedVideoChunk>> m_videoChunks;
    Vector<WebCodecsVideoFrameData> m_serializedVideoFrames;
    Vector<RefPtr<WebCodecsVideoFrame>> m_videoFrames;
#endif
};

void* SerializedScriptValue::sharedResourceForBindgen(CloneDeserializer* deserializer, uint8_t tag, const uint8_t*& cursor, const uint8_t* end)
{
    return deserializer->sharedResource(tag, cursor, end);
}

DeserializationResult CloneDeserializer::deserialize()
{
    VM& vm = m_lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    Vector<uint32_t, 16> indexStack;
    Vector<Identifier, 16> propertyNameStack;
    Vector<JSObject*, 32> outputObjectStack;
    MarkedArgumentBufferWithSize<4> mapKeyStack;
    Vector<JSMap*, 4> mapStack;
    Vector<JSSet*, 4> setStack;
    Vector<WalkerState, 16> stateStack;
    WalkerState state = StateUnknown;
    JSValue outValue;

    while (1) {
        switch (state) {
        arrayStartState:
        case ArrayStartState: {
            if (outputObjectStack.size() > maximumFilterRecursion)
                return std::make_pair(JSValue(), SerializationReturnCode::StackOverflowError);
            uint32_t length;
            if (!read(length)) {
                goto error;
            }
            JSArray* outArray = constructEmptyArray(m_globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), length);
            if (scope.exception()) [[unlikely]]
                goto error;
            if (!recordObject(outArray) || !outputObjectStack.tryAppend(outArray)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
        }
        arrayStartVisitMember:
            [[fallthrough]];
        case ArrayStartVisitMember: {
            uint32_t index;
            if (!read(index)) {
                goto error;
            }
            if (index == TerminatorTag) {
                JSObject* outArray = outputObjectStack.last();
                outValue = outArray;
                outputObjectStack.removeLast();
                break;
            } else if (index == NonIndexPropertiesTag) {
                goto objectStartVisitMember;
            }
            if (index >= asArray(outputObjectStack.last())->length())
                goto error;

            JSValue terminal = readTerminal();
            if (scope.exception()) [[unlikely]]
                goto error;
            if (failed())
                goto error;
            if (terminal) {
                putProperty(outputObjectStack.last(), index, terminal);
                if (scope.exception()) [[unlikely]] {
                    goto error;
                }
                goto arrayStartVisitMember;
            }
            if (failed())
                goto error;
            if (!indexStack.tryAppend(index) || !stateStack.tryAppend(ArrayEndVisitMember)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto stateUnknown;
        }
        case ArrayEndVisitMember: {
            JSObject* outArray = outputObjectStack.last();
            putProperty(outArray, indexStack.last(), outValue);
            if (scope.exception()) [[unlikely]] {
                goto error;
            }
            indexStack.removeLast();
            goto arrayStartVisitMember;
        }
        objectStartState:
        case ObjectStartState: {
            if (outputObjectStack.size() > maximumFilterRecursion)
                return std::make_pair(JSValue(), SerializationReturnCode::StackOverflowError);
            JSObject* outObject = constructEmptyObject(m_lexicalGlobalObject, m_globalObject->objectPrototype());
            if (!recordObject(outObject) || !outputObjectStack.tryAppend(outObject)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
        }
        objectStartVisitMember:
            [[fallthrough]];
        case ObjectStartVisitMember: {
            CachedStringRef cachedString;
            bool wasTerminator = false;
            if (!readStringData(cachedString, wasTerminator)) {
                if (!wasTerminator)
                    goto error;

                JSObject* outObject = outputObjectStack.last();
                outValue = outObject;
                outputObjectStack.removeLast();
                break;
            }

            JSValue terminal = readTerminal();
            if (scope.exception()) [[unlikely]]
                goto error;
            if (failed())
                goto error;
            if (terminal) {
                putProperty(outputObjectStack.last(), cachedString->identifier(vm), terminal);
                if (scope.exception()) [[unlikely]] {
                    goto error;
                }
                goto objectStartVisitMember;
            }
            if (!stateStack.tryAppend(ObjectEndVisitMember) || !propertyNameStack.tryAppend(cachedString->identifier(vm))) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto stateUnknown;
        }
        case ObjectEndVisitMember: {
            putProperty(outputObjectStack.last(), propertyNameStack.last(), outValue);
            if (scope.exception()) [[unlikely]]
                goto error;
            propertyNameStack.removeLast();
            goto objectStartVisitMember;
        }
        mapObjectStartState: {
            if (outputObjectStack.size() > maximumFilterRecursion)
                return std::make_pair(JSValue(), SerializationReturnCode::StackOverflowError);
            JSMap* map = JSMap::create(m_lexicalGlobalObject->vm(), m_globalObject->mapStructure());
            if (!recordObject(map) || !outputObjectStack.tryAppend(map) || !mapStack.tryAppend(map)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto mapDataStartVisitEntry;
        }
        mapDataStartVisitEntry:
        case MapDataStartVisitEntry: {
            if (consumeCollectionDataTerminationIfPossible<NonMapPropertiesTag>()) {
                mapStack.removeLast();
                goto objectStartVisitMember;
            }
            if (!stateStack.tryAppend(MapDataEndVisitKey)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto stateUnknown;
        }
        case MapDataEndVisitKey: {
            mapKeyStack.append(outValue);
            if (mapKeyStack.hasOverflowed() || !stateStack.tryAppend(MapDataEndVisitValue)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto stateUnknown;
        }
        case MapDataEndVisitValue: {
            mapStack.last()->set(m_lexicalGlobalObject, mapKeyStack.last(), outValue);
            if (scope.exception()) [[unlikely]] {
                goto error;
            }
            mapKeyStack.removeLast();
            goto mapDataStartVisitEntry;
        }

        setObjectStartState: {
            if (outputObjectStack.size() > maximumFilterRecursion)
                return std::make_pair(JSValue(), SerializationReturnCode::StackOverflowError);
            JSSet* set = JSSet::create(m_lexicalGlobalObject->vm(), m_globalObject->setStructure());
            if (!recordObject(set) || !outputObjectStack.tryAppend(set) || !setStack.tryAppend(set)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto setDataStartVisitEntry;
        }
        setDataStartVisitEntry:
        case SetDataStartVisitEntry: {
            if (consumeCollectionDataTerminationIfPossible<NonSetPropertiesTag>()) {
                setStack.removeLast();
                goto objectStartVisitMember;
            }
            if (!stateStack.tryAppend(SetDataEndVisitKey)) {
                fail(SerializationReturnCode::OutOfMemoryError);
                goto error;
            }
            goto stateUnknown;
        }
        case SetDataEndVisitKey: {
            JSSet* set = setStack.last();
            set->add(m_lexicalGlobalObject, outValue);
            if (scope.exception()) [[unlikely]] {
                goto error;
            }
            goto setDataStartVisitEntry;
        }

        stateUnknown:
        case StateUnknown:
            JSValue terminal = readTerminal();
            if (scope.exception()) [[unlikely]]
                goto error;
            if (failed())
                goto error;
            if (terminal) {
                outValue = terminal;
                break;
            }
            SerializationTag tag = readTag();
            if (tag == ArrayTag)
                goto arrayStartState;
            if (tag == ObjectTag)
                goto objectStartState;
            if (tag == MapObjectTag)
                goto mapObjectStartState;
            if (tag == SetObjectTag)
                goto setObjectStartState;
            goto error;
        }
        if (stateStack.isEmpty())
            break;

        state = stateStack.last();
        stateStack.removeLast();
    }
    ASSERT(outValue);
    ASSERT(!failed());
    return std::make_pair(outValue, SerializationReturnCode::SuccessfullyCompleted);
error:
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
    fail();
    return std::make_pair(JSValue(), m_failure);
}

SerializedScriptValue::~SerializedScriptValue() = default;

SerializedScriptValue::SerializedScriptValue(Vector<uint8_t>&& buffer, ArrayBufferContentsArray arrayBufferContentsArray, ArrayBufferContentsArray sharedBufferContentsArray
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    ,
    Vector<std::unique_ptr<DetachedOffscreenCanvas>>&& detachedOffscreenCanvases
#endif
#if ENABLE(WEB_RTC)
    ,
    Vector<std::unique_ptr<DetachedRTCDataChannel>>&& detachedRTCDataChannels
#endif
#if ENABLE(WEBASSEMBLY)
    ,
    WasmModuleArray wasmModulesArray, WasmMemoryHandleArray wasmMemoryHandlesArray
#endif
#if ENABLE(WEB_CODECS)
    ,
    Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>>&& serializedVideoChunks, Vector<WebCodecsVideoFrameData>&& serializedVideoFrames
#endif
    )
    : m_data(WTF::move(buffer))
    , m_arrayBufferContentsArray(WTF::move(arrayBufferContentsArray))
    , m_sharedBufferContentsArray(WTF::move(sharedBufferContentsArray))
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    , m_detachedOffscreenCanvases(WTF::move(detachedOffscreenCanvases))
#endif
#if ENABLE(WEB_RTC)
    , m_detachedRTCDataChannels(WTF::move(detachedRTCDataChannels))
#endif
#if ENABLE(WEBASSEMBLY)
    , m_wasmModulesArray(WTF::move(wasmModulesArray))
    , m_wasmMemoryHandlesArray(WTF::move(wasmMemoryHandlesArray))
#endif
#if ENABLE(WEB_CODECS)
    , m_serializedVideoChunks(WTF::move(serializedVideoChunks))
    , m_serializedVideoFrames(WTF::move(serializedVideoFrames))
#endif
{
    m_memoryCost = computeMemoryCost();
}

SerializedScriptValue::SerializedScriptValue(WTF::Vector<SimpleInMemoryPropertyTableEntry>&& object)
    : m_simpleInMemoryPropertyTable(WTF::move(object))
    , m_fastPath(FastPath::SimpleObject)
{
    m_memoryCost = computeMemoryCost();
}

SerializedScriptValue::SerializedScriptValue(const String& fastPathString)
    : m_fastPathString(fastPathString)
    , m_fastPath(FastPath::String)
{
    m_memoryCost = computeMemoryCost();
}

SerializedScriptValue::SerializedScriptValue(Vector<uint8_t>&& butterflyData, uint32_t length, FastPath fastPath)
    : m_arrayButterflyData(WTF::move(butterflyData))
    , m_arrayLength(length)
    , m_fastPath(fastPath)
{
    m_memoryCost = computeMemoryCost();
}

SerializedScriptValue::SerializedScriptValue(WTF::Vector<DenseArrayElement>&& denseElements)
    : m_denseArrayElements(WTF::move(denseElements))
    , m_fastPath(FastPath::DenseArray)
{
    m_memoryCost = computeMemoryCost();
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::createDenseArrayFastPath(
    WTF::Vector<DenseArrayElement>&& elements)
{
    return createWithArgs(WTF::move(elements));
}

size_t SerializedScriptValue::computeMemoryCost() const
{
    size_t cost = m_data.size() + m_sharedNativeResources.sizeInBytes();

    for (auto& content : m_arrayBufferContentsArray)
        cost += content.sizeInBytes();

    for (auto& content : m_sharedBufferContentsArray)
        cost += content.sizeInBytes();

    // for (auto& backingStore : m_backingStores) {
    //     if (auto buffer = backingStore ? backingStore->buffer() : nullptr)
    //         cost += buffer->memoryCost();
    // }

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    for (auto& canvas : m_detachedOffscreenCanvases) {
        if (canvas)
            cost += canvas->memoryCost();
    }
#endif
#if ENABLE(WEB_RTC)
    for (auto& channel : m_detachedRTCDataChannels) {
        if (channel)
            cost += channel->memoryCost();
    }
#endif
#if ENABLE(WEBASSEMBLY)
    // We are not supporting WebAssembly Module memory estimation yet.
    for (auto& content : m_wasmMemoryHandlesArray)
        cost += content->sizeInBytes(std::memory_order_relaxed);
#endif
#if ENABLE(WEB_CODECS)
    for (auto& chunk : m_serializedVideoChunks) {
        if (chunk)
            cost += chunk->memoryCost();
    }
    for (auto& frame : m_serializedVideoFrames)
        cost += frame.memoryCost();
#endif

    // for (auto& handle : m_blobHandles)
    //     cost += handle.url().string().sizeInBytes();

    // Account for fast path string memory usage
    switch (m_fastPath) {
    case FastPath::String:
        ASSERT(m_simpleInMemoryPropertyTable.isEmpty());
        cost += m_fastPathString.sizeInBytes();
        break;
    case FastPath::SimpleObject:
        ASSERT(m_fastPathString.isEmpty());
        cost += m_simpleInMemoryPropertyTable.span().size_bytes();
        // Add the memory cost of strings in the simple property table
        for (const auto& entry : m_simpleInMemoryPropertyTable) {
            // Add property name string cost
            cost += entry.propertyName.sizeInBytes();

            // Add value string cost if it's a string
            if (std::holds_alternative<WTF::String>(entry.value)) {
                const auto& str = std::get<WTF::String>(entry.value);
                cost += str.sizeInBytes();
            }
        }

        break;
    case FastPath::Int32Array:
    case FastPath::DoubleArray:
        cost += m_arrayButterflyData.size();
        break;
    case FastPath::DenseArray:
        cost += m_denseArrayElements.span().size_bytes();
        for (const auto& elem : m_denseArrayElements) {
            std::visit(WTF::makeVisitor(
                           [&](JSC::JSValue) { /* already included in byteSize() */ },
                           [&](const String& s) { cost += s.sizeInBytes(); },
                           [&](const SimpleCloneableObject& obj) {
                               cost += obj.properties.span().size_bytes();
                               for (const auto& prop : obj.properties) {
                                   cost += prop.propertyName.sizeInBytes();
                                   if (std::holds_alternative<WTF::String>(prop.value))
                                       cost += std::get<WTF::String>(prop.value).sizeInBytes();
                               }
                           }),
                elem);
        }
        break;
    case FastPath::None:
        break;
    }

    return cost;
}

static ExceptionOr<ArrayBufferContentsArray> prepareArrayBufferTransfers(VM& vm, const Vector<RefPtr<JSC::ArrayBuffer>>& arrayBuffers)
{
    ArrayBufferContentsArray contents;
    if (!contents.tryGrow(arrayBuffers.size()))
        return Exception { OutOfMemoryError };

    CloneConstantPool<JSC::ArrayBuffer*, PtrHash<JSC::ArrayBuffer*>> visited;
    for (const auto& arrayBuffer : arrayBuffers) {
        if (visited.find(arrayBuffer.get()))
            return Exception { DataCloneError, "Transfer list contains duplicate ArrayBuffer"_s };
        if (!visited.add(arrayBuffer.get(), visited.size()))
            return Exception { OutOfMemoryError };
        if (arrayBuffer->isDetached() || arrayBuffer->hasActiveByteLease())
            return Exception { DataCloneError };
    }

    for (size_t arrayBufferIndex = 0; arrayBufferIndex < arrayBuffers.size(); arrayBufferIndex++) {
        if (arrayBuffers[arrayBufferIndex]->isDetachable())
            continue;

        bool result = arrayBuffers[arrayBufferIndex]->transferTo(vm, contents[arrayBufferIndex]);
        if (!result)
            return Exception { OutOfMemoryError };
    }

    return contents;
}

static void commitArrayBufferTransfers(VM& vm, const Vector<RefPtr<JSC::ArrayBuffer>>& arrayBuffers, ArrayBufferContentsArray& contents)
{
    RELEASE_ASSERT(contents.size() == arrayBuffers.size());
    for (size_t index = 0; index < arrayBuffers.size(); ++index) {
        if (arrayBuffers[index]->isDetachable())
            RELEASE_ASSERT(arrayBuffers[index]->transferTo(vm, contents[index]));
    }
}

static void maybeThrowExceptionIfSerializationFailed(JSGlobalObject& lexicalGlobalObject, SerializationReturnCode code)
{
    auto& vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, void());

    switch (code) {
    case SerializationReturnCode::SuccessfullyCompleted:
        break;
    case SerializationReturnCode::StackOverflowError:
        throwException(&lexicalGlobalObject, scope, createStackOverflowError(&lexicalGlobalObject));
        break;
    case SerializationReturnCode::ValidationError:
        throwTypeError(&lexicalGlobalObject, scope, "Unable to deserialize data."_s);
        break;
    case SerializationReturnCode::DataCloneError:
        throwDataCloneError(lexicalGlobalObject, scope);
        break;
    case SerializationReturnCode::OutOfMemoryError:
        throwOutOfMemoryError(&lexicalGlobalObject, scope);
        break;
    case SerializationReturnCode::ExistingExceptionError:
    case SerializationReturnCode::UnspecifiedError:
        break;
    case SerializationReturnCode::InterruptedExecutionError:
        ASSERT_NOT_REACHED();
    }
}

static Exception exceptionForSerializationFailure(SerializationReturnCode code)
{
    ASSERT(code != SerializationReturnCode::SuccessfullyCompleted);

    switch (code) {
    case SerializationReturnCode::StackOverflowError:
        return Exception { StackOverflowError };
    case SerializationReturnCode::ValidationError:
        return Exception { TypeError };
    case SerializationReturnCode::DataCloneError:
        return Exception { DataCloneError };
    case SerializationReturnCode::OutOfMemoryError:
        return Exception { OutOfMemoryError };
    case SerializationReturnCode::ExistingExceptionError:
        return Exception { ExistingExceptionError };
    case SerializationReturnCode::UnspecifiedError:
        return Exception { TypeError };
    case SerializationReturnCode::SuccessfullyCompleted:
    case SerializationReturnCode::InterruptedExecutionError:
        ASSERT_NOT_REACHED();
        return Exception { TypeError };
    }
    ASSERT_NOT_REACHED();
    return Exception { TypeError };
}

// This is based on `checkStrucureForClone`
static bool isObjectFastPathCandidate(Structure* structure)
{
    static constexpr bool verbose = false;

    if (structure->typeInfo().type() != FinalObjectType) {
        dataLogLnIf(verbose, "target is not final object");
        return false;
    }

    if (!structure->canAccessPropertiesQuicklyForEnumeration()) {
        dataLogLnIf(verbose, "target cannot access properties quickly for enumeration");
        return false;
    }

    if (hasIndexedProperties(structure->indexingType())) {
        dataLogLnIf(verbose, "target has indexing mode");
        return false;
    }

    if (structure->isBrandedStructure()) {
        dataLogLnIf(verbose, "target has isBrandedStructure");
        return false;
    }

    if (structure->hasAnyKindOfGetterSetterProperties()) {
        dataLogLnIf(verbose, "target has any kind of getter setter properties");
        return false;
    }

    if (structure->hasNonConfigurableProperties() || structure->hasNonEnumerableProperties()) {
        dataLogLnIf(verbose, "target has non-configurable or non-enumerable properties");
        return false;
    }

    return true;
}

static ExceptionOr<String> prepareCloneString(VM& vm, const String& string)
{
    if (string.isEmpty())
        return String { emptyString() };

    RefPtr<StringImpl> impl = string.impl();
    if (string.length() < 256 || impl->isStatic() || impl->isAtom() || impl->isSymbol()
        || (impl->bufferOwnership() != StringImpl::BufferInternal && impl->bufferOwnership() != StringImpl::BufferOwned)) {
        if (string.is8Bit()) {
            std::span<Latin1Character> characters;
            impl = StringImpl::tryCreateUninitialized(string.length(), characters);
            if (!impl)
                return Exception { OutOfMemoryError };
            memcpy(characters.data(), string.span8().data(), characters.size_bytes());
        } else {
            std::span<char16_t> characters;
            impl = StringImpl::tryCreateUninitialized(string.length(), characters);
            if (!impl)
                return Exception { OutOfMemoryError };
            memcpy(characters.data(), string.span16().data(), characters.size_bytes());
        }
    }

    // A payload may reach multiple VMs, so consumers must never mutate its string flags.
    impl->hash();
    if (auto cost = impl->cost())
        vm.heap.deprecatedReportExtraMemory(cost);
    if (impl->canBecomeAtom())
        impl->setNeverAtomize();
    return String(WTF::move(impl));
}

static ExceptionOr<std::optional<SimpleCloneableValue>> serializeSimpleCloneValue(JSGlobalObject& globalObject, JSValue value)
{
    RELEASE_ASSERT(value);
    if (!value.isCell())
        return std::optional<SimpleCloneableValue>(std::in_place, value);
    if (!value.isString())
        return std::optional<SimpleCloneableValue> {};

    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto string = asString(value)->value(&globalObject);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    auto prepared = prepareCloneString(globalObject.vm(), string);
    if (prepared.hasException())
        return prepared.releaseException();
    return std::optional<SimpleCloneableValue>(std::in_place, prepared.releaseReturnValue());
}

static ExceptionOr<std::optional<Vector<SimpleInMemoryPropertyTableEntry>>> serializeSimpleCloneObject(JSGlobalObject& globalObject, JSObject* object)
{
    auto* structure = object->structure();
    if (!isObjectFastPathCandidate(structure))
        return std::optional<Vector<SimpleInMemoryPropertyTableEntry>> {};

    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    Vector<SimpleInMemoryPropertyTableEntry> properties;
    std::optional<Exception> failure;
    bool supported = true;
    structure->forEachProperty(vm, [&](const PropertyTableEntry& entry) {
        if (entry.key()->isSymbol())
            return true;
        ASSERT(!(entry.attributes() & (PropertyAttribute::DontEnum | PropertyAttribute::Accessor)));

        auto converted = serializeSimpleCloneValue(globalObject, object->getDirect(entry.offset()));
        RETURN_IF_EXCEPTION(scope, false);
        if (converted.hasException()) {
            failure = converted.releaseException();
            return false;
        }
        auto value = converted.releaseReturnValue();
        if (!value) {
            supported = false;
            return false;
        }
        auto key = prepareCloneString(vm, String(entry.key()));
        if (key.hasException()) {
            failure = key.releaseException();
            return false;
        }
        if (!properties.tryAppend({ key.releaseReturnValue(), WTF::move(*value) })) {
            failure = Exception { OutOfMemoryError };
            return false;
        }
        return true;
    });
    ensureStillAliveHere(object);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (failure)
        return WTF::move(*failure);
    if (!supported)
        return std::optional<Vector<SimpleInMemoryPropertyTableEntry>> {};
    return std::optional<Vector<SimpleInMemoryPropertyTableEntry>>(WTF::move(properties));
}
// static bool containsDuplicates(const Vector<RefPtr<ImageBitmap>>& imageBitmaps)
// {
//     HashSet<ImageBitmap*> visited;
//     for (auto& imageBitmap : imageBitmaps) {
//         if (!visited.add(imageBitmap.get()))
//             return true;
//     }
//     return false;
// }

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
static bool canOffscreenCanvasesDetach(const Vector<RefPtr<OffscreenCanvas>>& offscreenCanvases)
{
    HashSet<OffscreenCanvas*> visited;
    for (auto& offscreenCanvas : offscreenCanvases) {
        if (!offscreenCanvas->canDetach())
            return false;
        // Check the return value of add, we should not encounter duplicates.
        if (!visited.add(offscreenCanvas.get()))
            return false;
    }
    return true;
}
#endif

#if ENABLE(WEB_RTC)
static bool canDetachRTCDataChannels(const Vector<Ref<RTCDataChannel>>& channels)
{
    HashSet<RTCDataChannel*> visited;
    for (auto& channel : channels) {
        if (!channel->canDetach())
            return false;
        // Check the return value of add, we should not encounter duplicates.
        if (!visited.add(channel.ptr()))
            return false;
    }
    return true;
}
#endif

RefPtr<SerializedScriptValue> SerializedScriptValue::create(JSC::JSGlobalObject& globalObject, JSC::JSValue value, SerializationForStorage forStorage, SerializationErrorMode throwExceptions, SerializationContext serializationContext, SerializationForCrossProcessTransfer forTransfer)
{
    Vector<RefPtr<MessagePort>> dummyPorts;
    auto result = create(globalObject, value, {}, dummyPorts, forStorage, throwExceptions, serializationContext, forTransfer);
    if (result.hasException())
        return nullptr;
    return result.releaseReturnValue();
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::create(JSGlobalObject& globalObject, JSValue value, Vector<JSC::Strong<JSC::JSObject>>&& transferList, Vector<RefPtr<MessagePort>>& messagePorts, SerializationForStorage forStorage, SerializationContext serializationContext, SerializationForCrossProcessTransfer forTransfer)
{
    return create(globalObject, value, WTF::move(transferList), messagePorts, forStorage, SerializationErrorMode::Throwing, serializationContext, forTransfer);
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::create(JSGlobalObject& lexicalGlobalObject, JSValue value, Vector<JSC::Strong<JSC::JSObject>>&& transferList, Vector<RefPtr<MessagePort>>& messagePorts, SerializationForStorage forStorage, SerializationErrorMode throwExceptions, SerializationContext context, SerializationForCrossProcessTransfer forTransfer)
{
    auto& vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = prepare(lexicalGlobalObject, value, WTF::move(transferList), messagePorts, forStorage, context, forTransfer);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (result.hasException()) {
        auto exception = result.releaseException();
        if (throwExceptions == SerializationErrorMode::Throwing) {
            propagateException(lexicalGlobalObject, scope, WTF::move(exception));
            return Exception { ExistingExceptionError };
        }
        return exception;
    }
    auto prepared = result.releaseReturnValue();
    auto validation = prepared.validateTransfers();
    if (validation.hasException()) {
        auto exception = validation.releaseException();
        if (throwExceptions == SerializationErrorMode::Throwing) {
            propagateException(lexicalGlobalObject, scope, WTF::move(exception));
            return Exception { ExistingExceptionError };
        }
        return exception;
    }
    return prepared.commit(vm);
}

ExceptionOr<SerializedScriptValue::Prepared> SerializedScriptValue::prepare(JSGlobalObject& lexicalGlobalObject, JSValue value, Vector<JSC::Strong<JSC::JSObject>>&& transferList, Vector<RefPtr<MessagePort>>& messagePorts, SerializationForStorage forStorage, SerializationContext context, SerializationForCrossProcessTransfer forTransfer)
{
    VM& vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Fast path optimization: for postMessage/structuredClone with pure strings and no transfers
    const bool canUseFastPath = (context == SerializationContext::WorkerPostMessage || context == SerializationContext::WindowPostMessage || context == SerializationContext::Default)
        && forStorage == SerializationForStorage::No
        && forTransfer == SerializationForCrossProcessTransfer::No
        && transferList.isEmpty()
        && messagePorts.isEmpty();

    if (canUseFastPath) {
        if (value.isString()) {
            auto stringValue = asString(value)->value(&lexicalGlobalObject);
            RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
            return Prepared::fromResult(SerializedScriptValue::createStringFastPath(vm, stringValue));
        }

        if (auto* array = dynamicDowncast<JSArray>(value); array && array->structure()->maxOffset() == invalidOffset) {
            unsigned length = array->length();
            auto arrayType = array->indexingType();

            if ((arrayType == ArrayWithInt32 || arrayType == ArrayWithDouble)
                && length <= array->butterfly()->vectorLength()
                && !array->structure()->holesMustForwardToPrototype(array)) {
                CheckedSize checkedByteSize = length;
                checkedByteSize *= sizeof(EncodedJSValue);
                if (checkedByteSize.hasOverflowed())
                    return Exception { OutOfMemoryError };
                size_t byteSize = checkedByteSize.value();

                if (arrayType == ArrayWithInt32) {
                    auto* data = array->butterfly()->contiguous().data();
                    if (!containsHole(data, length)) {
                        Vector<uint8_t> buffer;
                        if (!buffer.tryAppend(std::span { reinterpret_cast<const uint8_t*>(data), byteSize }))
                            return Exception { OutOfMemoryError };
                        ensureStillAliveHere(array);
                        return Prepared::fromResult(SerializedScriptValue::createInt32ArrayFastPath(WTF::move(buffer), length));
                    }
                } else {
                    static_assert(sizeof(double) == sizeof(EncodedJSValue));
                    auto* data = array->butterfly()->contiguousDouble().data();
                    if (!containsHole(data, length)) {
                        Vector<uint8_t> buffer;
                        if (!buffer.tryAppend(std::span { reinterpret_cast<const uint8_t*>(data), byteSize }))
                            return Exception { OutOfMemoryError };
                        ensureStillAliveHere(array);
                        return Prepared::fromResult(SerializedScriptValue::createDoubleArrayFastPath(WTF::move(buffer), length));
                    }
                }
            }

            if (arrayType == ArrayWithContiguous
                && length <= array->butterfly()->vectorLength()
                && !array->structure()->holesMustForwardToPrototype(array)) {
                auto* data = array->butterfly()->contiguous().data();
                Vector<DenseArrayElement> elements;
                if (!elements.tryReserveInitialCapacity(length))
                    return Exception { OutOfMemoryError };
                CloneConstantPool<JSObject*, PtrHash<JSObject*>> seenObjects;
                bool supported = true;

                for (unsigned i = 0; i < length; i++) {
                    JSValue elem = data[i].get();
                    if (!elem) {
                        supported = false;
                        break;
                    }
                    auto converted = serializeSimpleCloneValue(lexicalGlobalObject, elem);
                    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
                    if (converted.hasException())
                        return converted.releaseException();
                    if (auto simple = converted.releaseReturnValue()) {
                        elements.append(std::visit([](auto&& item) -> DenseArrayElement { return WTF::move(item); }, WTF::move(*simple)));
                        continue;
                    }

                    auto* object = elem.getObject();
                    if (!object || seenObjects.find(object)) {
                        supported = false;
                        break;
                    }
                    auto convertedObject = serializeSimpleCloneObject(lexicalGlobalObject, object);
                    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
                    if (convertedObject.hasException())
                        return convertedObject.releaseException();
                    auto properties = convertedObject.releaseReturnValue();
                    if (!properties) {
                        supported = false;
                        break;
                    }
                    if (!seenObjects.add(object, seenObjects.size()))
                        return Exception { OutOfMemoryError };
                    elements.append(SimpleCloneableObject { WTF::move(*properties) });
                }
                ensureStillAliveHere(array);
                if (supported)
                    return Prepared::fromResult(SerializedScriptValue::createDenseArrayFastPath(WTF::move(elements)));
            }
        }

        if (auto* object = value.getObject()) {
            auto converted = serializeSimpleCloneObject(lexicalGlobalObject, object);
            RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
            if (converted.hasException())
                return converted.releaseException();
            if (auto properties = converted.releaseReturnValue())
                return Prepared::fromResult(SerializedScriptValue::createObjectFastPath(WTF::move(*properties)));
        }
    }

    Vector<RefPtr<JSC::ArrayBuffer>> arrayBuffers;
    // Vector<RefPtr<ImageBitmap>> imageBitmaps;
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    Vector<RefPtr<OffscreenCanvas>> offscreenCanvases;
#endif
#if ENABLE(WEB_RTC)
    Vector<Ref<RTCDataChannel>> dataChannels;
#endif
#if ENABLE(WEB_CODECS)
    Vector<Ref<WebCodecsVideoFrame>> transferredVideoFrames;
#endif
    CloneConstantPool<JSC::JSObject*, PtrHash<JSC::JSObject*>> uniqueTransferables;
    for (auto& transferable : transferList) {
        if (uniqueTransferables.find(transferable.get())) {
            if (toPossiblySharedArrayBuffer(vm, transferable.get())) {
                return Exception { DataCloneError, "Transfer list contains duplicate ArrayBuffer"_s };
            } else if (JSMessagePort::toWrapped(vm, transferable.get())) {
                return Exception { DataCloneError, "Transfer list contains duplicate MessagePort"_s };
            } else {
                return Exception { DataCloneError, "Duplicate transferable for structured clone"_s };
            }
        }
        if (!uniqueTransferables.add(transferable.get(), uniqueTransferables.size()))
            return Exception { OutOfMemoryError };

        if (auto arrayBuffer = toPossiblySharedArrayBuffer(vm, transferable.get())) {
            if (arrayBuffer->isDetached() || arrayBuffer->isShared())
                return Exception { DataCloneError };
            if (arrayBuffer->isWasmMemory()) {
                throwVMTypeError(&lexicalGlobalObject, scope, errorMessageForTransfer(arrayBuffer));
                return Exception { ExistingExceptionError };
            }
            if (!arrayBuffers.tryAppend(WTF::move(arrayBuffer)))
                return Exception { OutOfMemoryError };
            continue;
        }
        if (auto port = JSMessagePort::toWrapped(vm, transferable.get())) {
            if (port->isDetached())
                return Exception { DataCloneError, "MessagePort in transfer list is already detached"_s };
            if (!messagePorts.tryAppend(WTF::move(port)))
                return Exception { OutOfMemoryError };
            continue;
        }

        // if (auto imageBitmap = JSImageBitmap::toWrapped(vm, transferable.get())) {
        //     if (imageBitmap->isDetached())
        //         return Exception { DataCloneError };
        //     if (!imageBitmap->originClean())
        //         return Exception { DataCloneError };

        //     imageBitmaps.append(WTF::move(imageBitmap));
        //     continue;
        // }

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        if (auto offscreenCanvas = JSOffscreenCanvas::toWrapped(vm, transferable.get())) {
            offscreenCanvases.append(WTF::move(offscreenCanvas));
            continue;
        }
#endif

#if ENABLE(WEB_RTC)
        if (auto channel = JSRTCDataChannel::toWrapped(vm, transferable.get())) {
            dataChannels.append(*channel);
            continue;
        }
#endif

#if ENABLE(WEB_CODECS)
        if (auto videoFrame = JSWebCodecsVideoFrame::toWrapped(vm, transferable.get())) {
            if (videoFrame->isDetached())
                return Exception { DataCloneError };
            transferredVideoFrames.append(*videoFrame);
            continue;
        }
#endif
        return Exception { DataCloneError };
    }

    // if (containsDuplicates(imageBitmaps))
    //     return Exception { DataCloneError };
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    if (!canOffscreenCanvasesDetach(offscreenCanvases))
        return Exception { InvalidStateError };
#endif
#if ENABLE(WEB_RTC)
    if (!canDetachRTCDataChannels(dataChannels))
        return Exception { DataCloneError };
#endif

    Vector<uint8_t> buffer;
    // Vector<URLKeepingBlobAlive> blobHandles;
#if ENABLE(WEBASSEMBLY)
    WasmModuleArray wasmModules;
    WasmMemoryHandleArray wasmMemoryHandles;
#endif
    ArrayBufferContentsArray sharedBuffers;
    Bun::Bindgen::SharedCloneResources sharedNativeResources;
#if ENABLE(WEB_CODECS)
    Vector<RefPtr<WebCodecsEncodedVideoChunkStorage>> serializedVideoChunks;
    Vector<RefPtr<WebCodecsVideoFrame>> serializedVideoFrames;
#endif
    //     auto code = CloneSerializer::serialize(&lexicalGlobalObject, value, messagePorts, arrayBuffers, imageBitmaps,
    // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    //         offscreenCanvases,
    // #endif
    // #if ENABLE(WEB_RTC)
    //         dataChannels,
    // #endif
    // #if ENABLE(WEB_CODECS)
    //         serializedVideoChunks,
    //         serializedVideoFrames,
    // #endif
    // #if ENABLE(WEBASSEMBLY)
    //         wasmModules,
    //         wasmMemoryHandles,
    // #endif
    //         blobHandles, buffer, context, *sharedBuffers, forStorage);
    auto code = CloneSerializer::serialize(&lexicalGlobalObject, value, messagePorts, arrayBuffers,
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        offscreenCanvases,
#endif
#if ENABLE(WEB_RTC)
        dataChannels,
#endif
#if ENABLE(WEB_CODECS)
        serializedVideoChunks,
        serializedVideoFrames,
#endif
#if ENABLE(WEBASSEMBLY)
        wasmModules,
        wasmMemoryHandles,
#endif
        buffer, context, sharedBuffers, forStorage, forTransfer, sharedNativeResources);

    if (scope.exception()) [[unlikely]]
        RELEASE_AND_RETURN(scope, Exception { ExistingExceptionError });
    if (code != SerializationReturnCode::SuccessfullyCompleted) [[unlikely]]
        RELEASE_AND_RETURN(scope, exceptionForSerializationFailure(code));

    auto arrayBufferContentsArray = prepareArrayBufferTransfers(vm, arrayBuffers);
    if (arrayBufferContentsArray.hasException()) {
        RELEASE_AND_RETURN(scope, arrayBufferContentsArray.releaseException());
    }

    // auto backingStores = ImageBitmap::detachBitmaps(WTF::move(imageBitmaps));

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    Vector<std::unique_ptr<DetachedOffscreenCanvas>> detachedCanvases;
    if (!detachedCanvases.tryGrow(offscreenCanvases.size()))
        return Exception { OutOfMemoryError };
#endif
#if ENABLE(WEB_RTC)
    Vector<std::unique_ptr<DetachedRTCDataChannel>> detachedRTCDataChannels;
    if (!detachedRTCDataChannels.tryGrow(dataChannels.size()))
        return Exception { OutOfMemoryError };
#endif

#if ENABLE(WEB_CODECS)
    Vector<WebCodecsVideoFrameData> serializedVideoFrameData;
    if (!serializedVideoFrameData.tryReserveInitialCapacity(serializedVideoFrames.size()))
        return Exception { OutOfMemoryError };
    for (auto& frame : serializedVideoFrames)
        serializedVideoFrameData.append(frame->data());
#endif

    auto result = createWithArgs(WTF::move(buffer), arrayBufferContentsArray.releaseReturnValue(), WTF::move(sharedBuffers)
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
                                                                                                       ,
        WTF::move(detachedCanvases)
#endif
#if ENABLE(WEB_RTC)
            ,
        WTF::move(detachedRTCDataChannels)
#endif
#if ENABLE(WEBASSEMBLY)
            ,
        WTF::move(wasmModules), WTF::move(wasmMemoryHandles)
#endif
#if ENABLE(WEB_CODECS)
                                    ,
        WTF::move(serializedVideoChunks), WTF::move(serializedVideoFrameData)
#endif
    );
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (result.hasException())
        return result.releaseException();
    Prepared prepared { result.releaseReturnValue() };
    prepared.m_value->m_sharedNativeResources = WTF::move(sharedNativeResources);
    prepared.m_value->m_memoryCost = prepared.m_value->computeMemoryCost();
    prepared.m_arrayBuffers = WTF::move(arrayBuffers);
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    prepared.m_offscreenCanvases = WTF::move(offscreenCanvases);
#endif
#if ENABLE(WEB_RTC)
    prepared.m_dataChannels = WTF::move(dataChannels);
#endif
#if ENABLE(WEB_CODECS)
    prepared.m_videoFrames = WTF::move(transferredVideoFrames);
#endif
    return prepared;
}

SerializedScriptValue::Prepared::Prepared(Ref<SerializedScriptValue>&& value)
    : m_value(WTF::move(value))
{
}

SerializedScriptValue::Prepared::Prepared(Prepared&&) noexcept = default;
SerializedScriptValue::Prepared::~Prepared() = default;

ExceptionOr<SerializedScriptValue::Prepared> SerializedScriptValue::Prepared::fromResult(ExceptionOr<Ref<SerializedScriptValue>>&& result)
{
    if (result.hasException())
        return result.releaseException();
    return Prepared { result.releaseReturnValue() };
}

ExceptionOr<void> SerializedScriptValue::Prepared::validateTransfers() const
{
    RELEASE_ASSERT(m_value);
    for (const auto& arrayBuffer : m_arrayBuffers) {
        if (arrayBuffer->isDetached() || arrayBuffer->hasActiveByteLease())
            return Exception { DataCloneError };
    }
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    for (const auto& canvas : m_offscreenCanvases) {
        if (!canvas->canDetach())
            return Exception { InvalidStateError };
    }
#endif
#if ENABLE(WEB_RTC)
    for (const auto& channel : m_dataChannels) {
        if (!channel->canDetach())
            return Exception { DataCloneError };
    }
#endif
#if ENABLE(WEB_CODECS)
    for (const auto& frame : m_videoFrames) {
        if (frame->isDetached())
            return Exception { DataCloneError };
    }
#endif
    return {};
}

Ref<SerializedScriptValue> SerializedScriptValue::Prepared::commit(VM& vm)
{
    RELEASE_ASSERT(!validateTransfers().hasException());
    auto serialized = m_value.releaseNonNull();

#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
    for (size_t index = 0; index < m_offscreenCanvases.size(); ++index)
        serialized->m_detachedOffscreenCanvases[index] = m_offscreenCanvases[index]->detach();
#endif
#if ENABLE(WEB_RTC)
    for (size_t index = 0; index < m_dataChannels.size(); ++index)
        serialized->m_detachedRTCDataChannels[index] = m_dataChannels[index]->detach();
#endif
#if ENABLE(WEB_CODECS)
    for (auto& videoFrame : m_videoFrames)
        videoFrame->close();
#endif

    commitArrayBufferTransfers(vm, m_arrayBuffers, serialized->m_arrayBufferContentsArray);
    serialized->m_memoryCost = serialized->computeMemoryCost();
    return serialized;
}

RefPtr<SerializedScriptValue> SerializedScriptValue::create(StringView string)
{
    Vector<uint8_t> buffer;
    if (!CloneSerializer::serialize(string, buffer))
        return nullptr;
    auto result = createWithArgs(WTF::move(buffer));
    if (result.hasException())
        return nullptr;
    return result.releaseReturnValue();
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::createStringFastPath(VM& vm, const String& string)
{
    auto prepared = prepareCloneString(vm, string);
    if (prepared.hasException())
        return prepared.releaseException();
    return createWithArgs(prepared.releaseReturnValue());
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::createObjectFastPath(WTF::Vector<SimpleInMemoryPropertyTableEntry>&& object)
{
    return createWithArgs(WTF::move(object));
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::createInt32ArrayFastPath(Vector<uint8_t>&& data, uint32_t length)
{
    return createWithArgs(WTF::move(data), length, FastPath::Int32Array);
}

ExceptionOr<Ref<SerializedScriptValue>> SerializedScriptValue::createDoubleArrayFastPath(Vector<uint8_t>&& data, uint32_t length)
{
    return createWithArgs(WTF::move(data), length, FastPath::DoubleArray);
}

RefPtr<SerializedScriptValue> SerializedScriptValue::create(JSContextRef originContext, JSValueRef apiValue, JSValueRef* exception)
{
    JSGlobalObject* lexicalGlobalObject = toJS(originContext);
    auto& vm = JSC::getVM(lexicalGlobalObject);
    JSLockHolder locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    JSValue value = toJS(lexicalGlobalObject, apiValue);
    auto serializedValue = SerializedScriptValue::create(*lexicalGlobalObject, value);
    if (scope.exception()) [[unlikely]] {
        if (exception)
            *exception = toRef(lexicalGlobalObject, scope.exception()->value());
        (void)scope.tryClearException();
        return nullptr;
    }
    ASSERT(serializedValue);
    return serializedValue;
}

String SerializedScriptValue::toString() const
{
    return CloneDeserializer::deserializeString(m_data);
}

Ref<JSC::ArrayBuffer> SerializedScriptValue::toArrayBuffer()
{
    if (this->m_data.size() == 0) {
        return ArrayBuffer::create(static_cast<size_t>(0), static_cast<unsigned>(1));
    }

    this->ref();
    auto arrayBuffer = ArrayBuffer::createFromBytes(
        { this->m_data.begin(), this->m_data.size() }, createSharedTask<void(void*)>([protectedThis = Ref { *this }](void* p) {
            protectedThis->deref();
        }));

    // Note: using the SharedArrayBufferContents::create function directly didn't work.
    arrayBuffer->makeShared();

    return arrayBuffer;
}

JSC::JSValue SerializedScriptValue::fromBytes(JSC::JSGlobalObject& globalObject, std::span<const uint8_t> bytes)
{
    auto& vm = globalObject.vm();
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto result = CloneDeserializer::deserialize(&globalObject, &globalObject, {}
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
        ,
        {}
#endif
#if ENABLE(WEB_RTC)
        ,
        {}
#endif
        ,
        nullptr, bytes, nullptr
#if ENABLE(WEBASSEMBLY)
        ,
        nullptr, nullptr
#endif
#if ENABLE(WEB_CODECS)
        ,
        {}, {}
#endif
    );

    RETURN_IF_EXCEPTION(throwScope, {});
    maybeThrowExceptionIfSerializationFailed(globalObject, result.second);
    RETURN_IF_EXCEPTION(throwScope, {});

    return result.first;
}

// JSValue SerializedScriptValue::deserialize(JSGlobalObject& lexicalGlobalObject, JSGlobalObject* globalObject, SerializationErrorMode throwExceptions, bool* didFail)
// {
//     return deserialize(lexicalGlobalObject, globalObject, {}, throwExceptions, didFail);
// }

JSValue SerializedScriptValue::deserialize(JSGlobalObject& lexicalGlobalObject, JSGlobalObject* globalObject, SerializationErrorMode throwExceptions, bool* didFail)
{
    Vector<RefPtr<MessagePort>> dummyPorts;
    return deserialize(lexicalGlobalObject, globalObject, dummyPorts, throwExceptions, didFail);
}

static JSValue deserializeSimpleCloneValue(VM& vm, const SimpleCloneableValue& value)
{
    return std::visit(WTF::makeVisitor(
                          [](JSValue value) { return value; },
                          [&](const String& string) -> JSValue { return jsString(vm, string); }),
        value);
}

class CloneObjectDeserializer {
    WTF_FORBID_HEAP_ALLOCATION;

public:
    DeserializationResult deserialize(JSGlobalObject& lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<SimpleInMemoryPropertyTableEntry>& properties)
    {
        auto& vm = lexicalGlobalObject.vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        bool matchingKeys = m_identifiers.size() == properties.size();
        if (matchingKeys) {
            for (size_t index = 0; index < properties.size(); ++index) {
                if (m_identifiers[index].string() != properties[index].propertyName) {
                    matchingKeys = false;
                    break;
                }
            }
        }
        if (!matchingKeys) {
            Vector<Identifier> identifiers;
            if (!identifiers.tryReserveInitialCapacity(properties.size()))
                return { {}, SerializationReturnCode::OutOfMemoryError };
            for (const auto& property : properties)
                identifiers.append(Identifier::fromString(vm, property.propertyName));
            m_identifiers = WTF::move(identifiers);
            m_structure = nullptr;
        }

        auto* object = m_structure && !m_structure->outOfLineCapacity()
            ? JSFinalObject::create(vm, m_structure)
            : constructEmptyObject(globalObject, globalObject->objectPrototype(), std::min(static_cast<unsigned>(properties.size()), JSFinalObject::maxInlineCapacity));
        RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
        for (size_t index = 0; index < properties.size(); ++index) {
            auto value = deserializeSimpleCloneValue(vm, properties[index].value);
            RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
            object->putDirect(vm, m_identifiers[index], value);
            RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
        }
        m_structure = object->structure();
        return { object, SerializationReturnCode::SuccessfullyCompleted };
    }

private:
    Vector<Identifier> m_identifiers;
    Structure* m_structure { nullptr };
};

DeserializationResult SerializedScriptValue::deserializeFastPath(JSGlobalObject& lexicalGlobalObject, JSGlobalObject* globalObject)
{
    VM& vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    switch (m_fastPath) {
    case FastPath::String:
        return { jsString(vm, m_fastPathString), SerializationReturnCode::SuccessfullyCompleted };
    case FastPath::SimpleObject: {
        CloneObjectDeserializer objectDeserializer;
        RELEASE_AND_RETURN(scope, objectDeserializer.deserialize(lexicalGlobalObject, globalObject, m_simpleInMemoryPropertyTable));
    }
    case FastPath::DenseArray: {
        unsigned length = m_denseArrayElements.size();
        auto* structure = globalObject->arrayStructureForIndexingTypeDuringAllocation(ArrayWithContiguous);
        auto* array = JSArray::tryCreate(vm, structure, length);
        if (!array)
            return { {}, SerializationReturnCode::OutOfMemoryError };

        CloneObjectDeserializer objectDeserializer;
        for (unsigned index = 0; index < length; ++index) {
            auto result = std::visit(WTF::makeVisitor(
                                         [](JSValue value) -> DeserializationResult { return { value, SerializationReturnCode::SuccessfullyCompleted }; },
                                         [&](const String& string) -> DeserializationResult { return { jsString(vm, string), SerializationReturnCode::SuccessfullyCompleted }; },
                                         [&](const SimpleCloneableObject& object) { return objectDeserializer.deserialize(lexicalGlobalObject, globalObject, object.properties); }),
                m_denseArrayElements[index]);
            RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
            if (result.second != SerializationReturnCode::SuccessfullyCompleted)
                return result;
            array->putDirectIndex(globalObject, index, result.first);
            RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
        }
        return { array, SerializationReturnCode::SuccessfullyCompleted };
    }
    case FastPath::Int32Array:
    case FastPath::DoubleArray: {
        auto arrayType = m_fastPath == FastPath::Int32Array ? ArrayWithInt32 : ArrayWithDouble;
        auto* structure = globalObject->arrayStructureForIndexingTypeDuringAllocation(arrayType);
        auto* array = JSArray::tryCreate(vm, structure, m_arrayLength);
        if (!array)
            return { {}, SerializationReturnCode::OutOfMemoryError };
        RELEASE_ASSERT(m_arrayButterflyData.size() == static_cast<size_t>(m_arrayLength) * sizeof(EncodedJSValue));
        if (array->indexingType() == arrayType) {
            if (arrayType == ArrayWithDouble)
                memcpy(array->butterfly()->contiguousDouble().data(), m_arrayButterflyData.span().data(), m_arrayButterflyData.size());
            else
                memcpy(array->butterfly()->contiguous().data(), m_arrayButterflyData.span().data(), m_arrayButterflyData.size());
        } else {
            for (unsigned index = 0; index < m_arrayLength; ++index) {
                JSValue value;
                if (arrayType == ArrayWithDouble) {
                    double number;
                    memcpy(&number, m_arrayButterflyData.span().data() + static_cast<size_t>(index) * sizeof(number), sizeof(number));
                    value = jsNumber(number);
                } else {
                    EncodedJSValue encoded;
                    memcpy(&encoded, m_arrayButterflyData.span().data() + static_cast<size_t>(index) * sizeof(encoded), sizeof(encoded));
                    value = JSValue::decode(encoded);
                }
                array->putDirectIndex(globalObject, index, value);
                RETURN_IF_EXCEPTION(scope, std::make_pair(JSValue(), SerializationReturnCode::ExistingExceptionError));
            }
        }
        return { array, SerializationReturnCode::SuccessfullyCompleted };
    }
    case FastPath::None:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSValue SerializedScriptValue::deserialize(JSGlobalObject& lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<RefPtr<MessagePort>>& messagePorts, SerializationErrorMode throwExceptions, bool* didFail)
{
    auto& vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = m_fastPath != FastPath::None
        ? deserializeFastPath(lexicalGlobalObject, globalObject)
        : CloneDeserializer::deserialize(&lexicalGlobalObject, globalObject, messagePorts
#if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
              ,
              WTF::move(m_detachedOffscreenCanvases)
#endif
#if ENABLE(WEB_RTC)
                  ,
              WTF::move(m_detachedRTCDataChannels)
#endif
                  ,
              &m_arrayBufferContentsArray, m_data.span(), &m_sharedBufferContentsArray
#if ENABLE(WEBASSEMBLY)
              ,
              &m_wasmModulesArray, &m_wasmMemoryHandlesArray
#endif
#if ENABLE(WEB_CODECS)
              ,
              WTF::move(m_serializedVideoChunks), WTF::move(m_serializedVideoFrames)
#endif
              , m_sharedNativeResources.span());
    if (scope.exception() || throwExceptions == SerializationErrorMode::Throwing) [[unlikely]]
        maybeThrowExceptionIfSerializationFailed(lexicalGlobalObject, result.second);
    if (didFail)
        *didFail = scope.exception() || result.second != SerializationReturnCode::SuccessfullyCompleted;
    RETURN_IF_EXCEPTION(scope, {});

    return result.first;
}
// JSValue SerializedScriptValue::deserialize(JSGlobalObject& lexicalGlobalObject, JSGlobalObject* globalObject, const Vector<String>& blobURLs, const Vector<String>& blobFilePaths, SerializationErrorMode throwExceptions, bool* didFail)
// {
//     //     DeserializationResult result = CloneDeserializer::deserialize(&lexicalGlobalObject, globalObject, messagePorts, WTF::move(m_backingStores)
//     // #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
//     //                                                                                                                         ,
//     //         WTF::move(m_detachedOffscreenCanvases)
//     // #endif
//     // #if ENABLE(WEB_RTC)
//     //             ,
//     //         WTF::move(m_detachedRTCDataChannels)
//     // #endif
//     //             ,
//     //         m_arrayBufferContentsArray.get(), m_data, blobURLs, blobFilePaths, m_sharedBufferContentsArray.get()
//     // #if ENABLE(WEBASSEMBLY)
//     //                                                                                ,
//     //         m_wasmModulesArray.get(), m_wasmMemoryHandlesArray.get()
//     // #endif
//     // #if ENABLE(WEB_CODECS)
//     //                                       ,
//     //         WTF::move(m_serializedVideoChunks), WTF::move(m_serializedVideoFrames)
//     // #endif
//     //     );
//     DeserializationResult result = CloneDeserializer::deserialize(&lexicalGlobalObject, globalObject
// #if ENABLE(OFFSCREEN_CANVAS_IN_WORKERS)
//         ,
//         WTF::move(m_detachedOffscreenCanvases)
// #endif
// #if ENABLE(WEB_RTC)
//             ,
//         WTF::move(m_detachedRTCDataChannels)
// #endif
//             ,
//         m_arrayBufferContentsArray.get(), m_data, blobURLs, blobFilePaths, m_sharedBufferContentsArray.get()
// #if ENABLE(WEBASSEMBLY)
//                                                                                ,
//         m_wasmModulesArray.get(), m_wasmMemoryHandlesArray.get()
// #endif
// #if ENABLE(WEB_CODECS)
//                                       ,
//         WTF::move(m_serializedVideoChunks), WTF::move(m_serializedVideoFrames)
// #endif
//     );
//     if (didFail)
//         *didFail = result.second != SerializationReturnCode::SuccessfullyCompleted;
//     if (throwExceptions == SerializationErrorMode::Throwing)
//         maybeThrowExceptionIfSerializationFailed(lexicalGlobalObject, result.second);
//     return result.first ? result.first : jsNull();
// }

JSValueRef SerializedScriptValue::deserialize(JSContextRef destinationContext, JSValueRef* exception)
{
    JSGlobalObject* lexicalGlobalObject = toJS(destinationContext);
    auto& vm = JSC::getVM(lexicalGlobalObject);
    JSLockHolder locker(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    JSValue value = deserialize(*lexicalGlobalObject, lexicalGlobalObject);
    if (scope.exception()) [[unlikely]] {
        if (exception)
            *exception = toRef(lexicalGlobalObject, scope.exception()->value());
        (void)scope.tryClearException();
        return nullptr;
    }
    ASSERT(value);
    return toRef(lexicalGlobalObject, value);
}

uint32_t SerializedScriptValue::wireFormatVersion()
{
    return CurrentVersion;
}

// Vector<String> SerializedScriptValue::blobURLs() const
// {
//     return m_blobHandles.map([](auto& handle) {
//         return handle.url().string().isolatedCopy();
//     });
// }

// void SerializedScriptValue::writeBlobsToDiskForIndexedDB(CompletionHandler<void(IDBValue&&)>&& completionHandler)
// {
//     ASSERT(isMainThread());
//     ASSERT(hasBlobURLs());

//     blobRegistry().writeBlobsToTemporaryFilesForIndexedDB(blobURLs(), [completionHandler = WTF::move(completionHandler), this, protectedThis = Ref { *this }](auto&& blobFilePaths) mutable {
//         ASSERT(isMainThread());

//         if (blobFilePaths.isEmpty()) {
//             // We should have successfully written blobs to temporary files.
//             // If we failed, then we can't successfully store this record.
//             completionHandler({});
//             return;
//         }

//         ASSERT(m_blobHandles.size() == blobFilePaths.size());

//         completionHandler({ *this, blobURLs(), blobFilePaths });
//     });
// }

// IDBValue SerializedScriptValue::writeBlobsToDiskForIndexedDBSynchronously()
// {
//     ASSERT(!isMainThread());

//     BinarySemaphore semaphore;
//     IDBValue value;
//     callOnMainThread([this, &semaphore, &value] {
//         writeBlobsToDiskForIndexedDB([&semaphore, &value](IDBValue&& result) {
//             ASSERT(isMainThread());
//             value.setAsIsolatedCopy(result);

//             semaphore.signal();
//         });
//     });
//     semaphore.wait();

//     return value;
// }

} // namespace WebCore
