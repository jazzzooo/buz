//! This is AnyTask except it gives you two pointers instead of one.
//! Generally, prefer jsc.Task instead of this.

const AnyTaskWithExtraContext = @This();

pub const Context = bun.bindgen.NativeCallbackContext(.vm);

ctx: ?Context = null,
callback: *const fn (Context, *anyopaque) void = undefined,
on_cancel: ?*const fn (Context) void = null,
next: ?*AnyTaskWithExtraContext = null,
event_loop_node: @import("./EventLoopTaskNode.zig") = .{ .kind = .native },

pub fn from(this: *@This(), of: anytype, comptime field: []const u8) *@This() {
    const TheTask = New(std.meta.Child(@TypeOf(of)), void, @field(std.meta.Child(@TypeOf(of)), field));
    this.* = TheTask.init(of);
    return this;
}

pub fn run(this: *AnyTaskWithExtraContext, extra: *anyopaque) void {
    const callback = this.callback;
    const ctx = this.ctx;
    callback(ctx.?, extra);
}

pub fn cancel(this: *AnyTaskWithExtraContext) void {
    if (this.on_cancel) |callback| callback(this.ctx.?);
}

pub fn New(comptime Type: type, comptime ContextType: type, comptime Callback: anytype) type {
    return struct {
        pub fn init(ctx: *Type) AnyTaskWithExtraContext {
            return AnyTaskWithExtraContext{
                .callback = wrap,
                .ctx = .init(ctx),
            };
        }

        pub fn wrap(this: Context, extra: *anyopaque) void {
            @call(
                bun.callmod_inline,
                Callback,
                .{
                    this.get(*Type),
                    @as(*ContextType, @ptrCast(@alignCast(extra))),
                },
            );
        }
    };
}

const bun = @import("bun");
const std = @import("std");
