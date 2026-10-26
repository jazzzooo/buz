pub const S3Scheduler = struct {
    vm: *jsc.VirtualMachine,
    concurrent_task: jsc.ConcurrentTask = .{},

    pub fn initCurrent() S3Scheduler {
        return .{ .vm = jsc.VirtualMachine.get() };
    }

    pub fn io(this: *const S3Scheduler) std.Io {
        return this.vm.io;
    }

    pub fn ref(this: *S3Scheduler, keep_alive: *bun.Async.KeepAlive) void {
        keep_alive.ref(this.vm);
    }

    pub fn unref(this: *S3Scheduler, keep_alive: *bun.Async.KeepAlive) void {
        keep_alive.unref(this.vm);
    }

    pub fn enqueue(this: *S3Scheduler, task: anytype) void {
        this.vm.eventLoop().enqueueTaskConcurrent(this.concurrent_task.from(task, .manual_deinit));
    }

    pub fn javascriptSemantics(this: *const S3Scheduler) @FieldType(bun.http.AsyncHTTP.Options, "javascript_semantics") {
        return this.vm.transpiler.engine_capabilities.javascript_semantics;
    }

    pub fn verboseFetch(this: *S3Scheduler) @FieldType(bun.http.AsyncHTTP.Options, "verbose") {
        return this.vm.getVerboseFetch();
    }

    pub fn rejectUnauthorized(this: *const S3Scheduler) bool {
        return this.vm.getTLSRejectUnauthorized();
    }

    pub fn startHTTPThread(this: *const S3Scheduler) void {
        bun.http.HTTPThread.init(this.vm.io, &.{});
    }
};

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
