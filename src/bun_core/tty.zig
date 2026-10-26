pub const Mode = enum(c_int) {
    normal = 0,
    raw = 1,
    io = 2,
};

const Termios = if (Environment.isPosix) std.posix.termios else void;

var original_termios_fd: c_int = -1;
var original_termios: Termios = if (Environment.isPosix) undefined else {};
var original_tty_termios: Termios = if (Environment.isPosix) undefined else {};
var current_mode: Mode = .normal;
var original_termios_lock = std.atomic.Value(bool).init(false);
var reset_registered = std.atomic.Value(bool).init(false);

pub fn setMode(fd: c_int, mode: Mode) c_int {
    if (comptime Environment.isWindows) return setWindowsMode(fd, mode);
    if (comptime !Environment.isPosix) return 0;
    if (current_mode == mode) return 0;

    if (current_mode == .normal and mode != .normal) {
        const result = getTermios(fd, &original_tty_termios);
        if (result != 0) return result;

        lockOriginalTermios();
        if (original_termios_fd == -1) {
            original_termios = original_tty_termios;
            original_termios_fd = fd;
        }
        original_termios_lock.store(false, .seq_cst);
    }

    var termios = original_tty_termios;
    switch (mode) {
        .normal => {},
        .raw => makeRawMode(&termios),
        .io => makeIOMode(&termios),
    }

    if (mode != .normal) registerReset();
    ProcessStdio.markModified(fd);

    const result = setTermios(fd, .DRAIN, &termios);
    if (result == 0) current_mode = mode;
    return result;
}

fn setWindowsMode(fd: c_int, mode: Mode) c_int {
    const c = bun.c;
    const handle = bun.FD.fromUV(fd).native();
    var current: u32 = undefined;
    if (c.GetConsoleMode(handle, &current) == 0) return @backingInt(bun.windows.getLastErrno());
    var events: u32 = undefined;
    if (c.GetNumberOfConsoleInputEvents(handle, &events) == 0) return @backingInt(bun.sys.E.INVAL);
    const flags: u32 = switch (mode) {
        .normal => c.ENABLE_ECHO_INPUT | c.ENABLE_LINE_INPUT | c.ENABLE_PROCESSED_INPUT,
        .raw => c.ENABLE_WINDOW_INPUT,
        .io => return @backingInt(bun.sys.E.NOTSUP),
    };
    if (mode == .raw and c.SetConsoleMode(handle, flags | c.ENABLE_VIRTUAL_TERMINAL_INPUT) != 0) return 0;
    if (c.SetConsoleMode(handle, flags) == 0) return @backingInt(bun.windows.getLastErrno());
    return 0;
}

pub fn resetMode() callconv(.c) c_int {
    if (comptime !Environment.isPosix) return bun.windows.libuv.uv_tty_reset_mode();

    const saved_errno = std.c._errno().*;
    if (original_termios_lock.swap(true, .seq_cst)) return @backingInt(std.c.E.BUSY);
    defer {
        original_termios_lock.store(false, .seq_cst);
        std.c._errno().* = saved_errno;
    }

    if (original_termios_fd == -1) return 0;
    return setTermios(original_termios_fd, .NOW, &original_termios);
}

/// Reopening gives the reader independent file status flags; duplicating a
/// descriptor would make O_NONBLOCK affect the inherited terminal as well.
pub fn reopenForNonblockingRead(fd: c_int) ?c_int {
    if (comptime !Environment.isPosix) return null;
    const c = bun.c;
    var probe: if (Environment.isMac) [128]u8 else c_int = undefined;
    const request = if (Environment.isMac)
        c.TIOCPTYGNAME
    else if (Environment.isFreeBSD)
        c.TIOCPTMASTER
    else
        c.TIOCGPTN;
    while (true) {
        if (c.ioctl(fd, request, &probe) == 0) return null;
        if (std.c._errno().* != @backingInt(std.c.E.INTR)) break;
    }
    var path: bun.PathBuffer = undefined;
    while (true) {
        const result = c.ttyname_r(fd, &path, path.len);
        if (result == 0) break;
        if (result != @backingInt(std.c.E.INTR)) return null;
    }
    const length = std.mem.indexOfScalar(u8, &path, 0) orelse return null;
    const name = path[0..length :0];
    while (true) {
        const opened = std.c.open(name.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true });
        if (opened >= 0) return opened;
        if (std.c._errno().* != @backingInt(std.c.E.INTR)) return null;
    }
}

fn makeRawMode(termios: *Termios) void {
    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.oflag.ONLCR = true;
    termios.cflag.CSIZE = .CS8;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    termios.cc[@backingInt(std.c.V.MIN)] = 1;
    termios.cc[@backingInt(std.c.V.TIME)] = 0;
}

fn makeIOMode(termios: *Termios) void {
    termios.iflag.IGNBRK = false;
    termios.iflag.BRKINT = false;
    termios.iflag.PARMRK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.INLCR = false;
    termios.iflag.IGNCR = false;
    termios.iflag.ICRNL = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.lflag.ECHO = false;
    termios.lflag.ECHONL = false;
    termios.lflag.ICANON = false;
    termios.lflag.ISIG = false;
    termios.lflag.IEXTEN = false;
    termios.cflag.CSIZE = .CS8;
    termios.cflag.PARENB = false;
    termios.cc[@backingInt(std.c.V.MIN)] = 1;
    termios.cc[@backingInt(std.c.V.TIME)] = 0;
}

fn getTermios(fd: c_int, out: *Termios) c_int {
    while (true) {
        if (std.c.tcgetattr(fd, out) == 0) return 0;
        const err = std.c._errno().*;
        if (err != @backingInt(std.c.E.INTR)) return err;
    }
}

fn setTermios(fd: c_int, action: std.c.TCSA, termios: *const Termios) c_int {
    while (true) {
        if (std.c.tcsetattr(fd, action, termios) == 0) return 0;
        const err = std.c._errno().*;
        if (err != @backingInt(std.c.E.INTR)) return err;
    }
}

fn lockOriginalTermios() void {
    while (original_termios_lock.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {}
}

fn registerReset() void {
    if (reset_registered.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
        ProcessLifecycle.addExitCallback(&resetModeAtExit);
    }
}

fn resetModeAtExit() callconv(.c) void {
    _ = resetMode();
}

fn bindSetModeNative(
    args: bun.bindgen.Args(SetModeNativeSchema),
) bun.bindgen.Return(SetModeNativeSchema) {
    const mode: Mode = switch (args.mode) {
        0 => .normal,
        1 => .raw,
        2 => .io,
        else => return @backingInt(std.c.E.INVAL),
    };
    return setMode(args.fd, mode);
}

fn bindEnableConsoleControlHandler(
    _: bun.bindgen.Args(EnableConsoleControlHandlerSchema),
) bun.bindgen.Return(EnableConsoleControlHandlerSchema) {
    ProcessStdio.enableConsoleControlHandler();
}

const std = @import("std");
const bun = @import("bun");
const Environment = @import("./env.zig");
const ProcessLifecycle = @import("./ProcessLifecycle.zig");
const ProcessStdio = @import("./ProcessStdio.zig");
const ProcessTTYBindings = bun.bindgen.Module("ProcessTTY");
const SetModeNativeSchema = ProcessTTYBindings.nativeExport("setModeNative");
const SetModeNativeBinding = bun.bindgen.Fn(SetModeNativeSchema, bindSetModeNative);
const EnableConsoleControlHandlerSchema = ProcessTTYBindings.nativeExport("enableConsoleControlHandler");
const EnableConsoleControlHandlerBinding = bun.bindgen.Fn(EnableConsoleControlHandlerSchema, bindEnableConsoleControlHandler);

comptime {
    _ = SetModeNativeBinding;
    _ = EnableConsoleControlHandlerBinding;
    if (Environment.isPosix) {
        @export(&resetMode, .{ .name = "uv_tty_reset_mode" });
    }
}
