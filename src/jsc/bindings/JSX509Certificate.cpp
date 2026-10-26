#include "root.h"

#include "SchemaBindings.h"
#include "JavaScriptCore/ArrayAllocationProfile.h"
#include "JavaScriptCore/JSArray.h"

#include "ncrypto.h"
#include "openssl/x509.h"
#include "JavaScriptCore/InternalFunction.h"
#include "ErrorCode.h"
#include "JSX509Certificate.h"
#include "JSX509CertificatePrototype.h"
#include "StringConversion.h"
#include "ZigGlobalObject.h"
#include "wtf/Assertions.h"
#include "wtf/SharedTask.h"
#include "wtf/text/ASCIILiteral.h"

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ObjectConstructor.h>

#include <JavaScriptCore/LazyPropertyInlines.h>
#include "openssl/evp.h"
#include "JavaScriptCore/ObjectPrototype.h"
#include <JavaScriptCore/FunctionPrototype.h>
#include "JSBuffer.h"
#include "wtf/text/ExternalStringImpl.h"
#include <wtf/SIMDUTF.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include "CryptoUtil.h"
#include "JSPublicKeyObject.h"

#include <algorithm>
#include <type_traits>
#include <utility>

namespace Bun {

using namespace JSC;

Ref<WTF::ExternalStringImpl> toExternalStringImpl(ncrypto::BIOPointer& bio, std::span<const char> span)
{
    return WTF::ExternalStringImpl::create({ reinterpret_cast<const Latin1Character*>(span.data()), span.size() }, bio.release(), [](void* context, void* ptr, unsigned len) {
        ncrypto::BIOPointer deleter = ncrypto::BIOPointer(static_cast<BIO*>(context));
    });
}

WTF::String toWTFString(ncrypto::BIOPointer& bio)
{
    BUF_MEM* bptr;
    BIO_get_mem_ptr(bio.get(), &bptr);
    std::span<const char> span(bptr->data, bptr->length);
    if (simdutf::validate_ascii(span.data(), span.size())) {
        return toExternalStringImpl(bio, span);
    }
    return WTF::String::fromUTF8({ reinterpret_cast<const Latin1Character*>(bptr->data), bptr->length });
}

class JSX509CertificateConstructor final : public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static JSX509CertificateConstructor* create(JSC::VM&, JSC::JSGlobalObject*, JSC::Structure*, JSC::JSObject* prototype);

    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return &vm.internalFunctionSpace();
    }

    DECLARE_INFO;

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
    }

private:
    JSX509CertificateConstructor(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure, bun_bindgen_host_X509_certificateConstructorCall, bun_bindgen_host_X509_certificateConstructorConstruct)
    {
    }

    void finishCreation(JSC::VM&, JSC::JSGlobalObject*, JSC::JSObject* prototype);
};

const ClassInfo JSX509CertificateConstructor::s_info = { "X509Certificate"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSX509CertificateConstructor) };

JSX509CertificateConstructor* JSX509CertificateConstructor::create(VM& vm, JSGlobalObject* globalObject, Structure* structure, JSObject* prototype)
{
    JSX509CertificateConstructor* constructor = new (NotNull, allocateCell<JSX509CertificateConstructor>(vm)) JSX509CertificateConstructor(vm, structure);
    constructor->finishCreation(vm, globalObject, prototype);
    return constructor;
}

void JSX509CertificateConstructor::finishCreation(VM& vm, JSGlobalObject* globalObject, JSObject* prototype)
{
    Base::finishCreation(vm, 1, "X509Certificate"_s, PropertyAdditionMode::WithStructureTransition);
    putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
}
static JSValue createX509Certificate(JSC::VM& vm, JSGlobalObject* globalObject, Structure* structure, std::span<const uint8_t> data)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSX509Certificate* certificate = JSX509Certificate::create(vm, structure, globalObject, data);
    RETURN_IF_EXCEPTION(scope, {});
    return certificate;
}

void Bindgen::Cpp::bunBindgenCpp_X509_certificateConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateConstructorCall_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    Bun::throwError(globalObject, scope, ErrorCode::ERR_ILLEGAL_CONSTRUCTOR, "X509Certificate constructor cannot be invoked without 'new'"_s);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_X509_certificateConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateConstructorConstruct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.input) {
        Bun::throwError(globalObject, scope, ErrorCode::ERR_MISSING_ARGS, "X509Certificate constructor requires at least one argument"_s);
        return {};
    }

    WTF::Vector<uint8_t> encodedInput;
    std::span<const uint8_t> bytes;
    if (args.input->is_string()) {
        auto encoded = Bun::encodeUTF8ReplacingInvalidSequences(args.input->string());
        if (!encoded) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        encodedInput = WTF::move(*encoded);
        bytes = encodedInput;
    } else {
        RELEASE_ASSERT(args.input->is_buffer());
        bytes = args.input->buffer();
    }

    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    auto* newTarget = JSC::asObject(args.bindingNewTarget);
    Structure* structure = zigGlobalObject->m_JSX509CertificateClassStructure.get(zigGlobalObject);
    if (zigGlobalObject->m_JSX509CertificateClassStructure.constructor(zigGlobalObject) != newTarget) [[unlikely]] {
        auto* functionGlobalObject = defaultGlobalObject(getFunctionRealm(globalObject, newTarget));
        RETURN_IF_EXCEPTION(scope, {});
        structure = InternalFunction::createSubclassStructure(globalObject, newTarget, functionGlobalObject->m_JSX509CertificateClassStructure.get(functionGlobalObject));
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_AND_RETURN(scope, createX509Certificate(vm, globalObject, structure, bytes));
}

const ClassInfo JSX509Certificate::s_info = { "X509Certificate"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSX509Certificate) };

void JSX509Certificate::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));

    m_fingerprint.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.set(init.owner->computeFingerprint(init.owner->view(), init.owner->globalObject()));
    });
    m_subject.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        auto scope = DECLARE_THROW_SCOPE(init.vm);
        auto value = init.owner->computeSubject(init.owner->view(), init.owner->globalObject());
        if (scope.exception()) [[unlikely]] {
            (void)scope.tryClearException();
            return init.set(jsEmptyString(init.vm));
        }
        if (!value.isString()) {
            init.set(jsEmptyString(init.owner->vm()));
            return;
        }

        init.set(value.toString(init.owner->globalObject()));
    });
    m_issuer.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        auto scope = DECLARE_THROW_SCOPE(init.vm);
        JSValue value = init.owner->computeIssuer(init.owner->view(), init.owner->globalObject());
        if (scope.exception()) [[unlikely]] {
            (void)scope.tryClearException();
            return init.set(jsEmptyString(init.vm));
        }
        if (value.isString()) {
            init.set(value.toString(init.owner->globalObject()));
        } else {
            init.set(jsEmptyString(init.owner->vm()));
        }
    });
    m_validFrom.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.set(init.owner->computeValidFrom(init.owner->view(), init.owner->globalObject()));
    });
    m_validTo.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.set(init.owner->computeValidTo(init.owner->view(), init.owner->globalObject()));
    });
    m_serialNumber.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.set(init.owner->computeSerialNumber(init.owner->view(), init.owner->globalObject()));
    });
    m_fingerprint256.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.set(init.owner->computeFingerprint256(init.owner->view(), init.owner->globalObject()));
    });
    m_fingerprint512.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.set(init.owner->computeFingerprint512(init.owner->view(), init.owner->globalObject()));
    });
    m_raw.initLater([](const JSC::LazyProperty<JSX509Certificate, JSUint8Array>::Initializer& init) {
        init.property.setMayBeNull(init.owner->vm(), init.owner, init.owner->computeRaw(init.owner->view(), init.owner->globalObject()));
    });

    m_infoAccess.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        JSValue value = init.owner->computeInfoAccess(init.owner->view(), init.owner->globalObject());
        if (value.isString()) {
            init.set(value.toString(init.owner->globalObject()));
        } else {
            init.property.setMayBeNull(init.owner->vm(), init.owner, nullptr);
        }
    });
    m_subjectAltName.initLater([](const JSC::LazyProperty<JSX509Certificate, JSString>::Initializer& init) {
        init.property.setMayBeNull(init.owner->vm(), init.owner, init.owner->computeSubjectAltName(init.owner->view(), init.owner->globalObject()));
    });

    m_publicKey.initLater([](const JSC::LazyProperty<JSX509Certificate, JSCell>::Initializer& init) {
        JSValue value = init.owner->computePublicKey(init.owner->view(), init.owner->globalObject());
        init.property.setMayBeNull(init.owner->vm(), init.owner, !value.isEmpty() && value.isCell() ? value.asCell() : nullptr);
    });
}

JSX509Certificate* JSX509Certificate::create(VM& vm, Structure* structure)
{
    JSX509Certificate* ptr = new (NotNull, allocateCell<JSX509Certificate>(vm)) JSX509Certificate(vm, structure);
    ptr->finishCreation(vm);
    return ptr;
}

JSX509Certificate* JSX509Certificate::create(JSC::VM& vm, JSC::Structure* structure, JSC::JSGlobalObject* globalObject, std::span<const uint8_t> der)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Initialize the X509 certificate from the provided data
    auto result = ncrypto::X509Pointer::Parse(ncrypto::Buffer<const unsigned char> { reinterpret_cast<const unsigned char*>(der.data()), der.size() });
    if (!result) {
        Bun::throwBoringSSLError(globalObject, scope, result.error.value_or(0));
        return nullptr;
    }

    return create(vm, structure, globalObject, WTF::move(result.value));
}

JSX509Certificate* JSX509Certificate::create(JSC::VM& vm, JSC::Structure* structure, JSC::JSGlobalObject* globalObject, ncrypto::X509Pointer&& cert)
{
    auto* certificate = create(vm, structure);
    certificate->m_x509 = WTF::move(cert);
    size_t size = i2d_X509(certificate->m_x509.get(), nullptr);
    certificate->m_extraMemorySizeForGC = size;
    vm.heap.reportExtraMemoryAllocated(certificate, size);
    return certificate;
}

String JSX509Certificate::toPEMString() const
{
    auto bio = view().toPEM();
    if (!bio) {
        return String();
    }

    return toWTFString(bio);
}

void JSX509Certificate::destroy(JSCell* cell)
{
    static_cast<JSX509Certificate*>(cell)->~JSX509Certificate();
}

JSX509Certificate::~JSX509Certificate()
{
}

template<typename Visitor>
void JSX509Certificate::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSX509Certificate* thisObject = uncheckedDowncast<JSX509Certificate>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);

    thisObject->m_subject.visit(visitor);
    thisObject->m_issuer.visit(visitor);
    thisObject->m_validFrom.visit(visitor);
    thisObject->m_validTo.visit(visitor);
    thisObject->m_serialNumber.visit(visitor);
    thisObject->m_fingerprint.visit(visitor);
    thisObject->m_fingerprint256.visit(visitor);
    thisObject->m_fingerprint512.visit(visitor);
    thisObject->m_raw.visit(visitor);
    thisObject->m_infoAccess.visit(visitor);
    thisObject->m_subjectAltName.visit(visitor);
    thisObject->m_publicKey.visit(visitor);
    visitor.reportExtraMemoryVisited(thisObject->m_extraMemorySizeForGC);
}

DEFINE_VISIT_CHILDREN(JSX509Certificate);

size_t JSX509Certificate::estimatedSize(JSCell* cell, VM& vm)
{
    JSX509Certificate* thisObject = uncheckedDowncast<JSX509Certificate>(cell);
    size_t size = i2d_X509(thisObject->m_x509.get(), nullptr);
    return Base::estimatedSize(cell, vm) + size;
}

void JSX509Certificate::analyzeHeap(JSCell* cell, HeapAnalyzer& analyzer)
{
    Base::analyzeHeap(cell, analyzer);
}

JSC::Structure* JSX509Certificate::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSValue prototype)
{
    return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), info());
}

template<typename Vector, typename Value>
static bool appendX509Result(Vector& vector, Value&& value, JSGlobalObject* globalObject, JSC::ThrowScope& scope)
{
    if (vector.tryAppend(std::forward<Value>(value)))
        return true;
    throwOutOfMemoryError(globalObject, scope);
    return false;
}

template<X509_NAME* get_name(const X509*), typename OptionalRecord>
static bool getX509NameRecord(JSGlobalObject* globalObject, const X509* cert, OptionalRecord& output)
{
    using Record = typename OptionalRecord::value_type;
    using Entry = std::remove_cvref_t<decltype(std::declval<Record>()[0])>;
    using Value = std::remove_cvref_t<decltype(std::declval<Entry>().second)>;

    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    X509_NAME* name = get_name(cert);
    if (!name) {
        output = std::nullopt;
        return true;
    }

    int count = X509_NAME_entry_count(name);
    if (count < 0) {
        output = std::nullopt;
        return true;
    }

    Record result;
    if (!result.tryReserveCapacity(static_cast<size_t>(count))) {
        throwOutOfMemoryError(globalObject, scope);
        return false;
    }

    for (int i = 0; i < count; ++i) {
        X509_NAME_ENTRY* entry = X509_NAME_get_entry(name, i);
        if (!entry)
            continue;

        ASN1_OBJECT* object = X509_NAME_ENTRY_get_object(entry);
        ASN1_STRING* string = X509_NAME_ENTRY_get_data(entry);
        if (!object || !string)
            continue;

        String key;
        int nid = OBJ_obj2nid(object);
        if (nid != NID_undef) {
            if (const char* shortName = OBJ_nid2sn(nid))
                key = String::fromUTF8(shortName);
        }
        if (key.isEmpty()) {
            char buffer[80];
            if (OBJ_obj2txt(buffer, sizeof(buffer), object, 1) >= 0)
                key = String::fromUTF8(buffer);
        }
        if (key.isEmpty())
            continue;

        unsigned char* valueBytes = nullptr;
        int valueLength = ASN1_STRING_to_UTF8(&valueBytes, string);
        if (valueLength < 0)
            continue;
        ncrypto::DataPointer freeValueBytes(valueBytes, valueLength);
        String value = String::fromUTF8(std::span(reinterpret_cast<const char*>(valueBytes), valueLength));

        Value* existing = nullptr;
        for (auto& item : result) {
            if (item.first == key) {
                existing = &item.second;
                break;
            }
        }

        if (!existing) {
            Value first;
            first.set_value(WTF::move(value));
            if (!appendX509Result(result, Entry { WTF::move(key), WTF::move(first) }, globalObject, scope))
                return false;
            continue;
        }

        if (existing->is_value()) {
            WTF::Vector<WTF::String> values;
            if (!values.tryReserveCapacity(2)) {
                throwOutOfMemoryError(globalObject, scope);
                return false;
            }
            if (!appendX509Result(values, WTF::move(existing->value()), globalObject, scope)
                || !appendX509Result(values, WTF::move(value), globalObject, scope))
                return false;
            existing->set_values(WTF::move(values));
        } else if (!appendX509Result(existing->values(), WTF::move(value), globalObject, scope)) {
            return false;
        }
    }

    output = WTF::move(result);
    return true;
}

JSValue JSX509Certificate::computeSubject(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* cert = view.get();
    if (!cert)
        return jsUndefined();

    auto bio = view.getSubject();
    if (!bio) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    return jsString(vm, toWTFString(bio));
}

JSValue JSX509Certificate::computeIssuer(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto bio = view.getIssuer();
    if (!bio) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }

    return jsString(vm, toWTFString(bio));
}

JSString* JSX509Certificate::computeValidFrom(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto bio = view.getValidFrom();
    if (!bio) {
        throwCryptoOperationFailed(globalObject, scope);
        return jsEmptyString(vm);
    }

    return jsString(vm, toWTFString(bio));
}

JSString* JSX509Certificate::computeValidTo(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto bio = view.getValidTo();
    if (!bio) {
        throwCryptoOperationFailed(globalObject, scope);
        return jsEmptyString(vm);
    }

    return jsString(vm, toWTFString(bio));
}

JSString* JSX509Certificate::computeSerialNumber(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto serial = view.getSerialNumber();
    if (!serial) {
        throwCryptoOperationFailed(globalObject, scope);
        return jsEmptyString(vm);
    }

    return jsString(vm, String::fromUTF8(std::span(static_cast<const char*>(serial.get()), serial.size())));
}

JSString* JSX509Certificate::computeFingerprint(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto fingerprint = view.getFingerprint(EVP_sha1());
    if (!fingerprint) {
        throwCryptoOperationFailed(globalObject, scope);
        return jsEmptyString(vm);
    }

    return jsString(vm, fingerprint.value());
}

JSString* JSX509Certificate::computeFingerprint256(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto fingerprint = view.getFingerprint(EVP_sha256());
    if (!fingerprint) {
        throwCryptoOperationFailed(globalObject, scope);
        return jsEmptyString(vm);
    }

    return jsString(vm, fingerprint.value());
}

JSString* JSX509Certificate::computeFingerprint512(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto fingerprint = view.getFingerprint(EVP_sha512());
    if (!fingerprint) {
        throwCryptoOperationFailed(globalObject, scope);
        return jsEmptyString(vm);
    }

    return jsString(vm, fingerprint.value());
}

JSUint8Array* JSX509Certificate::computeRaw(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto bio = view.toDER();
    if (!bio) {
        throwCryptoOperationFailed(globalObject, scope);
        return nullptr;
    }

    BIO* bio_ptr = bio.release();
    BUF_MEM* bptr = nullptr;
    BIO_get_mem_ptr(bio_ptr, &bptr);

    // The ArrayBuffer aliases the BIO's internal buffer; free the BIO (which
    // owns the buffer) when the ArrayBuffer is destroyed. The destructor is
    // invoked with the data pointer (bptr->data), not the BIO, so capture
    // bio_ptr explicitly.
    Ref<JSC::ArrayBuffer> buffer = JSC::ArrayBuffer::createFromBytes(std::span(reinterpret_cast<uint8_t*>(bptr->data), bptr->length), createSharedTask<void(void*)>([bio_ptr](void*) {
        ncrypto::BIOPointer free_me(bio_ptr);
    }));
    RELEASE_AND_RETURN(scope, Bun::createBuffer(globalObject, WTF::move(buffer)));
}

bool JSX509Certificate::computeIsCA(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    return view.isCA();
}

static bool handleMatchResult(JSGlobalObject* globalObject, ASCIILiteral errorMessage, JSC::ThrowScope& scope, ncrypto::X509View::CheckMatch result)
{
    switch (result) {
    case ncrypto::X509View::CheckMatch::INVALID_NAME:
        Bun::throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, errorMessage);
        return false;
    case ncrypto::X509View::CheckMatch::NO_MATCH:
        return false;
    case ncrypto::X509View::CheckMatch::MATCH:
        return true;
    default: {
        throwCryptoOperationFailed(globalObject, scope);
        return false;
    }
    }
}

bool JSX509Certificate::checkHost(JSGlobalObject* globalObject, std::span<const char> name, uint32_t flags)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto result = view().checkHost(name, flags);
    return handleMatchResult(globalObject, "Invalid name"_s, scope, result);
}

bool JSX509Certificate::checkEmail(JSGlobalObject* globalObject, std::span<const char> email, uint32_t flags)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto result = view().checkEmail(email, flags);
    return handleMatchResult(globalObject, "Invalid email"_s, scope, result);
}

bool JSX509Certificate::checkIP(JSGlobalObject* globalObject, const char* ip, uint32_t flags)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto result = view().checkIp(ip, flags);
    return handleMatchResult(globalObject, "Invalid IP address"_s, scope, result);
}

bool JSX509Certificate::checkIssued(JSGlobalObject* globalObject, JSX509Certificate* issuer)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!issuer)
        return false;

    return view().isIssuedBy(issuer->view());
}

JSString* JSX509Certificate::subject()
{
    return m_subject.get(this);
}
JSString* JSX509Certificate::issuer()
{
    return m_issuer.get(this);
}
JSString* JSX509Certificate::validFrom()
{
    return m_validFrom.get(this);
}
JSString* JSX509Certificate::validTo()
{
    return m_validTo.get(this);
}
JSString* JSX509Certificate::serialNumber()
{
    return m_serialNumber.get(this);
}
JSString* JSX509Certificate::fingerprint()
{
    return m_fingerprint.get(this);
}
JSString* JSX509Certificate::fingerprint256()
{
    return m_fingerprint256.get(this);
}
JSString* JSX509Certificate::fingerprint512()
{
    return m_fingerprint512.get(this);
}
JSUint8Array* JSX509Certificate::raw()
{
    return m_raw.get(this);
}
JSString* JSX509Certificate::infoAccess()
{
    return m_infoAccess.get(this);
}
JSString* JSX509Certificate::subjectAltName()
{
    return m_subjectAltName.get(this);
}

JSValue JSX509Certificate::publicKey()
{
    return m_publicKey.get(this);
}

bool JSX509Certificate::checkPrivateKey(const KeyObject& keyObject)
{
    const auto& key = keyObject.asymmetricKey();
    return view().checkPrivateKey(key);
}

bool JSX509Certificate::verify(const KeyObject& keyObject)
{
    const auto& key = keyObject.asymmetricKey();
    return view().checkPublicKey(key);
}

// This one doesn't depend on a JSX509Certificate object
template<typename OptionalRecord>
static bool getX509InfoAccessRecord(JSGlobalObject* globalObject, ncrypto::X509View view, OptionalRecord& output)
{
    using Record = typename OptionalRecord::value_type;
    using Entry = std::remove_cvref_t<decltype(std::declval<Record>()[0])>;

    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto bio = view.getInfoAccess();
    if (!bio) {
        output = std::nullopt;
        return true;
    }

    String info = toWTFString(bio);
    Record result;
    unsigned substringStart = 0;
    while (substringStart < info.length()) {
        auto keyIndex = info.find(':', substringStart);
        if (keyIndex == notFound)
            break;

        auto lineEnd = info.find('\n', keyIndex);
        unsigned valueStart = keyIndex + 1;
        String key = info.substringSharingImpl(substringStart, keyIndex - substringStart);
        String value = lineEnd == notFound
            ? info.substringSharingImpl(valueStart)
            : info.substringSharingImpl(valueStart, lineEnd - valueStart);

        WTF::Vector<WTF::String>* existing = nullptr;
        for (auto& item : result) {
            if (item.first == key) {
                existing = &item.second;
                break;
            }
        }

        if (existing) {
            if (!appendX509Result(*existing, WTF::move(value), globalObject, scope))
                return false;
        } else {
            WTF::Vector<WTF::String> values;
            if (!appendX509Result(values, WTF::move(value), globalObject, scope)
                || !appendX509Result(result, Entry { WTF::move(key), WTF::move(values) }, globalObject, scope))
                return false;
        }

        if (lineEnd == notFound)
            break;
        substringStart = lineEnd + 1;
    }

    output = WTF::move(result);
    return true;
}

template<typename OptionalString>
static void setX509String(OptionalString& output, WTF::String value)
{
    if (!value.isEmpty())
        output = WTF::move(value);
}

template<typename Return>
static Return createLegacyCertificateResult(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    Return result {};
    auto* certificate = view.get();
    if (!certificate)
        return result;

    bool subjectConverted = getX509NameRecord<X509_get_subject_name>(globalObject, certificate, result.subject);
    RETURN_IF_EXCEPTION(scope, {});
    if (!subjectConverted)
        return {};

    auto issuer = view.getIssuer();
    if (!issuer) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    bool issuerConverted = getX509NameRecord<X509_get_issuer_name>(globalObject, certificate, result.issuer);
    RETURN_IF_EXCEPTION(scope, {});
    if (!issuerConverted)
        return {};

    if (auto subjectAltName = view.getSubjectAltName())
        setX509String(result.subjectaltname, toWTFString(subjectAltName));

    bool infoAccessConverted = getX509InfoAccessRecord(globalObject, view, result.infoAccess);
    RETURN_IF_EXCEPTION(scope, {});
    if (!infoAccessConverted)
        return {};

    EVP_PKEY* publicKey = X509_get0_pubkey(certificate);
    if (publicKey) {
        switch (EVP_PKEY_base_id(publicKey)) {
        case EVP_PKEY_RSA: {
            const RSA* rsa = EVP_PKEY_get0_RSA(publicKey);
            if (!rsa)
                break;

            const BIGNUM* modulus;
            const BIGNUM* exponent;
            RSA_get0_key(rsa, &modulus, &exponent, nullptr);

            if (auto bio = ncrypto::BIOPointer::New(modulus))
                result.modulus = toWTFString(bio);

            uint64_t exponentWord = static_cast<uint64_t>(ncrypto::BignumPointer::GetWord(exponent));
            auto exponentBio = ncrypto::BIOPointer::NewMem();
            if (exponentBio) {
                BIO_printf(exponentBio.get(), "0x%" PRIx64, exponentWord);
                result.exponent = toWTFString(exponentBio);
            }

            result.bits = ncrypto::BignumPointer::GetBitCount(modulus);

            int size = i2d_RSA_PUBKEY(rsa, nullptr);
            if (size > 0) {
                WTF::Vector<uint8_t> bytes;
                if (!bytes.tryGrow(static_cast<size_t>(size))) {
                    throwOutOfMemoryError(globalObject, scope);
                    return {};
                }
                uint8_t* data = bytes.mutableSpan().data();
                i2d_RSA_PUBKEY(rsa, &data);
                result.pubkey = WTF::move(bytes);
            }
            break;
        }
        case EVP_PKEY_EC: {
            const EC_KEY* ec = EVP_PKEY_get0_EC_KEY(publicKey);
            if (!ec)
                break;
            const EC_GROUP* group = EC_KEY_get0_group(ec);
            if (!group)
                break;

            int bits = EC_GROUP_order_bits(group);
            if (bits > 0)
                result.bits = bits;

            const EC_POINT* point = EC_KEY_get0_public_key(ec);
            if (point) {
                point_conversion_form_t form = EC_KEY_get_conv_form(ec);
                size_t size = EC_POINT_point2oct(group, point, form, nullptr, 0, nullptr);
                if (size > 0) {
                    WTF::Vector<uint8_t> bytes;
                    if (!bytes.tryGrow(size)) {
                        throwOutOfMemoryError(globalObject, scope);
                        return {};
                    }
                    size_t resultSize = EC_POINT_point2oct(group, point, form, bytes.mutableSpan().data(), size, nullptr);
                    if (resultSize == size)
                        result.pubkey = WTF::move(bytes);
                }
            }

            int nid = EC_GROUP_get_curve_name(group);
            if (nid != 0) {
                if (const char* shortName = OBJ_nid2sn(nid))
                    result.asn1Curve = String::fromUTF8(shortName);
                if (const char* nistName = EC_curve_nid2nist(nid))
                    result.nistCurve = String::fromUTF8(nistName);
            }
            break;
        }
        }
    }

    auto validFrom = view.getValidFrom();
    if (!validFrom) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    setX509String(result.valid_from, toWTFString(validFrom));

    auto validTo = view.getValidTo();
    if (!validTo) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    setX509String(result.valid_to, toWTFString(validTo));

    auto fingerprint = view.getFingerprint(EVP_sha1());
    if (!fingerprint) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    setX509String(result.fingerprint, WTF::move(fingerprint.value()));

    auto fingerprint256 = view.getFingerprint(EVP_sha256());
    if (!fingerprint256) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    setX509String(result.fingerprint256, WTF::move(fingerprint256.value()));

    auto fingerprint512 = view.getFingerprint(EVP_sha512());
    if (!fingerprint512) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    setX509String(result.fingerprint512, WTF::move(fingerprint512.value()));

    if (auto keyUsage = view.getKeyUsage()) {
        WTF::Vector<WTF::String> values;
        int count = sk_ASN1_OBJECT_num(keyUsage.get());
        if (!values.tryReserveCapacity(static_cast<size_t>(std::max(count, 0)))) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        char buffer[256];
        for (int i = 0; i < count; ++i) {
            if (OBJ_obj2txt(buffer, sizeof(buffer), sk_ASN1_OBJECT_value(keyUsage.get(), i), 1) >= 0
                && !appendX509Result(values, String::fromUTF8(buffer), globalObject, scope))
                return {};
        }
        result.ext_key_usage = WTF::move(values);
    }

    auto serialNumber = view.getSerialNumber();
    if (!serialNumber) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    setX509String(result.serialNumber, String::fromUTF8(std::span(static_cast<const char*>(serialNumber.get()), serialNumber.size())));

    auto raw = view.toDER();
    if (!raw) {
        throwCryptoOperationFailed(globalObject, scope);
        return {};
    }
    BUF_MEM* rawMemory = nullptr;
    BIO_get_mem_ptr(raw.get(), &rawMemory);
    std::span<const uint8_t> rawBytes(reinterpret_cast<const uint8_t*>(rawMemory->data), rawMemory->length);
    WTF::Vector<uint8_t> copiedRaw;
    if (!copiedRaw.tryAppend(rawBytes)) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    result.raw = WTF::move(copiedRaw);
    result.ca = view.isCA();
    return result;
}

using X509LegacyCertificateResult = decltype(Bindgen::Cpp::bunBindgenCpp_X509_certificateToLegacyObject(
    std::declval<Bindgen::CppCallContext&>(),
    std::declval<const Bindgen::Cpp::BunBindgenCpp_X509_certificateToLegacyObject_Arguments&>()));

X509LegacyCertificateResult Bindgen::Cpp::bunBindgenCpp_X509_certificateToLegacyObject(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_X509_certificateToLegacyObject_Arguments& args)
{
    auto* certificate = dynamicDowncast<JSX509Certificate>(args.bindingThis);
    RELEASE_ASSERT(certificate);
    return createLegacyCertificateResult<X509LegacyCertificateResult>(certificate->view(), &context.globalObject);
}
JSValue JSX509Certificate::computePublicKey(ncrypto::X509View view, JSGlobalObject* lexicalGlobalObject)
{
    VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    auto result = view.getPublicKey();
    if (!result) {
        throwCryptoError(lexicalGlobalObject, scope, result.error.value_or(0));
        return {};
    }

    auto handle = KeyObject::create(lexicalGlobalObject, scope, CryptoKeyType::Public, WTF::move(result.value));
    RETURN_IF_EXCEPTION(scope, {});
    return JSPublicKeyObject::create(vm, globalObject->m_JSPublicKeyObjectClassStructure.get(lexicalGlobalObject), lexicalGlobalObject, WTF::move(handle));
}

JSValue JSX509Certificate::computeInfoAccess(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto bio = view.getInfoAccess();
    if (!bio) {
        return jsEmptyString(vm);
    }
    return jsString(vm, toWTFString(bio));
}

JSString* JSX509Certificate::computeSubjectAltName(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto bio = view.getSubjectAltName();
    if (!bio) {
        return jsEmptyString(vm);
    }

    return jsString(vm, toWTFString(bio));
}

JSValue JSX509Certificate::getKeyUsage(ncrypto::X509View view, JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto keyUsage = view.getKeyUsage();
    if (!keyUsage) {
        return jsUndefined();
    }

    JSArray* array = JSArray::tryCreate(vm, globalObject->arrayStructureForIndexingTypeDuringAllocation(ArrayWithContiguous), 0);
    if (!array) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    int count = sk_ASN1_OBJECT_num(keyUsage.get());
    char buf[256];

    int j = 0;
    for (int i = 0; i < count; i++) {
        if (OBJ_obj2txt(buf, sizeof(buf), sk_ASN1_OBJECT_value(keyUsage.get(), i), 1) >= 0) {
            array->putDirectIndex(globalObject, j++, jsString(vm, String::fromUTF8(buf)));
        }
    }

    return array;
}

void setupX509CertificateClassStructure(LazyClassStructure::Initializer& init)
{
    auto* prototypeStructure = JSX509CertificatePrototype::createStructure(init.vm, init.global, init.global->objectPrototype());
    auto* prototype = JSX509CertificatePrototype::create(init.vm, init.global, prototypeStructure);

    auto* constructorStructure = JSX509CertificateConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());

    auto* constructor = JSX509CertificateConstructor::create(init.vm, init.global, constructorStructure, prototype);

    auto* structure = JSX509Certificate::createStructure(init.vm, init.global, prototype);
    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

Bindgen::Engine::BunBindgenEngine_X509_x509ToLegacyObject_Return Bindgen::Engine::bunBindgenEngine_X509_x509ToLegacyObject(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_X509_x509ToLegacyObject_Arguments& args)
{
    ncrypto::X509View view(args.certificate);
    return createLegacyCertificateResult<Bindgen::Engine::BunBindgenEngine_X509_x509ToLegacyObject_Return>(view, &context.globalObject);
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_X509_x509CreateCertificateObject(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_X509_x509CreateCertificateObject_Arguments& args)
{
    RELEASE_ASSERT(X509_up_ref(args.certificate));
    ncrypto::X509Pointer cert_ptr(args.certificate);
    auto* globalObject = &context.globalObject;
    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    return JSX509Certificate::create(zigGlobalObject->vm(), zigGlobalObject->m_JSX509CertificateClassStructure.get(zigGlobalObject), globalObject, WTF::move(cert_ptr));
}

bool Bindgen::Cpp::bunBindgenCpp_X509_isX509Certificate(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_X509_isX509Certificate_Arguments& args)
{
    return args.value.is_object() && args.value.object().inherits(JSX509Certificate::info());
}

} // namespace Bun
