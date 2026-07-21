const Options = struct {
    unit: Unit = .u8,

    const Unit = enum {
        u8,
        u16,
        os,
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
                    this.pooled[this.len] = std.fs.path.sep;
                    this.len += 1;
                }

                if (opts.inputChildType(@TypeOf(characters)) == opts.pathUnit()) {
                    if (comptime Environment.isWindows) {
                        for (characters) |c| {
                            if (native_path_type.isSep(opts.pathUnit(), c)) {
                                this.pooled[this.len] = std.fs.path.sep;
                            } else {
                                this.pooled[this.len] = c;
                            }
                            this.len += 1;
                        }
                    } else {
                        @memcpy(this.pooled[this.len..][0..characters.len], characters);
                        this.len += characters.len;
                    }
                } else {
                    switch (opts.inputChildType(@TypeOf(characters))) {
                        u8 => {
                            const converted = bun.strings.convertUTF8toUTF16InBuffer(this.pooled[this.len..], characters);
                            if (comptime Environment.isWindows) {
                                for (this.pooled[this.len..][0..converted.len], 0..) |c, off| {
                                    if (native_path_type.isSep(u16, c))
                                        this.pooled[this.len + off] = std.fs.path.sep;
                                }
                            }
                            this.len += converted.len;
                        },
                        u16 => {
                            const converted = bun.strings.convertUTF16toUTF8InBuffer(this.pooled[this.len..], characters) catch unreachable;
                            if (comptime Environment.isWindows) {
                                for (this.pooled[this.len..][0..converted.len], 0..) |c, off| {
                                    if (native_path_type.isSep(u8, c))
                                        this.pooled[this.len + off] = std.fs.path.sep;
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
            bun.debugAssert(isInputAbsolute(top_level_dir));

            var this = init();
            this._buf.append(trimInput(.abs, top_level_dir), false);
            return this;
        }

        pub fn fromLongPath(input: anytype) @This() {
            // TODO: Apply extended-path prefixes at Windows syscall boundaries; blindly prefixing here mishandles UNC and device paths.
            switch (comptime @TypeOf(input)) {
                []u8, []const u8, [:0]u8, [:0]const u8 => {},
                []u16, []const u16, [:0]u16, [:0]const u16 => {},
                else => @compileError("unsupported type: " ++ @typeName(@TypeOf(input))),
            }
            const trimmed = trimInput(if (isInputAbsolute(input)) .abs else .rel, input);

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
            const trimmed = trimInput(if (isInputAbsolute(input)) .abs else .rel, input);

            var this = init();
            this._buf.append(trimmed, false);
            return this;
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
            const trimmed = trimInput(if (isInputAbsolute(this.slice())) .abs else .rel, this.slice());
            this._buf.setLength(trimmed.len);
        }

        pub fn len(this: *const @This()) usize {
            return this._buf.len;
        }

        pub fn clear(this: *@This()) void {
            this._buf.setLength(0);
        }

        pub fn rootLen(input: anytype) ?usize {
            if (!isInputAbsolute(input)) return null;

            return switch (comptime native_path_type) {
                .windows => std.fs.path.parsePathWindows(opts.inputChildType(@TypeOf(input)), input).root.len,
                .posix => 1,
                .uefi => unreachable,
            };
        }

        const TrimInputKind = enum {
            abs,
            rel,
        };

        fn trimInput(kind: TrimInputKind, input: anytype) []const opts.inputChildType(@TypeOf(input)) {
            const T = opts.inputChildType(@TypeOf(input));
            var trimmed: []const T = input[0..];

            switch (kind) {
                .abs => {
                    const root_len = rootLen(input) orelse 0;
                    while (trimmed.len > root_len and native_path_type.isSep(T, trimmed[trimmed.len - 1])) {
                        trimmed = trimmed[0 .. trimmed.len - 1];
                    }
                },
                .rel => {
                    if (trimmed.len > 1 and trimmed[0] == '.' and native_path_type.isSep(T, trimmed[1])) {
                        trimmed = trimmed[2..];
                    }
                    while (trimmed.len > 0 and native_path_type.isSep(T, trimmed[0])) {
                        trimmed = trimmed[1..];
                    }

                    while (trimmed.len > 0 and native_path_type.isSep(T, trimmed[trimmed.len - 1])) {
                        trimmed = trimmed[0 .. trimmed.len - 1];
                    }
                },
            }

            return trimmed;
        }

        fn isInputAbsolute(input: anytype) bool {
            const T = opts.inputChildType(@TypeOf(input));
            return switch (comptime native_path_type) {
                .windows => switch (T) {
                    u8 => std.fs.path.isAbsoluteWindows(input),
                    u16 => std.fs.path.isAbsoluteWindowsWtf16(input),
                    else => @compileError("unexpected character type"),
                },
                .posix => input.len > 0 and std.fs.path.PathType.posix.isSep(T, input[0]),
                .uefi => unreachable,
            };
        }

        pub fn append(this: *@This(), input: anytype) void {
            const needs_sep = this.len() > 0 and !native_path_type.isSep(opts.pathUnit(), this.slice()[this.len() - 1]);
            const input_is_absolute = isInputAbsolute(input);

            if (comptime Environment.isDebug) {
                if (this.len() > 0) bun.debugAssert(!input_is_absolute);
            }

            const trimmed = trimInput(if (this.len() == 0 and input_is_absolute) .abs else .rel, input);
            if (trimmed.len == 0) return;
            this._buf.append(trimmed, needs_sep);
        }

        pub fn appendFmt(this: *@This(), comptime fmt: []const u8, args: anytype) void {
            const temp = bun.path_buffer_pool.get();
            defer bun.path_buffer_pool.put(temp);
            const input = std.mem.print(temp, fmt, args) catch unreachable;

            this.append(input);
        }

        pub fn undo(this: *@This(), n_components: usize) void {
            const min_len = rootLen(this.slice()) orelse 0;

            var it = std.fs.path.ComponentIterator(native_path_type, opts.pathUnit()).init(this.slice());
            _ = it.last() orelse {
                this._buf.setLength(min_len);
                return;
            };

            for (0..n_components) |_| {
                const parent = it.previous() orelse {
                    this._buf.setLength(min_len);
                    return;
                };
                this._buf.setLength(parent.path.len);
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
const PathBuffer = bun.PathBuffer;
const WPathBuffer = bun.WPathBuffer;
const native_path_type: std.fs.path.PathType = if (Environment.isWindows) .windows else .posix;
