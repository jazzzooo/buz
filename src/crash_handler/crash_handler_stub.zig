const std = @import("std");

pub const Action = union(enum) {
    parse: []const u8,
    visit: []const u8,
    print: []const u8,
};

pub const CrashReason = enum {
    out_of_memory,
};

pub var current_action: ?Action = null;

pub const StoredTrace = struct {
    pub const empty: StoredTrace = .{};

    pub fn capture(_: ?usize) StoredTrace {
        return .empty;
    }

    pub fn trace(_: *StoredTrace) std.debug.StackTrace {
        return .{ .return_addresses = &.{}, .skipped = .none };
    }
};

pub const WriteStackTraceLimits = struct {
    frame_count: usize = std.math.maxInt(usize),
    stop_at_jsc_llint: bool = false,
    skip_stdlib: bool = false,
    skip_file_patterns: []const []const u8 = &.{},
    skip_function_patterns: []const []const u8 = &.{},
};

pub fn isPanicking() bool {
    return false;
}

pub fn handleErrorReturnTrace(_: anyerror, _: ?*std.builtin.StackTrace) void {}

pub fn dumpStackTrace(_: std.debug.StackTrace, _: anytype) void {}

pub fn crashHandler(_: CrashReason, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @trap();
}
