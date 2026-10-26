pub const DiffFormatter = struct {
    received_string: ?string = null,
    expected_string: ?string = null,
    received: ?JSValue = null,
    expected: ?JSValue = null,
    globalThis: *JSGlobalObject,
    not: bool = false,

    pub fn format(this: DiffFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (this.expected_string != null and this.received_string != null) {
            return (StringDiffFormatter{
                .received_string = this.received_string.?,
                .expected_string = this.expected_string.?,
                .io = this.globalThis.bunVM().io,
                .not = this.not,
            }).format(writer);
        }

        var scope = bun.AllocationScope.init(this.globalThis.bunVM().io, bun.default_allocator);
        defer scope.deinit();
        var arena = std.heap.ArenaAllocator.init(scope.allocator());
        defer arena.deinit();
        const allocator = arena.allocator();

        const diff_config: DiffConfig = .default(bun.Output.isAIAgent(), bun.Output.enable_ansi_colors_stderr);

        var received_buf = std.Io.Writer.Allocating.init(allocator);
        defer received_buf.deinit();
        var expected_buf = std.Io.Writer.Allocating.init(allocator);
        defer expected_buf.deinit();

        var received_slice = this.received_string orelse received: {
            try this.formatValue(this.received orelse return, &received_buf.writer);
            break :received received_buf.written();
        };
        var expected_slice = this.expected_string orelse expected: {
            try this.formatValue(this.expected orelse return, &expected_buf.writer);
            break :expected expected_buf.written();
        };
        if (std.mem.startsWith(u8, received_slice, "\n")) received_slice = received_slice[1..];
        if (std.mem.startsWith(u8, expected_slice, "\n")) expected_slice = expected_slice[1..];
        if (std.mem.endsWith(u8, received_slice, "\n")) received_slice = received_slice[0 .. received_slice.len - 1];
        if (std.mem.endsWith(u8, expected_slice, "\n")) expected_slice = expected_slice[0 .. expected_slice.len - 1];

        try printDiffMain(allocator, this.not, received_slice, expected_slice, writer, diff_config);
    }

    fn formatValue(this: DiffFormatter, value: JSValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        value.jestSnapshotPrettyFormat(writer) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => |js_error| return this.globalThis.formatErrorToWriterError(js_error),
        };
    }
};

const string = []const u8;

const std = @import("std");
const diff_format = @import("./diff_format.zig");
const DiffConfig = diff_format.DiffConfig;
const StringDiffFormatter = diff_format.StringDiffFormatter;
const printDiffMain = diff_format.printDiffMain;

const bun = @import("bun");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = bun.bindgen.EngineOperand;
