var ready: std.atomic.Value(bool) = .init(false);
var missing: [3]bool = @splat(false);

pub fn wasMissing(fd: u2) bool {
    return ready.load(.acquire) and missing[fd];
}

pub fn init() void {
    if (comptime !Environment.isNative) return;
    if (ready.load(.acquire)) return;
    crt.bun_stdio_disable_buffering();
    if (comptime Environment.isWindows) {
        Windows.init();
    } else {
        Posix.init();
    }
    ready.store(true, .release);

    if (comptime Environment.isWindows) {
        enableConsoleControlHandler();
    } else {
        Posix.installSignalHandlers();
    }

    if (comptime Environment.isMac or Environment.enable_asan) {
        if (crt.atexit(onExit) != 0) std.c.abort();
    } else if (comptime Environment.isPosix) {
        if (crt.at_quick_exit(onExit) != 0) std.c.abort();
    }
}

fn onExit() callconv(.c) void {
    bun.Global.runProcessExitHooks();
}

pub fn restore() void {
    if (comptime !Environment.isNative) return;
    if (!ready.load(.acquire)) return;
    if (comptime Environment.isWindows) {
        Windows.restore();
    } else {
        Posix.restore();
    }
}

pub fn markModified(fd: c_int) void {
    if (comptime !Environment.isPosix) return;
    if (fd >= 0 and fd < 3) Posix.modified[@intCast(fd)].store(true, .monotonic);
}

pub fn prepareForReload() ?std.c.E {
    if (comptime !Environment.isPosix) return null;
    for (0..3) |index| {
        const fd: c_int = @intCast(index);
        const flags = Posix.getFdFlags(fd) orelse {
            const failure = Posix.lastError();
            if (failure == .BADF) continue;
            return failure;
        };
        if (!Posix.setFdFlags(fd, flags & ~@as(c_int, std.c.FD_CLOEXEC))) return Posix.lastError();
    }
    if (comptime Environment.isLinux or Environment.isFreeBSD) {
        if (crt.bun_close_range(3, std.math.maxInt(u32), crt.BUN_CLOSE_RANGE_CLOEXEC) != 0) return Posix.lastError();
    }
    var mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&mask);
    if (std.c.sigprocmask(std.c.SIG.SETMASK, &mask, null) != 0) return Posix.lastError();
    return null;
}

const Posix = struct {
    const Termios = if (Environment.isPosix) std.c.termios else void;
    var snapshots: [3]Termios = undefined;
    var has_snapshot: [3]bool = @splat(false);
    var is_tty: [3]bool = @splat(false);
    var modified: [3]std.atomic.Value(bool) = @splat(.init(false));

    fn lastError() std.c.E {
        return @fromBackingInt(@intCast(std.c._errno().*));
    }

    fn getFdFlags(fd: c_int) ?c_int {
        while (true) {
            const flags = std.c.fcntl(fd, std.c.F.GETFD);
            if (flags >= 0) return flags;
            if (std.c._errno().* != @backingInt(std.c.E.INTR)) return null;
        }
    }

    fn setFdFlags(fd: c_int, flags: c_int) bool {
        while (true) {
            if (std.c.fcntl(fd, std.c.F.SETFD, flags) == 0) return true;
            if (std.c._errno().* != @backingInt(std.c.E.INTR)) return false;
        }
    }

    fn replaceMissing(fd: c_int) void {
        const null_fd = while (true) {
            const result = std.c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
            if (result >= 0) break result;
            if (std.c._errno().* != @backingInt(std.c.E.INTR)) std.c.abort();
        };
        if (null_fd == fd) {
            if (!setFdFlags(fd, 0)) std.c.abort();
        } else {
            defer _ = std.c.close(null_fd);
            while (std.c.dup2(null_fd, fd) < 0) {
                if (std.c._errno().* != @backingInt(std.c.E.INTR)) std.c.abort();
            }
        }
        missing[@intCast(fd)] = true;
    }

    fn init() void {
        if (comptime Environment.isLinux) {
            // Descriptor 3 may carry IPC from the parent process.
            _ = crt.bun_close_range(4, std.math.maxInt(u32), crt.BUN_CLOSE_RANGE_CLOEXEC);
        }
        for (0..3) |index| {
            const fd: c_int = @intCast(index);
            if (getFdFlags(fd) == null and std.c._errno().* == @backingInt(std.c.E.BADF)) {
                replaceMissing(fd);
            }
            while (true) {
                if (std.c.isatty(fd) == 1) {
                    is_tty[index] = true;
                    break;
                }
                if (std.c._errno().* != @backingInt(std.c.E.INTR)) break;
            }
            if (!is_tty[index]) continue;
            while (true) {
                if (std.c.tcgetattr(fd, &snapshots[index]) == 0) {
                    has_snapshot[index] = true;
                    break;
                }
                if (std.c._errno().* != @backingInt(std.c.E.INTR)) break;
            }
        }
    }

    fn installSignalHandlers() void {
        if (std.mem.indexOfScalar(bool, &has_snapshot, true) == null) return;
        var action: std.c.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = undefined,
            .flags = std.c.SA.RESETHAND,
        };
        _ = std.c.sigemptyset(&action.mask);
        _ = std.c.sigaction(.TERM, &action, null);
        _ = std.c.sigaction(.INT, &action, null);
    }

    fn onSignal(signal: std.c.SIG) callconv(.c) void {
        Posix.restore();
        var action: std.c.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = undefined,
            .flags = 0,
        };
        _ = std.c.sigemptyset(&action.mask);
        _ = std.c.sigaction(signal, &action, null);
        _ = std.c.raise(signal);
    }

    fn restore() void {
        const saved_errno = std.c._errno().*;
        defer std.c._errno().* = saved_errno;
        var blocked: std.c.sigset_t = undefined;
        var saved_mask: std.c.sigset_t = undefined;
        var unused_mask: std.c.sigset_t = undefined;
        _ = std.c.sigemptyset(&blocked);
        _ = std.c.sigaddset(&blocked, .TTOU);
        // A background process must not be suspended while restoring its terminal.
        if (std.c.pthread_sigmask(std.c.SIG.BLOCK, &blocked, &saved_mask) != 0) return;
        defer _ = std.c.pthread_sigmask(std.c.SIG.SETMASK, &saved_mask, &unused_mask);
        for (0..3) |index| {
            if (!has_snapshot[index]) continue;
            // A pipeline consumer may have changed a terminal shared with this producer.
            if (!is_tty[1] and !modified[index].load(.monotonic)) continue;
            while (std.c.tcsetattr(@intCast(index), .NOW, &snapshots[index]) != 0) {
                if (std.c._errno().* != @backingInt(std.c.E.INTR)) break;
            }
        }
    }
};

const Windows = struct {
    var modes: [3]?u32 = @splat(null);
    var input_codepage: u32 = 0;
    var output_codepage: u32 = 0;
    var handler_registered: std.atomic.Value(bool) = .init(false);

    fn init() void {
        const c = bun.c;
        const kinds = [_]u32{ c.STD_INPUT_HANDLE, c.STD_OUTPUT_HANDLE, c.STD_ERROR_HANDLE };
        for (kinds, 0..) |kind, index| {
            const fd: c_int = @intCast(index);
            const raw = crt._get_osfhandle(fd);
            const valid = valid: {
                if (raw == 0 or raw == -1 or raw == -2) break :valid false;
                c.SetLastError(0);
                const file_type = c.GetFileType(@ptrFromInt(@as(usize, @bitCast(raw))));
                break :valid file_type != c.FILE_TYPE_UNKNOWN or c.GetLastError() == 0;
            };
            if (!valid) {
                _ = crt._close(fd);
                const null_fd = crt._open("nul", crt._O_RDWR);
                if (null_fd < 0) std.c.abort();
                if (null_fd != fd) {
                    defer _ = crt._close(null_fd);
                    if (crt._dup2(null_fd, fd) != 0) std.c.abort();
                }
                const handle = crt._get_osfhandle(fd);
                if (handle == 0 or handle == -1 or handle == -2) std.c.abort();
                if (c.SetStdHandle(kind, @ptrFromInt(@as(usize, @bitCast(handle)))) == 0) std.c.abort();
                missing[index] = true;
            }
        }
        bun.windows.libuv.uv_disable_stdio_inheritance();

        const handles = [_]std.os.windows.HANDLE{
            std.Io.File.stdin().handle,
            std.Io.File.stdout().handle,
            std.Io.File.stderr().handle,
        };
        const fd_internals = @import("../sys/fd.zig");
        const invalid_handle = std.os.windows.INVALID_HANDLE_VALUE;
        fd_internals.windows_cached_stdin = if (handles[0] != invalid_handle) .fromSystem(handles[0]) else .invalid;
        fd_internals.windows_cached_stdout = if (handles[1] != invalid_handle) .fromSystem(handles[1]) else .invalid;
        fd_internals.windows_cached_stderr = if (handles[2] != invalid_handle) .fromSystem(handles[2]) else .invalid;
        if (Environment.isDebug) fd_internals.windows_cached_fd_set = true;

        input_codepage = c.GetConsoleCP();
        output_codepage = c.GetConsoleOutputCP();
        for (handles, 0..) |handle, index| {
            var mode: u32 = undefined;
            if (c.GetConsoleMode(handle, &mode) != 0) modes[index] = mode;
        }
        _ = c.SetConsoleCP(65001);
        _ = c.SetConsoleOutputCP(65001);
    }

    fn restore() void {
        const c = bun.c;
        const parameters = std.os.windows.peb().ProcessParameters;
        const handles = .{ parameters.hStdInput, parameters.hStdOutput, parameters.hStdError };
        inline for (handles, 0..) |handle, index| {
            if (modes[index]) |mode| _ = c.SetConsoleMode(handle, mode);
        }
        if (output_codepage != 0) _ = c.SetConsoleOutputCP(output_codepage);
        if (input_codepage != 0) _ = c.SetConsoleCP(input_codepage);
    }

    fn onControl(event: bun.windows.DWORD) callconv(.winapi) bun.windows.BOOL {
        if (event == bun.windows.CTRL_C_EVENT) {
            Windows.restore();
            _ = bun.windows.SetConsoleCtrlHandler(onControl, .FALSE);
            handler_registered.store(false, .release);
        }
        return .FALSE;
    }
};

pub fn enableConsoleControlHandler() void {
    if (comptime !Environment.isWindows) return;
    if (!ready.load(.acquire)) return;
    if (Windows.handler_registered.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    if (bun.windows.SetConsoleCtrlHandler(Windows.onControl, .TRUE) == .FALSE) {
        Windows.handler_registered.store(false, .release);
    }
}

const std = @import("std");
const bun = @import("bun");
const Environment = @import("./env.zig");
const crt = @import("libc-stdio");
