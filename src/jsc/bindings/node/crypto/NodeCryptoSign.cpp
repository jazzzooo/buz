#include "config.h"
#include "CryptoSignature.h"
#include "CryptoSignJob.h"
#include "CryptoUtil.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include <new>

namespace Bun::Bindgen::Engine {

void destroyStreamingSignature(StreamingSignature* signature)
{
    delete signature;
}

BunBindgenEngine_NodeCryptoSign_create_Return bunBindgenEngine_NodeCryptoSign_create(const BunBindgenEngine_NodeCryptoSign_create_Arguments&)
{
    auto* signature = new (std::nothrow) StreamingSignature;
    if (!signature)
        return nativeAllocationFailure();
    return signature;
}

}

namespace Bun::Bindgen::Cpp {

static StreamingSignature& signatureFor(BunBindgen_NodeCryptoSign_Sign_Native* owner)
{
    return *ZigExports::bunBindgenZig_NodeCryptoSign_getSign(owner);
}

static StreamingSignature& signatureFor(BunBindgen_NodeCryptoSign_Verify_Native* owner)
{
    return *ZigExports::bunBindgenZig_NodeCryptoSign_getVerify(owner);
}

static void throwSignatureError(JSC::JSGlobalObject* global, JSC::ThrowScope& scope, const SignatureError& error)
{
    using Code = SignatureError::Code;
    auto type = [&](ASCIILiteral message) { JSC::throwTypeError(global, scope, message); };
    auto crypto = [&](const char* message) { throwCryptoError(global, scope, error.cryptoCode, message); };
    switch (error.code) {
    case Code::notInitialized:
        return type("Sign.prototype.sign cannot be called before Sign.prototype.init"_s);
    case Code::digestCreation:
        return type("Failed to create message digest context"_s);
    case Code::digestInitialization:
        return type("Failed to initialize message digest"_s);
    case Code::digestUpdate:
        return crypto("Failed to update digest");
    case Code::dsaParameters:
        return type("Invalid DSA parameters"_s);
    case Code::digestFinalization:
        return type("Failed to finalize digest"_s);
    case Code::signInitialization:
        return crypto("Failed to initialize signing context");
    case Code::verifyInitialization:
        return crypto("Failed to initialize verification context");
    case Code::signatureDigest:
        return crypto("Failed to set signature message digest");
    case Code::rsaPadding:
        return crypto("Failed to set RSA padding");
    case Code::signatureAllocation:
        return type("Failed to allocate signature buffer"_s);
    case Code::signing:
        return type("Failed to create signature"_s);
    case Code::p1363Allocation:
        return type("Failed to allocate P1363 buffer"_s);
    case Code::p1363Conversion:
        return type("Failed to convert signature format"_s);
    case Code::outOfMemory:
        JSC::throwOutOfMemoryError(global, scope);
        return;
    }
}

static void initializeSignature(CppCallContext& context, const auto& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* digest = ncrypto::getDigestByName(args.digest);
    if (!digest) {
        Bun::ERR::CRYPTO_INVALID_DIGEST(scope, global, args.digest);
        return;
    }
    auto result = signatureFor(args.bindingThis).init(digest);
    if (!result)
        throwSignatureError(global, scope, result.error());
}

static void updateSignature(CppCallContext& context, const auto& args, ASCIILiteral missingInput)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    if (!args.data) {
        JSC::throwVMError(global, scope, missingInput);
        return;
    }
    std::optional<NodeStringEncoding> encoding;
    if (!convertStringInputEncodingAndLease(context, scope, *args.data, args.encoding, encoding))
        return;
    auto input = getStringOrBufferBytes(global, scope, *args.data, nodeEncodingOrDefault(encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, void());
    if (input->size() > INT_MAX) {
        JSC::throwRangeError(global, scope, "data is too long"_s);
        return;
    }
    auto result = signatureFor(args.bindingThis).update({ input->data(), input->size() });
    if (!result)
        throwSignatureError(global, scope, result.error());
}

void bunBindgenCpp_NodeCryptoSign_Sign_method_init(CppCallContext& context, const BunBindgenCpp_NodeCryptoSign_Sign_method_init_Arguments& args)
{
    initializeSignature(context, args);
}

void bunBindgenCpp_NodeCryptoSign_Verify_method_init(CppCallContext& context, const BunBindgenCpp_NodeCryptoSign_Verify_method_init_Arguments& args)
{
    initializeSignature(context, args);
}

void bunBindgenCpp_NodeCryptoSign_Sign_method_update(CppCallContext& context, const BunBindgenCpp_NodeCryptoSign_Sign_method_update_Arguments& args)
{
    updateSignature(context, args, "Sign.prototype.update requires at least 1 argument"_s);
}

void bunBindgenCpp_NodeCryptoSign_Verify_method_update(CppCallContext& context, const BunBindgenCpp_NodeCryptoSign_Verify_method_update_Arguments& args)
{
    updateSignature(context, args, "Verify.prototype.update requires at least 1 argument"_s);
}

NodeCryptoEncodedOutputResult bunBindgenCpp_NodeCryptoSign_Sign_method_sign(CppCallContext& context, const BunBindgenCpp_NodeCryptoSign_Sign_method_sign_Arguments& args)
{
    ncrypto::ClearErrorOnReturn clearError;
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto key = createNodeCryptoSigningKey(*global, args.options, false);
    RETURN_IF_EXCEPTION(scope, {});
    if (!key)
        return {};
    const auto& keyPointer = key->keyData->asymmetricKey;
    auto result = signatureFor(args.bindingThis).sign(keyPointer, key->dsaSigEnc, key->padding.value_or(keyPointer.getDefaultSignPadding()), key->saltLength);
    if (!result) {
        throwSignatureError(global, scope, result.error());
        return {};
    }
    RELEASE_AND_RETURN(scope, StringBytes::encode(global, scope, result->span(), nodeEncodingOrDefault(args.outputEncoding, BufferEncodingType::buffer)));
}

bool bunBindgenCpp_NodeCryptoSign_Verify_method_verify(CppCallContext& context, const BunBindgenCpp_NodeCryptoSign_Verify_method_verify_Arguments& args)
{
    ncrypto::ClearErrorOnReturn clearError;
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto& state = signatureFor(args.bindingThis);
    if (!state.initialized()) {
        JSC::throwTypeError(global, scope, "Verify.prototype.verify cannot be called before Verify.prototype.init"_s);
        return false;
    }
    if (!args.signature) {
        Bun::ERR::INVALID_ARG_TYPE(scope, global, "signature"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, JSC::jsUndefined());
        return false;
    }
    CppDeferredLeaseProof proof;
    std::optional<NodeStringEncoding> encoding;
    if (args.signatureEncoding && args.signature->is_string()) {
        auto* converted = args.signatureEncoding->convertAndMaybeYieldProof(proof);
        RETURN_IF_EXCEPTION(scope, false);
        if (!converted)
            return false;
        encoding = *converted;
    } else
        discardDeferredAndMaybeYieldProof(args.signatureEncoding, proof);
    auto key = createNodeCryptoSigningKey(*global, args.options, true);
    RETURN_IF_EXCEPTION(scope, false);
    if (!key)
        return false;
    KeyObject::discardAsymmetricKeyDeferredAndMaybeYieldProof(args.options, proof);
    if (proof && !context.lease(proof))
        return false;
    auto signature = getStringOrBufferBytes(global, scope, *args.signature, nodeEncodingOrDefault(encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, false);
    const auto& keyPointer = key->keyData->asymmetricKey;
    auto result = state.verify(keyPointer, key->dsaSigEnc, key->padding.value_or(keyPointer.getDefaultSignPadding()), key->saltLength, { signature->data(), signature->size() });
    if (!result) {
        throwSignatureError(global, scope, result.error());
        return false;
    }
    return *result;
}

}
