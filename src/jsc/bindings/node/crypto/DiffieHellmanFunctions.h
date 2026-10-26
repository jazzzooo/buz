#pragma once

#include "root.h"
#include "ErrorCode.h"
#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include "JSBufferEncodingType.h"
#include "ncrypto.h"
#include "CryptoUtil.h"
#include "JSBuffer.h"

namespace Bun {

// Template implementations for Diffie-Hellman functions that are shared between
// JSDiffieHellman and JSDiffieHellmanGroup

template<typename DiffieHellmanType, typename Encoding>
Bindgen::NodeCryptoEncodedOutputResult jsDiffieHellmanProtoFuncGenerateKeysTemplate(JSC::JSGlobalObject* globalObject, DiffieHellmanType* thisObject, const std::optional<Encoding>& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& dh = thisObject->getImpl();
    auto keys = dh.generateKeys();
    if (!keys) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Key generation failed"_s);
        return {};
    }

    auto encodingType = nodeEncodingOrDefault(encoding, BufferEncodingType::buffer);

    RELEASE_AND_RETURN(scope, StringBytes::encode(globalObject, scope, keys.span(), encodingType));
}

template<typename DiffieHellmanType, typename Key, typename InputEncoding, typename OutputEncoding>
Bindgen::NodeCryptoEncodedOutputResult jsDiffieHellmanProtoFuncComputeSecretTemplate(
    Bindgen::CppCallContext& context,
    JSC::JSGlobalObject* globalObject,
    DiffieHellmanType* thisObject,
    const std::optional<Key>& keyArg,
    const std::optional<InputEncoding>& inputEncoding,
    const std::optional<OutputEncoding>& outputEncoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!keyArg) {
        Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, JSC::jsUndefined());
        return {};
    }

    BufferEncodingType resolvedInputEncoding = BufferEncodingType::utf8;
    if (inputEncoding) {
        const auto* converted = Bindgen::convertLastAndLease(context, *inputEncoding);
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        if (*converted)
            resolvedInputEncoding = nodeEncodingToBufferEncoding(**converted);
    }

    auto keyBuffer = Bun::getStringOrBufferBytes(globalObject, scope, *keyArg, resolvedInputEncoding);
    RETURN_IF_EXCEPTION(scope, {});

    auto span = keyBuffer.data;

    // Check for unusually large buffer sizes
    if (span.size() > INT32_MAX) {
        throwError(globalObject, scope, ErrorCode::ERR_OUT_OF_RANGE, "Public key is too big"_s);
        return {};
    }

    // Check for empty buffer
    if (span.size() == 0) {
        throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "Public key cannot be empty"_s);
        return {};
    }

    ncrypto::BignumPointer publicKey(span.data(), span.size());
    if (!publicKey) {
        throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid public key"_s);
        return {};
    }

    auto& dh = thisObject->getImpl();

    // Check the public key against our DH parameters
    auto checkResult = dh.checkPublicKey(publicKey);
    if (checkResult != ncrypto::DHPointer::CheckPublicKeyResult::NONE) {
        switch (checkResult) {
        // case ncrypto::DHPointer::CheckPublicKeyResult::TOO_SMALL:
        //     throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_KEYLEN, "Supplied key is too small"_s);
        //     return {};
        // case ncrypto::DHPointer::CheckPublicKeyResult::TOO_LARGE:
        //     throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_KEYLEN, "Supplied key is too large"_s);
        //     return {};
        case ncrypto::DHPointer::CheckPublicKeyResult::INVALID:
            throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_KEYTYPE, "Invalid public key for this key exchange"_s);
            return {};
        case ncrypto::DHPointer::CheckPublicKeyResult::CHECK_FAILED:
        default:
            throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "DH check public key failed"_s);
            return {};
        }
    }

    // Compute the shared secret
    auto secret = dh.computeSecret(publicKey);
    if (!secret) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Failed to compute shared secret"_s);
        return {};
    }

    BufferEncodingType outputEncodingType = nodeEncodingOrDefault(outputEncoding, BufferEncodingType::buffer);

    // If output encoding is specified and not "buffer", return a string
    RELEASE_AND_RETURN(scope, StringBytes::encode(globalObject, scope, secret.span(), outputEncodingType));
}

template<typename DiffieHellmanType, typename Encoding>
Bindgen::NodeCryptoEncodedOutputResult jsDiffieHellmanProtoFuncGetPrimeTemplate(JSC::JSGlobalObject* globalObject, DiffieHellmanType* thisObject, const std::optional<Encoding>& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& dh = thisObject->getImpl();
    auto prime = dh.getPrime();
    if (!prime) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_STATE, "p is null"_s);
        return {};
    }

    // Handle optional encoding parameter
    BufferEncodingType encodingType = nodeEncodingOrDefault(encoding, BufferEncodingType::buffer);

    RELEASE_AND_RETURN(scope, StringBytes::encode(globalObject, scope, prime.span(), encodingType));
}

template<typename DiffieHellmanType, typename Encoding>
Bindgen::NodeCryptoEncodedOutputResult jsDiffieHellmanProtoFuncGetGeneratorTemplate(JSC::JSGlobalObject* globalObject, DiffieHellmanType* thisObject, const std::optional<Encoding>& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& dh = thisObject->getImpl();
    auto gen = dh.getGenerator();
    if (!gen) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_STATE, "g is null"_s);
        return {};
    }

    // Handle optional encoding parameter
    BufferEncodingType encodingType = nodeEncodingOrDefault(encoding, BufferEncodingType::buffer);

    RELEASE_AND_RETURN(scope, StringBytes::encode(globalObject, scope, gen.span(), encodingType));
}

template<typename DiffieHellmanType, typename Encoding>
Bindgen::NodeCryptoEncodedOutputResult jsDiffieHellmanProtoFuncGetPublicKeyTemplate(JSC::JSGlobalObject* globalObject, DiffieHellmanType* thisObject, const std::optional<Encoding>& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& dh = thisObject->getImpl();
    auto key = dh.getPublicKey();
    if (!key) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_STATE, "No public key - did you forget to generate one?"_s);
        return {};
    }

    // Handle optional encoding parameter
    BufferEncodingType encodingType = nodeEncodingOrDefault(encoding, BufferEncodingType::buffer);

    RELEASE_AND_RETURN(scope, StringBytes::encode(globalObject, scope, key.span(), encodingType));
}

template<typename DiffieHellmanType, typename Encoding>
Bindgen::NodeCryptoEncodedOutputResult jsDiffieHellmanProtoFuncGetPrivateKeyTemplate(JSC::JSGlobalObject* globalObject, DiffieHellmanType* thisObject, const std::optional<Encoding>& encodingValue)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& dh = thisObject->getImpl();
    auto key = dh.getPrivateKey();
    if (!key) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_INVALID_STATE, "No private key - did you forget to generate one?"_s);
        return {};
    }

    auto encoding = nodeEncodingOrDefault(encodingValue, BufferEncodingType::buffer);

    RELEASE_AND_RETURN(scope, StringBytes::encode(globalObject, scope, key.span(), encoding));
}

template<typename DiffieHellmanType, typename Key, typename Encoding>
JSC::EncodedJSValue jsDiffieHellmanProtoFuncSetPublicKeyTemplate(
    Bindgen::CppCallContext& context,
    JSC::JSGlobalObject* globalObject,
    DiffieHellmanType* thisObject,
    const std::optional<Key>& keyArg,
    const std::optional<Encoding>& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!keyArg)
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, JSC::jsUndefined());

    BufferEncodingType resolvedEncoding = BufferEncodingType::utf8;
    if (encoding) {
        const auto* converted = Bindgen::convertLastAndLease(context, *encoding);
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        if (*converted)
            resolvedEncoding = nodeEncodingToBufferEncoding(**converted);
    }

    auto keyBuffer = Bun::getStringOrBufferBytes(globalObject, scope, *keyArg, resolvedEncoding);
    RETURN_IF_EXCEPTION(scope, {});

    auto span = keyBuffer.data;

    ncrypto::BignumPointer key(span.data(), span.size());
    if (!key) {
        throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid public key"_s);
        return {};
    }

    auto& dh = thisObject->getImpl();

    if (!dh.setPublicKey(WTF::move(key))) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Failed to set public key"_s);
        return {};
    }

    return JSC::JSValue::encode(thisObject);
}

template<typename DiffieHellmanType, typename Key, typename Encoding>
JSC::EncodedJSValue jsDiffieHellmanProtoFuncSetPrivateKeyTemplate(
    Bindgen::CppCallContext& context,
    JSC::JSGlobalObject* globalObject,
    DiffieHellmanType* thisObject,
    const std::optional<Key>& keyArg,
    const std::optional<Encoding>& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!keyArg)
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, JSC::jsUndefined());

    BufferEncodingType resolvedEncoding = BufferEncodingType::utf8;
    if (encoding) {
        const auto* converted = Bindgen::convertLastAndLease(context, *encoding);
        RETURN_IF_EXCEPTION(scope, {});
        if (!converted)
            return {};
        if (*converted)
            resolvedEncoding = nodeEncodingToBufferEncoding(**converted);
    }

    auto keyBuffer = Bun::getStringOrBufferBytes(globalObject, scope, *keyArg, resolvedEncoding);
    RETURN_IF_EXCEPTION(scope, {});

    auto span = keyBuffer.data;
    ncrypto::BignumPointer key(span.data(), span.size());
    if (!key) {
        throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid private key"_s);
        return {};
    }

    auto& dh = thisObject->getImpl();

    if (!dh.setPrivateKey(WTF::move(key))) {
        throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Failed to set private key"_s);
        return {};
    }

    return JSC::JSValue::encode(thisObject);
}

} // namespace Bun
