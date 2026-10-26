pub const PathLike = union(enum) {
    string: bun.PathString,
    slice_with_underlying_string: bun.SliceWithUnderlyingString,
    threadsafe_string: bun.SliceWithUnderlyingString,
    encoded_slice: bun.String.Slice,
    bindgen_path: BindgenPath,

    pub const BindgenPath = struct {
        bytes: [:0]u8,

        pub fn init(bytes: [:0]u8) BindgenPath {
            return .{ .bytes = bytes };
        }

        fn deinit(this: *const BindgenPath) void {
            bun.default_allocator.free(this.bytes);
        }

        fn slice(this: *const BindgenPath) []const u8 {
            return this.bytes;
        }
    };

    pub const NativeStringResult = union(enum) {
        path: NativeStringPath,
        too_long: bun.SliceWithUnderlyingString,
        contains_null: bun.SliceWithUnderlyingString,
    };

    pub const NativeStringPath = struct {
        slice: bun.SliceWithUnderlyingString,
        report_extra_memory: bool,
    };

    pub fn fromNativeString(value: *bun.String, allocator: std.mem.Allocator) bun.OOM!NativeStringResult {
        const sliced = try value.toSlice(allocator);
        const bytes = sliced.slice();
        if (bytes.len > bun.MAX_PATH_BYTES) return .{ .too_long = sliced };
        if (bun.strings.indexOfChar(bytes, 0) != null) return .{ .contains_null = sliced };
        return .{ .path = .{
            .slice = sliced,
            .report_extra_memory = sliced.utf8.storage == .allocated,
        } };
    }

    pub fn fromBindingView(view: anytype) bun.OOM!PathLike {
        const bytes = try bun.default_allocator.allocSentinel(u8, view.length(), 0);
        errdefer bun.default_allocator.free(bytes);
        bun.assert(view.read(0, bytes));
        return .{ .bindgen_path = .init(bytes) };
    }

    pub fn estimatedSize(this: *const PathLike) usize {
        return switch (this.*) {
            .string => this.string.estimatedSize(),
            .threadsafe_string, .slice_with_underlying_string => 0,
            .encoded_slice => this.encoded_slice.slice().len,
            .bindgen_path => this.bindgen_path.bytes.len,
        };
    }

    pub fn deinit(this: *const PathLike) void {
        switch (this.*) {
            .string => {},
            inline else => |*str| {
                str.deinit();
            },
        }
    }

    pub fn toThreadSafe(this: *PathLike) bun.OOM!void {
        if (this.* == .bindgen_path) return;
        const bytes = try bun.default_allocator.dupeSentinel(u8, this.slice(), 0);
        this.deinit();
        this.* = .{ .bindgen_path = .init(bytes) };
    }

    pub inline fn slice(this: PathLike) string {
        return switch (this) {
            inline else => |*str| str.slice(),
        };
    }

    pub fn sliceZWithForceCopy(this: PathLike, buf: *bun.PathBuffer, comptime force: bool) if (force) [:0]u8 else [:0]const u8 {
        const sliced = this.slice();

        if (comptime !force) {
            switch (this) {
                .bindgen_path => |path| return path.bytes,
                else => {},
            }
        }

        if (Environment.isWindows) {
            if (std.fs.path.isAbsolute(sliced)) {
                const parsed = std.fs.path.parsePathWindows(u8, sliced);
                if (parsed.kind == .drive_absolute) {
                    // Add the long path syntax while normalizing directly into
                    // the destination buffer.
                    buf[0..4].* = bun.windows.long_path_prefix_u8;
                    var fba = std.heap.FixedBufferAllocator.init(buf[4 .. buf.len - 1]);
                    const normalized = std.fs.path.resolveWindows(fba.allocator(), &.{sliced}) catch @panic("normalized path exceeds buffer");
                    buf[4 + normalized.len] = 0;
                    return buf[0 .. 4 + normalized.len :0];
                }
                if (parsed.kind == .rooted) {
                    var cwd_buf: bun.PathBuffer = undefined;
                    const cwd = bun.getcwd(&cwd_buf) catch @panic("Error while resolving path.");
                    return bun.path.joinAbsStringBufZ(cwd, buf, &.{sliced}, .windows);
                }
            }
        }

        if (sliced.len == 0) {
            if (comptime !force) return "";

            buf[0] = 0;
            return buf[0..0 :0];
        }

        if (comptime !force) {
            if (sliced[sliced.len - 1] == 0) {
                return sliced[0 .. sliced.len - 1 :0];
            }
        }

        if (sliced.len >= buf.len) {
            bun.Output.debugWarn("path too long: {d} bytes exceeds PathBuffer capacity of {d}\n", .{ sliced.len, buf.len });
            if (comptime !force) return "";

            buf[0] = 0;
            return buf[0..0 :0];
        }

        @memcpy(buf[0..sliced.len], sliced);
        buf[sliced.len] = 0;
        return buf[0..sliced.len :0];
    }

    pub fn sliceZ(this: PathLike, buf: *bun.PathBuffer) callconv(bun.callconv_inline) [:0]const u8 {
        return sliceZWithForceCopy(this, buf, false);
    }

    pub fn sliceW(this: PathLike, buf: *bun.WPathBuffer) callconv(bun.callconv_inline) [:0]const u16 {
        return strings.toWPath(buf, this.slice());
    }

    pub fn osPath(this: PathLike, buf: *bun.OSPathBuffer) callconv(bun.callconv_inline) bun.OSPathSliceZ {
        if (comptime Environment.isWindows) {
            return sliceW(this, buf);
        }

        return sliceZWithForceCopy(this, buf, false);
    }

    pub fn osPathIntoBuf(this: PathLike, buf: *bun.OSPathBuffer) bun.OSPathSliceZ {
        if (comptime Environment.isWindows) {
            return sliceW(this, buf);
        }

        return sliceZWithForceCopy(this, buf, true);
    }

    pub fn osPathKernel32(this: PathLike, buf: *bun.PathBuffer) callconv(bun.callconv_inline) bun.OSPathSliceZ {
        if (comptime Environment.isWindows) {
            const s = this.slice();
            const b = bun.path_buffer_pool.get();
            defer bun.path_buffer_pool.put(b);
            const windows_path = std.fs.path.PathType.windows;
            // Device and NT object paths must not normalize the dot in their prefix.
            if (s.len >= 4 and windows_path.isSep(u8, s[0]) and windows_path.isSep(u8, s[1]) and (s[2] == '.' or s[2] == '?') and windows_path.isSep(u8, s[3])) {
                return strings.toKernel32Path(@alignCast(std.mem.bytesAsSlice(u16, buf)), s);
            }
            if (std.fs.path.parsePathWindows(u8, s).kind == .rooted) {
                const cwd = bun.getcwd(buf) catch @panic("Error while resolving path.");
                const normal = bun.path.joinAbsStringBuf(cwd, b, &.{s}, .windows);
                return strings.toKernel32Path(@alignCast(std.mem.bytesAsSlice(u16, buf)), normal);
            }
            var normal_fba = std.heap.FixedBufferAllocator.init(b);
            const normal = std.fs.path.resolveWindows(normal_fba.allocator(), &.{s}) catch @panic("normalized path exceeds buffer");
            return strings.toKernel32Path(@alignCast(std.mem.bytesAsSlice(u16, buf)), normal);
        }

        return sliceZWithForceCopy(this, buf, false);
    }
};

pub const PathOrFileDescriptor = union(Tag) {
    fd: bun.FD,
    path: PathLike,

    pub const Tag = enum { fd, path };
    pub const SerializeTag = enum(u8) { fd, path };

    pub fn fromBinding(value: anytype) bun.OOM!PathOrFileDescriptor {
        return switch (value) {
            .fd => |fd| .{ .fd = bun.FD.fromUV(fd) },
            .path => |path| .{ .path = try PathLike.fromBindingView(path) },
        };
    }

    pub fn deinit(this: PathOrFileDescriptor) void {
        if (this == .path) {
            this.path.deinit();
        }
    }

    pub fn estimatedSize(this: *const PathOrFileDescriptor) usize {
        return switch (this.*) {
            .path => this.path.estimatedSize(),
            .fd => 0,
        };
    }

    pub fn toThreadSafe(this: *PathOrFileDescriptor) bun.OOM!void {
        if (this.* == .path) {
            try this.path.toThreadSafe();
        }
    }

    pub fn hash(this: PathOrFileDescriptor) u64 {
        return switch (this) {
            .path => bun.hash(this.path.slice()),
            .fd => bun.hash(std.mem.asBytes(&this.fd)),
        };
    }

    pub fn format(this: PathOrFileDescriptor, writer: *std.Io.Writer) !void {
        switch (this) {
            .path => |p| try writer.writeAll(p.slice()),
            .fd => |fd| try writer.print("{}", .{fd}),
        }
    }
};

const string = []const u8;

const std = @import("std");
const bun = @import("bun");
const Environment = bun.Environment;
const strings = bun.strings;
