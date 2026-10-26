pub fn New(
    comptime ProcessType: type,
    comptime EventScheduler: type,
    comptime SourceType: type,
    comptime StdioResultType: type,
) type {
    return struct {
        const StaticPipeWriter = @This();
        const RefCount = bun.ptr.RefCount(StaticPipeWriter, "ref_count", deinit, .{});

        pub const Scheduler = EventScheduler;

        ref_count: RefCount,
        writer: IOWriter = .{},
        stdio_result: StdioResultType,
        source: SourceType = .detached,
        process: ?*ProcessType = null,
        scheduler: EventScheduler,
        close_task: EventScheduler.Task = .{},
        buffer: []const u8 = "",
        leased_snapshot: ?[]u8 = null,
        started_ref_held: bool = false,
        starting: bool = false,
        close_pending: bool = false,
        completion_scheduled: bool = false,

        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        pub const IOWriter = bun.io.BufferedWriter(StaticPipeWriter, struct {
            pub const onWritable = null;
            pub const getBuffer = StaticPipeWriter.getBuffer;
            pub const onClose = StaticPipeWriter.onClose;
            pub const onError = StaticPipeWriter.onError;
            pub const onWrite = StaticPipeWriter.onWrite;
        });
        pub const Poll = IOWriter;

        pub fn updateRef(this: *StaticPipeWriter, add: bool) void {
            this.writer.updateRef(this.scheduler, add);
        }

        pub fn getBuffer(this: *StaticPipeWriter) []const u8 {
            return this.buffer;
        }

        pub fn close(this: *StaticPipeWriter) void {
            log("StaticPipeWriter(0x{x}) close()", .{@intFromPtr(this)});
            this.writer.close();
        }

        pub fn detach(this: *StaticPipeWriter) void {
            this.process = null;
        }

        pub fn flush(this: *StaticPipeWriter) void {
            if (this.buffer.len > 0) this.writer.write();
        }

        pub fn create(
            scheduler: EventScheduler,
            process: *ProcessType,
            result: *StdioResultType,
            source: SourceType,
        ) bun.OOM!*StaticPipeWriter {
            const this = bun.default_allocator.create(StaticPipeWriter) catch |err| {
                var owned_source = source;
                owned_source.detach();
                return err;
            };
            this.* = .{
                .ref_count = .init(),
                .scheduler = scheduler,
                .process = process,
                .stdio_result = result.take(),
                .source = source,
            };
            this.writer.setParent(this);
            return this;
        }

        pub fn start(this: *StaticPipeWriter) bun.sys.Maybe(void) {
            log("StaticPipeWriter(0x{x}) start()", .{@intFromPtr(this)});
            bun.assert(!this.started_ref_held);
            this.buffer = if (comptime @hasField(SourceType, "leased_bytes")) switch (this.source) {
                .leased_bytes => |*bytes| snapshot: {
                    const bytes_snapshot = bun.default_allocator.alloc(u8, bytes.length()) catch
                        return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
                    bun.assert(bytes.read(0, bytes_snapshot));
                    this.leased_snapshot = bytes_snapshot;
                    break :snapshot bytes_snapshot;
                },
                else => this.source.slice(),
            } else this.source.slice();
            this.ref();
            this.started_ref_held = true;
            this.starting = true;
            if (Environment.isWindows) this.writer.setPipe(this.stdio_result.take().buffer);
            const result = if (Environment.isWindows)
                this.writer.startWithCurrentPipe()
            else
                this.writer.start(this.stdio_result.owned_fd, .{});
            const start_error = result.asErr();
            if (start_error != null) {
                if (Environment.isPosix) this.stdio_result.deinit();
                this.writer.close();
                if (!this.close_pending) {
                    this.releaseInput();
                    this.close_pending = true;
                }
            } else if (Environment.isPosix) {
                _ = this.stdio_result.take();
            }
            this.starting = false;
            if (this.close_pending) this.completeCloseSynchronously();
            if (start_error) |err| return .{ .err = err };
            return .success;
        }

        pub fn onWrite(this: *StaticPipeWriter, amount: usize, status: bun.io.WriteStatus) void {
            log("StaticPipeWriter(0x{x}) onWrite(amount={d} {})", .{ @intFromPtr(this), amount, status });
            this.buffer = this.buffer[@min(amount, this.buffer.len)..];
            if (status == .end_of_file or this.buffer.len == 0) this.writer.close();
        }

        pub fn onError(this: *StaticPipeWriter, err: bun.sys.Error) void {
            log("StaticPipeWriter(0x{x}) onError(err={f})", .{ @intFromPtr(this), err });
            this.releaseInput();
        }

        pub fn onClose(this: *StaticPipeWriter) void {
            log("StaticPipeWriter(0x{x}) onClose()", .{@intFromPtr(this)});
            if (this.close_pending) return;
            this.releaseInput();
            this.close_pending = true;
            if (!this.starting) this.scheduleCloseCompletion();
        }

        fn releaseInput(this: *StaticPipeWriter) void {
            this.buffer = "";
            this.source.detach();
        }

        fn scheduleCloseCompletion(this: *StaticPipeWriter) void {
            if (!this.started_ref_held or this.completion_scheduled) return;
            this.completion_scheduled = true;
            this.scheduler.enqueue(&this.close_task, this);
        }

        pub fn runFromMainThread(this: *StaticPipeWriter) void {
            this.completeClose();
        }

        fn completeCloseSynchronously(this: *StaticPipeWriter) void {
            this.ref();
            this.completeClose();
            this.deref();
        }

        fn completeClose(this: *StaticPipeWriter) void {
            bun.assert(this.close_pending);
            bun.assert(this.started_ref_held);
            this.close_pending = false;
            this.completion_scheduled = false;
            this.started_ref_held = false;
            defer this.deref();
            if (bun.take(&this.process)) |process| process.onCloseIO(.stdin);
        }

        fn deinit(this: *StaticPipeWriter) void {
            bun.assert(!this.started_ref_held);
            bun.assert(!this.starting);
            bun.assert(!this.close_pending);
            bun.assert(!this.completion_scheduled);
            this.process = null;
            this.stdio_result.deinit();
            this.writer.close();
            this.releaseInput();
            if (this.leased_snapshot) |snapshot| bun.default_allocator.free(snapshot);
            bun.destroy(this);
        }

        pub fn memoryCost(this: *const StaticPipeWriter) usize {
            return @sizeOf(StaticPipeWriter) + this.source.memoryCost() + this.writer.memoryCost() +
                if (this.leased_snapshot) |snapshot| snapshot.len else 0;
        }

        pub fn loop(this: *StaticPipeWriter) *bun.Async.Loop {
            return this.scheduler.runtimeLoopHandle().platformLoop();
        }

        pub fn watch(this: *StaticPipeWriter) void {
            if (this.buffer.len > 0) this.writer.watch();
        }

        pub fn eventLoop(this: *StaticPipeWriter) EventScheduler {
            return this.scheduler;
        }
    };
}

const bun = @import("bun");
const Environment = bun.Environment;
const log = bun.Output.scoped(.StaticPipeWriter, .hidden);
