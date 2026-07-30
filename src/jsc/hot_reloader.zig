pub const ImportWatcher = union(enum) {
    none,
    hot: *HotReloader,
    watch: *WatchReloader,

    pub fn deinit(this: *ImportWatcher) void {
        switch (this.*) {
            .none => {},
            inline .hot, .watch => |reloader| reloader.deinit(Watcher.requires_file_descriptors),
        }
        this.* = .none;
    }

    pub inline fn watchlist(this: ImportWatcher) Watcher.WatchList {
        return if (this.core()) |watcher| watcher.watchlist else .{};
    }

    pub inline fn indexOf(this: ImportWatcher, hash: Watcher.HashType) ?u32 {
        return if (this.core()) |watcher| watcher.indexOf(hash) else null;
    }

    pub inline fn addFileByPathSlow(
        this: ImportWatcher,
        file_path: string,
        loader: options.Loader,
    ) bool {
        return if (this.core()) |watcher|
            watcher.addFileByPathSlow(file_path, loader)
        else
            true;
    }

    pub inline fn addFile(
        this: ImportWatcher,
        fd: bun.FD,
        file_path: string,
        hash: Watcher.HashType,
        loader: options.Loader,
        dir_fd: bun.FD,
        package_json: ?*bun.PackageJSON,
        comptime copy_file_path: bool,
    ) bun.sys.Maybe(void) {
        return if (this.core()) |watcher|
            watcher.addFile(
                fd,
                file_path,
                hash,
                loader,
                dir_fd,
                package_json,
                copy_file_path,
            )
        else
            .success;
    }

    pub inline fn core(this: ImportWatcher) ?*Watcher {
        return switch (this) {
            inline .hot, .watch => |reloader| reloader.watcher,
            .none => null,
        };
    }
};

pub const HotReloader = NewHotReloader(VirtualMachine, jsc.EventLoop, false);
pub const WatchReloader = NewHotReloader(VirtualMachine, jsc.EventLoop, true);

/// When non-null, `onFileUpdate` records the absolute path of every file
/// it sees change before triggering a reload. Used by `bun test --changed
/// --watch` so the restarted process can narrow its changed-file set to
/// what the watcher actually observed (instead of re-querying git, which
/// would re-run every test affected by any uncommitted change, not just
/// the one that was just edited).
///
/// Set by `test_command.zig` on the main thread before the watcher thread
/// starts; after that point only the watcher thread touches it. Its
/// contents are written to `watch_changed_trigger_file` immediately
/// before `reloadProcess`; the new process reads and deletes that file.
pub var watch_changed_paths: ?*bun.StringSet = null;

/// Absolute path of the temp file `flushChangedPathsForReload` writes
/// the changed-path list into. The same path is exported via the
/// `BUN_INTERNAL_TEST_CHANGED_TRIGGER_FILE` env var so the restarted
/// process can find it. Set alongside `watch_changed_paths` by
/// `test_command.zig`; the string must outlive the process.
pub var watch_changed_trigger_file: ?[:0]const u8 = null;

fn recordChangedPath(path: []const u8) void {
    const set = watch_changed_paths orelse return;
    if (path.len == 0) return;
    bun.handleOom(set.insert(path));
}

/// Write the recorded changed paths to the trigger file so the next
/// process (after exec()) can consume them. Best-effort: if the write
/// fails, the new process falls back to querying git.
fn flushChangedPathsForReload() void {
    // `watch_changed_trigger_file` is never set on Windows (see
    // `ChangedFilesFilter.initWatchTrigger`), so this body would be
    // dead there anyway; guarding lets us use POSIX path types below.
    if (Environment.isWindows) return;

    const set = watch_changed_paths orelse return;
    const dest = watch_changed_trigger_file orelse return;
    if (set.count() == 0) return;

    var buf = std.array_list.Managed(u8).init(bun.default_allocator);
    defer buf.deinit();
    for (set.keys()) |p| {
        buf.appendSlice(p) catch return;
        buf.append('\n') catch return;
    }
    _ = bun.sys.File.writeFile(bun.FD.cwd(), dest, buf.items);
}

extern fn BunDebugger__willHotReload() void;

pub fn NewHotReloader(comptime Ctx: type, comptime EventLoopType: type, comptime reload_immediately: bool) type {
    return struct {
        const Reloader = @This();

        ctx: *Ctx,
        watcher: *Watcher,
        verbose: bool = false,
        references: std.atomic.Value(u32) = .init(1),
        stopping: std.atomic.Value(bool) = .init(false),
        pending_count: std.atomic.Value(u32) = .init(0),
        watch_event: std.Io.Event = .unset,
        watch_outcome: std.atomic.Value(WatchOutcome) = .init(.waiting),

        main: MainFile = .{},

        tombstones: bun.StringHashMapUnmanaged(*bun.fs.FileSystem.RealFS.EntriesOption) = .{},

        pub const WatchOutcome = enum(u8) {
            waiting,
            reload,
            failed,
        };

        pub fn init(
            ctx: *Ctx,
            fs: *bun.fs.FileSystem,
            verbose: bool,
            clear_screen_flag: bool,
            entry_path: ?[]const u8,
        ) *Reloader {
            const reloader = bun.handleOom(bun.default_allocator.create(Reloader));
            reloader.* = .{
                .ctx = ctx,
                .watcher = undefined,
                .verbose = Environment.enable_logs or verbose,
                .main = MainFile.init(entry_path orelse ""),
            };

            clear_screen = clear_screen_flag;
            const watcher = Watcher.init(Reloader, reloader, fs, bun.default_allocator) catch |err| {
                bun.handleErrorReturnTrace(err, @errorReturnTrace());
                Output.panic("Failed to enable File Watcher: {s}", .{@errorName(err)});
            };
            reloader.watcher = watcher;
            watcher.start() catch |err| {
                bun.handleErrorReturnTrace(err, @errorReturnTrace());
                Output.panic("Failed to start File Watcher: {s}", .{@errorName(err)});
            };
            return reloader;
        }

        fn debug(comptime fmt: string, args: anytype) void {
            if (Environment.enable_logs) {
                Output.scoped(.hot_reloader, .visible)(fmt, args);
            } else {
                Output.prettyErrorln("<cyan>watcher<r><d>:<r> " ++ fmt, args);
            }
        }

        pub fn eventLoop(this: @This()) *EventLoopType {
            return this.ctx.eventLoop();
        }

        pub fn enqueueTaskConcurrent(this: @This(), task: *jsc.ConcurrentTask) void {
            if (comptime reload_immediately)
                unreachable;

            this.eventLoop().enqueueTaskConcurrent(task);
        }

        pub var clear_screen = false;

        const MainFile = struct {
            dir: []const u8 = "",
            dir_hash: Watcher.HashType = 0,

            file: []const u8 = "",
            hash: Watcher.HashType = 0,

            /// On macOS, vim's atomic save triggers a race condition:
            /// 1. Old file gets NOTE_RENAME (file renamed to temp name: a.js -> a.js~)
            /// 2. We receive the event and would normally trigger reload immediately
            /// 3. But the new file hasn't been created yet - reload fails with ENOENT
            /// 4. New file gets created and written (a.js)
            /// 5. Parent directory gets NOTE_WRITE
            ///
            /// To fix this: when the entrypoint gets NOTE_RENAME, we set this flag
            /// and skip the reload. Then when the parent directory gets NOTE_WRITE,
            /// we check if the file exists and trigger the reload.
            is_waiting_for_dir_change: bool = false,

            pub fn init(file: []const u8) MainFile {
                var main = MainFile{
                    .file = file,
                    .hash = if (file.len > 0) Watcher.getHash(file) else 0,
                    .is_waiting_for_dir_change = false,
                };

                if (file.len > 0) {
                    const dir = std.fs.path.dirname(file) orelse ".";
                    main.dir = dir;
                    main.dir_hash = Watcher.getHash(main.dir);
                }

                return main;
            }
        };

        pub const Task = struct {
            count: u8 = 0,
            hashes: [8]u32,
            paths: if (Ctx == bun.bake.DevServer) [8][]const u8 else void,
            /// Left uninitialized until .enqueue
            concurrent_task: jsc.ConcurrentTask,
            reloader: *Reloader,

            pub fn initEmpty(reloader: *Reloader) Task {
                return .{
                    .reloader = reloader,

                    .hashes = @splat(0),
                    .paths = if (Ctx == bun.bake.DevServer) @splat(&.{}),
                    .count = 0,
                    .concurrent_task = undefined,
                };
            }

            pub fn append(this: *Task, id: u32) void {
                if (this.count == 8) {
                    this.enqueue();
                    this.count = 0;
                }

                this.hashes[this.count] = id;
                this.count += 1;
            }

            pub fn run(this: *Task) void {
                if (this.reloader.stopping.load(.acquire)) return;

                // Since we rely on the event loop for hot reloads, there can be
                // a delay before the next reload begins. In the time between the
                // last reload and the next one, we shouldn't schedule any more
                // hot reloads. Since we reload literally everything, we don't
                // need to worry about missing any changes.
                //
                // Note that we set the count _before_ we reload, so that if we
                // get another hot reload request while we're reloading, we'll
                // still enqueue it.
                while (this.reloader.pending_count.swap(0, .monotonic) > 0) {
                    if (this.reloader.stopping.load(.acquire)) return;
                    this.reloader.ctx.reload(this);
                }
            }

            pub fn enqueue(this: *Task) void {
                jsc.markBinding(@src());
                if (this.count == 0 or this.reloader.stopping.load(.acquire))
                    return;

                if (comptime reload_immediately) {
                    if (comptime Ctx == bun.bundle_v2.BuildWatchSession) {
                        if (this.reloader.watch_outcome.cmpxchgStrong(.waiting, .reload, .release, .acquire) == null) {
                            this.reloader.watch_event.set(this.reloader.ctx.transpiler.io);
                        }
                        return;
                    }
                    Output.flush();
                    if (comptime Ctx == ImportWatcher) {
                        if (this.reloader.ctx.rare_data) |rare|
                            rare.closeAllListenSocketsForWatchMode();
                    }
                    flushChangedPathsForReload();
                    bun.reloadProcess(bun.default_allocator, clear_screen, false);
                    unreachable;
                }

                _ = this.reloader.pending_count.fetchAdd(1, .monotonic);

                BunDebugger__willHotReload();
                const that = bun.new(Task, .{
                    .reloader = this.reloader,
                    .count = this.count,
                    .paths = this.paths,
                    .hashes = this.hashes,
                    .concurrent_task = undefined,
                });
                _ = this.reloader.references.fetchAdd(1, .monotonic);
                that.concurrent_task = .{ .task = jsc.Task.init(that) };
                that.reloader.enqueueTaskConcurrent(&that.concurrent_task);
                this.count = 0;
            }

            pub fn deinit(this: *Task) void {
                const reloader = this.reloader;
                bun.destroy(this);
                reloader.release();
            }
        };

        pub fn enableHotModuleReloading(this: *Ctx, entry_path: ?[]const u8) void {
            comptime bun.assert(@TypeOf(this.bun_watcher) == ImportWatcher);
            if (this.bun_watcher != .none)
                return;

            const reloader = Reloader.init(
                this,
                this.transpiler.fs,
                if (@hasField(Ctx, "log")) this.log.level.atLeast(.info) else false,
                !this.transpiler.env.hasSetNoClearTerminalOnReload(!Output.enable_ansi_colors_stdout),
                entry_path,
            );

            if (comptime reload_immediately) {
                this.bun_watcher = .{ .watch = reloader };
            } else {
                this.bun_watcher = .{ .hot = reloader };
            }
            this.transpiler.resolver.watcher = reloader.watcher.getResolveWatcher();
        }

        pub fn deinit(this: *Reloader, close_descriptors: bool) void {
            bun.assert(!this.stopping.swap(true, .release));
            this.watcher.deinit(close_descriptors);
            this.pending_count.store(0, .release);
            this.release();
        }

        fn release(this: *Reloader) void {
            const previous = this.references.fetchSub(1, .release);
            bun.assert(previous > 0);
            if (previous == 1) {
                // Acquire the release sequence before destroying shared state.
                _ = this.references.load(.acquire);
                this.tombstones.deinit(bun.default_allocator);
                bun.destroy(this);
            }
        }

        pub fn waitForReload(this: *Reloader, io: std.Io) WatchOutcome {
            this.watch_event.waitUncancelable(io);
            return this.watch_outcome.load(.acquire);
        }

        fn putTombstone(this: *@This(), key: []const u8, value: *bun.fs.FileSystem.RealFS.EntriesOption) void {
            this.tombstones.put(bun.default_allocator, key, value) catch unreachable;
        }

        fn getTombstone(this: *@This(), key: []const u8) ?*bun.fs.FileSystem.RealFS.EntriesOption {
            return this.tombstones.get(key);
        }

        pub fn onError(this: *@This(), err: bun.sys.Error) void {
            Output.err(@as(bun.sys.E, @fromBackingInt(@intCast(err.errno))), "Watcher crashed", .{});
            if (comptime Ctx == bun.bundle_v2.BuildWatchSession) {
                if (this.watch_outcome.cmpxchgStrong(.waiting, .failed, .release, .acquire) == null) {
                    this.watch_event.set(this.ctx.transpiler.io);
                }
            }
            if (bun.Environment.isDebug) {
                @panic("Watcher crash");
            }
        }

        pub fn getContext(this: *@This()) *Watcher {
            return this.watcher;
        }

        pub noinline fn onFileUpdate(
            this: *@This(),
            events: []Watcher.WatchEvent,
            changed_files: []?[:0]u8,
            watchlist: Watcher.WatchList,
        ) void {
            const slice = watchlist.slice();
            const file_paths = slice.items(.file_path);
            const counts = slice.items(.count);
            const kinds = slice.items(.kind);
            const hashes = slice.items(.hash);
            const parents = slice.items(.parent_hash);
            const file_descriptors = slice.items(.fd);
            const ctx = this.getContext();
            defer ctx.flushEvictions();
            defer Output.flush();

            const fs: *Fs.FileSystem = &Fs.FileSystem.instance;
            const rfs: *Fs.FileSystem.RealFS = &fs.fs;
            var _on_file_update_path_buf: bun.PathBuffer = undefined;
            var current_task = Task.initEmpty(this);
            defer current_task.enqueue();

            for (events) |event| {
                // Stale udata: kevent.udata can outlive a swapRemove in flushEvictions.
                if (event.index >= file_paths.len) continue;
                const file_path = file_paths[event.index];
                const update_count = counts[event.index] + 1;
                counts[event.index] = update_count;
                const kind = kinds[event.index];

                const current_hash = hashes[event.index];

                switch (kind) {
                    .file => {
                        if (event.op.delete or (event.op.rename and Environment.isKqueue)) {
                            ctx.removeAtIndex(
                                event.index,
                                0,
                                &.{},
                                .file,
                            );
                        }

                        if (this.verbose) {
                            const relative_path = bun.handleOom(std.fs.path.relative(
                                bun.default_allocator,
                                fs.top_level_dir,
                                null,
                                fs.top_level_dir,
                                file_path,
                            ));
                            defer bun.default_allocator.free(relative_path);
                            debug("File changed: {s}", .{relative_path});
                        }

                        if (event.op.write or event.op.delete or event.op.rename) {
                            recordChangedPath(file_path);
                            if (comptime Environment.isKqueue) {
                                if (event.op.rename) {
                                    // Special case for entrypoint: defer reload until we get
                                    // a directory write event confirming the file exists.
                                    // This handles vim's save process which renames the old file
                                    // before the new file is re-created with a different inode.
                                    if (this.main.hash == current_hash and !reload_immediately) {
                                        this.main.is_waiting_for_dir_change = true;
                                        continue;
                                    }
                                }

                                // If we got a write event after rename, the file is back - proceed with reload
                                if (this.main.is_waiting_for_dir_change and this.main.hash == current_hash) {
                                    this.main.is_waiting_for_dir_change = false;
                                }
                            }

                            current_task.append(current_hash);
                        }
                    },
                    .directory => {
                        if (comptime Environment.isWindows) {
                            // on windows we receive file events for all items affected by a directory change
                            // so we only need to clear the directory cache. all other effects will be handled
                            // by the file events
                            _ = this.ctx.bustDirCache(file_path);
                            continue;
                        }
                        var affected_buf: [128][]const u8 = undefined;
                        var entries_option: ?*Fs.FileSystem.RealFS.EntriesOption = null;

                        const affected = brk: {
                            if (comptime Environment.isKqueue) {
                                if (rfs.entries.get(file_path)) |existing| {
                                    this.putTombstone(file_path, existing);
                                    entries_option = existing;
                                } else if (this.getTombstone(file_path)) |existing| {
                                    entries_option = existing;
                                }

                                if (event.op.write) {
                                    // Check if the entrypoint now exists after an atomic save.
                                    // If we previously got a NOTE_RENAME on the entrypoint (vim renamed
                                    // the file), this directory write event signals that the new
                                    // file has been re-created. Verify it exists and trigger reload.
                                    if (this.main.is_waiting_for_dir_change and this.main.dir_hash == current_hash) {
                                        if (bun.sys.faccessat(file_descriptors[event.index], std.fs.path.basename(this.main.file)) == .result) {
                                            this.main.is_waiting_for_dir_change = false;
                                            recordChangedPath(this.main.file);
                                            current_task.append(this.main.hash);
                                        }
                                    }
                                }

                                var affected_i: usize = 0;

                                // if a file descriptor is stale, we need to close it
                                if (event.op.delete and entries_option != null) {
                                    for (parents, 0..) |parent_hash, entry_id| {
                                        if (parent_hash == current_hash) {
                                            const affected_path = file_paths[entry_id];
                                            const was_deleted = !bun.sys.exists(affected_path);
                                            if (!was_deleted) continue;

                                            affected_buf[affected_i] = std.fs.path.basename(affected_path);
                                            affected_i += 1;
                                            if (affected_i >= affected_buf.len) break;
                                        }
                                    }
                                }

                                break :brk affected_buf[0..affected_i];
                            }

                            break :brk event.names(changed_files);
                        };

                        if (affected.len > 0 and !Environment.isKqueue) {
                            if (rfs.entries.get(file_path)) |existing| {
                                this.putTombstone(file_path, existing);
                                entries_option = existing;
                            } else if (this.getTombstone(file_path)) |existing| {
                                entries_option = existing;
                            }
                        }

                        _ = this.ctx.bustDirCache(file_path);

                        if (entries_option) |dir_ent| {
                            var last_file_hash: Watcher.HashType = std.math.maxInt(Watcher.HashType);

                            for (affected) |changed_name_| {
                                const changed_name: []const u8 = if (comptime Environment.isKqueue)
                                    changed_name_
                                else
                                    bun.asByteSlice(changed_name_.?);
                                if (changed_name.len == 0 or changed_name[0] == '~' or changed_name[0] == '.') continue;

                                const loader = (this.ctx.getLoaders().get(std.fs.path.extension(changed_name)) orelse .file);
                                var prev_entry_id: usize = std.math.maxInt(usize);
                                if (loader != .file) {
                                    var path_string: bun.PathString = undefined;
                                    var file_hash: Watcher.HashType = last_file_hash;
                                    const abs_path: string = brk: {
                                        if (dir_ent.entries.get(@as([]const u8, @ptrCast(changed_name)))) |file_ent| {
                                            // reset the file descriptor
                                            file_ent.entry.cache.fd = .invalid;
                                            file_ent.entry.need_stat = true;
                                            path_string = file_ent.entry.abs_path;
                                            file_hash = Watcher.getHash(path_string.slice());
                                            for (hashes, 0..) |hash, entry_id| {
                                                if (hash == file_hash) {
                                                    if (file_descriptors[entry_id].isValid()) {
                                                        if (prev_entry_id != entry_id) {
                                                            recordChangedPath(path_string.slice());
                                                            current_task.append(hashes[entry_id]);
                                                            if (this.verbose)
                                                                debug("Removing file: {s}", .{path_string.slice()});
                                                            ctx.removeAtIndex(
                                                                @as(u16, @truncate(entry_id)),
                                                                0,
                                                                &.{},
                                                                .file,
                                                            );
                                                        }
                                                    }

                                                    prev_entry_id = entry_id;
                                                    break;
                                                }
                                            }

                                            break :brk path_string.slice();
                                        } else {
                                            const path_slice = bun.path.joinAbsStringBuf(file_path, &_on_file_update_path_buf, &.{changed_name}, .auto);
                                            file_hash = Watcher.getHash(path_slice);
                                            break :brk path_slice;
                                        }
                                    };

                                    // skip consecutive duplicates
                                    if (last_file_hash == file_hash) continue;
                                    last_file_hash = file_hash;

                                    if (this.verbose) {
                                        const relative_path = bun.handleOom(std.fs.path.relative(
                                            bun.default_allocator,
                                            fs.top_level_dir,
                                            null,
                                            fs.top_level_dir,
                                            abs_path,
                                        ));
                                        defer bun.default_allocator.free(relative_path);
                                        debug("File change: {s}", .{relative_path});
                                    }
                                }
                            }
                        }

                        if (this.verbose) {
                            const relative_path = bun.handleOom(std.fs.path.relative(
                                bun.default_allocator,
                                fs.top_level_dir,
                                null,
                                fs.top_level_dir,
                                file_path,
                            ));
                            defer bun.default_allocator.free(relative_path);
                            debug("Dir change: {s} (affecting {d})", .{ relative_path, affected.len });
                        }
                    },
                }
            }
        }
    };
}

const string = []const u8;
pub const Buffer = MarkedArrayBuffer;

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Fs = bun.fs;
const Output = bun.Output;
const Watcher = bun.Watcher;
const options = bun.options;
const strings = bun.strings;

const jsc = bun.jsc;
const MarkedArrayBuffer = bun.jsc.MarkedArrayBuffer;
const VirtualMachine = jsc.VirtualMachine;
