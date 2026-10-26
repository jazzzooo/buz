//! Streams an already-open file descriptor to a uWS `AnyResponse`, handling
//! backpressure, client aborts, and fd lifetime. Shared by `FileRoute` (static
//! file routes) and `RequestContext` (file-blob bodies returned from `fetch`
//! handlers) so both get the same abort-safe lifecycle and so the SSL/Windows
//! path streams instead of buffering the whole file.
//!
//! The caller writes status + headers first, then hands off body streaming by
//! calling `start()`. Exactly one terminal callback fires. Completion and
//! error callbacks receive no response handle because it may already be closed.

const FileResponseStream = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

ref_count: RefCount,
resp: AnyResponse,
runtime_loop: bun.RuntimeLoopHandle,
fd: bun.FD,
auto_close: bool,
idle_timeout: u8,

ctx: Context,
on_complete: *const fn (Context) void,
on_abort: ?*const fn (Context, AnyResponse) void,
on_error: *const fn (Context, Failure) void,

mode: Mode,
reader: bun.io.BufferedReader = bun.io.BufferedReader.init(FileResponseStream),
max_size: ?u64 = null,

state: packed struct(u8) {
    response_done: bool = false,
    finished: bool = false,
    errored: bool = false,
    resp_detached: bool = false,
    reader_active: bool = false,
    _: u3 = 0,
} = .{},

const Mode = union(enum) { reader, sendfile: Sendfile };

pub const Failure = union(enum) {
    system: bun.sys.Error,
    out_of_memory,
    connection_closed,
    write_failed,
    unexpected_eof,
};

const Sendfile = struct {
    response: *uws.NewApp(false).Response,
    socket_fd: bun.FD,
    remain: u64,
    offset: u64,
    written: u64 = 0,
    headers_ready: bool = false,
    has_set_on_writable: bool = false,
};

pub const StartOptions = struct {
    fd: bun.FD,
    auto_close: bool = true,
    resp: AnyResponse,
    runtime_loop: bun.RuntimeLoopHandle,
    file_type: bun.io.FileType,
    pollable: bool,
    /// Byte offset into the file to begin reading from.
    offset: u64 = 0,
    /// Maximum bytes to send; `null` reads to EOF. For regular files this
    /// should be `stat.size - offset` (after Range/slice clamping).
    length: ?u64 = null,
    idle_timeout: u8,
    ctx: Context,
    on_complete: *const fn (Context) void,
    /// Fires instead of `on_complete` when the client disconnects mid-stream.
    /// If null, abort is reported via `on_complete`.
    on_abort: ?*const fn (Context, AnyResponse) void = null,
    on_error: *const fn (Context, Failure) void,
};

pub fn start(opts: StartOptions) void {
    const sendfile_response = sendfileResponse(opts.resp, opts.file_type, opts.length);

    opts.resp.clearOnWritable();
    opts.resp.clearAborted();
    opts.resp.clearTimeout();

    var this = bun.tryNew(FileResponseStream, .{
        .ref_count = .init(),
        .resp = opts.resp,
        .runtime_loop = opts.runtime_loop,
        .fd = opts.fd,
        .auto_close = opts.auto_close,
        .idle_timeout = opts.idle_timeout,
        .ctx = opts.ctx,
        .on_complete = opts.on_complete,
        .on_abort = opts.on_abort,
        .on_error = opts.on_error,
        .mode = if (sendfile_response) |response| .{ .sendfile = .{
            .response = response,
            .socket_fd = response.getNativeHandle(),
            .offset = opts.offset,
            .remain = opts.length.?,
        } } else .reader,
    }) catch {
        if (opts.auto_close) opts.fd.close();
        opts.resp.forceClose();
        opts.on_error(opts.ctx, .out_of_memory);
        return;
    };

    this.resp.timeout(this.idle_timeout);
    this.resp.onAborted(*FileResponseStream, onAborted, this);

    log("start mode={s} len={?d}", .{ @tagName(this.mode), opts.length });

    if (sendfile_response != null) {
        _ = this.onSendfile();
        return;
    }

    this.max_size = opts.length;
    if (opts.length) |length| {
        if (length == 0) {
            this.completeReader("");
            return;
        }
    }
    this.reader.flags.close_handle = false; // we own fd via auto_close
    this.reader.flags.pollable = opts.pollable;
    this.reader.flags.nonblocking = opts.file_type != .file;
    if (comptime bun.Environment.isPosix) {
        if (opts.file_type == .socket) this.reader.flags.socket = true;
    }
    this.reader.setParent(this);

    this.ref();
    defer this.deref();

    this.state.reader_active = true;
    this.ref();
    switch (if (opts.file_type == .file or opts.offset > 0)
        this.reader.startFileOffset(this.fd, opts.pollable, opts.offset)
    else
        this.reader.start(this.fd, opts.pollable)) {
        .err => |err| {
            this.failWith(.{ .system = err });
            if (this.state.reader_active) {
                this.state.reader_active = false;
                this.deref();
            }
            return;
        },
        .result => {},
    }

    if (this.state.response_done) return;
    this.reader.updateRef(true);

    if (comptime bun.Environment.isPosix) {
        if (this.reader.handle.getPoll()) |poll| {
            if (this.reader.flags.nonblocking) poll.flags.insert(.nonblocking);
            switch (opts.file_type) {
                .socket => poll.flags.insert(.socket),
                .nonblocking_pipe, .pipe => poll.flags.insert(.fifo),
                .file => {},
            }
        }
    }

    this.reader.read();
}

fn sendfileResponse(resp: AnyResponse, file_type: bun.io.FileType, length: ?u64) ?*uws.NewApp(false).Response {
    if (comptime bun.Environment.isWindows) return null;
    // sendfile() needs a real socket fd; SSL writes go through BIO and H3
    // through lsquic stream frames — neither has one.
    if (resp != .TCP) return null;
    if (file_type != .file) return null;
    if (!resp.state().hasWrittenContentLengthHeader()) return null;
    const len = length orelse return null;
    // Below ~1MB the syscall + dual-readiness overhead doesn't pay off.
    return if (len >= 1 << 20) resp.TCP else null;
}

// ───────────────────────── reader backend ─────────────────────────

pub fn onReadChunk(this: *FileResponseStream, chunk_: []const u8, state_: bun.io.ReadState) bool {
    this.ref();
    defer this.deref();

    if (this.state.response_done) return false;

    const chunk, const state = brk: {
        if (this.max_size) |*max| {
            const c = chunk_[0..@min(chunk_.len, max.*)];
            max.* -|= c.len;
            if (state_ != .eof and max.* == 0) {
                break :brk .{ c, .eof };
            }
            break :brk .{ c, state_ };
        }
        break :brk .{ chunk_, state_ };
    };

    this.resp.timeout(this.idle_timeout);

    if (state == .eof) {
        this.completeReader(chunk);
        return false;
    }

    const result = this.resp.write(chunk) catch |err| {
        this.failWrite(err);
        return false;
    };
    switch (result) {
        .backpressure => {
            this.resp.onWritable(*FileResponseStream, onWritable, this);
            this.reader.pause();
            return false;
        },
        .want_more => return true,
    }
}

pub fn onReaderDone(this: *FileResponseStream) void {
    bun.assert(this.state.reader_active);
    this.state.reader_active = false;
    defer this.deref();
    if (this.state.response_done) this.finish() else this.completeReader("");
}

fn completeReader(this: *FileResponseStream, chunk: []const u8) void {
    if (this.max_size) |remaining| {
        if (remaining != 0) return this.failWith(.unexpected_eof);
    }
    this.detachResp();
    this.resp.end(chunk, this.resp.shouldCloseConnection()) catch |err| {
        this.failWrite(err);
        return;
    };
    this.state.response_done = true;
    this.on_complete(this.ctx);
    this.finish();
}

pub fn onReaderError(this: *FileResponseStream, err: bun.sys.Error) void {
    bun.assert(this.state.reader_active);
    this.state.reader_active = false;
    defer this.deref();
    this.failWith(.{ .system = err });
}

fn onWritable(this: *FileResponseStream, _: u64, _: AnyResponse) bool {
    log("onWritable", .{});
    this.ref();
    defer this.deref();

    if (this.mode == .sendfile) return this.onSendfile();

    if (this.state.response_done or this.reader.isDone()) return false;
    this.resp.timeout(this.idle_timeout);
    if (comptime bun.Environment.isPosix) this.reader.unpause();
    this.reader.read();
    return true;
}

// ───────────────────────── sendfile backend ─────────────────────────

fn onSendfile(this: *FileResponseStream) bool {
    const sendfile = &this.mode.sendfile;
    log("onSendfile remain={d} offset={d}", .{ sendfile.remain, sendfile.offset });
    if (this.state.response_done) {
        this.finish();
        return false;
    }

    if (!sendfile.headers_ready) {
        const ready = sendfile.response.prepareForSendfile() catch |err| {
            this.failWrite(err);
            return false;
        };
        if (!ready) return this.armSendfileWritable();
        sendfile.headers_ready = true;
    }

    if (comptime bun.Environment.isLinux) {
        while (true) {
            if (sendfile.remain == 0) {
                this.endSendfile();
                return false;
            }
            const adjusted = @min(sendfile.remain, @as(u64, std.math.maxInt(i32)));
            var off: i64 = @intCast(sendfile.offset);
            const rc = std.os.linux.sendfile(
                sendfile.socket_fd.cast(),
                this.fd.cast(),
                &off,
                adjusted,
            );
            const errno = bun.sys.getErrno(rc);
            const sent: u64 = @intCast(@max(off - @as(i64, @intCast(sendfile.offset)), 0));
            sendfile.offset = @intCast(off);
            sendfile.remain -= sent;
            sendfile.written += sent;

            switch (errno) {
                .SUCCESS => {
                    if (sendfile.remain == 0) {
                        this.endSendfile();
                        return false;
                    }
                    if (sent == 0) {
                        this.failWith(.unexpected_eof);
                        return false;
                    }
                    return this.armSendfileWritable();
                },
                .INTR => continue,
                .AGAIN => return this.armSendfileWritable(),
                else => {
                    this.failWith(.{ .system = .{ .errno = @backingInt(errno), .syscall = .sendfile, .fd = this.fd } });
                    return false;
                },
            }
        }
    } else if (comptime bun.Environment.isMac) {
        while (true) {
            if (sendfile.remain == 0) {
                this.endSendfile();
                return false;
            }
            var sbytes: std.posix.off_t = @intCast(@min(sendfile.remain, @as(u64, std.math.maxInt(i32))));
            const errno = bun.sys.getErrno(std.c.sendfile(
                this.fd.cast(),
                sendfile.socket_fd.cast(),
                @intCast(sendfile.offset),
                &sbytes,
                null,
                0,
            ));
            const sent: u64 = @intCast(sbytes);
            sendfile.offset += sent;
            sendfile.remain -= sent;
            sendfile.written += sent;

            switch (errno) {
                .SUCCESS => {
                    if (sendfile.remain == 0) {
                        this.endSendfile();
                        return false;
                    }
                    if (sent == 0) {
                        this.failWith(.unexpected_eof);
                        return false;
                    }
                    return this.armSendfileWritable();
                },
                .INTR => continue,
                .AGAIN => return this.armSendfileWritable(),
                else => {
                    this.failWith(.{ .system = .{ .errno = @backingInt(errno), .syscall = .sendfile, .fd = this.fd } });
                    return false;
                },
            }
        }
    } else {
        unreachable;
    }
}

fn armSendfileWritable(this: *FileResponseStream) bool {
    log("armSendfileWritable", .{});
    if (!this.mode.sendfile.has_set_on_writable) {
        this.mode.sendfile.has_set_on_writable = true;
        this.resp.onWritable(*FileResponseStream, onWritable, this);
    }
    this.resp.markNeedsMore();
    return true;
}

fn endSendfile(this: *FileResponseStream) void {
    log("endSendfile", .{});
    if (this.state.response_done) return;
    this.detachResp();
    this.mode.sendfile.response.endSendFile(this.mode.sendfile.written, this.resp.shouldCloseConnection()) catch |err| {
        this.failWrite(err);
        return;
    };
    this.state.response_done = true;
    this.on_complete(this.ctx);
    this.finish();
}

// ───────────────────────── lifecycle ─────────────────────────

fn onAborted(this: *FileResponseStream, _: AnyResponse) void {
    log("onAborted", .{});
    if (!this.state.response_done) {
        this.state.response_done = true;
        this.detachResp();
        if (this.on_abort) |callback| callback(this.ctx, this.resp) else this.on_complete(this.ctx);
    }
    this.finish();
}

fn failWrite(this: *FileResponseStream, err: uws.ResponseWriteError) void {
    if (err == error.ConnectionClosed) this.state.resp_detached = true;
    this.failWith(switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.ConnectionClosed => .connection_closed,
        error.WriteFailed => .write_failed,
    });
}

fn failWith(this: *FileResponseStream, err: Failure) void {
    if (!this.state.response_done) {
        this.state.response_done = true;
        this.state.errored = true;
        this.detachResp();
        if (err != .connection_closed) this.resp.forceClose();
        this.on_error(this.ctx, err);
    }
    this.finish();
}

/// Clear all uWS callbacks pointing at us. Must run while `resp` is still
/// live (i.e., before `resp.end()` / `endSendFile()` / `forceClose()` give the
/// socket back to uWS, which may free it on the next loop tick). After this
/// runs, reader completion will not touch `resp` again.
fn detachResp(this: *FileResponseStream) void {
    if (this.state.resp_detached) return;
    this.state.resp_detached = true;
    this.resp.clearOnWritable();
    this.resp.clearAborted();
    this.resp.clearTimeout();
}

fn finish(this: *FileResponseStream) void {
    log("finish (already={})", .{this.state.finished});
    if (this.state.finished) return;
    bun.assert(this.state.response_done);
    this.state.finished = true;
    if (this.state.reader_active) this.reader.close();
    this.deref();
}

fn deinit(this: *FileResponseStream) void {
    log("deinit", .{});
    if (this.mode == .reader) this.reader.deinit();
    if (this.auto_close) {
        bun.Async.Closer.close(this.fd, if (comptime bun.Environment.isWindows) bun.windows.libuv.Loop.get());
    }
    bun.destroy(this);
}

pub fn eventLoop(this: *FileResponseStream) bun.RuntimeLoopHandle {
    return this.runtime_loop;
}

pub fn loop(this: *FileResponseStream) *bun.ParentEventLoop.PlatformEventLoop {
    return this.runtime_loop.platformLoop();
}

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

const log = bun.Output.scoped(.FileResponseStream, .hidden);

const std = @import("std");

const bun = @import("bun");

const uws = bun.uws;
const AnyResponse = uws.AnyResponse;
