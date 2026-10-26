#include "KeyObject.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"
#include "helpers.h"
#include "ZigGlobalObject.h"
#include "CryptoUtil.h"
#include "ErrorCode.h"
#include "AsymmetricKeyValue.h"
#include "CryptoKeyAES.h"
#include "CryptoKeyHMAC.h"
#include "CryptoKeyRaw.h"
#include "CryptoKey.h"
#include "CryptoKeyType.h"
#include "WebCryptoKey.h"
#include "JSBuffer.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/text/Base64.h>

namespace Bun {

using namespace Bun;
using namespace JSC;
using namespace ncrypto;
using namespace WebCore;

static JSKeyObject* nodeKeyObject(JSC::JSValue value)
{
    auto* key = dynamicDowncast<JSKeyObject>(value);
    RELEASE_ASSERT(key);
    return key;
}


struct AsymmetricKeyJwk {
    enum class Kind : uint8_t {
        rsa,
        ec,
        okp,
    };

    Kind kind;
    WTF::String kty;
    WTF::String crv;
    WTF::String n;
    WTF::String e;
    WTF::String x;
    WTF::String y;
    WTF::String d;
    WTF::String p;
    WTF::String q;
    WTF::String dp;
    WTF::String dq;
    WTF::String qi;
};

using EncodedKey = std::variant<WTF::String, WTF::Vector<uint8_t>>;

static WTF::String encodeBase64URL(JSGlobalObject* globalObject, ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto string = bufferToStringFromBytes(globalObject, scope, bytes, BufferEncodingType::base64url);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(!string.isNull());
    return string;
}

static WTF::String encodeBignum(JSGlobalObject* globalObject, ThrowScope& scope, const BIGNUM* value, int size = 0)
{
    if (size == 0)
        size = ncrypto::BignumPointer::GetByteCount(value);
    auto bytes = ncrypto::BignumPointer::EncodePadded(value, size);
    return encodeBase64URL(globalObject, scope, bytes.span());
}

static AsymmetricKeyJwk exportJwkEdKey(JSGlobalObject* globalObject, ThrowScope& scope, const KeyObject& key, CryptoKeyType exportType)
{
    const auto& pkey = key.asymmetricKey();
    AsymmetricKeyJwk jwk {
        .kind = AsymmetricKeyJwk::Kind::okp,
        .kty = "OKP"_s,
    };

    switch (pkey.id()) {
    case EVP_PKEY_ED25519:
        jwk.crv = "Ed25519"_s;
        break;
    case EVP_PKEY_ED448:
        jwk.crv = "Ed448"_s;
        break;
    case EVP_PKEY_X25519:
        jwk.crv = "X25519"_s;
        break;
    case EVP_PKEY_X448:
        jwk.crv = "X448"_s;
        break;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }

    if (exportType == CryptoKeyType::Private) {
        auto privateData = pkey.rawPrivateKey();
        jwk.d = encodeBase64URL(globalObject, scope, privateData.span());
        RETURN_IF_EXCEPTION(scope, {});
    }

    auto publicData = pkey.rawPublicKey();
    jwk.x = encodeBase64URL(globalObject, scope, publicData.span());
    RETURN_IF_EXCEPTION(scope, {});
    return jwk;
}

static AsymmetricKeyJwk exportJwkEcKey(JSGlobalObject* globalObject, ThrowScope& scope, const KeyObject& key, CryptoKeyType exportType)
{
    const auto& pkey = key.asymmetricKey();
    ASSERT(pkey.id() == EVP_PKEY_EC);
    const EC_KEY* ec = pkey;
    ASSERT(ec);

    const auto publicKey = ncrypto::ECKeyPointer::GetPublicKey(ec);
    const auto group = ncrypto::ECKeyPointer::GetGroup(ec);
    const int degreeBits = EC_GROUP_get_degree(group);
    const int degreeBytes = (degreeBits / CHAR_BIT) + (7 + (degreeBits % CHAR_BIT)) / 8;
    auto x = ncrypto::BignumPointer::New();
    auto y = ncrypto::BignumPointer::New();
    if (!x || !y) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    if (!EC_POINT_get_affine_coordinates(group, publicKey, x.get(), y.get(), nullptr)) {
        throwCryptoError(globalObject, scope, ERR_get_error(), "Failed to get elliptic-curve point coordinates");
        return {};
    }

    AsymmetricKeyJwk jwk {
        .kind = AsymmetricKeyJwk::Kind::ec,
        .kty = "EC"_s,
    };
    jwk.x = encodeBignum(globalObject, scope, x.get(), degreeBytes);
    RETURN_IF_EXCEPTION(scope, {});
    jwk.y = encodeBignum(globalObject, scope, y.get(), degreeBytes);
    RETURN_IF_EXCEPTION(scope, {});

    const int nid = EC_GROUP_get_curve_name(group);
    switch (nid) {
    case NID_X9_62_prime256v1:
        jwk.crv = "P-256"_s;
        break;
    case NID_secp256k1:
        jwk.crv = "secp256k1"_s;
        break;
    case NID_secp384r1:
        jwk.crv = "P-384"_s;
        break;
    case NID_secp521r1:
        jwk.crv = "P-521"_s;
        break;
    default:
        ERR::CRYPTO_JWK_UNSUPPORTED_CURVE(scope, globalObject, "Unsupported JWK EC curve: ", OBJ_nid2sn(nid));
        return {};
    }

    if (exportType == CryptoKeyType::Private) {
        auto privateKey = ncrypto::ECKeyPointer::GetPrivateKey(ec);
        RELEASE_ASSERT(privateKey);
        jwk.d = encodeBignum(globalObject, scope, privateKey, degreeBytes);
        RETURN_IF_EXCEPTION(scope, {});
    }
    return jwk;
}

static AsymmetricKeyJwk exportJwkRsaKey(JSGlobalObject* globalObject, ThrowScope& scope, const KeyObject& key, CryptoKeyType exportType)
{
    const ncrypto::Rsa rsa = key.asymmetricKey();
    RELEASE_ASSERT(rsa);
    auto publicKey = rsa.getPublicKey();
    AsymmetricKeyJwk jwk {
        .kind = AsymmetricKeyJwk::Kind::rsa,
        .kty = "RSA"_s,
    };
    jwk.n = encodeBignum(globalObject, scope, publicKey.n);
    RETURN_IF_EXCEPTION(scope, {});
    jwk.e = encodeBignum(globalObject, scope, publicKey.e);
    RETURN_IF_EXCEPTION(scope, {});

    if (exportType == CryptoKeyType::Private) {
        auto privateKey = rsa.getPrivateKey();
        jwk.d = encodeBignum(globalObject, scope, publicKey.d);
        RETURN_IF_EXCEPTION(scope, {});
        jwk.p = encodeBignum(globalObject, scope, privateKey.p);
        RETURN_IF_EXCEPTION(scope, {});
        jwk.q = encodeBignum(globalObject, scope, privateKey.q);
        RETURN_IF_EXCEPTION(scope, {});
        jwk.dp = encodeBignum(globalObject, scope, privateKey.dp);
        RETURN_IF_EXCEPTION(scope, {});
        jwk.dq = encodeBignum(globalObject, scope, privateKey.dq);
        RETURN_IF_EXCEPTION(scope, {});
        jwk.qi = encodeBignum(globalObject, scope, privateKey.qi);
        RETURN_IF_EXCEPTION(scope, {});
    }
    return jwk;
}

static AsymmetricKeyJwk exportJwkAsymmetricKey(JSGlobalObject* globalObject, ThrowScope& scope, const KeyObject& key, CryptoKeyType exportType)
{
    switch (key.asymmetricKey().id()) {
    case EVP_PKEY_RSA:
        return exportJwkRsaKey(globalObject, scope, key, exportType);
    case EVP_PKEY_EC:
        return exportJwkEcKey(globalObject, scope, key, exportType);
    case EVP_PKEY_ED25519:
    case EVP_PKEY_ED448:
    case EVP_PKEY_X25519:
    case EVP_PKEY_X448:
        return exportJwkEdKey(globalObject, scope, key, exportType);
    default:
        ERR::CRYPTO_JWK_UNSUPPORTED_KEY_TYPE(scope, globalObject);
        return {};
    }
}

static void putJwkString(JSGlobalObject* globalObject, JSObject* object, ASCIILiteral name, const WTF::String& value)
{
    auto& vm = globalObject->vm();
    object->putDirect(vm, Identifier::fromString(vm, name), jsString(vm, value));
}

static JSValue jwkToJS(JSGlobalObject* globalObject, const AsymmetricKeyJwk& jwk, CryptoKeyType exportType)
{
    auto* object = constructEmptyObject(globalObject);
    switch (jwk.kind) {
    case AsymmetricKeyJwk::Kind::rsa:
        putJwkString(globalObject, object, "kty"_s, jwk.kty);
        putJwkString(globalObject, object, "n"_s, jwk.n);
        putJwkString(globalObject, object, "e"_s, jwk.e);
        if (exportType == CryptoKeyType::Private) {
            putJwkString(globalObject, object, "d"_s, jwk.d);
            putJwkString(globalObject, object, "p"_s, jwk.p);
            putJwkString(globalObject, object, "q"_s, jwk.q);
            putJwkString(globalObject, object, "dp"_s, jwk.dp);
            putJwkString(globalObject, object, "dq"_s, jwk.dq);
            putJwkString(globalObject, object, "qi"_s, jwk.qi);
        }
        break;
    case AsymmetricKeyJwk::Kind::ec:
        putJwkString(globalObject, object, "kty"_s, jwk.kty);
        putJwkString(globalObject, object, "x"_s, jwk.x);
        putJwkString(globalObject, object, "y"_s, jwk.y);
        putJwkString(globalObject, object, "crv"_s, jwk.crv);
        if (exportType == CryptoKeyType::Private)
            putJwkString(globalObject, object, "d"_s, jwk.d);
        break;
    case AsymmetricKeyJwk::Kind::okp:
        putJwkString(globalObject, object, "crv"_s, jwk.crv);
        if (exportType == CryptoKeyType::Private)
            putJwkString(globalObject, object, "d"_s, jwk.d);
        putJwkString(globalObject, object, "x"_s, jwk.x);
        putJwkString(globalObject, object, "kty"_s, jwk.kty);
        break;
    }
    return object;
}

static EncodedKey encodeKey(JSGlobalObject* globalObject, ThrowScope& scope, const ncrypto::BIOPointer& bio, const ncrypto::EVPKeyPointer::AsymmetricKeyEncodingConfig& config)
{
    BUF_MEM* bytes = bio;
    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::PEM) {
        auto pem = String::fromUTF8({ bytes->data, bytes->length });
        if (pem.isNull())
            throwOutOfMemoryError(globalObject, scope);
        return pem;
    }

    ASSERT(config.format == ncrypto::EVPKeyPointer::PKFormatType::DER);
    WTF::Vector<uint8_t> result;
    if (!result.tryGrow(bytes->length)) {
        throwOutOfMemoryError(globalObject, scope);
        return WTF::String {};
    }
    if (bytes->length)
        memcpy(result.mutableSpan().data(), bytes->data, bytes->length);
    return result;
}

static EncodedKey exportPublicEncodedKey(JSGlobalObject* globalObject, ThrowScope& scope, const KeyObject& key, const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    auto encoded = key.asymmetricKey().writePublicKey(config);
    if (!encoded) {
        throwCryptoError(globalObject, scope, encoded.openssl_error.value_or(0), "Failed to encode public key");
        return WTF::String {};
    }
    return encodeKey(globalObject, scope, encoded.value, config);
}

static EncodedKey exportPrivateEncodedKey(JSGlobalObject* globalObject, ThrowScope& scope, const KeyObject& key, const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    auto encoded = key.asymmetricKey().writePrivateKey(config);
    if (!encoded) {
        throwCryptoError(globalObject, scope, encoded.openssl_error.value_or(0), "Failed to encode private key");
        return WTF::String {};
    }
    return encodeKey(globalObject, scope, encoded.value, config);
}

static JSValue encodedKeyToJS(JSGlobalObject* globalObject, ThrowScope& scope, const EncodedKey& encoded)
{
    if (std::holds_alternative<WTF::String>(encoded))
        return jsString(globalObject->vm(), std::get<WTF::String>(encoded));
    auto* buffer = createBuffer(globalObject, std::get<WTF::Vector<uint8_t>>(encoded));
    if (!buffer && !scope.exception())
        throwOutOfMemoryError(globalObject, scope);
    return buffer;
}

static Bindgen::NodeCryptoPublicKeyExportResult publicJwkResult(AsymmetricKeyJwk&& jwk)
{
    Bindgen::NodeCryptoPublicKeyExportResult result;
    switch (jwk.kind) {
    case AsymmetricKeyJwk::Kind::rsa:
        result.set_rsa_jwk({
            .kty = WTF::move(jwk.kty),
            .n = WTF::move(jwk.n),
            .e = WTF::move(jwk.e),
        });
        break;
    case AsymmetricKeyJwk::Kind::ec:
        result.set_ec_jwk({
            .kty = WTF::move(jwk.kty),
            .x = WTF::move(jwk.x),
            .y = WTF::move(jwk.y),
            .crv = WTF::move(jwk.crv),
        });
        break;
    case AsymmetricKeyJwk::Kind::okp:
        result.set_okp_jwk({
            .crv = WTF::move(jwk.crv),
            .x = WTF::move(jwk.x),
            .kty = WTF::move(jwk.kty),
        });
        break;
    }
    return result;
}

static Bindgen::NodeCryptoPrivateKeyExportResult privateJwkResult(AsymmetricKeyJwk&& jwk)
{
    Bindgen::NodeCryptoPrivateKeyExportResult result;
    switch (jwk.kind) {
    case AsymmetricKeyJwk::Kind::rsa:
        result.set_rsa_jwk({
            .kty = WTF::move(jwk.kty),
            .n = WTF::move(jwk.n),
            .e = WTF::move(jwk.e),
            .d = WTF::move(jwk.d),
            .p = WTF::move(jwk.p),
            .q = WTF::move(jwk.q),
            .dp = WTF::move(jwk.dp),
            .dq = WTF::move(jwk.dq),
            .qi = WTF::move(jwk.qi),
        });
        break;
    case AsymmetricKeyJwk::Kind::ec:
        result.set_ec_jwk({
            .kty = WTF::move(jwk.kty),
            .x = WTF::move(jwk.x),
            .y = WTF::move(jwk.y),
            .crv = WTF::move(jwk.crv),
            .d = WTF::move(jwk.d),
        });
        break;
    case AsymmetricKeyJwk::Kind::okp:
        result.set_okp_jwk({
            .crv = WTF::move(jwk.crv),
            .d = WTF::move(jwk.d),
            .x = WTF::move(jwk.x),
            .kty = WTF::move(jwk.kty),
        });
        break;
    }
    return result;
}

static Bindgen::NodeCryptoPublicKeyExportResult publicEncodedResult(EncodedKey&& encoded)
{
    Bindgen::NodeCryptoPublicKeyExportResult result;
    if (std::holds_alternative<WTF::String>(encoded))
        result.set_string(WTF::move(std::get<WTF::String>(encoded)));
    else
        result.set_buffer(WTF::move(std::get<WTF::Vector<uint8_t>>(encoded)));
    return result;
}

static Bindgen::NodeCryptoPrivateKeyExportResult privateEncodedResult(EncodedKey&& encoded)
{
    Bindgen::NodeCryptoPrivateKeyExportResult result;
    if (std::holds_alternative<WTF::String>(encoded))
        result.set_string(WTF::move(std::get<WTF::String>(encoded)));
    else
        result.set_buffer(WTF::move(std::get<WTF::Vector<uint8_t>>(encoded)));
    return result;
}

Bindgen::NodeCryptoPublicKeyExportResult KeyObject::exportPublicResult(JSGlobalObject* globalObject, ThrowScope& scope, const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    ASSERT(type() != CryptoKeyType::Secret);
    ASSERT(!config.output_key_object);
    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::JWK) {
        auto jwk = exportJwkAsymmetricKey(globalObject, scope, *this, CryptoKeyType::Public);
        RETURN_IF_EXCEPTION(scope, {});
        return publicJwkResult(WTF::move(jwk));
    }
    auto encoded = exportPublicEncodedKey(globalObject, scope, *this, config);
    RETURN_IF_EXCEPTION(scope, {});
    return publicEncodedResult(WTF::move(encoded));
}

Bindgen::NodeCryptoPrivateKeyExportResult KeyObject::exportPrivateResult(JSGlobalObject* globalObject, ThrowScope& scope, const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    ASSERT(type() != CryptoKeyType::Secret);
    ASSERT(!config.output_key_object);
    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::JWK) {
        auto jwk = exportJwkAsymmetricKey(globalObject, scope, *this, CryptoKeyType::Private);
        RETURN_IF_EXCEPTION(scope, {});
        return privateJwkResult(WTF::move(jwk));
    }
    auto encoded = exportPrivateEncodedKey(globalObject, scope, *this, config);
    RETURN_IF_EXCEPTION(scope, {});
    return privateEncodedResult(WTF::move(encoded));
}

JSC::JSValue KeyObject::exportPublic(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    ASSERT(type() != CryptoKeyType::Secret);

    if (config.output_key_object) {
        KeyObject keyObject = *this;
        keyObject.type() = CryptoKeyType::Public;
        Structure* structure = globalObject->m_JSPublicKeyObjectClassStructure.get(lexicalGlobalObject);
        JSPublicKeyObject* publicKey = JSPublicKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));
        return publicKey;
    }

    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::JWK) {
        auto jwk = exportJwkAsymmetricKey(lexicalGlobalObject, scope, *this, CryptoKeyType::Public);
        RETURN_IF_EXCEPTION(scope, {});
        return jwkToJS(lexicalGlobalObject, jwk, CryptoKeyType::Public);
    }

    auto encoded = exportPublicEncodedKey(lexicalGlobalObject, scope, *this, config);
    RETURN_IF_EXCEPTION(scope, {});
    return encodedKeyToJS(lexicalGlobalObject, scope, encoded);
}

JSValue KeyObject::exportPrivate(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    ASSERT(type() != CryptoKeyType::Secret);

    if (config.output_key_object) {
        KeyObject keyObject = *this;
        Structure* structure = globalObject->m_JSPrivateKeyObjectClassStructure.get(lexicalGlobalObject);
        JSPrivateKeyObject* privateKey = JSPrivateKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));
        return privateKey;
    }

    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::JWK) {
        auto jwk = exportJwkAsymmetricKey(lexicalGlobalObject, scope, *this, CryptoKeyType::Private);
        RETURN_IF_EXCEPTION(scope, {});
        return jwkToJS(lexicalGlobalObject, jwk, CryptoKeyType::Private);
    }

    auto encoded = exportPrivateEncodedKey(lexicalGlobalObject, scope, *this, config);
    RETURN_IF_EXCEPTION(scope, {});
    return encodedKeyToJS(lexicalGlobalObject, scope, encoded);
}

std::optional<Bindgen::NodeCryptoAsymmetricKeyKind> KeyObject::asymmetricKeyType() const
{
    if (type() == CryptoKeyType::Secret)
        return std::nullopt;

    switch (m_data->asymmetricKey.id()) {
    case EVP_PKEY_RSA:
        return Bindgen::NodeCryptoAsymmetricKeyKind::rsa;
    case EVP_PKEY_RSA_PSS:
        return Bindgen::NodeCryptoAsymmetricKeyKind::rsa_pss;
    case EVP_PKEY_DSA:
        return Bindgen::NodeCryptoAsymmetricKeyKind::dsa;
    case EVP_PKEY_DH:
        return Bindgen::NodeCryptoAsymmetricKeyKind::dh;
    case EVP_PKEY_EC:
        return Bindgen::NodeCryptoAsymmetricKeyKind::ec;
    case EVP_PKEY_ED25519:
        return Bindgen::NodeCryptoAsymmetricKeyKind::ed25519;
    case EVP_PKEY_ED448:
        return Bindgen::NodeCryptoAsymmetricKeyKind::ed448;
    case EVP_PKEY_X25519:
        return Bindgen::NodeCryptoAsymmetricKeyKind::x25519;
    case EVP_PKEY_X448:
        return Bindgen::NodeCryptoAsymmetricKeyKind::x448;
    default:
        return std::nullopt;
    }
}

void KeyObject::getRsaKeyDetails(JSGlobalObject* globalObject, ThrowScope& scope, AsymmetricKeyDetails& result)
{
    const auto& pkey = m_data->asymmetricKey;
    const ncrypto::Rsa rsa = pkey;
    if (!rsa) {
        return;
    }

    auto pubKey = rsa.getPublicKey();

    result.modulus_length = static_cast<double>(ncrypto::BignumPointer::GetBitCount(pubKey.n));

    auto publicExponentHex = BignumPointer::toHex(pubKey.e);
    if (!publicExponentHex) {
        ERR::CRYPTO_OPERATION_FAILED(scope, globalObject, "Failed to create publicExponent"_s);
        return;
    }

    result.public_exponent_hex = WTF::String { std::span<const char> {
        publicExponentHex.get<const char>(),
        publicExponentHex.size(),
    } };

    if (pkey.id() == EVP_PKEY_RSA_PSS) {
        auto maybeParams = rsa.getPssParams();
        if (maybeParams.has_value()) {
            auto& params = maybeParams.value();
            result.hash_algorithm = params.digest.toString();

            if (params.mgf1_digest.has_value()) {
                result.mgf1_hash_algorithm = params.mgf1_digest.value().toString();
            }

            result.salt_length = static_cast<double>(params.salt_length);
        }
    }
}

void KeyObject::getDsaKeyDetails(AsymmetricKeyDetails& result)
{
    const ncrypto::Dsa dsa = m_data->asymmetricKey;
    if (!dsa) {
        return;
    }

    size_t modulusLength = dsa.getModulusLength();
    size_t divisorLength = dsa.getDivisorLength();

    result.modulus_length = static_cast<double>(modulusLength);
    result.divisor_length = static_cast<double>(divisorLength);
}

void KeyObject::getEcKeyDetails(AsymmetricKeyDetails& result)
{
    const auto& pkey = m_data->asymmetricKey;
    ASSERT(pkey.id() == EVP_PKEY_EC);
    const EC_KEY* ec = pkey;

    const auto group = ncrypto::ECKeyPointer::GetGroup(ec);
    int nid = EC_GROUP_get_curve_name(group);

    result.named_curve = String::fromUTF8(OBJ_nid2sn(nid));
}

AsymmetricKeyDetails KeyObject::asymmetricKeyDetails(JSGlobalObject* globalObject, ThrowScope& scope)
{
    AsymmetricKeyDetails result {};

    if (type() == CryptoKeyType::Secret) {
        return result;
    }

    switch (m_data->asymmetricKey.id()) {
    case EVP_PKEY_RSA:
    case EVP_PKEY_RSA_PSS:
        getRsaKeyDetails(globalObject, scope, result);
        RETURN_IF_EXCEPTION(scope, {});
        break;
    case EVP_PKEY_DSA:
        getDsaKeyDetails(result);
        break;
    case EVP_PKEY_EC: {
        getEcKeyDetails(result);
        break;
    }
    default:
    }

    return result;
}

// returns std::nullopt for "unsupported crypto operation"
std::optional<bool> KeyObject::equals(const KeyObject& other) const
{
    auto thisType = type();
    auto otherType = other.type();
    if (thisType != otherType) {
        return false;
    }

    switch (thisType) {
    case CryptoKeyType::Secret: {
        auto thisKey = symmetricKey().span();
        auto otherKey = other.symmetricKey().span();

        if (thisKey.size() != otherKey.size()) {
            return false;
        }

        return CRYPTO_memcmp(thisKey.data(), otherKey.data(), thisKey.size()) == 0;
    }
    case CryptoKeyType::Public:
    case CryptoKeyType::Private: {
        EVP_PKEY* thisKey = m_data->asymmetricKey.get();
        EVP_PKEY* otherKey = other.m_data->asymmetricKey.get();

        int ok = EVP_PKEY_cmp(thisKey, otherKey);
        if (ok == -2) {
            return std::nullopt;
        }

        return ok == 1;
    }
    }
}

JSValue KeyObject::toCryptoKey(JSGlobalObject* globalObject, ThrowScope& scope, JSValue algorithmValue, JSValue extractableValue, JSValue keyUsagesValue)
{
    return jsUndefined();
}

static std::optional<const Vector<uint8_t>*> getSymmetricKey(const WebCore::CryptoKey& key)
{
    switch (key.keyClass()) {
    case WebCore::CryptoKeyClass::AES:
        return &downcast<CryptoKeyAES>(key).key();
    case WebCore::CryptoKeyClass::HMAC:
        return &downcast<CryptoKeyHMAC>(key).key();
    case WebCore::CryptoKeyClass::Raw:
        return &downcast<CryptoKeyRaw>(key).key();
    default: {
        return std::nullopt;
    }
    }
}

KeyObject KeyObject::create(CryptoKeyType type, RefPtr<KeyObjectData>&& data)
{
    return KeyObject(type, WTF::move(data));
}

WebCore::ExceptionOr<KeyObject> KeyObject::create(WebCore::CryptoKey& key)
{
    switch (key.type()) {
    case WebCore::CryptoKeyType::Secret: {
        std::optional<const Vector<uint8_t>*> keyData = getSymmetricKey(key);
        if (!keyData) {
            return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Failed to extract secret key material"_s };
        }

        WTF::Vector<uint8_t> copy;
        if (!copy.tryAppend(keyData.value()->span()))
            return WebCore::Exception { WebCore::ExceptionCode::OutOfMemoryError };
        return create(WTF::move(copy));
    }

    case WebCore::CryptoKeyType::Public: {
        // Extract asymmetric public key data
        AsymmetricKeyValue keyValue(key);
        if (!keyValue.key) {
            return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Failed to extract public key material"_s };
        }

        // Increment ref count because KeyObject will own a reference
        EVP_PKEY_up_ref(keyValue.key);
        ncrypto::EVPKeyPointer keyPtr(keyValue.key);

        return create(CryptoKeyType::Public, WTF::move(keyPtr));
    }

    case WebCore::CryptoKeyType::Private: {
        // Extract asymmetric private key data
        AsymmetricKeyValue keyValue(key);
        if (!keyValue.key) {
            return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Failed to extract private key material"_s };
        }

        // Increment ref count because KeyObject will own a reference
        EVP_PKEY_up_ref(keyValue.key);
        ncrypto::EVPKeyPointer keyPtr(keyValue.key);

        return create(CryptoKeyType::Private, WTF::move(keyPtr));
    }
    }

    return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Unknown key type"_s };
}

WebCore::ExceptionOr<KeyObject> KeyObject::create(WTF::Vector<uint8_t>&& symmetricKey)
{
    RefPtr<KeyObjectData> data = KeyObjectData::tryCreate(WTF::move(symmetricKey));
    if (!data)
        return WebCore::Exception { WebCore::ExceptionCode::OutOfMemoryError };
    return KeyObject(CryptoKeyType::Secret, WTF::move(data));
}

WebCore::ExceptionOr<KeyObject> KeyObject::create(CryptoKeyType type, ncrypto::EVPKeyPointer&& asymmetricKey)
{
    RefPtr<KeyObjectData> data = KeyObjectData::tryCreate(WTF::move(asymmetricKey));
    if (!data)
        return WebCore::Exception { WebCore::ExceptionCode::OutOfMemoryError };
    return KeyObject(type, WTF::move(data));
}

KeyObject KeyObject::create(JSGlobalObject* globalObject, ThrowScope& scope, WTF::Vector<uint8_t>&& symmetricKey)
{
    auto result = create(WTF::move(symmetricKey));
    if (result.hasException()) {
        WebCore::propagateException(*globalObject, scope, result.releaseException());
        return {};
    }
    return result.releaseReturnValue();
}

KeyObject KeyObject::create(JSGlobalObject* globalObject, ThrowScope& scope, CryptoKeyType type, ncrypto::EVPKeyPointer&& asymmetricKey)
{
    auto result = create(type, WTF::move(asymmetricKey));
    if (result.hasException()) {
        WebCore::propagateException(*globalObject, scope, result.releaseException());
        return {};
    }
    return result.releaseReturnValue();
}

void KeyObject::getKeyFormatAndType(
    EVPKeyPointer::PKFormatType formatType,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    KeyEncodingContext ctx,
    EVPKeyPointer::AsymmetricKeyEncodingConfig& config)
{
    // if (!formatType) {
    //     ASSERT(ctx == KeyEncodingContext::Generate);
    //     config.output_key_object = true;
    // } else {
    config.output_key_object = false;

    config.format = formatType;

    if (encodingType) {
        config.type = *encodingType;
    } else {
        ASSERT((ctx == KeyEncodingContext::Input && config.format == EVPKeyPointer::PKFormatType::PEM)
            || (ctx == KeyEncodingContext::Generate && config.format == EVPKeyPointer::PKFormatType::JWK));
        config.type = EVPKeyPointer::PKEncodingType::PKCS1;
    }
    // }
}

EVPKeyPointer::PrivateKeyEncodingConfig KeyObject::getPrivateKeyEncoding(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    EVPKeyPointer::PKFormatType formatType,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    const EVP_CIPHER* cipher,
    std::optional<DataPointer> passphrase,
    KeyEncodingContext ctx)
{
    EVPKeyPointer::PrivateKeyEncodingConfig config;
    getKeyFormatAndType(formatType, encodingType, ctx, config);

    if (config.output_key_object) {
        // TODO: make sure this case for key generation is handled
    } else {
        if (ctx != KeyEncodingContext::Input) {
            config.cipher = cipher;
        }

        if (passphrase) {
            config.passphrase = WTF::move(*passphrase);
        }
    }

    return config;
}

// KeyObjectHandle::init for public and private keys
KeyObject KeyObject::getPublicOrPrivateKey(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    std::span<const uint8_t> keyData,
    CryptoKeyType keyType,
    EVPKeyPointer::PKFormatType formatType,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    const EVP_CIPHER* cipher,
    std::optional<DataPointer> passphrase)
{
    auto buf = ncrypto::Buffer<const uint8_t> {
        .data = reinterpret_cast<const uint8_t*>(keyData.data()),
        .len = keyData.size(),
    };

    if (keyType == CryptoKeyType::Private) {
        auto config = getPrivateKeyEncoding(
            globalObject,
            scope,
            formatType,
            encodingType,
            cipher,
            WTF::move(passphrase),
            KeyEncodingContext::Input);
        RETURN_IF_EXCEPTION(scope, {});

        auto res = EVPKeyPointer::TryParsePrivateKey(config, buf);
        if (res) {
            return create(globalObject, scope, CryptoKeyType::Private, WTF::move(res.value));
        }

        if (res.error.value() == EVPKeyPointer::PKParseError::NEED_PASSPHRASE) {
            ERR::MISSING_PASSPHRASE(scope, globalObject, "Passphrase required for encrypted key"_s);
        } else {
            throwCryptoError(globalObject, scope, res.openssl_error.value_or(0), "Failed to read private key"_s);
        }
        return {};
    }

    if (buf.len > INT_MAX) {
        ERR::OUT_OF_RANGE(scope, globalObject, "keyData is too big"_s);
        return {};
    }

    auto config = getPrivateKeyEncoding(
        globalObject,
        scope,
        formatType,
        encodingType,
        cipher,
        WTF::move(passphrase),
        KeyEncodingContext::Input);
    RETURN_IF_EXCEPTION(scope, {});

    if (config.format == EVPKeyPointer::PKFormatType::PEM) {
        auto publicRes = EVPKeyPointer::TryParsePublicKeyPEM(buf);
        if (publicRes) {
            return create(globalObject, scope, CryptoKeyType::Public, WTF::move(publicRes.value));
        }

        if (publicRes.error.value() == EVPKeyPointer::PKParseError::NOT_RECOGNIZED) {
            auto privateRes = EVPKeyPointer::TryParsePrivateKey(config, buf);
            if (privateRes) {
                return create(globalObject, scope, CryptoKeyType::Public, WTF::move(privateRes.value));
            }

            if (privateRes.error.value() == EVPKeyPointer::PKParseError::NEED_PASSPHRASE) {
                ERR::MISSING_PASSPHRASE(scope, globalObject, "Passphrase required for encrypted key"_s);
            } else {
                throwCryptoError(globalObject, scope, privateRes.openssl_error.value_or(0), "Failed to read private key"_s);
            }
            return {};
        }

        throwCryptoError(globalObject, scope, publicRes.openssl_error.value_or(0), "Failed to read asymmetric key"_s);
        return {};
    }

    static const auto isPublic = [](const auto& config, const auto& buffer) -> bool {
        switch (config.type) {
        case EVPKeyPointer::PKEncodingType::PKCS1:
            return !EVPKeyPointer::IsRSAPrivateKey(buffer);
        case EVPKeyPointer::PKEncodingType::SPKI:
            return true;
        case EVPKeyPointer::PKEncodingType::PKCS8:
            return false;
        case EVPKeyPointer::PKEncodingType::SEC1:
            return false;
        default:
            return false;
        }
    };

    if (isPublic(config, buf)) {
        auto res = EVPKeyPointer::TryParsePublicKey(config, buf);
        if (res) {
            return create(globalObject, scope, CryptoKeyType::Public, WTF::move(res.value));
        }

        throwCryptoError(globalObject, scope, res.openssl_error.value_or(0), "Failed to read asymmetric key"_s);
        return {};
    }

    auto res = EVPKeyPointer::TryParsePrivateKey(config, buf);
    if (res) {
        return create(globalObject, scope, CryptoKeyType::Private, WTF::move(res.value));
    }

    if (res.error.value() == EVPKeyPointer::PKParseError::NEED_PASSPHRASE) {
        ERR::MISSING_PASSPHRASE(scope, globalObject, "Passphrase required for encrypted key"_s);
    } else {
        throwCryptoError(globalObject, scope, res.openssl_error.value_or(0), "Failed to read asymmetric key"_s);
    }
    return {};
}

static CryptoKeyType asymmetricKeyTypeForMode(KeyObject::PrepareAsymmetricKeyMode mode)
{
    return mode == KeyObject::PrepareAsymmetricKeyMode::ConsumePublic || mode == KeyObject::PrepareAsymmetricKeyMode::CreatePublic
        ? CryptoKeyType::Public
        : CryptoKeyType::Private;
}

static RefPtr<KeyObjectData> checkedAsymmetricKeyData(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    JSC::JSValue value,
    KeyObject::PrepareAsymmetricKeyMode mode)
{
    auto& keyObject = nodeKeyObject(value)->handle();
    if (mode == KeyObject::PrepareAsymmetricKeyMode::CreatePrivate) {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string, ArrayBuffer, Buffer, TypedArray, or DataView"_s, value);
        return nullptr;
    }

    if (keyObject.type() != CryptoKeyType::Private) {
        if (mode == KeyObject::PrepareAsymmetricKeyMode::ConsumePrivate || mode == KeyObject::PrepareAsymmetricKeyMode::CreatePublic) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, keyObject.type(), "private"_s);
            return nullptr;
        }
        if (keyObject.type() != CryptoKeyType::Public) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, keyObject.type(), "private or public"_s);
            return nullptr;
        }
    }

    return keyObject.data();
}

static RefPtr<KeyObjectData> checkedAsymmetricCryptoKeyData(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    JSC::JSValue value,
    KeyObject::PrepareAsymmetricKeyMode mode)
{
    auto& cryptoKey = webCryptoKey(value);
    if (mode == KeyObject::PrepareAsymmetricKeyMode::CreatePrivate) {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string, ArrayBuffer, Buffer, TypedArray, or DataView"_s, value);
        return nullptr;
    }

    if (cryptoKey.type() != CryptoKeyType::Private) {
        if (mode == KeyObject::PrepareAsymmetricKeyMode::ConsumePrivate || mode == KeyObject::PrepareAsymmetricKeyMode::CreatePublic) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, cryptoKey.type(), "private"_s);
            return nullptr;
        }
        if (cryptoKey.type() != CryptoKeyType::Public) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, cryptoKey.type(), "private or public"_s);
            return nullptr;
        }
    }

    auto keyObject = KeyObject::create(cryptoKey);
    if (keyObject.hasException()) [[unlikely]] {
        WebCore::propagateException(*globalObject, scope, keyObject.releaseException());
        return nullptr;
    }
    return keyObject.releaseReturnValue().data();
}

static std::optional<WTF::Vector<uint8_t>> decodeTypedJwkBytes(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const WTF::String& value)
{
    auto decoded = WTF::base64Decode(WTF::StringView { value }, { WTF::Base64DecodeOption::URL });
    if (!decoded) {
        ERR::CRYPTO_INVALID_JWK(scope, globalObject);
        return std::nullopt;
    }
    return WTF::move(*decoded);
}

static void throwJwkConstructionFailure(JSGlobalObject* globalObject, ThrowScope& scope, ASCIILiteral message = { })
{
    if (ncrypto::takeAllocationFailure())
        throwOutOfMemoryError(globalObject, scope);
    else if (message.isEmpty())
        ERR::CRYPTO_INVALID_JWK(scope, globalObject);
    else
        ERR::CRYPTO_INVALID_JWK(scope, globalObject, message);
}

static BignumPointer typedJwkBytesToBn(JSGlobalObject* globalObject, ThrowScope& scope, const WTF::Vector<uint8_t>& bytes)
{
    BignumPointer result(bytes.span().data(), bytes.size());
    if (!result)
        throwJwkConstructionFailure(globalObject, scope);
    return result;
}

static KeyObject keyObjectFromTypedJwk(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const Bindgen::NodeCryptoJwk& jwk,
    KeyObject::PrepareAsymmetricKeyMode mode)
{
    const auto* kty = jwk.kty.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!kty)
        return {};

    const auto keyType = asymmetricKeyTypeForMode(mode);
    switch (*kty) {
    case Bindgen::NodeCryptoJwkKeyType::okp: {
        const auto* curve = jwk.okp_crv.convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!curve)
            return {};

        int nid;
        switch (*curve) {
        case Bindgen::NodeCryptoJwkOkpCurve::ed25519:
            nid = EVP_PKEY_ED25519;
            break;
        case Bindgen::NodeCryptoJwkOkpCurve::ed448:
            nid = EVP_PKEY_ED448;
            break;
        case Bindgen::NodeCryptoJwkOkpCurve::x25519:
            nid = EVP_PKEY_X25519;
            break;
        case Bindgen::NodeCryptoJwkOkpCurve::x448:
            nid = EVP_PKEY_X448;
            break;
        }

        const auto* encoded = keyType == CryptoKeyType::Public ? jwk.x.convert() : jwk.d.convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!encoded)
            return {};
        auto decoded = decodeTypedJwkBytes(globalObject, scope, *encoded);
        RETURN_IF_EXCEPTION(scope, {});
        if (!decoded)
            return {};

        auto bytes = decoded->span();
        size_t expectedLength;
        switch (nid) {
        case EVP_PKEY_ED25519:
        case EVP_PKEY_X25519:
            expectedLength = 32;
            break;
        case EVP_PKEY_ED448:
            expectedLength = 57;
            break;
        case EVP_PKEY_X448:
            expectedLength = 56;
            break;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
        if (bytes.size() != expectedLength) {
            ERR::CRYPTO_INVALID_JWK(scope, globalObject);
            return {};
        }

        ncrypto::ClearErrorOnReturn clearError;
        ncrypto::Buffer<const uint8_t> buffer {
            .data = bytes.data(),
            .len = bytes.size(),
        };
        auto key = keyType == CryptoKeyType::Public
            ? EVPKeyPointer::NewRawPublic(nid, buffer)
            : EVPKeyPointer::NewRawPrivate(nid, buffer);
        if (!key) {
            throwJwkConstructionFailure(globalObject, scope);
            return {};
        }
        return KeyObject::create(globalObject, scope, keyType, WTF::move(key));
    }
    case Bindgen::NodeCryptoJwkKeyType::ec: {
        const auto* curve = jwk.crv.convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!curve)
            return {};

        const char* curveName;
        switch (*curve) {
        case Bindgen::NodeCryptoJwkEcCurve::p256:
            curveName = "P-256";
            break;
        case Bindgen::NodeCryptoJwkEcCurve::secp256k1:
            curveName = "secp256k1";
            break;
        case Bindgen::NodeCryptoJwkEcCurve::p384:
            curveName = "P-384";
            break;
        case Bindgen::NodeCryptoJwkEcCurve::p521:
            curveName = "P-521";
            break;
        }

        const auto* x = jwk.x.convert();
        RETURN_IF_EXCEPTION(scope, {});
        const auto* y = jwk.y.convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!x || !y)
            return {};
        auto xBytes = decodeTypedJwkBytes(globalObject, scope, *x);
        RETURN_IF_EXCEPTION(scope, {});
        auto yBytes = decodeTypedJwkBytes(globalObject, scope, *y);
        RETURN_IF_EXCEPTION(scope, {});
        if (!xBytes || !yBytes)
            return {};

        ncrypto::ClearErrorOnReturn clearError;
        int nid = Ec::GetCurveIdFromName(curveName);
        if (nid == NID_undef) {
            ERR::CRYPTO_INVALID_CURVE(scope, globalObject);
            return {};
        }
        auto ec = ECKeyPointer::NewByCurveName(nid);
        if (!ec) {
            throwJwkConstructionFailure(globalObject, scope, "Invalid JWK EC key"_s);
            return {};
        }
        auto xBn = typedJwkBytesToBn(globalObject, scope, *xBytes);
        RETURN_IF_EXCEPTION(scope, {});
        auto yBn = typedJwkBytesToBn(globalObject, scope, *yBytes);
        RETURN_IF_EXCEPTION(scope, {});
        if (!ec.setPublicKeyRaw(xBn, yBn)) {
            throwJwkConstructionFailure(globalObject, scope, "Invalid JWK EC key"_s);
            return {};
        }

        if (keyType == CryptoKeyType::Private) {
            const auto* d = jwk.d.convert();
            RETURN_IF_EXCEPTION(scope, {});
            if (!d)
                return {};
            auto dBytes = decodeTypedJwkBytes(globalObject, scope, *d);
            RETURN_IF_EXCEPTION(scope, {});
            if (!dBytes)
                return {};
            auto dBn = typedJwkBytesToBn(globalObject, scope, *dBytes);
            RETURN_IF_EXCEPTION(scope, {});
            if (!ec.setPrivateKey(dBn)) {
                throwJwkConstructionFailure(globalObject, scope, "Invalid JWK EC key"_s);
                return {};
            }
        }

        auto key = EVPKeyPointer::New();
        if (!key || !key.set(ec)) {
            throwJwkConstructionFailure(globalObject, scope, "Invalid JWK EC key"_s);
            return {};
        }
        return KeyObject::create(globalObject, scope, keyType, WTF::move(key));
    }
    case Bindgen::NodeCryptoJwkKeyType::rsa: {
        const auto* n = jwk.n.convert();
        RETURN_IF_EXCEPTION(scope, {});
        const auto* e = jwk.e.convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!n || !e)
            return {};
        auto nBytes = decodeTypedJwkBytes(globalObject, scope, *n);
        RETURN_IF_EXCEPTION(scope, {});
        auto eBytes = decodeTypedJwkBytes(globalObject, scope, *e);
        RETURN_IF_EXCEPTION(scope, {});
        if (!nBytes || !eBytes)
            return {};

        ncrypto::ClearErrorOnReturn clearError;
        RSAPointer rsa(RSA_new());
        if (!rsa) {
            throwJwkConstructionFailure(globalObject, scope, "Invalid JWK RSA key"_s);
            return {};
        }
        Rsa rsaView(rsa.get());
        auto nBn = typedJwkBytesToBn(globalObject, scope, *nBytes);
        RETURN_IF_EXCEPTION(scope, {});
        auto eBn = typedJwkBytesToBn(globalObject, scope, *eBytes);
        RETURN_IF_EXCEPTION(scope, {});
        if (!rsaView.setPublicKey(WTF::move(nBn), WTF::move(eBn))) {
            throwJwkConstructionFailure(globalObject, scope, "Invalid JWK RSA key"_s);
            return {};
        }

        if (keyType == CryptoKeyType::Private) {
            const auto* d = jwk.d.convert();
            RETURN_IF_EXCEPTION(scope, {});
            const auto* p = jwk.p.convert();
            RETURN_IF_EXCEPTION(scope, {});
            const auto* q = jwk.q.convert();
            RETURN_IF_EXCEPTION(scope, {});
            const auto* dp = jwk.dp.convert();
            RETURN_IF_EXCEPTION(scope, {});
            const auto* dq = jwk.dq.convert();
            RETURN_IF_EXCEPTION(scope, {});
            const auto* qi = jwk.qi.convert();
            RETURN_IF_EXCEPTION(scope, {});
            if (!d || !p || !q || !dp || !dq || !qi)
                return {};

            auto dBytes = decodeTypedJwkBytes(globalObject, scope, *d);
            RETURN_IF_EXCEPTION(scope, {});
            auto pBytes = decodeTypedJwkBytes(globalObject, scope, *p);
            RETURN_IF_EXCEPTION(scope, {});
            auto qBytes = decodeTypedJwkBytes(globalObject, scope, *q);
            RETURN_IF_EXCEPTION(scope, {});
            auto dpBytes = decodeTypedJwkBytes(globalObject, scope, *dp);
            RETURN_IF_EXCEPTION(scope, {});
            auto dqBytes = decodeTypedJwkBytes(globalObject, scope, *dq);
            RETURN_IF_EXCEPTION(scope, {});
            auto qiBytes = decodeTypedJwkBytes(globalObject, scope, *qi);
            RETURN_IF_EXCEPTION(scope, {});
            if (!dBytes || !pBytes || !qBytes || !dpBytes || !dqBytes || !qiBytes)
                return {};

            auto dBn = typedJwkBytesToBn(globalObject, scope, *dBytes);
            RETURN_IF_EXCEPTION(scope, {});
            auto pBn = typedJwkBytesToBn(globalObject, scope, *pBytes);
            RETURN_IF_EXCEPTION(scope, {});
            auto qBn = typedJwkBytesToBn(globalObject, scope, *qBytes);
            RETURN_IF_EXCEPTION(scope, {});
            auto dpBn = typedJwkBytesToBn(globalObject, scope, *dpBytes);
            RETURN_IF_EXCEPTION(scope, {});
            auto dqBn = typedJwkBytesToBn(globalObject, scope, *dqBytes);
            RETURN_IF_EXCEPTION(scope, {});
            auto qiBn = typedJwkBytesToBn(globalObject, scope, *qiBytes);
            RETURN_IF_EXCEPTION(scope, {});
            if (!rsaView.setPrivateKey(
                    WTF::move(dBn),
                    WTF::move(qBn),
                    WTF::move(pBn),
                    WTF::move(dpBn),
                    WTF::move(dqBn),
                    WTF::move(qiBn))) {
                throwJwkConstructionFailure(globalObject, scope, "Invalid JWK RSA key"_s);
                return {};
            }
        }

        auto key = EVPKeyPointer::NewRSA(WTF::move(rsa));
        if (!key) {
            throwJwkConstructionFailure(globalObject, scope, "Invalid JWK RSA key"_s);
            return {};
        }
        return KeyObject::create(globalObject, scope, keyType, WTF::move(key));
    }
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static EVPKeyPointer::PKFormatType typedAsymmetricKeyFormat(Bindgen::NodeCryptoAsymmetricKeyFormat format)
{
    switch (format) {
    case Bindgen::NodeCryptoAsymmetricKeyFormat::pem:
        return EVPKeyPointer::PKFormatType::PEM;
    case Bindgen::NodeCryptoAsymmetricKeyFormat::der:
        return EVPKeyPointer::PKFormatType::DER;
    case Bindgen::NodeCryptoAsymmetricKeyFormat::jwk:
        return EVPKeyPointer::PKFormatType::JWK;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static std::optional<EVPKeyPointer::PKEncodingType> typedAsymmetricKeyEncoding(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    std::optional<Bindgen::NodeCryptoAsymmetricKeyType> type,
    Bindgen::NodeCryptoAsymmetricKeyFormat format,
    KeyObject::PrepareAsymmetricKeyMode mode)
{
    if (!type) {
        if (format == Bindgen::NodeCryptoAsymmetricKeyFormat::der) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "options.type"_s, JSC::jsUndefined());
        }
        return std::nullopt;
    }

    const bool requiresPrivate = mode == KeyObject::PrepareAsymmetricKeyMode::ConsumePrivate || mode == KeyObject::PrepareAsymmetricKeyMode::CreatePrivate;
    switch (*type) {
    case Bindgen::NodeCryptoAsymmetricKeyType::pkcs1:
        return EVPKeyPointer::PKEncodingType::PKCS1;
    case Bindgen::NodeCryptoAsymmetricKeyType::spki:
        if (!requiresPrivate)
            return EVPKeyPointer::PKEncodingType::SPKI;
        break;
    case Bindgen::NodeCryptoAsymmetricKeyType::pkcs8:
        return EVPKeyPointer::PKEncodingType::PKCS8;
    case Bindgen::NodeCryptoAsymmetricKeyType::sec1:
        return EVPKeyPointer::PKEncodingType::SEC1;
    }

    ERR::INVALID_ARG_VALUE(scope, globalObject, "options.type"_s, JSC::jsString(globalObject->vm(), WTF::String("spki"_s)));
    return std::nullopt;
}

static RefPtr<KeyObjectData> parseTypedAsymmetricKeyBytes(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    std::span<const uint8_t> bytes,
    KeyObject::PrepareAsymmetricKeyMode mode,
    Bindgen::NodeCryptoAsymmetricKeyFormat format,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    std::optional<DataPointer> passphrase)
{
    auto keyObject = KeyObject::getPublicOrPrivateKey(
        globalObject,
        scope,
        bytes,
        asymmetricKeyTypeForMode(mode),
        typedAsymmetricKeyFormat(format),
        encodingType,
        nullptr,
        WTF::move(passphrase));
    RETURN_IF_EXCEPTION(scope, nullptr);
    return keyObject.data();
}

static RefPtr<KeyObjectData> prepareTypedAsymmetricKeyMaterial(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const auto& material,
    KeyObject::PrepareAsymmetricKeyMode mode,
    BufferEncodingType stringEncoding,
    Bindgen::NodeCryptoAsymmetricKeyFormat format,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    std::optional<DataPointer> passphrase)
{
    RELEASE_ASSERT(format != Bindgen::NodeCryptoAsymmetricKeyFormat::jwk);
    if (material.is_buffer())
        return parseTypedAsymmetricKeyBytes(globalObject, scope, material.buffer(), mode, format, encodingType, WTF::move(passphrase));

    RELEASE_ASSERT(material.is_string());
    auto encoded = getStringOrBufferBytes(globalObject, scope, material, stringEncoding);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return parseTypedAsymmetricKeyBytes(globalObject, scope, encoded.data, mode, format, encodingType, WTF::move(passphrase));
}

RefPtr<KeyObjectData> KeyObject::prepareAsymmetricKey(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const Bindgen::NodeCryptoAsymmetricKeyInput& input,
    PrepareAsymmetricKeyMode mode)
{
    if (input.is_key_object())
        return checkedAsymmetricKeyData(globalObject, scope, input.key_object(), mode);
    if (input.is_crypto_key())
        return checkedAsymmetricCryptoKeyData(globalObject, scope, input.crypto_key(), mode);
    if (input.is_buffer()) {
        return parseTypedAsymmetricKeyBytes(
            globalObject,
            scope,
            input.buffer(),
            mode,
            Bindgen::NodeCryptoAsymmetricKeyFormat::pem,
            std::nullopt,
            std::nullopt);
    }
    if (input.is_string()) {
        auto encoded = getStringOrBufferBytes(globalObject, scope, input, BufferEncodingType::utf8);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return parseTypedAsymmetricKeyBytes(
            globalObject,
            scope,
            encoded.data,
            mode,
            Bindgen::NodeCryptoAsymmetricKeyFormat::pem,
            std::nullopt,
            std::nullopt);
    }

    RELEASE_ASSERT(input.is_options());
    const auto& options = input.options();
    bool prefetched = options.key.prefetch();
    RETURN_IF_EXCEPTION(scope, nullptr);
    RELEASE_ASSERT(prefetched);
    const auto* encoding = options.encoding.convert();
    RETURN_IF_EXCEPTION(scope, nullptr);
    const auto* format = options.format.convert();
    RETURN_IF_EXCEPTION(scope, nullptr);
    const auto* keyObject = options.key.convert();
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!keyObject || !encoding || !format)
        return nullptr;

    const auto stringEncoding = encoding->has_value()
        ? nodeEncodingToBufferEncoding(**encoding)
        : BufferEncodingType::utf8;
    const auto keyFormat = format->value_or(Bindgen::NodeCryptoAsymmetricKeyFormat::pem);
    if (!keyObject->is_other()) {
        const auto& key = *keyObject;
        if (key.is_key_object())
            return checkedAsymmetricKeyData(globalObject, scope, key.key_object(), mode);
        RELEASE_ASSERT(key.is_crypto_key());
        return checkedAsymmetricCryptoKeyData(globalObject, scope, key.crypto_key(), mode);
    }
    if (keyFormat == Bindgen::NodeCryptoAsymmetricKeyFormat::jwk) {
        const auto* jwk = options.jwk_key.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!jwk)
            return nullptr;
        return keyObjectFromTypedJwk(globalObject, scope, *jwk, mode).data();
    }

    auto prepareEncoded = [&](const auto& field, const auto& shape) -> RefPtr<KeyObjectData> {
        const auto* classified = shape.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!classified)
            return nullptr;
        const auto* type = options.type.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!type)
            return nullptr;
        auto encodingType = typedAsymmetricKeyEncoding(globalObject, scope, *type, keyFormat, mode);
        RETURN_IF_EXCEPTION(scope, nullptr);
        const auto* passphraseValue = options.passphrase.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!passphraseValue)
            return nullptr;

        std::optional<DataPointer> passphrase;
        if (passphraseValue->has_value()) {
            const auto& value = **passphraseValue;
            if (value.is_buffer()) {
                auto copied = DataPointer::FromSpan(value.buffer());
                if (!value.buffer().empty() && !copied) {
                    JSC::throwOutOfMemoryError(globalObject, scope);
                    return nullptr;
                }
                passphrase = WTF::move(copied);
            } else {
                RELEASE_ASSERT(value.is_string());
                auto* encoded = encodeCryptoString(globalObject, scope, value.string(), stringEncoding);
                RETURN_IF_EXCEPTION(scope, nullptr);
                auto copied = DataPointer::FromSpan(encoded->span());
                if (encoded->byteLength() && !copied) {
                    JSC::throwOutOfMemoryError(globalObject, scope);
                    return nullptr;
                }
                passphrase = WTF::move(copied);
            }
        }

        const auto* material = field.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!material)
            return nullptr;

        return prepareTypedAsymmetricKeyMaterial(
            globalObject,
            scope,
            *material,
            mode,
            stringEncoding,
            keyFormat,
            encodingType,
            WTF::move(passphrase));
    };
    return mode == PrepareAsymmetricKeyMode::CreatePrivate
        ? prepareEncoded(options.private_material, options.private_shape)
        : prepareEncoded(options.material, options.material_shape);
}

template<typename Visit>
static void visitPendingAsymmetricKeyDeferred(const Bindgen::NodeCryptoAsymmetricKeyInput& input, Visit&& visit)
{
    if (!input.is_options())
        return;
    const auto& options = input.options();
    RELEASE_ASSERT(!Bindgen::deferredPending(options.key));
    const auto* keyObject = options.key.convert();
    RELEASE_ASSERT(keyObject);
    const auto* format = options.format.convert();
    RELEASE_ASSERT(format);
    if (keyObject->is_other() && format->value_or(Bindgen::NodeCryptoAsymmetricKeyFormat::pem) == Bindgen::NodeCryptoAsymmetricKeyFormat::jwk) {
        const auto* convertedJwk = options.jwk_key.convert();
        RELEASE_ASSERT(convertedJwk);
        const auto& jwk = *convertedJwk;
        visit(jwk.kty);
        visit(jwk.crv);
        visit(jwk.okp_crv);
        visit(jwk.x);
        visit(jwk.y);
        visit(jwk.d);
        visit(jwk.n);
        visit(jwk.e);
        visit(jwk.p);
        visit(jwk.q);
        visit(jwk.dp);
        visit(jwk.dq);
        visit(jwk.qi);
    }
    visit(options.key);
    visit(options.jwk_key);
    visit(options.private_shape);
    visit(options.material_shape);
    visit(options.private_material);
    visit(options.material);
    visit(options.encoding);
    visit(options.format);
    visit(options.type);
    visit(options.passphrase);
    visit(options.padding);
    visit(options.salt_length);
    visit(options.dsa_encoding);
    visit(options.oaep_hash);
    visit(options.oaep_label);
}

void KeyObject::discardAsymmetricKeyDeferred(const Bindgen::NodeCryptoAsymmetricKeyInput& input)
{
    visitPendingAsymmetricKeyDeferred(input, [](const auto& value) {
        Bindgen::discardDeferred(value);
    });
}

void KeyObject::discardAsymmetricKeyDeferredAndMaybeYieldProof(
    const Bindgen::NodeCryptoAsymmetricKeyInput& input,
    Bindgen::CppDeferredLeaseProof& proof)
{
    visitPendingAsymmetricKeyDeferred(input, [&proof](const auto& value) {
        Bindgen::discardDeferredAndMaybeYieldProof(value, proof);
    });
}

}
