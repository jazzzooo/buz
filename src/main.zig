pub const panic = _bun.crash_handler.panic;
pub const std_options = std.Options{
    .enable_segfault_handler = false,
};

pub const debug = struct {
    pub fn getDebugInfoAllocator() std.mem.Allocator {
        // Stack capture frees temporary unwind buffers on every call.
        return std.heap.smp_allocator;
    }
};

pub const io_mode = .blocking;

comptime {
    _bun.assert(builtin.target.cpu.arch.endian() == .little);
}

pub extern "c" var _environ: ?*anyopaque;
pub extern "c" var environ: ?*anyopaque;

pub fn main(init: std.process.Init.Minimal) void {
    const use_safe_allocator = builtin.mode == .debug or builtin.mode == .safe;
    var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };
    const allocator = if (use_safe_allocator) safe_allocator.allocator() else std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();
    _bun.crash_handler.init(io);

    if (Environment.isPosix) {
        var act: _bun.sys.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = _bun.sys.sigemptyset(),
            .flags = 0,
        };
        _bun.sys.sigaction(std.posix.SIG.PIPE, &act, null);
        _bun.sys.sigaction(std.posix.SIG.XFSZ, &act, null);
    }

    if (Environment.isDebug) {
        _bun.debug_allocator_data.backing = .init;
    }

    // This should appear before we make any calls at all to libuv.
    // So it's safest to put it very early in the main function.
    if (Environment.isWindows) {
        _ = _bun.windows.libuv.uv_replace_allocator(
            &_bun.mimalloc.mi_malloc,
            &_bun.mimalloc.mi_realloc,
            &_bun.mimalloc.mi_calloc,
            &_bun.mimalloc.mi_free,
        );
    }

    _bun.handleOom(_bun.initEnviron(init.environ));
    if (Environment.isWindows) {
        environ = @ptrCast(@constCast(_bun.environ.ptr));
        _environ = @ptrCast(@constCast(_bun.environ.ptr));
    }

    _bun.start_time = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    _bun.initSelfExePath(io) catch |err| {
        Output.panic("Failed to resolve the executable path: {s}\n", .{@errorName(err)});
    };
    _bun.initArgv(init.args) catch |err| {
        Output.panic("Failed to initialize argv: {s}\n", .{@errorName(err)});
    };

    Output.Source.Stdio.init(io);
    defer Output.flush();
    if (Environment.isX64 and Environment.enableSIMD and Environment.isPosix) {
        if (!_bun.crash_handler.CPUFeatures.detect().avx) {
            Output.prettyErrorln("warn: CPU lacks AVX support, strange crashes may occur. Reinstall Bun or use *-baseline build:\n  {s}", .{_bun.cli.UpgradeCommand.github_baseline_url});
            Output.flush();
        }
    }

    _bun.StackCheck.configureThread();
    _bun.ParentDeathWatchdogEngine.install();
    _bun.ParentDeathWatchdog.install();

    _bun.cli.Cli.start(
        _bun.default_allocator,
        io,
        _bun.CliEngine.capabilities(.{
            .javascript_semantics = _bun.jsc.JavaScriptSemanticsEngine.javascript_semantics,
            .macro_context_factory = _bun.api.MacroIntegration.context_factory,
            .bytecode_generator = _bun.BundlerEngine.bytecode_generator,
        }),
    );
    _bun.Global.exit(0);
}

// -- Zig Standard Library Additions --
pub fn copyForwards(comptime T: type, dest: []T, source: []const T) void {
    if (source.len == 0) {
        return;
    }
    _bun.copy(T, dest[0..source.len], source);
}
pub fn copyBackwards(comptime T: type, dest: []T, source: []const T) void {
    if (source.len == 0) {
        return;
    }
    _bun.copy(T, dest[0..source.len], source);
}
// -- End Zig Standard Library Additions --

// Claude thinks its @import("root").bun when it's @import("bun").
const bun = @compileError("Deprecated: Use @import(\"bun\") instead");

const builtin = @import("builtin");
const std = @import("std");

const _bun = @import("bun");
const Environment = _bun.Environment;
const Output = _bun.Output;
