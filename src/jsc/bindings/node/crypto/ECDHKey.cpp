#include "config.h"
#include "ECDHKey.h"

namespace Bun {

static auto ecdhFailure(ECDHError::Code code, uint32_t cryptoCode = 0)
{
    return std::unexpected(ECDHError { code, cryptoCode });
}

static ECDHKey::Result<int> curveNid(const WTF::String& curve)
{
    auto name = curve.tryGetUTF8();
    if (!name)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    int nid = OBJ_sn2nid(name->data());
    if (nid == NID_undef)
        return ecdhFailure(ECDHError::Code::invalidCurve);
    return nid;
}

ECDHKey::Result<ncrypto::ECKeyPointer> ECDHKey::create(const WTF::String& curve)
{
    auto nid = curveNid(curve);
    if (!nid)
        return std::unexpected(nid.error());
    auto key = ncrypto::ECKeyPointer::NewByCurveName(*nid);
    if (!key)
        return ecdhFailure(ECDHError::Code::createKey, ERR_get_error());
    return key;
}

ECDHKey::Result<ncrypto::ECKeyPointer> ECDHKey::generateCandidate() const
{
    auto key = m_key.clone();
    if (!key)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!key.generate())
        return ecdhFailure(ECDHError::Code::generateKey, ERR_get_error());
    return key;
}

static ECDHKey::Result<WTF::Vector<uint8_t>> encodePoint(const EC_GROUP* group, const EC_POINT* point, point_conversion_form_t form)
{
    size_t size = EC_POINT_point2oct(group, point, form, nullptr, 0, nullptr);
    if (!size)
        return ecdhFailure(ECDHError::Code::publicKeySize, ERR_get_error());
    WTF::Vector<uint8_t> bytes;
    if (!bytes.tryGrow(size))
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!EC_POINT_point2oct(group, point, form, bytes.mutableSpan().data(), size, nullptr))
        return ecdhFailure(ECDHError::Code::encodePublicKey, ERR_get_error());
    return bytes;
}

ECDHKey::Result<WTF::Vector<uint8_t>> ECDHKey::publicKey(const ncrypto::ECKeyPointer& key, point_conversion_form_t form)
{
    auto* point = key.getPublicKey();
    if (!point)
        return ecdhFailure(ECDHError::Code::missingPublicKey);
    return encodePoint(key.getGroup(), point, form);
}

ECDHKey::Result<WTF::Vector<uint8_t>> ECDHKey::privateKey() const
{
    const auto* key = m_key.getPrivateKey();
    if (!key)
        return ecdhFailure(ECDHError::Code::missingPrivateKey);
    size_t size = ncrypto::BignumPointer::GetByteCount(key);
    WTF::Vector<uint8_t> bytes;
    if (!bytes.tryGrow(size))
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (ncrypto::BignumPointer::EncodePaddedInto(key, bytes.mutableSpan().data(), size) != size)
        return ecdhFailure(ECDHError::Code::encodePrivateKey);
    return bytes;
}

ECDHKey::Result<WTF::Vector<uint8_t>> ECDHKey::computeSecret(std::span<const uint8_t> peer) const
{
    if (!m_key.checkKey())
        return ecdhFailure(ncrypto::takeAllocationFailure() ? ECDHError::Code::outOfMemory : ECDHError::Code::invalidKeyPair);
    auto point = ncrypto::ECPointPointer::New(m_key.getGroup());
    if (!point)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!point.setFromBuffer({ peer.data(), peer.size() }, m_key.getGroup()))
        return ecdhFailure(ncrypto::takeAllocationFailure() ? ECDHError::Code::outOfMemory : ECDHError::Code::invalidPeerKey);
    int bits = EC_GROUP_get_degree(m_key.getGroup());
    RELEASE_ASSERT(bits > 0);
    WTF::Vector<uint8_t> secret;
    if (!secret.tryGrow((static_cast<size_t>(bits) + 7) / 8))
        return ecdhFailure(ECDHError::Code::outOfMemory);
    int written = ECDH_compute_key(secret.mutableSpan().data(), secret.size(), point, m_key.get(), nullptr);
    if (written <= 0)
        return ecdhFailure(ECDHError::Code::computeSecret, ERR_get_error());
    RELEASE_ASSERT(static_cast<size_t>(written) <= secret.size());
    secret.shrink(static_cast<size_t>(written));
    return secret;
}

ECDHKey::Result<void> ECDHKey::setPublicKey(std::span<const uint8_t> bytes)
{
    auto point = ncrypto::ECPointPointer::New(m_key.getGroup());
    if (!point)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!point.setFromBuffer({ bytes.data(), bytes.size() }, m_key.getGroup()))
        return ecdhFailure(ECDHError::Code::decodePublicKey, ERR_get_error());
    auto key = m_key.clone();
    if (!key)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!key.setPublicKey(point))
        return ecdhFailure(ECDHError::Code::setPublicKey, ERR_get_error());
    commit(WTF::move(key));
    return {};
}

ECDHKey::Result<void> ECDHKey::setPrivateKey(std::span<const uint8_t> bytes)
{
    ncrypto::BignumPointer scalar(bytes.data(), bytes.size());
    if (!scalar)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    const auto* order = EC_GROUP_get0_order(m_key.getGroup());
    if (BN_is_zero(scalar.get()) || BN_is_negative(scalar.get()) || !order || BN_cmp(scalar.get(), order) >= 0)
        return ecdhFailure(ECDHError::Code::invalidPrivateKey);
    auto key = m_key.clone();
    if (!key)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!key.setPrivateKey(scalar))
        return ecdhFailure(ECDHError::Code::setPrivateKey, ERR_get_error());
    auto point = ncrypto::ECPointPointer::New(key.getGroup());
    if (!point)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!point.mul(key.getGroup(), key.getPrivateKey()))
        return ecdhFailure(ECDHError::Code::derivePublicKey, ERR_get_error());
    if (!key.setPublicKey(point))
        return ecdhFailure(ECDHError::Code::setPublicKey, ERR_get_error());
    commit(WTF::move(key));
    return {};
}

ECDHKey::Result<WTF::Vector<uint8_t>> ECDHKey::convertKey(const WTF::String& curve, std::span<const uint8_t> bytes, point_conversion_form_t form)
{
    auto nid = curveNid(curve);
    if (!nid)
        return std::unexpected(nid.error());
    auto group = ncrypto::ECGroupPointer::NewByCurveName(*nid);
    if (!group)
        return ecdhFailure(ECDHError::Code::createGroup, ERR_get_error());
    auto point = ncrypto::ECPointPointer::New(group);
    if (!point)
        return ecdhFailure(ECDHError::Code::outOfMemory);
    if (!point.setFromBuffer({ bytes.data(), bytes.size() }, group))
        return ecdhFailure(ECDHError::Code::convertPoint, ERR_get_error());
    return encodePoint(group, point, form);
}

}
