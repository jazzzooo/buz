

#include "root.h"
#include "BunHighway.h"

#include "ZigGlobalObject.h"
#include "WebCoreJSBuiltins.h"
#include "JavaScriptCore/ExceptionHelpers.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/Error.h"
#include "JavaScriptCore/JSArrayBufferView.h"
#include "JavaScriptCore/JSCell.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "BufferEncodingType.h"
#include "JavaScriptCore/JSCJSValue.h"

#include "JSBuffer.h"
#include "SchemaBindings.h"

#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/ExceptionScope.h"

#include "DOMClientIsoSubspaces.h"
#include "DOMIsoSubspaces.h"
#include "JSDOMBinding.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMGlobalObject.h"
#include "JSDOMOperation.h"
#include "JSDOMWrapperCache.h"
#include "ScriptExecutionContext.h"
#include "WebCoreJSClientData.h"
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/HeapAnalyzer.h>

#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/LazyClassStructure.h>
#include <JavaScriptCore/LazyClassStructureInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>

#include <JavaScriptCore/JSDestructibleObjectHeapCellType.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/SubspaceInlines.h>
#include <wtf/CheckedArithmetic.h>
#include <wtf/MathExtras.h>
#include <wtf/GetPtr.h>
#include <wtf/PointerPreparations.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/BuiltinNames.h>

#include "JSBufferEncodingType.h"
#include "ErrorCode.h"
#include "wtf/Assertions.h"
#include "wtf/Forward.h"
#include "wtf/SIMDUTF.h"
#include <JavaScriptCore/JSBase.h>
#if ENABLE(MEDIA_SOURCE)
#include "BufferMediaSource.h"
#include "JSMediaSource.h"
#endif

#if OS(WINDOWS)
#include <windows.h>
#endif

#include <atomic>
#include <bit>

// #include <JavaScriptCore/JSTypedArrayViewPrototype.h>
#include <JavaScriptCore/JSArrayBufferViewInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSObjectInlines.h>

static std::atomic_bool zeroFillBuffers { false };

static JSC::JSUint8Array* bindgenUint8Array(JSC::JSValue value)
{
    return uncheckedDowncast<JSC::JSUint8Array>(value);
}

static JSC::JSArrayBufferView* bindgenArrayBufferView(JSC::JSValue value)
{
    return uncheckedDowncast<JSC::JSArrayBufferView>(value);
}

void Bun::Bindgen::Engine::bunBindgenEngine_Process_setZeroFillBuffers(
    const BunBindgenEngine_Process_setZeroFillBuffers_Arguments& args)
{
    zeroFillBuffers.store(args.value, std::memory_order_relaxed);
}

using namespace JSC;
using namespace WebCore;

static_assert(std::is_same_v<JSBigInt::Digit, uint64_t>, "all Buffer BigInt functions assume bigint digits are 64 bits");

namespace Bun {

// Use a JSString* here to avoid unnecessarily joining the rope string.
// If we're only getting the length property, it won't join the rope string.
std::optional<double> byteLength(JSC::JSString* str, JSC::JSGlobalObject* lexicalGlobalObject, WebCore::BufferEncodingType encoding)
{
    if (str->length() == 0)
        return 0;

    switch (encoding) {

    case WebCore::BufferEncodingType::ucs2:
    case WebCore::BufferEncodingType::utf16le: {
        // https://github.com/nodejs/node/blob/e676942f814915b2d24fc899bb42dc71ae6c8226/lib/buffer.js#L600
        return str->length() * 2;
    }

    case WebCore::BufferEncodingType::latin1:
    case WebCore::BufferEncodingType::ascii: {
        // https://github.com/nodejs/node/blob/e676942f814915b2d24fc899bb42dc71ae6c8226/lib/buffer.js#L627
        return str->length();
    }

    case WebCore::BufferEncodingType::base64:
    case WebCore::BufferEncodingType::base64url: {
        int64_t length = str->length();
        const auto view = str->view(lexicalGlobalObject);
        if (view->isNull()) [[unlikely]] {
            return std::nullopt;
        }

        if (view->is8Bit()) {
            const auto span = view->span8();
            if (span.data()[length - 1] == 0x3D) {
                length--;

                if (length > 1 && span.data()[length - 1] == '=')
                    length--;
            }
        } else {
            const auto span = view->span16();
            if (span.data()[length - 1] == 0x3D) {
                length--;

                if (length > 1 && span.data()[length - 1] == '=')
                    length--;
            }
        }

        // https://github.com/nodejs/node/blob/e676942f814915b2d24fc899bb42dc71ae6c8226/lib/buffer.js#L579
        return static_cast<double>((length * 3) >> 2);
    }

    case WebCore::BufferEncodingType::hex: {
        return str->length() >> 1;
    }

    case WebCore::BufferEncodingType::utf8: {
        const auto view = str->view(lexicalGlobalObject);
        if (view->isNull()) [[unlikely]] {
            return std::nullopt;
        }

        if (view->is8Bit()) {
            const auto span = view->span8();
            return Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingByteLengthLatin1AsUTF8(span);
        } else {
            const auto span = view->span16();
            return Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingByteLengthUTF16AsUTF8(
                { reinterpret_cast<const uint16_t*>(span.data()), span.size() });
        }
    }
    default: {
        RELEASE_ASSERT_NOT_REACHED();
    }
    }

    return std::nullopt;
}
}

static JSUint8Array* allocBuffer(JSC::JSGlobalObject* lexicalGlobalObject, size_t byteLength)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* subclassStructure = globalObject->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(throwScope, nullptr);

    auto* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, byteLength);
    // it should have thrown an exception already
    EXCEPTION_ASSERT(!!throwScope.exception() == !uint8Array);

    return uint8Array;
}

// Normalize val to be an integer in the range of [1, -1] since
// implementations of memcmp() can vary by platform.
static int normalizeCompareVal(int val, size_t a_length, size_t b_length)
{
    if (val == 0) {
        if (a_length > b_length)
            return 1;
        else if (a_length < b_length)
            return -1;
    } else {
        if (val > 0)
            return 1;
        else
            return -1;
    }
    return val;
}

Bun::Bindgen::BufferEncoding Bun::Bindgen::Custom::bunBindgenBufferEncoding(
    JSC::JSGlobalObject& globalObject,
    const WTF::String& value,
    WTF::ASCIILiteral)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto encoding = WebCore::parseBufferEncoding(value);
    if (!encoding) {
        Bun::ERR::UNKNOWN_ENCODING(scope, &globalObject, value);
        return Bun::Bindgen::BufferEncoding::utf8;
    }
    return *encoding;
}

static Bun::Bindgen::BufferEncoding bufferFillEncoding(Bun::Bindgen::FillBufferEncoding value)
{
    using Input = Bun::Bindgen::FillBufferEncoding;
    using Output = Bun::Bindgen::BufferEncoding;
    switch (value) {
    case Input::utf8: return Output::utf8;
    case Input::utf16le: return Output::ucs2;
    case Input::latin1: return Output::latin1;
    case Input::ascii: return Output::ascii;
    case Input::base64: return Output::base64;
    case Input::base64url: return Output::base64url;
    case Input::hex: return Output::hex;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<Bun::Bindgen::BufferEncoding> Bun::Bindgen::Custom::bunBindgenOptionalBufferEncoding(
    const std::optional<WTF::String>& value,
    WTF::ASCIILiteral)
{
    if (!value)
        return std::nullopt;
    return WebCore::parseBufferEncoding(*value);
}

std::optional<Bun::Bindgen::BufferEncoding> Bun::Bindgen::Custom::bunBindgenOptionalBufferEncoding(
    const WTF::String& value,
    WTF::ASCIILiteral)
{
    return WebCore::parseBufferEncoding(value);
}

RefPtr<JSC::ArrayBuffer> Bun::borrowExternalMemoryUnsafe(uint8_t* data, size_t length)
{
    if (!length)
        return JSC::ArrayBuffer::tryCreate(0, 1);
    RELEASE_ASSERT(data);
    return JSC::ArrayBuffer::tryCreateFromBytes({ data, length }, { });
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_bufferAdoptOwnedBytes(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_bufferAdoptOwnedBytes_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto buffer = Bun::Bindgen::adoptByteOwner(args.owner);
    if (!buffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(&context.globalObject, scope);
        return {};
    }
    const auto length = buffer->byteLength();
    auto* structure = globalObject->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(scope, {});
    auto* result = JSC::JSUint8Array::create(&context.globalObject, structure, WTF::move(buffer), 0, length);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_bufferBorrowExternalMemoryUnsafe(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_bufferBorrowExternalMemoryUnsafe_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto* structure = globalObject->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(scope, {});
    auto buffer = Bun::borrowExternalMemoryUnsafe(args.data, args.length);
    if (!buffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(&context.globalObject, scope);
        return {};
    }
    auto* result = JSC::JSUint8Array::create(&context.globalObject, structure, WTF::move(buffer), 0, args.length);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

namespace WebCore {
using namespace JSC;

static size_t writeStringViewToBuffer(JSC::JSArrayBufferView* castedThis, WTF::StringView view, size_t offset, size_t length, BufferEncodingType encoding)
{
    if (view.isEmpty()) [[unlikely]]
        return 0;

    size_t written = 0;

    switch (encoding) {
    case WebCore::BufferEncodingType::utf8:
    case WebCore::BufferEncodingType::latin1:
    case WebCore::BufferEncodingType::ascii:
    case WebCore::BufferEncodingType::ucs2:
    case WebCore::BufferEncodingType::utf16le:
    case WebCore::BufferEncodingType::base64:
    case WebCore::BufferEncodingType::base64url:
    case WebCore::BufferEncodingType::hex: {

        if (view.is8Bit()) {
            const auto span = view.span8();
            written = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingWriteLatin1(
                span,
                { reinterpret_cast<uint8_t*>(castedThis->vector()) + offset, length },
                encoding);
        } else {
            const auto span = view.span16();
            written = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingWriteUTF16(
                { reinterpret_cast<const uint16_t*>(span.data()), span.size() },
                { reinterpret_cast<uint8_t*>(castedThis->vector()) + offset, length },
                encoding);
        }
        break;
    }
    default: {
        break;
    }
    }

    JSC::ensureStillAliveHere(castedThis);
    return written;
}

static size_t writeToBuffer(JSArrayBufferView* castedThis, const WTF::String& string, size_t offset, size_t length, BufferEncodingType encoding)
{
    return writeStringViewToBuffer(castedThis, WTF::StringView(string), offset, length, encoding);
}

JSC::JSUint8Array* createBuffer(JSC::JSGlobalObject* lexicalGlobalObject, Ref<JSC::ArrayBuffer>&& backingStore)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    size_t length = backingStore->byteLength();
    auto* structure = defaultGlobalObject(lexicalGlobalObject)->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(scope, nullptr);
    RELEASE_AND_RETURN(scope, JSC::JSUint8Array::create(lexicalGlobalObject, structure, WTF::move(backingStore), 0, length));
}

JSC::JSUint8Array* createBuffer(JSC::JSGlobalObject* lexicalGlobalObject, const uint8_t* ptr, size_t length)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto* buffer = createUninitializedBuffer(lexicalGlobalObject, length);
    RETURN_IF_EXCEPTION(scope, nullptr);

    if (ptr && length > 0 && buffer) [[likely]]
        memcpy(buffer->typedVector(), ptr, length);

    return buffer;
}

JSC::JSUint8Array* createBuffer(JSC::JSGlobalObject* lexicalGlobalObject, const std::span<const uint8_t> data)
{
    return createBuffer(lexicalGlobalObject, data.data(), data.size());
}

JSC::JSUint8Array* createBuffer(JSC::JSGlobalObject* lexicalGlobalObject, const char* ptr, size_t length)
{
    return createBuffer(lexicalGlobalObject, reinterpret_cast<const uint8_t*>(ptr), length);
}

JSC::JSUint8Array* createBuffer(JSC::JSGlobalObject* lexicalGlobalObject, const Vector<uint8_t>& data)
{
    return createBuffer(lexicalGlobalObject, data.begin(), data.size());
}

JSC::JSUint8Array* createEmptyBuffer(JSC::JSGlobalObject* lexicalGlobalObject)
{
    return createUninitializedBuffer(lexicalGlobalObject, 0);
}

JSC::JSUint8Array* createUninitializedBuffer(JSC::JSGlobalObject* lexicalGlobalObject, size_t length)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* subclassStructure = globalObject->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(scope, nullptr);

    RELEASE_AND_RETURN(scope, JSC::JSUint8Array::createUninitialized(lexicalGlobalObject, subclassStructure, length));
}

static JSC::JSUint8Array* JSBuffer__bufferFromLengthAsArray(JSC::JSGlobalObject* lexicalGlobalObject, int64_t length)
{
    auto throwScope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());

    if (length < 0) [[unlikely]] {
        throwNodeRangeError(lexicalGlobalObject, throwScope, "Invalid array length"_s);
        return nullptr;
    }
    if (length > MAX_ARRAY_BUFFER_SIZE) {
        Bun::ERR::OUT_OF_RANGE(throwScope, lexicalGlobalObject, "size"_s, 0, MAX_ARRAY_BUFFER_SIZE, jsNumber(length));
        return nullptr;
    }

    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* subclassStructure = globalObject->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    JSC::JSUint8Array* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, static_cast<size_t>(length));
    RELEASE_AND_RETURN(throwScope, uint8Array);
}

}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_createBufferFromLength(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_createBufferFromLength_Arguments& args)
{
    return WebCore::JSBuffer__bufferFromLengthAsArray(&context.globalObject, args.length);
}

namespace WebCore {

// https://github.com/nodejs/node/blob/v22.9.0/lib/buffer.js#L404
static JSC::JSValue allocateBufferUnsafe(JSC::JSGlobalObject* lexicalGlobalObject, size_t length)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* result = createUninitializedBuffer(lexicalGlobalObject, length);
    EXCEPTION_ASSERT(!!throwScope.exception() == !result);
    RETURN_IF_EXCEPTION(throwScope, {});
    if (zeroFillBuffers.load(std::memory_order_relaxed)) memset(result->typedVector(), 0, length);
    RELEASE_AND_RETURN(throwScope, result);
}

// new Buffer()
static JSC::JSValue constructBufferEmpty(JSGlobalObject* lexicalGlobalObject)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto* result = JSBuffer__bufferFromLengthAsArray(lexicalGlobalObject, 0);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, result);
}

JSC::JSValue constructFromEncoding(JSGlobalObject* lexicalGlobalObject, std::span<const uint8_t> bytes, WebCore::BufferEncodingType encoding)
{
    WTF::StringView view(bytes);
    return constructFromEncoding(lexicalGlobalObject, view, encoding);
}

JSC::JSValue constructFromEncoding(JSGlobalObject* lexicalGlobalObject, WTF::StringView view, WebCore::BufferEncodingType encoding)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSValue result;

    if (view.is8Bit()) {
        const auto span = view.span8();

        switch (encoding) {
        case WebCore::BufferEncodingType::utf8:
        case WebCore::BufferEncodingType::ucs2:
        case WebCore::BufferEncodingType::utf16le:
        case WebCore::BufferEncodingType::base64:
        case WebCore::BufferEncodingType::base64url:
        case WebCore::BufferEncodingType::hex: {

            result = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingConstructFromLatin1(
                lexicalGlobalObject, std::span<const uint8_t> { span.data(), span.size() }, encoding);
            break;
        }
        case WebCore::BufferEncodingType::ascii: // ascii is a noop for latin1
        case WebCore::BufferEncodingType::latin1: { // The native encoding is latin1, so we don't need to do any conversion.
            auto* buffer = createBuffer(lexicalGlobalObject, span.data(), span.size());
            RETURN_IF_EXCEPTION(scope, {});
            result = buffer;
            break;
        }
        default: {
            RELEASE_ASSERT_NOT_REACHED();
        }
        }
    } else {
        const auto span = view.span16();
        switch (encoding) {
        case WebCore::BufferEncodingType::utf8:
        case WebCore::BufferEncodingType::base64:
        case WebCore::BufferEncodingType::base64url:
        case WebCore::BufferEncodingType::hex:
        case WebCore::BufferEncodingType::ascii:
        case WebCore::BufferEncodingType::latin1: {
            result = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingConstructFromUTF16(
                lexicalGlobalObject,
                std::span<const uint16_t> { reinterpret_cast<const uint16_t*>(span.data()), span.size() },
                encoding);
            break;
        }
        case WebCore::BufferEncodingType::ucs2:
        case WebCore::BufferEncodingType::utf16le: {
            // The native encoding is UTF-16
            // so we don't need to do any conversion.
            auto* buffer = createBuffer(lexicalGlobalObject, reinterpret_cast<const unsigned char*>(span.data()), span.size_bytes());
            RETURN_IF_EXCEPTION(scope, {});
            result = buffer;
            break;
        }
        default: {
            RELEASE_ASSERT_NOT_REACHED();
        }
        }
    }
    RETURN_IF_EXCEPTION(scope, {});

    RELEASE_ASSERT(result);
    return result;
}

static JSC::JSValue constructBufferFromStringAndEncoding(JSC::JSGlobalObject* lexicalGlobalObject, const WTF::String& text, Bun::Bindgen::BufferEncoding encoding)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (text.isEmpty())
        RELEASE_AND_RETURN(scope, constructBufferEmpty(lexicalGlobalObject));

    RELEASE_AND_RETURN(scope, constructFromEncoding(lexicalGlobalObject, WTF::StringView(text), encoding));
}

template<typename Word>
static void swapBufferWords(std::span<uint8_t> bytes)
{
    RELEASE_ASSERT(bytes.size() % sizeof(Word) == 0);
    for (size_t offset = 0; offset < bytes.size(); offset += sizeof(Word)) {
        Word word;
        memcpy(&word, bytes.data() + offset, sizeof(word));
        word = std::byteswap(word);
        memcpy(bytes.data() + offset, &word, sizeof(word));
    }
}

static void repeatBytes(std::span<uint8_t> output, std::span<const uint8_t> fill)
{
    auto* head = output.data();
    size_t remaining = output.size();
    size_t copied = std::min(fill.size(), remaining);
    memmove(head, fill.data(), copied);
    remaining -= copied;
    head += copied;
    while (remaining >= copied && copied > 0) {
        memmove(head, output.data(), copied);
        remaining -= copied;
        head += copied;
        copied <<= 1;
    }
    if (remaining > 0)
        memmove(head, output.data(), remaining);
}

static JSC::JSValue allocateBuffer(JSC::JSGlobalObject* lexicalGlobalObject, size_t size)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (size == 0)
        RELEASE_AND_RETURN(scope, constructBufferEmpty(lexicalGlobalObject));
    auto* buffer = allocBuffer(lexicalGlobalObject, size);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, buffer);
}

static JSC::JSValue allocateBufferWithString(
    JSC::JSGlobalObject* lexicalGlobalObject,
    size_t size,
    const WTF::String& fill,
    Bun::Bindgen::BufferEncoding encoding)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (size == 0)
        RELEASE_AND_RETURN(scope, constructBufferEmpty(lexicalGlobalObject));

    auto* buffer = createUninitializedBuffer(lexicalGlobalObject, size);
    RETURN_IF_EXCEPTION(scope, {});
    auto output = buffer->typedSpan();
    if (fill.isEmpty()) {
        memset(output.data(), 0, output.size());
    } else if (!Bun::Bindgen::ZigExports::bunBindgenZig_array_buffers_bufferFill(
                   fill, output, encoding)) [[unlikely]] {
        {
            Bun::ERR::INVALID_ARG_VALUE(scope, lexicalGlobalObject, "value"_s, JSC::jsString(vm, fill));
            return {};
        }
    }
    RELEASE_AND_RETURN(scope, buffer);
}

static JSC::JSValue allocateBufferWithBytes(
    JSC::JSGlobalObject* lexicalGlobalObject,
    size_t size,
    std::span<const uint8_t> fill)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (size == 0)
        RELEASE_AND_RETURN(scope, constructBufferEmpty(lexicalGlobalObject));
    if (fill.empty()) {
        scope.throwException(lexicalGlobalObject, Bun::createError(lexicalGlobalObject, Bun::ErrorCode::ERR_INVALID_ARG_VALUE, "Buffer cannot be empty"_s));
        return {};
    }

    auto* buffer = createUninitializedBuffer(lexicalGlobalObject, size);
    RETURN_IF_EXCEPTION(scope, {});
    repeatBytes(buffer->typedSpan(), fill);
    RELEASE_AND_RETURN(scope, buffer);
}

static JSC::JSValue allocateBufferWithByte(
    JSC::JSGlobalObject* lexicalGlobalObject,
    size_t size,
    uint8_t fill)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (size == 0)
        RELEASE_AND_RETURN(scope, constructBufferEmpty(lexicalGlobalObject));

    auto* buffer = createUninitializedBuffer(lexicalGlobalObject, size);
    RETURN_IF_EXCEPTION(scope, {});
    memset(buffer->typedSpan().data(), fill, size);
    RELEASE_AND_RETURN(scope, buffer);
}

// https://github.com/nodejs/node/blob/v22.9.0/lib/buffer.js#L337

class JSBufferPrototype : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;
    static JSBufferPrototype* create(JSC::VM& vm, JSGlobalObject* globalObject, JSC::Structure* structure)
    {
        JSBufferPrototype* ptr = new (NotNull, JSC::allocateCell<JSBufferPrototype>(vm)) JSBufferPrototype(vm, globalObject, structure);
        ptr->finishCreation(vm, globalObject);
        return ptr;
    }

    DECLARE_INFO;
    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSBufferPrototype, Base);
        return &vm.plainObjectSpace();
    }
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

private:
    JSBufferPrototype(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM&, JSC::JSGlobalObject*);
};
STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSBufferPrototype, JSBufferPrototype::Base);

bool isNodeBuffer(JSC::JSValue value) noexcept
{
    auto* buffer = dynamicDowncast<JSC::JSUint8Array>(value);
    if (!buffer)
        return false;
    return buffer->getPrototype(buffer->globalObject()).inherits<JSBufferPrototype>();
}

static std::span<uint8_t> bufferFillTarget(
    JSC::JSUint8Array* receiver,
    size_t offset,
    size_t end)
{
    if (receiver->isDetached())
        return {};
    auto limit = receiver->byteLength();
    offset = std::min(offset, limit);
    end = std::min(end, limit);
    if (offset >= end)
        return {};
    return receiver->typedSpan().subspan(offset, end - offset);
}

static JSC::JSValue fillBufferWithString(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSUint8Array* receiver,
    size_t offset,
    size_t end,
    const WTF::String& fill,
    Bun::Bindgen::BufferEncoding encoding)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto target = bufferFillTarget(receiver, offset, end);
    RETURN_IF_EXCEPTION(scope, {});
    if (target.empty())
        RELEASE_AND_RETURN(scope, receiver);
    if (fill.isEmpty()) {
        memset(target.data(), 0, target.size());
    } else if (!Bun::Bindgen::ZigExports::bunBindgenZig_array_buffers_bufferFill(fill, target, encoding)) [[unlikely]] {
        {
            Bun::ERR::INVALID_ARG_VALUE(scope, lexicalGlobalObject, "value"_s, JSC::jsString(vm, fill));
            return {};
        }
    }
    RELEASE_AND_RETURN(scope, receiver);
}

static JSC::JSValue fillBufferWithBytes(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSUint8Array* receiver,
    size_t offset,
    size_t end,
    std::span<const uint8_t> fill)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto target = bufferFillTarget(receiver, offset, end);
    RETURN_IF_EXCEPTION(scope, {});
    if (target.empty())
        RELEASE_AND_RETURN(scope, receiver);
    if (fill.empty()) {
        scope.throwException(lexicalGlobalObject, Bun::createError(lexicalGlobalObject, Bun::ErrorCode::ERR_INVALID_ARG_VALUE, "Buffer cannot be empty"_s));
        return {};
    }
    repeatBytes(target, fill);
    RELEASE_AND_RETURN(scope, receiver);
}

static JSC::JSValue fillBufferWithByte(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSUint8Array* receiver,
    size_t offset,
    size_t end,
    uint8_t fill)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto target = bufferFillTarget(receiver, offset, end);
    RETURN_IF_EXCEPTION(scope, {});
    if (!target.empty())
        memset(target.data(), fill, target.size());
    RELEASE_AND_RETURN(scope, receiver);
}

static ssize_t indexOfOffset(size_t length, ssize_t offset_i64, ssize_t needle_length, bool is_forward)
{
    auto length_i64 = static_cast<ssize_t>(length);
    if (offset_i64 < 0) {
        if (offset_i64 + length_i64 >= 0) {
            // Negative offsets count backwards from the end of the buffer.
            return length_i64 + offset_i64;
        } else if (is_forward || needle_length == 0) {
            // indexOf from before the start of the buffer: search the whole buffer.
            return 0;
        } else {
            // lastIndexOf from before the start of the buffer: no match.
            return -1;
        }
    } else {
        if (offset_i64 + needle_length <= length_i64) {
            // Valid positive offset.
            return offset_i64;
        } else if (needle_length == 0) {
            // Out of buffer bounds, but empty needle: point to end of buffer.
            return length_i64;
        } else if (is_forward) {
            // indexOf from past the end of the buffer: no match.
            return -1;
        } else {
            // lastIndexOf from past the end of the buffer: search the whole buffer.
            return length_i64 - 1;
        }
    }
}

static int64_t indexOf(const uint8_t* thisPtr, int64_t thisLength, const uint8_t* valuePtr, int64_t valueLength, int64_t byteOffset)
{
    const size_t haystackLen = static_cast<size_t>(thisLength - byteOffset);
    const uint8_t* haystackPtr = thisPtr + byteOffset;

    if (valueLength == 1) {
        // Use SIMD-optimized single-byte search
        size_t result = highway_index_of_char(haystackPtr, haystackLen, valuePtr[0]);
        if (result == haystackLen) return -1;
        return byteOffset + static_cast<int64_t>(result);
    }

    // Use SIMD-optimized multi-byte search
    void* result = highway_memmem(haystackPtr, haystackLen, valuePtr, static_cast<size_t>(valueLength));
    if (result == nullptr) return -1;
    return byteOffset + static_cast<int64_t>(static_cast<const uint8_t*>(result) - haystackPtr);
}

static int64_t indexOf16(const uint8_t* thisPtr, int64_t thisLength, const uint8_t* valuePtr, int64_t valueLength, int64_t byteOffset)
{
    if (thisLength == 1) return -1;
    if (valueLength == 1) return -1;
    thisLength /= 2;
    valueLength /= 2;
    byteOffset /= 2;
    auto haystack = std::span<const uint16_t>((const uint16_t*)(thisPtr), thisLength).subspan(byteOffset);
    auto needle = std::span<const uint16_t>((const uint16_t*)(valuePtr), valueLength);
    auto it = std::search(haystack.begin(), haystack.end(), needle.begin(), needle.end());
    if (it == haystack.end()) return -1;
    auto idx = byteOffset + std::distance(haystack.begin(), it);
    return idx * 2;
}

static int64_t lastIndexOf(const uint8_t* thisPtr, int64_t thisLength, const uint8_t* valuePtr, int64_t valueLength, int64_t byteOffset)
{
    auto start = thisPtr;
    auto end = thisPtr + std::min(thisLength, byteOffset + valueLength);
    auto it = std::find_end(start, end, valuePtr, valuePtr + valueLength);
    if (it != end) {
        return it - thisPtr;
    }
    return -1;
}

static int64_t indexOfNumber(JSC::JSGlobalObject* lexicalGlobalObject, bool last, const uint8_t* typedVector, size_t byteLength, double byteOffsetD, uint8_t byteValue)
{
    ssize_t byteOffset = indexOfOffset(byteLength, byteOffsetD, 1, !last);
    if (byteOffset == -1) return -1;
    auto span = std::span<const uint8_t>(typedVector, byteLength);
    if (last) {
        span = span.subspan(0, byteOffset + 1);
        return WTF::reverseFind(span, byteValue);
    }
    span = span.subspan(byteOffset);
    auto result = WTF::find<uint8_t>(span, byteValue);
    if (result == WTF::notFound) return -1;
    return result + byteOffset;
}

static int64_t indexOfString(JSC::JSGlobalObject* lexicalGlobalObject, bool last, const uint8_t* typedVector, size_t byteLength, double byteOffsetD, const WTF::String& string, BufferEncodingType encoding)
{
    ssize_t byteOffset = indexOfOffset(byteLength, byteOffsetD, string.length(), !last);
    if (byteOffset == -1) return -1;
    if (string.isEmpty()) return byteOffset;

    VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSValue bufferValue = constructFromEncoding(lexicalGlobalObject, WTF::StringView(string), encoding);
    RETURN_IF_EXCEPTION(scope, -1);

    auto* arrayValue = uncheckedDowncast<JSC::JSUint8Array>(bufferValue);
    auto lengthValue = static_cast<int64_t>(arrayValue->byteLength());
    if (lengthValue == 0) return byteOffset;

    const uint8_t* typedVectorValue = arrayValue->typedVector();
    if (last) {
        return lastIndexOf(typedVector, byteLength, typedVectorValue, lengthValue, byteOffset);
    }
    if (encoding == BufferEncodingType::ucs2) {
        return indexOf16(typedVector, byteLength, typedVectorValue, lengthValue, byteOffset);
    }

    return indexOf(typedVector, byteLength, typedVectorValue, lengthValue, byteOffset);
}

static int64_t indexOfBuffer(JSC::JSGlobalObject* lexicalGlobalObject, bool last, const uint8_t* typedVector, size_t byteLength, double byteOffsetD, std::span<const uint8_t> value, BufferEncodingType encoding)
{
    size_t lengthValue = value.size();
    ssize_t byteOffset = indexOfOffset(byteLength, byteOffsetD, lengthValue, !last);
    if (byteOffset == -1) return -1;
    if (lengthValue == 0) return byteOffset;
    const uint8_t* typedVectorValue = value.data();
    if (last) {
        return lastIndexOf(typedVector, byteLength, typedVectorValue, lengthValue, byteOffset);
    }
    if (encoding == BufferEncodingType::ucs2) {
        return indexOf16(typedVector, byteLength, typedVectorValue, lengthValue, byteOffset);
    }
    return indexOf(typedVector, byteLength, typedVectorValue, lengthValue, byteOffset);
}

static int64_t searchBufferNumber(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSUint8Array* buffer,
    uint8_t value,
    double byteOffset,
    bool last)
{
    if (buffer->isDetached())
        return -1;
    auto byteLength = buffer->byteLength();
    if (byteLength == 0)
        return -1;
    auto* bytes = buffer->typedVector();
    return indexOfNumber(lexicalGlobalObject, last, bytes, byteLength, byteOffset, value);
}

static int64_t searchBufferString(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSUint8Array* buffer,
    const WTF::String& value,
    double byteOffset,
    Bun::Bindgen::BufferEncoding encoding,
    bool last)
{
    if (buffer->isDetached())
        return -1;
    auto byteLength = buffer->byteLength();
    if (byteLength == 0)
        return -1;
    auto result = indexOfString(lexicalGlobalObject, last, buffer->typedVector(), byteLength, byteOffset, value, encoding);
    JSC::ensureStillAliveHere(buffer);
    return result;
}

static int64_t searchBufferView(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSUint8Array* buffer,
    std::span<const uint8_t> value,
    double byteOffset,
    Bun::Bindgen::BufferEncoding encoding,
    bool last)
{
    if (buffer->isDetached())
        return -1;
    auto byteLength = buffer->byteLength();
    if (byteLength == 0)
        return -1;
    return indexOfBuffer(lexicalGlobalObject, last, buffer->typedVector(), byteLength, byteOffset, value, encoding);
}

WTF::String bufferToStringFromBytes(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, std::span<const uint8_t> bytes, BufferEncodingType encoding)
{
    if (bytes.size() == 0) [[unlikely]] {
        return WTF::emptyString();
    }

    if (bytes.size() > WTF::String::MaxLength) {
        Bun::ERR::STRING_TOO_LONG(scope, lexicalGlobalObject);
        return {};
    }

    // Check encoding-specific output size limits
    // For hex, output is 2x input size
    if (encoding == BufferEncodingType::hex && bytes.size() > WTF::String::MaxLength / 2) {
        Bun::ERR::STRING_TOO_LONG(scope, lexicalGlobalObject);
        return {};
    }
    // For base64, output is ceil(input * 4 / 3)
    if ((encoding == BufferEncodingType::base64 || encoding == BufferEncodingType::base64url) && bytes.size() > (WTF::String::MaxLength / 4) * 3) {
        Bun::ERR::STRING_TOO_LONG(scope, lexicalGlobalObject);
        return {};
    }

    switch (encoding) {
    case BufferEncodingType::latin1: {
        std::span<Latin1Character> data;
        auto str = String::tryCreateUninitialized(bytes.size(), data);
        if (str.isNull()) [[unlikely]] {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }

        memcpy(data.data(), bytes.data(), bytes.size());
        return str;
    }
    case BufferEncodingType::ucs2:
    case BufferEncodingType::utf16le: {
        std::span<char16_t> data;
        size_t u16length = bytes.size() / 2;
        if (u16length == 0) {
            return WTF::emptyString();
        }
        auto str = String::tryCreateUninitialized(u16length, data);
        if (str.isNull()) [[unlikely]] {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        memcpy(reinterpret_cast<void*>(data.data()), bytes.data(), u16length * 2);
        return str;
    }
    case BufferEncodingType::ascii: {
        std::span<Latin1Character> data;
        auto str = String::tryCreateUninitialized(bytes.size(), data);
        if (str.isNull()) [[unlikely]] {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingWriteLatin1(bytes, data, encoding);
        return str;
    }

    case WebCore::BufferEncodingType::utf8:
    case WebCore::BufferEncodingType::base64:
    case WebCore::BufferEncodingType::base64url:
    case WebCore::BufferEncodingType::hex: {
        auto string = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_encodingToString(
            lexicalGlobalObject, bytes, encoding);
        RETURN_IF_EXCEPTION(scope, {});
        return string;
    }
    case WebCore::BufferEncodingType::buffer:
    default: {
        throwTypeError(lexicalGlobalObject, scope, "Unsupported encoding? This shouldn't happen"_s);
        return {};
    }
    }
}

JSC::JSValue jsBufferToStringFromBytes(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, std::span<const uint8_t> bytes, BufferEncodingType encoding)
{
    auto& vm = lexicalGlobalObject->vm();

    if (encoding == WebCore::BufferEncodingType::buffer) {
        auto* buffer = createUninitializedBuffer(lexicalGlobalObject, bytes.size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!buffer) [[unlikely]] {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        if (!bytes.empty())
            memcpy(buffer->vector(), bytes.data(), bytes.size());
        return buffer;
    }

    auto string = bufferToStringFromBytes(lexicalGlobalObject, scope, bytes, encoding);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(!string.isNull());
    return jsString(vm, WTF::move(string));
}

JSC::JSValue jsBufferToString(JSC::JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, JSC::JSArrayBufferView* castedThis, size_t offset, size_t length, WebCore::BufferEncodingType encoding)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);

    auto byteLength = castedThis->byteLength();

    if (!byteLength) [[unlikely]] {
        RELEASE_AND_RETURN(scope, jsEmptyString(vm));
    }

    offset = std::min(offset, byteLength);
    length = std::min(length, byteLength - offset);
    auto result = jsBufferToStringFromBytes(lexicalGlobalObject, scope, castedThis->span().subspan(offset, length), encoding);
    JSC::ensureStillAliveHere(castedThis);
    return result;
}

static ALWAYS_INLINE size_t adjustSliceOffsetInt32(int32_t offset, size_t length)
{
    if (offset < 0) {
        int64_t adjusted = static_cast<int64_t>(offset) + static_cast<int64_t>(length);
        return adjusted > 0 ? static_cast<size_t>(adjusted) : 0;
    }
    return static_cast<size_t>(offset) < length ? static_cast<size_t>(offset) : length;
}

static ALWAYS_INLINE size_t adjustSliceOffsetDouble(double offset, size_t length)
{
    if (std::isnan(offset)) {
        return 0;
    }
    offset = std::trunc(offset);
    if (offset == 0) {
        return 0;
    } else if (offset < 0) {
        double adjusted = offset + static_cast<double>(length);
        return adjusted > 0 ? static_cast<size_t>(adjusted) : 0;
    } else {
        return offset < static_cast<double>(length) ? static_cast<size_t>(offset) : length;
    }
}

// https://github.com/nodejs/node/blob/v22.9.0/lib/buffer.js#L834
// using byteLength and byte offsets here is intentional

// https://github.com/nodejs/node/blob/2eff28fb7a93d3f672f80b582f664a7c701569fb/src/node_buffer.cc#L544
template<BufferEncodingType encoding>
static JSC::JSValue jsBufferPrototypeFunction_SliceWithEncoding(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSArrayBufferView* castedThis,
    const std::optional<Bun::Bindgen::CppLazyArgument<int64_t>>& startInput,
    const std::optional<Bun::Bindgen::CppLazyArgument<int64_t>>& endInput)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const size_t length = castedThis->byteLength();
    if (length == 0) [[unlikely]] {
        return JSC::jsEmptyString(vm);
    }

    size_t start = 0;
    size_t end = length;

    if (startInput) {
        auto* converted = startInput->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        start = *converted;
    }

    if (endInput) {
        auto* converted = endInput->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        end = *converted;
    }

    if (end < start)
        end = start;

    if (!(end <= length)) {
        throwNodeRangeError(lexicalGlobalObject, scope, "end out of range"_s);
        return {};
    }

    return jsBufferToString(lexicalGlobalObject, scope, castedThis, start, end - start, encoding);
}

template<BufferEncodingType encoding>
static uint64_t writeEncodedBufferRange(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSArrayBufferView* castedThis,
    const WTF::String& str,
    std::optional<double> offsetValue,
    std::optional<double> lengthValue)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());

    double offset = offsetValue.value_or(0);
    double length = lengthValue.value_or(0);
    bool lengthWasUndefined = !lengthValue.has_value();

    if (castedThis->isDetached()) [[unlikely]] {
        throwTypeError(lexicalGlobalObject, scope, "ArrayBufferView is detached"_s);
        return 0;
    }

    size_t byteLength = castedThis->byteLength();

    // Node.js JS wrapper checks: if (offset < 0 || offset > this.byteLength)
    // When offset is NaN, both comparisons return false, so no error is thrown.
    // We need to match this behavior exactly.
    bool offsetWasNaN = std::isnan(offset);
    if (!offsetWasNaN && (offset < 0 || offset > byteLength)) {
        Bun::ERR::BUFFER_OUT_OF_BOUNDS(scope, lexicalGlobalObject, "offset");
        return 0;
    }
    // Convert NaN offset to 0 for actual use (matching V8's IntegerValue behavior)
    size_t safeOffset = offsetWasNaN ? 0 : static_cast<size_t>(offset);

    // Calculate max_length
    size_t maxLength;
    if (lengthWasUndefined) {
        maxLength = byteLength - safeOffset;
    } else {
        // Node.js JS wrapper checks: if (length < 0 || length > this.byteLength - offset)
        // When offset is NaN, (byteLength - offset) is NaN, so (length > NaN) is false.
        // This means the check passes even for large lengths when offset is NaN.
        if (!offsetWasNaN && (length < 0 || length > byteLength - offset)) {
            Bun::ERR::BUFFER_OUT_OF_BOUNDS(scope, lexicalGlobalObject, "length");
            return 0;
        }
        // Convert NaN length to 0, negative to 0 (for NaN offset case)
        int64_t intLength = (std::isnan(length) || length < 0) ? 0 : truncateDoubleToInt64(length);
        // Clamp to available buffer space
        maxLength = std::min(byteLength - safeOffset, static_cast<size_t>(intLength));
    }

    return writeToBuffer(castedThis, str, safeOffset, maxLength, encoding);
}

static uint64_t writeBufferRange(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::JSArrayBufferView* receiver,
    const WTF::String& string,
    size_t offset,
    size_t length,
    Bun::Bindgen::BufferEncoding encoding)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (receiver->isDetached()) {
        throwTypeError(lexicalGlobalObject, scope, "ArrayBufferView is detached"_s);
        return 0;
    }
    auto byteLength = receiver->byteLength();
    if (offset >= byteLength || length == 0)
        return 0;
    length = std::min(length, byteLength - offset);
    const size_t written = writeToBuffer(receiver, string, offset, length, encoding);
    RETURN_IF_EXCEPTION(scope, 0);
    return written;
}

class JSBufferConstructor final : public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;
    static constexpr unsigned StructureFlags = Base::StructureFlags | HasStaticPropertyTable;

    ~JSBufferConstructor() = default;

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSBufferConstructor*>(cell)->JSBufferConstructor::~JSBufferConstructor();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        JSValue prototype = globalObject->m_typedArrayUint8.constructorInitializedOnMainThread(globalObject);
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(prototype.asCell()->type(), StructureFlags), info());
    }

    DECLARE_INFO;

    static JSBufferConstructor* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, JSC::JSObject* prototype)
    {
        JSBufferConstructor* constructor = new (NotNull, JSC::allocateCell<JSBufferConstructor>(vm)) JSBufferConstructor(vm, globalObject, structure);
        constructor->finishCreation(vm, globalObject, prototype);
        return constructor;
    }

private:
    JSBufferConstructor(JSC::VM& vm, JSGlobalObject* globalObject, JSC::Structure* structure)
        : Base(vm, structure, bun_bindgen_host_BufferHost_callJSBuffer, bun_bindgen_host_BufferHost_constructJSBuffer)

    {
    }

    void finishCreation(JSC::VM&, JSGlobalObject*, JSC::JSObject* prototype);

};

static size_t validateOffsetBigInt64(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSC::ThrowScope& scope,
    const std::optional<Bun::Bindgen::CppLazyArgument<uint64_t>>& input,
    size_t byteLength)
{
    if (byteLength < 8) [[unlikely]] {
        auto* error = Bun::createError(lexicalGlobalObject, Bun::ErrorCode::ERR_BUFFER_OUT_OF_BOUNDS, "Attempt to access memory outside buffer bounds"_s);
        scope.throwException(lexicalGlobalObject, error);
        return 0;
    }

    if (!input) {
        return 0;
    }

    const auto* converted = input->convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!converted)
        return 0;

    size_t offset = *converted;
    size_t maxOffset = byteLength - 8;

    if (offset > maxOffset) [[unlikely]] {
        Bun::ERR::OUT_OF_RANGE(scope, lexicalGlobalObject, "offset"_s, 0, maxOffset, JSC::jsNumber(offset));
        return 0;
    }

    return offset;
}

JSC_ANNOTATE_HOST_FUNCTION(JSBufferConstructorConstruct, JSBufferConstructor::construct);

class JSBuffer : public JSC::JSNonFinalObject {

    DECLARE_INFO;

    static constexpr JSC::JSTypeRange typeRange = { Uint8ArrayType, Uint8ArrayType };
};

const ClassInfo JSBuffer::s_info = {
    "Buffer"_s,
    &JSC::JSUint8Array::s_info,
    nullptr,
    nullptr,
    CREATE_METHOD_TABLE(JSBuffer)
};

template<typename Integer, bool bigEndian>
static uint64_t writeBufferBigInt(JSC::JSArrayBufferView* receiver, Integer value, size_t offset)
{
    static_assert(std::endian::native == std::endian::little);
    static_assert(sizeof(Integer) == sizeof(uint64_t));
    if constexpr (bigEndian)
        value = std::byteswap(value);
    memcpy(static_cast<uint8_t*>(receiver->vector()) + offset, &value, sizeof(value));
    return offset + 8;
}

static double normalizeSearchOffset(double offset, size_t length, bool last)
{
    return std::isnan(offset) ? static_cast<double>(last ? length : 0) : offset;
}

template<typename Arguments>
static int64_t searchNumberOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args,
    bool last)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto byteLength = receiver->byteLength();
    if (receiver->isDetached() || byteLength == 0)
        return -1;

    double offset = static_cast<double>(last ? byteLength : 0);
    if (args.offset) {
        const auto* converted = args.offset->convert();
        RETURN_IF_EXCEPTION(scope, -1);
        if (!converted)
            return -1;
        offset = converted->is_encoding()
            ? 0
            : normalizeSearchOffset(converted->offset(), byteLength, last);
    }

    const auto* value = args.value.convert();
    RETURN_IF_EXCEPTION(scope, -1);
    if (!value)
        return -1;
    return searchBufferNumber(globalObject, receiver, *value, offset, last);
}

template<typename Arguments>
static int64_t searchStringOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args,
    bool last)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto byteLength = receiver->byteLength();
    if (receiver->isDetached() || byteLength == 0)
        return -1;

    double offset = static_cast<double>(last ? byteLength : 0);
    auto encoding = Bun::Bindgen::BufferEncoding::utf8;
    bool positionalEncoding = false;
    if (args.offset) {
        const auto* converted = args.offset->convert();
        RETURN_IF_EXCEPTION(scope, -1);
        if (!converted)
            return -1;
        if (converted->is_encoding()) {
            offset = 0;
            encoding = converted->encoding();
            positionalEncoding = true;
        } else {
            offset = normalizeSearchOffset(converted->offset(), byteLength, last);
        }
    }
    if (!positionalEncoding && args.encoding) {
        const auto* converted = args.encoding->convert();
        RETURN_IF_EXCEPTION(scope, -1);
        if (!converted)
            return -1;
        encoding = *converted;
    }

    const auto* value = args.value.convert();
    RETURN_IF_EXCEPTION(scope, -1);
    if (!value)
        return -1;
    RELEASE_AND_RETURN(scope, searchBufferString(globalObject, receiver, *value, offset, encoding, last));
}

template<typename Arguments>
static int64_t searchViewOverload(
    Bun::Bindgen::CppCallContext& context,
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args,
    bool last)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto byteLength = receiver->byteLength();
    if (receiver->isDetached() || byteLength == 0)
        return -1;

    double offset = static_cast<double>(last ? byteLength : 0);
    auto encoding = Bun::Bindgen::BufferEncoding::utf8;
    bool positionalEncoding = false;
    if (args.offset) {
        const auto* converted = args.offset->convert();
        RETURN_IF_EXCEPTION(scope, -1);
        if (!converted)
            return -1;
        if (converted->is_encoding()) {
            offset = 0;
            encoding = converted->encoding().value_or(Bun::Bindgen::BufferEncoding::utf8);
            positionalEncoding = true;
        } else {
            offset = normalizeSearchOffset(converted->offset(), byteLength, last);
        }
    }
    if (!positionalEncoding && args.encoding) {
        const auto* converted = args.encoding->convert();
        RETURN_IF_EXCEPTION(scope, -1);
        if (!converted)
            return -1;
        encoding = converted->value_or(Bun::Bindgen::BufferEncoding::utf8);
    } else if (positionalEncoding && args.encoding) {
        args.encoding->discard();
    }

    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* value = args.value.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, -1);
    if (!value)
        return -1;
    if (!context.lease(proof))
        return -1;
    return searchBufferView(globalObject, receiver, { value->unsafePtr("The entry frame holds the search lease through the synchronous buffer search"_s), value->size() }, offset, encoding, last);
}

template<typename Arguments>
static int64_t searchInvalidOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments&)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (receiver->isDetached() || receiver->byteLength() == 0)
        return -1;
    Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, "The \"value\" argument must be a number, string, Buffer, or Uint8Array."_s);
    return -1;
}

template<typename Arguments>
static JSC::JSValue fillStringOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    size_t offset = 0;
    size_t end = receiver->byteLength();
    auto encoding = Bun::Bindgen::BufferEncoding::utf8;
    if (args.encoding) {
        const auto* converted = args.encoding->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        encoding = bufferFillEncoding(*converted);
    }
    if constexpr (requires { args.offset; }) {
        if (args.offset) {
            const auto* converted = args.offset->convert();
            RETURN_IF_EXCEPTION(scope, {});
            if (!converted)
                return {};
            offset = *converted;
        }
    }
    if constexpr (requires { args.end; }) {
        if (args.end) {
            const auto* converted = args.end->convert();
            RETURN_IF_EXCEPTION(scope, {});
            if (!converted)
                return {};
            end = *converted;
        }
    }
    if (offset >= end)
        RELEASE_AND_RETURN(scope, receiver);

    const auto* value = args.value.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!value)
        return {};
    RELEASE_AND_RETURN(scope, fillBufferWithString(globalObject, receiver, offset, end, *value, encoding));
}

template<typename Arguments>
static bool fillOtherRange(
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args,
    size_t& offset,
    size_t& end,
    bool& skippedEnd)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    offset = 0;
    end = receiver->byteLength();
    skippedEnd = false;
    if (args.offset) {
        const auto* converted = args.offset->convert();
        RETURN_IF_EXCEPTION(scope, false);
        if (!converted)
            return false;
        if (converted->is_encoding()) {
            skippedEnd = true;
            return true;
        }
        offset = converted->offset();
    }
    if (args.end) {
        const auto* converted = args.end->convert();
        RETURN_IF_EXCEPTION(scope, false);
        if (!converted)
            return false;
        if (!converted->is_encoding())
            end = converted->end();
    }
    return true;
}

template<typename Arguments>
static JSC::JSValue fillViewOverload(
    Bun::Bindgen::CppCallContext& context,
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    size_t offset;
    size_t end;
    bool skippedEnd;
    bool convertedRange = fillOtherRange(globalObject, receiver, args, offset, end, skippedEnd);
    RETURN_IF_EXCEPTION(scope, {});
    if (!convertedRange)
        return {};
    if (skippedEnd && args.end)
        args.end->discard();
    RETURN_IF_EXCEPTION(scope, {});
    if (offset >= end)
        RELEASE_AND_RETURN(scope, receiver);
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* value = args.value.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!value)
        return {};
    if (!context.lease(proof))
        return {};
    RELEASE_AND_RETURN(scope, fillBufferWithBytes(globalObject, receiver, offset, end, { value->unsafePtr("The entry frame holds the fill lease through synchronous buffer filling"_s), value->size() }));
}

template<typename Arguments>
static JSC::JSValue fillByteOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSUint8Array* receiver,
    const Arguments& args)
{
    if (!args.value)
        return receiver;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    size_t offset;
    size_t end;
    bool skippedEnd;
    bool convertedRange = fillOtherRange(globalObject, receiver, args, offset, end, skippedEnd);
    RETURN_IF_EXCEPTION(scope, {});
    if (!convertedRange)
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    if (offset >= end)
        RELEASE_AND_RETURN(scope, receiver);
    const auto* value = args.value->convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!value)
        return {};
    RELEASE_AND_RETURN(scope, fillBufferWithByte(globalObject, receiver, offset, end, *value));
}

template<typename Arguments>
static uint64_t writeEncodingOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSArrayBufferView* receiver,
    const Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    const auto* string = args.string.convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!string)
        return 0;
    const auto* encoding = args.encoding.convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!encoding)
        return 0;
    RELEASE_AND_RETURN(scope, writeBufferRange(globalObject, receiver, *string, 0, receiver->byteLength(), *encoding));
}

template<typename Arguments>
static uint64_t writeLengthEncodingOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSArrayBufferView* receiver,
    const Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    const auto* offset = args.offset.convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!offset)
        return 0;
    auto length = receiver->byteLength() - *offset;
    const auto* string = args.string.convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!string)
        return 0;
    const auto* encoding = args.encoding.convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!encoding)
        return 0;
    RELEASE_AND_RETURN(scope, writeBufferRange(globalObject, receiver, *string, *offset, length, *encoding));
}

template<typename Arguments>
static uint64_t writeRangeOverload(
    JSC::JSGlobalObject* globalObject,
    JSC::JSArrayBufferView* receiver,
    const Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    size_t offset = 0;
    if (args.offset) {
        const auto* converted = args.offset->convert();
        RETURN_IF_EXCEPTION(scope, 0);
        if (!converted)
            return 0;
        offset = *converted;
    }
    size_t length = receiver->byteLength() - offset;
    if (args.length) {
        const auto* converted = args.length->convert();
        RETURN_IF_EXCEPTION(scope, 0);
        if (!converted)
            return 0;
        length = std::min<size_t>(*converted, length);
    }
    const auto* string = args.string.convert();
    RETURN_IF_EXCEPTION(scope, 0);
    if (!string)
        return 0;

    auto encoding = Bun::Bindgen::BufferEncoding::utf8;
    if (args.encoding) {
        const auto* converted = args.encoding->convert();
        RETURN_IF_EXCEPTION(scope, 0);
        if (!converted)
            return 0;
        encoding = converted->value_or(Bun::Bindgen::BufferEncoding::utf8);
    }
    RELEASE_AND_RETURN(scope, writeBufferRange(globalObject, receiver, *string, offset, length, encoding));
}

} // namespace WebCore

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_alloc_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_alloc_overload_string_Arguments& args)
{
    if (args.size == 0)
        return WebCore::allocateBuffer(&context.globalObject, 0);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const auto* fill = args.fill.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!fill)
        return {};
    auto encoding = Bun::Bindgen::BufferEncoding::utf8;
    if (args.encoding) {
        const auto* converted = args.encoding->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        encoding = bufferFillEncoding(*converted);
    }
    RELEASE_AND_RETURN(scope, WebCore::allocateBufferWithString(&context.globalObject, args.size, *fill, encoding));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_alloc_overload_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_alloc_overload_view_Arguments& args)
{
    if (args.size == 0)
        return WebCore::allocateBuffer(&context.globalObject, 0);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* fill = args.fill.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!fill)
        return {};
    if (!context.lease(proof))
        return {};
    RELEASE_AND_RETURN(scope, WebCore::allocateBufferWithBytes(&context.globalObject, args.size, { fill->unsafePtr("The entry frame holds the fill lease through synchronous buffer initialization"_s), fill->size() }));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_alloc_overload_byte(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_alloc_overload_byte_Arguments& args)
{
    if (args.size == 0 || !args.fill)
        return WebCore::allocateBuffer(&context.globalObject, args.size);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const auto* fill = args.fill->convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!fill)
        return {};
    RELEASE_AND_RETURN(scope, WebCore::allocateBufferWithByte(&context.globalObject, args.size, *fill));
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_isUtf8(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_isUtf8_Arguments& args)
{
    return simdutf::validate_utf8(
        reinterpret_cast<const char*>(args.buffer.unsafePtr("The entry frame holds the byte lease through synchronous SIMD validation"_s)), args.buffer.size());
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_isAscii(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_isAscii_Arguments& args)
{
    return simdutf::validate_ascii(
        reinterpret_cast<const char*>(args.buffer.unsafePtr("The entry frame holds the byte lease through synchronous SIMD validation"_s)), args.buffer.size());
}

double Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_getInspectMaxBytes(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_getInspectMaxBytes_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->INSPECT_MAX_BYTES;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_setInspectMaxBytes(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_setInspectMaxBytes_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    globalObject->INSPECT_MAX_BYTES = args.INSPECT_MAX_BYTES;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_concat(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_concat_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    const auto& list = args.list;
    const auto& totalLengthInput = args.length;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    if (list.isEmpty())
        RELEASE_AND_RETURN(throwScope, constructBufferEmpty(lexicalGlobalObject));

    std::optional<uint64_t> explicitByteLength;
    if (totalLengthInput) {
        const auto* converted = Bun::Bindgen::convertLastAndLease(context, *totalLengthInput);
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!converted)
            return {};
        explicitByteLength = *converted;
    }

    WTF::CheckedSize checkedAvailableLength { 0 };
    for (const auto& buffer : list)
        checkedAvailableLength += buffer.size();
    if (checkedAvailableLength.hasOverflowed() && !explicitByteLength) {
        throwOutOfMemoryError(lexicalGlobalObject, throwScope);
        return {};
    }
    size_t availableLength = checkedAvailableLength.hasOverflowed()
        ? std::numeric_limits<size_t>::max()
        : checkedAvailableLength.value();
    size_t byteLength = explicitByteLength.value_or(availableLength);

    if (byteLength == 0)
        RELEASE_AND_RETURN(throwScope, constructBufferEmpty(lexicalGlobalObject));
    if (byteLength > MAX_ARRAY_BUFFER_SIZE) {
        auto message = tryMakeString("JavaScriptCore typed arrays are currently limited to "_s, MAX_ARRAY_BUFFER_SIZE, " bytes. To use an array this large, use an ArrayBuffer instead. If this is causing issues for you, please file an issue in Bun's GitHub repository."_s);
        if (message.isNull())
            throwOutOfMemoryError(lexicalGlobalObject, throwScope);
        else
            throwRangeError(lexicalGlobalObject, throwScope, message);
        return {};
    }

    JSC::JSUint8Array* outBuffer = byteLength <= availableLength
        ? createUninitializedBuffer(lexicalGlobalObject, byteLength)
        : allocBuffer(lexicalGlobalObject, byteLength);
    RETURN_IF_EXCEPTION(throwScope, {});

    auto output = outBuffer->typedSpan();
    for (const auto& source : list) {
        if (output.empty())
            break;
        if (source.empty())
            continue;
        size_t length = std::min(output.size(), source.size());
        memcpy(output.data(), source.unsafePtr("The entry frame holds each source lease through this synchronous copy"_s), length);
        output = output.subspan(length);
    }

    ASSERT(byteLength > availableLength || output.empty());

    RELEASE_AND_RETURN(throwScope, outBuffer);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_string_Arguments& args)
{
    return WebCore::fillStringOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_string_offset_encoding(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_string_offset_encoding_Arguments& args)
{
    return WebCore::fillStringOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_string_end_encoding(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_string_end_encoding_Arguments& args)
{
    return WebCore::fillStringOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_view_Arguments& args)
{
    return WebCore::fillViewOverload(context, &context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_byte(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_fill_overload_byte_Arguments& args)
{
    return WebCore::fillByteOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_number(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_number_Arguments& args)
{
    return WebCore::searchNumberOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args, false) != -1;
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_string_Arguments& args)
{
    return WebCore::searchStringOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args, false) != -1;
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_view_Arguments& args)
{
    return WebCore::searchViewOverload(context, &context.globalObject, bindgenUint8Array(args.bindingThis), args, false) != -1;
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_invalid(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_includes_overload_invalid_Arguments& args)
{
    return WebCore::searchInvalidOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args) != -1;
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_number(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_number_Arguments& args)
{
    return WebCore::searchNumberOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args, false);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_string_Arguments& args)
{
    return WebCore::searchStringOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args, false);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_view_Arguments& args)
{
    return WebCore::searchViewOverload(context, &context.globalObject, bindgenUint8Array(args.bindingThis), args, false);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_invalid(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_indexOf_overload_invalid_Arguments& args)
{
    return WebCore::searchInvalidOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_number(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_number_Arguments& args)
{
    return WebCore::searchNumberOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args, true);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_string_Arguments& args)
{
    return WebCore::searchStringOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args, true);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_view_Arguments& args)
{
    return WebCore::searchViewOverload(context, &context.globalObject, bindgenUint8Array(args.bindingThis), args, true);
}

int64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_invalid(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_lastIndexOf_overload_invalid_Arguments& args)
{
    return WebCore::searchInvalidOverload(&context.globalObject, bindgenUint8Array(args.bindingThis), args);
}

uint64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_write_overload_encoding(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_write_overload_encoding_Arguments& args)
{
    return WebCore::writeEncodingOverload(&context.globalObject, bindgenArrayBufferView(args.bindingThis), args);
}

uint64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_write_overload_length_encoding(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_write_overload_length_encoding_Arguments& args)
{
    return WebCore::writeLengthEncodingOverload(&context.globalObject, bindgenArrayBufferView(args.bindingThis), args);
}

uint64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_write_overload_range(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_write_overload_range_Arguments& args)
{
    return WebCore::writeRangeOverload(&context.globalObject, bindgenArrayBufferView(args.bindingThis), args);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructSlowBuffer(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructSlowBuffer_Arguments& args)
{
    return WebCore::allocateBufferUnsafe(&context.globalObject, args.size);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_allocUnsafe(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_allocUnsafe_Arguments& args)
{
    return WebCore::allocateBufferUnsafe(&context.globalObject, args.size);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_allocUnsafeSlow(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_allocUnsafeSlow_Arguments& args)
{
    return WebCore::allocateBufferUnsafe(&context.globalObject, args.size);
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_isEncoding(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_isEncoding_Arguments& args)
{
    return args.encoding.has_value();
}

int32_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_compare(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_compare_Arguments& args)
{
    const auto& first = args.first;
    const auto& second = args.second;
    auto sourceLength = first.size();
    auto targetLength = second.size();
    auto actualLength = std::min(sourceLength, targetLength);
    auto result = actualLength > 0 ? memcmp(first.unsafePtr("The entry frame holds both leases through synchronous memcmp"_s), second.unsafePtr("The entry frame holds both leases through synchronous memcmp"_s), actualLength) : 0;

    return normalizeCompareVal(result, sourceLength, targetLength);
}

double Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_byteLength(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_byteLength_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    const Bun::Bindgen::BufferByteLengthSource& source = args.string;
    std::optional<Bun::Bindgen::BufferEncoding> encodingInput = args.encoding;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto encoding = encodingInput.value_or(WebCore::BufferEncodingType::utf8);

    if (source.is_string()) {
        auto* string = asString(source.string());
        auto length = Bun::byteLength(string, lexicalGlobalObject, encoding);
        JSC::ensureStillAliveHere(string);
        RETURN_IF_EXCEPTION(scope, 0);
        if (!length) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return 0;
        }
        return *length;
    }
    if (source.is_view())
        return dynamicDowncast<JSC::JSArrayBufferView>(source.view())->byteLength();
    return dynamicDowncast<JSC::JSArrayBuffer>(source.array_buffer())->impl()->byteLength();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferConstructorFunction_copyBytesFrom(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferConstructorFunction_copyBytesFrom_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSArrayBufferView* view = bindgenArrayBufferView(args.view);
    std::optional<uint64_t> offsetInput = args.offset;
    std::optional<uint64_t> lengthInput = args.length;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    const auto viewLength = view->length();
    const auto requestedOffset = offsetInput.value_or(0);
    if (requestedOffset >= viewLength) {
        auto* result = createEmptyBuffer(lexicalGlobalObject);
        RETURN_IF_EXCEPTION(throwScope, {});
        RELEASE_AND_RETURN(throwScope, result);
    }

    const size_t offset = requestedOffset;
    const size_t available = viewLength - offset;
    const size_t length = std::min<uint64_t>(lengthInput.value_or(available), available);
    const auto elementSize = JSC::elementSize(JSC::typedArrayType(view->type()));
    const auto span = view->span().subspan(offset * elementSize, length * elementSize);
    auto* result = createBuffer(lexicalGlobalObject, span.data(), span.size());
    JSC::ensureStillAliveHere(view);
    RETURN_IF_EXCEPTION(throwScope, {});
    RELEASE_AND_RETURN(throwScope, result);
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_equals(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_equals_Arguments& args)
{
    const auto& source = args.bindingThis;
    const auto& target = args.other;
    size_t a_length = source.size();
    size_t b_length = target.size();
    auto sourceStartPtr = source.unsafePtr("The entry frame holds both leases through synchronous memcmp"_s);
    auto targetStartPtr = target.unsafePtr("The entry frame holds both leases through synchronous memcmp"_s);

    // same pointer, same length, same contents
    if (sourceStartPtr == targetStartPtr && a_length == b_length)
        return true;

    size_t compare_length = std::min(a_length, b_length);
    auto result = compare_length > 0 ? memcmp(sourceStartPtr, targetStartPtr, compare_length) : 0;

    return normalizeCompareVal(result, a_length, b_length) == 0;
}

Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_compare_Return::Type Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_compare(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_compare_Arguments& args)
{
    using Result = BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_compare_Return;
    auto outOfRange = [](ASCIILiteral name, size_t upper, uint64_t actual) -> Result::Type {
        auto message = WTF::tryMakeString("The value of \""_s, name, "\" is out of range. It must be >= 0 and <= "_s, upper, ". Received "_s, actual);
        if (message.isNull())
            return Bun::Bindgen::nativeAllocationFailure();
        return std::unexpected(Result::Errors::out_of_range { WTF::move(message) });
    };
    const auto& source = args.bindingThis;
    const auto& target = args.target;
    size_t targetStart = args.targetStart.value_or(0);
    size_t targetEnd = args.targetEnd.value_or(target.size());
    size_t sourceStart = args.sourceStart.value_or(0);
    size_t sourceEnd = args.sourceEnd.value_or(source.size());
    if (targetEnd > target.size())
        return outOfRange("targetEnd"_s, target.size(), targetEnd);
    if (sourceEnd > source.size())
        return outOfRange("sourceEnd"_s, source.size(), sourceEnd);
    // Starts beyond the buffer are valid when they describe an empty range.
    if (sourceStart >= sourceEnd)
        return targetStart >= targetEnd ? 0 : -1;
    if (targetStart >= targetEnd)
        return 1;
    size_t sourceLength = sourceEnd - sourceStart;
    size_t targetLength = targetEnd - targetStart;
    auto* sourceBytes = source.unsafePtr("The entry frame holds the source lease through synchronous memcmp"_s) + sourceStart;
    auto* targetBytes = target.unsafePtr("The entry frame holds the target lease through synchronous memcmp"_s) + targetStart;
    int result = memcmp(sourceBytes, targetBytes, std::min(sourceLength, targetLength));
    return normalizeCompareVal(result, sourceLength, targetLength);
}

uint64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_copy(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_copy_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* sourceView = bindgenUint8Array(args.bindingThis);
    auto* targetView = bindgenUint8Array(args.target);
    const auto& targetStartInput = args.targetStart;
    const auto& sourceStartInput = args.sourceStart;
    const auto& sourceEndInput = args.sourceEnd;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    double targetStartD = 0;
    if (targetStartInput) {
        auto* targetStart = targetStartInput->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!targetStart)
            return 0;
        targetStartD = *targetStart;
        if (targetStartD < 0) {
            Bun::ERR::OUT_OF_RANGE(throwScope, lexicalGlobalObject, "targetStart"_s, 0, targetView->byteLength(), JSC::jsNumber(*targetStart));
            return 0;
        }
    }

    double sourceStartD = 0;
    if (sourceStartInput) {
        auto* sourceStart = sourceStartInput->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!sourceStart)
            return 0;
        sourceStartD = *sourceStart;
        auto sourceLengthAtCheck = sourceView->byteLength();
        if (sourceStartD < 0 || sourceStartD > sourceLengthAtCheck) {
            Bun::ERR::OUT_OF_RANGE(throwScope, lexicalGlobalObject, "sourceStart"_s, 0, sourceLengthAtCheck, JSC::jsNumber(*sourceStart));
            return 0;
        }
    }

    bool sourceEndGiven = sourceEndInput.has_value();
    double sourceEndD = 0;
    if (sourceEndGiven) {
        auto* sourceEnd = sourceEndInput->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!sourceEnd)
            return 0;
        sourceEndD = *sourceEnd;
        if (sourceEndD < 0) {
            Bun::ERR::OUT_OF_RANGE(throwScope, lexicalGlobalObject, "sourceEnd"_s, 0, sourceView->byteLength(), JSC::jsNumber(*sourceEnd));
            return 0;
        }
    }

    auto sourceLength = sourceView->byteLength();
    auto targetLength = targetView->byteLength();

    size_t targetStart = static_cast<size_t>(targetStartD);
    size_t sourceStart = static_cast<size_t>(sourceStartD);
    size_t sourceEnd = sourceEndGiven ? std::min<size_t>(static_cast<size_t>(sourceEndD), sourceLength) : sourceLength;

    if (targetStart >= targetLength || sourceStart >= sourceEnd) {
        return 0;
    }

    if (sourceEnd - sourceStart > targetLength - targetStart)
        sourceEnd = sourceStart + (targetLength - targetStart);

    const auto* source = args.sourceBytes->convert();
    RETURN_IF_EXCEPTION(throwScope, 0);
    if (!source)
        return 0;
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* target = args.targetBytes->convertLast(proof);
    RETURN_IF_EXCEPTION(throwScope, 0);
    if (!target || !context.lease(proof))
        return 0;

    size_t nb = sourceEnd - sourceStart;
    auto sourceStartPtr = source->unsafePtr("The entry frame holds the source lease through synchronous memmove"_s) + sourceStart;
    auto targetStartPtr = target->unsafePtr("The entry frame holds the target lease through synchronous memmove"_s) + targetStart;
    memmove(targetStartPtr, sourceStartPtr, nb);

    return nb;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_inspect(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_inspect_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSUint8Array* castedThis = bindgenUint8Array(args.bindingThis);
    bool includeProperties = args.options.has_value();
    bool showHidden = args.options ? args.options->show_hidden : false;
    auto globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::StringBuilder result(OverflowPolicy::RecordOverflow);
    auto data = castedThis->span();
    auto alphabet = "0123456789abcdef"_s;
    auto any = false;

    result.append("<Buffer"_s);
    const size_t actualMax = std::min<double>(globalObject->INSPECT_MAX_BYTES, data.size());

    for (auto item : data.first(actualMax)) {
        any = true;
        result.append(' ');
        result.append(alphabet[item / 16]);
        result.append(alphabet[item % 16]);
        if (result.hasOverflowed()) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
    }
    if (data.size() > actualMax) {
        const size_t remaining = data.size() - actualMax;
        result.append(" ... "_s, remaining, " more byte"_s);
        if (remaining > 1) result.append('s');
    }
    if (result.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    // Inspect special properties as well, if possible.
    if (includeProperties) {
        JSC::PropertyNameArrayBuilder array(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Exclude);

        auto filter = showHidden ? DontEnumPropertiesMode::Include : DontEnumPropertiesMode::Exclude;

        if (castedThis->hasNonReifiedStaticProperties()) [[unlikely]] {
            castedThis->reifyAllStaticProperties(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
        }
        castedThis->getOwnNonIndexPropertyNames(globalObject, array, filter);
        RETURN_IF_EXCEPTION(scope, {});

        if (array.size() > 0) {
            any = true;
            if (data.size() > 0) {
                result.append(',');
            }
            result.append(' ');
            size_t i = 0;
            for (auto ident : array) {
                if (i > 0) result.append(", "_s);
                result.append(ident.string());
                result.append(": "_s);
                if (result.hasOverflowed()) {
                    throwOutOfMemoryError(globalObject, scope);
                    return {};
                }
                auto value = castedThis->get(globalObject, ident);
                RETURN_IF_EXCEPTION(scope, {});
                auto inspected = Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_inspectSingleLine(globalObject, value);
                RETURN_IF_EXCEPTION(scope, {});
                result.append(inspected);
                i++;
            }
        }
    }
    if (!any) result.append(' ');
    result.append('>');
    if (result.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto text = tryMakeString(StringView(result));
    if (text.isNull()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    return JSC::jsString(vm, text);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_swap16(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_swap16_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSUint8Array* castedThis = bindgenUint8Array(args.bindingThis);
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    constexpr size_t elemSize = 2;
    size_t length = castedThis->byteLength();
    if (length % elemSize != 0) {
        throwNodeRangeError(lexicalGlobalObject, scope, "Buffer size must be a multiple of 16-bits"_s);
        return {};
    }

    if (castedThis->isDetached()) [[unlikely]] {
        throwVMTypeError(lexicalGlobalObject, scope, "Buffer is detached"_s);
        return {};
    }

    swapBufferWords<uint16_t>(castedThis->typedSpan());

    return castedThis;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_swap32(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_swap32_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSUint8Array* castedThis = bindgenUint8Array(args.bindingThis);
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    constexpr size_t elemSize = 4;
    size_t length = castedThis->byteLength();
    if (length % elemSize != 0) {
        throwNodeRangeError(lexicalGlobalObject, scope, "Buffer size must be a multiple of 32-bits"_s);
        return {};
    }

    if (castedThis->isDetached()) [[unlikely]] {
        throwVMTypeError(lexicalGlobalObject, scope, "Buffer is detached"_s);
        return {};
    }

    swapBufferWords<uint32_t>(castedThis->typedSpan());

    return castedThis;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_swap64(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_swap64_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSUint8Array* castedThis = bindgenUint8Array(args.bindingThis);
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    constexpr size_t elemSize = 8;
    size_t length = castedThis->byteLength();
    if (length % elemSize != 0) {
        throwNodeRangeError(lexicalGlobalObject, scope, "Buffer size must be a multiple of 64-bits"_s);
        return {};
    }

    if (castedThis->isDetached()) [[unlikely]] {
        throwVMTypeError(lexicalGlobalObject, scope, "Buffer is detached"_s);
        return {};
    }

    swapBufferWords<uint64_t>(castedThis->typedSpan());

    return castedThis;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_slice(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_slice_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSUint8Array* castedThis = bindgenUint8Array(args.bindingThis);
    const std::optional<Bun::Bindgen::CppLazyArgument<double>>& startInput = args.start;
    const std::optional<Bun::Bindgen::CppLazyArgument<double>>& endInput = args.end;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    size_t byteLength = castedThis->byteLength();
    size_t byteOffset = castedThis->byteOffset();

    size_t startOffset = 0;
    size_t endOffset = byteLength;

    if (startInput) {
        auto* start = startInput->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!start)
            return {};
        startOffset = adjustSliceOffsetDouble(*start, byteLength);
    }

    if (endInput) {
        auto* end = endInput->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!end)
            return {};
        endOffset = adjustSliceOffsetDouble(*end, byteLength);
    }

    size_t newLength = endOffset > startOffset ? endOffset - startOffset : 0;

    if (castedThis->isDetached()) [[unlikely]] {
        throwVMTypeError(lexicalGlobalObject, throwScope, "Buffer is detached"_s);
        return {};
    }

    RefPtr<ArrayBuffer> buffer = castedThis->possiblySharedBuffer();
    if (!buffer) {
        throwOutOfMemoryError(globalObject, throwScope);
        return {};
    }

    if (castedThis->isResizableOrGrowableShared()) {
        auto* subclassStructure = globalObject->JSResizableOrGrowableSharedBufferSubclassStructure();
        auto* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, WTF::move(buffer), byteOffset + startOffset, newLength);
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!uint8Array) [[unlikely]] {
            throwOutOfMemoryError(globalObject, throwScope);
            return {};
        }
        RELEASE_AND_RETURN(throwScope, uint8Array);
    }

    auto* subclassStructure = globalObject->JSBufferSubclassStructure();
    auto* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, WTF::move(buffer), byteOffset + startOffset, newLength);
    RETURN_IF_EXCEPTION(throwScope, {});
    if (!uint8Array) [[unlikely]] {
        throwOutOfMemoryError(globalObject, throwScope);
        return {};
    }

    RELEASE_AND_RETURN(throwScope, uint8Array);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_jsBufferPrototypeFunction_toString(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_jsBufferPrototypeFunction_toString_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSUint8Array* castedThis = bindgenUint8Array(args.bindingThis);
    const std::optional<Bun::Bindgen::CppLazyArgument<Bun::Bindgen::BufferEncoding>>& encodingInput = args.encoding;
    const std::optional<Bun::Bindgen::CppLazyArgument<double>>& startInput = args.start;
    const std::optional<Bun::Bindgen::CppLazyArgument<uint64_t>>& endInput = args.end;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    size_t start = 0;
    size_t end = castedThis->byteLength();
    const size_t byteLength = end;
    WebCore::BufferEncodingType encoding = WebCore::BufferEncodingType::utf8;

    if (end == 0)
        return JSC::jsEmptyString(vm);

    if (encodingInput) {
        auto* converted = encodingInput->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        encoding = *converted;
    }

    if (startInput) {
        auto* converted = startInput->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        auto fstart = *converted;
        if (fstart < 0)
            fstart = 0;
        if (fstart > byteLength)
            return JSC::jsEmptyString(vm);
        start = std::isnan(fstart) ? 0 : static_cast<size_t>(fstart);
    }

    if (endInput) {
        auto* converted = endInput->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        auto lend = *converted;
        if (lend < byteLength) end = lend;
    }

    if (end <= start)
        return JSC::jsEmptyString(vm);

    auto offset = start;
    auto length = end > start ? end - start : 0;
    return jsBufferToString(lexicalGlobalObject, scope, castedThis, offset, length, encoding);
}

#define DEFINE_BUFFER_ENCODED_WRITE_BINDING(name, encoding)                                                                \
    uint64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_##name(                                                           \
        Bun::Bindgen::CppCallContext& context, const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_##name##_Arguments& args) \
    {                                                                                                                      \
        return WebCore::writeEncodedBufferRange<WebCore::BufferEncodingType::encoding>(                                    \
            &context.globalObject, bindgenArrayBufferView(args.bindingThis), args.text, args.offset, args.length);         \
    }

#define DEFINE_BUFFER_ENCODED_SLICE_BINDING(name, encoding)                                                                \
    JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_##name(                                                       \
        Bun::Bindgen::CppCallContext& context, const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_##name##_Arguments& args) \
    {                                                                                                                      \
        return WebCore::jsBufferPrototypeFunction_SliceWithEncoding<WebCore::BufferEncodingType::encoding>(                \
            &context.globalObject, bindgenArrayBufferView(args.bindingThis), args.start, args.end);                        \
    }

DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_utf16leWrite, utf16le)
DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_utf8Write, utf8)
DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_latin1Write, latin1)
DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_asciiWrite, ascii)
DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_base64Write, base64)
DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_base64urlWrite, base64url)
DEFINE_BUFFER_ENCODED_WRITE_BINDING(jsBufferPrototypeFunction_hexWrite, hex)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_utf8Slice, utf8)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_utf16leSlice, utf16le)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_latin1Slice, latin1)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_asciiSlice, ascii)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_base64Slice, base64)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_base64urlSlice, base64url)
DEFINE_BUFFER_ENCODED_SLICE_BINDING(jsBufferPrototypeFunction_hexSlice, hex)

#undef DEFINE_BUFFER_ENCODED_SLICE_BINDING
#undef DEFINE_BUFFER_ENCODED_WRITE_BINDING

#define DEFINE_BUFFER_BIGINT_BINDING(name, Integer, bigEndian)                                                                                          \
    uint64_t Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_##name(                                                                                       \
        Bun::Bindgen::CppCallContext& context, const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_##name##_Arguments& args)                             \
    {                                                                                                                                                  \
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());                                                                                   \
        auto* receiver = bindgenArrayBufferView(args.bindingThis);                                                                                     \
        auto offset = WebCore::validateOffsetBigInt64(&context.globalObject, scope, args.offset, receiver->byteLength());                              \
        RETURN_IF_EXCEPTION(scope, 0);                                                                                                                  \
        return WebCore::writeBufferBigInt<Integer, bigEndian>(receiver, args.value, offset);                                                            \
    }

DEFINE_BUFFER_BIGINT_BINDING(jsBufferPrototypeFunction_writeBigInt64LE, int64_t, false)
DEFINE_BUFFER_BIGINT_BINDING(jsBufferPrototypeFunction_writeBigInt64BE, int64_t, true)
DEFINE_BUFFER_BIGINT_BINDING(jsBufferPrototypeFunction_writeBigUInt64LE, uint64_t, false)
DEFINE_BUFFER_BIGINT_BINDING(jsBufferPrototypeFunction_writeBigUInt64BE, uint64_t, true)

#undef DEFINE_BUFFER_BIGINT_BINDING

namespace WebCore {

#define BUN_BINDGEN_OBJECT_SURFACE_JSBufferPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSBufferPrototype

void JSBufferPrototype::finishCreation(VM& vm, JSC::JSGlobalObject*)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSBufferPrototype_install(vm, JSBuffer::info(), *this);
}

const ClassInfo JSBufferPrototype::s_info = {
    // In Node.js, Object.prototype.toString.call(new Buffer(0)) returns "[object Uint8Array]".
    // We must use the same naming convention to match Node
    // Some packages (like MongoDB's official Node.js client) rely on this behavior.
    "Uint8Array"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSBufferPrototype)
};

#define BUN_BINDGEN_OBJECT_SURFACE_JSBufferConstructor
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSBufferConstructor

const ClassInfo JSBufferConstructor::s_info = { "Buffer"_s, &Base::s_info, &bunBindgenObjectSurface_JSBufferConstructorTable, nullptr, CREATE_METHOD_TABLE(JSBufferConstructor) };

void JSBufferConstructor::finishCreation(VM& vm, JSGlobalObject*, JSC::JSObject* prototype)
{
    Base::finishCreation(vm, 3, "Buffer"_s, PropertyAdditionMode::WithoutStructureTransition);
    prototype->putDirect(vm, vm.propertyNames->speciesSymbol, this, PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
}

JSC::Structure* createBufferStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
{
    return JSBuffer::createStructure(vm, globalObject, prototype);
}

JSC::JSObject* createBufferPrototype(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    return JSBufferPrototype::create(vm, globalObject, JSBufferPrototype::createStructure(vm, globalObject, globalObject->m_typedArrayUint8.prototype(globalObject)));
}

JSC::JSObject* createBufferConstructor(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSObject* bufferPrototype)
{
    return JSBufferConstructor::create(
        vm,
        globalObject,
        JSBufferConstructor::createStructure(vm, globalObject),
        bufferPrototype);
}

} // namespace WebCore

static JSValue constructBufferFromArrayBuffer(
    JSGlobalObject* lexicalGlobalObject,
    JSC::JSArrayBuffer* jsBuffer,
    const std::optional<Bun::Bindgen::CppLazyArgument<double>>& offsetValue,
    const std::optional<Bun::Bindgen::CppLazyArgument<double>>& lengthValue)
{
    auto throwScope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    RefPtr<ArrayBuffer> buffer = jsBuffer->impl();
    const bool isResizableOrGrowableShared = jsBuffer->isResizableOrGrowableShared();
    if (buffer->isDetached()) {
        {
            throwVMTypeError(globalObject, throwScope, "Buffer is detached"_s);
            return {};
        }
    }
    size_t byteLength = buffer->byteLength();
    size_t offset = 0;
    size_t length = byteLength;

    if (offsetValue) {
        const auto* converted = offsetValue->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!converted)
            return {};
        double offsetD = *converted;
        if (buffer->isDetached()) {
            throwVMTypeError(globalObject, throwScope, "Buffer is detached"_s);
            return {};
        }
        byteLength = buffer->byteLength();
        if (std::isnan(offsetD)) offsetD = 0;
        offset = truncateDoubleToUint64(offsetD);
        if (offset > byteLength) {
            Bun::ERR::BUFFER_OUT_OF_BOUNDS(throwScope, lexicalGlobalObject, "offset"_s);
            return {};
        }
        length = byteLength - offset;
    }

    if (lengthValue) {
        const auto* converted = lengthValue->convert();
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!converted)
            return {};
        double lengthD = *converted;
        if (buffer->isDetached()) {
            throwVMTypeError(globalObject, throwScope, "Buffer is detached"_s);
            return {};
        }
        byteLength = buffer->byteLength();
        if (offset > byteLength) {
            Bun::ERR::BUFFER_OUT_OF_BOUNDS(throwScope, lexicalGlobalObject, "offset"_s);
            return {};
        }
        if (std::isnan(lengthD)) lengthD = 0;
        length = truncateDoubleToUint64(lengthD);
        if (length > byteLength - offset) {
            Bun::ERR::BUFFER_OUT_OF_BOUNDS(throwScope, lexicalGlobalObject, "length"_s);
            return {};
        }
    }

    if (isResizableOrGrowableShared) {
        auto* subclassStructure = globalObject->JSResizableOrGrowableSharedBufferSubclassStructure();
        RETURN_IF_EXCEPTION(throwScope, {});
        const std::optional<size_t> viewLength = lengthValue ? std::optional<size_t>(length) : std::nullopt;
        auto* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, WTF::move(buffer), offset, viewLength);
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!uint8Array) [[unlikely]] {
            throwOutOfMemoryError(globalObject, throwScope);
            return {};
        }
        RELEASE_AND_RETURN(throwScope, uint8Array);
    }
    auto* subclassStructure = globalObject->JSBufferSubclassStructure();
    RETURN_IF_EXCEPTION(throwScope, {});
    auto* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, WTF::move(buffer), offset, length);
    RETURN_IF_EXCEPTION(throwScope, {});
    if (!uint8Array) [[unlikely]] {
        throwOutOfMemoryError(globalObject, throwScope);
        return {};
    }

    RELEASE_AND_RETURN(throwScope, uint8Array);
}

static JSC::JSValue constructBufferFromTypedArray(JSC::JSGlobalObject* globalObject, JSC::JSArrayBufferView* view)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (view->isDetached()) {
        throwException(globalObject, scope, createRangeError(globalObject, "Buffer is detached"_s));
        return {};
    }

    const size_t length = view->length();
    auto* result = createUninitializedBuffer(globalObject, length);
    RETURN_IF_EXCEPTION(scope, {});
    if (length) {
        bool copied = result->setFromTypedArray(globalObject, 0, view, 0, length, CopyType::LeftToRight);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_ASSERT(copied);
    }
    return result;
}

static JSC::JSValue constructBufferFromDataView(JSC::JSGlobalObject* globalObject, JSC::JSArrayBufferView* view)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (view->isDetached()) {
        throwException(globalObject, scope, createRangeError(globalObject, "Buffer is detached"_s));
        return {};
    }

    auto* result = createBuffer(globalObject, static_cast<const uint8_t*>(view->vector()), view->byteLength());
    JSC::ensureStillAliveHere(view);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_number_encoding(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_number_encoding_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    Bun::ERR::INVALID_ARG_TYPE(scope, &context.globalObject, "string"_s, "string"_s, JSC::jsNumber(args.size));
    return {};
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_number_encoding(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_number_encoding_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    Bun::ERR::INVALID_ARG_TYPE(scope, &context.globalObject, "string"_s, "string"_s, JSC::jsNumber(args.size));
    return {};
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_number(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_number_Arguments& args)
{
    return allocateBuffer(&context.globalObject, args.size);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_number(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_number_Arguments& args)
{
    return allocateBuffer(&context.globalObject, args.size);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_string_Arguments& args)
{
    auto encoding = args.encoding && args.encoding->is_encoding()
        ? args.encoding->encoding()
        : Bun::Bindgen::BufferEncoding::utf8;
    return constructBufferFromStringAndEncoding(&context.globalObject, args.text, encoding);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_string(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_string_Arguments& args)
{
    auto encoding = args.encoding && args.encoding->is_encoding()
        ? args.encoding->encoding()
        : Bun::Bindgen::BufferEncoding::utf8;
    return constructBufferFromStringAndEncoding(&context.globalObject, args.text, encoding);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_typed_array(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_typed_array_Arguments& args)
{
    return constructBufferFromTypedArray(&context.globalObject, bindgenArrayBufferView(args.view));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_typed_array(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_typed_array_Arguments& args)
{
    return constructBufferFromTypedArray(&context.globalObject, bindgenArrayBufferView(args.view));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_data_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_data_view_Arguments& args)
{
    return constructBufferFromDataView(&context.globalObject, bindgenArrayBufferView(args.view));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_data_view(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_data_view_Arguments& args)
{
    return constructBufferFromDataView(&context.globalObject, bindgenArrayBufferView(args.view));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_array_buffer(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_array_buffer_Arguments& args)
{
    return constructBufferFromArrayBuffer(
        &context.globalObject, uncheckedDowncast<JSC::JSArrayBuffer>(args.buffer), args.offset, args.length);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_array_buffer(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_array_buffer_Arguments& args)
{
    return constructBufferFromArrayBuffer(
        &context.globalObject, uncheckedDowncast<JSC::JSArrayBuffer>(args.buffer), args.offset, args.length);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_array(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_array_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* result = createBuffer(&context.globalObject, args.values.span().data(), args.values.size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_array(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_array_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* result = createBuffer(&context.globalObject, args.values.span().data(), args.values.size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

#define DEFINE_BUFFER_SEQUENCE_CONSTRUCTOR(name, overload)                                                                                     \
    JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_##name##_overload_##overload(                                                       \
        Bun::Bindgen::CppCallContext& context,                                                                                                \
        const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_##name##_overload_##overload##_Arguments& args)                                       \
    {                                                                                                                                       \
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());                                                                         \
        auto* result = createBuffer(&context.globalObject, args.values.span().data(), args.values.size());                                    \
        RETURN_IF_EXCEPTION(scope, {});                                                                                                      \
        return result;                                                                                                                       \
    }

DEFINE_BUFFER_SEQUENCE_CONSTRUCTOR(callJSBuffer, iterable)
DEFINE_BUFFER_SEQUENCE_CONSTRUCTOR(constructJSBuffer, iterable)

#undef DEFINE_BUFFER_SEQUENCE_CONSTRUCTOR

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_callJSBuffer_overload_array_like(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_callJSBuffer_overload_array_like_Arguments& args)
{
    if (!args.values)
        return constructBufferEmpty(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* result = createBuffer(&context.globalObject, args.values->span().data(), args.values->size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_constructJSBuffer_overload_array_like(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_constructJSBuffer_overload_array_like_Arguments& args)
{
    if (!args.values)
        return constructBufferEmpty(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* result = createBuffer(&context.globalObject, args.values->span().data(), args.values->size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_getJSBufferConstructor(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_getJSBufferConstructor_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->JSBufferConstructor();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BufferHost_getJSBufferPrototype(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BufferHost_getJSBufferPrototype_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->JSBufferPrototype();
}

bool Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_jsValueIsBuffer(
    Bun::Bindgen::EngineCallContext&,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_jsValueIsBuffer_Arguments& args)
{
    return WebCore::isNodeBuffer(args.value);
}
