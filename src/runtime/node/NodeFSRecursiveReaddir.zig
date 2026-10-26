pub fn Work(
    comptime FS: type,
    comptime Owner: type,
    comptime field_name: []const u8,
) type {
    return struct {
        args: FS.Arguments.Readdir,
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &workPoolCallback, .on_cancel = &cancelWork },
        has_result: std.atomic.Value(bool) = .init(false),
        subtask_count: std.atomic.Value(usize) = .init(1),
        result_list: ResultListEntry.Value,
        result_list_count: std.atomic.Value(usize) = .init(0),
        result_list_queue: ResultListEntry.Queue = .{},
        root_fd: bun.FD = bun.invalid_fd,
        root_path: bun.PathString,
        pending_err: ?bun.bindgen.SystemError = null,
        out_of_memory: std.atomic.Value(bool) = .init(false),
        pending_err_mutex: std.Io.Mutex = .init,
        background_tasks: *bun.BackgroundTaskGroup,
        io: std.Io,

        const Self = @This();

        pub const ResultListEntry = struct {
            pub const Value = union(FS.Return.Readdir.Tag) {
                with_file_types: std.array_list.Managed(FS.NodeTypes.Dirent),
                buffers: std.array_list.Managed(FS.NodeBuffer),
                files: std.array_list.Managed(bun.String),

                pub fn deinit(value: *@This()) void {
                    switch (value.*) {
                        .with_file_types => |*items| {
                            for (items.items) |item| item.deref();
                            items.clearAndFree();
                        },
                        .buffers => |*items| {
                            for (items.items) |*item| item.deinit();
                            items.clearAndFree();
                        },
                        .files => |*items| {
                            for (items.items) |item| item.deref();
                            items.clearAndFree();
                        },
                    }
                }
            };

            next: ?*ResultListEntry = null,
            value: Value,

            pub const Queue = bun.UnboundedQueue(ResultListEntry, .next);
        };

        const Subtask = struct {
            parent: *Self,
            basename: bun.PathString,
            task: bun.BackgroundTaskGroup.Task = .{ .callback = run, .on_cancel = cancel },

            const Task = @This();

            fn create(parent: *Self, basename: [:0]const u8) bun.OOM!*Task {
                const task = try bun.default_allocator.create(Task);
                errdefer bun.destroy(task);
                task.* = .{
                    .parent = parent,
                    .basename = .init(try bun.default_allocator.dupeSentinel(u8, basename, 0)),
                };
                return task;
            }

            fn run(task: *bun.BackgroundTaskGroup.Task) void {
                const subtask: *Task = @alignCast(@fieldParentPtr("task", task));
                const parent = subtask.parent;
                defer {
                    bun.default_allocator.free(subtask.basename.sliceAssumeZ());
                    bun.destroy(subtask);
                }
                var buf: bun.PathBuffer = undefined;
                parent.performWork(subtask.basename.sliceAssumeZ(), &buf, false);
            }

            fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
                const subtask: *Task = @alignCast(@fieldParentPtr("task", task));
                const parent = subtask.parent;
                parent.recordError(bun.sys.Error.fromCode(.AGAIN, .scandir));
                bun.default_allocator.free(subtask.basename.sliceAssumeZ());
                bun.destroy(subtask);
                if (parent.subtask_count.fetchSub(1, .acq_rel) == 1) parent.finishConcurrently();
            }
        };

        pub fn init(args: FS.Arguments.Readdir, runtime: @import("./NodeFSAsync.zig").Runtime) bun.OOM!Self {
            errdefer args.deinit();
            const io = runtime.io orelse @panic("recursive readdir requires the io capability");
            return .{
                .args = args,
                .background_tasks = runtime.background_tasks,
                .io = io,
                .root_path = .init(try bun.default_allocator.dupeSentinel(u8, args.path.slice(), 0)),
                .result_list = switch (args.tag()) {
                    .files => .{ .files = .init(bun.default_allocator) },
                    .with_file_types => .{ .with_file_types = .init(bun.default_allocator) },
                    .buffers => .{ .buffers = .init(bun.default_allocator) },
                },
            };
        }

        pub fn schedule(work: *Self) bun.OOM!void {
            try work.args.toThreadSafe();
            bun.BackgroundWork.schedule(work.background_tasks, &work.task) catch {
                work.recordError(bun.sys.Error.fromCode(.AGAIN, .scandir));
                bun.assert(work.subtask_count.fetchSub(1, .acq_rel) == 1);
                work.finishConcurrently();
            };
        }

        pub fn deinit(work: *Self) void {
            bun.assert(work.root_fd == bun.invalid_fd);
            if (work.pending_err) |*err| err.deinit();
            work.args.deinit();
            bun.default_allocator.free(work.root_path.slice());
            work.clearResultList();
        }

        pub fn takeResult(work: *Self) bun.OOM!FS.Return.Readdir {
            return switch (work.result_list) {
                .with_file_types => |*items| .{ .with_file_types = try items.toOwnedSlice() },
                .buffers => |*items| .{ .buffers = try items.toOwnedSlice() },
                .files => |*items| .{ .files = try items.toOwnedSlice() },
            };
        }

        fn owner(work: *Self) *Owner {
            return @alignCast(@fieldParentPtr(field_name, work));
        }

        pub fn enqueue(work: *Self, basename: [:0]const u8) void {
            if (work.out_of_memory.load(.monotonic)) return;
            const subtask = Subtask.create(work, basename) catch {
                work.out_of_memory.store(true, .monotonic);
                return;
            };
            bun.assert(work.subtask_count.fetchAdd(1, .monotonic) > 0);
            bun.BackgroundWork.scheduleContinuation(work.background_tasks, &subtask.task);
        }

        fn recordError(work: *Self, err: bun.sys.Error) void {
            work.pending_err_mutex.lockUncancelable(work.io);
            defer work.pending_err_mutex.unlock(work.io);
            if (work.pending_err != null) return;
            var source = err;
            if (source.path.len == 0) source.path = work.args.path.slice();
            work.pending_err = bun.bindgen.SystemError.fromSysError(source) catch {
                work.out_of_memory.store(true, .monotonic);
                return;
            };
        }

        fn performWork(work: *Self, basename: [:0]const u8, buf: *bun.PathBuffer, comptime is_root: bool) void {
            defer if (work.subtask_count.fetchSub(1, .acq_rel) == 1) work.finishConcurrently();
            if (work.out_of_memory.load(.monotonic)) return;
            switch (work.args.tag()) {
                inline else => |tag| {
                    const ResultType = comptime switch (tag) {
                        .files => bun.String,
                        .with_file_types => FS.NodeTypes.Dirent,
                        .buffers => FS.NodeBuffer,
                    };
                    var stack_buffer: [8192]u8 = undefined;
                    var stack: std.heap.BufferFirstAllocator = .init(&stack_buffer, bun.default_allocator);
                    var entries = std.array_list.Managed(ResultType).init(stack.allocator());
                    defer {
                        for (entries.items) |*item| switch (ResultType) {
                            bun.String, FS.NodeTypes.Dirent => item.deref(),
                            FS.NodeBuffer => item.deinit(),
                            else => comptime unreachable,
                        };
                        entries.deinit();
                    }

                    switch (FS.NodeFS.readdirWithEntriesRecursiveAsync(
                        buf,
                        work.args,
                        work,
                        basename,
                        ResultType,
                        &entries,
                        is_root,
                    ) catch {
                        work.out_of_memory.store(true, .monotonic);
                        return;
                    }) {
                        .err => |err| work.recordError(err),
                        .result => work.writeResults(ResultType, &entries) catch {
                            work.out_of_memory.store(true, .monotonic);
                        },
                    }
                },
            }
        }

        fn workPoolCallback(task: *bun.BackgroundTaskGroup.Task) void {
            const work: *Self = @alignCast(@fieldParentPtr("task", task));
            var buf: bun.PathBuffer = undefined;
            work.performWork(work.root_path.sliceAssumeZ(), &buf, true);
        }

        fn cancelWork(task: *bun.BackgroundTaskGroup.Task) void {
            const work: *Self = @alignCast(@fieldParentPtr("task", task));
            owner(work).cancel();
        }

        fn writeResults(work: *Self, comptime ResultType: type, result: *std.array_list.Managed(ResultType)) bun.OOM!void {
            if (result.items.len > 0) {
                const field = switch (ResultType) {
                    bun.String => .files,
                    FS.NodeTypes.Dirent => .with_file_types,
                    FS.NodeBuffer => .buffers,
                    else => comptime unreachable,
                };
                const list = try bun.default_allocator.create(ResultListEntry);
                errdefer bun.default_allocator.destroy(list);
                var clone = try std.array_list.Managed(ResultType).initCapacity(bun.default_allocator, result.items.len);
                clone.appendSliceAssumeCapacity(result.items);
                result.clearRetainingCapacity();
                _ = work.result_list_count.fetchAdd(clone.items.len, .monotonic);
                list.* = .{ .value = @unionInit(ResultListEntry.Value, @tagName(field), clone) };
                work.result_list_queue.push(list);
            }
        }

        fn finishConcurrently(work: *Self) void {
            if (work.has_result.cmpxchgStrong(false, true, .monotonic, .monotonic) != null) return;
            bun.assert(work.subtask_count.load(.monotonic) == 0);

            if (work.root_fd != bun.invalid_fd) {
                work.root_fd.close();
                work.root_fd = bun.invalid_fd;
                bun.default_allocator.free(work.root_path.slice());
                work.root_path = .empty;
            }

            if (work.pending_err != null or work.out_of_memory.load(.monotonic)) {
                work.clearResultList();
                owner(work).finish();
                return;
            }

            switch (work.args.tag()) {
                inline else => |tag| {
                    const results = &@field(work.result_list, @tagName(tag));
                    results.ensureTotalCapacityPrecise(work.result_list_count.swap(0, .monotonic)) catch {
                        work.out_of_memory.store(true, .monotonic);
                        work.clearResultList();
                        owner(work).finish();
                        return;
                    };
                },
            }

            var list = work.result_list_queue.popBatch();
            var iter = list.iterator();
            var previous: ?*ResultListEntry = null;
            switch (work.args.tag()) {
                inline else => |tag| {
                    const results = &@field(work.result_list, @tagName(tag));
                    while (iter.next()) |entry| {
                        if (previous) |value| bun.default_allocator.destroy(value);
                        previous = entry;
                        const source = &@field(entry.value, @tagName(tag));
                        results.appendSliceAssumeCapacity(source.items);
                        source.clearAndFree();
                    }
                },
            }
            if (previous) |value| bun.default_allocator.destroy(value);
            owner(work).finish();
        }

        fn clearResultList(work: *Self) void {
            work.result_list.deinit();
            var batch = work.result_list_queue.popBatch();
            var iter = batch.iterator();
            var previous: ?*ResultListEntry = null;
            while (iter.next()) |entry| {
                entry.value.deinit();
                if (previous) |value| bun.default_allocator.destroy(value);
                previous = entry;
            }
            if (previous) |value| bun.default_allocator.destroy(value);
            work.result_list_count.store(0, .monotonic);
        }
    };
}

const bun = @import("bun");
const std = @import("std");
