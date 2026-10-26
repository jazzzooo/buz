#ifndef UWS_H3CONTEXT_H
#define UWS_H3CONTEXT_H

#include "quic.h"
#include "Loop.h"
#include "Http3ContextData.h"
#include "Http3Request.h"
#include "Http3Response.h"
#include "Http3ResponseData.h"

namespace uWS {

struct Http3Context {

    static Http3Context *create(Loop *loop, us_bun_socket_context_options_t options, unsigned idleTimeoutSecs = 0) {
        us_quic_socket_context_t *ctx = us_create_quic_socket_context(
            (us_loop_t *) loop, options, sizeof(Http3ContextData), idleTimeoutSecs);
        if (!ctx) return nullptr;
        new (us_quic_socket_context_ext(ctx)) Http3ContextData();

        us_quic_socket_context_on_stream_open(ctx, [](us_quic_stream_t *s, int) {
            new (us_quic_stream_ext(s)) Http3ResponseData();
        });

        us_quic_socket_context_on_stream_headers(ctx, [](us_quic_stream_t *s) {
            Http3ContextData *cd = (Http3ContextData *) us_quic_socket_context_ext(us_quic_stream_context(s));
            Http3Response *res = (Http3Response *) s;
            Http3ResponseData *rd = res->getHttpResponseData();
            rd->reset();

            Http3Request req(s);
            if (req.getHeader("expect") == "100-continue" && res->writeContinue() != Http3Response::WriteStatus::Complete) {
                res->close();
                return;
            }
            if (const auto handler = cd->requestHandler) {
                handler(res, &req);
                return;
            }
            if (res->writeStatus("404 Not Found") != Http3Response::WriteStatus::Complete
                || res->end() != Http3Response::WriteStatus::Complete) res->close();
        });

        us_quic_socket_context_on_stream_data(ctx, [](us_quic_stream_t *s, const char *data, unsigned len, int fin) {
            Http3Response *res = (Http3Response *) s;
            Http3ResponseData *rd = res->getHttpResponseData();
            if (rd->inStream) {
                const auto callback = fin ? rd->inStream.take() : rd->inStream;
                callback(res, data, len, fin != 0);
            }
        });

        us_quic_socket_context_on_stream_writable(ctx, [](us_quic_stream_t *s) {
            Http3Response *res = (Http3Response *) s;
            switch (res->drain()) {
            case Http3Response::WriteStatus::Complete: break;
            case Http3Response::WriteStatus::Backpressure: us_quic_stream_want_write(s, 1); break;
            case Http3Response::WriteStatus::OutOfMemory:
            case Http3Response::WriteStatus::Failed: res->close(); break;
            }
        });

        us_quic_socket_context_on_stream_close(ctx, [](us_quic_stream_t *s) {
            Http3Response *res = (Http3Response *) s;
            Http3ResponseData *rd = res->getHttpResponseData();
            /* Fire onAborted for both real aborts and post-completion stream
             * teardown. The handler distinguishes via hasResponded(); for the
             * completed case it just drops its pointer so it doesn't outlive
             * this destructor. */
            if (rd->onAborted) {
                const auto callback = rd->onAborted.take();
                callback(res);
            }
            rd->~Http3ResponseData();
        });

        return (Http3Context *) ctx;
    }

    void free() {
        getContextData()->~Http3ContextData();
        us_quic_socket_context_free((us_quic_socket_context_t *) this);
    }

    Http3ContextData *getContextData() {
        return (Http3ContextData *) us_quic_socket_context_ext((us_quic_socket_context_t *) this);
    }


    us_quic_listen_socket_t *listen(const char *host, int port, int flags) {
        return us_quic_socket_context_listen((us_quic_socket_context_t *) this,
            host, port, flags, sizeof(Http3ResponseData));
    }

    void shutdown() { us_quic_socket_context_shutdown((us_quic_socket_context_t *) this); }

    bool addServerName(const char *hostname, us_bun_socket_context_options_t options) {
        return us_quic_socket_context_add_server_name((us_quic_socket_context_t *) this, hostname, options) == 0;
    }
};

}

#endif
