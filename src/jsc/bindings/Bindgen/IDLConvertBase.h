#pragma once
#include <BunIDLConvertBase.h>
#include <ErrorBindings.h>
#include <ErrorCode.h>
#include <utility>
#include <wtf/text/MakeString.h>

namespace Bun::Bindgen {

namespace Detail {

template<typename Derived>
struct ExactContextBase : Bun::IDLConversionContextBase<Derived> {
    void throwNumberNotInteger(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, double value)
    {
        this->throwTypeErrorWithPredicate(
            global,
            scope,
            WTF::makeString("must be an integer (received "_s, value, ')'));
    }
};

template<typename Derived>
struct ContextBase : Bun::IDLConversionContextBase<Derived> {
    void setValue(JSC::JSValue value)
    {
        m_value = value;
    }

    void throwNumberNotInteger(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, double)
    {
        throwRange(global, scope, "an integer"_s);
    }

    template<typename Number, std::integral Limit>
        requires(std::integral<Number> || std::floating_point<Number>)
    void throwIntegerOutOfRange(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        Number,
        Limit min,
        Limit max)
    {
        constexpr auto conjunction = Derived::usesProseIntegerRanges ? " and <= "_s : " && <= "_s;
        auto predicate = tryMakeString(">= "_s, min, conjunction, max);
        if (predicate.isNull())
            Bun::Bindgen::throwBindingOutOfMemoryError(&global, scope);
        else
            throwRange(global, scope, predicate);
    }

    template<std::integral Limit>
    void throwBigIntOutOfRange(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        Limit min,
        Limit max)
    {
        throwIntegerOutOfRange(global, scope, 0, min, max);
    }

    template<typename String>
    void throwTypeMustBe(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& expectedNounPhrase)
    {
        Bun::ERR::INVALID_ARG_TYPE(
            scope,
            &global,
            sourceString(),
            normalizeExpectedType(std::forward<String>(expectedNounPhrase)),
            value());
    }

    template<typename String>
    void throwTypeErrorWithPredicate(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& predicate)
    {
        auto expected = WTF::makeString(std::forward<String>(predicate));
        if (expected.startsWith("must be of type "_s))
            expected = expected.substring(16);
        else if (expected.startsWith("must be "_s))
            expected = expected.substring(8);
        else if (expected == "is required"_s)
            expected = "a value"_s;
        else if (expected == "is of an unsupported type"_s)
            expected = "a supported value"_s;
        throwTypeMustBe(global, scope, expected);
    }

    template<typename String>
    void throwRangeErrorWithPredicate(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& predicate)
    {
        auto requirement = WTF::makeString(std::forward<String>(predicate));
        if (requirement.startsWith("must be "_s))
            requirement = requirement.substring(8);
        throwRange(global, scope, requirement);
    }

    void throwInvalidArgumentValueRangeError(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope)
    {
        Bun::ERR::INVALID_ARG_VALUE_RangeError(scope, &global, sourceString(), value());
    }

    template<typename String>
    void throwGenericTypeError(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& message)
    {
        Bun::throwError(
            &global,
            scope,
            ErrorCode::ERR_INVALID_ARG_TYPE,
            std::forward<String>(message));
    }

    template<typename String>
    void throwGenericRangeError(
        JSC::JSGlobalObject& global,
        JSC::ThrowScope& scope,
        String&& message)
    {
        Bun::throwError(&global, scope, ErrorCode::ERR_OUT_OF_RANGE, std::forward<String>(message));
    }

private:
    Derived& derived() { return *static_cast<Derived*>(this); }

    JSC::JSValue value() const
    {
        RELEASE_ASSERT(!m_value.isEmpty());
        return m_value;
    }

    WTF::String sourceString()
    {
        return WTF::makeString(derived().source());
    }

    template<typename String>
    static WTF::String normalizeExpectedType(String&& expectedNounPhrase)
    {
        auto expected = WTF::makeString(std::forward<String>(expectedNounPhrase));
        if (expected.startsWith("an "_s))
            expected = expected.substring(3);
        else if (expected.startsWith("a "_s))
            expected = expected.substring(2);
        if (expected == "array"_s)
            return "Array"_s;
        if (expected.startsWith("array of "_s))
            return WTF::makeString("Array of "_s, expected.substring(9));
        return expected;
    }

    template<typename String>
    void throwRange(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, String&& requirement)
    {
        Bun::ERR::OUT_OF_RANGE(
            scope,
            &global,
            sourceString(),
            WTF::makeString(std::forward<String>(requirement)),
            value());
    }

    JSC::JSValue m_value;
};


}

template<typename Derived>
struct PredicateContextBase : Detail::ContextBase<Derived> {
    using Predicates = Bun::IDLConversionContextBase<Derived>;
    using Predicates::throwNumberNotInteger;
    using Predicates::throwIntegerOutOfRange;
    using Predicates::throwBigIntOutOfRange;
    using Predicates::throwRangeErrorWithPredicate;
};

template<typename Source, template<typename> class Base, bool Prose = false>
struct NamedConversionContext : Base<NamedConversionContext<Source, Base, Prose>> {
    static constexpr bool usesProseIntegerRanges = Prose;

    explicit constexpr NamedConversionContext(Source name)
        : m_name(std::move(name))
    {
    }

    const Source& source() const { return m_name; }

private:
    const Source m_name;
};

template<typename Source>
using PredicateConversionContext = NamedConversionContext<Source, PredicateContextBase>;

using PredicateLiteralConversionContext = PredicateConversionContext<WTF::ASCIILiteral>;
using PredicateStringConversionContext = PredicateConversionContext<WTF::String>;
using LiteralConversionContext = NamedConversionContext<WTF::ASCIILiteral, Detail::ContextBase>;
using StringConversionContext = NamedConversionContext<WTF::String, Detail::ContextBase>;
using ProseLiteralConversionContext = NamedConversionContext<WTF::ASCIILiteral, Detail::ContextBase, true>;
using ProseStringConversionContext = NamedConversionContext<WTF::String, Detail::ContextBase, true>;
using ExactLiteralConversionContext = NamedConversionContext<WTF::ASCIILiteral, Detail::ExactContextBase>;
using ExactStringConversionContext = NamedConversionContext<WTF::String, Detail::ExactContextBase>;

}
