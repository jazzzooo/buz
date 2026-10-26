#pragma once

#include "root.h"
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSObject.h>
#include "BunClientData.h"
#include "StrongRef.h"
#include <memory>

struct us_socket_stream_buffer_t;
struct us_socket_t;

namespace uWS {
template<bool SSL>
struct HttpResponseData;
struct WebSocketData;
}

namespace Bun {

class JSNodeHTTPServerSocketPrototype;

class JSNodeHTTPServerSocket : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    struct StreamBufferDeleter {
        void operator()(us_socket_stream_buffer_t*) const;
    };
    std::unique_ptr<us_socket_stream_buffer_t, StreamBufferDeleter> streamBuffer;
    size_t bufferedSize() const;
    size_t totalBytesWritten() const;
    us_socket_t* socket = nullptr;
    unsigned is_ssl : 1 = 0;
    unsigned ended : 1 = 0;
    unsigned upgraded : 1 = 0;
    StrongRef strongThis;
    StrongRef retainForTask() const;

    static JSNodeHTTPServerSocket* create(JSC::VM& vm, JSC::Structure* structure, us_socket_t* socket, bool is_ssl, JSC::JSObject* response);
    static JSNodeHTTPServerSocket* create(JSC::VM& vm, Zig::GlobalObject* globalObject, us_socket_t* socket, bool is_ssl, JSC::JSObject* response);

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSNodeHTTPServerSocket*>(cell)->JSNodeHTTPServerSocket::~JSNodeHTTPServerSocket();
    }

    template<bool SSL>
    static void clearSocketData(bool upgraded, us_socket_t* socket);

    void close();
    bool isClosed() const;
    bool isAuthorized() const;

    ~JSNodeHTTPServerSocket();

    JSNodeHTTPServerSocket(JSC::VM& vm, JSC::Structure* structure, us_socket_t* socket, bool is_ssl, JSC::JSObject* response);

    mutable JSC::WriteBarrier<JSC::JSObject> functionToCallOnClose;
    mutable JSC::WriteBarrier<JSC::JSObject> functionToCallOnDrain;
    mutable JSC::WriteBarrier<JSC::JSObject> functionToCallOnData;
    mutable JSC::WriteBarrier<JSC::JSObject> currentResponseObject;
    mutable JSC::WriteBarrier<JSC::JSObject> m_remoteAddress;
    mutable JSC::WriteBarrier<JSC::JSObject> m_localAddress;
    mutable JSC::WriteBarrier<JSC::JSObject> m_duplex;

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;

        return WebCore::subspaceForImpl<JSNodeHTTPServerSocket, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForJSNodeHTTPServerSocket.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForJSNodeHTTPServerSocket = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForJSNodeHTTPServerSocket.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForJSNodeHTTPServerSocket = std::forward<decltype(space)>(space); });
    }

    void detach();
    void onClose();
    void onDrain();
    void onData(const char* data, int length, bool last);

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject);
    void finishCreation(JSC::VM& vm);
};

} // namespace Bun
