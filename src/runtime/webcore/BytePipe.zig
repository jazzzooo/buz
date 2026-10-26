const BytePipe = @This();

const Context = bun.bindgen.NativeCallbackContext(.vm);
registration: ?struct { context: Context, callbacks: *const Callbacks } = null,

const Callbacks = struct {
    deliver: *const fn (Context, streams.Result, std.mem.Allocator) void,
    retain: *const fn (Context) void,
    release: *const fn (Context) void,
};

pub fn isEmpty(this: *const BytePipe) bool {
    return this.registration == null;
}

pub fn take(this: *BytePipe) BytePipe {
    const owned = this.*;
    this.* = .{};
    return owned;
}

pub fn deinit(this: *BytePipe) void {
    const owned = this.take();
    if (owned.registration) |registration| registration.callbacks.release(registration.context);
}

pub fn deliver(this: *BytePipe, result: streams.Result, allocator: std.mem.Allocator) void {
    const registration = this.registration.?;
    var frame: BytePipe = if (result.isDone()) this.take() else retained: {
        registration.callbacks.retain(registration.context);
        break :retained this.*;
    };
    defer frame.deinit();
    registration.callbacks.deliver(registration.context, result, allocator);
}

pub fn Wrap(comptime Owner: type, comptime callback: fn (*Owner, streams.Result, std.mem.Allocator) void) type {
    return struct {
        const callbacks: Callbacks = .{
            .deliver = struct {
                fn call(context: Context, result: streams.Result, allocator: std.mem.Allocator) void {
                    callback(context.get(*Owner), result, allocator);
                }
            }.call,
            .retain = struct {
                fn call(context: Context) void {
                    const owner = context.get(*Owner);
                    owner.ref();
                }
            }.call,
            .release = struct {
                fn call(context: Context) void {
                    const owner = context.get(*Owner);
                    owner.deref();
                }
            }.call,
        };

        pub fn init(owner: *Owner) BytePipe {
            owner.ref();
            return .{ .registration = .{ .context = .init(owner), .callbacks = &callbacks } };
        }
    };
}

const std = @import("std");
const streams = @import("streams.zig");

const bun = @import("bun");
