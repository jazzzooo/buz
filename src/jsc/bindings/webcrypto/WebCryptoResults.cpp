#include "config.h"
#include "CryptoKey.h"
#include "CryptoOperationResult.h"
#include "SchemaBindings.h"
#include "SubtleCrypto.h"
#include "WebCryptoOperations.h"
#include <JavaScriptCore/JSONObject.h>

namespace Bun::Bindgen::Engine {

void releaseWebCryptoKey(WebCore::CryptoKey* key)
{
    key->deref();
}

void releaseWebCryptoGeneratedKey(WebCore::GeneratedCryptoKey* key)
{
    delete key;
}

void releaseWebCryptoExportedKey(WebCore::ExportedCryptoKey* key)
{
    delete key;
}

JSC::JSValue bunBindgenEngine_WebCryptoResults_materializeKey(EngineCallContext& context, const BunBindgenEngine_WebCryptoResults_materializeKey_Arguments& args)
{
    auto* global = &context.globalObject;
    return ZigExports::bunBindgenZig_WebCryptoKey_adopt(global, &Ref { *args.key }.leakRef());
}

BunBindgenEngine_WebCryptoResults_materializeGeneratedKey_Return bunBindgenEngine_WebCryptoResults_materializeGeneratedKey(
    EngineCallContext& context, const BunBindgenEngine_WebCryptoResults_materializeGeneratedKey_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    BunBindgenEngine_WebCryptoResults_materializeGeneratedKey_Return result;
    if (auto* key = std::get_if<RefPtr<WebCore::CryptoKey>>(&args.key->value)) {
        RELEASE_ASSERT(*key);
        result.set_key(ZigExports::bunBindgenZig_WebCryptoKey_adopt(global, &Ref { **key }.leakRef()));
    } else {
        auto& pair = std::get<WebCore::CryptoKeyPair>(args.key->value);
        auto publicKey = ZigExports::bunBindgenZig_WebCryptoKey_adopt(global, &Ref { *pair.publicKey }.leakRef());
        RETURN_IF_EXCEPTION(scope, {});
        auto privateKey = ZigExports::bunBindgenZig_WebCryptoKey_adopt(global, &Ref { *pair.privateKey }.leakRef());
        RETURN_IF_EXCEPTION(scope, {});
        result.set_pair({
            .public_key = publicKey,
            .private_key = privateKey,
        });
    }
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

BunBindgenEngine_WebCryptoResults_materializeExportedKey_Return bunBindgenEngine_WebCryptoResults_materializeExportedKey(
    EngineCallContext& context, const BunBindgenEngine_WebCryptoResults_materializeExportedKey_Arguments& args)
{
    BunBindgenEngine_WebCryptoResults_materializeExportedKey_Return result;
    if (auto* bytes = std::get_if<Vector<uint8_t>>(&args.key->value)) {
        result.set_bytes(CppBytes(WTF::move(*bytes)));
        return result;
    }
    auto& native = std::get<WebCore::JsonWebKey>(args.key->value);
    std::remove_cvref_t<decltype(result.jwk())> jwk;
    jwk.kty = native.kty;
    jwk.ext = native.ext;
    if (!native.alg.isNull()) jwk.alg = native.alg;
    if (!native.use.isNull()) jwk.use = native.use;
    if (!native.crv.isNull()) jwk.crv = native.crv;
    if (!native.x.isNull()) jwk.x = native.x;
    if (!native.y.isNull()) jwk.y = native.y;
    if (!native.d.isNull()) jwk.d = native.d;
    if (!native.n.isNull()) jwk.n = native.n;
    if (!native.e.isNull()) jwk.e = native.e;
    if (!native.p.isNull()) jwk.p = native.p;
    if (!native.q.isNull()) jwk.q = native.q;
    if (!native.dp.isNull()) jwk.dp = native.dp;
    if (!native.dq.isNull()) jwk.dq = native.dq;
    if (!native.qi.isNull()) jwk.qi = native.qi;
    if (!native.k.isNull()) jwk.k = native.k;
    if (native.key_ops) {
        auto& usages = jwk.key_ops.emplace();
        if (!usages.tryReserveInitialCapacity(native.key_ops->size())) {
            raiseBindingOutOfMemory(context);
            return {};
        }
        for (auto usage : *native.key_ops)
            usages.unsafeAppendWithoutCapacityCheck(static_cast<SubtleCryptoKeyUsage>(usage));
    }
    if (native.oth) {
        auto& primes = jwk.oth.emplace();
        if (!primes.tryReserveInitialCapacity(native.oth->size())) {
            raiseBindingOutOfMemory(context);
            return {};
        }
        for (auto& prime : *native.oth)
            primes.unsafeAppendWithoutCapacityCheck({ .d = prime.d, .r = prime.r, .t = prime.t });
    }
    result.set_jwk(WTF::move(jwk));
    return result;
}

void releaseWebCryptoUnwrappedKey(WebCore::UnwrappedCryptoKey* key)
{
    delete key;
}

CppBytes bunBindgenEngine_WebCryptoResults_serializeJsonWebKey(EngineCallContext& context, const BunBindgenEngine_WebCryptoResults_serializeJsonWebKey_Arguments& args)
{
    RELEASE_ASSERT(std::holds_alternative<WebCore::JsonWebKey>(args.key->value));
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto jwk = Cpp::BunBind_SubtleCryptoHost_SubtleCrypto_method_exportKey_CompletionCodec::materialize(context, args.key);
    RETURN_IF_EXCEPTION(scope, {});
    auto json = JSC::JSONStringify(&context.globalObject, jwk, 0);
    RETURN_IF_EXCEPTION(scope, {});
    CppBytes result;
    if (!result.tryEncodeUTF8(json))
        raiseBindingOutOfMemory(context);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue bunBindgenEngine_WebCryptoResults_parseJsonWebKey(EngineCallContext& context, const BunBindgenEngine_WebCryptoResults_parseJsonWebKey_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto value = JSC::JSONParse(&context.globalObject, args.json);
    RETURN_IF_EXCEPTION(scope, {});
    if (!value) {
        Bun::Bindgen::CppErrorSink<Bun::Bindgen::Cpp::BunBind_SubtleCryptoHost_SubtleCrypto_method_unwrapKey_CompletionCodec> errors { context };
        errors.fail(decltype(errors)::Errors::data { "WrappedKey cannot be converted to a JSON object"_s });
        RETURN_IF_EXCEPTION(scope, {});
    }
    return value;
}

JSC::JSValue bunBindgenEngine_WebCryptoResults_materializeUnwrappedKey(EngineCallContext& context, const BunBindgenEngine_WebCryptoResults_materializeUnwrappedKey_Arguments& args)
{
    using namespace WebCore;
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    CppErrorSink<Cpp::BunBind_SubtleCryptoHost_SubtleCrypto_method_unwrapKey_CompletionCodec> errors { context };
    auto& key = *args.key;
    KeyData data;
    if (key.format == CryptoKeyFormat::Jwk) {
        auto json = String::fromUTF8(key.bytes.span());
        if (json.isNull()) {
            errors.fail(decltype(errors)::Errors::data { "WrappedKey is not valid UTF-8"_s });
            RETURN_IF_EXCEPTION(scope, {});
            return {};
        }
        auto parsed = bunBindgenEngine_WebCryptoResults_parseJsonWebKey_call(context, { .json = json });
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_ASSERT(parsed);
        if (!copyWebCryptoJsonWebKey(*parsed, data.emplace<JsonWebKey>())) {
            errors.outOfMemory();
            RETURN_IF_EXCEPTION(scope, {});
            return {};
        }
    } else {
        data = WTF::move(key.bytes);
    }
    auto result = SubtleCrypto::importKey(key.format, WTF::move(data), *key.parameters, key.extractable, WTF::move(key.usages));
    if (result.hasException()) {
        auto failure = result.releaseException();
        failWebCrypto(errors, failure.code(), failure.message());
        RETURN_IF_EXCEPTION(scope, {});
        return {};
    }
    RELEASE_AND_RETURN(scope, ZigExports::bunBindgenZig_WebCryptoKey_adopt(&context.globalObject, &result.releaseReturnValue().leakRef()));
}

}
