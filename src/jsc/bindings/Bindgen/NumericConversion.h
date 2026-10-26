#pragma once
#include "root.h"
#include "IDLTypes.h"
#include "JSDOMConvertBase.h"
#include "ErrorBindings.h"
#include "ErrorCode.h"
#include "BunIDLConvertNumbers.h"
#include "BindingStringLiteral.h"
#include "ConversionFailure.h"
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <algorithm>
#include <bit>
#include <concepts>
#include <cmath>
#include <limits>

namespace Bun {

struct BindgenToLength : WebCore::IDLInteger<uint64_t> {
};

template<uint64_t MinBits, uint64_t MaxBits>
struct BindgenClampedNumber : WebCore::IDLUnrestrictedDouble {
};

template<uint64_t MinBits, uint64_t MaxBits, bool Coerce, bool TypeError, Bindgen::BindingFixedString Message>
struct BindgenNumberEnforceRange : WebCore::IDLUnrestrictedDouble {
};

template<uint64_t MinBits, uint64_t MaxBits, uint64_t FallbackBits>
struct BindgenNormalizedInteger : WebCore::IDLUnrestrictedDouble {
};

template<uint64_t MinBits, uint64_t MaxBits, uint64_t FallbackBits>
struct BindgenTruncatedClampedNumber : WebCore::IDLUnrestrictedDouble {
};

template<unsigned Bits, uint64_t MinBits, uint64_t MaxBits>
struct BindgenWrappedClampedNumber : WebCore::IDLUnrestrictedDouble {
};

template<
    std::integral NumericType,
    NumericType Min,
    NumericType Max>
struct BindgenIntegerEnforceRange : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType>
struct BindgenNumberInteger : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, bool AllowNumber, bool AllowBigInt>
struct BindgenModuloInteger : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, bool Coerce>
struct BindgenSaturatedInteger : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max, NumericType NaN, bool Coerce>
struct BindgenTruncatedIntegerClamp : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max, NumericType Fallback, bool AllowBigInt>
struct BindgenCoercedIntegerDefault : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max, bool Coerce, bool CustomFailure, ErrorCode Code, Bindgen::BindingFixedString Suffix>
struct BindgenSaturatedIntegerRange : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max, bool SaturateBelow, bool SaturateAbove, bool AllowInfinity, typename Invalid, typename OutOfRange>
struct BindgenBoundedInteger : WebCore::IDLInteger<NumericType> {
};

template<
    std::integral NumericType,
    NumericType Min,
    NumericType Max,
    bool Truncate = false,
    bool Coerce = false,
    bool IndividualBounds = false,
    bool AllowBigInt = false>
struct BindgenNumberIntegerRange : WebCore::IDLInteger<NumericType> {
};

enum class BindgenIntegerRejection { SafeInteger, PropertyValue, Port };

template<std::integral NumericType, NumericType Min, NumericType Max, BindgenIntegerRejection Rejection, bool Truncate>
struct BindgenNodeIntegerDiagnostic : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max>
struct BindgenMatchingInteger : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max>
struct BindgenBigIntIntegerRange : WebCore::IDLInteger<NumericType> {
};

template<std::integral NumericType, NumericType Min, NumericType Max>
struct BindgenNumberOrBigIntIntegerRange : WebCore::IDLInteger<NumericType> {
};

namespace Bindgen {

template<bool ToLength, Bun::IDLConversionContext Ctx>
uint64_t byteLengthIndex(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx, uint64_t maximum)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    double number = Bun::convertIDL<Bun::IDLStrictDouble>(globalObject, value, ctx);
    RETURN_IF_EXCEPTION(scope, 0);
    if constexpr (!ToLength) {
        if (!std::isfinite(number) || std::trunc(number) != number) {
            ctx.throwNumberNotInteger(globalObject, scope, number);
            return 0;
        }
    }
    if (std::isnan(number) || number < 0 || number > static_cast<double>(maximum)
        || !Bun::Detail::isInIntegerRange<uint64_t>(number)) {
        ctx.throwIntegerOutOfRange(globalObject, scope, number, uint64_t { 0 }, maximum);
        return 0;
    }
    if constexpr (ToLength)
        number = std::min(number, 9007199254740991.0);
    return static_cast<uint64_t>(number);
}

template<bool ToLength, Bun::IDLConversionContext Ctx>
uint64_t receiverByteLengthIndex(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx, JSC::JSValue receiver)
{
    auto* view = WTF::uncheckedDowncast<JSC::JSArrayBufferView>(receiver);
    return byteLengthIndex<ToLength>(globalObject, value, ctx, view->byteLength());
}

template<std::integral NumericType>
JSC::JSValue integerNumberOrBigIntToJS(JSC::JSGlobalObject* globalObject, NumericType value)
{
    if (std::cmp_greater_equal(value, -9007199254740991LL) && std::cmp_less_equal(value, 9007199254740991ULL))
        return JSC::jsNumber(static_cast<double>(value));
    using WideType = std::conditional_t<std::is_signed_v<NumericType>, int64_t, uint64_t>;
    return JSC::JSBigInt::createFrom(globalObject, static_cast<WideType>(value));
}

template<std::integral NumericType, NumericType Min, NumericType Max>
std::optional<NumericType> matchingInteger(JSC::JSValue value)
{
    if (!value.isNumber())
        return std::nullopt;
    double number = value.asNumber();
    if (std::trunc(number) != number || !Bun::Detail::isInIntegerRange<NumericType>(number))
        return std::nullopt;
    auto integer = static_cast<NumericType>(number);
    if (integer < Min || integer > Max)
        return std::nullopt;
    return integer;
}

}

enum class BindgenNumberRangeError {
    OutOfRange,
    InvalidValue,
};

template<
    bool HasMin,
    uint64_t MinBits,
    bool HasMax,
    uint64_t MaxBits,
    BindgenNumberRangeError Error>
struct BindgenNumberRange : WebCore::IDLUnrestrictedDouble {
};

}

namespace WebCore {

template<std::integral NumericType, bool AllowNumber, bool AllowBigInt>
struct Converter<Bun::BindgenModuloInteger<NumericType, AllowNumber, AllowBigInt>>
    : Bun::DefaultTryConverter<Bun::BindgenModuloInteger<NumericType, AllowNumber, AllowBigInt>> {

    static NumericType fromBits(uint64_t bits)
    {
        using Unsigned = std::make_unsigned_t<NumericType>;
        auto value = static_cast<Unsigned>(bits);
        if constexpr (std::is_signed_v<NumericType>)
            return std::bit_cast<NumericType>(value);
        else
            return value;
    }

    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx)
    {
        if constexpr (AllowBigInt) {
            if (value.isBigInt())
                return fromBits(JSC::JSBigInt::toBigUInt64(value));
        }
        if constexpr (AllowNumber) {
            if (value.isNumber()) {
                auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
                double number = value.asNumber();
                if (!std::isfinite(number) || std::trunc(number) != number) {
                    ctx.throwNumberNotInteger(globalObject, scope, number);
                    return std::nullopt;
                }
                constexpr int64_t maximum = 9007199254740991LL;
                if (number < -maximum || number > maximum) {
                    ctx.throwIntegerOutOfRange(globalObject, scope, number, -maximum, maximum);
                    return std::nullopt;
                }
                return fromBits(static_cast<uint64_t>(static_cast<int64_t>(number)));
            }
        }
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, Ctx& ctx)
    {
        if constexpr (AllowNumber && AllowBigInt)
            ctx.throwNotNumberOrBigInt(globalObject, scope);
        else if constexpr (AllowBigInt)
            ctx.throwNotBigInt(globalObject, scope);
        else
            ctx.throwNotNumber(globalObject, scope);
    }
};

template<uint64_t MinBits, uint64_t MaxBits, bool Coerce, bool TypeError, Bun::Bindgen::BindingFixedString Message>
struct Converter<Bun::BindgenNumberEnforceRange<MinBits, MaxBits, Coerce, TypeError, Message>>
    : Bun::NumberTryConverter<Bun::BindgenNumberEnforceRange<MinBits, MaxBits, Coerce, TypeError, Message>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<double> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx&)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number;
        if constexpr (Coerce) {
            number = value.toNumber(&globalObject);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
        } else {
            if (!value.isNumber()) return std::nullopt;
            number = value.asNumber();
        }
        if (number >= std::bit_cast<double>(MinBits) && number <= std::bit_cast<double>(MaxBits))
            return number;
        if constexpr (TypeError)
            JSC::throwTypeError(&globalObject, scope, Bun::Bindgen::bindingLiteral<Message>());
        else
            JSC::throwRangeError(&globalObject, scope, Bun::Bindgen::bindingLiteral<Message>());
        return std::nullopt;
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max, NumericType Fallback, bool AllowBigInt>
struct Converter<Bun::BindgenCoercedIntegerDefault<NumericType, Min, Max, Fallback, AllowBigInt>>
    : DefaultConverter<Bun::BindgenCoercedIntegerDefault<NumericType, Min, Max, Fallback, AllowBigInt>> {
    static NumericType convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        static_assert(Min <= Fallback && Fallback <= Max);
        if constexpr (AllowBigInt) {
            if (value.isBigInt()) {
                if (auto integer = Bun::Detail::tryBigIntToInt<NumericType>(value); integer && *integer >= Min && *integer <= Max)
                    return *integer;
                return Fallback;
            }
        }
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.toNumber(&globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        if (!std::isfinite(number))
            return Fallback;
        number = std::trunc(number);
        if (number < static_cast<double>(Min) || number > static_cast<double>(Max))
            return Fallback;
        return static_cast<NumericType>(number);
    }
};

template<uint64_t MinBits, uint64_t MaxBits, uint64_t FallbackBits>
struct Converter<Bun::BindgenNormalizedInteger<MinBits, MaxBits, FallbackBits>>
    : DefaultConverter<Bun::BindgenNormalizedInteger<MinBits, MaxBits, FallbackBits>> {
    static double convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.toNumber(&globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        if (std::isnan(number) || number < std::bit_cast<double>(MinBits) || number > std::bit_cast<double>(MaxBits))
            return std::bit_cast<double>(FallbackBits);
        return std::trunc(number);
    }
};

template<uint64_t MinBits, uint64_t MaxBits, uint64_t FallbackBits>
struct Converter<Bun::BindgenTruncatedClampedNumber<MinBits, MaxBits, FallbackBits>>
    : DefaultConverter<Bun::BindgenTruncatedClampedNumber<MinBits, MaxBits, FallbackBits>> {
    static double convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.toNumber(&globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        if (!std::isfinite(number))
            return std::bit_cast<double>(FallbackBits);
        return std::clamp(std::trunc(number), std::bit_cast<double>(MinBits), std::bit_cast<double>(MaxBits));
    }
};

template<unsigned Bits, uint64_t MinBits, uint64_t MaxBits>
struct Converter<Bun::BindgenWrappedClampedNumber<Bits, MinBits, MaxBits>>
    : DefaultConverter<Bun::BindgenWrappedClampedNumber<Bits, MinBits, MaxBits>> {
    static double convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        static_assert(Bits >= 2 && Bits <= 53);
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.toNumber(&globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        const double modulus = std::ldexp(1.0, Bits);
        double wrapped = std::isfinite(number) ? std::fmod(std::trunc(number), modulus) : 0;
        if (wrapped >= modulus / 2)
            wrapped -= modulus;
        else if (wrapped < -modulus / 2)
            wrapped += modulus;
        return std::clamp(wrapped, std::bit_cast<double>(MinBits), std::bit_cast<double>(MaxBits));
    }
};

template<uint64_t MinBits, uint64_t MaxBits>
struct Converter<Bun::BindgenClampedNumber<MinBits, MaxBits>> : DefaultConverter<Bun::BindgenClampedNumber<MinBits, MaxBits>> {
    static double convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.toNumber(&globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        return std::clamp(number, std::bit_cast<double>(MinBits), std::bit_cast<double>(MaxBits));
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max, bool Coerce, bool CustomFailure, Bun::ErrorCode Code, Bun::Bindgen::BindingFixedString Suffix>
struct Converter<Bun::BindgenSaturatedIntegerRange<NumericType, Min, Max, Coerce, CustomFailure, Code, Suffix>>
    : Bun::NumberTryConverter<Bun::BindgenSaturatedIntegerRange<NumericType, Min, Max, Coerce, CustomFailure, Code, Suffix>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number;
        if constexpr (Coerce) {
            number = value.toNumber(&globalObject);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
        } else {
            if (!value.isNumber())
                return std::nullopt;
            number = value.asNumber();
        }
        auto integer = Bun::Detail::saturateInteger<NumericType>(number);
        if (integer >= Min && integer <= Max)
            return integer;
        if constexpr (CustomFailure) {
            auto message = WTF::tryMakeString(ctx.source(), Bun::Bindgen::bindingLiteral<Suffix>());
            if (message.isNull())
                Bun::Bindgen::throwBindingOutOfMemoryError(&globalObject, scope);
            else
                Bun::throwError(&globalObject, scope, Code, message);
        } else
            ctx.throwIntegerOutOfRange(globalObject, scope, integer, Min, Max);
        return std::nullopt;
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max, NumericType NaN, bool Coerce>
struct Converter<Bun::BindgenTruncatedIntegerClamp<NumericType, Min, Max, NaN, Coerce>>
    : Bun::NumberTryConverter<Bun::BindgenTruncatedIntegerClamp<NumericType, Min, Max, NaN, Coerce>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx&)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number;
        if constexpr (Coerce) {
            number = value.toNumber(&globalObject);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
        } else {
            if (!value.isNumber())
                return std::nullopt;
            number = value.asNumber();
        }
        if (std::isnan(number))
            return NaN;
        return std::clamp(Bun::Detail::saturateInteger<NumericType>(number), Min, Max);
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max, bool SaturateBelow, bool SaturateAbove, bool AllowInfinity, typename Invalid, typename OutOfRange>
struct Converter<Bun::BindgenBoundedInteger<NumericType, Min, Max, SaturateBelow, SaturateAbove, AllowInfinity, Invalid, OutOfRange>>
    : Bun::DefaultTryConverter<Bun::BindgenBoundedInteger<NumericType, Min, Max, SaturateBelow, SaturateAbove, AllowInfinity, Invalid, OutOfRange>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx&)
    {
        if (!value.isNumber())
            return std::nullopt;
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.asNumber();
        if ((!AllowInfinity && !std::isfinite(number)) || std::trunc(number) != number) {
            Invalid::raise(globalObject, scope);
            return std::nullopt;
        }
        if (number < static_cast<double>(Min)) {
            if constexpr (SaturateBelow)
                return Min;
            OutOfRange::raise(globalObject, scope);
            return std::nullopt;
        }
        if (number > static_cast<double>(Max)) {
            if constexpr (SaturateAbove)
                return Max;
            OutOfRange::raise(globalObject, scope);
            return std::nullopt;
        }
        return static_cast<NumericType>(number);
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, Ctx&)
    {
        Invalid::raise(globalObject, scope);
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max>
struct Converter<Bun::BindgenNumberOrBigIntIntegerRange<NumericType, Min, Max>>
    : Bun::DefaultTryConverter<Bun::BindgenNumberOrBigIntIntegerRange<NumericType, Min, Max>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx)
    {
        auto integer = Converter<Bun::IDLStrictInteger<NumericType>>::tryConvert(globalObject, value, ctx);
        if (!integer || (*integer >= Min && *integer <= Max))
            return integer;
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        if (value.isBigInt())
            ctx.throwBigIntOutOfRange(globalObject, scope, Min, Max);
        else
            ctx.throwIntegerOutOfRange(globalObject, scope, *integer, Min, Max);
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, Ctx& ctx)
    {
        ctx.throwNotNumberOrBigInt(globalObject, scope);
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max>
struct Converter<Bun::BindgenBigIntIntegerRange<NumericType, Min, Max>>
    : Bun::DefaultTryConverter<Bun::BindgenBigIntIntegerRange<NumericType, Min, Max>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx)
    {
        if (!value.isBigInt())
            return std::nullopt;
        if (auto integer = Bun::Detail::tryBigIntToInt<NumericType>(value); integer && *integer >= Min && *integer <= Max)
            return integer;
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        ctx.throwBigIntOutOfRange(globalObject, scope, Min, Max);
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, Ctx& ctx)
    {
        ctx.throwNotBigInt(globalObject, scope);
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max>
struct Converter<Bun::BindgenMatchingInteger<NumericType, Min, Max>>
    : Bun::NumberTryConverter<Bun::BindgenMatchingInteger<NumericType, Min, Max>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx)
    {
        if (auto integer = Bun::Bindgen::matchingInteger<NumericType, Min, Max>(value))
            return integer;
        if (!value.isNumber())
            return std::nullopt;
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.asNumber();
        if (!std::isfinite(number) || std::trunc(number) != number)
            ctx.throwNumberNotInteger(globalObject, scope, number);
        else
            ctx.throwIntegerOutOfRange(globalObject, scope, number, Min, Max);
        return std::nullopt;
    }
};

template<>
struct Converter<Bun::BindgenToLength> : DefaultConverter<Bun::BindgenToLength> {
    static uint64_t convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        return value.toLength(&globalObject);
    }
};

template<
    std::integral NumericType,
    NumericType Min,
    NumericType Max>
struct Converter<Bun::BindgenIntegerEnforceRange<NumericType, Min, Max>>
    : DefaultConverter<Bun::BindgenIntegerEnforceRange<NumericType, Min, Max>> {
    static NumericType convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        double number = value.toNumber(&globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        double integer = std::trunc(number);
        if (Bun::Detail::isInIntegerRange<NumericType>(integer)) {
            auto result = static_cast<NumericType>(integer);
            if (result >= Min && result <= Max)
                return result;
        }
        auto message = tryMakeString("Value "_s, number, " is outside the range ["_s, static_cast<double>(Min), ", "_s, static_cast<double>(Max), ']');
        if (message.isNull())
            Bun::Bindgen::throwBindingOutOfMemoryError(&globalObject, scope);
        else
            throwTypeError(&globalObject, scope, message);
        return 0;
    }
};

template<std::integral NumericType, NumericType Min, NumericType Max, Bun::BindgenIntegerRejection Rejection, bool Truncate>
struct Converter<Bun::BindgenNodeIntegerDiagnostic<NumericType, Min, Max, Rejection, Truncate>>
    : Bun::NumberTryConverter<Bun::BindgenNodeIntegerDiagnostic<NumericType, Min, Max, Rejection, Truncate>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx& ctx)
    {
        if (value.isNumber()) {
            double number = value.asNumber();
            if constexpr (Truncate)
                number = std::trunc(number);
            if (std::isfinite(number) && std::trunc(number) == number
                && number >= static_cast<double>(Min) && number <= static_cast<double>(Max)
                && Bun::Detail::isInIntegerRange<NumericType>(number))
                return static_cast<NumericType>(number);
        }
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        if constexpr (Rejection == Bun::BindgenIntegerRejection::SafeInteger)
            Bun::ERR::INVALID_ARG_SAFE_INTEGER(scope, &globalObject, ctx.source(), value);
        else if constexpr (Rejection == Bun::BindgenIntegerRejection::Port)
            Bun::ERR::SOCKET_BAD_PORT_NUMBER(scope, &globalObject, ctx.source(), value);
        else
            Bun::ERR::INVALID_ARG_VALUE(scope, &globalObject, ctx.source(), value);
        return std::nullopt;
    }
};

template<std::integral NumericType>
struct Converter<Bun::BindgenNumberInteger<NumericType>>
    : Bun::NumberTryConverter<Bun::BindgenNumberInteger<NumericType>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (!value.isNumber())
            return std::nullopt;
        return Converter<Bun::IDLStrictInteger<NumericType>>::tryConvert(globalObject, value, ctx);
    }
};

template<
    std::integral NumericType,
    bool Coerce>
struct Converter<Bun::BindgenSaturatedInteger<NumericType, Coerce>>
    : Bun::NumberTryConverter<Bun::BindgenSaturatedInteger<NumericType, Coerce>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx&)
    {
        if constexpr (Coerce) {
            auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
            double number = value.toNumber(&globalObject);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            return Bun::Detail::saturateInteger<NumericType>(number);
        } else {
            if (!value.isNumber())
                return std::nullopt;
            return Bun::Detail::saturateInteger<NumericType>(value.asNumber());
        }
    }
};

template<
    std::integral NumericType,
    NumericType Min,
    NumericType Max,
    bool Truncate,
    bool Coerce,
    bool IndividualBounds,
    bool AllowBigInt>
struct Converter<Bun::BindgenNumberIntegerRange<NumericType, Min, Max, Truncate, Coerce, IndividualBounds, AllowBigInt>>
    : Bun::NumberTryConverter<Bun::BindgenNumberIntegerRange<NumericType, Min, Max, Truncate, Coerce, IndividualBounds, AllowBigInt>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<NumericType> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        if constexpr (AllowBigInt) {
            if (value.isBigInt()) {
                if (auto integer = Bun::Detail::tryBigIntToInt<NumericType>(value); integer && *integer >= Min && *integer <= Max)
                    return integer;
                ctx.throwBigIntOutOfRange(globalObject, scope, Min, Max);
                return std::nullopt;
            }
        }
        double number;
        if constexpr (Coerce) {
            number = value.toNumber(&globalObject);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            value = JSC::jsNumber(number);
            ctx.setValue(value);
        } else {
            if (!value.isNumber())
                return std::nullopt;
            number = value.asNumber();
        }
        if constexpr (Truncate) {
            if (number >= static_cast<double>(Min) && number <= static_cast<double>(Max)
                && Bun::Detail::isInIntegerRange<NumericType>(number)) {
                auto result = static_cast<NumericType>(number);
                if (result >= Min && result <= Max)
                    return result;
            }
            ctx.throwIntegerOutOfRange(globalObject, scope, number, Min, Max);
            return std::nullopt;
        }
        if (!std::isfinite(number) || std::trunc(number) != number) {
            ctx.throwNumberNotInteger(globalObject, scope, number);
            return std::nullopt;
        }

        if (auto integer = Bun::Bindgen::matchingInteger<NumericType, Min, Max>(value))
            return integer;
        if constexpr (IndividualBounds) {
            if (number < static_cast<double>(Min))
                ctx.throwRangeErrorWithPredicate(globalObject, scope, WTF::makeString(">= "_s, Min));
            else
                ctx.throwRangeErrorWithPredicate(globalObject, scope, WTF::makeString("<= "_s, Max));
        } else {
            ctx.throwIntegerOutOfRange(globalObject, scope, number, Min, Max);
        }
        return std::nullopt;
    }
};

template<
    bool HasMin,
    uint64_t MinBits,
    bool HasMax,
    uint64_t MaxBits,
    Bun::BindgenNumberRangeError Error>
struct Converter<Bun::BindgenNumberRange<HasMin, MinBits, HasMax, MaxBits, Error>>
    : Bun::NumberTryConverter<Bun::BindgenNumberRange<HasMin, MinBits, HasMax, MaxBits, Error>> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<double> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (!value.isNumber())
            return std::nullopt;

        constexpr double min = std::bit_cast<double>(MinBits);
        constexpr double max = std::bit_cast<double>(MaxBits);
        double number = value.asNumber();
        if ((HasMin && number < min) || (HasMax && number > max) || std::isnan(number)) {
            auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
            if constexpr (Error == Bun::BindgenNumberRangeError::InvalidValue) {
                ctx.throwInvalidArgumentValueRangeError(globalObject, scope);
            } else {
                String predicate;
                if constexpr (HasMin && HasMax)
                    predicate = tryMakeString(">= "_s, min, " && <= "_s, max);
                else if constexpr (HasMin)
                    predicate = tryMakeString(">= "_s, min);
                else
                    predicate = tryMakeString("<= "_s, max);
                if (predicate.isNull())
                    Bun::Bindgen::throwBindingOutOfMemoryError(&globalObject, scope);
                else
                    ctx.throwRangeErrorWithPredicate(globalObject, scope, predicate);
            }
            return std::nullopt;
        }
        return number;
    }
};

}
