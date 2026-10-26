#include "JSNodeHTTPServerSocketPrototype.h"
#include "JSNodeHTTPServerSocket.h"
#include "JSSocketAddressDTO.h"
#include "ZigGlobalObject.h"
#include "SchemaBindings.h"
#include "helpers.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <wtf/text/WTFString.h>
#include "_libusockets.h"

namespace Bun {

using namespace JSC;
using namespace WebCore;

const JSC::ClassInfo JSNodeHTTPServerSocketPrototype::s_info = { "NodeHTTPServerSocket"_s, &Base::s_info, nullptr, nullptr,
    CREATE_METHOD_TABLE(JSNodeHTTPServerSocketPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSNodeHTTPServerSocketPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSNodeHTTPServerSocketPrototype

void JSNodeHTTPServerSocketPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    bunBindgenObjectSurface_JSNodeHTTPServerSocketPrototype_install(vm, info(), *this);
    this->structure()->setMayBePrototype(true);
}

static JSNodeHTTPServerSocket* serverSocket(JSC::JSValue value)
{
    auto* socket = dynamicDowncast<JSNodeHTTPServerSocket>(value);
    RELEASE_ASSERT(socket);
    return socket;
}

static JSNodeHTTPServerSocket* serverSocket(const std::optional<JSC::JSValue>& value)
{
    return value ? serverSocket(*value) : nullptr;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketClose(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketClose_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (!thisObject) [[unlikely]]
        return;
    if (thisObject->isClosed())
        return;
    thisObject->close();
}

bool Bindgen::Engine::bunBindgenEngine_NodeHTTP_serverSocketIsWritable(
    Bindgen::EngineCallContext&,
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_serverSocketIsWritable_Arguments& args)
{
    auto* thisObject = serverSocket(args.socket);
    return !thisObject->isClosed() && !thisObject->ended;
}

Bun::Bindgen::NodeHTTPServerSocketWriteResult Bindgen::Engine::bunBindgenEngine_NodeHTTP_serverSocketWriteBytes(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_serverSocketWriteBytes_Arguments& args)
{
    Bun::Bindgen::NodeHTTPServerSocketWriteResult result;
    auto* thisObject = serverSocket(args.socket);
    if (thisObject->isClosed() || thisObject->ended) {
        result.set_closed(0);
        return result;
    }
    result.set_written(Bun::Bindgen::ZigExports::bunBindgenZig_Socket_socketBufferedWrite(
        &context.globalObject, thisObject->socket, thisObject->ended, thisObject->streamBuffer.get(), args.data));
    return result;
}

std::optional<bool> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketEnd(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketEnd_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (!thisObject) [[unlikely]]
        return std::nullopt;
    if (thisObject->isClosed())
        return std::nullopt;

    thisObject->ended = true;
    auto bufferedSize = thisObject->bufferedSize();
    if (bufferedSize == 0) {
        return Bun::Bindgen::ZigExports::bunBindgenZig_Socket_socketBufferedWrite(
            &context.globalObject, thisObject->socket, thisObject->ended, thisObject->streamBuffer.get(), {});
    }
    return std::nullopt;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetSecureEstablished(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetSecureEstablished_Arguments& args)
{
    return serverSocket(args.bindingThis)->isAuthorized();
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetDuplex(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetDuplex_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (thisObject->m_duplex)
        return thisObject->m_duplex.get();
    return std::nullopt;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketSetDuplex(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketSetDuplex_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* thisObject = serverSocket(args.bindingThis);
    if (args.value.is_object()) {
        thisObject->m_duplex.set(vm, thisObject, args.value.object().getObject());
    } else {
        thisObject->m_duplex.clear();
    }

    return true;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetRemoteAddress(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetRemoteAddress_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto* thisObject = serverSocket(args.bindingThis);
    if (thisObject->m_remoteAddress) {
        return thisObject->m_remoteAddress.get();
    }

    us_socket_t* socket = thisObject->socket;
    if (!socket) {
        return std::nullopt;
    }

    const char* address = nullptr;
    int port = 0;
    bool is_ipv6 = false;

    uws_res_get_remote_address_info(reinterpret_cast<uws_res_t*>(socket), &address, &port, &is_ipv6);

    if (address == nullptr) {
        return std::nullopt;
    }

    auto addressString = WTF::String::fromUTF8(address);
    if (addressString.isEmpty()) {
        return std::nullopt;
    }

    auto* object = JSSocketAddressDTO::create(defaultGlobalObject(globalObject), jsString(vm, addressString), port, is_ipv6);
    thisObject->m_remoteAddress.set(vm, thisObject, object);
    return object;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetLocalAddress(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetLocalAddress_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto* thisObject = serverSocket(args.bindingThis);
    if (thisObject->m_localAddress) {
        return thisObject->m_localAddress.get();
    }

    us_socket_t* socket = thisObject->socket;
    if (!socket) {
        return std::nullopt;
    }

    const char* address = nullptr;
    int port = 0;
    bool is_ipv6 = false;

    uws_res_get_local_address_info(reinterpret_cast<uws_res_t*>(socket), &address, &port, &is_ipv6);

    if (address == nullptr) {
        return std::nullopt;
    }

    auto addressString = WTF::String::fromUTF8(address);
    if (addressString.isEmpty()) {
        return std::nullopt;
    }

    auto* object = JSSocketAddressDTO::create(defaultGlobalObject(globalObject), jsString(vm, addressString), port, is_ipv6);
    thisObject->m_localAddress.set(vm, thisObject, object);
    return object;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetOnClose(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetOnClose_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (thisObject->functionToCallOnClose)
        return thisObject->functionToCallOnClose.get();

    return std::nullopt;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetOnDrain(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetOnDrain_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (thisObject->functionToCallOnDrain)
        return thisObject->functionToCallOnDrain.get();

    return std::nullopt;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketSetOnDrain(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketSetOnDrain_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* thisObject = serverSocket(args.bindingThis);
    if (args.value.is_undefined_value() || args.value.is_null_value()) {
        thisObject->functionToCallOnDrain.clear();
        return true;
    }

    if (!args.value.is_callable()) {
        return false;
    }

    thisObject->functionToCallOnDrain.set(vm, thisObject, args.value.callable().getObject());
    return true;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetOnData(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetOnData_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (thisObject->functionToCallOnData)
        return thisObject->functionToCallOnData.get();

    return std::nullopt;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketSetOnData(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketSetOnData_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* thisObject = serverSocket(args.bindingThis);
    if (args.value.is_undefined_value() || args.value.is_null_value()) {
        thisObject->functionToCallOnData.clear();
        return true;
    }

    if (!args.value.is_callable()) {
        return false;
    }

    thisObject->functionToCallOnData.set(vm, thisObject, args.value.callable().getObject());
    return true;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketSetOnClose(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketSetOnClose_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto* thisObject = serverSocket(args.bindingThis);
    if (args.value.is_undefined_value() || args.value.is_null_value()) {
        thisObject->functionToCallOnClose.clear();
        return true;
    }

    if (!args.value.is_callable()) {
        return false;
    }

    thisObject->functionToCallOnClose.set(vm, thisObject, args.value.callable().getObject());
    return true;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetClosed(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetClosed_Arguments& args)
{
    return serverSocket(args.bindingThis)->isClosed();
}

double Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetBytesWritten(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetBytesWritten_Arguments& args)
{
    return static_cast<double>(serverSocket(args.bindingThis)->totalBytesWritten());
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_serverSocketGetResponse(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_serverSocketGetResponse_Arguments& args)
{
    auto* thisObject = serverSocket(args.bindingThis);
    if (!thisObject->currentResponseObject)
        return std::nullopt;

    return thisObject->currentResponseObject.get();
}

} // namespace Bun
