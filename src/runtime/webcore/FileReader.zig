const FileReader = @This();

const log = Output.scoped(.FileReader, .visible);

reader: IOReader = IOReader.init(FileReader),
done: bool = false,
pending_result: Result = .{ .done = {} },
pending_pull: ?PendingPull = null,
source_control: ?BorrowedSourceControl = null,
terminal_error: ?bun.sys.Error = null,
fd: bun.FD = bun.invalid_fd,
start_offset: ?usize = null,
max_size: ?usize = null,
total_readed: usize = 0,
started: bool = false,
waiting_for_onReaderDone: bool = false,
event_loop: bun.RuntimeLoopHandle,
lazy: Lazy = .{ .none = {} },
buffered: std.ArrayList(u8) = .empty,
read_inside_on_pull: ReadDuringJSOnPullResult = .{ .none = {} },
highwater_mark: usize = 16384,
flowing: bool = true,

pub const IOReader = bun.io.BufferedReader;
pub const Poll = IOReader;

pub const Start = union(enum) {
    err: bun.bindgen.SystemError,
    out_of_memory,
    ready: void,
    owned_and_done: bun.ByteList,

    fn fromSysError(err: bun.sys.Error) Start {
        if (err.getErrno() == .NOMEM) return .out_of_memory;
        return .{ .err = bun.bindgen.SystemError.fromSysError(err) catch return .out_of_memory };
    }
};

pub const Result = union(enum) {
    pending: void,
    err: bun.sys.Error,
    done: void,
    owned: bun.ByteList,
    owned_and_done: bun.ByteList,
    temporary_and_done: []const u8,
    temporary: []const u8,
    into_array: IntoArray,
    into_array_and_done: IntoArray,

    pub const IntoArray = struct {
        len: usize,
    };

    pub fn deinit(this: *Result) void {
        switch (this.*) {
            .owned => |*owned| owned.clearAndFree(bun.default_allocator),
            .owned_and_done => |*owned| owned.clearAndFree(bun.default_allocator),
            else => {},
        }
        this.* = .{ .done = {} };
    }
};

pub const BorrowedSourceControl = struct {
    pub const Context = bun.bindgen.NativeCallbackContext(.vm);
    context: Context,
    increment_fn: *const fn (Context) void,
    decrement_fn: *const fn (Context) void,
    close_fn: *const fn (Context) void,
    cancel_fn: *const fn (Context) void,
    complete_pull_fn: *const fn (Context, Result) void,

    pub fn increment(this: BorrowedSourceControl) void {
        this.increment_fn(this.context);
    }

    pub fn decrement(this: BorrowedSourceControl) void {
        this.decrement_fn(this.context);
    }

    pub fn close(this: BorrowedSourceControl) void {
        this.close_fn(this.context);
    }

    pub fn cancel(this: BorrowedSourceControl) void {
        this.cancel_fn(this.context);
    }

    pub fn completePull(this: BorrowedSourceControl, result: Result) void {
        this.complete_pull_fn(this.context, result);
    }
};

const PendingPull = struct {
    bytes: []u8,
};

const ReadDuringJSOnPullResult = union(enum) {
    none: void,
    js: []u8,
    amount_read: usize,
    temporary: []const u8,
    use_buffered: usize,
};

pub const Lazy = union(enum) {
    none: void,
    blob: bun.bindgen.RefNative(Store, .any),

    const OpenedFileBlob = struct {
        fd: bun.FD,
        pollable: bool = false,
        nonblocking: bool = true,
        file_type: bun.io.FileType = .file,
    };

    pub fn openFileBlob(file: *Store.File) bun.sys.Maybe(OpenedFileBlob) {
        var this = OpenedFileBlob{ .fd = bun.invalid_fd };
        var file_buf: bun.PathBuffer = undefined;
        var is_nonblocking = false;

        const fd: bun.FD = if (file.pathlike == .fd) brk: {
            if (comptime Environment.isPosix) {
                if (file.pathlike.fd.stdioTag() != null) {
                    if (bun.tty.reopenForNonblockingRead(file.pathlike.fd.native())) |fd| {
                        is_nonblocking = true;
                        file.is_atty = true;
                        break :brk .fromNative(fd);
                    }
                }
            }
            const fd = switch (bun.sys.dupForLibUV(file.pathlike.fd)) {
                .result => |fd| fd,
                .err => |err| return .{ .err = err.withFd(file.pathlike.fd) },
            };
            if (comptime Environment.isPosix) {
                is_nonblocking = switch (fd.getFcntlFlags()) {
                    .result => |flags| (flags & bun.O.NONBLOCK) != 0,
                    .err => false,
                };
            }
            break :brk fd;
        } else switch (bun.sys.open(file.pathlike.path.sliceZ(&file_buf), bun.O.RDONLY | bun.O.NONBLOCK | bun.O.CLOEXEC, 0)) {
            .result => |fd| brk: {
                if (Environment.isPosix) is_nonblocking = true;
                break :brk switch (fd.makeLibUVOwnedForSyscall(.open, .close_on_fail)) {
                    .result => |owned_fd| owned_fd,
                    .err => |err| return .{ .err = err },
                };
            },

            .err => |err| {
                return .{ .err = err.withPath(file.pathlike.path.slice()) };
            },
        };

        if (comptime Environment.isPosix) {
            if ((file.is_atty orelse false) or
                (fd.stdioTag() != null and bun.sys.isatty(fd)) or
                (file.pathlike == .fd and
                    file.pathlike.fd.stdioTag() != null and
                    bun.sys.isatty(file.pathlike.fd)))
            {
                // var termios = std.mem.zeroes(std.posix.termios);
                // _ = std.c.tcgetattr(fd.cast(), &termios);
                // bun.C.cfmakeraw(&termios);
                // _ = std.c.tcsetattr(fd.cast(), std.posix.TCSA.NOW, &termios);
                file.is_atty = true;
            }

            const stat: bun.Stat = switch (bun.sys.fstat(fd)) {
                .result => |result| result,
                .err => |err| {
                    _ = fd.closeAllowingStandardIo(null);
                    return .{ .err = err };
                },
            };

            if (bun.S.ISDIR(@intCast(stat.mode))) {
                bun.Async.Closer.close(fd, {});
                return .{ .err = .fromCode(.ISDIR, .fstat) };
            }

            if (bun.S.ISREG(@intCast(stat.mode))) {
                is_nonblocking = false;
            }

            this.pollable = bun.sys.isPollable(@intCast(stat.mode)) or is_nonblocking or (file.is_atty orelse false);
            this.file_type = if (bun.S.ISFIFO(@intCast(stat.mode)))
                .pipe
            else if (bun.S.ISSOCK(@intCast(stat.mode)))
                .socket
            else
                .file;

            // pretend it's a non-blocking pipe if it's a TTY
            if (is_nonblocking and this.file_type != .socket) {
                this.file_type = .nonblocking_pipe;
            }

            this.nonblocking = is_nonblocking or (this.pollable and
                !(file.is_atty orelse false) and
                this.file_type != .pipe);

            if (this.nonblocking and this.file_type == .pipe) {
                this.file_type = .nonblocking_pipe;
            }
        }

        this.fd = fd;

        return .{ .result = this };
    }
};

pub fn eventLoop(this: *const FileReader) bun.RuntimeLoopHandle {
    return this.event_loop;
}

pub fn loop(this: *const FileReader) *bun.Async.Loop {
    return this.eventLoop().platformLoop();
}

pub fn attachSource(this: *FileReader, control: BorrowedSourceControl) void {
    bun.assert(this.source_control == null and !this.started);
    this.source_control = control;
    this.reader.setParent(this);
}

pub fn onStart(this: *FileReader) Start {
    const was_lazy = this.lazy != .none;
    var pollable = false;
    var file_type: bun.io.FileType = .file;
    if (this.lazy == .blob) {
        switch (this.lazy.blob.get().data) {
            .s3, .bytes => @panic("Invalid state in FileReader: expected file "),
            .file => |*file| {
                defer {
                    this.lazy.blob.deinit();
                    this.lazy = .none;
                }
                switch (Lazy.openFileBlob(file)) {
                    .err => |err| {
                        this.fd = bun.invalid_fd;
                        return .fromSysError(err);
                    },
                    .result => |opened| {
                        bun.assert(opened.fd.isValid());
                        this.fd = opened.fd;
                        pollable = opened.pollable;
                        file_type = opened.file_type;
                        this.reader.flags.nonblocking = opened.nonblocking;
                        this.reader.flags.pollable = pollable;
                    },
                }
            },
        }
    }

    {
        const reader_fd = this.reader.getFd();
        if (reader_fd != bun.invalid_fd and this.fd == bun.invalid_fd) {
            this.fd = reader_fd;
        }
    }

    if (was_lazy) {
        this.retainUntilReaderDone();
        if (this.start_offset) |offset| {
            switch (this.reader.startFileOffset(this.fd, pollable, offset)) {
                .result => {},
                .err => |e| {
                    const result = Start.fromSysError(e);
                    this.releaseAfterReaderDone();
                    return result;
                },
            }
        } else {
            switch (this.reader.start(this.fd, pollable)) {
                .result => {},
                .err => |e| {
                    const result = Start.fromSysError(e);
                    this.releaseAfterReaderDone();
                    return result;
                },
            }
        }
    } else if (comptime Environment.isPosix) {
        if (this.reader.flags.pollable and !this.reader.isDone()) {
            this.retainUntilReaderDone();
        }
    }

    if (comptime Environment.isPosix) {
        if (file_type == .socket) {
            this.reader.flags.socket = true;
        }

        if (this.reader.handle.getPoll()) |poll| {
            if (file_type == .socket or this.reader.flags.socket) {
                poll.flags.insert(.socket);
            } else {
                // if it's a TTY, we report it as a fifo
                // we want the behavior to be as though it were a blocking pipe.
                poll.flags.insert(.fifo);
            }

            if (this.reader.flags.nonblocking) {
                poll.flags.insert(.nonblocking);
            }
        }
    }

    this.started = true;

    if (this.reader.isDone()) {
        this.consumeReaderBuffer();
        if (this.buffered.items.len > 0) {
            return .{ .owned_and_done = bun.ByteList.moveFromList(&this.buffered) };
        }
    } else if (comptime Environment.isPosix) {
        if (!was_lazy and this.reader.flags.pollable) {
            this.reader.read();
            if (this.takeTerminalError()) |err| return .fromSysError(err);
        }
    }

    return .{ .ready = {} };
}

fn sourceControl(this: *const FileReader) BorrowedSourceControl {
    return this.source_control orelse @panic("FileReader source control is unavailable");
}

fn retainUntilReaderDone(this: *FileReader) void {
    bun.assert(!this.waiting_for_onReaderDone);
    this.sourceControl().increment();
    this.waiting_for_onReaderDone = true;
}

fn releaseAfterReaderDone(this: *FileReader) void {
    if (!this.waiting_for_onReaderDone) return;
    this.waiting_for_onReaderDone = false;
    this.sourceControl().decrement();
}

fn beginPendingPull(this: *FileReader, buffer: []u8) Result {
    bun.assert(this.pending_pull == null);
    this.pending_pull = .{ .bytes = buffer };
    return .{ .pending = {} };
}

fn completePendingPull(this: *FileReader) void {
    bun.assert(this.pending_pull != null);
    const result = this.pending_result;
    this.pending_result = .{ .done = {} };
    this.pending_pull = null;
    this.sourceControl().completePull(result);
}

pub fn onCancel(this: *FileReader) void {
    if (this.done) return;
    this.done = true;
    this.reader.updateRef(false);
    if (!this.reader.isDone())
        this.reader.close();
}

pub fn cancelSource(this: *FileReader) void {
    this.sourceControl().cancel();
}

pub fn takeTerminalError(this: *FileReader) ?bun.sys.Error {
    return bun.take(&this.terminal_error);
}

pub fn deinit(this: *FileReader) void {
    this.buffered.deinit(bun.default_allocator);
    this.reader.updateRef(false);
    this.reader.deinit();
    this.pending_pull = null;
    this.pending_result.deinit();
    this.source_control = null;

    if (this.lazy != .none) {
        this.lazy.blob.deinit();
        this.lazy = .none;
    }
}

pub fn onReadChunk(this: *@This(), init_buf: []const u8, state: bun.io.ReadState) bool {
    var buf = init_buf;
    log("onReadChunk() = {d} ({s}) - read_inside_on_pull: {s}", .{ buf.len, @tagName(state), @tagName(this.read_inside_on_pull) });

    if (this.done) {
        this.reader.close();
        return false;
    }
    var close = false;
    defer if (close) this.reader.close();
    var hasMore = state != .eof;

    if (buf.len > 0) {
        if (this.max_size) |max_size| {
            if (this.total_readed >= max_size) return false;
            const len = @min(max_size - this.total_readed, buf.len);
            if (buf.len > len) {
                buf = buf[0..len];
            }
            this.total_readed += len;

            if (buf.len == 0) {
                close = true;
                hasMore = false;
            }
        }
    }

    const reader_buffer = this.reader.buffer();
    if (this.read_inside_on_pull != .none) {
        switch (this.read_inside_on_pull) {
            .js => |in_progress| {
                if (in_progress.len >= buf.len and !hasMore) {
                    @memcpy(in_progress[0..buf.len], buf);
                    this.read_inside_on_pull = .{ .js = in_progress[buf.len..] };
                } else if (in_progress.len > 0 and !hasMore) {
                    this.read_inside_on_pull = .{ .temporary = buf };
                } else if (hasMore and !bun.isSliceInBuffer(buf, this.buffered.allocatedSlice())) {
                    bun.handleOom(this.buffered.appendSlice(bun.default_allocator, buf));
                    this.read_inside_on_pull = .{ .use_buffered = buf.len };
                }
            },
            .use_buffered => |original| {
                bun.handleOom(this.buffered.appendSlice(bun.default_allocator, buf));
                this.read_inside_on_pull = .{ .use_buffered = buf.len + original };
            },
            .none => unreachable,
            else => @panic("Invalid state"),
        }
    } else if (this.pending_pull) |pending_pull| {
        // Certain readers (such as pipes) may return 0-byte reads even when
        // not at EOF. Consequently, we need to check whether the reader is
        // actually done or not.
        if (buf.len == 0 and state == .drained) {
            // If the reader is not done, we still want to keep reading.
            return true;
        }

        defer {
            this.completePendingPull();
        }

        if (buf.len == 0) {
            if (this.buffered.items.len == 0) {
                this.buffered.clearAndFree(bun.default_allocator);
                this.buffered = reader_buffer.moveToUnmanaged();
            }

            var buffer = &this.buffered;
            defer buffer.clearAndFree(bun.default_allocator);
            if (buffer.items.len > 0) {
                if (pending_pull.bytes.len >= buffer.items.len) {
                    @memcpy(pending_pull.bytes[0..buffer.items.len], buffer.items);
                    this.pending_result = .{ .into_array_and_done = .{ .len = buffer.items.len } };
                } else {
                    this.pending_result = .{ .owned_and_done = bun.ByteList.moveFromList(buffer) };
                }
            } else {
                this.pending_result = .{ .done = {} };
            }
            return false;
        }

        const was_done = this.reader.isDone();

        if (pending_pull.bytes.len >= buf.len) {
            @memcpy(pending_pull.bytes[0..buf.len], buf);
            reader_buffer.clearRetainingCapacity();
            this.buffered.clearRetainingCapacity();

            const into_array: Result.IntoArray = .{
                .len = buf.len,
            };

            this.pending_result = if (was_done)
                .{ .into_array_and_done = into_array }
            else
                .{ .into_array = into_array };
            return !was_done;
        }

        if (bun.isSliceInBuffer(buf, reader_buffer.allocatedSlice())) {
            if (this.reader.isDone()) {
                bun.assert_eql(buf.ptr, reader_buffer.items.ptr);
                var buffer = reader_buffer.moveToUnmanaged();
                buffer.shrinkRetainingCapacity(buf.len);
                this.pending_result = .{ .owned_and_done = .moveFromList(&buffer) };
            } else {
                reader_buffer.clearRetainingCapacity();
                this.pending_result = .{ .temporary = buf };
            }
            return !was_done;
        }

        if (!bun.isSliceInBuffer(buf, this.buffered.allocatedSlice())) {
            this.pending_result = if (this.reader.isDone())
                .{ .temporary_and_done = buf }
            else
                .{ .temporary = buf };
            return !was_done;
        }

        bun.assert_eql(buf.ptr, this.buffered.items.ptr);
        var buffered = this.buffered;
        this.buffered = .empty;
        buffered.shrinkRetainingCapacity(buf.len);

        this.pending_result = if (this.reader.isDone())
            .{ .owned_and_done = .moveFromList(&buffered) }
        else
            .{ .owned = .moveFromList(&buffered) };
        return !was_done;
    } else if (!bun.isSliceInBuffer(buf, this.buffered.allocatedSlice())) {
        bun.handleOom(this.buffered.appendSlice(bun.default_allocator, buf));
        if (bun.isSliceInBuffer(buf, reader_buffer.allocatedSlice())) {
            reader_buffer.clearRetainingCapacity();
        }
    }

    // For pipes, we have to keep pulling or the other process will block.
    return this.read_inside_on_pull != .temporary and
        !(this.buffered.items.len + reader_buffer.items.len >= this.highwater_mark and
            !this.reader.flags.pollable);
}

fn isPulling(this: *const FileReader) bool {
    return this.read_inside_on_pull != .none;
}

pub fn onPull(this: *FileReader, buffer: []u8) Result {
    if (this.takeTerminalError()) |err| {
        return .{ .err = err };
    }

    var drained = this.drain();
    defer drained.deinit(bun.default_allocator);

    if (drained.len > 0) {
        log("onPull({d}) = {d}", .{ buffer.len, drained.len });

        this.pending_pull = null;

        if (buffer.len >= @as(usize, drained.len)) {
            const drained_len = drained.len;
            @memcpy(buffer[0..drained_len], drained.slice());

            if (this.reader.isDone()) {
                return .{ .into_array_and_done = .{ .len = drained_len } };
            } else {
                return .{ .into_array = .{ .len = drained_len } };
            }
        }

        const bytes = drained;
        drained = .{};
        return if (this.reader.isDone())
            .{ .owned_and_done = bytes }
        else
            .{ .owned = bytes };
    }

    if (this.reader.isDone()) {
        return .{ .done = {} };
    }

    if (!this.reader.hasPendingRead()) {
        // If not flowing (paused), don't initiate new reads
        if (!this.flowing) {
            log("onPull({d}) = pending (not flowing)", .{buffer.len});
            return this.beginPendingPull(buffer);
        }

        this.read_inside_on_pull = .{ .js = buffer };
        this.reader.read();

        defer this.read_inside_on_pull = .{ .none = {} };
        if (this.takeTerminalError()) |err| {
            return .{ .err = err };
        }
        switch (this.read_inside_on_pull) {
            .js => |remaining_buf| {
                const amount_read = buffer.len - remaining_buf.len;

                log("onPull({d}) = {d}", .{ buffer.len, amount_read });

                if (amount_read > 0) {
                    if (this.reader.isDone()) {
                        return .{ .into_array_and_done = .{ .len = amount_read } };
                    }

                    return .{ .into_array = .{ .len = amount_read } };
                }

                if (this.reader.isDone()) {
                    return .{ .done = {} };
                }
            },
            .temporary => |buf| {
                log("onPull({d}) = {d}", .{ buffer.len, buf.len });
                if (this.reader.isDone()) {
                    return .{ .temporary_and_done = buf };
                }

                return .{ .temporary = buf };
            },
            .use_buffered => {
                log("onPull({d}) = {d}", .{ buffer.len, this.buffered.items.len });
                if (this.reader.isDone()) {
                    return .{ .owned_and_done = bun.ByteList.moveFromList(&this.buffered) };
                }
                return .{ .owned = bun.ByteList.moveFromList(&this.buffered) };
            },
            else => {},
        }

        if (this.reader.isDone()) {
            log("onPull({d}) = done", .{buffer.len});

            return .{ .done = {} };
        }
    }

    log("onPull({d}) = pending", .{buffer.len});

    return this.beginPendingPull(buffer);
}

pub fn drain(this: *FileReader) bun.ByteList {
    if (this.buffered.items.len > 0) {
        const out = bun.ByteList.moveFromList(&this.buffered);
        if (comptime Environment.allow_assert) {
            bun.assert(this.reader.buffer().items.ptr != out.ptr);
        }
        return out;
    }

    if (this.reader.hasPendingRead()) {
        return .{};
    }

    return bun.ByteList.moveFromList(this.reader.buffer());
}

pub fn drainOwned(this: *FileReader) bun.OOM![]u8 {
    if (this.buffered.items.len > 0) {
        return this.buffered.toOwnedSlice(bun.default_allocator);
    }
    if (this.reader.hasPendingRead()) return &.{};
    const buffer = this.reader.buffer();
    const bytes = try bun.default_allocator.dupe(u8, buffer.items);
    buffer.clearAndFree();
    return bytes;
}

pub fn setRefOrUnref(this: *FileReader, enable: bool) void {
    if (this.done) return;
    this.reader.updateRef(enable);
}

fn consumeReaderBuffer(this: *FileReader) void {
    if (this.buffered.capacity == 0) {
        this.buffered = this.reader.buffer().moveToUnmanaged();
    }
}

pub fn onReaderDone(this: *FileReader) void {
    log("onReaderDone()", .{});
    if (!this.isPulling()) {
        this.consumeReaderBuffer();
        if (this.pending_pull != null) {
            if (this.buffered.items.len > 0) {
                this.pending_result = .{ .owned_and_done = bun.ByteList.moveFromList(&this.buffered) };
            } else {
                this.pending_result = .{ .done = {} };
            }
            this.buffered = .empty;
            this.completePendingPull();
        }
        // Don't handle buffered data here - it will be returned on the next onPull
        // This ensures proper ordering of chunks
    }

    // Only close the stream if there's no buffered data left to deliver
    if (this.buffered.items.len == 0) {
        this.sourceControl().close();
    }
    this.releaseAfterReaderDone();
}

pub fn onReaderError(this: *FileReader, err: bun.sys.Error) void {
    defer this.releaseAfterReaderDone();
    this.consumeReaderBuffer();
    if (this.buffered.capacity > 0 and this.buffered.items.len == 0) {
        this.buffered.deinit(bun.default_allocator);
        this.buffered = .empty;
    }

    if (this.pending_pull != null) {
        this.pending_result = .{ .err = err };
        this.completePendingPull();
    } else {
        this.terminal_error = err;
    }
}

pub fn setRawMode(this: *FileReader, flag: bool) bun.sys.Maybe(void) {
    if (comptime !Environment.isWindows) return .{ .err = bun.sys.Error.fromCode(.OPNOTSUPP, .uv_tty_set_mode) };
    if (this.reader.source != null) return this.reader.setRawMode(flag);
    const fd = fd: {
        if (this.fd.isValid()) break :fd this.fd;
        if (this.lazy == .blob) {
            const store = this.lazy.blob.get();
            if (store.data == .file and store.data.file.pathlike == .fd)
                break :fd store.data.file.pathlike.fd;
        }
        return .{ .err = bun.sys.Error.fromCode(.BADF, .uv_tty_set_mode) };
    };
    const errno = bun.tty.setMode(fd.uv(), if (flag) .raw else .normal);
    if (errno != 0) {
        return .{ .err = .{ .errno = @intCast(errno), .syscall = .uv_tty_set_mode, .fd = fd } };
    }
    this.reader.flags.initial_tty_mode = if (flag) .raw else .normal;
    return .success;
}

pub fn setFlowing(this: *FileReader, flag: bool) void {
    log("setFlowing({}) was={}", .{ flag, this.flowing });

    if (this.flowing == flag) {
        return;
    }

    this.flowing = flag;
    if (!this.started) return;

    if (flag) {
        this.reader.unpause();
        if (!this.reader.isDone() and !this.reader.hasPendingRead()) {
            // Kick off a new read if needed
            this.reader.read();
        }
    } else {
        this.reader.pause();
    }
}

pub fn memoryCost(this: *const FileReader) usize {
    return this.reader.memoryCost() + this.buffered.capacity;
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const BlobSize = @import("./BlobSize.zig");
const Store = @import("./blob/Store.zig");
