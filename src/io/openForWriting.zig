pub fn openForWriting(
    dir: bun.FD,
    input_path: anytype,
    input_flags: i32,
    mode: bun.Mode,
) bun.sys.Maybe(bun.FD) {
    return openForWritingImpl(
        dir,
        input_path,
        input_flags,
        mode,
        bun.sys.openat,
    );
}

pub fn openForWritingImpl(
    dir: bun.FD,
    input_path: anytype,
    input_flags: i32,
    mode: bun.Mode,
    comptime openat: *const fn (dir: bun.FD, path: [:0]const u8, flags: i32, mode: bun.Mode) bun.sys.Maybe(bun.FD),
) bun.sys.Maybe(bun.FD) {
    const PathT = @TypeOf(input_path);
    if (PathT != bun.webcore.PathOrFileDescriptor and PathT != [:0]const u8 and PathT != [:0]u8) {
        @compileError("Only string or PathOrFileDescriptor is supported but got: " ++ @typeName(PathT));
    }

    return switch (PathT) {
        bun.webcore.PathOrFileDescriptor => switch (input_path) {
            .path => |path| bun.sys.openatA(dir, path.slice(), input_flags, mode),
            .fd => |fd| bun.sys.dupWithFlags(fd, 0),
        },
        [:0]const u8, [:0]u8 => openat(dir, input_path, input_flags, mode),
        else => unreachable,
    };
}

const bun = @import("bun");
