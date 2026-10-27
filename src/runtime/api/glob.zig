const Glob = @This();

pub const getConstructor = GlobClass.constructor;

bindgen_state: bindgen.ClassState = .{},
pattern: bindgen.OwnedBytes,
has_pending_activity: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

const ScanOpts = struct {
    cwd: ?[]const u8,
    dot: bool,
    absolute: bool,
    only_files: bool,
    follow_symlinks: bool,
    error_on_broken_symlinks: bool,

    fn parseCWD(context: anytype, allocator: std.mem.Allocator, cwd_value: bindgen.DOMStringView, absolute: bool, comptime fnName: []const u8) bun.bindgen.CallError(@TypeOf(context))![]const u8 {
        const cwd_utf8 = try cwd_value.toUTF8(allocator);
        defer cwd_utf8.deinit();
        const cwd = cwd_utf8.slice();
        if (cwd.len == 0) return "";
        const cwd_str = if (absolute and !std.fs.path.isAbsolute(cwd)) cwd_str: {
            var path_buf: bun.PathBuffer = undefined;
            const process_cwd = switch (bun.sys.getcwd(&path_buf)) {
                .result => |result| result,
                .err => |err| {
                    return context.fail(.system, try bindgen.SystemError.fromSysError(err));
                },
            };
            break :cwd_str try std.fs.path.resolve(allocator, &.{ process_cwd, cwd });
        } else try std.fs.path.resolve(allocator, &.{cwd});

        if (cwd_str.len > bun.MAX_PATH_BYTES) {
            const message = try std.fmt.allocPrint(bun.default_allocator, "{s}: invalid `cwd`, longer than {d} bytes", .{ fnName, bun.MAX_PATH_BYTES });
            defer bun.default_allocator.free(message);
            return context.fail(.invalid_cwd, try bindgen.ThreadSafeDOMString.fromUTF8(message));
        }

        return cwd_str;
    }

    fn fromGenerated(context: anytype, options: anytype, comptime fnName: []const u8, arena: *Arena) bun.bindgen.CallError(@TypeOf(context))!?ScanOpts {
        const input = options orelse return null;
        var out: ScanOpts = .{
            .cwd = null,
            .dot = false,
            .absolute = false,
            .follow_symlinks = false,
            .error_on_broken_symlinks = false,
            .only_files = true,
        };

        switch (input) {
            .cwd => |cwd| {
                const result = try parseCWD(context, arena.allocator(), cwd, out.absolute, fnName);
                if (result.len > 0) out.cwd = result;
            },
            .options => |generated| {
                out.only_files = generated.only_files;
                out.error_on_broken_symlinks = generated.error_on_broken_symlinks;
                out.follow_symlinks = generated.follow_symlinks;
                out.absolute = generated.absolute;
                out.dot = generated.dot;
                if (generated.cwd) |cwd| {
                    const result = try parseCWD(context, arena.allocator(), cwd, out.absolute, fnName);
                    if (result.len > 0) out.cwd = result;
                }
            },
        }

        return out;
    }
};

const WalkTask = struct {
    walker: *GlobWalker,
    alloc: Allocator,
    has_pending_activity: *std.atomic.Value(usize),
    completion: bindgen.OwnedCompletion(GlobPullSchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(this: *WalkTask, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &this.task) catch {
            defer this.deinit();
            decrPendingActivityFlag(this.has_pending_activity);
            this.completion.fail(.concurrency_unavailable, {});
        };
    }

    fn run(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *WalkTask = @fieldParentPtr("task", work_task);
        defer this.deinit();
        defer decrPendingActivityFlag(this.has_pending_activity);
        const result = this.walker.walk() catch |err| {
            switch (err) {
                error.OutOfMemory => this.completion.outOfMemory(),
            }
            return;
        };
        switch (result) {
            .err => |err| {
                const system_error = bindgen.SystemError.fromSysError(err) catch {
                    this.completion.outOfMemory();
                    return;
                };
                this.completion.fail(.system, system_error);
            },
            .result => {
                const output = globWalkResult(this.walker) catch {
                    this.completion.outOfMemory();
                    return;
                };
                this.completion.resolve(output);
            },
        }
    }

    fn cancel(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *WalkTask = @fieldParentPtr("task", work_task);
        decrPendingActivityFlag(this.has_pending_activity);
        this.completion.release();
        this.deinit();
    }

    fn deinit(this: *WalkTask) void {
        this.walker.deinit(true);
        this.alloc.destroy(this.walker);
        this.alloc.destroy(this);
    }
};

fn globWalkResult(globWalk: *GlobWalker) bun.OOM!bindgen.Return(GlobPullSchema) {
    return bindgen.Return(GlobPullSchema).fromUTF8Slices(globWalk.matchedPaths.keys());
}

/// The reference to the arena is not used after the scope because it is copied
/// by `GlobWalker.init`/`GlobWalker.initWithCwd` if all allocations work and no
/// errors occur
fn makeGlobWalker(
    this: *Glob,
    context: anytype,
    options: anytype,
    comptime fnName: []const u8,
    alloc: Allocator,
    arena: *Arena,
) bun.bindgen.CallError(@TypeOf(context))!?*GlobWalker {
    const matchOpts = try ScanOpts.fromGenerated(context, options, fnName, arena) orelse return null;
    const cwd = matchOpts.cwd;
    const dot = matchOpts.dot;
    const absolute = matchOpts.absolute;
    const follow_symlinks = matchOpts.follow_symlinks;
    const error_on_broken_symlinks = matchOpts.error_on_broken_symlinks;
    const only_files = matchOpts.only_files;

    var globWalker = try alloc.create(GlobWalker);
    errdefer alloc.destroy(globWalker);
    globWalker.* = .{};

    if (cwd != null) {
        switch (try globWalker.initWithCwd(
            arena,
            this.pattern.slice(),
            cwd.?,
            dot,
            absolute,
            follow_symlinks,
            error_on_broken_symlinks,
            only_files,
        )) {
            .err => |err| {
                return context.fail(.system, try bindgen.SystemError.fromSysError(err));
            },
            else => {},
        }
        return globWalker;
    }

    switch (try globWalker.init(
        arena,
        this.pattern.slice(),
        dot,
        absolute,
        follow_symlinks,
        error_on_broken_symlinks,
        only_files,
    )) {
        .err => |err| {
            return context.fail(.system, try bindgen.SystemError.fromSysError(err));
        },
        else => {},
    }
    return globWalker;
}

pub fn construct(
    _: bindgen.CallContext(GlobConstructorSchema),
    args: bindgen.Args(GlobConstructorSchema),
) bun.JSError!*Glob {
    var pattern = bindgen.OwnedBytes.fromDefaultAllocatedSlice(try args.pattern.toOwnedSlice(bun.default_allocator));
    errdefer pattern.deinit();
    return bun.tryNew(Glob, .{ .pattern = pattern });
}

pub fn destroy(this: *Glob) void {
    this.pattern.deinit();
    bun.destroy(this);
}

pub fn hasPendingActivity(this: *const Glob) bool {
    return this.has_pending_activity.load(.seq_cst) > 0;
}

fn incrPendingActivityFlag(has_pending_activity: *std.atomic.Value(usize)) void {
    _ = has_pending_activity.fetchAdd(1, .seq_cst);
}

fn decrPendingActivityFlag(has_pending_activity: *std.atomic.Value(usize)) void {
    _ = has_pending_activity.fetchSub(1, .seq_cst);
}

pub fn __scan(
    this: *Glob,
    context: bindgen.CallContext(GlobPullSchema),
    args: bindgen.Args(GlobPullSchema),
) bindgen.CallError(GlobPullSchema)!void {
    const alloc = bun.default_allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    const globWalker = (this.makeGlobWalker(context, args.options, "scan", alloc, &arena) catch |err| {
        arena.deinit();
        return err;
    }) orelse {
        arena.deinit();
        var completion = context.completion();
        completion.resolve(try bindgen.Return(GlobPullSchema).fromUTF8Slices(&[_][]const u8{}));
        return;
    };

    var completion = context.completion();
    const task = alloc.create(WalkTask) catch {
        completion.outOfMemory();
        globWalker.deinit(true);
        alloc.destroy(globWalker);
        return;
    };
    task.* = .{
        .walker = globWalker,
        .alloc = alloc,
        .has_pending_activity = &this.has_pending_activity,
        .completion = completion.take(),
    };
    incrPendingActivityFlag(&this.has_pending_activity);
    task.schedule(bun.current_runtime.backgroundTasks());
}

pub fn __scanSync(
    this: *Glob,
    context: bindgen.CallContext(GlobResolveSyncSchema),
    args: bindgen.Args(GlobResolveSyncSchema),
) bindgen.CallError(GlobResolveSyncSchema)!bindgen.Return(GlobResolveSyncSchema) {
    const alloc = bun.default_allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    const globWalker = (this.makeGlobWalker(context, args.options, "scanSync", alloc, &arena) catch |err| {
        arena.deinit();
        return err;
    }) orelse {
        arena.deinit();
        return null;
    };
    defer {
        globWalker.deinit(true);
        alloc.destroy(globWalker);
    }

    switch (try globWalker.walk()) {
        .err => |err| {
            return context.fail(.system, try bindgen.SystemError.fromSysError(err));
        },
        .result => {},
    }

    return try globWalkResult(globWalker);
}

pub fn match(
    this: *Glob,
    _: bindgen.CallContext(GlobMatchSchema),
    args: bindgen.Args(GlobMatchSchema),
) bun.JSError!bool {
    const alloc = bun.default_allocator;
    var arena = Arena.init(alloc);
    defer arena.deinit();
    var str = try args.value.toUTF8(arena.allocator());
    defer str.deinit();

    return bun.glob.match(this.pattern.slice(), str.slice()).matches();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

const bun = @import("bun");
const GlobWalker = bun.glob.BunGlobWalker;
const bindgen = bun.bindgen;

const GlobBindingModule = bindgen.Module("Glob");
const GlobSchema = GlobBindingModule.class("Glob");
const GlobConstructorSchema = GlobSchema.constructor();
const GlobPullSchema = GlobSchema.member("__scan");
const GlobResolveSyncSchema = GlobSchema.member("__scanSync");
const GlobMatchSchema = GlobSchema.member("match");
const GlobClass = bindgen.Class(GlobSchema, Glob);

comptime {
    _ = GlobClass;
}
