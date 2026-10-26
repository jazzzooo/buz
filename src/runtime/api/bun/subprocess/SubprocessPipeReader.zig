pub fn WithIntegration(comptime Integration: type) type {
    return struct {
        const PipeReader = @This();
        const RefCount = bun.ptr.RefCount(PipeReader, "ref_count", PipeReader.deinit, .{});

        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        reader: IOReader = undefined,
        process: ?Integration.ProcessHandle = null,
        event_loop: Integration.LoopHandle = undefined,
        ref_count: RefCount,
        state: union(enum) {
            pending: void,
            done: []u8,
            err: bun.sys.Error,
        } = .{ .pending = {} },
        stdio_result: StdioResult,
        started: bool = false,
        pub const IOReader = bun.io.BufferedReader;
        pub const Poll = IOReader;

        pub fn memoryCost(this: *const PipeReader) usize {
            return this.reader.memoryCost();
        }

        pub fn hasPendingActivity(this: *const PipeReader) bool {
            if (this.state == .pending)
                return true;

            return this.reader.hasPendingActivity();
        }

        pub fn detach(this: *PipeReader) void {
            this.process = null;
            this.deref();
        }

        pub fn create(event_loop: Integration.LoopHandle, process: Integration.ProcessHandle, result: *StdioResult, limit: ?*MaxBuf) bun.OOM!*PipeReader {
            const this = try bun.default_allocator.create(PipeReader);
            this.* = .{
                .ref_count = .init(),
                .process = process,
                .reader = IOReader.init(@This()),
                .event_loop = event_loop,
                .stdio_result = result.take(),
            };
            MaxBuf.addToPipereader(limit, &this.reader.maxbuf);
            this.reader.setParent(this);
            return this;
        }

        pub fn readAll(this: *PipeReader) void {
            if (this.state == .pending)
                this.reader.read();
        }

        pub fn start(this: *PipeReader, process: Integration.ProcessHandle, event_loop: Integration.LoopHandle) bun.sys.Maybe(void) {
            bun.assert(!this.started);
            this.started = true;
            this.ref();
            this.process = process;
            this.event_loop = event_loop;
            if (Environment.isWindows) {
                this.reader.source = .{ .pipe = this.stdio_result.take().buffer };
                if (this.reader.startWithCurrentPipe().asErr()) |err| {
                    this.ref();
                    this.reader.onError(err);
                    this.deref();
                    return .{ .err = err };
                }
                return .success;
            }

            switch (this.reader.start(this.stdio_result.takeOwnedFd().?, true)) {
                .err => |err| {
                    this.ref();
                    this.reader.onError(err);
                    this.deref();
                    return .{ .err = err };
                },
                .result => {
                    if (comptime Environment.isPosix) {
                        const poll = this.reader.handle.poll;
                        poll.flags.insert(.socket);
                        this.reader.flags.socket = true;
                        this.reader.flags.nonblocking = true;
                        this.reader.flags.pollable = true;
                        poll.flags.insert(.nonblocking);
                    }

                    return .success;
                },
            }
        }

        pub fn onReaderDone(this: *PipeReader) void {
            const owned = this.toOwnedSlice();
            this.state = .{ .done = owned };
            if (this.process) |process| {
                this.process = null;
                Integration.readerClosed(process, this);
                this.deref();
            }
        }

        pub fn toOwnedSlice(this: *PipeReader) []u8 {
            if (this.state == .done) {
                return this.state.done;
            }
            // we do not use .toOwnedSlice() because we don't want to reallocate memory.
            const out = this.reader._buffer;
            this.reader._buffer.items = &.{};
            this.reader._buffer.capacity = 0;

            if (out.capacity > 0 and out.items.len == 0) {
                out.deinit();
                return &.{};
            }

            return out.items;
        }

        pub fn updateRef(this: *PipeReader, add: bool) void {
            this.reader.updateRef(add);
        }

        pub fn watch(this: *PipeReader) void {
            if (!this.reader.isDone())
                this.reader.watch();
        }

        pub fn toReadableStreamResult(this: *PipeReader, context: anytype) bun.bindgen.CallError(@TypeOf(context))!Integration.StreamResult {
            defer this.detach();

            switch (this.state) {
                .pending => {
                    this.state = .{ .done = &.{} };
                    return Integration.streamFromPipe(context, this, &this.reader);
                },
                .done => |bytes| {
                    this.state = .{ .done = &.{} };
                    return Integration.streamFromOwnedSlice(context, bytes);
                },
                .err => |err| {
                    _ = err;
                    return Integration.emptyStream(context, true);
                },
            }
        }

        pub fn takeBuffer(this: *PipeReader) ?[]u8 {
            return switch (this.state) {
                .done => |bytes| blk: {
                    this.state = .{ .done = &.{} };
                    break :blk bytes;
                },
                .pending, .err => null,
            };
        }

        pub fn onReaderError(this: *PipeReader, err: bun.sys.Error) void {
            if (this.state == .done) {
                bun.default_allocator.free(this.state.done);
            }
            this.state = .{ .err = err };
            if (this.process) |process| {
                this.process = null;
                Integration.readerClosed(process, this);
                this.deref();
            }
        }

        pub fn close(this: *PipeReader) void {
            switch (this.state) {
                .pending => {
                    this.reader.close();
                },
                .done => {},
                .err => {},
            }
        }

        pub fn eventLoop(this: *PipeReader) Integration.ReaderEventLoop {
            return Integration.readerEventLoop(this.event_loop);
        }

        pub fn loop(this: *PipeReader) *bun.Async.Loop {
            return Integration.platformLoop(this.event_loop);
        }

        fn deinit(this: *PipeReader) void {
            if (this.state == .done) {
                bun.default_allocator.free(this.state.done);
            }

            this.stdio_result.deinit();
            this.reader.deinit();
            bun.destroy(this);
        }
    };
}

const bun = @import("bun");
const Environment = bun.Environment;
const MaxBuf = bun.io.MaxBuf;
const StdioResult = bun.spawn.process.SpawnProcessResult.StdioResult;
