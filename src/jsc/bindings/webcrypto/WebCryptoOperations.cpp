#include "config.h"
#include "WebCryptoOperations.h"
#include "WebCryptoParameters.h"
#include "SubtleCrypto.h"
#include "CryptoDigest.h"

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_digest(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_digest_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_digest_CompletionCodec>& completion)
{
    PAL::CryptoDigest::Algorithm digestAlgorithm;
    switch (args.algorithm.selector()) {
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA_1:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA_1;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA_224:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA_224;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA_256:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA_256;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA_384:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA_384;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA_512:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA_512;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA3_256:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA3_256;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA3_384:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA3_384;
        break;
    case Bun::Bindgen::WebCryptoAlgorithmIdentifier::SHA3_512:
        digestAlgorithm = PAL::CryptoDigest::Algorithm::SHA3_512;
        break;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
    auto digest = PAL::CryptoDigest::create(digestAlgorithm);
    CppBytes output;
    std::span<uint8_t> outputBytes;
    if (!digest || !output.tryAllocate(digest->digestLength(), outputBytes)) {
        completion.outOfMemory();
        return;
    }
    auto compute = [digest = WTF::move(digest), output = WTF::move(output), outputBytes](std::span<const uint8_t> data) mutable -> WebCore::ExceptionOr<CppBytes> {
        if (!digest->addBytes(data.data(), data.size()) || !digest->computeHash(outputBytes))
            return WebCore::Exception { WebCore::OperationError };
        return WTF::move(output);
    };
    constexpr size_t inlineLimit = 64 * 1024;
    if (args.data.size() <= inlineLimit) {
        WebCore::completeWebCrypto(completion, compute(args.data));
        return;
    }
    WTF::Vector<uint8_t> data;
    if (!data.tryAppend(args.data)) {
        completion.outOfMemory();
        return;
    }
    WebCore::dispatchWebCrypto(context, completion, [compute = WTF::move(compute), data = WTF::move(data)]() mutable {
        return compute(data.span());
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_encrypt(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_encrypt_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_encrypt_CompletionCodec>& completion)
{
    using namespace WebCore;
    auto params = ownWebCryptoParameters(args.algorithm);
    Vector<uint8_t> data;
    if (!params || !data.tryAppend(args.data)) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [params = WTF::move(params), key = Ref { webCryptoKey(args.key) }, data = WTF::move(data)]() mutable {
        return SubtleCrypto::encrypt(*params, WTF::move(key), WTF::move(data));
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_decrypt(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_decrypt_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_decrypt_CompletionCodec>& completion)
{
    using namespace WebCore;
    auto params = ownWebCryptoParameters(args.algorithm);
    Vector<uint8_t> data;
    if (!params || !data.tryAppend(args.data)) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [params = WTF::move(params), key = Ref { webCryptoKey(args.key) }, data = WTF::move(data)]() mutable {
        return SubtleCrypto::decrypt(*params, WTF::move(key), WTF::move(data));
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_sign(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_sign_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_sign_CompletionCodec>& completion)
{
    using namespace WebCore;
    auto params = ownWebCryptoParameters(args.algorithm);
    Vector<uint8_t> data;
    if (!params || !data.tryAppend(args.data)) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [params = WTF::move(params), key = Ref { webCryptoKey(args.key) }, data = WTF::move(data)]() mutable {
        return SubtleCrypto::sign(*params, WTF::move(key), WTF::move(data));
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_verify(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_verify_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_verify_CompletionCodec>& completion)
{
    using namespace WebCore;
    auto params = ownWebCryptoParameters(args.algorithm);
    Vector<uint8_t> data;
    Vector<uint8_t> signature;
    if (!params || !data.tryAppend(args.data) || !signature.tryAppend(args.signature)) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [params = WTF::move(params), key = Ref { webCryptoKey(args.key) }, data = WTF::move(data), signature = WTF::move(signature)]() mutable {
        return SubtleCrypto::verify(*params, WTF::move(key), WTF::move(signature), WTF::move(data));
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_deriveBits(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_deriveBits_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_deriveBits_CompletionCodec>& completion)
{
    using namespace WebCore;
    auto params = ownWebCryptoParameters(args.algorithm);
    if (!params) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [params = WTF::move(params), key = Ref { webCryptoKey(args.baseKey) }, length = args.length]() mutable {
        return SubtleCrypto::deriveBits(*params, WTF::move(key), length);
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_generateKey(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_generateKey_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_generateKey_CompletionCodec>& completion)
{
    using namespace WebCore;
    using Completion = std::remove_reference_t<decltype(completion)>;
    auto params = ownWebCryptoParameters(args.algorithm);
    Vector<CryptoKeyUsage> usages;
    if (!params || !usages.tryAppend(args.keyUsages.span())) {
        completion.outOfMemory();
        return;
    }
    auto identifier = params->identifier;
    bool background = identifier == CryptoAlgorithmIdentifier::RSA_OAEP || identifier == CryptoAlgorithmIdentifier::RSA_PSS || identifier == CryptoAlgorithmIdentifier::RSASSA_PKCS1_v1_5;
    dispatchWebCrypto(context, completion, [params = WTF::move(params), extractable = args.extractable, usages = WTF::move(usages)]() mutable -> ExceptionOr<Completion::Value> {
        auto result = SubtleCrypto::generateKey(*params, extractable, WTF::move(usages));
        if (result.hasException()) return result.releaseException();
        auto* value = tryCreateCryptoResult<GeneratedCryptoKey>(result.releaseReturnValue());
        if (!value) return WebCore::Exception { OutOfMemoryError };
        return Completion::Value { value }; }, background);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_deriveKey(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_deriveKey_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_deriveKey_CompletionCodec>& completion)
{
    using namespace WebCore;
    using Completion = std::remove_reference_t<decltype(completion)>;
    auto params = ownWebCryptoParameters(args.algorithm);
    auto importParams = ownWebCryptoParameters(args.derivedKeyType);
    auto lengthParams = ownWebCryptoParameters(args.keyLength);
    Vector<CryptoKeyUsage> usages;
    if (!params || !importParams || !lengthParams || !usages.tryAppend(args.keyUsages.span())) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [params = WTF::move(params), importParams = WTF::move(importParams), lengthParams = WTF::move(lengthParams), key = Ref { webCryptoKey(args.baseKey) }, extractable = args.extractable, usages = WTF::move(usages)]() mutable -> ExceptionOr<Completion::Value> {
        auto result = SubtleCrypto::deriveKey(*params, WTF::move(key), *importParams, *lengthParams, extractable, WTF::move(usages));
        if (result.hasException()) return result.releaseException();
        auto value = result.releaseReturnValue();
        return Completion::Value { &value.leakRef() };
    });
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_importKey(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_importKey_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_importKey_CompletionCodec>& completion)
{
    using namespace WebCore;
    using Completion = std::remove_reference_t<decltype(completion)>;
    KeyData keyData;
    if (args.format == CryptoKeyFormat::Jwk) {
        if (!copyWebCryptoJsonWebKey(args.keyData.jwk(), keyData.emplace<JsonWebKey>())) {
            completion.outOfMemory();
            return;
        }
    } else {
        if (!std::get<Vector<uint8_t>>(keyData).tryAppend(args.keyData.bytes())) {
            completion.outOfMemory();
            return;
        }
    }
    auto params = ownWebCryptoParameters(args.algorithm);
    Vector<CryptoKeyUsage> usages;
    if (!params || !usages.tryAppend(args.keyUsages.span())) {
        completion.outOfMemory();
        return;
    }
    dispatchWebCrypto(context, completion, [format = args.format, params = WTF::move(params), keyData = WTF::move(keyData), extractable = args.extractable, usages = WTF::move(usages)]() mutable -> ExceptionOr<Completion::Value> {
        auto result = SubtleCrypto::importKey(format, WTF::move(keyData), *params, extractable, WTF::move(usages));
        if (result.hasException()) return result.releaseException();
        auto value = result.releaseReturnValue();
        return Completion::Value { &value.leakRef() }; }, false);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_exportKey(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_exportKey_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_exportKey_CompletionCodec>& completion)
{
    using namespace WebCore;
    using Completion = std::remove_reference_t<decltype(completion)>;
    dispatchWebCrypto(context, completion, [format = args.format, key = Ref { webCryptoKey(args.key) }]() mutable -> ExceptionOr<Completion::Value> {
        auto result = SubtleCrypto::exportKey(format, WTF::move(key));
        if (result.hasException()) return result.releaseException();
        auto* value = tryCreateCryptoResult<ExportedCryptoKey>(result.releaseReturnValue());
        if (!value) return WebCore::Exception { OutOfMemoryError };
        return Completion::Value { value }; }, false);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_wrapKey(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_wrapKey_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_wrapKey_CompletionCodec>& completion)
{
    using namespace WebCore;
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto params = ownWebCryptoParameters(args.wrapAlgorithm);
    if (!params) {
        completion.outOfMemory();
        return;
    }
    Ref wrappingKey { webCryptoKey(args.wrappingKey) };
    auto validation = SubtleCrypto::validateWrappingKey(*params, wrappingKey, false);
    if (validation.hasException()) {
        auto failure = validation.releaseException();
        failWebCrypto(completion, failure.code(), failure.message());
        return;
    }
    auto exported = SubtleCrypto::exportKey(args.format, Ref { webCryptoKey(args.key) });
    if (exported.hasException()) {
        auto failure = exported.releaseException();
        failWebCrypto(completion, failure.code(), failure.message());
        return;
    }
    ExportedCryptoKey value { exported.releaseReturnValue() };
    Vector<uint8_t> bytes;
    if (auto* data = std::get_if<Vector<uint8_t>>(&value.value)) {
        bytes = WTF::move(*data);
    } else {
        Bun::Bindgen::EngineCallContext engineContext { *global, nullptr };
        auto json = Engine::bunBindgenEngine_WebCryptoResults_serializeJsonWebKey(engineContext, { .key = &value });
        RETURN_IF_EXCEPTION(scope, void());
        if (!bytes.tryAppend(json.span())) {
            completion.outOfMemory();
            return;
        }
    }
    scope.release();
    bool background = params->identifier != CryptoAlgorithmIdentifier::AES_KW;
    dispatchWebCrypto(context, completion, [params = WTF::move(params), wrappingKey = WTF::move(wrappingKey), bytes = WTF::move(bytes)]() mutable { return SubtleCrypto::wrapKey(*params, WTF::move(wrappingKey), WTF::move(bytes)); }, background);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_unwrapKey(
    Bun::Bindgen::CppCallContext& context,
    const BunBindgenCpp_SubtleCryptoHost_SubtleCrypto_method_unwrapKey_Arguments& args,
    Bun::Bindgen::CppCompletion<BunBind_SubtleCryptoHost_SubtleCrypto_method_unwrapKey_CompletionCodec>& completion)
{
    using namespace WebCore;
    using Completion = std::remove_reference_t<decltype(completion)>;
    auto params = ownWebCryptoParameters(args.unwrapAlgorithm);
    auto importParams = ownWebCryptoParameters(args.unwrappedKeyAlgorithm);
    Vector<uint8_t> bytes;
    Vector<CryptoKeyUsage> usages;
    if (!params || !importParams || !bytes.tryAppend(args.wrappedKey) || !usages.tryAppend(args.keyUsages.span())) {
        completion.outOfMemory();
        return;
    }
    UnwrappedCryptoKey imported { args.format, {}, WTF::move(importParams), args.extractable, WTF::move(usages) };
    bool background = params->identifier != CryptoAlgorithmIdentifier::AES_KW;
    dispatchWebCrypto(context, completion, [params = WTF::move(params), key = Ref { webCryptoKey(args.unwrappingKey) }, bytes = WTF::move(bytes), imported = WTF::move(imported)]() mutable -> ExceptionOr<Completion::Value> {
            auto result = SubtleCrypto::unwrapKey(*params, WTF::move(key), WTF::move(bytes));
            if (result.hasException()) return result.releaseException();
            imported.bytes = result.releaseReturnValue();
            auto* value = tryCreateCryptoResult<UnwrappedCryptoKey>(WTF::move(imported));
            if (!value) return WebCore::Exception { OutOfMemoryError };
            return Completion::Value { value }; }, background);
}
