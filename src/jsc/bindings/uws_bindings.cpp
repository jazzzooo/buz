// clang-format off
#include "root.h"

#include "SchemaBindings.h"
#include "wtf/Vector.h"
#include "wtf/text/WTFString.h"
#include <bun-uws/src/App.h>
#include <span>
#include <string_view>

using TLSWebSocket = uWS::WebSocket<true, true, void *>;
using TCPWebSocket = uWS::WebSocket<false, true, void *>;

template<bool isSSL>
static WTF::Vector<WTF::String> uwsWebSocketTopics(void* websocket) {
  using WebSocketType = typename std::conditional<isSSL, TLSWebSocket, TCPWebSocket>::type;
  WebSocketType *uws = reinterpret_cast<WebSocketType*>(websocket);

  WTF::Vector<WTF::String> topics;
  uws->iterateTopics([&](std::string_view topic) {
    topics.append(WTF::String::fromUTF8ReplacingInvalidSequences(std::span {
      reinterpret_cast<const unsigned char*>(topic.data()),
      topic.length()
    }));
  });
  return topics;
}

Bun::Bindgen::Engine::BunBindgenEngine_ServerWebSocket_uwsWebSocketTopics_Return Bun::Bindgen::Engine::bunBindgenEngine_ServerWebSocket_uwsWebSocketTopics(
    const BunBindgenEngine_ServerWebSocket_uwsWebSocketTopics_Arguments& args)
{
  if (args.tls) {
    return uwsWebSocketTopics<true>(args.websocket);
  } else {
    return uwsWebSocketTopics<false>(args.websocket);
  }
}
