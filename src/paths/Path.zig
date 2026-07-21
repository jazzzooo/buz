const Options = struct {
    sep: PathSeparators = .any,
    kind: Kind = .any,
    unit: Unit = .u8,

    const Unit = enum {
        u8,
        u16,
        os,
    };

    const Kind = enum {
        abs,
        rel,

        // not recommended, but useful when you don't know
        any,
    };

    const PathSeparators = enum {
        any,
        auto,
        posix,

        pub fn char(comptime sep: @This()) u8 {
            return switch (sep) {
                .any => @compileError("use the existing slash"),
                .auto => std.fs.path.sep,
                .posix => std.fs.path.sep_posix,
            };
        }
    };

    pub fn pathUnit(comptime opts: @This()) type {
        return switch (opts.unit) {
            .u8 => u8,
            .u16 => u16,
            .os => if (Environment.isWindows) u16 else u8,
        };
    }

    pub fn Buf(comptime opts: @This()) type {
        return struct {
            pooled: switch (opts.unit) {
                .u8 => *PathBuffer,
                .u16 => *WPathBuffer,
                .os => if (Environment.isWindows) *WPathBuffer else *PathBuffer,
            },
            len: usize,

            pub fn setLength(this: *@This(), new_len: usize) void {
                this.len = new_len;
            }

            pub fn append(this: *@This(), characters: anytype, add_separator: bool) void {
                if (add_separator) {
                    switch (comptime opts.sep) {
                        .any, .auto => this.pooled[this.len] = std.fs.path.sep,
                        .posix => this.pooled[this.len] = std.fs.path.sep_posix,
                    }
                    this.len += 1;
                }

                if (opts.inputChildType(@TypeOf(characters)) == opts.pathUnit()) {
                    switch (comptime opts.sep) {
                        .any => {
                            @memcpy(this.pooled[this.len..][0..characters.len], characters);
                            this.len += characters.len;
                        },
                        .auto, .posix => {
                            for (characters) |c| {
                                switch (c) {
                                    '/', '\\' => this.pooled[this.len] = opts.sep.char(),
                                    else => this.pooled[this.len] = c,
                                }
                                this.len += 1;
                            }
                        },
                    }
                } else {
                    switch (opts.inputChildType(@TypeOf(characters))) {
                        u8 => {
                            const converted = bun.strings.convertUTF8toUTF16InBuffer(this.pooled[this.len..], characters);
                            if (comptime opts.sep != .any) {
                                for (this.pooled[this.len..][0..converted.len], 0..) |c, off| {
                                    switch (c) {
                                        '/', '\\' => this.pooled[this.len + off] = opts.sep.char(),
                                        else => {},
                                    }
                                }
                            }
                            this.len += converted.len;
                        },
                        u16 => {
                            const converted = bun.strings.convertUTF16toUTF8InBuffer(this.pooled[this.len..], characters) catch unreachable;
                            if (comptime opts.sep != .any) {
                                for (this.pooled[this.len..][0..converted.len], 0..) |c, off| {
                                    switch (c) {
                                        '/', '\\' => this.pooled[this.len + off] = opts.sep.char(),
                                        else => {},
                                    }
                                }
                            }
                            this.len += converted.len;
                        },
                        else => @compileError("unexpected character type"),
                    }
                }
            }
        };
    }

    pub fn inputChildType(comptime opts: @This(), comptime InputType: type) type {
        _ = opts;
        return switch (@typeInfo(std.meta.Child(InputType))) {
            // handle string literals
            .array => |array| array.child,
            else => std.meta.Child(InputType),
        };
    }
};

pub fn AbsPath(comptime opts: Options) type {
    var copy = opts;
    copy.kind = .abs;
    return Path(copy);
}

pub fn RelPath(comptime opts: Options) type {
    var copy = opts;
    copy.kind = .rel;
    return Path(copy);
}

pub const AutoRelPath = Path(.{ .kind = .rel, .sep = .auto });

pub fn Path(comptime opts: Options) type {
    return struct {
        _buf: opts.Buf(),

        pub fn init() @This() {
            return .{
                ._buf = .{
                    .pooled = switch (opts.unit) {
                        .u8 => bun.path_buffer_pool.get(),
                        .u16 => bun.w_path_buffer_pool.get(),
                        .os => if (comptime Environment.isWindows)
                            bun.w_path_buffer_pool.get()
                        else
                            bun.path_buffer_pool.get(),
                    },
                    .len = 0,
                },
            };
        }

        pub fn deinit(this: *const @This()) void {
            switch (opts.unit) {
                .u8 => bun.path_buffer_pool.put(this._buf.pooled),
                .u16 => bun.w_path_buffer_pool.put(this._buf.pooled),
                .os => if (comptime Environment.isWindows)
                    bun.w_path_buffer_pool.put(this._buf.pooled)
                else
                    bun.path_buffer_pool.put(this._buf.pooled),
            }
            @constCast(this).* = undefined;
        }

        pub fn initTopLevelDir() @This() {
            bun.debugAssert(bun.fs.FileSystem.instance_loaded);
            const top_level_dir = bun.fs.FileSystem.instance.top_level_dir;

            const trimmed = switch (comptime opts.kind) {
                .abs => trimmed: {
                    bun.debugAssert(isInputAbsolute(top_level_dir));
                    break :trimmed trimInput(.abs, top_level_dir);
                },
                .rel => @compileError("cannot create a relative path from top_level_dir"),
                .any => trimInput(.abs, top_level_dir),
            };

            var this = init();
            this._buf.append(trimmed, false);
            return this;
        }

        pub fn initFdPath(fd: FD) !@This() {
            switch (comptime opts.kind) {
                .abs => {},
                .rel => @compileError("cannot create a relative path from getFdPath"),
                .any => {},
            }

            var this = init();
            const raw = try fd.getFdPath(this._buf.pooled);
            const trimmed = trimInput(.abs, raw);
            this._buf.len = trimmed.len;

            return this;
        }

        pub fn fromLongPath(input: anytype) @This() {
            switch (comptime @TypeOf(input)) {
                []u8, []const u8, [:0]u8, [:0]const u8 => {},
                []u16, []const u16, [:0]u16, [:0]const u16 => {},
                else => @compileError("unsupported type: " ++ @typeName(@TypeOf(input))),
            }
            const trimmed = switch (comptime opts.kind) {
                .abs => trimmed: {
                    bun.debugAssert(isInputAbsolute(input));
                    break :trimmed trimInput(.abs, input);
                },
                .rel => trimmed: {
                    bun.debugAssert(!isInputAbsolute(input));
                    break :trimmed trimInput(.rel, input);
                },
                .any => trimInput(if (isInputAbsolute(input)) .abs else .rel, input),
            };

            var this = init();
            if (comptime Environment.isWindows) {
                switch (comptime opts.unit) {
                    .u8 => this._buf.append(bun.windows.long_path_prefix_u8, false),
                    .u16 => this._buf.append(bun.windows.long_path_prefix, false),
                    .os => if (Environment.isWindows)
                        this._buf.append(bun.windows.long_path_prefix, false)
                    else
                        this._buf.append(bun.windows.long_path_prefix_u8, false),
                }
            }

            this._buf.append(trimmed, false);
            return this;
        }

        pub fn from(input: anytype) @This() {
            const trimmed = switch (comptime opts.kind) {
                .abs => trimmed: {
                    bun.debugAssert(isInputAbsolute(input));
                    break :trimmed trimInput(.abs, input);
                },
                .rel => trimmed: {
                    bun.debugAssert(!isInputAbsolute(input));
                    break :trimmed trimInput(.rel, input);
                },
                .any => trimInput(if (isInputAbsolute(input)) .abs else .rel, input),
            };

            var this = init();
            this._buf.append(trimmed, false);
            return this;
        }

        pub fn isAbsolute(this: *const @This()) bool {
            return switch (comptime opts.kind) {
                .abs => @compileError("already known to be absolute"),
                .rel => @compileError("already known to not be absolute"),
                .any => isInputAbsolute(this.slice()),
            };
        }

        pub fn basename(this: *const @This()) []const opts.pathUnit() {
            return bun.strings.basename(opts.pathUnit(), this.slice());
        }

        pub fn dirname(this: *const @This()) ?[]const opts.pathUnit() {
            const path_type = comptime switch (opts.sep) {
                .posix => std.fs.path.PathType.posix,
                .any, .auto => if (Environment.isWindows) std.fs.path.PathType.windows else std.fs.path.PathType.posix,
            };
            var it = std.fs.path.ComponentIterator(path_type, opts.pathUnit()).init(this.slice());
            _ = it.last() orelse return null;
            const parent = it.previous() orelse return it.root();
            return parent.path;
        }

        pub fn slice(this: *const @This()) []const opts.pathUnit() {
            return this._buf.pooled[0..this._buf.len];
        }

        pub fn sliceZ(this: *const @This()) [:0]const opts.pathUnit() {
            this._buf.pooled[this._buf.len] = 0;
            return this._buf.pooled[0..this._buf.len :0];
        }

        pub fn buf(this: *const @This()) []opts.pathUnit() {
            return this._buf.pooled;
        }

        pub fn setLength(this: *@This(), new_length: usize) void {
            this._buf.setLength(new_length);

            const trimmed = switch (comptime opts.kind) {
                .abs => trimInput(.abs, this.slice()),
                .rel => trimInput(.rel, this.slice()),
                .any => trimmed: {
                    if (this.isAbsolute()) {
                        break :trimmed trimInput(.abs, this.slice());
                    }

                    break :trimmed trimInput(.rel, this.slice());
                },
            };

            this._buf.setLength(trimmed.len);
        }

        pub fn len(this: *const @This()) usize {
            return this._buf.len;
        }

        pub fn clear(this: *@This()) void {
            this._buf.setLength(0);
        }

        pub fn rootLen(input: anytype) ?usize {
            if (comptime Environment.isWindows) {
                if (input.len > 2 and input[1] == ':' and switch (input[2]) {
                    '/', '\\' => true,
                    else => false,
                }) {
                    const letter = input[0];
                    if (('a' <= letter and letter <= 'z') or ('A' <= letter and letter <= 'Z')) {
                        // C:\
                        return 3;
                    }
                }

                if (input.len > 5 and
                    switch (input[0]) {
                        '/', '\\' => true,
                        else => false,
                    } and
                    switch (input[1]) {
                        '/', '\\' => true,
                        else => false,
                    } and
                    switch (input[2]) {
                        '\\', '.' => false,
                        else => true,
                    })
                {
                    var i: usize = 3;
                    // \\network\share\
                    //   ^
                    while (i < input.len and switch (input[i]) {
                        '/', '\\' => false,
                        else => true,
                    }) {
                        i += 1;
                    }

                    i += 1;
                    // \\network\share\
                    //           ^
                    const start = i;
                    while (i < input.len and switch (input[i]) {
                        '/', '\\' => false,
                        else => true,
                    }) {
                        i += 1;
                    }

                    if (start != i and i < input.len and switch (input[i]) {
                        '/', '\\' => true,
                        else => false,
                    }) {
                        // \\network\share\
                        //                ^
                        if (i + 1 < input.len) {
                            return i + 1;
                        }
                        return i;
                    }
                }

                if (input.len > 0 and switch (input[0]) {
                    '/', '\\' => true,
                    else => false,
                }) {
                    // \
                    return 1;
                }

                return null;
            }

            if (input.len > 0 and input[0] == '/') {
                // /
                return 1;
            }

            return null;
        }

        const TrimInputKind = enum {
            abs,
            rel,
        };

        fn trimInput(kind: TrimInputKind, input: anytype) []const opts.inputChildType(@TypeOf(input)) {
            var trimmed: []const opts.inputChildType(@TypeOf(input)) = input[0..];

            if (comptime Environment.isWindows) {
                switch (kind) {
                    .abs => {
                        const root_len = rootLen(input) orelse 0;
                        while (trimmed.len > root_len and switch (trimmed[trimmed.len - 1]) {
                            '/', '\\' => true,
                            else => false,
                        }) {
                            trimmed = trimmed[0 .. trimmed.len - 1];
                        }
                    },
                    .rel => {
                        if (trimmed.len > 1 and trimmed[0] == '.') {
                            const c = trimmed[1];
                            if (c == '/' or c == '\\') {
                                trimmed = trimmed[2..];
                            }
                        }
                        while (trimmed.len > 0 and switch (trimmed[0]) {
                            '/', '\\' => true,
                            else => false,
                        }) {
                            trimmed = trimmed[1..];
                        }
                        while (trimmed.len > 0 and switch (trimmed[trimmed.len - 1]) {
                            '/', '\\' => true,
                            else => false,
                        }) {
                            trimmed = trimmed[0 .. trimmed.len - 1];
                        }
                    },
                }

                return trimmed;
            }

            switch (kind) {
                .abs => {
                    const root_len = rootLen(input) orelse 0;
                    while (trimmed.len > root_len and trimmed[trimmed.len - 1] == '/') {
                        trimmed = trimmed[0 .. trimmed.len - 1];
                    }
                },
                .rel => {
                    if (trimmed.len > 1 and trimmed[0] == '.' and trimmed[1] == '/') {
                        trimmed = trimmed[2..];
                    }
                    while (trimmed.len > 0 and trimmed[0] == '/') {
                        trimmed = trimmed[1..];
                    }

                    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
                        trimmed = trimmed[0 .. trimmed.len - 1];
                    }
                },
            }

            return trimmed;
        }

        fn isInputAbsolute(input: anytype) bool {
            if (input.len == 0) {
                return false;
            }

            if (input[0] == '/') {
                return true;
            }

            if (comptime Environment.isWindows) {
                if (input[0] == '\\') {
                    return true;
                }

                if (input.len < 3) {
                    return false;
                }

                if (input[1] == ':' and switch (input[2]) {
                    '/', '\\' => true,
                    else => false,
                }) {
                    return true;
                }
            }

            return false;
        }

        pub fn append(this: *@This(), input: anytype) void {
            const needs_sep = this.len() > 0 and switch (comptime opts.sep) {
                .any => switch (this.slice()[this.len() - 1]) {
                    '/', '\\' => false,
                    else => true,
                },
                else => this.slice()[this.len() - 1] != opts.sep.char(),
            };

            switch (comptime opts.kind) {
                .abs => {
                    const has_root = this.len() > 0;

                    if (comptime Environment.isDebug) {
                        if (has_root) {
                            bun.debugAssert(!isInputAbsolute(input));
                        } else {
                            bun.debugAssert(isInputAbsolute(input));
                        }
                    }

                    const trimmed = trimInput(if (has_root) .rel else .abs, input);

                    if (trimmed.len == 0) {
                        return;
                    }

                    this._buf.append(trimmed, needs_sep);
                },
                .rel => {
                    bun.debugAssert(!isInputAbsolute(input));

                    const trimmed = trimInput(.rel, input);

                    if (trimmed.len == 0) {
                        return;
                    }

                    this._buf.append(trimmed, needs_sep);
                },
                .any => {
                    const input_is_absolute = isInputAbsolute(input);

                    if (comptime Environment.isDebug) {
                        if (needs_sep) {
                            bun.debugAssert(!input_is_absolute);
                        }
                    }

                    const trimmed = trimInput(if (this.len() > 0)
                        // anything appended to an existing path should be trimmed
                        // as a relative path
                        .rel
                    else if (isInputAbsolute(input))
                        // path is empty, trim based on input
                        .abs
                    else
                        .rel, input);

                    if (trimmed.len == 0) {
                        return;
                    }

                    this._buf.append(trimmed, needs_sep);
                },
            }
        }

        pub fn appendFmt(this: *@This(), comptime fmt: []const u8, args: anytype) void {
            // TODO: there's probably a better way to do this. needed for trimming slashes
            var temp: Path(.{}) = .init();
            defer temp.deinit();

            const input = std.fmt.bufPrint(temp._buf.pooled, fmt, args) catch unreachable;

            this.append(input);
        }

        pub fn undo(this: *@This(), n_components: usize) void {
            const min_len = switch (comptime opts.kind) {
                .abs => rootLen(this.slice()) orelse 0,
                .rel => 0,
                .any => min_len: {
                    if (this.isAbsolute()) {
                        break :min_len rootLen(this.slice()) orelse 0;
                    }
                    break :min_len 0;
                },
            };

            var i: usize = 0;
            while (i < n_components) {
                const slash = switch (comptime opts.sep) {
                    .any => std.mem.lastIndexOfAny(opts.pathUnit(), this.slice(), &.{ std.fs.path.sep_posix, std.fs.path.sep_windows }),
                    .auto => std.mem.lastIndexOfScalar(opts.pathUnit(), this.slice(), std.fs.path.sep),
                    .posix => std.mem.lastIndexOfScalar(opts.pathUnit(), this.slice(), std.fs.path.sep_posix),
                } orelse {
                    this._buf.setLength(min_len);
                    return;
                };

                if (slash < min_len) {
                    this._buf.setLength(min_len);
                    return;
                }

                this._buf.setLength(slash);
                i += 1;
            }
        }

        const ResetScope = struct {
            path: *Path(opts),
            saved_len: usize,

            pub fn restore(this: *const ResetScope) void {
                this.path._buf.setLength(this.saved_len);
            }
        };

        pub fn save(this: *@This()) ResetScope {
            return .{ .path = this, .saved_len = this.len() };
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const PathBuffer = bun.PathBuffer;
const WPathBuffer = bun.WPathBuffer;
