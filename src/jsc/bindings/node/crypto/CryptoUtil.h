#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoSignature.h"
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ThrowScope.h>
#include "CryptoAlgorithmRegistry.h"
#include "JSBufferEncodingType.h"
#include "Bindgen/BindingRuntimeDeclarations.h"
#include "SchemaBindingsEnumerations.h"
#include <memory>

namespace Bun {

using namespace JSC;

namespace Bindgen {
class NodeCryptoEncodedOutputResult;
class NodeSecretKeyObjectInput;
}

WTF::Vector<uint8_t> exportSecretKeyBytes(JSGlobalObject*, ThrowScope&, const Bindgen::NodeSecretKeyObjectInput&);

namespace ExternZigHash {
struct Hasher;
void destroy(Hasher*);

struct HasherDeleter {
    void operator()(Hasher* hasher) const { destroy(hasher); }
};
using HasherOwner = std::unique_ptr<Hasher, HasherDeleter>;

struct ResolveResult {
    Bindgen::CryptoHasherExternStatus status;
    HasherOwner hasher;
    uint32_t errorCode;
};

struct OperationResult {
    Bindgen::CryptoHasherExternStatus status;
    uint32_t errorCode;
};

struct DigestResult {
    Bindgen::CryptoHasherExternStatus status;
    uint32_t length;
    uint32_t errorCode;
};

ResolveResult getByName(Zig::GlobalObject* globalObject, const StringView& name);
ResolveResult getFromOther(Zig::GlobalObject* globalObject, Hasher* hasher);
OperationResult update(Hasher* hasher, std::span<const uint8_t> data);
DigestResult digest(Hasher* hasher, Zig::GlobalObject* globalObject, std::span<uint8_t> out);
uint32_t getDigestSize(Hasher* hasher);
bool isXof(Hasher* hasher);

}; // namespace ExternZigHash

namespace StringBytes {
Bindgen::NodeCryptoEncodedOutputResult encode(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, std::span<const uint8_t> bytes, BufferEncodingType encoding);
};

void throwCryptoError(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, uint32_t err, const char* message = nullptr);
void throwCapturedCryptoError(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint32_t>, const char* message);
JSC::JSArrayBufferView* encodeCryptoString(JSGlobalObject*, ThrowScope&, const WTF::String&, BufferEncodingType);

template<typename Encoding>
BufferEncodingType nodeEncodingToBufferEncoding(Encoding encoding)
{
    if (encoding == Encoding::utf8)
        return BufferEncodingType::utf8;
    if (encoding == Encoding::utf16le)
        return BufferEncodingType::utf16le;
    if (encoding == Encoding::latin1)
        return BufferEncodingType::latin1;
    if (encoding == Encoding::ascii)
        return BufferEncodingType::ascii;
    if (encoding == Encoding::base64)
        return BufferEncodingType::base64;
    if (encoding == Encoding::base64url)
        return BufferEncodingType::base64url;
    if (encoding == Encoding::hex)
        return BufferEncodingType::hex;
    if constexpr (requires { Encoding::buffer; })
        if (encoding == Encoding::buffer)
            return BufferEncodingType::buffer;
    RELEASE_ASSERT_NOT_REACHED();
}

template<typename Encoding>
BufferEncodingType nodeEncodingOrDefault(const std::optional<Encoding>& encoding, BufferEncodingType defaultEncoding)
{
    return encoding ? nodeEncodingToBufferEncoding(*encoding) : defaultEncoding;
}

template<typename Encoding>
BufferEncodingType nodeEncodingOrDefault(const std::optional<std::optional<Encoding>>& encoding, BufferEncodingType defaultEncoding)
{
    return encoding && *encoding ? nodeEncodingToBufferEncoding(**encoding) : defaultEncoding;
}

inline bool convertStringInputEncodingAndLease(
    Bindgen::CppCallContext& context,
    ThrowScope& scope,
    const auto& input,
    const auto& encodingValue,
    auto& encoding)
{
    bool converted = input.is_string()
        ? Bindgen::convertOptionalLastAndLease(context, encodingValue, encoding)
        : !encodingValue || Bindgen::discardPendingDeferredAndLease(context, encodingValue);
    RETURN_IF_EXCEPTION(scope, false);
    return converted;
}

template<typename StringOrBuffer>
GCOwnedDataScope<std::span<const uint8_t>> getStringOrBufferBytes(JSGlobalObject* globalObject, ThrowScope& scope, const StringOrBuffer& value, BufferEncodingType encoding)
{
    if (value.is_buffer()) {
        const auto& buffer = value.buffer();
        if constexpr (std::is_same_v<std::remove_cvref_t<decltype(buffer)>, Bindgen::CppScopedBytes>)
            return { nullptr, { buffer.unsafePtr("The entry frame holds the input lease through the synchronous crypto operation"_s), buffer.size() } };
        else
            return { nullptr, buffer };
    }

    auto* view = encodeCryptoString(globalObject, scope, value.string(), encoding);
    return { view, view ? view->span() : std::span<const uint8_t> {} };
}

template<typename StringOrBuffer, typename LazyEncoding>
GCOwnedDataScope<std::span<const uint8_t>> getStringOrBufferBytes(JSGlobalObject* globalObject, ThrowScope& scope, const StringOrBuffer& value, const std::optional<LazyEncoding>& encoding)
{
    BufferEncodingType bufferEncoding = BufferEncodingType::utf8;
    if (encoding) {
        const auto* converted = encoding->convert();
        if (!converted)
            return { nullptr, {} };
        if (*converted)
            bufferEncoding = nodeEncodingToBufferEncoding(**converted);
    }

    return getStringOrBufferBytes(globalObject, scope, value, bufferEncoding);
}

template<typename SecretKeyMaterial>
GCOwnedDataScope<std::span<const uint8_t>> getSecretKeyMaterial(JSGlobalObject* globalObject, ThrowScope& scope, const SecretKeyMaterial& value, BufferEncodingType encoding, std::span<const uint8_t> exportedKey)
{
    if (value.is_buffer()) {
        const auto& buffer = value.buffer();
        if constexpr (std::is_same_v<std::remove_cvref_t<decltype(buffer)>, Bindgen::CppScopedBytes>)
            return { nullptr, { buffer.unsafePtr("The entry frame holds the key lease through the synchronous crypto operation"_s), buffer.size() } };
        else
            return { nullptr, buffer };
    }
    if (value.is_key_object())
        return { nullptr, exportedKey };
    auto* view = encodeCryptoString(globalObject, scope, value.string(), encoding);
    return { view, view ? view->span() : std::span<const uint8_t> {} };
}

// Modified version of ByteSource from node
//
// https://github.com/nodejs/node/blob/2a6f90813f4802def79f2df1bfe20e95df279abf/src/crypto/crypto_util.h#L168
// A helper class representing a read-only byte array. When deallocated, its
// contents are zeroed.
class ByteSource final {
public:
    ByteSource() = default;
    ByteSource(ByteSource&& other) noexcept;
    ~ByteSource();

    ByteSource& operator=(ByteSource&& other) noexcept;

    ByteSource(const ByteSource&) = delete;
    ByteSource& operator=(const ByteSource&) = delete;

    std::span<const uint8_t> span() const;

    template<typename T = void>
    inline const T* data() const
    {
        return reinterpret_cast<const T*>(data_);
    }

    template<typename T = void>
    operator ncrypto::Buffer<const T>() const
    {
        return ncrypto::Buffer<const T> {
            .data = data<T>(),
            .len = size(),
        };
    }

    inline size_t size() const { return size_; }

    inline bool empty() const { return size_ == 0; }

    inline operator bool() const { return data_ != nullptr; }

    static ByteSource allocated(void* data, size_t size);

    template<typename T>
    static ByteSource allocated(const ncrypto::Buffer<T>& buffer)
    {
        return allocated(buffer.data, buffer.len);
    }

    static ByteSource foreign(const void* data, size_t size);

    static ByteSource fromBIO(const ncrypto::BIOPointer& bio);

private:
    const void* data_ = nullptr;
    void* allocated_data_ = nullptr;
    size_t size_ = 0;

    ByteSource(const void* data, void* allocated_data, size_t size)
        : data_(data)
        , allocated_data_(allocated_data)
        , size_(size)
    {
    }
};

}
