//! Abstraction to allow multiple writers that can write to a file descriptor.
//!
//! This exists because kqueue/epoll does not work when registering multiple
//! poll events on the same file descriptor.
//!
//! One way to get around this limitation is to just call `.dup()` on the file
//! descriptor, which we do for the top-level stdin/stdout/stderr. But calling
//! `.dup()` for every concurrent writer is expensive.
//!
//! So `IOWriter` is essentially a writer queue to a file descriptor.
//!
//! We also make `*IOWriter` reference counted, this simplifies management of
//! the file descriptor.

const IOWriter = @This();

pub const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

ref_count: RefCount,
writer: WriterImpl = if (bun.Environment.isWindows) .{
    .owns_fd = false,
} else .{ .close_fd = false },
fd: MovableIfWindowsFd,
writers: Writers = .{ .inlined = .{} },
buf: std.ArrayListUnmanaged(u8) = .empty,
writer_idx: usize = 0,
total_bytes_written: usize = 0,
err: ?bun.sys.SystemError = null,
scheduler: Interpreter.Scheduler,
is_writing: bool = false,
started: bool = false,
options: Options = .{},
broken_pipe: bool = false,

const debug = bun.Output.scoped(.IOWriter, .hidden);

pub const ChildPtr = IOWriterChildPtr;

/// ~128kb
/// We shrunk the `buf` when we reach the last writer,
/// but if this never happens, we shrink `buf` when it exceeds this threshold
const SHRINK_THRESHOLD = 1024 * 128;

pub const WriterImpl = bun.io.BufferedWriter(IOWriter, struct {
    pub const onWrite = IOWriter.onWritePollable;
    pub const onError = IOWriter.onError;
    pub const onClose = IOWriter.onClose;
    pub const getBuffer = IOWriter.getBuffer;
    pub const onWritable = null;
});
pub const Poll = WriterImpl;

// pub fn __onClose(_: *IOWriter) void {}
// pub fn __flush(_: *IOWriter) void {}

pub fn dupeRef(this: *IOWriter) *IOWriter {
    this.ref();
    return this;
}

pub fn memoryCost(this: *const IOWriter) usize {
    var cost: usize = @sizeOf(IOWriter);
    cost += this.buf.allocatedSlice().len;
    cost += this.writers.memoryCost();
    cost += this.writer.memoryCost();
    return cost;
}

pub const Options = struct {
    tty_mode: bun.io.WriterStartOptions.TTYMode = .evented,
    ofd_ownership: bun.io.WriterStartOptions.Ownership = .shared,
    child_sigpipe: bool = false,
};

pub fn init(fd: bun.FD, options: Options, scheduler: Interpreter.Scheduler) *IOWriter {
    const this = bun.new(IOWriter, .{
        .ref_count = .init(),
        .fd = MovableIfWindowsFd.init(fd),
        .scheduler = scheduler,
    });

    this.writer.parent = this;
    this.options = options;

    debug("IOWriter(0x{x}, fd={f}) init options={any}", .{ @intFromPtr(this), fd, options });

    return this;
}

pub fn __start(this: *IOWriter) Maybe(void) {
    this.ref();
    defer this.deref();
    bun.assert(this.fd.isOwned());
    debug("IOWriter(0x{x}, fd={f}) __start()", .{ @intFromPtr(this), this.fd });
    if (this.writer.start(&this.fd, .{
        .tty_mode = this.options.tty_mode,
        .ofd_ownership = this.options.ofd_ownership,
    }).asErr()) |err| return .{ .err = err };

    if (comptime bun.Environment.isWindows) {
        log("IOWriter(0x{x}, {f}) starting with source={s}", .{ @intFromPtr(this), this.fd, if (this.writer.source) |src| @tagName(src) else "no source lol" });
    }

    return .success;
}

pub fn eventLoop(this: *IOWriter) bun.RuntimeLoopHandle {
    return this.scheduler.runtimeLoopHandle();
}

pub fn loop(this: *IOWriter) *bun.Async.Loop {
    return this.scheduler.platformLoop();
}

/// Idempotent write call
fn write(this: *IOWriter) union(enum) {
    suspended,
    failed: Yield,
    is_actually_file,
} {
    this.ref();
    defer this.deref();
    bun.assert(this.err == null);
    if (!this.started) {
        log("IOWriter(0x{x}, fd={f}) starting", .{ @intFromPtr(this), this.fd });
        this.started = true;
        if (this.__start().asErr()) |e| {
            return .{ .failed = this.fail(e) };
        }
        if (comptime bun.Environment.isPosix) {
            // if `handle == .fd` it means it's a file which does not
            // support polling for writeability and we should just
            // write to it
            if (this.writer.handle == .fd) {
                return .is_actually_file;
            }
            return .suspended;
        }
        return .suspended;
    }

    if (bun.Environment.isWindows) {
        log("IOWriter(0x{x}, fd={f}) write() is_writing={}", .{ @intFromPtr(this), this.fd, this.is_writing });
        if (this.is_writing) return .suspended;
        this.is_writing = true;
        if (this.writer.startWithCurrentPipe().asErr()) |e| {
            return .{ .failed = this.fail(e) };
        }
        return .suspended;
    }

    if (this.writer.handle == .fd) return .is_actually_file;
    bun.assert(this.writer.handle == .poll);
    if (this.writer.handle.poll.isWatching()) return .suspended;
    if (this.writer.waitForWritable().asErr()) |err| {
        return .{ .failed = this.fail(err) };
    }
    return .suspended;
}

/// Cancel the chunks enqueued by the given writer by
/// marking them as dead
pub fn cancelChunks(this: *IOWriter, ptr_: anytype) void {
    const ptr = switch (@TypeOf(ptr_)) {
        ChildPtr => ptr_,
        else => ChildPtr.init(ptr_),
    };
    const actual_ptr = ptr.ptr.repr._ptr;
    if (this.writers.len() == 0) return;
    const idx = this.writer_idx;
    const slice: []Writer = this.writers.sliceMutable();
    if (idx >= slice.len) return;
    for (slice[idx..]) |*w| {
        if (w.ptr.ptr.repr._ptr == actual_ptr) {
            w.setDead();
        }
    }
}

const Writer = struct {
    ptr: ChildPtr,
    len: usize,
    written: usize = 0,
    bytelist: ?*bun.ByteList = null,

    pub fn format(this: Writer, writer: *std.Io.Writer) !void {
        try writer.print("Writer(0x{x}, {s})", .{ this.ptr.ptr.repr._ptr, @tagName(this.ptr.ptr.tag()) });
    }

    pub fn wroteEverything(this: *const Writer) bool {
        return this.written >= this.len;
    }

    pub fn rawPtr(this: Writer) ?*anyopaque {
        return this.ptr.ptr.ptr();
    }

    pub fn isDead(this: Writer) bool {
        return this.ptr.ptr.isNull();
    }

    pub fn setDead(this: *Writer) void {
        log("Writer setDead {s}(0x{x})", .{ @tagName(this.ptr.ptr.tag()), this.ptr.ptr.repr._ptr });
        this.ptr.ptr = ChildPtrRaw.Null;
    }
};

pub const Writers = SmolList(Writer, 2);

/// Skips over dead children and increments `total_bytes_written` by the
/// amount they would have written so the buf is skipped as well
pub fn skipDead(this: *IOWriter) void {
    const slice = this.writers.slice();
    for (slice[this.writer_idx..]) |*w| {
        if (w.isDead()) {
            this.writer_idx += 1;
            this.total_bytes_written += w.len - w.written;
            continue;
        }
        return;
    }
    return;
}

pub fn doFileWrite(this: *IOWriter) Yield {
    this.ref();
    defer this.deref();
    if (comptime bun.Environment.isPosix) {
        assert(this.writer_idx < this.writers.len());

        defer this.setWriting(false);
        this.skipDead();

        const child = this.writers.get(this.writer_idx);
        assert(!child.isDead());

        const buf = this.getBuffer();
        assert(buf.len > 0);

        var pending = false;
        var failure: ?bun.sys.Error = null;
        const writeResult = this.writer.drainBufferedData(buf, std.math.maxInt(u32), false);
        const amt = switch (writeResult) {
            .done => |amt| amt,
            .wrote => |amt| amt,
            .pending => |amt| amt: {
                pending = true;
                break :amt amt;
            },
            .err => |err| amt: {
                failure = err.cause;
                break :amt err.written;
            },
        };
        if (child.bytelist) |bl| {
            const written_slice = this.buf.items[this.total_bytes_written .. this.total_bytes_written + amt];
            bun.handleOom(bl.appendSlice(bun.default_allocator, written_slice));
        }
        this.total_bytes_written += amt;
        child.written += amt;
        if (failure) |err| {
            return this.fail(err);
        }
        if (pending) {
            if (this.writer.waitForWritable().asErr()) |err| {
                return this.fail(err);
            }
            return .suspended;
        }
        if (!child.wroteEverything()) {
            bun.assert(writeResult == .done);
            // This should never happen if we are here. The only case where we get
            // partial writes is when an error is encountered
            bun.unreachablePanic("IOWriter.doFileWrite: child.wroteEverything() is false. This is unexpected behavior and indicates a bug in Bun. Please file a GitHub issue.", .{});
        }
        return this.bump(child);
    }
    unreachable;
}

pub fn onWritePollable(this: *IOWriter, amount: usize, status: bun.io.WriteStatus) void {
    this.ref();
    defer this.deref();
    this.setWriting(false);
    debug("IOWriter(0x{x}, fd={f}) onWrite({d}, {})", .{ @intFromPtr(this), this.fd, amount, status });
    if (this.writer_idx >= this.writers.len()) return;
    const child = this.writers.get(this.writer_idx);
    if (child.isDead()) {
        this.bump(child).run();
    } else {
        if (child.bytelist) |bl| {
            const written_slice = this.buf.items[this.total_bytes_written .. this.total_bytes_written + amount];
            bun.handleOom(bl.appendSlice(bun.default_allocator, written_slice));
        }
        this.total_bytes_written += amount;
        child.written += amount;
        if (status == .end_of_file) {
            const not_fully_written = if (this.isLastIdx(this.writer_idx)) true else child.written < child.len;
            // We wrote everything
            if (!not_fully_written) return;

            // We did not write everything. This means the other end of the
            // socket/pipe closed and we got EPIPE.
            //
            // An example:
            //
            // Example: `ls . | echo hi`
            //
            // 1. We call `socketpair()` and give `ls .` a socket to _write_ to and `echo hi` a socket to _read_ from
            // 2. `ls .` executes first, but has to do some async work and so is suspended
            // 3. `echo hi` then executes and finishes first (since it does less work) and closes its socket
            // 4. `ls .` does its thing and then tries to write to its socket
            // 5. Because `echo hi` closed its socket, when `ls .` does `send(...)` it will return EPIPE
            // 6. Inside our PipeWriter abstraction this gets returned as bun.io.WriteStatus.end_of_file
            //
            // So what should we do? In a normal shell, `ls .` would receive the SIGPIPE signal and exit.
            // We don't support signals right now. In fact we don't even have a way to kill the shell.
            //
            // So for a quick hack we're just going to have all writes return an error.
            bun.Output.debugWarn("IOWriter(0x{x}, fd={f}) received done without fully writing data", .{ @intFromPtr(this), this.fd });
            this.broken_pipe = true;
            this.brokenPipeForWriters();
            return;
        }

        if (child.written >= child.len) {
            this.bump(child).run();
        }
    }

    const wrote_everything: bool = this.wroteEverything();

    log("IOWriter(0x{x}, fd={f}) wrote_everything={}, idx={d} writers={d} next_len={d}", .{ @intFromPtr(this), this.fd, wrote_everything, this.writer_idx, this.writers.len(), if (this.writers.len() >= 1) this.writers.get(0).len else 0 });
    if (!wrote_everything and this.writer_idx < this.writers.len()) {
        debug("IOWriter(0x{x}, fd={f}) poll again", .{ @intFromPtr(this), this.fd });
        if (comptime bun.Environment.isWindows) {
            this.setWriting(true);
            this.writer.write();
        } else {
            bun.assert(this.writer.handle == .poll);
            if (this.writer.waitForWritable().asErr()) |err| this.onError(err);
        }
    }
}

pub fn brokenPipeForWriters(this: *IOWriter) void {
    bun.assert(this.broken_pipe);
    this.onError(bun.sys.Error.fromCode(.PIPE, .write));
}

pub fn wroteEverything(this: *IOWriter) bool {
    return this.total_bytes_written >= this.buf.items.len;
}

pub fn onClose(this: *IOWriter) void {
    this.setWriting(false);
}

pub fn onError(this: *IOWriter, err__: bun.sys.Error) void {
    this.fail(err__).run();
}

fn fail(this: *IOWriter, err__: bun.sys.Error) Yield {
    if (this.err != null) return .done;
    this.ref();
    this.setWriting(false);
    const ee = err__.toShellSystemError();
    this.err = ee;
    // Track broken pipe state for future enqueue calls
    if (err__.getErrno() == .PIPE) {
        this.broken_pipe = true;
    }
    this.writer.close();
    log("IOWriter(0x{x}, fd={f}) onError errno={s} errmsg={f} errsyscall={f}", .{ @intFromPtr(this), this.fd, @tagName(ee.getErrno()), ee.message, ee.syscall });
    return .{ .io_writer_error = this };
}

pub fn hasPendingErrorNotifications(this: *const IOWriter) bool {
    return this.writer_idx < this.writers.len();
}

pub fn nextError(this: *IOWriter) ?Yield {
    bun.assert(this.err != null);
    while (this.writer_idx < this.writers.len()) {
        const child = this.writers.get(this.writer_idx).ptr;
        this.writer_idx += 1;
        if (child.ptr.isNull()) continue;
        // Consume duplicates before a callback can destroy the child or cancel other requests.
        this.cancelChunks(child);
        // Each consumer owns an error reference independently of this writer.
        this.err.?.ref();
        while (this.writer_idx < this.writers.len() and this.writers.get(this.writer_idx).isDead()) {
            this.writer_idx += 1;
        }
        if (!this.hasPendingErrorNotifications()) this.clearFailedQueue();
        return .{ .on_io_writer_chunk = .{ .child = child, .written = 0, .err = this.err } };
    }
    this.clearFailedQueue();
    return null;
}

fn clearFailedQueue(this: *IOWriter) void {
    this.total_bytes_written = 0;
    this.writer_idx = 0;
    this.buf.clearRetainingCapacity();
    this.writers.clearRetainingCapacity();
}

/// Returns the buffer of data that needs to be written
/// for the *current* writer.
pub fn getBuffer(this: *IOWriter) []const u8 {
    const result = this.getBufferImpl();
    log("IOWriter(0x{x}, fd={f}) getBuffer = {d} bytes", .{ @intFromPtr(this), this.fd, result.len });
    return result;
}

fn getBufferImpl(this: *IOWriter) []const u8 {
    const writer = brk: {
        if (this.writer_idx >= this.writers.len()) {
            log("IOWriter(0x{x}, fd={f}) getBufferImpl all writes done", .{ @intFromPtr(this), this.fd });
            return "";
        }
        log("IOWriter(0x{x}, fd={f}) getBufferImpl idx={d} writer_len={d}", .{ @intFromPtr(this), this.fd, this.writer_idx, this.writers.len() });
        var writer = this.writers.get(this.writer_idx);
        if (!writer.isDead()) break :brk writer;
        log("IOWriter(0x{x}, fd={f}) skipping dead", .{ @intFromPtr(this), this.fd });
        this.skipDead();
        if (this.writer_idx >= this.writers.len()) {
            log("IOWriter(0x{x}, fd={f}) getBufferImpl all writes done", .{ @intFromPtr(this), this.fd });
            return "";
        }
        writer = this.writers.get(this.writer_idx);
        break :brk writer;
    };
    log("IOWriter(0x{x}, fd={f}) getBufferImpl writer_len={} writer_written={}", .{ @intFromPtr(this), this.fd, writer.len, writer.written });
    const remaining = writer.len - writer.written;
    if (bun.Environment.allow_assert) {
        assert(!(writer.len == writer.written));
    }
    return this.buf.items[this.total_bytes_written .. this.total_bytes_written + remaining];
}

pub fn bump(this: *IOWriter, current_writer: *Writer) Yield {
    log("IOWriter(0x{x}, fd={f}) bump(0x{x} {s})", .{ @intFromPtr(this), this.fd, @intFromPtr(current_writer), @tagName(current_writer.ptr.ptr.tag()) });

    const is_dead = current_writer.isDead();
    const written = current_writer.written;
    const child_ptr = current_writer.ptr;

    if (is_dead) {
        this.skipDead();
    } else {
        if (bun.Environment.allow_assert) {
            if (!is_dead) assert(current_writer.written == current_writer.len);
        }
        this.writer_idx += 1;
    }

    if (this.writer_idx >= this.writers.len()) {
        log("IOWriter(0x{x}, fd={f}) all writers complete: truncating", .{ @intFromPtr(this), this.fd });
        this.buf.clearRetainingCapacity();
        this.writer_idx = 0;
        this.writers.clearRetainingCapacity();
        this.total_bytes_written = 0;
    } else if (this.total_bytes_written >= SHRINK_THRESHOLD) {
        const slice = this.buf.items[this.total_bytes_written..];
        const remaining_len = slice.len;
        log("IOWriter(0x{x}, fd={f}) exceeded shrink threshold: truncating (new_len={d}, writer_starting_idx={d})", .{ @intFromPtr(this), this.fd, remaining_len, this.writer_idx });
        if (slice.len == 0) {
            this.buf.clearRetainingCapacity();
            this.total_bytes_written = 0;
        } else {
            bun.copy(u8, this.buf.items[0..remaining_len], slice);
            this.buf.items.len = remaining_len;
            this.total_bytes_written = 0;
        }
        this.writers.truncate(this.writer_idx);
        this.writer_idx = 0;
        if (bun.Environment.allow_assert) {
            if (this.writers.len() > 0) {
                const first = this.writers.getConst(this.writer_idx);
                assert(this.buf.items.len >= first.len);
            }
        }
    }

    // If the writer was not dead then call its `onIOWriterChunk` callback
    if (!is_dead) {
        return child_ptr.onIOWriterChunk(written, null);
    }

    return .done;
}

fn enqueueFile(this: *IOWriter) Yield {
    if (this.is_writing) {
        return .suspended;
    }
    this.setWriting(true);

    return this.doFileWrite();
}

/// `writer` is the new writer to queue
///
/// You MUST have already added the data to `this.buf`!!
pub fn enqueueInternal(this: *IOWriter) Yield {
    bun.assert(!this.broken_pipe);
    switch (this.write()) {
        .suspended => return .suspended,
        .is_actually_file => {
            bun.assert(bun.Environment.isPosix);
            return this.enqueueFile();
        },
        .failed => |yield| return yield,
    }
}

pub fn handleFailure(this: *IOWriter, ptr: ChildPtr) ?Yield {
    const err = if (this.err) |*stored| failure: {
        stored.ref();
        break :failure stored.*;
    } else if (this.broken_pipe)
        bun.sys.Error.fromCode(.PIPE, .write).toSystemError()
    else
        return null;
    return .{ .on_io_writer_chunk = .{ .child = ptr, .written = 0, .err = err } };
}

pub fn enqueue(this: *IOWriter, ptr: anytype, bytelist: ?*bun.ByteList, buf: []const u8) Yield {
    const childptr = if (@TypeOf(ptr) == ChildPtr) ptr else ChildPtr.init(ptr);
    if (this.handleFailure(childptr)) |yield| return yield;

    if (buf.len == 0) {
        log("IOWriter(0x{x}, fd={f}) enqueue EMPTY", .{ @intFromPtr(this), this.fd });
        return .{ .on_io_writer_chunk = .{ .child = childptr, .written = 0, .err = null } };
    }
    const writer: Writer = .{
        .ptr = childptr,
        .len = buf.len,
        .bytelist = bytelist,
    };
    log("IOWriter(0x{x}, fd={f}) enqueue(0x{x} {s}, buf_len={d}, buf={s}, writer_len={d})", .{ @intFromPtr(this), this.fd, @intFromPtr(writer.rawPtr()), @tagName(writer.ptr.ptr.tag()), buf.len, buf[0..@min(128, buf.len)], this.writers.len() + 1 });
    bun.handleOom(this.buf.appendSlice(bun.default_allocator, buf));
    this.writers.append(writer);
    return this.enqueueInternal();
}

pub fn enqueueFmtBltn(
    this: *IOWriter,
    ptr: anytype,
    bytelist: ?*bun.ByteList,
    comptime kind: ?Interpreter.Builtin.Kind,
    comptime fmt_: []const u8,
    args: anytype,
) Yield {
    const cmd_str = comptime if (kind) |k| @tagName(k) ++ ": " else "";
    const fmt__ = cmd_str ++ fmt_;
    return this.enqueueFmt(ptr, bytelist, fmt__, args);
}

pub fn enqueueFmt(
    this: *IOWriter,
    ptr: anytype,
    bytelist: ?*bun.ByteList,
    comptime fmt: []const u8,
    args: anytype,
) Yield {
    const childptr = if (@TypeOf(ptr) == ChildPtr) ptr else ChildPtr.init(ptr);
    if (this.handleFailure(childptr)) |yield| return yield;
    const start = this.buf.items.len;
    {
        var writer_state = bun.UnmanagedWriter.init(&this.buf, bun.default_allocator);
        defer writer_state.finish();
        writer_state.writer().print(fmt, args) catch bun.outOfMemory();
    }

    const end = this.buf.items.len;
    const writer: Writer = .{
        .ptr = childptr,
        .len = end - start,
        .bytelist = bytelist,
    };
    log("IOWriter(0x{x}, fd={f}) enqueue(0x{x} {s}, {s})", .{ @intFromPtr(this), this.fd, @intFromPtr(writer.rawPtr()), @tagName(writer.ptr.ptr.tag()), this.buf.items[start..end] });
    this.writers.append(writer);
    return this.enqueueInternal();
}

fn deinit(this: *IOWriter) void {
    debug("IOWriter(0x{x}, fd={f}) deinit", .{ @intFromPtr(this), this.fd });
    if (bun.Environment.allow_assert) this.ref_count.assertNoRefs();
    this.writer.close();
    this.buf.deinit(bun.default_allocator);
    this.writers.deinit();
    if (this.err) |*e| e.deref();
    if (this.fd.isValid()) this.fd.close();
    this.writer.disableKeepingProcessAlive(this.scheduler);
    bun.destroy(this);
}

pub fn isLastIdx(this: *IOWriter, idx: usize) bool {
    return idx == this.writers.len() -| 1;
}

/// Only does things on windows
pub inline fn setWriting(this: *IOWriter, writing: bool) void {
    if (bun.Environment.isWindows) {
        log("IOWriter(0x{x}, fd={f}) setWriting({})", .{ @intFromPtr(this), this.fd, writing });
        this.is_writing = writing;
    }
}

// this is unused
pub fn runFromMainThread(_: *IOWriter) void {}

// this is unused
pub fn runFromMainThreadMini(_: *IOWriter, _: *void) void {}

/// Anything which uses `*IOWriter` to write to a file descriptor needs to
/// register itself here so we know how to call its callback on completion.
pub const IOWriterChildPtr = struct {
    ptr: ChildPtrRaw,

    pub fn init(p: anytype) IOWriterChildPtr {
        return .{
            .ptr = ChildPtrRaw.init(p),
        };
    }

    /// Called when the IOWriter writes a complete chunk of data the child enqueued
    pub fn onIOWriterChunk(this: IOWriterChildPtr, amount: usize, err: ?bun.sys.SystemError) Yield {
        return this.ptr.call("onIOWriterChunk", .{ amount, err }, Yield);
    }
};

pub const ChildPtrRaw = bun.TaggedPointerUnion(.{
    Interpreter.Cmd,
    Interpreter.Pipeline,
    Interpreter.CondExpr,
    Interpreter.Subshell,
    Interpreter.Builtin.Cd,
    Interpreter.Builtin.Echo,
    Interpreter.Builtin.Export,
    Interpreter.Builtin.Ls,
    Interpreter.Builtin.Ls.ShellLsOutputTask,
    Interpreter.Builtin.Mv,
    Interpreter.Builtin.Pwd,
    Interpreter.Builtin.Rm,
    Interpreter.Builtin.Which,
    Interpreter.Builtin.Mkdir,
    Interpreter.Builtin.Mkdir.ShellMkdirOutputTask,
    Interpreter.Builtin.Touch,
    Interpreter.Builtin.Touch.ShellTouchOutputTask,
    Interpreter.Builtin.Cat,
    Interpreter.Builtin.Exit,
    Interpreter.Builtin.True,
    Interpreter.Builtin.False,
    Interpreter.Builtin.Yes,
    Interpreter.Builtin.Seq,
    Interpreter.Builtin.Dirname,
    Interpreter.Builtin.Basename,
    Interpreter.Builtin.Cp,
    Interpreter.Builtin.Cp.ShellCpOutputTask,
    shell.subproc.PipeReader.CapturedWriter,
});

const log = bun.Output.scoped(.IOWriter, .hidden);

const std = @import("std");

const bun = @import("bun");
const MovableIfWindowsFd = bun.MovableIfWindowsFd;
const assert = bun.assert;
const Maybe = bun.sys.Maybe;

const shell = bun.shell;
const Interpreter = shell.Interpreter;
const SmolList = shell.SmolList;
const Yield = bun.shell.Yield;
