#ifndef UWS_H3APP_H
#define UWS_H3APP_H

#include "App.h"
#include "Http3Context.h"

namespace uWS {

struct H3App {
    Http3Context *http3Context;

    static H3App *create(SocketContextOptions options, unsigned idleTimeoutSecs = 0) {
        us_bun_socket_context_options_t raw;
        memcpy(&raw, &options, sizeof(raw));
        Http3Context *ctx = Http3Context::create(Loop::get(), raw, idleTimeoutSecs);
        if (!ctx) return nullptr;
        return new H3App{ctx};
    }

    bool constructorFailed() { return http3Context == nullptr; }

    ~H3App() {
        if (http3Context) http3Context->free();
    }

    H3App &&listen(const std::string &host, int port, int options,
                   MoveOnlyFunction<void(us_quic_listen_socket_t *)> &&cb) {
        cb(http3Context->listen(host.empty() ? nullptr : host.c_str(), port, options));
        return std::move(*this);
    }
    H3App &&listen(const std::string &host, int port,
                   MoveOnlyFunction<void(us_quic_listen_socket_t *)> &&cb) {
        return listen(host, port, 0, std::move(cb));
    }
    H3App &&listen(int port, MoveOnlyFunction<void(us_quic_listen_socket_t *)> &&cb) {
        return listen({}, port, 0, std::move(cb));
    }

    void setRequestHandler(void *context, void (*handler)(void *, void *, void *)) {
        http3Context->getContextData()->requestHandler.set(context, handler);
    }

    /* GOAWAY + drain. The engine itself is torn down in the destructor. */
    void close() { http3Context->shutdown(); }
    bool addServerNameWithOptions(const char *hostname, SocketContextOptions options) {
        us_bun_socket_context_options_t raw;
        memcpy(&raw, &options, sizeof(raw));
        return http3Context->addServerName(hostname, raw);
    }
    void *getNativeHandle() { return http3Context; }
};

}

#endif
