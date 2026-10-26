#pragma once
#include "BunIDLTypes.h"
#include "BunIDLConvertBase.h"
#include <JavaScriptCore/JSBigInt.h>
#include <cmath>
#include <limits>
#include <type_traits>
#include <utility>

namespace Bun {
template<typename IDL>
struct NumberTryConverter : DefaultTryConverter<IDL> {
    template<IDLConversionContext Ctx>
    static void throwConversionFailed(JSC::JSGlobalObject& globalObject, JSC::ThrowScope& scope, Ctx& ctx)
    {
        ctx.throwNotNumber(globalObject, scope);
    }
};
}

namespace Bun::Detail {
template<std::integral T>
bool isInIntegerRange(double number)
{
    return number >= static_cast<double>(std::numeric_limits<T>::min())
        && number < std::ldexp(1.0, std::numeric_limits<T>::digits);
}

template<std::integral T>
T saturateInteger(double number)
{
    if (std::isnan(number))
        return 0;
    constexpr auto min = std::numeric_limits<T>::min();
    constexpr auto max = std::numeric_limits<T>::max();
    if (number <= static_cast<double>(min))
        return min;
    if (number >= static_cast<double>(max))
        return max;
    return static_cast<T>(number);
}

template<std::integral T>
std::optional<T> tryBigIntToInt(JSC::JSValue value)
{
    using Wide = std::conditional_t<std::is_signed_v<T>, std::int64_t, std::uint64_t>;
    static constexpr Wide minInt = std::numeric_limits<T>::min();
    static constexpr Wide maxInt = std::numeric_limits<T>::max();
    using ComparisonResult = JSC::JSBigInt::ComparisonResult;
    if (JSC::JSBigInt::compare(value, minInt) != ComparisonResult::LessThan
        && JSC::JSBigInt::compare(value, maxInt) != ComparisonResult::GreaterThan) {
        if constexpr (std::is_signed_v<T>)
            return static_cast<T>(JSC::JSBigInt::toBigInt64(value));
        else
            return static_cast<T>(JSC::JSBigInt::toBigUInt64(value));
    }
    return std::nullopt;
}
}

template<std::integral T>
    requires(sizeof(T) <= sizeof(std::uint64_t))
struct WebCore::Converter<Bun::IDLBigIntInteger<T>>
    : Bun::DefaultTryConverter<Bun::IDLBigIntInteger<T>> {


    template<Bun::IDLConversionContext Ctx>
    static std::optional<T> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (!value.isBigInt())
            return std::nullopt;
        if (auto result = Bun::Detail::tryBigIntToInt<T>(value))
            return *result;

        auto& vm = JSC::getVM(&globalObject);
        auto scope = DECLARE_THROW_SCOPE(vm);
        ctx.throwBigIntOutOfRange(globalObject, scope, std::numeric_limits<T>::min(), std::numeric_limits<T>::max());
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotBigInt(globalObject, scope);
    }
};

template<std::integral T>
    requires(sizeof(T) <= sizeof(std::uint64_t))
struct WebCore::Converter<Bun::IDLStrictInteger<T>>
    : Bun::DefaultTryConverter<Bun::IDLStrictInteger<T>> {


    template<Bun::IDLConversionContext Ctx>
    static std::optional<T> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        static constexpr auto minInt = std::numeric_limits<T>::min();
        static constexpr auto maxInt = std::numeric_limits<T>::max();
        static constexpr auto maxSafeInteger = 9007199254740991LL;

        auto& vm = JSC::getVM(&globalObject);
        auto scope = DECLARE_THROW_SCOPE(vm);

        if (value.isInt32()) {
            auto intValue = value.asInt32();
            if (std::in_range<T>(intValue)) {
                return static_cast<T>(intValue);
            }
            ctx.throwIntegerOutOfRange(globalObject, scope, intValue, minInt, maxInt);
            return {};
        }

        using Largest = std::conditional_t<std::signed_integral<T>, std::int64_t, std::uint64_t>;
        if (value.isBigInt()) {
            if (auto result = Bun::Detail::tryBigIntToInt<T>(value)) {
                return *result;
            }
            if constexpr (maxInt < std::numeric_limits<Largest>::max()) {
                if (auto result = Bun::Detail::tryBigIntToInt<Largest>(value)) {
                    ctx.throwIntegerOutOfRange(globalObject, scope, *result, minInt, maxInt);
                    return std::nullopt;
                }
            }
            ctx.throwBigIntOutOfRange(globalObject, scope, minInt, maxInt);
            return {};
        }

        if (!value.isNumber()) {
            return std::nullopt;
        }

        double number = value.asNumber();
        if (!std::isfinite(number) || std::trunc(number) != number) {
            ctx.throwNumberNotInteger(globalObject, scope, number);
            return {};
        }
        if (number > maxSafeInteger || number < -maxSafeInteger) {
            ctx.throwNumberNotSafeInteger(globalObject, scope, number);
            return std::nullopt;
        }
        auto intVal = static_cast<std::int64_t>(number);
        if (std::in_range<T>(intVal)) {
            return static_cast<T>(intVal);
        }
        ctx.throwIntegerOutOfRange(globalObject, scope, intVal, minInt, maxInt);
        return {};
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotNumberOrBigInt(globalObject, scope);
    }
};

template<>
struct WebCore::Converter<Bun::IDLStrictDouble> : Bun::NumberTryConverter<Bun::IDLStrictDouble> {
    template<Bun::IDLConversionContext Ctx>
    static std::optional<double> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (value.isNumber()) {
            return value.asNumber();
        }
        return std::nullopt;
    }
};

template<>
struct WebCore::Converter<Bun::IDLIntegerOrInfinity> : WebCore::DefaultConverter<Bun::IDLIntegerOrInfinity> {
    static double convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value)
    {
        return value.toIntegerOrInfinity(&globalObject);
    }
};

template<std::integral T>
struct WebCore::Converter<Bun::IDLLooseInteger<T>>
    : Bun::DefaultContextConverter<Bun::IDLLooseInteger<T>> {

    using Bun::DefaultContextConverter<Bun::IDLLooseInteger<T>>::convert;

    template<Bun::IDLConversionContext Ctx>
    static T convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx&)
    {
        auto& vm = JSC::getVM(&globalObject);
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto numeric = value.toNumeric(&globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        if (numeric.isBigInt()) {
            if constexpr (std::signed_integral<T>)
                return static_cast<T>(JSC::JSBigInt::toBigInt64(numeric));
            else
                return static_cast<T>(JSC::JSBigInt::toBigUInt64(numeric));
        }

        return Bun::Detail::saturateInteger<T>(numeric.asNumber());
    }
};

template<std::integral T>
struct WebCore::Converter<Bun::IDLToInt32Saturated<T>>
    : Bun::DefaultContextConverter<Bun::IDLToInt32Saturated<T>> {

    using Bun::DefaultContextConverter<Bun::IDLToInt32Saturated<T>>::convert;

    template<Bun::IDLConversionContext Ctx>
    static T convert(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Ctx&)
    {
        auto& vm = JSC::getVM(&globalObject);
        auto scope = DECLARE_THROW_SCOPE(vm);
        int32_t number = value.toInt32(&globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        static constexpr auto minInt = std::numeric_limits<T>::min();
        static constexpr auto maxInt = std::numeric_limits<T>::max();
        if (std::cmp_less(number, minInt))
            return minInt;
        if (std::cmp_greater(number, maxInt))
            return maxInt;
        return static_cast<T>(number);
    }
};
