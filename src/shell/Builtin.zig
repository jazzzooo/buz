//! Some common commands (e.g. `ls`, `which`, `mv`, essentially coreutils) we make "built-in"
//! to the shell and implement natively in Zig. We do this for a couple reasons:
//!
//! 1. We can re-use a lot of our existing code in Bun and often times it's
//!    faster (for example `cp` and `mv` can be implemented using our Node FS
//!    logic)
//!
//! 2. Builtins run in the Bun process, so we can save a lot of time not having to
//!    spawn a new subprocess. A lot of the times, just spawning the shell can take
//!    longer than actually running the command. This is especially noticeable and
//!    important to consider for Windows.

kind: Kind,
stdin: BuiltinIO.Input,
stdout: BuiltinIO.Output,
stderr: BuiltinIO.Output,
exit_code: ?ExitCode = null,

export_env: *EnvMap,
cmd_local_env: *EnvMap,

arena: *bun.ArenaAllocator,
cwd: bun.FD,

/// TODO: It would be nice to make this mutable so that certain commands (e.g.
/// `export`) don't have to duplicate arguments. However, it is tricky because
/// modifications will invalidate any codepath which previously sliced the array
/// list (e.g. turned it into a `[]const [:0]const u8`)
args: *const std.array_list.Managed(?[*:0]const u8),
/// Cached slice of `args`.
///
/// This caches the result of calling `bun.span(this.args.items[i])` since the
/// items in `this.args` are sentinel terminated and don't carry their length.
args_slice: ?[]const [:0]const u8 = null,

impl: Impl,

pub const Impl = union(Kind) {
    cat: Cat,
    touch: Touch,
    mkdir: Mkdir,
    @"export": Export,
    cd: Cd,
    echo: Echo,
    pwd: Pwd,
    which: Which,
    rm: Rm,
    mv: Mv,
    ls: Ls,
    exit: Exit,
    true: True,
    false: False,
    yes: Yes,
    seq: Seq,
    dirname: Dirname,
    basename: Basename,
    cp: Cp,
};

pub const Result = @import("../bun_core/result.zig").Result;

// Note: this enum uses @tagName, choose wisely!
pub const Kind = enum {
    cat,
    touch,
    mkdir,
    @"export",
    cd,
    echo,
    pwd,
    which,
    rm,
    mv,
    ls,
    exit,
    true,
    false,
    yes,
    seq,
    dirname,
    basename,
    cp,

    pub const DISABLED_ON_POSIX: []const Kind = &.{ .cat, .cp };

    pub fn usageString(this: Kind) []const u8 {
        return switch (this) {
            .cat => "usage: cat [-belnstuv] [file ...]\n",
            .touch => "usage: touch [-A [-][[hh]mm]SS] [-achm] [-r file] [-t [[CC]YY]MMDDhhmm[.SS]]\n       [-d YYYY-MM-DDThh:mm:SS[.frac][tz]] file ...\n",
            .mkdir => "usage: mkdir [-pv] [-m mode] directory_name ...\n",
            .@"export" => "",
            .cd => "",
            .echo => "",
            .pwd => "",
            .which => "",
            .rm => "usage: rm [-f | -i] [-dIPRrvWx] file ...\n       unlink [--] file\n",
            .mv => "usage: mv [-f | -i | -n] [-hv] source target\n       mv [-f | -i | -n] [-v] source ... directory\n",
            .ls => "usage: ls [-@ABCFGHILOPRSTUWabcdefghiklmnopqrstuvwxy1%,] [--color=when] [-D format] [file ...]\n",
            .exit => "usage: exit [n]\n",
            .true => "",
            .false => "",
            .yes => "usage: yes [expletive]\n",
            .seq => "usage: seq [-w] [-f format] [-s string] [-t string] [first [incr]] last\n",
            .dirname => "usage: dirname string\n",
            .basename => "usage: basename string\n",
            .cp => "usage: cp [-R [-H | -L | -P]] [-fi | -n] [-aclpsvXx] source_file target_file\n       cp [-R [-H | -L | -P]] [-fi | -n] [-aclpsvXx] source_file ... target_directory\n",
        };
    }

    fn forceEnableOnPosix() bool {
        return bun.feature_flag.BUN_ENABLE_EXPERIMENTAL_SHELL_BUILTINS.get();
    }

    pub fn fromStr(str: []const u8) ?Builtin.Kind {
        const result = std.meta.stringToEnum(Builtin.Kind, str) orelse return null;
        if (bun.Environment.isWindows) return result;
        if (forceEnableOnPosix()) return result;
        inline for (Builtin.Kind.DISABLED_ON_POSIX) |disabled| {
            if (disabled == result) {
                log("{s} builtin disabled on posix for now", .{@tagName(disabled)});
                return null;
            }
        }
        return result;
    }
};

pub const BuiltinIO = struct {
    pub const Output = union(enum) {
        fd: struct { writer: *IOWriter, captured: ?*bun.ByteList = null },
        buf: std.array_list.Managed(u8),
        leased_bytes: LeasedBytesOutput,
        ignore,

        pub fn ref(this: *Output) *Output {
            switch (this.*) {
                .fd => {
                    this.fd.writer.ref();
                },
                else => {},
            }
            return this;
        }

        pub fn deref(this: *Output) void {
            switch (this.*) {
                .fd => {
                    this.fd.writer.deref();
                },
                .leased_bytes => this.leased_bytes.buf.deinit(),
                .buf => {
                    const alloc = this.buf.allocator;
                    this.buf.deinit();
                    this.* = .{ .buf = std.array_list.Managed(u8).init(alloc) };
                },
                .ignore => {},
            }
        }

        pub fn needsIO(this: *Output) ?OutputNeedsIOSafeGuard {
            return switch (this.*) {
                .fd => .output_needs_io,
                else => null,
            };
        }

        /// You must check that `.needsIO() == true` before calling this!
        /// e.g.
        ///
        /// ```zig
        /// if (this.stderr.neesdIO()) |safeguard| {
        ///   this.bltn.stderr.enqueueFmtBltn(this, .cd, fmt, args, safeguard);
        /// }
        /// ```
        pub fn enqueueFmtBltn(
            this: *@This(),
            ptr: anytype,
            comptime kind: ?Interpreter.Builtin.Kind,
            comptime fmt_: []const u8,
            args: anytype,
            _: OutputNeedsIOSafeGuard,
        ) Yield {
            return this.fd.writer.enqueueFmtBltn(ptr, this.fd.captured, kind, fmt_, args);
        }

        pub fn enqueue(this: *@This(), ptr: anytype, buf: []const u8, _: OutputNeedsIOSafeGuard) Yield {
            return this.fd.writer.enqueue(ptr, this.fd.captured, buf);
        }

        pub fn enqueueFmt(this: *@This(), ptr: anytype, comptime fmt: []const u8, args: anytype, _: OutputNeedsIOSafeGuard) Yield {
            return this.fd.writer.enqueueFmt(ptr, this.fd.captured, fmt, args);
        }
    };

    pub const Input = union(enum) {
        fd: *IOReader,
        /// array list not ownedby this type
        buf: std.array_list.Managed(u8),
        ignore,

        pub fn ref(this: *Input) *Input {
            switch (this.*) {
                .fd => {
                    this.fd.ref();
                },
                else => {},
            }
            return this;
        }

        pub fn deref(this: *Input) void {
            switch (this.*) {
                .fd => {
                    this.fd.deref();
                },
                .buf => {
                    const alloc = this.buf.allocator;
                    this.buf.deinit();
                    this.* = .{ .buf = std.array_list.Managed(u8).init(alloc) };
                },
                .ignore => {},
            }
        }

        pub fn needsIO(this: *Input) bool {
            return switch (this.*) {
                .fd => true,
                else => false,
            };
        }
    };

    const LeasedBytesOutput = struct {
        buf: bun.bindgen.OwnedMutableLease(u8),
        i: usize = 0,
    };
};

pub fn argsSlice(this: *Builtin) []const [*:0]const u8 {
    const args_raw = this.args.items[1..];
    const args_len = std.mem.indexOfScalar(?[*:0]const u8, args_raw, null) orelse @panic("bad");
    if (args_len == 0)
        return &[_][*:0]const u8{};

    const args_ptr = args_raw.ptr;
    return @as([*][*:0]const u8, @ptrCast(args_ptr))[0..args_len];
}

pub inline fn callImpl(this: *Builtin, comptime Ret: type, comptime field: []const u8, args_: anytype) Ret {
    return switch (this.kind) {
        .cat => this.callImplWithType(Cat, Ret, "cat", field, args_),
        .touch => this.callImplWithType(Touch, Ret, "touch", field, args_),
        .mkdir => this.callImplWithType(Mkdir, Ret, "mkdir", field, args_),
        .@"export" => this.callImplWithType(Export, Ret, "export", field, args_),
        .echo => this.callImplWithType(Echo, Ret, "echo", field, args_),
        .cd => this.callImplWithType(Cd, Ret, "cd", field, args_),
        .which => this.callImplWithType(Which, Ret, "which", field, args_),
        .rm => this.callImplWithType(Rm, Ret, "rm", field, args_),
        .pwd => this.callImplWithType(Pwd, Ret, "pwd", field, args_),
        .mv => this.callImplWithType(Mv, Ret, "mv", field, args_),
        .ls => this.callImplWithType(Ls, Ret, "ls", field, args_),
        .exit => this.callImplWithType(Exit, Ret, "exit", field, args_),
        .true => this.callImplWithType(True, Ret, "true", field, args_),
        .false => this.callImplWithType(False, Ret, "false", field, args_),
        .yes => this.callImplWithType(Yes, Ret, "yes", field, args_),
        .seq => this.callImplWithType(Seq, Ret, "seq", field, args_),
        .dirname => this.callImplWithType(Dirname, Ret, "dirname", field, args_),
        .basename => this.callImplWithType(Basename, Ret, "basename", field, args_),
        .cp => this.callImplWithType(Cp, Ret, "cp", field, args_),
    };
}

fn callImplWithType(this: *Builtin, comptime BuiltinImpl: type, comptime Ret: type, comptime union_field: []const u8, comptime field: []const u8, args_: anytype) Ret {
    const self = &@field(this.impl, union_field);
    const args = brk: {
        var args: std.meta.ArgsTuple(@TypeOf(@field(BuiltinImpl, field))) = undefined;
        args[0] = self;

        var i: usize = 1;
        inline for (args_) |a| {
            args[i] = a;
            i += 1;
        }

        break :brk args;
    };
    return @call(.auto, @field(BuiltinImpl, field), args);
}

pub inline fn allocator(this: *Builtin) Allocator {
    // FIXME: This should be `this.parentCmd().base.allocator()`
    return this.parentCmd().base.interpreter.allocator;
}

fn openRedirectPath(cmd: *Cmd, node: *const ast.Cmd, path: [:0]const u8) Maybe(bun.FD) {
    const perm = 0o666;
    if (node.redirect.stdin) {
        return ShellSyscall.openat(cmd.base.shell.cwd_fd, path, node.redirect.toFlags(), perm);
    }

    const result = bun.io.openForWritingImpl(
        cmd.base.shell.cwd_fd,
        path,
        node.redirect.toFlags(),
        perm,
        ShellSyscall.openat,
    );
    if (!bun.Environment.isWindows) return result;
    return switch (result) {
        .err => |err| .{ .err = err },
        .result => |fd| fd.makeLibUVOwnedForSyscall(.open, .close_on_fail),
    };
}

fn reportRedirectOpenError(cmd: *Cmd, err: bun.sys.Error, path: []const u8) Yield {
    const sys_err = err.toShellSystemError();
    defer sys_err.deref();
    return if (path.len == 0)
        cmd.writeFailingError("bun: {f}\n", .{sys_err.message})
    else
        cmd.writeFailingError("bun: {f}: {s}", .{ sys_err.message, path });
}

fn installRedirectFd(cmd: *Cmd, node: *const ast.Cmd, redirfd: bun.FD) void {
    if (node.redirect.stdin) {
        cmd.exec.bltn.stdin.deref();
        cmd.exec.bltn.stdin = .{ .fd = IOReader.init(redirfd, cmd.base.eventLoop()) };
        return;
    }

    const redirect_writer: *IOWriter = .init(
        redirfd,
        .{
            .tty_mode = .blocking,
            .ofd_ownership = .exclusive,
        },
        cmd.base.eventLoop(),
    );
    defer redirect_writer.deref();

    if (node.redirect.stdout) {
        cmd.exec.bltn.stdout.deref();
        cmd.exec.bltn.stdout = .{ .fd = .{ .writer = redirect_writer.dupeRef() } };
    }

    if (node.redirect.stderr) {
        cmd.exec.bltn.stderr.deref();
        cmd.exec.bltn.stderr = .{ .fd = .{ .writer = redirect_writer.dupeRef() } };
    }
}

fn applyBlobRedirect(cmd: *Cmd, node: *const ast.Cmd, source: *const bun.webcore.Blob) ?Yield {
    if ((node.redirect.stdout or node.redirect.stderr) and !source.needsToReadFile()) {
        cmd.base.eventLoop().throwMessage("Cannot redirect stdout/stderr to an immutable blob. Expected a file");
        return .failed;
    }

    if (!node.redirect.stdin and !node.redirect.stdout and !node.redirect.stderr) {
        return null;
    }

    if (!source.needsToReadFile()) {
        if (node.redirect.stdin) {
            var input = std.array_list.Managed(u8).init(cmd.base.allocator());
            bun.handleOom(input.appendSlice(source.sharedView()));
            cmd.exec.bltn.stdin.deref();
            cmd.exec.bltn.stdin = .{ .buf = input };
        }
        return null;
    }

    const store = source.storePtr() orelse @panic("file-backed blob has no store");
    const file = switch (store.data) {
        .file => |file| file,
        else => @panic("file-backed blob has non-file storage"),
    };
    var path_buffer: bun.PathBuffer = undefined;
    const path = if (file.pathlike == .path) file.pathlike.path.sliceZ(&path_buffer) else "";
    const result = switch (file.pathlike) {
        .fd => |fd| ShellSyscall.dup(fd),
        .path => openRedirectPath(cmd, node, path),
    };
    const redirfd = switch (result) {
        .err => |err| return reportRedirectOpenError(cmd, err, path),
        .result => |fd| fd,
    };
    installRedirectFd(cmd, node, redirfd);

    return null;
}

fn applyAnyBlobRedirect(cmd: *Cmd, node: *const ast.Cmd, source: *const bun.webcore.Blob.Any) ?Yield {
    switch (source.*) {
        .Blob => return applyBlobRedirect(cmd, node, &source.Blob),
        .InternalBlob, .WTFStringImpl => {
            if (node.redirect.stdout or node.redirect.stderr) {
                cmd.base.eventLoop().throwMessage("Cannot redirect stdout/stderr to an immutable blob. Expected a file");
                return .failed;
            }
            if (node.redirect.stdin) {
                var input = std.array_list.Managed(u8).init(cmd.base.allocator());
                bun.handleOom(input.appendSlice(source.slice()));
                cmd.exec.bltn.stdin.deref();
                cmd.exec.bltn.stdin = .{ .buf = input };
            }
            return null;
        },
    }
}

const BlobRedirectContext = struct {
    cmd: *Cmd,
    node: *const ast.Cmd,

    fn consume(raw_context: *anyopaque, source: *bun.webcore.Blob.Any) ?Yield {
        const context: *BlobRedirectContext = @ptrCast(@alignCast(raw_context));
        return applyAnyBlobRedirect(context.cmd, context.node, source);
    }
};

pub fn init(
    cmd: *Cmd,
    interpreter: *Interpreter,
    kind: Kind,
    arena: *bun.ArenaAllocator,
    node: *const ast.Cmd,
    args: *const std.array_list.Managed(?[*:0]const u8),
    export_env: *EnvMap,
    cmd_local_env: *EnvMap,
    cwd: bun.FD,
    io: *IO,
) ?Yield {
    const stdin: BuiltinIO.Input = switch (io.stdin) {
        .fd => |fd| .{ .fd = fd.dupeRef() },
        .ignore => .ignore,
    };
    const stdout: BuiltinIO.Output = switch (io.stdout) {
        .fd => |val| .{ .fd = .{ .writer = val.writer.dupeRef(), .captured = val.captured } },
        .pipe => .{ .buf = std.array_list.Managed(u8).init(cmd.base.allocator()) },
        .ignore => .ignore,
    };
    const stderr: BuiltinIO.Output = switch (io.stderr) {
        .fd => |val| .{ .fd = .{ .writer = val.writer.dupeRef(), .captured = val.captured } },
        .pipe => .{ .buf = std.array_list.Managed(u8).init(cmd.base.allocator()) },
        .ignore => .ignore,
    };

    cmd.exec = .{
        .bltn = Builtin{
            .kind = kind,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = null,
            .arena = arena,
            .args = args,
            .export_env = export_env,
            .cmd_local_env = cmd_local_env,
            .cwd = cwd,
            .impl = undefined,
        },
    };

    switch (kind) {
        .rm => {
            cmd.exec.bltn.impl = .{
                .rm = Rm{
                    .opts = .{},
                },
            };
        },
        .echo => {
            cmd.exec.bltn.impl = .{
                .echo = Echo{
                    .output = std.array_list.Managed(u8).init(arena.allocator()),
                },
            };
        },
        .ls => {
            cmd.exec.bltn.impl = .{
                .ls = Ls{
                    .alloc_scope = shell.AllocScope.beginScope(interpreter.scheduler().io(), bun.default_allocator),
                },
            };
        },
        .yes => {
            cmd.exec.bltn.impl = .{
                .yes = Yes{
                    .alloc_scope = shell.AllocScope.beginScope(interpreter.scheduler().io(), bun.default_allocator),
                },
            };
        },
        inline else => |tag| {
            cmd.exec.bltn.impl = @unionInit(Impl, @tagName(tag), .{});
        },
    }

    return initRedirections(cmd, kind, node, interpreter);
}

fn initRedirections(
    cmd: *Cmd,
    kind: Kind,
    node: *const ast.Cmd,
    interpreter: *Interpreter,
) ?Yield {
    if (node.redirect_file) |file| {
        switch (file) {
            .atom => {
                if (cmd.redirection_file.items.len == 0) {
                    return cmd.writeFailingError("bun: ambiguous redirect: at `{s}`\n", .{@tagName(kind)});
                }

                const path = cmd.redirection_file.items[0..cmd.redirection_file.items.len -| 1 :0];
                log("EXPANDED REDIRECT: {s}\n", .{cmd.redirection_file.items[0..]});
                const redirfd = switch (openRedirectPath(cmd, node, path)) {
                    .err => |err| return reportRedirectOpenError(cmd, err, path),
                    .result => |fd| fd,
                };
                installRedirectFd(cmd, node, redirfd);
            },
            .jsbuf => |val| {
                const value = interpreter.shellValue(val.idx) orelse {
                    interpreter.scheduler().throwMessage("Invalid JS object reference in shell");
                    return .failed;
                };

                switch (value.*) {
                    .buffer => |*buffer| {
                        if (node.redirect.stdin) {
                            var input = std.array_list.Managed(u8).init(cmd.base.allocator());
                            bun.handleOom(input.resize(buffer.length()));
                            bun.assert(buffer.read(0, input.items));
                            cmd.exec.bltn.stdin.deref();
                            cmd.exec.bltn.stdin = .{ .buf = input };
                        }
                        if (node.redirect.stdout) {
                            cmd.exec.bltn.stdout.deref();
                            cmd.exec.bltn.stdout = .{ .leased_bytes = .{ .buf = bun.handleOom(buffer.clone()) } };
                        }
                        if (node.redirect.stderr) {
                            cmd.exec.bltn.stderr.deref();
                            cmd.exec.bltn.stderr = .{ .leased_bytes = .{ .buf = bun.handleOom(buffer.clone()) } };
                        }
                    },
                    .blob => |*blob| {
                        if (applyBlobRedirect(cmd, node, blob)) |result| return result;
                    },
                    .response, .stream => {
                        var context: BlobRedirectContext = .{ .cmd = cmd, .node = node };
                        if (interpreter.scheduler().withShellValueBlob(
                            value,
                            switch (value.*) {
                                .response => "Cannot redirect a streaming Response to a builtin command",
                                .stream => "Cannot redirect a live ReadableStream to a builtin command",
                                else => unreachable,
                            },
                            &context,
                            BlobRedirectContext.consume,
                        )) |result| return result;
                    },
                }
            },
        }
    } else if (node.redirect.duplicate_out) {
        if (node.redirect.stdout) {
            cmd.exec.bltn.stderr.deref();
            cmd.exec.bltn.stderr = cmd.exec.bltn.stdout.ref().*;
        }

        if (node.redirect.stderr) {
            cmd.exec.bltn.stdout.deref();
            cmd.exec.bltn.stdout = cmd.exec.bltn.stderr.ref().*;
        }
    }

    return null;
}

pub inline fn eventLoop(this: *const Builtin) Interpreter.Scheduler {
    return this.parentCmd().base.eventLoop();
}

pub inline fn throw(this: *const Builtin, err: *const bun.shell.ShellErr) void {
    this.parentCmd().base.throw(err) catch {};
}

/// The `Cmd` state node associated with this builtin
pub inline fn parentCmd(this: *const Builtin) *const Cmd {
    const union_ptr: *const Cmd.Exec = @fieldParentPtr("bltn", this);
    return @fieldParentPtr("exec", union_ptr);
}

pub inline fn parentCmdMut(this: *Builtin) *Cmd {
    const union_ptr: *Cmd.Exec = @fieldParentPtr("bltn", this);
    return @fieldParentPtr("exec", union_ptr);
}

pub fn done(this: *Builtin, exit_code: anytype) Yield {
    const code: ExitCode = switch (@TypeOf(exit_code)) {
        bun.sys.E => @backingInt(exit_code),
        u1, u8, u16 => exit_code,
        comptime_int => exit_code,
        else => @compileError("Invalid type: " ++ @typeName(@TypeOf(exit_code))),
    };
    this.exit_code = code;

    var cmd = this.parentCmdMut();
    log("builtin done ({s}: exit={d}) cmd to free: ({x})", .{ @tagName(this.kind), code, @intFromPtr(cmd) });
    cmd.exit_code = this.exit_code.?;

    // Aggregate output data if shell state is piped and this cmd is piped
    if (cmd.io.stdout == .pipe and cmd.io.stdout == .pipe and this.stdout == .buf) {
        bun.handleOom(cmd.base.shell.buffered_stdout().appendSlice(
            bun.default_allocator,
            this.stdout.buf.items[0..],
        ));
    }
    // Aggregate output data if shell state is piped and this cmd is piped
    if (cmd.io.stderr == .pipe and cmd.io.stderr == .pipe and this.stderr == .buf) {
        bun.handleOom(cmd.base.shell.buffered_stderr().appendSlice(
            bun.default_allocator,
            this.stderr.buf.items[0..],
        ));
    }

    return cmd.parent.childDone(cmd, this.exit_code.?);
}

pub fn start(this: *Builtin) Yield {
    return this.callImpl(Yield, "start", .{});
}

pub fn deinit(this: *Builtin) void {
    this.callImpl(void, "deinit", .{});

    // No need to free it because it belongs to the parent cmd
    // _ = Syscall.close(this.cwd);

    this.stdout.deref();
    this.stderr.deref();
    this.stdin.deref();

    // Parent cmd frees this
    // this.arena.deinit();
}

pub fn readStdinNoIO(this: *Builtin) []const u8 {
    return switch (this.stdin) {
        .buf => |buf| buf.items[0..],
        else => "",
    };
}

/// **WARNING** You should make sure that stdout/stderr does not need IO (e.g. `.needsIO(.stderr)` is false before caling `.writeNoIO(.stderr, buf)`)
pub fn writeNoIO(this: *Builtin, comptime io_kind: @EnumLiteral(), buf: []const u8) Maybe(usize) {
    if (comptime io_kind != .stdout and io_kind != .stderr) {
        @compileError("Bad IO" ++ @tagName(io_kind));
    }

    if (buf.len == 0) return Maybe(usize).initResult(0);

    var io: *BuiltinIO.Output = &@field(this, @tagName(io_kind));

    switch (io.*) {
        .fd => @panic("writeNoIO(. " ++ @tagName(io_kind) ++ ", buf) can't write to a file descriptor, did you check that needsIO(." ++ @tagName(io_kind) ++ ") was false?"),
        .buf => {
            log("{s} write to buf len={d} str={s}{s}\n", .{ @tagName(this.kind), buf.len, buf[0..@min(buf.len, 16)], if (buf.len > 16) "..." else "" });
            bun.handleOom(io.buf.appendSlice(buf));
            return Maybe(usize).initResult(buf.len);
        },
        .leased_bytes => {
            const offset = io.leased_bytes.i;
            const capacity = io.leased_bytes.buf.length();
            if (offset >= capacity) {
                return Maybe(usize).initErr(bun.sys.Error.fromCode(bun.sys.E.NOSPC, .write));
            }

            const write_len = @min(capacity - offset, buf.len);
            bun.assert(io.leased_bytes.buf.write(offset, buf[0..write_len]));
            io.leased_bytes.i += write_len;
            log("{s} write to leased bytes {d}\n", .{ @tagName(this.kind), write_len });
            return Maybe(usize).initResult(write_len);
        },
        .ignore => return Maybe(usize).initResult(buf.len),
    }
}

/// Error messages formatted to match bash
pub fn taskErrorToString(this: *Builtin, comptime kind: Kind, err: anytype) []const u8 {
    switch (@TypeOf(err)) {
        Syscall.Error => {
            if (err.getErrorCodeTagName()) |entry| {
                _, const sys_errno = entry;
                if (bun.sys.coreutils_error_map.get(sys_errno)) |message| {
                    if (err.path.len > 0) {
                        return this.fmtErrorArena(kind, "{s}: {s}\n", .{ err.path, message });
                    }
                    return this.fmtErrorArena(kind, "{s}\n", .{message});
                }
            }
            return this.fmtErrorArena(kind, "unknown error {d}\n", .{err.errno});
        },
        bun.sys.SystemError => {
            if (err.path.length() == 0) return this.fmtErrorArena(kind, "{s}\n", .{err.message.byteSlice()});
            return this.fmtErrorArena(kind, "{s}: {f}\n", .{ err.message.byteSlice(), err.path });
        },
        bun.shell.ShellErr => return switch (err) {
            .sys => this.taskErrorToString(kind, err.sys),
            .custom => this.fmtErrorArena(kind, "{s}\n", .{err.custom}),
            .invalid_arguments => this.fmtErrorArena(kind, "{s}\n", .{err.invalid_arguments.val}),
            .todo => this.fmtErrorArena(kind, "{s}\n", .{err.todo}),
        },
        else => @compileError("Bad type: " ++ @typeName(err)),
    }
}

pub fn fmtErrorArena(this: *Builtin, comptime kind: ?Kind, comptime fmt_: []const u8, args: anytype) []u8 {
    const cmd_str = comptime if (kind) |k| @tagName(k) ++ ": " else "";
    const fmt = cmd_str ++ fmt_;
    return bun.handleOom(std.fmt.allocPrint(this.arena.allocator(), fmt, args));
}

// --- Shell Builtin Commands ---
pub const Cat = @import("./builtin/cat.zig").Type(BuiltinHost);
pub const Touch = @import("./builtin/touch.zig");
pub const Mkdir = @import("./builtin/mkdir.zig");
pub const Export = @import("./builtin/export.zig").Type(BuiltinHost);
pub const Cd = @import("./builtin/cd.zig").Type(BuiltinHost);
pub const Ls = @import("./builtin/ls.zig");
pub const Pwd = @import("./builtin/pwd.zig").Type(BuiltinHost);
pub const Echo = @import("./builtin/echo.zig").Type(BuiltinHost);
pub const Which = @import("./builtin/which.zig").Type(BuiltinHost);
pub const Rm = @import("./builtin/rm.zig");
pub const Exit = @import("./builtin/exit.zig").Type(BuiltinHost);
pub const True = @import("./builtin/true_.zig").Type(BuiltinHost);
pub const False = @import("./builtin/false_.zig").Type(BuiltinHost);
pub const Yes = @import("./builtin/yes.zig");
pub const Seq = @import("./builtin/seq.zig").Type(BuiltinHost);
pub const Dirname = @import("./builtin/dirname.zig").Type(BuiltinHost);
pub const Basename = @import("./builtin/basename.zig").Type(BuiltinHost);
pub const Cp = @import("./builtin/cp.zig");
pub const Mv = @import("./builtin/mv.zig");
// --- End Shell Builtin Commands ---

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");

const shell = bun.shell;
const Yield = bun.shell.Yield;
const ast = shell.AST;
const IO = shell.Interpreter.IO;

const EnvMap = shell.interpret.EnvMap;
const ExitCode = shell.interpret.ExitCode;
const OutputNeedsIOSafeGuard = shell.interpret.OutputNeedsIOSafeGuard;
const ShellSyscall = shell.interpret.ShellSyscall;
const log = shell.interpret.log;

const Interpreter = shell.interpret.Interpreter;
const BuiltinModule = @This();
const Builtin = BuiltinModule;
const BuiltinHost = struct {
    pub const Interpreter = struct {
        pub const Builtin = BuiltinModule;
    };
    pub const EnvStr = shell.interpret.EnvStr;
    pub const FlagParser = shell.interpret.FlagParser;
    pub const ParseError = shell.interpret.ParseError;
    pub const ParseFlagResult = shell.interpret.ParseFlagResult;
    pub const ShellSyscall = shell.interpret.ShellSyscall;
    pub const unsupportedFlag = shell.interpret.unsupportedFlag;
};
const Cmd = Interpreter.Cmd;
const IOReader = Interpreter.IOReader;
const IOWriter = Interpreter.IOWriter;

const Syscall = bun.sys;
const Maybe = bun.sys.Maybe;
