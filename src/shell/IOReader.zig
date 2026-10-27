//! Delivers descriptor reads to registered shell consumers.
pub const IOReader = @This();

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

fd: bun.FD,
owns_fd: bool = true,
reader: ReaderImpl,
buf: std.ArrayList(u8) = .empty,
readers: Readers = .{ .inlined = .{} },
next_reader_id: u64 = 0,
read: usize = 0,
ref_count: RefCount,
err: ?bun.sys.SystemError = null,
scheduler: Interpreter.Scheduler,
is_reading: if (bun.Environment.isWindows) bool else u0 = if (bun.Environment.isWindows) false else 0,
started: bool = false,

pub const ChildPtr = IOReaderChildPtr;
pub const ReaderImpl = bun.io.BufferedReader;

pub fn dupeRef(this: *IOReader) *IOReader {
    this.ref();
    return this;
}

pub fn memoryCost(this: *const IOReader) usize {
    var size: usize = @sizeOf(IOReader);
    size += this.buf.allocatedSlice().len;
    size += this.readers.memoryCost();
    return size;
}

pub fn eventLoop(this: *IOReader) bun.RuntimeLoopHandle {
    return this.scheduler.runtimeLoopHandle();
}

pub fn loop(this: *IOReader) *bun.Async.Loop {
    return this.scheduler.platformLoop();
}

pub fn init(fd: bun.FD, scheduler: Interpreter.Scheduler) *IOReader {
    const this = bun.new(IOReader, .{
        .ref_count = .init(),
        .fd = fd,
        .reader = ReaderImpl.init(@This()),
        .scheduler = scheduler,
    });
    log("IOReader(0x{x}, fd={f}) create", .{ @intFromPtr(this), fd });

    if (bun.Environment.isPosix) {
        this.reader.flags.close_handle = false;
    }

    this.reader.setParent(this);

    return this;
}

/// Idempotent function to start the reading
pub fn start(this: *IOReader) Yield {
    this.ref();
    defer this.deref();
    if (this.started and (this.err != null or this.reader.isDone())) {
        this.onReaderDone();
        return .suspended;
    }
    this.started = true;
    if (bun.Environment.isPosix) {
        if (this.reader.handle == .closed or !this.reader.handle.poll.isRegistered()) {
            if (this.reader.start(this.fd, true).asErr()) |e| {
                this.onReaderError(e);
            }
        }
        return .suspended;
    }

    if (this.is_reading) return .suspended;
    this.is_reading = true;
    const result = if (this.reader.source == null) start: {
        const result = this.reader.start(this.fd, true);
        if (this.reader.source != null) this.owns_fd = false;
        break :start result;
    } else this.reader.startReading();
    if (result.asErr()) |err| {
        this.reader.onError(err);
        return .failed;
    }
    return .suspended;
}

/// Only does things on windows
pub inline fn setReading(this: *IOReader, reading: bool) void {
    if (bun.Environment.isWindows) {
        log("IOReader(0x{x}) setReading({})", .{ @intFromPtr(this), reading });
        this.is_reading = reading;
    }
}

pub fn addReader(this: *IOReader, reader_: anytype) void {
    const reader: ChildPtr = switch (@TypeOf(reader_)) {
        ChildPtr => reader_,
        else => ChildPtr.init(reader_),
    };

    for (this.readers.slice()) |registered| {
        if (registered.ptr.ptr.ptr() == reader.ptr.ptr()) return;
    }
    this.next_reader_id = std.math.add(u64, this.next_reader_id, 1) catch
        @panic("reader registration generation exhausted");
    this.readers.append(.{ .ptr = reader, .id = this.next_reader_id });
}

pub fn removeReader(this: *IOReader, reader_: anytype) void {
    const reader = switch (@TypeOf(reader_)) {
        ChildPtr => reader_,
        else => ChildPtr.init(reader_),
    };
    for (this.readers.slice(), 0..) |registered, idx| {
        if (registered.ptr.ptr.ptr() == reader.ptr.ptr()) {
            this.readers.orderedRemove(idx);
            return;
        }
    }
}

fn removeRegistration(this: *IOReader, id: u64) void {
    for (this.readers.slice(), 0..) |registered, idx| {
        if (registered.id == id) {
            this.readers.orderedRemove(idx);
            return;
        }
    }
}

fn nextRegistration(this: *const IOReader, after: u64, last: u64) ?Reader {
    for (this.readers.slice()) |registered| {
        if (registered.id > after and registered.id <= last) return registered;
    }
    return null;
}

pub fn onReadChunk(ptr: *anyopaque, chunk: []const u8, has_more: bun.io.ReadState) bool {
    var this: *IOReader = @ptrCast(@alignCast(ptr));
    this.ref();
    defer this.deref();
    log("IOReader(0x{x}, fd={f}) onReadChunk(chunk_len={d}, has_more={s})", .{ @intFromPtr(this), this.fd, chunk.len, @tagName(has_more) });
    this.setReading(false);

    const last_registration = this.next_reader_id;
    var delivered: u64 = 0;
    while (this.nextRegistration(delivered, last_registration)) |registered| {
        delivered = registered.id;
        var remove = false;
        const yielded = registered.ptr.onReadChunk(chunk, &remove);
        if (remove) this.removeRegistration(registered.id);
        yielded.run();
    }

    const should_continue = has_more != .eof and this.readers.len() > 0;
    if (should_continue) {
        this.setReading(true);
        if (bun.Environment.isPosix) this.reader.registerPoll();
    }

    return should_continue;
}

pub fn onReaderError(this: *IOReader, err: bun.sys.Error) void {
    this.ref();
    defer this.deref();
    log("IOReader(0x{x}.onReaderError({f}) ", .{ @intFromPtr(this), err });
    this.setReading(false);
    if (this.err) |*previous| previous.deref();
    this.err = err.toShellSystemError();
    this.notifyReadersDone();
}

pub fn onReaderDone(this: *IOReader) void {
    this.ref();
    defer this.deref();
    log("IOReader(0x{x}) done", .{@intFromPtr(this)});
    this.setReading(false);
    this.notifyReadersDone();
}

fn notifyReadersDone(this: *IOReader) void {
    while (this.readers.len() > 0) {
        const reader = this.readers.get(0).ptr;
        this.readers.orderedRemove(0);
        reader.onReaderDone(if (this.err) |*err| brk: {
            err.ref();
            break :brk err.*;
        } else null).run();
    }
}

fn deinit(this: *IOReader) void {
    this.reader.deinitWhenIdle(this, destroy);
}

fn destroy(this: *IOReader) void {
    if (this.err) |*e| e.deref();
    this.readers.deinit();
    this.buf.deinit(bun.default_allocator);
    this.reader.disableKeepingProcessAlive({});
    this.reader.deinit();
    if (this.owns_fd) _ = this.fd.closeAllowingStandardIo(null);
    bun.destroy(this);
}

pub const Reader = struct {
    ptr: ChildPtr,
    id: u64,

    pub fn memoryCost(this: Reader) usize {
        return this.ptr.memoryCost();
    }
};

pub const Readers = SmolList(Reader, 4);

pub const IOReaderChildPtr = struct {
    ptr: ChildPtrRaw,

    pub const ChildPtrRaw = bun.TaggedPointerUnion(.{
        Interpreter.Builtin.Cat,
    });

    pub fn init(p: anytype) IOReaderChildPtr {
        return .{
            .ptr = ChildPtrRaw.init(p),
            // .ptr = @ptrCast(p),
        };
    }

    pub fn memoryCost(this: IOReaderChildPtr) usize {
        if (this.ptr.is(Interpreter.Builtin.Cat)) {
            // TODO:
            return @sizeOf(Interpreter.Builtin.Cat);
        }
        return 0;
    }

    /// Return true if the child should be deleted
    pub fn onReadChunk(this: IOReaderChildPtr, chunk: []const u8, remove: *bool) Yield {
        return this.ptr.call("onIOReaderChunk", .{ chunk, remove }, Yield);
    }

    pub fn onReaderDone(this: IOReaderChildPtr, err: ?bun.sys.SystemError) Yield {
        return this.ptr.call("onIOReaderDone", .{err}, Yield);
    }
};

const std = @import("std");

const bun = @import("bun");

const shell = bun.shell;
const Interpreter = bun.shell.Interpreter;
const SmolList = bun.shell.SmolList;
const Yield = shell.Yield;
const log = bun.shell.interpret.log;
