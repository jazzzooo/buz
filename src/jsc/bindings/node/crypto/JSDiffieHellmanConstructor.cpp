#include "JSDiffieHellmanConstructor.h"
#include "JSDiffieHellman.h"
#include "ErrorCode.h"
#include "JSBufferEncodingType.h"
#include "NodeValidator.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include "CryptoUtil.h"
#include "openssl/dh.h"
#include "openssl/bn.h"
#include "openssl/err.h"
#include "ncrypto.h"

namespace Bun {

const JSC::ClassInfo JSDiffieHellmanConstructor::s_info = { "DiffieHellman"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSDiffieHellmanConstructor) };

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorCall_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    JSC::VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* constructor = globalObject->m_JSDiffieHellmanClassStructure.constructor(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSC::MarkedArgumentBuffer forwardedArguments;
    if (args.sizeOrKey) args.sizeOrKey->appendTo(forwardedArguments);
    if (args.keyEncoding) args.keyEncoding->appendTo(forwardedArguments);
    if (args.generator) args.generator->appendTo(forwardedArguments);
    if (args.generatorEncoding) args.generatorEncoding->appendTo(forwardedArguments);
    auto callData = JSC::getConstructData(constructor);
    JSC::JSValue result = JSC::construct(globalObject, constructor, callData, ArgList(forwardedArguments));
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

static JSC::JSValue createDiffieHellman(JSC::JSGlobalObject* globalObject, ncrypto::DHPointer&& dh)
{
    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    auto* structure = zigGlobalObject->m_JSDiffieHellmanClassStructure.get(zigGlobalObject);
    return JSDiffieHellman::create(globalObject->vm(), structure, globalObject, WTF::move(dh));
}

static JSC::JSValue constructDiffieHellmanFromBits(
    JSC::JSGlobalObject* globalObject,
    int32_t bits,
    const std::optional<Bindgen::DiffieHellmanGenerator>& generatorValue)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (bits < 2) {
        ERR_put_error(ERR_LIB_DH, 0, DH_R_MODULUS_TOO_LARGE, __FILE__, __LINE__);
        throwCryptoError(globalObject, scope, ERR_get_error(), "Invalid prime length"_s);
        return {};
    }

    int32_t generator = 2;
    if (generatorValue) {
        if (!generatorValue->is_number())
            return createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, "Second argument must be an int32"_s);
        generator = generatorValue->number();
    }

    if (generator < 2) {
        ERR_put_error(ERR_LIB_DH, 0, DH_R_BAD_GENERATOR, __FILE__, __LINE__);
        throwCryptoError(globalObject, scope, ERR_get_error(), "Invalid generator"_s);
        return {};
    }

    auto dh = ncrypto::DHPointer::New(bits, generator);
    if (!dh)
        return createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid DH parameters"_s);
    return createDiffieHellman(globalObject, WTF::move(dh));
}

static std::optional<BufferEncodingType> diffieHellmanGeneratorEncoding(
    JSC::JSGlobalObject* globalObject,
    JSC::ThrowScope& scope,
    const std::optional<Bindgen::NodeEncodingOrOriginal>& candidate)
{
    if (!candidate)
        return BufferEncodingType::utf8;
    if (candidate->is_encoding())
        return nodeEncodingToBufferEncoding(candidate->encoding());
    RELEASE_ASSERT(candidate->is_original());
    ERR::UNKNOWN_ENCODING(scope, globalObject, candidate->original());
    return std::nullopt;
}

static JSC::JSValue constructDiffieHellmanFromPrime(
    JSC::JSGlobalObject* globalObject,
    const Bindgen::DiffieHellmanPrime& prime,
    const std::optional<Bindgen::CoercedNodeEncoding>& keyEncoding,
    const std::optional<Bindgen::DiffieHellmanGenerator>& generatorValue,
    const std::optional<Bindgen::NodeEncodingOrOriginal>& generatorEncodingValue)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto primeBytes = getStringOrBufferBytes(
        globalObject,
        scope,
        prime,
        nodeEncodingOrDefault(keyEncoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, {});

    if (primeBytes->size() > INT32_MAX)
        return createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, "prime is too big"_s);

    ncrypto::BignumPointer primeNumber(
        static_cast<const unsigned char*>(primeBytes->data()),
        primeBytes->size());
    if (!primeNumber)
        return createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid prime"_s);

    ncrypto::BignumPointer generatorNumber;
    if (!generatorValue || generatorValue->is_number()) {
        int32_t generator = generatorValue ? generatorValue->number() : 2;
        if (generator < 2) {
            ERR_put_error(ERR_LIB_DH, 0, DH_R_BAD_GENERATOR, __FILE__, __LINE__);
            throwCryptoError(globalObject, scope, ERR_get_error(), "Invalid generator"_s);
            return {};
        }
        generatorNumber = ncrypto::BignumPointer::New();
        if (!generatorNumber.setWord(generator)) {
            ERR_put_error(ERR_LIB_DH, 0, DH_R_BAD_GENERATOR, __FILE__, __LINE__);
            throwCryptoError(globalObject, scope, ERR_get_error(), "Invalid generator"_s);
            return {};
        }
    } else {
        std::span<const uint8_t> generatorBytes;
        JSC::JSArrayBufferView* generatorOwner = nullptr;
        if (generatorValue->is_string()) {
            auto encoding = diffieHellmanGeneratorEncoding(globalObject, scope, generatorEncodingValue);
            RETURN_IF_EXCEPTION(scope, {});
            RELEASE_ASSERT(encoding);
            generatorOwner = encodeCryptoString(
                globalObject,
                scope,
                generatorValue->string(),
                *encoding);
            RETURN_IF_EXCEPTION(scope, {});
            generatorBytes = generatorOwner->span();
        } else {
            RELEASE_ASSERT(generatorValue->is_buffer());
            generatorBytes = generatorValue->buffer();
        }

        if (generatorBytes.size() > INT32_MAX)
            return createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, "generator is too big"_s);

        generatorNumber = ncrypto::BignumPointer(
            static_cast<const unsigned char*>(generatorBytes.data()),
            generatorBytes.size());
        if (!generatorNumber)
            return createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid generator"_s);

        if (generatorNumber.getWord() < 2) {
            ERR_put_error(ERR_LIB_DH, 0, DH_R_BAD_GENERATOR, __FILE__, __LINE__);
            throwCryptoError(globalObject, scope, ERR_get_error(), "Invalid generator"_s);
            return {};
        }
    }

    auto dh = ncrypto::DHPointer::New(WTF::move(primeNumber), WTF::move(generatorNumber));
    if (!dh)
        return createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, "Invalid DH parameters"_s);
    return createDiffieHellman(globalObject, WTF::move(dh));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_bits_with_encoding(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_bits_with_encoding_Arguments& args)
{
    return constructDiffieHellmanFromBits(&context.globalObject, args.sizeOrKey, args.generator);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_bits_with_generator(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_bits_with_generator_Arguments& args)
{
    return constructDiffieHellmanFromBits(&context.globalObject, args.sizeOrKey, args.generator);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_prime_with_encoding(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_prime_with_encoding_Arguments& args)
{
    return constructDiffieHellmanFromPrime(
        &context.globalObject,
        args.sizeOrKey,
        args.keyEncoding,
        args.generator,
        args.generatorEncoding);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_prime_with_generator(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructorConstruct_overload_prime_with_generator_Arguments& args)
{
    return constructDiffieHellmanFromPrime(
        &context.globalObject,
        args.sizeOrKey,
        std::nullopt,
        args.generator,
        args.generatorEncoding);
}

} // namespace Bun
