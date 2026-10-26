pub fn createArgvForContext(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return createArgv(bun.bindgen.Return(@TypeOf(context)), jsc.VirtualMachine.get());
}

pub fn setCwdForContext(context: anytype, path: bun.bindgen.DOMStringView) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return setCwd(context.viewToken().globalObject(), context, path);
}

pub fn exitProcess(code: u8) void {
    jsc.VirtualMachine.get().exitProcess(code);
}

pub fn createExecArgvForContext(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return createExecArgv(bun.bindgen.Return(@TypeOf(context)), jsc.VirtualMachine.get());
}

pub fn getEvalForContext(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    if (jsc.VirtualMachine.get().module_loader.eval_source) |source| {
        return try bun.bindgen.DOMString.fromUTF8(source.contents);
    }
    return null;
}

fn createExecArgv(comptime Result: type, vm: *jsc.VirtualMachine) bun.OOM!Result {
    var sfb_buffer: [4096]u8 = undefined;
    var sfb: std.heap.BufferFirstAllocator = .init(&sfb_buffer, bun.default_allocator);
    const temp_alloc = sfb.allocator();

    if (vm.worker) |worker| {
        if (worker.exec_argv) |exec_argv| return Result.fromUTF8Slices(exec_argv);
    }

    if (vm.standalone_module_graph) |graph| {
        const compile_exec_argv = graph.compile_exec_argv;
        if (compile_exec_argv.len > 0 or bun.bun_options_argc > 0) {
            var args = std.array_list.Managed(bun.String).init(temp_alloc);
            defer args.deinit();
            defer for (args.items) |*arg| arg.deref();

            if (bun.bun_options_argc > 0) {
                if (bun.env_var.BUN_OPTIONS.get()) |opts| {
                    try args.append(bun.String.empty);
                    try bun.appendOptionsEnv(opts, bun.String, &args);
                    _ = args.orderedRemove(0);
                }
            }

            if (compile_exec_argv.len > 0) {
                var tokenizer = std.mem.tokenizeAny(u8, compile_exec_argv, " \t\n\r");
                while (tokenizer.next()) |token| {
                    try args.append(bun.String.cloneUTF8(token));
                }
            }

            return Result.fromBunStrings(args.items);
        }
        return Result.fromUTF8Slices(&[_][]const u8{});
    }

    var args = try std.array_list.Managed(bun.String).initCapacity(temp_alloc, bun.argv.len - 1);
    defer args.deinit();
    defer for (args.items) |*arg| arg.deref();

    var seen_run = false;
    var prev: ?[]const u8 = null;
    for (bun.argv[@min(1, bun.argv.len)..]) |arg| {
        defer prev = arg;

        if (arg.len >= 1 and arg[0] == '-') {
            try args.append(bun.String.cloneUTF8(arg));
            continue;
        }

        if (!seen_run and bun.strings.eqlComptime(arg, "run")) {
            seen_run = true;
            continue;
        }

        const map = bun.ComptimeStringMap(void, comptime brk: {
            const auto_params = bun.cli.Arguments.auto_params;
            const KV = struct { []const u8, void };
            var entries: [auto_params.len]KV = undefined;
            var i = 0;
            for (auto_params) |param| {
                if (param.takes_value != .none) {
                    if (param.names.long) |name| {
                        entries[i] = .{ "--" ++ name, {} };
                        i += 1;
                    }
                    if (param.names.short) |name| {
                        entries[i] = .{ &[_]u8{ '-', name }, {} };
                        i += 1;
                    }
                }
            }

            var result: [i]KV = undefined;
            @memcpy(&result, entries[0..i]);
            break :brk result;
        });

        if (prev) |previous| if (map.has(previous)) {
            try args.append(bun.String.cloneUTF8(arg));
            continue;
        };

        break;
    }

    return Result.fromBunStrings(args.items);
}

fn createArgv(comptime Result: type, vm: *jsc.VirtualMachine) bun.OOM!Result {
    var stack_buffer: [32 * @sizeOf(bun.String) + (bun.MAX_PATH_BYTES + 1) + 32]u8 = undefined;
    var stack_allocator: std.heap.BufferFirstAllocator = .init(&stack_buffer, bun.default_allocator);
    const allocator = stack_allocator.allocator();

    const worker_argv = if (vm.worker) |worker| worker.argv else null;
    const process_argv = vm.argv;
    const args_count = if (worker_argv) |argv| argv.len else process_argv.len;
    const args = allocator.alloc(bun.String, args_count + 2) catch return error.OutOfMemory;
    defer allocator.free(args);

    var args_list: std.ArrayListUnmanaged(bun.String) = .initBuffer(args);
    defer for (args_list.items) |*arg| arg.deref();

    if (vm.standalone_module_graph != null) {
        args_list.appendAssumeCapacity(bun.String.static("bun"));
    } else {
        const exe_path = bun.selfExePath() catch null;
        args_list.appendAssumeCapacity(if (exe_path) |path| bun.String.cloneUTF8(path) else bun.String.static("bun"));
    }

    const main_path = vm.main;
    if (main_path.len > 0 and
        !bun.strings.endsWithComptime(main_path, bun.pathLiteral("/[eval]")) and
        !bun.strings.endsWithComptime(main_path, bun.pathLiteral("/[stdin]")))
    {
        if (vm.worker != null and vm.worker.?.eval_mode) {
            args_list.appendAssumeCapacity(bun.String.static("[worker eval]"));
        } else {
            args_list.appendAssumeCapacity(bun.String.cloneUTF8(main_path));
        }
    }

    if (worker_argv) |argv| {
        for (argv) |arg| args_list.appendAssumeCapacity(bun.String.cloneUTF8(arg));
    } else {
        for (process_argv) |arg| args_list.appendAssumeCapacity(bun.String.cloneUTF8(arg));
    }

    return Result.fromBunStrings(args_list.items);
}

fn setCwd(
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    path: bun.bindgen.DOMStringView,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.DOMString {
    if (path.length() == 0) return context.fail(.empty_path, {});

    const fs = globalThis.bunVM().transpiler.fs;
    const previous_cwd = fs.top_level_dir;
    var buf: bun.PathBuffer = undefined;
    const utf8 = try path.toUTF8(bun.default_allocator);
    defer utf8.deinit();
    const slice = std.mem.printSentinel(&buf, "{s}", .{utf8.slice()}, 0) catch
        return context.fail(.invalid_path, {});

    switch (bun.sys.chdir(previous_cwd, slice)) {
        .result => {
            const into_cwd_buf = switch (bun.sys.getcwd(&buf)) {
                .result => |result| result,
                .err => |err| {
                    _ = bun.sys.chdir(previous_cwd, previous_cwd);
                    return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
                },
            };
            bun.assert(into_cwd_buf.len + 2 <= fs.top_level_dir_buf.len);
            @memcpy(fs.top_level_dir_buf[0..into_cwd_buf.len], into_cwd_buf);
            fs.top_level_dir_buf[into_cwd_buf.len] = 0;
            fs.top_level_dir = fs.top_level_dir_buf[0..into_cwd_buf.len :0];
            if (into_cwd_buf.len == 0 or fs.top_level_dir_buf[into_cwd_buf.len - 1] != std.fs.path.sep) {
                fs.top_level_dir_buf[into_cwd_buf.len] = std.fs.path.sep;
                fs.top_level_dir_buf[into_cwd_buf.len + 1] = 0;
                fs.top_level_dir = fs.top_level_dir_buf[0 .. into_cwd_buf.len + 1 :0];
            }
            const stripTrailingSlash = if (bun.Environment.isWindows)
                bun.strings.withoutTrailingSlashWindowsPath
            else
                bun.strings.withoutTrailingSlash;
            return bun.bindgen.DOMString.fromUTF8(stripTrailingSlash(fs.top_level_dir));
        },
        .err => |err| return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    }
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;

const ProcessBindings = bun.bindgen.Module("Process");
const ProcessCreateArgvSchema = ProcessBindings.nativeExport("createArgv");
const ProcessSetCwdSchema = ProcessBindings.nativeExport("setCwd");
const ProcessExitSchema = ProcessBindings.nativeExport("exit");
const ProcessCreateExecArgvSchema = ProcessBindings.nativeExport("createExecArgv");
const ProcessGetEvalSchema = ProcessBindings.nativeExport("getEval");
