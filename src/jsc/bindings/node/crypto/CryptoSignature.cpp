#include "config.h"
#include "CryptoSignature.h"

namespace Bun {

static auto failure(SignatureError::Code code, uint32_t cryptoCode = 0)
{
    return std::unexpected(SignatureError { code, cryptoCode });
}

using Error = SignatureError::Code;

StreamingSignature::Result<void> StreamingSignature::init(const EVP_MD* digest)
{
    auto context = ncrypto::EVPMDCtxPointer::New();
    if (!context)
        return failure(Error::digestCreation);
    if (!context.digestInit(digest))
        return failure(Error::digestInitialization);
    m_digest = WTF::move(context);
    return {};
}

StreamingSignature::Result<void> StreamingSignature::update(std::span<const uint8_t> input)
{
    if (!m_digest.digestUpdate({ .data = input.data(), .len = input.size() }))
        return failure(Error::digestUpdate, ERR_get_error());
    return {};
}

StreamingSignature::Result<StreamingSignature::Prepared> StreamingSignature::prepare(const ncrypto::EVPKeyPointer& key, bool signing, int padding, std::optional<int> saltLength)
{
    if (signing && !m_digest)
        return failure(Error::notInitialized);

    auto context = WTF::move(m_digest);
    if (!key.validateDsaParameters())
        return failure(Error::dsaParameters);
    auto digest = context.digestFinal(context.getExpectedSize());
    if (!digest)
        return failure(Error::digestFinalization);

    auto keyContext = key.newCtx();
    if (!keyContext || (signing ? keyContext.initForSign() : keyContext.initForVerify()) <= 0)
        return failure(signing ? Error::signInitialization : Error::verifyInitialization, ERR_peek_error());

    if (signing && !keyContext.setSignatureMd(context))
        return failure(Error::signatureDigest, ERR_peek_error());
    if (key.isRsaVariant()) {
        // Node uses AUTO for PSS when no salt length is supplied.
        if (padding == RSA_PKCS1_PSS_PADDING && !saltLength)
            saltLength = RSA_PSS_SALTLEN_AUTO;
        if (!ncrypto::EVPKeyCtxPointer::setRsaPadding(keyContext.get(), padding, saltLength))
            return failure(Error::rsaPadding, ERR_peek_error());
    }
    if (!signing && !keyContext.setSignatureMd(context))
        return failure(Error::signatureDigest, ERR_peek_error());
    return Prepared { WTF::move(digest), WTF::move(keyContext) };
}

StreamingSignature::Result<WTF::Vector<uint8_t>> StreamingSignature::sign(const ncrypto::EVPKeyPointer& key, DSASigEnc encoding, int padding, std::optional<int> saltLength)
{
    auto prepared = prepare(key, true, padding, saltLength);
    if (!prepared)
        return std::unexpected(prepared.error());

    WTF::Vector<uint8_t> signature;
    if (!signature.tryGrow(key.size()))
        return failure(Error::signatureAllocation);
    ncrypto::Buffer<unsigned char> buffer { .data = signature.mutableSpan().data(), .len = signature.size() };
    if (!prepared->context.signInto(prepared->digest, &buffer))
        return failure(Error::signing);
    signature.shrink(buffer.len);

    if (encoding == DSASigEnc::P1363 && key.isSigVariant()) {
        auto size = key.getBytesOfRS().value_or(0) * 2;
        if (size) {
            WTF::Vector<uint8_t> converted;
            if (!converted.tryGrow(size))
                return failure(Error::p1363Allocation);
            ncrypto::Buffer<const unsigned char> der { .data = signature.span().data(), .len = signature.size() };
            if (!ncrypto::extractP1363(der, converted.mutableSpan().data(), size / 2))
                return failure(Error::p1363Conversion);
            return converted;
        }
    }
    return signature;
}

StreamingSignature::Result<bool> StreamingSignature::verify(const ncrypto::EVPKeyPointer& key, DSASigEnc encoding, int padding, std::optional<int> saltLength, std::span<const uint8_t> signature)
{
    auto prepared = prepare(key, false, padding, saltLength);
    if (!prepared)
        return std::unexpected(prepared.error());

    ncrypto::Buffer<const unsigned char> buffer { .data = signature.data(), .len = signature.size() };
    WTF::Vector<uint8_t> der;
    if (encoding == DSASigEnc::P1363 && key.isSigVariant()) {
        switch (convertP1363ToDER(buffer, key, der)) {
        case SignatureConversionResult::out_of_memory:
            return failure(Error::outOfMemory);
        case SignatureConversionResult::invalid:
            return false;
        case SignatureConversionResult::converted:
            buffer = { .data = der.span().data(), .len = der.size() };
            break;
        }
    }
    return prepared->context.verify(buffer, prepared->digest);
}

SignatureConversionResult convertP1363ToDER(const ncrypto::Buffer<const unsigned char>& p1363Sig,
    const ncrypto::EVPKeyPointer& pkey,
    WTF::Vector<uint8_t>& derBuffer)
{
    auto bytesOfRS = pkey.getBytesOfRS();
    if (!bytesOfRS || !*bytesOfRS || p1363Sig.len % 2 || p1363Sig.len / 2 != *bytesOfRS)
        return SignatureConversionResult::invalid;
    size_t bytesOfRSValue = *bytesOfRS;

    ncrypto::BignumPointer r(p1363Sig.data, bytesOfRSValue);
    if (!r)
        return SignatureConversionResult::out_of_memory;

    ncrypto::BignumPointer s(p1363Sig.data + bytesOfRSValue, bytesOfRSValue);
    if (!s)
        return SignatureConversionResult::out_of_memory;

    auto asn1_sig = ncrypto::ECDSASigPointer::New();
    if (!asn1_sig)
        return SignatureConversionResult::out_of_memory;
    RELEASE_ASSERT(asn1_sig.setParams(WTF::move(r), WTF::move(s)));

    auto buf = asn1_sig.encode();
    if (!buf)
        return SignatureConversionResult::out_of_memory;
    WTF::Vector<uint8_t> result;
    if (!result.tryAppend(buf.span()))
        return SignatureConversionResult::out_of_memory;
    derBuffer = WTF::move(result);
    return SignatureConversionResult::converted;
}

}
