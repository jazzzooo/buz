/// allocated using bun.default_allocator. when called from lldb, it is never freed.
pub export fn dumpBtjsTrace() [*:0]const u8 {
    if (comptime bun.Environment.isDebug) {
        return dumpBtjsTraceDebugImpl();
    }

    return "btjs is disabled in release builds";
}

fn dumpBtjsTraceDebugImpl() [*:0]const u8 {
    var result_writer = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer result_writer.deinit();
    const w = &result_writer.writer;

    const tty_config: std.Io.Terminal = .{
        .writer = w,
        .mode = if (bun.Output.enable_ansi_colors_stdout) .escape_codes else .no_color,
    };
    std.debug.writeCurrentStackTrace(.{ .allow_unsafe_unwind = true }, tty_config) catch {
        w.writeAll("Unable to dump stack trace\n") catch return "<oom>".ptr;
    };

    // remove nulls
    for (result_writer.written()) |*itm| if (itm.* == 0) {
        itm.* = ' ';
    };
    // add null terminator
    w.writeByte(0) catch {
        return "<oom>".ptr;
    };
    return @ptrCast((result_writer.toOwnedSlice() catch {
        return "<oom>".ptr;
    }).ptr);
}

const bun = @import("bun");
const std = @import("std");
