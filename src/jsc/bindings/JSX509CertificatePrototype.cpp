

#include "root.h"

#include "JSDOMExceptionHandling.h"
#include "ZigGlobalObject.h"
#include "ncrypto.h"
#include "JSX509Certificate.h"
#include "JSX509CertificatePrototype.h"
#include "ErrorCode.h"

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include "webcrypto/CryptoKeyEC.h"
#include "webcrypto/CryptoKeyRSA.h"
#include "webcrypto/CryptoKeyOKP.h"
#include "webcrypto/CryptoKeyAES.h"
#include "wtf/DateMath.h"
#include "AsymmetricKeyValue.h"
#include <JavaScriptCore/DateInstance.h>
#include "JSKeyObject.h"
#include "SchemaBindings.h"
#include "StringConversion.h"

#include <cstring>
#include <span>

namespace Bun {

using namespace JSC;

#define BUN_BINDGEN_OBJECT_SURFACE_JSX509CertificatePrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSX509CertificatePrototype

const ClassInfo JSX509CertificatePrototype::s_info = { "X509Certificate"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSX509CertificatePrototype) };

void JSX509CertificatePrototype::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSX509CertificatePrototype_install(vm, JSX509Certificate::info(), *this);
}

static JSX509Certificate* x509Certificate(JSC::JSValue value)
{
    auto* certificate = dynamicDowncast<JSX509Certificate>(value);
    RELEASE_ASSERT(certificate);
    return certificate;
}

static JSKeyObject* keyObject(JSC::JSValue value)
{
    auto* key = dynamicDowncast<JSKeyObject>(value);
    RELEASE_ASSERT(key);
    return key;
}

WTF::String Bindgen::Cpp::bunBindgenCpp_X509_certificateToString(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateToString_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    String pemString = x509Certificate(args.bindingThis)->toPEMString();
    RETURN_IF_EXCEPTION(scope, {});
    return pemString;
}

static uint32_t x509CheckFlags(const std::optional<Bun::Bindgen::X509CheckOptions>& input)
{
    if (!input)
        return 0;
    const auto& options = *input;

    uint32_t flags = 0;
    switch (options.subject) {
    case Bun::Bindgen::X509CheckSubject::default_:
        break;
    case Bun::Bindgen::X509CheckSubject::always:
        flags |= X509_CHECK_FLAG_ALWAYS_CHECK_SUBJECT;
        break;
    case Bun::Bindgen::X509CheckSubject::never:
        flags |= X509_CHECK_FLAG_NEVER_CHECK_SUBJECT;
        break;
    }
    if (!options.wildcards)
        flags |= X509_CHECK_FLAG_NO_WILDCARDS;
    if (!options.partialWildcards)
        flags |= X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS;
    if (options.multiLabelWildcards)
        flags |= X509_CHECK_FLAG_MULTI_LABEL_WILDCARDS;
    if (options.singleLabelSubdomains)
        flags |= X509_CHECK_FLAG_SINGLE_LABEL_SUBDOMAINS;

    return flags;
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_X509_certificateCheckEmail(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateCheckEmail_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    uint32_t flags = x509CheckFlags(args.options);

    auto email = encodeUTF8ReplacingInvalidSequences(args.email);
    if (!email) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto check = x509Certificate(args.bindingThis)->checkEmail(globalObject, { reinterpret_cast<const char*>(email->span().data()), email->size() }, flags);
    RETURN_IF_EXCEPTION(scope, {});
    if (!check) return std::nullopt;
    return args.email;
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_X509_certificateCheckHost(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateCheckHost_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    uint32_t flags = x509CheckFlags(args.options);

    auto host = encodeUTF8ReplacingInvalidSequences(args.host);
    if (!host) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto check = x509Certificate(args.bindingThis)->checkHost(globalObject, { reinterpret_cast<const char*>(host->span().data()), host->size() }, flags);
    RETURN_IF_EXCEPTION(scope, {});
    if (!check) return std::nullopt;
    return args.host;
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_X509_certificateCheckIP(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateCheckIP_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto ip = encodeUTF8ReplacingInvalidSequences(args.ip, UTF8Termination::Null);
    if (!ip) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto check = x509Certificate(args.bindingThis)->checkIP(globalObject, reinterpret_cast<const char*>(ip->span().data()), x509CheckFlags(args.options));
    RETURN_IF_EXCEPTION(scope, {});
    if (!check) return std::nullopt;
    return args.ip;
}

bool Bindgen::Cpp::bunBindgenCpp_X509_certificateCheckIssued(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateCheckIssued_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto check = x509Certificate(args.bindingThis)->checkIssued(globalObject, x509Certificate(args.issuer));
    RETURN_IF_EXCEPTION(scope, false);
    return check;
}

bool Bindgen::Cpp::bunBindgenCpp_X509_certificateCheckPrivateKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateCheckPrivateKey_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* privateKey = keyObject(args.privateKey);
    if (privateKey->handle().type() != CryptoKeyType::Private) {
        ERR::INVALID_ARG_VALUE(scope, globalObject, "pkey"_s, args.privateKey);
        return false;
    }
    scope.release();
    return x509Certificate(args.bindingThis)->checkPrivateKey(privateKey->handle());
}

WTF::String Bindgen::Cpp::bunBindgenCpp_X509_certificateToJSON(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateToJSON_Arguments& args)
{
    // There's no standardized JSON encoding for X509 certs so we
    // fallback to providing the PEM encoding as a string.
    return x509Certificate(args.bindingThis)->toPEMString();
}

static std::optional<JSValue> optionalIfEmpty(JSString* value)
{
    if (!value || value->length() == 0)
        return std::nullopt;
    return value;
}

bool Bindgen::Cpp::bunBindgenCpp_X509_certificateVerify(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateVerify_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* publicKey = keyObject(args.publicKey);
    if (publicKey->handle().type() != CryptoKeyType::Public) {
        ERR::INVALID_ARG_VALUE(scope, globalObject, "pkey"_s, args.publicKey);
        return false;
    }
    scope.release();
    return x509Certificate(args.bindingThis)->verify(publicKey->handle());
}

bool Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_ca(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_ca_Arguments& args)
{
    return x509Certificate(args.bindingThis)->view().isCA();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_fingerprint(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_fingerprint_Arguments& args)
{
    return x509Certificate(args.bindingThis)->fingerprint();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_fingerprint256(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_fingerprint256_Arguments& args)
{
    return x509Certificate(args.bindingThis)->fingerprint256();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_fingerprint512(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_fingerprint512_Arguments& args)
{
    return x509Certificate(args.bindingThis)->fingerprint512();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_subject(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_subject_Arguments& args)
{
    return x509Certificate(args.bindingThis)->subject();
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_subjectAltName(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_subjectAltName_Arguments& args)
{
    return optionalIfEmpty(x509Certificate(args.bindingThis)->subjectAltName());
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_infoAccess(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_infoAccess_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto bio = x509Certificate(args.bindingThis)->view().getInfoAccess();
    if (!bio)
        return std::nullopt;

    BUF_MEM* bptr = bio;
    if (!bptr)
        return std::nullopt;
    return optionalIfEmpty(jsString(vm, String::fromUTF8(std::span(bptr->data, bptr->length))));
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_keyUsage(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_keyUsage_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = x509Certificate(args.bindingThis)->getKeyUsage(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    scope.release();
    if (result.isUndefined())
        return std::nullopt;
    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_issuer(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_issuer_Arguments& args)
{
    return x509Certificate(args.bindingThis)->issuer();
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_issuerCertificate(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_issuerCertificate_Arguments&)
{
    // issuerCertificate is only available when the certificate was obtained from
    // a TLS connection with a peer certificate chain. For certificates parsed
    // directly from PEM/DER data, it is always undefined (matching Node.js behavior).
    return std::nullopt;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_publicKey(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_publicKey_Arguments& args)
{
    return x509Certificate(args.bindingThis)->publicKey();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_raw(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_raw_Arguments& args)
{
    return x509Certificate(args.bindingThis)->raw();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_serialNumber(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_serialNumber_Arguments& args)
{
    return x509Certificate(args.bindingThis)->serialNumber();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_validFrom(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_validFrom_Arguments& args)
{
    return x509Certificate(args.bindingThis)->validFrom();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_validTo(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_validTo_Arguments& args)
{
    return x509Certificate(args.bindingThis)->validTo();
}

static JSC::JSValue parseCertificateDate(JSC::JSGlobalObject* globalObject, JSC::JSString* string)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    RETURN_IF_EXCEPTION(scope, {});
    auto view = string->view(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto bytes = encodeUTF8ReplacingInvalidSequences(view);
    JSC::ensureStillAliveHere(string);
    if (!bytes) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    double date = WTF::parseDate(bytes->span());
    return JSC::DateInstance::create(vm, globalObject->dateStructure(), date);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_validToDate(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_validToDate_Arguments& args)
{
    return parseCertificateDate(&context.globalObject, x509Certificate(args.bindingThis)->validTo());
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateGetter_validFromDate(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateGetter_validFromDate_Arguments& args)
{
    return parseCertificateDate(&context.globalObject, x509Certificate(args.bindingThis)->validFrom());
}
} // namespace Bun
