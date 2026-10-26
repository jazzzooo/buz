// clang-format off
#include "root.h"
#include "_libusockets.h"
#include "libusockets.h"
#include <bun-uws/src/App.h>
#include <bun-uws/src/AsyncSocket.h>
#include <bun-usockets/src/internal/internal.h>
#include <string_view>
#include <ares.h>

#define uws_res_r uws_res_t* nonnull_arg
static inline std::string_view stringViewFromC(const char* message, size_t length) {
  if(length) {
    return std::string_view(message, length);
  }

  return std::string_view();

}
using TLSWebSocket = uWS::WebSocket<true, true, void *>;
using TCPWebSocket = uWS::WebSocket<false, true, void *>;

static uws_write_status_t writeStatusToC(uWS::WriteStatus status) {
    switch (status) {
    case uWS::WriteStatus::Complete: return UWS_WRITE_COMPLETE;
    case uWS::WriteStatus::Backpressure: return UWS_WRITE_BACKPRESSURE;
    case uWS::WriteStatus::OutOfMemory: return UWS_WRITE_OUT_OF_MEMORY;
    case uWS::WriteStatus::Closed: return UWS_WRITE_CLOSED;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

struct uws_prepared_websocket_upgrade_s {
    int ssl = 0;
    uws_res_t *response = nullptr;
    uws_socket_context_t *context = nullptr;
    uWS::PreparedWebSocketUpgrade resources;

    ~uws_prepared_websocket_upgrade_s() {
        if (!context) return;
        if (ssl) reinterpret_cast<uWS::WebSocketContext<true, true, void *> *>(context)->deref();
        else reinterpret_cast<uWS::WebSocketContext<false, true, void *> *>(context)->deref();
    }
};

template<bool SSL>
static auto *prepareWebSocketContext(uws_app_t *app, const uws_socket_behavior_t &behavior) {
    using App = uWS::TemplatedApp<SSL>;
    auto callbacks = typename App::template WebSocketBehavior<void *>{
        .compression = static_cast<uWS::CompressOptions>(behavior.compression),
        .maxPayloadLength = behavior.maxPayloadLength,
        .idleTimeout = behavior.idleTimeout,
        .maxBackpressure = behavior.maxBackpressure,
        .closeOnBackpressureLimit = behavior.closeOnBackpressureLimit,
        .resetIdleTimeoutOnSend = behavior.resetIdleTimeoutOnSend,
        .sendPingsAutomatically = behavior.sendPingsAutomatically,
        .maxLifetime = behavior.maxLifetime,
    };
    if (auto callback = behavior.open) callbacks.open = [callback](auto *ws) { callback(reinterpret_cast<uws_websocket_t *>(ws)); };
    if (auto callback = behavior.message) callbacks.message = [callback](auto *ws, auto message, auto opcode) {
        callback(reinterpret_cast<uws_websocket_t *>(ws), message.data(), message.size(), static_cast<uws_opcode_t>(opcode));
    };
    if (auto callback = behavior.drain) callbacks.drain = [callback](auto *ws) { callback(reinterpret_cast<uws_websocket_t *>(ws)); };
    if (auto callback = behavior.ping) callbacks.ping = [callback](auto *ws, auto message) {
        callback(reinterpret_cast<uws_websocket_t *>(ws), message.data(), message.size());
    };
    if (auto callback = behavior.pong) callbacks.pong = [callback](auto *ws, auto message) {
        callback(reinterpret_cast<uws_websocket_t *>(ws), message.data(), message.size());
    };
    if (auto callback = behavior.close) callbacks.close = [callback](auto *ws, int code, auto message) {
        callback(reinterpret_cast<uws_websocket_t *>(ws), code, message.data(), message.size());
    };
    return reinterpret_cast<App *>(app)->template prepareWebSocketContext<void *>(std::move(callbacks));
}

extern "C"
{

  void uws_mark_process_exiting() {
    uWS::Loop::markProcessExiting();
  }

  void uws_loop_date_header_timer_update(us_loop_t *loop) {
    uWS::LoopData *loopData = uWS::Loop::data(loop);
    loopData->updateDate();
  }

  uws_app_t *uws_create_app(int ssl, struct ssl_ctx_st *context, int request_cert, int reject_unauthorized)
  {
    if (ssl)
    {
      return (uws_app_t *)uWS::SSLApp::create(context, request_cert, reject_unauthorized);
    }

    return (uws_app_t *)uWS::App::create(context, request_cert, reject_unauthorized);
  }

  void uws_app_set_request_handler(int ssl, uws_app_t *app, void *context, void (*handler)(void *, void *, void *)) {
    if (ssl) reinterpret_cast<uWS::SSLApp *>(app)->setRequestHandler(context, handler);
    else reinterpret_cast<uWS::App *>(app)->setRequestHandler(context, handler);
  }

size_t uws_req_get_raw_method(uws_req_t *request, const char **output) {
    const auto method = reinterpret_cast<uWS::HttpRequest *>(request)->getCaseSensitiveMethod();
    *output = method.data();
    return method.size();
}

  void uws_req_set_parameter_source(uws_req_t *request, void *context, size_t (*getter)(void *, unsigned, const char **)) {
    reinterpret_cast<uWS::HttpRequest *>(request)->setParameterSource(context, getter);
  }





  extern "C" void uws_res_clear_corked_socket(us_loop_t *loop) {
    uWS::Loop::drainCorkedSockets(loop);
}






  size_t uws_res_get_buffered_amount(int ssl, uws_res_t *res) nonnull_fn_decl;

  size_t uws_res_get_buffered_amount(int ssl, uws_res_t *res)
  {
      if (ssl) {
        uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
        return uwsRes->getBufferedAmount();
      } else {
        uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
        return uwsRes->getBufferedAmount();
      }
  }


  void uws_app_run(int ssl, uws_app_t *app)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->run();
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->run();
    }
  }

  void uws_app_close(int ssl, uws_app_t *app)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->close();
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->close();
    }
  }

  void uws_app_close_idle(int ssl, uws_app_t *app)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->closeIdle();
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->closeIdle();
    }
  }

  void uws_app_set_on_clienterror(int ssl, uws_app_t *app, void (*handler)(void *user_data, int is_ssl, struct us_socket_t *rawSocket, uint8_t errorCode, char *rawPacket, int rawPacketLength), void *user_data)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      if (handler == nullptr) {
        uwsApp->setOnClientError(nullptr);
        return;
      }
      uwsApp->setOnClientError([handler, user_data](int is_ssl, struct us_socket_t *rawSocket, uint8_t errorCode, char *rawPacket, int rawPacketLength) {
        handler(user_data, is_ssl, rawSocket, errorCode, rawPacket, rawPacketLength);
      });
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      if (handler == nullptr) {
        uwsApp->setOnClientError(nullptr);
        return;
      }
      uwsApp->setOnClientError([handler, user_data](int is_ssl, struct us_socket_t *rawSocket, uint8_t errorCode, char *rawPacket, int rawPacketLength) {
        handler(user_data, is_ssl, rawSocket, errorCode, rawPacket, rawPacketLength);
      });
    }
  }

  us_listen_socket_t *uws_app_listen_with_config(int ssl, uws_app_t *app, const char *host,
                                                uint16_t port, int32_t options,
                                                us_listen_error_t *error)
  {
    if (ssl) return ((uWS::SSLApp *)app)->listen(host, port, options, error);
    return ((uWS::App *)app)->listen(host, port, options, error);
  }

  us_listen_socket_t *uws_app_listen_domain_with_options(int ssl, uws_app_t *app,
                                                        const char *domain, size_t pathlen,
                                                        int options, us_listen_error_t *error)
  {
    if (ssl) return ((uWS::SSLApp *)app)->listenUnix({domain, pathlen}, options, error);
    return ((uWS::App *)app)->listenUnix({domain, pathlen}, options, error);
  }

  void uws_app_set_max_http_header_size(int ssl, uws_app_t *app, uint64_t max_header_size) {
    if (ssl) {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->setMaxHTTPHeaderSize(max_header_size);
    } else {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->setMaxHTTPHeaderSize(max_header_size);
    }
  }
  void uws_app_set_flags(int ssl, uws_app_t *app, bool require_host_header, bool use_strict_method_validation) {
    if (ssl) {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->setFlags(require_host_header, use_strict_method_validation);
    } else {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->setFlags(require_host_header, use_strict_method_validation);
    }
  }

  void uws_app_destroy(int ssl, uws_app_t *app)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      delete uwsApp;
    }
    else
    {

      uWS::App *uwsApp = (uWS::App *)app;
      delete uwsApp;
    }
  }

  bool uws_constructor_failed(int ssl, uws_app_t *app)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      if (!uwsApp)
        return true;
      return uwsApp->constructorFailed();
    }
    uWS::App *uwsApp = (uWS::App *)app;
    if (!uwsApp)
      return true;
    return uwsApp->constructorFailed();
  }

  unsigned int uws_num_subscribers(int ssl, uws_app_t *app, const char *topic, size_t topic_length)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      return uwsApp->numSubscribers(stringViewFromC(topic, topic_length));
    }
    uWS::App *uwsApp = (uWS::App *)app;
    return uwsApp->numSubscribers(stringViewFromC(topic, topic_length));
  }
  bool uws_publish(int ssl, uws_app_t *app, const char *topic,
                   size_t topic_length, const char *message,
                   size_t message_length, uws_opcode_t opcode, bool compress)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      return uwsApp->publish(stringViewFromC(topic, topic_length),
                             stringViewFromC(message, message_length),
                             (uWS::OpCode)(unsigned char)opcode, compress);
    }
    uWS::App *uwsApp = (uWS::App *)app;
    return uwsApp->publish(stringViewFromC(topic, topic_length),
                           stringViewFromC(message, message_length),
                           (uWS::OpCode)(unsigned char)opcode, compress);
  }
  void *uws_get_native_handle(int ssl, uws_app_t *app)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      return uwsApp->getNativeHandle();
    }
    uWS::App *uwsApp = (uWS::App *)app;
    return uwsApp->getNativeHandle();
  }
  void uws_remove_server_name(int ssl, uws_app_t *app,
                              const char *hostname_pattern)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->removeServerName(hostname_pattern);
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->removeServerName(hostname_pattern);
    }
  }
  int uws_add_server_name_with_context(
      int ssl, uws_app_t *app, const char *hostname_pattern,
      struct ssl_ctx_st *context)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      return uwsApp->addServerName(hostname_pattern, context);
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      return uwsApp->addServerName(hostname_pattern, context);
    }
  }

  void uws_missing_server_name(int ssl, uws_app_t *app,
                               uws_missing_server_handler handler,
                               void *user_data)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->missingServerName(
          [handler, user_data](auto hostname)
          { handler(hostname, user_data); });
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;
      uwsApp->missingServerName(
          [handler, user_data](auto hostname)
          { handler(hostname, user_data); });
    }
  }
  void uws_filter(int ssl, uws_app_t *app, uws_filter_handler handler,
                  void *user_data)
  {
    if (ssl)
    {
      uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
      uwsApp->filter([handler, user_data](auto res, auto i)
                     { handler((uws_res_t *)res, i, user_data); });
    }
    else
    {
      uWS::App *uwsApp = (uWS::App *)app;

      uwsApp->filter([handler, user_data](auto res, auto i)
                     { handler((uws_res_t *)res, i, user_data); });
    }
  }

  uws_socket_context_t *uws_prepare_websocket_context(int ssl, uws_app_t *app, const uws_socket_behavior_t *behavior) {
    if (ssl) return reinterpret_cast<uws_socket_context_t *>(prepareWebSocketContext<true>(app, *behavior));
    return reinterpret_cast<uws_socket_context_t *>(prepareWebSocketContext<false>(app, *behavior));
  }

  void uws_websocket_context_release(int ssl, uws_socket_context_t *context) {
    if (ssl) reinterpret_cast<uWS::WebSocketContext<true, true, void *> *>(context)->deref();
    else reinterpret_cast<uWS::WebSocketContext<false, true, void *> *>(context)->deref();
  }

  void uws_res_prepare_websocket_dispatch(int ssl, uws_res_t *response, uws_req_t *request) {
    const auto enabled = !uWS::hasBrokenCompression(reinterpret_cast<uWS::HttpRequest *>(request)->getHeader("user-agent"));
    if (ssl) reinterpret_cast<uWS::HttpResponse<true> *>(response)->setWebSocketCompressionEnabled(enabled);
    else reinterpret_cast<uWS::HttpResponse<false> *>(response)->setWebSocketCompressionEnabled(enabled);
  }

  void *uws_ws_get_user_data(int ssl, uws_websocket_t *ws)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return *uws->getUserData();
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return *uws->getUserData();
  }

  void uws_ws_close(int ssl, uws_websocket_t *ws)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      uws->close();
    }
    else
    {
      TCPWebSocket *uws =
          (TCPWebSocket *)ws;
      uws->close();
    }
  }

  uws_sendstatus_t uws_ws_send(int ssl, uws_websocket_t *ws, const char *message,
                               size_t length, uws_opcode_t opcode)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return (uws_sendstatus_t)uws->send(stringViewFromC(message, length),
                                         (uWS::OpCode)(unsigned char)opcode);
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return (uws_sendstatus_t)uws->send(stringViewFromC(message, length),
                                       (uWS::OpCode)(unsigned char)opcode);
  }

  uws_sendstatus_t uws_ws_send_with_options(int ssl, uws_websocket_t *ws,
                                            const char *message, size_t length,
                                            uws_opcode_t opcode, bool compress,
                                            bool fin)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return (uws_sendstatus_t)uws->send(stringViewFromC(message, length),
                                         (uWS::OpCode)(unsigned char)opcode,
                                         compress, fin);
    }
    else
    {

      TCPWebSocket *uws =
          (TCPWebSocket *)ws;
      return (uws_sendstatus_t)uws->send(stringViewFromC(message, length),
                                         (uWS::OpCode)(unsigned char)opcode,
                                         compress, fin);
    }
  }

  uws_sendstatus_t uws_ws_send_fragment(int ssl, uws_websocket_t *ws,
                                        const char *message, size_t length,
                                        bool compress)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return (uws_sendstatus_t)uws->sendFragment(
          stringViewFromC(message, length), compress);
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return (uws_sendstatus_t)uws->sendFragment(stringViewFromC(message, length),
                                               compress);
  }
  uws_sendstatus_t uws_ws_send_first_fragment(int ssl, uws_websocket_t *ws,
                                              const char *message, size_t length,
                                              bool compress)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return (uws_sendstatus_t)uws->sendFirstFragment(
          stringViewFromC(message, length), uWS::OpCode::BINARY, compress);
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return (uws_sendstatus_t)uws->sendFirstFragment(
        stringViewFromC(message, length), uWS::OpCode::BINARY, compress);
  }
  uws_sendstatus_t
  uws_ws_send_first_fragment_with_opcode(int ssl, uws_websocket_t *ws,
                                         const char *message, size_t length,
                                         uws_opcode_t opcode, bool compress)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return (uws_sendstatus_t)uws->sendFirstFragment(
          stringViewFromC(message, length), (uWS::OpCode)(unsigned char)opcode,
          compress);
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return (uws_sendstatus_t)uws->sendFirstFragment(
        stringViewFromC(message, length), (uWS::OpCode)(unsigned char)opcode,
        compress);
  }
  uws_sendstatus_t uws_ws_send_last_fragment(int ssl, uws_websocket_t *ws,
                                             const char *message, size_t length,
                                             bool compress)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return (uws_sendstatus_t)uws->sendLastFragment(
          stringViewFromC(message, length), compress);
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return (uws_sendstatus_t)uws->sendLastFragment(
        stringViewFromC(message, length), compress);
  }

  bool uws_ws_end(int ssl, uws_websocket_t *ws, int code, const char *message,
                  size_t length)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->end(code, stringViewFromC(message, length));
    }
    else
    {
      TCPWebSocket *uws =
          (TCPWebSocket *)ws;
      return uws->end(code, stringViewFromC(message, length));
    }
  }

  bool uws_ws_cork(int ssl, uws_websocket_t *ws, void (*handler)(void *user_data),
                   void *user_data)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->cork([handler, user_data]()
                { handler(user_data); }) != uWS::WriteStatus::OutOfMemory;
    }
    else
    {
      TCPWebSocket *uws =
          (TCPWebSocket *)ws;

      return uws->cork([handler, user_data]()
                { handler(user_data); }) != uWS::WriteStatus::OutOfMemory;
    }
  }
  bool uws_ws_subscribe(int ssl, uws_websocket_t *ws, const char *topic,
                        size_t length)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->subscribe(stringViewFromC(topic, length));
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return uws->subscribe(stringViewFromC(topic, length));
  }
  bool uws_ws_unsubscribe(int ssl, uws_websocket_t *ws, const char *topic,
                          size_t length)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->unsubscribe(stringViewFromC(topic, length));
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return uws->unsubscribe(stringViewFromC(topic, length));
  }

  bool uws_ws_is_subscribed(int ssl, uws_websocket_t *ws, const char *topic,
                            size_t length)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->isSubscribed(stringViewFromC(topic, length));
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return uws->isSubscribed(stringViewFromC(topic, length));
  }
  void uws_ws_iterate_topics(int ssl, uws_websocket_t *ws,
                             void (*callback)(const char *topic, size_t length,
                                              void *user_data),
                             void *user_data)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      uws->iterateTopics([callback, user_data](auto topic)
                         { callback(topic.data(), topic.length(), user_data); });
    }
    else
    {
      TCPWebSocket *uws =
          (TCPWebSocket *)ws;

      uws->iterateTopics([callback, user_data](auto topic)
                         { callback(topic.data(), topic.length(), user_data); });
    }
  }

  bool uws_ws_publish(int ssl, uws_websocket_t *ws, const char *topic,
                      size_t topic_length, const char *message,
                      size_t message_length)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->publish(stringViewFromC(topic, topic_length),
                          stringViewFromC(message, message_length));
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return uws->publish(stringViewFromC(topic, topic_length),
                        stringViewFromC(message, message_length));
  }

  bool uws_ws_publish_with_options(int ssl, uws_websocket_t *ws,
                                   const char *topic, size_t topic_length,
                                   const char *message, size_t message_length,
                                   uws_opcode_t opcode, bool compress)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->publish(stringViewFromC(topic, topic_length),
                          stringViewFromC(message, message_length),
                          (uWS::OpCode)(unsigned char)opcode, compress);
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return uws->publish(stringViewFromC(topic, topic_length),
                        stringViewFromC(message, message_length),
                        (uWS::OpCode)(unsigned char)opcode, compress);
  }

  size_t uws_ws_get_buffered_amount(int ssl, uws_websocket_t *ws)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      return uws->getBufferedAmount();
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;
    return uws->getBufferedAmount();
  }

  size_t uws_ws_get_remote_address(int ssl, uws_websocket_t *ws,
                                   const char **dest)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;
      std::string_view value = uws->getRemoteAddress();
      *dest = value.data();
      return value.length();
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;

    std::string_view value = uws->getRemoteAddress();
    *dest = value.data();
    return value.length();
  }

  size_t uws_ws_get_remote_address_as_text(int ssl, uws_websocket_t *ws,
                                           const char **dest)
  {
    if (ssl)
    {
      TLSWebSocket *uws =
          (TLSWebSocket *)ws;

      std::string_view value = uws->getRemoteAddressAsText();
      *dest = value.data();
      return value.length();
    }
    TCPWebSocket *uws =
        (TCPWebSocket *)ws;

    std::string_view value = uws->getRemoteAddressAsText();
    *dest = value.data();
    return value.length();
  }

  uws_write_status_t uws_res_end(int ssl, uws_res_r res, const char *data, size_t length,
                   bool close_connection)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->end(stringViewFromC(data, length), close_connection));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->end(stringViewFromC(data, length), close_connection));
    }
  }

  uws_write_status_t uws_res_end_stream(int ssl, uws_res_r res, bool close_connection)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->sendTerminatingChunk(close_connection));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->sendTerminatingChunk(close_connection));
    }
  }

  void uws_res_pause(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->pause();
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->pause();
    }
  }

  void uws_res_resume(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->resume();
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->resume();
    }
  }

  uws_write_status_t uws_res_write_continue(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->writeContinue());
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->writeContinue());
    }
  }

  uws_write_status_t uws_res_write_status(int ssl, uws_res_r res, const char *status,
                            size_t length)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->writeStatus(stringViewFromC(status, length)));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->writeStatus(stringViewFromC(status, length)));
    }
  }

  void uws_res_mark_wrote_content_length_header(int ssl, uws_res_r res) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->getHttpResponseData()->state |= uWS::HttpResponseData<true>::HTTP_WROTE_CONTENT_LENGTH_HEADER;
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->getHttpResponseData()->state |= uWS::HttpResponseData<false>::HTTP_WROTE_CONTENT_LENGTH_HEADER;
    }
  }

  uws_write_status_t uws_res_write_mark(int ssl, uws_res_r res) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->writeMark());
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->writeMark());
    }
  }

  uws_write_status_t uws_res_write_header(int ssl, uws_res_r res, const char *key,
                            size_t key_length, const char *value,
                            size_t value_length)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->writeHeader(stringViewFromC(key, key_length),
                          stringViewFromC(value, value_length)));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->writeHeader(stringViewFromC(key, key_length),
                          stringViewFromC(value, value_length)));
    }
  }
  uws_write_status_t uws_res_write_header_int(int ssl, uws_res_r res, const char *key,
                                size_t key_length, uint64_t value)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->writeHeader(stringViewFromC(key, key_length), value));
    }
    else
    {

      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->writeHeader(stringViewFromC(key, key_length), value));
    }
  }
  uws_write_status_t uws_res_end_sendfile(uws_res_r res, uint64_t offset, bool close_connection)
  {
    return writeStatusToC(reinterpret_cast<uWS::HttpResponse<false> *>(res)->endSendFile(offset, close_connection));
  }
  void uws_res_reset_timeout(int ssl, uws_res_r res) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->resetTimeout();
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->resetTimeout();
    }
  }
  void uws_res_timeout(int ssl, uws_res_r res, uint8_t seconds) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->setTimeout(seconds);
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->setTimeout(seconds);
    }
  }

  uws_write_status_t uws_res_end_without_body(int ssl, uws_res_r res, bool close_connection)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->endWithoutBody(std::nullopt, close_connection));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->endWithoutBody(std::nullopt, close_connection));
    }
  }

  uws_write_status_t uws_res_write(int ssl, uws_res_r res, const char *data, size_t *length) nonnull_fn_decl;

  uws_write_status_t uws_res_write(int ssl, uws_res_r res, const char *data, size_t *length)
  {
    if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(res))) {
      *length = 0;
      return UWS_WRITE_CLOSED;
    }
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      if (*length < 16 * 1024 && *length > 0) {
        if (!uwsRes->uWS::AsyncSocket<true>::isCorked()) {
          uwsRes->uWS::AsyncSocket<true>::cork();
        }
      }
      return writeStatusToC(uwsRes->write(stringViewFromC(data, *length), length));
    }
    uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
    if (*length < 16 * 1024 && *length > 0) {
        if (!uwsRes->uWS::AsyncSocket<false>::isCorked()) {
          uwsRes->uWS::AsyncSocket<false>::cork();
        }
    }
    return writeStatusToC(uwsRes->write(stringViewFromC(data, *length), length));
  }

  uws_write_status_t uws_res_prepare_write(int ssl, uws_res_r res, uint32_t length, bool *chunked)
  {
    *chunked = false;
    if (ssl)
    {
      const auto result = ((uWS::HttpResponse<true> *)res)->prepareWrite(length);
      if (result.status == uWS::WriteStatus::Complete || result.status == uWS::WriteStatus::Backpressure) *chunked = result.chunked;
      return writeStatusToC(result.status);
    }
    const auto result = ((uWS::HttpResponse<false> *)res)->prepareWrite(length);
    if (result.status == uWS::WriteStatus::Complete || result.status == uWS::WriteStatus::Backpressure) *chunked = result.chunked;
    return writeStatusToC(result.status);
  }

  uws_write_status_t uws_res_write_body(int ssl, uws_res_r res, const char *data, size_t *length, bool optional) nonnull_fn_decl;

  uws_write_status_t uws_res_write_body(int ssl, uws_res_r res, const char *data, size_t *length, bool optional)
  {
    if (ssl)
    {
      const auto result = ((uWS::HttpResponse<true> *)res)->writeBody(stringViewFromC(data, *length), optional);
      *length = result.written;
      return writeStatusToC(result.status);
    }
    const auto result = ((uWS::HttpResponse<false> *)res)->writeBody(stringViewFromC(data, *length), optional);
    *length = result.written;
    return writeStatusToC(result.status);
  }

  uws_write_status_t uws_res_finish_write(int ssl, uws_res_r res, bool chunked)
  {
    if (ssl)
    {
      return writeStatusToC(((uWS::HttpResponse<true> *)res)->finishWrite(chunked));
    }
    return writeStatusToC(((uWS::HttpResponse<false> *)res)->finishWrite(chunked));
  }

  uint64_t uws_res_get_write_offset(int ssl, uws_res_r res) nonnull_fn_decl;
  uint64_t uws_res_get_write_offset(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->getWriteOffset();
    }
    uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
    return uwsRes->getWriteOffset();
  }

  bool uws_res_has_responded(int ssl, uws_res_r res) nonnull_fn_decl;
  bool uws_res_has_responded(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->hasResponded();
    }
    uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
    return uwsRes->hasResponded();
  }

  void uws_res_on_writable(int ssl, uws_res_r res,
                           bool (*handler)(uws_res_r res, uint64_t,
                                           void *optional_data),
                           void *optional_data)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      auto onWritable = reinterpret_cast<bool (*)(uWS::HttpResponse<true>*, uint64_t, void*)>(handler);
      uwsRes->onWritable(optional_data, onWritable);
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      auto onWritable = reinterpret_cast<bool (*)(uWS::HttpResponse<false>*, uint64_t, void*)>(handler);
      uwsRes->onWritable(optional_data, onWritable);
    }
  }

  void uws_res_clear_on_writable(int ssl, uws_res_r res) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->clearOnWritable();
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->clearOnWritable();
    }
  }

  void uws_res_on_aborted(int ssl, uws_res_r res,
                          void (*handler)(uws_res_r res, void *optional_data),
                          void *optional_data)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      auto* onAborted = reinterpret_cast<void (*)(uWS::HttpResponse<true>*, void*)>(handler);
      if (handler)
      {
        uwsRes->onAborted(optional_data, onAborted);
      }
      else
      {
        uwsRes->clearOnAborted();
      }
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      auto* onAborted = reinterpret_cast<void (*)(uWS::HttpResponse<false>*, void*)>(handler);
      if (handler)
      {
        uwsRes->onAborted(optional_data, onAborted);
      }
      else
      {
        uwsRes->clearOnAborted();
      }
    }
  }

  void uws_res_on_timeout(int ssl, uws_res_r res,
                          void (*handler)(uws_res_r res, void *optional_data),
                          void *optional_data)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      auto* onTimeout = reinterpret_cast<void (*)(uWS::HttpResponse<true>*, void*)>(handler);
      if (handler)
      {
        uwsRes->onTimeout(optional_data, onTimeout);
      }
      else
      {
        uwsRes->clearOnTimeout();
      }
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      auto* onTimeout = reinterpret_cast<void (*)(uWS::HttpResponse<false>*, void*)>(handler);
      if (handler)
      {
        uwsRes->onTimeout(optional_data, onTimeout);
      }
      else
      {
        uwsRes->clearOnTimeout();
      }
    }
  }

  void uws_res_on_data(int ssl, uws_res_r res,
                       void (*handler)(uws_res_r res, const char *chunk,
                                       size_t chunk_length, bool is_end,
                                       void *optional_data),
                       void *optional_data)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      auto onData = reinterpret_cast<void (*)(uWS::HttpResponse<true>* response, const char* chunk, size_t chunk_length, bool, void*)>(handler);
      if (handler) {
        uwsRes->onData(optional_data, onData);
      } else {
        uwsRes->onData(optional_data, nullptr);
      }
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      auto onData = reinterpret_cast<void (*)(uWS::HttpResponse<false>* response, const char* chunk, size_t chunk_length, bool, void*)>(handler);
      if (handler) {
        uwsRes->onData(optional_data, onData);
      } else {
        uwsRes->onData(optional_data, nullptr);
      }
    }
  }

  bool uws_req_is_ancient(uws_req_t *res)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    return uwsReq->isAncient();
  }

  bool uws_req_get_yield(uws_req_t *res)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    return uwsReq->getYield();
  }

  void uws_req_set_yield(uws_req_t *res, bool yield)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    return uwsReq->setYield(yield);
  }

  size_t uws_req_get_url(uws_req_t *res, const char **dest)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    std::string_view value = uwsReq->getFullUrl();
    *dest = value.data();
    return value.length();
  }

  size_t uws_req_get_method(uws_req_t *res, const char **dest)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    std::string_view value = uwsReq->getMethod();
    *dest = value.data();
    return value.length();
  }

size_t uws_req_get_header(uws_req_t *res, const char *lower_case_header,
                            size_t lower_case_header_length, const char **dest) nonnull_fn_decl;

  size_t uws_req_get_header(uws_req_t *res, const char *lower_case_header,
                            size_t lower_case_header_length, const char **dest)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;

    std::string_view value = uwsReq->getHeader(
        stringViewFromC(lower_case_header, lower_case_header_length));
    *dest = value.data();
    return value.length();
  }

  void uws_req_for_each_header(uws_req_t *res, uws_get_headers_server_handler handler, void *user_data)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    for (auto header : *uwsReq)
    {
      handler(header.first.data(), header.first.length(), header.second.data(), header.second.length(), user_data);
    }
  }

  size_t uws_req_get_query(uws_req_t *res, const char *key, size_t key_length,
                           const char **dest)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;

    std::string_view value = uwsReq->getQuery(stringViewFromC(key, key_length));
    *dest = value.data();
    return value.length();
  }

  size_t uws_req_get_parameter(uws_req_t *res, unsigned short index,
                               const char **dest)
  {
    uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
    std::string_view value = uwsReq->getParameter(index);
    *dest = value.data();
    return value.length();
  }

  uws_prepared_websocket_upgrade_t *uws_res_prepare_upgrade(int ssl, uws_res_t *response,
      const char *key, size_t key_length, const char *protocol, size_t protocol_length,
      const char *extensions, size_t extensions_length, uws_socket_context_t *context,
      uws_websocket_upgrade_error_t *error)
  {
    auto prepared = std::unique_ptr<uws_prepared_websocket_upgrade_t>(new (std::nothrow) uws_prepared_websocket_upgrade_t);
    if (!prepared) {
      *error = UWS_WEBSOCKET_UPGRADE_OUT_OF_MEMORY;
      return nullptr;
    }
    uWS::WebSocketUpgradeError preparationError;
    auto resources = ssl
        ? reinterpret_cast<uWS::HttpResponse<true> *>(response)->prepareUpgrade(
            stringViewFromC(key, key_length), stringViewFromC(protocol, protocol_length),
            stringViewFromC(extensions, extensions_length),
            reinterpret_cast<uWS::WebSocketContext<true, true, void *> *>(context), preparationError)
        : reinterpret_cast<uWS::HttpResponse<false> *>(response)->prepareUpgrade(
            stringViewFromC(key, key_length), stringViewFromC(protocol, protocol_length),
            stringViewFromC(extensions, extensions_length),
            reinterpret_cast<uWS::WebSocketContext<false, true, void *> *>(context), preparationError);
    if (!resources) {
      switch (preparationError) {
      case uWS::WebSocketUpgradeError::OutOfMemory:
        *error = UWS_WEBSOCKET_UPGRADE_OUT_OF_MEMORY;
        break;
      case uWS::WebSocketUpgradeError::InvalidExtensions:
        *error = UWS_WEBSOCKET_UPGRADE_INVALID_EXTENSIONS;
        break;
      case uWS::WebSocketUpgradeError::CompressionInitializationFailed:
        *error = UWS_WEBSOCKET_UPGRADE_COMPRESSION_INITIALIZATION_FAILED;
        break;
      case uWS::WebSocketUpgradeError::InvalidKey:
        *error = UWS_WEBSOCKET_UPGRADE_INVALID_KEY;
        break;
      case uWS::WebSocketUpgradeError::InvalidProtocol:
        *error = UWS_WEBSOCKET_UPGRADE_INVALID_PROTOCOL;
        break;
      case uWS::WebSocketUpgradeError::InvalidResponseState:
        *error = UWS_WEBSOCKET_UPGRADE_INVALID_RESPONSE_STATE;
        break;
      case uWS::WebSocketUpgradeError::None:
        RELEASE_ASSERT_NOT_REACHED();
      }
      return nullptr;
    }
    prepared->ssl = ssl;
    prepared->response = response;
    prepared->context = context;
    if (ssl) reinterpret_cast<uWS::WebSocketContext<true, true, void *> *>(context)->ref();
    else reinterpret_cast<uWS::WebSocketContext<false, true, void *> *>(context)->ref();
    prepared->resources = std::move(*resources);
    *error = UWS_WEBSOCKET_UPGRADE_OK;
    return prepared.release();
  }

  void uws_prepared_websocket_upgrade_destroy(uws_prepared_websocket_upgrade_t *prepared)
  {
    delete prepared;
  }

  bool uws_prepared_websocket_upgrade_add_header(uws_prepared_websocket_upgrade_t *prepared,
      const char *name, size_t name_length, const char *value, size_t value_length)
  {
    return prepared->resources.addHeader(stringViewFromC(name, name_length), stringViewFromC(value, value_length));
  }

  bool uws_prepared_websocket_upgrade_finish(uws_prepared_websocket_upgrade_t *prepared)
  {
    if (prepared->ssl) {
      return reinterpret_cast<uWS::HttpResponse<true> *>(prepared->response)->finishUpgrade(prepared->resources);
    }
    return reinterpret_cast<uWS::HttpResponse<false> *>(prepared->response)->finishUpgrade(prepared->resources);
  }

  us_socket_t *uws_res_upgrade(uws_prepared_websocket_upgrade_t *ownedPrepared, void *data)
  {
    std::unique_ptr<uws_prepared_websocket_upgrade_t> prepared(ownedPrepared);
    if (prepared->ssl) {
    auto *uwsRes = reinterpret_cast<uWS::HttpResponse<true> *>(prepared->response);

    return uwsRes->template upgrade<void *>(
        data ? std::move(data) : nullptr,
        std::move(prepared->resources),
        reinterpret_cast<uWS::WebSocketContext<true, true, void *> *>(prepared->context));
    } else {
    auto *uwsRes = reinterpret_cast<uWS::HttpResponse<false> *>(prepared->response);

    return uwsRes->template upgrade<void *>(
        data ? std::move(data) : nullptr,
        std::move(prepared->resources),
        reinterpret_cast<uWS::WebSocketContext<false, true, void *> *>(prepared->context));
    }
  }

  struct us_loop_t *uws_get_loop()
  {
    return (struct us_loop_t *)uWS::Loop::get();
  }
  struct us_loop_t *uws_ensure_loop(void *existing_native_loop, struct us_poll_error_t *failure)
  {
      return (struct us_loop_t *)uWS::Loop::ensure(existing_native_loop, failure);
  }

  void uws_loop_defer(us_loop_t *loop, void *ctx, void (*cb)(void *ctx))
  {
    uWS::Loop *uwsLoop = (uWS::Loop *)loop;
    uwsLoop->defer([ctx, cb]()
                   { cb(ctx); });
  }

  uws_write_status_t uws_res_uncork(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->uncork().status);
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->uncork().status);
    }
  }

  void us_socket_mark_needs_more_not_ssl(uws_res_r res)
  {
    us_socket_r s = (us_socket_t *)res;
    if(us_socket_is_closed(s)) return;
    s->flags.last_write_failed = 1;
    us_poll_change(&s->p, s->group->loop,
                   LIBUS_SOCKET_READABLE | LIBUS_SOCKET_WRITABLE);
  }

  void uws_res_override_write_offset(int ssl, uws_res_r res, uint64_t offset)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      uwsRes->setWriteOffset(offset); //TODO: when updated to master this will bechanged to overrideWriteOffset
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      uwsRes->setWriteOffset(offset); //TODO: when updated to master this will bechanged to overrideWriteOffset
    }
  }

__attribute__((callback (corker, ctx)))
  uws_write_status_t uws_res_cork(int ssl, uws_res_r res, void *ctx,
                    void (*corker)(void *ctx)) nonnull_fn_decl;

  uws_write_status_t uws_res_cork(int ssl, uws_res_r res, void *ctx,
                    void (*corker)(void *ctx))
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->cork([ctx, corker]()
                   { corker(ctx); }));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->cork([ctx, corker]()
                   { corker(ctx); }));
    }
  }

  uws_write_status_t uws_res_prepare_for_sendfile(uws_res_r res)
  {
    return writeStatusToC(reinterpret_cast<uWS::HttpResponse<false> *>(res)->prepareForSendfile());
  }

  uws_write_status_t uws_res_try_end(int ssl, uws_res_r res, const char *bytes, size_t len,
                       size_t total_len, bool close)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->tryEnd(stringViewFromC(bytes, len), total_len, close));
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->tryEnd(stringViewFromC(bytes, len), total_len, close));
    }
  }

  int uws_res_state(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->getHttpResponseData()->state;
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return uwsRes->getHttpResponseData()->state;
    }
  }

  uws_write_status_t uws_res_flush_headers(int ssl, uws_res_r res, bool flushImmediately) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return writeStatusToC(uwsRes->flushHeaders(flushImmediately));
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return writeStatusToC(uwsRes->flushHeaders(flushImmediately));
    }
  }

  bool uws_res_is_corked(int ssl, uws_res_r res) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->isCorked();
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return uwsRes->isCorked();
    }
  }

  void *uws_res_get_socket_data(int ssl, uws_res_r res) {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->getSocketData();
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return uwsRes->getSocketData();
    }
  }

  bool uws_res_is_connect_request(int ssl, uws_res_r res)
  {
    if (ssl) {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->isConnectRequest();
    } else {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return uwsRes->isConnectRequest();
    }
  }
  void *uws_res_get_native_handle(int ssl, uws_res_r res)
  {
    if (ssl)
    {
      uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
      return uwsRes->getNativeHandle();
    }
    else
    {
      uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
      return uwsRes->getNativeHandle();
    }
  }

  size_t uws_ws_memory_cost(int ssl, uws_websocket_t *ws) {
    if (ssl) {
      return ((TLSWebSocket*)ws)->memoryCost();
    } else {
      return ((TCPWebSocket*)ws)->memoryCost();
    }
  }

  void us_socket_sendfile_needs_more(us_socket_r s) {
    if(us_socket_is_closed(s)) return;
    s->flags.last_write_failed = 1;
    us_poll_change(&s->p, s->group->loop, LIBUS_SOCKET_READABLE | LIBUS_SOCKET_WRITABLE);
  }

  LIBUS_SOCKET_DESCRIPTOR us_socket_get_fd(us_socket_r s) {
    return us_poll_fd(&s->p);
  }

  // Gets the remote address and port
  // Returns 0 if failure / unix socket
  uint64_t uws_res_get_remote_address_info(uws_res_r res, const char **dest, int *port, bool *is_ipv6)
  {
    static thread_local char b[64];
    *dest = nullptr;
    auto length = us_get_remote_address_info(b, (us_socket_t *)res, port);

    if (length == 0) return 0;
    if (length == 4) {
      if (!ares_inet_ntop(AF_INET, b, &b[4], 64 - 4)) return 0;
      *dest = &b[4];
      *is_ipv6 = false;
      return strlen(*dest);
    } else {
      if (length != 16 || !ares_inet_ntop(AF_INET6, b, &b[16], 64 - 16)) return 0;
      *dest = &b[16];
      *is_ipv6 = true;
      return strlen(*dest);
    }
  }

  uint64_t uws_res_get_local_address_info(uws_res_r res, const char **dest, int *port, bool *is_ipv6)
  {
    static thread_local char b[64];
    *dest = nullptr;
    auto length = us_get_local_address_info(b, (us_socket_t *)res, port);

    if (length == 0) return 0;
    if (length == 4) {
      if (!ares_inet_ntop(AF_INET, b, &b[4], 64 - 4)) return 0;
      *dest = &b[4];
      *is_ipv6 = false;
      return strlen(*dest);
    } else {
      if (length != 16 || !ares_inet_ntop(AF_INET6, b, &b[16], 64 - 16)) return 0;
      *dest = &b[16];
      *is_ipv6 = true;
      return strlen(*dest);
    }
  }
}
