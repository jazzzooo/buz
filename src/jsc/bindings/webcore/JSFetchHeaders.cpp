#include "config.h"
#include "JSFetchHeaders.h"

#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <limits>

namespace WebCore {

using namespace JSC;

RefPtr<FetchHeaders> protectedFetchHeaders(JSGlobalObject* global, JSValue value)
{
    auto* headers = Bun::Bindgen::ZigExports::bunBindgenZig_fetch_headers_fetchHeadersRetainFromWrapper(global, value);
    if (!headers)
        return nullptr;
    return adoptRef(*headers);
}

static JSArray* headersStringArray(JSGlobalObject& globalObject, const Vector<String, 0>& values)
{
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* result = constructEmptyArray(&globalObject, nullptr, values.size());
    RETURN_IF_EXCEPTION(scope, nullptr);
    for (size_t index = 0; index < values.size(); ++index) {
        result->putDirectIndex(&globalObject, index, jsString(vm, values[index]));
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return result;
}

JSC::JSValue getInternalProperties(JSC::VM& vm, JSGlobalObject* globalObject, JSFetchHeaders* wrapper)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto protectedHeaders = protectedFetchHeaders(globalObject, wrapper);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(protectedHeaders);
    auto& headers = *protectedHeaders;
    size_t size = headers.sizeAfterJoiningSetCookieHeader();
    JSObject* result = size && size <= JSFinalObject::maxInlineCapacity
        ? constructEmptyObject(globalObject, globalObject->objectPrototype(), size)
        : constructEmptyObject(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    for (const auto& header : headers.internalHeaders().commonHeaders()) {
        result->putDirect(vm, Identifier::fromString(vm, WTF::httpHeaderNameStringImpl(header.key)), jsString(vm, header.value), 0);
        RETURN_IF_EXCEPTION(scope, {});
    }

    const auto& cookies = headers.getSetCookieHeaders();
    if (!cookies.isEmpty()) {
        auto* values = headersStringArray(*globalObject, cookies);
        RETURN_IF_EXCEPTION(scope, {});
        result->putDirect(vm, Identifier::fromString(vm, WTF::httpHeaderNameStringImpl(HTTPHeaderName::SetCookie)), values, 0);
        RETURN_IF_EXCEPTION(scope, {});
    }

    for (const auto& header : headers.internalHeaders().uncommonHeaders()) {
        auto name = FetchHeaders::lowercaseName(header.key);
        if (name.hasException()) {
            propagateException(globalObject, scope, name.releaseException());
            return {};
        }
        result->putDirectMayBeIndex(globalObject, Identifier::fromString(vm, name.releaseReturnValue()), jsString(vm, header.value));
        RETURN_IF_EXCEPTION(scope, {});
    }

    return result;
}

} // namespace WebCore

namespace Bun::Bindgen::Engine {

using namespace JSC;
using namespace WebCore;

static void propagateHeaderException(JSGlobalObject& globalObject, WebCore::Exception&& exception)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    propagateException(&globalObject, scope, WTF::move(exception));
}

void bunBindgenEngine_fetch_headers_fetchHeadersAppend(
    EngineCallContext& ctx,
    const BunBindgenEngine_fetch_headers_fetchHeadersAppend_Arguments& args)
{
    auto result = args.headers->append(args.name, args.value);
    if (result.hasException()) [[unlikely]]
        propagateHeaderException(ctx.globalObject, result.releaseException());
}

void bunBindgenEngine_fetch_headers_fetchHeadersRemove(
    EngineCallContext& ctx,
    const BunBindgenEngine_fetch_headers_fetchHeadersRemove_Arguments& args)
{
    auto result = args.headers->remove(args.name);
    if (result.hasException()) [[unlikely]]
        propagateHeaderException(ctx.globalObject, result.releaseException());
}

std::optional<WTF::String> bunBindgenEngine_fetch_headers_fetchHeadersGetByName(
    EngineCallContext& ctx,
    const BunBindgenEngine_fetch_headers_fetchHeadersGetByName_Arguments& args)
{
    auto result = args.headers->get(args.name);
    if (result.hasException()) [[unlikely]] {
        propagateHeaderException(ctx.globalObject, result.releaseException());
        return std::nullopt;
    }
    auto value = result.releaseReturnValue();
    if (value.isNull())
        return std::nullopt;
    return value;
}

bool bunBindgenEngine_fetch_headers_fetchHeadersHas(
    EngineCallContext& ctx,
    const BunBindgenEngine_fetch_headers_fetchHeadersHas_Arguments& args)
{
    auto result = args.headers->has(args.name);
    if (result.hasException()) [[unlikely]] {
        propagateHeaderException(ctx.globalObject, result.releaseException());
        return false;
    }
    return result.releaseReturnValue();
}

void bunBindgenEngine_fetch_headers_fetchHeadersSet(
    EngineCallContext& ctx,
    const BunBindgenEngine_fetch_headers_fetchHeadersSet_Arguments& args)
{
    auto result = args.headers->set(args.name, args.value);
    if (result.hasException()) [[unlikely]]
        propagateHeaderException(ctx.globalObject, result.releaseException());
}

BunBindgenEngine_fetch_headers_fetchHeadersJSON_Return bunBindgenEngine_fetch_headers_fetchHeadersJSON(
    const BunBindgenEngine_fetch_headers_fetchHeadersJSON_Arguments& args)
{
    auto& headers = *args.headers;
    BunBindgenEngine_fetch_headers_fetchHeadersJSON_Return::value_type result;
    if (!result.tryReserveInitialCapacity(headers.sizeAfterJoiningSetCookieHeader()))
        return nativeAllocationFailure();

    for (const auto& header : headers.internalHeaders().commonHeaders()) {
        HeadersJSONValueResult value;
        value.set_value(header.value);
        result.unsafeAppendWithoutCapacityCheck(std::pair { WTF::httpHeaderNameStringImpl(header.key), WTF::move(value) });
    }

    const auto& cookies = headers.getSetCookieHeaders();
    if (!cookies.isEmpty()) {
        HeadersJSONValueResult value;
        auto copiedCookies = headers.copySetCookieHeaders();
        if (copiedCookies.hasException()) {
            RELEASE_ASSERT(copiedCookies.releaseException().code() == OutOfMemoryError);
            return nativeAllocationFailure();
        }
        value.set_set_cookie(copiedCookies.releaseReturnValue());
        result.unsafeAppendWithoutCapacityCheck(std::pair { WTF::httpHeaderNameStringImpl(HTTPHeaderName::SetCookie), WTF::move(value) });
    }

    for (const auto& header : headers.internalHeaders().uncommonHeaders()) {
        HeadersJSONValueResult value;
        value.set_value(header.value);
        auto name = FetchHeaders::lowercaseName(header.key);
        if (name.hasException()) {
            RELEASE_ASSERT(name.releaseException().code() == OutOfMemoryError);
            return nativeAllocationFailure();
        }
        result.unsafeAppendWithoutCapacityCheck(std::pair { name.releaseReturnValue(), WTF::move(value) });
    }

    return result;
}

BunBindgenEngine_fetch_headers_fetchHeadersCount_Return bunBindgenEngine_fetch_headers_fetchHeadersCount(
    const BunBindgenEngine_fetch_headers_fetchHeadersCount_Arguments& args)
{
    const auto count = args.headers->size();
    if (count > std::numeric_limits<uint32_t>::max())
        return nativeAllocationFailure();
    return static_cast<uint32_t>(count);
}

BunBindgenEngine_fetch_headers_fetchHeadersGetSetCookie_Return bunBindgenEngine_fetch_headers_fetchHeadersGetSetCookie(
    const BunBindgenEngine_fetch_headers_fetchHeadersGetSetCookie_Arguments& args)
{
    auto result = args.headers->copySetCookieHeaders();
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    return result.releaseReturnValue();
}

BunBindgenEngine_fetch_headers_fetchHeadersRawKeys_Return bunBindgenEngine_fetch_headers_fetchHeadersRawKeys(
    const BunBindgenEngine_fetch_headers_fetchHeadersRawKeys_Arguments& args)
{
    const auto& headers = args.headers->internalHeaders();
    WTF::Vector<WTF::String> result;
    const size_t keyCount = static_cast<size_t>(headers.commonHeaders().size()) + headers.uncommonHeaders().size();
    if (!result.tryReserveInitialCapacity(keyCount))
        return nativeAllocationFailure();
    for (const auto& header : headers)
        result.unsafeAppendWithoutCapacityCheck(header.name());
    return result;
}

} // namespace Bun::Bindgen::Engine
