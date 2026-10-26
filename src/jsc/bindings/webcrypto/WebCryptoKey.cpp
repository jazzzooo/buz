#include "config.h"
#include "WebCryptoKey.h"
#include "CryptoKeySerialization.h"
#include "JSDOMExceptionHandling.h"

namespace Bun::Bindgen::Engine {

WebCryptoKeyType bunBindgenEngine_WebCryptoKey_type(const BunBindgenEngine_WebCryptoKey_type_Arguments& args)
{
    return args.key->type();
}

bool bunBindgenEngine_WebCryptoKey_extractable(const BunBindgenEngine_WebCryptoKey_extractable_Arguments& args)
{
    return args.key->extractable();
}

BunBindgenEngine_WebCryptoKey_algorithm_Return bunBindgenEngine_WebCryptoKey_algorithm(const BunBindgenEngine_WebCryptoKey_algorithm_Arguments& args)
{
    BunBindgenEngine_WebCryptoKey_algorithm_Return::value_type result;
    auto algorithm = args.key->algorithm();
    std::visit([&](auto& value) {
        using T = std::remove_cvref_t<decltype(value)>;
        if constexpr (std::is_same_v<T, WebCore::CryptoRsaHashedKeyAlgorithm>) {
            result.set_rsa_hashed({ .name = value.name, .modulus_length = value.modulusLength,
                .public_exponent = CppBytes(WTF::move(value.publicExponent)), .hash = { .name = value.hash.name } });
        } else if constexpr (std::is_same_v<T, WebCore::CryptoRsaKeyAlgorithm>) {
            result.set_rsa({ .name = value.name, .modulus_length = value.modulusLength,
                .public_exponent = CppBytes(WTF::move(value.publicExponent)) });
        } else if constexpr (std::is_same_v<T, WebCore::CryptoHmacKeyAlgorithm>) {
            result.set_hmac({ .name = value.name, .hash = { .name = value.hash.name }, .length = value.length });
        } else if constexpr (std::is_same_v<T, WebCore::CryptoEcKeyAlgorithm>) {
            result.set_ec({ .name = value.name, .named_curve = value.namedCurve });
        } else if constexpr (std::is_same_v<T, WebCore::CryptoAesKeyAlgorithm>) {
            result.set_aes({ .name = value.name, .length = value.length });
        } else {
            static_assert(std::is_same_v<T, WebCore::CryptoKeyAlgorithm>);
            result.set_plain({ .name = value.name });
        }
    }, algorithm);
    return result;
}

BunBindgenEngine_WebCryptoKey_usages_Return bunBindgenEngine_WebCryptoKey_usages(const BunBindgenEngine_WebCryptoKey_usages_Arguments& args)
{
    WTF::Vector<SubtleCryptoKeyUsage> result;
    if (!result.tryReserveInitialCapacity(8))
        return nativeAllocationFailure();
    for (auto& usage : EnumerationTraits<SubtleCryptoKeyUsage>::entries) {
        if (args.key->usagesBitmap() & (1 << static_cast<unsigned>(usage.value)))
            result.unsafeAppendWithoutCapacityCheck(usage.value);
    }
    return result;
}

CppBytes bunBindgenEngine_WebCryptoKey_serialize(EngineCallContext& context, const BunBindgenEngine_WebCryptoKey_serialize_Arguments& args)
{
    auto result = WebCore::serializeCryptoKey(*args.key);
    if (!result) {
        raiseBindingOutOfMemory(context);
        return {};
    }
    if (!*result) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        WebCore::throwDataCloneError(context.globalObject, scope);
        return {};
    }
    return CppBytes(WTF::move(**result));
}

BunBindgenEngine_WebCryptoKey_deserialize_Return bunBindgenEngine_WebCryptoKey_deserialize(const BunBindgenEngine_WebCryptoKey_deserialize_Arguments& args)
{
    auto result = WebCore::deserializeCryptoKey(args.bytes);
    if (!result)
        return nativeAllocationFailure();
    if (!*result)
        return std::nullopt;
    return std::optional { result->leakRef() };
}

}
