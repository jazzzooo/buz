var default_manager: ?*PathWatcherManager = null;

// TODO: make this a generic so we can reuse code with path_watcher
// TODO: we probably should use native instead of libuv abstraction here for better performance
pub const PathWatcherManager = struct {
    const options = @import("../../bundler/options.zig");
    const log = Output.scoped(.PathWatcherManager, .visible);

    watchers: bun.StringArrayHashMap(*PathWatcher) = .empty,
    loop: *bun.Async.Loop,
    deinit_on_last_watcher: bool = false,

    pub const new = bun.TrivialNew(PathWatcherManager);

    pub fn init(runtime: Runtime) *PathWatcherManager {
        return PathWatcherManager.new(.{
            .watchers = .{},
            .loop = runtime.loop,
        });
    }

    // unregister is always called form main thread
    fn unregisterWatcher(this: *PathWatcherManager, watcher: *PathWatcher, path: [:0]const u8) void {
        defer {
            if (this.deinit_on_last_watcher and this.watchers.count() == 0) {
                this.deinit();
            }
        }

        if (std.mem.indexOfScalar(*PathWatcher, this.watchers.values(), watcher)) |index| {
            if (comptime bun.Environment.isDebug) {
                if (path.len > 0)
                    bun.assert(bun.strings.eql(this.watchers.keys()[index], path));
            }

            bun.default_allocator.free(this.watchers.keys()[index]);
            _ = this.watchers.swapRemoveAt(index);
        }
    }

    fn deinit(this: *PathWatcherManager) void {
        // enable to create a new manager
        if (default_manager == this) {
            default_manager = null;
        }

        if (this.watchers.count() != 0) {
            this.deinit_on_last_watcher = true;
            return;
        }

        for (this.watchers.values()) |watcher| {
            watcher.manager = null;
            watcher.deinit();
        }

        for (this.watchers.keys()) |path| {
            bun.default_allocator.free(path);
        }

        this.watchers.deinit(bun.default_allocator);
        bun.destroy(this);
    }
};

pub const PathWatcher = struct {
    handle: uv.uv_fs_event_t,
    manager: ?*PathWatcherManager,
    emit_in_progress: bool = false,
    handlers: std.array_hash_map.Auto(*WatcherCore.CallbackContext, Handler) = .empty,

    pub const new = bun.TrivialNew(PathWatcher);

    const log = Output.scoped(.@"fs.watch", .visible);

    const Handler = struct {
        duplicate_filter: WatcherCore.DuplicateFilter = .{},
        callback: WatcherCore.Callback,
        update_end: WatcherCore.UpdateEndCallback,
    };

    const Callback = WatcherCore.Callback;
    const UpdateEndCallback = WatcherCore.UpdateEndCallback;

    fn uvEventCallback(event: *uv.uv_fs_event_t, filename: ?[*:0]const u8, events: c_int, status: uv.ReturnCode) callconv(.c) void {
        if (event.data == null) {
            Output.debugWarn("uvEventCallback called with null data", .{});
            return;
        }
        const this: *PathWatcher = @alignCast(@fieldParentPtr("handle", event));
        if (comptime bun.Environment.isDebug) {
            bun.assert(event.data == @as(?*anyopaque, @ptrCast(this)));
        }

        const timestamp = event.loop.time;

        if (status.toError(.watch)) |err| {
            this.emit_in_progress = true;
            defer this.emit_in_progress = false;

            for (this.handlers.keys(), this.handlers.values()) |ctx, handler| {
                handler.callback(ctx, .{ .@"error" = err }, false);
                handler.update_end(ctx);
            }
            this.maybeDeinit();

            return;
        }

        const path = if (filename) |file| file[0..bun.len(file) :0] else return;

        this.emit(
            path,
            @truncate(event.hash(path, events, status)),
            timestamp,
            !event.isDir(),
            if (events & uv.UV_RENAME != 0) .rename else .change,
        );
    }

    pub fn emit(this: *PathWatcher, path: string, hash: u32, timestamp: u64, is_file: bool, event_type: EventType) void {
        this.emit_in_progress = true;
        var debug_count: if (bun.Environment.isDebug) usize else u0 = 0;
        for (this.handlers.keys(), this.handlers.values()) |ctx, *handler| {
            if (handler.duplicate_filter.shouldEmit(hash, timestamp, event_type)) {
                handler.callback(ctx, event_type.toEvent(path), is_file);
                if (comptime bun.Environment.isDebug)
                    debug_count += 1;
                handler.update_end(ctx);
            }
        }
        if (comptime bun.Environment.isDebug)
            log("emit({s}, {s}, {s}, at {d}) x {d}", .{
                path,
                if (is_file) "file" else "dir",
                @tagName(event_type),
                timestamp,
                debug_count,
            });

        this.emit_in_progress = false;
        this.maybeDeinit();
    }

    pub fn init(manager: *PathWatcherManager, path: [:0]const u8, recursive: bool) bun.sys.Maybe(*PathWatcher) {
        var outbuf: bun.PathBuffer = undefined;
        const event_path = switch (bun.sys.readlink(path, &outbuf)) {
            .err => |err| brk: {
                if (err.errno == @backingInt(bun.sys.E.NOENT)) {
                    return .{ .err = .{
                        .errno = err.errno,
                        .syscall = .open,
                    } };
                }

                break :brk path;
            },
            .result => |event_path| event_path,
        };

        const watchers_entry = bun.handleOom(manager.watchers.getOrPut(bun.default_allocator, @as([]const u8, event_path)));
        if (watchers_entry.found_existing) {
            return .{ .result = watchers_entry.value_ptr.* };
        }

        var this = PathWatcher.new(.{
            .handle = std.mem.zeroes(uv.uv_fs_event_t),
            .manager = manager,
        });

        // uv_fs_event_init on Windows unconditionally returns 0 (vendor/libuv/src/win/fs-event.c).
        // bun.assert evaluates its argument before the inline early-return, so this runs in release too.
        bun.assert(uv.uv_fs_event_init(manager.loop, &this.handle) == .zero);
        this.handle.data = this;

        // UV_FS_EVENT_RECURSIVE only works for Windows and OSX
        if (uv.uv_fs_event_start(
            &this.handle,
            PathWatcher.uvEventCallback,
            event_path.ptr,
            if (recursive) uv.UV_FS_EVENT_RECURSIVE else 0,
        ).toError(.watch)) |err| {
            // `errdefer` doesn't fire on `return .{ .err = ... }` (that's a successful return of a
            // Maybe(T), not an error-union return). Clean up the map entry and the half-initialized
            // watcher inline. See #26254.
            _ = manager.watchers.swapRemove(event_path);
            this.manager = null; // prevent deinit() from re-entering unregisterWatcher
            this.deinit();
            return .{ .err = err };
        }
        // we handle this in node_fs_watcher
        uv.uv_unref(@ptrCast(&this.handle));

        watchers_entry.value_ptr.* = this;
        watchers_entry.key_ptr.* = bun.handleOom(bun.default_allocator.dupeSentinel(u8, event_path, 0));

        return .{ .result = this };
    }

    fn uvClosedCallback(handler: *anyopaque) callconv(.c) void {
        log("onClose", .{});
        const event = bun.cast(*uv.uv_fs_event_t, handler);
        const this = bun.cast(*PathWatcher, event.data);
        bun.destroy(this);
    }

    pub fn detach(this: *PathWatcher, handler: *WatcherCore.CallbackContext) void {
        if (this.handlers.swapRemove(handler)) {
            this.maybeDeinit();
        }
    }

    fn maybeDeinit(this: *PathWatcher) void {
        if (this.handlers.count() == 0 and !this.emit_in_progress) {
            this.deinit();
        }
    }

    fn deinit(this: *PathWatcher) void {
        log("deinit", .{});
        this.handlers.clearAndFree(bun.default_allocator);

        if (this.manager) |manager| {
            this.manager = null;
            if (this.handle.path) |path| {
                manager.unregisterWatcher(this, std.mem.sliceTo(path, 0));
            } else {
                manager.unregisterWatcher(this, "");
            }
        }
        if (uv.uv_is_closed(@ptrCast(&this.handle))) {
            bun.destroy(this);
        } else {
            _ = uv.uv_fs_event_stop(&this.handle);
            _ = uv.uv_close(@ptrCast(&this.handle), PathWatcher.uvClosedCallback);
        }
    }
};

pub const Runtime = struct {
    loop: *bun.Async.Loop,
};

pub fn watch(
    runtime: Runtime,
    path: [:0]const u8,
    recursive: bool,
    callback: PathWatcher.Callback,
    update_end: PathWatcher.UpdateEndCallback,
    ctx: *WatcherCore.CallbackContext,
) bun.sys.Maybe(*PathWatcher) {
    if (!bun.Environment.isWindows) {
        @compileError("win_watcher should only be used on Windows");
    }

    const manager = default_manager orelse brk: {
        default_manager = PathWatcherManager.init(runtime);
        break :brk default_manager.?;
    };
    var watcher = switch (PathWatcher.init(manager, path, recursive)) {
        .err => |err| return .{ .err = err },
        .result => |watcher| watcher,
    };
    bun.handleOom(watcher.handlers.put(bun.default_allocator, ctx, .{
        .callback = callback,
        .update_end = update_end,
    }));
    return .{ .result = watcher };
}

const string = []const u8;

const std = @import("std");
const WatcherCore = @import("./fs_watcher.zig");
const EventType = WatcherCore.ChangeKind;

const bun = @import("bun");
const Output = bun.Output;

const windows = bun.windows;
const uv = windows.libuv;
