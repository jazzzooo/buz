#include "JSCipherConstructor.h"
#include "JSCipher.h"
#include "ErrorCode.h"
#include "JSBufferEncodingType.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include "CryptoUtil.h"
#include "openssl/dh.h"
#include "openssl/bn.h"
#include "openssl/err.h"
#include "ncrypto.h"

using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

namespace Bun {

const JSC::ClassInfo JSCipherConstructor::s_info = { "Cipher"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSCipherConstructor) };

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherConstructorCall_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    JSC::VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* constructor = globalObject->m_JSCipherClassStructure.constructor(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSC::MarkedArgumentBuffer forwardedArguments;
    if (args.isDecipher) args.isDecipher->appendTo(forwardedArguments);
    if (args.cipher) args.cipher->appendTo(forwardedArguments);
    if (args.key) args.key->appendTo(forwardedArguments);
    if (args.iv) args.iv->appendTo(forwardedArguments);
    if (args.options) args.options->appendTo(forwardedArguments);
    auto callData = JSC::getConstructData(constructor);
    JSC::JSValue result = JSC::construct(globalObject, constructor, callData, ArgList(forwardedArguments));
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

void initAuthenticated(JSGlobalObject* globalObject, ThrowScope& scope, CipherCtxPointer& ctx, const WTF::StringView& cipherString, CipherKind kind, int32_t ivLen, std::optional<uint32_t>& authTagLen, int32_t& maxMessageSize)
{
    MarkPopErrorOnReturn popError;

    if (!ctx.setIvLength(ivLen)) {
        ERR::CRYPTO_INVALID_IV(scope, globalObject);
        return;
    }

    if (ctx.isGcmMode()) {
        if (authTagLen.has_value()) {
            if (!Cipher::IsValidGCMTagLength(*authTagLen)) {
                WTF::StringBuilder builder;
                builder.append("Invalid authentication tag length: "_s);
                builder.append(*authTagLen);
                ERR::CRYPTO_INVALID_AUTH_TAG(scope, globalObject, builder.toString());
                return;
            }
        }
    } else {
        if (!authTagLen.has_value()) {
            if (ctx.isChaCha20Poly1305()) {
                authTagLen = 16;
            } else {
                WTF::StringBuilder builder;
                builder.append("authTagLength required for: "_s);
                builder.append(cipherString);
                ERR::CRYPTO_INVALID_AUTH_TAG(scope, globalObject, builder.toString());
                return;
            }
        }

        if (ctx.isCcmMode() && kind == CipherKind::Decipher && ncrypto::isFipsEnabled()) {
            ERR::CRYPTO_UNSUPPORTED_OPERATION(scope, globalObject, "CCM encryption not supported in FIPS mode"_s);
            return;
        }

        if (!ctx.setAeadTagLength(*authTagLen)) {
            WTF::StringBuilder builder;
            builder.append("Invalid authentication tag length: "_s);
            builder.append(*authTagLen);
            ERR::CRYPTO_INVALID_AUTH_TAG(scope, globalObject, builder.toString());
            return;
        }

        if (ctx.isCcmMode()) {
            if (ivLen == 12)
                maxMessageSize = 16777215;
            else if (ivLen == 13)
                maxMessageSize = 65535;
            else
                maxMessageSize = INT_MAX;
        }
    }
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherConstructorConstruct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    CipherKind cipherKind = args.isDecipher ? CipherKind::Decipher : CipherKind::Cipher;
    BufferEncodingType encoding = BufferEncodingType::utf8;
    std::optional<uint32_t> authTagLength = std::nullopt;
    if (args.options && args.options->is_options()) {
        const auto& value = args.options->options();
        if (value.encoding)
            encoding = nodeEncodingToBufferEncoding(*value.encoding);
        authTagLength = value.auth_tag_length;
    }

    const auto* key = args.key.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!key)
        return {};
    WTF::Vector<uint8_t> exportedKey;
    if (key->is_key_object()) {
        exportedKey = exportSecretKeyBytes(globalObject, scope, key->key_object());
        RETURN_IF_EXCEPTION(scope, {});
    }
    const auto* iv = Bindgen::convertLastAndLease(context, args.iv);
    RETURN_IF_EXCEPTION(scope, {});
    if (!iv)
        return {};

    auto keyData = getSecretKeyMaterial(globalObject, scope, *key, encoding, exportedKey.span());
    RETURN_IF_EXCEPTION(scope, {});
    std::span<const uint8_t> keyBytes { keyData->data(), keyData->size() };

    const bool hasIv = iv->has_value();
    auto ivData = [&]() -> GCOwnedDataScope<std::span<const uint8_t>> {
        if (!hasIv)
            return { nullptr, {} };
        const auto& value = iv->value();
        if (value.is_buffer())
            return { nullptr, { value.buffer().unsafePtr("The entry frame holds the input lease through the synchronous crypto operation"_s), value.buffer().size() } };
        auto* view = encodeCryptoString(globalObject, scope, value.string(), BufferEncodingType::utf8);
        return { view, view ? view->span() : std::span<const uint8_t> {} };
    }();
    RETURN_IF_EXCEPTION(scope, {});
    std::span<const uint8_t> ivBytes { ivData->data(), ivData->size() };

    const WTF::String& cipherString = args.cipher;

    if (keyBytes.size() > INT_MAX) [[unlikely]] {
        return JSC::JSValue::decode(ERR::OUT_OF_RANGE(scope, globalObject, "key is too big"_s, 0, INT_MAX, jsNumber(keyBytes.size())));
    }

    if (ivBytes.size() > INT_MAX) [[unlikely]] {
        return JSC::JSValue::decode(ERR::OUT_OF_RANGE(scope, globalObject, "iv is too big"_s, 0, INT_MAX, jsNumber(ivBytes.size())));
    }
    const int32_t ivLen = static_cast<int32_t>(ivBytes.size());

    MarkPopErrorOnReturn popError;

    Cipher cipher = Cipher::FromName(cipherString);
    if (!cipher) {
        return JSC::JSValue::decode(ERR::CRYPTO_UNKNOWN_CIPHER(scope, globalObject, cipherString));
    }

    const int32_t expectedIvLen = cipher.getIvLength();

    if (!hasIv && expectedIvLen != 0) {
        return JSC::JSValue::decode(ERR::CRYPTO_INVALID_IV(scope, globalObject));
    }

    if (!cipher.isSupportedAuthenticatedMode() && hasIv && ivLen != expectedIvLen) {
        return JSC::JSValue::decode(ERR::CRYPTO_INVALID_IV(scope, globalObject));
    }

    if (cipher.isChaCha20Poly1305()) {
        ASSERT(hasIv);

        if (ivLen > 12) {
            return JSC::JSValue::decode(ERR::CRYPTO_INVALID_IV(scope, globalObject));
        }
    }

    CipherCtxPointer ctx = CipherCtxPointer::New();

    if (cipher.isWrapMode()) {
        ctx.setAllowWrap();
    }

    const bool encrypt = cipherKind == CipherKind::Cipher;
    if (!ctx.init(cipher, encrypt)) {
        throwCryptoError(globalObject, scope, ERR_get_error(), "Failed to initialize cipher"_s);
        return {};
    }

    int32_t maxMessageSize = 0;
    if (cipher.isSupportedAuthenticatedMode()) {
        initAuthenticated(globalObject, scope, ctx, cipherString, cipherKind, ivLen, authTagLength, maxMessageSize);
        RETURN_IF_EXCEPTION(scope, {});
    }

    if (!ctx.setKeyLength(keyBytes.size())) {
        ctx.reset();
        return JSC::JSValue::decode(ERR::CRYPTO_INVALID_KEYLEN(scope, globalObject));
    }

    if (!ctx.init(Cipher(), encrypt, keyBytes.data(), hasIv ? ivBytes.data() : nullptr)) {
        throwCryptoError(globalObject, scope, ERR_get_error(), "Failed to initialize cipher"_s);
    }

    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    JSC::Structure* structure = zigGlobalObject->m_JSCipherClassStructure.get(zigGlobalObject);

    return JSCipher::create(vm, structure, globalObject, cipherKind, WTF::move(ctx), authTagLength, maxMessageSize);
}

} // namespace Bun
