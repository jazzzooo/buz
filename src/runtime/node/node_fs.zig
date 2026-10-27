// This file contains the underlying implementation for sync & async functions
// for interacting with the filesystem from JavaScript.
// The top-level functions assume the arguments are already validated
pub const constants = @import("./node_fs_constant.zig");

pub const default_permission = NodeFSCore.default_permission;

// All async FS functions are run in a thread pool, but some implementations may
// decide to do something slightly different. For example, reading a file has
// an extra stack buffer in the async case.
pub const Flavor = enum { sync, async };

// TODO: to improve performance for all of these
// The tagged unions for each type should become regular unions
// and the tags should be passed in as comptime arguments to the functions performing the syscalls
// This would reduce stack size, at the cost of instruction cache misses
pub const Arguments = struct {
    pub const ValidationError = union(enum) {
        invalid_argument_value: []const u8,
        out_of_range: struct {
            value: union(enum) {
                float: f64,
                signed: i64,
                unsigned: u64,
            },
            options: bun.fmt.OutOfRangeOptions,
        },
    };

    pub fn Validated(comptime T: type) type {
        return union(enum) {
            value: T,
            validation_error: ValidationError,
        };
    }

    pub const Rename = struct {
        old_path: PathLike,
        new_path: PathLike,

        pub fn deinit(this: @This()) void {
            this.old_path.deinit();
            this.new_path.deinit();
        }

        pub fn toThreadSafe(this: *@This()) bun.OOM!void {
            try this.old_path.toThreadSafe();
            try this.new_path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Rename {
            const old_path = try PathLike.fromBindingView(args.oldPath);
            errdefer old_path.deinit();
            return .{
                .old_path = old_path,
                .new_path = try PathLike.fromBindingView(args.newPath),
            };
        }
    };

    pub const Truncate = struct {
        path: PathLike,
        len: u63 = 0,

        pub fn deinit(this: @This()) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *@This()) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Truncate {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .len = @intCast(@max(args.len, 0)),
            };
        }
    };

    fn VectorIO(comptime writable: bool) type {
        const OwnedBufferLease = if (writable) OwnedReadVectorBufferLease else OwnedWriteVectorBufferLease;
        const OwnedBuffers = bun.bindgen.OwnedNativeSlice(OwnedBufferLease, .vm);
        return struct {
            fd: FD,
            buffers: OwnedBuffers,
            iovecs: []bun.PlatformIOVec,
            position: ?i64 = null,

            pub const Async = struct {
                fd: FD,
                storage: []u8,
                iovecs: []bun.PlatformIOVec,
                position: ?i64,

                pub fn execute(node_fs: *NodeFS, args: Async, _: Flavor) Maybe(if (writable) Return.Readv else Return.Writev) {
                    return if (writable) node_fs.readvImpl(args) else node_fs.writevImpl(args);
                }

                pub fn toThreadSafe(_: *Async) bun.OOM!void {}

                pub fn deinit(this: *const Async) void {
                    bun.default_allocator.free(this.iovecs);
                    bun.default_allocator.free(this.storage);
                }
            };

            pub const Attachment = if (writable) struct {
                buffers: OwnedBuffers,

                pub fn deliver(this: *@This(), work: *const Async, count: usize) void {
                    if (count > work.storage.len) @panic("filesystem vector read exceeded its native storage");
                    var remaining = count;
                    var offset: usize = 0;
                    for (this.buffers.values) |*buffer| {
                        if (remaining == 0) break;
                        const length = buffer.length();
                        const written = @min(length, remaining);
                        if (!buffer.write(0, work.storage[offset..][0..written]))
                            @panic("filesystem vector read exceeded its destination");
                        remaining -= written;
                        offset += length;
                    }
                    if (remaining != 0) @panic("filesystem vector read lost its destination");
                }

                pub fn deinit(this: *@This()) void {
                    this.buffers.deinit();
                }
            } else void;

            pub fn prepareAsync(this: *@This()) bun.OOM!struct { args: Async, attachment: Attachment } {
                var total: usize = 0;
                for (this.buffers.values) |*buffer| total = std.math.add(usize, total, buffer.length()) catch return error.OutOfMemory;
                const storage = try bun.default_allocator.alloc(u8, total);
                var offset: usize = 0;
                var iovec_index: usize = 0;
                for (this.buffers.values) |*buffer| {
                    const length = buffer.length();
                    if (length == 0) continue;
                    const bytes = storage[offset..][0..length];
                    if (comptime !writable) {
                        if (!buffer.read(0, bytes)) @panic("filesystem vector write lost its source");
                    }
                    this.iovecs[iovec_index] = bun.platformIOVecCreate(bytes);
                    iovec_index += 1;
                    offset += length;
                }
                const work: Async = .{ .fd = this.fd, .storage = storage, .iovecs = this.iovecs, .position = this.position };
                const attachment: Attachment = if (writable) .{ .buffers = this.buffers } else {};
                if (comptime !writable) this.buffers.deinit();
                this.buffers = .empty;
                this.iovecs = &.{};
                return .{ .args = work, .attachment = attachment };
            }

            pub fn deinit(this: *@This()) void {
                this.buffers.deinit();
                const iovecs = this.iovecs;
                this.iovecs = &.{};
                bun.default_allocator.free(iovecs);
            }

            pub fn fromBindgen(args: anytype) bun.JSError!@This() {
                var owned_buffers = try OwnedBuffers.Builder.init(args.buffers.len());
                errdefer owned_buffers.deinit();
                for (0..args.buffers.len()) |index| {
                    owned_buffers.appendOwned(try args.buffers.at(index).?.toOwned());
                }
                const buffers = owned_buffers.slice();

                var iovec_count: usize = 0;
                for (buffers) |*buffer| {
                    if (buffer.length() > 0) iovec_count += 1;
                }

                const iovecs = try bun.default_allocator.alloc(bun.PlatformIOVec, iovec_count);
                errdefer if (iovecs.len > 0) bun.default_allocator.free(iovecs);
                var iovec_index: usize = 0;
                for (buffers) |*buffer| {
                    if (buffer.length() == 0) continue;
                    const bytes = if (writable)
                        buffer.unsafeMutPtr("the owned mutable leases remain alive until filesystem I/O completes")
                    else
                        buffer.unsafePtr("the owned leases remain alive until filesystem I/O completes");
                    iovecs[iovec_index] = bun.platformIOVecCreate(bytes);
                    iovec_index += 1;
                }

                return .{
                    .fd = .fromUV(args.fd),
                    .buffers = owned_buffers.finish(),
                    .iovecs = iovecs,
                    .position = if (args.position orelse null) |integer| @intCast(integer) else null,
                };
            }
        };
    }

    pub const Writev = VectorIO(false);
    pub const Readv = VectorIO(true);

    pub const FTruncate = struct {
        fd: FD,
        len: isize = 0,

        pub fn deinit(this: @This()) void {
            _ = this;
        }

        pub fn toThreadSafe(this: *const @This()) bun.OOM!void {
            _ = this;
        }

        pub fn fromBindgen(args: anytype) bun.JSError!FTruncate {
            return .{
                .fd = .fromUV(args.fd),
                .len = @intCast(@max(args.len, 0)),
            };
        }
    };

    pub const Chown = struct {
        path: PathLike,
        uid: uid_t = 0,
        gid: gid_t = 0,

        pub fn deinit(this: @This()) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *@This()) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Chown {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .uid = wrapTo(uid_t, args.uid),
                .gid = wrapTo(gid_t, args.gid),
            };
        }
    };

    pub const Fchown = struct {
        fd: FD,
        uid: uid_t,
        gid: gid_t,

        pub fn deinit(_: @This()) void {}

        pub fn toThreadSafe(_: *const @This()) bun.OOM!void {}

        pub fn fromBindgen(args: anytype) bun.JSError!Fchown {
            return .{
                .fd = .fromUV(args.fd),
                .uid = wrapTo(uid_t, args.uid),
                .gid = wrapTo(gid_t, args.gid),
            };
        }
    };

    fn wrapTo(T: type, in: i64) T {
        comptime bun.assert(@typeInfo(T).int.signedness == .unsigned);
        return if (in == -1) std.math.maxInt(T) else @intCast(in);
    }

    pub const LChown = Chown;

    pub const Lutimes = struct {
        path: PathLike,
        atime: TimeLike,
        mtime: TimeLike,

        pub fn deinit(this: @This()) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *@This()) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Lutimes {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .atime = TimeLikeModule.fromBindgen(args.atime),
                .mtime = TimeLikeModule.fromBindgen(args.mtime),
            };
        }
    };

    pub const Chmod = struct {
        path: PathLike,
        mode: Mode = 0x777,

        pub fn deinit(this: @This()) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *@This()) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Chmod {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .mode = @truncate(args.mode),
            };
        }
    };

    pub const FChmod = struct {
        fd: FD,
        mode: Mode = 0x777,

        pub fn deinit(_: *const @This()) void {}

        pub fn toThreadSafe(_: *const @This()) bun.OOM!void {}

        pub fn fromBindgen(args: anytype) bun.JSError!FChmod {
            return .{
                .fd = .fromUV(args.fd),
                .mode = @truncate(args.mode),
            };
        }
    };

    pub const LCHmod = Chmod;

    pub const StatFS = struct {
        path: PathLike,
        big_int: bool = false,

        pub fn deinit(this: Arguments.StatFS) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Arguments.StatFS) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Arguments.StatFS {
            const big_int = if (args.options) |options| options.big_int orelse false else false;
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .big_int = big_int,
            };
        }
    };

    pub const Stat = struct {
        path: PathLike,
        big_int: bool = false,
        throw_if_no_entry: bool = true,

        pub fn deinit(this: Stat) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Stat) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Stat {
            var throw_if_no_entry = true;
            const big_int = if (args.options) |options| parsed: {
                throw_if_no_entry = options.throw_if_no_entry orelse true;
                break :parsed options.big_int orelse false;
            } else false;
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .big_int = big_int,
                .throw_if_no_entry = throw_if_no_entry,
            };
        }
    };

    pub const Fstat = struct {
        fd: FD,
        big_int: bool = false,

        pub fn deinit(_: @This()) void {}

        pub fn toThreadSafe(_: *@This()) bun.OOM!void {}

        pub fn fromBindgen(args: anytype) bun.JSError!Fstat {
            const big_int = if (args.options) |options| options.big_int orelse false else false;
            return .{ .fd = .fromUV(args.fd), .big_int = big_int };
        }
    };

    pub const Lstat = Stat;

    pub const Link = struct {
        old_path: PathLike,
        new_path: PathLike,

        pub fn deinit(this: Link) void {
            this.old_path.deinit();
            this.new_path.deinit();
        }

        pub fn toThreadSafe(this: *Link) bun.OOM!void {
            try this.old_path.toThreadSafe();
            try this.new_path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Link {
            const old_path = try PathLike.fromBindingView(args.existingPath);
            errdefer old_path.deinit();
            return .{
                .old_path = old_path,
                .new_path = try PathLike.fromBindingView(args.newPath),
            };
        }
    };

    pub const Symlink = struct {
        /// Where the symbolic link is targetting.
        target_path: PathLike,
        /// The path to create the symbolic link at.
        new_path: PathLike,
        /// Windows has multiple link types. By default, only junctions can be created by non-admin.
        link_type: if (Environment.isWindows) LinkType else void,

        const LinkType = enum {
            unspecified,
            file,
            dir,
            junction,
        };

        pub fn deinit(this: Symlink) void {
            this.target_path.deinit();
            this.new_path.deinit();
        }

        pub fn toThreadSafe(this: *@This()) bun.OOM!void {
            try this.target_path.toThreadSafe();
            try this.new_path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Symlink {
            const target_path = try PathLike.fromBindingView(args.target);
            errdefer target_path.deinit();

            return .{
                .target_path = target_path,
                .new_path = try PathLike.fromBindingView(args.path),
                .link_type = if (Environment.isWindows)
                    if (args.type) |link_type| switch (link_type) {
                        .file => .file,
                        .dir => .dir,
                        .junction => .junction,
                    } else .unspecified
                else {},
            };
        }
    };

    fn encodingFromBindgen(options: anytype) Encoding {
        const encoding = if (options) |value| switch (value) {
            .encoding => |encoding| encoding,
            .options => |encoding_options| encoding_options.encoding orelse return .utf8,
        } else return .utf8;

        return encodingFromBindgenValue(encoding);
    }

    fn encodingFromBindgenValue(encoding: anytype) Encoding {
        if (comptime @hasField(@TypeOf(encoding), "buffer")) {
            return switch (encoding) {
                .utf8 => .utf8,
                .utf16le => .utf16le,
                .latin1 => .latin1,
                .ascii => .ascii,
                .base64 => .base64,
                .base64url => .base64url,
                .hex => .hex,
                .buffer => .buffer,
            };
        }
        return switch (encoding) {
            .utf8 => .utf8,
            .utf16le => .utf16le,
            .latin1 => .latin1,
            .ascii => .ascii,
            .base64 => .base64,
            .base64url => .base64url,
            .hex => .hex,
        };
    }

    fn fileSystemFlagsFromBindgen(value: anytype, default: FileSystemFlags) FileSystemFlags {
        const selected = value orelse return default;
        return switch (selected) {
            .number => |flags| if (Environment.isWindows)
                @fromBackingInt(windows.libuv.O.toBunO(flags))
            else
                @fromBackingInt(flags),
            .name => |name| @fromBackingInt(switch (name) {
                .r => bun.O.RDONLY,
                .rs => bun.O.RDONLY | bun.O.SYNC,
                .r_plus => bun.O.RDWR,
                .rs_plus => bun.O.RDWR | bun.O.SYNC,
                .w => bun.O.TRUNC | bun.O.CREAT | bun.O.WRONLY,
                .wx => bun.O.TRUNC | bun.O.CREAT | bun.O.WRONLY | bun.O.EXCL,
                .w_plus => bun.O.TRUNC | bun.O.CREAT | bun.O.RDWR,
                .wx_plus => bun.O.TRUNC | bun.O.CREAT | bun.O.RDWR | bun.O.EXCL,
                .a => bun.O.APPEND | bun.O.CREAT | bun.O.WRONLY,
                .ax => bun.O.APPEND | bun.O.CREAT | bun.O.WRONLY | bun.O.EXCL,
                .as => bun.O.APPEND | bun.O.CREAT | bun.O.WRONLY | bun.O.SYNC,
                .a_plus => bun.O.APPEND | bun.O.CREAT | bun.O.RDWR,
                .ax_plus => bun.O.APPEND | bun.O.CREAT | bun.O.RDWR | bun.O.EXCL,
                .as_plus => bun.O.APPEND | bun.O.CREAT | bun.O.RDWR | bun.O.SYNC,
            }),
        };
    }

    pub const Readlink = struct {
        path: PathLike,
        encoding: Encoding = Encoding.utf8,

        pub fn deinit(this: Readlink) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Readlink) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Readlink {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .encoding = encodingFromBindgen(args.options),
            };
        }
    };

    pub const Realpath = Readlink;

    pub const Unlink = struct {
        path: PathLike,

        pub fn deinit(this: Unlink) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Unlink) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Unlink {
            return .{ .path = try PathLike.fromBindingView(args.path) };
        }
    };

    pub const Rm = RmDir;

    pub const RmDir = struct {
        path: PathLike,

        force: bool = false,

        max_retries: u32 = 0,
        recursive: bool = false,
        retry_delay: c_uint = 100,

        pub fn toThreadSafe(this: *RmDir) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn deinit(this: RmDir) void {
            this.path.deinit();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!RmDir {
            const options = args.options orelse @as(@TypeOf(args.options.?), .{
                .force = false,
                .max_retries = 0,
                .recursive = false,
                .retry_delay = 100,
            });
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .force = options.force,
                .max_retries = options.max_retries,
                .recursive = options.recursive,
                .retry_delay = options.retry_delay,
            };
        }
    };

    pub const Rmdir = struct {
        path: PathLike,

        pub fn toThreadSafe(this: *Rmdir) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn deinit(this: Rmdir) void {
            this.path.deinit();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Rmdir {
            return .{ .path = try PathLike.fromBindingView(args.path) };
        }
    };

    /// https://github.com/nodejs/node/blob/master/lib/fs.js#L1285
    pub const Mkdir = struct {
        path: PathLike,
        /// Indicates whether parent folders should be created.
        /// If a folder was created, the path to the first created folder will be returned.
        /// @default false
        recursive: bool = false,
        /// A file mode. If a string is passed, it is parsed as an octal integer. If not specified
        mode: Mode = DefaultMode,
        /// If set to true, the return value is never set to a string
        always_return_none: bool = false,

        pub const DefaultMode = NodeFSCore.Mkdir.DefaultMode;

        pub fn deinit(this: Mkdir) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Mkdir) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Mkdir {
            var recursive = false;
            var mode: Mode = DefaultMode;
            if (args.options) |options| switch (options) {
                .mode => |value| mode = @truncate(value),
                .options => |value| {
                    recursive = value.recursive;
                    mode = @truncate(value.mode);
                },
                .ignored => {},
            };

            return .{
                .path = try PathLike.fromBindingView(args.path),
                .recursive = recursive,
                .mode = mode,
            };
        }
    };

    pub const MkdirTemp = struct {
        prefix: PathLike = .{ .string = bun.PathString.empty },
        encoding: Encoding = .utf8,

        pub fn deinit(this: MkdirTemp) void {
            this.prefix.deinit();
        }

        pub fn toThreadSafe(this: *MkdirTemp) bun.OOM!void {
            try this.prefix.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!MkdirTemp {
            return .{
                .prefix = try PathLike.fromBindingView(args.prefix),
                .encoding = encodingFromBindgen(args.options),
            };
        }
    };

    pub const Readdir = struct {
        path: PathLike,
        encoding: Encoding = .utf8,
        with_file_types: bool = false,
        recursive: bool = false,

        pub fn deinit(this: Readdir) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Readdir) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn tag(this: *const Readdir) Return.Readdir.Tag {
            return switch (this.encoding) {
                .buffer => .buffers,
                else => if (this.with_file_types)
                    .with_file_types
                else
                    .files,
            };
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Readdir {
            var encoding: Encoding = .utf8;
            var with_file_types = false;
            var recursive = false;
            if (args.options) |options| switch (options) {
                .encoding => |value| encoding = encodingFromBindgenValue(value),
                .options => |value| {
                    if (value.encoding) |selected| encoding = encodingFromBindgenValue(selected);
                    with_file_types = value.with_file_types;
                    recursive = value.recursive orelse false;
                },
            };
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .encoding = encoding,
                .with_file_types = with_file_types,
                .recursive = recursive,
            };
        }
    };

    pub const Close = struct {
        fd: FD,

        pub fn deinit(_: Close) void {}
        pub fn toThreadSafe(_: Close) bun.OOM!void {}

        pub fn fromBindgen(args: anytype) bun.JSError!Close {
            return .{ .fd = .fromUV(args.fd) };
        }
    };

    pub const Open = struct {
        path: PathLike,
        flags: FileSystemFlags = .r,
        mode: Mode = default_permission,

        pub fn deinit(this: Open) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Open) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Open {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .flags = fileSystemFlagsFromBindgen(args.flags, .r),
                .mode = @truncate(args.mode orelse default_permission),
            };
        }
    };

    /// Change the file system timestamps of the object referenced by `path`.
    ///
    /// The `atime` and `mtime` arguments follow these rules:
    ///
    /// * Values can be either numbers representing Unix epoch time in seconds,`Date`s, or a numeric string like `'123456789.0'`.
    /// * If the value can not be converted to a number, or is `NaN`, `Infinity` or`-Infinity`, an `Error` will be thrown.
    /// @since v0.4.2
    pub const Utimes = Lutimes;

    pub const Futimes = struct {
        fd: FD,
        atime: TimeLike,
        mtime: TimeLike,

        pub fn deinit(_: Futimes) void {}

        pub fn toThreadSafe(self: *const @This()) bun.OOM!void {
            _ = self;
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Futimes {
            return .{
                .fd = .fromUV(args.fd),
                .atime = TimeLikeModule.fromBindgen(args.atime),
                .mtime = TimeLikeModule.fromBindgen(args.mtime),
            };
        }
    };

    /// Write `buffer` to the file specified by `fd`. If `buffer` is a normal object, it
    /// must have an own `toString` function property.
    ///
    /// `offset` determines the part of the buffer to be written, and `length` is
    /// an integer specifying the number of bytes to write.
    ///
    /// `position` refers to the offset from the beginning of the file where this data
    /// should be written. An absent or negative position uses the current file position.
    /// See [`pwrite(2)`](http://man7.org/linux/man-pages/man2/pwrite.2.html).
    ///
    /// The callback will be given three arguments `(err, bytesWritten, buffer)` where`bytesWritten` specifies how many _bytes_ were written from `buffer`.
    ///
    /// If this method is invoked as its `util.promisify()` ed version, it returns
    /// a promise for an `Object` with `bytesWritten` and `buffer` properties.
    ///
    /// It is unsafe to use `fs.write()` multiple times on the same file without waiting
    /// for the callback. For this scenario, {@link createWriteStream} is
    /// recommended.
    ///
    /// On Linux, positional writes don't work when the file is opened in append mode.
    /// The kernel ignores the position argument and always appends the data to
    /// the end of the file.
    /// @since v0.0.2
    pub const Write = struct {
        fd: FD,
        buffer: StringOrBuffer,
        offset: u64 = 0,
        length: u64 = std.math.maxInt(u64),
        position: ?ReadPosition = null,
        encoding: Encoding = Encoding.buffer,

        pub fn deinit(this: *const @This()) void {
            this.buffer.deinit();
        }

        pub fn toThreadSafe(self: *@This()) bun.OOM!void {
            try self.buffer.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.OOM!Validated(Write) {
            return switch (args) {
                .buffer => |values| fromBindgenBuffer(values),
                .string_position => |values| .{ .value = try fromBindgenString(
                    values,
                    writePosition(values.position),
                    writeStringEncoding(values.encoding),
                ) },
                .string_other => |values| .{ .value = try fromBindgenString(
                    values,
                    null,
                    writeStringEncoding(values.positionOrEncoding),
                ) },
            };
        }

        fn fromBindgenBuffer(values: anytype) bun.OOM!Validated(Write) {
            const offset = if (values.offset) |input| switch (input) {
                .number => |value| value,
                .callable => 0,
            } else 0;
            const buffer_length = values.buffer.length();
            const max_offset = @min(buffer_length, std.math.maxInt(i64));
            if (offset > max_offset) {
                return .{ .validation_error = .{ .out_of_range = .{
                    .value = .{ .unsigned = offset },
                    .options = .{ .field_name = "offset", .max = @intCast(max_offset) },
                } } };
            }

            var length: u64 = std.math.maxInt(u64);
            const parsed_length = if (values.length) |length_input| switch (length_input) {
                .value => |parsed| parsed,
                .ignored => null,
            } else null;
            if (parsed_length) |value| {
                const max_length = @min(buffer_length - offset, std.math.maxInt(i32));
                if (value > max_length or value < 0) {
                    return .{ .validation_error = .{ .out_of_range = .{
                        .value = .{ .signed = value },
                        .options = .{ .field_name = "length", .min = 0, .max = @intCast(max_length) },
                    } } };
                }
                length = @intCast(value);
            }

            return .{ .value = .{
                .fd = .fromUV(values.fd),
                .buffer = try StringOrBuffer.fromBindgenBuffer(values.buffer),
                .offset = offset,
                .length = length,
                .position = if (values.position) |position| writePosition(position) else null,
                .encoding = .buffer,
            } };
        }

        fn fromBindgenString(values: anytype, position: ?ReadPosition, encoding: Encoding) bun.OOM!Write {
            return .{
                .fd = .fromUV(values.fd),
                .buffer = try StringOrBuffer.fromBindgenString(values.data, encoding),
                .position = position,
                .encoding = encoding,
            };
        }

        fn writePosition(input: anytype) ?ReadPosition {
            return switch (input) {
                .value => |position| if (position >= 0) position else null,
                .ignored => null,
            };
        }

        fn writeStringEncoding(value: anytype) Encoding {
            const selected = value orelse return .utf8;
            return switch (selected) {
                .encoding => |encoding| encodingFromBindgenValue(encoding),
                .ignored => .utf8,
            };
        }
    };

    pub const Read = struct {
        fd: FD,
        buffer: OwnedReadBufferLease,
        offset: u64,
        length: u64,
        position: ?ReadPosition = null,

        pub const Async = struct {
            fd: FD,
            output: []u8,
            position: ?ReadPosition,

            pub fn bytes(this: *const Async) []u8 {
                return this.output;
            }

            pub fn execute(node_fs: *NodeFS, args: Async, _: Flavor) Maybe(Return.Read) {
                return node_fs.readImpl(args);
            }

            pub fn toThreadSafe(_: *Async) bun.OOM!void {}

            pub fn deinit(this: *const Async) void {
                bun.default_allocator.free(this.output);
            }
        };

        pub const Attachment = struct {
            buffer: OwnedReadBufferLease,
            offset: usize,

            pub fn deliver(this: *Attachment, work: *const Async, count: usize) void {
                if (count > work.output.len or !this.buffer.write(this.offset, work.output[0..count]))
                    @panic("filesystem read returned bytes outside its destination");
            }

            pub fn deinit(this: *Attachment) void {
                this.buffer.deinit();
            }
        };

        pub fn prepareAsync(this: *Read) bun.OOM!struct { args: Async, attachment: Attachment } {
            const output = try bun.default_allocator.alloc(u8, @intCast(this.length));
            return .{
                .args = .{ .fd = this.fd, .output = output, .position = this.position },
                .attachment = .{ .buffer = this.buffer.take(), .offset = @intCast(this.offset) },
            };
        }

        pub fn bytes(this: *const Read) []u8 {
            const buffer = this.buffer.unsafeMutPtr("Arguments.Read owns the destination lease until the synchronous filesystem read returns");
            const offset = @min(this.offset, buffer.len);
            return buffer[offset..][0..@min(this.length, buffer.len - offset)];
        }

        pub fn deinit(this: Read) void {
            var buffer = this.buffer;
            buffer.deinit();
        }

        pub fn fromBindgen(args: anytype) bun.OOM!Validated(Read) {
            const length = args.length;
            if (length == 0) {
                return .{ .value = .{
                    .fd = .fromUV(args.fd),
                    .buffer = try args.buffer.toOwned(),
                    .length = 0,
                    .offset = 0,
                } };
            }

            const buf_len = args.buffer.length();
            if (buf_len == 0) {
                return .{ .validation_error = .{
                    .invalid_argument_value = "The argument 'buffer' is empty and cannot be written.",
                } };
            }
            if (length > buf_len) {
                return .{ .validation_error = .{ .out_of_range = .{
                    .value = .{ .unsigned = length },
                    .options = .{ .field_name = "length", .max = @intCast(@min(buf_len, std.math.maxInt(i64))) },
                } } };
            }
            const buf_len_u64: u64 = @intCast(buf_len);
            if (args.offset +| length > buf_len_u64) {
                return .{ .validation_error = .{ .out_of_range = .{
                    .value = .{ .unsigned = length },
                    .options = .{ .field_name = "length", .max = @intCast(@min(buf_len_u64 -| args.offset, std.math.maxInt(i64))) },
                } } };
            }
            const max_position = std.math.maxInt(i64) - @as(i64, @intCast(length));
            if (args.position > max_position) {
                return .{ .validation_error = .{ .out_of_range = .{
                    .value = .{ .signed = args.position },
                    .options = .{
                        .field_name = "position",
                        .min = -1,
                        .max = max_position,
                    },
                } } };
            }

            return .{ .value = .{
                .fd = .fromUV(args.fd),
                .buffer = try args.buffer.toOwned(),
                .offset = args.offset,
                .length = length,
                .position = if (args.position >= 0) args.position else null,
            } };
        }
    };

    /// Asynchronously reads the entire contents of a file.
    /// @param path A path to a file. If a URL is provided, it must use the `file:` protocol.
    /// If a file descriptor is provided, the underlying file will _not_ be closed automatically.
    /// @param options Either the encoding for the result, or an object that contains the encoding and an optional flag.
    /// If a flag is not provided, it defaults to `'r'`.
    pub const ReadFile = struct {
        path: PathOrFileDescriptor,
        encoding: Encoding = Encoding.utf8,

        offset: BlobSize.SizeType = 0,
        max_size: ?BlobSize.SizeType = null,
        limit_size_for_javascript: bool = false,

        flag: FileSystemFlags = FileSystemFlags.r,

        abort: NodeFSAbort.Token = .{},

        pub fn deinit(self: ReadFile) void {
            self.path.deinit();
            self.abort.deinit();
        }

        pub fn toThreadSafe(self: *ReadFile) bun.OOM!void {
            try self.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!ReadFile {
            const path = try PathOrFileDescriptor.fromBinding(args.path);
            errdefer path.deinit();

            var encoding: Encoding = .buffer;
            var flag: FileSystemFlags = .r;
            if (args.options) |options| switch (options) {
                .encoding => |value| encoding = encodingFromBindgenValue(value),
                .options => |value| {
                    if (value.encoding) |selected| encoding = encodingFromBindgenValue(selected);
                    flag = fileSystemFlagsFromBindgen(value.flag, .r);
                },
            };

            return .{
                .path = path,
                .encoding = encoding,
                .flag = flag,
                .limit_size_for_javascript = true,
            };
        }

        pub fn aborted(self: ReadFile) bool {
            return self.abort.aborted();
        }
    };

    pub const WriteFile = struct {
        encoding: Encoding = Encoding.utf8,

        flag: FileSystemFlags = FileSystemFlags.w,
        mode: Mode = 0o666,
        file: PathOrFileDescriptor,
        flush: bool = false,

        /// Encoded at the time of construction.
        data: StringOrBuffer,

        dirfd: FD,

        abort: NodeFSAbort.Token = .{},

        pub fn deinit(self: WriteFile) void {
            self.file.deinit();
            self.data.deinit();
            self.abort.deinit();
        }

        pub fn toThreadSafe(self: *WriteFile) bun.OOM!void {
            try self.file.toThreadSafe();
            try self.data.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!WriteFile {
            const path = try PathOrFileDescriptor.fromBinding(args.file);
            errdefer path.deinit();

            var encoding: Encoding = switch (args.data) {
                .buffer => .buffer,
                .string => .utf8,
            };
            var flag = FileSystemFlags.w;
            var mode: Mode = default_permission;
            var flush: bool = false;
            if (args.options) |options| switch (options) {
                .encoding => |value| encoding = encodingFromBindgenValue(value),
                .options => |value| {
                    if (value.encoding) |selected| encoding = encodingFromBindgenValue(selected);
                    flag = fileSystemFlagsFromBindgen(value.flag, .w);
                    mode = @truncate(value.mode orelse default_permission);
                    flush = value.flush orelse false;
                },
            };

            const data = try StringOrBuffer.fromBindgen(args.data, encoding);

            return .{
                .file = path,
                .encoding = encoding,
                .flag = flag,
                .mode = mode,
                .data = data,
                .dirfd = bun.FD.cwd(),
                .flush = flush,
            };
        }

        pub fn aborted(self: WriteFile) bool {
            return self.abort.aborted();
        }
    };

    pub const AppendFile = WriteFile;

    pub const Exists = struct {
        path: PathLike,

        pub fn deinit(this: Exists) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Exists) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Exists {
            return .{ .path = try PathLike.fromBindingView(args.path) };
        }
    };

    pub const Access = struct {
        path: PathLike,
        mode: FileSystemFlags = FileSystemFlags.r,

        pub fn deinit(this: Access) void {
            this.path.deinit();
        }

        pub fn toThreadSafe(this: *Access) bun.OOM!void {
            try this.path.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Access {
            return .{
                .path = try PathLike.fromBindingView(args.path),
                .mode = @fromBackingInt(@intCast(args.mode)),
            };
        }
    };

    pub const FdataSync = struct {
        fd: FD,

        pub fn deinit(_: FdataSync) void {}
        pub fn toThreadSafe(self: *const @This()) bun.OOM!void {
            _ = self;
        }

        pub fn fromBindgen(args: anytype) bun.JSError!FdataSync {
            return .{ .fd = .fromUV(args.fd) };
        }
    };

    pub const CopyFile = struct {
        src: PathLike,
        dest: PathLike,
        mode: constants.Copyfile,

        pub fn deinit(this: *const CopyFile) void {
            this.src.deinit();
            this.dest.deinit();
        }

        pub fn toThreadSafe(this: *CopyFile) bun.OOM!void {
            try this.src.toThreadSafe();
            try this.dest.toThreadSafe();
        }

        pub fn fromBindgen(args: anytype) bun.JSError!CopyFile {
            const src = try PathLike.fromBindingView(args.src);
            errdefer src.deinit();
            return .{
                .src = src,
                .dest = try PathLike.fromBindingView(args.dest),
                .mode = @fromBackingInt(@intCast(args.mode)),
            };
        }
    };

    pub const Cp = struct {
        src: PathLike,
        dest: PathLike,
        flags: Flags,

        pub const Flags = NodeFSCopy.Arguments.Flags;

        pub fn deinit(this: *const Cp) void {
            if (this.flags.deinit_paths) {
                this.src.deinit();
                this.dest.deinit();
            }
        }

        pub fn fromBindgen(args: anytype) bun.JSError!Cp {
            const src = try PathLike.fromBindingView(args.src);
            errdefer src.deinit();
            return .{
                .src = src,
                .dest = try PathLike.fromBindingView(args.dest),
                .flags = .{
                    .mode = @fromBackingInt(@intCast(args.mode)),
                    .recursive = args.recursive,
                    .errorOnExist = args.errorOnExist,
                    .force = args.force,
                },
            };
        }

        pub fn toCopyArguments(this: Cp) NodeFSCopy.Arguments {
            return .{
                .src = this.src,
                .dest = this.dest,
                .flags = this.flags,
            };
        }
    };

    pub const Watch = @import("./FSWatcherTypes.zig").Arguments;

    pub const WatchFile = @import("./StatWatcherTypes.zig").Arguments;

    pub const Fsync = struct {
        fd: FD,

        pub fn deinit(_: Fsync) void {}
        pub fn toThreadSafe(_: *const @This()) bun.OOM!void {}

        pub fn fromBindgen(args: anytype) bun.JSError!Fsync {
            return .{ .fd = .fromUV(args.fd) };
        }
    };
};

pub const StatOrNotFound = union(enum) {
    stats: NodeStats,
    not_found: void,
};

pub const StringOrUndefined = NodeFSCore.MkdirResult;

const OwnedStringResult = struct {
    string: bun.String,

    pub fn deinit(result: *@This()) void {
        result.string.deref();
    }
};

/// For use in `Return`'s definitions to act as `void` while returning `null` to JavaScript
const Null = struct {};

pub const Return = struct {
    pub const Access = Null;
    pub const AppendFile = void;
    pub const Close = void;
    pub const CopyFile = void;
    pub const Cp = void;
    pub const Exists = bool;
    pub const Fchmod = void;
    pub const Chmod = void;
    pub const Fchown = void;
    pub const Fdatasync = void;
    pub const Fstat = NodeStats;
    pub const Rm = void;
    pub const Fsync = void;
    pub const Ftruncate = void;
    pub const Futimes = void;
    pub const Lchmod = void;
    pub const Lchown = void;
    pub const Link = void;
    pub const Lstat = StatOrNotFound;
    pub const Mkdir = StringOrUndefined;
    pub const Mkdtemp = OwnedStringResult;
    pub const Open = FD;
    pub const WriteFile = void;
    pub const Readv = Read;
    pub const StatFS = NodeStatFS;
    pub const Read = struct {
        bytes_read: u52,
    };
    pub const Write = struct {
        bytes_written: u52,
    };
    pub const Readdir = union(Tag) {
        with_file_types: []NodeTypes.Dirent,
        buffers: []NodeBuffer,
        files: []const bun.String,

        pub const Tag = enum {
            with_file_types,
            buffers,
            files,
        };

        pub fn deinit(result: *@This()) void {
            switch (result.*) {
                .with_file_types => |items| {
                    for (items) |*item| item.deref();
                    bun.default_allocator.free(items);
                },
                .buffers => |items| {
                    for (items) |*item| item.deinit();
                    bun.default_allocator.free(items);
                },
                .files => |items| {
                    for (items) |*item| item.deref();
                    bun.default_allocator.free(items);
                },
            }
        }
    };
    pub const ReadFile = StringOrBuffer;
    pub const ReadFileWithOptions = union(enum) {
        string: string,
        transcoded_string: bun.String,
        buffer: NodeBuffer,
        null_terminated: [:0]const u8,
    };
    pub const Readlink = StringOrBuffer;
    pub const Realpath = StringOrBuffer;
    pub const RealpathNative = Realpath;
    pub const Rename = void;
    pub const Rmdir = void;
    pub const Stat = StatOrNotFound;
    pub const Symlink = void;
    pub const Truncate = void;
    pub const Unlink = void;
    pub const Utimes = void;
    pub const Chown = void;
    pub const Lutimes = void;
    pub const Writev = Write;
};

pub fn deinitSuccess(result: anytype) void {
    const Result = @TypeOf(result.*);
    if (comptime Result == Return.Open) {
        result.close();
        return;
    }
    if (comptime Result == Return.Mkdir) {
        result.deinit();
        return;
    }
    if (comptime Result == Return.Mkdtemp) {
        result.deinit();
        return;
    }
    if (comptime Result == Return.Readdir) {
        result.deinit();
        return;
    }
    if (comptime Result == Return.ReadFile) {
        result.deinit();
        return;
    }
    if (comptime Result == void or
        Result == Return.Access or
        Result == Return.Exists or
        Result == Return.Fstat or
        Result == StatOrNotFound or
        Result == Return.StatFS or
        Result == Return.Read or
        Result == Return.Write)
    {
        return;
    }
    @compileError("NodeFS async result needs an explicit cleanup classification: " ++ @typeName(Result));
}

/// Bun's implementation of the Node.js "fs" module
/// https://nodejs.org/api/fs.html
/// https://github.com/DefinitelyTyped/DefinitelyTyped/blob/master/types/node/fs.d.ts
const node_fs_threadlocal_buffers = bun.ThreadlocalBuffers(struct {
    read_file: [256 * 1024]u8 = undefined,
});

pub const NodeFS = struct {
    /// Buffer to store a temporary file path that might appear in a returned error message.
    ///
    /// We want to avoid allocating a new path buffer for every error message so that jsc can clone + GC it.
    /// That means a stack-allocated buffer won't suffice. Instead, we re-use
    /// the heap allocated buffer on the NodeFS struct
    sync_error_buf: bun.PathBuffer align(@alignOf(u16)) = undefined,
    sync_message_buf: [2048]u8 = undefined,
    runtime_io: ?std.Io = null,

    pub const ReturnType = Return;

    pub fn io(this: *const NodeFS) std.Io {
        return this.runtime_io orelse bun.cli.Cli.io;
    }

    pub fn access(this: *NodeFS, args: Arguments.Access, _: Flavor) Maybe(Return.Access) {
        const path: bun.OSPathSliceZ = if (args.path.slice().len == 0)
            comptime bun.OSPathLiteral("")
        else
            args.path.osPathKernel32(&this.sync_error_buf);
        return switch (Syscall.access(path, args.mode.asInt())) {
            .err => |err| .{ .err = err.withPath(args.path.slice()) },
            .result => .{ .result = .{} },
        };
    }

    pub fn appendFile(this: *NodeFS, args: Arguments.AppendFile, _: Flavor) Maybe(Return.AppendFile) {
        var data = args.data.slice();

        switch (args.file) {
            .fd => |fd| {
                while (data.len > 0) {
                    const written = switch (Syscall.write(fd, data)) {
                        .result => |result| result,
                        .err => |err| return .{ .err = err },
                    };
                    data = data[written..];
                }

                return .success;
            },
            .path => |path_| {
                const path = path_.sliceZ(&this.sync_error_buf);

                const fd = switch (Syscall.open(path, @backingInt(FileSystemFlags.a), args.mode)) {
                    .result => |result| result,
                    .err => |err| return .{ .err = err },
                };

                defer {
                    fd.close();
                }

                while (data.len > 0) {
                    const written = switch (Syscall.write(fd, data)) {
                        .result => |result| result,
                        .err => |err| return .{ .err = err },
                    };
                    data = data[written..];
                }

                return .success;
            },
        }
    }

    pub fn close(_: *NodeFS, args: Arguments.Close, _: Flavor) Maybe(Return.Close) {
        return if (args.fd.closeAllowingBadFileDescriptor(null)) |err|
            .{ .err = err }
        else
            .success;
    }

    pub fn uv_close(_: *NodeFS, args: Arguments.Close, rc: i64) Maybe(Return.Close) {
        if (rc < 0) {
            return Maybe(Return.Close){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .close,
                .fd = args.fd,
                .from_libuv = true,
            } };
        }
        return .success;
    }

    pub const copyFileUsingReadWriteLoop = NodeFSCore.copyFileUsingReadWriteLoop;

    pub fn copyFile(this: *NodeFS, args: Arguments.CopyFile, _: Flavor) Maybe(Return.CopyFile) {
        return switch (this.copyFileInner(args)) {
            .result => .success,
            .err => |err| .{ .err = .{
                .errno = err.errno,
                .syscall = .copyfile,
                .path = args.src.slice(),
                .dest = args.dest.slice(),
            } },
        };
    }

    /// https://github.com/libuv/libuv/pull/2233
    /// https://github.com/pnpm/pnpm/issues/2761
    /// https://github.com/libuv/libuv/pull/2578
    /// https://github.com/nodejs/node/issues/34624
    fn copyFileInner(fs: *NodeFS, args: Arguments.CopyFile) Maybe(Return.CopyFile) {
        const ret = Maybe(Return.CopyFile);

        // TODO: do we need to fchown?
        if (comptime Environment.isMac) {
            var src_buf: bun.PathBuffer = undefined;
            var dest_buf: bun.PathBuffer = undefined;

            const src = args.src.sliceZ(&src_buf);
            const dest = args.dest.sliceZ(&dest_buf);

            if (args.mode.isForceClone()) {
                // https://www.manpagez.com/man/2/clonefile/
                return ret.errnoSysP(c.clonefile(src, dest, 0), .copyfile, src) orelse ret.success;
            } else {
                const stat_ = switch (Syscall.stat(src)) {
                    .result => |result| result,
                    .err => |err| return Maybe(Return.CopyFile){ .err = err.withPath(src) },
                };

                if (!posix.S.ISREG(@intCast(stat_.mode))) {
                    return Maybe(Return.CopyFile){ .err = .{
                        .errno = @backingInt(SystemErrno.ENOTSUP),
                        .syscall = .copyfile,
                    } };
                }

                // 64 KB is about the break-even point for clonefile() to be worth it
                // at least, on an M1 with an NVME SSD.
                if (stat_.size > 128 * 1024) {
                    if (!args.mode.shouldntOverwrite()) {
                        // clonefile() will fail if it already exists
                        _ = Syscall.unlink(dest);
                    }

                    if (ret.errnoSysP(c.clonefile(src, dest, 0), .copyfile, src) == null) {
                        _ = Syscall.chmod(dest, @intCast(stat_.mode));
                        return ret.success;
                    }
                } else {
                    const src_fd = switch (Syscall.open(src, bun.O.RDONLY, 0o644)) {
                        .result => |result| result,
                        .err => |err| return .{ .err = err.withPath(args.src.slice()) },
                    };
                    defer {
                        src_fd.close();
                    }

                    var flags: Mode = bun.O.CREAT | bun.O.WRONLY;
                    var wrote: usize = 0;
                    if (args.mode.shouldntOverwrite()) {
                        flags |= bun.O.EXCL;
                    }

                    // Created with the source's permissions so the file is
                    // never briefly readable.
                    const dest_fd = switch (Syscall.open(dest, flags, @intCast(stat_.mode & 0o777))) {
                        .result => |result| result,
                        .err => |err| return Maybe(Return.CopyFile){ .err = err.withPath(args.dest.slice()) },
                    };
                    defer {
                        _ = Syscall.ftruncate(dest_fd, @as(std.c.off_t, @intCast(@as(u63, @truncate(wrote)))));
                        _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                        dest_fd.close();
                    }

                    return copyFileUsingReadWriteLoop(src, dest, src_fd, dest_fd, @intCast(@max(stat_.size, 0)), &wrote);
                }
            }

            // we fallback to copyfile() when the file is > 128 KB and clonefile fails
            // clonefile() isn't supported on all devices
            // nor is it supported across devices
            var mode: u32 = c.COPYFILE_ACL | c.COPYFILE_DATA;
            if (args.mode.shouldntOverwrite()) {
                mode |= c.COPYFILE_EXCL;
            }

            return ret.errnoSysP(c.copyfile(src, dest, null, mode), .copyfile, src) orelse ret.success;
        }

        if (comptime Environment.isFreeBSD) {
            var src_buf: bun.PathBuffer = undefined;
            var dest_buf: bun.PathBuffer = undefined;
            const src = args.src.sliceZ(&src_buf);
            const dest = args.dest.sliceZ(&dest_buf);

            if (args.mode.isForceClone()) {
                return Maybe(Return.CopyFile){ .err = .{ .errno = @backingInt(SystemErrno.EOPNOTSUPP), .syscall = .copyfile } };
            }

            const src_fd = switch (Syscall.open(src, bun.O.RDONLY, 0)) {
                .result => |result| result,
                .err => |err| return .{ .err = err.withPath(args.src.slice()) },
            };
            defer src_fd.close();

            const stat_: bun.Stat = switch (Syscall.fstat(src_fd)) {
                .result => |result| result,
                .err => |err| return Maybe(Return.CopyFile){ .err = err },
            };
            if (!posix.S.ISREG(@intCast(stat_.mode))) {
                return Maybe(Return.CopyFile){ .err = .{ .errno = @backingInt(SystemErrno.EOPNOTSUPP), .syscall = .copyfile } };
            }

            var flags: i32 = bun.O.CREAT | bun.O.WRONLY;
            if (args.mode.shouldntOverwrite()) {
                flags |= bun.O.EXCL;
            }
            // Created with the source's permissions so the file is never
            // briefly readable.
            const dest_fd = switch (Syscall.open(dest, flags, @intCast(stat_.mode & 0o777))) {
                .result => |result| result,
                .err => |err| return Maybe(Return.CopyFile){ .err = err },
            };
            defer dest_fd.close();

            // Don't O_TRUNC at open: if src and dest resolve to the same
            // inode, that would zero the file before the first read. Match
            // Node by checking inodes after both are open and refusing.
            if (Syscall.fstat(dest_fd).asValue()) |dst_stat| {
                if (stat_.ino == dst_stat.ino and stat_.dev == dst_stat.dev) {
                    return Maybe(Return.CopyFile){ .err = .{ .errno = @backingInt(SystemErrno.EINVAL), .syscall = .copyfile, .path = args.src.slice() } };
                }
            }
            _ = Syscall.ftruncate(dest_fd, 0);

            // FreeBSD 13+ has copy_file_range(2). Try the kernel-side copy
            // first; fall back to read/write on cross-device or unsupported
            // fd types.
            cfr: while (true) {
                const rc = std.c.copy_file_range(src_fd.native(), null, dest_fd.native(), null, std.math.maxInt(i32) - 1, 0);
                switch (bun.sys.getErrno(rc)) {
                    .SUCCESS => if (rc == 0) {
                        _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                        return ret.success;
                    },
                    .INTR => continue,
                    .XDEV, .INVAL, .OPNOTSUPP, .BADF => break :cfr,
                    else => |e| {
                        _ = bun.sys.unlink(dest);
                        return Maybe(Return.CopyFile){ .err = .{ .errno = @backingInt(e), .syscall = .copyfile } };
                    },
                }
            }

            var wrote: u64 = 0;
            if (copyFileUsingReadWriteLoop(src, dest, src_fd, dest_fd, @intCast(@max(stat_.size, 0)), &wrote).asErr()) |err| {
                _ = bun.sys.unlink(dest);
                return Maybe(Return.CopyFile){ .err = err };
            }
            _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
            return ret.success;
        }

        if (comptime Environment.isLinux) {
            var src_buf: bun.PathBuffer = undefined;
            var dest_buf: bun.PathBuffer = undefined;
            const src = args.src.sliceZ(&src_buf);
            const dest = args.dest.sliceZ(&dest_buf);

            const src_fd = switch (Syscall.open(src, bun.O.RDONLY, 0o644)) {
                .result => |result| result,
                .err => |err| return .{ .err = err },
            };
            defer {
                src_fd.close();
            }

            const stat_: bun.Stat = switch (Syscall.fstat(src_fd)) {
                .result => |result| result,
                .err => |err| return Maybe(Return.CopyFile){ .err = err },
            };

            if (!posix.S.ISREG(@intCast(stat_.mode))) {
                return Maybe(Return.CopyFile){ .err = .{ .errno = @backingInt(SystemErrno.ENOTSUP), .syscall = .copyfile } };
            }

            var flags: i32 = bun.O.CREAT | bun.O.WRONLY;
            var wrote: usize = 0;
            if (args.mode.shouldntOverwrite()) {
                flags |= bun.O.EXCL;
            }

            // Created with the source's permissions so the file is never
            // briefly readable.
            const dest_fd = switch (Syscall.open(dest, flags, @intCast(stat_.mode & 0o777))) {
                .result => |result| result,
                .err => |err| return Maybe(Return.CopyFile){ .err = err },
            };

            const size: usize = @intCast(@max(stat_.size, 0));

            // https://manpages.debian.org/testing/manpages-dev/ioctl_ficlone.2.en.html
            if (args.mode.isForceClone()) {
                if (ret.errnoSysP(bun.linux.ioctl_ficlone(dest_fd, src_fd), .ioctl_ficlone, dest)) |err| {
                    dest_fd.close();
                    // This is racey, but it's the best we can do
                    _ = bun.sys.unlink(dest);
                    return err;
                }
                _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                dest_fd.close();
                return ret.success;
            }

            // If we know it's a regular file and ioctl_ficlone is available, attempt to use it.
            if (posix.S.ISREG(@intCast(stat_.mode)) and bun.can_use_ioctl_ficlone()) {
                const rc = bun.linux.ioctl_ficlone(dest_fd, src_fd);
                if (rc == 0) {
                    _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                    dest_fd.close();
                    return ret.success;
                }

                // If this fails for any reason, we say it's disabled
                // We don't want to add the system call overhead of running this function on a lot of files that don't support it
                bun.disable_ioctl_ficlone();
            }

            defer {
                _ = linux.ftruncate(dest_fd.cast(), @as(i64, @intCast(@as(u63, @truncate(wrote)))));
                _ = linux.fchmod(dest_fd.cast(), @intCast(stat_.mode));
                dest_fd.close();
            }

            return NodeFSCore.copyFileDataOnLinux(src, dest, src_fd, dest_fd, size, &wrote);
        }

        if (comptime Environment.isWindows) {
            const dest_buf = bun.os_path_buffer_pool.get();
            defer bun.os_path_buffer_pool.put(dest_buf);

            const src = bun.strings.toKernel32Path(bun.reinterpretSlice(u16, &fs.sync_error_buf), args.src.slice());
            const dest = bun.strings.toKernel32Path(dest_buf, args.dest.slice());
            if (!windows.CopyFileW(src.ptr, dest.ptr, windows.BOOL.fromBool(args.mode.shouldntOverwrite())).toBool()) {
                if (ret.errnoSysP(0, .copyfile, args.src.slice())) |rest| {
                    return NodeFSCopy.Copy.shouldIgnoreEbusy(args.src, args.dest, rest);
                }
            }

            return ret.success;
        }

        @compileError("unreachable");
    }

    pub fn exists(this: *NodeFS, args: Arguments.Exists, _: Flavor) Maybe(Return.Exists) {
        // NOTE: exists cannot return an error
        const path = args.path;

        if (bun.StandaloneModuleGraph.get()) |graph| {
            if (graph.find(path.slice()) != null) {
                return .{ .result = true };
            }
        }

        const slice = if (path.slice().len == 0)
            comptime bun.OSPathLiteral("")
        else
            path.osPathKernel32(&this.sync_error_buf);

        return .{ .result = bun.sys.existsOSPath(slice, false) };
    }

    pub fn chown(this: *NodeFS, args: Arguments.Chown, _: Flavor) Maybe(Return.Chown) {
        if (comptime Environment.isWindows) {
            return switch (Syscall.chown(args.path.sliceZ(&this.sync_error_buf), args.uid, args.gid)) {
                .err => |err| .{ .err = err.withPath(args.path.slice()) },
                .result => |res| .{ .result = res },
            };
        }

        const path = args.path.sliceZ(&this.sync_error_buf);

        return Syscall.chown(path, args.uid, args.gid);
    }

    pub fn chmod(this: *NodeFS, args: Arguments.Chmod, _: Flavor) Maybe(Return.Chmod) {
        const path = args.path.sliceZ(&this.sync_error_buf);

        if (comptime Environment.isWindows) {
            return switch (Syscall.chmod(path, args.mode)) {
                .err => |err| .{ .err = err.withPath(args.path.slice()) },
                .result => |res| .{ .result = res },
            };
        }

        return switch (Syscall.chmod(path, args.mode)) {
            .err => |err| .{ .err = err.withPath(args.path.slice()) },
            .result => .success,
        };
    }

    pub fn fchmod(_: *NodeFS, args: Arguments.FChmod, _: Flavor) Maybe(Return.Fchmod) {
        return Syscall.fchmod(args.fd, args.mode);
    }

    pub fn fchown(_: *NodeFS, args: Arguments.Fchown, _: Flavor) Maybe(Return.Fchown) {
        return Syscall.fchown(args.fd, args.uid, args.gid);
    }

    pub fn fdatasync(_: *NodeFS, args: Arguments.FdataSync, _: Flavor) Maybe(Return.Fdatasync) {
        if (Environment.isWindows) {
            return Syscall.fdatasync(args.fd);
        }
        return Maybe(Return.Fdatasync).errnoSysFd(system.fdatasync(args.fd.native()), .fdatasync, args.fd) orelse .success;
    }

    pub fn fstat(_: *NodeFS, args: Arguments.Fstat, _: Flavor) Maybe(Return.Fstat) {
        if (Environment.isLinux and Syscall.supports_statx_on_linux.load(.monotonic)) {
            return switch (Syscall.fstatx(args.fd, &.{ .type, .mode, .nlink, .uid, .gid, .atime, .mtime, .ctime, .btime, .ino, .size, .blocks })) {
                .result => |result| .{ .result = .init(&result, args.big_int) },
                .err => |err| .{ .err = err },
            };
        } else {
            return switch (Syscall.fstat(args.fd)) {
                .result => |result| .{ .result = .init(&Syscall.PosixStat.init(&result), args.big_int) },
                .err => |err| .{ .err = err },
            };
        }
    }

    pub fn fsync(_: *NodeFS, args: Arguments.Fsync, _: Flavor) Maybe(Return.Fsync) {
        if (Environment.isWindows) {
            return Syscall.fsync(args.fd);
        }
        return Maybe(Return.Fsync).errnoSys(system.fsync(args.fd.native()), .fsync) orelse
            .success;
    }

    pub fn ftruncate(_: *NodeFS, args: Arguments.FTruncate, _: Flavor) Maybe(Return.Ftruncate) {
        return NodeFSCore.ftruncate(args.fd, @intCast(@max(args.len, 0)));
    }

    pub fn futimes(_: *NodeFS, args: Arguments.Futimes, _: Flavor) Maybe(Return.Futimes) {
        if (comptime Environment.isWindows) {
            var req: uv.fs_t = uv.fs_t.uninitialized;
            defer req.deinit();
            const rc = uv.uv_fs_futime(uv.Loop.get(), &req, args.fd.uv(), args.atime, args.mtime, null);
            return if (rc.errno()) |e|
                .{ .err = .{
                    .errno = e,
                    .syscall = .futime,
                    .fd = args.fd,
                } }
            else
                .success;
        }

        return switch (Syscall.futimens(args.fd, args.atime, args.mtime)) {
            .err => |err| .{ .err = err },
            .result => .success,
        };
    }

    pub fn lchmod(this: *NodeFS, args: Arguments.LCHmod, _: Flavor) Maybe(Return.Lchmod) {
        if (comptime Environment.isWindows) {
            return Maybe(Return.Lchmod).todo();
        }
        if (comptime Environment.isAndroid) {
            // bionic has no lchmod(); symlink modes are meaningless on Linux
            // anyway. Match glibc's stub behaviour.
            return .{ .err = .{ .errno = @backingInt(bun.sys.E.OPNOTSUPP), .syscall = .lchmod, .path = args.path.slice() } };
        }

        const path = args.path.sliceZ(&this.sync_error_buf);
        return Maybe(Return.Lchmod).errnoSysP(c.lchmod(path, @truncate(args.mode)), .lchmod, path) orelse
            .success;
    }

    pub fn lchown(this: *NodeFS, args: Arguments.LChown, _: Flavor) Maybe(Return.Lchown) {
        if (comptime Environment.isWindows) {
            return Maybe(Return.Lchown).todo();
        }

        const path = args.path.sliceZ(&this.sync_error_buf);

        return Maybe(Return.Lchown).errnoSysP(c.lchown(path, args.uid, args.gid), .lchown, path) orelse
            .success;
    }

    pub fn link(this: *NodeFS, args: Arguments.Link, _: Flavor) Maybe(Return.Link) {
        var to_buf: bun.PathBuffer = undefined;
        const from = args.old_path.sliceZ(&this.sync_error_buf);
        const to = args.new_path.sliceZ(&to_buf);

        if (Environment.isWindows) {
            return switch (Syscall.link(from, to)) {
                .err => |err| .{ .err = err.withPathDest(args.old_path.slice(), args.new_path.slice()) },
                .result => |result| .{ .result = result },
            };
        }

        return Maybe(Return.Link).errnoSysPD(system.link(from, to), .link, args.old_path.slice(), args.new_path.slice()) orelse
            .success;
    }

    pub fn lstat(this: *NodeFS, args: Arguments.Lstat, _: Flavor) Maybe(Return.Lstat) {
        if (Environment.isLinux and Syscall.supports_statx_on_linux.load(.monotonic)) {
            return switch (Syscall.lstatx(args.path.sliceZ(&this.sync_error_buf), &.{ .type, .mode, .nlink, .uid, .gid, .atime, .mtime, .ctime, .btime, .ino, .size, .blocks })) {
                .result => |result| Maybe(Return.Lstat){ .result = .{ .stats = .init(&result, args.big_int) } },
                .err => |err| brk: {
                    if (!args.throw_if_no_entry and err.getErrno() == .NOENT) {
                        return Maybe(Return.Lstat){ .result = .{ .not_found = {} } };
                    }
                    break :brk Maybe(Return.Lstat){ .err = err.withPath(args.path.slice()) };
                },
            };
        } else {
            return switch (Syscall.lstat(args.path.sliceZ(&this.sync_error_buf))) {
                .result => |result| Maybe(Return.Lstat){ .result = .{ .stats = .init(&Syscall.PosixStat.init(&result), args.big_int) } },
                .err => |err| brk: {
                    if (!args.throw_if_no_entry and err.getErrno() == .NOENT) {
                        return Maybe(Return.Lstat){ .result = .{ .not_found = {} } };
                    }
                    break :brk Maybe(Return.Lstat){ .err = err.withPath(args.path.slice()) };
                },
            };
        }
    }

    pub fn mkdir(this: *NodeFS, args: Arguments.Mkdir, _: Flavor) Maybe(Return.Mkdir) {
        return NodeFSCore.mkdirFromArgs(&this.sync_error_buf, &args, void, {});
    }

    pub fn mkdirNonRecursive(this: *NodeFS, args: Arguments.Mkdir) Maybe(Return.Mkdir) {
        return NodeFSCore.mkdirNonRecursiveFromArgs(&this.sync_error_buf, &args);
    }

    pub fn mkdirRecursive(this: *NodeFS, args: Arguments.Mkdir) Maybe(Return.Mkdir) {
        return NodeFSCore.mkdirRecursiveFromArgs(&this.sync_error_buf, &args, void, {});
    }

    pub fn mkdirRecursiveImpl(this: *NodeFS, args: Arguments.Mkdir, comptime Context: type, context: Context) Maybe(Return.Mkdir) {
        return NodeFSCore.mkdirRecursiveFromArgs(&this.sync_error_buf, &args, Context, context);
    }

    pub fn mkdirRecursiveOSPath(this: *NodeFS, path: bun.OSPathSliceZ, mode: Mode, comptime return_path: bool) Maybe(Return.Mkdir) {
        return NodeFSCore.mkdirRecursiveOSPath(&this.sync_error_buf, void, {}, path, mode, return_path);
    }

    pub fn mkdirRecursiveOSPathImpl(
        this: *NodeFS,
        comptime Context: type,
        context: Context,
        path: bun.OSPathSliceZ,
        mode: Mode,
        comptime return_path: bool,
    ) Maybe(Return.Mkdir) {
        return NodeFSCore.mkdirRecursiveOSPath(&this.sync_error_buf, Context, context, path, mode, return_path);
    }
    pub fn mkdtemp(this: *NodeFS, args: Arguments.MkdirTemp, _: Flavor) Maybe(Return.Mkdtemp) {
        var prefix_buf = &this.sync_error_buf;
        const prefix_slice = args.prefix.slice();
        const len = @min(prefix_slice.len, prefix_buf.len -| 7);
        if (len > 0) {
            @memcpy(prefix_buf[0..len], prefix_slice[0..len]);
        }
        prefix_buf[len..][0..6].* = "XXXXXX".*;
        prefix_buf[len..][6] = 0;

        // The mkdtemp() function returns  a  pointer  to  the  modified  template
        // string  on  success, and NULL on failure, in which case errno is set to
        // indicate the error

        if (Environment.isWindows) {
            var req: uv.fs_t = uv.fs_t.uninitialized;
            defer req.deinit();
            const rc = uv.uv_fs_mkdtemp(bun.Async.Loop.get(), &req, @ptrCast(prefix_buf.ptr), null);
            if (rc.errno()) |errno| {
                return .{ .err = .{
                    .errno = errno,
                    .syscall = .mkdtemp,
                    .path = prefix_buf[0 .. len + 6],
                } };
            }
            return .initResult(.{ .string = bun.String.cloneUTF8(std.mem.sliceTo(req.path, 0)) });
        }

        const rc = c.mkdtemp(prefix_buf);
        if (rc) |ptr| {
            return .initResult(.{ .string = bun.String.cloneUTF8(std.mem.sliceTo(ptr, 0)) });
        }

        // c.getErrno(rc) returns SUCCESS if rc is -1 so we call std.c._errno() directly
        const errno = @as(std.c.E, @fromBackingInt(@intCast(std.c._errno().*)));
        return .{
            .err = Syscall.Error{
                .errno = @as(Syscall.Error.Int, @truncate(@backingInt(errno))),
                .syscall = .mkdtemp,
                .path = prefix_buf[0 .. len + 6],
            },
        };
    }

    pub fn open(this: *NodeFS, args: Arguments.Open, _: Flavor) Maybe(Return.Open) {
        const path = if (Environment.isWindows and bun.strings.eqlComptime(args.path.slice(), "/dev/null"))
            "\\\\.\\NUL"
        else
            args.path.sliceZ(&this.sync_error_buf);

        return switch (Syscall.open(path, args.flags.asInt(), args.mode)) {
            .err => |err| .{
                .err = err.withPath(args.path.slice()),
            },
            .result => |fd| .{ .result = fd },
        };
    }

    pub fn uv_open(this: *NodeFS, args: Arguments.Open, rc: i64) Maybe(Return.Open) {
        _ = this;
        if (rc < 0) {
            return Maybe(Return.Open){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .open,
                .path = args.path.slice(),
                .from_libuv = true,
            } };
        }
        return Maybe(Return.Open).initResult(.fromUV(@intCast(rc)));
    }

    pub fn uv_statfs(_: *NodeFS, args: Arguments.StatFS, req: *uv.fs_t, rc: i64) Maybe(Return.StatFS) {
        if (rc < 0) {
            return Maybe(Return.StatFS){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .open,
                .path = args.path.slice(),
                .from_libuv = true,
            } };
        }
        const statfs_ = req.ptrAs(*align(1) bun.StatFS).*;
        return Maybe(Return.StatFS).initResult(Return.StatFS.init(&statfs_, args.big_int));
    }

    fn readInner(_: *NodeFS, args: anytype) Maybe(Return.Read) {
        if (Environment.allow_assert) bun.assert(args.position == null);
        const buf = args.bytes();

        return switch (Syscall.read(args.fd, buf)) {
            .err => |err| .{ .err = err },
            .result => |amt| .{ .result = .{
                .bytes_read = @as(u52, @truncate(amt)),
            } },
        };
    }

    fn preadInner(_: *NodeFS, args: anytype) Maybe(Return.Read) {
        const buf = args.bytes();

        return switch (Syscall.pread(args.fd, buf, args.position.?)) {
            .err => |err| .{ .err = .{
                .errno = err.errno,
                .fd = args.fd,
                .syscall = .read,
            } },
            .result => |amt| .{ .result = .{
                .bytes_read = @as(u52, @truncate(amt)),
            } },
        };
    }

    pub fn read(this: *NodeFS, args: Arguments.Read, _: Flavor) Maybe(Return.Read) {
        return this.readImpl(args);
    }

    fn readImpl(this: *NodeFS, args: anytype) Maybe(Return.Read) {
        if (args.bytes().len == 0) {
            return Maybe(Return.Read).initResult(.{ .bytes_read = 0 });
        }
        return if (args.position != null)
            this.preadInner(args)
        else
            this.readInner(args);
    }

    pub fn uv_read(this: *NodeFS, args: anytype, rc: i64) Maybe(Return.Read) {
        _ = this;
        if (rc < 0) {
            return Maybe(Return.Read){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .read,
                .fd = args.fd,
                .from_libuv = true,
            } };
        }
        return Maybe(Return.Read).initResult(.{ .bytes_read = @intCast(rc) });
    }

    pub fn uv_readv(this: *NodeFS, args: anytype, rc: i64) Maybe(Return.Readv) {
        _ = this;
        if (rc < 0) {
            return Maybe(Return.Readv){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .readv,
                .fd = args.fd,
                .from_libuv = true,
            } };
        }
        return Maybe(Return.Readv).initResult(.{ .bytes_read = @intCast(rc) });
    }

    pub fn readv(this: *NodeFS, args: Arguments.Readv, _: Flavor) Maybe(Return.Readv) {
        return this.readvImpl(args);
    }

    fn readvImpl(this: *NodeFS, args: anytype) Maybe(Return.Readv) {
        if (args.iovecs.len == 0) {
            return .{ .result = .{ .bytes_read = 0 } };
        }
        return if (args.position != null) preadvInner(this, args) else readvInner(this, args);
    }

    pub fn writev(this: *NodeFS, args: Arguments.Writev, _: Flavor) Maybe(Return.Writev) {
        return this.writevImpl(args);
    }

    fn writevImpl(this: *NodeFS, args: anytype) Maybe(Return.Writev) {
        if (args.iovecs.len == 0) {
            return .{ .result = .{ .bytes_written = 0 } };
        }
        return if (args.position != null) pwritevInner(this, args) else writevInner(this, args);
    }

    pub fn write(this: *NodeFS, args: Arguments.Write, _: Flavor) Maybe(Return.Write) {
        return if (args.position != null) pwriteInner(this, args) else writeInner(this, args);
    }

    pub fn uv_write(this: *NodeFS, args: Arguments.Write, rc: i64) Maybe(Return.Write) {
        _ = this;
        if (rc < 0) {
            return Maybe(Return.Write){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .write,
                .fd = args.fd,
                .from_libuv = true,
            } };
        }
        return Maybe(Return.Write).initResult(.{ .bytes_written = @intCast(rc) });
    }

    pub fn uv_writev(this: *NodeFS, args: anytype, rc: i64) Maybe(Return.Writev) {
        _ = this;
        if (rc < 0) {
            return Maybe(Return.Writev){ .err = .{
                .errno = @intCast(-rc),
                .syscall = .writev,
                .fd = args.fd,
                .from_libuv = true,
            } };
        }
        return Maybe(Return.Writev).initResult(.{ .bytes_written = @intCast(rc) });
    }

    fn writeInner(_: *NodeFS, args: Arguments.Write) Maybe(Return.Write) {
        var buf = args.buffer.slice();
        buf = buf[@min(args.offset, buf.len)..];
        buf = buf[0..@min(buf.len, args.length)];

        return switch (Syscall.write(args.fd, buf)) {
            .err => |err| .{
                .err = err,
            },
            .result => |amt| .{
                .result = .{
                    .bytes_written = @as(u52, @truncate(amt)),
                },
            },
        };
    }

    fn pwriteInner(_: *NodeFS, args: Arguments.Write) Maybe(Return.Write) {
        const position = args.position.?;

        var buf = args.buffer.slice();
        buf = buf[@min(args.offset, buf.len)..];
        buf = buf[0..@min(args.length, buf.len)];

        return switch (Syscall.pwrite(args.fd, buf, position)) {
            .err => |err| .{ .err = .{
                .errno = err.errno,
                .fd = args.fd,
                .syscall = .write,
            } },
            .result => |amt| .{ .result = .{
                .bytes_written = @as(u52, @truncate(amt)),
            } },
        };
    }

    fn preadvInner(_: *NodeFS, args: anytype) Maybe(Return.Readv) {
        const position = args.position.?;

        return switch (Syscall.preadv(args.fd, args.iovecs, position)) {
            .err => |err| .{
                .err = err,
            },
            .result => |amt| .{ .result = .{
                .bytes_read = @as(u52, @truncate(amt)),
            } },
        };
    }

    fn readvInner(_: *NodeFS, args: anytype) Maybe(Return.Readv) {
        return switch (Syscall.readv(args.fd, args.iovecs)) {
            .err => |err| .{
                .err = err,
            },
            .result => |amt| .{ .result = .{
                .bytes_read = @as(u52, @truncate(amt)),
            } },
        };
    }

    fn pwritevInner(_: *NodeFS, args: anytype) Maybe(Return.Write) {
        const position = args.position.?;
        return switch (Syscall.pwritev(args.fd, @ptrCast(args.iovecs), position)) {
            .err => |err| .{
                .err = err,
            },
            .result => |amt| .{ .result = .{
                .bytes_written = @as(u52, @truncate(amt)),
            } },
        };
    }

    fn writevInner(_: *NodeFS, args: anytype) Maybe(Return.Write) {
        return switch (Syscall.writev(args.fd, @ptrCast(args.iovecs))) {
            .err => |err| .{
                .err = err,
            },
            .result => |amt| .{ .result = .{
                .bytes_written = @as(u52, @truncate(amt)),
            } },
        };
    }

    pub fn readdir(this: *NodeFS, args: Arguments.Readdir, comptime flavor: Flavor) Maybe(Return.Readdir) {
        if (comptime flavor != .sync) {
            if (args.recursive) {
                @panic("Assertion failure: this code path should never be reached.");
            }
        }

        const maybe = switch (args.recursive) {
            inline else => |recursive| switch (args.tag()) {
                .buffers => readdirInner(&this.sync_error_buf, args, NodeBuffer, recursive, flavor),
                .with_file_types => readdirInner(&this.sync_error_buf, args, NodeTypes.Dirent, recursive, flavor),
                .files => readdirInner(&this.sync_error_buf, args, bun.String, recursive, flavor),
            },
        };
        return switch (maybe) {
            .err => |err| .{ .err = .{
                .syscall = .scandir,
                .errno = err.errno,
                .path = args.path.slice(),
            } },
            .result => |result| .{ .result = result },
        };
    }

    fn readdirWithEntries(
        args: Arguments.Readdir,
        fd: bun.FD,
        basename: [:0]const u8,
        comptime ExpectedType: type,
        entries: *std.array_list.Managed(ExpectedType),
    ) Maybe(void) {
        const is_u16 = comptime Environment.isWindows and (ExpectedType == bun.String or ExpectedType == NodeTypes.Dirent);

        var dirent_path: bun.String = bun.String.dead;
        defer {
            dirent_path.deref();
        }

        var iterator = DirIterator.iterate(fd, comptime if (is_u16) .u16 else .u8);
        var entry = iterator.next();

        const re_encoding_buffer: ?*bun.PathBuffer = if (is_u16 and args.encoding != .utf8)
            bun.path_buffer_pool.get()
        else
            null;
        defer if (is_u16 and args.encoding != .utf8)
            bun.path_buffer_pool.put(re_encoding_buffer.?);

        while (switch (entry) {
            .err => |err| {
                for (entries.items) |*item| {
                    switch (ExpectedType) {
                        NodeTypes.Dirent => {
                            item.deref();
                        },
                        NodeBuffer => {
                            item.deinit();
                        },
                        bun.String => {
                            item.deref();
                        },
                        else => @compileError("unreachable"),
                    }
                }

                entries.deinit();

                return .{
                    .err = err.withPath(args.path.slice()),
                };
            },
            .result => |ent| ent,
        }) |current| : (entry = iterator.next()) {
            if (ExpectedType == NodeTypes.Dirent) {
                if (dirent_path.isEmpty()) {
                    dirent_path = webcore_encoding.toBunString(strings.withoutNTPrefix(std.meta.Child(@TypeOf(basename)), basename), args.encoding);
                }
            }
            if (comptime !is_u16) {
                const utf8_name = current.name.slice();
                switch (ExpectedType) {
                    NodeTypes.Dirent => {
                        dirent_path.ref();
                        // On filesystems that return DT_UNKNOWN (e.g. FUSE, bind mounts),
                        // fall back to lstat to determine the real file kind.
                        const kind = if (current.kind == .unknown)
                            switch (Syscall.lstatat(fd, current.name.sliceAssumeZ())) {
                                .result => |st| bun.sys.kindFromMode(@intCast(st.mode)),
                                .err => current.kind,
                            }
                        else
                            current.kind;
                        entries.append(.{
                            .name = webcore_encoding.toBunString(utf8_name, args.encoding),
                            .path = dirent_path,
                            .kind = kind,
                        }) catch |err| bun.handleOom(err);
                    },
                    NodeBuffer => {
                        bun.handleOom(entries.append(bun.handleOom(NodeBuffer.copy(utf8_name))));
                    },
                    bun.String => {
                        bun.handleOom(entries.append(webcore_encoding.toBunString(utf8_name, args.encoding)));
                    },
                    else => @compileError("unreachable"),
                }
            } else {
                const utf16_name = current.name.slice();
                switch (ExpectedType) {
                    NodeTypes.Dirent => {
                        dirent_path.ref();
                        entries.append(.{
                            .name = bun.String.cloneUTF16(utf16_name),
                            .path = dirent_path,
                            .kind = current.kind,
                        }) catch |err| bun.handleOom(err);
                    },
                    bun.String => switch (args.encoding) {
                        .buffer => unreachable,
                        // in node.js, libuv converts to utf8 before node.js converts those bytes into other stuff
                        // all encodings besides hex, base64, and base64url are mis-interpreting filesystem bytes.
                        .utf8 => bun.handleOom(entries.append(bun.String.cloneUTF16(utf16_name))),
                        else => |enc| {
                            const utf8_path = bun.strings.fromWPath(re_encoding_buffer.?, utf16_name);
                            bun.handleOom(entries.append(webcore_encoding.toBunString(utf8_path, enc)));
                        },
                    },
                    else => @compileError("unreachable"),
                }
            }
        }

        return .success;
    }

    pub fn readdirWithEntriesRecursiveAsync(
        buf: *bun.PathBuffer,
        args: Arguments.Readdir,
        async_task: anytype,
        basename: [:0]const u8,
        comptime ExpectedType: type,
        entries: *std.array_list.Managed(ExpectedType),
        comptime is_root: bool,
    ) bun.OOM!Maybe(void) {
        const root_basename = async_task.root_path.slice();
        const flags = bun.O.DIRECTORY | bun.O.RDONLY;
        const atfd = if (comptime is_root) bun.FD.cwd() else async_task.root_fd;
        const fd = switch (switch (Environment.os) {
            else => Syscall.openat(atfd, basename, flags, 0),
            // windows bun.sys.open does not pass iterable=true,
            .windows => bun.sys.openDirAtWindowsA(atfd, basename, .{ .no_follow = true, .iterable = true, .read_only = true }),
        }) {
            .err => |err| {
                if (comptime !is_root) {
                    switch (err.getErrno()) {
                        // These things can happen and there's nothing we can do about it.
                        //
                        // This is different than what Node does, at the time of writing.
                        // Node doesn't gracefully handle errors like these. It fails the entire operation.
                        .NOENT, .NOTDIR, .PERM => {
                            return .success;
                        },
                        else => {},
                    }

                    const path_parts = [_]string{ root_basename, basename };
                    const error_path = std.mem.printSentinel(buf, "{f}", .{std.fs.path.fmtJoin(&path_parts)}, 0) catch args.path.slice();
                    return .{
                        .err = err.withPath(error_path),
                    };
                }
                return .{
                    .err = err.withPath(args.path.slice()),
                };
            },
            .result => |fd_| fd_,
        };

        if (comptime is_root) {
            async_task.root_fd = fd;
        }

        defer {
            if (comptime !is_root) {
                fd.close();
            }
        }

        var iterator = DirIterator.iterate(fd, .u8);
        var entry = iterator.next();
        var dirent_path_prev: bun.String = bun.String.empty;
        defer {
            dirent_path_prev.deref();
        }

        while (switch (entry) {
            .err => |err| {
                if (comptime !is_root) {
                    const path_parts = [_]string{ root_basename, basename };
                    const error_path = std.mem.printSentinel(buf, "{f}", .{std.fs.path.fmtJoin(&path_parts)}, 0) catch args.path.slice();
                    return .{
                        .err = err.withPath(error_path),
                    };
                }

                return .{
                    .err = err.withPath(args.path.slice()),
                };
            },
            .result => |ent| ent,
        }) |current| : (entry = iterator.next()) {
            const utf8_name = current.name.slice();

            const name_to_copy: [:0]const u8 = brk: {
                if (async_task.root_path.sliceAssumeZ().ptr == basename.ptr) {
                    break :brk @ptrCast(utf8_name);
                }

                const path_parts = [_]string{ basename, utf8_name };
                break :brk std.mem.printSentinel(buf, "{f}", .{std.fs.path.fmtJoin(&path_parts)}, 0) catch continue;
            };

            // Track effective kind - may be resolved from .unknown via stat
            var effective_kind = current.kind;

            enqueue: {
                switch (current.kind) {
                    // a symlink might be a directory or might not be
                    // if it's not a directory, the task will fail at that point.
                    .sym_link,

                    // we know for sure it's a directory
                    .directory,
                    => {
                        // if the name is too long, we can't enqueue it regardless
                        // the operating system would just return ENAMETOOLONG
                        //
                        // Technically, we could work around that due to the
                        // usage of openat, but then we risk leaving too many
                        // file descriptors open.
                        if (current.name.len + 1 + name_to_copy.len > bun.MAX_PATH_BYTES) break :enqueue;

                        async_task.enqueue(name_to_copy);
                    },
                    // Some filesystems (e.g., Docker bind mounts, FUSE, NFS) return
                    // DT_UNKNOWN for d_type. Use lstatat to determine the actual type.
                    .unknown => {
                        if (current.name.len + 1 + name_to_copy.len > bun.MAX_PATH_BYTES) break :enqueue;

                        // Lazy stat to determine the actual kind (lstatat to not follow symlinks)
                        const stat_result = bun.sys.lstatat(fd, current.name.sliceAssumeZ());
                        switch (stat_result) {
                            .result => |st| {
                                const real_kind = bun.sys.kindFromMode(@intCast(st.mode));
                                effective_kind = real_kind;
                                if (real_kind == .directory or real_kind == .sym_link) {
                                    async_task.enqueue(name_to_copy);
                                }
                            },
                            .err => {}, // Skip entries we can't stat
                        }
                    },
                    else => {},
                }
            }

            try entries.ensureUnusedCapacity(1);
            switch (comptime ExpectedType) {
                NodeTypes.Dirent => {
                    var path_buf: bun.PathBuffer = undefined;
                    var path_fba = std.heap.FixedBufferAllocator.init(&path_buf);
                    const joined_path = std.fs.path.resolve(path_fba.allocator(), &.{ root_basename, name_to_copy }) catch root_basename;
                    const path_u8 = std.fs.path.dirname(joined_path) orelse "";
                    if (dirent_path_prev.isEmpty() or !bun.strings.eql(dirent_path_prev.byteSlice(), path_u8)) {
                        const path = bun.String.cloneUTF8(path_u8);
                        if (path.tag == .Dead) return error.OutOfMemory;
                        dirent_path_prev.deref();
                        dirent_path_prev = path;
                    }
                    const name = bun.String.cloneUTF8(utf8_name);
                    if (name.tag == .Dead) return error.OutOfMemory;
                    dirent_path_prev.ref();

                    entries.appendAssumeCapacity(.{
                        .name = name,
                        .path = dirent_path_prev,
                        .kind = effective_kind,
                    });
                },
                NodeBuffer => {
                    entries.appendAssumeCapacity(try NodeBuffer.copy(name_to_copy));
                },
                bun.String => {
                    const name = bun.String.cloneUTF8(name_to_copy);
                    if (name.tag == .Dead) return error.OutOfMemory;
                    entries.appendAssumeCapacity(name);
                },
                else => @compileError("unsupported recursive readdir result type"),
            }
        }

        return .success;
    }

    fn readdirWithEntriesRecursiveSync(
        buf: *bun.PathBuffer,
        args: Arguments.Readdir,
        root_basename: [:0]const u8,
        comptime ExpectedType: type,
        entries: *std.array_list.Managed(ExpectedType),
    ) Maybe(void) {
        var iterator_stack_buffer: [128]u8 = undefined;
        var iterator_stack: std.heap.BufferFirstAllocator = .init(&iterator_stack_buffer, bun.default_allocator);
        var stack = bun.LinearFifo([:0]const u8, .{ .Dynamic = {} }).init(iterator_stack.allocator());
        var basename_stack_buffer: [8192 * 2]u8 = undefined;
        var basename_stack: std.heap.BufferFirstAllocator = .init(&basename_stack_buffer, bun.default_allocator);
        const basename_allocator = basename_stack.allocator();
        defer {
            while (stack.readItem()) |name| {
                basename_allocator.free(name);
            }
            stack.deinit();
        }

        stack.writeItem(root_basename) catch unreachable;
        var root_fd: bun.FD = bun.invalid_fd;

        defer {
            // all other paths are relative to the root directory
            // so we can only close it once we're 100% done
            if (root_fd != bun.invalid_fd) {
                root_fd.close();
            }
        }

        while (stack.readItem()) |basename| {
            defer {
                if (root_basename.ptr != basename.ptr) {
                    basename_allocator.free(basename);
                }
            }

            const flags = bun.O.DIRECTORY | bun.O.RDONLY;
            const fd = switch (Syscall.openat(if (root_fd == bun.invalid_fd) bun.FD.cwd() else root_fd, basename, flags, 0)) {
                .err => |err| {
                    if (root_fd == bun.invalid_fd) {
                        return .{
                            .err = err.withPath(args.path.slice()),
                        };
                    }

                    switch (err.getErrno()) {
                        // These things can happen and there's nothing we can do about it.
                        //
                        // This is different than what Node does, at the time of writing.
                        // Node doesn't gracefully handle errors like these. It fails the entire operation.
                        .NOENT, .NOTDIR, .PERM => continue,
                        else => {
                            // const path_parts = [_]string{ args.path.slice(), basename };
                            // TODO: propagate file path (removed previously because it leaked the path)
                            return .{ .err = err };
                        },
                    }
                },
                .result => |fd_| fd_,
            };
            if (root_fd == bun.invalid_fd) {
                root_fd = fd;
            }

            defer {
                if (fd != root_fd) {
                    fd.close();
                }
            }

            var iterator = DirIterator.iterate(fd, .u8);
            var entry = iterator.next();
            var dirent_path_prev: bun.String = bun.String.dead;
            defer {
                dirent_path_prev.deref();
            }

            while (switch (entry) {
                .err => |err| {
                    return .{
                        .err = err.withPath(args.path.slice()),
                    };
                },
                .result => |ent| ent,
            }) |current| : (entry = iterator.next()) {
                const utf8_name = current.name.slice();

                const name_to_copy = brk: {
                    if (root_basename.ptr == basename.ptr) {
                        break :brk utf8_name;
                    }

                    const path_parts = [_]string{ basename, utf8_name };
                    break :brk std.mem.printSentinel(buf, "{f}", .{std.fs.path.fmtJoin(&path_parts)}, 0) catch continue;
                };

                // Track effective kind - may be resolved from .unknown via stat
                var effective_kind = current.kind;

                enqueue: {
                    switch (current.kind) {
                        // a symlink might be a directory or might not be
                        // if it's not a directory, the task will fail at that point.
                        .sym_link,

                        // we know for sure it's a directory
                        .directory,
                        => {
                            if (current.name.len + 1 + name_to_copy.len > bun.MAX_PATH_BYTES) break :enqueue;
                            stack.writeItem(basename_allocator.dupeSentinel(u8, name_to_copy, 0) catch break :enqueue) catch break :enqueue;
                        },
                        // Some filesystems (e.g., Docker bind mounts, FUSE, NFS) return
                        // DT_UNKNOWN for d_type. Use lstatat to determine the actual type.
                        .unknown => {
                            if (current.name.len + 1 + name_to_copy.len > bun.MAX_PATH_BYTES) break :enqueue;

                            // Lazy stat to determine the actual kind (lstatat to not follow symlinks)
                            const stat_result = bun.sys.lstatat(fd, current.name.sliceAssumeZ());
                            switch (stat_result) {
                                .result => |st| {
                                    const real_kind = bun.sys.kindFromMode(@intCast(st.mode));
                                    effective_kind = real_kind;
                                    if (real_kind == .directory or real_kind == .sym_link) {
                                        stack.writeItem(basename_allocator.dupeSentinel(u8, name_to_copy, 0) catch break :enqueue) catch break :enqueue;
                                    }
                                },
                                .err => {}, // Skip entries we can't stat
                            }
                        },
                        else => {},
                    }
                }

                switch (comptime ExpectedType) {
                    NodeTypes.Dirent => {
                        var path_buf: bun.PathBuffer = undefined;
                        var path_fba = std.heap.FixedBufferAllocator.init(&path_buf);
                        const joined_path = std.fs.path.resolve(path_fba.allocator(), &.{ root_basename, name_to_copy }) catch root_basename;
                        const path_u8 = std.fs.path.dirname(joined_path) orelse "";
                        if (dirent_path_prev.isEmpty() or !bun.strings.eql(dirent_path_prev.byteSlice(), path_u8)) {
                            dirent_path_prev.deref();
                            dirent_path_prev = webcore_encoding.toBunString(strings.withoutNTPrefix(std.meta.Child(@TypeOf(path_u8)), path_u8), args.encoding);
                        }
                        dirent_path_prev.ref();
                        entries.append(.{
                            .name = webcore_encoding.toBunString(utf8_name, args.encoding),
                            .path = dirent_path_prev,
                            .kind = effective_kind,
                        }) catch |err| bun.handleOom(err);
                    },
                    NodeBuffer => {
                        bun.handleOom(entries.append(bun.handleOom(NodeBuffer.copy(strings.withoutNTPrefix(std.meta.Child(@TypeOf(name_to_copy)), name_to_copy)))));
                    },
                    bun.String => {
                        bun.handleOom(entries.append(webcore_encoding.toBunString(strings.withoutNTPrefix(std.meta.Child(@TypeOf(name_to_copy)), name_to_copy), args.encoding)));
                    },
                    else => @compileError("unreachable"),
                }
            }
        }

        return .success;
    }

    fn shouldThrowOutOfMemoryEarlyForJavaScript(encoding: Encoding, size: usize, syscall: Syscall.Tag) ?Syscall.Error {
        // Strings & typed arrays max out at 4.7 GB.
        // But, it's **string length**
        // So you can load an 8 GB hex string, for example, it should be fine.
        const adjusted_size = switch (encoding) {
            .utf16le, .ucs2, .utf8 => size / 4 -| 1,
            .hex => size / 2 -| 1,
            .base64, .base64url => size / 3 -| 1,
            .ascii, .latin1, .buffer => size,
        };

        if (
        // Typed arrays in JavaScript are limited to 4.7 GB.
        adjusted_size > bun.JavaScriptLimits.syntheticAllocationLimit() or
            // If they do not have enough memory to open the file and they're on Linux, let's throw an error instead of dealing with the OOM killer.
            (Environment.isLinux and size >= bun.getTotalMemorySize()))
        {
            return Syscall.Error.fromCode(.NOMEM, syscall);
        }

        return null;
    }

    fn readdirInner(
        buf: *bun.PathBuffer,
        args: Arguments.Readdir,
        comptime ExpectedType: type,
        comptime recursive: bool,
        comptime flavor: Flavor,
    ) Maybe(Return.Readdir) {
        const file_type = switch (ExpectedType) {
            NodeTypes.Dirent => "with_file_types",
            bun.String => "files",
            NodeBuffer => "buffers",
            else => @compileError("unreachable"),
        };

        const path = args.path.sliceZ(buf);

        if (comptime recursive and flavor == .sync) {
            var buf_to_pass: bun.PathBuffer = undefined;

            var entries = std.array_list.Managed(ExpectedType).init(bun.default_allocator);
            return switch (readdirWithEntriesRecursiveSync(&buf_to_pass, args, path, ExpectedType, &entries)) {
                .err => |err| {
                    for (entries.items) |*result| {
                        switch (ExpectedType) {
                            NodeTypes.Dirent => {
                                result.deref();
                            },
                            NodeBuffer => {
                                result.deinit();
                            },
                            bun.String => {
                                result.deref();
                            },
                            else => @compileError("unreachable"),
                        }
                    }

                    entries.deinit();

                    return .{
                        .err = err,
                    };
                },
                .result => .{ .result = @unionInit(Return.Readdir, file_type, bun.handleOom(entries.toOwnedSlice())) },
            };
        }

        if (comptime recursive) {
            @panic("This code path should never be reached. It should only go through readdirWithEntriesRecursiveAsync.");
        }

        const flags = bun.O.DIRECTORY | bun.O.RDONLY;
        const fd = switch (switch (Environment.os) {
            else => Syscall.open(path, flags, 0),
            // windows bun.sys.open does not pass iterable=true,
            .windows => bun.sys.openDirAtWindowsA(bun.FD.cwd(), path, .{ .iterable = true, .read_only = true }),
        }) {
            .err => |err| return .{
                .err = err.withPath(args.path.slice()),
            },
            .result => |fd_| fd_,
        };

        defer fd.close();

        var entries = std.array_list.Managed(ExpectedType).init(bun.default_allocator);
        return switch (readdirWithEntries(args, fd, path, ExpectedType, &entries)) {
            .err => |err| return .{
                .err = err,
            },
            .result => .{ .result = @unionInit(Return.Readdir, file_type, bun.handleOom(entries.toOwnedSlice())) },
        };
    }

    pub const StringType = enum {
        default,
        null_terminated,
    };

    pub fn readFile(this: *NodeFS, args: Arguments.ReadFile, comptime flavor: Flavor) Maybe(Return.ReadFile) {
        const ret = readFileWithOptions(this, args, flavor, .default);
        return switch (ret) {
            .err => .{ .err = ret.err },
            .result => |result| switch (result) {
                .buffer => |buffer| .{
                    .result = .{ .buffer = buffer },
                },
                .transcoded_string => |str| {
                    if (str.tag == .Dead) {
                        return .{ .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path) };
                    }

                    return .{ .result = .{ .string = .{ .underlying = str } } };
                },
                .string => brk: {
                    const str = bun.SliceWithUnderlyingString.transcodeFromOwnedSlice(@constCast(ret.result.string), args.encoding);

                    if (str.underlying.tag == .Dead and str.utf8.length() == 0) {
                        return .{ .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path) };
                    }

                    break :brk .{ .result = .{ .string = str } };
                },
                else => unreachable,
            },
        };
    }

    pub fn readFileWithOptions(this: *NodeFS, args: Arguments.ReadFile, comptime flavor: Flavor, comptime string_type: StringType) Maybe(Return.ReadFileWithOptions) {
        var path: [:0]const u8 = undefined;
        const fd_maybe_windows: FD = switch (args.path) {
            .path => brk: {
                path = args.path.path.sliceZ(&this.sync_error_buf);

                if (bun.StandaloneModuleGraph.get()) |graph| {
                    if (graph.find(path)) |file| {
                        if (args.encoding == .buffer) {
                            return .{
                                .result = .{
                                    .buffer = NodeBuffer.adoptDefault(
                                        bun.handleOom(bun.default_allocator.dupe(u8, file.contents)),
                                    ),
                                },
                            };
                        } else if (comptime string_type == .default)
                            return .{
                                .result = .{
                                    .string = bun.handleOom(bun.default_allocator.dupe(u8, file.contents)),
                                },
                            }
                        else
                            return .{
                                .result = .{
                                    .null_terminated = bun.handleOom(bun.default_allocator.dupeSentinel(u8, file.contents, 0)),
                                },
                            };
                    }
                }

                break :brk switch (bun.sys.open(
                    path,
                    args.flag.asInt() | bun.O.NOCTTY,
                    default_permission,
                )) {
                    .err => |err| return .{
                        .err = err.withPath(args.path.path.slice()),
                    },
                    .result => |fd| fd,
                };
            },
            .fd => |fd| fd,
        };
        const fd = fd_maybe_windows.makeLibUVOwned() catch {
            if (args.path == .path)
                fd_maybe_windows.close();

            return .{
                .err = .{
                    .errno = @backingInt(posix.E.MFILE),
                    .syscall = .open,
                },
            };
        };

        defer {
            if (args.path == .path)
                fd.close();
        }

        if (args.aborted()) return Maybe(Return.ReadFileWithOptions).aborted;

        // Only used in DOMFormData
        if (args.offset > 0) {
            _ = Syscall.setFileOffset(fd, args.offset);
        }

        var did_succeed = false;
        var total: usize = 0;
        var async_stack_buffer: [if (flavor == .sync) 0 else 256 * 1024]u8 = undefined;

        // --- Optimization: attempt to read up to 256 KB before calling stat()
        // If we manage to read the entire file, we don't need to call stat() at all.
        // This will make it slightly slower to read e.g. 512 KB files, but usually the OS won't return a full 512 KB in one read anyway.
        const temporary_read_buffer_before_stat_call = brk: {
            const temporary_read_buffer = temporary_read_buffer: {
                const temporary_read_buffer: []u8 = if (comptime flavor == .sync)
                    &node_fs_threadlocal_buffers.get().read_file
                else
                    &async_stack_buffer;

                var available = temporary_read_buffer;
                while (available.len > 0) {
                    switch (Syscall.read(fd, available)) {
                        .err => |err| return .{ .err = err },
                        .result => |amt| {
                            if (amt == 0) {
                                did_succeed = true;
                                break;
                            }
                            total += amt;
                            available = available[amt..];
                        },
                    }
                }
                break :temporary_read_buffer temporary_read_buffer[0..total];
            };

            if (did_succeed) {
                switch (args.encoding) {
                    .buffer => {
                        return .{
                            .result = .{
                                .buffer = NodeBuffer.adoptDefault(
                                    bun.default_allocator.dupe(u8, temporary_read_buffer) catch return .{
                                        .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path),
                                    },
                                ),
                            },
                        };
                    },
                    else => {
                        if (comptime string_type == .default) {
                            return .{
                                .result = .{
                                    .transcoded_string = webcore_encoding.toBunString(temporary_read_buffer, args.encoding),
                                },
                            };
                        } else {
                            return .{
                                .result = .{
                                    .null_terminated = bun.default_allocator.dupeSentinel(u8, temporary_read_buffer, 0) catch return .{
                                        .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path),
                                    },
                                },
                            };
                        }
                    },
                }
            }

            break :brk temporary_read_buffer;
        };
        // ----------------------------

        if (args.aborted()) return Maybe(Return.ReadFileWithOptions).aborted;

        const stat_ = switch (Syscall.fstat(fd)) {
            .err => |err| return .{
                .err = err,
            },
            .result => |stat_| stat_,
        };

        // For certain files, the size might be 0 but the file might still have contents.
        // https://github.com/oven-sh/bun/issues/1220
        const max_size = args.max_size orelse BlobSize.max_size;
        const has_max_size = args.max_size != null;

        const size = @as(
            u64,
            @max(
                @min(
                    stat_.size,
                    // Only used in DOMFormData
                    max_size,
                ),
                @as(i64, @intCast(total)),
                0,
            ),
        ) + @intFromBool(comptime string_type == .null_terminated);

        if (args.limit_size_for_javascript and
            // assume that anything more than 40 bits is not trustworthy.
            (size < std.math.maxInt(u40)))
        {
            if (shouldThrowOutOfMemoryEarlyForJavaScript(args.encoding, size, .read)) |err| {
                return .{ .err = err.withPathLike(args.path) };
            }
        }

        var buf = std.array_list.Managed(u8).init(bun.default_allocator);
        defer buf.deinit();
        buf.ensureTotalCapacityPrecise(
            @min(
                @max(temporary_read_buffer_before_stat_call.len, size) + 16,
                max_size,
                1024 * 1024 * 1024 * 8,
            ),
        ) catch return .{ .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path) };
        if (temporary_read_buffer_before_stat_call.len > 0) {
            buf.appendSlice(temporary_read_buffer_before_stat_call) catch return .{
                .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path),
            };
        }
        buf.expandToCapacity();

        while (total < size) {
            if (args.aborted()) return Maybe(Return.ReadFileWithOptions).aborted;
            switch (Syscall.read(fd, buf.items.ptr[total..@min(buf.capacity, max_size)])) {
                .err => |err| return .{ .err = err },
                .result => |amt| {
                    total += amt;

                    if (args.limit_size_for_javascript) {
                        if (shouldThrowOutOfMemoryEarlyForJavaScript(args.encoding, total, .read)) |err| {
                            return .{
                                .err = err.withPathLike(args.path),
                            };
                        }
                    }

                    // There are cases where stat()'s size is wrong or out of date
                    if (total > size and amt != 0 and !has_max_size) {
                        buf.items.len = total;
                        buf.ensureUnusedCapacity(8192) catch {
                            return .{ .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path) };
                        };
                        continue;
                    }

                    if (amt == 0) {
                        did_succeed = true;
                        break;
                    }
                },
            }
        } else {
            while (true) {
                if (args.aborted()) return Maybe(Return.ReadFileWithOptions).aborted;
                switch (Syscall.read(fd, buf.items.ptr[total..@min(buf.capacity, max_size)])) {
                    .err => |err| return .{ .err = err },
                    .result => |amt| {
                        total += amt;

                        if (args.limit_size_for_javascript) {
                            if (shouldThrowOutOfMemoryEarlyForJavaScript(args.encoding, total, .read)) |err| {
                                return .{ .err = err.withPathLike(args.path) };
                            }
                        }

                        if (total > size and amt != 0 and !has_max_size) {
                            buf.items.len = total;
                            buf.ensureUnusedCapacity(8192) catch {
                                return .{ .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path) };
                            };
                            continue;
                        }

                        if (amt == 0) {
                            did_succeed = true;
                            break;
                        }
                    },
                }
            }
        }

        buf.items.len = if (comptime string_type == .null_terminated) total + 1 else total;
        if (total == 0) {
            buf.clearAndFree();
            return switch (args.encoding) {
                .buffer => .{
                    .result = .{
                        .buffer = NodeBuffer.empty,
                    },
                },
                else => brk: {
                    if (comptime string_type == .default) {
                        break :brk .{
                            .result = .{
                                .string = "",
                            },
                        };
                    } else {
                        break :brk .{
                            .result = .{
                                .null_terminated = "",
                            },
                        };
                    }
                },
            };
        }

        return switch (args.encoding) {
            .buffer => .{
                .result = .{
                    .buffer = NodeBuffer.adoptDefault(buf.toOwnedSlice() catch return .{
                        .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path),
                    }),
                },
            },
            else => brk: {
                if (comptime string_type == .default) {
                    break :brk .{
                        .result = .{
                            .string = buf.toOwnedSlice() catch return .{
                                .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path),
                            },
                        },
                    };
                } else {
                    break :brk .{
                        .result = .{
                            .null_terminated = buf.toOwnedSliceSentinel(0) catch return .{
                                // Since we are expecting a null-terminated string, we can't just ignore the resize failure.
                                .err = Syscall.Error.fromCode(.NOMEM, .read).withPathLike(args.path),
                            },
                        },
                    };
                }
            },
        };
    }

    pub fn writeFileWithPathBuffer(pathbuf: *bun.PathBuffer, args: Arguments.WriteFile) Maybe(Return.WriteFile) {
        return NodeFSCore.writeFileWithPathBufferFromArgs(pathbuf, &args, args.aborted());
    }
    pub fn writeFile(this: *NodeFS, args: Arguments.WriteFile, _: Flavor) Maybe(Return.WriteFile) {
        return writeFileWithPathBuffer(&this.sync_error_buf, args);
    }

    pub fn readlink(this: *NodeFS, args: Arguments.Readlink, _: Flavor) Maybe(Return.Readlink) {
        var outbuf: bun.PathBuffer = undefined;
        const inbuf = &this.sync_error_buf;

        const path = args.path.sliceZ(inbuf);

        const link_path = switch (Syscall.readlink(path, &outbuf)) {
            .err => |err| return .{ .err = err.withPath(args.path.slice()) },
            .result => |result| result,
        };

        return .{
            .result = switch (args.encoding) {
                .buffer => .{
                    .buffer = NodeBuffer.copy(link_path) catch unreachable,
                },
                else => if (args.path == .slice_with_underlying_string and
                    strings.eqlLong(args.path.slice_with_underlying_string.slice(), link_path, true))
                    .{
                        .string = args.path.slice_with_underlying_string.dupeRef(),
                    }
                else
                    .{
                        .string = .{ .utf8 = .{}, .underlying = bun.String.cloneUTF8(link_path) },
                    },
            },
        };
    }

    pub fn realpathNonNative(this: *NodeFS, args: Arguments.Realpath, _: Flavor) Maybe(Return.Realpath) {
        return switch (this.realpathInner(args, .emulated)) {
            .result => |res| .{ .result = res },
            .err => |err| .{ .err = .{
                .errno = err.errno,
                .syscall = .lstat,
                .path = args.path.slice(),
            } },
        };
    }

    pub fn realpath(this: *NodeFS, args: Arguments.Realpath, _: Flavor) Maybe(Return.Realpath) {
        return switch (this.realpathInner(args, .native)) {
            .result => |res| .{ .result = res },
            .err => |err| .{
                .err = .{
                    .errno = err.errno,
                    .syscall = .realpath,
                    .path = args.path.slice(),
                },
            },
        };
    }

    // For `fs.realpath`, Node.js uses `lstat`, exposing the native system call under
    // `fs.realpath.native`. In Bun, the system call is the default, but the error
    // code must be changed to make it seem like it is using lstat (tests expect this),
    // in addition, some more subtle things depend on the variant.
    pub fn realpathInner(this: *NodeFS, args: Arguments.Realpath, variant: enum { native, emulated }) Maybe(Return.Realpath) {
        if (Environment.isWindows) {
            var req: uv.fs_t = uv.fs_t.uninitialized;
            defer req.deinit();
            const rc = uv.uv_fs_realpath(bun.Async.Loop.get(), &req, args.path.sliceZ(&this.sync_error_buf).ptr, null);

            if (rc.errno()) |errno|
                return .{ .err = Syscall.Error{
                    .errno = errno,
                    .syscall = .realpath,
                    .path = args.path.slice(),
                } };

            const result_ptr: ?[*:0]u8 = req.ptrAs(?[*:0]u8);
            var buf = bun.span(result_ptr orelse return .{ .err = Syscall.Error{
                .errno = @backingInt(bun.sys.E.NOENT),
                .syscall = .realpath,
                .path = args.path.slice(),
            } });

            if (variant == .emulated) {
                // remove the trailing slash
                if (buf[buf.len - 1] == '\\') {
                    buf[buf.len - 1] = 0;
                    buf.len -= 1;
                }
            }

            return .{
                .result = switch (args.encoding) {
                    .buffer => .{
                        .buffer = NodeBuffer.copy(buf) catch unreachable,
                    },
                    .utf8 => utf8: {
                        if (args.path == .slice_with_underlying_string) {
                            const slice = args.path.slice_with_underlying_string;
                            if (strings.eqlLong(slice.slice(), buf, true)) {
                                return .{ .result = .{ .string = slice.dupeRef() } };
                            }
                        }
                        break :utf8 .{
                            .string = .{ .utf8 = .{}, .underlying = bun.String.cloneUTF8(buf) },
                        };
                    },
                    else => |enc| .{
                        .string = .{ .utf8 = .{}, .underlying = webcore_encoding.toBunString(buf, enc) },
                    },
                },
            };
        }

        var outbuf: bun.PathBuffer = undefined;
        const path: [:0]const u8 = switch (variant) {
            .native => args.path.sliceZ(&this.sync_error_buf),
            .emulated => path: {
                if (comptime Environment.allow_assert) bun.assert(FileSystem.instance_loaded);
                break :path bun.path.joinAbsStringBufZChecked(
                    FileSystem.instance.top_level_dir,
                    &this.sync_error_buf,
                    &.{args.path.slice()},
                    .auto,
                ) orelse return .{ .err = Syscall.Error.fromCode(.NAMETOOLONG, .realpath).withPath(args.path.slice()) };
            },
        };

        const flags = if (comptime Environment.isLinux)
            // O_PATH is faster
            bun.O.PATH
        else
            // O_NONBLOCK prevents blocking on a FIFO.
            // O_NOCTTY prevents acquiring a controlling terminal.
            bun.O.RDONLY | bun.O.NONBLOCK | bun.O.NOCTTY;

        const fd = switch (bun.sys.open(path, flags, 0)) {
            .err => |err| return .{ .err = err.withPath(path) },
            .result => |fd_| fd_,
        };

        defer fd.close();

        const buf = switch (Syscall.getFdPath(fd, &outbuf)) {
            .err => |err| return .{ .err = err.withPath(path) },
            .result => |buf_| buf_,
        };

        return .{
            .result = switch (args.encoding) {
                .buffer => .{
                    .buffer = NodeBuffer.copy(buf) catch unreachable,
                },
                .utf8 => utf8: {
                    if (args.path == .slice_with_underlying_string) {
                        const slice = args.path.slice_with_underlying_string;
                        if (strings.eqlLong(slice.slice(), buf, true)) {
                            return .{ .result = .{ .string = slice.dupeRef() } };
                        }
                    }
                    break :utf8 .{
                        .string = .{ .utf8 = .{}, .underlying = bun.String.cloneUTF8(buf) },
                    };
                },
                else => |enc| .{
                    .string = .{ .utf8 = .{}, .underlying = webcore_encoding.toBunString(buf, enc) },
                },
            },
        };
    }

    pub const realpathNative = realpath;

    pub fn rename(this: *NodeFS, args: Arguments.Rename, _: Flavor) Maybe(Return.Rename) {
        const from_buf = &this.sync_error_buf;
        var to_buf: bun.PathBuffer = undefined;

        const from = args.old_path.sliceZ(from_buf);
        const to = args.new_path.sliceZ(&to_buf);
        return switch (Syscall.rename(from, to)) {
            .result => |result| .{ .result = result },
            .err => |err| .{ .err = err.withPathDest(args.old_path.slice(), args.new_path.slice()) },
        };
    }

    pub fn rmdir(this: *NodeFS, args: Arguments.Rmdir, _: Flavor) Maybe(Return.Rmdir) {
        if (comptime Environment.isWindows) {
            return switch (Syscall.rmdir(args.path.sliceZ(&this.sync_error_buf))) {
                .err => |err| .{ .err = err.withPath(args.path.slice()) },
                .result => |result| .{ .result = result },
            };
        }

        return Maybe(Return.Rmdir).errnoSysP(system.rmdir(args.path.sliceZ(&this.sync_error_buf)), .rmdir, args.path.slice()) orelse
            .success;
    }

    pub fn rm(this: *NodeFS, args: Arguments.Rm, _: Flavor) Maybe(Return.Rm) {

        // We cannot use removefileat() on macOS because it does not handle write-protected files as expected.
        if (args.recursive) {
            zigDeleteTree(this.io(), std.Io.Dir.cwd(), args.path.slice(), .file) catch |err| {
                bun.handleErrorReturnTrace(err, @errorReturnTrace());
                const errno = bun.sys.Error.errnoFromStdIo(err, .ACCES);
                if (errno == .NOENT and args.force) {
                    return .success;
                }
                return Maybe(Return.Rm){
                    .err = bun.sys.Error.fromCode(errno, .rm).withPath(args.path.slice()),
                };
            };
            return .success;
        }

        const dest = args.path.sliceZ(&this.sync_error_buf);
        if (bun.sys.unlink(dest).asErr()) |err| {
            if (args.force and err.getErrno() == .NOENT) return .success;
            return .{ .err = err.withPathAndSyscall(args.path.slice(), .rm) };
        }

        return .success;
    }

    pub fn statfs(this: *NodeFS, args: Arguments.StatFS, _: Flavor) Maybe(Return.StatFS) {
        return switch (Syscall.statfs(args.path.sliceZ(&this.sync_error_buf))) {
            .result => |*result| Maybe(Return.StatFS){ .result = Return.StatFS.init(result, args.big_int) },
            .err => |err| Maybe(Return.StatFS){ .err = err },
        };
    }

    pub fn stat(this: *NodeFS, args: Arguments.Stat, _: Flavor) Maybe(Return.Stat) {
        const path = args.path.sliceZ(&this.sync_error_buf);
        if (bun.StandaloneModuleGraph.get()) |graph| {
            if (graph.stat(path)) |*result| {
                return .{ .result = .{ .stats = .init(&Syscall.PosixStat.init(result), args.big_int) } };
            }
        }

        if (Environment.isLinux and Syscall.supports_statx_on_linux.load(.monotonic)) {
            return switch (Syscall.statx(path, &.{ .type, .mode, .nlink, .uid, .gid, .atime, .mtime, .ctime, .btime, .ino, .size, .blocks })) {
                .result => |result| .{
                    .result = .{ .stats = .init(&result, args.big_int) },
                },
                .err => |err| brk: {
                    if (!args.throw_if_no_entry and err.getErrno() == .NOENT) {
                        return .{ .result = .{ .not_found = {} } };
                    }
                    break :brk .{ .err = err.withPath(args.path.slice()) };
                },
            };
        } else {
            return switch (Syscall.stat(path)) {
                .result => |result| .{
                    .result = .{ .stats = .init(&Syscall.PosixStat.init(&result), args.big_int) },
                },
                .err => |err| brk: {
                    if (!args.throw_if_no_entry and err.getErrno() == .NOENT) {
                        return .{ .result = .{ .not_found = {} } };
                    }
                    break :brk .{ .err = err.withPath(args.path.slice()) };
                },
            };
        }
    }

    pub fn symlink(this: *NodeFS, args: Arguments.Symlink, _: Flavor) Maybe(Return.Symlink) {
        var to_buf: bun.PathBuffer = undefined;

        if (Environment.isWindows) {
            const target_path = args.target_path.slice();
            const new_path = args.new_path.slice();
            const new_path_dir = std.fs.path.dirnameWindows(new_path) orelse ".";
            // Note: to_buf and sync_error_buf hold intermediate states, but the
            // ending state is:
            //    - new_path is in &sync_error_buf
            //    - target_path is in &to_buf

            // Stat target if unspecified.
            const resolved_link_type: enum { file, dir, junction } = switch (args.link_type) {
                .unspecified => auto_detect: {
                    const src = bun.path.joinAbsStringBuf(
                        bun.getcwd(&to_buf) catch @panic("failed to resolve current working directory"),
                        &this.sync_error_buf,
                        &.{
                            new_path_dir,
                            target_path,
                        },
                        .windows,
                    );
                    break :auto_detect switch (bun.sys.directoryExistsAt(bun.invalid_fd, src)) {
                        .err => .file,
                        .result => |is_dir| if (is_dir) .dir else .file,
                    };
                },
                .file => .file,
                .dir => .dir,
                .junction => .junction,
            };
            // preprocessSymlinkDestination
            // - junctions: make absolute with long path prefix
            // - absolute paths: add long path prefix
            // - all: no forward slashes
            const processed_target: [:0]u8 = target: {
                if (resolved_link_type == .junction) {
                    // this is similar to the `const src` above, but these cases
                    // are mutually exclusive, so it isn't repeating any work.
                    const target = bun.path.joinAbsStringBuf(
                        bun.getcwd(&to_buf) catch @panic("failed to resolve current working directory"),
                        this.sync_error_buf[4..],
                        &.{
                            new_path_dir,
                            target_path,
                        },
                        .windows,
                    );
                    this.sync_error_buf[0..4].* = bun.windows.long_path_prefix_u8;
                    this.sync_error_buf[4 + target.len] = 0;
                    break :target this.sync_error_buf[0 .. 4 + target.len :0];
                }
                if (std.fs.path.isAbsolute(target_path)) {
                    // This normalizes slashes and adds the long path prefix
                    break :target args.target_path.sliceZWithForceCopy(&this.sync_error_buf, true);
                }
                @memcpy(this.sync_error_buf[0..target_path.len], target_path);
                this.sync_error_buf[target_path.len] = 0;
                const target_path_z = this.sync_error_buf[0..target_path.len :0];
                bun.path.dangerouslyConvertPathToWindowsInPlace(u8, target_path_z);
                break :target target_path_z;
            };
            return switch (Syscall.symlinkUV(
                processed_target,
                args.new_path.sliceZ(&to_buf),
                switch (resolved_link_type) {
                    .file => 0,
                    .dir => uv.UV_FS_SYMLINK_DIR,
                    .junction => uv.UV_FS_SYMLINK_JUNCTION,
                },
            )) {
                .err => |err| .{ .err = err.withPathDest(args.target_path.slice(), args.new_path.slice()) },
                .result => |result| .{ .result = result },
            };
        }

        return switch (Syscall.symlink(
            args.target_path.sliceZ(&this.sync_error_buf),
            args.new_path.sliceZ(&to_buf),
        )) {
            .result => |result| .{ .result = result },
            .err => |err| .{ .err = err.withPathDest(args.target_path.slice(), args.new_path.slice()) },
        };
    }

    fn truncateInner(this: *NodeFS, path: PathLike, len: u63) Maybe(Return.Truncate) {
        return NodeFSCore.truncate(&this.sync_error_buf, &path, len);
    }
    pub fn truncate(this: *NodeFS, args: Arguments.Truncate, _: Flavor) Maybe(Return.Truncate) {
        return this.truncateInner(args.path, args.len);
    }

    pub fn unlink(this: *NodeFS, args: Arguments.Unlink, _: Flavor) Maybe(Return.Unlink) {
        if (Environment.isWindows) {
            return switch (Syscall.unlink(args.path.sliceZ(&this.sync_error_buf))) {
                .err => |err| .{ .err = err.withPath(args.path.slice()) },
                .result => |result| .{ .result = result },
            };
        }
        return Maybe(Return.Unlink).errnoSysP(system.unlink(args.path.sliceZ(&this.sync_error_buf)), .unlink, args.path.slice()) orelse
            .success;
    }

    pub fn utimes(this: *NodeFS, args: Arguments.Utimes, _: Flavor) Maybe(Return.Utimes) {
        return NodeFSCore.utimes(&this.sync_error_buf, &args);
    }

    pub fn lutimes(this: *NodeFS, args: Arguments.Lutimes, _: Flavor) Maybe(Return.Lutimes) {
        if (comptime Environment.isWindows) {
            var req: uv.fs_t = uv.fs_t.uninitialized;
            defer req.deinit();
            const rc = uv.uv_fs_lutime(
                bun.Async.Loop.get(),
                &req,
                args.path.sliceZ(&this.sync_error_buf).ptr,
                args.atime,
                args.mtime,
                null,
            );
            return if (rc.errno()) |errno|
                .{ .err = Syscall.Error{
                    .errno = errno,
                    .syscall = .utime,
                    .path = args.path.slice(),
                } }
            else
                .success;
        }

        return switch (Syscall.lutimes(args.path.sliceZ(&this.sync_error_buf), args.atime, args.mtime)) {
            .err => |err| .{ .err = err.withPath(args.path.slice()) },
            .result => .success,
        };
    }

    /// This function is `cpSync`, but only if you pass `{ recursive: ..., force: ..., errorOnExist: ..., mode: ... }'
    /// The other options like `filter` use a JS fallback, see `src/js/internal/fs/cp.ts`
    pub fn cp(this: *NodeFS, args: Arguments.Cp, _: Flavor) Maybe(Return.Cp) {
        var copy: NodeFSCopy.Copy = .{
            .sync_error_buf = &this.sync_error_buf,
            .sync_message_buf = &this.sync_message_buf,
            .runtime_io = this.runtime_io,
        };
        return copy.cp(args.toCopyArguments());
    }
};

/// Copied from std.Io.Dir.deleteTree. This function returns `FileNotFound` instead of ignoring it, which
/// is required to match the behavior of Node.js's `fs.rm` { recursive: true, force: false }.
pub fn zigDeleteTree(io: std.Io, self: std.Io.Dir, sub_path: []const u8, kind_hint: std.Io.File.Kind) !void {
    var initial_iterable_dir = (try zigDeleteTreeOpenInitialSubpath(io, self, sub_path, kind_hint)) orelse return;

    const StackItem = struct {
        name: []const u8,
        parent_dir: std.Io.Dir,
        iter: std.Io.Dir.Iterator,

        fn closeAll(items: []@This(), io_: std.Io) void {
            for (items) |*item| item.iter.reader.dir.close(io_);
        }
    };

    var stack_buffer: [16]StackItem = undefined;
    var stack = std.ArrayList(StackItem).initBuffer(&stack_buffer);
    defer StackItem.closeAll(stack.items, io);

    stack.appendAssumeCapacity(.{
        .name = sub_path,
        .parent_dir = self,
        .iter = initial_iterable_dir.iterateAssumeFirstIteration(),
    });

    process_stack: while (stack.items.len != 0) {
        var top = &stack.items[stack.items.len - 1];
        while (try top.iter.next(io)) |entry| {
            var treat_as_dir = entry.kind == .directory;
            handle_entry: while (true) {
                if (treat_as_dir) {
                    if (stack.unusedCapacitySlice().len >= 1) {
                        var iterable_dir = top.iter.reader.dir.openDir(io, entry.name, .{
                            .follow_symlinks = false,
                            .iterate = true,
                        }) catch |err| switch (err) {
                            error.NotDir => {
                                treat_as_dir = false;
                                continue :handle_entry;
                            },
                            error.FileNotFound,
                            error.AccessDenied,
                            error.PermissionDenied,
                            error.SymLinkLoop,
                            error.ProcessFdQuotaExceeded,
                            error.NameTooLong,
                            error.SystemFdQuotaExceeded,
                            error.NoDevice,
                            error.SystemResources,
                            error.Canceled,
                            error.Unexpected,
                            error.BadPathName,
                            error.NetworkNotFound,
                            => |e| return e,
                        };
                        stack.appendAssumeCapacity(.{
                            .name = entry.name,
                            .parent_dir = top.iter.reader.dir,
                            .iter = iterable_dir.iterateAssumeFirstIteration(),
                        });
                        continue :process_stack;
                    } else {
                        try zigDeleteTreeMinStackSizeWithKindHint(io, top.iter.reader.dir, entry.name, entry.kind);
                        break :handle_entry;
                    }
                } else {
                    if (top.iter.reader.dir.deleteFile(io, entry.name)) {
                        break :handle_entry;
                    } else |err| switch (err) {
                        error.IsDir => {
                            treat_as_dir = true;
                            continue :handle_entry;
                        },

                        error.FileNotFound,
                        error.NotDir,
                        error.AccessDenied,
                        error.PermissionDenied,
                        error.SymLinkLoop,
                        error.NameTooLong,
                        error.SystemResources,
                        error.ReadOnlyFileSystem,
                        error.FileSystem,
                        error.FileBusy,
                        error.BadPathName,
                        error.NetworkNotFound,
                        error.Canceled,
                        error.Unexpected,
                        => |e| return e,
                    }
                }
            }
        }

        // On Windows, we can't delete until the dir's handle has been closed, so
        // close it before we try to delete.
        top.iter.reader.dir.close(io);

        // In order to avoid double-closing the directory when cleaning up
        // the stack in the case of an error, we save the relevant portions and
        // pop the value from the stack.
        const parent_dir = top.parent_dir;
        const name = top.name;
        stack.items.len -= 1;

        var need_to_retry: bool = false;
        parent_dir.deleteDir(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            error.DirNotEmpty => need_to_retry = true,
            else => |e| return e,
        };

        if (need_to_retry) {
            // Since we closed the handle that the previous iterator used, we
            // need to re-open the dir and re-create the iterator.
            var iterable_dir = iterable_dir: {
                var treat_as_dir = true;
                handle_entry: while (true) {
                    if (treat_as_dir) {
                        break :iterable_dir parent_dir.openDir(io, name, .{
                            .follow_symlinks = false,
                            .iterate = true,
                        }) catch |err| switch (err) {
                            error.NotDir => {
                                treat_as_dir = false;
                                continue :handle_entry;
                            },
                            error.FileNotFound => {
                                // That's fine, we were trying to remove this directory anyway.
                                continue :process_stack;
                            },

                            error.AccessDenied,
                            error.PermissionDenied,
                            error.SymLinkLoop,
                            error.ProcessFdQuotaExceeded,
                            error.NameTooLong,
                            error.SystemFdQuotaExceeded,
                            error.NoDevice,
                            error.SystemResources,
                            error.Canceled,
                            error.Unexpected,
                            error.BadPathName,
                            error.NetworkNotFound,
                            => |e| return e,
                        };
                    } else {
                        if (parent_dir.deleteFile(io, name)) {
                            continue :process_stack;
                        } else |err| switch (err) {
                            error.FileNotFound => continue :process_stack,
                            error.NotDir => if (Environment.isDebug) unreachable else return error.Unexpected,
                            error.IsDir => {
                                treat_as_dir = true;
                                continue :handle_entry;
                            },

                            error.AccessDenied,
                            error.PermissionDenied,
                            error.SymLinkLoop,
                            error.NameTooLong,
                            error.SystemResources,
                            error.ReadOnlyFileSystem,
                            error.FileSystem,
                            error.FileBusy,
                            error.BadPathName,
                            error.NetworkNotFound,
                            error.Canceled,
                            error.Unexpected,
                            => |e| return e,
                        }
                    }
                }
            };
            // We know there is room on the stack since we are just re-adding
            // the StackItem that we previously popped.
            stack.appendAssumeCapacity(.{
                .name = name,
                .parent_dir = parent_dir,
                .iter = iterable_dir.iterateAssumeFirstIteration(),
            });
            continue :process_stack;
        }
    }
}

fn zigDeleteTreeOpenInitialSubpath(io: std.Io, self: std.Io.Dir, sub_path: []const u8, kind_hint: std.Io.File.Kind) !?std.Io.Dir {
    return iterable_dir: {
        // Treat as a file by default
        var treat_as_dir = kind_hint == .directory;

        handle_entry: while (true) {
            if (treat_as_dir) {
                break :iterable_dir self.openDir(io, sub_path, .{
                    .follow_symlinks = false,
                    .iterate = true,
                }) catch |err| switch (err) {
                    error.NotDir,
                    error.FileNotFound,
                    error.AccessDenied,
                    error.PermissionDenied,
                    error.SymLinkLoop,
                    error.ProcessFdQuotaExceeded,
                    error.NameTooLong,
                    error.SystemFdQuotaExceeded,
                    error.NoDevice,
                    error.SystemResources,
                    error.Canceled,
                    error.Unexpected,
                    error.BadPathName,
                    error.NetworkNotFound,
                    => |e| return e,
                };
            } else {
                if (self.deleteFile(io, sub_path)) {
                    return null;
                } else |err| switch (err) {
                    error.IsDir => {
                        treat_as_dir = true;
                        continue :handle_entry;
                    },

                    error.FileNotFound,
                    error.AccessDenied,
                    error.PermissionDenied,
                    error.SymLinkLoop,
                    error.NameTooLong,
                    error.SystemResources,
                    error.Canceled,
                    error.ReadOnlyFileSystem,
                    error.NotDir,
                    error.FileSystem,
                    error.FileBusy,
                    error.BadPathName,
                    error.NetworkNotFound,
                    error.Unexpected,
                    => |e| return e,
                }
            }
        }
    };
}

fn zigDeleteTreeMinStackSizeWithKindHint(io: std.Io, self: std.Io.Dir, sub_path: []const u8, kind_hint: std.Io.File.Kind) !void {
    start_over: while (true) {
        var dir = (try zigDeleteTreeOpenInitialSubpath(io, self, sub_path, kind_hint)) orelse return;
        var cleanup_dir_parent: ?std.Io.Dir = null;
        defer if (cleanup_dir_parent) |*d| d.close(io);

        var cleanup_dir = true;
        defer if (cleanup_dir) dir.close(io);

        // Valid use of MAX_PATH_BYTES because dir_name_buf will only
        // ever store a single path component that was returned from the
        // filesystem.
        var dir_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dir_name: []const u8 = sub_path;

        // Here we must avoid recursion, in order to provide O(1) memory guarantee of this function.
        // Go through each entry and if it is not a directory, delete it. If it is a directory,
        // open it, and close the original directory. Repeat. Then start the entire operation over.

        scan_dir: while (true) {
            var dir_it = dir.iterateAssumeFirstIteration();
            dir_it: while (try dir_it.next(io)) |entry| {
                var treat_as_dir = entry.kind == .directory;
                handle_entry: while (true) {
                    if (treat_as_dir) {
                        const new_dir = dir.openDir(io, entry.name, .{
                            .follow_symlinks = false,
                            .iterate = true,
                        }) catch |err| switch (err) {
                            error.NotDir => {
                                treat_as_dir = false;
                                continue :handle_entry;
                            },
                            error.FileNotFound => {
                                // That's fine, we were trying to remove this directory anyway.
                                continue :dir_it;
                            },

                            error.AccessDenied,
                            error.PermissionDenied,
                            error.SymLinkLoop,
                            error.ProcessFdQuotaExceeded,
                            error.NameTooLong,
                            error.SystemFdQuotaExceeded,
                            error.NoDevice,
                            error.SystemResources,
                            error.Canceled,
                            error.Unexpected,
                            error.BadPathName,
                            error.NetworkNotFound,
                            => |e| return e,
                        };
                        if (cleanup_dir_parent) |*d| d.close(io);
                        cleanup_dir_parent = dir;
                        dir = new_dir;
                        const result = dir_name_buf[0..entry.name.len];
                        @memcpy(result, entry.name);
                        dir_name = result;
                        continue :scan_dir;
                    } else {
                        if (dir.deleteFile(io, entry.name)) {
                            continue :dir_it;
                        } else |err| switch (err) {
                            error.FileNotFound => continue :dir_it,
                            error.NotDir => if (Environment.isDebug) unreachable else return error.Unexpected,

                            error.IsDir => {
                                treat_as_dir = true;
                                continue :handle_entry;
                            },

                            error.AccessDenied,
                            error.PermissionDenied,
                            error.SymLinkLoop,
                            error.NameTooLong,
                            error.SystemResources,
                            error.ReadOnlyFileSystem,
                            error.FileSystem,
                            error.FileBusy,
                            error.BadPathName,
                            error.NetworkNotFound,
                            error.Canceled,
                            error.Unexpected,
                            => |e| return e,
                        }
                    }
                }
            }
            // Reached the end of the directory entries, which means we successfully deleted all of them.
            // Now to remove the directory itself.
            dir.close(io);
            cleanup_dir = false;

            if (cleanup_dir_parent) |d| {
                d.deleteDir(io, dir_name) catch |err| switch (err) {
                    // These two things can happen due to file system race conditions.
                    error.FileNotFound, error.DirNotEmpty => continue :start_over,
                    else => |e| return e,
                };
                continue :start_over;
            } else {
                self.deleteDir(io, sub_path) catch |err| switch (err) {
                    error.FileNotFound => return,
                    error.DirNotEmpty => continue :start_over,
                    else => |e| return e,
                };
                return;
            }
        }
    }
}

const Syscall = if (Environment.isWindows) bun.sys.sys_uv else bun.sys;

const ReadPosition = i64;
const NodeFSFunctionEnum = std.meta.DeclEnum(NodeFS);

const string = []const u8;

const DirIterator = @import("./dir_iterator.zig");
const FileSystem = @import("../../resolver/fs.zig").FileSystem;
const BlobSize = @import("../webcore/BlobSize.zig");
const webcore_encoding = @import("../webcore/encoding.zig");
const NodeFSCore = @import("./NodeFSCore.zig");
const NodeFSAbort = @import("./NodeFSAbort.zig");
const NodeFSCopy = @import("./NodeFSCopy.zig");
pub const NodeTypes = @import("./types.zig");
const NodeStats = @import("./Stat.zig").Stats;
const NodeStatFS = @import("./StatFS.zig").StatFS;

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const Mode = bun.Mode;
const PathString = bun.PathString;
const c = bun.c;
const strings = bun.strings;
pub const NodeBuffer = NodeTypes.NodeBuffer;

const Encoding = NodeTypes.Encoding;
const FileSystemFlags = NodeTypes.FileSystemFlags;
const PathLike = NodeTypes.PathLike;
const PathOrFileDescriptor = NodeTypes.PathOrFileDescriptor;
const StringOrBuffer = NodeTypes.StringOrBuffer;
const TimeLikeModule = @import("./time_like.zig");
const TimeLike = TimeLikeModule.TimeLike;
const gid_t = if (Environment.isPosix) std.posix.gid_t else bun.windows.libuv.uv_gid_t;
const uid_t = if (Environment.isPosix) std.posix.uid_t else bun.windows.libuv.uv_uid_t;

const E = bun.sys.E;
const Maybe = bun.sys.Maybe;
const SystemErrno = bun.sys.SystemErrno;

const windows = bun.windows;
const uv = bun.windows.libuv;

const std = @import("std");
const linux = std.os.linux;

const posix = std.posix;
const system = std.posix.system;
const NodeJSFSBindings = bun.bindgen.Module("NodeJSFS");
const NodeJSFSReadSchema = NodeJSFSBindings.class("NodeJSFS").member("read");
const NodeJSFSReadvSchema = NodeJSFSBindings.class("NodeJSFS").member("readv");
const NodeJSFSWritevSchema = NodeJSFSBindings.class("NodeJSFS").member("writev");
const OwnedReadBufferLease = bun.bindgen.ResultType(NodeJSFSReadSchema.args[1].ArgumentType);
const ReadVectorBufferSequenceSchema = NodeJSFSReadvSchema.args[1].ArgumentType;
const VectorBufferSequenceSchema = NodeJSFSWritevSchema.args[1].ArgumentType;
const OwnedReadVectorBufferLease = bun.bindgen.ResultType(ReadVectorBufferSequenceSchema.child);
const OwnedWriteVectorBufferLease = bun.bindgen.ResultType(VectorBufferSequenceSchema.child);
