pub fn WithIntegration(comptime Integration: type, comptime PipeReader: type) type {
    const Stdio = Integration.Stdio;
    return union(enum) {
        const Readable = @This();

        fd: bun.FD,
        memfd: bun.FD,
        pipe: *PipeReader,
        inherit: void,
        ignore: void,
        closed: void,
        buffer: CowString,

        pub const BufferedBytes = union(enum) {
            bytes: bindgen.OwnedBytes,
            unavailable,
            err: bun.sys.Error,
        };

        fn copyAndFreeDefaultBytes(bytes: []u8) bun.OOM!bindgen.OwnedBytes {
            defer if (bytes.len > 0) bun.default_allocator.free(bytes);
            return bindgen.OwnedBytes.fromSlice(bytes);
        }

        pub fn memoryCost(this: *const Readable) usize {
            return switch (this.*) {
                .pipe => @sizeOf(PipeReader) + this.pipe.memoryCost(),
                .buffer => this.buffer.length(),
                else => 0,
            };
        }

        pub fn hasPendingActivity(this: *const Readable) bool {
            return switch (this.*) {
                .pipe => this.pipe.hasPendingActivity(),
                else => false,
            };
        }

        pub fn ref(this: *Readable) void {
            switch (this.*) {
                .pipe => {
                    this.pipe.updateRef(true);
                },
                else => {},
            }
        }

        pub fn unref(this: *Readable) void {
            switch (this.*) {
                .pipe => {
                    this.pipe.updateRef(false);
                },
                else => {},
            }
        }

        pub fn init(stdio: *Stdio, event_loop: Integration.LoopHandle, process: Integration.ProcessHandle, result: *StdioResult, _: std.mem.Allocator, max_size: ?*MaxBuf, _: bool) bun.OOM!Readable {
            Integration.assertStdioResult(result.*);

            if (comptime Environment.isPosix) {
                if (stdio.* == .pipe) {
                    _ = bun.sys.setNonblocking(result.owned_fd);
                }
            }

            return switch (stdio.*) {
                .inherit => Readable{ .inherit = {} },
                .ignore, .ipc => Readable{ .ignore = {} },
                .fd => |fd| Readable{ .fd = fd },
                .memfd => if (Environment.isPosix) memfd: {
                    const fd = stdio.memfd;
                    stdio.* = .ignore;
                    _ = result.take();
                    break :memfd Readable{ .memfd = fd };
                } else Readable{ .ignore = {} },
                .dup2 => |dup2| if (Environment.isPosix) Output.panic("TODO: implement dup2 support in Stdio readable", .{}) else Readable{ .fd = dup2.out.toFd() },
                .pipe => Readable{ .pipe = try PipeReader.create(event_loop, process, result, max_size) },
                .blob => |*blob| file: {
                    bun.assert(blob.needsToReadFile());
                    const store = blob.store() orelse unreachable;
                    break :file switch (store.data.file.pathlike) {
                        .fd => |fd| .{ .fd = fd },
                        .path => .ignore,
                    };
                },
                .retained_bytes => unreachable,
                .capture => Output.panic("TODO: implement capture support in Stdio readable", .{}),
                .readable_stream => Readable{ .ignore = {} }, // ReadableStream is handled separately
            };
        }

        pub fn onClose(this: *Readable, _: ?bun.sys.Error) void {
            this.* = .closed;
        }

        pub fn onReady(_: *Readable, _: ?usize, _: ?usize) void {}

        pub fn onStart(_: *Readable) void {}

        pub fn close(this: *Readable) void {
            switch (this.*) {
                .memfd => |fd| {
                    this.* = .{ .closed = {} };
                    _ = fd.closeAllowingStandardIo(null);
                },
                .fd => {
                    this.* = .{ .closed = {} };
                },
                .pipe => {
                    this.pipe.close();
                },
                else => {},
            }
        }

        pub fn finalize(this: *Readable) void {
            switch (this.*) {
                .memfd => |fd| {
                    this.* = .{ .closed = {} };
                    _ = fd.closeAllowingStandardIo(null);
                },
                .fd => {
                    this.* = .{ .closed = {} };
                },
                .pipe => |pipe| {
                    defer pipe.detach();
                    this.* = .{ .closed = {} };
                },
                .buffer => |*buf| {
                    buf.deinit(bun.default_allocator);
                },
                else => {},
            }
        }

        pub fn toBindingResult(this: *Readable, context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            return switch (this.*) {
                .fd => |fd| .{ .fd = try this.transferFD(context, fd) },
                .memfd => switch (try this.takeBufferedBytes()) {
                    .bytes => |bytes| .{ .node_buffer = bytes },
                    .unavailable => .{ .undefined = true },
                    .err => |err| context.fail(.system, try bindgen.SystemError.fromSysError(err)),
                },
                .pipe => |pipe| stream: {
                    this.* = .{ .closed = {} };
                    break :stream .{ .stream = try pipe.toReadableStreamResult(context) };
                },
                .buffer => |*buffer| stream: {
                    defer this.* = .{ .closed = {} };
                    if (buffer.length() == 0) {
                        break :stream .{ .stream = try Integration.emptyStream(context, false) };
                    }
                    const owned = try buffer.takeSlice(bun.default_allocator);
                    break :stream .{ .stream = try Integration.streamFromOwnedSlice(context, owned) };
                },
                .inherit, .ignore, .closed => .{ .undefined = true },
            };
        }

        fn transferFD(this: *Readable, context: anytype, fd: bun.FD) bun.bindgen.CallError(@TypeOf(context))!i32 {
            return switch (Integration.fdToBindingInt32(fd)) {
                .result => |owned| owned,
                .err => |err| {
                    this.* = .{ .closed = {} };
                    return context.fail(.system, try bindgen.SystemError.fromSysError(err));
                },
            };
        }

        pub fn takeBufferedBytes(this: *Readable) bun.OOM!BufferedBytes {
            return switch (this.*) {
                .memfd => |fd| try this.takeMemfdBytes(fd),
                .pipe => |pipe| blk: {
                    const bytes = pipe.takeBuffer();
                    pipe.detach();
                    this.* = .{ .closed = {} };
                    break :blk if (bytes) |owned|
                        .{ .bytes = try copyAndFreeDefaultBytes(owned) }
                    else
                        .unavailable;
                },
                .buffer => |*buf| blk: {
                    const owned = try buf.takeSlice(bun.default_allocator);
                    this.* = .{ .closed = {} };
                    break :blk .{ .bytes = try copyAndFreeDefaultBytes(owned) };
                },
                .fd => {
                    this.* = .{ .closed = {} };
                    return .unavailable;
                },
                .inherit, .ignore, .closed => .unavailable,
            };
        }

        fn takeMemfdBytes(this: *Readable, fd: bun.FD) bun.OOM!BufferedBytes {
            if (comptime Environment.isLinux) return this.takeMemfdBytesLinux(fd);
            unreachable;
        }

        fn takeMemfdBytesLinux(this: *Readable, fd: bun.FD) bun.OOM!BufferedBytes {
            this.* = .{ .closed = {} };
            defer _ = fd.closeAllowingStandardIo(null);

            const stat = switch (bun.sys.fstat(fd)) {
                .result => |value| value,
                .err => |err| return .{ .err = err },
            };
            const size = std.math.cast(usize, stat.size) orelse
                return .{ .err = bun.sys.Error.fromCode(.OVERFLOW, .fstat) };
            if (size == 0) return .{ .bytes = bindgen.OwnedBytes.empty() };

            if (size < mmap_threshold) {
                const bytes = try bun.default_allocator.alloc(u8, size);
                var offset: usize = 0;
                while (offset < bytes.len) {
                    switch (bun.sys.pread(fd, bytes[offset..], @intCast(offset))) {
                        .result => |amount| {
                            if (amount == 0) {
                                @memset(bytes[offset..], 0);
                                break;
                            }
                            offset += amount;
                        },
                        .err => |err| {
                            bun.default_allocator.free(bytes);
                            return .{ .err = err };
                        },
                    }
                }
                return .{ .bytes = try copyAndFreeDefaultBytes(bytes) };
            }

            const mapping = switch (bun.sys.mmap(
                null,
                size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            )) {
                .result => |value| value,
                .err => |err| return .{ .err = err },
            };
            return .{ .bytes = bindgen.OwnedBytes.fromMappedSlice(mapping) catch |err| {
                _ = bun.sys.munmap(mapping);
                return err;
            } };
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const CowString = bun.ptr.CowString;
const bindgen = bun.bindgen;
const BlobSize = @import("../../../webcore/BlobSize.zig").SizeType;

const mmap_threshold = 4 * 1024 * 1024;

const MaxBuf = bun.io.MaxBuf;
const StdioResult = bun.spawn.process.SpawnProcessResult.StdioResult;
