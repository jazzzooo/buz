#include "root.h"

#include "SchemaBindings.h"
#include "URLDecomposition.h"
#include <wtf/FastMalloc.h>
#include <wtf/URL.h>
#include <wtf/text/MakeString.h>

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlFileURLFromString_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlFileURLFromString(
    const BunBindgenEngine_urls_urlFileURLFromString_Arguments& args)
{
    return WTF::URL::fileURLWithFileSystemPath(args.input).string();
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlOriginFromString_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlOriginFromString(
    const BunBindgenEngine_urls_urlOriginFromString_Arguments& args)
{
    WTF::URL url { args.input };
    if (!url.isValid())
        return std::nullopt;
    auto origin = WebCore::URLDecomposition::origin(url);
    if (origin.hasException()) {
        RELEASE_ASSERT(origin.releaseException().code() == WebCore::OutOfMemoryError);
        return Bun::Bindgen::nativeAllocationFailure();
    }
    return origin.releaseReturnValue();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_urls_bunStringToJSDOMURL(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_urls_bunStringToJSDOMURL_Arguments& args)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_urls_domURLFromString(&context.globalObject, args.value);
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlHrefFromString_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlHrefFromString(
    const BunBindgenEngine_urls_urlHrefFromString_Arguments& args)
{
    WTF::URL url { args.input };
    if (!url.isValid())
        return std::nullopt;

    return url.string();
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlPathFromFileURL_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlPathFromFileURL(
    const BunBindgenEngine_urls_urlPathFromFileURL_Arguments& args)
{
    WTF::URL url { args.input };
    if (!url.isValid())
        return std::nullopt;

    auto path = url.fileSystemPath();
    return path.isNull() ? WTF::String(emptyString()) : WTF::move(path);
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlJoin_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlJoin(
    const BunBindgenEngine_urls_urlJoin_Arguments& args)
{
    WTF::URL base { args.base };
    WTF::URL url { base.isValid() ? base : WTF::URL { }, args.relative };
    if (!url.isValid())
        return std::nullopt;

    return url.string();
}

static Bun::Bindgen::NativeAllocationResult<WTF::String> copyURLComponent(WTF::StringView value)
{
    auto result = WTF::tryMakeString(value);
    if (result.isNull())
        return Bun::Bindgen::nativeAllocationFailure();
    return result;
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlHash_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlHash(
    const BunBindgenEngine_urls_urlHash_Arguments& args)
{
    return copyURLComponent(args.url->fragmentIdentifier().isEmpty()
        ? WTF::StringView { }
        : args.url->fragmentIdentifierWithLeadingNumberSign());
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlFragmentIdentifier_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlFragmentIdentifier(
    const BunBindgenEngine_urls_urlFragmentIdentifier_Arguments& args)
{
    return copyURLComponent(args.url->fragmentIdentifier());
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlFromString_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlFromString(
    const BunBindgenEngine_urls_urlFromString_Arguments& args)
{
    WTF::URL url { args.input };
    if (!url.isValid())
        return std::nullopt;

    void* allocation = nullptr;
    if (!WTF::tryFastMalloc(sizeof(WTF::URL)).getValue(allocation))
        return Bun::Bindgen::nativeAllocationFailure();
    return ::new (allocation) WTF::URL(WTF::move(url));
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlProtocol_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlProtocol(
    const BunBindgenEngine_urls_urlProtocol_Arguments& args)
{
    return copyURLComponent(args.url->protocol());
}

void Bun::Bindgen::Engine::releaseURL(WTF::URL* url)
{
    url->~URL();
    WTF::fastFree(url);
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlHref_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlHref(
    const BunBindgenEngine_urls_urlHref_Arguments& args)
{
    return args.url->string();
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlUsername_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlUsername(
    const BunBindgenEngine_urls_urlUsername_Arguments& args)
{
    auto result = args.url->user();
    return result.isNull() ? WTF::String(emptyString()) : WTF::move(result);
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlPassword_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlPassword(
    const BunBindgenEngine_urls_urlPassword_Arguments& args)
{
    auto result = args.url->password();
    return result.isNull() ? WTF::String(emptyString()) : WTF::move(result);
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlSearch_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlSearch(
    const BunBindgenEngine_urls_urlSearch_Arguments& args)
{
    return copyURLComponent(args.url->query());
}

/// Returns the host WITHOUT the port.
///
/// Note that this does NOT match JS behavior, which returns the host with the port.
///
/// ```
/// URL("http://example.com:8080").host() => "example.com"
/// ```
Bun::Bindgen::Engine::BunBindgenEngine_urls_urlHost_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlHost(
    const BunBindgenEngine_urls_urlHost_Arguments& args)
{
    return copyURLComponent(args.url->host());
}

/// Returns the host WITH the port.
///
/// Note that this does NOT match JS behavior which returns the host without the port.
///
/// ```
/// URL("http://example.com:8080").hostname() => "example.com:8080"
/// ```
Bun::Bindgen::Engine::BunBindgenEngine_urls_urlHostname_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlHostname(
    const BunBindgenEngine_urls_urlHostname_Arguments& args)
{
    return args.url->hostAndPort();
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlPort_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlPort(
    const BunBindgenEngine_urls_urlPort_Arguments& args)
{
    return args.url->port();
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlPathname_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlPathname(
    const BunBindgenEngine_urls_urlPathname_Arguments& args)
{
    return copyURLComponent(args.url->path());
}

