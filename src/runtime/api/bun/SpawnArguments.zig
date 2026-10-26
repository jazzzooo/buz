pub const ResolveArgv0Error = error{
    InvalidArgumentValue,
    CommandNotFound,
} || std.mem.Allocator.Error;

pub const ResolvedArgv0 = struct {
    executable: [:0]const u8,
    argument: [:0]u8,
};

pub fn resolveArgv0(
    path: []const u8,
    cwd: []const u8,
    pretend_argv0: ?[*:0]const u8,
    command: []const u8,
    allocator: std.mem.Allocator,
) ResolveArgv0Error!ResolvedArgv0 {
    if (bun.strings.indexOfChar(command, 0) != null) {
        return error.InvalidArgumentValue;
    }

    const path_buffer = try bun.default_allocator.create(bun.PathBuffer);
    defer bun.default_allocator.destroy(path_buffer);

    const search_path = if (bun.strings.containsChar(command, '/'))
        ""
    else if (path.len > 0)
        path
    else if (comptime bun.Environment.isPosix)
        std.mem.sliceTo(bun.c._PATH_DEFPATH, 0)
    else
        "";

    const executable = if (search_path.len == 0)
        try allocator.dupeSentinel(u8, command, 0)
    else
        try allocator.dupeSentinel(
            u8,
            bun.which(path_buffer, search_path, cwd, command) orelse return error.CommandNotFound,
            0,
        );
    errdefer allocator.free(executable);

    return .{
        .executable = executable,
        .argument = if (pretend_argv0) |value|
            try allocator.dupeSentinel(u8, std.mem.sliceTo(value, 0), 0)
        else
            try allocator.dupeSentinel(u8, command, 0),
    };
}

const std = @import("std");
const bun = @import("bun");
