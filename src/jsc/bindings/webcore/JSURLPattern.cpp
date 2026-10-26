#include "config.h"
#include "SchemaBindings.h"

#include "JSDOMExceptionHandling.h"
#include "JSDOMGlobalObject.h"
#include "URLPattern.h"
#include "URLPatternOptions.h"
#include "URLPatternResult.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/ObjectConstructor.h>

namespace Bun::Bindgen::Engine {

using namespace JSC;
using namespace WebCore;

static URLPatternInit urlPatternInit(const Bun::Bindgen::URLPatternInitDictionary& input)
{
    URLPatternInit result;
    if (input.protocol)
        result.protocol = *input.protocol;
    if (input.username)
        result.username = *input.username;
    if (input.password)
        result.password = *input.password;
    if (input.hostname)
        result.hostname = *input.hostname;
    if (input.port)
        result.port = *input.port;
    if (input.pathname)
        result.pathname = *input.pathname;
    if (input.search)
        result.search = *input.search;
    if (input.hash)
        result.hash = *input.hash;
    if (input.baseURL)
        result.baseURL = *input.baseURL;
    return result;
}

static URLPattern::URLPatternInput urlPatternInput(const Bun::Bindgen::URLPatternInputValue& input)
{
    switch (input.tag()) {
    case Bun::Bindgen::URLPatternInputValue::Tag::string:
        return String(input.string());
    case Bun::Bindgen::URLPatternInputValue::Tag::init:
        return urlPatternInit(input.init());
    case Bun::Bindgen::URLPatternInputValue::Tag::none:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static std::optional<URLPattern::URLPatternInput> optionalURLPatternInput(const std::optional<Bun::Bindgen::URLPatternInputValue>& input)
{
    if (!input)
        return std::nullopt;
    return urlPatternInput(*input);
}

static RefPtr<ScriptExecutionContext> urlPatternScriptContext(JSGlobalObject& global)
{
    return defaultGlobalObject(&global)->scriptExecutionContext();
}

static URLPattern* finishURLPatternCreation(
    EngineCallContext& context,
    ExceptionOr<std::unique_ptr<URLPattern>>&& result)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (result.hasException()) [[unlikely]] {
        propagateException(context.globalObject, scope, result.releaseException());
        return nullptr;
    }

    return result.releaseReturnValue().release();
}

void releaseURLPattern(URLPattern* pattern)
{
    delete pattern;
}

URLPattern* bunBindgenEngine_url_pattern_urlPatternCreateWithBase(
    EngineCallContext& context,
    const BunBindgenEngine_url_pattern_urlPatternCreateWithBase_Arguments& args)
{
    auto scriptContext = urlPatternScriptContext(context.globalObject);
    if (!scriptContext) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwConstructorScriptExecutionContextUnavailableError(context.globalObject, scope, "URLPattern"_s);
        return nullptr;
    }
    return finishURLPatternCreation(context, URLPattern::create(
                                            *scriptContext,
                                            urlPatternInput(args.input),
                                            String(args.baseURL),
                                            URLPatternOptions { .ignoreCase = args.ignoreCase }));
}

URLPattern* bunBindgenEngine_url_pattern_urlPatternCreate(
    EngineCallContext& context,
    const BunBindgenEngine_url_pattern_urlPatternCreate_Arguments& args)
{
    auto scriptContext = urlPatternScriptContext(context.globalObject);
    if (!scriptContext) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwConstructorScriptExecutionContextUnavailableError(context.globalObject, scope, "URLPattern"_s);
        return nullptr;
    }
    return finishURLPatternCreation(context, URLPattern::create(
                                            *scriptContext,
                                            optionalURLPatternInput(args.input),
                                            URLPatternOptions { .ignoreCase = args.ignoreCase }));
}

WTF::String bunBindgenEngine_url_pattern_urlPatternProtocol(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternProtocol_Arguments& args)
{
    return args.pattern->protocol();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternUsername(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternUsername_Arguments& args)
{
    return args.pattern->username();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternPassword(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternPassword_Arguments& args)
{
    return args.pattern->password();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternHostname(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternHostname_Arguments& args)
{
    return args.pattern->hostname();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternPort(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternPort_Arguments& args)
{
    return args.pattern->port();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternPathname(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternPathname_Arguments& args)
{
    return args.pattern->pathname();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternSearch(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternSearch_Arguments& args)
{
    return args.pattern->search();
}

WTF::String bunBindgenEngine_url_pattern_urlPatternHash(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternHash_Arguments& args)
{
    return args.pattern->hash();
}

bool bunBindgenEngine_url_pattern_urlPatternHasRegExpGroups(
    EngineCallContext&,
    const BunBindgenEngine_url_pattern_urlPatternHasRegExpGroups_Arguments& args)
{
    return args.pattern->hasRegExpGroups();
}

bool bunBindgenEngine_url_pattern_urlPatternTest(
    EngineCallContext& context,
    const BunBindgenEngine_url_pattern_urlPatternTest_Arguments& args)
{
    auto scriptContext = urlPatternScriptContext(context.globalObject);
    if (!scriptContext) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwTypeError(&context.globalObject, scope, "URLPattern is unavailable without a script execution context"_s);
        return false;
    }
    auto result = args.pattern->test(
        *scriptContext,
        optionalURLPatternInput(args.input),
        args.baseURL.value_or(String {}));
    if (result.hasException()) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        propagateException(context.globalObject, scope, result.releaseException());
        return false;
    }
    return result.releaseReturnValue();
}

static std::optional<WTF::String> optionalResultString(const WTF::String& value)
{
    if (value.isNull())
        return std::nullopt;
    return value;
}

static URLPatternInitDictionaryResult bindingURLPatternInit(const URLPatternInit& input)
{
    return {
        .protocol = optionalResultString(input.protocol),
        .username = optionalResultString(input.username),
        .password = optionalResultString(input.password),
        .hostname = optionalResultString(input.hostname),
        .port = optionalResultString(input.port),
        .pathname = optionalResultString(input.pathname),
        .search = optionalResultString(input.search),
        .hash = optionalResultString(input.hash),
        .baseURL = optionalResultString(input.baseURL),
    };
}

static URLPatternInputValueResult bindingURLPatternInput(const URLPattern::URLPatternInput& input)
{
    URLPatternInputValueResult result;
    WTF::switchOn(input,
        [&](const String& string) { result.set_string(string); },
        [&](const URLPatternInit& init) { result.set_init(bindingURLPatternInit(init)); });
    return result;
}

static bool bindingURLPatternComponentResult(const URLPatternComponentResult& input, URLPatternComponentResultDictionaryResult& output)
{
    WTF::Vector<std::pair<WTF::String, std::optional<WTF::String>>> groups;
    if (!groups.tryReserveInitialCapacity(input.groups.size()))
        return false;
    for (const auto& pair : input.groups) {
        auto value = WTF::switchOn(pair.value,
            [](std::monostate) -> std::optional<WTF::String> { return std::nullopt; },
            [](const String& string) -> std::optional<WTF::String> { return string; });
        groups.unsafeAppendWithoutCapacityCheck({ pair.key, WTF::move(value) });
    }
    output = { .input = input.input, .groups = WTF::move(groups) };
    return true;
}

static ExceptionOr<URLPatternResultDictionaryResult> bindingURLPatternResult(URLPatternResult&& input)
{
    WTF::Vector<URLPatternInputValueResult> inputs;
    if (!inputs.tryReserveInitialCapacity(input.inputs.size()))
        return WebCore::Exception { WebCore::OutOfMemoryError };
    for (const auto& value : input.inputs)
        inputs.unsafeAppendWithoutCapacityCheck(bindingURLPatternInput(value));
    URLPatternResultDictionaryResult result { .inputs = WTF::move(inputs) };
    if (!bindingURLPatternComponentResult(input.protocol, result.protocol)
        || !bindingURLPatternComponentResult(input.username, result.username)
        || !bindingURLPatternComponentResult(input.password, result.password)
        || !bindingURLPatternComponentResult(input.hostname, result.hostname)
        || !bindingURLPatternComponentResult(input.port, result.port)
        || !bindingURLPatternComponentResult(input.pathname, result.pathname)
        || !bindingURLPatternComponentResult(input.search, result.search)
        || !bindingURLPatternComponentResult(input.hash, result.hash))
        return WebCore::Exception { WebCore::OutOfMemoryError };
    return result;
}

BunBindgenEngine_url_pattern_urlPatternExec_Return bunBindgenEngine_url_pattern_urlPatternExec(
    EngineCallContext& context,
    const BunBindgenEngine_url_pattern_urlPatternExec_Arguments& args)
{
    auto scriptContext = urlPatternScriptContext(context.globalObject);
    if (!scriptContext) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwTypeError(&context.globalObject, scope, "URLPattern is unavailable without a script execution context"_s);
        return {};
    }
    auto result = args.pattern->exec(
        *scriptContext,
        optionalURLPatternInput(args.input),
        args.baseURL.value_or(String {}));
    if (result.hasException()) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        propagateException(context.globalObject, scope, result.releaseException());
        return {};
    }
    auto matched = result.releaseReturnValue();
    if (!matched)
        return std::nullopt;
    auto converted = bindingURLPatternResult(WTF::move(*matched));
    if (converted.hasException()) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        propagateException(context.globalObject, scope, converted.releaseException());
        return {};
    }
    return converted.releaseReturnValue();
}

} // namespace Bun::Bindgen::Engine
