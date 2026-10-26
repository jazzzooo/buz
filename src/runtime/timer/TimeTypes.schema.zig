const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const node_countdown = archetypes.nodeTimerCountdown;

pub fn timeoutSeconds(comptime name: []const u8) b.Argument {
    return archetypes.saturatedInteger(name, b.uint32, .{});
}

pub const date_or_milliseconds = archetypes.date_or_milliseconds;
pub const sleep_countdown = archetypes.sleep_countdown;

pub const schema = b.module("TimeTypes", .{});
