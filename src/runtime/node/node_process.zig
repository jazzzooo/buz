//! Process information and control APIs (`globalThis.process` / `node:process`)

var title_mutex: std.Io.Mutex = .init;

fn bindGetTitle(
    _: bun.bindgen.CallContext(ProcessGetTitleSchema),
    args: bun.bindgen.Args(ProcessGetTitleSchema),
) bun.JSError!bun.bindgen.Return(ProcessGetTitleSchema) {
    _ = args;
    const io = bun.current_runtime.io();
    title_mutex.lockUncancelable(io);
    defer title_mutex.unlock(io);
    return bun.bindgen.DOMString.fromUTF8(bun.cli.process_title orelse "bun");
}

// TODO: https://github.com/nodejs/node/blob/master/deps/uv/src/unix/darwin-proctitle.c
fn bindSetTitle(
    _: bun.bindgen.CallContext(ProcessSetTitleSchema),
    args: bun.bindgen.Args(ProcessSetTitleSchema),
) bun.JSError!bun.bindgen.Return(ProcessSetTitleSchema) {
    const new_title = try args.title.toOwnedSlice(bun.default_allocator);

    const io = bun.current_runtime.io();
    title_mutex.lockUncancelable(io);
    defer title_mutex.unlock(io);

    if (bun.cli.process_title) |slice| bun.default_allocator.free(slice);
    bun.cli.process_title = new_title;
}

fn createArgv0() bun.OOM!bun.bindgen.DOMString {
    return bun.bindgen.DOMString.fromUTF8(bun.argv[0]);
}

fn getExecPath() bun.OOM!bun.bindgen.DOMString {
    const out = bun.selfExePath() catch {
        return createArgv0();
    };

    return bun.bindgen.DOMString.fromUTF8(out);
}

fn getCwd_() bun.OOM!bun.sys.Maybe(bun.bindgen.DOMString) {
    var buf: bun.PathBuffer = undefined;
    switch (NodePath.getCwd(&buf)) {
        .result => |result| return .{ .result = try bun.bindgen.DOMString.fromUTF8(result) },
        .err => |err| return .{ .err = err },
    }
}

fn bindCreateArgv(
    context: bun.bindgen.CallContext(ProcessCreateArgvSchema),
    _: bun.bindgen.Args(ProcessCreateArgvSchema),
) bun.JSError!bun.bindgen.Return(ProcessCreateArgvSchema) {
    return bun.current_runtime.createProcessArgv(context);
}

fn bindGetCwd(
    context: bun.bindgen.CallContext(ProcessGetCwdSchema),
    _: bun.bindgen.Args(ProcessGetCwdSchema),
) bun.bindgen.CallError(ProcessGetCwdSchema)!bun.bindgen.Return(ProcessGetCwdSchema) {
    return switch (try getCwd_()) {
        .result => |value| value,
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

fn bindSetCwd(
    context: bun.bindgen.CallContext(ProcessSetCwdSchema),
    args: bun.bindgen.Args(ProcessSetCwdSchema),
) bun.bindgen.CallError(ProcessSetCwdSchema)!bun.bindgen.Return(ProcessSetCwdSchema) {
    return bun.current_runtime.setProcessWorkingDirectory(context, args.path);
}

fn bindExit(
    _: bun.bindgen.CallContext(ProcessExitSchema),
    args: bun.bindgen.Args(ProcessExitSchema),
) bun.JSError!bun.bindgen.Return(ProcessExitSchema) {
    bun.current_runtime.exitProcess(args.code);
}

fn bindCreateArgv0(
    context: bun.bindgen.CallContext(ProcessCreateArgv0Schema),
    args: bun.bindgen.Args(ProcessCreateArgv0Schema),
) bun.JSError!bun.bindgen.Return(ProcessCreateArgv0Schema) {
    _ = context;
    _ = args;
    return createArgv0();
}

fn bindGetExecPath(
    context: bun.bindgen.CallContext(ProcessGetExecPathSchema),
    args: bun.bindgen.Args(ProcessGetExecPathSchema),
) bun.JSError!bun.bindgen.Return(ProcessGetExecPathSchema) {
    _ = context;
    _ = args;
    return getExecPath();
}

fn bindCreateExecArgv(
    context: bun.bindgen.CallContext(ProcessCreateExecArgvSchema),
    args: bun.bindgen.Args(ProcessCreateExecArgvSchema),
) bun.JSError!bun.bindgen.Return(ProcessCreateExecArgvSchema) {
    _ = args;
    return bun.current_runtime.createProcessExecArgv(context);
}

fn bindGetEval(
    context: bun.bindgen.CallContext(ProcessGetEvalSchema),
    args: bun.bindgen.Args(ProcessGetEvalSchema),
) bun.JSError!bun.bindgen.Return(ProcessGetEvalSchema) {
    _ = args;
    return bun.current_runtime.getProcessEval(context);
}

fn bindNodeNoWarnings(
    args: bun.bindgen.Args(ProcessNodeNoWarningsSchema),
) bun.bindgen.Return(ProcessNodeNoWarningsSchema) {
    _ = args;
    return bun.feature_flag.NODE_NO_WARNINGS.get();
}

fn bindSuppressCrashOnProcessKillSelfIfDesired(
    args: bun.bindgen.Args(ProcessSuppressCrashOnProcessKillSelfIfDesiredSchema),
) bun.bindgen.Return(ProcessSuppressCrashOnProcessKillSelfIfDesiredSchema) {
    _ = args;
    if (bun.feature_flag.BUN_INTERNAL_SUPPRESS_CRASH_ON_PROCESS_KILL_SELF.get()) {
        bun.crash_handler.suppressReporting();
    }
}

fn bindVersion(
    args: bun.bindgen.Args(ProcessVersionSchema),
) bun.bindgen.Return(ProcessVersionSchema) {
    _ = args;
    return bun.bindgen.DOMString.fromUTF8("v" ++ bun.Global.package_json_version) catch bun.outOfMemory();
}

fn bindVersionWithSha(
    args: bun.bindgen.Args(ProcessVersionWithShaSchema),
) bun.bindgen.Return(ProcessVersionWithShaSchema) {
    _ = args;
    return bun.bindgen.DOMString.fromUTF8("v" ++ bun.Global.package_json_version_with_sha) catch bun.outOfMemory();
}

fn bindRevision(
    args: bun.bindgen.Args(ProcessRevisionSchema),
) bun.bindgen.Return(ProcessRevisionSchema) {
    _ = args;
    return bun.bindgen.DOMString.fromUTF8(bun.Environment.git_sha) catch bun.outOfMemory();
}

fn bindGitHubReleaseURL(
    args: bun.bindgen.Args(ProcessGitHubReleaseURLSchema),
) bun.bindgen.Return(ProcessGitHubReleaseURLSchema) {
    _ = args;
    return bun.bindgen.DOMString.fromUTF8(bun.cli.UpgradeCommand.github_url) catch bun.outOfMemory();
}

fn bindUseSystemCA(
    args: bun.bindgen.Args(ProcessUseSystemCASchema),
) bun.bindgen.Return(ProcessUseSystemCASchema) {
    _ = args;
    return bun.cli.Arguments.useSystemCA();
}

fn toNullTerminatedUTF16(
    allocator: std.mem.Allocator,
    value: bun.bindgen.DOMStringView,
) [:0]u16 {
    const result = bun.handleOom(allocator.allocSentinel(u16, value.length(), 0));
    for (result, 0..) |*destination, index| destination.* = value.codeUnitAt(index).?;
    return result;
}

fn bindEditWindowsEnvVar(
    args: bun.bindgen.Args(ProcessEditWindowsEnvVarSchema),
) bun.bindgen.Return(ProcessEditWindowsEnvVarSchema) {
    if (comptime bun.Environment.isWindows) {
        if (args.key.length() == 0) return;

        var fixed_stack_allocator_buffer: [1025]u8 = undefined;
        var fixed_stack_allocator: std.heap.BufferFirstAllocator = .init(
            &fixed_stack_allocator_buffer,
            bun.default_allocator,
        );
        const allocator = fixed_stack_allocator.allocator();

        const key = toNullTerminatedUTF16(allocator, args.key);
        defer allocator.free(key);

        var value_buffer: ?[:0]u16 = null;
        defer if (value_buffer) |value| allocator.free(value);
        if (args.value) |value| value_buffer = toNullTerminatedUTF16(allocator, value);

        _ = bun.c.SetEnvironmentVariableW(
            key.ptr,
            if (value_buffer) |value| value.ptr else null,
        );
    }
}

const ProcessBindings = bun.bindgen.Module("Process");
const ProcessGetTitleSchema = ProcessBindings.nativeExport("getTitle");
const ProcessSetTitleSchema = ProcessBindings.nativeExport("setTitle");
const ProcessCreateArgvSchema = ProcessBindings.nativeExport("createArgv");
const ProcessGetCwdSchema = ProcessBindings.nativeExport("getCwd");
const ProcessSetCwdSchema = ProcessBindings.nativeExport("setCwd");
const ProcessExitSchema = ProcessBindings.nativeExport("exit");
const ProcessCreateArgv0Schema = ProcessBindings.nativeExport("createArgv0");
const ProcessGetExecPathSchema = ProcessBindings.nativeExport("getExecPath");
const ProcessCreateExecArgvSchema = ProcessBindings.nativeExport("createExecArgv");
const ProcessGetEvalSchema = ProcessBindings.nativeExport("getEval");
const ProcessNodeNoWarningsSchema = ProcessBindings.nativeExport("nodeNoWarnings");
const ProcessSuppressCrashOnProcessKillSelfIfDesiredSchema = ProcessBindings.nativeExport("suppressCrashOnProcessKillSelfIfDesired");
const ProcessVersionSchema = ProcessBindings.nativeExport("version");
const ProcessVersionWithShaSchema = ProcessBindings.nativeExport("versionWithSha");
const ProcessRevisionSchema = ProcessBindings.nativeExport("revision");
const ProcessGitHubReleaseURLSchema = ProcessBindings.nativeExport("githubReleaseURL");
const ProcessUseSystemCASchema = ProcessBindings.nativeExport("useSystemCA");
const ProcessEditWindowsEnvVarSchema = ProcessBindings.nativeExport("editWindowsEnvVar");

const ProcessGetTitleBinding = bun.bindgen.Fn(ProcessGetTitleSchema, bindGetTitle);
const ProcessSetTitleBinding = bun.bindgen.Fn(ProcessSetTitleSchema, bindSetTitle);
const ProcessCreateArgvBinding = bun.bindgen.Fn(ProcessCreateArgvSchema, bindCreateArgv);
const ProcessGetCwdBinding = bun.bindgen.Fn(ProcessGetCwdSchema, bindGetCwd);
const ProcessSetCwdBinding = bun.bindgen.Fn(ProcessSetCwdSchema, bindSetCwd);
const ProcessExitBinding = bun.bindgen.Fn(ProcessExitSchema, bindExit);
const ProcessCreateArgv0Binding = bun.bindgen.Fn(ProcessCreateArgv0Schema, bindCreateArgv0);
const ProcessGetExecPathBinding = bun.bindgen.Fn(ProcessGetExecPathSchema, bindGetExecPath);
const ProcessCreateExecArgvBinding = bun.bindgen.Fn(ProcessCreateExecArgvSchema, bindCreateExecArgv);
const ProcessGetEvalBinding = bun.bindgen.Fn(ProcessGetEvalSchema, bindGetEval);
const ProcessNodeNoWarningsBinding = bun.bindgen.Fn(ProcessNodeNoWarningsSchema, bindNodeNoWarnings);
const ProcessVersionBinding = bun.bindgen.Fn(ProcessVersionSchema, bindVersion);
const ProcessVersionWithShaBinding = bun.bindgen.Fn(ProcessVersionWithShaSchema, bindVersionWithSha);
const ProcessRevisionBinding = bun.bindgen.Fn(ProcessRevisionSchema, bindRevision);
const ProcessGitHubReleaseURLBinding = bun.bindgen.Fn(ProcessGitHubReleaseURLSchema, bindGitHubReleaseURL);
const ProcessUseSystemCABinding = bun.bindgen.Fn(ProcessUseSystemCASchema, bindUseSystemCA);
const ProcessEditWindowsEnvVarBinding = bun.bindgen.Fn(ProcessEditWindowsEnvVarSchema, bindEditWindowsEnvVar);
const ProcessSuppressCrashOnProcessKillSelfIfDesiredBinding = bun.bindgen.Fn(
    ProcessSuppressCrashOnProcessKillSelfIfDesiredSchema,
    bindSuppressCrashOnProcessKillSelfIfDesired,
);

comptime {
    _ = ProcessGetTitleBinding;
    _ = ProcessSetTitleBinding;
    _ = ProcessCreateArgvBinding;
    _ = ProcessGetCwdBinding;
    _ = ProcessSetCwdBinding;
    _ = ProcessExitBinding;
    _ = ProcessCreateArgv0Binding;
    _ = ProcessGetExecPathBinding;
    _ = ProcessCreateExecArgvBinding;
    _ = ProcessGetEvalBinding;
    _ = ProcessNodeNoWarningsBinding;
    _ = ProcessVersionBinding;
    _ = ProcessVersionWithShaBinding;
    _ = ProcessRevisionBinding;
    _ = ProcessGitHubReleaseURLBinding;
    _ = ProcessUseSystemCABinding;
    _ = ProcessEditWindowsEnvVarBinding;
    _ = ProcessSuppressCrashOnProcessKillSelfIfDesiredBinding;
}

const std = @import("std");

const bun = @import("bun");
const NodePath = @import("./path.zig");
