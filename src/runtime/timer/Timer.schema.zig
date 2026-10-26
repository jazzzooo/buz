const b = @import("bindgen_schema");
pub const timer_callback = b.callback(
    "TimerCallback",
    .{b.rest("arguments", b.invocation_any)},
    b.none,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

pub const schema = b.module("Timer", .{});
