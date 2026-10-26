//! Bun.Terminal - Creates a pseudo-terminal (PTY) for interactive terminal sessions.
//!
//! This module provides a Terminal class that creates a PTY master/slave pair,
//! allowing JavaScript code to interact with terminal-based programs.
//!
const Terminal = @This();

const log = bun.Output.scoped(.Terminal, .hidden);

// Reference counting for Terminal
// Refs are held by:
// 1. JS binding
// 2. Reader (released in onReaderDone/onReaderError)
// 3. Writer (released in onWriterClose)
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

ref_count: RefCount,

/// The master side of the PTY (original fd, used for ioctl operations)
/// On Windows this is always invalid_fd; ConPTY uses hpcon for control.
master_fd: bun.FD,

/// Duplicated master fd for reading (POSIX) / overlapped read pipe end (Windows)
read_fd: bun.FD,

/// Duplicated master fd for writing (POSIX) / overlapped write pipe end (Windows)
write_fd: bun.FD,

/// The slave side of the PTY (used by child processes). Unused on Windows.
slave_fd: bun.FD,

/// Windows ConPTY handle. Used for resize and passed to uv_spawn via
/// uv_process_options_t.pseudoconsole.
hpcon: if (Environment.isWindows) ?bun.windows.HPCON else void = if (Environment.isWindows) null else {},

/// Current terminal size
cols: u16,
rows: u16,

/// Event loop handle for callbacks
event_loop_handle: jsc.EventLoopHandle,

/// Global object reference
globalThis: *jsc.JSGlobalObject,

/// Writer for sending data to the terminal
writer: IOWriter = .{},

/// Reader for receiving data from the terminal
reader: IOReader = IOReader.init(@This()),

normal_termios: if (Environment.isPosix) ?Termios else void = if (Environment.isPosix) null else {},

binding: ?*JSBinding = null,

/// State flags
flags: Flags = .{},

pub const Flags = packed struct(u8) {
    closed: bool = false,
    finalized: bool = false,
    raw_mode: bool = false,
    _padding: bool = false,
    reader_started: bool = false,
    reader_done: bool = false,
    writer_done: bool = false,
    /// Set when an inline-created terminal has been attached to a subprocess
    /// via spawn; prevents reusing the same inline terminal for a second
    /// spawn (which on Windows would be silently killed by ClosePseudoConsole
    /// when the first subprocess exits, and on POSIX has no slave_fd left).
    inline_spawned: bool = false,
};

pub const IOWriter = bun.io.StreamingWriter(@This(), struct {
    pub const onClose = Terminal.onWriterClose;
    pub const onWritable = Terminal.onWriterReady;
    pub const onError = Terminal.onWriterError;
    pub const onWrite = Terminal.onWrite;
});

/// Poll type alias for FilePoll Owner registration
pub const Poll = IOWriter;

pub const IOReader = bun.io.BufferedReader;

fn takeOptionalCallback(
    comptime CallbackType: type,
    source: *?bindgen.Callback(CallbackType),
) ?bindgen.Callback(CallbackType) {
    const callback = if (source.*) |*value| value.take() else return null;
    source.* = null;
    return callback;
}

/// Options for creating a Terminal
pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    term_name: bun.String.Slice = .{},
    data_callback: ?bindgen.Callback(TerminalDataCallbackType) = null,
    exit_callback: ?bindgen.Callback(TerminalExitCallbackType) = null,
    drain_callback: ?bindgen.Callback(TerminalDrainCallbackType) = null,

    /// Maximum length for terminal name (e.g., "xterm-256color")
    /// Longest known terminfo names are ~23 chars; 128 allows for custom terminals
    pub const max_term_name_len = 128;

    pub fn fromBindgen(generated: anytype) bun.JSError!Options {
        var result: Options = .{
            .cols = generated.cols,
            .rows = generated.rows,
            .term_name = try generated.name.toUTF8(bun.default_allocator),
        };
        errdefer result.deinit();
        result.data_callback = if (generated.data) |callback| try callback.toOwned() else null;
        result.exit_callback = if (generated.exit) |callback| try callback.toOwned() else null;
        result.drain_callback = if (generated.drain) |callback| try callback.toOwned() else null;
        return result;
    }

    pub fn deinit(this: *Options) void {
        this.term_name.deinit();
        if (this.data_callback) |*callback| callback.deinit();
        if (this.exit_callback) |*callback| callback.deinit();
        if (this.drain_callback) |*callback| callback.deinit();
        this.* = .{};
    }
};

/// Result from creating a Terminal
pub const CreateResult = struct {
    terminal: *Terminal,
    reference: Ref,
};

pub const InitError = CreatePtyError || bun.OOM || error{ WriterStartFailed, ReaderStartFailed };

pub const JSBinding = struct {
    const BindingRefCount = bun.ptr.RefCount(@This(), "ref_count", bindingDeinit, .{});

    pub const ref = BindingRefCount.ref;
    pub const deref = BindingRefCount.deref;
    pub const derefDeferred = BindingRefCount.derefDeferred;
    pub const destroyAfterDeferred = BindingRefCount.destroyAfterDeferred;

    ref_count: BindingRefCount = .init(),
    bindgen_state: bindgen.ClassState = .{},
    terminal: bindgen.RefNative(Terminal, .vm),
    data_callback: ?bindgen.Callback(TerminalDataCallbackType) = null,
    drain_callback: ?bindgen.Callback(TerminalDrainCallbackType) = null,
    exit_callback: ?bindgen.Callback(TerminalExitCallbackType) = null,
    awaiting_initial_wrapper: bool = true,
    weak_wrapper: bindgen.ClassWrapperHandle(TerminalClassSchema, .weak) = .empty,

    pub fn construct(
        context: bindgen.CallContext(TerminalConstructorSchema),
        args: bindgen.Args(TerminalConstructorSchema),
    ) bindgen.CallError(TerminalConstructorSchema)!*JSBinding {
        const options_argument = args.options orelse return context.fail(.missing_options, {});
        var options = try Options.fromBindgen(&options_argument);
        defer options.deinit();
        if (options.term_name.length() > Options.max_term_name_len) return context.fail(.name_too_long, {});

        const binding = initTerminal(context.viewToken().globalObject(), &options) catch |err| return switch (err) {
            error.OpenPtyFailed => context.fail(.open_pty_failed, {}),
            error.DupFailed => context.fail(.dup_failed, {}),
            error.NotSupported => context.fail(.not_supported, {}),
            error.WriterStartFailed => context.fail(.writer_start_failed, {}),
            error.ReaderStartFailed => context.fail(.reader_start_failed, {}),
            error.OutOfMemory => error.OutOfMemory,
        };
        return binding;
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        const terminal = this.terminal.get();
        return !terminal.flags.finalized and terminal.flags.reader_started and !terminal.flags.reader_done;
    }

    pub fn bindAsyncDisposeNative(
        this: *JSBinding,
        _: bindgen.CallContext(TerminalAsyncDisposeNativeSchema),
        _: bindgen.Args(TerminalAsyncDisposeNativeSchema),
    ) bun.JSError!void {
        this.terminal.get().asyncDispose();
    }

    pub fn bindClose(
        this: *JSBinding,
        _: bindgen.CallContext(TerminalCloseSchema),
        _: bindgen.Args(TerminalCloseSchema),
    ) bun.JSError!void {
        this.terminal.get().close();
    }

    pub fn bindGetClosed(
        this: *JSBinding,
        _: bindgen.CallContext(TerminalClosedSchema),
        _: bindgen.Args(TerminalClosedSchema),
    ) bun.JSError!bool {
        return this.terminal.get().getClosed();
    }

    fn FlagProperty(comptime name: []const u8, comptime field: TermiosFlag) type {
        const Getter = TerminalClassSchema.memberKind(name, .getter);
        const Setter = TerminalClassSchema.memberKind(name, .setter);
        return struct {
            fn get(
                this: *JSBinding,
                _: bindgen.CallContext(Getter),
                _: bindgen.Args(Getter),
            ) bun.JSError!u32 {
                return this.terminal.get().getTermiosFlag(field);
            }

            fn set(
                this: *JSBinding,
                context: bindgen.CallContext(Setter),
                args: bindgen.Args(Setter),
            ) bun.JSError!void {
                const terminal = this.terminal.get();
                if (!terminal.canSetTermiosFlag()) return;
                const value = try args.value.convert(context);
                terminal.setTermiosFlag(field, value.value);
            }
        };
    }

    pub const bindGetControlFlags = FlagProperty("controlFlags", .cflag).get;
    pub const bindSetControlFlags = FlagProperty("controlFlags", .cflag).set;
    pub const bindGetInputFlags = FlagProperty("inputFlags", .iflag).get;
    pub const bindSetInputFlags = FlagProperty("inputFlags", .iflag).set;
    pub const bindGetLocalFlags = FlagProperty("localFlags", .lflag).get;
    pub const bindSetLocalFlags = FlagProperty("localFlags", .lflag).set;
    pub const bindGetOutputFlags = FlagProperty("outputFlags", .oflag).get;
    pub const bindSetOutputFlags = FlagProperty("outputFlags", .oflag).set;

    pub fn bindRef(
        this: *JSBinding,
        _: bindgen.CallContext(TerminalRefSchema),
        _: bindgen.Args(TerminalRefSchema),
    ) bun.JSError!void {
        this.terminal.get().doRef();
    }

    pub fn bindResize(
        this: *JSBinding,
        context: bindgen.CallContext(TerminalResizeSchema),
        args: bindgen.Args(TerminalResizeSchema),
    ) bindgen.CallError(TerminalResizeSchema)!void {
        try this.terminal.get().resize(context, args.cols, args.rows);
    }

    pub fn bindSetRawMode(
        this: *JSBinding,
        context: bindgen.CallContext(TerminalSetRawModeSchema),
        args: bindgen.Args(TerminalSetRawModeSchema),
    ) bindgen.CallError(TerminalSetRawModeSchema)!void {
        try this.terminal.get().setRawMode(context, args.enabled orelse false);
    }

    pub fn bindUnref(
        this: *JSBinding,
        _: bindgen.CallContext(TerminalUnrefSchema),
        _: bindgen.Args(TerminalUnrefSchema),
    ) bun.JSError!void {
        this.terminal.get().doUnref();
    }

    pub fn bindWrite(
        this: *JSBinding,
        context: bindgen.CallContext(TerminalWriteSchema),
        args: bindgen.Args(TerminalWriteSchema),
    ) bindgen.CallError(TerminalWriteSchema)!u64 {
        return this.terminal.get().write(context, args.data);
    }

    pub fn wrapperCreated(this: *JSBinding, wrapper: bindgen.ClassRefView(TerminalClassSchema)) bun.JSError!void {
        if (!this.awaiting_initial_wrapper) return;
        var receiver = try wrapper.toOwned();
        defer receiver.deinit();
        const weak_wrapper = try TerminalClass.WeakWrapper.initView(wrapper);
        this.awaiting_initial_wrapper = false;
        const terminal = this.terminal.get();
        this.weak_wrapper.deinit();
        this.weak_wrapper = weak_wrapper;
        attachCallback(TerminalDataCallbackSlot, &this.data_callback, &receiver);
        attachCallback(TerminalDrainCallbackSlot, &this.drain_callback, &receiver);
        attachCallback(TerminalExitCallbackSlot, &this.exit_callback, &receiver);
        if (!terminal.flags.closed and !terminal.flags.reader_done) terminal.reader.read();
    }

    fn attachCallback(comptime Slot: type, callback: anytype, receiver: anytype) void {
        if (callback.*) |*value| {
            Slot.setOwnedCallbackOnOwned(receiver, value);
            value.deinit();
            callback.* = null;
        }
    }

    fn wrapperRef(this: *const JSBinding) bun.JSError!?Ref {
        return this.weak_wrapper.toOwned();
    }

    fn bindingDeinit(this: *JSBinding) void {
        const terminal = this.terminal.get();
        if (terminal.binding == this) terminal.binding = null;
        terminal.flags.finalized = true;
        terminal.closeInternal();
        this.weak_wrapper.deinit();
        if (this.data_callback) |*callback| callback.deinit();
        if (this.drain_callback) |*callback| callback.deinit();
        if (this.exit_callback) |*callback| callback.deinit();
        this.terminal.deinit();
        bun.destroy(this);
    }
};

pub fn initTerminal(
    globalObject: *jsc.JSGlobalObject,
    options: *Options,
) InitError!*JSBinding {
    const resources = resources: {
        const terminal = try bun.default_allocator.create(Terminal);
        errdefer bun.default_allocator.destroy(terminal);
        const binding = try bun.default_allocator.create(JSBinding);
        errdefer bun.default_allocator.destroy(binding);
        break :resources .{
            .terminal = terminal,
            .binding = binding,
            .pty = try createPty(options.cols, options.rows),
        };
    };
    const terminal = resources.terminal;
    const binding = resources.binding;
    const pty_result = resources.pty;
    terminal.* = .{
        .ref_count = .init(),
        .master_fd = pty_result.master,
        .read_fd = pty_result.read_fd,
        .write_fd = pty_result.write_fd,
        .slave_fd = pty_result.slave,
        .hpcon = if (comptime Environment.isWindows) pty_result.hpcon else {},
        .cols = if (Environment.isWindows) @intCast(clampToCoord(options.cols)) else options.cols,
        .rows = if (Environment.isWindows) @intCast(clampToCoord(options.rows)) else options.rows,
        .event_loop_handle = jsc.EventLoopHandle.init(globalObject.bunVM().eventLoop()),
        .globalThis = globalObject,
    };
    binding.* = .{
        .terminal = .adopt(terminal),
        .data_callback = takeOptionalCallback(TerminalDataCallbackType, &options.data_callback),
        .drain_callback = takeOptionalCallback(TerminalDrainCallbackType, &options.drain_callback),
        .exit_callback = takeOptionalCallback(TerminalExitCallbackType, &options.exit_callback),
    };
    terminal.binding = binding;

    // Set reader parent
    terminal.reader.setParent(terminal);

    // Set writer parent
    terminal.writer.parent = terminal;

    // Start writer with the write fd - adds a ref
    switch (terminal.writer.start(pty_result.write_fd, .{ .ofd_ownership = .exclusive })) {
        .result => terminal.ref(),
        .err => |err| {
            // Pre-set writer_done so onWriterClose's deref is skipped and the
            // struct isn't freed mid-closeInternal.
            terminal.flags.writer_done = true;
            terminal.read_fd.close();
            terminal.read_fd = bun.invalid_fd;
            terminal.write_fd.close();
            terminal.write_fd = bun.invalid_fd;
            terminal.closeInternal();
            binding.bindingDeinit();
            if (err.getErrno() == .NOMEM) return error.OutOfMemory;
            return error.WriterStartFailed;
        },
    }

    // Start reader with the read fd - adds a ref
    switch (terminal.reader.start(pty_result.read_fd, true)) {
        .err => |err| {
            if (comptime Environment.isWindows) terminal.read_fd.close();
            terminal.read_fd = bun.invalid_fd;
            terminal.closeInternal();
            binding.bindingDeinit();
            if (err.getErrno() == .NOMEM) return error.OutOfMemory;
            return error.ReaderStartFailed;
        },
        .result => {
            terminal.ref();
            if (comptime Environment.isPosix) {
                if (terminal.reader.handle == .poll) {
                    const poll = terminal.reader.handle.poll;
                    // PTY behaves like a pipe, not a socket
                    terminal.reader.flags.nonblocking = true;
                    terminal.reader.flags.pollable = true;
                    poll.flags.insert(.nonblocking);
                }
            }
            terminal.flags.reader_started = true;
        },
    }

    return binding;
}

pub fn createFromSpawn(
    globalObject: *jsc.JSGlobalObject,
    options: *Options,
) (InitError || bun.JSError)!CreateResult {
    const binding = try initTerminal(globalObject, options);
    const terminal = binding.terminal.get();
    const reference = try TerminalClass.adoptNativeRef(binding, globalObject);
    return .{ .terminal = terminal, .reference = reference };
}

pub const Handle = struct {
    binding: TerminalClass.Handle,

    pub fn get(this: *const Handle) *Terminal {
        return this.binding.get().terminal.get();
    }

    pub fn deinit(this: *Handle) void {
        this.binding.deinit();
    }
};

pub const Ref = bindgen.ClassRef(TerminalClassSchema);

pub fn wrapperRef(this: *Terminal) bun.JSError!?Ref {
    const binding = this.binding orelse return null;
    return binding.wrapperRef();
}

/// Get the slave fd for subprocess to use
pub fn getSlaveFd(this: *Terminal) bun.FD {
    return this.slave_fd;
}

/// Windows: get the ConPTY handle to pass to uv_spawn via
/// uv_process_options_t.pseudoconsole.
pub fn getPseudoconsole(this: *Terminal) ?bun.windows.HPCON {
    if (comptime !Environment.isWindows) return null;
    return this.hpcon;
}

/// Close the parent's copy of slave_fd after fork
/// The child process has its own copy - closing the parent's ensures
/// EOF is received on the master side when the child exits
pub fn closeSlaveFd(this: *Terminal) void {
    this.flags.inline_spawned = true;
    if (this.slave_fd != bun.invalid_fd) {
        this.slave_fd.close();
        this.slave_fd = bun.invalid_fd;
    }
}

/// Windows: close only the ConPTY handle so conhost releases its pipe ends and
/// our reader observes EOF. Leaves the Terminal itself open (closed=false),
/// matching POSIX semantics where child exit delivers EOF without closing the
/// master fd.
pub fn closePseudoconsole(this: *Terminal) void {
    if (comptime !Environment.isWindows) return;
    if (this.hpcon) |hpcon| {
        this.hpcon = null;
        this.closePseudoconsoleOffThread(hpcon);
    }
}

/// On Windows < 11 24H2, ClosePseudoConsole blocks until the output pipe is
/// drained. Our reader runs on the event-loop thread, so calling it there
/// deadlocks. Fire from a detached thread so the event loop keeps draining;
/// conhost completes its flush and our reader sees the final data then EOF.
/// hpcon is passed to the thread by value so the Terminal struct may be freed
/// before the thread completes.
fn closePseudoconsoleOffThread(this: *Terminal, hpcon: bun.windows.HPCON) void {
    if (comptime !Environment.isWindows) return;
    const Runner = struct {
        fn run(h: bun.windows.HPCON) void {
            bun.windows.ClosePseudoConsole(h);
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{hpcon}) catch {
        // CreateThread failed — the process is in a bad state. Close the
        // reader so onReaderDone fires next loop tick (releasing the reader
        // ref) instead of hanging on an EOF that will never come. Leak hpcon;
        // calling ClosePseudoConsole here would deadlock since reader.close()
        // is async (uv_close) and the pipe HANDLE is still open. Conhost sees
        // broken-pipe once libuv's deferred close runs.
        if (this.flags.reader_started and !this.flags.reader_done) this.reader.close();
        return;
    };
    t.detach();
}

const PtyResult = struct {
    master: bun.FD,
    read_fd: bun.FD,
    write_fd: bun.FD,
    slave: bun.FD,
    hpcon: if (Environment.isWindows) bun.windows.HPCON else void,
};

const CreatePtyError = error{ OpenPtyFailed, DupFailed, NotSupported };

fn createPty(cols: u16, rows: u16) CreatePtyError!PtyResult {
    if (comptime Environment.isPosix) {
        return createPtyPosix(cols, rows);
    }
    if (comptime Environment.isWindows) {
        return createPtyWindows(cols, rows);
    }
    return error.NotSupported;
}

// OpenPtyTermios is required for the openpty() extern signature even though we pass null.
// Kept for type correctness of the C function declaration.
const OpenPtyTermios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_cc: [20]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const OpenPtyFn = *const fn (
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*const OpenPtyTermios,
    winp: ?*const Winsize,
) callconv(.c) c_int;

/// Dynamic loading of openpty on Linux (it's in libutil which may not be linked)
const LibUtil = struct {
    fn loadHandle() ?*anyopaque {
        // Try libutil.so first (most common), then libutil.so.1
        const lib_names = [_][:0]const u8{ "libutil.so", "libutil.so.1", "libc.so.6" };
        for (lib_names) |lib_name| {
            if (bun.sys.dlopen(lib_name, .{ .LAZY = true })) |handle| return handle;
        }
        return null;
    }

    var handle_once = bun.threadedOnce(loadHandle);

    pub fn getHandle() ?*anyopaque {
        return handle_once.call(.{});
    }

    pub fn getOpenPty() ?OpenPtyFn {
        return bun.sys.dlsymWithHandle(OpenPtyFn, "openpty", getHandle);
    }
};

fn getOpenPtyFn() ?OpenPtyFn {
    // On macOS, openpty is in libc, so we can use it directly
    if (comptime Environment.isMac) {
        const c = struct {
            extern "c" fn openpty(
                amaster: *c_int,
                aslave: *c_int,
                name: ?[*]u8,
                termp: ?*const OpenPtyTermios,
                winp: ?*const Winsize,
            ) c_int;
        };
        return &c.openpty;
    }

    // On Linux, openpty is in libutil, which may not be linked
    // Load it dynamically via dlopen
    if (comptime Environment.isLinux) {
        return LibUtil.getOpenPty();
    }

    return null;
}

fn createPtyPosix(cols: u16, rows: u16) CreatePtyError!PtyResult {
    const openpty_fn = getOpenPtyFn() orelse {
        return error.NotSupported;
    };

    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;

    const winsize = Winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const result = openpty_fn(&master_fd, &slave_fd, null, null, &winsize);
    if (result != 0) {
        return error.OpenPtyFailed;
    }

    const master_fd_desc = bun.FD.fromNative(master_fd);
    const slave_fd_desc = bun.FD.fromNative(slave_fd);

    // Configure sensible terminal defaults matching node-pty behavior.
    // These are "cooked mode" defaults that most terminal applications expect.
    if (std.posix.tcgetattr(slave_fd)) |termios| {
        var t = termios;

        // Input flags: standard terminal input processing
        t.iflag = .{
            .ICRNL = true, // Map CR to NL on input
            .IXON = true, // Enable XON/XOFF flow control on output
            .IXANY = true, // Any character restarts output
            .IMAXBEL = true, // Ring bell on input queue full
            .BRKINT = true, // Signal interrupt on break
        };
        // IUTF8: present in Linux/macOS/FreeBSD kernels but Zig std's
        // tc_iflag_t only exposes the field on Linux/macOS, so probe for it.
        if (comptime @hasField(@TypeOf(t.iflag), "IUTF8")) {
            t.iflag.IUTF8 = true;
        }

        // Output flags: standard terminal output processing
        t.oflag = .{
            .OPOST = true, // Enable output processing
            .ONLCR = true, // Map NL to CR-NL on output
        };

        // Control flags: 8-bit chars, enable receiver
        t.cflag = .{
            .CREAD = true, // Enable receiver
            .CSIZE = .CS8, // 8-bit characters
            .HUPCL = true, // Hang up on last close
        };

        // Local flags: canonical mode with echo and signals
        t.lflag = .{
            .ICANON = true, // Canonical input (line editing)
            .ISIG = true, // Enable signals (INTR, QUIT, SUSP)
            .IEXTEN = true, // Enable extended input processing
            .ECHO = true, // Echo input characters
            .ECHOE = true, // Echo erase as backspace-space-backspace
            .ECHOK = true, // Echo NL after KILL
            .ECHOKE = true, // Visual erase for KILL
            .ECHOCTL = true, // Echo control chars as ^X
        };

        // Control characters - standard defaults
        t.cc[@backingInt(std.posix.V.EOF)] = 4; // Ctrl-D
        t.cc[@backingInt(std.posix.V.EOL)] = 0; // Disabled
        t.cc[@backingInt(std.posix.V.ERASE)] = 0x7f; // DEL (backspace)
        t.cc[@backingInt(std.posix.V.WERASE)] = 23; // Ctrl-W
        t.cc[@backingInt(std.posix.V.KILL)] = 21; // Ctrl-U
        t.cc[@backingInt(std.posix.V.REPRINT)] = 18; // Ctrl-R
        t.cc[@backingInt(std.posix.V.INTR)] = 3; // Ctrl-C
        t.cc[@backingInt(std.posix.V.QUIT)] = 0x1c; // Ctrl-backslash
        t.cc[@backingInt(std.posix.V.SUSP)] = 26; // Ctrl-Z
        t.cc[@backingInt(std.posix.V.START)] = 17; // Ctrl-Q (XON)
        t.cc[@backingInt(std.posix.V.STOP)] = 19; // Ctrl-S (XOFF)
        t.cc[@backingInt(std.posix.V.LNEXT)] = 22; // Ctrl-V
        t.cc[@backingInt(std.posix.V.DISCARD)] = 15; // Ctrl-O
        t.cc[@backingInt(std.posix.V.MIN)] = 1; // Min chars for non-canonical read
        t.cc[@backingInt(std.posix.V.TIME)] = 0; // Timeout for non-canonical read

        // Set baud rate to 38400 (standard for PTYs)
        t.ispeed = .B38400;
        t.ospeed = .B38400;

        std.posix.tcsetattr(slave_fd, .NOW, t) catch {};
    } else |err| {
        // tcgetattr failed, log in debug builds but continue without modifying termios
        if (comptime bun.Environment.allow_assert) {
            bun.sys.syslog("tcgetattr(slave_fd={d}) failed: {s}", .{ slave_fd, @errorName(err) });
        }
    }

    // Duplicate the master fd for reading and writing separately
    // This allows independent epoll registration and closing
    const read_fd = switch (bun.sys.dup(master_fd_desc)) {
        .result => |fd| fd,
        .err => {
            master_fd_desc.close();
            slave_fd_desc.close();
            return error.DupFailed;
        },
    };

    const write_fd = switch (bun.sys.dup(master_fd_desc)) {
        .result => |fd| fd,
        .err => {
            master_fd_desc.close();
            slave_fd_desc.close();
            read_fd.close();
            return error.DupFailed;
        },
    };

    // Set non-blocking on master side fds (for async I/O in the event loop)
    _ = bun.sys.updateNonblocking(master_fd_desc, true);
    _ = bun.sys.updateNonblocking(read_fd, true);
    _ = bun.sys.updateNonblocking(write_fd, true);
    // Note: slave_fd stays blocking - child processes expect blocking I/O

    // Set close-on-exec on master side fds only
    // slave_fd should NOT have close-on-exec since child needs to inherit it
    _ = bun.sys.setCloseOnExec(master_fd_desc);
    _ = bun.sys.setCloseOnExec(read_fd);
    _ = bun.sys.setCloseOnExec(write_fd);

    return PtyResult{
        .master = master_fd_desc,
        .read_fd = read_fd,
        .write_fd = write_fd,
        .slave = slave_fd_desc,
        .hpcon = {},
    };
}

/// Create one end of a pipe pair as an overlapped named pipe (server) and the
/// other as a synchronous client. Returns both raw HANDLEs. Caller closes
/// both on error. The "server" end is suitable for libuv (uv_pipe_open) and
/// the "client" end is suitable for ConPTY (which uses synchronous I/O).
fn createOverlappedPipePair(
    /// PIPE_ACCESS_INBOUND: server reads, client writes.
    /// PIPE_ACCESS_OUTBOUND: server writes, client reads.
    server_access: u32,
) CreatePtyError!struct { server: bun.windows.HANDLE, client: bun.windows.HANDLE } {
    const w = bun.windows;
    const k32 = bun.c;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;

    const pid: u32 = std.os.windows.GetCurrentProcessId();
    const counter = pipe_serial.fetchAdd(1, .monotonic);
    var name_utf8_buf: [96]u8 = undefined;
    const name = std.fmt.bufPrint(
        &name_utf8_buf,
        "\\\\.\\pipe\\bun-conpty-{d}-{d}",
        .{ pid, counter },
    ) catch return error.OpenPtyFailed;
    var name_w_buf: [96:0]u16 = undefined;
    const name_w_len = bun.strings.convertUTF8toUTF16InBuffer(&name_w_buf, name).len;
    name_w_buf[name_w_len] = 0;
    const name_w = name_w_buf[0..name_w_len :0];

    const server = k32.CreateNamedPipeW(
        name_w,
        server_access | w.FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT,
        1,
        65536,
        65536,
        0,
        null,
    );
    if (server == w.INVALID_HANDLE_VALUE) return error.OpenPtyFailed;
    errdefer _ = w.CloseHandle(server);

    const client_access: u32 = if (server_access == w.PIPE_ACCESS_INBOUND)
        w.GENERIC_WRITE
    else
        w.GENERIC_READ;

    const client = w.CreateFileW(
        name_w,
        client_access,
        0,
        null,
        w.OPEN_EXISTING,
        0,
        null,
    );
    if (client == w.INVALID_HANDLE_VALUE) return error.OpenPtyFailed;

    return .{ .server = server, .client = client };
}

var pipe_serial = std.atomic.Value(u32).init(0);

fn createPtyWindows(cols: u16, rows: u16) CreatePtyError!PtyResult {
    const w = bun.windows;

    // Track ownership explicitly: handles are nulled out as they are closed or
    // transferred so the errdefer cleanup never double-closes.
    var out_server: ?w.HANDLE = null;
    var out_client: ?w.HANDLE = null;
    var in_server: ?w.HANDLE = null;
    var in_client: ?w.HANDLE = null;
    var hpcon: ?w.HPCON = null;
    errdefer {
        if (hpcon) |h| w.ClosePseudoConsole(h);
        if (out_server) |h| _ = w.CloseHandle(h);
        if (out_client) |h| _ = w.CloseHandle(h);
        if (in_server) |h| _ = w.CloseHandle(h);
        if (in_client) |h| _ = w.CloseHandle(h);
    }

    // Output pipe: ConPTY writes (client), we read (overlapped server).
    {
        const pair = try createOverlappedPipePair(w.PIPE_ACCESS_INBOUND);
        out_server = pair.server;
        out_client = pair.client;
    }

    // Input pipe: we write (overlapped server), ConPTY reads (client).
    {
        const pair = try createOverlappedPipePair(w.PIPE_ACCESS_OUTBOUND);
        in_server = pair.server;
        in_client = pair.client;
    }

    const size = w.COORD{ .X = clampToCoord(cols), .Y = clampToCoord(rows) };
    {
        var pc: w.HPCON = undefined;
        if (w.CreatePseudoConsole(size, in_client.?, out_client.?, 0, &pc) < 0)
            return error.OpenPtyFailed;
        hpcon = pc;
    }

    // ConPTY duplicated the client handles internally; close our copies.
    _ = w.CloseHandle(in_client.?);
    in_client = null;
    _ = w.CloseHandle(out_client.?);
    out_client = null;

    // Wrap server (overlapped) ends as libuv-owned FDs so they can be passed
    // to BufferedReader/StreamingWriter.start() which calls uv_pipe_open.
    const read_fd = bun.FD.fromNative(out_server.?).makeLibUVOwned() catch return error.DupFailed;
    out_server = null;
    errdefer read_fd.close();

    const write_fd = bun.FD.fromNative(in_server.?).makeLibUVOwned() catch return error.DupFailed;
    in_server = null;

    const result_hpcon = hpcon.?;
    hpcon = null;

    return PtyResult{
        .master = bun.invalid_fd,
        .read_fd = read_fd,
        .write_fd = write_fd,
        .slave = bun.invalid_fd,
        .hpcon = result_hpcon,
    };
}

/// COORD.X/Y are i16; clamp the u16 cols/rows to its range.
inline fn clampToCoord(v: u16) i16 {
    return @intCast(@min(v, std.math.maxInt(i16)));
}

/// Check if terminal is closed
pub fn getClosed(this: *Terminal) bool {
    return this.flags.closed;
}

const TermiosFlag = enum { iflag, oflag, lflag, cflag };

fn getTermiosFlag(this: *Terminal, comptime field: TermiosFlag) u32 {
    if (comptime Environment.isPosix) {
        if (this.flags.closed or this.master_fd == bun.invalid_fd) return 0;
        const termios_data = getTermios(this.master_fd) orelse return 0;
        const flag = @field(termios_data, @tagName(field));
        const Int = @typeInfo(@TypeOf(flag)).@"struct".backing_integer.?;
        return @intCast(@as(Int, @bitCast(flag)));
    }
    return 0;
}

fn canSetTermiosFlag(this: *const Terminal) bool {
    return Environment.isPosix and !this.flags.closed and this.master_fd != bun.invalid_fd;
}

fn setTermiosFlag(this: *Terminal, comptime field: TermiosFlag, value: u32) void {
    if (comptime Environment.isPosix) {
        if (!this.canSetTermiosFlag()) return;
        var termios_data = getTermios(this.master_fd) orelse return;
        const FlagType = @TypeOf(@field(termios_data, @tagName(field)));
        const Int = @typeInfo(FlagType).@"struct".backing_integer.?;
        @field(termios_data, @tagName(field)) = @bitCast(@as(Int, value));
        _ = setTermios(this.master_fd, &termios_data);
    }
}

/// Write data to the terminal
pub fn write(
    this: *Terminal,
    context: anytype,
    data: anytype,
) bun.bindgen.CallError(@TypeOf(context))!u64 {
    if (this.flags.closed) {
        return context.fail(.terminal_closed, {});
    }

    const string_or_buffer = try bun.api.node.StringOrBuffer.fromBindgen(data, .utf8);
    defer string_or_buffer.deinit();

    const bytes = string_or_buffer.slice();

    if (bytes.len == 0) {
        return 0;
    }

    // Write using the streaming writer
    const write_result = try this.writer.write(bytes);
    return switch (write_result) {
        .done => |amt| @intCast(amt),
        .wrote, .pending => @intCast(bytes.len),
        .err => |err| context.fail(.system, try bindgen.SystemError.fromSysError(err)),
    };
}

/// Resize the terminal
pub fn resize(
    this: *Terminal,
    context: anytype,
    new_cols: u16,
    new_rows: u16,
) bun.bindgen.CallError(@TypeOf(context))!void {
    if (this.flags.closed) {
        return context.fail(.terminal_closed, {});
    }

    if (comptime Environment.isPosix) {
        const ioctl_c = struct {
            const TIOCSWINSZ: c_ulong = if (Environment.isMac) 0x80087467 else 0x5414;

            const Winsize = extern struct {
                ws_row: u16,
                ws_col: u16,
                ws_xpixel: u16,
                ws_ypixel: u16,
            };

            extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
        };

        var winsize = ioctl_c.Winsize{
            .ws_row = new_rows,
            .ws_col = new_cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const ioctl_result = ioctl_c.ioctl(this.master_fd.cast(), ioctl_c.TIOCSWINSZ, &winsize);
        if (ioctl_result != 0) {
            return context.fail(.resize_failed, {});
        }
    }

    if (comptime Environment.isWindows) {
        if (this.hpcon) |hpcon| {
            const size = bun.windows.COORD{ .X = clampToCoord(new_cols), .Y = clampToCoord(new_rows) };
            const hr = bun.windows.ResizePseudoConsole(hpcon, size);
            if (hr < 0) {
                return context.fail(.resize_failed, {});
            }
        }
    }

    this.cols = if (Environment.isWindows) @intCast(clampToCoord(new_cols)) else new_cols;
    this.rows = if (Environment.isWindows) @intCast(clampToCoord(new_rows)) else new_rows;
}

/// Set raw mode on the terminal
pub fn setRawMode(
    this: *Terminal,
    context: anytype,
    enabled: bool,
) bun.bindgen.CallError(@TypeOf(context))!void {
    if (this.flags.closed) {
        return context.fail(.terminal_closed, {});
    }

    if (comptime Environment.isPosix) {
        if (enabled == this.flags.raw_mode) return;
        if (enabled) {
            const normal = getTermios(this.master_fd) orelse {
                return context.fail(.raw_mode_failed, {});
            };
            var raw = normal;
            makeTermiosRaw(&raw);
            if (!setTermiosAt(this.master_fd, .DRAIN, &raw)) {
                return context.fail(.raw_mode_failed, {});
            }
            this.normal_termios = normal;
        } else if (this.normal_termios) |normal| {
            if (!setTermiosAt(this.master_fd, .DRAIN, &normal)) {
                return context.fail(.raw_mode_failed, {});
            }
            this.normal_termios = null;
        } else {
            return;
        }
    }

    this.flags.raw_mode = enabled;
}

fn makeTermiosRaw(termios_p: *Termios) void {
    if (comptime Environment.isPosix) {
        termios_p.iflag.BRKINT = false;
        termios_p.iflag.ICRNL = false;
        termios_p.iflag.INPCK = false;
        termios_p.iflag.ISTRIP = false;
        termios_p.iflag.IXON = false;
        termios_p.oflag.ONLCR = true;
        termios_p.cflag.CSIZE = .CS8;
        termios_p.lflag.ECHO = false;
        termios_p.lflag.ICANON = false;
        termios_p.lflag.IEXTEN = false;
        termios_p.lflag.ISIG = false;
        termios_p.cc[@backingInt(std.c.V.MIN)] = 1;
        termios_p.cc[@backingInt(std.c.V.TIME)] = 0;
    }
}

fn restoreTermios(this: *Terminal) void {
    if (comptime Environment.isPosix) {
        if (this.normal_termios) |normal| {
            _ = setTermiosAt(this.master_fd, .NOW, &normal);
            this.normal_termios = null;
        }
    }
    this.flags.raw_mode = false;
}
/// POSIX termios struct for terminal flags manipulation
const Termios = if (Environment.isPosix) std.posix.termios else void;

/// Get terminal attributes using tcgetattr
fn getTermios(fd: bun.FD) ?Termios {
    if (comptime !Environment.isPosix) return null;
    return std.posix.tcgetattr(fd.cast()) catch null;
}

fn setTermiosAt(fd: bun.FD, action: std.posix.TCSA, termios_p: *const Termios) bool {
    if (comptime !Environment.isPosix) return false;
    std.posix.tcsetattr(fd.cast(), action, termios_p.*) catch return false;
    return true;
}

/// Set terminal attributes using tcsetattr (TCSANOW = immediate)
fn setTermios(fd: bun.FD, termios_p: *const Termios) bool {
    return setTermiosAt(fd, .NOW, termios_p);
}

/// Reference the terminal to keep the event loop alive
pub fn doRef(this: *Terminal) void {
    this.updateRef(true);
}

/// Unreference the terminal
pub fn doUnref(this: *Terminal) void {
    this.updateRef(false);
}

fn updateRef(this: *Terminal, add: bool) void {
    this.reader.updateRef(add);
    this.writer.updateRef(this.event_loop_handle, add);
}

/// Close the terminal
pub fn close(this: *Terminal) void {
    this.closeInternal();
}

/// Async dispose for "using" syntax
pub fn asyncDispose(this: *Terminal) void {
    // After dispose the caller must not see further data/exit callbacks.
    // closeInternal on Windows leaves the reader draining off-thread, so
    this.flags.finalized = true;
    this.closeInternal();
}

pub fn abortCreation(this: *Terminal) void {
    this.flags.finalized = true;
    this.closeInternal();
}

pub fn closeInternal(this: *Terminal) void {
    if (this.flags.closed) return;
    this.restoreTermios();
    this.flags.closed = true;

    // Close writer (closes write_fd)
    this.writer.close();
    this.write_fd = bun.invalid_fd;

    if (comptime Environment.isWindows) {
        // Dispatch ClosePseudoConsole off-thread (it blocks until the output
        // pipe is drained on Windows < 11 24H2) and leave the reader open so
        // the event loop can keep draining; conhost flushes the final frame,
        // closes its pipe end, and the reader observes EOF → onReaderDone.
        if (this.hpcon) |hpcon| {
            this.hpcon = null;
            this.closePseudoconsoleOffThread(hpcon);
        }
        // Reader stays open even if hpcon was already null (closePseudoconsole
        // may have dispatched it earlier); onReaderDone closes on EOF.
        if (this.flags.reader_started and !this.flags.reader_done) return;
    }

    // Close reader (closes read_fd)
    if (this.flags.reader_started) {
        this.reader.close();
    }
    this.read_fd = bun.invalid_fd;

    // Close master fd
    if (this.master_fd != bun.invalid_fd) {
        this.master_fd.close();
        this.master_fd = bun.invalid_fd;
    }

    // Close slave fd
    if (this.slave_fd != bun.invalid_fd) {
        this.slave_fd.close();
        this.slave_fd = bun.invalid_fd;
    }
}

// IOWriter callbacks
fn onWriterClose(this: *Terminal) void {
    log("onWriterClose", .{});
    if (!this.flags.writer_done) {
        this.flags.writer_done = true;
        // Release writer's ref
        this.deref();
    }
}

fn onWriterReady(this: *Terminal) void {
    log("onWriterReady", .{});
    if (this.flags.finalized) return;
    const binding = this.binding orelse return;
    var receiver = (binding.weak_wrapper.toOwned() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = (TerminalDrainCallbackSlot.ownedCallback(&receiver) catch |err|
        return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.dispatch(.{
        .bindingThis = receiver.operand(&invocation),
        .terminal = receiver.operand(&invocation),
    });
}

fn onWriterError(this: *Terminal, err: bun.sys.Error) void {
    log("onWriterError: {any}", .{err});
    // On write error, close the terminal to prevent further operations
    // This handles cases like broken pipe when the child process exits
    if (!this.flags.closed) {
        this.closeInternal();
    }
}

fn onWrite(this: *Terminal, amount: usize, status: bun.io.WriteStatus) void {
    log("onWrite: {} bytes, status: {any}", .{ amount, status });
    if (status == .drained and !this.writer.hasPendingData()) {
        this.onWriterReady();
    }
}

// IOReader callbacks
pub fn onReaderDone(this: *Terminal) void {
    log("onReaderDone", .{});
    // Skip JS interactions if already finalized (happens when close() is called during finalize)
    if (!this.flags.finalized) {
        // exit_code 0 = clean EOF on PTY stream (not subprocess exit code)
        this.callExitCallback(0, null);
    }
    // Release reader's ref (only once)
    if (!this.flags.reader_done) {
        this.flags.reader_done = true;
        this.deref();
    }
}

pub fn onReaderError(this: *Terminal, err: bun.sys.Error) void {
    log("onReaderError: {any}", .{err});
    // Skip JS interactions if already finalized
    if (!this.flags.finalized) {
        // exit_code 1 = I/O error on PTY stream (not subprocess exit code)
        this.callExitCallback(1, null);
    }
    // Release reader's ref (only once)
    if (!this.flags.reader_done) {
        this.flags.reader_done = true;
        this.deref();
    }
}

/// Invoke the exit callback with PTY lifecycle status.
/// Note: exit_code is PTY-level (0=EOF, 1=error), NOT the subprocess exit code.
/// The signal parameter is only populated if a signal caused the PTY close.
fn callExitCallback(this: *Terminal, exit_code: i32, signal: ?bun.SignalCode) void {
    const binding = this.binding orelse return;
    var receiver = (binding.weak_wrapper.toOwned() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = (TerminalExitCallbackSlot.ownedCallback(&receiver) catch |err|
        return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();

    const globalThis = this.globalThis;
    var signal_value: ?bindgen.DOMString = if (signal) |value|
        bindgen.DOMString.fromUTF8(value.name() orelse "unknown") catch |err| {
            globalThis.reportUncaughtExceptionFromError(err);
            return;
        }
    else
        null;
    defer if (signal_value) |*value| value.deinit();

    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.dispatch(.{
        .bindingThis = receiver.operand(&invocation),
        .terminal = receiver.operand(&invocation),
        .exit_code = exit_code,
        .signal = if (signal_value) |*value| value.operand() else null,
    });
}

// Called when data is available from the reader
// Returns true to continue reading, false to pause
pub fn onReadChunk(this: *Terminal, chunk: []const u8, has_more: bun.io.ReadState) bool {
    _ = has_more;
    log("onReadChunk: {} bytes", .{chunk.len});

    if (this.flags.finalized) return true;

    const binding = this.binding orelse return true;
    var receiver = (binding.weak_wrapper.toOwned() catch |err| {
        this.globalThis.reportActiveExceptionAsUnhandled(err);
        return true;
    }) orelse return true;
    defer receiver.deinit();
    var callback = (TerminalDataCallbackSlot.ownedCallback(&receiver) catch |err| {
        this.globalThis.reportActiveExceptionAsUnhandled(err);
        return true;
    }) orelse return true;
    defer callback.deinit();

    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.dispatch(.{
        .bindingThis = receiver.operand(&invocation),
        .terminal = receiver.operand(&invocation),
        .data = bindgen.BytesOperand.fromSlice(chunk),
    });

    return true; // Continue reading
}

pub fn eventLoop(this: *Terminal) jsc.EventLoopHandle {
    return this.event_loop_handle;
}

pub fn loop(this: *Terminal) *bun.Async.Loop {
    if (comptime Environment.isWindows) {
        return this.event_loop_handle.loop().uv_loop;
    } else {
        return this.event_loop_handle.loop();
    }
}

fn deinit(this: *Terminal) void {
    log("deinit", .{});
    // Set reader/writer done flags to prevent extra deref calls in closeInternal
    this.flags.reader_done = true;
    this.flags.writer_done = true;
    // Close all FDs if not already closed (handles constructor error paths)
    // closeInternal() checks flags.closed and returns early on subsequent calls,
    // so this is safe even if finalize() already called it
    this.closeInternal();
    this.reader.deinit();
    this.writer.deinit();
    bun.destroy(this);
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const JSGlobalObject = jsc.JSGlobalObject;

const TerminalBindings = bindgen.Module("Terminal");
const TerminalClassSchema = TerminalBindings.class("Terminal");
const TerminalClass = bindgen.Class(TerminalClassSchema, JSBinding);
const TerminalConstructorSchema = TerminalClassSchema.constructor();
const TerminalOptionsSchema = TerminalConstructorSchema.args[0].ArgumentType;
const TerminalDataCallbackType = optionalDictionaryFieldChild(TerminalOptionsSchema, "data");
const TerminalDrainCallbackType = optionalDictionaryFieldChild(TerminalOptionsSchema, "drain");
const TerminalExitCallbackType = optionalDictionaryFieldChild(TerminalOptionsSchema, "exit");
const TerminalDataCallbackSlot = TerminalClass.CachedSlot("dataCallback");
const TerminalDrainCallbackSlot = TerminalClass.CachedSlot("drainCallback");
const TerminalExitCallbackSlot = TerminalClass.CachedSlot("exitCallback");
const TerminalAsyncDisposeNativeSchema = TerminalClassSchema.memberKind("__asyncDispose", .method);
const TerminalCloseSchema = TerminalClassSchema.memberKind("close", .method);
const TerminalClosedSchema = TerminalClassSchema.memberKind("closed", .getter);
const TerminalRefSchema = TerminalClassSchema.memberKind("ref", .method);
const TerminalResizeSchema = TerminalClassSchema.memberKind("resize", .method);
const TerminalSetRawModeSchema = TerminalClassSchema.memberKind("setRawMode", .method);
const TerminalUnrefSchema = TerminalClassSchema.memberKind("unref", .method);
const TerminalWriteSchema = TerminalClassSchema.memberKind("write", .method);

comptime {
    _ = TerminalClass;
}

fn optionalDictionaryFieldChild(comptime Dictionary: type, comptime field_name: []const u8) type {
    inline for (Dictionary.dictionary_fields) |Field| {
        if (std.mem.eql(u8, Field.field_name, field_name)) {
            if (Field.FieldType.kind != .optional) {
                @compileError("binding dictionary field '" ++ field_name ++ "' is not optional");
            }
            return Field.FieldType.child;
        }
    }
    @compileError("binding dictionary has no field named '" ++ field_name ++ "'");
}
