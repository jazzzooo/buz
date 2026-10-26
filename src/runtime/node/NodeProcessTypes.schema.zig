const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const process_object = b.brandedValueWithBrand(b.cppBrand("ProcessObjectValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isProcessObject",
    .header = "BindgenTypePredicates.h",
}, "NodeJS.Process"), .{
    .error_kind = .instance,
    .expectation = "a process object",
    .node_requirement = "Process",
});

const process_object_receiver_input = b.unionType("ProcessObjectReceiverInput", .{
    b.unionMember("process", process_object),
    b.unionMember("fallback", b.discarded),
}, .{ .ordered = true, .fallback_member = "fallback", .cpp_name = "ProcessObjectReceiverInput" });

pub fn processObjectReceiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return process_object_receiver_input;
}

pub const signal_input = archetypes.node_signal_input;
pub const signal_code = archetypes.nodeSignalCode("signal", false);

pub const schema = b.module("NodeProcessTypes", .{});
