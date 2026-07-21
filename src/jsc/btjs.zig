extern const jsc_llint_begin: u8;
extern const jsc_llint_end: u8;
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

fn printSourceAtAddress(debug_info: *std.debug.SelfInfo, out_stream: *std.Io.Writer, address: usize, tty_config: std.Io.Terminal, fp: usize) !void {
    if (!bun.Environment.isDebug) unreachable;
    const allocator = std.debug.getDebugInfoAllocator();
    var symbol_buf: [1]std.debug.Symbol = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(@ptrCast(&symbol_buf), allocator);
    const symbol_allocator = bfa.allocator();
    var symbols = try std.ArrayList(std.debug.Symbol).initCapacity(symbol_allocator, 1);
    defer symbols.deinit(symbol_allocator);

    debug_info.getSymbols(
        std.Options.debug_io,
        symbol_allocator,
        allocator,
        address,
        false,
        &symbols,
    ) catch |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo, error.UnsupportedDebugInfo => return printUnknownSource(debug_info, out_stream, address, tty_config),
        else => return err,
    };
    if (symbols.items.len == 0) return printUnknownSource(debug_info, out_stream, address, tty_config);
    const symbol_info = symbols.items[0];
    defer if (symbol_info.source_location) |sl| allocator.free(sl.file_name);
    const symbol_name = symbol_info.name orelse "???";

    const probably_llint = address > @intFromPtr(&jsc_llint_begin) and address < @intFromPtr(&jsc_llint_end);
    var allow_llint = true;
    if (std.mem.startsWith(u8, symbol_name, "__")) {
        allow_llint = false; // disallow llint for __ZN3JSC11Interpreter20executeModuleProgramEPNS_14JSModuleRecordEPNS_23ModuleProgramExecutableEPNS_14JSGlobalObjectEPNS_19JSModuleEnvironmentENS_7JSValueES9_
    }
    if (std.mem.startsWith(u8, symbol_name, "_llint_call_javascript")) {
        allow_llint = false; // disallow llint for _llint_call_javascript
    }
    const do_llint = probably_llint and allow_llint;

    const frame: *const bun.jsc.CallFrame = @ptrFromInt(fp);
    if (do_llint) {
        const srcloc = frame.getCallerSrcLoc(bun.jsc.VirtualMachine.get().global);
        try tty_config.setColor(.bold);
        try out_stream.print("{f}:{d}:{d}: ", .{ srcloc.str, srcloc.line, srcloc.column });
        try tty_config.setColor(.reset);
    }

    try printLineInfo(
        out_stream,
        symbol_info.source_location,
        address,
        symbol_name,
        symbol_info.compile_unit_name orelse "",
        tty_config,
        printLineFromFileAnyOs,
        do_llint,
    );
    if (do_llint) {
        const desc = frame.describeFrame();
        try out_stream.print("    {s}\n    ", .{desc});
        try tty_config.setColor(.green);
        try out_stream.writeAll("^");
        try tty_config.setColor(.reset);
        try out_stream.writeAll("\n");
    }
}

fn printUnknownSource(debug_info: *std.debug.SelfInfo, out_stream: *std.Io.Writer, address: usize, tty_config: std.Io.Terminal) !void {
    if (!bun.Environment.isDebug) unreachable;
    const module_name = debug_info.getModuleName(std.Options.debug_io, address) catch null;
    return printLineInfo(
        out_stream,
        null,
        address,
        "???",
        module_name orelse "???",
        tty_config,
        printLineFromFileAnyOs,
        false,
    );
}
fn printLineInfo(
    out_stream: *std.Io.Writer,
    source_location: ?std.debug.SourceLocation,
    address: usize,
    symbol_name: []const u8,
    compile_unit_name: []const u8,
    tty_config: std.Io.Terminal,
    comptime printLineFromFile: anytype,
    do_llint: bool,
) !void {
    if (!bun.Environment.isDebug) unreachable;

    nosuspend {
        try tty_config.setColor(.bold);

        if (source_location) |*sl| {
            try out_stream.print("{s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column });
        } else if (!do_llint) {
            try out_stream.writeAll("???:?:?");
        }

        try tty_config.setColor(.reset);
        if (!do_llint or source_location != null) try out_stream.writeAll(": ");
        try tty_config.setColor(.dim);
        try out_stream.print("0x{x} in {s} ({s})", .{ address, symbol_name, compile_unit_name });
        try tty_config.setColor(.reset);
        try out_stream.writeAll("\n");

        // Show the matching source code line if possible
        if (source_location) |sl| {
            if (printLineFromFile(out_stream, sl)) {
                if (sl.column > 0) {
                    // The caret already takes one char
                    const space_needed = @as(usize, @intCast(sl.column - 1));

                    try out_stream.splatByteAll(' ', space_needed);
                    try tty_config.setColor(.green);
                    try out_stream.writeAll("^");
                    try tty_config.setColor(.reset);
                }
                try out_stream.writeAll("\n");
            } else |err| switch (err) {
                error.EndOfFile, error.FileNotFound => {},
                error.BadPathName => {},
                error.AccessDenied => {},
                else => return err,
            }
        }
    }
}

fn printLineFromFileAnyOs(out_stream: *std.Io.Writer, source_location: std.debug.SourceLocation) !void {
    if (!bun.Environment.isDebug) unreachable;

    // Need this to always block even in async I/O mode, because this could potentially
    // be called from e.g. the event loop code crashing.
    const io = std.Options.debug_io;
    var f = try std.Io.Dir.cwd().openFile(io, source_location.file_name, .{});
    defer f.close(io);
    // TODO fstat and make sure that the file has the correct size

    var buf: [4096]u8 = undefined;
    var file_offset: u64 = 0;
    var amt_read = try f.readPositionalAll(io, buf[0..], file_offset);
    file_offset += amt_read;
    const line_start = seek: {
        var current_line_start: usize = 0;
        var next_line: usize = 1;
        while (next_line != source_location.line) {
            const slice = buf[current_line_start..amt_read];
            if (std.mem.indexOfScalar(u8, slice, '\n')) |pos| {
                next_line += 1;
                if (pos == slice.len - 1) {
                    amt_read = try f.readPositionalAll(io, buf[0..], file_offset);
                    file_offset += amt_read;
                    current_line_start = 0;
                } else current_line_start += pos + 1;
            } else if (amt_read < buf.len) {
                return error.EndOfFile;
            } else {
                amt_read = try f.readPositionalAll(io, buf[0..], file_offset);
                file_offset += amt_read;
                current_line_start = 0;
            }
        }
        break :seek current_line_start;
    };
    const slice = buf[line_start..amt_read];
    if (std.mem.indexOfScalar(u8, slice, '\n')) |pos| {
        const line = slice[0 .. pos + 1];
        std.mem.replaceScalar(u8, line, '\t', ' ');
        return out_stream.writeAll(line);
    } else { // Line is the last inside the buffer, and requires another read to find delimiter. Alternatively the file ends.
        std.mem.replaceScalar(u8, slice, '\t', ' ');
        try out_stream.writeAll(slice);
        while (amt_read == buf.len) {
            amt_read = try f.readPositionalAll(io, buf[0..], file_offset);
            file_offset += amt_read;
            if (std.mem.indexOfScalar(u8, buf[0..amt_read], '\n')) |pos| {
                const line = buf[0 .. pos + 1];
                std.mem.replaceScalar(u8, line, '\t', ' ');
                return out_stream.writeAll(line);
            } else {
                const line = buf[0..amt_read];
                std.mem.replaceScalar(u8, line, '\t', ' ');
                try out_stream.writeAll(line);
            }
        }
        // Make sure printing last line of file inserts extra newline
        try out_stream.writeByte('\n');
    }
}

fn printUnwindError(debug_info: *std.debug.SelfInfo, out_stream: *std.Io.Writer, address: usize, err: std.debug.UnwindError, tty_config: std.Io.Terminal) !void {
    if (!bun.Environment.isDebug) unreachable;

    const module_name = debug_info.getModuleName(std.Options.debug_io, address) catch "???";
    try tty_config.setColor(.dim);
    if (err == error.MissingDebugInfo) {
        try out_stream.print("Unwind information for `{s}:0x{x}` was not available, trace may be incomplete\n\n", .{ module_name, address });
    } else {
        try out_stream.print("Unwind error at address `{s}:0x{x}` ({}), trace may be incomplete\n\n", .{ module_name, address, err });
    }
    try tty_config.setColor(.reset);
}

const bun = @import("bun");
const std = @import("std");
