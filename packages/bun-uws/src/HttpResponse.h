/*
 * Authored by Alex Hultman, 2018-2020.
 * Intellectual property of third-party.

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at

 *     http://www.apache.org/licenses/LICENSE-2.0

 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
// clang-format off
#ifndef UWS_HTTPRESPONSE_H
#define UWS_HTTPRESPONSE_H

/* An HttpResponse is the channel on which you send back a response */

#include "AsyncSocket.h"
#include "HttpResponseData.h"
#include "HttpContext.h"
#include "HttpContextData.h"
#include "Utilities.h"

#include "WebSocketExtensions.h"
#include "WebSocketHandshake.h"
#include "WebSocket.h"
#include "WebSocketContextData.h"

#include "MoveOnlyFunction.h"
#include <algorithm>
#include <limits>
#include <type_traits>

namespace uWS {

template <bool, bool, typename> struct WebSocketContext;

template <bool SSL>
struct HttpResponse : public AsyncSocket<SSL> {
    /* Solely used for getHttpResponseData() */
    template <bool> friend struct TemplatedApp;
    typedef AsyncSocket<SSL> Super;
public:

    HttpResponseData<SSL> *getHttpResponseData() {
        return (HttpResponseData<SSL> *) Super::getAsyncSocketData();
    }

    static HttpResponseData<SSL> *getHttpResponseDataS(us_socket_t *s) {
        return (HttpResponseData<SSL> *) us_socket_ext(s);
    }

    void setTimeout(uint8_t seconds) {
        auto* data = getHttpResponseData();
        data->idleTimeout = seconds;
        Super::timeout(data->idleTimeout);
    }

    void resetTimeout() {
        auto* data = getHttpResponseData();

        Super::timeout(data->idleTimeout);
    }
    /* Called only once per request */
    [[nodiscard]] WriteStatus writeMark() {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        if (getHttpResponseData()->state & HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER) {
            return WriteStatus::Complete;
        }
        const auto result = writeHeader("Date", std::string_view(Super::getLoopData()->date, 29));
        return result;
    }

private:
    WriteStatus prepareEndHeaders(std::optional<uint64_t> contentLength, bool closeConnection) {
        auto *data = getHttpResponseData();
        const bool first = !(data->state & (HttpResponseData<SSL>::HTTP_WRITE_CALLED | HttpResponseData<SSL>::HTTP_END_CALLED));
        const bool needsStatus = !(data->state & HttpResponseData<SSL>::HTTP_STATUS_CALLED);
        const bool needsDate = first && !(data->state & HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER);
        const bool needsLength = first && contentLength && !(data->state & HttpResponseData<SSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER);
        const bool needsClose = first && closeConnection && !(data->state & HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE);
        char lengthBuffer[20];
        std::string_view lengthValue;
        if (needsLength) lengthValue = std::string_view(lengthBuffer, static_cast<size_t>(utils::u64toa(*contentLength, lengthBuffer)));
        const auto status = Super::writeParts({
            needsStatus ? "HTTP/1.1 200 OK\r\n" : "",
            needsClose ? "Connection: close\r\n" : "",
            needsDate ? "Date: " : "",
            needsDate ? std::string_view(Super::getLoopData()->date, 29) : std::string_view(),
            needsDate ? "\r\n" : "",
            needsLength ? "Content-Length: " : "",
            lengthValue,
            needsLength ? "\r\n" : "",
            first ? "\r\n" : "",
        });
        if (status == WriteStatus::OutOfMemory || status == WriteStatus::Closed) return status;
        if (needsStatus) {
            data->state |= HttpResponseData<SSL>::HTTP_STATUS_CALLED;
            data->webSocketStatusWritten = false;
        }
        if (needsDate) data->state |= HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER;
        if (needsLength) data->state |= HttpResponseData<SSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER;
        if (closeConnection) data->state |= HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE;
        data->state |= HttpResponseData<SSL>::HTTP_END_CALLED;
        return status;
    }

    WriteStatus finishResponse() {
        const auto flushed = Super::uncork().status;
        if (flushed == WriteStatus::OutOfMemory || flushed == WriteStatus::Closed) return flushed;
        resetTimeout();
        auto *data = getHttpResponseData();
        data->markDone(this);
        if ((data->state & HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE) && !Super::hasPendingOutput()) {
            Super::shutdown();
            Super::close();
        }
        return WriteStatus::Complete;
    }

    WriteStatus internalEnd(std::string_view body, std::optional<uint64_t> totalSize,
            std::optional<uint64_t> contentLength, bool closeConnection) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        auto *data = getHttpResponseData();
        if (!(data->state & HttpResponseData<SSL>::HTTP_RESPONSE_PENDING)) return WriteStatus::Complete;
        const bool chunked = (data->state & HttpResponseData<SSL>::HTTP_WRITE_CALLED) &&
            !(data->state & HttpResponseData<SSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER) && !data->fromAncientRequest;
        const auto headers = prepareEndHeaders(contentLength, closeConnection);
        if (headers == WriteStatus::OutOfMemory || headers == WriteStatus::Closed) return headers;
        if (chunked) {
            const auto written = write(body);
            if (written == WriteStatus::OutOfMemory || written == WriteStatus::Closed) return written;
            const auto terminated = Super::writeParts({"0\r\n\r\n"});
            if (terminated == WriteStatus::OutOfMemory || terminated == WriteStatus::Closed) return terminated;
            return finishResponse();
        }
        const auto written = writeBody(body, totalSize.has_value());
        if (written.status == WriteStatus::OutOfMemory || written.status == WriteStatus::Closed) return written.status;
        if (!totalSize || getHttpResponseData()->offset == *totalSize) {
            const auto finished = finishResponse();
            if (finished == WriteStatus::OutOfMemory || finished == WriteStatus::Closed) return finished;
        } else {
            resetTimeout();
        }
        return totalSize ? written.status : WriteStatus::Complete;
    }

public:
    /* If we have proxy support; returns the proxed source address as reported by the proxy. */
#ifdef UWS_WITH_PROXY
    std::string_view getProxiedRemoteAddress() {
        return getHttpResponseData()->proxyParser.getSourceAddress();
    }

    std::string_view getProxiedRemoteAddressAsText() {
        return Super::addressAsText(getProxiedRemoteAddress());
    }


#endif

    void setWebSocketCompressionEnabled(bool enabled) {
        getHttpResponseData()->webSocketCompressionEnabled = enabled;
    }

    template <typename UserData>
    std::optional<PreparedWebSocketUpgrade> prepareUpgrade(std::string_view key, std::string_view protocol, std::string_view extensions,
            WebSocketContext<SSL, true, UserData> *context, WebSocketUpgradeError &error) {
        const auto *data = getHttpResponseData();
        const auto state = data->state;
        if ((state & (HttpResponseData<SSL>::HTTP_WRITE_CALLED | HttpResponseData<SSL>::HTTP_END_CALLED)) ||
            ((state & HttpResponseData<SSL>::HTTP_STATUS_CALLED) && !data->webSocketStatusWritten)) {
            error = WebSocketUpgradeError::InvalidResponseState;
            return std::nullopt;
        }
        auto compression = data->webSocketCompressionEnabled
            ? context->getExt()->compression : CompressOptions::DISABLED;
        return PreparedWebSocketUpgrade::prepare(Super::getLoopData(), compression, key, protocol, extensions,
            !(state & HttpResponseData<SSL>::HTTP_STATUS_CALLED), !(state & HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER), error);
    }

    bool finishUpgrade(PreparedWebSocketUpgrade &prepared) {
        auto *loop = Super::getLoopData();
        const int slot = loop->findCorkSlot(this);
        const auto corked = slot == LoopData::INVALID_CORK_SLOT ? std::string_view()
            : std::string_view(loop->getCorkSlot(slot)->buffer, loop->getCorkSlot(slot)->offset);
        return prepared.finish(std::string_view(loop->date, 29), getHttpResponseData()->buffer.view(), corked);
    }

    template <typename UserData>
    us_socket_t *upgrade(UserData&& userData, PreparedWebSocketUpgrade&& prepared,
            WebSocketContext<SSL, true, UserData> *webSocketContext) {
        static_assert(std::is_pointer_v<UserData>, "WebSocket user data is an opaque native owner pointer");
        static_assert(sizeof(WebSocketData) + sizeof(UserData) <= HttpContext<SSL>::socketExtensionSize);

        /* Extract needed parameters from WebSocketContextData */
        WebSocketContextData<SSL, UserData> *webSocketContextData = webSocketContext->getExt();

        RELEASE_ASSERT(prepared.ready);
        auto *responseData = getHttpResponseData();
        auto *loop = Super::getLoopData();
        const int slot = loop->findCorkSlot(this);
        const bool needsFlush = slot == LoopData::INVALID_CORK_SLOT || prepared.output.size() > LoopData::CORK_BUFFER_SIZE;
        if (needsFlush) {
            responseData->buffer.adopt(std::move(prepared.output));
            if (slot != LoopData::INVALID_CORK_SLOT) loop->getCorkSlot(slot)->offset = 0;
        } else {
            auto *cork = loop->getCorkSlot(slot);
            memcpy(cork->buffer, prepared.output.data(), prepared.output.size());
            cork->offset = static_cast<unsigned int>(prepared.output.size());
            responseData->buffer.clear();
            loop->touchCorkSlot(slot);
        }
        responseData->state |= HttpResponseData<SSL>::HTTP_STATUS_CALLED |
            HttpResponseData<SSL>::HTTP_END_CALLED | HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER;
        responseData->markDone(this);

        /* Grab the httpContext from res */
        HttpContext<SSL> *httpContext = HttpContext<SSL>::fromSocket((struct us_socket_t *) this);

        /* Move any backpressure out of HttpResponse */
        BackPressure backpressure(std::move(((AsyncSocketData<SSL> *) responseData)->buffer));

        auto* socketData = responseData->socketData;
        HttpContextData<SSL> *httpContextData = httpContext->getSocketContextData();

        /* Destroy HttpResponseData */
        responseData->~HttpResponseData();

        /* Before we adopt and potentially change socket, check which cork slot
         * we occupy so we can transfer it to the new WebSocket. */
        LoopData *loopData = Super::getLoopData();
        int corkedSlot = loopData->findCorkSlot(this);

        /* HTTP sockets reserve storage for either protocol; only group ownership changes. */
        webSocketContext->ref();
        us_socket_t *usSocket = us_socket_adopt((us_socket_t *) this, webSocketContext->getSocketGroup(),
            WebSocketContext<SSL, true, UserData>::socketKind(),
            HttpContext<SSL>::socketExtensionSize, -1);
        WebSocket<SSL, true, UserData> *webSocket = (WebSocket<SSL, true, UserData> *) usSocket;

        /* For whatever reason we were corked, update cork to the new socket */
        if (corkedSlot != LoopData::INVALID_CORK_SLOT) {
            loopData->transferCorkSlot(corkedSlot, webSocket, SSL);
        }

        /* Initialize websocket with any moved backpressure intact */
        webSocket->init(std::move(prepared), std::move(backpressure), socketData, httpContextData->onSocketClosed);
        if (httpContextData->onSocketUpgraded) {
            httpContextData->onSocketUpgraded(socketData, SSL, usSocket);
        }

        /* We should only mark this if inside the parser; if upgrading "async" we cannot set this */
        if (httpContextData->flags.isParsingHttp) {
            /* We need to tell the Http parser that we changed socket */
            httpContextData->upgradedWebSocket = webSocket;
        }

        /* Arm maxLifetime timeout */
        us_socket_long_timeout((us_socket_t *) webSocket, webSocketContextData->maxLifetime);

        /* Arm idleTimeout */
        us_socket_timeout((us_socket_t *) webSocket, webSocketContextData->idleTimeoutComponents.first);

        /* Move construct the UserData right before calling open handler */
        new (webSocket->getUserData()) UserData(std::forward<UserData>(userData));

        if (needsFlush && webSocket->flush() == WriteStatus::Closed) return usSocket;

        /* Emit open event and start the timeout */
        if (webSocketContextData->openHandler) {
            webSocketContextData->openHandler(webSocket);
        }

        return usSocket;
    }

    /* Immediately terminate this Http response */
    using Super::close;

    /* See AsyncSocket */
    using Super::getRemoteAddress;
    using Super::getRemoteAddressAsText;
    using Super::getNativeHandle;

    /* Throttle reads and writes */
    HttpResponse *pause() {
        Super::pause();
        Super::timeout(0);
        return this;
    }

    HttpResponse *resume() {
        Super::resume();
        this->resetTimeout();
        return this;
    }

    /* Note: Headers are not checked in regards to timeout.
     * We only check when you actively push data or end the request */

    /* Write 100 Continue, can be done any amount of times */
    [[nodiscard]] WriteStatus writeContinue() {
        return Super::writeParts({"HTTP/1.1 100 Continue\r\n\r\n"});
    }

    /* Write the HTTP status */
    [[nodiscard]] WriteStatus writeStatus(std::string_view status) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        /* Do not allow writing more than one status */
        if (httpResponseData->state & HttpResponseData<SSL>::HTTP_STATUS_CALLED) {
            return WriteStatus::Complete;
        }

        const auto result = Super::writeParts({"HTTP/1.1 ", status, "\r\n"});
        if (result == WriteStatus::OutOfMemory || result == WriteStatus::Closed) return result;
        httpResponseData->state |= HttpResponseData<SSL>::HTTP_STATUS_CALLED;
        httpResponseData->webSocketStatusWritten = status == "101" || status.starts_with("101 ");
        return result;
    }

    /* Write an HTTP header with string value */
    [[nodiscard]] WriteStatus writeHeader(std::string_view key, std::string_view value) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        auto *data = getHttpResponseData();
        const bool needsStatus = !(data->state & HttpResponseData<SSL>::HTTP_STATUS_CALLED);
        const bool date = HttpHeaderSyntax::equalsIgnoringCase(key, "Date");
        const bool contentLength = HttpHeaderSyntax::equalsIgnoringCase(key, "Content-Length");
        const bool transferEncoding = HttpHeaderSyntax::equalsIgnoringCase(key, "Transfer-Encoding");
        const auto result = Super::writeParts({needsStatus ? "HTTP/1.1 200 OK\r\n" : "", key, ": ", value, "\r\n"});
        if (result == WriteStatus::OutOfMemory || result == WriteStatus::Closed) return result;
        if (needsStatus) {
            data->state |= HttpResponseData<SSL>::HTTP_STATUS_CALLED;
            data->webSocketStatusWritten = false;
        }
        if (date) data->state |= HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER;
        if (contentLength) data->state |= HttpResponseData<SSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER;
        if (transferEncoding) data->state |= HttpResponseData<SSL>::HTTP_WROTE_TRANSFER_ENCODING_HEADER;
        return result;
    }

    /* Write an HTTP header with unsigned int value */
    [[nodiscard]] WriteStatus writeHeader(std::string_view key, uint64_t value) {
        char buffer[20];
        const int length = utils::u64toa(value, buffer);
        return writeHeader(key, std::string_view(buffer, static_cast<size_t>(length)));
    }

    [[nodiscard]] WriteStatus endWithoutBody(std::optional<size_t> reportedContentLength = std::nullopt, bool closeConnection = false) {
        return internalEnd({}, std::nullopt, reportedContentLength, closeConnection);
    }

    [[nodiscard]] WriteStatus prepareForSendfile() {
        static_assert(!SSL);
        return flushHeaders(true);
    }

    [[nodiscard]] WriteStatus endSendFile(uint64_t offset, bool closeConnection) {
        static_assert(!SSL);
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        auto *data = getHttpResponseData();
        data->offset = offset;
        data->state |= HttpResponseData<SSL>::HTTP_END_CALLED;
        if (closeConnection) data->state |= HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE;
        return finishResponse();
    }

    /* End the response with an optional data chunk. Always starts a timeout. */
    [[nodiscard]] WriteStatus end(std::string_view data = {}, bool closeConnection = false) {
        return internalEnd(data, std::nullopt, static_cast<uint64_t>(data.length()), closeConnection);
    }

    [[nodiscard]] WriteStatus tryEnd(std::string_view data, uint64_t totalSize = 0, bool closeConnection = false) {
        if (!totalSize) totalSize = static_cast<uint64_t>(data.length());
        return internalEnd(data, totalSize, totalSize, closeConnection);
    }

    [[nodiscard]] WriteStatus sendTerminatingChunk(bool closeConnection = false) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        if (!(getHttpResponseData()->state & HttpResponseData<SSL>::HTTP_RESPONSE_PENDING)) return WriteStatus::Complete;
        const auto prepared = prepareBodyFraming(std::nullopt, closeConnection);
        if (prepared.status == WriteStatus::OutOfMemory || prepared.status == WriteStatus::Closed) return prepared.status;
        return internalEnd({}, std::nullopt, std::nullopt, closeConnection);
    }

    struct WritePreparation {
        bool chunked;
        WriteStatus status;
    };

private:
    WritePreparation prepareBodyFraming(std::optional<uint32_t> chunkLength, bool closeConnection = false) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return {false, WriteStatus::Closed};
        auto *data = getHttpResponseData();
        const bool first = !(data->state & HttpResponseData<SSL>::HTTP_WRITE_CALLED);
        const bool chunked = !(data->state & HttpResponseData<SSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER) && !data->fromAncientRequest;
        const bool needsStatus = !(data->state & HttpResponseData<SSL>::HTTP_STATUS_CALLED);
        const bool needsDate = first && !(data->state & HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER);
        const bool needsEncoding = first && chunked && !(data->state & HttpResponseData<SSL>::HTTP_WROTE_TRANSFER_ENCODING_HEADER);
        const bool needsClose = first && closeConnection && !(data->state & HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE);
        char chunkSize[10];
        std::string_view chunkPrefix;
        if (chunked && chunkLength) chunkPrefix = std::string_view(chunkSize, static_cast<size_t>(utils::u32toaHex(*chunkLength, chunkSize)));
        const auto status = Super::writeParts({
            needsStatus ? "HTTP/1.1 200 OK\r\n" : "",
            needsClose ? "Connection: close\r\n" : "",
            needsDate ? "Date: " : "",
            needsDate ? std::string_view(Super::getLoopData()->date, 29) : std::string_view(),
            needsDate ? "\r\n" : "",
            needsEncoding ? "Transfer-Encoding: chunked\r\n" : "",
            first ? "\r\n" : "",
            chunkPrefix,
            chunkPrefix.empty() ? "" : "\r\n",
        });
        if (status == WriteStatus::OutOfMemory || status == WriteStatus::Closed) return {false, status};
        if (needsStatus) {
            data->state |= HttpResponseData<SSL>::HTTP_STATUS_CALLED;
            data->webSocketStatusWritten = false;
        }
        if (needsDate) data->state |= HttpResponseData<SSL>::HTTP_WROTE_DATE_HEADER;
        if (needsEncoding) data->state |= HttpResponseData<SSL>::HTTP_WROTE_TRANSFER_ENCODING_HEADER;
        if (closeConnection) data->state |= HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE;
        if (first) data->state |= HttpResponseData<SSL>::HTTP_WRITE_CALLED;
        return {chunked, status};
    }

public:
    [[nodiscard]] WriteStatus flushHeaders(bool flushImmediately = false) {
        const auto prepared = prepareBodyFraming(std::nullopt);
        if (prepared.status == WriteStatus::OutOfMemory || prepared.status == WriteStatus::Closed) return prepared.status;
        return flushImmediately ? Super::uncork().status : prepared.status;
    }

    [[nodiscard]] WritePreparation prepareWrite(uint32_t length) {
        return prepareBodyFraming(length);
    }

    struct BodyWriteResult {
        size_t written;
        WriteStatus status;
    };

    [[nodiscard]] BodyWriteResult writeBody(std::string_view data, bool optional) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return {0, WriteStatus::Closed};
        size_t total_written = 0;
        WriteStatus status = WriteStatus::Complete;

        while (!data.empty()) {
            const int write_length = static_cast<int>(std::min<size_t>(data.length(), INT_MAX));
            const auto result = Super::write(data.data(), write_length, optional);
            total_written += static_cast<size_t>(result.written);
            if (result.status != WriteStatus::Closed && result.written) {
                auto *response = getHttpResponseData();
                RELEASE_ASSERT(static_cast<uint64_t>(result.written) <= UINT64_MAX - response->offset);
                response->offset += static_cast<uint64_t>(result.written);
            }
            switch (result.status) {
            case WriteStatus::OutOfMemory:
            case WriteStatus::Closed:
                return {total_written, result.status};
            case WriteStatus::Backpressure:
                if (optional) return {total_written, WriteStatus::Backpressure};
                status = WriteStatus::Backpressure;
                break;
            case WriteStatus::Complete:
                break;
            }
            RELEASE_ASSERT(result.written > 0);
            data.remove_prefix(static_cast<size_t>(result.written));
        }

        return {total_written, status};
    }

    [[nodiscard]] WriteStatus finishWrite(bool chunked) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        WriteStatus status = WriteStatus::Complete;
        if (chunked) {
            status = Super::write("\r\n", 2).status;
            if (status == WriteStatus::OutOfMemory || status == WriteStatus::Closed) return status;
        }

        this->resetTimeout();

        return status;
    }

    [[nodiscard]] WriteStatus write(std::string_view data, size_t *writtenPtr = nullptr) {
        if (writtenPtr) *writtenPtr = 0;
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        WriteStatus status = WriteStatus::Complete;
        size_t written = 0;
        while (!data.empty()) {
            const auto length = static_cast<uint32_t>(std::min<size_t>(data.length(), UINT32_MAX));
            const auto prepared = prepareWrite(length);
            if (prepared.status == WriteStatus::OutOfMemory || prepared.status == WriteStatus::Closed) return prepared.status;
            const auto body = writeBody(data.substr(0, length), false);
            written += body.written;
            if (writtenPtr) *writtenPtr = written;
            if (body.status == WriteStatus::OutOfMemory || body.status == WriteStatus::Closed) return body.status;
            const auto finished = finishWrite(prepared.chunked);
            if (finished == WriteStatus::OutOfMemory || finished == WriteStatus::Closed) return finished;
            if (prepared.status == WriteStatus::Backpressure || body.status == WriteStatus::Backpressure || finished == WriteStatus::Backpressure) status = WriteStatus::Backpressure;
            data.remove_prefix(length);
        }
        return status;
    }

    /* Get the current byte write offset for this Http response */
    uint64_t getWriteOffset() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        return httpResponseData->offset;
    }

    /* If you are messing around with sendfile you might want to override the offset. */
    void overrideWriteOffset(uint64_t offset) {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->offset = offset;
    }

    /* Checking if we have fully responded and are ready for another request */
    bool hasResponded() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        return !(httpResponseData->state & HttpResponseData<SSL>::HTTP_RESPONSE_PENDING);
    }

     /* Corks the response if possible. Leaves already corked socket be. */
    [[nodiscard]] WriteStatus cork(MoveOnlyFunction<void()> &&handler) {
        auto *socket = reinterpret_cast<us_socket_t *>(this);
        if (us_socket_is_closed(socket)) {
            handler();
            return WriteStatus::Closed;
        }
        auto *group = us_socket_group(socket);
        auto *loopData = Super::getLoopData();
        const bool alreadyCorked = Super::isCorked();
        if (!alreadyCorked) Super::cork();
        handler();
        if (us_socket_is_closed(socket) || us_socket_group(socket) != group) return WriteStatus::Closed;
        if (alreadyCorked || loopData->findCorkSlot(this) == LoopData::INVALID_CORK_SLOT) return WriteStatus::Complete;

        const auto result = Super::uncork();
        if (result.status == WriteStatus::OutOfMemory || result.status == WriteStatus::Closed) return result.status;
        const bool pendingOutput = Super::hasPendingOutput();
        if (result.written || pendingOutput) resetTimeout();
        const auto state = getHttpResponseData()->state;
        if ((state & HttpResponseData<SSL>::HTTP_CONNECTION_CLOSE)
            && !(state & HttpResponseData<SSL>::HTTP_RESPONSE_PENDING) && !pendingOutput) {
            Super::shutdown();
            Super::close();
        }
        return result.status;
    }

    /* Attach handler for writable HTTP response */
    HttpResponse *onWritable(void* userData, HttpResponseData<SSL>::OnWritableCallback handler) {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onWritable.set(userData, handler);
        return this;
    }

    /* Remove handler for writable HTTP response */
    HttpResponse *clearOnWritable() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onWritable.clear();
        return this;
    }

    /* Attach handler for aborted HTTP request */
    HttpResponse *onAborted(void* userData,  HttpResponseData<SSL>::OnAbortedCallback handler) {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onAborted.set(userData, handler);
        return this;
    }

    HttpResponse *onTimeout(void* userData,  HttpResponseData<SSL>::OnTimeoutCallback handler) {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onTimeout.set(userData, handler);
        return this;
    }

    HttpResponse* clearOnWritableAndAborted() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onWritable.clear();
        httpResponseData->onAborted.clear();
        httpResponseData->onTimeout.clear();

        return this;
    }

    HttpResponse* clearOnAborted() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onAborted.clear();
        return this;
    }

    HttpResponse* clearOnTimeout() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->onTimeout.clear();
        return this;
    }
    /* Attach a read handler for data sent. Will be called with FIN set true if last segment. */
    void onData(void* userData, HttpResponseData<SSL>::OnDataCallback handler) {
        HttpResponseData<SSL> *data = getHttpResponseData();
        data->inStream.set(userData, handler);

        /* Always reset this counter here */
        data->received_bytes_per_timeout = 0;
    }

    void* getSocketData() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        return httpResponseData->socketData;
    }
    bool isConnectRequest() {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();
        return httpResponseData->isConnectRequest;
    }

    void setWriteOffset(uint64_t offset) {
        HttpResponseData<SSL> *httpResponseData = getHttpResponseData();

        httpResponseData->offset = offset;
    }

};

}

#endif // UWS_HTTPRESPONSE_H
