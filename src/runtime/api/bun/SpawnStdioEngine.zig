pub const Stdio = union(enum) {
    inherit,
    capture: struct { buf: *bun.ByteList },
    ignore,
    fd: bun.FD,
    dup2: struct {
        out: bun.jsc.Subprocess.StdioKind,
        to: bun.jsc.Subprocess.StdioKind,
    },
    blob: jsc.WebCore.Blob.Any,
    retained_bytes: bun.bindgen.OwnedLease(u8),
    memfd: bun.FD,
    pipe,
    ipc,
    readable_stream: jsc.WebCore.ReadableStream.Strong,

    const log = bun.sys.syslog;

    pub const Result = union(enum) {
        result: bun.spawn.SpawnOptions.Stdio,
        err: ToSpawnOptsError,
    };

    pub const ToSpawnOptsError = enum {
        stdin_used_as_out,
        out_used_as_stdin,
        blob_used_as_out,
    };

    pub fn byteSlice(this: *const Stdio) []const u8 {
        return switch (this.*) {
            .capture => this.capture.buf.slice(),
            .retained_bytes => this.retained_bytes.unsafePtr("Stdio owns the input lease until synchronous memfd writes finish, then releases it"),
            .blob => this.blob.slice(),
            else => &[_]u8{},
        };
    }

    pub fn deinit(this: *Stdio) void {
        switch (this.*) {
            .retained_bytes => |*bytes| bytes.deinit(),
            .blob => |*blob| {
                blob.detach();
            },
            .memfd => |fd| {
                _ = fd.closeAllowingStandardIo(null);
            },
            .readable_stream => |*stream| stream.deinit(),
            else => {},
        }
        this.* = .ignore;
    }

    pub fn canUseMemfd(this: *const @This(), is_sync: bool, has_max_buffer: bool) bool {
        if (comptime !Environment.isLinux) {
            return false;
        }

        return switch (this.*) {
            .blob => !this.blob.needsToReadFile(),
            .memfd, .retained_bytes => true,
            .pipe => is_sync and !has_max_buffer,
            else => false,
        };
    }

    pub fn useMemfd(this: *@This(), index: u32) bool {
        if (comptime !Environment.isLinux) {
            return false;
        }
        if (!bun.sys.canUseMemfd()) return false;
        const label = switch (index) {
            0 => "spawn_stdio_stdin",
            1 => "spawn_stdio_stdout",
            2 => "spawn_stdio_stderr",
            else => "spawn_stdio_memory_file",
        };

        const fd = bun.sys.memfd_create(label, .cross_process).unwrap() catch return false;

        var remain = this.byteSlice();

        if (remain.len > 0)
            // Hint at the size of the file
            _ = bun.sys.ftruncate(fd, @intCast(remain.len));

        // Dump all the bytes in there
        var written: isize = 0;
        while (remain.len > 0) {
            switch (bun.sys.pwrite(fd, remain, written)) {
                .err => |err| {
                    if (err.getErrno() == .AGAIN) {
                        continue;
                    }

                    Output.debugWarn("Failed to write to memfd: {s}", .{@tagName(err.getErrno())});
                    fd.close();
                    return false;
                },
                .result => |result| {
                    if (result == 0) {
                        Output.debugWarn("Failed to write to memfd: EOF", .{});
                        fd.close();
                        return false;
                    }
                    written += @intCast(result);
                    remain = remain[result..];
                },
            }
        }

        switch (this.*) {
            .retained_bytes => this.retained_bytes.deinit(),
            .blob => this.blob.detach(),
            else => {},
        }

        this.* = .{ .memfd = fd };
        return true;
    }

    fn toPosix(
        stdio: *@This(),
        i: i32,
    ) Result {
        return .{
            .result = switch (stdio.*) {
                .blob => |blob| brk: {
                    if (blob.needsToReadFile()) {
                        if (blob.store()) |store| {
                            if (store.data.file.pathlike == .fd) {
                                if (isSameStandardDescriptor(i, store.data.file.pathlike.fd)) {
                                    break :brk .{ .inherit = {} };
                                }

                                if (store.data.file.pathlike.fd.stdioTag()) |tag| switch (tag) {
                                    .std_in => {
                                        if (i == 1 or i == 2) {
                                            return .{ .err = .stdin_used_as_out };
                                        }
                                    },
                                    .std_out, .std_err => {
                                        if (i == 0) {
                                            return .{ .err = .out_used_as_stdin };
                                        }
                                    },
                                };

                                break :brk .{ .pipe = store.data.file.pathlike.fd };
                            }

                            break :brk .{ .path = store.data.file.pathlike.path.slice() };
                        }
                    }

                    if (i == 1 or i == 2) {
                        return .{ .err = .blob_used_as_out };
                    }

                    break :brk .{ .buffer = {} };
                },
                .dup2 => .{ .dup2 = .{ .out = stdio.dup2.out, .to = stdio.dup2.to } },
                .capture, .pipe, .retained_bytes, .readable_stream => .{ .buffer = {} },
                .ipc => .{ .ipc = {} },
                .fd => |fd| .{ .pipe = fd },
                .memfd => |fd| .{ .pipe = fd },
                .inherit => .{ .inherit = {} },
                .ignore => .{ .ignore = {} },
            },
        };
    }

    fn toWindows(
        stdio: *@This(),
        i: i32,
    ) Result {
        return .{
            .result = switch (stdio.*) {
                .blob => |blob| brk: {
                    if (blob.needsToReadFile()) {
                        if (blob.store()) |store| {
                            if (store.data.file.pathlike == .fd) {
                                if (isSameStandardDescriptor(i, store.data.file.pathlike.fd)) {
                                    break :brk .{ .inherit = {} };
                                }

                                if (store.data.file.pathlike.fd.stdioTag()) |tag| switch (tag) {
                                    .std_in => {
                                        if (i == 1 or i == 2) {
                                            return .{ .err = .stdin_used_as_out };
                                        }
                                    },
                                    .std_out, .std_err => {
                                        if (i == 0) {
                                            return .{ .err = .out_used_as_stdin };
                                        }
                                    },
                                };

                                break :brk .{ .pipe = store.data.file.pathlike.fd };
                            }

                            break :brk .{ .path = store.data.file.pathlike.path.slice() };
                        }
                    }

                    if (i == 1 or i == 2) {
                        return .{ .err = .blob_used_as_out };
                    }

                    break :brk .{ .buffer = createZeroedPipe() };
                },
                .ipc => .{ .ipc = createZeroedPipe() },
                .capture, .pipe, .retained_bytes, .readable_stream => .{ .buffer = createZeroedPipe() },
                .fd => |fd| .{ .pipe = fd },
                .dup2 => .{ .dup2 = .{ .out = stdio.dup2.out, .to = stdio.dup2.to } },
                .inherit => .{ .inherit = {} },
                .ignore => .{ .ignore = {} },

                .memfd => @panic("This should never happen"),
            },
        };
    }

    pub fn toSync(this: *@This(), i: u32) void {
        // Piping an empty stdin doesn't make sense
        if (i == 0 and this.* == .pipe) {
            this.* = .{ .ignore = {} };
        }
    }

    /// On windows this function allocate memory ensure that .deinit() is called or ownership is passed for all *uv.Pipe
    pub fn asSpawnOption(
        stdio: *@This(),
        i: i32,
    ) Stdio.Result {
        if (comptime Environment.isWindows) {
            return stdio.toWindows(i);
        } else {
            return stdio.toPosix(i);
        }
    }

    pub fn isPiped(self: Stdio) bool {
        return switch (self) {
            .capture, .retained_bytes, .blob, .pipe, .readable_stream => true,
            .ipc => Environment.isWindows,
            else => false,
        };
    }

    /// `stream_value` must be a ReadableStream wrapper.
    pub fn extractReadableStreamValue(out_stdio: *Stdio, globalThis: *jsc.JSGlobalObject, context: anytype, i: i32, stream_value: anytype, is_sync: bool) bun.bindgen.CallError(@TypeOf(context))!void {
        var retained_stream = try jsc.WebCore.ReadableStream.Strong.initOwned(try stream_value.toOwned());
        defer retained_stream.deinit();
        if (try retained_stream.toAnyBlob(globalThis)) |blob| {
            if (out_stdio.assignBlob(blob, i)) |err| return failConfiguration(context, err);
            return;
        }

        if (i > 2) return failExtraResource(context, "ReadableStream", i);
        if (i == 1) return context.fail(.stdio_stream_stdout, {});
        if (i == 2) return context.fail(.stdio_stream_stderr, {});

        if (is_sync) {
            return failWithName(context, .stdio_stream_sync_named, "'{s}' ReadableStream cannot be used in sync mode", "stdin");
        }

        if (retained_stream.isDisturbed(globalThis)) {
            return failWithName(context, .stdio_stream_used, "'{s}' ReadableStream has already been used", "stdin");
        }
        out_stdio.* = .{ .readable_stream = retained_stream.take() };
    }

    fn failWithName(
        context: anytype,
        comptime tag: anytype,
        comptime fmt: []const u8,
        name: []const u8,
    ) bun.bindgen.CallError(@TypeOf(context)) {
        var message_buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, fmt, .{name}) catch unreachable;
        return context.fail(tag, try bun.bindgen.DOMString.fromUTF8(message));
    }

    pub fn failExtraResource(context: anytype, comptime resource: []const u8, index: i32) bun.bindgen.CallError(@TypeOf(context)) {
        var message_buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, resource ++ " cannot be used for stdio[{d}] yet", .{index}) catch unreachable;
        return context.fail(.stdio_unsupported_resource, try bun.bindgen.DOMString.fromUTF8(message));
    }

    pub fn extractBodyValue(out_stdio: *Stdio, globalThis: *jsc.JSGlobalObject, context: anytype, i: i32, body: *jsc.WebCore.Body.Value, is_sync: bool) bun.bindgen.CallError(@TypeOf(context))!void {
        try body.toBlobIfPossible();

        if (try body.tryUseAsAnyBlob()) |blob| {
            if (out_stdio.assignBlob(blob, i)) |err| return failConfiguration(context, err);
            return;
        }

        switch (body.*) {
            .Null, .Empty => {
                out_stdio.* = .{ .ignore = {} };
                return;
            },
            .Used => {
                return context.fail(.stdio_body_used, {});
            },
            .Error => {
                var reason = try body.Error.toRoot(globalThis);
                defer reason.deinit();
                return reason.throwException(context);
            },

            .Blob, .WTFStringImpl, .InternalBlob => unreachable, // handled above.
            .Locked => {
                if (is_sync) {
                    return context.fail(.stdio_stream_sync, {});
                }

                switch (i) {
                    0 => {},
                    1 => {
                        return context.fail(.stdio_stream_stdout, {});
                    },
                    2 => {
                        return context.fail(.stdio_stream_stderr, {});
                    },
                    else => return failExtraResource(context, "ReadableStream", i),
                }

                const stream = (try body.toReadableStream(globalThis)) orelse
                    return context.fail(.stdio_stream_create_failed, {});
                var retained = try jsc.WebCore.ReadableStream.Strong.initOwned(stream);
                if (retained.isDisturbed(globalThis)) {
                    retained.deinit();
                    return context.fail(.stdio_stream_body_used, {});
                }

                out_stdio.* = .{ .readable_stream = retained.take() };
            },
        }

        return;
    }

    pub fn failConfiguration(context: anytype, err: ToSpawnOptsError) bun.bindgen.CallError(@TypeOf(context)) {
        return switch (err) {
            .stdin_used_as_out => context.fail(.stdio_stdin_misused, {}),
            .out_used_as_stdin => context.fail(.stdio_out_misused, {}),
            .blob_used_as_out => context.fail(.stdio_blob_output, {}),
        };
    }

    pub fn assignBlob(stdio: *Stdio, blob: jsc.WebCore.Blob.Any, i: i32) ?ToSpawnOptsError {
        var owned_blob = blob;

        if (owned_blob.needsToReadFile()) {
            if (owned_blob.store()) |store| {
                if (store.data.file.pathlike == .fd) {
                    if (!isSameStandardDescriptor(i, store.data.file.pathlike.fd)) {
                        if (store.data.file.pathlike.fd.stdioTag()) |tag| switch (tag) {
                            .std_in,
                            => if (i == 1 or i == 2) {
                                owned_blob.detach();
                                return .stdin_used_as_out;
                            },
                            .std_out,
                            .std_err,
                            => if (i == 0) {
                                owned_blob.detach();
                                return .out_used_as_stdin;
                            },
                        };
                    }
                }
                stdio.* = .{ .blob = owned_blob };
                return null;
            }
        }

        if (i == 1 or i == 2) {
            owned_blob.detach();
            return .blob_used_as_out;
        }

        // Instead of writing an empty blob, lets just make it /dev/null
        if (owned_blob.fastSize() == 0) {
            owned_blob.detach();
            stdio.* = .{ .ignore = {} };
            return null;
        }

        stdio.* = .{ .blob = owned_blob };
        return null;
    }

    fn isSameStandardDescriptor(index: i32, fd: bun.FD) bool {
        const standard = bun.FD.Stdio.fromInt(index) orelse return false;
        return fd == standard.fd();
    }
};

/// Allocate a zero-initialized uv.Pipe. Zero-init ensures `pipe.loop` is null
/// for pipes that never reach `uv_pipe_init`, so `closeAndDestroy` can tell
/// whether `uv_close` is needed.
fn createZeroedPipe() *uv.Pipe {
    return bun.new(uv.Pipe, std.mem.zeroes(uv.Pipe));
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const uv = bun.windows.libuv;

const jsc = bun.jsc;
