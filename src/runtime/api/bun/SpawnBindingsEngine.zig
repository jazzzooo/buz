const SetupFailure = union(enum) {
    system: bun.bindgen.SystemError,
    thrown: bun.bindgen.Root,
    failure: bun.JSError,
    consumed,

    fn fromFailure(context: anytype, failure: bun.JSError) SetupFailure {
        if (failure != error.JSError) return .{ .failure = failure };
        var thrown = context.takeThrownValue(failure) catch |err| return .{ .failure = err };
        defer thrown.deinit();
        return .{ .thrown = thrown.toRoot() catch |err| return .{ .failure = err } };
    }

    fn fromSysError(err: bun.sys.Error) SetupFailure {
        if (err.getErrno() == .NOMEM) return .{ .failure = error.OutOfMemory };
        return .{ .system = bun.bindgen.SystemError.fromSysError(err) catch |failure| return .{ .failure = failure } };
    }

    fn deinit(this: *SetupFailure) void {
        switch (this.*) {
            .system => |*err| err.deinit(),
            .thrown => |*root| root.deinit(),
            .failure, .consumed => {},
        }
        this.* = .consumed;
    }

    fn raise(this: *SetupFailure, context: anytype) bun.bindgen.CallError(@TypeOf(context)) {
        return switch (this.*) {
            .system => |err| failure: {
                this.* = .consumed;
                break :failure context.fail(.system, err);
            },
            .thrown => |*root| root.throwException(context),
            .failure => |err| err,
            .consumed => @panic("subprocess setup failure was consumed twice"),
        };
    }
};

fn failInvalidSpawnArgument(context: anytype, comptime fmt: []const u8, args: anytype) bun.bindgen.CallError(@TypeOf(context)) {
    const message = try std.fmt.allocPrint(bun.default_allocator, fmt, args);
    defer bun.default_allocator.free(message);
    return context.fail(.invalid_argument_value, try bun.bindgen.DOMString.fromUTF8(message));
}

fn failCommandNotFound(context: anytype, command: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    const message = try std.fmt.allocPrint(bun.default_allocator, "Executable not found in $PATH: \"{s}\"", .{command});
    defer bun.default_allocator.free(message);
    return context.fail(.command_not_found, try bun.bindgen.SystemError.init(.{
        .errno = -bun.sys.UV_E.NOENT,
        .code = "ENOENT",
        .message = message,
        .path = command,
    }));
}

/// `argv` for `Bun.spawn` & `Bun.spawnSync`, from the converted command
/// sequence.
fn getArgv(
    context: anytype,
    commands: anytype,
    PATH: []const u8,
    cwd: []const u8,
    argv0: *?[*:0]const u8,
    allocator: std.mem.Allocator,
    argv: *std.array_list.Managed(?[*:0]const u8),
) bun.bindgen.CallError(@TypeOf(context))!void {
    if (commands.len() == 0) {
        return context.fail(.empty_cmd, {});
    }

    bun.assert(commands.len() <= std.math.maxInt(u32) - 2);

    // + 1 for argv0
    // + 1 for null terminator
    argv.* = try @TypeOf(argv.*).initCapacity(allocator, commands.len() + 2);

    const arg0_utf8 = try commands.at(0).?.toUTF8(bun.default_allocator);
    defer arg0_utf8.deinit();
    const argv0_result = SpawnArguments.resolveArgv0(PATH, cwd, argv0.*, arg0_utf8.slice(), allocator) catch |err| switch (err) {
        error.InvalidArgumentValue => return failInvalidSpawnArgument(
            context,
            "The argument 'args[0]' must be a string without null bytes. Received {f}",
            .{bun.fmt.quote(arg0_utf8.slice())},
        ),
        error.CommandNotFound => return failCommandNotFound(context, arg0_utf8.slice()),
        error.OutOfMemory => return error.OutOfMemory,
    };

    argv0.* = argv0_result.executable.ptr;
    try argv.append(argv0_result.argument.ptr);

    for (1..commands.len()) |arg_index| {
        const arg = commands.at(arg_index).?;
        const utf8 = try arg.toUTF8(bun.default_allocator);
        defer utf8.deinit();
        if (std.mem.indexOfScalar(u8, utf8.slice(), 0) != null) {
            return failInvalidSpawnArgument(
                context,
                "The argument 'args[{d}]' must be a string without null bytes. Received \"{s}\"",
                .{ arg_index, utf8.slice() },
            );
        }

        try argv.append((try allocator.dupeSentinel(u8, utf8.slice(), 0)).ptr);
    }
}

fn applyStdioValue(globalThis: *jsc.JSGlobalObject, context: anytype, slot: *Stdio, i: i32, element: anytype, is_sync: bool) bun.bindgen.CallError(@TypeOf(context))!void {
    if (element.* == .undefined) return;
    var replacement: Stdio = .ignore;
    errdefer replacement.deinit();
    try convertStdioValue(globalThis, context, &replacement, i, element, is_sync);
    if (i > 2 and replacement == .blob and !replacement.blob.needsToReadFile()) {
        return Stdio.failExtraResource(context, "Blob", i);
    }
    slot.deinit();
    slot.* = replacement;
}

fn convertStdioValue(globalThis: *jsc.JSGlobalObject, context: anytype, slot: *Stdio, i: i32, element: anytype, is_sync: bool) bun.bindgen.CallError(@TypeOf(context))!void {
    switch (element.*) {
        .name => |name| slot.* = switch (name) {
            .inherit => Stdio{ .inherit = {} },
            .ignore => Stdio{ .ignore = {} },
            .pipe => Stdio{ .pipe = {} },
            .ipc => Stdio{ .ipc = {} },
        },
        .fd => |descriptor| {
            const fd = bun.FD.fromUV(descriptor);
            if (fd.stdioTag()) |tag| switch (tag) {
                .std_in => {
                    if (i == 1 or i == 2) return context.fail(.stdio_stdin_misused, {});
                    slot.* = .inherit;
                    return;
                },
                .std_out, .std_err => {
                    if (i == 0) return context.fail(.stdio_out_misused, {});
                    if ((i == 1 and tag == .std_out) or (i == 2 and tag == .std_err)) {
                        slot.* = .inherit;
                        return;
                    }
                },
            };
            slot.* = .{ .fd = fd };
        },
        .invalid_boolean => return context.fail(.stdio_invalid_value, {}),
        .nulled => slot.* = Stdio{ .ignore = {} },
        .undefined => {},
        .blob => |*view| if (slot.assignBlob(.{ .Blob = try view.get().dupe() }, i)) |err| return Stdio.failConfiguration(context, err),
        .request => |*handle| try Stdio.extractBodyValue(slot, globalThis, context, i, handle.get(jsc.WebCore.Request).getBodyValue(), is_sync),
        .response => |*handle| try Stdio.extractBodyValue(slot, globalThis, context, i, handle.get(jsc.WebCore.Response).getBodyValue(), is_sync),
        .stream => |stream| try Stdio.extractReadableStreamValue(slot, globalThis, context, i, stream, is_sync),
        .buffer => |buffer| {
            if (i != 0) return context.fail(.stdio_buffer_output, {});
            var retained = try buffer.toOwned();
            if (retained.length() == 0) {
                retained.deinit();
                slot.* = .ignore;
                return;
            }
            slot.* = .{ .retained_bytes = retained };
        },
        .invalid => return context.fail(.stdio_invalid_value, {}),
    }
}

/// Bun.spawn() calls this.
pub fn spawn(
    context: bun.bindgen.CallContext(SpawnSchema),
    args: bun.bindgen.Args(SpawnSchema),
) bun.bindgen.CallError(SpawnSchema)!bun.bindgen.Return(SpawnSchema) {
    return spawnFromBinding(false, context, args);
}

/// Bun.spawnSync() calls this.
pub fn spawnSync(
    context: bun.bindgen.CallContext(SpawnSyncSchema),
    args: bun.bindgen.Args(SpawnSyncSchema),
) bun.bindgen.CallError(SpawnSyncSchema)!bun.bindgen.Return(SpawnSyncSchema) {
    return spawnFromBinding(true, context, args);
}

pub fn spawnFromBinding(
    comptime is_sync: bool,
    context: anytype,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return spawnMaybeSync(is_sync, globalThis, context, args);
}

fn spawnMaybeSync(
    comptime is_sync: bool,
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!SpawnResult(is_sync) {
    if (comptime is_sync) {
        // We skip this on Windows due to test failures.
        if (comptime !Environment.isWindows) {
            // Since the event loop is recursively called, we need to check if it's safe to recurse.
            if (!bun.StackCheck.init().isSafeToRecurse()) {
                context.engineIn("errors", "throwStackOverflow").call(.{}) catch |err| return err;
                unreachable;
            }
        }
    }

    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var override_env = false;
    var env_array = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    var jsc_vm = globalThis.bunVM();

    var cwd = jsc_vm.transpiler.fs.top_level_dir;

    var stdio = [3]Stdio{
        .{ .ignore = {} },
        .{ .pipe = {} },
        .{ .inherit = {} },
    };
    defer for (&stdio) |*io| io.deinit();

    if (comptime is_sync) {
        stdio[1] = .{ .pipe = {} };
        stdio[2] = .{ .pipe = {} };
    }
    var lazy = false;
    var on_exit_callback: ?SpawnOnExitCallback = null;
    defer if (on_exit_callback) |*callback| callback.deinit();
    var on_disconnect_callback: ?SpawnOnDisconnectCallback = null;
    defer if (on_disconnect_callback) |*callback| callback.deinit();
    var PATH = jsc_vm.transpiler.env.get("PATH") orelse "";
    var argv = std.array_list.Managed(?[*:0]const u8).init(allocator);
    var detached = false;
    var maybe_ipc_mode: if (is_sync) void else ?IPC.Mode = if (is_sync) {} else null;
    var ipc_callback: ?SpawnIPCCallback = null;
    defer if (ipc_callback) |*callback| callback.deinit();
    var extra_fds = std.array_list.Managed(bun.spawn.SpawnOptions.Stdio).init(bun.default_allocator);
    var owns_extra_fds = true;
    defer {
        if (comptime Environment.isWindows) {
            if (owns_extra_fds) for (extra_fds.items) |*option| option.deinit();
        }
        extra_fds.deinit();
    }
    var extra_stdio = std.array_list.Managed(Stdio).init(bun.default_allocator);
    defer {
        for (extra_stdio.items) |*io| io.deinit();
        extra_stdio.deinit();
    }
    var argv0: ?[*:0]const u8 = null;
    var ipc_channel: i32 = -1;
    var timeout: ?i64 = null;
    var killSignal: SignalCode = SignalCode.default;
    var maxBuffer: ?i64 = null;

    var windows_hide: bool = false;
    var windows_verbatim_arguments: bool = false;
    var abort_signal: ?*jsc.WebCore.AbortSignal = null;
    var terminal_info: ?Terminal.CreateResult = null;
    var existing_terminal: ?*Terminal = null; // Existing terminal passed by user
    var terminal_reference: ?Terminal.Ref = null;
    defer {
        if (abort_signal) |signal| {
            signal.unref();
        }
        // If we created a new terminal but spawn failed, close it. The
        // writer/reader/finalizer deref paths release the remaining refs.
        // Suppress the exit callback because the user never received this
        // terminal when spawn threw.
        if (terminal_info) |*info| {
            info.terminal.abortCreation();
            info.reference.deinit();
        }
        if (terminal_reference) |*reference| reference.deinit();
    }

    const commands_argument = args.commands orelse return context.fail(.missing_cmd, {});
    var command_input = if (comptime !is_sync)
        commands_argument
    else if (args.options != null)
        (try commands_argument.convert(context)).value
    else commands: {
        const forced = try commands_argument.convertLast(context);
        try context.lease(forced.proof);
        break :commands forced.converted.value;
    };

    var secondary_converted = secondary: {
        const options_argument = args.options orelse break :secondary null;
        if (command_input != .commands) {
            try context.lease(try options_argument.discardLast(context));
            break :secondary null;
        }
        const forced = try options_argument.convertLast(context);
        try context.lease(forced.proof);
        break :secondary forced.converted;
    };

    var commands: ?*@TypeOf(command_input.commands) = null;
    const options: ?*@TypeOf(command_input.options) = resolve: {
        switch (command_input) {
            .commands => |*list| {
                commands = list;
                if (secondary_converted) |*converted| switch (converted.value) {
                    .options => |*resolved| break :resolve resolved,
                    .ignored => {},
                };
                break :resolve null;
            },
            .options => |*resolved| break :resolve resolved,
            .invalid => return context.fail(.missing_cmd, {}),
        }
    };

    if (options) |resolved_options| {
        if (resolved_options.argv0) |*argv0_text| {
            if (argv0_text.length() > 0) {
                const utf8 = try argv0_text.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                if (std.mem.indexOfScalar(u8, utf8.slice(), 0) != null) {
                    return failInvalidSpawnArgument(
                        context,
                        "The property 'options.argv0' must be a string without null bytes. Received {f}",
                        .{bun.fmt.quote(utf8.slice())},
                    );
                }
                argv0 = (try allocator.dupeSentinel(u8, utf8.slice(), 0)).ptr;
            }
        }

        // need to update `cwd` before searching for executable with `Which.which`
        if (resolved_options.cwd) |*cwd_text| {
            if (cwd_text.length() > 0) {
                const utf8 = try cwd_text.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                if (std.mem.indexOfScalar(u8, utf8.slice(), 0) != null) {
                    return failInvalidSpawnArgument(
                        context,
                        "The property 'options.cwd' must be a string without null bytes. Received {f}",
                        .{bun.fmt.quote(utf8.slice())},
                    );
                }
                cwd = try allocator.dupeSentinel(u8, utf8.slice(), 0);
            }
        }

        // Reject terminal option on spawnSync
        if (comptime is_sync) {
            if (resolved_options.terminal) |field| {
                if (field != null) return context.fail(.sync_terminal_unsupported, {});
            }
        }

        if (comptime !is_sync) {
            if (resolved_options.ipc) |*ipc_field| switch (ipc_field.*) {
                .callback => |*callback| {
                    maybe_ipc_mode = ipc_mode: {
                        if (resolved_options.serialization) |*serialization_field| switch (serialization_field.*) {
                            .mode => |mode| break :ipc_mode switch (mode) {
                                .json => .json,
                                .advanced => .advanced,
                            },
                            .invalid => return context.fail(.invalid_serialization, {}),
                        };
                        break :ipc_mode .advanced;
                    };

                    ipc_callback = try callback.toOwned();
                },
                .nulled, .invalid => {},
            };
        }

        if (resolved_options.signal) |*signal_field| switch (signal_field.*) {
            .signal => |*signal_ref| abort_signal = signal_ref.get().ref(),
            .nulled => {},
            .invalid => return context.fail(.invalid_signal, {}),
        };

        if (resolved_options.onDisconnect) |*callback_field| switch (callback_field.*) {
            .callback => |*callback| {
                on_disconnect_callback = try callback.toOwned();
            },
            .nulled => {},
            .invalid => return context.fail(.invalid_on_disconnect, {}),
        };

        if (resolved_options.onExit) |*callback_field| switch (callback_field.*) {
            .callback => |*callback| {
                on_exit_callback = try callback.toOwned();
            },
            .nulled => {},
            .invalid => return context.fail(.invalid_on_exit, {}),
        };

        if (resolved_options.env) |*env_record| {
            override_env = true;
            // If the env object does not include a $PATH, it must disable path lookup for argv[0]
            var NEW_PATH: []const u8 = "";
            var envp_managed = env_array.toManaged(allocator);
            try appendEnvpFromSchema(context, env_record, &envp_managed, &NEW_PATH);
            env_array = envp_managed.moveToUnmanaged();
            PATH = NEW_PATH;
        }

        const command_list = commands orelse
            (if (resolved_options.cmd) |*list| list else return context.fail(.missing_cmd, {}));
        try getArgv(context, command_list, PATH, cwd, &argv0, allocator, &argv);

        if (resolved_options.stdio) |*stdio_field| switch (stdio_field.*) {
            .list => |*list| {
                for (0..list.len()) |index| {
                    const i: u31 = @intCast(index);
                    const element = list.at(index).?;
                    if (i <= 2) {
                        try applyStdioValue(globalThis, context, &stdio[i], i, &element, is_sync);
                    } else {
                        try extra_fds.ensureUnusedCapacity(1);
                        try extra_stdio.ensureUnusedCapacity(1);
                        var new_item: Stdio = .{ .ignore = {} };
                        defer new_item.deinit();
                        try applyStdioValue(globalThis, context, &new_item, i, &element, is_sync);

                        const opt = switch (new_item.asSpawnOption(i)) {
                            .result => |opt| opt,
                            .err => |err| return Stdio.failConfiguration(context, err),
                        };
                        if (opt == .ipc) {
                            ipc_channel = @intCast(extra_fds.items.len);
                        }
                        extra_fds.appendAssumeCapacity(opt);
                        extra_stdio.appendAssumeCapacity(new_item);
                        new_item = .ignore;
                    }
                }
            },
            .nulled => {},
            .invalid => return context.fail(.invalid_stdio, {}),
        };

        if (resolved_options.stdin) |*value| try applyStdioValue(globalThis, context, &stdio[0], 0, value, is_sync);
        if (resolved_options.stderr) |*value| try applyStdioValue(globalThis, context, &stdio[2], 2, value, is_sync);
        if (resolved_options.stdout) |*value| try applyStdioValue(globalThis, context, &stdio[1], 1, value, is_sync);

        if (comptime !is_sync) {
            if (resolved_options.lazy) |field| {
                if (field) |flag| lazy = flag;
            }
        }

        if (resolved_options.detached) |field| {
            if (field) |flag| detached = flag;
        }

        if (Environment.isWindows) {
            if (resolved_options.windowsHide) |field| {
                if (field) |flag| windows_hide = flag;
            }

            if (resolved_options.windowsVerbatimArguments) |field| {
                if (field) |flag| windows_verbatim_arguments = flag;
            }
        }

        if (resolved_options.timeout orelse null) |timeout_value| switch (timeout_value) {
            .milliseconds => |milliseconds| {
                if (milliseconds > 0) timeout = @intCast(milliseconds);
            },
            .infinite => {},
        };

        if (resolved_options.killSignal) |signal_value| {
            killSignal = @fromBackingInt(signal_value);
        }

        if (resolved_options.maxBuffer) |*field| switch (field.*) {
            .bytes => |count| {
                if (count > 0 and (stdio[0].isPiped() or stdio[1].isPiped() or stdio[2].isPiped())) {
                    maxBuffer = count;
                }
            },
            .infinite, .ignored => {},
        };

        if (comptime !is_sync) {
            if (resolved_options.terminal) |*field| {
                if (field.*) |*terminal_input| {
                    switch (terminal_input.*) {
                        .terminal => |*handle| {
                            const terminal = handle.get(Terminal.JSBinding).terminal.get();
                            if (terminal.flags.closed) {
                                return context.fail(.terminal_closed, {});
                            }
                            if (terminal.flags.inline_spawned) {
                                return context.fail(.terminal_already_used, {});
                            }
                            if (comptime Environment.isPosix) {
                                if (terminal.slave_fd == bun.invalid_fd) {
                                    return context.fail(.terminal_slave_invalid, {});
                                }
                            } else if (terminal.getPseudoconsole() == null) {
                                return context.fail(.terminal_pseudoconsole_invalid, {});
                            }
                            existing_terminal = terminal;
                            terminal_reference = try handle.toOwned();
                        },
                        .options => |*generated_options| {
                            // Create a new terminal from options
                            var term_options = try Terminal.Options.fromBindgen(generated_options);
                            defer term_options.deinit();
                            terminal_info = Terminal.createFromSpawn(globalThis, &term_options) catch |err| {
                                return switch (err) {
                                    error.OpenPtyFailed => context.fail(.terminal_open_failed, {}),
                                    error.DupFailed => context.fail(.terminal_dup_failed, {}),
                                    error.NotSupported => context.fail(.terminal_not_supported, {}),
                                    error.WriterStartFailed => context.fail(.terminal_writer_failed, {}),
                                    error.ReaderStartFailed => context.fail(.terminal_reader_failed, {}),
                                    error.JSError, error.JSTerminated, error.OutOfMemory => |js_error| js_error,
                                };
                            };
                        },
                        .invalid => return context.fail(.invalid_terminal, {}),
                    }

                    for (&stdio) |*io| io.deinit();
                    if (comptime Environment.isPosix) {
                        const terminal = existing_terminal orelse terminal_info.?.terminal;
                        const slave_fd = terminal.getSlaveFd();
                        stdio[0] = .{ .fd = slave_fd };
                        stdio[1] = .{ .fd = slave_fd };
                        stdio[2] = .{ .fd = slave_fd };
                    } else {
                        // On Windows, ConPTY supplies stdio via PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.
                        // Set stdio to .ignore so spawnProcessWindows doesn't allocate pipes.
                        stdio[0] = .ignore;
                        stdio[1] = .ignore;
                        stdio[2] = .ignore;
                        // ConPTY spawns with bInheritHandles=FALSE and no stdio buffer,
                        // so extra fds and IPC pipes can't be passed to the child.
                        if (maybe_ipc_mode != null or extra_fds.items.len > 0) {
                            return context.fail(.terminal_extra_stdio_windows, {});
                        }
                    }
                }
            }
        }
    } else {
        try getArgv(context, commands.?, PATH, cwd, &argv0, allocator, &argv);
    }

    log("spawn maxBuffer: {?d}", .{maxBuffer});

    if (!override_env and env_array.items.len == 0) {
        env_array.items = try jsc_vm.transpiler.env.map.createNullDelimitedEnvMap(allocator);
        env_array.capacity = env_array.items.len + 1;
    }

    inline for (0..stdio.len) |fd_index| {
        if (stdio[fd_index].canUseMemfd(is_sync, fd_index > 0 and maxBuffer != null)) {
            if (stdio[fd_index].useMemfd(fd_index)) {
                jsc_vm.counters.mark(.spawn_memfd);
            }
        }
    }
    //"NODE_CHANNEL_FD=" is 16 bytes long, 15 bytes for the number, and 1 byte for the null terminator should be enough/safe
    var ipc_env_buf: [32]u8 = undefined;
    if (!is_sync) if (maybe_ipc_mode) |ipc_mode| {
        try env_array.ensureUnusedCapacity(allocator, 3);
        const ipc_fd: i32 = brk: {
            if (ipc_channel == -1) {
                try extra_fds.ensureUnusedCapacity(1);
                ipc_channel = @intCast(extra_fds.items.len);
                var ipc_extra_fd_default = Stdio{ .ipc = {} };
                const fd: i32 = ipc_channel + 3;
                switch (ipc_extra_fd_default.asSpawnOption(fd)) {
                    .result => |opt| {
                        extra_fds.appendAssumeCapacity(opt);
                    },
                    .err => |err| return Stdio.failConfiguration(context, err),
                }
                break :brk fd;
            } else {
                break :brk @intCast(ipc_channel + 3);
            }
        };

        const pipe_env = std.mem.printSentinel(&ipc_env_buf, "NODE_CHANNEL_FD={d}", .{ipc_fd}, 0) catch unreachable;
        env_array.appendAssumeCapacity(pipe_env);

        env_array.appendAssumeCapacity(switch (ipc_mode) {
            inline else => |t| "NODE_CHANNEL_SERIALIZATION_MODE=" ++ @tagName(t),
        });
    };

    try env_array.append(allocator, null);
    try argv.append(null);

    if (comptime is_sync) {
        for (&stdio, 0..) |*io, i| {
            io.toSync(@truncate(i));
        }
    }

    // If the whole thread is supposed to do absolutely nothing while waiting,
    // we can block the thread which reduces CPU usage.
    //
    // That means:
    // - No maximum buffer
    // - No timeout
    // - No abort signal
    // - No stdin, stdout, stderr pipes
    // - No extra fds
    // - No auto killer (for tests)
    // - No execution time limit (for tests)
    // - No IPC
    // - No inspector (since they might want to press pause or step)
    const can_block_entire_thread_to_reduce_cpu_usage_in_fast_path = (comptime Environment.isPosix and is_sync) and
        abort_signal == null and
        timeout == null and
        maxBuffer == null and
        !stdio[0].isPiped() and
        !stdio[1].isPiped() and
        !stdio[2].isPiped() and
        extra_fds.items.len == 0 and
        !jsc_vm.auto_killer.enabled and
        !jsc_vm.jsc_vm.hasExecutionTimeLimit() and
        !jsc_vm.isInspectorEnabled() and
        !bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_SPAWNSYNC_FAST_PATH.get();

    // For spawnSync, use an isolated event loop to prevent JavaScript timers from firing
    // and to avoid interfering with the main event loop
    const sync_event_loop = if (comptime is_sync) switch (try (try jsc_vm.tryRareData()).spawnSyncEventLoop(jsc_vm)) {
        .loop => |loop| loop,
        .failed => |failure| {
            const errno = failure.systemErrno() orelse .EIO;
            if (errno == .ENOMEM) return error.OutOfMemory;
            const native_errno: bun.sys.E = if (Environment.isWindows) errno.toE() else @fromBackingInt(@backingInt(errno));
            return context.fail(.system, try bun.bindgen.SystemError.fromSysError(bun.sys.Error.fromCode(native_errno, .poll)));
        },
    } else {};
    const event_loop: *jsc.EventLoop = if (comptime is_sync)
        &sync_event_loop.event_loop
    else
        jsc_vm.eventLoop();

    if (comptime is_sync) {
        sync_event_loop.prepare(jsc_vm);
    }

    defer {
        if (comptime is_sync) {
            sync_event_loop.cleanup(jsc_vm, jsc_vm.eventLoop());
        }
    }

    const loop_handle = jsc.EventLoopHandle.init(event_loop);

    const subprocess = try bun.default_allocator.create(Subprocess);
    var subprocess_initialized = false;
    var stdout_maxbuf: ?*MaxBuf = null;
    var stderr_maxbuf: ?*MaxBuf = null;
    defer if (!subprocess_initialized) {
        MaxBuf.removeFromOwner(&stdout_maxbuf);
        MaxBuf.removeFromOwner(&stderr_maxbuf);
        bun.default_allocator.destroy(subprocess);
    };
    try subprocess.createMaxBuffer(.stderr, &stderr_maxbuf, maxBuffer);
    try subprocess.createMaxBuffer(.stdout, &stdout_maxbuf, maxBuffer);

    var native_stdio: [3]bun.spawn.SpawnOptions.Stdio = .{ .ignore, .ignore, .ignore };
    var owns_native_stdio = true;
    defer if (comptime Environment.isWindows) {
        if (owns_native_stdio) for (&native_stdio) |*option| option.deinit();
    };
    inline for (0..native_stdio.len) |index| {
        native_stdio[index] = switch (stdio[index].asSpawnOption(@intCast(index))) {
            .result => |opt| opt,
            .err => |err| return Stdio.failConfiguration(context, err),
        };
    }

    const spawn_options = bun.spawn.SpawnOptions{
        .cwd = cwd,
        .detached = detached,
        .stdin = native_stdio[0],
        .stdout = native_stdio[1],
        .stderr = native_stdio[2],
        .extra_fds = extra_fds.items,
        .argv0 = argv0,
        .can_block_entire_thread_to_reduce_cpu_usage_in_fast_path = can_block_entire_thread_to_reduce_cpu_usage_in_fast_path,
        // Only pass pty_slave_fd for newly created terminals (for setsid+TIOCSCTTY setup).
        // For existing terminals, the session is already set up - child just uses the fd as stdio.
        .pty_slave_fd = if (Environment.isPosix) blk: {
            if (terminal_info) |*ti| break :blk ti.terminal.getSlaveFd().native();
            break :blk -1;
        } else {},
        .pseudoconsole = if (Environment.isWindows) blk: {
            if (existing_terminal) |t| break :blk t.getPseudoconsole();
            if (terminal_info) |*ti| break :blk ti.terminal.getPseudoconsole();
            break :blk null;
        } else {},

        .windows = if (Environment.isWindows) .{
            .hide_window = windows_hide,
            .verbatim_arguments = windows_verbatim_arguments,
            .loop = loop_handle.parentEventLoop(),
        },
    };

    owns_native_stdio = false;
    owns_extra_fds = false;
    var spawned = switch (bun.spawn.spawnProcess(
        &spawn_options,
        @ptrCast(argv.items.ptr),
        @ptrCast(env_array.items.ptr),
    ) catch |err| switch (err) {
        error.EMFILE, error.ENFILE => {
            spawn_options.deinit();
            const display_path: [:0]const u8 = if (argv.items.len > 0 and argv.items[0] != null)
                std.mem.sliceTo(argv.items[0].?, 0)
            else
                "";
            const syscall_error = bun.sys.Error.fromCode(if (err == error.EMFILE) .MFILE else .NFILE, .posix_spawn).withPath(display_path);
            var system_error = try bun.bindgen.SystemError.fromSysError(syscall_error);
            system_error.error_number = if (err == error.EMFILE) -bun.sys.UV_E.MFILE else -bun.sys.UV_E.NFILE;
            return context.fail(.system, system_error);
        },
        error.OutOfMemory => {
            spawn_options.deinit();
            return error.OutOfMemory;
        },
        else => {
            spawn_options.deinit();
            const message = try std.fmt.allocPrint(bun.default_allocator, "{s} : failed to spawn process", .{@errorName(err)});
            defer bun.default_allocator.free(message);
            return context.fail(.spawn_failed, try bun.bindgen.DOMString.fromUTF8(message));
        },
    }) {
        .err => |err| {
            spawn_options.deinit();
            switch (err.getErrno()) {
                .ACCES, .NOENT, .PERM, .ISDIR, .NOTDIR => |errno| {
                    const display_path: [:0]const u8 = if (argv.items.len > 0 and argv.items[0] != null)
                        std.mem.sliceTo(argv.items[0].?, 0)
                    else
                        "";
                    if (display_path.len > 0) {
                        var system_error = try bun.bindgen.SystemError.fromSysError(err.withPath(display_path));
                        if (errno == .NOENT) system_error.error_number = -bun.sys.UV_E.NOENT;
                        return context.fail(.system, system_error);
                    }
                },
                else => {},
            }

            return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
        },
        .result => |result| result,
    };
    defer spawned.close();

    // Use the isolated loop for spawnSync operations
    const process = spawned.toProcess(loop_handle.runtimeLoopHandle(), is_sync);

    const posix_ipc_fd = if (Environment.isPosix and !is_sync and maybe_ipc_mode != null)
        spawned.extra_pipes.items[@intCast(ipc_channel)].fd()
    else
        bun.invalid_fd;

    var stdin_is_readable_stream = false;

    // When run synchronously, subprocess isn't garbage collected
    subprocess.* = Subprocess{
        .globalThis = globalThis,
        .process = process,
        .pid_rusage = null,
        // Stdio initialization can retain and mutate the subprocess.
        .stdin = .{ .ignore = {} },
        .stdout = .{ .ignore = {} },
        .stderr = .{ .ignore = {} },
        // 1. JavaScript wrapper or synchronous caller.
        // 2. Pending asynchronous activity.
        .ref_count = .initExactRefs(2),
        .stdio_pipes = spawned.extra_pipes.moveToUnmanaged(),
        .ipc_data = if (!is_sync)
            if (maybe_ipc_mode) |ipc_mode|
                .init(ipc_mode, .{ .subprocess = subprocess }, .uninitialized)
            else
                null
        else
            null,

        .flags = .{
            .is_sync = is_sync,
        },
        .killSignal = killSignal,
        .stderr_maxbuf = stderr_maxbuf,
        .stdout_maxbuf = stdout_maxbuf,
        .terminal = existing_terminal orelse if (terminal_info) |*info| info.terminal else null,
    };
    subprocess_initialized = true;

    {
        errdefer {
            subprocess.shutdown();
            subprocess.deref();
        }
        subprocess.stdin = try Writable.init(
            context,
            &stdio[0],
            event_loop,
            subprocess,
            &spawned.stdin,
            &stdin_is_readable_stream,
        );
        subprocess.stdout = try Readable.init(
            &stdio[1],
            event_loop,
            subprocess,
            &spawned.stdout,
            jsc_vm.allocator,
            subprocess.stdout_maxbuf,
            is_sync,
        );
        subprocess.stderr = try Readable.init(
            &stdio[2],
            event_loop,
            subprocess,
            &spawned.stderr,
            jsc_vm.allocator,
            subprocess.stderr_maxbuf,
            is_sync,
        );
    }

    // For inline terminal options: close parent's slave_fd so EOF is received when child exits
    // For existing terminal: keep slave_fd open so terminal can be reused for more spawns
    if (terminal_info) |*info| {
        terminal_reference = info.reference.take();
        info.terminal.closeSlaveFd();
        subprocess.flags.owns_terminal = true;
        terminal_info = null;
    }
    // existing_terminal: don't close slave_fd - user manages lifecycle and can reuse

    subprocess.process.setExitHandler(subprocess);

    subprocess.flags.is_stdin_a_readable_stream = stdin_is_readable_stream;

    var setup_failure: ?SetupFailure = null;
    defer if (setup_failure) |*failure| failure.deinit();

    if (globalThis.hasException()) {
        setup_failure = SetupFailure.fromFailure(context, error.JSError);
        lazy = false;
        _ = subprocess.tryKill(subprocess.killSignal);
    }

    if (setup_failure == null) if (subprocess.ipc_data) |*ipc_data| {
        ipc_data.prepareVersionPacket() catch |err| {
            setup_failure = SetupFailure.fromFailure(context, err);
            lazy = false;
            _ = subprocess.tryKill(subprocess.killSignal);
        };
    };

    if (setup_failure == null and Environment.isPosix and !is_sync) {
        if (subprocess.ipc_data) |*ipc_data| ipc_setup: {
            const rare = jsc_vm.tryRareData() catch |err| {
                setup_failure = SetupFailure.fromFailure(context, err);
                lazy = false;
                _ = subprocess.tryKill(subprocess.killSignal);
                break :ipc_setup;
            };
            switch (rare.spawnIPCGroup(jsc_vm).fromFd(
                .spawn_ipc,
                null,
                @sizeOf(*IPC.SendQueue),
                posix_ipc_fd.cast(),
                true,
            )) {
                .socket => |socket| {
                    ipc_data.socket = .{ .open = IPC.Socket.from(socket) };
                    socket.ext(?*IPC.SendQueue).* = ipc_data;
                    subprocess.stdio_pipes.items[@intCast(ipc_channel)] = .unavailable;
                },
                .failed => |failure| {
                    setup_failure = if (failure.isOutOfMemory())
                        SetupFailure.fromFailure(context, error.OutOfMemory)
                    else system_failure: {
                        const errno = failure.systemErrno() orelse .EIO;
                        const native_errno: bun.sys.E = @fromBackingInt(@backingInt(errno));
                        break :system_failure SetupFailure.fromSysError(bun.sys.Error.fromCode(native_errno, .poll));
                    };
                    lazy = false;
                    _ = subprocess.tryKill(subprocess.killSignal);
                },
            }
        }
    }

    var ipc_configuration_failed = false;
    if (setup_failure == null) if (subprocess.ipc_data) |*ipc_data| {
        if (Environment.isWindows) {
            if (ipc_data.windowsConfigureServer(
                subprocess.stdio_pipes.items[@intCast(ipc_channel)].buffer,
            ).asErr()) |err| {
                setup_failure = SetupFailure.fromSysError(err);
                lazy = false;
                _ = subprocess.tryKill(subprocess.killSignal);
                ipc_configuration_failed = true;
            }
            subprocess.stdio_pipes.items[@intCast(ipc_channel)] = .unavailable;
        }
        if (!ipc_configuration_failed) ipc_data.start(globalThis);
    };
    if (ipc_configuration_failed) {
        subprocess.ipc_data.?.deinit();
        subprocess.ipc_data = null;
    } else if (setup_failure != null) {
        if (subprocess.ipc_data) |*ipc_data| ipc_data.deinit();
        subprocess.ipc_data = null;
    }

    if (subprocess.stdin == .pipe and !stdin_is_readable_stream) {
        subprocess.stdin.pipe.signal = jsc.WebCore.streams.Signal.init(&subprocess.stdin);
    }

    var out: ?Subprocess.Ref = if (comptime !is_sync)
        if (setup_failure == null)
            subprocess.toRef(globalThis) catch |err| blk: {
                setup_failure = SetupFailure.fromFailure(context, err);
                lazy = false;
                _ = subprocess.tryKill(subprocess.killSignal);
                break :blk null;
            }
        else
            null
    else
        null;
    if (out) |*out_value| {
        subprocess.wrapper = Subprocess.SubprocessClass.WeakWrapper.initRef(out_value) catch |err| failed: {
            setup_failure = SetupFailure.fromFailure(context, err);
            lazy = false;
            _ = subprocess.tryKill(subprocess.killSignal);
            break :failed .empty;
        };
    }
    defer subprocess.deref();
    defer if (out) |*out_value| out_value.deinit();

    var send_exit_notification = false;
    var reap_failed_watch = false;

    if (comptime !is_sync) {
        switch (subprocess.process.watch()) {
            .result => {},
            .err => |err| {
                send_exit_notification = true;
                lazy = false;
                if (err.getErrno() != .SRCH) {
                    if (setup_failure == null) setup_failure = SetupFailure.fromSysError(err);
                    _ = subprocess.tryKill(.SIGKILL);
                    reap_failed_watch = true;
                }
            },
        }
    }

    defer {
        if (send_exit_notification) {
            if (subprocess.process.hasExited()) {
                // process has already exited, we called wait4(), but we did not call onProcessExit()
                subprocess.process.onExit(subprocess.process.status, &std.mem.zeroes(Rusage));
            } else {
                subprocess.process.wait(is_sync or reap_failed_watch);
            }
        }
    }

    if (subprocess.stdin == .buffer) {
        if (subprocess.stdin.buffer.start().asErr()) |err| {
            lazy = false;
            _ = subprocess.tryKill(subprocess.killSignal);
            if (setup_failure == null) {
                setup_failure = SetupFailure.fromSysError(err);
            }
        }
    }

    if (subprocess.stdout == .pipe) {
        if (subprocess.stdout.pipe.start(subprocess, event_loop).asErr()) |err| {
            lazy = false;
            _ = subprocess.tryKill(subprocess.killSignal);
            if (setup_failure == null) {
                setup_failure = SetupFailure.fromSysError(err);
            }
        }
        if ((is_sync or !lazy) and subprocess.stdout == .pipe) {
            subprocess.stdout.pipe.readAll();
        }
    }

    if (subprocess.stderr == .pipe) {
        if (subprocess.stderr.pipe.start(subprocess, event_loop).asErr()) |err| {
            lazy = false;
            _ = subprocess.tryKill(subprocess.killSignal);
            if (setup_failure == null) {
                setup_failure = SetupFailure.fromSysError(err);
            }
        }

        if ((is_sync or !lazy) and subprocess.stderr == .pipe) {
            subprocess.stderr.pipe.readAll();
        }
    }

    const initialization_failed = setup_failure != null;
    if (comptime !is_sync) if (!initialization_failed) {
        const out_value = if (out) |*value| value else unreachable;
        if (on_exit_callback) |*callback| Subprocess.OnExitCallbackSlot.setOwnedCallbackOnOwned(out_value, callback);
        if (on_disconnect_callback) |*callback| Subprocess.OnDisconnectCallbackSlot.setOwnedCallbackOnOwned(out_value, callback);
        if (ipc_callback) |*callback| Subprocess.IPCCallbackSlot.setOwnedCallbackOnOwned(out_value, callback);
        if (stdio[0] == .readable_stream) {
            var stdin_stream = stdio[0].readable_stream.cloneOwned() orelse unreachable;
            defer stdin_stream.deinit();
            Subprocess.StdinSlot.setOwnedBrandedMemberOnOwned("readable_stream", out_value, &stdin_stream);
        }
        if (terminal_reference) |*terminal_ref| {
            Subprocess.TerminalSlot.setOnOwned(out_value, terminal_ref);
        }

        if (timeout) |timeout_val| {
            if (!subprocess.process.hasExited()) {
                subprocess.event_loop_timer.next = bun.timespec.msFromNow(.allow_mocked_time, timeout_val);
                globalThis.bunVM().timer.insert(&subprocess.event_loop_timer);
                subprocess.setEventLoopTimerRefd(true);
            }
        }
    };

    if (initialization_failed and subprocess.flags.owns_terminal) {
        if (subprocess.terminal) |terminal| terminal.abortCreation();
        subprocess.terminal = null;
    }

    if (!initialization_failed) if (abort_signal) |signal| {
        signal.pendingActivityRef();
        subprocess.abort_signal = signal.listen(globalThis, &subprocess.abort_listener, subprocess, Subprocess.onAbortSignal) catch |err| {
            signal.pendingActivityUnref();
            return err;
        };
        abort_signal = null;
    };

    if (comptime !is_sync) {
        if (!subprocess.process.hasExited()) {
            jsc_vm.onSubprocessSpawn(subprocess.process);
        }
        if (setup_failure) |*failure| return failure.raise(context);
        return out.?.take();
    }

    comptime bun.assert(is_sync);

    if (can_block_entire_thread_to_reduce_cpu_usage_in_fast_path) {
        jsc_vm.counters.mark(.spawnSync_blocking);
        const debug_timer = Output.DebugTimer.start();
        subprocess.process.wait(true);
        log("spawnSync fast path took {f}", .{debug_timer});

        // watchOrReap will handle the already exited case for us.
    }

    switch (subprocess.process.watchOrReap()) {
        .result => {},
        .err => |err| {
            if (setup_failure == null) setup_failure = SetupFailure.fromSysError(err);
            _ = subprocess.tryKill(.SIGKILL);
            subprocess.process.wait(true);
        },
    }

    if (!subprocess.process.hasExited()) {
        jsc_vm.onSubprocessSpawn(subprocess.process);
    }

    var did_timeout = false;

    // Use the isolated event loop to tick instead of the main event loop
    // This ensures JavaScript timers don't fire and stdin/stdout from the main process aren't affected
    {
        var absolute_timespec = bun.timespec.epoch;
        var now = bun.timespec.now(.allow_mocked_time);
        var user_timespec: bun.timespec = if (timeout) |timeout_ms| now.addMs(timeout_ms) else absolute_timespec;

        // Support `AbortSignal.timeout`, but it's best-effort.
        // Specifying both `timeout: number` and `AbortSignal.timeout` chooses the soonest one.
        // This does mean if an AbortSignal times out it will throw
        if (subprocess.abort_signal) |signal| {
            if (signal.timeoutDeadline()) |deadline| {
                if (user_timespec.eql(&.epoch) or deadline.order(&user_timespec) == .lt)
                    user_timespec = deadline;
            }
        }

        const has_user_timespec = !user_timespec.eql(&.epoch);

        const sync_loop = sync_event_loop;

        while (subprocess.computeHasPendingActivity()) {
            // Re-evaluate this at each iteration of the loop since it may change between iterations.
            const bun_test_timeout: bun.timespec = if (bun.jsc.Jest.Jest.runner) |runner| runner.getActiveTimeout() else .epoch;
            const has_bun_test_timeout = !bun_test_timeout.eql(&.epoch);

            if (has_bun_test_timeout) {
                switch (bun_test_timeout.orderIgnoreEpoch(user_timespec)) {
                    .lt => absolute_timespec = bun_test_timeout,
                    .eq => {},
                    .gt => absolute_timespec = user_timespec,
                }
            } else if (has_user_timespec) {
                absolute_timespec = user_timespec;
            } else {
                absolute_timespec = .epoch;
            }
            const has_timespec = !absolute_timespec.eql(&.epoch);

            if (subprocess.stdin == .buffer) {
                subprocess.stdin.buffer.watch();
            }

            if (subprocess.stderr == .pipe) {
                subprocess.stderr.pipe.watch();
            }

            if (subprocess.stdout == .pipe) {
                subprocess.stdout.pipe.watch();
            }

            // Tick the isolated event loop without passing timeout to avoid blocking
            // The timeout check is done at the top of the loop
            switch (sync_loop.tickWithTimeout(if (has_timespec and !did_timeout) &absolute_timespec else null)) {
                .completed => {
                    now = bun.timespec.now(.allow_mocked_time);
                },
                .timeout => {
                    now = bun.timespec.now(.allow_mocked_time);
                    const did_user_timeout = has_user_timespec and (absolute_timespec.eql(&user_timespec) or user_timespec.order(&now) == .lt);

                    if (did_user_timeout) {
                        did_timeout = true;
                        _ = subprocess.tryKill(subprocess.killSignal);
                    }

                    // Support bun:test timeouts AND spawnSync() timeout.
                    // There is a scenario where inside of spawnSync() a totally
                    // different test fails, and that SHOULD be okay.
                    if (has_bun_test_timeout) {
                        if (bun_test_timeout.order(&now) == .lt) {
                            var active_file_strong = bun.jsc.Jest.Jest.runner.?.bun_test_root.active_file
                                // TODO: add a .cloneNonOptional()?
                                .clone();

                            defer active_file_strong.deinit();
                            var taken_active_file = active_file_strong.take().?;
                            defer taken_active_file.deinit();

                            bun.jsc.Jest.removeActiveTimeout(bun.jsc.Jest.Jest.runner.?, jsc_vm);

                            // This might internally call `std.c.kill` on this
                            // spawnSync process. Even if we do that, we still
                            // need to reap the process. So we may go through
                            // the event loop again, but it should wake up
                            // ~instantly so we can drain the events.
                            jsc.Jest.bun_test.BunTest.bunTestTimeoutCallback(taken_active_file, &absolute_timespec, jsc_vm);
                        }
                    }
                },
            }
        }
    }
    if (globalThis.hasException()) {
        // e.g. a termination exception.
        return error.JSError;
    }

    subprocess.updateHasPendingActivity();

    if (setup_failure) |*failure| return failure.raise(context);

    const exit_code: ?i32 = if (subprocess.process.status == .exited)
        @intCast(subprocess.process.status.exited.code)
    else
        null;

    var stdout = try takeSyncOutput(context, &subprocess.stdout);
    errdefer if (stdout) |*bytes| bytes.deinit();
    var stderr = try takeSyncOutput(context, &subprocess.stderr);
    errdefer if (stderr) |*bytes| bytes.deinit();
    var resource_usage = (try subprocess.createResourceUsageObject(context)) orelse
        @panic("synchronous subprocess completed without resource usage");
    errdefer resource_usage.deinit();

    const SignalCodeResult = @FieldType(SpawnResult(true), "signalCode");
    const signal_code: SignalCodeResult = if (subprocess.process.signalCode()) |signal|
        if (signal.name()) |name|
            .{ .string = try bun.bindgen.DOMString.fromUTF8(name) }
        else
            .{ .integer = @intCast(@backingInt(signal)) }
    else
        null;

    return .{
        .stdout = if (stdout) |*bytes| bytes.take() else null,
        .stderr = if (stderr) |*bytes| bytes.take() else null,
        .exitCode = exit_code,
        .success = exit_code != null and exit_code.? == 0,
        .resourceUsage = resource_usage.take(),
        .signalCode = signal_code,
        .exitedDueToTimeout = if (timeout != null) did_timeout else null,
        .exitedDueToMaxBuffer = if (maxBuffer != null) subprocess.exited_due_to_maxbuf != null else null,
        .pid = subprocess.pid(),
    };
}

fn SpawnResult(comptime is_sync: bool) type {
    return if (is_sync) bun.bindgen.Return(SpawnSyncSchema) else bun.bindgen.Return(SpawnSchema);
}

fn takeSyncOutput(context: anytype, readable: *Subprocess.Readable) !?bun.bindgen.OwnedBytes {
    return switch (try readable.takeBufferedBytes()) {
        .bytes => |bytes| bytes,
        .unavailable => null,
        .err => |err| context.fail(.stdio_read, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

fn appendEnvpFromSchema(
    context: anytype,
    env_record: anytype,
    envp: *std.array_list.Managed(?[*:0]const u8),
    PATH: *[]const u8,
) bun.bindgen.CallError(@TypeOf(context))!void {
    try envp.ensureTotalCapacityPrecise(env_record.len() +
        // +1 incase there's IPC
        // +1 for null terminator
        2);
    for (0..env_record.len()) |index| {
        const entry = env_record.at(index).?;
        const value = entry.value orelse continue;
        const key_utf8 = try entry.key.toUTF8(bun.default_allocator);
        defer key_utf8.deinit();
        const value_utf8 = try value.toUTF8(bun.default_allocator);
        defer value_utf8.deinit();
        if (std.mem.indexOfScalar(u8, key_utf8.slice(), 0) != null) {
            return failInvalidSpawnArgument(context, "The property 'options.env['{s}']' must be a string without null bytes. Received \"{s}\"", .{ key_utf8.slice(), key_utf8.slice() });
        }
        if (std.mem.indexOfScalar(u8, value_utf8.slice(), 0) != null) {
            return failInvalidSpawnArgument(context, "The property 'options.env['{s}']' must be a string without null bytes. Received \"{s}\"", .{ key_utf8.slice(), value_utf8.slice() });
        }

        const line = try std.fmt.allocPrintSentinel(envp.allocator, "{s}={s}", .{ key_utf8.slice(), value_utf8.slice() }, 0);

        if (std.mem.eql(u8, key_utf8.slice(), "PATH")) {
            PATH.* = bun.asByteSlice(line["PATH=".len..]);
        }

        try envp.append(line);
    }
}

const log = Output.scoped(.Subprocess, .hidden);
const IPC = @import("../../../jsc/ipc.zig");
const SpawnArguments = @import("./SpawnArguments.zig");
const Terminal = @import("./Terminal.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const SignalCode = bun.SignalCode;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const uws = bun.uws;
const windows = bun.windows;
const MaxBuf = bun.io.MaxBuf;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const Subprocess = jsc.Subprocess;
const SpawnOnExitCallback = bun.bindgen.Callback(Subprocess.OnExitCallbackSlot.SemanticType);
const SpawnOnDisconnectCallback = bun.bindgen.Callback(Subprocess.OnDisconnectCallbackSlot.SemanticType);
const SpawnIPCCallback = bun.bindgen.Callback(Subprocess.IPCCallbackSlot.SemanticType);
const Readable = Subprocess.Readable;
const Writable = Subprocess.Writable;

const Process = bun.spawn.Process;
const Rusage = bun.spawn.Rusage;
const Stdio = bun.api.SpawnStdio;

const BunObjectBindings = bun.bindgen.Module("BunObject");
const SpawnSchema = BunObjectBindings.function("spawn");
const SpawnSyncSchema = BunObjectBindings.function("spawnSync");
