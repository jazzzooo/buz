#include "JSHash.h"
#include "SchemaBindings.h"
#include "CryptoUtil.h"
#include "BunClientData.h"
#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/ThrowScope.h>
#include <openssl/evp.h>
#include <JavaScriptCore/Error.h>
#include "NodeValidator.h"
#include <JavaScriptCore/FunctionPrototype.h>

namespace Bun {

static JSHash* hashObject(JSC::JSValue value)
{
    auto* hash = dynamicDowncast<JSHash>(value);
    RELEASE_ASSERT(hash);
    return hash;
}

#define BUN_BINDGEN_OBJECT_SURFACE_JSHashPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSHashPrototype

const ClassInfo JSHash::s_info = { "Hash"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSHash) };
const ClassInfo JSHashPrototype::s_info = { "Hash"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSHashPrototype) };
const ClassInfo JSHashConstructor::s_info = { "Hash"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSHashConstructor) };

JSHash::JSHash(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure)
{
}

void JSHash::destroy(JSC::JSCell* cell)
{
    static_cast<JSHash*>(cell)->~JSHash();
}

JSHash::~JSHash() = default;

void JSHash::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
}

template<typename, JSC::SubspaceAccess mode>
JSC::GCClient::IsoSubspace* JSHash::subspaceFor(JSC::VM& vm)
{
    if constexpr (mode == JSC::SubspaceAccess::Concurrently)
        return nullptr;

    return WebCore::subspaceForImpl<JSHash, WebCore::UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForJSHash.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForJSHash = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForJSHash.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForJSHash = std::forward<decltype(space)>(space); });
}

JSHash* JSHash::create(JSC::VM& vm, JSC::Structure* structure)
{
    JSHash* instance = new (NotNull, JSC::allocateCell<JSHash>(vm)) JSHash(vm, structure);
    instance->finishCreation(vm);
    return instance;
}

bool JSHash::init(JSC::JSGlobalObject* globalObject, ThrowScope& scope, const EVP_MD* md, std::optional<uint32_t> xofLen)
{
    // Create the digest context
    m_ctx = ncrypto::EVPMDCtxPointer::New();
    if (!m_ctx.digestInit(md)) {
        m_ctx.reset();
        return false;
    }

    // Set the digest length
    m_mdLen = m_ctx.getDigestSize();

    // Handle custom length for XOF hash functions (like SHAKE)
    if (xofLen.has_value() && xofLen.value() != m_mdLen) {
        // from node:
        // https://github.com/nodejs/node/blob/2a6f90813f4802def79f2df1bfe20e95df279abf/src/crypto/crypto_hash.cc#L346
        //
        // This is a little hack to cause createHash to fail when an incorrect
        // hashSize option was passed for a non-XOF hash function.
        if (!m_ctx.hasXofFlag()) {
            EVPerr(EVP_F_EVP_DIGESTFINALXOF, EVP_R_NOT_XOF_OR_INVALID_LENGTH);
            m_ctx.reset();
            return false;
        }
        m_mdLen = xofLen.value();
    }

    return true;
}

bool JSHash::initZig(JSGlobalObject* globalObject, ThrowScope& scope, ExternZigHash::HasherOwner hasher, std::optional<uint32_t> xofLen)
{
    m_mdLen = ExternZigHash::getDigestSize(hasher.get());

    if (m_mdLen == 0) {
        return false;
    }

    if (xofLen.has_value() && *xofLen != m_mdLen) {
        if (!ExternZigHash::isXof(hasher.get())) {
            EVPerr(EVP_F_EVP_DIGESTFINALXOF, EVP_R_NOT_XOF_OR_INVALID_LENGTH);
            return false;
        }
        m_mdLen = xofLen.value();
    }

    m_zigHasher = WTF::move(hasher);
    return true;
}

bool JSHash::update(std::span<const uint8_t> input)
{
    if (m_ctx) {
        ncrypto::Buffer<const void> buffer {
            .data = input.data(),
            .len = input.size(),
        };

        return m_ctx.digestUpdate(buffer);
    }

    if (m_zigHasher) {
        return ExternZigHash::update(m_zigHasher.get(), input).status == Bindgen::CryptoHasherExternStatus::success;
    }

    return false;
}

void JSHashPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSHashPrototype_install(vm, JSHash::info(), *this);
}

static bool hashUpdate(
    Bindgen::CppCallContext& context,
    JSC::JSGlobalObject* globalObject,
    JSHash* hash,
    const auto& inputValue,
    const auto& encoding)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Check if the Hash is already finalized
    if (hash->m_finalized) {
        Bun::ERR::CRYPTO_HASH_FINALIZED(scope, globalObject);
        return false;
    }

    if (!inputValue) {
        Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, "data"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, jsUndefined());
        return false;
    }

    std::optional<Bindgen::NodeStringEncoding> convertedEncoding;
    if (!convertStringInputEncodingAndLease(context, scope, *inputValue, encoding, convertedEncoding))
        return {};

    auto input = getStringOrBufferBytes(globalObject, scope, inputValue.value(), nodeEncodingOrDefault(convertedEncoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, false);

    if (!hash->update(input)) {
        Bun::ERR::CRYPTO_HASH_UPDATE_FAILED(scope, globalObject);
        return false;
    }

    return true;
}

template<typename Encoding>
static Bindgen::NodeCryptoEncodedOutputResult hashDigest(
    JSC::JSGlobalObject* lexicalGlobalObject,
    JSHash* hash,
    const std::optional<Encoding>& encodingValue,
    const std::optional<std::optional<bool>>& setFinalizedValue)
{
    JSC::VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    // Check if already finalized
    if (hash->m_finalized) {
        Bun::ERR::CRYPTO_HASH_FINALIZED(scope, globalObject);
        return {};
    }

    BufferEncodingType encoding = nodeEncodingOrDefault(encodingValue, BufferEncodingType::buffer);

    bool finalized = setFinalizedValue && setFinalizedValue->has_value() ? **setFinalizedValue : true;

    uint32_t len = hash->m_mdLen;

    if (hash->m_zigHasher) {
        if (hash->m_digestBuffer.isEmpty() && len > 0) {
            Vector<uint8_t, EVP_MAX_MD_SIZE> digestBuffer;
            if (!digestBuffer.tryGrow(len)) {
                throwOutOfMemoryError(lexicalGlobalObject, scope);
                return {};
            }
            auto digestResult = ExternZigHash::digest(hash->m_zigHasher.get(), globalObject, digestBuffer.mutableSpan());
            if (digestResult.status != Bindgen::CryptoHasherExternStatus::success) {
                throwCryptoError(lexicalGlobalObject, scope, digestResult.errorCode, "Failed to finalize digest"_s);
                return {};
            }
            RELEASE_ASSERT(digestResult.length == len);
            hash->m_digestBuffer = WTF::move(digestBuffer);
        }

        hash->m_finalized = finalized;
        RELEASE_AND_RETURN(scope, StringBytes::encode(lexicalGlobalObject, scope, hash->m_digestBuffer.span(), encoding));
    }

    // Only compute the digest if it hasn't been cached yet
    if (!hash->m_digest && len > 0) {
        auto data = hash->m_ctx.digestFinal(len);
        if (!data) {
            throwCryptoError(lexicalGlobalObject, scope, ERR_get_error(), "Failed to finalize digest"_s);
            return {};
        }

        // Some hash algorithms don't support calling EVP_DigestFinal_ex more than once
        // We need to cache the result for future calls
        hash->m_digest = ByteSource::allocated(data.release());
    }

    // Mark as finalized
    hash->m_finalized = finalized;

    // Return the digest with the requested encoding
    RELEASE_AND_RETURN(scope, StringBytes::encode(lexicalGlobalObject, scope, std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(hash->m_digest.data()), len }, encoding));
}

static JSC::EncodedJSValue constructHash(
    JSC::JSGlobalObject* globalObject,
    JSC::JSObject* newTarget,
    const auto& algorithmOrHashValue,
    const auto& optionsValue)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    JSC::Structure* structure = zigGlobalObject->m_JSHashClassStructure.get(zigGlobalObject);

    // Handle new target
    if (zigGlobalObject->m_JSHashClassStructure.constructor(zigGlobalObject) != newTarget) [[unlikely]] {
        auto* functionGlobalObject = defaultGlobalObject(getFunctionRealm(globalObject, newTarget));
        RETURN_IF_EXCEPTION(scope, {});
        structure = InternalFunction::createSubclassStructure(globalObject, newTarget, functionGlobalObject->m_JSHashClassStructure.get(functionGlobalObject));
        RETURN_IF_EXCEPTION(scope, {});
    }

    // Because we aren't checking if m_finalized true in Hash.prototype.copy, we need to check here
    // and make sure we validate arguments in the correct order.
    // If clone, check m_finalized before anything else.
    JSHash* original = nullptr;
    const EVP_MD* md = nullptr;
    ExternZigHash::HasherOwner zigHasher;
    uint32_t zigErrorCode = 0;
    const auto* algorithmOrHash = algorithmOrHashValue.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (algorithmOrHash->is_hash()) {
        original = hashObject(algorithmOrHash->hash());
        if (original->m_finalized) {
            return Bun::ERR::CRYPTO_HASH_FINALIZED(scope, globalObject);
        }

        if (original->m_zigHasher) {
            auto result = ExternZigHash::getFromOther(zigGlobalObject, original->m_zigHasher.get());
            RETURN_IF_EXCEPTION(scope, {});
            zigHasher = WTF::move(result.hasher);
            zigErrorCode = result.errorCode;
        } else {
            md = original->m_ctx.getDigest();
        }
    } else {
        RELEASE_ASSERT(algorithmOrHash->is_algorithm());
        md = ncrypto::getDigestByName(algorithmOrHash->algorithm());
        if (!md) {
            auto result = ExternZigHash::getByName(zigGlobalObject, algorithmOrHash->algorithm());
            RETURN_IF_EXCEPTION(scope, {});
            zigHasher = WTF::move(result.hasher);
            zigErrorCode = result.errorCode;
        }
    }

    if (md == nullptr && zigHasher == nullptr) [[unlikely]] {
        throwCryptoError(globalObject, scope, zigErrorCode, "Digest method not supported"_s);
        return {};
    }

    std::optional<unsigned int> xofLen = std::nullopt;
    if (optionsValue) {
        const auto* converted = optionsValue->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (converted->is_options())
            xofLen = converted->options().output_length;
    }

    JSHash* hash = JSHash::create(vm, structure);

    if (zigHasher) {
        if (!hash->initZig(globalObject, scope, WTF::move(zigHasher), xofLen)) {
            throwCryptoError(globalObject, scope, ERR_get_error(), "Digest method not supported"_s);
            return {};
        }
        return JSValue::encode(hash);
    }

    if (!hash->init(globalObject, scope, md, xofLen)) {
        throwCryptoError(globalObject, scope, ERR_get_error(), "Digest method not supported"_s);
        return {};
    }

    if (original != nullptr && !original->m_ctx.copyTo(hash->m_ctx)) {
        throwCryptoError(globalObject, scope, ERR_get_error(), "Digest copy error"_s);
        return {};
    }

    return JSC::JSValue::encode(hash);
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_hashConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_hashConstructorCall_Arguments&)
{
    auto* globalObject = &context.globalObject;
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    throwTypeError(globalObject, scope, "Class constructor Hash cannot be invoked without 'new'"_s);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_hashConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_hashConstructorConstruct_Arguments& args)
{
    return JSC::JSValue::decode(constructHash(
        &context.globalObject,
        JSC::asObject(args.bindingNewTarget),
        args.algorithm,
        args.options));
}

std::optional<Bindgen::CppAny> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_hashUpdate(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_hashUpdate_Arguments& args)
{
    if (!hashUpdate(
        context,
        &context.globalObject,
        hashObject(args.bindingThis),
        args.data,
        args.encoding))
        return std::nullopt;
    return args.wrapper;
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_hashDigest(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_hashDigest_Arguments& args)
{
    return hashDigest(
        &context.globalObject,
        hashObject(args.bindingThis),
        args.encoding,
        args.setFinalized);
}

JSHashConstructor::JSHashConstructor(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure, bun_bindgen_host_NodeCryptoBinding_hashConstructorCall, bun_bindgen_host_NodeCryptoBinding_hashConstructorConstruct)
{
}

JSC::Structure* JSHashConstructor::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
}

void setupJSHashClassStructure(JSC::LazyClassStructure::Initializer& init)
{
    auto* prototypeStructure = JSHashPrototype::createStructure(init.vm, init.global, init.global->objectPrototype());
    auto* prototype = JSHashPrototype::create(init.vm, init.global, prototypeStructure);

    auto* constructorStructure = JSHashConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());
    auto* constructor = JSHashConstructor::create(init.vm, constructorStructure, prototype);

    auto* structure = JSHash::createStructure(init.vm, init.global, prototype);
    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

} // namespace Bun
