#include "config.h"

#include "SchemaBindings.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/ArrayConstructor.h"
#include "libusockets.h"

#include "ZigGlobalObject.h"
#include "ErrorCode.h"
#include "openssl/base.h"
#include "openssl/bio.h"
#include "openssl/x509.h"
#include "../../packages/bun-usockets/src/crypto/root_certs_header.h"

namespace Bun {

using namespace JSC;

WTF::Vector<WTF::String> Bindgen::Cpp::bunBindgenCpp_TLSCertificates_getBundled(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_TLSCertificates_getBundled_Arguments&)
{
    struct us_cert_string_t* out;
    auto size = us_raw_root_certs(&out);
    if (size < 0) {
        return {};
    }

    WTF::Vector<WTF::String> rootCertificates;
    rootCertificates.reserveInitialCapacity(size);
    for (auto i = 0; i < size; i++) {
        auto raw = out[i];
        rootCertificates.append(WTF::String::fromUTF8(std::span { raw.str, raw.len }));
    }

    return rootCertificates;
}

WTF::Vector<WTF::String> Bindgen::Cpp::bunBindgenCpp_TLSCertificates_getExtra(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_TLSCertificates_getExtra_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    STACK_OF(X509)* root_extra_cert_instances = us_get_root_extra_cert_instances();

    auto size = sk_X509_num(root_extra_cert_instances);
    if (size < 0) size = 0;

    WTF::Vector<WTF::String> rootCertificates;
    rootCertificates.reserveInitialCapacity(size);
    for (auto i = 0; i < size; i++) {
        BIO* bio = BIO_new(BIO_s_mem());
        if (!bio) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }

        if (PEM_write_bio_X509(bio, sk_X509_value(root_extra_cert_instances, i)) != 1) {
            BIO_free(bio);
            throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "X509 to PEM conversion"_str);
            return {};
        }

        char* bioData = nullptr;
        long bioLen = BIO_get_mem_data(bio, &bioData);
        if (bioLen <= 0 || !bioData) {
            BIO_free(bio);
            throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Reading PEM data"_str);
            return {};
        }

        rootCertificates.append(WTF::String::fromUTF8(std::span { bioData, static_cast<size_t>(bioLen) }));
        BIO_free(bio);
    }

    return rootCertificates;
}

WTF::Vector<WTF::String> Bindgen::Cpp::bunBindgenCpp_TLSCertificates_getSystem(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_TLSCertificates_getSystem_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    STACK_OF(X509)* root_system_cert_instances = us_get_root_system_cert_instances();

    auto size = sk_X509_num(root_system_cert_instances);
    if (size < 0) size = 0;

    WTF::Vector<WTF::String> rootCertificates;
    rootCertificates.reserveInitialCapacity(size);
    for (auto i = 0; i < size; i++) {
        BIO* bio = BIO_new(BIO_s_mem());
        if (!bio) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        X509* cert = sk_X509_value(root_system_cert_instances, i);
        if (!cert) {
            BIO_free(bio);
            continue;
        }
        if (!PEM_write_bio_X509(bio, cert)) {
            BIO_free(bio);
            continue;
        }

        char* bioData;
        long bioLen = BIO_get_mem_data(bio, &bioData);
        if (bioLen <= 0) {
            BIO_free(bio);
            continue;
        }

        rootCertificates.append(WTF::String::fromUTF8(std::span { bioData, static_cast<size_t>(bioLen) }));
        BIO_free(bio);
    }

    return rootCertificates;
}

} // namespace Bun
