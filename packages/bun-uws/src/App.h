#pragma once
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

#include <string>
#include <new>
#include <memory>
#include <cstdlib>
#include <cstring>
#include <charconv>
#include <string_view>

namespace uWS {
    /* Safari 15.0 - 15.3 has a completely broken compression implementation (client_no_context_takeover not
     * properly implemented) - so we fully disable compression for this browser :-(
     * see https://github.com/uNetworking/uWebSockets/issues/1347 */
    inline bool hasBrokenCompression(std::string_view userAgent) {
        size_t posStart = userAgent.find(" Version/15.");
        if (posStart == std::string_view::npos) return false;
        posStart += 12;

        size_t posEnd = userAgent.find(' ', posStart);
        if (posEnd == std::string_view::npos) return false;

        unsigned int minorVersion = 0;
        auto result = std::from_chars(userAgent.data() + posStart, userAgent.data() + posEnd, minorVersion);
        if (result.ec != std::errc()) return false;
        if (result.ptr != userAgent.data() + posEnd) return false; // do not accept trailing chars
        if (minorVersion > 3) return false; // we target just Safari 15.0 - 15.3

        if (userAgent.find(" Safari/", posEnd) == std::string_view::npos) return false;

        return true;
    }
}

/* An app is a convenience wrapper of some of the most used fuctionalities and allows a
 * builder-pattern kind of init. Apps operate on the implicit thread local Loop */

#include "HttpContext.h"
#include "HttpResponse.h"
#include "WebSocketContext.h"
#include "WebSocket.h"
#include "PerMessageDeflate.h"

namespace uWS {

    /* This one matches us_socket_context_options_t but has default values */
    struct SocketContextOptions {
        const char *key_file_name = nullptr;
        const char *cert_file_name = nullptr;
        const char *passphrase = nullptr;
        const char *dh_params_file_name = nullptr;
        const char *ca_file_name = nullptr;
        const char *ssl_ciphers = nullptr;
        int ssl_prefer_low_memory_usage = 0;

        const char **key = nullptr;
        unsigned int key_count = 0;
        const char **cert = nullptr;
        unsigned int cert_count = 0;
        const char **ca = nullptr;
        unsigned int ca_count = 0;
        unsigned int secure_options = 0;
        int reject_unauthorized = 0;
        int request_cert = 0;
        unsigned int client_renegotiation_limit = 3;
        unsigned int client_renegotiation_window = 600;

        /* Conversion operator used internally */
        operator struct us_bun_socket_context_options_t() const {
            struct us_bun_socket_context_options_t socket_context_options;
            memcpy(&socket_context_options, this, sizeof(SocketContextOptions));
            return socket_context_options;
        }
    };

    static_assert(sizeof(struct us_bun_socket_context_options_t) == sizeof(SocketContextOptions), "Mismatching uSockets/uWebSockets ABI");

template <bool SSL>
struct TemplatedApp {
private:
    /* The app always owns at least one http context, but creates websocket contexts on demand */
    HttpContext<SSL> *httpContext;
    /* One retained SSL_CTX reference; listeners and accepted sockets retain
     * their own references. Plain HTTP holds nullptr. */
    struct ssl_ctx_st *sslCtx = nullptr;
    /* SNI: the tree hangs off the listen socket, but addServerName() is allowed
     * before listen(). Queue them and replay onto each us_listen_socket_t. */
    struct PendingServerName {
        char *hostname = nullptr;
        struct ssl_ctx_st *ctx = nullptr;
        PendingServerName *next = nullptr;

        ~PendingServerName() {
            std::free(hostname);
            us_internal_ssl_ctx_unref(ctx);
        }
    };
    PendingServerName *pendingServerNames = nullptr;
    /* No raw us_listen_socket_t* cache here. server.zig's non-abrupt stop calls
     * us_listen_socket_close(ls) directly; the listener is queued for free in
     * loop_post, so any vector we kept would dangle by the time the deferred
     * App::close() task runs. The group's intrusive head_listen_sockets list is
     * the only source of truth and is kept in sync by us_listen_socket_close(). */
    template <typename Fn>
    void forEachListenSocket(Fn &&fn) {
        for (auto *ls = us_socket_group_head_listen_socket(httpContext->getSocketGroup()); ls;
             ls = us_listen_socket_next(ls)) {
            fn(ls);
        }
    }
    /* WebSocketContexts are of differing type, but we as owners and creators must delete them correctly */
    WebSocketContextLifetime *webSocketContexts = nullptr;
    LoopData::Hook topicDrainHook;
    bool topicNeedsUncork = false;

public:

    TopicTree<TopicTreeMessage, TopicTreeBigMessage> *topicTree = nullptr;

    /* Server name */
    int addServerName(const char *hostname_pattern, struct ssl_ctx_st *domainCtx) {
        if constexpr (SSL) {
            auto **tail = &pendingServerNames;
            while (*tail) {
                if (std::strcmp((*tail)->hostname, hostname_pattern) == 0) return US_SERVER_NAME_DUPLICATE;
                tail = &(*tail)->next;
            }
            std::unique_ptr<PendingServerName> pending(new (std::nothrow) PendingServerName);
            if (!pending) return US_SERVER_NAME_OUT_OF_MEMORY;
            const size_t hostnameSize = std::strlen(hostname_pattern) + 1;
            pending->hostname = static_cast<char *>(std::malloc(hostnameSize));
            if (!pending->hostname) return US_SERVER_NAME_OUT_OF_MEMORY;
            std::memcpy(pending->hostname, hostname_pattern, hostnameSize);
            auto *first = us_socket_group_head_listen_socket(httpContext->getSocketGroup());
            auto *failed = first;
            int result = US_SERVER_NAME_OK;
            for (; failed; failed = us_listen_socket_next(failed)) {
                result = us_listen_socket_add_server_name(failed, pending->hostname, domainCtx, nullptr);
                if (result != US_SERVER_NAME_OK) break;
            }
            if (failed) {
                // Only the successful prefix belongs to this registration.
                for (auto *ls = first; ls != failed; ls = us_listen_socket_next(ls)) {
                    us_listen_socket_remove_server_name(ls, pending->hostname);
                }
                return result;
            }
            /* Queue for any listeners not yet created. We hold one SSL_CTX ref;
             * each listen socket took its own via SSL_CTX_up_ref. */
            us_internal_ssl_ctx_up_ref(domainCtx);
            pending->ctx = domainCtx;
            *tail = pending.release();
            return US_SERVER_NAME_OK;
        }
        return US_SERVER_NAME_INVALID;
    }

    TemplatedApp &&removeServerName(const char *hostname_pattern) {
        if constexpr (SSL) {
            forEachListenSocket([&](us_listen_socket_t *ls) {
                us_listen_socket_remove_server_name(ls, hostname_pattern);
            });
            auto **link = &pendingServerNames;
            while (auto *pending = *link) {
                if (std::strcmp(pending->hostname, hostname_pattern) == 0) {
                    *link = pending->next;
                    delete pending;
                    break;
                }
                link = &pending->next;
            }
        }
        return std::move(*this);
    }

    TemplatedApp &&missingServerName(MoveOnlyFunction<void(const char *hostname)> &&handler) {
        if (!constructorFailed()) {
            httpContext->getSocketContextData()->missingServerNameHandler = std::move(handler);
            forEachListenSocket([&](us_listen_socket_t *ls) {
                us_listen_socket_on_server_name(ls, &onMissingServerName);
            });
        }
        return std::move(*this);
    }

    /* Returns the SSL_CTX* of this app, or nullptr. */
    void *getNativeHandle() {
        return sslCtx;
    }

    /* Attaches a "filter" function to track socket connections/disconnections */
    TemplatedApp &&filter(MoveOnlyFunction<void(HttpResponse<SSL> *, int)> &&filterHandler) {
        httpContext->filter(std::move(filterHandler));

        return std::move(*this);
    }

    /* Publishes a message to all websocket contexts - conceptually as if publishing to the one single
     * TopicTree of this app (technically there are many TopicTrees, however the concept is that one
     * app has one conceptual Topic tree) */
    bool publish(std::string_view topic, std::string_view message, unsigned char opCode, bool compress = false) {
        return this->publish(topic, message, (OpCode)opCode, compress);
    }

    /* Publishes a message to all websocket contexts - conceptually as if publishing to the one single
     * TopicTree of this app (technically there are many TopicTrees, however the concept is that one
     * app has one conceptual Topic tree) */
    bool publish(std::string_view topic, std::string_view message, OpCode opCode, bool compress = false) {
        /* Anything big bypasses corking efforts */
        if (message.length() >= LoopData::CORK_BUFFER_SIZE) {
            return topicTree->publishBig(nullptr, topic, {message, opCode, compress}, [](Subscriber *s, TopicTreeBigMessage &message) {
                auto *ws = (WebSocket<SSL, true, int> *) s->user;

                /* Send will drain if needed */
                ws->send(message.message, (OpCode)message.opCode, message.compress);
            });
        } else {
            return topicTree->publish(nullptr, topic, {std::string(message), opCode, compress});
        }
    }

    /* Returns number of subscribers for this topic, or 0 for failure.
     * This function should probably be optimized a lot in future releases,
     * it could be O(1) with a hash map of fullnames and their counts. */
    unsigned int numSubscribers(std::string_view topic) {
        if (!topicTree) {
            return 0;
        }

        Topic *t = topicTree->lookupTopic(topic);
        if (t) {
            return (unsigned int) t->size();
        }

        return 0;
    }

    ~TemplatedApp() {
        /* Let's just put everything here */
        if (httpContext) {
            httpContext->free();

            assert(!webSocketContexts);
        }

        if constexpr (SSL) {
            while (auto *pending = pendingServerNames) {
                pendingServerNames = pending->next;
                delete pending;
            }
            us_internal_ssl_ctx_unref(sslCtx);
        }

        /* Delete TopicTree */
        if (topicTree) {
            /* And unregister loop callbacks */
            /* We must unregister any loop post handler here */
            Loop::get()->removeHook(topicDrainHook);
            delete topicTree;
        }
    }

    /* Disallow copying, only move */
    TemplatedApp(const TemplatedApp &other) = delete;

    /* Heap-only — group.ext / SNI callback userdata point at `this`, so a move
     * would dangle. Bun always uses TemplatedApp::create() anyway. */
    TemplatedApp(TemplatedApp &&other) = delete;

private:
    static void onMissingServerName(struct us_listen_socket_t *ls, const char *hostname) {
        auto *httpContext = (HttpContext<SSL> *) us_socket_group_ext(us_listen_socket_group(ls));
        httpContext->getSocketContextData()->missingServerNameHandler(hostname);
    }

    TemplatedApp(struct ssl_ctx_st *context, bool requestCert, bool rejectUnauthorized) {
        if constexpr (SSL) {
            sslCtx = context;
            us_internal_ssl_ctx_up_ref(sslCtx);
        }
        httpContext = HttpContext<SSL>::create(Loop::get(), requestCert, rejectUnauthorized);
    }
public:

    static TemplatedApp<SSL>* create(struct ssl_ctx_st *context, bool requestCert, bool rejectUnauthorized) {
        auto *app = new (std::nothrow) TemplatedApp<SSL>(context, requestCert, rejectUnauthorized);
        if (!app) return nullptr;
        if (app->constructorFailed()) {
            delete app;
            return nullptr;
        }
        return app;
    }

    bool constructorFailed() {
        return !httpContext;
    }

    template <typename UserData>
    struct WebSocketBehavior {
        /* Disabled compression by default - probably a bad default */
        CompressOptions compression = DISABLED;
        /* Maximum message size we can receive */
        unsigned int maxPayloadLength = 16 * 1024;
        /* 2 minutes timeout is good */
        unsigned short idleTimeout = 120;
        /* 64kb backpressure is probably good */
        unsigned int maxBackpressure = 64 * 1024;
        bool closeOnBackpressureLimit = false;
        /* This one depends on kernel timeouts and is a bad default */
        bool resetIdleTimeoutOnSend = false;
        /* A good default, esp. for newcomers */
        bool sendPingsAutomatically = true;
        /* Maximum socket lifetime in minutes before forced closure (defaults to disabled) */
        unsigned short maxLifetime = 0;
        MoveOnlyFunction<void(HttpResponse<SSL> *, HttpRequest *, WebSocketContext<SSL, true, UserData> *)> upgrade = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *)> open = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *, std::string_view, OpCode)> message = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *)> drain = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *, std::string_view)> ping = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *, std::string_view)> pong = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *, std::string_view, int, int)> subscription = nullptr;
        MoveOnlyFunction<void(WebSocket<SSL, true, UserData> *, int, std::string_view)> close = nullptr;
    };

    /* Closes all sockets including listen sockets. */
    TemplatedApp &&close() {
        /* close_all() walks head_listen_sockets first, so listeners are closed
         * here without us holding raw pointers to them across loop ticks. */
        us_socket_group_close_all(httpContext->getSocketGroup());
        auto *context = webSocketContexts;
        if (context) context->ref();
        while (context) {
            auto *next = context->next;
            if (next) next->ref();
            us_socket_group_close_all(context->group);
            context->deref();
            context = next;
        }

        return std::move(*this);
    }

    /** Closes all connections connected to this server which are not sending a request or waiting for a response. Does not close the listen socket. */
    TemplatedApp &&closeIdle() {
        auto *group = httpContext->getSocketGroup();
        struct us_socket_t *s = group->head_sockets;
        while (s) {
            // no matter the type of socket will always contain the AsyncSocketData
            auto *data = ((AsyncSocket<SSL> *) s)->getAsyncSocketData();
            struct us_socket_t *next = s->next;
            if (data->isIdle) {
                us_socket_close(s, LIBUS_SOCKET_CLOSE_CODE_CLEAN_SHUTDOWN, 0);
            }
            s = next;
        }
        return std::move(*this);
    }

    template <typename UserData>
    WebSocketContext<SSL, true, UserData> *prepareWebSocketContext(WebSocketBehavior<UserData> &&behavior) {
        static_assert(std::is_trivially_destructible_v<UserData>);
        static_assert(alignof(UserData) <= LIBUS_EXT_ALIGNMENT);
        assert(!behavior.idleTimeout || behavior.idleTimeout >= 8);
        assert(behavior.idleTimeout <= 960 && behavior.maxLifetime <= 240);
        if (!httpContext) return nullptr;
        if (!topicTree) {
            auto *tree = new (std::nothrow) TopicTree<TopicTreeMessage, TopicTreeBigMessage>(this,
                [](Subscriber *s, TopicTreeMessage &message, TopicTree<TopicTreeMessage, TopicTreeBigMessage>::IteratorFlags flags, void *context) {
                auto &needsUncork = static_cast<TemplatedApp *>(context)->topicNeedsUncork;
                /* Subscriber's user is the socket */
                /* Unfortunately we need to cast is to PerSocketData = int
                 * since many different WebSocketContexts use the same
                 * TopicTree now */
                auto *ws = (WebSocket<SSL, true, int> *) s->user;

                /* If this is the first message we try and cork */
                if (flags & TopicTree<TopicTreeMessage, TopicTreeBigMessage>::IteratorFlags::FIRST) {
                    needsUncork = false;
                    if (!ws->isCorked()) {
                        ((AsyncSocket<SSL> *)ws)->cork();
                        needsUncork = ws->isCorked();
                    }
                }

                /* If we ever overstep maxBackpresure, exit immediately */
                if (WebSocket<SSL, true, int>::SendStatus::DROPPED == ws->send(message.message, (OpCode)message.opCode, message.compress)) {
                    if (needsUncork) {
                        const auto status = ((AsyncSocket<SSL> *)ws)->uncork().status;
                        needsUncork = false;
                        if (status == WriteStatus::OutOfMemory)
                            ((AsyncSocket<SSL> *)ws)->closeOnOutOfMemory();
                    }
                    /* Stop draining */
                    return true;
                }

                /* If this is the last message we uncork if we are corked */
                if (flags & TopicTree<TopicTreeMessage, TopicTreeBigMessage>::IteratorFlags::LAST) {
                    /* We should not uncork in all cases? */
                    if (needsUncork) {
                        const auto status = ((AsyncSocket<SSL> *)ws)->uncork().status;
                        needsUncork = false;
                        if (status == WriteStatus::OutOfMemory) {
                            ((AsyncSocket<SSL> *)ws)->closeOnOutOfMemory();
                            return true;
                        }
                        if (status == WriteStatus::Closed) return true;
                    }
                }

                /* Success */
                return false;
            });
            if (!tree) return nullptr;
            topicTree = tree;
            topicDrainHook.context = tree;
            topicDrainHook.run = [](void *value) { static_cast<TopicTree<TopicTreeMessage, TopicTreeBigMessage> *>(value)->drain(); };
            Loop::get()->addHook(topicDrainHook);
        }
        auto *webSocketContext = WebSocketContext<SSL, true, UserData>::create(Loop::get(), topicTree);
        if (!webSocketContext) return nullptr;
        webSocketContext->attach(webSocketContexts);
#ifdef UWS_NO_ZLIB
        behavior.compression = DISABLED;
#endif
        /* Copy all handlers */
        webSocketContext->getExt()->openHandler = std::move(behavior.open);
        webSocketContext->getExt()->messageHandler = std::move(behavior.message);
        webSocketContext->getExt()->drainHandler = std::move(behavior.drain);
        webSocketContext->getExt()->subscriptionHandler = std::move(behavior.subscription);
        webSocketContext->getExt()->closeHandler = std::move(behavior.close);
        webSocketContext->getExt()->pingHandler = std::move(behavior.ping);
        webSocketContext->getExt()->pongHandler = std::move(behavior.pong);

        /* Copy settings */
        webSocketContext->getExt()->maxPayloadLength = behavior.maxPayloadLength;
        webSocketContext->getExt()->maxBackpressure = behavior.maxBackpressure;
        webSocketContext->getExt()->closeOnBackpressureLimit = behavior.closeOnBackpressureLimit;
        webSocketContext->getExt()->resetIdleTimeoutOnSend = behavior.resetIdleTimeoutOnSend;
        webSocketContext->getExt()->sendPingsAutomatically = behavior.sendPingsAutomatically;
        webSocketContext->getExt()->maxLifetime = behavior.maxLifetime;
        webSocketContext->getExt()->compression = behavior.compression;

        /* Calculate idleTimeoutComponents */
        webSocketContext->getExt()->calculateIdleTimeoutComponents(behavior.idleTimeout);

        return webSocketContext;
    }

    void setRequestHandler(void *context, void (*handler)(void *, void *, void *)) {
        httpContext->getSocketContextData()->requestHandler.set(context, handler);
    }

private:
    /* Replay queued SNI entries onto a fresh listener. The listener is already
     * linked into the http group's head_listen_sockets by us_socket_group_listen,
     * which is the only owner — we don't (and must not) cache the raw pointer. */
    us_listen_socket_t *trackListenSocket(us_listen_socket_t *ls, us_listen_error_t *error) {
        if (!ls) return nullptr;
        if constexpr (SSL) {
            for (auto *pending = pendingServerNames; pending; pending = pending->next) {
                const int result = us_listen_socket_add_server_name(ls, pending->hostname, pending->ctx, nullptr);
                if (result != US_SERVER_NAME_OK) {
                    error->server_name_error = static_cast<us_server_name_error_t>(result);
                    us_listen_socket_close(ls);
                    return nullptr;
                }
            }
            if (httpContext->getSocketContextData()->missingServerNameHandler) {
                us_listen_socket_on_server_name(ls, &onMissingServerName);
            }
        }
        return ls;
    }

    struct ssl_ctx_st *sslCtxOrNull() { return SSL ? sslCtx : nullptr; }

public:
    us_listen_socket_t *listen(const char *host, int port, int options, us_listen_error_t *error) {
        *error = {};
        return trackListenSocket(httpContext->listen(sslCtxOrNull(), host && host[0] ? host : nullptr, port, options, error), error);
    }

    us_listen_socket_t *listenUnix(std::string_view path, int options, us_listen_error_t *error) {
        *error = {};
        return trackListenSocket(httpContext->listen_unix(sslCtxOrNull(), path.data(), path.length(), options, error), error);
    }

    void setOnSocketClosed(HttpContextData<SSL>::OnSocketClosedCallback onClose) {
        httpContext->getSocketContextData()->onSocketClosed = onClose;
    }
    void setOnSocketDrain(HttpContextData<SSL>::OnSocketDrainCallback onDrain) {
        httpContext->getSocketContextData()->onSocketDrain = onDrain;
    }
    void setOnSocketData(HttpContextData<SSL>::OnSocketDataCallback onData) {
        httpContext->getSocketContextData()->onSocketData = onData;
    }

    void setOnClientError(HttpContextData<SSL>::OnClientErrorCallback onClientError) {
        httpContext->getSocketContextData()->onClientError = std::move(onClientError);
    }

    void setOnSocketUpgraded(HttpContextData<SSL>::OnSocketUpgradedCallback onUpgraded) {
        httpContext->getSocketContextData()->onSocketUpgraded = onUpgraded;
    }

    TemplatedApp &&run() {
        uWS::run();
        return std::move(*this);
    }

    TemplatedApp &&setUsingCustomExpectHandler(bool value) {
        httpContext->getSocketContextData()->flags.usingCustomExpectHandler = value;
        return std::move(*this);
    }

    TemplatedApp &&setFlags(bool requireHostHeader, bool useStrictMethodValidation) {
        httpContext->getSocketContextData()->flags.requireHostHeader = requireHostHeader;
        httpContext->getSocketContextData()->flags.useStrictMethodValidation = useStrictMethodValidation;
        return std::move(*this);
    }

    TemplatedApp &&setMaxHTTPHeaderSize(uint64_t maxHeaderSize) {
        httpContext->getSocketContextData()->maxHeaderSize = maxHeaderSize;
        return std::move(*this);
    }

};

typedef TemplatedApp<false> App;
typedef TemplatedApp<true> SSLApp;

}
