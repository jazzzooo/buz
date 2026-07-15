var file: bun.FD = .invalid;
pub var enabled = false;
pub var check = bun.once(load);

pub fn write(data: []const u8) void {
    _ = bun.sys.File.from(file).writeAll(data);
}

pub fn load() void {
    if (bun.env_var.BUN_POSTGRES_SOCKET_MONITOR.get()) |monitor| {
        enabled = true;
        file = bun.sys.openA(monitor, bun.O.WRONLY | bun.O.CREAT | bun.O.TRUNC, 0o644).unwrap() catch {
            enabled = false;
            return;
        };
        debug("writing to {s}", .{monitor});
    }
}

const debug = bun.Output.scoped(.Postgres, .visible);

const bun = @import("bun");
const std = @import("std");
