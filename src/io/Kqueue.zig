pub const Event = if (bun.Environment.isFreeBSD) std.c.Kevent else std.posix.system.kevent64_s;

pub fn change(fd: bun.FD, event: *Event) bun.sys.Maybe(void) {
    while (true) {
        const result = call(fd.native(), @ptrCast(event), 1, @ptrCast(event), 0);
        if (bun.sys.getErrno(result) == .INTR) continue;
        if (bun.sys.Maybe(void).errnoSys(result, .kevent)) |err| return err;
        return .success;
    }
}

pub fn wait(fd: bun.FD, events: []Event) bun.sys.Maybe(usize) {
    const count = std.math.cast(c_int, events.len) orelse return .{ .err = bun.sys.Error.fromCode(.INVAL, .kevent) };
    while (true) {
        const result = call(fd.native(), events.ptr, 0, events.ptr, count);
        if (bun.sys.getErrno(result) == .INTR) continue;
        if (bun.sys.Maybe(usize).errnoSys(result, .kevent)) |err| return err;
        return .{ .result = @intCast(result) };
    }
}

fn call(fd: i32, changes: [*]const Event, change_count: c_int, events: [*]Event, event_count: c_int) isize {
    if (comptime bun.Environment.isFreeBSD) return std.c.kevent(fd, changes, change_count, events, event_count, null);
    return std.posix.system.kevent64(fd, changes, change_count, events, event_count, .{}, null);
}

const std = @import("std");
const bun = @import("bun");
