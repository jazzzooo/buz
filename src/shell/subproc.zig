pub const Stdio = StdioModule.Stdio;

const StdioResult = StdioModule.Result;

/// Used for captured writer
pub const ShellIO = struct {
    stdout: ?*sh.IOWriter = null,
    stderr: ?*sh.IOWriter = null,

    pub fn ref(this: *@This()) void {
        if (this.stdout) |io| io.ref();
        if (this.stderr) |io| io.ref();
    }

    pub fn deref(this: *@This()) void {
        if (this.stdout) |io| io.deref();
        if (this.stderr) |io| io.deref();
    }
};

/// TODO Set this to interpreter
const ShellCmd = bun.shell.Interpreter.Cmd;

const log = Output.scoped(.SHELL_SUBPROC, .visible);

pub const ShellSubprocess = struct {
    const Subprocess = @This();

    pub const default_max_buffer_size = 1024 * 1024 * 4;
    pub const Process = bun.spawn.Process;

    cmd_parent: *ShellCmd,

    process: *Process,

    stdin: Writable = undefined,
    stdout: Readable = undefined,
    stderr: Readable = undefined,

    scheduler: sh.Scheduler,

    closed: std.enums.EnumSet(enum {
        stdin,
        stdout,
        stderr,
    }) = .{},

    flags: Flags = .{},

    pub const OutKind = util.OutKind;

    pub fn onStaticPipeWriterDone(this: *ShellSubprocess) void {
        log("Subproc(0x{x}) onStaticPipeWriterDone(cmd=0x{x}))", .{ @intFromPtr(this), @intFromPtr(this.cmd_parent) });
        this.cmd_parent.bufferedInputClose();
    }

    const Writable = union(enum) {
        fd: bun.FD,
        buffer: *StaticPipeWriter,
        memfd: bun.FD,
        inherit: void,
        ignore: void,

        pub fn hasPendingActivity(this: *const Writable) bool {
            return switch (this.*) {
                .buffer => true,
                else => false,
            };
        }

        pub fn ref(this: *Writable) void {
            switch (this.*) {
                .buffer => this.buffer.updateRef(true),
                else => {},
            }
        }

        pub fn unref(this: *Writable) void {
            switch (this.*) {
                .buffer => this.buffer.updateRef(false),
                else => {},
            }
        }

        pub fn init(
            stdio: *Stdio,
            scheduler: sh.Scheduler,
            subprocess: *Subprocess,
            result: *StdioResult,
        ) bun.OOM!Writable {
            assertStdioResult(result.*);
            return switch (stdio.*) {
                .blob, .leased_bytes, .retained_bytes => source: {
                    if (comptime Environment.isWindows) {
                        if (result.* != .buffer) break :source .ignore;
                    } else if (result.* != .owned_fd) break :source .ignore;
                    const input: StdioModule.Source = switch (stdio.*) {
                        .blob => |blob| .{ .blob = blob },
                        .leased_bytes => |bytes| .{ .leased_bytes = bytes },
                        .retained_bytes => |bytes| .{ .retained_bytes = bytes },
                        else => unreachable,
                    };
                    stdio.* = .ignore;
                    break :source .{ .buffer = try StaticPipeWriter.create(scheduler, subprocess, result, input) };
                },
                .memfd => |fd| memfd: {
                    assert(fd != bun.invalid_fd);
                    stdio.* = .ignore;
                    _ = result.take();
                    break :memfd .{ .memfd = fd };
                },
                .fd => |fd| .{ .fd = fd },
                .dup2 => |dup2| if (Environment.isWindows) .{ .fd = dup2.to.toFd() } else @panic("Unimplemented stdin dup2"),
                .inherit => .inherit,
                .pipe, .ignore, .ipc, .capture => .ignore,
            };
        }

        pub fn finalize(this: *Writable) void {
            return switch (this.*) {
                .buffer => |buffer| {
                    this.* = .ignore;
                    buffer.detach();
                    buffer.updateRef(false);
                    buffer.close();
                    buffer.deref();
                },
                .memfd => |fd| {
                    _ = fd.closeAllowingStandardIo(null);
                    this.* = .{ .ignore = {} };
                },
                .ignore => {},
                .fd, .inherit => {},
            };
        }

        pub fn close(this: *Writable) void {
            switch (this.*) {
                .memfd => |fd| {
                    _ = fd.closeAllowingStandardIo(null);
                    this.* = .{ .ignore = {} };
                },
                .fd => this.* = .ignore,
                .buffer => {
                    this.buffer.close();
                },
                .ignore => {},
                .inherit => {},
            }
        }
    };

    pub const Readable = union(enum) {
        fd: bun.FD,
        memfd: bun.FD,
        pipe: *PipeReader,
        inherit: void,
        ignore: void,
        closed: void,
        buffer: []u8,

        pub fn ref(this: *Readable) void {
            switch (this.*) {
                .pipe => {
                    this.pipe.updateRef(true);
                },
                else => {},
            }
        }

        pub fn unref(this: *Readable) void {
            switch (this.*) {
                .pipe => {
                    this.pipe.updateRef(false);
                },
                else => {},
            }
        }

        pub fn toSlice(this: *Readable) ?[]const u8 {
            switch (this.*) {
                .fd => return null,
                .pipe => {
                    var buf = this.pipe.reader.buffer();
                    this.pipe.buffer.fifo.close_on_empty_read = true;
                    this.pipe.readAll();

                    const bytes = buf.items[0..];
                    // this.pipe.buffer.internal_buffer = .{};

                    if (bytes.len > 0) {
                        return bytes;
                    }

                    return "";
                },
                .buffer => |buf| buf,
                .memfd => @panic("TODO"),
                else => {
                    return null;
                },
            }
        }

        pub fn init(out_type: bun.shell.Subprocess.OutKind, stdio: *Stdio, shellio: ?*sh.IOWriter, scheduler: sh.Scheduler, process: *ShellSubprocess, result: *StdioResult) bun.OOM!Readable {
            assertStdioResult(result.*);
            return switch (stdio.*) {
                .inherit => Readable{ .inherit = {} },
                .ipc, .dup2, .ignore => Readable{ .ignore = {} },
                .fd => |fd| Readable{ .fd = fd },
                .blob => Readable{ .ignore = {} },
                .memfd => |fd| memfd: {
                    stdio.* = .ignore;
                    _ = result.take();
                    break :memfd Readable{ .memfd = fd };
                },
                .pipe => Readable{ .pipe = try PipeReader.create(scheduler, process, result, null, out_type) },
                .leased_bytes => {
                    const readable = Readable{ .pipe = try PipeReader.create(scheduler, process, result, null, out_type) };
                    readable.pipe.buffered_output = .{
                        .leased_bytes = .{ .buf = stdio.leased_bytes, .i = 0 },
                    };
                    stdio.* = .ignore;
                    return readable;
                },
                .retained_bytes => @panic("retained input bytes cannot be used as shell output"),
                .capture => Readable{ .pipe = try PipeReader.create(scheduler, process, result, shellio, out_type) },
            };
        }

        pub fn close(this: *Readable) void {
            switch (this.*) {
                .memfd => |fd| {
                    this.* = .{ .closed = {} };
                    _ = fd.closeAllowingStandardIo(null);
                },
                // .fd is borrowed from the shell's IOWriter (see IO.OutKind.to_subproc_stdio) or
                // a CowFd redirect; the owner closes it.
                .fd => {
                    this.* = .{ .closed = {} };
                },
                .pipe => {
                    this.pipe.close();
                },
                else => {},
            }
        }

        pub fn finalize(this: *Readable) void {
            switch (this.*) {
                .memfd => |fd| {
                    this.* = .{ .closed = {} };
                    _ = fd.closeAllowingStandardIo(null);
                },
                // .fd is borrowed from the shell's IOWriter (see IO.OutKind.to_subproc_stdio) or
                // a CowFd redirect; the owner closes it.
                .fd => {
                    this.* = .{ .closed = {} };
                },
                .pipe => |pipe| {
                    defer pipe.detach();
                    this.* = .{ .closed = {} };
                },
                else => {},
            }
        }
    };

    pub const Flags = packed struct(u8) {
        is_sync: bool = false,
        killed: bool = false,
        _: u6 = 0,
    };
    pub const SignalCode = bun.SignalCode;

    // pub const Pipe = struct {
    //     writer: Writer = Writer{},
    //     parent: *Subprocess,
    //     src: WriterSrc,

    //     writer: ?CapturedBufferedWriter = null,

    //     status: Status = .{
    //         .pending = {},
    //     },
    // };

    pub const StaticPipeWriter = @import("../io/StaticPipeWriter.zig").New(
        ShellSubprocess,
        sh.Scheduler,
        StdioModule.Source,
        StdioResult,
    );

    pub fn getIO(this: *Subprocess, comptime out_kind: OutKind) *Readable {
        switch (out_kind) {
            .stdout => return &this.stdout,
            .stderr => return &this.stderr,
        }
    }

    pub fn hasExited(this: *const Subprocess) bool {
        return this.process.hasExited();
    }

    pub fn ref(this: *Subprocess) void {
        this.process.enableKeepingEventLoopAlive();

        // this.stdin.ref();
        // }

        // if (!this.hasCalledGetter(.stdout)) {
        this.stdout.ref();
        // }

        // if (!this.hasCalledGetter(.stderr)) {
        this.stderr.ref();
        // }
    }

    /// This disables the keeping process alive flag on the poll and also in the stdin, stdout, and stderr
    pub fn unref(this: *@This(), comptime _: bool) void {
        this.process.disableKeepingEventLoopAlive();

        this.stdout.unref();

        this.stderr.unref();
    }

    pub fn hasKilled(this: *const @This()) bool {
        return this.process.hasKilled();
    }

    pub fn tryKill(this: *@This(), sig: i32) bun.sys.Maybe(void) {
        if (this.hasExited()) {
            return .success;
        }

        return this.process.kill(@intCast(sig));
    }

    fn closeProcess(this: *@This()) void {
        this.process.exit_handler = .{};
        this.process.close();
        this.process.deref();
    }

    pub fn disconnect(this: *@This()) void {
        _ = this;
        // if (this.ipc_mode == .none) return;
        // this.ipc.socket.close(0, null);
        // this.ipc_mode = .none;
    }

    pub fn closeIO(this: *@This(), comptime io: @EnumLiteral()) void {
        if (this.closed.contains(io)) return;
        log("close IO {s}", .{@tagName(io)});
        this.closed.insert(io);

        // If you never referenced stdout/stderr, they won't be garbage collected.
        //
        // That means:
        //   1. We need to stop watching them
        //   2. We need to free the memory
        //   3. We need to halt any pending reads (1)
        // if (!this.hasCalledGetter(io)) {
        @field(this, @tagName(io)).finalize();
        // } else {
        // @field(this, @tagName(io)).close();
        // }
    }

    // This must only be run once per Subprocess
    pub fn finalizeSync(this: *@This()) void {
        this.closeProcess();

        this.closeIO(.stdin);
        this.closeIO(.stdout);
        this.closeIO(.stderr);
    }

    pub fn onCloseIO(this: *Subprocess, kind: StdioKind) void {
        switch (kind) {
            .stdin => {
                const input = this.stdin;
                this.stdin = .{ .ignore = {} };
                switch (input) {
                    .buffer => |writer| {
                        writer.deref();
                        this.onStaticPipeWriterDone();
                    },
                    else => {},
                }
            },
            inline .stdout, .stderr => |tag| {
                const out: *Readable = &@field(this, @tagName(tag));
                switch (out.*) {
                    .pipe => |pipe| {
                        if (pipe.state == .done) {
                            out.* = .{ .buffer = pipe.state.done };
                            pipe.state = .{ .done = &.{} };
                        } else {
                            out.* = .{ .ignore = {} };
                        }
                        pipe.deref();
                    },
                    else => {},
                }
            },
        }
    }

    pub fn deinit(this: *@This()) void {
        this.finalizeSync();
        log("Deinit", .{});
        bun.default_allocator.destroy(this);
    }

    pub const SpawnArgs = struct {
        arena: *bun.ArenaAllocator,
        cmd_parent: *ShellCmd,

        override_env: bool = false,
        env_array: std.ArrayList(?[*:0]const u8) = .empty,
        cwd: []const u8,
        stdio: [3]Stdio = .{
            .ignore,
            .pipe,
            .inherit,
        },
        lazy: bool = false,
        PATH: []const u8,
        detached: bool,
        // ipc_mode: IPCMode,
        // ipc_callback: JSValue,

        const EnvMapIter = struct {
            map: *bun.DotEnv.Map,
            iter: bun.DotEnv.Map.HashTable.Iterator,
            alloc: Allocator,

            const Entry = struct {
                key: Key,
                value: Value,
            };

            pub const Key = struct {
                val: []const u8,

                pub fn format(self: Key, writer: *std.Io.Writer) !void {
                    try writer.writeAll(self.val);
                }

                pub fn eqlComptime(this: Key, comptime str: []const u8) bool {
                    return bun.strings.eqlComptime(this.val, str);
                }
            };

            pub const Value = struct {
                val: [:0]const u8,

                pub fn format(self: Value, writer: *std.Io.Writer) !void {
                    try writer.writeAll(self.val);
                }
            };

            pub fn init(map: *bun.DotEnv.Map, alloc: Allocator) EnvMapIter {
                return EnvMapIter{
                    .map = map,
                    .iter = map.iter(),
                    .alloc = alloc,
                };
            }

            pub fn len(this: *const @This()) usize {
                return this.map.map.entries.len;
            }

            pub fn next(this: *@This()) !?@This().Entry {
                const entry = this.iter.next() orelse return null;
                var value = try this.alloc.allocSentinel(u8, entry.value_ptr.value.len, 0);
                @memcpy(value[0..entry.value_ptr.value.len], entry.value_ptr.value);
                value[entry.value_ptr.value.len] = 0;
                return .{
                    .key = .{ .val = entry.key_ptr.* },
                    .value = .{ .val = value },
                };
            }
        };

        pub fn default(arena: *bun.ArenaAllocator, cmd_parent: *ShellCmd, scheduler: sh.Scheduler, comptime is_sync: bool) SpawnArgs {
            var out: SpawnArgs = .{
                .arena = arena,

                .override_env = false,
                .env_array = .empty,
                .cwd = scheduler.top_level_dir,
                .stdio = .{
                    .{ .ignore = {} },
                    .{ .pipe = {} },
                    .inherit,
                },
                .lazy = false,
                // PATH unset → fall back to _PATH_DEFPATH on POSIX (Android often
                // has no PATH). PATH="" (explicit empty) is preserved — that's a
                // deliberate "search nothing" and substituting a default would
                // change argv[0] resolution on existing platforms.
                .PATH = if (scheduler.environment.get("PATH")) |p|
                    p
                else if (bun.Environment.isPosix)
                    std.mem.sliceTo(bun.c._PATH_DEFPATH, 0)
                else
                    "",
                .detached = false,
                .cmd_parent = cmd_parent,
            };

            if (comptime is_sync) {
                out.stdio[1] = .{ .pipe = {} };
                out.stdio[2] = .{ .pipe = {} };
            }
            return out;
        }

        /// `object_iter` should be a some type with the following fields:
        /// - `next() bool`
        pub fn fillEnv(
            this: *SpawnArgs,
            env_iter: *bun.shell.EnvMap.Iterator,
            comptime disable_path_lookup_for_arv0: bool,
        ) void {
            const allocator = this.arena.allocator();
            this.override_env = true;
            bun.handleOom(this.env_array.ensureTotalCapacityPrecise(allocator, env_iter.len));

            if (disable_path_lookup_for_arv0) {
                // If the env object does not include a $PATH, it must disable path lookup for argv[0]
                this.PATH = "";
            }

            while (env_iter.next()) |entry| {
                const key = entry.key_ptr.*.slice();
                const value = entry.value_ptr.*.slice();

                var line = bun.handleOom(std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ key, value }, 0));

                if (bun.strings.eqlComptime(key, "PATH")) {
                    this.PATH = bun.asByteSlice(line["PATH=".len..]);
                }

                bun.handleOom(this.env_array.append(allocator, line));
            }
        }
    };

    pub const WatchFd = bun.FD;

    pub fn spawnAsync(
        scheduler: sh.Scheduler,
        shellio: *ShellIO,
        spawn_args_: SpawnArgs,
        // We have to use an out pointer because this function may invoke callbacks that expect a
        // fully initialized parent object. Writing to this out pointer may be the last step needed
        // to initialize the object.
        out: **@This(),
        notify_caller_process_already_exited: *bool,
    ) bun.OOM!bun.shell.Result(void) {
        var spawn_args = spawn_args_;

        return switch (try spawnMaybeSyncImpl(
            scheduler,
            &spawn_args,
            shellio,
            out,
            notify_caller_process_already_exited,
        )) {
            .result => .success,
            .err => |err| return .{ .err = err },
        };
    }

    fn spawnMaybeSyncImpl(
        scheduler: sh.Scheduler,
        spawn_args: *SpawnArgs,
        shellio: *ShellIO,
        // We have to use an out pointer because this function may invoke callbacks that expect a
        // fully initialized parent object. Writing to this out pointer may be the last step needed
        // to initialize the object.
        out_subproc: **@This(),
        notify_caller_process_already_exited: *bool,
    ) bun.OOM!bun.shell.Result(void) {
        const is_sync = false;

        const arena = spawn_args.arena.allocator();

        if (!spawn_args.override_env and spawn_args.env_array.items.len == 0) {
            spawn_args.env_array.items = try scheduler.createNullDelimitedEnvMap(arena);
            spawn_args.env_array.capacity = spawn_args.env_array.items.len + 1;
        }

        defer {
            for (&spawn_args.stdio) |*s| s.deinit();
        }

        const no_sigpipe = if (shellio.stdout) |iowriter| !iowriter.options.child_sigpipe else true;

        // Hoist asSpawnOption results so a later one failing doesn't strand an earlier
        // Windows *uv.Pipe in an unbound temporary inside the struct initializer.
        const stdin_opt = switch (spawn_args.stdio[0].asSpawnOption(0)) {
            .result => |opt| opt,
            .err => |e| return .{ .err = .{ .custom = try bun.default_allocator.dupe(u8, e.toStr()) } },
        };
        const stdout_opt = switch (spawn_args.stdio[1].asSpawnOption(1)) {
            .result => |opt| opt,
            .err => |e| {
                if (Environment.isWindows) stdin_opt.deinit();
                return .{ .err = .{ .custom = try bun.default_allocator.dupe(u8, e.toStr()) } };
            },
        };
        const stderr_opt = switch (spawn_args.stdio[2].asSpawnOption(2)) {
            .result => |opt| opt,
            .err => |e| {
                if (Environment.isWindows) {
                    stdin_opt.deinit();
                    stdout_opt.deinit();
                }
                return .{ .err = .{ .custom = try bun.default_allocator.dupe(u8, e.toStr()) } };
            },
        };

        var spawn_options = bun.spawn.SpawnOptions{
            .cwd = spawn_args.cwd,
            .stdin = stdin_opt,
            .stdout = stdout_opt,
            .stderr = stderr_opt,
            .windows = if (Environment.isWindows) bun.spawn.WindowsSpawnOptions.WindowsOptions{
                .hide_window = true,
                .loop = scheduler.parentEventLoop(),
            },
        };
        if (bun.Environment.isPosix) {
            spawn_options.no_sigpipe = no_sigpipe;
        }

        spawn_args.cmd_parent.args.append(null) catch {
            spawn_options.deinit();
            return .{ .err = .{ .custom = bun.handleOom(bun.default_allocator.dupe(u8, "out of memory")) } };
        };

        spawn_args.env_array.append(arena, null) catch {
            spawn_options.deinit();
            return error.OutOfMemory;
        };

        const subprocess = scheduler.allocator.create(Subprocess) catch |err| {
            spawn_options.deinit();
            return err;
        };
        var initialized = false;
        defer if (!initialized) scheduler.allocator.destroy(subprocess);

        var spawn_result = switch (bun.spawn.spawnProcess(
            &spawn_options,
            @ptrCast(spawn_args.cmd_parent.args.items.ptr),
            @ptrCast(spawn_args.env_array.items.ptr),
        ) catch |err| {
            spawn_options.deinit();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .err = .{ .custom = try std.fmt.allocPrint(bun.default_allocator, "Failed to spawn process: {s}", .{@errorName(err)}) } };
        }) {
            .err => |err| {
                spawn_options.deinit();
                return .{ .err = .{ .sys = err.toShellSystemError() } };
            },
            .result => |result| result,
        };
        defer spawn_result.close();

        subprocess.* = Subprocess{
            .scheduler = scheduler,
            .process = spawn_result.toProcess(
                scheduler.runtimeLoopHandle(),
                is_sync,
            ),
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,

            .flags = .{
                .is_sync = is_sync,
            },
            .cmd_parent = spawn_args.cmd_parent,
        };
        initialized = true;
        {
            errdefer subprocess.deinit();
            subprocess.stdin = try Subprocess.Writable.init(&spawn_args.stdio[0], scheduler, subprocess, &spawn_result.stdin);
            subprocess.stdout = try Subprocess.Readable.init(.stdout, &spawn_args.stdio[1], shellio.stdout, scheduler, subprocess, &spawn_result.stdout);
            subprocess.stderr = try Subprocess.Readable.init(.stderr, &spawn_args.stdio[2], shellio.stderr, scheduler, subprocess, &spawn_result.stderr);
        }
        out_subproc.* = subprocess;
        subprocess.process.setExitHandler(subprocess);

        switch (subprocess.process.watch()) {
            .result => {},
            .err => {
                notify_caller_process_already_exited.* = true;
                spawn_args.lazy = false;
            },
        }

        if (subprocess.stdin == .buffer) {
            if (subprocess.stdin.buffer.start().asErr()) |err| {
                if (err.getErrno() == .NOMEM) {
                    _ = subprocess.tryKill(@backingInt(bun.SignalCode.SIGTERM));
                    subprocess.deinit();
                    return error.OutOfMemory;
                }
                const sys_err = err.toShellSystemError();
                _ = subprocess.tryKill(@backingInt(bun.SignalCode.SIGTERM));
                subprocess.deinit();
                return .{ .err = .{ .sys = sys_err } };
            }
        }

        if (subprocess.stdout == .pipe) {
            if (subprocess.stdout.pipe.start(subprocess, scheduler).asErr()) |err| {
                if (err.getErrno() == .NOMEM) {
                    _ = subprocess.tryKill(@backingInt(bun.SignalCode.SIGTERM));
                    subprocess.deinit();
                    return error.OutOfMemory;
                }
                const sys_err = err.toShellSystemError();
                _ = subprocess.tryKill(@backingInt(bun.SignalCode.SIGTERM));
                subprocess.deinit();
                return .{ .err = .{ .sys = sys_err } };
            }
            if (!spawn_args.lazy and subprocess.stdout == .pipe) {
                subprocess.stdout.pipe.readAll();
            }
        }

        if (subprocess.stderr == .pipe) {
            if (subprocess.stderr.pipe.start(subprocess, scheduler).asErr()) |err| {
                if (err.getErrno() == .NOMEM) {
                    _ = subprocess.tryKill(@backingInt(bun.SignalCode.SIGTERM));
                    subprocess.deinit();
                    return error.OutOfMemory;
                }
                const sys_err = err.toShellSystemError();
                _ = subprocess.tryKill(@backingInt(bun.SignalCode.SIGTERM));
                subprocess.deinit();
                return .{ .err = .{ .sys = sys_err } };
            }

            if (!spawn_args.lazy and subprocess.stderr == .pipe) {
                subprocess.stderr.pipe.readAll();
            }
        }

        log("returning", .{});

        return .{ .result = {} };
    }

    pub fn wait(this: *@This(), sync: bool) void {
        return this.process.wait(sync);
    }

    pub fn onProcessExit(this: *@This(), _: *Process, status: bun.spawn.Status, _: *const bun.spawn.Rusage) void {
        log("onProcessExit({x}, {f})", .{ @intFromPtr(this), status });
        const exit_code: ?u8 = brk: {
            if (status == .exited) {
                break :brk status.exited.code;
            }

            if (status == .err) {
                // TODO: handle error
            }

            if (status == .signaled) {
                if (status.signalCode()) |code| {
                    break :brk code.toExitCode().?;
                }
            }

            break :brk null;
        };

        if (exit_code) |code| {
            const cmd = this.cmd_parent;
            if (cmd.exit_code == null) {
                cmd.onExit(code);
            }
        }
    }
};

pub const PipeReader = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    reader: IOReader = undefined,
    process: ?*ShellSubprocess = null,
    scheduler: sh.Scheduler = undefined,
    state: union(enum) {
        pending: void,
        done: []u8,
        err: ?bun.sys.SystemError,
    } = .{ .pending = {} },
    stdio_result: StdioResult,
    started: bool = false,
    out_type: bun.shell.subproc.ShellSubprocess.OutKind,
    captured_writer: CapturedWriter = .{},
    buffered_output: BufferedOutput = .{ .bytelist = .{} },
    ref_count: RefCount,

    const BufferedOutput = union(enum) {
        bytelist: bun.ByteList,
        leased_bytes: struct {
            buf: bun.bindgen.OwnedMutableLease(u8),
            i: usize = 0,
        },

        pub inline fn len(this: *BufferedOutput) usize {
            return switch (this.*) {
                .bytelist => this.bytelist.len,
                .leased_bytes => this.leased_bytes.i,
            };
        }

        pub fn slice(this: *BufferedOutput) []const u8 {
            return switch (this.*) {
                .bytelist => this.bytelist.slice(),
                .leased_bytes => "",
            };
        }

        pub fn append(this: *BufferedOutput, bytes: []const u8) void {
            switch (this.*) {
                .bytelist => {
                    bun.handleOom(this.bytelist.appendSlice(bun.default_allocator, bytes));
                },
                .leased_bytes => {
                    const offset = this.leased_bytes.i;
                    const capacity = this.leased_bytes.buf.length();
                    if (offset >= capacity) return;
                    const length = @min(capacity - offset, bytes.len);
                    bun.assert(this.leased_bytes.buf.write(offset, bytes[0..length]));
                    this.leased_bytes.i += length;
                },
            }
        }

        pub fn deinit(this: *BufferedOutput) void {
            switch (this.*) {
                .bytelist => {
                    this.bytelist.deinit(bun.default_allocator);
                },
                .leased_bytes => this.leased_bytes.buf.deinit(),
            }
        }
    };

    pub const CapturedWriter = struct {
        dead: bool = true,
        writer: *sh.IOWriter = undefined,
        written: usize = 0,
        err: ?bun.sys.SystemError = null,

        pub fn doWrite(this: *CapturedWriter, chunk: []const u8) void {
            if (this.dead or this.err != null) return;

            log("CapturedWriter(0x{x}, {s}) doWrite len={d} parent_amount={d}", .{ @intFromPtr(this), @tagName(this.parent().out_type), chunk.len, this.parent().buffered_output.len() });
            this.writer.enqueue(this, null, chunk).run();
        }

        pub fn getBuffer(this: *CapturedWriter) []const u8 {
            const p = this.parent();
            if (this.written >= p.reader.buffer().items.len) return "";
            return p.reader.buffer().items[this.written..];
        }

        pub fn loop(this: *CapturedWriter) *bun.Async.Loop {
            return this.parent().scheduler.platformLoop();
        }

        pub fn parent(this: *CapturedWriter) *PipeReader {
            return @fieldParentPtr("captured_writer", this);
        }

        pub fn eventLoop(this: *CapturedWriter) sh.Scheduler {
            return this.parent().eventLoop();
        }

        pub fn isDone(this: *CapturedWriter, just_written: usize) bool {
            log("CapturedWriter(0x{x}, {s}) isDone(has_err={}, parent_state={s}, written={d}, parent_amount={d})", .{ @intFromPtr(this), @tagName(this.parent().out_type), this.err != null, @tagName(this.parent().state), this.written, this.parent().buffered_output.len() });
            if (this.dead or this.err != null) return true;
            const p = this.parent();
            if (p.state == .pending) return false;
            return this.written + just_written >= this.parent().buffered_output.len();
        }

        pub fn onIOWriterChunk(this: *CapturedWriter, amount: usize, err: ?bun.sys.SystemError) Yield {
            log("CapturedWriter({x}, {s}) onWrite({d}, has_err={}) total_written={d} total_to_write={d}", .{ @intFromPtr(this), @tagName(this.parent().out_type), amount, err != null, this.written + amount, this.parent().buffered_output.len() });
            this.written += amount;
            if (err) |e| {
                log("CapturedWriter(0x{x}, {s}) onWrite errno={d} errmsg={f} errfd={} syscall={f}", .{ @intFromPtr(this), @tagName(this.parent().out_type), e.errno, e.message, e.fd, e.syscall });
                this.err = e;
                return this.parent().trySignalDoneToCmd();
            } else if (this.written >= this.parent().buffered_output.len() and !(this.parent().state == .pending)) {
                return this.parent().trySignalDoneToCmd();
            }
            return .suspended;
        }

        pub fn onError(this: *CapturedWriter, err: bun.sys.Error) void {
            this.err = err;
        }

        pub fn onClose(this: *CapturedWriter) void {
            log("CapturedWriter({x}, {s}) onClose()", .{ @intFromPtr(this), @tagName(this.parent().out_type) });
            this.parent().onCapturedWriterDone();
        }

        pub fn deinit(this: *CapturedWriter) void {
            if (this.err) |e| {
                this.err = null;
                e.deref();
            }
            this.writer.deref();
        }
    };

    pub const IOReader = bun.io.BufferedReader;
    pub const Poll = IOReader;

    pub fn detach(this: *PipeReader) void {
        log("PipeReader(0x{x}, {s}) detach()", .{ @intFromPtr(this), @tagName(this.out_type) });
        this.process = null;
        this.deref();
    }

    pub fn isDone(this: *PipeReader) bool {
        log("PipeReader(0x{x}, {s}) isDone() state={s} captured_writer_done={}", .{ @intFromPtr(this), @tagName(this.out_type), @tagName(this.state), this.captured_writer.isDone(0) });
        if (this.state == .pending) return false;
        return this.captured_writer.isDone(0);
    }

    pub fn onCapturedWriterDone(this: *PipeReader) void {
        this.trySignalDoneToCmd().run();
    }

    pub fn create(scheduler: sh.Scheduler, process: *ShellSubprocess, result: *StdioResult, capture: ?*sh.IOWriter, out_type: bun.shell.Subprocess.OutKind) bun.OOM!*PipeReader {
        const this = try bun.default_allocator.create(PipeReader);
        this.* = .{
            .ref_count = .init(),
            .process = process,
            .reader = IOReader.init(@This()),
            .scheduler = scheduler,
            .stdio_result = result.take(),
            .out_type = out_type,
        };
        log("PipeReader(0x{x}, {s}) create()", .{ @intFromPtr(this), @tagName(this.out_type) });

        if (capture) |cap| {
            this.captured_writer.writer = cap.dupeRef();
            this.captured_writer.dead = false;
        }

        this.reader.setParent(this);

        return this;
    }

    pub fn readAll(this: *PipeReader) void {
        if (this.state == .pending)
            this.reader.read();
    }

    pub fn start(this: *PipeReader, process: *ShellSubprocess, scheduler: sh.Scheduler) bun.sys.Maybe(void) {
        bun.assert(!this.started);
        this.started = true;
        this.ref();
        defer this.deref();
        this.process = process;
        this.scheduler = scheduler;
        if (Environment.isWindows) {
            this.reader.source = switch (this.stdio_result) {
                .buffer => |pipe| .{ .pipe = pipe },
                .buffer_fd => |fd| switch (bun.io.Source.open(this.loop(), fd)) {
                    .result => |source| source,
                    .err => |err| return .{ .err = err },
                },
                .unavailable => unreachable,
            };
            _ = this.stdio_result.take();
            return this.reader.startWithCurrentPipe();
        }

        switch (this.reader.start(this.stdio_result.takeOwnedFd().?, true)) {
            .err => |err| {
                return .{ .err = err };
            },
            .result => {
                if (this.state != .pending) return .success;
                if (comptime Environment.isPosix) {
                    // TODO: are these flags correct
                    const poll = this.reader.handle.poll;
                    poll.flags.insert(.socket);
                    this.reader.flags.socket = true;
                }

                return .success;
            },
        }
    }

    pub fn onReadChunk(ptr: *anyopaque, chunk: []const u8, has_more: bun.io.ReadState) bool {
        var this: *PipeReader = @ptrCast(@alignCast(ptr));
        this.buffered_output.append(chunk);
        log("PipeReader(0x{x}, {s}) onReadChunk(chunk_len={d}, has_more={s})", .{ @intFromPtr(this), @tagName(this.out_type), chunk.len, @tagName(has_more) });

        this.captured_writer.doWrite(chunk);

        const should_continue = has_more != .eof;

        if (should_continue and bun.Environment.isPosix) this.reader.registerPoll();

        return should_continue;
    }

    pub fn onReaderDone(this: *PipeReader) void {
        log("onReaderDone(0x{x}, {s})", .{ @intFromPtr(this), @tagName(this.out_type) });
        const owned = this.toOwnedSlice();
        this.state = .{ .done = owned };
        if (!this.isDone()) return;
        // we need to ref because the process might be done and deref inside signalDoneToCmd and we wanna to keep it alive to check this.process
        this.ref();
        defer this.deref();
        this.trySignalDoneToCmd().run();

        if (this.process) |process| {
            // this.process = null;
            process.onCloseIO(this.kind(process));
            this.deref();
        }
    }

    pub fn trySignalDoneToCmd(
        this: *PipeReader,
    ) Yield {
        if (!this.isDone()) return .suspended;
        log("signalDoneToCmd ({x}: {s}) isDone={}", .{ @intFromPtr(this), @tagName(this.out_type), this.isDone() });
        if (bun.Environment.allow_assert) assert(this.process != null);
        if (this.process) |proc| {
            const cmd = proc.cmd_parent;
            if (this.captured_writer.err) |e| {
                // Transfer ownership of the error out of captured_writer so
                // PipeReader.deinit doesn't deref the same SystemError twice.
                this.captured_writer.err = null;
                if (this.state == .done) bun.default_allocator.free(this.state.done);
                if (this.state != .err) {
                    this.state = .{ .err = e };
                } else {
                    e.deref();
                }
            }
            const e: ?bun.sys.SystemError = brk: {
                if (this.state != .err) break :brk null;
                if (this.state.err) |*e| {
                    e.ref();
                    break :brk e.*;
                }
                break :brk null;
            };
            return cmd.bufferedOutputClose(this.out_type, e);
        }
        return .suspended;
    }

    pub fn kind(reader: *const PipeReader, process: *const ShellSubprocess) StdioKind {
        if (process.stdout == .pipe and process.stdout.pipe == reader) {
            return .stdout;
        }

        if (process.stderr == .pipe and process.stderr.pipe == reader) {
            return .stderr;
        }

        @panic("We should be either stdout or stderr");
    }

    pub fn takeBuffer(this: *PipeReader) std.array_list.Managed(u8) {
        return this.reader.takeBuffer();
    }

    pub fn slice(this: *PipeReader) []const u8 {
        return this.buffered_output.slice();
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

    pub fn onReaderError(this: *PipeReader, err: bun.sys.Error) void {
        log("PipeReader(0x{x}) onReaderError {f}", .{ @intFromPtr(this), err });
        if (this.state == .done) {
            bun.default_allocator.free(this.state.done);
        }
        this.state = .{ .err = err.toSystemError() };
        // we need to ref because the process might be done and deref inside signalDoneToCmd and we wanna to keep it alive to check this.process
        this.ref();
        defer this.deref();
        this.trySignalDoneToCmd().run();
        if (this.process) |process| {
            // this.process = null;
            process.onCloseIO(this.kind(process));
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

    pub fn eventLoop(this: *PipeReader) sh.Scheduler {
        return this.scheduler;
    }

    pub fn loop(this: *PipeReader) *bun.Async.Loop {
        return this.scheduler.platformLoop();
    }

    fn deinit(this: *PipeReader) void {
        log("PipeReader(0x{x}, {s}) deinit()", .{ @intFromPtr(this), @tagName(this.out_type) });
        if (this.state == .done) {
            bun.default_allocator.free(this.state.done);
        }

        if (!this.captured_writer.dead) {
            this.captured_writer.deinit();
        }

        if (this.state == .err) {
            if (this.state.err) |e| {
                e.deref();
                this.state.err = null;
            }
        }

        this.buffered_output.deinit();

        this.stdio_result.deinit();
        this.reader.deinit();
        bun.destroy(this);
    }
};

pub const StdioKind = enum {
    stdin,
    stdout,
    stderr,
};

pub inline fn assertStdioResult(result: StdioResult) void {
    if (comptime Environment.allow_assert) {
        if (Environment.isPosix) {
            if (result != .unavailable) assert(result.fd() != bun.invalid_fd);
        }
    }
}

const std = @import("std");
const util = @import("./util.zig");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const strings = bun.strings;

const sh = bun.shell;
const Yield = bun.shell.Yield;
const StdioModule = @import("./Stdio.zig");
