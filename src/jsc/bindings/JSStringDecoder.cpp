#include "JSStringDecoder.h"
#include "JSBuffer.h"
#include "SchemaBindings.h"
#include "Bindgen/EnumerationConversion.h"
#include <JavaScriptCore/Lookup.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include "JavaScriptCore/ExceptionScope.h"
#include "ZigGlobalObject.h"
#include "JSDOMOperation.h"
#include <JavaScriptCore/JSArrayBufferView.h>
#include "BunClientData.h"
#include "wtf/text/ASCIILiteral.h"
#include "wtf/text/StringImpl.h"
#include "wtf/unicode/CharacterNames.h"
#include "wtf/SIMDUTF.h"
#include "ErrorCode.h"

namespace WebCore {

using namespace JSC;

// Checks the type of a UTF-8 byte, whether it's ASCII, a leading byte, or a
// continuation byte.
//     0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
// 0   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 1   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 2   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 3   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 4   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 5   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 6   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 7   0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
// 8  -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
// 9  -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
// A  -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
// B  -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
// C   2  2  2  2  2  2  2  2  2  2  2  2  2  2  2  2
// D   2  2  2  2  2  2  2  2  2  2  2  2  2  2  2  2
// E   3  3  3  3  3  3  3  3  3  3  3  3  3  3  3  3
// F   4  4  4  4  4  4  4  4 -2 -2 -2 -2 -2 -2 -2 -2
int8_t utf8CheckByte(uint8_t byte)
{
    if (byte <= 0x7F)
        return 0; // ASCII
    else if ((byte >> 5) == 0x06)
        return 2; // 2-byte Start
    else if ((byte >> 4) == 0x0E)
        return 3; // 3-byte Start
    else if ((byte >> 3) == 0x1E)
        return 4; // 4-byte Start
    return (byte >> 6) == 0x02
        ? -1 // Continuation
        : -2; // Invalid
}

ALWAYS_INLINE bool isContinuation(uint8_t byte)
{
    return (byte & 0xC0) == 0x80;
}

static BufferEncodingType bufferEncoding(JSStringDecoder::Encoding encoding)
{
    using Encoding = JSStringDecoder::Encoding;
    using BufferEncoding = BufferEncodingType;
    switch (encoding) {
    case Encoding::utf8: return BufferEncoding::utf8;
    case Encoding::utf16le: return BufferEncoding::utf16le;
    case Encoding::latin1: return BufferEncoding::latin1;
    case Encoding::ascii: return BufferEncoding::ascii;
    case Encoding::base64: return BufferEncoding::base64;
    case Encoding::base64url: return BufferEncoding::base64url;
    case Encoding::hex: return BufferEncoding::hex;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static ALWAYS_INLINE JSString* encodingToString(const uint8_t* input, size_t len, JSGlobalObject* globalObject, JSStringDecoder::Encoding encoding)
{
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto value = bufferToStringFromBytes(globalObject, throwScope, std::span<const uint8_t> { input, len }, bufferEncoding(encoding));
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    RELEASE_AND_RETURN(throwScope, jsString(vm, WTF::move(value)));
}

void JSStringDecoder::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    Base::finishCreation(vm);
}

// Checks at most 3 bytes at the end of a Buffer in order to detect an
// incomplete multi-byte UTF-8 character. The total number of bytes (2, 3, or 4)
// needed to complete the UTF-8 character (if applicable) are returned.
uint8_t JSStringDecoder::utf8CheckIncomplete(const uint8_t* bufPtr, size_t length, size_t i)
{
    size_t j = length - 1;
    if (j < i)
        return 0;
    int8_t nb = utf8CheckByte(bufPtr[j]);
    if (nb >= 0) {
        if (nb > 0)
            m_lastNeed = nb - 1;
        return nb;
    }
    if (j == 0 || --j < i || nb == -2)
        return 0;
    nb = utf8CheckByte(bufPtr[j]);
    if (nb >= 0) {
        if (nb > 0)
            m_lastNeed = nb - 2;
        return nb;
    }
    if (j == 0 || --j < i || nb == -2)
        return 0;
    nb = utf8CheckByte(bufPtr[j]);
    if (nb >= 0) {
        if (nb > 0) {
            if (nb == 2)
                nb = 0;
            else
                m_lastNeed = nb - 3;
        }
        return nb;
    }
    return 0;
}

JSC::JSString* JSStringDecoder::fillLast(JSC::VM& vm, JSC::JSGlobalObject* globalObject, const uint8_t* bufPtr, size_t length)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    if (m_encoding == Encoding::utf8) {
        // Check if the start has a failing UTF-8 code point. This is checking
        // for situations where the a new character starts instead of a
        // continuation byte. In this case, lastNeed (offset for decoding the
        // rest of bufPtr) needs to be set less than the number of codepoints
        // from what lastChar[0] requests since a new character starts.
        // Example:
        // [ 0xcc ] + [ 0xcc, 0x8c ]
        // The first byte is not known to be an error until the second chunk
        // comes in, to which the error is just the first 0xcc, and then
        // the second two bytes are seen as the valid code point.
        size_t max = std::min<size_t>(length, m_lastNeed);
        for (size_t i = 0; i < max; i++) {
            if (!isContinuation(bufPtr[i])) {
                // copy the continuation bytes to lastChar, then run it through
                // originally this had an abridged version of the utf-8 decoder,
                // but doing that is going to be more error prone.
                // Example: [ 0xf2, 0x90 ] + [ 0xD0 ] -> '' + '\uFFFD' + '\uFFFD'
                //            ~~~~~~~~~~       ~~~~  two total errors
                // Example: [ 0xf6, 0x90 ] + [ 0xD0 ] -> '' + '\uFFFD\uFFFD' + '\uFFFD'
                //            ~~~~  ~~~~       ~~~~  three total errors
                //            ^ 0xF6 is an invalid start byte
                size_t chars = m_lastTotal - m_lastNeed + i;
                memmove(m_lastChar + m_lastTotal - m_lastNeed, bufPtr, i);
                m_lastNeed = static_cast<uint8_t>(i);
                RELEASE_AND_RETURN(throwScope, encodingToString(m_lastChar, chars, globalObject, m_encoding));
            }
        }
    }
    if (m_lastNeed <= length) {
        memmove(m_lastChar + m_lastTotal - m_lastNeed, bufPtr, m_lastNeed);
        RELEASE_AND_RETURN(throwScope, encodingToString(m_lastChar, m_lastTotal, globalObject, m_encoding));
    }

    memmove(m_lastChar + m_lastTotal - m_lastNeed, bufPtr, length);
    if (m_encoding == Encoding::utf8) {
        uint8_t lastLastNeed = m_lastNeed;
        uint8_t total = utf8CheckIncomplete(m_lastChar, m_lastTotal - lastLastNeed + length, 0);
        if (total == 0) {
            size_t len = m_lastTotal - m_lastNeed + length;
            m_lastNeed = static_cast<uint8_t>(length);
            RELEASE_AND_RETURN(throwScope, encodingToString(m_lastChar, len, globalObject, m_encoding));
        }
        m_lastNeed = lastLastNeed;
    }

    m_lastNeed -= static_cast<uint8_t>(length);
    RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));
}

// This is not the exposed text
JSC::JSString* JSStringDecoder::text(JSC::VM& vm, JSC::JSGlobalObject* globalObject, const uint8_t* bufPtr, size_t length, size_t offset)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    switch (m_encoding) {
    case Encoding::utf16le: {
        if (length == offset)
            RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));
        if ((length - offset) % 2 == 0) {
            char16_t c = (static_cast<uint16_t>(bufPtr[length - 1]) << 8) + static_cast<uint16_t>(bufPtr[length - 2]);
            if (c >= 0xD800 && c <= 0xDBFF) {
                m_lastNeed = 2;
                m_lastTotal = 4;
                m_lastChar[0] = bufPtr[length - 2];
                m_lastChar[1] = bufPtr[length - 1];
                RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, length - offset - 2, globalObject, m_encoding));
            }
            RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, length - offset, globalObject, m_encoding));
        }
        m_lastNeed = 1;
        m_lastTotal = 2;
        m_lastChar[0] = bufPtr[length - 1];
        RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, length - offset - 1, globalObject, m_encoding));
    }
    case Encoding::utf8: {
        uint8_t total = utf8CheckIncomplete(bufPtr, length, offset);
        if (!m_lastNeed)
            RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, length - offset, globalObject, m_encoding));
        m_lastTotal = total;
        size_t end = length - (total - m_lastNeed);
        if (end < length)
            memmove(m_lastChar, bufPtr + end, std::min<size_t>(4, length - end));
        RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, end - offset, globalObject, m_encoding));
    }
    case Encoding::base64:
    case Encoding::base64url: {
        size_t n = (length - offset) % 3;
        if (n == 0)
            RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, length - offset, globalObject, m_encoding));
        m_lastNeed = static_cast<uint8_t>(3 - n);
        m_lastTotal = 3;
        if (n == 1) {
            m_lastChar[0] = bufPtr[length - 1];
        } else {
            m_lastChar[0] = bufPtr[length - 2];
            m_lastChar[1] = bufPtr[length - 1];
        }
        RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr + offset, length - offset - n, globalObject, m_encoding));
    }
    default: {
        // should never reach here.
        RELEASE_AND_RETURN(throwScope, nullptr);
        break;
    }
    }

    __builtin_unreachable();
}

JSC::JSString* JSStringDecoder::write(JSC::VM& vm, JSC::JSGlobalObject* globalObject, const uint8_t* bufPtr, size_t length)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    if (length == 0)
        RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));

    switch (m_encoding) {
    case Encoding::utf16le:
    case Encoding::utf8:
    case Encoding::base64:
    case Encoding::base64url: {
        size_t offset = 0;
        if (m_lastNeed) {
            JSString* firstHalf = fillLast(vm, globalObject, bufPtr, length);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            if (firstHalf->length() == 0)
                RELEASE_AND_RETURN(throwScope, firstHalf);
            offset = m_lastNeed;
            m_lastNeed = 0;
            if (offset == length)
                RELEASE_AND_RETURN(throwScope, firstHalf);

            JSString* secondHalf = text(vm, globalObject, bufPtr, length, offset);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            if (secondHalf->length() == 0)
                RELEASE_AND_RETURN(throwScope, firstHalf);
            RELEASE_AND_RETURN(throwScope, JSC::jsString(globalObject, firstHalf, secondHalf));
        }
        JSString* str = text(vm, globalObject, bufPtr, length, offset);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        RELEASE_AND_RETURN(throwScope, str);
    }
    default: {
        RELEASE_AND_RETURN(throwScope, encodingToString(bufPtr, length, globalObject, m_encoding));
    }
    }

    __builtin_unreachable();
}

class ResetScope final {
public:
    ResetScope(JSStringDecoder* decoder);
    ~ResetScope();
    JSStringDecoder* m_decoder;
};

ResetScope::ResetScope(JSStringDecoder* decoder)
{
    m_decoder = decoder;
}

ResetScope::~ResetScope()
{
    m_decoder->m_lastTotal = 0;
    m_decoder->m_lastNeed = 0;
    memset(m_decoder->m_lastChar, 0, 4);
}

JSC::JSString*
JSStringDecoder::end(JSC::VM& vm, JSC::JSGlobalObject* globalObject, const uint8_t* bufPtr, size_t length)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto resetScope = ResetScope(this);
    switch (m_encoding) {
    case Encoding::utf16le: {
        if (length == 0) {
            if (m_lastNeed) {
                RELEASE_AND_RETURN(throwScope, encodingToString(m_lastChar, m_lastTotal - m_lastNeed, globalObject, m_encoding));
            }
            RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));
        }
        JSString* firstHalf = write(vm, globalObject, bufPtr, length);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        if (m_lastNeed) {
            JSString* secondHalf = encodingToString(m_lastChar, m_lastTotal - m_lastNeed, globalObject, m_encoding);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            RELEASE_AND_RETURN(throwScope, JSC::jsString(globalObject, firstHalf, secondHalf));
        }
        RELEASE_AND_RETURN(throwScope, firstHalf);
    }
    case Encoding::utf8: {
        if (length == 0) {
            if (m_lastNeed) {
                RELEASE_AND_RETURN(throwScope, encodingToString(m_lastChar, m_lastTotal - m_lastNeed, globalObject, m_encoding));
            }
            RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));
        }
        JSString* firstHalf = write(vm, globalObject, bufPtr, length);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        if (m_lastNeed) {
            JSString* secondHalf = encodingToString(m_lastChar, m_lastTotal - m_lastNeed, globalObject, m_encoding);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            RELEASE_AND_RETURN(throwScope, JSC::jsString(globalObject, firstHalf, secondHalf));
        }
        RELEASE_AND_RETURN(throwScope, firstHalf);
    }
    case Encoding::base64:
    case Encoding::base64url: {
        if (length == 0) {
            if (m_lastNeed) {
                RELEASE_AND_RETURN(throwScope, encodingToString(m_lastChar, 3 - m_lastNeed, globalObject, m_encoding));
            }
            RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));
        }
        JSString* firstHalf = write(vm, globalObject, bufPtr, length);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        if (m_lastNeed) {
            JSString* secondHalf = encodingToString(m_lastChar, 3 - m_lastNeed, globalObject, m_encoding);
            RETURN_IF_EXCEPTION(throwScope, nullptr);
            RELEASE_AND_RETURN(throwScope, JSC::jsString(globalObject, firstHalf, secondHalf));
        }
        RELEASE_AND_RETURN(throwScope, firstHalf);
    }
    default: {
        if (length == 0) {
            RELEASE_AND_RETURN(throwScope, JSC::jsEmptyString(vm));
        }
        RELEASE_AND_RETURN(throwScope, write(vm, globalObject, bufPtr, length));
    }
    }
}

const JSC::ClassInfo JSStringDecoder::s_info = { "StringDecoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSStringDecoder) };

JSC::GCClient::IsoSubspace* JSStringDecoder::subspaceForImpl(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<JSStringDecoder, UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForStringDecoder.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForStringDecoder = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForStringDecoder.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForStringDecoder = std::forward<decltype(space)>(space); });
}

STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSStringDecoderPrototype, JSStringDecoderPrototype::Base);

/* Hash table for prototype */
#define BUN_BINDGEN_OBJECT_SURFACE_JSStringDecoderPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSStringDecoderPrototype

void JSStringDecoderPrototype::finishCreation(VM& vm, JSC::JSGlobalObject* globalThis)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSStringDecoderPrototype_install(vm, JSStringDecoder::info(), *this);
}

const ClassInfo JSStringDecoderPrototype::s_info = { "StringDecoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSStringDecoderPrototype) };

void JSStringDecoderConstructor::finishCreation(VM& vm, JSC::JSGlobalObject* globalObject, JSStringDecoderPrototype* prototype)
{
    Base::finishCreation(vm, 0, "StringDecoder"_s, PropertyAdditionMode::WithoutStructureTransition);
    putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    ASSERT(inherits(info()));
}

JSStringDecoderConstructor* JSStringDecoderConstructor::create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, JSStringDecoderPrototype* prototype)
{
    JSStringDecoderConstructor* ptr = new (NotNull, JSC::allocateCell<JSStringDecoderConstructor>(vm)) JSStringDecoderConstructor(vm, structure, bun_bindgen_host_StringDecoder_construct);
    ptr->finishCreation(vm, globalObject, prototype);
    return ptr;
}

void JSStringDecoderConstructor::initializeProperties(VM& vm, JSC::JSGlobalObject* globalObject, JSStringDecoderPrototype* prototype)
{
    putDirect(vm, vm.propertyNames->length, jsNumber(1), JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    JSString* nameString = jsNontrivialString(vm, "StringDecoder"_s);
    m_originalName.set(vm, this, nameString);
    putDirect(vm, vm.propertyNames->name, nameString, JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    putDirect(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
}

const ClassInfo JSStringDecoderConstructor::s_info = { "StringDecoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSStringDecoderConstructor) };

} // namespace Zig

static WebCore::JSStringDecoder* bindgenStringDecoder(const auto& receiver)
{
    const auto value = receiver.is_decoder() ? receiver.decoder() : receiver.wrapper().decoder;
    return uncheckedDowncast<WebCore::JSStringDecoder>(value);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_lastChar(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_lastChar_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto buffer = JSC::ArrayBuffer::create({ bindgenStringDecoder(args.bindingThis)->m_lastChar, 4 });
    auto* structure = static_cast<Zig::GlobalObject*>(globalObject)->JSBufferSubclassStructure();
    return JSC::JSUint8Array::create(globalObject, structure, WTF::move(buffer), 0, 4);
}

uint8_t Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_lastNeed(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_lastNeed_Arguments& args)
{
    return bindgenStringDecoder(args.bindingThis)->m_lastNeed;
}

uint8_t Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_lastTotal(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_lastTotal_Arguments& args)
{
    return bindgenStringDecoder(args.bindingThis)->m_lastTotal;
}

Bun::Bindgen::CoercedNodeStringEncoding Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_encoding(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_encoding_Arguments& args)
{
    return bindgenStringDecoder(args.bindingThis)->m_encoding;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_construct(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_construct_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = static_cast<Zig::GlobalObject*>(lexicalGlobalObject);
    auto encoding = args.encoding.value_or(Bun::Bindgen::CoercedNodeStringEncoding::utf8);

    auto* constructor = globalObject->JSStringDecoder();
    auto* jsObject = WebCore::JSStringDecoder::create(
        vm,
        lexicalGlobalObject,
        globalObject->JSStringDecoderStructure(),
        encoding);
    RETURN_IF_EXCEPTION(scope, {});

    auto* thisObject = args.bindingThis ? JSC::asObject(*args.bindingThis) : nullptr;
    if ((!args.bindingNewTarget || constructor != JSC::asObject(*args.bindingNewTarget)) && thisObject) {
        auto encodingName = Bun::Bindgen::enumerationString(encoding);
        if (!encodingName) {
            JSC::throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        auto* jsEncodingName = JSC::jsStringWithCache(vm, encodingName.value());
        RETURN_IF_EXCEPTION(scope, {});
        auto clientData = WebCore::clientData(vm);
        thisObject->putDirect(vm, clientData->builtinNames().decodePrivateName(), jsObject, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        RETURN_IF_EXCEPTION(scope, {});
        thisObject->putDirect(vm, clientData->builtinNames().encodingPublicName(), jsEncodingName, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, thisObject);
    }

    RELEASE_AND_RETURN(scope, jsObject);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_write(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_write_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (args.buf.is_string())
        return JSC::jsString(vm, args.buf.string());

    const auto& buffer = args.buf.buffer();
    auto* result = bindgenStringDecoder(args.bindingThis)->write(vm, globalObject, buffer.unsafePtr("The entry frame holds the input lease through synchronous string decoding"_s), buffer.size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_end(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_end_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.buf.has_value()) {
        auto* result = bindgenStringDecoder(args.bindingThis)->end(vm, globalObject, nullptr, 0);
        RETURN_IF_EXCEPTION(scope, {});
        return result;
    }

    const auto& buffer = *args.buf;
    auto* result = bindgenStringDecoder(args.bindingThis)->end(vm, globalObject, buffer.unsafePtr("The entry frame holds the input lease through synchronous string decoding"_s), buffer.size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_StringDecoder_text(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_StringDecoder_text_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto& buffer = args.buf;
    const auto offset = static_cast<size_t>(args.offset);
    if (offset > buffer.size())
        return JSC::jsEmptyString(vm);

    const auto input = std::span { buffer.unsafePtr("The entry frame holds the input lease through synchronous string decoding"_s), buffer.size() }.subspan(offset);
    auto* result = bindgenStringDecoder(args.bindingThis)->write(vm, globalObject, input.data(), input.size());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}
