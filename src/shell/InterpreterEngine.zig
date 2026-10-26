pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    interpreter: bindgen.OwnedNative(Interpreter, .vm),

    pub fn destroy(this: *JSBinding) void {
        this.interpreter.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(JSBinding) + this.interpreter.get().estimatedSize();
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        return this.interpreter.get().hasPendingActivity();
    }

    pub fn run(
        this: *JSBinding,
        context: bindgen.CallContext(ShellInterpreterRunSchema),
        _: bindgen.Args(ShellInterpreterRunSchema),
    ) bindgen.CallError(ShellInterpreterRunSchema)!void {
        const interpreter = this.interpreter.get();
        if (interpreter.started.load(.seq_cst)) return context.fail(.already_started, {});
        var completion_owner = bindgen.OwnedNative(JSCompletion, .vm).init(try bun.tryNew(JSCompletion, .{}));
        defer completion_owner.deinit();
        if (interpreter.prepareRunFromJS().asErr()) |err| {
            return context.fail(.system, try bindgen.SystemError.fromSysError(err));
        }
        var view = context.completion();
        completion_owner.get().sender = view.take();
        interpreter.completion = .{ .context = .init(completion_owner.take()), .vtable = &JSCompletion.vtable };
        interpreter.startFromJS();
        if (context.viewToken().globalObject().hasException()) return error.JSError;
    }

    pub fn isRunning(
        this: *JSBinding,
        _: bindgen.CallContext(ShellInterpreterIsRunningSchema),
        _: bindgen.Args(ShellInterpreterIsRunningSchema),
    ) bun.JSError!bool {
        return this.interpreter.get().hasPendingActivity();
    }

    pub fn getStarted(
        this: *JSBinding,
        _: bindgen.CallContext(ShellInterpreterStartedSchema),
        _: bindgen.Args(ShellInterpreterStartedSchema),
    ) bun.JSError!bool {
        return this.interpreter.get().started.load(.seq_cst);
    }
};

const JSCompletion = struct {
    sender: ?bindgen.OwnedCompletion(ShellInterpreterRunSchema) = null,

    fn finish(
        raw_context: Interpreter.Completion.Context,
        exit_code: bun.shell.ExitCode,
        stdout: *bun.ByteList,
        stderr: *bun.ByteList,
        cleanup_context: *anyopaque,
        cleanup: *const fn (*anyopaque) void,
    ) void {
        const this = raw_context.get(*JSCompletion);
        defer cleanup(cleanup_context);
        var sender = this.sender orelse @panic("shell completion was already consumed");
        this.sender = null;
        var buffered_stdout = takeBuffer(stdout) catch {
            sender.outOfMemory();
            return;
        };
        defer buffered_stdout.deinit();
        var buffered_stderr = takeBuffer(stderr) catch {
            sender.outOfMemory();
            return;
        };
        defer buffered_stderr.deinit();
        sender.resolve(.{
            .exitCode = exit_code,
            .stdout = buffered_stdout.take(),
            .stderr = buffered_stderr.take(),
        });
    }

    fn deinit(raw_context: Interpreter.Completion.Context) void {
        raw_context.get(*JSCompletion).destroy();
    }

    pub fn destroy(this: *JSCompletion) void {
        if (this.sender) |*sender| sender.release();
        bun.destroy(this);
    }

    fn takeBuffer(buffer: *bun.ByteList) bun.OOM!bindgen.OwnedBytes {
        return .fromDefaultAllocatedSlice(try buffer.toOwnedSlice(bun.default_allocator));
    }

    const vtable: Interpreter.Completion.VTable = .{
        .finish = finish,
        .deinit = deinit,
    };
};

pub fn createShellInterpreter(
    context: bindgen.CallContext(CreateShellInterpreterSchema),
    args: bindgen.Args(CreateShellInterpreterSchema),
) bun.JSError!bindgen.Return(CreateShellInterpreterSchema) {
    return createFromBinding(context, args);
}

pub fn createFromBinding(
    context: bindgen.CallContext(CreateShellInterpreterSchema),
    args: bindgen.Args(CreateShellInterpreterSchema),
) bun.JSError!bindgen.Return(CreateShellInterpreterSchema) {
    const global_this = context.viewToken().globalObject();
    const parsed_shell_script = args.parsedShellScript.get(ParsedShellScript);
    var parsed_ref = try args.parsedShellScript.toOwned();
    defer parsed_ref.deinit();
    const taken = (try parsed_shell_script.take(&parsed_ref)) orelse
        return global_this.throw("shell: shell args is null, this is a bug in Bun. Please file a GitHub issue.", .{});

    const shargs = taken.args;
    const shell_values = taken.shell_values;
    var inputs_adopted = false;
    var export_env = taken.export_env;
    defer if (!inputs_adopted) {
        shell_values.destroy();
        shargs.deinit();
    };
    defer if (export_env) |*env| env.deinit();
    var cwd = taken.cwd;
    defer if (cwd) |*value| value.deinit();
    const cwd_string: ?bun.String.Slice = if (cwd) |*value| try value.toUTF8(bun.default_allocator) else null;
    defer if (cwd_string) |value| value.deinit();

    const scheduler = SchedulerEngine.init(.{ .js = global_this.bunVM().event_loop });
    const transferred_env = export_env;
    export_env = null;
    const interpreter = switch (Interpreter.init(
        null,
        scheduler,
        bun.default_allocator,
        shargs,
        transferred_env,
        if (cwd_string) |value| value.slice() else null,
    )) {
        .result => |value| value,
        .err => |*err| {
            scheduler.reportShellError(err);
            return error.JSError;
        },
    };
    interpreter.adoptArguments();
    interpreter.shell_values = .init(shell_values);
    inputs_adopted = true;
    var interpreter_owner = bindgen.OwnedNative(Interpreter, .vm).init(interpreter);
    defer interpreter_owner.deinit();

    if (global_this.hasException()) {
        return error.JSError;
    }

    interpreter.flags.quiet = taken.quiet;
    interpreter.estimated_size_for_gc.store(interpreter.computeEstimatedSizeForGC(), .monotonic);

    const binding = try bun.default_allocator.create(JSBinding);
    binding.* = .{ .interpreter = .init(interpreter_owner.take()) };
    const reference = try ShellInterpreterClass.adoptNativeRef(binding, global_this);
    bun.analytics.Features.shell += 1;
    return reference;
}

const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;
const Interpreter = @import("./interpreter.zig").Interpreter;
const ParsedShellScript = @import("./ParsedShellScriptEngine.zig").ParsedShellScript;
const SchedulerEngine = @import("./ShellSchedulerEngine.zig");

const ShellInterpreterBindingModule = bindgen.Module("ShellInterpreter");
const ShellInterpreterSchema = ShellInterpreterBindingModule.class("ShellInterpreter");
const ShellInterpreterClass = bindgen.Class(ShellInterpreterSchema, JSBinding);
const BunObjectBindingModule = bindgen.Module("BunObject");
const CreateShellInterpreterSchema = BunObjectBindingModule.function("createShellInterpreter");
const CreateShellInterpreterBinding = bindgen.Fn(CreateShellInterpreterSchema, createShellInterpreter);
const ShellInterpreterIsRunningSchema = ShellInterpreterSchema.member("isRunning");
const ShellInterpreterRunSchema = ShellInterpreterSchema.member("run");
const ShellInterpreterStartedSchema = ShellInterpreterSchema.member("started");

comptime {
    _ = ShellInterpreterClass;
    _ = CreateShellInterpreterBinding;
}
