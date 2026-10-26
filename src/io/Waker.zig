const Waker = @This();

fd: bun.FD,

pub fn init() !Waker {
    return create(false).unwrap();
}

pub fn create(comptime pollable: bool) bun.sys.Maybe(Waker) {
    if (comptime bun.Environment.isLinux) {
        return switch (bun.sys.eventfd(0, std.os.linux.EFD.CLOEXEC | (if (pollable) std.os.linux.EFD.NONBLOCK else 0))) {
            .result => |fd| .{ .result = .{ .fd = fd } },
            .err => |err| .{ .err = err },
        };
    }
    const fd = switch (bun.sys.kqueue()) {
        .result => |fd| fd,
        .err => |err| return .{ .err = err },
    };
    switch (bun.sys.fcntl(fd, std.posix.F.SETFD, @as(c_int, bun.c.FD_CLOEXEC))) {
        .result => {},
        .err => |err| {
            _ = fd.closeAllowingStandardIo(null);
            return .{ .err = err };
        },
    }
    var event = std.mem.zeroes(Kqueue.Event);
    event.filter = std.c.EVFILT.USER;
    event.flags = std.c.EV.ADD | std.c.EV.CLEAR;
    switch (Kqueue.change(fd, &event)) {
        .result => return .{ .result = .{ .fd = fd } },
        .err => |err| {
            _ = fd.closeAllowingStandardIo(null);
            return .{ .err = err };
        },
    }
}

pub fn getFd(this: *const Waker) bun.FD {
    return this.fd;
}

pub fn deinit(this: *Waker) void {
    _ = this.fd.closeAllowingStandardIo(null);
    this.fd = .invalid;
}

pub fn wake(this: *const Waker) void {
    if (comptime bun.Environment.isLinux) {
        const increment: u64 = 1;
        switch (bun.sys.write(this.fd, std.mem.asBytes(&increment))) {
            .result => |amount| bun.assert(amount == @sizeOf(u64)),
            .err => |err| if (err.getErrno() != .AGAIN) {
                bun.Output.panic("eventfd wake failed: {s}", .{@tagName(err.getErrno())});
            },
        }
        return;
    }
    var event = std.mem.zeroes(Kqueue.Event);
    event.filter = std.c.EVFILT.USER;
    event.fflags = std.c.NOTE.TRIGGER;
    if (Kqueue.change(this.fd, &event) == .err) @panic("kqueue wake failed");
}

pub fn wait(this: Waker) void {
    if (comptime bun.Environment.isLinux) return this.drain();
    var events: [1]Kqueue.Event = undefined;
    if (Kqueue.wait(this.fd, &events) == .err) @panic("kqueue wake wait failed");
}

pub fn drain(this: Waker) void {
    if (comptime !bun.Environment.isLinux) return;
    var count: u64 = undefined;
    switch (bun.sys.read(this.fd, std.mem.asBytes(&count))) {
        .result => |amount| bun.assert(amount == @sizeOf(u64)),
        .err => |err| if (err.getErrno() != .AGAIN) {
            bun.Output.panic("eventfd drain failed: {s}", .{@tagName(err.getErrno())});
        },
    }
}

const std = @import("std");
const bun = @import("bun");
const Kqueue = @import("./Kqueue.zig");
