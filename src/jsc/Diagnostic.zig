pub const frame_limit = 32;
pub const source_line_limit = 6;
pub const DescribeSchema = bindgen.Module("errors").engineShim("jsValueDescribeException");
pub const SourceLinesSchema = bindgen.Module("errors").engineShim("exceptionSourceLines");
pub const StackSchema = bindgen.Module("errors").engineShim("exceptionGetStackTrace");
const native_data = @import("../bindgen/owned_result.zig");
const DetailsType = bindgen.DictionaryFieldType(DescribeSchema.ReturnType, "details");
const FrameType = StackSchema.ReturnType.child;
const SourceLineType = SourceLinesSchema.ReturnType.child.child;
pub const Frame = bindgen.ResultType(FrameType);
pub const SourceLine = bindgen.ResultType(SourceLineType);
pub const Frames = native_data.ResultList(FrameType);
pub const SourceLines = native_data.ResultList(SourceLineType);
pub const Value = struct {
    details: bindgen.ResultType(DetailsType),
    frames: Frames,
    sourceLines: SourceLines,
};
pub const Owned = native_data.Owner(Value, destroyValue);

fn destroyValue(value: *Value) void {
    bindgen.deinitResult(DetailsType, &value.details);
    value.frames.deinit();
    value.sourceLines.deinit();
}

pub fn takeResult(input: bindgen.Return(DescribeSchema)) bun.OOM!Owned {
    var source = input;
    defer bindgen.deinitReturn(DescribeSchema, &source);
    var frames = try takeFrames(&source.frames);
    errdefer frames.deinit();
    const lines = try takeSourceLines(&source.sourceLines);
    const details = source.details;
    source.details = empty.value.details;
    return .{ .value = .{ .details = details, .frames = frames, .sourceLines = lines } };
}

pub const takeFrames = Frames.takeSequence;
pub const takeSourceLines = SourceLines.takeSequence;

pub const empty: Owned = .{ .value = .{
    .details = .{
        .errorCode = .unknown,
        .runtimeType = .nothing,
        .name = .empty(),
        .message = .empty(),
    },
    .frames = .empty,
    .sourceLines = .empty,
} };

pub fn setSourceText(value: *Value, text: []const u8, last_line: u32) bun.OOM!void {
    var buffer: [source_line_limit][]const u8 = undefined;
    const lines = strings.getLinesInText(text, last_line, &buffer) orelse return;
    var replacement = try SourceLines.initCapacity(lines.len);
    defer replacement.deinit();
    for (lines, 0..) |line, i| {
        replacement.appendAssumeCapacity(.{
            .text = try bindgen.DOMString.fromUTF8(line),
            .line = last_line - @as(u32, @intCast(i)),
        });
    }
    value.sourceLines.replace(&replacement);
}

pub fn hasPosition(frame: *const Frame) bool {
    return frame.line != null or frame.column != null or frame.bytePosition != null;
}

pub fn nameFormatter(frame: *const Frame, comptime enable_color: bool) NameFormatter {
    return .{ .function_name = &frame.functionName, .code_type = frame.codeType, .enable_color = enable_color, .is_async = frame.isAsync };
}

pub fn sourceURLFormatter(frame: *const Frame, root_path: []const u8, origin: ?*const ZigURL, exclude_line_column: bool, comptime enable_color: bool) SourceURLFormatter {
    return .{
        .frame = frame,
        .enable_color = enable_color,
        .origin = origin,
        .exclude_line_column = exclude_line_column,
        .root_path = root_path,
    };
}

pub fn trace(this: *const Value) Trace {
    return .{ .frames = this.frames.slice(), .source_lines = this.sourceLines.slice() };
}

pub fn addToErrorList(this: *const Value, error_list: *std.array_list.Managed(api.JsException), root_path: []const u8, origin: ?*const ZigURL) bun.OOM!void {
    if (this.details.name.isEmpty() and this.details.message.isEmpty() and this.frames.len() == 0) return;
    try error_list.ensureUnusedCapacity(1);
    var result: api.JsException = .{
        .runtime_type = @backingInt(this.details.runtimeType),
        .code = @backingInt(this.details.errorCode),
    };
    if (!this.details.name.isEmpty()) result.name = try this.details.name.toOwnedSlice(error_list.allocator);
    errdefer if (result.name) |text| error_list.allocator.free(text);
    if (!this.details.message.isEmpty()) result.message = try this.details.message.toOwnedSlice(error_list.allocator);
    errdefer if (result.message) |text| error_list.allocator.free(text);
    if (this.frames.len() > 0) result.stack = try trace(this).toAPI(error_list.allocator, root_path, origin);
    error_list.appendAssumeCapacity(result);
}

pub const Trace = struct {
    frames: []const Frame,
    source_lines: []const SourceLine = &.{},

    pub fn sourceLineIterator(this: Trace) SourceLineIterator {
        return .{ .lines = this.source_lines, .remaining = this.source_lines.len };
    }

    pub fn toAPI(this: Trace, allocator: std.mem.Allocator, root_path: []const u8, origin: ?*const ZigURL) bun.OOM!api.StackTrace {
        var text_length: usize = 0;
        for (this.source_lines) |*line|
            text_length = std.math.add(usize, text_length, line.text.utf8ByteLength()) catch return error.OutOfMemory;
        const text = try allocator.alloc(u8, text_length);
        errdefer allocator.free(text);
        const source_lines = try allocator.alloc(api.SourceLine, this.source_lines.len);
        errdefer allocator.free(source_lines);
        var offset: usize = 0;
        var iter = this.sourceLineIterator();
        for (source_lines) |*line| {
            const source = (try iter.next()).?;
            defer source.text.deinit();
            const bytes = source.text.slice();
            @memcpy(text[offset..][0..bytes.len], bytes);
            line.* = .{ .text = text[offset..][0..bytes.len], .line = @intCast(source.line) };
            offset += bytes.len;
        }
        const frames = try allocator.alloc(api.StackFrame, this.frames.len);
        var initialized: usize = 0;
        errdefer {
            for (frames[0..initialized]) |frame| {
                allocator.free(frame.function_name);
                allocator.free(frame.file);
            }
            allocator.free(frames);
        }
        for (this.frames, frames) |*frame, *output| {
            const name = try frame.functionName.toOwnedSlice(allocator);
            errdefer allocator.free(name);
            output.* = .{
                .function_name = name,
                .file = try std.fmt.allocPrint(allocator, "{f}", .{sourceURLFormatter(frame, root_path, origin, true, false)}),
                .position = .{
                    .line = if (frame.line) |line| .fromZeroBased(@intCast(line)) else .invalid,
                    .column = if (frame.column) |column| .fromZeroBased(@intCast(column)) else .invalid,
                    .line_start_byte = if (frame.bytePosition) |byte| @intCast(byte) else -1,
                },
                .scope = @fromBackingInt(@backingInt(frame.codeType)),
            };
            initialized += 1;
        }
        return .{ .source_lines = source_lines, .frames = frames };
    }
};

pub const SourceLineIterator = struct {
    lines: []const SourceLine,
    remaining: usize,

    pub const Item = struct { line: u32, text: bun.String.Slice };

    pub fn untilLast(this: *SourceLineIterator) bun.OOM!?Item {
        if (this.remaining <= 1) return null;
        return this.next();
    }

    pub fn next(this: *SourceLineIterator) bun.OOM!?Item {
        if (this.remaining == 0) return null;
        const line = &this.lines[this.remaining - 1];
        const text = try line.text.toUTF8(bun.default_allocator);
        this.remaining -= 1;
        return .{ .line = line.line, .text = text };
    }
};

pub const SourceURLFormatter = struct {
    frame: *const Frame,
    enable_color: bool,
    origin: ?*const ZigURL,
    exclude_line_column: bool = false,
    root_path: string = "",

    pub fn format(this: SourceURLFormatter, writer: *std.Io.Writer) !void {
        if (this.enable_color) {
            try writer.writeAll(Output.prettyFmt("<r><cyan>", true));
        }

        var source_slice_ = this.frame.sourceURL.toUTF8(bun.default_allocator) catch return error.WriteFailed;
        var source_slice = source_slice_.slice();
        defer source_slice_.deinit();

        if (!this.frame.remapped) {
            if (this.origin) |origin| {
                try writer.writeAll(origin.displayProtocol());
                try writer.writeAll("://");
                try writer.writeAll(origin.displayHostname());
                try writer.writeAll(":");
                try writer.writeAll(origin.port);
                try writer.writeAll("/blob:");

                if (strings.startsWith(source_slice, this.root_path)) {
                    source_slice = source_slice[this.root_path.len..];
                }
            }
            try writer.writeAll(source_slice);
        } else {
            if (this.enable_color) {
                const not_root = if (comptime bun.Environment.isWindows) this.root_path.len > "C:\\".len else this.root_path.len > "/".len;
                if (not_root and strings.startsWith(source_slice, this.root_path)) {
                    const root_path = strings.withoutTrailingSlash(this.root_path);
                    const relative_path = strings.withoutLeadingPathSeparator(source_slice[this.root_path.len..]);
                    try writer.writeAll(comptime Output.prettyFmt("<d>", true));
                    try writer.writeAll(root_path);
                    try writer.writeByte(std.fs.path.sep);
                    try writer.writeAll(comptime Output.prettyFmt("<r><cyan>", true));
                    try writer.writeAll(relative_path);
                } else {
                    try writer.writeAll(source_slice);
                }
            } else {
                try writer.writeAll(source_slice);
            }
        }

        if (source_slice.len > 0 and (this.frame.line != null or this.frame.column != null)) {
            if (this.enable_color) {
                try writer.writeAll(comptime Output.prettyFmt("<r><d>:", true));
            } else {
                try writer.writeAll(":");
            }
        }

        if (this.enable_color) try writer.writeAll(comptime Output.prettyFmt("<r>", true));

        if (!this.exclude_line_column) {
            if (this.frame.line != null and this.frame.column != null) {
                if (this.enable_color) {
                    try writer.print(
                        comptime Output.prettyFmt("<yellow>{d}<r><d>:<yellow>{d}<r>", true),
                        .{ @as(u64, this.frame.line.?) + 1, @as(u64, this.frame.column.?) + 1 },
                    );
                } else {
                    try writer.print("{d}:{d}", .{
                        @as(u64, this.frame.line.?) + 1,
                        @as(u64, this.frame.column.?) + 1,
                    });
                }
            } else if (this.frame.line != null) {
                if (this.enable_color) {
                    try writer.print(
                        comptime Output.prettyFmt("<yellow>{d}<r>", true),
                        .{
                            @as(u64, this.frame.line.?) + 1,
                        },
                    );
                } else {
                    try writer.print("{d}", .{
                        @as(u64, this.frame.line.?) + 1,
                    });
                }
            }
        }
    }
};

pub const NameFormatter = struct {
    function_name: *const bindgen.DOMString,
    code_type: @FieldType(Frame, "codeType"),
    enable_color: bool,
    is_async: bool,

    pub fn format(this: NameFormatter, writer: *std.Io.Writer) !void {
        const name = this.function_name;

        switch (this.code_type) {
            .eval => {
                if (this.enable_color) {
                    try writer.print(comptime Output.prettyFmt("<r><d>", true) ++ "eval" ++ Output.prettyFmt("<r>", true), .{});
                } else {
                    try writer.writeAll("eval");
                }
                if (!name.isEmpty()) {
                    if (this.enable_color) {
                        try writer.print(comptime Output.prettyFmt(" <r><b><i>{f}<r>", true), .{name});
                    } else {
                        try writer.print(" {f}", .{name});
                    }
                }
            },
            .function => {
                if (!name.isEmpty()) {
                    if (this.enable_color) {
                        if (this.is_async) {
                            try writer.print(comptime Output.prettyFmt("<r><b><i>async {f}<r>", true), .{name});
                        } else {
                            try writer.print(comptime Output.prettyFmt("<r><b><i>{f}<r>", true), .{name});
                        }
                    } else {
                        if (this.is_async) {
                            try writer.print("async {f}", .{name});
                        } else {
                            try writer.print("{f}", .{name});
                        }
                    }
                } else {
                    if (this.enable_color) {
                        if (this.is_async) {
                            try writer.print(comptime Output.prettyFmt("<r><d>", true) ++ "async <anonymous>" ++ Output.prettyFmt("<r>", true), .{});
                        } else {
                            try writer.print(comptime Output.prettyFmt("<r><d>", true) ++ "<anonymous>" ++ Output.prettyFmt("<r>", true), .{});
                        }
                    } else {
                        if (this.is_async) {
                            try writer.writeAll("async ");
                        }
                        try writer.writeAll("<anonymous>");
                    }
                }
            },
            .global => {},
            .wasm => {
                if (!name.isEmpty()) {
                    try writer.print("{f}", .{name});
                } else {
                    try writer.writeAll("WASM");
                }
            },
            .constructor => {
                try writer.print("new {f}", .{name});
            },
            else => {
                if (!name.isEmpty()) {
                    try writer.print("{f}", .{name});
                }
            },
        }
    }
};

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
const Output = bun.Output;
const strings = bun.strings;
const api = bun.schema.api;
const ZigURL = @import("../url/url.zig").URL;
const string = []const u8;
