#include "config.h"
#include "JSWebSocket.h"

#include "EventNames.h"
#include "FetchHeaders.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSEventListener.h"
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include "blob.h"
#include <JavaScriptCore/JSCInlines.h>

namespace WebCore {

using namespace JSC;

bool JSWebSocketOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSWebSocket>(handle.slot()->asCell());
    auto& wrapped = wrapper->wrapped();
    if (wrapped.hasPendingActivity()) {
        if (reason) [[unlikely]]
            *reason = "ActiveDOMObject with pending activity"_s;
        return true;
    }
    if (wrapped.isFiringEventListeners()) {
        if (reason) [[unlikely]]
            *reason = "EventTarget firing event listeners"_s;
        return true;
    }
    if (reason) [[unlikely]]
        *reason = "Reachable from Event"_s;
    return visitor.containsOpaqueRoot(static_cast<EventTarget*>(&wrapped));
}

void JSWebSocketOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSWebSocket*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

static JSWebSocket* finishWebSocketConstruction(
    CppEngineConstructContext<JSWebSocket>& ctx,
    JSC::ThrowScope& scope,
    ExceptionOr<Ref<WebSocket>>&& result)
{
    auto* zigGlobal = defaultGlobalObject(&ctx.globalObject);
    if (result.hasException()) [[unlikely]] {
        propagateException(ctx.globalObject, scope, result.releaseException());
        return nullptr;
    }
    auto impl = result.releaseReturnValue();
    auto* implPtr = impl.ptr();
    auto* wrapper = JSWebSocket::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    return wrapper;
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

static FetchHeaders::Init webSocketHeaders(const WebSocketHeadersInput& input)
{
    if (input.is_sequence())
        return FetchHeaders::Init { std::in_place_index<0>, input.sequence() };

    RELEASE_ASSERT(input.is_record());
    Vector<KeyValuePair<String, String>> record;
    record.reserveInitialCapacity(input.record().size());
    for (const auto& entry : input.record())
        record.append({ entry.first, entry.second });
    return FetchHeaders::Init { std::in_place_index<1>, WTF::move(record) };
}

static void appendWebSocketProtocols(Vector<String>& protocols, const WebSocketProtocolsInput& input)
{
    if (input.is_protocol()) {
        protocols.append(input.protocol());
        return;
    }

    RELEASE_ASSERT(input.is_protocols());
    protocols.reserveInitialCapacity(input.protocols().size());
    for (const auto& protocol : input.protocols())
        protocols.append(protocol);
}

static WebSocketConstructorOptions webSocketConstructorOptions(
    Zig::GlobalObject& globalObject,
    ThrowScope& scope,
    const std::optional<WebSocketSecondInput>& input)
{
    WebSocketConstructorOptions result;
    if (!input)
        return result;

    if (input->is_protocol()) {
        result.protocols.append(input->protocol());
        return result;
    }
    if (input->is_protocols()) {
        result.protocols.reserveInitialCapacity(input->protocols().size());
        for (const auto& protocol : input->protocols())
            result.protocols.append(protocol);
        return result;
    }

    RELEASE_ASSERT(input->is_options());
    result.hasOptions = true;
    const auto& options = input->options();

    if (options.headers && *options.headers)
        result.headers = webSocketHeaders(**options.headers);

    if (options.protocols)
        appendWebSocketProtocols(result.protocols, *options.protocols);
    else if (options.protocol)
        result.protocols.append(*options.protocol);

    if (options.tls && *options.tls) {
        const auto& tls = **options.tls;
        if (tls.reject_unauthorized)
            result.rejectUnauthorized = *tls.reject_unauthorized ? 1 : 0;
        result.sslConfig = WebSocketSSLConfigPtr {
            ZigExports::bunBindgenZig_websocket_client_webSocketParseSSLConfig(&globalObject, tls).value_or(nullptr)
        };
        RETURN_IF_EXCEPTION(scope, {});
    }

    if (options.perMessageDeflate)
        result.offerPerMessageDeflate = *options.perMessageDeflate;

    if (options.proxy && *options.proxy) {
        const auto& proxy = **options.proxy;
        if (proxy.is_url()) {
            result.proxyUrl = proxy.url();
        } else {
            RELEASE_ASSERT(proxy.is_options());
            result.proxyUrl = proxy.options().url;
            if (proxy.options().headers && *proxy.options().headers)
                result.proxyHeaders = webSocketHeaders(**proxy.options().headers);
        }
    }

    return result;
}

JSWebSocket* bunBindgenCpp_WebCoreWebSocket_WebSocket_construct(
    CppEngineConstructContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*global, throwScope, "WebSocket"_s);
        return nullptr;
    }

    auto options = webSocketConstructorOptions(*zigGlobal, throwScope, args.second);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    WTF::String url = args.url;
    auto object = [&]() -> ExceptionOr<Ref<WebSocket>> {
        if (!options.hasOptions)
            return WebSocket::create(*context, url, options.protocols);
        if (options.rejectUnauthorized == -1) {
            return WebSocket::create(*context, url, options.protocols, WTF::move(options.headers), WTF::move(options.proxyUrl), WTF::move(options.proxyHeaders), WTF::move(options.sslConfig), options.offerPerMessageDeflate);
        }
        return WebSocket::create(*context, url, options.protocols, WTF::move(options.headers), options.rejectUnauthorized != 0, WTF::move(options.proxyUrl), WTF::move(options.proxyHeaders), WTF::move(options.sslConfig), options.offerPerMessageDeflate);
    }();
    RELEASE_AND_RETURN(throwScope, finishWebSocketConstruction(ctx, throwScope, WTF::move(object)));
}

WTF::String bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_URL(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_URL_Arguments&)
{
    return ctx.wrapped().url().string();
}

WTF::String bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_url(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_url_Arguments&)
{
    return ctx.wrapped().url().string();
}

uint16_t bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_readyState(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_readyState_Arguments&)
{
    return ctx.wrapped().readyState();
}

uint32_t bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_bufferedAmount(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_bufferedAmount_Arguments&)
{
    return ctx.wrapped().bufferedAmount();
}

static std::optional<JSValue> webSocketEventHandler(CppEngineCallContext<JSWebSocket>& ctx, const AtomString& eventType)
{
    return eventHandlerAttribute(ctx.wrapped(), eventType, worldForDOMObject(ctx.wrapper));
}

static void setWebSocketEventHandler(CppEngineCallContext<JSWebSocket>& ctx, const AtomString& eventType, const std::optional<JSValue>& value)
{
    setEventHandlerAttribute<JSEventListener>(ctx.globalObject, ctx.wrapped(), eventType, value, ctx.wrapper);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onopen(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onopen_Arguments&)
{
    return webSocketEventHandler(ctx, eventNames().openEvent);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onopen(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onopen_Arguments& args)
{
    setWebSocketEventHandler(ctx, eventNames().openEvent, args.value);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onmessage(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onmessage_Arguments&)
{
    return webSocketEventHandler(ctx, eventNames().messageEvent);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onmessage(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onmessage_Arguments& args)
{
    setWebSocketEventHandler(ctx, eventNames().messageEvent, args.value);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onerror(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onerror_Arguments&)
{
    return webSocketEventHandler(ctx, eventNames().errorEvent);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onerror(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onerror_Arguments& args)
{
    setWebSocketEventHandler(ctx, eventNames().errorEvent, args.value);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onclose(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_onclose_Arguments&)
{
    return webSocketEventHandler(ctx, eventNames().closeEvent);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onclose(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_setter_onclose_Arguments& args)
{
    setWebSocketEventHandler(ctx, eventNames().closeEvent, args.value);
}

std::optional<WTF::String> bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_protocol(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_protocol_Arguments&)
{
    auto value = ctx.wrapped().protocol();
    if (value.isNull())
        return std::nullopt;
    return value;
}

std::optional<WTF::String> bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_extensions(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_extensions_Arguments&)
{
    auto value = ctx.wrapped().extensions();
    if (value.isNull())
        return std::nullopt;
    return value;
}

WTF::String bunBindgenCpp_WebCoreWebSocket_WebSocket_getter_binaryType(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_getter_binaryType_Arguments&)
{
    return ctx.wrapped().binaryType();
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_setter_binaryType(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_setter_binaryType_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto result = ctx.wrapped().setBinaryType(args.value);
    if (result.hasException()) [[unlikely]]
        propagateException(*global, scope, result.releaseException());
}

enum class WebSocketPayloadOperation : uint8_t { Send, Ping, Pong };

template<WebSocketPayloadOperation operation>
static void sendWebSocketPayload(CppEngineCallContext<JSWebSocket>& ctx, const WebSocketPayloadInput& payload)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto& impl = ctx.wrapped();
    auto dispatch = [&](auto&& value) {
        if constexpr (operation == WebSocketPayloadOperation::Send)
            return impl.send(std::forward<decltype(value)>(value));
        else if constexpr (operation == WebSocketPayloadOperation::Ping)
            return impl.ping(std::forward<decltype(value)>(value));
        else
            return impl.pong(std::forward<decltype(value)>(value));
    };
    if (payload.is_bytes()) {
        invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] { return dispatch(std::span { payload.bytes().unsafePtr("WebSocket copies the bytes before the entry frame releases its lease"_s), payload.bytes().size() }); });
    } else if (payload.is_blob()) {
        invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] { return dispatch(payload.blob().get()); });
    } else {
        RELEASE_ASSERT(payload.is_string());
        invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] { return dispatch(payload.string()); });
    }
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_method_send(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_method_send_Arguments& args)
{
    sendWebSocketPayload<WebSocketPayloadOperation::Send>(ctx, args.data);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_method_ping(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_method_ping_Arguments& args)
{
    if (!args.data) {
        auto* global = &ctx.globalObject;
        auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
        invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] { return ctx.wrapped().ping(); });
        return;
    }
    sendWebSocketPayload<WebSocketPayloadOperation::Ping>(ctx, *args.data);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_method_pong(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_method_pong_Arguments& args)
{
    if (!args.data) {
        auto* global = &ctx.globalObject;
        auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
        invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] { return ctx.wrapped().pong(); });
        return;
    }
    sendWebSocketPayload<WebSocketPayloadOperation::Pong>(ctx, *args.data);
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_method_close(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_method_close_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto code = args.code;
    auto reason = args.reason ? *args.reason : String();
    invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] {
        return ctx.wrapped().close(WTF::move(code), WTF::move(reason));
    });
}

void bunBindgenCpp_WebCoreWebSocket_WebSocket_method_terminate(
    CppEngineCallContext<JSWebSocket>& ctx,
    const BunBindgenCpp_WebCoreWebSocket_WebSocket_method_terminate_Arguments&)
{
    ctx.wrapped().terminate();
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
