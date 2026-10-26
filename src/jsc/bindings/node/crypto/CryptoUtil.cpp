#include "CryptoUtil.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include <openssl/err.h>
#include <limits>
#include "ErrorCode.h"
#include "ncrypto.h"
#include "JSBuffer.h"
#include "SchemaBindings.h"
#include "JSBufferEncodingType.h"

namespace Bun {

using namespace JSC;
using namespace ncrypto;

namespace ExternZigHash {

ResolveResult getByName(Zig::GlobalObject* globalObject, const StringView& name)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto utf8 = name.tryGetUTF8();
    if (!utf8) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto result = Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherGetByName(
        globalObject,
        std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8->data()), utf8->length() });
    HasherOwner hasher(result.hasher.value_or(nullptr));
    RETURN_IF_EXCEPTION(scope, {});
    return { result.status, WTF::move(hasher), result.errorCode };
}

ResolveResult getFromOther(Zig::GlobalObject* globalObject, Hasher* hasher)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto result = Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherGetFromOther(globalObject, hasher);
    HasherOwner copied(result.hasher.value_or(nullptr));
    RETURN_IF_EXCEPTION(scope, {});
    return { result.status, WTF::move(copied), result.errorCode };
}

void destroy(Hasher* hasher)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherDestroy(hasher);
}

OperationResult update(Hasher* hasher, std::span<const uint8_t> data)
{
    auto result = Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherUpdate(hasher, data);
    return { result.status, result.errorCode };
}

DigestResult digest(Hasher* hasher, Zig::GlobalObject* globalObject, std::span<uint8_t> out)
{
    auto result = Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherDigest(globalObject, hasher, out);
    return { result.status, result.length, result.errorCode };
}

uint32_t getDigestSize(Hasher* hasher)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherGetDigestSize(hasher);
}

bool isXof(Hasher* hasher)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_CryptoHasher_cryptoHasherIsXof(hasher);
}

}; // namespace ExternZigHash

void Bindgen::Engine::releaseCryptoHasherExtern(ExternZigHash::Hasher* hasher)
{
    ExternZigHash::destroy(hasher);
}

namespace StringBytes {

Bindgen::NodeCryptoEncodedOutputResult encode(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, std::span<const uint8_t> bytes, BufferEncodingType encoding)
{
    Bindgen::NodeCryptoEncodedOutputResult result;

    if (encoding == BufferEncodingType::buffer) {
        WTF::Vector<uint8_t> buffer;
        if (!buffer.tryGrow(bytes.size())) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        if (!bytes.empty())
            memcpy(buffer.mutableSpan().data(), bytes.data(), bytes.size());
        result.set_buffer(WTF::move(buffer));
        return result;
    }

    auto string = WebCore::bufferToStringFromBytes(lexicalGlobalObject, scope, bytes, encoding);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(!string.isNull());
    result.set_string(WTF::move(string));
    return result;
}

}

static JSValue createCryptoError(JSC::JSGlobalObject* globalObject, ThrowScope& scope, uint32_t err, const char* message, std::span<const uint32_t> errorStack)
{
    JSC::VM& vm = globalObject->vm();

    bool allocationFailed = err && ERR_GET_REASON(err) == ERR_R_MALLOC_FAILURE;
    for (auto error : errorStack) {
        if (ERR_GET_REASON(error) == ERR_R_MALLOC_FAILURE)
            allocationFailed = true;
    }
    if (allocationFailed) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    char message_buffer[128] = { 0 };
    if (err != 0 || message == nullptr) {
        ERR_error_string_n(err, message_buffer, sizeof(message_buffer));
        message = message_buffer;
    }

    WTF::String errorMessage = WTF::String::fromUTF8(message);
    if (errorMessage.isNull()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    JSC::JSObject* errorObject = createError(globalObject, errorMessage);
    RETURN_IF_EXCEPTION(scope, {});

    auto putString = [&](ASCIILiteral name, const WTF::String& value) -> bool {
        if (value.isNull()) {
            throwOutOfMemoryError(globalObject, scope);
            return false;
        }
        auto* string = jsString(vm, value);
        RETURN_IF_EXCEPTION(scope, false);
        errorObject->putDirect(vm, Identifier::fromString(vm, name), string);
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    };

    if (err != 0) {
        const char* lib = ERR_lib_error_string(err);
        const char* func = ERR_func_error_string(err);
        const char* reason = ERR_reason_error_string(err);

        if (lib && !putString("library"_s, WTF::String::fromUTF8(lib)))
            return {};
        if (func && !putString("function"_s, WTF::String::fromUTF8(func)))
            return {};

        if (reason) {
            WTF::String reasonString = WTF::String::fromUTF8(reason);
            if (!putString("reason"_s, reasonString))
                return {};
            constexpr char prefix[] = "ERR_OSSL_";
            constexpr size_t prefixLength = sizeof(prefix) - 1;
            std::span<UChar> units;
            auto code = WTF::String::tryCreateUninitialized(prefixLength + static_cast<size_t>(reasonString.length()), units);
            if (code.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            for (size_t i = 0; i < prefixLength; ++i)
                units[i] = prefix[i];
            for (size_t i = 0; i < reasonString.length(); ++i) {
                auto character = reasonString[i];
                units[prefixLength + i] = character >= 'a' && character <= 'z' ? character - ('a' - 'A') : character;
            }
            if (!putString("code"_s, code))
                return {};
        }
    }

    if (!errorStack.empty()) {
        if (errorStack.size() > std::numeric_limits<unsigned>::max()) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        unsigned count = static_cast<unsigned>(errorStack.size());
        auto arr = JSC::constructEmptyArray(globalObject, nullptr, count);
        RETURN_IF_EXCEPTION(scope, {});
        for (unsigned i = 0; i < count; ++i) {
            char text[256];
            ERR_error_string_n(errorStack[i], text, sizeof(text));
            auto error = WTF::String::fromUTF8(text);
            if (error.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            auto* string = jsString(vm, error);
            RETURN_IF_EXCEPTION(scope, {});
            arr->putDirectIndex(globalObject, i, string);
            RETURN_IF_EXCEPTION(scope, {});
        }
        errorObject->putDirect(vm, Identifier::fromString(vm, "opensslErrorStack"_s), arr);
        RETURN_IF_EXCEPTION(scope, {});
    }

    return errorObject;
}

void throwCryptoError(JSC::JSGlobalObject* globalObject, ThrowScope& scope, uint32_t err, const char* message)
{
    bool allocationFailed = err && ERR_GET_REASON(err) == ERR_R_MALLOC_FAILURE;
    WTF::Vector<uint32_t> errors;
    while (auto error = ERR_get_error()) {
        if (ERR_GET_REASON(error) == ERR_R_MALLOC_FAILURE)
            allocationFailed = true;
        if (!allocationFailed && !errors.tryAppend(error)) {
            ERR_clear_error();
            throwOutOfMemoryError(globalObject, scope);
            return;
        }
    }
    if (allocationFailed) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }
    JSValue errorObject = createCryptoError(globalObject, scope, err, message, errors.span());
    RETURN_IF_EXCEPTION(scope, void());
    throwException(globalObject, scope, errorObject);
}

void throwCapturedCryptoError(JSC::JSGlobalObject* globalObject, ThrowScope& scope, std::span<const uint32_t> errors, const char* message)
{
    uint32_t first = errors.empty() ? 0 : errors.front();
    auto remaining = errors.empty() ? errors : errors.subspan(1);
    JSValue errorObject = createCryptoError(globalObject, scope, first, message, remaining);
    RETURN_IF_EXCEPTION(scope, void());
    throwException(globalObject, scope, errorObject);
}

JSC::JSArrayBufferView* encodeCryptoString(JSGlobalObject* globalObject, ThrowScope& scope, const WTF::String& value, BufferEncodingType encoding)
{
    if (encoding == BufferEncodingType::hex && value.length() % 2 != 0) {
        auto reason = tryMakeString("is invalid for data of length "_s, value.length());
        if (reason.isNull()) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        ERR::INVALID_ARG_VALUE(scope, globalObject, "encoding"_s, jsString(globalObject->vm(), WTF::String("hex"_s)), reason);
        return {};
    }

    encoding = encoding == BufferEncodingType::buffer ? BufferEncodingType::utf8 : encoding;
    JSValue buffer = WebCore::constructFromEncoding(globalObject, WTF::StringView(value), encoding);
    RETURN_IF_EXCEPTION(scope, {});
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(buffer);
    RELEASE_ASSERT(view && !view->isDetached());
    return view;
}

ByteSource::ByteSource(ByteSource&& other) noexcept
    : data_(other.data_)
    , allocated_data_(other.allocated_data_)
    , size_(other.size_)
{
    other.allocated_data_ = nullptr;
}

ByteSource::~ByteSource()
{
    OPENSSL_clear_free(allocated_data_, size_);
}

std::span<const uint8_t> ByteSource::span() const
{
    return { reinterpret_cast<const uint8_t*>(data_), size_ };
}

ByteSource& ByteSource::operator=(ByteSource&& other) noexcept
{
    if (&other != this) {
        OPENSSL_clear_free(allocated_data_, size_);
        data_ = other.data_;
        allocated_data_ = other.allocated_data_;
        other.allocated_data_ = nullptr;
        size_ = other.size_;
    }
    return *this;
}

ByteSource ByteSource::fromBIO(const ncrypto::BIOPointer& bio)
{
    ASSERT(bio);
    BUF_MEM* bptr = bio;
    auto out = ncrypto::DataPointer::Alloc(bptr->length);
    memcpy(out.get(), bptr->data, bptr->length);
    return ByteSource::allocated(out.release());
}

ByteSource ByteSource::allocated(void* data, size_t size)
{
    return ByteSource(data, data, size);
}

ByteSource ByteSource::foreign(const void* data, size_t size)
{
    return ByteSource(data, nullptr, size);
}

}
