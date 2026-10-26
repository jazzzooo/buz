#include "root.h"
#include "BunBuiltinNames.h"
#include "BunClientData.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include "StringConversion.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSStringInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/SIMDUTF.h>

namespace Bun::Bindgen::Engine {

JSC::JSValue bunBindgenEngine_IPC_createSendError(
    EngineCallContext& context,
    const BunBindgenEngine_IPC_createSendError_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    WTF::String message;
    switch (args.reason) {
    case IPCSendFailure::process_channel_closed:
        message = "process.send() can only be used if the IPC channel is open."_s;
        break;
    case IPCSendFailure::subprocess_channel_closed:
        message = "Subprocess.send() can only be used if an IPC channel is open."_s;
        break;
    case IPCSendFailure::subprocess_exited:
        message = "Subprocess.send() cannot be used after the process has exited."_s;
        break;
    case IPCSendFailure::write_failed: {
        auto* error = JSC::createTypeError(global, "process.send() failed"_s);
        RETURN_IF_EXCEPTION(scope, {});
        error->putDirect(vm, JSC::Identifier::fromString(vm, "syscall"_s), JSC::jsString(vm, WTF::String("write"_s)));
        RETURN_IF_EXCEPTION(scope, {});
        return error;
    }
    }
    RELEASE_ASSERT(!message.isNull());
    RELEASE_AND_RETURN(scope, Bun::createError(global, Bun::ErrorCode::ERR_IPC_CHANNEL_CLOSED, message));
}

BunBindgenEngine_IPC_serializeHandleReply_Return bunBindgenEngine_IPC_serializeHandleReply(
    EngineCallContext& context,
    const BunBindgenEngine_IPC_serializeHandleReply_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* message = JSC::constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, {});
    message->putDirect(vm, WebCore::clientData(vm)->builtinNames().cmdPublicName(),
        JSC::jsString(vm, WTF::String(args.acknowledged ? "NODE_HANDLE_ACK"_s : "NODE_HANDLE_NACK"_s)));
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, bunBindgenEngine_structured_serialization_serializeJSValue(context, {
        .value = message,
        .for_cross_process_transfer = true,
    }));
}

std::optional<JSC::JSValue> bunBindgenEngine_IPC_parseJSONMessage(
    EngineCallContext& context,
    const BunBindgenEngine_IPC_parseJSONMessage_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    if (args.bytes.size() > WTF::String::MaxLength) {
        JSC::throwOutOfMemoryError(global, scope);
        return std::nullopt;
    }
    WTF::String decoded;
    WTF::StringView text;
    if (simdutf::validate_ascii(reinterpret_cast<const char*>(args.bytes.data()), args.bytes.size())) {
        text = WTF::StringView(args.bytes);
    } else {
        auto result = Bun::decodeUTF8ReplacingInvalidSequences(args.bytes);
        if (!result) {
            JSC::throwOutOfMemoryError(global, scope);
            return std::nullopt;
        }
        decoded = WTF::move(result.value());
        text = decoded;
    }
    auto value = JSC::JSONParse(global, text);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!value) return std::nullopt;
    return value;
}

IPCIncomingCommand bunBindgenEngine_IPC_classifyIncomingCommand(
    EngineCallContext& context,
    const BunBindgenEngine_IPC_classifyIncomingCommand_Arguments& args)
{
    auto* global = static_cast<::Zig::GlobalObject*>(&context.globalObject);
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!args.message.isObject()) return IPCIncomingCommand::message;
    auto command = args.message.getObject()->get(global, WebCore::clientData(vm)->builtinNames().cmdPublicName());
    RETURN_IF_EXCEPTION(scope, IPCIncomingCommand::message);
    if (!command.isString()) return IPCIncomingCommand::message;
    auto name = JSC::asString(command)->value(global);
    RETURN_IF_EXCEPTION(scope, IPCIncomingCommand::message);
    if (WTF::StringView(name) == "NODE_HANDLE"_s) return IPCIncomingCommand::handle;
    if (WTF::StringView(name) == "NODE_HANDLE_ACK"_s) return IPCIncomingCommand::ack;
    if (WTF::StringView(name) == "NODE_HANDLE_NACK"_s) return IPCIncomingCommand::nack;
    return IPCIncomingCommand::message;
}

}
