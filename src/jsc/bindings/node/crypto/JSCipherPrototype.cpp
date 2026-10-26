#include "JSCipherPrototype.h"
#include "JSCipher.h"
#include "SchemaBindings.h"
#include "ErrorCode.h"
#include "CryptoUtil.h"
#include "BunProcess.h"
#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>

using namespace Bun;
using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

static JSCipher* cipherObject(JSC::JSValue value)
{
    auto* cipher = dynamicDowncast<JSCipher>(value);
    RELEASE_ASSERT(cipher);
    return cipher;
}

const JSC::ClassInfo JSCipherPrototype::s_info = { "Cipher"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSCipherPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSCipherPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSCipherPrototype

void JSCipherPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSCipherPrototype_install(vm, JSCipherPrototype::info(), *this);
}

std::optional<Bun::Bindgen::CppBytes> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherUpdate(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherUpdate_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSCipher* cipher = cipherObject(args.bindingThis);

    if (!args.data) {
        ERR::INVALID_ARG_TYPE(scope, lexicalGlobalObject, "data"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, jsUndefined());
        return std::nullopt;
    }

    std::optional<Bindgen::NodeStringEncoding> encoding;
    if (!convertStringInputEncodingAndLease(context, scope, *args.data, args.encoding, encoding))
        return std::nullopt;

    auto data = getStringOrBufferBytes(lexicalGlobalObject, scope, *args.data, nodeEncodingOrDefault(encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, {});

    MarkPopErrorOnReturn popError;

    if (data->size() > INT_MAX) {
        ERR::OUT_OF_RANGE(scope, lexicalGlobalObject, "data is too big"_s, 0, INT_MAX, jsNumber(data->size()));
        return std::nullopt;
    }

    if (!cipher->m_ctx) {
        throwCryptoError(lexicalGlobalObject, scope, popError.peekError(), "Trying to add data in unsupported state");
        return std::nullopt;
    }

    if (cipher->m_ctx.isCcmMode() && !cipher->checkCCMMessageLength(data->size())) {
        return std::nullopt;
    }

    if (cipher->m_kind == CipherKind::Decipher && cipher->isAuthenticatedMode()) {
        ASSERT(cipher->maybePassAuthTagToOpenSSL());
    }

    const int32_t blockSize = cipher->m_ctx.getBlockSize();
    if (data->size() + blockSize > INT_MAX) {
        throwCryptoError(lexicalGlobalObject, scope, popError.peekError(), "Trying to add data in unsupported state");
        return std::nullopt;
    }
    int32_t bufLen = data->size() + blockSize;

    ncrypto::Buffer<const uint8_t> buf {
        .data = data->data(),
        .len = data->size(),
    };

    if (cipher->m_kind == CipherKind::Cipher && cipher->m_ctx.isWrapMode() && !cipher->m_ctx.update(buf, nullptr, &bufLen)) {
        throwCryptoError(lexicalGlobalObject, scope, popError.peekError(), "Trying to add data in unsupported state");
        return std::nullopt;
    }

    WTF::Vector<uint8_t> outBuf;
    if (!outBuf.tryGrow(bufLen)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return std::nullopt;
    }

    buf = {
        .data = data->data(),
        .len = data->size(),
    };

    bool res = cipher->m_ctx.update(buf, outBuf.mutableSpan().data(), &bufLen);
    ASSERT(static_cast<size_t>(bufLen) <= outBuf.size());

    if (!res && cipher->m_kind == CipherKind::Decipher && cipher->m_ctx.isCcmMode()) {
        cipher->m_pendingAuthFailed = true;
        outBuf.shrink(bufLen);
        return outBuf;
    }

    if (res != 1) {
        throwCryptoError(lexicalGlobalObject, scope, popError.peekError(), "Trying to add data in unsupported state");
        return std::nullopt;
    }

    outBuf.shrink(bufLen);
    return outBuf;
}

Bun::Bindgen::CppBytes Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherFinal(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherFinal_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    MarkPopErrorOnReturn popError;

    JSCipher* cipher = cipherObject(args.bindingThis);

    if (!cipher->m_ctx) {
        ERR::CRYPTO_INVALID_STATE(scope, lexicalGlobalObject, "final"_s);
        return {};
    }

    const bool isAuthMode = cipher->isAuthenticatedMode();

    auto throwCryptoErrorWithAuth = [isAuthMode, &popError](JSGlobalObject* globalObject, ThrowScope& scope) {
        throwCryptoError(globalObject, scope, popError.peekError(), isAuthMode ? "Unsupported state or unable to authenticate data" : "Unsupported state");
    };

    int32_t outLen = cipher->m_ctx.getBlockSize();
    WTF::Vector<uint8_t> outBuf;
    if (!outBuf.tryGrow(outLen)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }

    if (cipher->m_kind == CipherKind::Decipher && Cipher::FromCtx(cipher->m_ctx).isSupportedAuthenticatedMode()) {
        cipher->maybePassAuthTagToOpenSSL();
    }

    if (cipher->m_kind == CipherKind::Decipher && cipher->m_ctx.isChaCha20Poly1305() && cipher->m_authTagState != AuthTagState::AuthTagPassedToOpenSSL) {
        throwCryptoErrorWithAuth(lexicalGlobalObject, scope);
        return {};
    }

    bool ok;
    if (cipher->m_kind == CipherKind::Decipher && cipher->m_ctx.isCcmMode()) {
        ok = !cipher->m_pendingAuthFailed;
        outLen = 0;
    } else {
        ok = cipher->m_ctx.update({}, outBuf.mutableSpan().data(), &outLen, true);
        ASSERT(static_cast<size_t>(outLen) <= outBuf.size());

        if (ok && cipher->m_kind == CipherKind::Cipher && cipher->isAuthenticatedMode()) {
            if (!cipher->m_authTagLen.has_value()) {
                ASSERT(cipher->m_ctx.isGcmMode());
                cipher->m_authTagLen = sizeof(cipher->m_authTag);
            }

            ok = cipher->m_ctx.getAeadTag(*cipher->m_authTagLen, reinterpret_cast<unsigned char*>(cipher->m_authTag));
        }
    }

    cipher->m_ctx.reset();

    if (!ok) {
        throwCryptoErrorWithAuth(lexicalGlobalObject, scope);
        return {};
    }

    outBuf.shrink(outLen);
    return outBuf;
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherSetAutoPadding(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherSetAutoPadding_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSCipher* cipher = cipherObject(args.bindingThis);

    MarkPopErrorOnReturn popError;
    if (!cipher->m_ctx.setPadding(args.padding)) {
        ERR::CRYPTO_INVALID_STATE(scope, globalObject, "setAutoPadding"_s);
        return;
    }
}

Bun::Bindgen::CppBytes Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherGetAuthTag(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherGetAuthTag_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSCipher* cipher = cipherObject(args.bindingThis);

    if (cipher->m_ctx || cipher->m_kind != CipherKind::Cipher || !cipher->m_authTagLen) {
        ERR::CRYPTO_INVALID_STATE(scope, lexicalGlobalObject, "getAuthTag"_s);
        return {};
    }

    WTF::Vector<uint8_t> result;
    if (!result.tryGrow(*cipher->m_authTagLen)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }

    memcpy(result.mutableSpan().data(), cipher->m_authTag, *cipher->m_authTagLen);
    return result;
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherSetAuthTag(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherSetAuthTag_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSCipher* cipher = cipherObject(args.bindingThis);

    if (!args.authTag) {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "buffer"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, jsUndefined());
        return;
    }

    std::optional<Bindgen::NodeStringEncoding> encoding;
    if (!convertStringInputEncodingAndLease(context, scope, *args.authTag, args.encoding, encoding))
        return;

    auto authTag = getStringOrBufferBytes(globalObject, scope, *args.authTag, nodeEncodingOrDefault(encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, void());

    if (!cipher->m_ctx || !cipher->isAuthenticatedMode() || cipher->m_kind != CipherKind::Decipher || cipher->m_authTagState != AuthTagState::AuthTagUnknown) {
        ERR::CRYPTO_INVALID_STATE(scope, globalObject, "setAuthTag"_s);
        return;
    }

    if (authTag->size() > INT_MAX) {
        ERR::OUT_OF_RANGE(scope, globalObject, "buffer is too big"_s, 0, INT_MAX, jsNumber(authTag->size()));
        return;
    }

    uint32_t tagLen = authTag->size();

    bool isValid;
    if (cipher->m_ctx.isGcmMode()) {
        isValid = (!cipher->m_authTagLen.has_value() || *cipher->m_authTagLen == tagLen) && Cipher::IsValidGCMTagLength(tagLen);
    } else {
        ASSERT(Cipher::FromCtx(cipher->m_ctx).isSupportedAuthenticatedMode());
        ASSERT(cipher->m_authTagLen.has_value());
        isValid = *cipher->m_authTagLen == tagLen;
    }

    if (!isValid) {
        auto message = WTF::tryMakeString("Invalid authentication tag length: "_s, tagLen);
        if (message.isNull()) {
            throwOutOfMemoryError(globalObject, scope);
            return;
        }
        ERR::CRYPTO_INVALID_AUTH_TAG(scope, globalObject, message);
        return;
    }

    if (cipher->m_ctx.isGcmMode() && !cipher->m_authTagLen.has_value() && tagLen != 16 && !Process::noDeprecation()) {
        Bun::Process::emitWarning(globalObject, "Using AES-GCM authentication tags of less than 128 bits without specifying the authTagLength option when initializing decryption is deprecated."_s, "DeprecationWarning"_s, "DEP0182"_s);
        RETURN_IF_EXCEPTION(scope, void());
    }

    cipher->m_authTagLen = tagLen;
    cipher->m_authTagState = AuthTagState::AuthTagKnown;

    memset(cipher->m_authTag, 0, sizeof(cipher->m_authTag));
    memcpy(cipher->m_authTag, authTag->data(), *cipher->m_authTagLen);
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherSetAAD(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherSetAAD_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSCipher* cipher = cipherObject(args.bindingThis);

    BufferEncodingType encoding = BufferEncodingType::utf8;
    std::optional<uint32_t> plaintextLength = std::nullopt;
    if (args.options && args.options->is_options()) {
        const auto& value = args.options->options();
        if (value.encoding)
            encoding = nodeEncodingToBufferEncoding(*value.encoding);
        plaintextLength = value.plaintext_length;
    }

    const auto* aad = Bindgen::convertLastAndLease(context, args.aad);
    RETURN_IF_EXCEPTION(scope, void());
    if (!aad)
        return;

    auto aadbuf = [&]() -> GCOwnedDataScope<std::span<const uint8_t>> {
        if (aad->is_buffer())
            return { nullptr, { aad->buffer().unsafePtr("The entry frame holds the authentication data lease through the synchronous cipher operation"_s), aad->buffer().size() } };
        auto* view = encodeCryptoString(globalObject, scope, aad->string(), encoding);
        return { view, view ? view->span() : std::span<const uint8_t> {} };
    }();
    RETURN_IF_EXCEPTION(scope, void());

    if (aadbuf->size() > std::numeric_limits<int>::max()) {
        ERR::OUT_OF_RANGE(scope, globalObject, "buffer is too big"_s, 0, INT_MAX, jsNumber(aadbuf->size()));
        return;
    }

    MarkPopErrorOnReturn popError;

    int32_t outlen;

    if (cipher->m_ctx.isCcmMode()) {
        if (!plaintextLength.has_value()) {
            ERR::MISSING_ARGS(scope, globalObject, "options.plaintextLength required for CCM mode with AAD"_s);
            return;
        }

        if (!cipher->checkCCMMessageLength(*plaintextLength)) {
            ERR::CRYPTO_INVALID_MESSAGELEN(scope, globalObject);
            return;
        }

        if (cipher->m_kind == CipherKind::Decipher && !cipher->maybePassAuthTagToOpenSSL()) {
            ERR::CRYPTO_INVALID_STATE(scope, globalObject, "setAAD"_s);
            return;
        }

        ncrypto::Buffer<const unsigned char> buf {
            .data = nullptr,
            .len = static_cast<size_t>(*plaintextLength),
        };

        if (!cipher->m_ctx.update(buf, nullptr, &outlen)) {
            ERR::CRYPTO_INVALID_STATE(scope, globalObject, "setAAD"_s);
            return;
        }
    }

    ncrypto::Buffer<const unsigned char> buf {
        .data = aadbuf->data(),
        .len = aadbuf->size(),
    };

    if (!cipher->m_ctx.update(buf, nullptr, &outlen)) {
        ERR::CRYPTO_INVALID_STATE(scope, globalObject, "setAAD"_s);
        return;
    }
}
