#pragma once

#include "root.h"
#include "ncrypto.h"
#include "ExceptionOr.h"
#include "CryptoKeyType.h"
#include "KeyObjectData.h"

namespace WebCore {
class CryptoKey;
}

namespace Bun::Bindgen {
class NodeCryptoAsymmetricKeyInput;
enum class NodeCryptoAsymmetricKeyKind : uint8_t;
class NodeCryptoPublicKeyExportResult;
class NodeCryptoPrivateKeyExportResult;
class CppDeferredLeaseProof;
}

namespace Bun {

struct AsymmetricKeyDetails {
    std::optional<double> modulus_length;
    std::optional<WTF::String> public_exponent_hex;
    std::optional<WTF::String> hash_algorithm;
    std::optional<WTF::String> mgf1_hash_algorithm;
    std::optional<double> salt_length;
    std::optional<double> divisor_length;
    std::optional<WTF::String> named_curve;
};

class KeyObject {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(KeyObject);

    KeyObject(WebCore::CryptoKeyType type, RefPtr<KeyObjectData>&& data)
        : m_data(WTF::move(data))
        , m_type(type)
    {
    }

public:
    KeyObject() = default;
    ~KeyObject() = default;

    static WebCore::ExceptionOr<KeyObject> create(WebCore::CryptoKey&);
    static WebCore::ExceptionOr<KeyObject> create(WTF::Vector<uint8_t>&& symmetricKey);
    static WebCore::ExceptionOr<KeyObject> create(WebCore::CryptoKeyType type, ncrypto::EVPKeyPointer&& asymmetricKey);
    static KeyObject create(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<uint8_t>&& symmetricKey);
    static KeyObject create(JSC::JSGlobalObject*, JSC::ThrowScope&, WebCore::CryptoKeyType type, ncrypto::EVPKeyPointer&& asymmetricKey);
    static KeyObject create(WebCore::CryptoKeyType type, RefPtr<KeyObjectData>&& data);

    enum class KeyEncodingContext {
        Input,
        Export,
        Generate,
    };

    enum class PrepareAsymmetricKeyMode {
        ConsumePublic,
        ConsumePrivate,
        CreatePublic,
        CreatePrivate,
    };

    static ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig getPrivateKeyEncoding(
        JSC::JSGlobalObject*,
        JSC::ThrowScope&,
        ncrypto::EVPKeyPointer::PKFormatType formatType,
        std::optional<ncrypto::EVPKeyPointer::PKEncodingType> encodingType,
        const EVP_CIPHER* cipher,
        std::optional<ncrypto::DataPointer> passphrase,
        KeyEncodingContext ctx);

    static void getKeyFormatAndType(
        ncrypto::EVPKeyPointer::PKFormatType formatType,
        std::optional<ncrypto::EVPKeyPointer::PKEncodingType> encodingType,
        KeyEncodingContext ctx,
        ncrypto::EVPKeyPointer::AsymmetricKeyEncodingConfig& config);

    static KeyObject getPublicOrPrivateKey(
        JSC::JSGlobalObject* globalObject,
        JSC::ThrowScope& scope,
        std::span<const uint8_t> keyData,
        WebCore::CryptoKeyType keyType,
        ncrypto::EVPKeyPointer::PKFormatType formatType,
        std::optional<ncrypto::EVPKeyPointer::PKEncodingType> encodingType,
        const EVP_CIPHER* cipher,
        std::optional<ncrypto::DataPointer> passphrase);

    static RefPtr<KeyObjectData> prepareAsymmetricKey(JSC::JSGlobalObject*, JSC::ThrowScope&, const Bindgen::NodeCryptoAsymmetricKeyInput&, PrepareAsymmetricKeyMode mode);
    static void discardAsymmetricKeyDeferred(const Bindgen::NodeCryptoAsymmetricKeyInput&);
    static void discardAsymmetricKeyDeferredAndMaybeYieldProof(const Bindgen::NodeCryptoAsymmetricKeyInput&, Bindgen::CppDeferredLeaseProof&);

    Bindgen::NodeCryptoPublicKeyExportResult exportPublicResult(JSC::JSGlobalObject*, JSC::ThrowScope&, const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig&);
    Bindgen::NodeCryptoPrivateKeyExportResult exportPrivateResult(JSC::JSGlobalObject*, JSC::ThrowScope&, const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig&);
    JSC::JSValue exportPublic(JSC::JSGlobalObject*, JSC::ThrowScope&, const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig&);
    JSC::JSValue exportPrivate(JSC::JSGlobalObject*, JSC::ThrowScope&, const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig&);

    void getRsaKeyDetails(JSC::JSGlobalObject*, JSC::ThrowScope&, AsymmetricKeyDetails& result);
    void getDsaKeyDetails(AsymmetricKeyDetails& result);
    void getEcKeyDetails(AsymmetricKeyDetails& result);

    std::optional<Bindgen::NodeCryptoAsymmetricKeyKind> asymmetricKeyType() const;
    AsymmetricKeyDetails asymmetricKeyDetails(JSC::JSGlobalObject*, JSC::ThrowScope&);

    std::optional<bool> equals(const KeyObject& other) const;
    JSC::JSValue toCryptoKey(JSC::JSGlobalObject*, JSC::ThrowScope&,
        JSC::JSValue algorithmValue, JSC::JSValue extractableValue, JSC::JSValue keyUsagesValue);

    inline WebCore::CryptoKeyType type() const { return m_type; }
    inline WebCore::CryptoKeyType& type() { return m_type; }
    const WTF::Vector<uint8_t>& symmetricKey() const { return m_data->symmetricKey; }
    const ncrypto::EVPKeyPointer& asymmetricKey() const { return m_data->asymmetricKey; }
    RefPtr<KeyObjectData> data() const { return m_data; }

private:
    RefPtr<KeyObjectData> m_data = nullptr;
    WebCore::CryptoKeyType m_type = WebCore::CryptoKeyType::Secret;
};

}
