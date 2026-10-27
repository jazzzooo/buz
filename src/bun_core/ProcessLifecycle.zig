const std = @import("std");

pub const Callback = *const fn () callconv(.c) void;

var before_exit_callbacks: std.ArrayList(Callback) = .empty;
var shutdown_callbacks: std.ArrayList(Callback) = .empty;
var exit_callbacks: std.ArrayList(Callback) = .empty;

pub fn addBeforeExitCallback(callback: Callback) void {
    add(&before_exit_callbacks, callback);
}

pub fn addExitCallback(callback: Callback) void {
    add(&exit_callbacks, callback);
}

pub fn addShutdownCallback(callback: Callback) void {
    add(&shutdown_callbacks, callback);
}

pub fn runBeforeExitCallbacks() void {
    run(&before_exit_callbacks);
}

pub fn runExitCallbacks() void {
    run(&exit_callbacks);
}

pub fn runShutdownCallbacks() void {
    run(&shutdown_callbacks);
}

fn add(callbacks: *std.ArrayList(Callback), callback: Callback) void {
    if (std.mem.indexOfScalar(Callback, callbacks.items, callback) == null) {
        callbacks.append(std.heap.c_allocator, callback) catch @panic("OOM");
    }
}

fn run(callbacks: *std.ArrayList(Callback)) void {
    for (callbacks.items) |callback| callback();
    callbacks.items.len = 0;
}
