#include "config.h"
#include "JSCookie.h"
#include "StringConversion.h"

#include "HTTPParsers.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/DateMath.h>

namespace WebCore {

using namespace JSC;

RefPtr<Cookie> protectedCookie(JSGlobalObject* global, JSValue value)
{
    auto* cookie = Bun::Bindgen::ZigExports::bunBindgenZig_cookie_cookieRetainFromWrapper(global, value);
    if (!cookie)
        return nullptr;
    return adoptRef(*cookie);
}

JSValue getInternalProperties(VM& vm, JSGlobalObject* global, JSCookie* wrapper)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto protectedValue = protectedCookie(global, wrapper);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(protectedValue);
    auto* object = constructEmptyObject(vm, global->nullPrototypeObjectStructure());
    RETURN_IF_EXCEPTION(scope, {});
    const auto& cookie = *protectedValue;
    auto& names = Bun::builtinNames(vm);
    const auto putString = [&](const Identifier& key, const String& text) {
        auto* value = jsString(vm, text);
        if (scope.exception())
            return false;
        object->putDirect(vm, key, value);
        return !scope.exception();
    };
    if (!putString(vm.propertyNames->name, cookie.name())
        || !putString(vm.propertyNames->value, cookie.value())
        || (!cookie.domain().isEmpty() && !putString(names.domainPublicName(), cookie.domain()))
        || !putString(names.pathPublicName(), cookie.path()))
        return {};
    if (auto expires = cookie.expires()) {
        auto* date = DateInstance::create(vm, global->dateStructure(), *expires);
        RETURN_IF_EXCEPTION(scope, {});
        object->putDirect(vm, names.expiresPublicName(), date);
        RETURN_IF_EXCEPTION(scope, {});
    }
    if (auto maxAge = cookie.maxAge()) {
        object->putDirect(vm, names.maxAgePublicName(), jsNumber(*maxAge));
        RETURN_IF_EXCEPTION(scope, {});
    }
    object->putDirect(vm, names.securePublicName(), jsBoolean(cookie.secure()));
    RETURN_IF_EXCEPTION(scope, {});
    String sameSite;
    switch (cookie.sameSite()) {
    case CookieSameSite::strict:
        sameSite = "strict"_s;
        break;
    case CookieSameSite::lax:
        sameSite = "lax"_s;
        break;
    case CookieSameSite::none:
        sameSite = "none"_s;
        break;
    }
    if (!putString(names.sameSitePublicName(), sameSite))
        return {};
    object->putDirect(vm, names.httpOnlyPublicName(), jsBoolean(cookie.httpOnly()));
    RETURN_IF_EXCEPTION(scope, {});
    object->putDirect(vm, names.partitionedPublicName(), jsBoolean(cookie.partitioned()));
    RETURN_IF_EXCEPTION(scope, {});
    return object;
}

} // namespace WebCore

namespace Bun::Bindgen::Custom {

std::optional<int64_t> bunBindgenCookieExpires(
    JSC::JSGlobalObject& global,
    const std::optional<Bun::Bindgen::CookieExpiresInput>& input,
    WTF::ASCIILiteral)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (!input)
        return std::nullopt;

    if (input->is_date()) {
        auto* date = dynamicDowncast<JSC::DateInstance>(input->date());
        RELEASE_ASSERT(date);
        const double milliseconds = date->internalNumber();
        if (!WebCore::Cookie::isValidExpiration(milliseconds)) [[unlikely]] {
            JSC::throwRangeError(&global, scope, "expires must be a valid Date (or Number)"_s);
            return std::nullopt;
        }
        return static_cast<int64_t>(milliseconds);
    }

    if (input->is_number()) {
        const double milliseconds = input->number() * 1000;
        if (!WebCore::Cookie::isValidExpiration(milliseconds)) [[unlikely]] {
            JSC::throwRangeError(&global, scope, "expires must be a valid Number (or Date)"_s);
            return std::nullopt;
        }
        return static_cast<int64_t>(milliseconds);
    }

    RELEASE_ASSERT(input->is_string());
    auto utf8 = Bun::encodeUTF8ReplacingInvalidSequences(input->string());
    if (!utf8) {
        RELEASE_ASSERT(utf8.error() == WTF::UTF8ConversionError::OutOfMemory);
        JSC::throwOutOfMemoryError(&global, scope);
        return std::nullopt;
    }
    const auto parsed = WTF::parseDate(std::span<const Latin1Character>(
        reinterpret_cast<const Latin1Character*>(utf8->span().data()), utf8->size()));
    if (WebCore::Cookie::isValidExpiration(parsed))
        return static_cast<int64_t>(parsed);
    JSC::throwTypeError(&global, scope, "Invalid cookie expiration date"_s);
    return std::nullopt;
}

} // namespace Bun::Bindgen::Custom

namespace Bun::Bindgen::Engine {

using namespace JSC;
using namespace WebCore;

static Cookie* finishCookieCreation(
    EngineCallContext& context,
    ExceptionOr<Ref<Cookie>>&& result)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (result.hasException()) [[unlikely]] {
        propagateException(context.globalObject, scope, result.releaseException());
        return nullptr;
    }

    return &result.releaseReturnValue().leakRef();
}

Cookie* bunBindgenEngine_cookie_cookieCreate(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieCreate_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (args.name.isEmpty()) {
        JSC::throwTypeError(&context.globalObject, scope, "name is required"_s);
        return nullptr;
    }
    CookieInit init;
    init.name = args.name;
    if (args.value)
        init.value = *args.value;
    if (args.domain)
        init.domain = *args.domain;
    if (args.path)
        init.path = *args.path;
    init.expires = args.expires;
    init.secure = args.secure;
    init.sameSite = args.same_site;
    init.httpOnly = args.http_only;
    init.maxAge = args.max_age;
    init.partitioned = args.partitioned;
    RELEASE_AND_RETURN(scope, finishCookieCreation(context, Cookie::create(init)));
}

Cookie* bunBindgenEngine_cookie_cookieParse(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieParse_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (!WebCore::isValidHTTPHeaderValue(args.input)) [[unlikely]] {
        JSC::throwTypeError(&context.globalObject, scope, "cookie string is not a valid HTTP header value"_s);
        return nullptr;
    }
    RELEASE_AND_RETURN(scope, finishCookieCreation(context, Cookie::parse(args.input)));
}

Cookie* bunBindgenEngine_cookie_cookieRetain(const BunBindgenEngine_cookie_cookieRetain_Arguments& args)
{
    args.cookie->ref();
    return args.cookie;
}

void releaseCookie(Cookie* cookie)
{
    cookie->deref();
}

size_t bunBindgenEngine_cookie_cookieMemoryCost(const BunBindgenEngine_cookie_cookieMemoryCost_Arguments& args)
{
    return args.cookie->memoryCost();
}

WTF::String bunBindgenEngine_cookie_cookieName(const BunBindgenEngine_cookie_cookieName_Arguments& args)
{
    return args.cookie->name();
}

WTF::String bunBindgenEngine_cookie_cookieValue(const BunBindgenEngine_cookie_cookieValue_Arguments& args)
{
    return args.cookie->value();
}

void bunBindgenEngine_cookie_cookieSetValue(const BunBindgenEngine_cookie_cookieSetValue_Arguments& args)
{
    args.cookie->setValue(args.value);
}

std::optional<WTF::String> bunBindgenEngine_cookie_cookieDomain(const BunBindgenEngine_cookie_cookieDomain_Arguments& args)
{
    auto domain = args.cookie->domain();
    if (domain.isNull())
        return std::nullopt;
    return domain;
}

void bunBindgenEngine_cookie_cookieSetDomain(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieSetDomain_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    propagateException(context.globalObject, scope, args.cookie->setDomain(args.value));
}

WTF::String bunBindgenEngine_cookie_cookiePath(const BunBindgenEngine_cookie_cookiePath_Arguments& args)
{
    return args.cookie->path();
}

void bunBindgenEngine_cookie_cookieSetPath(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieSetPath_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    propagateException(context.globalObject, scope, args.cookie->setPath(args.value));
}

std::optional<JSValue> bunBindgenEngine_cookie_cookieExpires(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieExpires_Arguments& args)
{
    const auto expires = args.cookie->expires();
    if (!expires)
        return std::nullopt;
    return DateInstance::create(context.globalObject.vm(), context.globalObject.dateStructure(), *expires);
}

void bunBindgenEngine_cookie_cookieSetExpires(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieSetExpires_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    propagateException(context.globalObject, scope, args.cookie->setExpires(args.value));
}

bool bunBindgenEngine_cookie_cookieSecure(const BunBindgenEngine_cookie_cookieSecure_Arguments& args)
{
    return args.cookie->secure();
}

void bunBindgenEngine_cookie_cookieSetSecure(const BunBindgenEngine_cookie_cookieSetSecure_Arguments& args)
{
    args.cookie->setSecure(args.value);
}

Bun::Bindgen::CookieSameSite bunBindgenEngine_cookie_cookieSameSite(const BunBindgenEngine_cookie_cookieSameSite_Arguments& args)
{
    return args.cookie->sameSite();
}

void bunBindgenEngine_cookie_cookieSetSameSite(const BunBindgenEngine_cookie_cookieSetSameSite_Arguments& args)
{
    args.cookie->setSameSite(args.value);
}

bool bunBindgenEngine_cookie_cookieHttpOnly(const BunBindgenEngine_cookie_cookieHttpOnly_Arguments& args)
{
    return args.cookie->httpOnly();
}

void bunBindgenEngine_cookie_cookieSetHttpOnly(const BunBindgenEngine_cookie_cookieSetHttpOnly_Arguments& args)
{
    args.cookie->setHttpOnly(args.value);
}

std::optional<double> bunBindgenEngine_cookie_cookieMaxAge(const BunBindgenEngine_cookie_cookieMaxAge_Arguments& args)
{
    return args.cookie->maxAge();
}

void bunBindgenEngine_cookie_cookieSetMaxAge(const BunBindgenEngine_cookie_cookieSetMaxAge_Arguments& args)
{
    args.cookie->setMaxAge(args.value);
}

bool bunBindgenEngine_cookie_cookiePartitioned(const BunBindgenEngine_cookie_cookiePartitioned_Arguments& args)
{
    return args.cookie->partitioned();
}

void bunBindgenEngine_cookie_cookieSetPartitioned(const BunBindgenEngine_cookie_cookieSetPartitioned_Arguments& args)
{
    args.cookie->setPartitioned(args.value);
}

bool bunBindgenEngine_cookie_cookieIsExpired(const BunBindgenEngine_cookie_cookieIsExpired_Arguments& args)
{
    return args.cookie->isExpired();
}

WTF::String bunBindgenEngine_cookie_cookieToString(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieToString_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = args.cookie->toString();
    if (result.hasException()) {
        propagateException(context.globalObject, scope, result.releaseException());
        return {};
    }
    return result.releaseReturnValue();
}

BunBindgenEngine_cookie_cookieJSON_Return bunBindgenEngine_cookie_cookieJSON(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_cookieJSON_Arguments& args)
{
    auto& global = context.globalObject;
    auto& cookie = *args.cookie;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    std::optional<JSValue> expires;
    if (const auto milliseconds = cookie.expires()) {
        expires = DateInstance::create(global.vm(), global.dateStructure(), *milliseconds);
        RETURN_IF_EXCEPTION(scope, {});
    }
    return {
        .name = cookie.name(),
        .value = cookie.value(),
        .domain = cookie.domain().isEmpty() ? std::nullopt : std::optional { cookie.domain() },
        .path = cookie.path(),
        .expires = expires,
        .max_age = cookie.maxAge(),
        .secure = cookie.secure(),
        .same_site = cookie.sameSite(),
        .http_only = cookie.httpOnly(),
        .partitioned = cookie.partitioned(),
    };
}

} // namespace Bun::Bindgen::Engine
