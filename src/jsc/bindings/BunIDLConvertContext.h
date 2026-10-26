#pragma once
#include <JavaScriptCore/Error.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/MakeString.h>
#include <concepts>
#include <utility>

namespace Bun {

namespace Detail {
struct IDLConversionContextMarker {};
}

template<typename T>
concept IDLConversionContext = std::derived_from<T, Detail::IDLConversionContextMarker>;

template<typename Derived>
struct IDLConversionContextBase : Detail::IDLConversionContextMarker {
    void throwNumberNotInteger(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, double value)
    {
        derived().throwRangeErrorWithPredicate(
            global,
            scope,
            WTF::makeString("must be an integer (received "_s, value, ')'));
    }

    template<typename Number, std::integral Limit>
        requires(std::integral<Number> || std::floating_point<Number>)
    void throwIntegerOutOfRange(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        Number value,
        Limit min,
        Limit max)
    {
        derived().throwRangeErrorWithPredicate(
            global,
            scope,
            WTF::makeString(
                "must be in the range ["_s,
                min,
                ", "_s,
                max,
                "] (received "_s,
                value,
                ')'));
    }

    template<std::integral Limit>
    void throwBigIntOutOfRange(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        Limit min,
        Limit max)
    {
        derived().throwRangeErrorWithPredicate(
            global,
            scope,
            WTF::makeString(
                "must be in the range ["_s,
                min,
                ", "_s,
                max,
                ']'));
    }

    void throwNotNumber(JSC::JSGlobalObject& global, JSC::ThrowScope& scope)
    {
        derived().throwTypeMustBe(global, scope, "a number"_s);
    }

    void throwNotBigInt(JSC::JSGlobalObject& global, JSC::ThrowScope& scope)
    {
        derived().throwTypeMustBe(global, scope, "a bigint"_s);
    }

    void throwNotNumberOrBigInt(JSC::JSGlobalObject& global, JSC::ThrowScope& scope)
    {
        derived().throwTypeMustBe(global, scope, "a number or bigint"_s);
    }

    void throwNumberNotSafeInteger(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, double value)
    {
        derived().throwRangeErrorWithPredicate(
            global,
            scope,
            WTF::makeString("must be a safe integer; use bigint for larger values (received "_s, value, ')'));
    }

    void throwNotString(JSC::JSGlobalObject& global, JSC::ThrowScope& scope)
    {
        derived().throwTypeMustBe(global, scope, "a string"_s);
    }

    void throwNotBoolean(JSC::JSGlobalObject& global, JSC::ThrowScope& scope)
    {
        derived().throwTypeMustBe(global, scope, "a boolean"_s);
    }

    void throwNotBlob(JSC::JSGlobalObject& global, JSC::ThrowScope& scope)
    {
        derived().throwTypeMustBe(global, scope, "a Blob"_s);
    }

    template<typename String>
    void throwTypeMustBe(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& expectedNounPhrase)
    {
        derived().throwTypeErrorWithPredicate(
            global,
            scope,
            WTF::makeString("must be "_s, std::forward<String>(expectedNounPhrase)));
    }

    template<typename String>
    void throwTypeErrorWithPredicate(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& predicate)
    {
        derived().throwGenericTypeError(
            global,
            scope,
            WTF::makeString(derived().source(), ' ', std::forward<String>(predicate)));
    }

    template<typename String>
    void throwRangeErrorWithPredicate(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& predicate)
    {
        derived().throwGenericRangeError(
            global,
            scope,
            WTF::makeString(derived().source(), ' ', std::forward<String>(predicate)));
    }

    template<typename String>
    void throwGenericTypeError(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& message)
    {
        JSC::throwTypeError(&global, scope, std::forward<String>(message));
    }

    template<typename String>
    void throwGenericRangeError(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& message)
    {
        JSC::throwRangeError(&global, scope, std::forward<String>(message));
    }

private:
    Derived& derived() { return *static_cast<Derived*>(this); }
};

// Default conversion context: throws a plain TypeError or RangeError with the message
// "value must be ...". See also Bindgen::LiteralConversionContext, which uses Bun::throwError.
struct DefaultConversionContext : IDLConversionContextBase<DefaultConversionContext> {
    WTF::ASCIILiteral source() { return "value"_s; }
};

}
