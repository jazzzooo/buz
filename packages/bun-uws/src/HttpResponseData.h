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
#pragma once

/* This data belongs to the HttpResponse */

#include "HttpParser.h"
#include "AsyncSocketData.h"
#include "ProxyParser.h"
#include "HttpContext.h"

#include "MoveOnlyFunction.h"
#include "HttpCallback.h"
#include "libusockets.h"

namespace uWS {

template <bool SSL>
struct HttpContext;

template <bool SSL>
struct HttpResponseData : AsyncSocketData<SSL>, HttpParser {
    template <bool> friend struct HttpResponse;
    template <bool> friend struct HttpContext;
    public:
    using OnWritableCallback = bool (*)(uWS::HttpResponse<SSL>*, uint64_t, void*);
    using OnAbortedCallback = void (*)(uWS::HttpResponse<SSL>*, void*);
    using OnTimeoutCallback = void (*)(uWS::HttpResponse<SSL>*, void*);
    using OnDataCallback = void (*)(uWS::HttpResponse<SSL>* response, const char* chunk, size_t chunk_length, bool, void*);

    /* When we are done with a response we mark it like so */
    void markDone(uWS::HttpResponse<SSL> *uwsRes) {
        onAborted.clear();
        /* Also remove onWritable so that we do not emit when draining behind the scenes. */
        onWritable.clear();
        /* Ignore data after this point */
        inStream.clear();

        // Ensure we don't call a timeout callback
        onTimeout.clear();

        /* We are done with this request */
        this->state &= ~HttpResponseData<SSL>::HTTP_RESPONSE_PENDING;

        this->isIdle = !uwsRes->hasPendingOutput();
    }

    bool callOnWritable(uWS::HttpResponse<SSL>* response, uint64_t offset) {
        auto *socket = reinterpret_cast<us_socket_t *>(response);
        auto *group = us_socket_group(socket);
        const auto callback = onWritable;
        HttpCallback<OnWritableCallback> placeholder;
        placeholder.set(nullptr, +[](uWS::HttpResponse<SSL>*, uint64_t, void*) {return true;});
        onWritable = placeholder;
        const bool ret = callback(response, offset);
        if (us_socket_is_closed(socket) || us_socket_group(socket) != group) return false;
        if (onWritable == placeholder) onWritable = callback;
        return ret;
    }
    /* Bits of status */
    enum  : uint8_t {
        HTTP_STATUS_CALLED = 1, // used
        HTTP_WRITE_CALLED = 2, // used
        HTTP_END_CALLED = 4, // used
        HTTP_RESPONSE_PENDING = 8, // used
        HTTP_CONNECTION_CLOSE = 16, // used
        HTTP_WROTE_CONTENT_LENGTH_HEADER = 32, // used
        HTTP_WROTE_DATE_HEADER = 64, // used
        HTTP_WROTE_TRANSFER_ENCODING_HEADER = 128, // used
    };

    void* socketData = nullptr;

    /* Per socket event handlers */
    HttpCallback<OnWritableCallback> onWritable;
    HttpCallback<OnAbortedCallback> onAborted;
    HttpCallback<OnDataCallback> inStream;
    HttpCallback<OnTimeoutCallback> onTimeout;
    /* Outgoing offset */
    uint64_t offset = 0;

    /* Let's track number of bytes since last timeout reset in data handler */
    unsigned int received_bytes_per_timeout = 0;

    /* Current state (content-length sent, status sent, write called, etc */
    uint8_t state = 0;
    uint8_t idleTimeout = 10; // default HTTP_TIMEOUT 10 seconds
    bool fromAncientRequest = false;
    bool isConnectRequest = false;
    bool webSocketCompressionEnabled = true;
    bool webSocketStatusWritten = false;

#ifdef UWS_WITH_PROXY
    ProxyParser proxyParser;
#endif
};

}
