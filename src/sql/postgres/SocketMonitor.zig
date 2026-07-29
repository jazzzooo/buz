pub fn write(io: std.Io, data: []const u8) void {
    debug("SocketMonitor: write {x}", .{data});
    if (comptime bun.Environment.isDebug) {
        DebugSocketMonitorWriter.check.call(io, .{});
        if (DebugSocketMonitorWriter.enabled) {
            DebugSocketMonitorWriter.write(data);
        }
    }
}

pub fn read(io: std.Io, data: []const u8) void {
    debug("SocketMonitor: read {x}", .{data});
    if (comptime bun.Environment.isDebug) {
        DebugSocketMonitorReader.check.call(io, .{});
        if (DebugSocketMonitorReader.enabled) {
            DebugSocketMonitorReader.write(data);
        }
    }
}

const debug = bun.Output.scoped(.SocketMonitor, .visible);

const DebugSocketMonitorReader = @import("./DebugSocketMonitorReader.zig");
const DebugSocketMonitorWriter = @import("./DebugSocketMonitorWriter.zig");
const bun = @import("bun");
const std = @import("std");
