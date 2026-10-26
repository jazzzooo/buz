const Global = @This();

/// Does not have the canary tag, because it is exposed in `Bun.version`
/// "1.0.0" or "1.0.0-debug"
pub const package_json_version = if (Environment.isDebug)
    version_string ++ "-debug"
else
    version_string;

/// This is used for `bun` without any arguments, it `package_json_version` but with canary if it is a canary build.
/// like "1.0.0-canary.12"
pub const package_json_version_with_canary = if (Environment.isDebug)
    version_string ++ "-debug"
else if (Environment.is_canary)
    std.fmt.comptimePrint("{s}-canary.{d}", .{ version_string, Environment.canary_revision })
else
    version_string;

/// The version and a short hash in parenthesis.
pub const package_json_version_with_sha = if (Environment.git_sha.len == 0)
    package_json_version
else if (Environment.isDebug)
    std.fmt.comptimePrint("{s} ({s})", .{ version_string, Environment.git_sha[0..@min(Environment.git_sha.len, 8)] })
else if (Environment.is_canary)
    std.fmt.comptimePrint("{s}-canary.{d} ({s})", .{ version_string, Environment.canary_revision, Environment.git_sha[0..@min(Environment.git_sha.len, 8)] })
else
    std.fmt.comptimePrint("{s} ({s})", .{ version_string, Environment.git_sha[0..@min(Environment.git_sha.len, 8)] });

/// What is printed by `bun --revision`
/// "1.0.0+abcdefghi" or "1.0.0-canary.12+abcdefghi"
pub const package_json_version_with_revision = if (Environment.git_sha.len == 0)
    package_json_version
else if (Environment.isDebug)
    std.fmt.comptimePrint(version_string ++ "-debug+{s}", .{Environment.git_sha_short})
else if (Environment.is_canary)
    std.fmt.comptimePrint(version_string ++ "-canary.{d}+{s}", .{ Environment.canary_revision, Environment.git_sha_short })
else
    std.fmt.comptimePrint(version_string ++ "+{s}", .{Environment.git_sha_short});

// Node-style platform string. Distinct from Environment.os.nameString() on
// Android: the kernel-level OS enum stays .linux (so syscall switches keep
// working), but user-facing strings — npm user-agent, process.platform —
// must be "android" so native-addon postinstalls don't fetch glibc binaries.
pub const os_name = if (Environment.isAndroid) "android" else Environment.os.nameString();
pub const os_display = if (Environment.isAndroid) "Android" else Environment.os.displayString();

// Bun v1.0.0 (Linux x64 baseline)
// Bun v1.0.0-debug (Linux x64)
// Bun v1.0.0-canary.0+44e09bb7f (Linux x64)
pub const unhandled_error_bun_version_string = "Bun v" ++
    (if (Environment.is_canary) package_json_version_with_revision else package_json_version) ++
    " (" ++ os_display ++ " " ++ arch_name ++
    (if (Environment.baseline) " baseline)" else ")");

pub const arch_name = if (Environment.isX64)
    "x64"
else if (Environment.isX86)
    "x86"
else if (Environment.isAarch64)
    "arm64"
else
    "unknown";

extern "kernel32" fn SetThreadDescription(thread: std.os.windows.HANDLE, name: [*:0]const u16) callconv(.winapi) i32;

pub fn setThreadName(name: [:0]const u8) void {
    if (Environment.isLinux) {
        _ = std.posix.prctl(.SET_NAME, .{@intFromPtr(name.ptr)}) catch 0;
    } else if (Environment.isMac) {
        _ = std.c.pthread_setname_np(name);
    } else if (Environment.isFreeBSD) {
        std.c.pthread_set_name_np(std.c.pthread_self(), name);
    } else if (Environment.isWindows) {
        // TODO: use SetThreadDescription or NtSetInformationThread with 0x26 (ThreadNameInformation)
        // without causing exit code 0xC0000409 (stack buffer overrun) in child process
    }
}

pub const addExitCallback = ProcessLifecycle.addExitCallback;

fn bindRunProcessExitHooks(
    _: bun.bindgen.Args(RunProcessExitHooksSchema),
) bun.bindgen.Return(RunProcessExitHooksSchema) {
    runProcessExitHooks();
}

fn bindRuntimeUserAgent(
    _: bun.bindgen.Args(RuntimeUserAgentSchema),
) bun.bindgen.Return(RuntimeUserAgentSchema) {
    return bun.bindgen.DOMString.fromUTF8(user_agent) catch bun.outOfMemory();
}

pub fn runExitCallbacks() void {
    ProcessLifecycle.runExitCallbacks();
}

fn prepareProcessExit() void {
    ProcessLifecycle.runBeforeExitCallbacks();
}

/// Flushes stdout and stderr (in exit/quick_exit callback) and exits with the given code.
pub fn exit(code: u32) noreturn {
    prepareProcessExit();
    _ = @atomicRmw(usize, &bun.analytics.Features.exited, .Add, 1, .monotonic);

    // If we are crashing, allow the crash handler to finish it's work.
    bun.crash_handler.sleepForeverIfAnotherThreadIsCrashing();
    bun.cli.Cli.shutdownRuntimeServices();

    if (Environment.isDebug) {
        bun.assert(bun.debug_allocator_data.backing.?.deinit() == .ok);
        bun.debug_allocator_data.backing = null;
    }

    // Flush output before exiting to ensure all messages are visible
    Output.flush();

    switch (Environment.os) {
        .mac => std.c.exit(@bitCast(code)),
        .windows => {
            runProcessExitHooks();
            std.os.windows.ntdll.RtlExitUserProcess(code);
        },
        else => {
            if (Environment.enable_asan) {
                std.c.exit(@bitCast(code));
                std.c.abort(); // exit should be noreturn
            }
            bun.c.quick_exit(@bitCast(code));
            std.c.abort(); // quick_exit should be noreturn
        },
    }
}

pub fn exitWithoutCleanup(code: u32) noreturn {
    prepareProcessExit();
    Output.flush();
    Output.Source.Stdio.restore();
    if (Environment.isWindows) {
        std.os.windows.ntdll.RtlExitUserProcess(code);
    }
    std.c._exit(@bitCast(code));
}

pub fn raiseIgnoringPanicHandler(sig: bun.SignalCode) noreturn {
    Output.flush();
    Output.Source.Stdio.restore();

    // clear segfault handler
    bun.crash_handler.resetSegfaultHandler();

    // clear signal handler
    if (bun.Environment.os != .windows) {
        const posix_signal: std.posix.SIG = @fromBackingInt(@intCast(@backingInt(sig)));
        var sa: bun.sys.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = bun.sys.sigemptyset(),
            .flags = std.posix.SA.RESETHAND,
        };
        bun.sys.sigaction(posix_signal, &sa, null);

        // A faulting signal is blocked while its own handler runs, and this is
        // reachable from inside one; raising it while blocked would only mark
        // it pending and return.
        var unblock = bun.sys.sigemptyset();
        bun.sys.sigaddset(&unblock, posix_signal);
        std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &unblock, null);
    }

    // kill self
    _ = std.c.raise(@fromBackingInt(@intCast(@backingInt(sig))));
    std.c.abort();
}

pub inline fn mimalloc_cleanup(force: bool) void {
    if (comptime use_mimalloc) {
        Mimalloc.mi_collect(force);
    }
}
pub fn notimpl() noreturn {
    @branchHint(.cold);
    Output.panic("Not implemented yet!!!!!", .{});
}

// Make sure we always print any leftover
pub fn crash() noreturn {
    @branchHint(.cold);
    Global.exit(1);
}

pub const BunInfo = struct {
    bun_version: string,
    platform: bun.Platform,

    const JSON = bun.json;
    const JSAst = bun.ast;
    pub fn generate(comptime Bundler: type, _: Bundler, allocator: std.mem.Allocator) !JSAst.Expr {
        const info = BunInfo{
            .bun_version = Global.package_json_version,
            .platform = bun.Platform.forOS(),
        };

        return try JSON.toAST(allocator, BunInfo, info);
    }
};

pub const user_agent = "Bun/" ++ Global.package_json_version;

pub fn runProcessExitHooks() void {
    if (comptime bun.Environment.isNative) {
        ProcessLifecycle.runShutdownCallbacks();
        runExitCallbacks();
        Output.flush();

        Output.Source.Stdio.restore();
    }
}

const string = []const u8;

const Output = @import("./output.zig");
const std = @import("std");

const Environment = @import("./env.zig");
const version_string = Environment.version_string;

const bun = @import("bun");
const Mimalloc = bun.mimalloc;
const use_mimalloc = bun.use_mimalloc;
const ProcessHostBindings = bun.bindgen.Module("ProcessHost");
const RuntimeUserAgentBindings = bun.bindgen.Module("runtime_user_agent");
const ProcessLifecycle = @import("./ProcessLifecycle.zig");
const RunProcessExitHooksSchema = ProcessHostBindings.nativeExport("runProcessExitHooks");
const RuntimeUserAgentSchema = RuntimeUserAgentBindings.nativeExport("runtimeUserAgent");
const RunProcessExitHooksBinding = bun.bindgen.Fn(RunProcessExitHooksSchema, bindRunProcessExitHooks);
const RuntimeUserAgentBinding = bun.bindgen.Fn(RuntimeUserAgentSchema, bindRuntimeUserAgent);

comptime {
    _ = RunProcessExitHooksBinding;
    _ = RuntimeUserAgentBinding;
}
