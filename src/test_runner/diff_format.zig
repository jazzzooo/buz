pub const StringDiffFormatter = struct {
    received_string: string,
    expected_string: string,
    io: std.Io,
    not: bool = false,

    pub fn format(this: StringDiffFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var scope = bun.AllocationScope.init(this.io, default_allocator);
        defer scope.deinit();
        var arena = std.heap.ArenaAllocator.init(scope.allocator());
        defer arena.deinit();
        const allocator = arena.allocator();
        const diff_config: DiffConfig = .default(Output.isAIAgent(), Output.enable_ansi_colors_stderr);
        try printDiffMain(allocator, this.not, this.received_string, this.expected_string, writer, diff_config);
    }
};

const string = []const u8;

const std = @import("std");
const printDiffFile = @import("./diff/printDiff.zig");
pub const DiffConfig = printDiffFile.DiffConfig;
pub const printDiffMain = printDiffFile.printDiffMain;

const bun = @import("bun");
const Output = bun.Output;
const default_allocator = bun.default_allocator;
