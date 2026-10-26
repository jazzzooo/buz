const log = bun.Output.scoped(.PipeWriter, .hidden);

pub const WriterStartOptions = struct {
    force_sync: bool = false,
    tty_mode: TTYMode = .evented,
    ofd_ownership: Ownership = .shared,

    pub const TTYMode = enum {
        evented,
        blocking,
        synchronous,
    };

    pub const Ownership = enum {
        shared,
        /// The caller guarantees that no descriptor alias can mutate this OFD's status flags.
        exclusive,
    };
};

const PosixDescriptor = struct {
    const posix_min_pipe_buf = 512;

    kind: Kind = .file,
    known_nonblocking: bool = false,

    const Kind = enum {
        file,
        fifo,
        socket,
        tty,
    };

    fn init(fd: bun.FD, options: WriterStartOptions) bun.sys.Maybe(PosixDescriptor) {
        const stat = switch (bun.sys.fstat(fd)) {
            .result => |stat| stat,
            .err => |err| return .{ .err = err },
        };
        const mode: bun.Mode = @intCast(stat.mode);
        const kind: Kind = if (bun.S.ISSOCK(mode))
            .socket
        else if (bun.S.ISFIFO(mode))
            .fifo
        else if (bun.S.ISCHR(mode) and bun.sys.isatty(fd))
            .tty
        else
            .file;

        const flags = switch (bun.sys.getFcntlFlags(fd)) {
            .result => |flags| flags,
            .err => |err| return .{ .err = err },
        };
        var nonblocking = (flags & @as(@TypeOf(flags), bun.O.NONBLOCK)) != 0;
        const force_sync = options.force_sync or (kind == .tty and options.tty_mode == .synchronous);
        const exclusive = options.ofd_ownership == .exclusive;

        if (force_sync or (kind == .tty and options.tty_mode == .blocking)) {
            if (nonblocking and bun.sys.updateNonblocking(fd, false) == .result) {
                nonblocking = false;
            }
        } else if (exclusive and kind != .file and !nonblocking) {
            if (bun.sys.setNonblocking(fd) == .result) {
                nonblocking = true;
            }
        }

        return .{ .result = .{
            .kind = kind,
            .known_nonblocking = exclusive and nonblocking,
        } };
    }

    fn forceSync(this: PosixDescriptor, options: WriterStartOptions) bool {
        return options.force_sync or (this.kind == .tty and options.tty_mode == .synchronous);
    }

    fn fileType(this: PosixDescriptor) FileType {
        return switch (this.kind) {
            // MSG_DONTWAIT can block on macOS when the socket's OFD is blocking.
            .socket => if (!Environment.isMac or this.known_nonblocking) .socket else .pipe,
            .fifo, .tty => if (this.known_nonblocking) .nonblocking_pipe else .pipe,
            .file => .file,
        };
    }

    fn write(this: PosixDescriptor, fd: bun.FD, force_sync: bool, buf: []const u8) bun.sys.Maybe(usize) {
        if (force_sync) return bun.sys.write(fd, buf);

        return switch (this.kind) {
            .file => bun.sys.write(fd, buf),
            .socket => if (!Environment.isMac or this.known_nonblocking)
                bun.sys.sendNonBlock(fd, buf)
            else
                writeAfterPoll(fd, buf),
            .fifo => if (this.known_nonblocking)
                bun.sys.write(fd, buf)
            else
                writeAfterPoll(fd, buf[0..@min(buf.len, posix_min_pipe_buf)]),
            .tty => if (this.known_nonblocking)
                bun.sys.write(fd, buf)
            else
                writeAfterPoll(fd, buf),
        };
    }

    fn writeAfterPoll(fd: bun.FD, buf: []const u8) bun.sys.Maybe(usize) {
        return switch (bun.isWritable(fd)) {
            .ready, .hup => bun.sys.write(fd, buf),
            .not_ready => .{ .err = bun.sys.Error.retry },
        };
    }

    fn isPollable(this: PosixDescriptor) bool {
        return this.kind != .file;
    }

    fn requiresPoll(this: PosixDescriptor) bool {
        return this.kind == .fifo or this.kind == .socket;
    }

    fn configurePoll(this: PosixDescriptor, poll: *Async.FilePoll) void {
        if (this.known_nonblocking) poll.flags.insert(.nonblocking);
        if (this.fileType() == .socket) {
            poll.flags.insert(.socket);
        } else if (this.isPollable()) {
            poll.flags.insert(.fifo);
        }
    }
};

pub const WriteResult = union(enum) {
    done: usize,
    wrote: usize,
    pending: usize,
    err: bun.sys.Error,
};

pub const WriteStatus = enum {
    buffered,
    end_of_file,
    drained,
    pending,
};

const WriteAttempt = union(enum) {
    done: usize,
    wrote: usize,
    pending: usize,
    err: struct { cause: bun.sys.Error, written: usize },

    fn result(this: WriteAttempt) WriteResult {
        return switch (this) {
            .done => |written| .{ .done = written },
            .wrote => |written| .{ .wrote = written },
            .pending => |written| .{ .pending = written },
            .err => @panic("failed writes must report their progress before returning the error"),
        };
    }
};

fn reportWriteError(comptime Parent: type, comptime callbacks: anytype, parent: *Parent, err: bun.sys.Error, written: usize) void {
    const reports_progress = if (@TypeOf(callbacks) == type)
        @hasDecl(callbacks, "onWriteError")
    else
        @hasField(@TypeOf(callbacks), "onWriteError");
    if (comptime reports_progress) callbacks.onWriteError(parent, err, written) else callbacks.onError(parent, err);
}

pub fn PosixPipeWriter(
    comptime This: type,
    comptime getBuffer: fn (*This) []const u8,
    comptime write: fn (*This, bool, []const u8) bun.sys.Maybe(usize),
    comptime onWrite: fn (*This, written: usize, status: WriteStatus) void,
    comptime registerPoll: ?fn (*This) bun.sys.Maybe(void),
    comptime onError: fn (*This, bun.sys.Error, usize) void,
    comptime _: fn (*This) void,
    comptime getFileType: *const fn (*This) FileType,
) type {
    return struct {
        fn tryWrite(this: *This, force_sync: bool, buf: []const u8) WriteAttempt {
            var offset: usize = 0;

            while (offset < buf.len) {
                switch (write(this, force_sync, buf[offset..])) {
                    .err => |err| {
                        if (err.isRetry() and getFileType(this) != .file) {
                            return .{ .pending = offset };
                        }

                        return .{ .err = .{ .cause = err, .written = offset } };
                    },

                    .result => |wrote| {
                        offset += wrote;
                        if (wrote == 0) {
                            return .{ .err = .{ .cause = bun.sys.Error.fromCode(.IO, .write), .written = offset } };
                        }
                    },
                }
            }

            return .{ .wrote = offset };
        }

        pub fn onPoll(parent: *This, size_hint: isize, received_hup: bool) void {
            const buffer = getBuffer(parent);
            log("onPoll({})", .{buffer.len});
            if (buffer.len == 0 and !received_hup) {
                log("PosixPipeWriter(0x{x}) handle={s}", .{ @intFromPtr(parent), @tagName(parent.handle) });
                if (parent.handle == .poll) {
                    log("PosixPipeWriter(0x{x}) got 0, registered state = {}", .{ @intFromPtr(parent), parent.handle.poll.isRegistered() });
                }
                return;
            }

            switch (drainBufferedData(
                parent,
                buffer,
                if (size_hint > 0 and getFileType(parent).isBlocking()) @intCast(size_hint) else std.math.maxInt(usize),
                received_hup,
            )) {
                .pending => |wrote| {
                    if (comptime registerPoll) |register| {
                        if (register(parent).asErr()) |err| return onError(parent, err, wrote);
                    }
                    if (wrote > 0)
                        onWrite(parent, wrote, .pending);
                },
                .wrote => |amt| {
                    // `.drained`: the buffer was fully written before the
                    // callback. If the callback buffers more data via
                    // `write()`, that path already calls `registerPoll()`.
                    // Don't touch `parent` after the callback returns — the
                    // `.drained` callback is allowed to close/free the writer
                    // (e.g. `FileSink.onWrite` → `writer.end()` → `onClose`
                    // may drop the last ref).
                    onWrite(parent, amt, .drained);
                },
                .err => |failure| {
                    onError(parent, failure.cause, failure.written);
                },
                .done => |amt| {
                    onWrite(parent, amt, .end_of_file);
                },
            }
        }

        pub fn drainBufferedData(parent: *This, buf: []const u8, max_write_size: usize, _: bool) WriteAttempt {
            const trimmed = if (max_write_size < buf.len and max_write_size > 0) buf[0..max_write_size] else buf;
            return tryWrite(parent, parent.getForceSync(), trimmed);
        }
    };
}

/// See below for the expected signature of `function_table`. In many cases, the
/// function table can be the same as `Parent`. `anytype` is used because of a
/// dependency loop in Zig.
pub fn PosixBufferedWriter(Parent: type, function_table: anytype) type {
    return struct {
        const PosixWriter = @This();
        const onWrite: *const fn (*Parent, amount: usize, status: WriteStatus) void = function_table.onWrite;
        const onClose: ?*const fn (*Parent) void = function_table.onClose;
        const getBuffer: *const fn (*Parent) []const u8 = function_table.getBuffer;
        const onWritable: ?*const fn (*Parent) void = function_table.onWritable;

        handle: PollOrFd = .{ .closed = {} },
        parent: *Parent = undefined,
        is_done: bool = false,
        descriptor: PosixDescriptor = .{},
        force_sync: bool = false,
        closed_without_reporting: bool = false,
        close_fd: bool = true,
        callback_frame: ?*CallbackFrame = null,

        const CallbackFrame = struct {
            owner: ?*PosixWriter,
            previous: ?*CallbackFrame,

            fn enter(frame: *CallbackFrame, owner: *PosixWriter) void {
                frame.* = .{ .owner = owner, .previous = owner.callback_frame };
                owner.callback_frame = frame;
            }

            fn leave(frame: *CallbackFrame) void {
                if (frame.owner) |owner| owner.callback_frame = frame.previous;
            }
        };

        const internals = PosixPipeWriter(@This(), getBufferInternal, writeOnce, _onWrite, waitForWritable, _onError, _onWritable, getFileType);
        pub const onPoll = internals.onPoll;
        pub const drainBufferedData = internals.drainBufferedData;

        pub fn memoryCost(_: *const @This()) usize {
            return @sizeOf(@This());
        }

        pub fn createPoll(this: *@This(), fd: bun.FD) bun.OOM!*Async.FilePoll {
            return Async.FilePoll.create(this.parent.eventLoop().runtimeLoopHandle(), fd, .{}, PosixWriter, this);
        }

        pub fn getPoll(this: *const @This()) ?*Async.FilePoll {
            return this.handle.getPoll();
        }

        pub fn getFileType(this: *const @This()) FileType {
            return this.descriptor.fileType();
        }

        pub fn getFd(this: *const PosixWriter) bun.FD {
            return this.handle.getFd();
        }

        fn writeOnce(this: *PosixWriter, force_sync: bool, buf: []const u8) bun.sys.Maybe(usize) {
            return this.descriptor.write(this.getFd(), force_sync, buf);
        }

        fn _onError(
            this: *PosixWriter,
            err: bun.sys.Error,
            written: usize,
        ) void {
            var frame: CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();
            this.closeWithoutReporting();
            this.is_done = true;
            reportWriteError(Parent, function_table, this.parent, err, written);
            if (frame.owner) |current| current.close();
        }

        pub fn getForceSync(this: *const @This()) bool {
            return this.force_sync;
        }

        fn _onWrite(
            this: *PosixWriter,
            written: usize,
            status: WriteStatus,
        ) void {
            var frame: CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();
            const was_done = this.is_done == true;
            const parent = this.parent;

            if (status == .end_of_file and !was_done) {
                this.closeWithoutReporting();
            }

            onWrite(parent, written, status);
            if (status == .end_of_file and !was_done) {
                if (frame.owner) |current| current.close();
            }
        }

        fn _onWritable(this: *PosixWriter) void {
            if (this.is_done) {
                return;
            }

            if (onWritable) |cb| {
                cb(this.parent);
            }
        }

        pub fn waitForWritable(this: *PosixWriter) bun.sys.Maybe(void) {
            if (this.handle == .fd) {
                const fd = this.handle.fd;
                const poll = this.createPoll(fd) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
                this.handle = .{ .poll = poll };
                this.descriptor.configurePoll(this.handle.poll);
            }
            const poll = this.getPoll() orelse return .success;
            return poll.registerWithFd(this.parent.eventLoop().runtimeLoopHandle().platformLoop(), .writable, .dispatch, poll.fd);
        }

        pub fn hasRef(this: *PosixWriter) bool {
            if (this.is_done) {
                return false;
            }

            const poll = this.getPoll() orelse return false;
            return poll.canEnableKeepingProcessAlive();
        }

        pub fn enableKeepingProcessAlive(this: *PosixWriter, event_loop: anytype) void {
            this.updateRef(event_loop, true);
        }

        pub fn disableKeepingProcessAlive(this: *PosixWriter, event_loop: anytype) void {
            this.updateRef(event_loop, false);
        }

        fn getBufferInternal(this: *PosixWriter) []const u8 {
            return getBuffer(this.parent);
        }

        pub fn end(this: *PosixWriter) void {
            this.close();
        }

        fn closeWithoutReporting(this: *PosixWriter) void {
            if (this.getFd() != bun.invalid_fd) {
                bun.assert(!this.closed_without_reporting);
                this.closed_without_reporting = true;
                this.handle.closeImpl(null, {}, this.close_fd);
            }
        }

        pub fn close(this: *PosixWriter) void {
            const report_close = this.closed_without_reporting or this.getFd() != bun.invalid_fd;
            this.is_done = true;
            this.closed_without_reporting = false;
            var frame = bun.take(&this.callback_frame);
            while (frame) |active| {
                active.owner = null;
                frame = active.previous;
            }
            this.handle.closeImpl(null, {}, this.close_fd);
            if (report_close) if (onClose) |closer| closer(this.parent);
        }

        pub fn updateRef(this: *const PosixWriter, event_loop: anytype, value: bool) void {
            const poll = this.getPoll() orelse return;
            poll.setKeepingProcessAlive(event_loop.runtimeLoopHandle(), value);
        }

        pub fn setParent(this: *PosixWriter, parent: *Parent) void {
            this.parent = parent;
            this.handle.setOwner(this);
        }

        pub fn write(this: *PosixWriter) void {
            if (this.is_done) return;
            this.onPoll(0, false);
        }

        pub fn watch(this: *PosixWriter) void {
            if (this.waitForWritable().asErr()) |err| this._onError(err, 0);
        }

        pub fn start(this: *PosixWriter, rawfd: anytype, options: WriterStartOptions) bun.sys.Maybe(void) {
            bun.assert(this.callback_frame == null);
            this.is_done = false;
            this.closed_without_reporting = false;
            const FDType = @TypeOf(rawfd);
            const fd = switch (FDType) {
                bun.FD => rawfd,
                *bun.MovableIfWindowsFd, bun.MovableIfWindowsFd => rawfd.getPosix(),
                else => @compileError("Expected `bun.FD`, `*bun.MovableIfWindowsFd` or `bun.MovableIfWindowsFd` but got: " ++ @typeName(rawfd)),
            };
            var effective_options = options;
            effective_options.force_sync = effective_options.force_sync or this.force_sync;
            this.descriptor = switch (PosixDescriptor.init(fd, effective_options)) {
                .result => |descriptor| descriptor,
                .err => |err| return .{ .err = err },
            };
            this.force_sync = this.descriptor.forceSync(effective_options);
            if (!this.descriptor.isPollable()) {
                bun.assert(this.handle != .poll);
                this.handle = .{ .fd = fd };
                return .success;
            }
            var poll = this.getPoll() orelse brk: {
                const created = this.createPoll(fd) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
                this.handle = .{ .poll = created };
                break :brk this.handle.poll;
            };
            this.descriptor.configurePoll(poll);
            const loop = @as(*Parent, @ptrCast(this.parent)).eventLoop().runtimeLoopHandle();

            switch (poll.registerWithFd(loop.platformLoop(), .writable, .dispatch, fd)) {
                .err => |err| {
                    this.handle.closeImpl(null, {}, false);
                    if (!this.descriptor.requiresPoll()) {
                        this.handle = .{ .fd = fd };
                        return .success;
                    }
                    return .initErr(err);
                },
                .result => {
                    this.enableKeepingProcessAlive(@as(*Parent, @ptrCast(this.parent)).eventLoop());
                },
            }

            return .success;
        }
    };
}

/// See below for the expected signature of `function_table`. In many cases, the
/// function table can be the same as `Parent`. `anytype` is used because of a
/// dependency loop in Zig.
pub fn PosixStreamingWriter(comptime Parent: type, comptime function_table: anytype) type {
    return struct {
        const onWrite: fn (*Parent, amount: usize, status: WriteStatus) void = function_table.onWrite;
        const onWritable: ?fn (*Parent) void = function_table.onWritable;
        const onClose: fn (*Parent) void = function_table.onClose;

        outgoing: StreamBuffer = .{},
        handle: PollOrFd = .{ .closed = {} },
        parent: *Parent = undefined,
        is_done: bool = false,
        closed_without_reporting: bool = false,
        force_sync: bool = false,
        descriptor: PosixDescriptor = .{},

        const internals = PosixPipeWriter(@This(), getBuffer, writeOnce, _onWrite, waitForWritable, _onError, _onWritable, getFileType);
        pub fn onPoll(this: *@This(), size_hint: isize, received_hup: bool) void {
            const owner = this.parent;
            owner.ref();
            defer owner.deref();
            internals.onPoll(this, size_hint, received_hup);
        }
        pub const drainBufferedData = internals.drainBufferedData;

        pub fn getForceSync(this: *const @This()) bool {
            return this.force_sync;
        }

        pub fn makeSynchronous(this: *PosixWriter) void {
            this.force_sync = true;
            const fd = this.getFd();
            if (fd == bun.invalid_fd) return;
            if (bun.sys.updateNonblocking(fd, false) == .result) {
                this.descriptor.known_nonblocking = false;
                if (this.getPoll()) |poll| poll.flags.remove(.nonblocking);
            }
        }

        // TODO: configurable?
        const chunk_size: usize = std.heap.page_size_min;

        pub fn memoryCost(this: *const @This()) usize {
            return @sizeOf(@This()) + this.outgoing.memoryCost();
        }

        pub fn getPoll(this: *@This()) ?*Async.FilePoll {
            return this.handle.getPoll();
        }

        pub fn getFd(this: *PosixWriter) bun.FD {
            return this.handle.getFd();
        }

        fn writeOnce(this: *PosixWriter, force_sync: bool, buf: []const u8) bun.sys.Maybe(usize) {
            return this.descriptor.write(this.getFd(), force_sync, buf);
        }

        pub fn getFileType(this: *PosixWriter) FileType {
            return this.descriptor.fileType();
        }

        pub fn hasPendingData(this: *const PosixWriter) bool {
            return this.outgoing.isNotEmpty();
        }

        pub fn shouldBuffer(this: *const PosixWriter, addition: usize) bool {
            return !this.force_sync and addition < chunk_size -| this.outgoing.size();
        }

        const PosixWriter = @This();

        pub fn getBuffer(this: *const PosixWriter) []const u8 {
            return this.outgoing.slice();
        }

        fn _onError(
            this: *PosixWriter,
            err: bun.sys.Error,
            written: usize,
        ) void {
            this.closeWithoutReporting();
            this.is_done = true;
            this.outgoing.reset();

            reportWriteError(Parent, function_table, this.parent, err, written);
            this.close();
        }

        fn _onWrite(
            this: *PosixWriter,
            written: usize,
            status: WriteStatus,
        ) void {
            this.outgoing.wrote(written);

            if (status == .end_of_file and !this.is_done) {
                this.closeWithoutReporting();
            }

            if (this.outgoing.isEmpty()) {
                this.outgoing.cursor = 0;
                if (status != .end_of_file) {
                    this.outgoing.maybeShrink();
                }
                this.outgoing.list.clearRetainingCapacity();
            }

            onWrite(this.parent, written, status);
        }

        pub fn setParent(this: *PosixWriter, parent: *Parent) void {
            this.parent = parent;
            this.handle.setOwner(this);
        }

        fn _onWritable(this: *PosixWriter) void {
            if (this.is_done or this.closed_without_reporting) {
                return;
            }

            this.outgoing.reset();

            if (onWritable) |cb| {
                cb(@ptrCast(this.parent));
            }
        }

        fn closeWithoutReporting(this: *PosixWriter) void {
            if (this.getFd() != bun.invalid_fd) {
                bun.assert(!this.closed_without_reporting);
                this.closed_without_reporting = true;
                this.handle.close(null, {});
            }
        }

        fn registerPoll(this: *PosixWriter) bun.sys.Maybe(void) {
            const poll = this.getPoll() orelse return .success;
            return poll.registerWithFd(this.parent.loop(), .writable, .dispatch, poll.fd);
        }

        fn waitForWritable(this: *PosixWriter) bun.sys.Maybe(void) {
            if (this.handle == .fd) {
                const fd = this.handle.fd;
                const poll = Async.FilePoll.create(this.parent.eventLoop().runtimeLoopHandle(), fd, .{}, PosixWriter, this) catch
                    return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
                this.handle = .{ .poll = poll };
                this.descriptor.configurePoll(this.handle.poll);
            }
            const poll = this.getPoll() orelse return .success;
            return poll.registerWithFd(this.parent.loop(), .writable, .dispatch, poll.fd);
        }

        pub fn writeUTF16(this: *PosixWriter, buf: []const u16) OOM!WriteResult {
            const owner = this.parent;
            owner.ref();
            defer owner.deref();
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            const before_len = this.outgoing.size();

            this.outgoing.writeUTF16(buf) catch {
                return error.OutOfMemory;
            };

            const buf_len = this.outgoing.size() - before_len;

            return this.maybeWriteNewlyBufferedData(buf_len);
        }

        pub fn writeLatin1(this: *PosixWriter, buf: []const u8) OOM!WriteResult {
            const owner = this.parent;
            owner.ref();
            defer owner.deref();
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            if (bun.strings.isAllASCII(buf)) {
                return this.write(buf);
            }

            const before_len = this.outgoing.size();

            const check_ascii = false;
            this.outgoing.writeLatin1(buf, check_ascii) catch {
                return error.OutOfMemory;
            };

            const buf_len = this.outgoing.size() - before_len;

            return this.maybeWriteNewlyBufferedData(buf_len);
        }

        fn maybeWriteNewlyBufferedData(this: *PosixWriter, buf_len: usize) WriteResult {
            bun.assert(!this.is_done);

            if (this.shouldBuffer(0)) {
                if (this.registerPoll().asErr()) |err| {
                    this._onError(err, 0);
                    return .{ .err = err };
                }
                onWrite(this.parent, buf_len, .buffered);

                return .{ .wrote = buf_len };
            }

            return this.tryWriteNewlyBufferedData(this.outgoing.slice());
        }

        fn tryWriteNewlyBufferedData(this: *PosixWriter, buf: []const u8) WriteResult {
            bun.assert(!this.is_done);

            const rc = internals.tryWrite(this, this.force_sync, buf);

            switch (rc) {
                .wrote => |amt| {
                    bun.assert(amt == this.outgoing.size());
                    this.outgoing.reset();
                    onWrite(this.parent, amt, .drained);
                },
                .done => |amt| {
                    this.outgoing.reset();
                    onWrite(this.parent, amt, .end_of_file);
                },
                .pending => |amt| {
                    this.outgoing.wrote(amt);
                    if (this.waitForWritable().asErr()) |err| {
                        this._onError(err, amt);
                        return .{ .err = err };
                    }
                    onWrite(this.parent, amt, .pending);
                },

                .err => |failure| {
                    this._onError(failure.cause, failure.written);
                    return .{ .err = failure.cause };
                },
            }

            return rc.result();
        }

        pub fn write(this: *PosixWriter, buf: []const u8) OOM!WriteResult {
            const owner = this.parent;
            owner.ref();
            defer owner.deref();
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            if (this.shouldBuffer(buf.len)) {

                // this is streaming, but we buffer the data below `chunk_size` to
                // reduce the number of writes
                this.outgoing.write(buf) catch {
                    return error.OutOfMemory;
                };

                if (this.registerPoll().asErr()) |err| {
                    this._onError(err, 0);
                    return .{ .err = err };
                }
                onWrite(this.parent, buf.len, .buffered);

                // it's buffered, but should be reported as written to
                // callers
                return .{ .wrote = buf.len };
            }

            if (this.outgoing.size() > 0) {
                // make sure write is in-order
                this.outgoing.write(buf) catch {
                    return error.OutOfMemory;
                };

                return this.tryWriteNewlyBufferedData(this.outgoing.slice());
            }

            if (this.descriptor.isPollable()) try this.outgoing.ensureUnusedCapacity(buf.len);
            const rc = internals.tryWrite(this, this.force_sync, buf);

            switch (rc) {
                .pending => |amt| {
                    this.outgoing.writeAssumeCapacity(buf[amt..]);
                    if (this.waitForWritable().asErr()) |err| {
                        this._onError(err, amt);
                        return .{ .err = err };
                    }
                    onWrite(this.parent, amt, .pending);
                },
                .wrote => |amt| {
                    bun.assert(amt == buf.len);
                    this.outgoing.reset();
                    onWrite(this.parent, amt, .drained);
                },
                .done => |amt| {
                    this.outgoing.reset();
                    onWrite(this.parent, amt, .end_of_file);
                    return .{ .done = amt };
                },
                .err => |failure| {
                    this._onError(failure.cause, failure.written);
                    return .{ .err = failure.cause };
                },
            }

            return rc.result();
        }

        pub fn flush(this: *PosixWriter) WriteResult {
            const owner = this.parent;
            owner.ref();
            defer owner.deref();
            if (this.closed_without_reporting or this.is_done) {
                return .{ .done = 0 };
            }

            const buffer = this.getBuffer();
            if (buffer.len == 0) {
                this.outgoing.reset();
                return .{ .wrote = 0 };
            }

            const rc = this.drainBufferedData(buffer, std.math.maxInt(usize), brk: {
                if (this.getPoll()) |poll| {
                    break :brk poll.flags.contains(.hup);
                }

                break :brk false;
            });
            // update head
            switch (rc) {
                .pending => |written| {
                    this.outgoing.wrote(written);
                    if (this.outgoing.isEmpty()) {
                        this.outgoing.reset();
                    }
                    if (this.waitForWritable().asErr()) |err| {
                        this._onError(err, written);
                        return .{ .err = err };
                    }
                },
                .wrote => |written| {
                    this.outgoing.wrote(written);
                    if (this.outgoing.isEmpty()) {
                        this.outgoing.reset();
                    }
                },
                .err => |failure| {
                    this._onError(failure.cause, failure.written);
                    return .{ .err = failure.cause };
                },
                .done => {
                    this.outgoing.reset();
                },
            }
            switch (rc) {
                .pending => |written| onWrite(this.parent, written, .pending),
                .wrote => |written| onWrite(this.parent, written, .drained),
                .done => |written| onWrite(this.parent, written, .end_of_file),
                .err => {},
            }
            return rc.result();
        }

        pub fn deinit(this: *PosixWriter) void {
            this.closeWithoutReporting();
            this.outgoing.deinit();
        }

        pub fn hasRef(this: *PosixWriter) bool {
            const poll = this.getPoll() orelse return false;
            return !this.is_done and poll.canEnableKeepingProcessAlive();
        }

        pub fn enableKeepingProcessAlive(this: *PosixWriter, event_loop: anytype) void {
            if (this.is_done) return;
            const poll = this.getPoll() orelse return;

            poll.enableKeepingProcessAlive(event_loop.runtimeLoopHandle());
        }

        pub fn disableKeepingProcessAlive(this: *PosixWriter, event_loop: anytype) void {
            const poll = this.getPoll() orelse return;
            poll.disableKeepingProcessAlive(event_loop.runtimeLoopHandle());
        }

        pub fn updateRef(this: *PosixWriter, event_loop: anytype, value: bool) void {
            if (value) {
                this.enableKeepingProcessAlive(event_loop);
            } else {
                this.disableKeepingProcessAlive(event_loop);
            }
        }

        pub fn end(this: *PosixWriter) void {
            if (this.is_done) {
                return;
            }

            this.is_done = true;
            this.close();
        }

        pub fn close(this: *PosixWriter) void {
            if (this.closed_without_reporting) {
                this.closed_without_reporting = false;
                bun.assert(this.getFd() == bun.invalid_fd);
                onClose(this.parent);
                return;
            }

            this.handle.close(this.parent, onClose);
        }

        pub fn start(this: *PosixWriter, fd: bun.FD, options: WriterStartOptions) bun.sys.Maybe(void) {
            var effective_options = options;
            effective_options.force_sync = effective_options.force_sync or this.force_sync;
            this.descriptor = switch (PosixDescriptor.init(fd, effective_options)) {
                .result => |descriptor| descriptor,
                .err => |err| return .{ .err = err },
            };
            this.force_sync = this.descriptor.forceSync(effective_options);

            if (!this.descriptor.isPollable()) {
                this.handle = .{ .fd = fd };
                return .success;
            }

            const loop = this.parent.eventLoop().runtimeLoopHandle();
            var poll = this.getPoll() orelse brk: {
                const created = Async.FilePoll.create(loop, fd, .{}, PosixWriter, this) catch
                    return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
                this.handle = .{ .poll = created };
                break :brk this.handle.poll;
            };
            this.descriptor.configurePoll(poll);

            switch (poll.registerWithFd(loop.platformLoop(), .writable, .dispatch, fd)) {
                .err => |err| {
                    this.handle.closeImpl(null, {}, false);
                    if (!this.descriptor.requiresPoll()) {
                        this.handle = .{ .fd = fd };
                        return .success;
                    }
                    return bun.sys.Maybe(void){ .err = err };
                },
                .result => {},
            }

            return .success;
        }
    };
}

/// Will provide base behavior for pipe writers
/// The WindowsPipeWriter type should implement the following interface:
/// struct {
///   source: ?Source = null,
///   parent: *Parent = undefined,
///   is_done: bool = false,
///   pub fn startWithCurrentPipe(this: *WindowsPipeWriter) bun.sys.Maybe(void),
///   fn onClosePipe(pipe: *uv.Pipe) callconv(.c) void,
/// };
fn BaseWindowsPipeWriter(
    comptime WindowsPipeWriter: type,
    comptime Parent: type,
) type {
    const Impl = struct {
        /// Closing invalidates stack frames before a notification can destroy their writer.
        pub const CallbackFrame = struct {
            owner: ?*WindowsPipeWriter,
            previous: ?*CallbackFrame,

            pub fn enter(frame: *CallbackFrame, owner: *WindowsPipeWriter) void {
                frame.* = .{ .owner = owner, .previous = owner.callback_frame };
                owner.callback_frame = frame;
            }

            pub fn leave(frame: *CallbackFrame) void {
                if (frame.owner) |owner| owner.callback_frame = frame.previous;
            }
        };

        pub fn getFd(this: *const WindowsPipeWriter) bun.FD {
            const pipe = this.source orelse return bun.invalid_fd;
            return pipe.getFd();
        }

        pub fn hasRef(this: *const WindowsPipeWriter) bool {
            if (this.is_done) {
                return false;
            }
            if (this.source) |pipe| return pipe.hasRef();
            return false;
        }

        pub fn enableKeepingProcessAlive(this: *WindowsPipeWriter, event_loop: anytype) void {
            this.updateRef(event_loop, true);
        }

        pub fn disableKeepingProcessAlive(this: *WindowsPipeWriter, event_loop: anytype) void {
            this.updateRef(event_loop, false);
        }

        fn onPipeClose(handle: *uv.Pipe) callconv(.c) void {
            const this = bun.cast(*uv.Pipe, handle.data);
            bun.default_allocator.destroy(this);
        }

        fn onTTYClose(handle: *uv.uv_tty_t) callconv(.c) void {
            const this = bun.cast(*uv.uv_tty_t, handle.data);
            bun.default_allocator.destroy(this);
        }

        pub fn close(this: *WindowsPipeWriter) void {
            this.is_done = true;
            var frame = bun.take(&this.callback_frame);
            while (frame) |active| {
                active.owner = null;
                frame = active.previous;
            }
            const source = this.source orelse return;
            const stream_write = bun.take(&this.stream_write);
            const has_inflight_write = if (@hasField(WindowsPipeWriter, "current_payload"))
                stream_write != null or switch (source) {
                    .sync_file, .file => |file| file.state == .operating or file.state == .canceling,
                    else => false,
                }
            else
                false;
            if (stream_write) |write| write.detach();
            switch (source) {
                .sync_file, .file => |file| file.detach(),
                .pipe => |pipe| {
                    pipe.data = pipe;
                    pipe.close(onPipeClose);
                },
                .tty => |tty| {
                    tty.data = tty;
                    tty.close(onTTYClose);
                },
            }
            this.source = null;
            const parent = this.parent;
            this.onCloseSource();
            if (has_inflight_write) parent.deref();
        }

        pub fn updateRef(this: *WindowsPipeWriter, _: anytype, value: bool) void {
            if (this.source) |pipe| {
                if (value) {
                    pipe.ref();
                } else {
                    pipe.unref();
                }
            }
        }

        pub fn setParent(this: *WindowsPipeWriter, parent: *Parent) void {
            this.parent = parent;
            if (!this.is_done) {
                if (this.source) |pipe| {
                    pipe.setData(this);
                }
            }
        }

        pub fn watch(_: *WindowsPipeWriter) void {
            // no-op
        }

        pub fn startWithPipe(this: *WindowsPipeWriter, pipe: *uv.Pipe) bun.sys.Maybe(void) {
            bun.assert(this.source == null);
            this.source = .{ .pipe = pipe };
            this.setParent(this.parent);
            return this.startWithCurrentPipe();
        }

        pub fn startSync(this: *WindowsPipeWriter, fd: bun.FD) bun.sys.Maybe(void) {
            bun.assert(this.source == null);
            const file = switch (openFile(this, fd)) {
                .result => |file| file,
                .err => |err| return .{ .err = err },
            };
            const source = Source{ .sync_file = file };
            source.setData(this);
            this.source = source;
            this.setParent(this.parent);
            return this.startWithCurrentPipe();
        }

        pub fn startWithFile(this: *WindowsPipeWriter, fd: bun.FD) bun.sys.Maybe(void) {
            bun.assert(this.source == null);
            const file = switch (openFile(this, fd)) {
                .result => |file| file,
                .err => |err| return .{ .err = err },
            };
            const source: Source = .{ .file = file };
            source.setData(this);
            this.source = source;
            this.setParent(this.parent);
            return this.startWithCurrentPipe();
        }

        fn openFile(this: *WindowsPipeWriter, fd: bun.FD) bun.sys.Maybe(*Source.File) {
            const owned_fd = if (this.owns_fd) fd else switch (bun.sys.dupForLibUV(fd)) {
                .result => |copy| copy,
                .err => |err| return .{ .err = err },
            };
            return switch (Source.openFile(this.parent.loop(), owned_fd)) {
                .result => |file| .{ .result = file },
                .err => |err| {
                    if (!this.owns_fd) _ = owned_fd.closeAllowingStandardIo(null);
                    return .{ .err = err };
                },
            };
        }

        pub fn start(this: *WindowsPipeWriter, rawfd: anytype, options: WriterStartOptions) bun.sys.Maybe(void) {
            const FDType = @TypeOf(rawfd);
            const fd = switch (FDType) {
                bun.FD => rawfd,
                *bun.MovableIfWindowsFd => rawfd.get().?,
                else => @compileError("Expected `bun.FD` or `*bun.MovableIfWindowsFd` but got: " ++ @typeName(rawfd)),
            };
            bun.assert(this.source == null);
            const owned_fd = if (this.owns_fd) fd else switch (bun.sys.dupForLibUV(fd)) {
                .result => |copy| copy,
                .err => |err| return .{ .err = err },
            };
            const loop = this.parent.loop();
            const opened = if (options.force_sync) file: {
                break :file switch (Source.openFile(loop, owned_fd)) {
                    .result => |file| bun.sys.Maybe(Source){ .result = .{ .sync_file = file } },
                    .err => |err| bun.sys.Maybe(Source){ .err = err },
                };
            } else Source.open(loop, owned_fd);
            const source = switch (opened) {
                .result => |source| source,
                .err => |err| {
                    if (!this.owns_fd) _ = owned_fd.closeAllowingStandardIo(null);
                    return .{ .err = err };
                },
            };
            if (FDType == *bun.MovableIfWindowsFd and this.owns_fd) _ = rawfd.take();
            source.setData(this);
            this.source = source;
            this.setParent(this.parent);
            return this.startWithCurrentPipe();
        }

        pub fn setPipe(this: *WindowsPipeWriter, pipe: *uv.Pipe) void {
            this.source = .{ .pipe = pipe };
            this.setParent(this.parent);
        }

        pub fn getStream(this: *const WindowsPipeWriter) ?*uv.uv_stream_t {
            const source = this.source orelse return null;
            if (source == .file or source == .sync_file) return null;
            return source.toStream();
        }
    };
    return Impl;
}

/// See below for the expected signature of `function_table`. In many cases, the
/// function table can be the same as `Parent`. `anytype` is used because of a
/// dependency loop in Zig.
pub fn WindowsBufferedWriter(Parent: type, function_table: anytype) type {
    return struct {
        source: ?Source = null,
        owns_fd: bool = true,
        parent: *Parent = undefined,
        is_done: bool = false,
        stream_write: ?*Source.StreamWrite = null,
        callback_frame: ?*internals.CallbackFrame = null,
        pending_payload_size: usize = 0,
        submitting: bool = false,

        const onWrite: *const fn (*Parent, amount: usize, status: WriteStatus) void = function_table.onWrite;
        const onError: *const fn (*Parent, bun.sys.Error) void = function_table.onError;
        const onClose: ?*const fn (*Parent) void = function_table.onClose;
        const getBuffer: *const fn (*Parent) []const u8 = function_table.getBuffer;
        const onWritable: ?*const fn (*Parent) void = function_table.onWritable;

        const WindowsWriter = @This();

        const internals = BaseWindowsPipeWriter(WindowsWriter, Parent);
        pub const getFd = internals.getFd;
        pub const hasRef = internals.hasRef;
        pub const enableKeepingProcessAlive = internals.enableKeepingProcessAlive;
        pub const disableKeepingProcessAlive = internals.disableKeepingProcessAlive;
        pub const close = internals.close;
        pub const updateRef = internals.updateRef;
        pub const setParent = internals.setParent;
        pub const watch = internals.watch;
        pub const startWithPipe = internals.startWithPipe;
        pub const startSync = internals.startSync;
        pub const startWithFile = internals.startWithFile;
        pub const start = internals.start;
        pub const setPipe = internals.setPipe;
        pub const getStream = internals.getStream;

        fn onCloseSource(this: *WindowsWriter) void {
            if (onClose) |onCloseFn| {
                onCloseFn(this.parent);
            }
        }

        pub fn memoryCost(this: *const WindowsWriter) usize {
            const source_cost = if (this.source) |source| source.memoryCost() else 0;
            const write_cost = if (this.stream_write) |pending| @sizeOf(Source.StreamWrite) + pending.bytes.len else 0;
            return @sizeOf(@This()) + source_cost + write_cost;
        }

        pub fn startWithCurrentPipe(this: *WindowsWriter) bun.sys.Maybe(void) {
            bun.assert(this.source != null);
            this.is_done = false;
            return this.submit();
        }

        fn onWriteComplete(this: *WindowsWriter, status: uv.ReturnCode) void {
            var frame: internals.CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();
            const written = this.pending_payload_size;
            this.pending_payload_size = 0;
            if (status.toError(.write)) |err| {
                return this.fail(err);
            }
            onWrite(this.parent, @intCast(written), if (this.is_done) .drained else .pending);
            const current = frame.owner orelse return;
            if (current.is_done and current.pending_payload_size == 0 and current.getBufferInternal().len == 0)
                return current.close();
            if (onWritable) |onWritableFn| {
                onWritableFn(current.parent);
            }
        }

        fn fail(this: *WindowsWriter, err: bun.sys.Error) void {
            var frame: internals.CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();
            this.pending_payload_size = 0;
            this.is_done = true;
            onError(this.parent, err);
            if (frame.owner) |current| current.close();
        }

        fn onStreamWriteComplete(parent: *anyopaque, status: uv.ReturnCode) void {
            const this = bun.cast(*WindowsWriter, parent);
            this.stream_write = null;
            this.onWriteComplete(status);
        }

        fn onFsWriteComplete(fs: *uv.fs_t) callconv(.c) void {
            const file = Source.File.fromFS(fs);
            const result = fs.result;
            const was_canceled = result.int() == uv.UV_ECANCELED;
            const parent_ptr = fs.data;

            file.complete();

            if (parent_ptr == null) {
                return;
            }

            const this = bun.cast(*WindowsWriter, parent_ptr);

            if (was_canceled) {
                // Canceled write - clear pending state
                this.pending_payload_size = 0;
                return;
            }

            if (result.toError(.write)) |err| {
                return this.fail(err);
            }

            this.onWriteComplete(.zero);
        }

        pub fn write(this: *WindowsWriter) void {
            if (this.submit().asErr()) |err| this.fail(err);
        }

        fn submit(this: *WindowsWriter) bun.sys.Maybe(void) {
            if (this.submitting) return .success;
            var frame: internals.CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();
            this.submitting = true;
            defer if (frame.owner) |current| {
                current.submitting = false;
            };

            while (frame.owner) |current| {
                if (current.is_done or current.pending_payload_size > 0) return .success;
                const buffer = current.getBufferInternal();
                if (buffer.len == 0) return .success;
                const source = current.source orelse return .{ .err = bun.sys.Error.fromCode(.PIPE, .write) };
                switch (source) {
                    .sync_file => |file| {
                        var remaining = buffer;
                        while (remaining.len > 0) {
                            switch (bun.FD.fromUV(file.file).write(remaining)) {
                                .err => |err| return .{ .err = err },
                                .result => |written| {
                                    if (written == 0) return .{ .err = bun.sys.Error.fromCode(.IO, .write) };
                                    remaining = remaining[written..];
                                },
                            }
                        }
                        current.pending_payload_size = buffer.len;
                        current.onWriteComplete(.zero);
                    },
                    .file => |file| {
                        bun.assert(file.canStart());
                        current.pending_payload_size = buffer.len;
                        file.fs.setData(current);
                        if (file.write(buffer, onFsWriteComplete).asErr()) |err| {
                            current.pending_payload_size = 0;
                            return .{ .err = err };
                        }
                        return .success;
                    },
                    else => {
                        current.pending_payload_size = buffer.len;
                        current.stream_write = switch (Source.StreamWrite.start(source.toStream(), buffer, current, onStreamWriteComplete)) {
                            .result => |result| result,
                            .err => |err| {
                                current.pending_payload_size = 0;
                                return .{ .err = err };
                            },
                        };
                        return .success;
                    },
                }
            }
            return .success;
        }

        fn getBufferInternal(this: *WindowsWriter) []const u8 {
            return getBuffer(this.parent);
        }

        pub fn end(this: *WindowsWriter) void {
            if (this.is_done) {
                return;
            }

            this.is_done = true;
            if (this.pending_payload_size == 0) {
                // will auto close when pending stuff get written
                this.close();
            }
        }
    };
}

/// Basic std.array_list.Managed(u8) + usize cursor wrapper
pub const StreamBuffer = struct {
    list: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(bun.default_allocator),
    cursor: usize = 0,

    pub fn reset(this: *StreamBuffer) void {
        this.cursor = 0;
        this.maybeShrink();
        this.list.clearRetainingCapacity();
    }

    pub fn maybeShrink(this: *StreamBuffer) void {
        if (this.list.capacity > std.heap.pageSize()) {
            // workaround insane zig decision to make it undefined behavior to resize .len < .capacity
            this.list.expandToCapacity();
            this.list.shrinkAndFree(std.heap.pageSize());
        }
    }

    pub fn memoryCost(this: *const StreamBuffer) usize {
        return this.list.capacity;
    }

    pub fn size(this: *const StreamBuffer) usize {
        return this.list.items.len - this.cursor;
    }

    pub fn isEmpty(this: *const StreamBuffer) bool {
        return this.size() == 0;
    }

    pub fn isNotEmpty(this: *const StreamBuffer) bool {
        return this.size() > 0;
    }

    pub fn write(this: *StreamBuffer, buffer: []const u8) OOM!void {
        _ = try this.list.appendSlice(buffer);
    }

    pub fn wrote(this: *StreamBuffer, amount: usize) void {
        this.cursor += amount;
    }

    pub fn writeAssumeCapacity(this: *StreamBuffer, buffer: []const u8) void {
        this.list.appendSliceAssumeCapacity(buffer);
    }

    pub fn ensureUnusedCapacity(this: *StreamBuffer, capacity: usize) OOM!void {
        return this.list.ensureUnusedCapacity(capacity);
    }

    pub fn writeTypeAsBytesAssumeCapacity(this: *StreamBuffer, comptime T: type, data: T) void {
        var byte_list = bun.ByteList.moveFromList(&this.list);
        defer this.list = byte_list.moveToListManaged(this.list.allocator);
        byte_list.writeTypeAsBytesAssumeCapacity(T, data);
    }

    pub fn writeOrFallback(this: *StreamBuffer, buffer: anytype, comptime writeFn: anytype) OOM![]const u8 {
        if (comptime @TypeOf(writeFn) == @TypeOf(&writeLatin1) and writeFn == &writeLatin1) {
            if (bun.strings.isAllASCII(buffer)) {
                return buffer;
            }

            {
                var byte_list = bun.ByteList.moveFromList(&this.list);
                defer this.list = byte_list.moveToListManaged(this.list.allocator);
                _ = try byte_list.writeLatin1(this.list.allocator, buffer);
            }

            return this.list.items[this.cursor..];
        } else if (comptime @TypeOf(writeFn) == @TypeOf(&writeUTF16) and writeFn == &writeUTF16) {
            {
                var byte_list = bun.ByteList.moveFromList(&this.list);
                defer this.list = byte_list.moveToListManaged(this.list.allocator);

                _ = try byte_list.writeUTF16(this.list.allocator, buffer);
            }

            return this.list.items[this.cursor..];
        } else if (comptime @TypeOf(writeFn) == @TypeOf(&write) and writeFn == &write) {
            return buffer;
        } else {
            @compileError("Unsupported writeFn " ++ @typeName(@TypeOf(writeFn)));
        }
    }

    pub fn writeLatin1(this: *StreamBuffer, buffer: []const u8, comptime check_ascii: bool) OOM!void {
        if (comptime check_ascii) {
            if (bun.strings.isAllASCII(buffer)) {
                return this.write(buffer);
            }
        }

        var byte_list = bun.ByteList.moveFromList(&this.list);
        defer this.list = byte_list.moveToListManaged(this.list.allocator);

        _ = try byte_list.writeLatin1(this.list.allocator, buffer);
    }

    pub fn writeUTF16(this: *StreamBuffer, buffer: []const u16) OOM!void {
        var byte_list = bun.ByteList.moveFromList(&this.list);
        defer this.list = byte_list.moveToListManaged(this.list.allocator);

        _ = try byte_list.writeUTF16(this.list.allocator, buffer);
    }

    pub fn slice(this: *const StreamBuffer) []const u8 {
        return this.list.items[this.cursor..];
    }

    pub fn deinit(this: *StreamBuffer) void {
        this.cursor = 0;
        if (this.list.capacity > 0) {
            this.list.clearAndFree();
        }
    }
};

/// See below for the expected signature of `function_table`. In many cases, the
/// function table can be the same as `Parent`. `anytype` is used because of a
/// dependency loop in Zig.
pub fn WindowsStreamingWriter(comptime Parent: type, function_table: anytype) type {
    return struct {
        /// reports the amount written and done means that we dont have any
        /// other pending data to send (but we may send more data)
        const onWrite: fn (*Parent, amount: usize, status: WriteStatus) void = function_table.onWrite;
        const onError: fn (*Parent, bun.sys.Error) void = function_table.onError;
        const onWritable: ?fn (*Parent) void = function_table.onWritable;
        const onClose: fn (*Parent) void = function_table.onClose;

        source: ?Source = null,
        /// Whether start consumes the caller's descriptor or duplicates it.
        owns_fd: bool = true,
        parent: *Parent = undefined,
        is_done: bool = false,
        force_sync: bool = false,
        stream_write: ?*Source.StreamWrite = null,
        callback_frame: ?*internals.CallbackFrame = null,

        // queue any data that we want to write here
        outgoing: StreamBuffer = .{},
        // libuv requires a stable ptr when doing async so we swap buffers
        current_payload: StreamBuffer = .{},
        // some error happed? we will not report onClose only onError
        closed_without_reporting: bool = false,

        const internals = BaseWindowsPipeWriter(WindowsWriter, Parent);
        pub const getFd = internals.getFd;
        pub const hasRef = internals.hasRef;
        pub const enableKeepingProcessAlive = internals.enableKeepingProcessAlive;
        pub const disableKeepingProcessAlive = internals.disableKeepingProcessAlive;
        pub const close = internals.close;
        pub const updateRef = internals.updateRef;
        pub const setParent = internals.setParent;
        pub const watch = internals.watch;
        pub const startWithPipe = internals.startWithPipe;
        pub const startWithFile = internals.startWithFile;
        pub const setPipe = internals.setPipe;
        pub const getStream = internals.getStream;

        pub fn startSync(this: *WindowsWriter, fd: bun.FD) bun.sys.Maybe(void) {
            this.force_sync = true;
            return internals.startSync(this, fd);
        }

        pub fn start(this: *WindowsWriter, rawfd: anytype, options: WriterStartOptions) bun.sys.Maybe(void) {
            var effective_options = options;
            effective_options.force_sync = effective_options.force_sync or this.force_sync;
            return internals.start(this, rawfd, effective_options);
        }

        pub fn makeSynchronous(this: *WindowsWriter) void {
            this.force_sync = true;
            if (this.hasPendingData()) return;
            const source = this.source orelse return;
            switch (source) {
                .pipe => |pipe| _ = uv.uv_stream_set_blocking(@ptrCast(pipe), 1),
                .tty => |tty| _ = uv.uv_stream_set_blocking(@ptrCast(tty), 1),
                .file => |file| {
                    if (file.canStart()) this.source = .{ .sync_file = file };
                },
                .sync_file => {},
            }
        }

        pub fn memoryCost(this: *const WindowsWriter) usize {
            const source_cost = if (this.source) |source| source.memoryCost() else 0;
            const write_cost = if (this.stream_write) |pending| @sizeOf(Source.StreamWrite) + pending.bytes.len else 0;
            return @sizeOf(@This()) + this.current_payload.memoryCost() + this.outgoing.memoryCost() + source_cost + write_cost;
        }

        fn onCloseSource(this: *WindowsWriter) void {
            this.source = null;
            if (this.closed_without_reporting) {
                this.closed_without_reporting = false;
                return;
            }
            onClose(this.parent);
        }

        pub fn startWithCurrentPipe(this: *WindowsWriter) bun.sys.Maybe(void) {
            bun.assert(this.source != null);
            this.is_done = false;
            return .success;
        }

        pub fn hasPendingData(this: *const WindowsWriter) bool {
            return (this.outgoing.isNotEmpty() or this.current_payload.isNotEmpty());
        }

        fn isDone(this: *WindowsWriter) bool {
            // done is flags andd no more data queued? so we are done!
            return this.is_done and !this.hasPendingData();
        }

        fn onWriteComplete(this: *WindowsWriter, status: uv.ReturnCode) void {
            const parent = this.parent;
            defer parent.deref();
            var frame: internals.CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();

            if (status.toError(.write)) |err| {
                return this.fail(err);
            }

            // success means that we send all the data inside current_payload
            const written = this.current_payload.size();
            this.current_payload.reset();
            if (this.force_sync and this.outgoing.isEmpty()) this.makeSynchronous();

            // if we dont have more outgoing data we report done in onWrite
            const done = this.outgoing.isEmpty();
            const was_done = this.is_done;

            log("onWrite({d}) ({d} left)", .{ written, this.outgoing.size() });

            if (was_done and done) {
                // we already call .end lets close the connection
                onWrite(this.parent, written, .end_of_file);
                return;
            }

            // report data written
            onWrite(this.parent, written, if (done) .drained else .pending);

            const current = frame.owner orelse return;
            _ = current.processSend();
            const still_open = frame.owner orelse return;
            if (onWritable) |onWritableFn| {
                onWritableFn(still_open.parent);
            }
        }

        fn fail(this: *WindowsWriter, err: bun.sys.Error) void {
            var frame: internals.CallbackFrame = undefined;
            frame.enter(this);
            defer frame.leave();
            this.is_done = true;
            this.current_payload.reset();
            onError(this.parent, err);
            if (frame.owner) |current| current.closeWithoutReporting();
        }

        fn onStreamWriteComplete(parent: *anyopaque, status: uv.ReturnCode) void {
            const this = bun.cast(*WindowsWriter, parent);
            this.stream_write = null;
            this.onWriteComplete(status);
        }

        fn onFsWriteComplete(fs: *uv.fs_t) callconv(.c) void {
            const file = Source.File.fromFS(fs);
            const result = fs.result;
            const was_canceled = result.int() == uv.UV_ECANCELED;
            const parent_ptr = fs.data;

            file.complete();

            if (parent_ptr == null) {
                return;
            }

            const this = bun.cast(*WindowsWriter, parent_ptr);

            if (was_canceled) {
                // Canceled write - reset buffers and deref to balance processSend ref
                this.current_payload.reset();
                this.parent.deref();
                return;
            }

            if (result.toError(.write)) |err| {
                const parent = this.parent;
                defer parent.deref();
                return this.fail(err);
            }

            // onWriteComplete handles the deref
            this.onWriteComplete(.zero);
        }

        fn processSend(this: *WindowsWriter) WriteResult {
            log("processSend", .{});
            if (this.current_payload.isNotEmpty()) {
                return .{ .pending = 0 };
            }

            const bytes = this.outgoing.slice();
            // nothing todo (we assume we are writable until we try to write something)
            if (bytes.len == 0) {
                return .{ .wrote = 0 };
            }

            const pipe = this.source orelse {
                const err = bun.sys.Error.fromCode(bun.sys.E.PIPE, .pipe);
                this.fail(err);
                return .{ .err = err };
            };

            // current payload is empty we can just swap with outgoing
            const temp = this.current_payload;
            this.current_payload = this.outgoing;
            this.outgoing = temp;
            switch (pipe) {
                .sync_file => {
                    @panic("sync_file pipe write should not be reachable");
                },
                .file => |file| {
                    bun.assert(file.canStart());

                    file.fs.setData(this);
                    if (file.write(bytes, onFsWriteComplete).asErr()) |err| {
                        this.fail(err);
                        return .{ .err = err };
                    }
                },
                else => {
                    this.stream_write = switch (Source.StreamWrite.start(pipe.toStream(), bytes, this, onStreamWriteComplete)) {
                        .result => |result| result,
                        .err => |err| {
                            this.fail(err);
                            return .{ .err = err };
                        },
                    };
                },
            }
            // Ref the parent to prevent it from being freed while the async
            // write is in flight. The matching deref is in onWriteComplete
            // or onFsWriteComplete.
            this.parent.ref();
            return .{ .pending = 0 };
        }

        const WindowsWriter = @This();

        fn closeWithoutReporting(this: *WindowsWriter) void {
            if (this.source != null) {
                bun.assert(!this.closed_without_reporting);
                this.closed_without_reporting = true;
            }
            this.close();
        }

        pub fn deinit(this: *WindowsWriter) void {
            this.closeWithoutReporting();
            this.outgoing.deinit();
            this.current_payload.deinit();
        }

        fn writeInternal(this: *WindowsWriter, buffer: anytype, comptime writeFn: anytype) OOM!WriteResult {
            const owner = this.parent;
            owner.ref();
            defer owner.deref();
            if (this.is_done) {
                return .{ .done = 0 };
            }

            if (this.source != null and this.source.? == .sync_file) {
                defer this.outgoing.reset();
                var remain = StreamBuffer.writeOrFallback(&this.outgoing, buffer, comptime writeFn) catch {
                    return error.OutOfMemory;
                };
                const initial_len = remain.len;
                const fd: bun.FD = .fromUV(this.source.?.sync_file.file);

                while (remain.len > 0) {
                    switch (fd.write(remain)) {
                        .err => |err| {
                            return .{ .err = err };
                        },
                        .result => |wrote| {
                            if (wrote == 0) return .{ .err = bun.sys.Error.fromCode(.IO, .write) };
                            remain = remain[wrote..];
                        },
                    }
                }

                const wrote = initial_len - remain.len;
                if (wrote == 0) {
                    return .{ .done = wrote };
                }
                onWrite(this.parent, wrote, .drained);
                return .{ .wrote = wrote };
            }

            const had_buffered_data = this.outgoing.isNotEmpty();
            (if (comptime @TypeOf(writeFn) == @TypeOf(&StreamBuffer.writeLatin1) and writeFn == &StreamBuffer.writeLatin1)
                writeFn(&this.outgoing, buffer, true)
            else
                writeFn(&this.outgoing, buffer)) catch {
                return error.OutOfMemory;
            };
            if (had_buffered_data) {
                return .{ .pending = 0 };
            }
            return this.processSend();
        }

        pub fn writeUTF16(this: *WindowsWriter, buf: []const u16) OOM!WriteResult {
            return writeInternal(this, buf, &StreamBuffer.writeUTF16);
        }

        pub fn writeLatin1(this: *WindowsWriter, buffer: []const u8) OOM!WriteResult {
            return writeInternal(this, buffer, &StreamBuffer.writeLatin1);
        }

        pub fn write(this: *WindowsWriter, buffer: []const u8) OOM!WriteResult {
            return writeInternal(this, buffer, &StreamBuffer.write);
        }

        pub fn flush(this: *WindowsWriter) WriteResult {
            if (this.is_done) {
                return .{ .done = 0 };
            }
            if (!this.hasPendingData()) {
                return .{ .wrote = 0 };
            }

            return this.processSend();
        }

        pub fn end(this: *WindowsWriter) void {
            if (this.is_done) {
                return;
            }

            this.closed_without_reporting = false;
            this.is_done = true;

            if (!this.hasPendingData()) {
                this.close();
            }
        }
    };
}

pub const BufferedWriter = if (bun.Environment.isPosix) PosixBufferedWriter else WindowsBufferedWriter;
pub const StreamingWriter = if (bun.Environment.isPosix) PosixStreamingWriter else WindowsStreamingWriter;

const std = @import("std");
const Source = @import("./source.zig").Source;

const FileType = @import("./pipes.zig").FileType;
const PollOrFd = @import("./pipes.zig").PollOrFd;

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const OOM = bun.OOM;
const uv = bun.windows.libuv;
