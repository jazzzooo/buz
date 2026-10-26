#include "root.h"

#include "BindingAssertions.h"
#include "FetchHeaders.h"
#include "HTTPHeaderNames.h"
#include "JSDOMBinding.h"
#include "JSDOMGlobalObject.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSFetchHeaders.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "helpers.h"
#include <bun-uws/src/App.h>
#include <bun-uws/src/Http3Request.h>
#include <string_view>

using namespace JSC;
using namespace WebCore;

static bool copyHeaderString(std::span<const uint8_t> bytes, String& result)
{
    if (bytes.size() > StringImpl::MaxLength)
        return false;
    std::span<Latin1Character> data;
    auto impl = StringImpl::tryCreateUninitialized(bytes.size(), data);
    if (!impl)
        return false;
    if (!bytes.empty())
        memcpy(data.data(), bytes.data(), bytes.size());
    result = String(WTF::move(impl));
    return true;
}

static bool appendNetworkHeader(HTTPHeaderMap& map, std::span<const uint8_t> name, std::span<const uint8_t> value)
{
    if (name.size() > StringImpl::MaxLength)
        return false;
    String ownedValue;
    if (!copyHeaderString(value, ownedValue))
        return false;
    StringView nameView(name);
    HTTPHeaderName commonName;
    if (findHTTPHeaderName(nameView, commonName))
        return map.tryAdd(commonName, ownedValue);
    return map.trySetUncommonHeaderCloneName(nameView, ownedValue);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersIsEmpty(
    const BunBindgenEngine_fetch_headers_fetchHeadersIsEmpty_Arguments& args)
{
    return args.headers->size() == 0;
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersCreateEmpty_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersCreateEmpty(
    const BunBindgenEngine_fetch_headers_fetchHeadersCreateEmpty_Arguments&)
{
    auto headers = WebCore::FetchHeaders::tryCreate();
    if (!headers)
        return Bun::Bindgen::nativeAllocationFailure();
    return headers.leakRef();
}

WebCore::FetchHeaders* Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersCreateFromEntries(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_fetch_headers_fetchHeadersCreateFromEntries_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto headers = WebCore::FetchHeaders::tryCreate();
    if (!headers) {
        throwOutOfMemoryError(lexicalGlobalObject, throwScope);
        return nullptr;
    }
    for (const auto& entry : args.entries) {
        String name;
        String value;
        if (!copyHeaderString(entry.name, name) || !copyHeaderString(entry.value, value)) {
            throwOutOfMemoryError(lexicalGlobalObject, throwScope);
            return nullptr;
        }
        WebCore::propagateException(*lexicalGlobalObject, throwScope, headers->append(name, value));
        RETURN_IF_EXCEPTION(throwScope, nullptr);
    }
    return headers.leakRef();
}
namespace Bun::Bindgen::Custom {

static std::optional<WTF::RefPtr<WebCore::FetchHeaders>> headersInit(
    JSC::JSGlobalObject& globalObject,
    const std::optional<Bun::Bindgen::HeadersInitValue>& input,
    bool cloneExisting)
{
    if (!input)
        return std::nullopt;

    const auto& value = *input;
    if (value.is_headers()) {
        auto headers = value.headers();
        if (!cloneExisting)
            return headers;
        if (headers->size() == 0)
            return std::nullopt;
        auto throwScope = DECLARE_THROW_SCOPE(globalObject.vm());
        auto clone = WebCore::FetchHeaders::tryCreate(*headers);
        if (!clone) {
            throwOutOfMemoryError(&globalObject, throwScope);
            return std::nullopt;
        }
        return clone;
    }

    auto throwScope = DECLARE_THROW_SCOPE(globalObject.vm());
    throwScope.assertNoException();
    if (value.is_sequence() && value.sequence().isEmpty())
        return std::nullopt;
    if (value.is_record() && value.record().isEmpty())
        return std::nullopt;
    auto headers = WebCore::FetchHeaders::tryCreate();
    if (!headers) {
        throwOutOfMemoryError(&globalObject, throwScope);
        return std::nullopt;
    }
    if (value.is_sequence()) {
        for (const auto& entry : value.sequence()) {
            if (entry.size() != 2) {
                WebCore::propagateException(globalObject, throwScope, WebCore::Exception { TypeError, "Header sub-sequence must contain exactly two items"_s });
                return std::nullopt;
            }
            WebCore::propagateException(globalObject, throwScope, headers->append(entry[0], entry[1]));
            RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        }
    } else {
        RELEASE_ASSERT(value.is_record());
        for (const auto& [name, value] : value.record()) {
            WebCore::propagateException(globalObject, throwScope, headers->append(name, value));
            RETURN_IF_EXCEPTION(throwScope, std::nullopt);
        }
    }
    return headers;
}

std::optional<WTF::RefPtr<WebCore::FetchHeaders>> bunBindgenHeadersInit(
    JSC::JSGlobalObject& globalObject,
    const std::optional<Bun::Bindgen::HeadersInitValue>& input,
    WTF::ASCIILiteral)
{
    return headersInit(globalObject, input, false);
}

std::optional<WTF::RefPtr<WebCore::FetchHeaders>> bunBindgenClonedHeadersInit(
    JSC::JSGlobalObject& globalObject,
    const std::optional<Bun::Bindgen::HeadersInitValue>& input,
    WTF::ASCIILiteral)
{
    return headersInit(globalObject, input, true);
}

}

WebCore::FetchHeaders* Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersRetain(
    const BunBindgenEngine_fetch_headers_fetchHeadersRetain_Arguments& args)
{
    args.headers->ref();
    return args.headers;
}

size_t Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersMemoryCost(
    const BunBindgenEngine_fetch_headers_fetchHeadersMemoryCost_Arguments& args)
{
    return args.headers->memoryCost();
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersCloneNative_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersCloneNative(
    const BunBindgenEngine_fetch_headers_fetchHeadersCloneNative_Arguments& args)
{
    auto clone = WebCore::FetchHeaders::tryCreate(*args.headers);
    if (!clone)
        return Bun::Bindgen::nativeAllocationFailure();
    return clone.leakRef();
}

bool Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersFastHas(
    const BunBindgenEngine_fetch_headers_fetchHeadersFastHas_Arguments& args)
{
    return args.headers->fastHas(args.name);
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersSnapshotForHTTP_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersSnapshotForHTTP(
    const BunBindgenEngine_fetch_headers_fetchHeadersSnapshotForHTTP_Arguments& args)
{
    BunBindgenEngine_fetch_headers_fetchHeadersSnapshotForHTTP_Return::value_type result;
    if (!result.tryReserveCapacity(args.headers->size()))
        return Bun::Bindgen::nativeAllocationFailure();
    auto append = [&](const String& name, const String& value) {
        RELEASE_ASSERT_WITH_MESSAGE(name.is8Bit() && !name.isEmpty() && name.containsOnlyASCII(), "Header names must use nonempty ASCII byte storage");
        RELEASE_ASSERT_WITH_MESSAGE(value.isEmpty() || value.is8Bit(), "Header values must use ByteString storage");
        return result.tryAppend({ .key = name, .value = value });
    };
    const auto& headers = args.headers->internalHeaders();
    for (const auto& header : headers.commonHeaders()) {
        if (!append(WTF::httpHeaderNameDefaultCaseStringImpl(header.key), header.value))
            return Bun::Bindgen::nativeAllocationFailure();
    }
    for (const auto& header : headers.uncommonHeaders()) {
        if (!append(header.key, header.value))
            return Bun::Bindgen::nativeAllocationFailure();
    }
    for (const auto& cookie : headers.getSetCookieHeaders()) {
        if (!append("set-cookie"_s, cookie))
            return Bun::Bindgen::nativeAllocationFailure();
    }
    return result;
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersCreateFromPicoHeaders_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersCreateFromPicoHeaders(
    const BunBindgenEngine_fetch_headers_fetchHeadersCreateFromPicoHeaders_Arguments& args)
{
    HTTPHeaderMap map;
    for (const auto& header : args.headers) {
        if (header.name.empty())
            continue;
        if (!appendNetworkHeader(map, header.name, header.value))
            return Bun::Bindgen::nativeAllocationFailure();
    }
    auto headers = WebCore::FetchHeaders::tryCreate(WebCore::FetchHeaders::Guard::None, WTF::move(map));
    if (!headers)
        return Bun::Bindgen::nativeAllocationFailure();
    return headers.leakRef();
}
Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersCreateFromUWS_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersCreateFromUWS(
    const BunBindgenEngine_fetch_headers_fetchHeadersCreateFromUWS_Arguments& args)
{
    uWS::HttpRequest req = *reinterpret_cast<uWS::HttpRequest*>(args.request);

    HTTPHeaderMap map;

    for (const auto& header : req) {
        if (!appendNetworkHeader(map,
                { reinterpret_cast<const uint8_t*>(header.first.data()), header.first.size() },
                { reinterpret_cast<const uint8_t*>(header.second.data()), header.second.size() }))
            return Bun::Bindgen::nativeAllocationFailure();
    }
    auto headers = WebCore::FetchHeaders::tryCreate(WebCore::FetchHeaders::Guard::None, WTF::move(map));
    if (!headers)
        return Bun::Bindgen::nativeAllocationFailure();
    return headers.leakRef();
}
Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersCreateFromH3_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersCreateFromH3(
    const BunBindgenEngine_fetch_headers_fetchHeadersCreateFromH3_Arguments& args)
{
    auto* req = reinterpret_cast<uWS::Http3Request*>(args.request);

    HTTPHeaderMap map;
    bool allocationFailed = false;
    req->forEachHeader([&](std::string_view name, std::string_view val) {
        if (!allocationFailed)
            allocationFailed = !appendNetworkHeader(map,
                { reinterpret_cast<const uint8_t*>(name.data()), name.size() },
                { reinterpret_cast<const uint8_t*>(val.data()), val.size() });
    });
    if (allocationFailed)
        return Bun::Bindgen::nativeAllocationFailure();
    auto headers = WebCore::FetchHeaders::tryCreate(WebCore::FetchHeaders::Guard::None, WTF::move(map));
    if (!headers)
        return Bun::Bindgen::nativeAllocationFailure();
    return headers.leakRef();
}
void Bun::Bindgen::Engine::releaseFetchHeaders(WebCore::FetchHeaders* headers)
{
    headers->deref();
}

void Bun::Bindgen::Engine::fetchHeadersIteratorRelease(WebCore::FetchHeaders::Iterator* iterator)
{
    delete iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersIteratorCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersIteratorCreate(
    const BunBindgenEngine_fetch_headers_fetchHeadersIteratorCreate_Arguments& args)
{
    auto* memory = WTF::FastMalloc::tryMalloc(sizeof(WebCore::FetchHeaders::Iterator));
    if (!memory)
        return Bun::Bindgen::nativeAllocationFailure();
    return new (memory) WebCore::FetchHeaders::Iterator(*args.headers, true);
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersIteratorNext_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersIteratorNext(
    const BunBindgenEngine_fetch_headers_fetchHeadersIteratorNext_Arguments& args)
{
    auto next = args.iterator->next();
    if (next.hasException()) {
        RELEASE_ASSERT(next.releaseException().code() == OutOfMemoryError);
        return Bun::Bindgen::nativeAllocationFailure();
    }
    auto entry = next.releaseReturnValue();
    if (!entry)
        return std::nullopt;
    using Entry = BunBindgenEngine_fetch_headers_fetchHeadersIteratorNext_Return::value_type::value_type;
    return Entry {
        .key = WTF::move(entry->key),
        .value = WTF::move(entry->value),
    };
}

std::optional<WTF::String> Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersGet(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_fetch_headers_fetchHeadersGet_Arguments& args)
{
    auto* global = &context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(global->vm());
    if (args.name.size() > StringImpl::MaxLength) {
        throwOutOfMemoryError(global, throwScope);
        return std::nullopt;
    }
    auto result = args.headers->get(StringView(args.name));
    if (result.hasException()) {
        WebCore::propagateException(*global, throwScope, result.releaseException());
        return std::nullopt;
    }

    auto value = result.releaseReturnValue();
    if (value.isNull())
        return std::nullopt;
    return value;
}

void Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersPut(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_fetch_headers_fetchHeadersPut_Arguments& args)
{
    auto* global = &context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(global->vm());
    throwScope.assertNoException();
    String value;
    if (!copyHeaderString(args.value, value)) {
        throwOutOfMemoryError(global, throwScope);
        return;
    }
    WebCore::propagateException(*global, throwScope, args.headers->set(args.name, value));
}

void Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersFastRemove(
    const BunBindgenEngine_fetch_headers_fetchHeadersFastRemove_Arguments& args)
{
    args.headers->fastRemove(args.name);
}

Bun::Bindgen::Engine::BunBindgenEngine_fetch_headers_fetchHeadersFastGet_Return Bun::Bindgen::Engine::bunBindgenEngine_fetch_headers_fetchHeadersFastGet(
    const BunBindgenEngine_fetch_headers_fetchHeadersFastGet_Arguments& args)
{
    auto result = args.headers->get(args.name);
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return Bun::Bindgen::nativeAllocationFailure();
    }
    auto str = result.releaseReturnValue();
    if (str.isNull())
        return std::nullopt;
    return str;
}
