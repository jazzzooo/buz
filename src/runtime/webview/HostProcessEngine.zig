//! Spawns and watches the WebView host subprocess. macOS only.
//!
//! WKWebView hard-asserts `pthread_main_np()` (MainThreadCocoa.mm). Bridging
//! CFRunLoop into kqueue on the JS thread was abandoned: CFRunLoopWakeUp's
//! ignoreWakeUps flag check is a userspace drop before the mach send — lldb on
//! hangs showed the CF wake port seqno=0 over the process lifetime. No wake
//! path exists for kqueue to observe.
//!
//! The host child runs CFRunLoopRun() as its real main loop. CF manages
//! ignoreWakeUps correctly when it owns the loop. Parent talks over a
//! socketpair; usockets handles the parent end (C++ side), CFFileDescriptor
//! handles the child end. Socket EOF = parent died = child exits.
//!
//! This file owns process lifetime only. The usockets client lives in C++
//! (WebKitBackend.cpp) — usockets is a C API and the frame protocol is C structs.

/// Called from WebView.closeAll() and dispatchOnExit. Socket EOF handles
/// normal parent-death (including SIGKILL of Bun — kernel closes fds, child
/// reads 0, CFRunLoopStop). This catches the clean-exit path where the child
/// hasn't yet noticed EOF before we return from main(). WKWebView's own
/// WebContent/GPU/Network helpers are XPC-connected to the child — when the
/// child dies they get connection-invalidated and exit.
fn kill(vm: *jsc.VirtualMachine) void {
    const rare = vm.rare_data orelse return;
    if (rare.webview_host_process) |i| {
        i.kill();
    }
}

/// Lazy: first `new Bun.WebView()` calls this via C++. Returns the parent
/// socket fd (C++ adopts into usockets and owns it from then on), or -1.
/// C++'s HostClient::ensureSpawned checks its own sock before calling here,
/// so instance-already-exists → -1 means "you already have the fd, this is
/// a bug" not "spawn failed". We deliberately don't store the fd — usockets
/// owns it; re-returning a fd usockets may have already closed would be a
/// use-after-close. Zig only owns process lifetime (watch + kill).
fn ensure(global: *jsc.JSGlobalObject, generation: u64, stdoutInherit: bool, stderrInherit: bool) bun.OOM!i32 {
    if (comptime !bun.Environment.isMac) return -1;
    if (global.bunVM().rareData().webview_host_process != null) return -1;

    const fd = spawn(global, generation, stdoutInherit, stderrInherit) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log("spawn failed: {s}", .{@errorName(err)});
        return -1;
    };
    return fd.cast();
}

fn spawn(global: *jsc.JSGlobalObject, generation: u64, stdoutInherit: bool, stderrInherit: bool) !bun.FD {
    if (comptime !bun.Environment.isMac) return error.Unsupported;

    const vm = global.bunVM();
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Both ends nonblocking — parent uses usockets; child sets O_NONBLOCK
    // again after dup2 (socketpair flags are per-fd, not per-pair).
    const fds = try bun.sys.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        .nonblocking,
    ).unwrap();
    errdefer fds[0].close();
    defer fds[1].close();

    const exe = try bun.selfExePath();

    // Child sees fd 3 (first extra_fd → 3+0). The env var is the only
    // signal; no argv changes so `ps` shows a normal `bun` invocation.
    // Same pattern as NODE_CHANNEL_FD in the subprocess binding adapter.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    const base = try vm.transpiler.env.map.createNullDelimitedEnvMap(alloc);
    try env.ensureTotalCapacity(alloc, base.len + 2);
    env.appendSliceAssumeCapacity(@ptrCast(base));
    env.appendAssumeCapacity("BUN_INTERNAL_WEBVIEW_HOST=3");
    env.appendAssumeCapacity(null);

    var argv = [_:null]?[*:0]const u8{exe.ptr};

    var opts: bun.spawn.SpawnOptions = .{
        .stdin = .ignore,
        // Default ignore — the child runs no JS or user code, so output is
        // only panics/NSLog from WebKit. Opt-in via backend.stderr when
        // debugging a silent host crash.
        .stdout = if (stdoutInherit) .inherit else .ignore,
        .stderr = if (stderrInherit) .inherit else .ignore,
        .extra_fds = &.{.{ .pipe = fds[1] }},
        .argv0 = exe.ptr,
    };

    var spawned = try (try bun.spawn.spawnProcess(
        &opts,
        @ptrCast(&argv),
        @ptrCast(env.items.ptr),
    )).unwrap();
    defer spawned.close();

    _ = try ProcessWatcher.start(vm, .webkit, generation, spawned.pid);
    // fd handed to C++ which adopts it into usockets. Not stored here —
    // usockets owns the socket; Zig only owns process lifetime.
    return fds[0];
}

fn bindKill(
    args: bun.bindgen.Args(WebViewHostProcessKillSchema),
) bun.bindgen.Return(WebViewHostProcessKillSchema) {
    kill(@ptrCast(@alignCast(args.vm)));
}

fn bindEnsure(
    context: bun.bindgen.CallContext(WebViewHostProcessEnsureSchema),
    args: bun.bindgen.Args(WebViewHostProcessEnsureSchema),
) bun.JSError!bun.bindgen.Return(WebViewHostProcessEnsureSchema) {
    return ensure(context.viewToken().globalObject(), args.generation, args.stdoutInherit, args.stderrInherit);
}

const WebViewHostProcessBindings = bun.bindgen.Module("WebViewHostProcess");
const WebViewHostProcessKillSchema = WebViewHostProcessBindings.nativeExport("webViewHostProcessKill");
const WebViewHostProcessEnsureSchema = WebViewHostProcessBindings.nativeExport("webViewHostProcessEnsure");
const WebViewHostProcessKillBinding = bun.bindgen.Fn(WebViewHostProcessKillSchema, bindKill);
const WebViewHostProcessEnsureBinding = bun.bindgen.Fn(WebViewHostProcessEnsureSchema, bindEnsure);

comptime {
    _ = WebViewHostProcessKillBinding;
    _ = WebViewHostProcessEnsureBinding;
}

const log = bun.Output.scoped(.WebViewHost, .hidden);

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const ProcessWatcher = @import("./ProcessWatcher.zig");
