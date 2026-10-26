#pragma once
#include "BunIDLTypes.h"
#include "BunIDLConvertBase.h"
#include "BunIDLConvertNumbers.h"
#include "JSDOMConvert.h"

template<> struct WebCore::Converter<Bun::IDLStrictBoolean>
    : Bun::DefaultTryConverter<Bun::IDLStrictBoolean> {


    template<Bun::IDLConversionContext Ctx>
    static std::optional<bool> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (value.isBoolean()) {
            return value.asBoolean();
        }
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotBoolean(globalObject, scope);
    }
};

template<> struct WebCore::Converter<Bun::IDLStrictString>
    : Bun::DefaultTryConverter<Bun::IDLStrictString> {


    template<Bun::IDLConversionContext Ctx>
    static std::optional<WTF::String> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (value.isString()) {
            return value.toWTFString(&globalObject);
        }
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotString(globalObject, scope);
    }
};

template<> struct WebCore::Converter<Bun::IDLStrictUSVString>
    : Bun::DefaultTryConverter<Bun::IDLStrictUSVString> {


    template<Bun::IDLConversionContext Ctx>
    static std::optional<WTF::String> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (value.isString())
            return WebCore::valueToUSVString(globalObject, value);
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotString(globalObject, scope);
    }
};

template<> struct WebCore::Converter<Bun::IDLStrictByteString>
    : Bun::DefaultTryConverter<Bun::IDLStrictByteString> {


    template<Bun::IDLConversionContext Ctx>
    static std::optional<WTF::String> tryConvert(
        JSC::JSGlobalObject& globalObject,
        JSC::JSValue value,
        Ctx& ctx)
    {
        if (value.isString())
            return WebCore::valueToByteString(globalObject, value);
        return std::nullopt;
    }

    template<Bun::IDLConversionContext Ctx>
    static void throwConversionFailed(
        JSC::JSGlobalObject& globalObject,
        JSC::ThrowScope& scope,
        Ctx& ctx)
    {
        ctx.throwNotString(globalObject, scope);
    }
};
