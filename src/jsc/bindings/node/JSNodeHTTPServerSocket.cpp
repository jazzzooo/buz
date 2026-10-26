#include "JSNodeHTTPServerSocket.h"
#include "JSNodeHTTPServerSocketPrototype.h"
#include "ZigGlobalObject.h"
#include "SchemaBindings.h"
#include "DOMIsoSubspaces.h"
#include "ScriptExecutionContext.h"
#include "helpers.h"
#include "JSSocketAddressDTO.h"
#include "JSBuffer.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <wtf/text/WTFString.h>
#include <bun-uws/src/App.h>
#include "libusockets.h"

namespace Bun {

using namespace JSC;
using namespace WebCore;

const JSC::ClassInfo JSNodeHTTPServerSocket::s_info = { "NodeHTTPServerSocket"_s, &Base::s_info, nullptr, nullptr,
    CREATE_METHOD_TABLE(JSNodeHTTPServerSocket) };

JSNodeHTTPServerSocket* JSNodeHTTPServerSocket::create(JSC::VM& vm, JSC::Structure* structure, us_socket_t* socket, bool is_ssl, JSC::JSObject* response)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (socket && us_socket_is_closed(socket)) {
        // dont attach closed socket because the callback will never be called
        socket = nullptr;
    }
    auto* object = new (JSC::allocateCell<JSNodeHTTPServerSocket>(vm)) JSNodeHTTPServerSocket(vm, structure, socket, is_ssl, response);
    object->finishCreation(vm);
    object->streamBuffer.reset(Bindgen::ZigExports::bunBindgenZig_Socket_socketStreamBufferCreate(object->globalObject()));
    if (!scope.exception() && socket)
        object->strongThis.reset(createStrongRef(object->globalObject(), object));
    if (scope.exception()) {
        object->socket = nullptr;
        return nullptr;
    }
    return object;
}

JSNodeHTTPServerSocket* JSNodeHTTPServerSocket::create(JSC::VM& vm, Zig::GlobalObject* globalObject, us_socket_t* socket, bool is_ssl, JSC::JSObject* response)
{
    auto* structure = globalObject->m_JSNodeHTTPServerSocketStructure.getInitializedOnMainThread(globalObject);
    return create(vm, structure, socket, is_ssl, response);
}

template<bool SSL>
void JSNodeHTTPServerSocket::clearSocketData(bool upgraded, us_socket_t* socket)
{
    if (upgraded) {
        auto* webSocket = (uWS::WebSocketData*)us_socket_ext(socket);
        webSocket->socketData = nullptr;
    } else {
        auto* httpResponseData = (uWS::HttpResponseData<SSL>*)us_socket_ext(socket);
        httpResponseData->socketData = nullptr;
    }
}

void JSNodeHTTPServerSocket::close()
{
    if (socket) {
        us_socket_close(socket, 0, nullptr);
    }
}

bool JSNodeHTTPServerSocket::isClosed() const
{
    return !socket || us_socket_is_closed(socket);
}

bool JSNodeHTTPServerSocket::isAuthorized() const
{
    // is secure means that tls was established successfully
    if (!is_ssl || !socket)
        return false;

    // Check if the handshake callback has fired. If so, use the isAuthorized flag
    // which reflects the actual certificate verification result.
    if (us_socket_ssl_handshake_callback_has_fired(socket)) {
        auto* httpResponseData = reinterpret_cast<uWS::HttpResponseData<true>*>(us_socket_ext(socket));
        if (!httpResponseData)
            return false;
        return httpResponseData->isAuthorized;
    }

    // The handshake callback hasn't fired yet, but we're in an HTTP handler,
    // which means we received HTTP data. Check if the TLS handshake has actually
    // completed using OpenSSL's state (SSL_is_init_finished).
    //
    // If the handshake is complete but the callback hasn't fired, we're in a race
    // condition. The callback will fire shortly and either:
    // 1. Set isAuthorized = true (success)
    // 2. Close the socket (if rejectUnauthorized and verification failed)
    //
    // Since we're in an HTTP handler and the socket isn't closed, we can safely
    // assume the handshake will succeed. If it fails, the socket will be closed
    // and subsequent operations will fail appropriately.
    return us_socket_is_ssl_handshake_finished(socket);
}

JSNodeHTTPServerSocket::~JSNodeHTTPServerSocket()
{
    if (socket) {
        if (is_ssl) {
            clearSocketData<true>(this->upgraded, socket);
        } else {
            clearSocketData<false>(this->upgraded, socket);
        }
    }
}

void Bindgen::Engine::releaseSocketStreamBuffer(us_socket_stream_buffer_t* buffer)
{
    Bindgen::ZigExports::bunBindgenZig_Socket_socketStreamBufferDeinit(buffer);
}

void JSNodeHTTPServerSocket::StreamBufferDeleter::operator()(us_socket_stream_buffer_t* buffer) const
{
    Bindgen::Engine::releaseSocketStreamBuffer(buffer);
}

size_t JSNodeHTTPServerSocket::bufferedSize() const
{
    return Bindgen::ZigExports::bunBindgenZig_Socket_socketStreamBufferSize(streamBuffer.get());
}

size_t JSNodeHTTPServerSocket::totalBytesWritten() const
{
    return Bindgen::ZigExports::bunBindgenZig_Socket_socketStreamBufferTotalWritten(streamBuffer.get());
}

JSNodeHTTPServerSocket::JSNodeHTTPServerSocket(JSC::VM& vm, JSC::Structure* structure, us_socket_t* socket, bool is_ssl, JSC::JSObject* response)
    : JSC::JSDestructibleObject(vm, structure)
    , socket(socket)
    , is_ssl(is_ssl)
    , currentResponseObject(response, JSC::WriteBarrierEarlyInit)
{
}

void JSNodeHTTPServerSocket::detach()
{
    this->m_duplex.clear();
    this->currentResponseObject.clear();
    this->functionToCallOnClose.clear();
    this->functionToCallOnDrain.clear();
    this->functionToCallOnData.clear();
    this->strongThis.reset();
}

StrongRef JSNodeHTTPServerSocket::retainForTask() const
{
    if (!strongThis)
        return nullptr;
    strongThis->ref();
    return StrongRef(strongThis.get());
}

static BunBindgen_NodeHTTPResponse_NodeHTTPResponse_Native* nodeHTTPResponseBinding(JSObject* response)
{
    if (!response)
        return nullptr;
    return bun_bindgen_class_NodeHTTPResponse_NodeHTTPResponse_try_cast_value(response);
}

void Bindgen::Engine::releaseNodeHTTPResponseCloseState(NodeHTTPResponseCloseState* response)
{
    Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_nodeHTTPResponseReleaseCloseState(response);
}

struct CloseStateDeleter {
    void operator()(NodeHTTPResponseCloseState* response) const
    {
        Bindgen::Engine::releaseNodeHTTPResponseCloseState(response);
    }
};

class SocketCloseDelivery {
public:
    SocketCloseDelivery(StrongRef&& socket, NodeHTTPResponseCloseState* response)
        : m_socket(WTF::move(socket))
        , m_response(response)
    {
    }

    SocketCloseDelivery(SocketCloseDelivery&&) = default;
    SocketCloseDelivery(const SocketCloseDelivery&) = delete;
    SocketCloseDelivery& operator=(const SocketCloseDelivery&) = delete;
    ~SocketCloseDelivery() { finish(); }

    void operator()(ScriptExecutionContext& context)
    {
        auto* globalObject = defaultGlobalObject(context.globalObject());
        auto* socket = uncheckedDowncast<JSNodeHTTPServerSocket>(m_socket->value());
        auto* callback = socket->functionToCallOnClose.get();
        if (m_response) {
            Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_nodeHTTPResponseOnClose(globalObject, m_response.get());
        }
        if (callback && globalObject->scriptExecutionStatus(globalObject, socket) == ScriptExecutionStatus::Running) {
            auto callData = JSC::getCallData(callback);
            MarkedArgumentBuffer args;
            auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
            profiledCall(globalObject, JSC::ProfilingReason::API, callback, callData, socket, args);

            if (auto* exception = scope.exception()) {
                if (scope.clearExceptionExceptTermination())
                    globalObject->reportUncaughtExceptionAtEventLoop(globalObject, exception);
            }
        }
        finish();
    }

private:
    void finish()
    {
        auto root = WTF::move(m_socket);
        auto responseState = WTF::move(m_response);
        if (!root)
            return;
        auto* socket = uncheckedDowncast<JSNodeHTTPServerSocket>(root->value());
        if (auto* response = dynamicDowncast<BunBindgen_NodeHTTPResponse_NodeHTTPResponse>(socket->currentResponseObject.get())) {
            response->clear_slot_onAborted();
            response->clear_slot_onWritable();
            response->clear_slot_onData();
        }
        responseState.reset();
        socket->detach();
    }

    StrongRef m_socket;
    std::unique_ptr<NodeHTTPResponseCloseState, CloseStateDeleter> m_response;
};

void JSNodeHTTPServerSocket::onClose()
{
    auto self = WTF::move(strongThis);
    if (socket) {
        if (is_ssl)
            clearSocketData<true>(upgraded, socket);
        else
            clearSocketData<false>(upgraded, socket);
    }
    this->socket = nullptr;
    if (!self)
        return;

    NodeHTTPResponseCloseState* response = nullptr;
    if (auto* binding = nodeHTTPResponseBinding(this->currentResponseObject.get())) {
        response = Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_nodeHTTPResponseRetainCloseState(binding);
        Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_nodeHTTPResponseSetClosed(binding);
    }

    auto* globalObject = static_cast<Zig::GlobalObject*>(this->globalObject());
    SocketCloseDelivery delivery(WTF::move(self), response);
    if (auto* context = globalObject->scriptExecutionContext())
        context->postTask(WTF::move(delivery));
}

void JSNodeHTTPServerSocket::onDrain()
{
    // This function can be called during GC!
    Zig::GlobalObject* globalObject = static_cast<Zig::GlobalObject*>(this->globalObject());
    if (isClosed()) {
        return;
    }

    auto bufferedSize = this->bufferedSize();
    if (bufferedSize > 0) {
        auto* globalObject = defaultGlobalObject(this->globalObject());
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
        Bun::Bindgen::ZigExports::bunBindgenZig_Socket_socketBufferedWrite(
            globalObject, this->socket, this->ended, this->streamBuffer.get(), {});
        if (auto* exception = scope.exception()) {
            if (scope.clearExceptionExceptTermination())
                globalObject->reportUncaughtExceptionAtEventLoop(globalObject, exception);
            return;
        }
        bufferedSize = this->bufferedSize();

        if (bufferedSize > 0) {
            // need to drain more
            return;
        }
    }
    if (!functionToCallOnDrain)
        return;
    WebCore::ScriptExecutionContext* scriptExecutionContext = globalObject->scriptExecutionContext();

    if (scriptExecutionContext) {
        auto self = retainForTask();
        if (!self)
            return;
        scriptExecutionContext->postTask([self = WTF::move(self)](ScriptExecutionContext& context) {
            auto* globalObject = defaultGlobalObject(context.globalObject());
            auto* thisObject = uncheckedDowncast<JSNodeHTTPServerSocket>(self->value());
            auto* callbackObject = thisObject->functionToCallOnDrain.get();
            if (!callbackObject) {
                return;
            }
            auto callData = JSC::getCallData(callbackObject);
            MarkedArgumentBuffer args;

            if (globalObject->scriptExecutionStatus(globalObject, thisObject) == ScriptExecutionStatus::Running) {
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
                profiledCall(globalObject, JSC::ProfilingReason::API, callbackObject, callData, thisObject, args);

                if (auto* exception = scope.exception()) {
                    if (scope.clearExceptionExceptTermination())
                        globalObject->reportUncaughtExceptionAtEventLoop(globalObject, exception);
                }
            }
        });
    }
}

void JSNodeHTTPServerSocket::onData(const char* data, int length, bool last)
{
    // This function can be called during GC!
    Zig::GlobalObject* globalObject = static_cast<Zig::GlobalObject*>(this->globalObject());
    if (!functionToCallOnData) {
        return;
    }

    WebCore::ScriptExecutionContext* scriptExecutionContext = globalObject->scriptExecutionContext();

    if (scriptExecutionContext) {
        auto self = retainForTask();
        if (!self)
            return;
        RELEASE_ASSERT(length >= 0);
        WTF::Vector<uint8_t> bytes;
        bytes.append(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(data), static_cast<size_t>(length)));
        scriptExecutionContext->postTask([self = WTF::move(self), bytes = WTF::move(bytes), last = last](ScriptExecutionContext& context) {
            auto* globalObject = defaultGlobalObject(context.globalObject());
            auto* thisObject = uncheckedDowncast<JSNodeHTTPServerSocket>(self->value());
            auto* callbackObject = thisObject->functionToCallOnData.get();
            if (!callbackObject) {
                return;
            }

            JSC::JSValue chunk;
            {
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
                chunk = JSC::JSValue(WebCore::createBuffer(globalObject, bytes.span()));
                if (auto* exception = scope.exception()) {
                    if (scope.clearExceptionExceptTermination())
                        globalObject->reportUncaughtExceptionAtEventLoop(globalObject, exception);
                    return;
                }
            }

            auto callData = JSC::getCallData(callbackObject);
            MarkedArgumentBuffer args;
            args.append(chunk);
            args.append(JSC::jsBoolean(last));

            if (globalObject->scriptExecutionStatus(globalObject, thisObject) == ScriptExecutionStatus::Running) {
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
                profiledCall(globalObject, JSC::ProfilingReason::API, callbackObject, callData, thisObject, args);

                if (auto* exception = scope.exception()) {
                    if (scope.clearExceptionExceptTermination())
                        globalObject->reportUncaughtExceptionAtEventLoop(globalObject, exception);
                }
            }
        });
    }
}

JSC::Structure* JSNodeHTTPServerSocket::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    auto* structure = JSC::Structure::create(vm, globalObject, globalObject->objectPrototype(), JSC::TypeInfo(JSC::ObjectType, StructureFlags), JSNodeHTTPServerSocketPrototype::info());
    auto* prototype = JSNodeHTTPServerSocketPrototype::create(vm, structure);
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

void JSNodeHTTPServerSocket::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
}

template<typename Visitor>
void JSNodeHTTPServerSocket::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSNodeHTTPServerSocket* fn = uncheckedDowncast<JSNodeHTTPServerSocket>(cell);
    ASSERT_GC_OBJECT_INHERITS(fn, info());
    Base::visitChildren(fn, visitor);

    visitor.append(fn->currentResponseObject);
    visitor.append(fn->functionToCallOnClose);
    visitor.append(fn->functionToCallOnDrain);
    visitor.append(fn->functionToCallOnData);
    visitor.append(fn->m_remoteAddress);
    visitor.append(fn->m_localAddress);
    visitor.append(fn->m_duplex);
}

DEFINE_VISIT_CHILDREN(JSNodeHTTPServerSocket);

template<bool SSL>
static JSNodeHTTPServerSocket* getNodeHTTPServerSocket(us_socket_t* socket)
{
    auto* httpResponseData = (uWS::HttpResponseData<SSL>*)us_socket_ext(socket);
    return reinterpret_cast<JSNodeHTTPServerSocket*>(httpResponseData->socketData);
}

bool Bindgen::Engine::bunBindgenEngine_NodeHTTP_nodeHTTPServerSocketExistsForSocket(
    Bindgen::EngineCallContext&,
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPServerSocketExistsForSocket_Arguments& args)
{
    auto* socket = args.isSSL ? getNodeHTTPServerSocket<true>(args.socket) : getNodeHTTPServerSocket<false>(args.socket);
    return socket != nullptr;
}

JSValue Bindgen::Engine::bunBindgenEngine_NodeHTTP_nodeHTTPServerSocketCreateForClientError(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPServerSocketCreateForClientError_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    RETURN_IF_EXCEPTION(scope, {});

    if (args.isSSL) {
        uWS::HttpResponse<true>* response = reinterpret_cast<uWS::HttpResponse<true>*>(args.socket);
        auto* currentSocketDataPtr = reinterpret_cast<JSC::JSCell*>(response->getHttpResponseData()->socketData);
        if (currentSocketDataPtr) {
            return currentSocketDataPtr;
        }
    } else {
        uWS::HttpResponse<false>* response = reinterpret_cast<uWS::HttpResponse<false>*>(args.socket);
        auto* currentSocketDataPtr = reinterpret_cast<JSC::JSCell*>(response->getHttpResponseData()->socketData);
        if (currentSocketDataPtr) {
            return currentSocketDataPtr;
        }
    }
    // socket without response because is not valid http
    JSNodeHTTPServerSocket* socket = JSNodeHTTPServerSocket::create(
        vm,
        globalObject->m_JSNodeHTTPServerSocketStructure.getInitializedOnMainThread(globalObject),
        args.socket,
        args.isSSL, nullptr);
    RETURN_IF_EXCEPTION(scope, {});
    if (!socket->socket)
        return socket;
    if (args.isSSL) {
        uWS::HttpResponse<true>* response = reinterpret_cast<uWS::HttpResponse<true>*>(args.socket);
        response->getHttpResponseData()->socketData = socket;
    } else {
        uWS::HttpResponse<false>* response = reinterpret_cast<uWS::HttpResponse<false>*>(args.socket);
        response->getHttpResponseData()->socketData = socket;
    }
    return socket;
}

JSC::Structure* createNodeHTTPServerSocketStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    return JSNodeHTTPServerSocket::createStructure(vm, globalObject);
}

} // namespace Bun
