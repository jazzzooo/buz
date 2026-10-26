const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");
const serialization = @import("binding_schema_structured_serialization");

const incoming_command = b.enumerationWithOptions("IPCIncomingCommand", .{
    b.enumerationValue("message", "message"),
    b.enumerationValue("handle", "handle"),
    b.enumerationValue("ack", "ack"),
    b.enumerationValue("nack", "nack"),
}, .{ .cpp_name = "IPCIncomingCommand" });

const send_failure = b.enumerationWithOptions("IPCSendFailure", .{
    b.enumerationValue("process_channel_closed", "process_channel_closed"),
    b.enumerationValue("subprocess_channel_closed", "subprocess_channel_closed"),
    b.enumerationValue("subprocess_exited", "subprocess_exited"),
    b.enumerationValue("write_failed", "write_failed"),
}, .{ .cpp_name = "IPCSendFailure" });

const engine_shims = .{
    b.engineShim("serializeHandleReply", .{b.argument("acknowledged", b.boolean, .{})}, serialization.serialized_script_value_handle, .current_realm_throwing),
    b.engineShim("parseJSONMessage", .{b.argument("bytes", b.buffer(.copy), .{})}, b.optional(b.engine_value), .current_realm_throwing),
    b.engineShim("createSendError", .{b.argument("reason", send_failure, .{})}, b.js_error_instance, .current_realm_throwing),
    b.engineShim("classifyIncomingCommand", .{b.argument("message", b.engine_value, .{})}, incoming_command, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExport("globalObjectConnectedIPC", .{b.argument("global", engine_types.global_object, .{})}, b.boolean),
    b.nativeExport("globalObjectHasIPC", .{b.argument("global", engine_types.global_object, .{})}, b.boolean),
    b.nativeExportWithOptions("ensureProcessIPCInitialized", .{}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("closeChildIPC", .{}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("IPC", .{}, .{}, engine_shims, native_exports);
