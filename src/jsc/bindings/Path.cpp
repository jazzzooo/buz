#include "PathInlines.h"
#include "root.h"
#include "SchemaBindings.h"
#include "Bindgen/FileURL.h"
#include "BindgenTypePredicates.h"
#include "StringConversion.h"
#include "BunClientData.h"
#include "DOMURL.h"
#include "ErrorCode.h"
#include "JSDOMURL.h"
#include "JSDOMExceptionHandling.h"
#include "ZigGlobalObject.h"
#include "helpers.h"

#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSMicrotask.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <span>
#include <wtf/URL.h>
#include <wtf/ASCIICType.h>

#pragma mark - Node.js Path

namespace Bun::Bindgen {

using namespace JSC;

static bool validateNodePath(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, JSC::JSValue value, WTF::ASCIILiteral name, std::span<const uint8_t> bytes)
{
    if (std::find(bytes.begin(), bytes.end(), 0) != bytes.end()) {
        Bun::ERR::INVALID_ARG_VALUE(scope, &global, name, value, "must be a string, Uint8Array, or URL without null bytes"_s);
        return false;
    }
    return true;
}

static bool copyPathBytes(JSC::JSGlobalObject& global, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& result, std::span<const uint8_t> bytes, bool shared)
{
    if (!result.tryGrow(bytes.size())) {
        JSC::throwOutOfMemoryError(&global, scope);
        return false;
    }
    if (shared) {
        for (size_t index = 0; index < bytes.size(); ++index)
            result[index] = std::atomic_ref<uint8_t>(const_cast<uint8_t&>(bytes[index])).load(std::memory_order_relaxed);
    } else if (!bytes.empty()) {
        memcpy(result.mutableSpan().data(), bytes.data(), bytes.size());
    }
    return true;
}

WTF::String fileURLToPath(JSC::JSGlobalObject& global, const WTF::URL& url)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (!url.isValid()) {
        Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "Expected a valid file URL"_s);
        return {};
    }
    if (!url.protocolIsFile()) {
        Bun::ERR::INVALID_URL_SCHEME(scope, &global, "file"_s);
        return {};
    }
#if !OS(WINDOWS)
    if (!url.host().isEmpty() && url.host() != "localhost"_s) {
#if OS(DARWIN)
        Bun::ERR::INVALID_FILE_URL_HOST(scope, &global, "darwin"_s);
#else
        Bun::ERR::INVALID_FILE_URL_HOST(scope, &global, "linux"_s);
#endif
        return {};
    }
#endif
    const auto encodedPath = url.path();
    if (encodedPath.containsIgnoringASCIICase("%2f"_s)
#if OS(WINDOWS)
        || encodedPath.containsIgnoringASCIICase("%5c"_s)
#endif
    ) {
#if OS(WINDOWS)
        Bun::ERR::INVALID_FILE_URL_PATH(scope, &global, "must not include encoded \\ or / characters"_s);
#else
        Bun::ERR::INVALID_FILE_URL_PATH(scope, &global, "must not include encoded / characters"_s);
#endif
        return {};
    }
    for (unsigned index = 0; index < encodedPath.length(); ++index) {
        if (encodedPath[index] != '%')
            continue;
        if (encodedPath.length() - index < 3 || !WTF::isASCIIHexDigit(encodedPath[index + 1]) || !WTF::isASCIIHexDigit(encodedPath[index + 2])) {
            scope.throwException(&global, JSC::createURIError(&global, "URI malformed"_s));
            return {};
        }
        index += 2;
    }
    auto path = url.fileSystemPath();
    if (path.isNull()) {
        scope.throwException(&global, JSC::createURIError(&global, "URI malformed"_s));
        return {};
    }
#if OS(WINDOWS)
    if (!isAbsolutePath(path)) {
        Bun::ERR::INVALID_FILE_URL_PATH(scope, &global, "must be an absolute path"_s);
        return {};
    }
#endif
    if (path.isEmpty()) {
        Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "URL must be a non-empty \"file:\" path"_s);
        return {};
    }
    scope.release();
    return path;
}

static WTF::Vector<uint8_t> convertFileURLPath(JSC::JSGlobalObject& global, JSC::JSValue value, WTF::ASCIILiteral name, const WTF::URL& url)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto path = fileURLToPath(global, url);
    RETURN_IF_EXCEPTION(scope, {});
    auto utf8 = Bun::encodeUTF8ReplacingInvalidSequences(path);
    if (!utf8) {
        JSC::throwOutOfMemoryError(&global, scope);
        return {};
    }
    if (!validateNodePath(global, scope, value, name, utf8->span()))
        return {};
    scope.release();
    return WTF::move(*utf8);
}

WTF::Vector<uint8_t> convertNodePath(JSC::JSGlobalObject& global, JSC::JSValue value, WTF::ASCIILiteral name, bool fileURLStrings, bool boxedStrings)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    WTF::Vector<uint8_t> result;

    if (value.isString() || (boxedStrings && TypePredicates::isStringObject(value))) {
        auto string = value.toWTFString(&global);
        RETURN_IF_EXCEPTION(scope, {});
        if (fileURLStrings && string.startsWith("file:"_s)) {
            WTF::URL parsed { string };
            auto path = convertFileURLPath(global, value, name, parsed.isValid() ? parsed : WTF::URL { });
            RETURN_IF_EXCEPTION(scope, {});
            scope.release();
            return path;
        }
        auto utf8 = Bun::encodeUTF8ReplacingInvalidSequences(string);
        if (!utf8) {
            JSC::throwOutOfMemoryError(&global, scope);
            return {};
        }
        if (!validateNodePath(global, scope, value, name, utf8->span()))
            return {};
        scope.release();
        return WTF::move(*utf8);
    }

    if (auto* array = dynamicDowncast<JSC::JSUint8Array>(value)) {
        if (array->isDetached() || array->isOutOfBounds()) {
            JSC::throwTypeError(&global, scope, "Cannot perform %TypedArray%.prototype.includes on a detached or out-of-bounds ArrayBuffer"_s);
            return {};
        }
        std::span<const uint8_t> bytes { static_cast<const uint8_t*>(array->vector()), array->byteLength() };
        if (!copyPathBytes(global, scope, result, bytes, array->isShared())
            || !validateNodePath(global, scope, value, name, result.span()))
            return {};
        JSC::ensureStillAliveHere(array);
        scope.release();
        return result;
    }

    if (dynamicDowncast<WebCore::JSDOMURL>(value)) {
        auto domURL = WebCore::protectedDOMURL(&global, value);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_ASSERT(domURL);
        auto snapshot = domURL->href();
        if (snapshot.hasException()) {
            WebCore::propagateException(global, scope, snapshot.releaseException());
            return {};
        }
        auto path = convertFileURLPath(global, value, name, snapshot.releaseReturnValue());
        RETURN_IF_EXCEPTION(scope, {});
        scope.release();
        return path;
    }

    Bun::ERR::INVALID_ARG_TYPE_INSTANCE(scope, &global, name, "string"_s, "Buffer or URL"_s, value);
    return {};
}

} // namespace Bun::Bindgen
