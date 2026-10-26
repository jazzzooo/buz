#include "config.h"
#include "JSDOMURL.h"

#include "SchemaBindings.h"
#include "URLSearchParams.h"

namespace WebCore {

RefPtr<DOMURL> protectedDOMURL(JSC::JSGlobalObject* global, JSC::JSValue value)
{
    auto* url = Bun::Bindgen::ZigExports::bunBindgenZig_urls_domURLRetainFromWrapper(global, value);
    if (!url)
        return nullptr;
    return adoptRef(*url);
}

} // namespace WebCore

namespace Bun::Bindgen::Engine {

using namespace WebCore;

void releaseDOMURL(DOMURL* url)
{
    url->deref();
}

DOMURL* bunBindgenEngine_urls_domURLRetain(const BunBindgenEngine_urls_domURLRetain_Arguments& args)
{
    args.url->ref();
    return args.url;
}

uint64_t bunBindgenEngine_urls_domURLMemoryCost(const BunBindgenEngine_urls_domURLMemoryCost_Arguments& args)
{
    return args.url->memoryCost();
}

static BunBindgenEngine_urls_domURLCreate_Return domURLCreationResult(ExceptionOr<Ref<DOMURL>>&& result)
{
    BunBindgenEngine_urls_domURLCreate_Return::value_type output;
    if (result.hasException()) {
        auto exception = result.releaseException();
        if (exception.code() == OutOfMemoryError)
            return nativeAllocationFailure();
        RELEASE_ASSERT(exception.code() == InvalidURLError);
        output.set_invalid(exception.releaseMessage());
    } else {
        output.set_url(&result.releaseReturnValue().leakRef());
    }
    return output;
}

BunBindgenEngine_urls_domURLCreate_Return bunBindgenEngine_urls_domURLCreate(const BunBindgenEngine_urls_domURLCreate_Arguments& args)
{
    return domURLCreationResult(args.base ? DOMURL::create(args.url, *args.base) : DOMURL::create(args.url));
}

BunBindgenEngine_urls_domURLCreateFromFileSystemPath_Return bunBindgenEngine_urls_domURLCreateFromFileSystemPath(const BunBindgenEngine_urls_domURLCreateFromFileSystemPath_Arguments& args)
{
    return domURLCreationResult(DOMURL::createFromFileSystemPath(args.path));
}

BunBindgenEngine_urls_domURLParse_Return bunBindgenEngine_urls_domURLParse(const BunBindgenEngine_urls_domURLParse_Arguments& args)
{
    auto result = DOMURL::parse(args.url, args.base.value_or(WTF::String {}));
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    auto url = result.releaseReturnValue();
    if (!url)
        return std::nullopt;
    return &url.releaseNonNull().leakRef();
}

BunBindgenEngine_urls_domURLCanParse_Return bunBindgenEngine_urls_domURLCanParse(const BunBindgenEngine_urls_domURLCanParse_Arguments& args)
{
    auto result = DOMURL::canParse(args.url, args.base.value_or(WTF::String {}));
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    return result.releaseReturnValue();
}

static ExceptionOr<WTF::String> getComponent(DOMURL& url, DOMURLComponent component)
{
    switch (component) {
    case DOMURLComponent::href: {
        auto result = url.href();
        if (result.hasException())
            return result.releaseException();
        return WTF::String(result.releaseReturnValue().string());
    }
    case DOMURLComponent::origin: return url.origin();
    case DOMURLComponent::protocol: return url.protocol();
    case DOMURLComponent::username: return url.username();
    case DOMURLComponent::password: return url.password();
    case DOMURLComponent::host: return url.host();
    case DOMURLComponent::hostname: return url.hostname();
    case DOMURLComponent::port: return url.port();
    case DOMURLComponent::pathname: return url.pathname();
    case DOMURLComponent::search: return url.search();
    case DOMURLComponent::hash: return url.hash();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

BunBindgenEngine_urls_domURLGet_Return bunBindgenEngine_urls_domURLGet(const BunBindgenEngine_urls_domURLGet_Arguments& args)
{
    auto result = getComponent(*args.url, args.component);
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    return result.releaseReturnValue();
}

static ExceptionOr<void> setComponent(DOMURL& url, DOMURLMutableComponent component, const WTF::String& value)
{
    switch (component) {
    case DOMURLMutableComponent::protocol: return url.setProtocol(value);
    case DOMURLMutableComponent::username: return url.setUsername(value);
    case DOMURLMutableComponent::password: return url.setPassword(value);
    case DOMURLMutableComponent::host: return url.setHost(value);
    case DOMURLMutableComponent::hostname: return url.setHostname(value);
    case DOMURLMutableComponent::port: return url.setPort(value);
    case DOMURLMutableComponent::pathname: return url.setPathname(value);
    case DOMURLMutableComponent::search: return url.setSearch(value);
    case DOMURLMutableComponent::hash: return url.setHash(value);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

BunBindgenEngine_urls_domURLSet_Return bunBindgenEngine_urls_domURLSet(const BunBindgenEngine_urls_domURLSet_Arguments& args)
{
    auto result = setComponent(*args.url, args.component, args.value);
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    return { };
}

BunBindgenEngine_urls_domURLSetHref_Return bunBindgenEngine_urls_domURLSetHref(const BunBindgenEngine_urls_domURLSetHref_Arguments& args)
{
    auto result = args.url->setHref(args.value);
    if (!result.hasException())
        return std::nullopt;
    auto exception = result.releaseException();
    if (exception.code() == OutOfMemoryError)
        return nativeAllocationFailure();
    RELEASE_ASSERT(exception.code() == InvalidURLError);
    return exception.releaseMessage();
}

BunBindgenEngine_urls_domURLSearchParams_Return bunBindgenEngine_urls_domURLSearchParams(const BunBindgenEngine_urls_domURLSearchParams_Arguments& args)
{
    auto result = args.url->searchParams();
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    return &result.releaseReturnValue().leakRef();
}

} // namespace Bun::Bindgen::Engine
