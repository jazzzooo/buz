const NativeContext = bun.bindgen.NativeCallbackContext(.vm);

const BufferedReaderVTable = struct {
    parent: NativeContext = undefined,
    fns: *const Fn = undefined,

    pub fn init(comptime Type: type) BufferedReaderVTable {
        return .{
            .fns = Fn.init(Type),
        };
    }

    pub const Fn = struct {
        onReadChunk: ?*const fn (NativeContext, chunk: []const u8, hasMore: ReadState) bool = null,
        onReaderDone: *const fn (NativeContext) void,
        onReaderError: *const fn (NativeContext, bun.sys.Error) void,
        loop: *const fn (NativeContext) *Async.Loop,
        eventLoop: *const fn (NativeContext) RuntimeLoopHandle,

        pub fn init(comptime Type: type) *const BufferedReaderVTable.Fn {
            const fns = struct {
                fn onReadChunk(this: NativeContext, chunk: []const u8, hasMore: ReadState) bool {
                    return Type.onReadChunk(this.get(*Type), chunk, hasMore);
                }
                fn onReaderDone(this: NativeContext) void {
                    return Type.onReaderDone(this.get(*Type));
                }
                fn onReaderError(this: NativeContext, err: bun.sys.Error) void {
                    return Type.onReaderError(this.get(*Type), err);
                }
                fn eventLoop(this: NativeContext) RuntimeLoopHandle {
                    return Type.eventLoop(this.get(*Type)).runtimeLoopHandle();
                }
                fn loop(this: NativeContext) *Async.Loop {
                    return Type.loop(this.get(*Type));
                }
            };
            return comptime &BufferedReaderVTable.Fn{
                .onReadChunk = if (@hasDecl(Type, "onReadChunk")) &fns.onReadChunk else null,
                .onReaderDone = &fns.onReaderDone,
                .onReaderError = &fns.onReaderError,
                .eventLoop = &fns.eventLoop,
                .loop = &fns.loop,
            };
        }
    };

    pub fn eventLoop(this: @This()) RuntimeLoopHandle {
        return this.fns.eventLoop(this.parent);
    }

    pub fn loop(this: @This()) *Async.Loop {
        return this.fns.loop(this.parent);
    }

    pub fn isStreamingEnabled(this: @This()) bool {
        return this.fns.onReadChunk != null;
    }

    /// When the reader has read a chunk of data
    /// and hasMore is true, it means that there might be more data to read.
    ///
    /// Returning false prevents the reader from reading more data.
    pub fn onReadChunk(this: @This(), chunk: []const u8, hasMore: ReadState) bool {
        return this.fns.onReadChunk.?(this.parent, chunk, hasMore);
    }

    pub fn onReaderDone(this: @This()) void {
        this.fns.onReaderDone(this.parent);
    }

    pub fn onReaderError(this: @This(), err: bun.sys.Error) void {
        this.fns.onReaderError(this.parent, err);
    }
};

const DeferredReaderDeinit = struct {
    context: NativeContext,
    callback: *const fn (NativeContext) void,
};

const PosixBufferedReader = struct {
    handle: PollOrFd = .{ .closed = {} },
    _buffer: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(bun.default_allocator),
    _offset: usize = 0,
    vtable: BufferedReaderVTable,
    flags: Flags = .{},
    count: usize = 0,
    maxbuf: ?*MaxBuf = null,
    dispatch_depth: usize = 0,
    terminal: union(enum) { none, done, failure: bun.sys.Error } = .none,
    deferred_deinit: ?DeferredReaderDeinit = null,

    const Flags = packed struct(u16) {
        is_done: bool = false,
        pollable: bool = false,
        nonblocking: bool = false,
        socket: bool = false,
        received_eof: bool = false,
        closed_without_reporting: bool = false,
        close_handle: bool = true,
        memfd: bool = false,
        use_pread: bool = false,
        is_paused: bool = false,
        _: u6 = 0,
    };

    pub fn init(comptime Type: type) PosixBufferedReader {
        return .{
            .vtable = BufferedReaderVTable.init(Type),
        };
    }

    pub fn updateRef(this: *const PosixBufferedReader, value: bool) void {
        const poll = this.handle.getPoll() orelse return;
        poll.setKeepingProcessAlive(this.vtable.eventLoop(), value);
    }

    pub inline fn isDone(this: *const PosixBufferedReader) bool {
        return this.flags.is_done or this.flags.received_eof or this.flags.closed_without_reporting or this.terminal != .none;
    }

    pub fn memoryCost(this: *const PosixBufferedReader) usize {
        return @sizeOf(@This()) + this._buffer.capacity;
    }

    pub fn from(to: *@This(), other: *PosixBufferedReader, parent_: anytype) void {
        bun.assert(to.dispatch_depth == 0 and to.deferred_deinit == null);
        bun.assert(other.dispatch_depth == 0 and other.deferred_deinit == null);
        to.* = .{
            .handle = other.handle,
            ._buffer = other.buffer().*,
            ._offset = other._offset,
            .flags = other.flags,
            .vtable = .{
                .fns = to.vtable.fns,
                .parent = .init(parent_),
            },
        };
        other.buffer().* = std.array_list.Managed(u8).init(bun.default_allocator);
        other.flags.is_done = true;
        other.handle = .{ .closed = {} };
        other._offset = 0;
        MaxBuf.transferToPipereader(&other.maxbuf, &to.maxbuf);
        to.handle.setOwner(to);

        // note: the caller is supposed to drain the buffer themselves
        // doing it here automatically makes it very easy to end up reading from the same buffer multiple times.
    }

    pub fn setParent(this: *PosixBufferedReader, parent_: anytype) void {
        this.vtable.parent = .init(parent_);
        this.handle.setOwner(this);
    }

    pub fn startMemfd(this: *PosixBufferedReader, fd: bun.FD) void {
        this.flags.memfd = true;
        this.handle = .{ .fd = fd };
    }

    pub fn getFileType(this: *const PosixBufferedReader) FileType {
        const flags = this.flags;
        if (flags.socket) {
            return .socket;
        }

        if (flags.pollable) {
            if (flags.nonblocking) {
                return .nonblocking_pipe;
            }

            return .pipe;
        }

        return .file;
    }

    pub fn close(this: *PosixBufferedReader) void {
        this.done();
    }

    fn closeWithoutReporting(this: *PosixBufferedReader) void {
        if (this.getFd() != bun.invalid_fd) {
            bun.assert(!this.flags.closed_without_reporting);
            this.flags.closed_without_reporting = true;
            this.handle.closeImpl(null, {}, this.flags.close_handle);
        }
    }

    pub fn getFd(this: *PosixBufferedReader) bun.FD {
        return this.handle.getFd();
    }

    pub fn pause(this: *PosixBufferedReader) void {
        if (this.flags.is_paused) return;
        this.flags.is_paused = true;

        // Unregister the FilePoll if it's registered
        if (this.handle == .poll) {
            if (this.handle.poll.isRegistered()) {
                if (this.handle.poll.unregister(this.loop(), false).asErr()) |err| this.onError(err);
            }
        }
    }

    pub fn unpause(this: *PosixBufferedReader) void {
        if (!this.flags.is_paused) return;
        this.flags.is_paused = false;
        // The next read() call will re-register the poll if needed
    }

    pub fn takeBuffer(this: *PosixBufferedReader) std.array_list.Managed(u8) {
        const out = this._buffer;
        this._buffer = std.array_list.Managed(u8).init(out.allocator);
        return out;
    }

    pub fn buffer(this: *PosixBufferedReader) *std.array_list.Managed(u8) {
        return &this._buffer;
    }

    pub fn finalBuffer(this: *PosixBufferedReader) *std.array_list.Managed(u8) {
        if (this.flags.memfd and this.handle == .fd) {
            defer this.handle.close(null, {});
            _ = bun.sys.File.readToEndWithArrayList(.{ .handle = this.handle.fd }, this.buffer(), .unknown_size).unwrap() catch |err| {
                bun.Output.debugWarn("error reading from memfd\n{}", .{err});
                return this.buffer();
            };
        }

        return this.buffer();
    }

    pub fn disableKeepingProcessAlive(this: *@This(), event_loop_ctx: anytype) void {
        _ = event_loop_ctx; // autofix
        this.updateRef(false);
    }

    pub fn enableKeepingProcessAlive(this: *@This(), event_loop_ctx: anytype) void {
        _ = event_loop_ctx; // autofix
        this.updateRef(true);
    }

    fn finish(this: *PosixBufferedReader) void {
        bun.assert(this.handle == .closed);
        bun.assert(!this.flags.is_done);
        this.flags.closed_without_reporting = false;
        this.flags.is_done = true;
        this._buffer.shrinkAndFree(this._buffer.items.len);
    }

    fn endDispatch(this: *PosixBufferedReader) void {
        bun.assert(this.dispatch_depth > 0);
        this.dispatch_depth -= 1;
        if (this.dispatch_depth != 0) return;
        if (bun.take(&this.deferred_deinit)) |deinit_request| {
            deinit_request.callback(deinit_request.context);
            return;
        }
        this.deliverTerminal();
    }

    fn deliverTerminal(this: *PosixBufferedReader) void {
        const terminal = this.terminal;
        if (terminal == .none) return;
        this.terminal = .none;
        this.finish();
        // The terminal callback may destroy the embedded reader; every read frame must have returned.
        switch (terminal) {
            .none => unreachable,
            .done => this.vtable.onReaderDone(),
            .failure => |err| this.vtable.onReaderError(err),
        }
    }

    pub fn done(this: *PosixBufferedReader) void {
        if (this.flags.is_done or this.terminal != .none) return;
        this.closeWithoutReporting();
        this.terminal = .done;
        if (this.dispatch_depth == 0) this.deliverTerminal();
    }

    pub fn deinit(this: *PosixBufferedReader) void {
        bun.assert(this.dispatch_depth == 0);
        bun.assert(this.deferred_deinit == null);
        MaxBuf.removeFromPipereader(&this.maxbuf);
        this.buffer().clearAndFree();
        this.closeWithoutReporting();
    }

    /// Takes responsibility for destruction after all frames borrowing the reader have returned.
    pub fn deinitWhenIdle(this: *PosixBufferedReader, context: anytype, comptime callback: fn (@TypeOf(context)) void) void {
        bun.assert(this.deferred_deinit == null);
        this.closeWithoutReporting();
        this.terminal = .none;
        this.flags.is_done = true;
        if (this.dispatch_depth == 0) {
            callback(context);
            return;
        }
        const Adapter = struct {
            fn call(raw: NativeContext) void {
                callback(raw.get(@TypeOf(context)));
            }
        };
        this.deferred_deinit = .{ .context = .init(context), .callback = Adapter.call };
    }

    pub fn onError(this: *PosixBufferedReader, err: bun.sys.Error) void {
        if (this.flags.is_done or this.terminal != .none) return;
        this.closeWithoutReporting();
        this.terminal = .{ .failure = err };
        if (this.dispatch_depth == 0) this.deliverTerminal();
    }

    pub fn registerPoll(this: *PosixBufferedReader) void {
        if (this.isDone() or this.flags.is_paused) return;
        if (this.tryRegisterPoll().asErr()) |err| this.onError(err);
    }

    fn tryRegisterPoll(this: *PosixBufferedReader) bun.sys.Maybe(void) {
        const poll = this.handle.getPoll() orelse brk: {
            if (this.handle == .fd and this.flags.pollable) {
                const fd = this.handle.fd;
                const created = Async.FilePoll.create(this.eventLoop(), fd, .{}, @This(), this) catch
                    return .{ .err = bun.sys.Error.fromCode(.NOMEM, .read) };
                this.handle = .{ .poll = created };
                break :brk this.handle.poll;
            }

            return .success;
        };
        poll.owner.set(this);

        if (!poll.flags.contains(.was_ever_registered))
            poll.enableKeepingProcessAlive(this.eventLoop());

        return poll.registerWithFd(this.loop(), .readable, .dispatch, poll.fd);
    }

    /// Takes ownership of fd when close_handle is set, including on failure.
    pub fn start(this: *PosixBufferedReader, fd: bun.FD, is_pollable: bool) bun.sys.Maybe(void) {
        bun.assert(this.dispatch_depth == 0 and this.terminal == .none and this.deferred_deinit == null);
        this.flags.is_done = false;
        this.flags.received_eof = false;
        this.flags.closed_without_reporting = false;
        this.flags.is_paused = false;
        this.flags.pollable = is_pollable;
        if (!is_pollable) {
            this.buffer().clearRetainingCapacity();
            this.handle.closeImpl(null, {}, this.flags.close_handle and this.getFd() != fd);
            this.handle = .{ .fd = fd };
            return .success;
        }
        if (this.getFd() != fd) {
            this.handle.closeImpl(null, {}, this.flags.close_handle);
            this.handle = .{ .fd = fd };
        }
        const result = this.tryRegisterPoll();
        if (result.asErr() != null) this.closeWithoutReporting();
        return result;
    }

    pub fn startFileOffset(this: *PosixBufferedReader, fd: bun.FD, poll: bool, offset: usize) bun.sys.Maybe(void) {
        this._offset = offset;
        this.flags.use_pread = true;
        return this.start(fd, poll);
    }

    // Exists for consistently with Windows.
    pub fn hasPendingRead(this: *const PosixBufferedReader) bool {
        return this.handle == .poll and this.handle.poll.isRegistered();
    }

    pub fn watch(this: *PosixBufferedReader) void {
        if (this.flags.pollable) {
            this.registerPoll();
        }
    }

    pub fn hasPendingActivity(this: *const PosixBufferedReader) bool {
        return switch (this.handle) {
            .poll => |poll| poll.isActive(),
            .fd => true,
            else => false,
        };
    }

    pub fn loop(this: *const PosixBufferedReader) *Async.Loop {
        return this.vtable.loop();
    }

    pub fn eventLoop(this: *const PosixBufferedReader) RuntimeLoopHandle {
        return this.vtable.eventLoop();
    }

    pub fn read(this: *PosixBufferedReader) void {
        // Don't initiate new reads if paused
        if (this.flags.is_paused or this.isDone()) {
            return;
        }
        this.dispatch_depth += 1;
        defer this.endDispatch();

        const buf = this.buffer();
        const fd = this.getFd();

        switch (this.getFileType()) {
            .nonblocking_pipe => {
                readPipe(this, buf, fd, 0, false);
                return;
            },
            .file => {
                readFile(this, buf, fd, 0, false);
                return;
            },
            .socket => {
                readSocket(this, buf, fd, 0, false);
                return;
            },
            .pipe => {
                switch (bun.isReadable(fd)) {
                    .ready => {
                        readFromBlockingPipeWithoutBlocking(this, buf, fd, 0, false);
                    },
                    .hup => {
                        readFromBlockingPipeWithoutBlocking(this, buf, fd, 0, true);
                    },
                    .not_ready => {
                        this.registerPoll();
                    },
                }
            },
        }
    }

    pub fn onPoll(parent: *PosixBufferedReader, size_hint: isize, received_hup: bool) void {
        if (parent.flags.is_paused or parent.isDone()) return;
        parent.dispatch_depth += 1;
        defer parent.endDispatch();
        const resizable_buffer = parent.buffer();
        const fd = parent.getFd();
        bun.sys.syslog("onPoll({f}) = {d}", .{ fd, size_hint });

        switch (parent.getFileType()) {
            .nonblocking_pipe => {
                readPipe(parent, resizable_buffer, fd, size_hint, received_hup);
            },
            .file => {
                readFile(parent, resizable_buffer, fd, size_hint, received_hup);
            },
            .socket => {
                readSocket(parent, resizable_buffer, fd, size_hint, received_hup);
            },
            .pipe => {
                readFromBlockingPipeWithoutBlocking(parent, resizable_buffer, fd, size_hint, received_hup);
            },
        }
    }

    inline fn drainChunk(parent: *PosixBufferedReader, chunk: []const u8, hasMore: ReadState) bool {
        if (parent.vtable.isStreamingEnabled()) {
            if (chunk.len > 0) {
                return parent.vtable.onReadChunk(chunk, hasMore);
            }
        }

        return false;
    }

    fn emitProgress(parent: *PosixBufferedReader, chunk: []const u8, state: ReadState) bool {
        const more = parent.vtable.onReadChunk(chunk, state);
        return more and !parent.isDone() and !parent.flags.is_paused;
    }

    fn accountRead(parent: *PosixBufferedReader, bytes: usize) bool {
        parent._offset += bytes;
        if (parent.maxbuf) |limit| limit.onReadBytes(bytes);
        return !parent.isDone() and !parent.flags.is_paused;
    }

    fn wrapReadFn(comptime func: *const fn (bun.FD, []u8) bun.sys.Maybe(usize)) *const fn (bun.FD, []u8, usize) bun.sys.Maybe(usize) {
        return struct {
            pub fn call(fd: bun.FD, buf: []u8, offset: usize) bun.sys.Maybe(usize) {
                _ = offset;
                return func(fd, buf);
            }
        }.call;
    }

    fn readFile(parent: *PosixBufferedReader, resizable_buffer: *std.array_list.Managed(u8), fd: bun.FD, size_hint: isize, received_hup: bool) void {
        const preadFn = struct {
            pub fn call(fd1: bun.FD, buf: []u8, offset: usize) bun.sys.Maybe(usize) {
                return bun.sys.pread(fd1, buf, @intCast(offset));
            }
        }.call;
        if (parent.flags.use_pread) {
            return readWithFn(parent, resizable_buffer, fd, size_hint, received_hup, .file, preadFn);
        } else {
            return readWithFn(parent, resizable_buffer, fd, size_hint, received_hup, .file, wrapReadFn(bun.sys.read));
        }
    }

    fn readSocket(parent: *PosixBufferedReader, resizable_buffer: *std.array_list.Managed(u8), fd: bun.FD, size_hint: isize, received_hup: bool) void {
        return readWithFn(parent, resizable_buffer, fd, size_hint, received_hup, .socket, wrapReadFn(bun.sys.recvNonBlock));
    }

    fn readPipe(parent: *PosixBufferedReader, resizable_buffer: *std.array_list.Managed(u8), fd: bun.FD, size_hint: isize, received_hup: bool) void {
        return readWithFn(parent, resizable_buffer, fd, size_hint, received_hup, .nonblocking_pipe, wrapReadFn(bun.sys.readNonblocking));
    }

    fn readBlockingPipe(parent: *PosixBufferedReader, resizable_buffer: *std.array_list.Managed(u8), fd: bun.FD, _: isize, received_hup_initially: bool) void {
        var received_hup = received_hup_initially;
        while (true) {
            const streaming = parent.vtable.isStreamingEnabled();
            var got_retry = false;

            if (resizable_buffer.capacity == 0) {
                // Use stack buffer for streaming
                const stack_buffer = parent.vtable.eventLoop().pipeReadBuffer();

                switch (bun.sys.readNonblocking(fd, stack_buffer)) {
                    .result => |bytes_read| {
                        if (!parent.accountRead(bytes_read)) return;

                        if (bytes_read == 0) {
                            // EOF - finished and closed pipe
                            parent.closeWithoutReporting();
                            if (!parent.flags.is_done)
                                parent.done();
                            return;
                        }

                        if (streaming) {
                            if (!parent.emitProgress(stack_buffer[0..bytes_read], .progress)) return;
                        } else {
                            resizable_buffer.appendSlice(stack_buffer[0..bytes_read]) catch return parent.onError(bun.sys.Error.fromCode(.NOMEM, .read));
                        }
                    },
                    .err => |err| {
                        if (!err.isRetry()) {
                            parent.onError(err);
                            return;
                        }
                        // EAGAIN - fall through to register for next poll
                        got_retry = true;
                    },
                }
            } else {
                resizable_buffer.ensureUnusedCapacity(16 * 1024) catch return parent.onError(bun.sys.Error.fromCode(.NOMEM, .read));
                var buf: []u8 = resizable_buffer.unusedCapacitySlice();

                switch (bun.sys.readNonblocking(fd, buf)) {
                    .result => |bytes_read| {
                        if (!parent.accountRead(bytes_read)) return;
                        resizable_buffer.items.len += bytes_read;

                        if (bytes_read == 0) {
                            parent.closeWithoutReporting();
                            if (!parent.flags.is_done)
                                parent.done();
                            return;
                        }

                        if (streaming) {
                            if (!parent.emitProgress(buf[0..bytes_read], .progress)) {
                                return;
                            }
                        }
                    },
                    .err => |err| {
                        if (!err.isRetry()) {
                            parent.onError(err);
                            return;
                        }
                        got_retry = true;
                    },
                }
            }

            // Register for next poll cycle unless we got HUP
            if (!received_hup) {
                parent.registerPoll();
                return;
            }

            // We have received HUP. Normally that means all writers are gone
            // and draining the buffer will eventually hit EOF (read() == 0),
            // so we loop locally instead of re-arming the poll (HUP is
            // level-triggered and would fire again immediately).
            //
            // But `received_hup` is a snapshot from when the epoll/kqueue
            // event fired. `onReadChunk` above re-enters JS (resolves the
            // pending read, drains microtasks, fires the 'data' event), and
            // user code there can open a new writer on the same FIFO — after
            // which the pipe is no longer hung up. Looping again would then
            // either spin forever on EAGAIN (if the fd is O_NONBLOCK) or
            // block the event loop in read() (if the fd is blocking and
            // RWF_NOWAIT is unavailable — Linux named FIFOs return
            // EOPNOTSUPP for it, unlike anonymous pipes).
            //
            // An explicit EAGAIN proves the HUP is stale, so re-arm.
            if (got_retry) {
                parent.registerPoll();
                return;
            }
            // Otherwise we just returned from user JS; re-poll the fd to see
            // whether HUP still holds before committing to another blocking
            // read. This is one extra poll() per chunk only on the HUP path
            // (i.e. while draining the final buffered bytes), not per read.
            switch (bun.isReadable(fd)) {
                .hup => {
                    // Still hung up; keep draining towards EOF.
                },
                .ready => {
                    // Data is available but HUP cleared — a writer came back.
                    // Drop the stale HUP so the next iteration takes the
                    // normal registerPoll() exit once the data is drained.
                    received_hup = false;
                },
                .not_ready => {
                    // No data and no HUP: a writer exists. Go back to the
                    // event loop instead of blocking in read().
                    parent.registerPoll();
                    return;
                },
            }
        }
    }

    fn readWithFn(parent: *PosixBufferedReader, resizable_buffer: *std.array_list.Managed(u8), fd: bun.FD, size_hint: isize, _: bool, comptime file_type: FileType, comptime sys_fn: *const fn (bun.FD, []u8, usize) bun.sys.Maybe(usize)) void {
        _ = size_hint; // autofix
        const streaming = parent.vtable.isStreamingEnabled();

        if (streaming) {
            const stack_buffer = parent.vtable.eventLoop().pipeReadBuffer();
            while (resizable_buffer.capacity == 0) {
                const stack_buffer_cutoff = stack_buffer.len / 2;
                var stack_buffer_head = stack_buffer;
                while (stack_buffer_head.len > 16 * 1024) {
                    var buf = stack_buffer_head;

                    switch (sys_fn(
                        fd,
                        buf,
                        parent._offset,
                    )) {
                        .result => |bytes_read| {
                            if (!parent.accountRead(bytes_read)) return;
                            buf = stack_buffer_head[0..bytes_read];
                            stack_buffer_head = stack_buffer_head[bytes_read..];

                            if (bytes_read == 0) {
                                parent.closeWithoutReporting();
                                if (stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len].len > 0)
                                    _ = parent.vtable.onReadChunk(stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len], .eof);
                                if (!parent.flags.is_done)
                                    parent.done();
                                return;
                            }

                            // Keep reading as much as we can
                            if (stack_buffer_head.len < stack_buffer_cutoff) {
                                if (!parent.emitProgress(stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len], .progress)) {
                                    return;
                                }
                                stack_buffer_head = stack_buffer;
                            }
                        },
                        .err => |err| {
                            if (err.isRetry()) {
                                if (stack_buffer_head.len != stack_buffer.len) {
                                    if (!parent.emitProgress(stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len], .drained)) return;
                                }
                                if (comptime file_type == .file) {
                                    parent.onError(err);
                                } else {
                                    parent.registerPoll();
                                }
                                return;
                            }

                            if (stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len].len > 0)
                                _ = parent.vtable.onReadChunk(stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len], .progress);
                            parent.onError(err);
                            return;
                        },
                    }
                }

                if (stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len].len > 0) {
                    if (!parent.emitProgress(stack_buffer[0 .. stack_buffer.len - stack_buffer_head.len], .progress)) {
                        return;
                    }
                }

                if (!parent.vtable.isStreamingEnabled()) break;
            }
        } else if (resizable_buffer.capacity == 0 and parent._offset == 0) {
            // Avoid a 16 KB dynamic memory allocation when the buffer might very well be empty.
            const stack_buffer = parent.vtable.eventLoop().pipeReadBuffer();

            // Unlike the block of code following this one, only handle the non-streaming case.
            bun.debugAssert(!streaming);

            switch (sys_fn(fd, stack_buffer, 0)) {
                .result => |bytes_read| {
                    if (bytes_read > 0) {
                        resizable_buffer.appendSlice(stack_buffer[0..bytes_read]) catch return parent.onError(bun.sys.Error.fromCode(.NOMEM, .read));
                    }
                    if (!parent.accountRead(bytes_read)) return;

                    if (bytes_read == 0) {
                        parent.closeWithoutReporting();
                        _ = drainChunk(parent, resizable_buffer.items, .eof);
                        if (!parent.flags.is_done)
                            parent.done();
                        return;
                    }
                },
                .err => |err| {
                    if (err.isRetry()) {
                        if (comptime file_type == .file) {
                            parent.onError(err);
                        } else {
                            parent.registerPoll();
                        }
                        return;
                    }
                    parent.onError(err);
                    return;
                },
            }

            // Allow falling through
        }

        while (true) {
            resizable_buffer.ensureUnusedCapacity(16 * 1024) catch return parent.onError(bun.sys.Error.fromCode(.NOMEM, .read));
            var buf: []u8 = resizable_buffer.unusedCapacitySlice();

            switch (sys_fn(fd, buf, parent._offset)) {
                .result => |bytes_read| {
                    if (!parent.accountRead(bytes_read)) return;
                    buf = buf[0..bytes_read];
                    resizable_buffer.items.len += bytes_read;

                    if (bytes_read == 0) {
                        parent.closeWithoutReporting();
                        _ = drainChunk(parent, resizable_buffer.items, .eof);
                        if (!parent.flags.is_done)
                            parent.done();
                        return;
                    }

                    if (parent.vtable.isStreamingEnabled()) {
                        if (resizable_buffer.items.len > 128_000) {
                            defer {
                                resizable_buffer.clearRetainingCapacity();
                            }
                            if (!parent.emitProgress(resizable_buffer.items, .progress)) {
                                return;
                            }

                            continue;
                        }
                    }
                },
                .err => |err| {
                    var more = true;
                    if (parent.vtable.isStreamingEnabled()) {
                        if (resizable_buffer.items.len > 0) {
                            more = parent.emitProgress(resizable_buffer.items, if (err.isRetry()) .drained else .progress);
                            resizable_buffer.clearRetainingCapacity();
                        }
                    }

                    if (err.isRetry()) {
                        if (!more) return;
                        if (comptime file_type == .file) {
                            parent.onError(err);
                        } else {
                            parent.registerPoll();
                        }
                        return;
                    }
                    parent.onError(err);
                    return;
                },
            }
        }
    }

    fn readFromBlockingPipeWithoutBlocking(parent: *PosixBufferedReader, resizable_buffer: *std.array_list.Managed(u8), fd: bun.FD, size_hint: isize, received_hup: bool) void {
        if (parent.vtable.isStreamingEnabled()) {
            resizable_buffer.clearRetainingCapacity();
        }

        readBlockingPipe(parent, resizable_buffer, fd, size_hint, received_hup);
    }

    comptime {
        bun.meta.banFieldType(@This(), bool); // put them in flags instead.
    }
};

const WindowsBufferedReaderVTable = struct {
    onReaderDone: *const fn (*anyopaque) void,
    onReaderError: *const fn (*anyopaque, bun.sys.Error) void,
    onReadChunk: ?*const fn (
        *anyopaque,
        chunk: []const u8,
        hasMore: ReadState,
    ) bool = null,
    loop: *const fn (*anyopaque) *Async.Loop,
};

pub const WindowsBufferedReader = struct {
    source: ?Source = null,
    stream_read: ?*Source.StreamRead = null,
    _offset: usize = 0,
    _buffer: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(bun.default_allocator),
    // for compatibility with Linux
    flags: Flags = .{},
    maxbuf: ?*MaxBuf = null,

    dispatch_depth: usize = 0,
    deferred_deinit: ?DeferredReaderDeinit = null,

    parent: *anyopaque = undefined,
    vtable: WindowsBufferedReaderVTable = undefined,

    pub fn memoryCost(this: *const WindowsBufferedReader) usize {
        const source_cost = if (this.source) |source| source.memoryCost() else 0;
        const stream_cost = if (this.stream_read) |stream| stream.memoryCost() else 0;
        return @sizeOf(@This()) + this._buffer.capacity + source_cost + stream_cost;
    }

    const Flags = packed struct(u16) {
        is_done: bool = false,
        pollable: bool = false,
        nonblocking: bool = false,
        received_eof: bool = false,
        closed_without_reporting: bool = false,
        close_handle: bool = true,

        is_paused: bool = true,
        has_inflight_read: bool = false,
        use_pread: bool = false,

        starting: bool = false,
        start_oom: bool = false,
        initial_tty_mode: enum(u2) { unspecified, normal, raw } = .unspecified,
        _: u3 = 0,
    };

    pub fn init(comptime Type: type) WindowsBufferedReader {
        const fns = struct {
            fn onReadChunk(this: *anyopaque, chunk: []const u8, hasMore: ReadState) bool {
                return Type.onReadChunk(@as(*Type, @ptrCast(@alignCast(this))), chunk, hasMore);
            }
            fn onReaderDone(this: *anyopaque) void {
                return Type.onReaderDone(@as(*Type, @ptrCast(@alignCast(this))));
            }
            fn onReaderError(this: *anyopaque, err: bun.sys.Error) void {
                return Type.onReaderError(@as(*Type, @ptrCast(@alignCast(this))), err);
            }
            fn loop(this: *anyopaque) *Async.Loop {
                return Type.loop(@as(*Type, @ptrCast(@alignCast(this))));
            }
        };
        return .{
            .vtable = .{
                .onReadChunk = if (@hasDecl(Type, "onReadChunk")) &fns.onReadChunk else null,
                .onReaderDone = &fns.onReaderDone,
                .onReaderError = &fns.onReaderError,
                .loop = &fns.loop,
            },
        };
    }

    pub inline fn isDone(this: *WindowsBufferedReader) bool {
        return this.flags.is_done or this.flags.received_eof or this.flags.closed_without_reporting;
    }

    pub fn from(to: *WindowsBufferedReader, other: anytype, parent: anytype) void {
        bun.assert(other.source != null and to.source == null);
        bun.assert(to.dispatch_depth == 0 and to.deferred_deinit == null);
        bun.assert(other.deferred_deinit == null);
        to.* = .{
            .vtable = to.vtable,
            .flags = other.flags,
            ._buffer = other.buffer().*,
            ._offset = other._offset,
            .source = other.source,
            .stream_read = other.stream_read,
        };
        other.flags.is_done = true;
        other._offset = 0;
        other.buffer().* = std.array_list.Managed(u8).init(bun.default_allocator);
        other.source = null;
        other.stream_read = null;
        MaxBuf.transferToPipereader(&other.maxbuf, &to.maxbuf);
        to.setParent(parent);
    }

    pub fn getFd(this: *const WindowsBufferedReader) bun.FD {
        const source = this.source orelse return bun.invalid_fd;
        return source.getFd();
    }

    pub fn watch(_: *WindowsBufferedReader) void {
        // No-op on windows.
    }

    pub fn setParent(this: *WindowsBufferedReader, parent: anytype) void {
        this.parent = parent;
        if (!this.flags.is_done) {
            if (this.stream_read) |stream| {
                stream.parent = this;
            } else if (this.source) |source| {
                source.setData(this);
            }
        }
    }

    pub fn updateRef(this: *WindowsBufferedReader, value: bool) void {
        if (this.source) |source| {
            if (value) {
                source.ref();
            } else {
                source.unref();
            }
        }
    }

    pub fn enableKeepingProcessAlive(this: *WindowsBufferedReader, _: anytype) void {
        this.updateRef(true);
    }

    pub fn disableKeepingProcessAlive(this: *WindowsBufferedReader, _: anytype) void {
        this.updateRef(false);
    }

    pub fn takeBuffer(this: *WindowsBufferedReader) std.array_list.Managed(u8) {
        const out = this._buffer;
        this._buffer = std.array_list.Managed(u8).init(out.allocator);
        return out;
    }

    pub fn buffer(this: *WindowsBufferedReader) *std.array_list.Managed(u8) {
        return &this._buffer;
    }

    pub const finalBuffer = buffer;

    pub fn hasPendingActivity(this: *const WindowsBufferedReader) bool {
        const source = this.source orelse return false;
        return source.isActive();
    }

    pub fn hasPendingRead(this: *const WindowsBufferedReader) bool {
        if (this.flags.has_inflight_read) return true;
        const source = this.source orelse return false;
        return switch (source) {
            .file, .sync_file => |file| file.state != .deinitialized,
            else => false,
        };
    }

    fn finish(this: *WindowsBufferedReader) void {
        this.flags.has_inflight_read = false;
        this.flags.is_done = true;
        this._buffer.shrinkAndFree(this._buffer.items.len);
    }

    pub fn done(this: *WindowsBufferedReader) void {
        if (this.flags.is_done) return;
        if (this.source) |source| bun.assert(source.isClosed());

        this.finish();

        this.vtable.onReaderDone(this.parent);
    }

    pub fn onError(this: *WindowsBufferedReader, err: bun.sys.Error) void {
        if (this.flags.is_done) return;
        this.closeImpl(false);
        this.finish();
        this.vtable.onReaderError(this.parent, err);
    }

    pub fn startWithCurrentPipe(this: *WindowsBufferedReader) bun.sys.Maybe(void) {
        bun.assert(!this.source.?.isClosed());
        this.buffer().clearRetainingCapacity();
        this.flags.is_done = false;
        return this.startReading();
    }

    pub fn startWithPipe(this: *WindowsBufferedReader, pipe: *uv.Pipe) bun.sys.Maybe(void) {
        this.source = .{ .pipe = pipe };
        return this.startWithCurrentPipe();
    }

    pub fn start(this: *WindowsBufferedReader, fd: bun.FD, _: bool) bun.sys.Maybe(void) {
        bun.assert(this.source == null);
        const loop = this.vtable.loop(this.parent);
        const owned_fd = if (this.flags.close_handle) fd else switch (bun.sys.dupForLibUV(fd)) {
            .result => |copy| copy,
            .err => |err| return .{ .err = err },
        };
        const source = switch (Source.open(loop, owned_fd)) {
            .err => |err| {
                if (!this.flags.close_handle) _ = owned_fd.closeAllowingStandardIo(null);
                return .{ .err = err };
            },
            .result => |source| source,
        };
        this.source = source;
        return this.startWithCurrentPipe();
    }

    pub fn startFileOffset(this: *WindowsBufferedReader, fd: bun.FD, poll: bool, offset: usize) bun.sys.Maybe(void) {
        this._offset = offset;
        this.flags.use_pread = true;
        return this.start(fd, poll);
    }

    pub fn deinit(this: *WindowsBufferedReader) void {
        bun.assert(this.dispatch_depth == 0 and this.deferred_deinit == null);
        MaxBuf.removeFromPipereader(&this.maxbuf);
        this.closeImpl(false);
        this.buffer().deinit();
    }

    pub fn deinitWhenIdle(this: *WindowsBufferedReader, context: anytype, comptime callback: fn (@TypeOf(context)) void) void {
        bun.assert(this.deferred_deinit == null);
        this.closeImpl(false);
        this.flags.is_done = true;
        if (this.dispatch_depth == 0) {
            callback(context);
            return;
        }
        const Adapter = struct {
            fn call(raw: NativeContext) void {
                callback(raw.get(@TypeOf(context)));
            }
        };
        this.deferred_deinit = .{ .context = .init(context), .callback = Adapter.call };
    }

    fn endDispatch(this: *WindowsBufferedReader) void {
        bun.assert(this.dispatch_depth > 0);
        this.dispatch_depth -= 1;
        if (this.dispatch_depth != 0) return;
        if (bun.take(&this.deferred_deinit)) |request| request.callback(request.context);
    }

    pub fn setRawMode(this: *WindowsBufferedReader, value: bool) bun.sys.Maybe(void) {
        this.dispatch_depth += 1;
        defer this.endDispatch();
        const stream = this.stream_read;
        if (stream) |owner| owner.ref();
        defer if (stream) |owner| owner.deref();
        const source = this.source orelse return .{
            .err = .{
                .errno = @backingInt(bun.sys.E.BADF),
                .syscall = .uv_tty_set_mode,
            },
        };
        this.flags.starting = true;
        const result = source.setRawMode(value);
        if (this.finishStarting()) |err| return .{ .err = err };
        if (!this.flags.is_done and this.source != null and source == .tty)
            this.flags.is_paused = !source.tty.isActive();
        return result;
    }

    fn finishStarting(this: *WindowsBufferedReader) ?bun.sys.Error {
        this.flags.starting = false;
        if (!this.flags.start_oom) return null;
        this.flags.start_oom = false;
        _ = this.stopReading();
        return bun.sys.Error.fromCode(.NOMEM, .read);
    }

    fn onStreamAlloc(handle: *uv.Handle, suggested_size: usize, buf: *uv.uv_buf_t) callconv(.c) void {
        const stream = handle.getData(Source.StreamRead).?;
        const bytes = stream.allocate(suggested_size) catch {
            buf.* = .init("");
            return;
        };
        buf.* = .init(bytes);
    }

    fn onStreamRead(handle: *uv.uv_handle_t, nread: uv.ReturnCodeI64, buf: *const uv.uv_buf_t) callconv(.c) void {
        const stream = handle.getData(Source.StreamRead).?;
        stream.ref();
        defer stream.deref();
        const bytes = stream.takeBuffer(buf);
        defer stream.recycle(bytes);
        if (handle.isClosing()) return;
        const this: *WindowsBufferedReader = @ptrCast(@alignCast(stream.parent orelse return));
        const source = this.source orelse return;
        switch (nread.int()) {
            0 => return,
            uv.UV_EOF => {
                _ = this.stopReading();
                onRead(source, "", .eof);
                if (attachedReader(source)) |reader| reader.close();
            },
            else => {
                if (nread.int() == uv.UV_ENOBUFS and buf.len == 0) {
                    // libuv can report allocation failure inline during uv_read_start.
                    if (this.flags.starting) {
                        this.flags.start_oom = true;
                        return;
                    }
                    return this.onError(bun.sys.Error.fromCode(.NOMEM, .read));
                }
                if (nread.toError(.read)) |err| return this.onError(err);
                const len: usize = @intCast(nread.int());
                onRead(source, bytes[0..len], .progress);
            },
        }
    }

    fn onFileRead(fs: *uv.fs_t) callconv(.c) void {
        const file = Source.File.fromFS(fs);
        const result = fs.result;
        const source = Source{ .file = file };
        file.beginDelivery();
        if (attachedReader(source)) |this| {
            this.flags.has_inflight_read = false;
            if (!this.flags.is_done) switch (result.int()) {
                uv.UV_ECANCELED => {},
                0, uv.UV_EOF => {
                    this.flags.is_paused = true;
                    onRead(source, "", .eof);
                },
                else => {
                    if (result.toError(.read)) |err| {
                        this.onError(err);
                    } else {
                        const len: usize = @intCast(result.int());
                        this._offset += len;
                        onRead(source, file.iov.slice()[0..len], .progress);
                    }
                },
            };
        }

        // Callbacks may detach the source or move it into another reader.
        const ptr = file.endDelivery() orelse return;
        const this = bun.cast(*WindowsBufferedReader, ptr);
        if (this.flags.received_eof) return this.close();
        if (!this.flags.is_done and !this.flags.is_paused) {
            if (this.submitFileRead(file).asErr()) |err| this.onError(err);
        }
    }

    fn submitFileRead(this: *WindowsBufferedReader, file: *Source.File) bun.sys.Maybe(void) {
        file.fs.data = this;
        if (!file.canStart()) return .success;
        const offset: i64 = if (this.flags.use_pread)
            std.math.cast(i64, this._offset) orelse {
                this.flags.is_paused = true;
                return .{ .err = bun.sys.Error.fromCode(.FBIG, .read) };
            }
        else
            -1;
        this.flags.has_inflight_read = true;
        if (file.read(offset, onFileRead).asErr()) |err| {
            this.flags.has_inflight_read = false;
            this.flags.is_paused = true;
            return .{ .err = err };
        }
        return .success;
    }

    fn attachedReader(source: Source) ?*WindowsBufferedReader {
        return switch (source) {
            .file, .sync_file => @ptrCast(@alignCast(source.getData())),
            .pipe, .tty => {
                const handle = source.getHandle();
                if (handle.isClosing()) return null;
                const stream = handle.getData(Source.StreamRead).?;
                return @ptrCast(@alignCast(stream.parent));
            },
        };
    }

    fn onRead(source: Source, chunk: []const u8, state: ReadState) void {
        var this = attachedReader(source) orelse return;
        const original_reader = this;
        original_reader.dispatch_depth += 1;
        defer original_reader.endDispatch();
        this.flags.has_inflight_read = false;
        if (state == .eof) this.flags.received_eof = true;
        if (this.maxbuf) |m| {
            m.onReadBytes(chunk.len);
            this = attachedReader(source) orelse return;
        }
        const callback = this.vtable.onReadChunk orelse {
            this._buffer.appendSlice(chunk) catch return this.onError(bun.sys.Error.fromCode(.NOMEM, .read));
            return;
        };

        // A transferred capture buffer precedes the new bytes and belongs to this delivery frame.
        var pending = this.takeBuffer();
        defer pending.deinit();
        const bytes = if (pending.items.len != 0) bytes: {
            pending.appendSlice(chunk) catch return this.onError(bun.sys.Error.fromCode(.NOMEM, .read));
            break :bytes pending.items;
        } else chunk;
        if (!callback(this.parent, bytes, state)) {
            if (attachedReader(source)) |reader| reader.pause();
        }
    }

    pub fn startReading(this: *WindowsBufferedReader) bun.sys.Maybe(void) {
        this.dispatch_depth += 1;
        defer this.endDispatch();
        if (this.flags.is_done or !this.flags.is_paused) return .success;
        const source: Source = this.source orelse return .{ .err = bun.sys.Error.fromCode(bun.sys.E.BADF, .read) };
        bun.assert(!source.isClosed());
        if (source == .pipe or source == .tty) {
            if (this.stream_read == null) {
                this.stream_read = Source.StreamRead.create(source, this) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .read) };
            }
            this.stream_read.?.parent = this;
        }
        const stream = this.stream_read;
        if (stream) |owner| owner.ref();
        defer if (stream) |owner| owner.deref();
        if (source == .tty and this.flags.initial_tty_mode != .unspecified) {
            if (source.setRawMode(this.flags.initial_tty_mode == .raw).asErr()) |err| return .{ .err = err };
            this.flags.initial_tty_mode = .unspecified;
        }
        if (this.flags.is_done or this.source == null) return .success;
        this.flags.is_paused = false;

        switch (source) {
            .file, .sync_file => |file| return this.submitFileRead(file),
            else => {
                this.flags.starting = true;
                const result = uv.uv_read_start(source.toStream(), &onStreamAlloc, &onStreamRead);
                if (this.finishStarting()) |err| return .{ .err = err };
                if (result.toError(.open)) |err| {
                    this.flags.is_paused = true;
                    return .{ .err = err };
                }
            },
        }

        return .success;
    }

    pub fn stopReading(this: *WindowsBufferedReader) bun.sys.Maybe(void) {
        if (this.flags.is_done or this.flags.is_paused) return .success;
        this.flags.is_paused = true;
        const source = this.source orelse return .success;
        switch (source) {
            .file, .sync_file => |file| {
                file.stop();
            },
            else => {
                source.toStream().readStop();
            },
        }
        return .success;
    }

    pub fn closeImpl(this: *WindowsBufferedReader, comptime callDone: bool) void {
        if (this.source) |source| {
            this.source = null;
            this.flags.is_paused = true;
            switch (source) {
                .sync_file, .file => |file| {
                    file.detach();
                },
                .pipe => |pipe| {
                    if (bun.take(&this.stream_read)) |stream| {
                        stream.detach();
                    } else {
                        pipe.data = pipe;
                        pipe.close(onPipeClose);
                    }
                },
                .tty => |tty| {
                    if (bun.take(&this.stream_read)) |stream| {
                        stream.detach();
                    } else {
                        tty.data = tty;
                        tty.close(onTTYClose);
                    }
                },
            }
            if (comptime callDone) this.done();
        }
    }

    pub fn close(this: *WindowsBufferedReader) void {
        _ = this.stopReading();
        this.closeImpl(true);
    }

    fn onPipeClose(handle: *uv.Pipe) callconv(.c) void {
        const this = bun.cast(*uv.Pipe, handle.data);
        bun.destroy(this);
    }

    fn onTTYClose(handle: *uv.uv_tty_t) callconv(.c) void {
        const this = bun.cast(*uv.uv_tty_t, handle.data);
        bun.default_allocator.destroy(this);
    }

    pub fn pause(this: *WindowsBufferedReader) void {
        _ = this.stopReading();
    }

    pub fn unpause(this: *WindowsBufferedReader) void {
        this.dispatch_depth += 1;
        defer this.endDispatch();
        if (this.startReading().asErr()) |err| this.onError(err);
    }

    pub fn read(this: *WindowsBufferedReader) void {
        // we cannot sync read pipes on Windows so we just check if we are paused to resume the reading
        this.unpause();
    }

    comptime {
        bun.meta.banFieldType(WindowsBufferedReader, bool); // Don't increase the size of the struct. Put them in flags instead.
    }
};

pub const BufferedReader = if (bun.Environment.isPosix)
    PosixBufferedReader
else if (bun.Environment.isWindows)
    WindowsBufferedReader
else
    @compileError("Unsupported platform");

const MaxBuf = @import("./MaxBuf.zig");
const std = @import("std");
const Source = @import("./source.zig").Source;

const FileType = @import("./pipes.zig").FileType;
const PollOrFd = @import("./pipes.zig").PollOrFd;
const ReadState = @import("./pipes.zig").ReadState;

const bun = @import("bun");
const Async = bun.Async;
const RuntimeLoopHandle = @import("../event_loop/RuntimeLoopHandle.zig");
const uv = bun.windows.libuv;
