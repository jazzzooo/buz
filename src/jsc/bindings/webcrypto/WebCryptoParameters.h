#pragma once

#include "SchemaBindings.h"
#include "WebCryptoKey.h"
#include "CryptoAlgorithmParameters.h"
#include "CryptoAlgorithmRsaOaepParams.h"
#include "CryptoAlgorithmAesCbcCfbParams.h"
#include "CryptoAlgorithmAesCtrParams.h"
#include "CryptoAlgorithmAesGcmParams.h"
#include "CryptoAlgorithmEcdsaParams.h"
#include "CryptoAlgorithmRsaPssParams.h"
#include "CryptoAlgorithmRsaHashedKeyGenParams.h"
#include "CryptoAlgorithmAesKeyParams.h"
#include "CryptoAlgorithmHmacKeyParams.h"
#include "CryptoAlgorithmEcKeyParams.h"
#include "CryptoAlgorithmEcdhKeyDeriveParams.h"
#include "CryptoAlgorithmHkdfParams.h"
#include "CryptoAlgorithmPbkdf2Params.h"
#include "CryptoAlgorithmRsaHashedImportParams.h"

namespace WebCore {

template<typename Input> struct NativeCryptoParameters;
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoAlgorithmParameters> {
    using Type = CryptoAlgorithmParameters;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoRsaOaepParams> {
    using Type = CryptoAlgorithmRsaOaepParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoAesCbcParams> {
    using Type = CryptoAlgorithmAesCbcCfbParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoAesCtrParams> {
    using Type = CryptoAlgorithmAesCtrParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoAesGcmParams> {
    using Type = CryptoAlgorithmAesGcmParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoEcdsaParams> {
    using Type = CryptoAlgorithmEcdsaParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoRsaPssParams> {
    using Type = CryptoAlgorithmRsaPssParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoRsaHashedKeyGenParams> {
    using Type = CryptoAlgorithmRsaHashedKeyGenParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoAesKeyParams> {
    using Type = CryptoAlgorithmAesKeyParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoHmacKeyParams> {
    using Type = CryptoAlgorithmHmacKeyParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoEcKeyParams> {
    using Type = CryptoAlgorithmEcKeyParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoKeyDeriveParams> {
    using Type = CryptoAlgorithmEcdhKeyDeriveParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoHkdfParams> {
    using Type = CryptoAlgorithmHkdfParams;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoPbkdf2Params> {
    using Type = CryptoAlgorithmPbkdf2Params;
};
template<> struct NativeCryptoParameters<Bun::Bindgen::WebCryptoRsaHashedImportParams> {
    using Type = CryptoAlgorithmRsaHashedImportParams;
};

template<typename Algorithm>
std::unique_ptr<CryptoAlgorithmParameters> ownWebCryptoParameters(const Algorithm& algorithm)
{
    return algorithm.visit([identifier = algorithm.selector()](const auto& input) -> std::unique_ptr<CryptoAlgorithmParameters> {
        if constexpr (requires { input.selector(); }) {
            return ownWebCryptoParameters(input);
        } else {
            using Parameters = typename NativeCryptoParameters<std::remove_cvref_t<decltype(input)>>::Type;
            void* allocation;
            if (!WTF::tryFastMalloc(sizeof(Parameters)).getValue(allocation)) return nullptr;
            auto result = std::unique_ptr<Parameters> { new (NotNull, allocation) Parameters };
            result->identifier = identifier;
            if constexpr (requires { input.hash; }) result->hashIdentifier = input.hash.selector();
            if constexpr (requires { input.length; }) result->length = input.length;
            if constexpr (requires { input.iterations; }) result->iterations = input.iterations;
            if constexpr (requires { input.tag_length; }) result->tagLength = input.tag_length;
            if constexpr (requires { input.salt_length; }) result->saltLength = input.salt_length;
            if constexpr (requires { input.modulus_length; }) result->modulusLength = input.modulus_length;
            if constexpr (requires { input.named_curve; }) result->namedCurve = input.named_curve.isolatedCopy();
            if constexpr (requires { input.public_key; }) result->publicKey = &webCryptoKey(input.public_key);
            if constexpr (requires { input.iv; }) {
                if (!result->iv.tryAppend(input.iv)) return nullptr;
            }
            if constexpr (requires { input.counter; }) {
                if (!result->counter.tryAppend(input.counter)) return nullptr;
            }
            if constexpr (requires { input.label; }) {
                if (input.label && !result->label.tryAppend(*input.label)) return nullptr;
            }
            if constexpr (requires { input.additional_data; }) {
                if (input.additional_data && !result->additionalData.tryAppend(*input.additional_data)) return nullptr;
            }
            if constexpr (requires { input.salt; }) {
                if (!result->salt.tryAppend(input.salt)) return nullptr;
            }
            if constexpr (requires { input.info; }) {
                if (!result->info.tryAppend(input.info)) return nullptr;
            }
            if constexpr (requires { input.public_exponent; }) {
                if (!result->publicExponent.tryAppend(input.public_exponent)) return nullptr;
            }
            return result;
        }
    });
}

}
