pub fn init(event_loop: jsc.EventLoopHandle) Scheduler {
    return switch (event_loop) {
        .js => |loop| .{
            .runtime_loop = event_loop.runtimeLoopHandle(),
            .environment = loop.virtual_machine.transpiler.env,
            .top_level_dir = loop.virtual_machine.transpiler.fs.top_level_dir,
            .allocator = loop.virtual_machine.allocator,
            .context = .init(loop),
            .vtable = &js_vtable,
        },
        .mini => |loop| Scheduler.initMini(loop),
    };
}

pub fn eventLoop(scheduler: Scheduler) jsc.EventLoopHandle {
    return if (scheduler.isJavaScript())
        .{ .js = scheduler.integrationContext().get(*jsc.EventLoop) }
    else
        .{ .mini = scheduler.integrationContext().get(*bun.MiniEventLoop) };
}

const js_vtable: Scheduler.VTable = .{
    .enqueue = struct {
        fn call(raw_loop: Scheduler.Context, task: *Scheduler.Task) void {
            const loop = raw_loop.get(*jsc.EventLoop);
            loop.enqueueNativeTaskConcurrent(task.taskForQueue());
        }
    }.call,
    .tick = struct {
        fn call(raw_loop: Scheduler.Context) void {
            raw_loop.get(*jsc.EventLoop).tick();
        }
    }.call,
    .report_shell_error = struct {
        fn call(raw_loop: Scheduler.Context, err: *const bun.shell.ShellErr) void {
            const loop = raw_loop.get(*jsc.EventLoop);
            throwShellError(err, loop.global) catch {};
        }
    }.call,
    .report_out_of_memory = struct {
        fn call(raw_loop: Scheduler.Context) void {
            const loop = raw_loop.get(*jsc.EventLoop);
            loop.global.reportOutOfMemory();
        }
    }.call,
    .throw_message = struct {
        fn call(raw_loop: Scheduler.Context, message: []const u8) void {
            const loop = raw_loop.get(*jsc.EventLoop);
            loop.global.throw("{s}", .{message}) catch {};
        }
    }.call,
    .throw_invalid_arguments = struct {
        fn call(raw_loop: Scheduler.Context, message: []const u8) void {
            const loop = raw_loop.get(*jsc.EventLoop);
            loop.global.throwInvalidArguments("{s}", .{message}) catch {};
        }
    }.call,
    .with_shell_value_blob = struct {
        fn call(
            raw_loop: Scheduler.Context,
            value: *const ShellValue.Value,
            unavailable_message: []const u8,
            consumer_context: *anyopaque,
            consumer: Scheduler.BlobConsumer,
        ) ?bun.shell.Yield {
            const loop = raw_loop.get(*jsc.EventLoop);
            switch (value.*) {
                .response => |*response| {
                    const body = response.get(jsc.WebCore.Response).getBodyValue();
                    body.toBlobIfPossible() catch {
                        loop.global.reportOutOfMemory();
                        return .failed;
                    };
                    const available = body.tryUseAsAnyBlob() catch {
                        loop.global.reportOutOfMemory();
                        return .failed;
                    };
                    if (available) |source_value| {
                        var source = source_value;
                        defer source.detach();
                        return consumer(consumer_context, &source);
                    }
                },
                .stream => |*stream| {
                    var retained = jsc.WebCore.ReadableStream.Strong.initOwned(stream.clone()) catch |err| {
                        bun.bindgen.voidFromJSError(err, loop.global);
                        return .failed;
                    };
                    defer retained.deinit();
                    const available = retained.toAnyBlob(loop.global) catch {
                        loop.global.reportOutOfMemory();
                        return .failed;
                    };
                    if (available) |source_value| {
                        var source = source_value;
                        defer source.detach();
                        return consumer(consumer_context, &source);
                    }
                },
                else => unreachable,
            }
            loop.global.throw("{s}", .{unavailable_message}) catch {};
            return .failed;
        }
    }.call,
    .positional_arg = struct {
        fn call(raw_loop: Scheduler.Context, original_index: u8) []const u8 {
            var index = original_index;
            if (index == 0) return bun.selfExePath() catch "";
            index -= 1;

            const loop = raw_loop.get(*jsc.EventLoop);
            const vm = loop.virtual_machine;
            if (vm.main.len > 0) {
                if (index == 0) return vm.main;
                index -= 1;
            }

            if (vm.worker) |worker| {
                if (index >= worker.argv.len) return "";
                return worker.argv[index];
            }
            if (index >= vm.argv.len) return "";
            return vm.argv[index];
        }
    }.call,
    .is_javascript = true,
};

fn throwShellError(err: *const bun.shell.ShellErr, global_this: *jsc.JSGlobalObject) bun.JSError {
    defer switch (err.*) {
        .sys => {},
        .custom, .invalid_arguments, .todo => err.deinit(bun.default_allocator),
    };
    switch (err.*) {
        .sys => {
            return bun.api.SystemErrorBindings.throwSystemError(err.sys, global_this);
        },
        .custom => return global_this.throw("{s}", .{err.custom}),
        .invalid_arguments => return global_this.throwInvalidArguments("{s}", .{err.invalid_arguments.val}),
        .todo => return global_this.throwTODO(err.todo),
    }
}

const bun = @import("bun");
const jsc = bun.jsc;
const Scheduler = @import("./Scheduler.zig");
const ShellValue = @import("./ShellValue.zig");
