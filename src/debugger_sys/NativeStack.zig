pub fn dumpBtjsTrace() callconv(.c) [*c]u8 {
    if (comptime !bun.Environment.isDebug) {
        const message = bun.default_allocator.dupeSentinel(u8, "btjs is disabled in release builds", 0) catch return null;
        return message.ptr;
    }

    var writer = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer writer.deinit();
    const terminal: std.Io.Terminal = .{
        .writer = &writer.writer,
        .mode = if (bun.Output.enable_ansi_colors_stdout) .escape_codes else .no_color,
    };
    std.debug.writeCurrentStackTrace(.{ .allow_unsafe_unwind = true }, terminal) catch {
        writer.writer.writeAll("Unable to dump stack trace\n") catch return null;
    };
    for (writer.written()) |*byte| {
        if (byte.* == 0) byte.* = ' ';
    }
    const bytes = writer.toOwnedSliceSentinel(0) catch return null;
    return bytes.ptr;
}

pub fn freeBtjsTrace(trace: [*c]u8) callconv(.c) void {
    if (trace == null) return;
    const bytes: [*:0]u8 = @ptrCast(trace);
    bun.default_allocator.free(std.mem.span(bytes));
}

comptime {
    const dump: *const @TypeOf(c.dumpBtjsTrace) = &dumpBtjsTrace;
    const free: *const @TypeOf(c.freeBtjsTrace) = &freeBtjsTrace;
    @export(dump, .{ .name = "dumpBtjsTrace" });
    @export(free, .{ .name = "freeBtjsTrace" });
}

const bun = @import("bun");
const std = @import("std");
const c = @import("debugger-native-stack");
