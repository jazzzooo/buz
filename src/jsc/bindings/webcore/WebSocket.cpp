/*
 * Copyright (C) 2011 Google Inc.  All rights reserved.
 * Copyright (C) 2015-2016 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "UTF8View.h"
#include "WebSocket.h"
#include "WebSocketDeflate.h"
#include "blob.h"
#include "SchemaBindings.h"
#include "CloseEvent.h"
#include "JSDOMExceptionHandling.h"
#include <JavaScriptCore/TopExceptionScope.h>
#include <wtf/text/Base64.h>
// #include "ContentSecurityPolicy.h"
// #include "DOMWindow.h"
// #include "Document.h"
#include "Event.h"
#include "EventListener.h"
#include "EventNames.h"
// #include "Frame.h"
// #include "FrameLoader.h"
// #include "FrameLoaderClient.h"
// #include "InspectorInstrumentation.h"
// #include "Logging.h"
#include "MessageEvent.h"
// #include "MixedContentChecker.h"
// #include "ResourceLoadObserver.h"
// #include "ScriptController.h"
#include "ScriptExecutionContext.h"
// #include "SecurityOrigin.h"
// #include "SocketProvider.h"
// #include "ThreadableWebSocketChannel.h"
// #include "WebSocketChannel.h"
// #include "WorkerGlobalScope.h"
// #include "WorkerLoaderProxy.h"
// #include "WorkerThread.h"
#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/ArrayBufferView.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include <wtf/HashSet.h>
#include <wtf/HexNumber.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/NeverDestroyed.h>
// #include <wtf/RunLoop.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/CString.h>
#include <wtf/text/StringBuilder.h>

#include "JSBuffer.h"
#include "ErrorEvent.h"
#include "WebSocketDeflate.h"

// #if USE(WEB_THREAD)
// #include "WebCoreThreadRun.h"
// #endif

namespace WebCore {
WTF_MAKE_TZONE_ALLOCATED_IMPL(WebSocket);

static ErrorEvent::Init createErrorEventInit(WebSocket& webSocket, const String& reason, JSC::JSGlobalObject* globalObject)
{
    ErrorEvent::Init eventInit = {};
    if (reason.isEmpty()) {
        eventInit.message = makeString("WebSocket connection to '"_s, webSocket.url().stringCenterEllipsizedToLength(), "' failed"_s);
    } else {
        eventInit.message = makeString("WebSocket connection to '"_s, webSocket.url().stringCenterEllipsizedToLength(), "' failed: "_s, reason);
    }
    eventInit.filename = String();
    eventInit.bubbles = false;
    eventInit.cancelable = false;
    eventInit.colno = 0;
    eventInit.error = JSC::createError(globalObject, eventInit.message);
    return eventInit;
}

static size_t getFramingOverhead(size_t payloadSize)
{
    static const size_t hybiBaseFramingOverhead = 2; // Every frame has at least two-byte header.
    static const size_t hybiMaskingKeyLength = 4; // Every frame from client must have masking key.
    static const size_t minimumPayloadSizeWithTwoByteExtendedPayloadLength = 126;
    static const size_t minimumPayloadSizeWithEightByteExtendedPayloadLength = 0x10000;
    size_t overhead = hybiBaseFramingOverhead + hybiMaskingKeyLength;
    if (payloadSize >= minimumPayloadSizeWithEightByteExtendedPayloadLength)
        overhead += 8;
    else if (payloadSize >= minimumPayloadSizeWithTwoByteExtendedPayloadLength)
        overhead += 2;
    return overhead;
}

const size_t maxReasonSizeInBytes = 123;

static inline bool isValidProtocolCharacter(char16_t character)
{
    // Hybi-10 says "(Subprotocol string must consist of) characters in the range U+0021 to U+007E not including
    // separator characters as defined in [RFC2616]."
    const char16_t minimumProtocolCharacter = '!'; // U+0021.
    const char16_t maximumProtocolCharacter = '~'; // U+007E.
    return character >= minimumProtocolCharacter && character <= maximumProtocolCharacter
        && character != '"' && character != '(' && character != ')' && character != ',' && character != '/'
        && !(character >= ':' && character <= '@') // U+003A - U+0040 (':', ';', '<', '=', '>', '?', '@').
        && !(character >= '[' && character <= ']') // U+005B - U+005D ('[', '\\', ']').
        && character != '{' && character != '}';
}

static bool isValidProtocolString(StringView protocol)
{
    if (protocol.isEmpty())
        return false;
    for (auto codeUnit : protocol.codeUnits()) {
        if (!isValidProtocolCharacter(codeUnit))
            return false;
    }
    return true;
}

static String encodeProtocolString(const String& protocol)
{
    StringBuilder builder;
    for (size_t i = 0; i < protocol.length(); i++) {
        if (protocol[i] < 0x20 || protocol[i] > 0x7E)
            builder.append("\\u"_s, hex(protocol[i], 4));
        else if (protocol[i] == 0x5c)
            builder.append("\\\\"_s);
        else
            builder.append(protocol[i]);
    }
    return builder.toString();
}

static String joinStrings(const Vector<String>& strings, ASCIILiteral separator)
{
    StringBuilder builder;
    for (size_t i = 0; i < strings.size(); ++i) {
        if (i)
            builder.append(separator);
        builder.append(strings[i]);
    }
    return builder.toString();
}

static unsigned saturateAdd(unsigned a, size_t b)
{
    if (b > std::numeric_limits<unsigned>::max() - a)
        return std::numeric_limits<unsigned>::max();
    return a + static_cast<unsigned>(b);
}

ASCIILiteral WebSocket::subprotocolSeparator()
{
    return ", "_s;
}

WebSocket::WebSocket(ScriptExecutionContext& context)
    : ContextDestructionObserver(&context)
    , m_subprotocol(emptyString())
    , m_extensions(emptyString())
{
    m_state = CONNECTING;
    m_hasPendingActivity.store(true);
    m_rejectUnauthorized = Bun::Bindgen::ZigExports::bunBindgenZig_Process_getTLSRejectUnauthorizedValue() != 0;
}

WebSocket::~WebSocket()
{
    if (hasUpgradeClient()) {
        if (usesTLSUpgradeClient()) {
            Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPSClientCancel(m_upgradeClient.https);
        } else {
            Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPClientCancel(m_upgradeClient.http);
        }
    }

    switch (m_connectedWebSocketKind) {
    case ConnectedWebSocketKind::Client: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientFinalize(this->m_connectedWebSocket.client);
        break;
    }
    case ConnectedWebSocketKind::ClientSSL: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSFinalize(this->m_connectedWebSocket.clientSSL);
        break;
    }
    // case ConnectedWebSocketKind::Server: {
    //     this->m_connectedWebSocket.server->end(None);
    //     break;
    // }
    // case ConnectedWebSocketKind::ServerSSL: {
    //     this->m_connectedWebSocket.serverSSL->end(None);
    //     break;
    // }
    default: {
        break;
    }
    }
}

// Transient proxy configuration - used only during connect() and not stored as member fields
struct ProxyConfig {
    String host;
    uint16_t port { 0 };
    String authorization;
    Vector<std::pair<String, String>> headers;
    bool isHTTPS { false };
};

static ExceptionOr<std::optional<ProxyConfig>> setupProxy(const String& proxyUrl, std::optional<FetchHeaders::Init>&& proxyHeaders)
{
    if (proxyUrl.isNull() || proxyUrl.isEmpty())
        return { std::nullopt };

    URL url { proxyUrl };
    if (!url.isValid())
        return Exception { SyntaxError, makeString("Invalid proxy URL: "_s, proxyUrl) };

    ProxyConfig config;
    config.host = url.host().toString();
    config.isHTTPS = url.protocolIs("https"_s);
    config.port = url.port().value_or(config.isHTTPS ? 443 : 80);

    // Compute Basic auth from proxy URL credentials
    if (!url.user().isEmpty()) {
        auto credentials = makeString(url.user(), ':', url.password());
        auto utf8 = credentials.utf8();
        auto encoded = base64EncodeToString(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(utf8.data()), utf8.length()));
        config.authorization = makeString("Basic "_s, encoded);
    }

    // Store proxy headers
    if (proxyHeaders) {
        auto headersOrException = FetchHeaders::create(WTF::move(proxyHeaders));
        if (headersOrException.hasException())
            return headersOrException.releaseException();
        auto hdrs = headersOrException.releaseReturnValue();
        auto iterator = hdrs.get().createIterator(false);
        for (;;) {
            auto next = iterator.next();
            if (next.hasException())
                return next.releaseException();
            auto value = next.releaseReturnValue();
            if (!value)
                break;
            if (!config.headers.tryAppend({ value->key, value->value }))
                return Exception { OutOfMemoryError };
        }
    }

    return { WTF::move(config) };
}

void WebSocket::setExtensionsFromDeflateParams(const PerMessageDeflateParams* deflate_params)
{
    if (deflate_params == nullptr)
        return;

    StringBuilder extensions;
    extensions.append("permessage-deflate"_s);
    if (deflate_params->server_no_context_takeover)
        extensions.append("; server_no_context_takeover"_s);
    if (deflate_params->client_no_context_takeover)
        extensions.append("; client_no_context_takeover"_s);
    if (deflate_params->server_max_window_bits != 15) {
        extensions.append("; server_max_window_bits="_s);
        extensions.append(String::number(deflate_params->server_max_window_bits));
    }
    if (deflate_params->client_max_window_bits != 15) {
        extensions.append("; client_max_window_bits="_s);
        extensions.append(String::number(deflate_params->client_max_window_bits));
    }
    m_extensions = extensions.toString();
}

ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url)
{
    return create(context, url, Vector<String> {}, std::nullopt);
}

ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url, const Vector<String>& protocols)
{
    return create(context, url, protocols, std::nullopt);
}

ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url, const Vector<String>& protocols, std::optional<FetchHeaders::Init>&& headers)
{
    if (url.isNull())
        return Exception { SyntaxError };

    auto socket = adoptRef(*new WebSocket(context));
    // socket->suspendIfNeeded();

    auto result = socket->connect(url, protocols, WTF::move(headers));
    // auto result = socket->connect(url, protocols);

    if (result.hasException())
        return result.releaseException();

    return socket;
}
ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url, const Vector<String>& protocols, std::optional<FetchHeaders::Init>&& headers, bool rejectUnauthorized)
{
    if (url.isNull())
        return Exception { SyntaxError };

    auto socket = adoptRef(*new WebSocket(context));
    socket->setRejectUnauthorized(rejectUnauthorized);
    // socket->suspendIfNeeded();

    auto result = socket->connect(url, protocols, WTF::move(headers));
    // auto result = socket->connect(url, protocols);

    if (result.hasException())
        return result.releaseException();

    return socket;
}

ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url, const Vector<String>& protocols, std::optional<FetchHeaders::Init>&& headers, const String& proxyUrl, std::optional<FetchHeaders::Init>&& proxyHeaders, WebSocketSSLConfigPtr&& sslConfig, bool offerPerMessageDeflate)
{
    if (url.isNull())
        return Exception { SyntaxError };

    auto proxyConfigResult = setupProxy(proxyUrl, WTF::move(proxyHeaders));
    if (proxyConfigResult.hasException())
        return proxyConfigResult.releaseException();

    auto socket = adoptRef(*new WebSocket(context));
    socket->m_sslConfig = WTF::move(sslConfig); // Set BEFORE connect() so it's available during connection
    socket->setOfferPerMessageDeflate(offerPerMessageDeflate);

    auto result = socket->connect(url, protocols, WTF::move(headers), proxyConfigResult.releaseReturnValue());
    if (result.hasException())
        return result.releaseException();

    return socket;
}

ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url, const Vector<String>& protocols, std::optional<FetchHeaders::Init>&& headers, bool rejectUnauthorized, const String& proxyUrl, std::optional<FetchHeaders::Init>&& proxyHeaders, WebSocketSSLConfigPtr&& sslConfig, bool offerPerMessageDeflate)
{
    if (url.isNull())
        return Exception { SyntaxError };

    auto proxyConfigResult = setupProxy(proxyUrl, WTF::move(proxyHeaders));
    if (proxyConfigResult.hasException())
        return proxyConfigResult.releaseException();

    auto socket = adoptRef(*new WebSocket(context));
    socket->setRejectUnauthorized(rejectUnauthorized);
    socket->m_sslConfig = WTF::move(sslConfig); // Set BEFORE connect() so it's available during connection
    socket->setOfferPerMessageDeflate(offerPerMessageDeflate);

    auto result = socket->connect(url, protocols, WTF::move(headers), proxyConfigResult.releaseReturnValue());
    if (result.hasException())
        return result.releaseException();

    return socket;
}

ExceptionOr<Ref<WebSocket>> WebSocket::create(ScriptExecutionContext& context, const String& url, const String& protocol)
{
    return create(context, url, Vector<String> { protocol });
}

ExceptionOr<void> WebSocket::connect(const String& url)
{
    return connect(url, Vector<String> {}, std::nullopt);
}

ExceptionOr<void> WebSocket::connect(const String& url, const String& protocol)
{
    return connect(url, Vector<String> { protocol }, std::nullopt);
}

static String resourceName(const URL& url)
{
    auto path = url.path();
    auto result = makeString(
        path,
        path.isEmpty() ? "/"_s : ""_s,
        url.queryWithLeadingQuestionMark());
    ASSERT(!result.isEmpty());
    ASSERT(!result.contains(' '));
    return result;
}

static String hostName(const URL& url, bool secure)
{
    // ASSERT(url.protocolIs("wss"_s) == secure);
    if (url.port() && ((!secure && url.port().value() != 80) || (secure && url.port().value() != 443)))
        return makeString(asASCIILowercase(url.host()), ':', url.port().value());
    return url.host().convertToASCIILowercase();
}

ExceptionOr<void> WebSocket::connect(const String& url, const Vector<String>& protocols)
{
    return connect(url, protocols, std::nullopt);
}

ExceptionOr<void> WebSocket::connect(const String& url, const Vector<String>& protocols, std::optional<FetchHeaders::Init>&& headersInit)
{
    return connect(url, protocols, WTF::move(headersInit), std::nullopt);
}

size_t WebSocket::memoryCost() const

{
    size_t cost = sizeof(WebSocket);
    cost += m_url.string().sizeInBytes();
    cost += m_subprotocol.sizeInBytes();
    cost += m_extensions.sizeInBytes();

    if (m_connectedWebSocketKind == ConnectedWebSocketKind::Client) {
        cost += Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientMemoryCost(m_connectedWebSocket.client);
    } else if (m_connectedWebSocketKind == ConnectedWebSocketKind::ClientSSL) {
        cost += Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSMemoryCost(m_connectedWebSocket.clientSSL);
    }

    if (hasUpgradeClient()) {
        if (usesTLSUpgradeClient()) {
            cost += Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPSClientMemoryCost(m_upgradeClient.https);
        } else {
            cost += Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPClientMemoryCost(m_upgradeClient.http);
        }
    }

    return cost;
}

ExceptionOr<void> WebSocket::connect(const String& url, const Vector<String>& protocols, std::optional<FetchHeaders::Init>&& headersInit, std::optional<ProxyConfig>&& proxyConfig)
{
    auto throwScope = DECLARE_THROW_SCOPE(scriptExecutionContext()->jsGlobalObject()->vm());
    // LOG(Network, "WebSocket %p connect() url='%s'", this, url.utf8().data());
    m_url = URL { url };

    ASSERT(scriptExecutionContext());

    if (!m_url.isValid()) {
        // context.addConsoleMessage(MessageSource::JS, MessageLevel::Error, );
        m_state = CLOSED;
        updateHasPendingActivity();
        return Exception { SyntaxError, makeString("Invalid url for WebSocket "_s, m_url.stringCenterEllipsizedToLength()) };
    }

    bool is_unix = m_url.protocolIs("ws+unix"_s) || m_url.protocolIs("wss+unix"_s);
    bool is_secure = m_url.protocolIs("wss"_s) || m_url.protocolIs("https"_s) || m_url.protocolIs("wss+unix"_s);

    if (!m_url.protocolIs("http"_s) && !m_url.protocolIs("ws"_s) && !is_secure && !is_unix) {
        // context.addConsoleMessage(MessageSource::JS, MessageLevel::Error, );
        m_state = CLOSED;
        updateHasPendingActivity();
        return Exception { SyntaxError, makeString("Wrong url scheme for WebSocket "_s, m_url.stringCenterEllipsizedToLength()) };
    }
    if (m_url.hasFragmentIdentifier()) {
        // context.addConsoleMessage(MessageSource::JS, MessageLevel::Error, );
        m_state = CLOSED;
        updateHasPendingActivity();
        return Exception { SyntaxError, makeString("URL has fragment component "_s, m_url.stringCenterEllipsizedToLength()) };
    }

    // ASSERT(context.contentSecurityPolicy());
    // auto& contentSecurityPolicy = *context.contentSecurityPolicy();

    // contentSecurityPolicy.upgradeInsecureRequestIfNeeded(m_url, ContentSecurityPolicy::InsecureRequestType::Load);

    // if (!portAllowed(m_url)) {
    //     String message;
    //     if (m_url.port())
    //         message = makeString("WebSocket port ", m_url.port().value(), " blocked");
    //     else
    //         message = "WebSocket without port blocked"_s;
    //     context.addConsoleMessage(MessageSource::JS, MessageLevel::Error, message);
    //     failAsynchronously();
    //     return {};
    // }

    // FIXME: Convert this to check the isolated world's Content Security Policy once webkit.org/b/104520 is solved.
    // if (!context.shouldBypassMainWorldContentSecurityPolicy() && !contentSecurityPolicy.allowConnectToSource(m_url)) {
    //     m_state = CLOSED;

    //     // FIXME: Should this be throwing an exception?
    //     return Exception { SecurityError };
    // }

    // FIXME: There is a disagreement about restriction of subprotocols between WebSocket API and hybi-10 protocol
    // draft. The former simply says "only characters in the range U+0021 to U+007E are allowed," while the latter
    // imposes a stricter rule: "the elements MUST be non-empty strings with characters as defined in [RFC2616],
    // and MUST all be unique strings."
    //
    // Here, we throw SyntaxError if the given protocols do not meet the latter criteria. This behavior does not
    // comply with WebSocket API specification, but it seems to be the only reasonable way to handle this conflict.
    for (auto& protocol : protocols) {
        if (!isValidProtocolString(protocol)) {
            // context.addConsoleMessage(MessageSource::JS, MessageLevel::Error, );
            m_state = CLOSED;
            updateHasPendingActivity();
            return Exception { SyntaxError, makeString("Wrong protocol for WebSocket '"_s, encodeProtocolString(protocol), "'"_s) };
        }
    }
    HashSet<String> visited;
    for (auto& protocol : protocols) {
        if (!visited.add(protocol).isNewEntry) {
            // context.addConsoleMessage(MessageSource::JS, MessageLevel::Error, );
            m_state = CLOSED;
            updateHasPendingActivity();
            return Exception { SyntaxError, makeString("WebSocket protocols contain duplicates:"_s, encodeProtocolString(protocol), "'"_s) };
        }
    }

    // RunLoop::main().dispatch([targetURL = m_url.isolatedCopy(), mainFrameURL = context.url().isolatedCopy()]() {
    //     ResourceLoadObserver::shared().logWebSocketLoading(targetURL, mainFrameURL);
    // });

    // if (is<Document>(context)) {
    //     Document& document = downcast<Document>(context);
    //     RefPtr<Frame> frame = document.frame();
    //     // FIXME: make the mixed content check equivalent to the non-document mixed content check currently in WorkerThreadableWebSocketChannel::Bridge::connect()
    //     if (!frame || !MixedContentChecker::canRunInsecureContent(*frame, document.securityOrigin(), m_url)) {
    //         failAsynchronously();
    //         return { };
    //     }
    // }

    String protocolString;
    if (!protocols.isEmpty())
        protocolString = joinStrings(protocols, subprotocolSeparator());

    String hostString = m_url.host().toString();
    auto resource = resourceName(m_url);
    String unixSocketPathString;
    if (is_unix) {
        // ws+unix:///path/to/sock.sock[:/request/path][?query]
        // The URL pathname is "/path/to/sock.sock:/request/path". Split on the
        // first ':' into the socket path and the HTTP request path, matching
        // the npm `ws` package's ws+unix: handling. Anything after the first
        // colon becomes the request path; if there is no colon the request
        // path is "/" (plus any query string).
        auto pathname = m_url.path();
        if (pathname.isEmpty()) {
            m_state = CLOSED;
            updateHasPendingActivity();
            return Exception { SyntaxError, makeString("Invalid url for WebSocket "_s, m_url.stringCenterEllipsizedToLength(), " (missing unix socket path)"_s) };
        }
        size_t colon = pathname.find(':');
        if (colon == notFound) {
            unixSocketPathString = pathname.toString();
            resource = makeString('/', m_url.queryWithLeadingQuestionMark());
        } else {
            unixSocketPathString = pathname.left(colon).toString();
            auto requestPath = pathname.substring(colon + 1);
            // Ensure origin-form per RFC 7230 §5.3.1 (leading '/').
            if (requestPath.isEmpty()) {
                resource = makeString('/', m_url.queryWithLeadingQuestionMark());
            } else if (requestPath.startsWith('/')) {
                resource = makeString(requestPath, m_url.queryWithLeadingQuestionMark());
            } else {
                resource = makeString('/', requestPath, m_url.queryWithLeadingQuestionMark());
            }
        }
        if (unixSocketPathString.isEmpty()) {
            m_state = CLOSED;
            updateHasPendingActivity();
            return Exception { SyntaxError, makeString("Invalid url for WebSocket "_s, m_url.stringCenterEllipsizedToLength(), " (missing unix socket path)"_s) };
        }
        // Host header defaults to "localhost" over a unix socket, matching
        // Node's http.request({ socketPath }) and the npm `ws` package.
        if (hostString.isEmpty()) {
            hostString = "localhost"_s;
        }
    }
    uint16_t port = is_secure ? 443 : 80;
    if (auto userPort = m_url.port()) {
        port = userPort.value();
    }

    Vector<String, 8> headerNameStrings;
    Vector<String, 8> headerValueStrings;

    auto headersOrException = FetchHeaders::create(WTF::move(headersInit));
    if (headersOrException.hasException()) [[unlikely]] {
        m_state = CLOSED;
        updateHasPendingActivity();
        return headersOrException.releaseException();
    }

    auto headers = headersOrException.releaseReturnValue();
    if (!headerNameStrings.tryReserveInitialCapacity(headers.get().internalHeaders().size())
        || !headerValueStrings.tryReserveInitialCapacity(headers.get().internalHeaders().size())) {
        m_state = CLOSED;
        updateHasPendingActivity();
        return Exception { OutOfMemoryError };
    }
    // lowerCaseKeys = false so we dont touch the keys casing
    auto iterator = headers.get().createIterator(false);
    for (;;) {
        auto next = iterator.next();
        if (next.hasException()) {
            m_state = CLOSED;
            updateHasPendingActivity();
            return next.releaseException();
        }
        auto value = next.releaseReturnValue();
        if (!value)
            break;
        headerNameStrings.unsafeAppendWithoutCapacityCheck(value->key);
        headerValueStrings.unsafeAppendWithoutCapacityCheck(value->value);
    }
    // Determine connection type based on proxy usage and TLS requirements
    bool hasProxy = proxyConfig.has_value();

    // Unix domain sockets are local; proxies do not apply.
    if (is_unix) {
        proxyConfig = std::nullopt;
        hasProxy = false;
    }

    // Check NO_PROXY even for explicitly-provided proxies
    if (hasProxy) {
        auto hostStr = m_url.host().toString();
        auto hostWithPort = hostName(m_url, is_secure);
        auto hostUtf8 = hostStr.utf8();
        auto hostWithPortUtf8 = hostWithPort.utf8();
        if (Bun::Bindgen::ZigExports::bunBindgenZig_Process_isNoProxy(
                std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(hostUtf8.data()), hostUtf8.length() },
                std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(hostWithPortUtf8.data()), hostWithPortUtf8.length() })) {
            proxyConfig = std::nullopt;
            hasProxy = false;
        }
    }

    bool proxyIsHTTPS = hasProxy && proxyConfig->isHTTPS;

    // Connection type determines what kind of socket we use:
    // - Plain/TLS: direct connection, socket type matches target protocol
    // - ProxyPlain/ProxyTLS: through proxy, socket type matches PROXY protocol (not target)
    if (hasProxy) {
        m_connectionType = proxyIsHTTPS ? ConnectionType::ProxyTLS : ConnectionType::ProxyPlain;
    } else {
        m_connectionType = is_secure ? ConnectionType::TLS : ConnectionType::Plain;
    }

    std::optional<String> proxyHost;
    std::optional<String> proxyAuthorization;
    uint16_t proxyPort = hasProxy ? proxyConfig->port : 0;

    Vector<String, 8> proxyHeaderNames;
    Vector<String, 8> proxyHeaderValues;
    if (hasProxy) {
        proxyHost = proxyConfig->host;
        if (!proxyConfig->authorization.isEmpty())
            proxyAuthorization = proxyConfig->authorization;
        if (!proxyHeaderNames.tryReserveInitialCapacity(proxyConfig->headers.size())
            || !proxyHeaderValues.tryReserveInitialCapacity(proxyConfig->headers.size())) {
            m_state = CLOSED;
            updateHasPendingActivity();
            return Exception { OutOfMemoryError };
        }
        for (const auto& header : proxyConfig->headers) {
            proxyHeaderNames.unsafeAppendWithoutCapacityCheck(header.first);
            proxyHeaderValues.unsafeAppendWithoutCapacityCheck(header.second);
        }
    }

    // Compute Basic auth from target URL credentials (for WebSocket upgrade request)
    std::optional<String> targetAuthorization;
    if (!m_url.user().isEmpty()) {
        auto credentials = makeString(m_url.user(), ':', m_url.password());
        auto utf8 = credentials.utf8();
        auto encoded = base64EncodeToString(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(utf8.data()), utf8.length()));
        targetAuthorization = makeString("Basic "_s, encoded);
    }

    this->incPendingActivityCount();
    auto* sslConfig = m_sslConfig.release();

    // Use TLS client based on connection type:
    // - TLS/ProxyTLS: use TLS socket
    // - Plain/ProxyPlain: use plain socket
    bool useTLSClient = (m_connectionType == ConnectionType::TLS || m_connectionType == ConnectionType::ProxyTLS);
    auto headerNames = std::span<const WTF::String> { headerNameStrings.span().data(), headerNameStrings.size() };
    auto headerValues = std::span<const WTF::String> { headerValueStrings.span().data(), headerValueStrings.size() };
    auto proxyHeadersNames = std::span<const WTF::String> { proxyHeaderNames.span().data(), proxyHeaderNames.size() };
    auto proxyHeadersValues = std::span<const WTF::String> { proxyHeaderValues.span().data(), proxyHeaderValues.size() };
    auto optionalSSLConfig = sslConfig ? std::optional<Bun::WebSocketSSLConfigNative*> { sslConfig } : std::nullopt;
    auto unixSocketPath = is_unix ? std::optional<String> { unixSocketPathString } : std::nullopt;

    if (useTLSClient) {
        this->m_upgradeClient.https = Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPSClientConnect(
            scriptExecutionContext()->jsGlobalObject(), this,
            hostString, port, resource, protocolString,
            headerNames, headerValues,
            proxyHost, proxyPort, proxyAuthorization,
            proxyHeadersNames, proxyHeadersValues,
            optionalSSLConfig, is_secure, targetAuthorization, unixSocketPath,
            m_offerPerMessageDeflate)
                                          .value_or(nullptr);
    } else {
        this->m_upgradeClient.http = Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPClientConnect(
            scriptExecutionContext()->jsGlobalObject(), this,
            hostString, port, resource, protocolString,
            headerNames, headerValues,
            proxyHost, proxyPort, proxyAuthorization,
            proxyHeadersNames, proxyHeadersValues,
            optionalSSLConfig, is_secure, targetAuthorization, unixSocketPath,
            m_offerPerMessageDeflate)
                                         .value_or(nullptr);
    }

    if (throwScope.exception()) {
        m_state = CLOSED;
        decPendingActivityCount();
        return Exception { ExistingExceptionError };
    }

    if (!this->hasUpgradeClient()) {
        m_state = CLOSED;
        if (auto* context = scriptExecutionContext()) {
            context->postTask([this, protectedThis = Ref { *this }](ScriptExecutionContext& context) {
                ASSERT(scriptExecutionContext());
                auto* globalObject = context.jsGlobalObject();

                auto eventInit = createErrorEventInit(protectedThis, "Failed to connect"_s, globalObject);
                auto message = eventInit.message;
                ErrorEvent::dispatch(protectedThis.get(), eventInit, EventIsTrusted::Yes);
                protectedThis->dispatchCloseEvent(false, 1006, message);

                protectedThis->decPendingActivityCount();
            });
        }
        return {};
    }

    m_state = CONNECTING;

    // #if ENABLE(INTELLIGENT_TRACKING_PREVENTION)
    //     auto reportRegistrableDomain = [domain = RegistrableDomain(m_url).isolatedCopy()](auto& context) mutable {
    //         if (auto* frame = downcast<Document>(context).frame())
    //             frame->loader().client().didLoadFromRegistrableDomain(WTF::move(domain));
    //     };
    //     if (is<Document>(context))
    //         reportRegistrableDomain(context);
    //     else
    //         downcast<WorkerGlobalScope>(context).thread().workerLoaderProxy().postTaskToLoader(WTF::move(reportRegistrableDomain));
    // #endif

    // m_pendingActivity = makePendingActivity(*this);
    updateHasPendingActivity();
    return {};
}

ExceptionOr<void> WebSocket::send(const String& message)
{
    // LOG(Network, "WebSocket %p send() Sending String '%s'", this, message.utf8().data());
    if (m_state == CONNECTING)
        return Exception { InvalidStateError };
    // No exception is raised if the connection was once established but has subsequently been closed.
    if (m_state == CLOSING || m_state == CLOSED) {
        auto utf8 = message.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
        size_t payloadSize = utf8.length();
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, payloadSize);
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, getFramingOverhead(payloadSize));
        return {};
    }

    this->sendWebSocketString(message, Opcode::Text);

    return {};
}

ExceptionOr<void> WebSocket::send(ArrayBuffer& binaryData)
{
    return send({ static_cast<const uint8_t*>(binaryData.data()), binaryData.byteLength() });
}

ExceptionOr<void> WebSocket::send(ArrayBufferView& arrayBufferView)
{
    auto bufferRef = arrayBufferView.unsharedBuffer();
    auto* buffer = bufferRef.get();
    auto* bytes = static_cast<const uint8_t*>(buffer->data()) + arrayBufferView.byteOffset();
    return send({ bytes, arrayBufferView.byteLength() });
}

ExceptionOr<void> WebSocket::send(std::span<const uint8_t> bytes)
{
    return sendBinary(bytes, Opcode::Binary);
}

WebCore::ExceptionOr<void> WebCore::WebSocket::send(WebCore::BlobImpl* blob)
{
    auto owner = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobSharedData(blob);
    if (!owner)
        return Exception { OutOfMemoryError };
    Bun::Bindgen::ByteOwner data { owner.value() };
    return send(data.bytes());
}

ExceptionOr<void> WebSocket::sendBinary(std::span<const uint8_t> bytes, Opcode opcode)
{
    if (m_state == CONNECTING)
        return Exception { InvalidStateError };
    if (m_state == CLOSING || m_state == CLOSED) {
        auto payloadSize = bytes.size();
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, payloadSize);
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, getFramingOverhead(payloadSize));
        return {};
    }

    sendWebSocketData(bytes, opcode);
    return {};
}

void WebSocket::sendWebSocketData(std::span<const uint8_t> bytes, const Opcode op)
{
    switch (m_connectedWebSocketKind) {
    case ConnectedWebSocketKind::Client: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientWriteBytes(this->m_connectedWebSocket.client, bytes, static_cast<uint8_t>(op));
        // this->m_connectedWebSocket.client->send({ baseAddress, length }, opCode);
        // this->m_bufferedAmount = this->m_connectedWebSocket.client->getBufferedAmount();
        break;
    }
    case ConnectedWebSocketKind::ClientSSL: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSWriteBytes(this->m_connectedWebSocket.clientSSL, bytes, static_cast<uint8_t>(op));
        break;
    }
    // case ConnectedWebSocketKind::Server: {
    //     this->m_connectedWebSocket.server->send({ baseAddress, length }, opCode);
    //     this->m_bufferedAmount = this->m_connectedWebSocket.server->getBufferedAmount();
    //     break;
    // }
    // case ConnectedWebSocketKind::ServerSSL: {
    //     this->m_connectedWebSocket.serverSSL->send({ baseAddress, length }, opCode);
    //     this->m_bufferedAmount = this->m_connectedWebSocket.serverSSL->getBufferedAmount();
    //     break;
    // }
    default: {
        RELEASE_ASSERT_NOT_REACHED();
    }
    }
}

void WebSocket::sendWebSocketString(const String& message, const Opcode op)
{
    switch (m_connectedWebSocketKind) {
    case ConnectedWebSocketKind::Client: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientWriteText(this->m_connectedWebSocket.client, message, static_cast<uint8_t>(op));
        // this->m_connectedWebSocket.client->send({ baseAddress, length }, opCode);
        // this->m_bufferedAmount = this->m_connectedWebSocket.client->getBufferedAmount();
        break;
    }
    case ConnectedWebSocketKind::ClientSSL: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSWriteText(this->m_connectedWebSocket.clientSSL, message, static_cast<uint8_t>(op));
        break;
    }
    // case ConnectedWebSocketKind::Server: {
    //     auto utf8 = message.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
    //     this->m_connectedWebSocket.server->send({ utf8.data(), utf8.length() }, uWS::OpCode::TEXT);
    //     this->m_bufferedAmount = this->m_connectedWebSocket.server->getBufferedAmount();
    //     break;
    // }
    // case ConnectedWebSocketKind::ServerSSL: {
    //     auto utf8 = message.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
    //     this->m_connectedWebSocket.serverSSL->send({ utf8.data(), utf8.length() }, uWS::OpCode::TEXT);
    //     this->m_bufferedAmount = this->m_connectedWebSocket.serverSSL->getBufferedAmount();
    //     break;
    // }
    default: {
        RELEASE_ASSERT_NOT_REACHED();
    }
    }
    updateHasPendingActivity();
}

// Called from close()/terminate() while m_state == CONNECTING.
//
// The Zig-side upgrade client's cancel() clears its back-pointer to us
// without calling didAbruptClose, so none of didConnect /
// didFailWithErrorCode / didClose will ever fire for this socket. We
// must therefore finish the close ourselves: cancel the upgrade, queue
// a task that moves to CLOSED, fires error + close events (spec "fail
// the WebSocket connection" path — code 1006, wasClean false), and
// releases the pending-activity ref taken in connect(). Without this
// the WebSocket stays in CLOSING with m_pendingActivityCount > 0
// forever and is never garbage-collected.
void WebSocket::failConnectingWebSocket()
{
    ASSERT(m_state == CONNECTING);
    m_state = CLOSING;

    if (hasUpgradeClient()) {
        if (usesTLSUpgradeClient()) {
            auto* upgradeClient = m_upgradeClient.https;
            clearUpgradeClient();
            Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPSClientCancel(upgradeClient);
        } else {
            auto* upgradeClient = m_upgradeClient.http;
            clearUpgradeClient();
            Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketHTTPClientCancel(upgradeClient);
        }
    }

    if (auto* context = scriptExecutionContext()) {
        context->postTask([protectedThis = Ref { *this }](ScriptExecutionContext& context) {
            if (protectedThis->m_state == CLOSED)
                return;
            protectedThis->m_state = CLOSED;
            if (protectedThis->m_native.onClose) {
                protectedThis->m_native.onClose(protectedThis->m_native.ctx, 1006);
            } else {
                // Spec: close() while CONNECTING runs "fail the WebSocket
                // connection", which requires an error event before the
                // close event. Matches Chrome/Firefox and npm ws.
                auto reason = "WebSocket is closed before the connection is established"_s;
                auto eventInit = createErrorEventInit(protectedThis, reason, context.jsGlobalObject());
                ErrorEvent::dispatch(protectedThis.get(), eventInit, EventIsTrusted::Yes);
                protectedThis->dispatchCloseEvent(false, 1006, reason);
            }
            protectedThis->releaseConnectionActivity();
        });
    } else {
        m_state = CLOSED;
        releaseConnectionActivity();
    }
    updateHasPendingActivity();
}

ExceptionOr<void> WebSocket::close(std::optional<unsigned short> optionalCode, const String& reason)
{
    int code = optionalCode ? optionalCode.value() : static_cast<int>(1000);
    auto utf8Reason = reason.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
    if (utf8Reason.length() > maxReasonSizeInBytes) {
        return Exception { SyntaxError, "WebSocket close message is too long."_s };
    }
    if (code == 1000) {
        // LOG(Network, "WebSocket %p close() without code and reason", this);
    } else {
        // LOG(Network, "WebSocket %p close() code=%d reason='%s'", this, code, reason.utf8().data());
        // if (!(code == WebSocketChannel::CloseEventCodeNormalClosure || (WebSocketChannel::CloseEventCodeMinimumUserDefined <= code && code <= WebSocketChannel::CloseEventCodeMaximumUserDefined)))
        //     return Exception { InvalidAccessError };
    }

    if (m_state == CLOSING || m_state == CLOSED)
        return {};
    if (m_state == CONNECTING) {
        failConnectingWebSocket();
        return {};
    }
    m_state = CLOSING;
    auto reasonBytes = std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8Reason.data()), utf8Reason.length() };
    switch (m_connectedWebSocketKind) {
    case ConnectedWebSocketKind::Client: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientClose(this->m_connectedWebSocket.client, code, reasonBytes);
        updateHasPendingActivity();
        // this->m_bufferedAmount = this->m_connectedWebSocket.client->getBufferedAmount();
        break;
    }
    case ConnectedWebSocketKind::ClientSSL: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSClose(this->m_connectedWebSocket.clientSSL, code, reasonBytes);
        updateHasPendingActivity();
        // this->m_bufferedAmount = this->m_connectedWebSocket.clientSSL->getBufferedAmount();
        break;
    }
    // case ConnectedWebSocketKind::Server: {
    // this->m_connectedWebSocket.server->end(code, { utf8.data(), utf8.length() });
    // this->m_bufferedAmount = this->m_connectedWebSocket.server->getBufferedAmount();
    //     break;
    // }
    // case ConnectedWebSocketKind::ServerSSL: {
    //     // this->m_connectedWebSocket.serverSSL->end(code, { utf8.data(), utf8.length() });
    //     // this->m_bufferedAmount = this->m_connectedWebSocket.serverSSL->getBufferedAmount();
    //     break;
    // }
    default: {
        break;
    }
    }
    updateHasPendingActivity();
    return {};
}

ExceptionOr<void> WebSocket::terminate()
{
    // LOG(Network, "WebSocket %p terminate()", this);

    if (m_state == CLOSED)
        return {};
    if (m_state == CONNECTING) {
        failConnectingWebSocket();
        return {};
    }
    m_state = CLOSING;
    switch (m_connectedWebSocketKind) {
    case ConnectedWebSocketKind::Client: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientCancel(this->m_connectedWebSocket.client);
        updateHasPendingActivity();
        break;
    }
    case ConnectedWebSocketKind::ClientSSL: {
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSCancel(this->m_connectedWebSocket.clientSSL);
        updateHasPendingActivity();
        break;
    }
    default: {
        break;
    }
    }
    this->m_connectedWebSocketKind = ConnectedWebSocketKind::None;
    updateHasPendingActivity();
    return {};
}

ExceptionOr<void> WebSocket::ping()
{
    return ping(std::span<const uint8_t> {});
}

ExceptionOr<void> WebSocket::ping(const String& message)
{
    // LOG(Network, "WebSocket %p ping() Sending String '%s'", this, message.utf8().data());
    if (m_state == CONNECTING)
        return Exception { InvalidStateError };

    // No exception is raised if the connection was once established but has subsequently been closed.
    if (m_state == CLOSING || m_state == CLOSED) {
        auto utf8 = message.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
        size_t payloadSize = utf8.length();
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, payloadSize);
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, getFramingOverhead(payloadSize));
        return {};
    }

    this->sendWebSocketString(message, Opcode::Ping);

    return {};
}

ExceptionOr<void> WebSocket::ping(ArrayBuffer& binaryData)
{
    return ping({ static_cast<const uint8_t*>(binaryData.data()), binaryData.byteLength() });
}

ExceptionOr<void> WebSocket::ping(ArrayBufferView& arrayBufferView)
{
    auto bufferRef = arrayBufferView.unsharedBuffer();
    auto* buffer = bufferRef.get();
    auto* bytes = static_cast<const uint8_t*>(buffer->data()) + arrayBufferView.byteOffset();
    return ping({ bytes, arrayBufferView.byteLength() });
}

ExceptionOr<void> WebSocket::ping(std::span<const uint8_t> bytes)
{
    return sendBinary(bytes, Opcode::Ping);
}

ExceptionOr<void> WebSocket::pong()
{
    return pong(std::span<const uint8_t> {});
}

ExceptionOr<void> WebSocket::pong(const String& message)
{
    // LOG(Network, "WebSocket %p pong() Sending String '%s'", this, message.utf8().data());
    if (m_state == CONNECTING)
        return Exception { InvalidStateError };

    // No exception is raised if the connection was once established but has subsequently been closed.
    if (m_state == CLOSING || m_state == CLOSED) {
        auto utf8 = message.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
        size_t payloadSize = utf8.length();
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, payloadSize);
        m_bufferedAmountAfterClose = saturateAdd(m_bufferedAmountAfterClose, getFramingOverhead(payloadSize));
        return {};
    }

    this->sendWebSocketString(message, Opcode::Pong);

    return {};
}

ExceptionOr<void> WebSocket::pong(ArrayBuffer& binaryData)
{
    return pong({ static_cast<const uint8_t*>(binaryData.data()), binaryData.byteLength() });
}

ExceptionOr<void> WebSocket::pong(ArrayBufferView& arrayBufferView)
{
    auto bufferRef = arrayBufferView.unsharedBuffer();
    auto* buffer = bufferRef.get();
    auto* bytes = static_cast<const uint8_t*>(buffer->data()) + arrayBufferView.byteOffset();
    return pong({ bytes, arrayBufferView.byteLength() });
}

ExceptionOr<void> WebSocket::pong(std::span<const uint8_t> bytes)
{
    return sendBinary(bytes, Opcode::Pong);
}

const URL& WebSocket::url() const
{
    return m_url;
}

WebSocket::State WebSocket::readyState() const
{
    return m_state;
}

unsigned WebSocket::bufferedAmount() const
{
    return saturateAdd(m_bufferedAmount, m_bufferedAmountAfterClose);
}

String WebSocket::protocol() const
{
    return m_subprotocol;
}

String WebSocket::extensions() const
{
    return m_extensions;
}

String WebSocket::binaryType() const
{
    switch (m_binaryType) {
    case BinaryType::NodeBuffer:
        return "nodebuffer"_s;
    case BinaryType::ArrayBuffer:
        return "arraybuffer"_s;
    case BinaryType::Blob:
        return "blob"_s;
    }

    ASSERT_NOT_REACHED();
    return String();
}

ExceptionOr<void> WebSocket::setBinaryType(const String& binaryType)
{
    if (binaryType == "blob"_s) {
        m_binaryType = BinaryType::Blob;
        return {};
    }
    if (binaryType == "arraybuffer"_s) {
        m_binaryType = BinaryType::ArrayBuffer;
        return {};
    } else if (binaryType == "nodebuffer"_s) {
        m_binaryType = BinaryType::NodeBuffer;
        return {};
    }
    // scriptExecutionContext()->addConsoleMessage(MessageSource::JS, MessageLevel::Error, "'" + binaryType + "' is not a valid value for binaryType; binaryType remains unchanged.");
    return Exception { SyntaxError, makeString("'"_s, binaryType, "' is not a valid value for binaryType; binaryType remains unchanged."_s) };
}

EventTargetInterface WebSocket::eventTargetInterface() const
{
    return WebSocketEventTargetInterfaceType;
}

ScriptExecutionContext* WebSocket::scriptExecutionContext() const
{
    return ContextDestructionObserver::scriptExecutionContext();
}

// void WebSocket::contextDestroyed()
// {
// LOG(Network, "WebSocket %p contextDestroyed()", this);
//     ASSERT(!m_channel);
//     ASSERT(m_state == CLOSED);
//     // ActiveDOMObject::contextDestroyed();
// }

// void WebSocket::suspend(ReasonForSuspension reason)
// {
//     // if (!m_channel)
//     //     return;

//     // if (reason == ReasonForSuspension::BackForwardCache) {
//     //     // This will cause didClose() to be called.
//     //     m_channel->fail("WebSocket is closed due to suspension."_s);
//     //     return;
//     // }

//     // m_channel->suspend();
// }

// void WebSocket::resume()
// {
//     // if (m_channel)
//     //     m_channel->resume();
// }

// void WebSocket::stop()
// {
//     if (m_channel)
//         m_channel->disconnect();
//     m_channel = nullptr;
//     m_state = CLOSED;
//     // ActiveDOMObject::stop();
//     // m_pendingActivity = nullptr;
// }

// const char* WebSocket::activeDOMObjectName() const
// {
//     return "WebSocket";
// }

void WebSocket::didConnect()
{
    // from new WebSocket() -> connect()

    // LOG(Network, "WebSocket %p didConnect()", this);
    // queueTaskKeepingObjectAlive(*this, TaskSource::WebSocket, [this] {
    if (m_state == CLOSED)
        return;
    if (m_state != CONNECTING) {
        didClose(0, 0, emptyString());
        return;
    }
    m_state = OPEN;

    // Native callback: fire synchronously, skip Event construction +
    // dispatchEvent + the postTask deferral. The m_state = OPEN above is
    // the only bookkeeping the native path needs — sendTextNative checks
    // it. incPendingActivityCount is a JS-GC-root concern; the native
    // consumer holds a RefPtr so it doesn't need it.
    if (m_native.onOpen) {
        m_native.onOpen(m_native.ctx);
        return;
    }

    if (auto* context = scriptExecutionContext()) {

        if (this->hasEventListeners("open"_s)) {
            this->incPendingActivityCount();
            // the main reason for dispatching on a separate tick is to handle when you haven't yet attached an event listener
            dispatchSimpleEvent(eventNames().openEvent);
            this->decPendingActivityCount();
        } else {
            this->incPendingActivityCount();
            context->postTask([this, protectedThis = Ref { *this }](ScriptExecutionContext& context) {
                ASSERT(scriptExecutionContext());
                protectedThis->dispatchSimpleEvent(eventNames().openEvent);
                protectedThis->decPendingActivityCount();
            });
        }
    }
}

void WebSocket::didReceiveMessage(String&& message)
{
    // LOG(Network, "WebSocket %p didReceiveMessage() Text message '%s'", this, message.utf8().data());
    // queueTaskKeepingObjectAlive(*this, TaskSource::WebSocket, [this, message = WTF::move(message)]() mutable {
    if (m_state != OPEN)
        return;

    // Native callback: hand off the UTF-8 bytes directly. UTF8View checks
    // is8Bit() && containsOnlyASCII() first — if true (the common case for
    // CDP JSON), span() is a zero-copy view over the existing buffer.
    // Only non-ASCII Latin1 or UTF-16 strings pay for a transcode into
    // a CString. The callback reads the span, we drop it — no
    // MessageEvent, no dispatchEvent, no postTask.
    if (m_native.onMessage) {
        Bun::UTF8View view(message);
        m_native.onMessage(m_native.ctx, view.span());
        return;
    }

    // if (InspectorInstrumentation::hasFrontends()) [[unlikely]] {
    //     if (auto* inspector = m_channel->channelInspector()) {
    //         auto utf8Message = message.utf8();
    //         inspector->didReceiveWebSocketFrame(WebSocketChannelInspector::createFrame(utf8Message.dataAsUInt8Ptr(), utf8Message.length(), WebSocketFrame::OpCode::OpCodeText));
    //     }
    // }

    if (this->hasEventListeners("message"_s)) {
        // the main reason for dispatching on a separate tick is to handle when you haven't yet attached an event listener
        this->incPendingActivityCount();
        dispatchEvent(MessageEvent::create(WTF::move(message), m_url.string()));
        this->decPendingActivityCount();
        return;
    }

    if (auto* context = scriptExecutionContext()) {
        this->incPendingActivityCount();
        context->postTask([this, message_ = WTF::move(message), protectedThis = Ref { *this }](ScriptExecutionContext& context) {
            ASSERT(scriptExecutionContext());
            protectedThis->dispatchEvent(MessageEvent::create(message_, protectedThis->m_url.string()));
            protectedThis->decPendingActivityCount();
        });
    }

    // });
}

void WebSocket::didReceiveBinaryData(const AtomString& eventName, const std::span<const uint8_t> binaryData)
{
    // LOG(Network, "WebSocket %p didReceiveBinaryData() %u byte binary message", this, static_cast<unsigned>(binaryData.size()));
    // queueTaskKeepingObjectAlive(*this, TaskSource::WebSocket, [this, binaryData = WTF::move(binaryData)]() mutable {
    if (m_state != OPEN)
        return;

    // if (InspectorInstrumentation::hasFrontends()) [[unlikely]] {
    //     if (auto* inspector = m_channel->channelInspector())
    //         inspector->didReceiveWebSocketFrame(WebSocketChannelInspector::createFrame(binaryData.data(), binaryData.size(), WebSocketFrame::OpCode::OpCodeBinary));
    // }
    switch (m_binaryType) {
    case BinaryType::Blob: {
        auto* context = scriptExecutionContext();
        if (!context) return;
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(context->vm());
        RefPtr<Blob> blob = Blob::create(binaryData, context->jsGlobalObject());
        if (scope.exception()) [[unlikely]] {
            if (!scope.clearExceptionExceptTermination()) return;
            this->incPendingActivityCount();
            ErrorEvent::Init errorInit;
            errorInit.message = "Failed to allocate memory for binary data"_s;
            ErrorEvent::dispatch(*this, errorInit);
            this->decPendingActivityCount();
            return;
        }
        if (this->hasEventListeners(eventName)) {
            // the main reason for dispatching on a separate tick is to handle when you haven't yet attached an event listener
            this->incPendingActivityCount();
            dispatchEvent(MessageEvent::create(eventName, blob.releaseNonNull(), m_url.string()));
            this->decPendingActivityCount();
            return;
        }

        {
            this->incPendingActivityCount();
            context->postTask([this, name = eventName, blob = blob.releaseNonNull(), protectedThis = Ref { *this }](ScriptExecutionContext& context) {
                ASSERT(scriptExecutionContext());
                protectedThis->dispatchEvent(MessageEvent::create(name, blob, protectedThis->m_url.string()));
                protectedThis->decPendingActivityCount();
            });
        }

        break;
    }
    case BinaryType::ArrayBuffer:
    case BinaryType::NodeBuffer: {
        auto* context = scriptExecutionContext();
        if (!context)
            return;
        auto buffer = JSC::ArrayBuffer::tryCreate(binaryData);
        if (!buffer) {
            this->incPendingActivityCount();
            ErrorEvent::Init errorInit;
            errorInit.message = "Failed to allocate memory for binary data"_s;
            ErrorEvent::dispatch(*this, errorInit);
            this->decPendingActivityCount();
            return;
        }

        MessageEvent::DataType data;
        if (m_binaryType == BinaryType::NodeBuffer)
            data = MessageEvent::NodeBufferData { buffer.releaseNonNull() };
        else
            data = buffer.releaseNonNull();

        if (this->hasEventListeners(eventName)) {
            this->incPendingActivityCount();
            dispatchEvent(MessageEvent::create(eventName, WTF::move(data), m_url.string()));
            this->decPendingActivityCount();
            return;
        }

        this->incPendingActivityCount();
        context->postTask([name = eventName, data = WTF::move(data), protectedThis = Ref { *this }](ScriptExecutionContext&) mutable {
            protectedThis->dispatchEvent(MessageEvent::create(name, WTF::move(data), protectedThis->m_url.string()));
            protectedThis->decPendingActivityCount();
        });
        break;
    }
    }
    // });
}

void WebSocket::didReceiveClose(CleanStatus wasClean, unsigned short code, WTF::String reason, bool isConnectionError)
{
    // LOG(Network, "WebSocket %p didReceiveErrorMessage()", this);
    // queueTaskKeepingObjectAlive(*this, TaskSource::WebSocket, [this, reason = WTF::move(reason)] {
    if (m_state == CLOSED)
        return;
    const bool wasConnecting = m_state == CONNECTING;
    m_state = CLOSED;

    // Native callback: state transitioned, hand off the close code.
    // Covers both connect-failure (didFailWithErrorCode →
    // didReceiveClose) and server-initiated close. The consumer's
    // onClose distinguishes by whether onOpen ever fired. Cleanup
    // (releaseConnectionActivity) is the caller's job — didFailWithErrorCode
    // posts it after the switch.
    if (m_native.onClose) {
        m_native.onClose(m_native.ctx, code);
        return;
    }

    if (auto* context = scriptExecutionContext()) {
        this->incPendingActivityCount();
        if (wasConnecting && isConnectionError) {
            auto eventInit = createErrorEventInit(*this, reason, context->jsGlobalObject());
            ErrorEvent::dispatch(*this, eventInit, EventIsTrusted::Yes);
        }
        // https://html.spec.whatwg.org/multipage/web-sockets.html#feedback-from-the-protocol:concept-websocket-closed, we should synchronously fire a close event.
        dispatchCloseEvent(wasClean == CleanStatus::Clean, code, reason);
        this->decPendingActivityCount();
    }
}

void WebSocket::didUpdateBufferedAmount(unsigned bufferedAmount)
{
    // LOG(Network, "WebSocket %p didUpdateBufferedAmount() New bufferedAmount is %u", this, bufferedAmount);
    if (m_state == CLOSED)
        return;
    m_bufferedAmount = bufferedAmount;
}

void WebSocket::didStartClosingHandshake()
{
    // LOG(Network, "WebSocket %p didStartClosingHandshake()", this);
    // queueTaskKeepingObjectAlive(*this, TaskSource::WebSocket, [this] {
    if (m_state == CLOSED)
        return;
    m_state = CLOSING;
    updateHasPendingActivity();
    // });
}

void WebSocket::didClose(unsigned unhandledBufferedAmount, unsigned short code, const String& reason)
{
    // LOG(Network, "WebSocket %p didClose()", this);
    if (this->m_connectedWebSocketKind == ConnectedWebSocketKind::None)
        return;

    // queueTaskKeepingObjectAlive(*this, TaskSource::WebSocket, [this, unhandledBufferedAmount, closingHandshakeCompletion, code, reason] {
    // if (!m_channel)
    //     return;

    // if (InspectorInstrumentation::hasFrontends()) [[unlikely]] {
    //     if (auto* inspector = m_channel->channelInspector()) {
    //         WebSocketFrame closingFrame(WebSocketFrame::OpCodeClose, true, false, false);
    //         inspector->didReceiveWebSocketFrame(closingFrame);
    //         inspector->didCloseWebSocket();
    //     }
    // }

    bool wasClean = m_state == CLOSING && !unhandledBufferedAmount && code != 0; // WebSocketChannel::CloseEventCodeAbnormalClosure;
    m_state = CLOSED;
    m_bufferedAmount = unhandledBufferedAmount;
    ASSERT(scriptExecutionContext());
    this->m_connectedWebSocketKind = ConnectedWebSocketKind::None;
    this->clearUpgradeClient();

    // Native callback: state transition above is done, hand off the code.
    // releaseConnectionActivity releases the GC-root ref connect() took —
    // the native consumer holds a RefPtr so GC-rooting doesn't matter,
    // but the count should balance for the ASSERT below and any future
    // consumer of hasPendingActivity().
    if (m_native.onClose) {
        m_native.onClose(m_native.ctx, code);
        releaseConnectionActivity();
        return;
    }

    // since we are open and closing now we know that we have at least one pending activity
    // so we just call decPendingActivityCount() after dispatching the event
    ASSERT(m_pendingActivityCount > 0);

    if (this->hasEventListeners("close"_s)) {
        dispatchCloseEvent(wasClean, code, reason);

        // we deinit if possible in the next tick
        if (auto* context = scriptExecutionContext()) {
            context->postTask([this, protectedThis = Ref { *this }](ScriptExecutionContext& context) {
                ASSERT(scriptExecutionContext());
                protectedThis->releaseConnectionActivity();
            });
            return;
        }
    } else if (auto* context = scriptExecutionContext()) {
        context->postTask([this, code, wasClean, reason, protectedThis = Ref { *this }](ScriptExecutionContext& context) {
            ASSERT(scriptExecutionContext());
            protectedThis->dispatchCloseEvent(wasClean, code, reason);
            protectedThis->releaseConnectionActivity();
        });
        return;
    }

    this->releaseConnectionActivity();
}

void WebSocket::dispatchCloseEvent(bool wasClean, unsigned short code, const String& reason)
{
    Ref protectedThis { *this };
    auto* context = scriptExecutionContext();
    if (!context)
        return;
    auto* global = context->globalObject();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
    if (!scope.exception()) {
        auto event = CloseEvent::tryCreate(wasClean, code, reason);
        if (event)
            dispatchEvent(*event);
        else {
            auto throwScope = DECLARE_THROW_SCOPE(global->vm());
            throwOutOfMemoryError(global, throwScope);
        }
    }
    if (auto* exception = scope.exception())
        reportException(global, exception);
}

void WebSocket::didConnect(us_socket_t* socket, std::span<const uint8_t> bufferedData, const PerMessageDeflateParams* deflate_params, ssl_ctx_st* customSSLCtx)
{
    Ref protectedThis { *this };
    auto* globalObject = scriptExecutionContext()->jsGlobalObject();
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    std::unique_ptr<us_socket_t, decltype(&Bun::Bindgen::Engine::releaseWebSocketUpgradeSocket)> ownedSocket(socket, Bun::Bindgen::Engine::releaseWebSocketUpgradeSocket);
    setExtensionsFromDeflateParams(deflate_params);

    // Use TLS WebSocket client if connection type is TLS or ProxyTLS.
    // For TLS: direct wss:// connection, socket is already TLS.
    // For ProxyTLS: connected through HTTPS proxy, socket is TLS (even for ws:// target).
    // For Plain/ProxyPlain: socket is not TLS.
    bool useTLSSocket = (m_connectionType == ConnectionType::TLS || m_connectionType == ConnectionType::ProxyTLS);
    auto deflateParams = deflate_params ? std::optional<const PerMessageDeflateParams*> { deflate_params } : std::nullopt;
    auto sslContext = customSSLCtx ? std::optional<ssl_ctx_st*> { customSSLCtx } : std::nullopt;

    if (useTLSSocket) {
        auto client = Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSAdoptSocket(globalObject, this, ownedSocket.release(), bufferedData, deflateParams, sslContext);
        RETURN_IF_EXCEPTION(scope, void());
        if (!client) {
            didFailWithErrorCode(Bun::WebSocketErrorCode::failed_to_connect);
            return;
        }
        this->m_connectedWebSocket.clientSSL = client.value();
        this->m_connectedWebSocketKind = ConnectedWebSocketKind::ClientSSL;
    } else {
        auto client = Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientAdoptSocket(globalObject, this, ownedSocket.release(), bufferedData, deflateParams, sslContext);
        RETURN_IF_EXCEPTION(scope, void());
        if (!client) {
            didFailWithErrorCode(Bun::WebSocketErrorCode::failed_to_connect);
            return;
        }
        this->m_connectedWebSocket.client = client.value();
        this->m_connectedWebSocketKind = ConnectedWebSocketKind::Client;
    }

    this->didConnect();
    RETURN_IF_EXCEPTION(scope, void());
}

void WebSocket::didFailWithErrorCode(Bun::WebSocketErrorCode code)
{
    // from new WebSocket() -> connect()

    if (m_state == CLOSED)
        return;

    this->clearUpgradeClient();
    if (this->m_connectedWebSocketKind == ConnectedWebSocketKind::ClientSSL) {
        this->m_connectedWebSocket.clientSSL = nullptr;
    } else if (this->m_connectedWebSocketKind == ConnectedWebSocketKind::Client) {
        this->m_connectedWebSocket.client = nullptr;
    }
    this->m_connectedWebSocketKind = ConnectedWebSocketKind::None;
    switch (code) {

    case Bun::WebSocketErrorCode::cancel: {
        didReceiveClose(CleanStatus::NotClean, 1000, "Connection cancelled"_s);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_response: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Invalid response"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::expected_101_status_code: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Expected 101 status code"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::missing_upgrade_header: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Missing upgrade header"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::missing_connection_header: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Missing connection header"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::missing_websocket_accept_header: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Missing websocket accept header"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_upgrade_header: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Invalid upgrade header"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_connection_header: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Invalid connection header"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_websocket_version: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Invalid websocket version"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::mismatch_websocket_accept_header: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Mismatch websocket accept header"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::missing_client_protocol: {
        didReceiveClose(CleanStatus::Clean, 1002, "Missing client protocol"_s);
        break;
    }
    case Bun::WebSocketErrorCode::mismatch_client_protocol: {
        didReceiveClose(CleanStatus::Clean, 1002, "Mismatch client protocol"_s);
        break;
    }
    case Bun::WebSocketErrorCode::timeout: {
        didReceiveClose(CleanStatus::Clean, 1013, "Timeout"_s);
        break;
    }
    case Bun::WebSocketErrorCode::closed: {
        didReceiveClose(CleanStatus::Clean, 1000, "Closed by client"_s);
        break;
    }
    case Bun::WebSocketErrorCode::failed_to_write: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Failed to write"_s);
        break;
    }
    case Bun::WebSocketErrorCode::failed_to_connect: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Failed to connect"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::headers_too_large: {
        didReceiveClose(CleanStatus::NotClean, 1007, "Headers too large"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::ended: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Connection ended"_s, true);
        break;
    }

    case Bun::WebSocketErrorCode::failed_to_allocate_memory: {
        didReceiveClose(CleanStatus::NotClean, 1001, "Failed to allocate memory"_s);
        break;
    }
    case Bun::WebSocketErrorCode::control_frame_is_fragmented: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error - control frame is fragmented"_s);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_control_frame: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error - invalid control frame"_s);
        break;
    }
    case Bun::WebSocketErrorCode::compression_unsupported: {
        didReceiveClose(CleanStatus::Clean, 1011, "Compression not implemented yet"_s);
        break;
    }
    case Bun::WebSocketErrorCode::unexpected_mask_from_server: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error - unexpected mask from server"_s);
        break;
    }
    case Bun::WebSocketErrorCode::expected_control_frame: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error - expected control frame"_s);
        break;
    }
    case Bun::WebSocketErrorCode::unsupported_control_frame: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error - unsupported control frame"_s);
        break;
    }
    case Bun::WebSocketErrorCode::unexpected_opcode: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error - unexpected opcode"_s);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_utf8: {
        didReceiveClose(CleanStatus::NotClean, 1003, "Server sent invalid UTF8"_s);
        break;
    }
    case Bun::WebSocketErrorCode::tls_handshake_failed: {
        didReceiveClose(CleanStatus::NotClean, 1015, "TLS handshake failed"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::message_too_big: {
        didReceiveClose(CleanStatus::NotClean, 1009, "Message too big"_s);
        break;
    }
    case Bun::WebSocketErrorCode::protocol_error: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Protocol error"_s);
        break;
    }
    case Bun::WebSocketErrorCode::compression_failed: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Compression failed"_s);
        break;
    }
    case Bun::WebSocketErrorCode::invalid_compressed_data: {
        didReceiveClose(CleanStatus::NotClean, 1002, "Invalid compressed data"_s);
        break;
    }
    case Bun::WebSocketErrorCode::proxy_connect_failed: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Proxy connection failed"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::proxy_authentication_required: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Proxy authentication required"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::proxy_connection_refused: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Proxy connection refused"_s, true);
        break;
    }
    case Bun::WebSocketErrorCode::proxy_tunnel_failed: {
        didReceiveClose(CleanStatus::NotClean, 1006, "Proxy tunnel failed"_s, true);
        break;
    }
    }

    // didReceiveClose already set m_state = CLOSED. The connect() ref
    // kept us alive across the switch (including across the native
    // onClose callback dropping its RefPtr); release it from a task so
    // the caller's stack frame unwinds first. ContextDestructionObserver
    // holds a WeakPtr — a Worker terminated mid-connect returns null
    // here; deref directly since there's no loop to post to.
    if (auto* context = scriptExecutionContext()) {
        context->postTask([protectedThis = Ref { *this }](ScriptExecutionContext&) {
            protectedThis->releaseConnectionActivity();
        });
    } else {
        this->deref();
    }
}

void WebSocket::releaseConnectionActivity()
{
    // Queued event deliveries retain their own activity references.
    this->decPendingActivityCount();
}

void WebSocket::updateHasPendingActivity()
{
    std::atomic_thread_fence(std::memory_order_acquire);
    m_hasPendingActivity.store(
        !(m_state == CLOSED && m_pendingActivityCount == 0));
}

void WebSocket::didConnectWithTunnel(Bun::WebSocketProxyTunnelNative* tunnel, std::span<const uint8_t> bufferedData, const PerMessageDeflateParams* deflate_params)
{
    Ref protectedThis { *this };
    auto* globalObject = scriptExecutionContext()->jsGlobalObject();
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    setExtensionsFromDeflateParams(deflate_params);

    // For wss:// through HTTP proxy, we use a plain (non-TLS) WebSocket client
    // because the TLS is handled by the proxy tunnel
    auto deflateParams = deflate_params ? std::optional<const PerMessageDeflateParams*> { deflate_params } : std::nullopt;
    this->m_connectedWebSocket.client = Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketClientCreateWithTunnel(
        globalObject,
        this,
        tunnel,
        bufferedData,
        deflateParams);
    RETURN_IF_EXCEPTION(scope, void());
    this->m_connectedWebSocketKind = ConnectedWebSocketKind::Client;

    // IMPORTANT: Call didConnect() BEFORE setting the connected websocket on the tunnel.
    // didConnect() sets m_state = OPEN, and messages are dropped if state != OPEN.
    // By calling didConnect() first, we ensure the state is OPEN before the tunnel
    // starts forwarding messages to the WebSocket client.
    this->didConnect();
    RETURN_IF_EXCEPTION(scope, void());

    // Now set the connected websocket on the tunnel to start forwarding data
    if (m_connectedWebSocketKind == ConnectedWebSocketKind::Client && m_connectedWebSocket.client)
        Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketProxyTunnelSetConnectedWebSocket(tunnel, m_connectedWebSocket.client);
}

} // namespace WebCore

void Bun::Bindgen::Engine::releaseWebSocketUpgradeSocket(us_socket_t* socket)
{
    ZigExports::bunBindgenZig_websocket_client_discardUpgradeSocket(socket);
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketClearUpgradeClient(
    const BunBindgenEngine_websocket_client_webSocketClearUpgradeClient_Arguments& args)
{
    args.webSocket->clearUpgradeClient();
}

void Bun::Bindgen::Engine::releaseWebSocketClient(Bun::WebSocketClientNative* client)
{
    ZigExports::bunBindgenZig_websocket_client_webSocketClientFinalize(client);
}

void Bun::Bindgen::Engine::releaseWebSocketClientTLS(Bun::WebSocketClientTLSNative* client)
{
    ZigExports::bunBindgenZig_websocket_client_webSocketClientTLSFinalize(client);
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDidConnect(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_websocket_client_webSocketDidConnect_Arguments& args)
{
    args.webSocket->didConnect(
        args.socket,
        args.bufferedData,
        args.deflateParams.value_or(nullptr),
        args.sslContext.value_or(nullptr));
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDidConnectWithTunnel(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_websocket_client_webSocketDidConnectWithTunnel_Arguments& args)
{
    args.webSocket->didConnectWithTunnel(
        args.tunnel,
        args.bufferedData,
        args.deflateParams.value_or(nullptr));
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDidAbruptClose(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_websocket_client_webSocketDidAbruptClose_Arguments& args)
{
    args.webSocket->didFailWithErrorCode(static_cast<Bun::WebSocketErrorCode>(args.errorCode));
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDidClose(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_websocket_client_webSocketDidClose_Arguments& args)
{
    args.webSocket->didClose(0, args.code, args.reason);
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDidReceiveText(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_websocket_client_webSocketDidReceiveText_Arguments& args)
{
    args.webSocket->didReceiveMessage(WTF::String(args.text));
}
void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDidReceiveBytes(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_websocket_client_webSocketDidReceiveBytes_Arguments& args)
{
    auto opcode = static_cast<WebCore::WebSocket::Opcode>(args.opcode);
    switch (opcode) {
    case WebCore::WebSocket::Opcode::Binary:
        args.webSocket->didReceiveBinaryData("message"_s, args.bytes);
        break;
    case WebCore::WebSocket::Opcode::Ping:
        args.webSocket->didReceiveBinaryData("ping"_s, args.bytes);
        break;
    case WebCore::WebSocket::Opcode::Pong:
        args.webSocket->didReceiveBinaryData("pong"_s, args.bytes);
        break;
    default:
        break;
    }
}
bool Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketRejectUnauthorized(
    const BunBindgenEngine_websocket_client_webSocketRejectUnauthorized_Arguments& args)
{
    return args.webSocket->rejectUnauthorized();
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketIncrementPendingActivity(
    const BunBindgenEngine_websocket_client_webSocketIncrementPendingActivity_Arguments& args)
{
    args.webSocket->incPendingActivityCount();
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketDecrementPendingActivity(
    const BunBindgenEngine_websocket_client_webSocketDecrementPendingActivity_Arguments& args)
{
    args.webSocket->decPendingActivityCount();
}

WebCore::ExceptionOr<void> WebCore::WebSocket::ping(WebCore::BlobImpl* blob)
{
    auto owner = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobSharedData(blob);
    if (!owner)
        return Exception { OutOfMemoryError };
    Bun::Bindgen::ByteOwner data { owner.value() };
    return ping(data.bytes());
}

WebCore::ExceptionOr<void> WebCore::WebSocket::pong(WebCore::BlobImpl* blob)
{
    auto owner = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobSharedData(blob);
    if (!owner)
        return Exception { OutOfMemoryError };
    Bun::Bindgen::ByteOwner data { owner.value() };
    return pong(data.bytes());
}

void WebCore::WebSocket::setProtocol(const String& protocol)
{
    m_subprotocol = protocol;
}

void Bun::Bindgen::Engine::bunBindgenEngine_websocket_client_webSocketSetProtocol(
    const BunBindgenEngine_websocket_client_webSocketSetProtocol_Arguments& args)
{
    args.webSocket->setProtocol(args.protocol);
}

void Bun::Bindgen::Engine::releaseWebSocketSSLConfig(Bun::WebSocketSSLConfigNative* config)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_websocket_client_webSocketSSLConfigDestroy(config);
}
