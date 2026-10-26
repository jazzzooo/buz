//! The interpreter for the shell language
//!
//! There are several constraints on the Bun shell language that make this
//! interpreter implementation unique:
//!
//! 1. We try to keep everything in the Bun process as much as possible for
//!    performance reasons and also to leverage Bun's existing IO/FS code
//! 2. We try to use non-blocking IO operations as much as possible so the
//!    shell does not block the main JS thread
//! 3. Zig does not have coroutines (yet)
//!
//! The idea is that this is a tree-walking interpreter. Except it's not.
//!
//! Why not? Because 99% of operations in the shell are IO, and we need to do
//! non-blocking IO because Bun is a JS runtime.
//!
//! So what do we do? Instead of iteratively walking the AST like in a traditional
//! tree-walking interpreter, we're also going to build up a tree of state-machines
//! (an AST node becomes a state-machine node), so we can suspend and resume
//! execution without blocking the main thread.
//!
//! We'll also need to do things in continuation-passing style, see `Yield.zig` for
//! more on that.
//!
//! Once all these pieces come together, this ends up being a:
//! "state-machine based [tree-walking], [trampoline]-driven [continuation-passing style] interpreter"
//!
//! [tree-walking]: https://en.wikipedia.org/wiki/Interpreter_(computing)#Abstract_syntax_tree_interpreters
//! [trampoline]:   https://en.wikipedia.org/wiki/Trampoline_(computing)
//! [continuation-passing style]: https://en.wikipedia.org/wiki/Continuation-passing_style
//!
//! # Memory management
//!
//! Almost all allocations go through the `AllocationScope` allocator. This
//! trackd memory allocations and frees in debug builds (or builds with asan
//! enabled) and helps us catch memory leaks.
//!
//! The underlying parent allocator that every `AllocationScope` uses in the
//! shell is `bun.default_allocator`. This means in builds of Bun which do not
//! have `AllocationScope` enabled, every allocation just goes straight through
//! to `bun.default_allocator`.
//!
//! Usually every state machine node ends up creating a new allocation scope,
//! so an `AllocationScope` is stored in the base header struct (see `Base.zig`)
//! that all state-machine nodes include in their layout.
//!
//! You will often see `Base.initWithNewAllocScope` to create a new state machine node
//! and allocation scope.
//!
//! Sometimes it is necessary to "leak" an allocation from its scope. For
//! example, argument expansion happens in an allocation scope inside
//! `Expansion.zig`.
//!
//! But the string that is expanded may end up becoming the key/value of an
//! environment variable, which we internally use the reference counted `EnvStr`
//! for. When we turn it into an `EnvStr`, the reference counting scheme is
//! responsible for managing the memory so we can call
//! `allocScope.leakSlice(str)` to tell it not to track the allocation anymore
//! and let `EnvStr` handle it.
const string = []const u8;
pub const Arena = std.heap.ArenaAllocator;
pub const Braces = @import("../shell_parser/braces.zig");
pub const Syscall = bun.sys;
const BackgroundTask = bun.BackgroundTaskGroup.Task;
const BackgroundWork = bun.BackgroundWork;

pub const Pipe = [2]bun.FD;
pub const SmolList = shell.SmolList;

pub const GlobWalker = bun.glob.BunGlobWalkerZ;

pub const stdin_no = 0;
pub const stdout_no = 1;
pub const stderr_no = 2;

pub fn OOM(e: anyerror) noreturn {
    if (comptime bun.Environment.allow_assert) {
        if (e != error.OutOfMemory) bun.outOfMemory();
    }
    bun.outOfMemory();
}

pub const log = bun.Output.scoped(.SHELL, .visible);

/// This is a zero-sized type returned by `.needsIO()`, designed to ensure
/// functions which rely on IO are not called when they do don't need it.
///
/// For example the .enqueue(), .enqueueFmtBltn(), etc functions.
///
/// It is used like this:
///
/// ```zig
/// if (this.bltn.stdout.needsIO()) |safeguard| {
///     this.bltn.stdout.enqueue(this, chunk, safeguard);
///     return .cont;
/// }
// _ = this.bltn.writeNoIO(.stdout, chunk);
/// ```
///
/// The compiler optimizes away this type so it has zero runtime cost.
///
/// You should never instantiate this type directly, unless you know
/// from previous context that the output needs IO.
///
/// Functions which accept a `_: OutputNeedsIOSafeGuard` parameter can
/// safely assume the stdout/stderr they are working with require IO.
pub const OutputNeedsIOSafeGuard = enum(u0) { output_needs_io };

pub const ExitCode = u16;

pub const StateKind = enum(u8) {
    script,
    stmt,
    assign,
    cmd,
    binary,
    pipeline,
    expansion,
    if_clause,
    condexpr,
    async,
    subshell,
};

/// Copy-on-write file descriptor. This is to avoid having multiple non-blocking
/// writers to the same file descriptor, which breaks epoll/kqueue
///
/// Two main fields:
/// 1. refcount - tracks number of references to the fd, closes file descriptor when reaches 0
/// 2. being_written - if the fd is currently being used by a BufferedWriter for non-blocking writes
///
/// If you want to write to the file descriptor, you call `.write()`, if `being_written` is true it will duplicate the file descriptor.
pub const CowFd = struct {
    __fd: bun.FD,
    refcount: u32 = 1,
    being_used: bool = false,

    const debug = bun.Output.scoped(.CowFd, .hidden);

    pub fn init(fd: bun.FD) *CowFd {
        const this = bun.handleOom(bun.default_allocator.create(CowFd));
        this.* = .{
            .__fd = fd,
        };
        debug("init(0x{x}, fd={f})", .{ @intFromPtr(this), fd });
        return this;
    }

    pub fn dup(this: *CowFd) Maybe(*CowFd) {
        const new = bun.new(CowFd, .{
            .fd = bun.sys.dup(this.fd),
            .writercount = 1,
        });
        debug("dup(0x{x}, fd={f}) = (0x{x}, fd={f})", .{ @intFromPtr(this), this.fd, new, new.fd });
        return new;
    }

    pub fn use(this: *CowFd) Maybe(*CowFd) {
        if (!this.being_used) {
            this.being_used = true;
            this.ref();
            return .{ .result = this };
        }
        return this.dup();
    }

    pub fn ref(this: *CowFd) void {
        this.refcount += 1;
    }

    pub fn dupeRef(this: *CowFd) *CowFd {
        this.ref();
        return this;
    }

    pub fn deref(this: *CowFd) void {
        this.refcount -= 1;
        if (this.refcount == 0) {
            this.deinit();
        }
    }

    pub fn deinit(this: *CowFd) void {
        assert(this.refcount == 0);
        this.__fd.close();
        bun.default_allocator.destroy(this);
    }
};

pub const RefCountedStr = @import("./RefCountedStr.zig");
pub const EnvStr = @import("./EnvStr.zig").EnvStr;
pub const EnvMap = @import("./EnvMap.zig");
pub const ShellArgs = struct {
    /// This is the arena used to allocate the input shell script's AST nodes,
    /// tokens, and a string pool used to store all strings.
    __arena: *bun.ArenaAllocator,
    /// Root ast node
    script_ast: ast.Script = .{ .stmts = &[_]ast.Stmt{} },

    pub const new = bun.TrivialNew(@This());

    pub fn arena_allocator(this: *ShellArgs) std.mem.Allocator {
        return this.__arena.allocator();
    }

    pub fn deinit(this: *ShellArgs) void {
        this.__arena.deinit();
        bun.destroy(this.__arena);
        bun.destroy(this);
    }

    pub fn destroy(this: *ShellArgs) void {
        this.deinit();
    }

    pub fn init() *ShellArgs {
        const arena = bun.new(bun.ArenaAllocator, bun.ArenaAllocator.init(bun.default_allocator));
        return ShellArgs.new(.{
            .__arena = arena,
            .script_ast = undefined,
        });
    }

    pub fn memoryCost(this: *const ShellArgs) usize {
        return @sizeOf(ShellArgs) + @sizeOf(bun.ArenaAllocator) + this.__arena.queryCapacity();
    }
};

pub const AssignCtx = Interpreter.Assigns.AssignCtx;

/// This interpreter works by basically turning the AST into a state machine so
/// that execution can be suspended and resumed to support async.
pub const Interpreter = struct {
    pub const Scheduler = @import("./Scheduler.zig");

    pub const Completion = struct {
        pub const Context = bun.bindgen.NativeCallbackContext(.vm);
        context: Context,
        vtable: *const VTable,

        pub const VTable = struct {
            finish: *const fn (Context, ExitCode, *bun.ByteList, *bun.ByteList, *anyopaque, *const fn (*anyopaque) void) void,
            deinit: *const fn (Context) void,
        };

        pub fn finish(
            this: Completion,
            exit_code: ExitCode,
            stdout: *bun.ByteList,
            stderr: *bun.ByteList,
            cleanup_context: *anyopaque,
            cleanup: *const fn (*anyopaque) void,
        ) void {
            this.vtable.finish(this.context, exit_code, stdout, stderr, cleanup_context, cleanup);
        }

        pub fn deinit(this: Completion) void {
            this.vtable.deinit(this.context);
        }
    };

    command_ctx: ?bun.cli.Command.Context,
    scheduler_state: Scheduler,
    /// This is the allocator used to allocate interpreter state
    allocator: Allocator,

    args: Arguments,

    shell_values: ?ShellValue.OwnedList = null,
    completion: ?Completion = null,

    root_shell: ShellExecEnv,
    root_io: IO,

    has_pending_activity: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Necessary for builtin commands.
    keep_alive: bun.Async.KeepAlive = .{},

    async_commands_executing: u32 = 0,

    flags: packed struct(u8) {
        done: bool = false,
        quiet: bool = false,
        __unused: u6 = 0,
    } = .{},
    exit_code: ?ExitCode = 0,

    /// Tracks which resources have been cleaned up to avoid double-free.
    /// When the interpreter finishes normally via finish(), it cleans up
    /// the runtime resources (IO, shell env) and sets this to .runtime_cleaned.
    /// Completed JavaScript runs also release their owned arguments before dropping pending activity.
    cleanup_state: enum(u8) {
        /// Nothing has been cleaned up yet - need full cleanup
        needs_full_cleanup,
        /// Runtime resources (IO, shell env) have been cleaned up via finish()
        runtime_cleaned,
    } = .needs_full_cleanup,

    __alloc_scope: if (bun.Environment.enableAllocScopes) bun.AllocationScope else void,
    estimated_size_for_gc: std.atomic.Value(usize) = .init(0),

    /// Side-channel for `try_()`: lets init/setup paths use `try`/`errdefer` for cleanup
    /// while still surfacing the rich syscall error (errno+path+syscall) at the boundary.
    last_err: ?Syscall.Error = null,

    /// Unwrap a `Maybe(T)` into `error{Sys}!T`, stashing the syscall error on `last_err`.
    /// Use with `try` so `errdefer` fires for resources acquired earlier in the function.
    /// The boundary `catch`es and reads `takeErr()` to surface it.
    ///
    /// The stashed `Syscall.Error.path` is borrowed; the catch boundary must be inside the
    /// scope that owns any path buffer passed to the failing syscall. In practice keep the
    /// `try_` calls and the `catch` in the same function.
    ///
    /// Main-thread only — thread-pool task bodies must keep using `Maybe` directly.
    pub fn scheduler(this: *const Interpreter) Scheduler {
        return this.scheduler_state;
    }

    pub fn try_(this: *ThisInterpreter, m: anytype) error{Sys}!@TypeOf(m).ReturnType {
        return switch (m) {
            .result => |r| r,
            .err => |e| {
                this.last_err = e;
                return error.Sys;
            },
        };
    }

    pub fn takeErr(this: *ThisInterpreter) Syscall.Error {
        const e = this.last_err.?;
        this.last_err = null;
        return e;
    }

    /// Standalone error sink for code paths where `*ThisInterpreter` isn't available yet
    /// (e.g. `ThisInterpreter.init` before the struct is constructed). Same path-lifetime
    /// caveat as `ThisInterpreter.try_`.
    pub const Catch = struct {
        err: ?Syscall.Error = null,

        pub fn try_(this: *Catch, m: anytype) error{Sys}!@TypeOf(m).ReturnType {
            return switch (m) {
                .result => |r| r,
                .err => |e| {
                    this.err = e;
                    return error.Sys;
                },
            };
        }

        pub fn take(this: *Catch) Syscall.Error {
            const e = this.err.?;
            this.err = null;
            return e;
        }
    };

    // Here are all the state nodes:
    pub const State = @import("./states/Base.zig");
    pub const Script = @import("./states/Script.zig");
    pub const Stmt = @import("./states/Stmt.zig");
    pub const Pipeline = @import("./states/Pipeline.zig");
    pub const Binary = @import("./states/Binary.zig");
    pub const Subshell = @import("./states/Subshell.zig");
    pub const Expansion = @import("./states/Expansion.zig");
    pub const Assigns = @import("./states/Assigns.zig");
    pub const Async = @import("./states/Async.zig");
    pub const CondExpr = @import("./states/CondExpr.zig");
    pub const If = @import("./states/If.zig");
    pub const Cmd = @import("./states/Cmd.zig");

    pub const InterpreterChildPtr = StatePtrUnion(.{
        Script,
    });

    /// During execution, the shell has an "environment" or "context". This
    /// contains important details like environment variables, cwd, etc. Every
    /// state node is given a `*ShellExecEnv` which is stored in its header (see
    /// `states/Base.zig`).
    ///
    /// Certain state nodes like subshells, pipelines, and cmd substitutions
    /// will duplicate their `*ShellExecEnv` so that they can make modifications
    /// without affecting their parent `ShellExecEnv`. This is done in the
    /// `.dupeForSubshell` function.
    ///
    /// For example:
    ///
    /// ```bash
    /// echo $(FOO=bar; echo $FOO); echo $FOO
    /// ```
    ///
    /// The $FOO variable is set inside the command substitution but not outside.
    ///
    /// Note that stdin/stdout/stderr is also considered to be part of the
    /// environment/context, but we keep that in a separate struct called `IO`. We do
    /// this because stdin/stdout/stderr changes a lot and we don't want to copy
    /// this `ShellExecEnv` struct too much.
    ///
    /// More info here: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_12
    pub const ShellExecEnv = struct {
        kind: Kind = .normal,

        /// This is the buffered stdout/stderr that captures the entire
        /// output of the script and is given to JS.
        ///
        /// Accross the entire script execution, this is usually the same.
        ///
        /// It changes when a cmd substitution is run.
        ///
        /// These MUST use the `bun.default_allocator` Allocator
        _buffered_stdout: Bufio = .{ .owned = .{} },
        _buffered_stderr: Bufio = .{ .owned = .{} },

        /// TODO Performance optimization: make these env maps copy-on-write
        /// Shell env for expansion by the shell
        shell_env: EnvMap,
        /// Local environment variables to be given to a subprocess
        cmd_local_env: EnvMap,
        /// Exported environment variables available to all subprocesses. This includes system ones.
        export_env: EnvMap,

        /// The current working directory of the shell.
        /// Use an array list so we don't have to keep reallocating
        /// Always has zero-sentinel
        __prev_cwd: std.array_list.Managed(u8),
        __cwd: std.array_list.Managed(u8),
        cwd_fd: bun.FD,

        async_pids: SmolList(pid_t, 4) = SmolList(pid_t, 4).zeroes,

        __alloc_scope: if (bun.Environment.enableAllocScopes) *bun.AllocationScope else void,

        const pid_t = if (bun.Environment.isPosix) std.posix.pid_t else uv.uv_pid_t;

        const Bufio = union(enum) {
            owned: bun.ByteList,
            borrowed: *bun.ByteList,
            pub fn memoryCost(this: *const @This()) usize {
                return switch (this.*) {
                    .owned => |*owned| owned.memoryCost(),
                    .borrowed => |borrowed| borrowed.memoryCost(),
                };
            }
        };

        const Kind = enum {
            normal,
            cmd_subst,
            subshell,
            pipeline,
        };

        pub fn allocator(this: *ShellExecEnv) std.mem.Allocator {
            if (comptime bun.Environment.enableAllocScopes) return this.__alloc_scope.allocator();
            return bun.default_allocator;
        }

        pub fn memoryCost(this: *const ShellExecEnv) usize {
            var size: usize = @sizeOf(ShellExecEnv);
            size += this.shell_env.memoryCost();
            size += this.cmd_local_env.memoryCost();
            size += this.export_env.memoryCost();
            size += this.__cwd.allocatedSlice().len;
            size += this.__prev_cwd.allocatedSlice().len;
            size += this._buffered_stderr.memoryCost();
            size += this._buffered_stdout.memoryCost();
            size += this.async_pids.memoryCost();
            return size;
        }

        pub fn buffered_stdout(this: *ShellExecEnv) *bun.ByteList {
            return switch (this._buffered_stdout) {
                .owned => &this._buffered_stdout.owned,
                .borrowed => this._buffered_stdout.borrowed,
            };
        }

        pub fn buffered_stderr(this: *ShellExecEnv) *bun.ByteList {
            return switch (this._buffered_stderr) {
                .owned => &this._buffered_stderr.owned,
                .borrowed => this._buffered_stderr.borrowed,
            };
        }

        pub inline fn cwdZ(this: *ShellExecEnv) [:0]const u8 {
            if (this.__cwd.items.len == 0) return "";
            return this.__cwd.items[0..this.__cwd.items.len -| 1 :0];
        }

        pub inline fn prevCwdZ(this: *ShellExecEnv) [:0]const u8 {
            if (this.__prev_cwd.items.len == 0) return "";
            return this.__prev_cwd.items[0..this.__prev_cwd.items.len -| 1 :0];
        }

        pub inline fn prevCwd(this: *ShellExecEnv) []const u8 {
            const prevcwdz = this.prevCwdZ();
            return prevcwdz[0..prevcwdz.len];
        }

        pub inline fn cwd(this: *ShellExecEnv) []const u8 {
            const cwdz = this.cwdZ();
            return cwdz[0..cwdz.len];
        }

        pub fn deinit(this: *ShellExecEnv) void {
            this.deinitImpl(true, true);
        }

        /// Doesn't deref `this.io`
        ///
        /// If called by interpreter we have to:
        /// 1. not free this *ShellExecEnv, because its on a field on the interpreter
        /// 2. don't free buffered_stdout and buffered_stderr, because that is used for output
        fn deinitImpl(this: *ShellExecEnv, comptime destroy_this: bool, comptime free_buffered_io: bool) void {
            log("[ShellExecEnv] deinit {x}", .{@intFromPtr(this)});

            if (comptime free_buffered_io) {
                if (this._buffered_stdout == .owned) {
                    this._buffered_stdout.owned.clearAndFree(bun.default_allocator);
                }
                if (this._buffered_stderr == .owned) {
                    this._buffered_stderr.owned.clearAndFree(bun.default_allocator);
                }
            }

            this.shell_env.deinit();
            this.cmd_local_env.deinit();
            this.export_env.deinit();
            this.__cwd.deinit();
            this.__prev_cwd.deinit();
            closefd(this.cwd_fd);

            if (comptime destroy_this) this.allocator().destroy(this);
        }

        pub fn dupeForSubshell(
            this: *ShellExecEnv,
            alloc_scope: if (bun.Environment.enableAllocScopes) *bun.AllocationScope else void,
            alloc: Allocator,
            io: IO,
            kind: Kind,
        ) Maybe(*ShellExecEnv) {
            const duped = bun.handleOom(alloc.create(ShellExecEnv));

            const dupedfd = switch (Syscall.dup(this.cwd_fd)) {
                .err => |err| {
                    alloc.destroy(duped);
                    return .{ .err = err };
                },
                .result => |fd| fd,
            };

            const stdout: Bufio = switch (io.stdout) {
                .fd => brk: {
                    if (io.stdout.fd.captured != null) break :brk .{ .borrowed = io.stdout.fd.captured.? };
                    break :brk .{ .owned = .{} };
                },
                .ignore => .{ .owned = .{} },
                .pipe => switch (kind) {
                    .normal, .cmd_subst => .{ .owned = .{} },
                    .subshell, .pipeline => .{ .borrowed = this.buffered_stdout() },
                },
            };

            const stderr: Bufio = switch (io.stderr) {
                .fd => brk: {
                    if (io.stderr.fd.captured != null) break :brk .{ .borrowed = io.stderr.fd.captured.? };
                    break :brk .{ .owned = .{} };
                },
                .ignore => .{ .owned = .{} },
                .pipe => switch (kind) {
                    .normal, .cmd_subst => .{ .owned = .{} },
                    .subshell, .pipeline => .{ .borrowed = this.buffered_stderr() },
                },
            };

            duped.* = .{
                .kind = kind,
                ._buffered_stdout = stdout,
                ._buffered_stderr = stderr,
                .shell_env = this.shell_env.clone(),
                .cmd_local_env = EnvMap.init(alloc),
                .export_env = this.export_env.clone(),

                .__prev_cwd = bun.handleOom(this.__prev_cwd.clone()),
                .__cwd = bun.handleOom(this.__cwd.clone()),
                // TODO probably need to use os.dup here
                .cwd_fd = dupedfd,
                .__alloc_scope = alloc_scope,
            };

            return .{ .result = duped };
        }

        /// NOTE: This will `.ref()` value, so you should `defer value.deref()` it before handing it to this function.
        pub fn assignVar(this: *ShellExecEnv, interp: *ThisInterpreter, label: EnvStr, value: EnvStr, assign_ctx: AssignCtx) void {
            _ = interp; // autofix
            switch (assign_ctx) {
                .cmd => this.cmd_local_env.insert(label, value),
                .shell => this.shell_env.insert(label, value),
                .exported => this.export_env.insert(label, value),
            }
        }

        pub fn changePrevCwd(self: *ShellExecEnv, interp: *ThisInterpreter) Maybe(void) {
            return self.changeCwd(interp, self.prevCwdZ());
        }

        pub fn changeCwd(this: *ShellExecEnv, interp: *ThisInterpreter, new_cwd_: anytype) Maybe(void) {
            return this.changeCwdImpl(interp, new_cwd_, false);
        }

        pub fn changeCwdImpl(this: *ShellExecEnv, _: *ThisInterpreter, new_cwd_: anytype, comptime in_init: bool) Maybe(void) {
            if (comptime @TypeOf(new_cwd_) != [:0]const u8 and @TypeOf(new_cwd_) != []const u8) {
                @compileError("Bad type for new_cwd " ++ @typeName(@TypeOf(new_cwd_)));
            }
            var new_cwd_buf: bun.PathBuffer = undefined;
            const new_cwd: [:0]const u8 = if (comptime @TypeOf(new_cwd_) == [:0]const u8)
                new_cwd_
            else
                std.mem.printSentinel(&new_cwd_buf, "{s}", .{new_cwd_}, 0) catch
                    return Maybe(void).initErr(Syscall.Error.fromCode(.NAMETOOLONG, .chdir));

            const new_cwd_fd = switch (ShellSyscall.openat(
                this.cwd_fd,
                new_cwd,
                bun.O.DIRECTORY | bun.O.RDONLY,
                0,
            )) {
                .result => |fd| fd,
                .err => |err| {
                    return Maybe(void).initErr(err);
                },
            };
            const resolved_cwd = bun.handleOom(std.fs.path.resolve(bun.default_allocator, &.{ this.cwd(), new_cwd_ }));
            defer bun.default_allocator.free(resolved_cwd);
            _ = this.cwd_fd.closeAllowingBadFileDescriptor(null);

            this.__prev_cwd.clearRetainingCapacity();
            bun.handleOom(this.__prev_cwd.appendSlice(this.__cwd.items[0..]));

            this.__cwd.clearRetainingCapacity();
            bun.handleOom(this.__cwd.appendSlice(resolved_cwd));
            bun.handleOom(this.__cwd.append(0));

            if (comptime bun.Environment.isDebug) {
                assert(this.__cwd.items[this.__cwd.items.len -| 1] == 0);
                assert(this.__prev_cwd.items[this.__prev_cwd.items.len -| 1] == 0);
            }

            this.cwd_fd = new_cwd_fd;

            if (comptime !in_init) {
                this.export_env.insert(EnvStr.initSlice("OLDPWD"), EnvStr.initSlice(this.prevCwd()));
            }
            this.export_env.insert(EnvStr.initSlice("PWD"), EnvStr.initSlice(this.cwd()));

            return .success;
        }

        pub fn getHomedir(self: *ShellExecEnv) EnvStr {
            const env_var: ?EnvStr = brk: {
                const static_str = if (comptime bun.Environment.isWindows) EnvStr.initSlice("USERPROFILE") else EnvStr.initSlice("HOME");
                break :brk self.shell_env.get(static_str) orelse self.export_env.get(static_str);
            };
            return env_var orelse EnvStr.initSlice(if (comptime bun.Environment.isAndroid) "/data/local/tmp" else "");
        }

        pub fn writeFailingErrorFmt(
            this: *ShellExecEnv,
            ctx: anytype,
            enqueueCb: fn (c: @TypeOf(ctx)) void,
            comptime fmt: []const u8,
            args: anytype,
        ) Yield {
            const io: *IO.OutKind = &@field(ctx.io, "stderr");
            switch (io.*) {
                .fd => |x| {
                    enqueueCb(ctx);
                    return x.writer.enqueueFmt(ctx, x.captured, fmt, args);
                },
                .pipe => {
                    const bufio: *bun.ByteList = this.buffered_stderr();
                    bun.handleOom(bufio.appendFmt(bun.default_allocator, fmt, args));
                    return ctx.parent.childDone(ctx, 1);
                },
                // FIXME: This is not correct? This would just make the entire shell hang I think?
                .ignore => {
                    const childptr = IOWriterChildPtr.init(ctx);
                    // TODO: is this necessary
                    const count = std.fmt.count(fmt, args);
                    return .{ .on_io_writer_chunk = .{
                        .child = childptr,
                        .err = null,
                        .written = count,
                    } };
                },
            }
        }
    };

    const Arguments = union(enum) {
        borrowed: *ShellArgs,
        owned: bun.bindgen.OwnedNative(ShellArgs, .any),
        released,

        fn get(this: *const Arguments) *ShellArgs {
            return switch (this.*) {
                .borrowed => |args| args,
                .owned => |args| args.get(),
                .released => @panic("shell arguments used after execution cleanup"),
            };
        }

        fn memoryCost(this: *const Arguments) usize {
            return if (this.* == .released) 0 else this.get().memoryCost();
        }

        fn deinit(this: *Arguments) void {
            if (this.* == .owned) this.owned.deinit();
            this.* = .released;
        }
    };

    const ThisInterpreter = @This();

    pub fn computeEstimatedSizeForGC(this: *const ThisInterpreter) usize {
        var size: usize = @sizeOf(ThisInterpreter);
        size += this.args.memoryCost();
        size += this.root_shell.memoryCost();
        size += this.root_io.memoryCost();
        if (this.shell_values) |values| size += values.get().memoryCost();
        return size;
    }

    pub fn estimatedSize(this: *const ThisInterpreter) usize {
        return this.estimated_size_for_gc.load(.monotonic);
    }

    pub fn shellValue(this: *const ThisInterpreter, index: u32) ?*const ShellValue.Value {
        const values = if (this.shell_values) |owned| owned.get().values.items else return null;
        if (index >= values.len) return null;
        return &values[index];
    }

    pub fn parse(
        arena_allocator: std.mem.Allocator,
        script: []const u8,
        object_count: u32,
        jsstrings_to_escape: []bun.String,
        out_parser: *?bun.shell.Parser,
        out_lex_result: *?shell.LexResult,
    ) !ast.Script {
        const lex_result = brk: {
            if (bun.strings.isAllASCII(script)) {
                var lexer = bun.shell.LexerAscii.new(arena_allocator, script, jsstrings_to_escape, object_count);
                try lexer.lex();
                break :brk lexer.get_result();
            }
            var lexer = bun.shell.LexerUnicode.new(arena_allocator, script, jsstrings_to_escape, object_count);
            try lexer.lex();
            break :brk lexer.get_result();
        };

        if (lex_result.errors.len > 0) {
            out_lex_result.* = lex_result;
            return shell.ParseError.Lex;
        }

        if (comptime bun.Environment.isDebug) {
            const debug = bun.Output.scoped(.ShellTokens, .hidden);
            var test_tokens = std.array_list.Managed(shell.Test.TestToken).initCapacity(arena_allocator, lex_result.tokens.len) catch @panic("OOPS");
            defer test_tokens.deinit();
            for (lex_result.tokens) |tok| {
                const test_tok = shell.Test.TestToken.from_real(tok, lex_result.strpool);
                test_tokens.append(test_tok) catch @panic("OOPS");
            }

            const str = bun.handleOom(std.fmt.allocPrint(bun.default_allocator, "{f}", .{std.json.fmt(test_tokens.items[0..], .{})}));
            defer bun.default_allocator.free(str);
            debug("Tokens: {s}", .{str});
        }

        out_parser.* = try bun.shell.Parser.new(arena_allocator, lex_result);

        const script_ast = try out_parser.*.?.parse();
        return script_ast;
    }

    /// If all initialization allocations succeed, the arena will be copied
    /// into the interpreter struct, so it is not a stale reference and safe to call `arena.deinit()` on error.
    pub fn init(
        ctx: ?bun.cli.Command.Context,
        loop_scheduler: Scheduler,
        allocator: Allocator,
        shargs: *ShellArgs,
        export_env_: ?EnvMap,
        cwd_: ?[]const u8,
    ) shell.Result(*ThisInterpreter) {
        // Hoisted so the catch boundary's toShellSystemError() can read err.path
        // (which borrows from this buffer) before it's returned to the pool.
        const pathbuf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(pathbuf);

        var sys: Catch = .{};
        const interpreter = initImpl(&sys, ctx, loop_scheduler, allocator, shargs, export_env_, pathbuf) catch {
            return .{ .err = .{ .sys = sys.take().toShellSystemError() } };
        };

        if (cwd_) |c| {
            if (interpreter.root_shell.changeCwdImpl(interpreter, c, true).asErr()) |e| {
                const sys_err = e.toShellSystemError();
                interpreter.root_io.deref();
                interpreter.root_shell.deinitImpl(false, true);
                if (comptime bun.Environment.enableAllocScopes) interpreter.__alloc_scope.deinit();
                allocator.destroy(interpreter);
                return .{ .err = .{ .sys = sys_err } };
            }
        }

        interpreter.root_shell.__alloc_scope = if (bun.Environment.enableAllocScopes) &interpreter.__alloc_scope else {};

        return .{ .result = interpreter };
    }

    fn initImpl(
        sys: *Catch,
        ctx: ?bun.cli.Command.Context,
        loop_scheduler: Scheduler,
        allocator: Allocator,
        shargs: *ShellArgs,
        export_env_: ?EnvMap,
        pathbuf: *bun.PathBuffer,
    ) error{Sys}!*ThisInterpreter {
        var export_env = brk: {
            if (loop_scheduler.isJavaScript()) break :brk if (export_env_) |e| e else EnvMap.init(allocator);

            const env_loader = loop_scheduler.environment;

            // This will save ~2x memory
            var export_env = EnvMap.initWithCapacity(allocator, env_loader.map.map.entries.len);

            var iter = env_loader.iterator();

            while (iter.next()) |entry| {
                const value = EnvStr.initSlice(entry.value_ptr.value);
                const key = EnvStr.initSlice(entry.key_ptr.*);
                export_env.insert(key, value);
            }

            break :brk export_env;
        };
        // init() consumes export_env_ regardless of outcome; callers must not free it.
        errdefer export_env.deinit();

        const cwd: [:0]const u8 = try sys.try_(Syscall.getcwdZ(pathbuf));

        const cwd_fd = try sys.try_(Syscall.open(cwd, bun.O.DIRECTORY | bun.O.RDONLY, 0));
        errdefer cwd_fd.close();

        var cwd_arr = bun.handleOom(std.array_list.Managed(u8).initCapacity(bun.default_allocator, cwd.len + 1));
        bun.handleOom(cwd_arr.appendSlice(cwd[0 .. cwd.len + 1]));
        errdefer cwd_arr.deinit();

        if (comptime bun.Environment.isDebug) {
            assert(cwd_arr.items[cwd_arr.items.len -| 1] == 0);
        }

        log("Duping stdin", .{});
        const stdin_fd = try sys.try_(if (bun.Output.Source.Stdio.isStdinNull()) bun.sys.openNullDevice() else ShellSyscall.dup(shell.STDIN_FD));

        const stdin_reader = IOReader.init(stdin_fd, loop_scheduler);
        errdefer stdin_reader.deref();

        const interpreter = bun.handleOom(allocator.create(ThisInterpreter));
        interpreter.* = .{
            .command_ctx = ctx,
            .scheduler_state = loop_scheduler,

            .args = .{ .borrowed = shargs },
            .allocator = allocator,

            .root_shell = ShellExecEnv{
                .shell_env = EnvMap.init(allocator),
                .cmd_local_env = EnvMap.init(allocator),
                .export_env = export_env,

                .__cwd = cwd_arr,
                .__prev_cwd = bun.handleOom(cwd_arr.clone()),
                .cwd_fd = cwd_fd,

                .__alloc_scope = undefined,
            },

            .root_io = .{
                .stdin = .{
                    .fd = stdin_reader,
                },
                // By default stdout/stderr should be an IOWriter writing to a dup'ed stdout/stderr
                // But if the user later calls `.setQuiet(true)` then all those syscalls/initialization was pointless work
                // So we cheaply initialize them now as `.pipe`
                // When `Interpreter.run()` is called, we check if `this.flags.quiet == false`, if so then we then properly initialize the IOWriter
                .stdout = .pipe,
                .stderr = .pipe,
            },

            .__alloc_scope = if (bun.Environment.enableAllocScopes) bun.AllocationScope.init(loop_scheduler.io(), allocator) else {},
        };

        return interpreter;
    }

    pub fn initAndRunFromFile(ctx: bun.cli.Command.Context, mini: *bun.MiniEventLoop, path: []const u8) !bun.shell.ExitCode {
        var shargs = ShellArgs.init();
        const src = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, shargs.arena_allocator(), .limited(std.math.maxInt(u32)));
        defer shargs.deinit();

        var out_parser: ?bun.shell.Parser = null;
        var out_lex_result: ?bun.shell.LexResult = null;
        const script = ThisInterpreter.parse(
            shargs.arena_allocator(),
            src,
            0,
            &[_]bun.String{},
            &out_parser,
            &out_lex_result,
        ) catch |err| {
            if (err == bun.shell.ParseError.Lex) {
                assert(out_lex_result != null);
                const str = out_lex_result.?.combineErrors(shargs.arena_allocator());
                bun.Output.prettyErrorln("<r><red>error<r>: Failed to run <b>{s}<r> due to error <b>{s}<r>", .{ std.fs.path.basename(path), str });
                bun.Global.exit(1);
            }

            if (out_parser) |*p| {
                const errstr = p.combineErrors();
                bun.Output.prettyErrorln("<r><red>error<r>: Failed to run <b>{s}<r> due to error <b>{s}<r>", .{ std.fs.path.basename(path), errstr });
                bun.Global.exit(1);
            }

            return err;
        };
        shargs.script_ast = script;
        var interp = switch (ThisInterpreter.init(
            ctx,
            Scheduler.initMini(mini),
            bun.default_allocator,
            shargs,
            null,
            null,
        )) {
            .err => |*e| {
                e.throwMini();
            },
            .result => |i| i,
        };

        const exit_code: ExitCode = 1;

        const IsDone = struct {
            interp: *const Interpreter,

            fn isDone(this: *anyopaque) bool {
                const asdlfk = bun.cast(*const @This(), this);
                return asdlfk.interp.flags.done;
            }
        };
        var is_done: IsDone = .{
            .interp = interp,
        };
        interp.exit_code = exit_code;
        switch (try interp.run()) {
            .err => |e| {
                interp.deinitFromExec();
                bun.Output.err(e, "Failed to run script <b>{s}<r>", .{std.fs.path.basename(path)});
                bun.Global.exit(1);
                return 1;
            },
            else => {},
        }
        mini.tick(&is_done, @as(fn (*anyopaque) bool, IsDone.isDone));
        const code = interp.exit_code.?;
        interp.deinitFromExec();
        return code;
    }

    pub fn initAndRunFromSource(ctx: bun.cli.Command.Context, mini: *bun.MiniEventLoop, path_for_errors: []const u8, src: []const u8, cwd: ?[]const u8) !ExitCode {
        bun.analytics.Features.standalone_shell += 1;
        var shargs = ShellArgs.init();
        defer shargs.deinit();

        var out_parser: ?bun.shell.Parser = null;
        var out_lex_result: ?bun.shell.LexResult = null;
        const script = ThisInterpreter.parse(shargs.arena_allocator(), src, 0, &[_]bun.String{}, &out_parser, &out_lex_result) catch |err| {
            if (err == bun.shell.ParseError.Lex) {
                assert(out_lex_result != null);
                const str = out_lex_result.?.combineErrors(shargs.arena_allocator());
                bun.Output.prettyErrorln("<r><red>error<r>: Failed to run script <b>{s}<r> due to error <b>{s}<r>", .{ path_for_errors, str });
                bun.Global.exit(1);
            }

            if (out_parser) |*p| {
                const errstr = p.combineErrors();
                bun.Output.prettyErrorln("<r><red>error<r>: Failed to run script <b>{s}<r> due to error <b>{s}<r>", .{ path_for_errors, errstr });
                bun.Global.exit(1);
            }

            return err;
        };
        shargs.script_ast = script;
        var interp: *ThisInterpreter = switch (ThisInterpreter.init(
            ctx,
            Scheduler.initMini(mini),
            bun.default_allocator,
            shargs,
            null,
            cwd,
        )) {
            .err => |*e| {
                e.throwMini();
            },
            .result => |i| i,
        };
        const IsDone = struct {
            interp: *const Interpreter,

            fn isDone(this: *anyopaque) bool {
                const asdlfk = bun.cast(*const @This(), this);
                return asdlfk.interp.flags.done;
            }
        };
        var is_done: IsDone = .{
            .interp = interp,
        };
        const exit_code: ExitCode = 1;
        interp.exit_code = exit_code;
        switch (try interp.run()) {
            .err => |e| {
                interp.deinitFromExec();
                bun.Output.err(e, "Failed to run script <b>{s}<r>", .{path_for_errors});
                bun.Global.exit(1);
                return 1;
            },
            else => {},
        }
        mini.tick(&is_done, @as(fn (*anyopaque) bool, IsDone.isDone));
        const code = interp.exit_code.?;
        interp.deinitFromExec();
        return code;
    }

    fn setupIOBeforeRun(this: *ThisInterpreter) Maybe(void) {
        return if (this.setupIOBeforeRunImpl()) |_| .success else |_| .{ .err = this.takeErr() };
    }

    fn setupIOBeforeRunImpl(this: *ThisInterpreter) error{Sys}!void {
        if (!this.flags.quiet) {
            log("Duping stdout", .{});
            const stdout_fd = try this.try_(if (bun.Output.Source.Stdio.isStdoutNull()) bun.sys.openNullDevice() else ShellSyscall.dup(.stdout()));
            errdefer stdout_fd.close();

            log("Duping stderr", .{});
            const stderr_fd = try this.try_(if (bun.Output.Source.Stdio.isStderrNull()) bun.sys.openNullDevice() else ShellSyscall.dup(.stderr()));
            errdefer stderr_fd.close();

            const loop_scheduler = this.scheduler();
            const stdout_writer = IOWriter.init(
                stdout_fd,
                .{},
                loop_scheduler,
            );
            const stderr_writer = IOWriter.init(stderr_fd, .{}, this.scheduler());

            this.root_io = .{
                .stdin = this.root_io.stdin,
                .stdout = .{
                    .fd = .{
                        .writer = stdout_writer,
                    },
                },
                .stderr = .{
                    .fd = .{
                        .writer = stderr_writer,
                    },
                },
            };

            if (this.scheduler_state.isJavaScript()) {
                this.root_io.stdout.fd.captured = &this.root_shell._buffered_stdout.owned;
                this.root_io.stderr.fd.captured = &this.root_shell._buffered_stderr.owned;
            }
        }
    }

    pub fn run(this: *ThisInterpreter) !Maybe(void) {
        log("Interpreter(0x{x}) run", .{@intFromPtr(this)});
        if (this.setupIOBeforeRun().asErr()) |e| {
            return .{ .err = e };
        }

        var root = Script.init(this, &this.root_shell, &this.args.get().script_ast, Script.ParentPtr.init(this), this.root_io.copy());
        this.started.store(true, .seq_cst);
        root.start().run();

        return .success;
    }

    pub fn adoptArguments(this: *ThisInterpreter) void {
        const args = switch (this.args) {
            .borrowed => |args| args,
            .owned, .released => @panic("shell arguments adopted more than once"),
        };
        this.args = .{ .owned = .init(args) };
    }

    pub fn prepareRunFromJS(this: *ThisInterpreter) Maybe(void) {
        if (this.setupIOBeforeRun().asErr()) |e| {
            this.scheduler_state.disable(&this.keep_alive);
            defer this.derefRootShellAndIOIfNeeded(true);
            return .{ .err = e };
        }
        return .success;
    }

    pub fn startFromJS(this: *ThisInterpreter) void {
        this.scheduler_state.ref(&this.keep_alive);
        incrPendingActivityFlag(&this.has_pending_activity);

        var root = Script.init(this, &this.root_shell, &this.args.get().script_ast, Script.ParentPtr.init(this), this.root_io.copy());
        this.started.store(true, .seq_cst);
        root.start().run();
    }

    pub fn asyncCmdDone(this: *ThisInterpreter, async: *Async) void {
        log("asyncCommandDone {f}", .{async});
        async.actuallyDeinit();
        this.async_commands_executing -= 1;
        if (this.async_commands_executing == 0 and this.exit_code != null) {
            this.finish(this.exit_code.?).run();
        }
    }

    pub fn childDone(this: *ThisInterpreter, child: InterpreterChildPtr, exit_code: ExitCode) Yield {
        if (child.ptr.is(Script)) {
            const script = child.as(Script);
            script.deinitFromInterpreter();
            this.exit_code = exit_code;
            if (this.async_commands_executing == 0) return this.finish(exit_code);
            return .suspended;
        }
        @panic("Bad child");
    }

    pub fn finish(this: *ThisInterpreter, exit_code: ExitCode) Yield {
        log("Interpreter(0x{x}) finish {d}", .{ @intFromPtr(this), exit_code });

        if (this.completion) |completion| {
            defer decrPendingActivityFlag(&this.has_pending_activity);
            this.exit_code = exit_code;
            completion.finish(exit_code, this.root_shell.buffered_stdout(), this.root_shell.buffered_stderr(), this, finishRuntimeCleanup);
            this.releaseCompletion();
        } else {
            this.flags.done = true;
            this.exit_code = exit_code;
        }

        return .done;
    }

    fn finishRuntimeCleanup(raw_interpreter: *anyopaque) void {
        const this: *ThisInterpreter = @ptrCast(@alignCast(raw_interpreter));
        this.scheduler_state.disable(&this.keep_alive);
        this.derefRootShellAndIOIfNeeded(true);
        this.releaseShellValues();
        this.args.deinit();
        this.estimated_size_for_gc.store(@sizeOf(ThisInterpreter), .monotonic);
    }

    fn derefRootShellAndIOIfNeeded(this: *ThisInterpreter, free_buffered_io: bool) void {
        // Check if already cleaned up to prevent double-free
        if (this.cleanup_state == .runtime_cleaned) {
            return;
        }

        if (free_buffered_io) {
            // Can safely be called multiple times.
            if (this.root_shell._buffered_stderr == .owned) {
                this.root_shell._buffered_stderr.owned.clearAndFree(bun.default_allocator);
            }
            if (this.root_shell._buffered_stdout == .owned) {
                this.root_shell._buffered_stdout.owned.clearAndFree(bun.default_allocator);
            }
        }

        this.root_io.deref();
        this.root_shell.deinitImpl(false, false);
        // Mark that runtime resources have been cleaned up
        this.cleanup_state = .runtime_cleaned;
    }

    fn releaseCompletion(this: *ThisInterpreter) void {
        if (this.completion) |completion| completion.deinit();
        this.completion = null;
    }

    fn releaseBindingRoots(this: *ThisInterpreter) void {
        this.releaseCompletion();
        this.releaseShellValues();
    }

    fn releaseShellValues(this: *ThisInterpreter) void {
        if (bun.take(&this.shell_values)) |owned| {
            var values = owned;
            values.deinit();
        }
    }

    fn deinitFromFinalizer(this: *ThisInterpreter) void {
        log("Interpreter(0x{x}) deinitFromFinalizer (cleanup_state={s})", .{ @intFromPtr(this), @tagName(this.cleanup_state) });

        switch (this.cleanup_state) {
            .needs_full_cleanup => {
                // The interpreter never finished normally (e.g., early error or never started),
                // so we need to clean up IO and shell env here
                this.root_io.deref();
                this.root_shell.deinitImpl(false, true);
            },
            .runtime_cleaned => {
                // finish() already cleaned up IO and shell env via derefRootShellAndIOIfNeeded,
                // nothing more to do for those resources
            },
        }

        this.scheduler_state.disable(&this.keep_alive);
        this.releaseBindingRoots();
        this.args.deinit();
        this.allocator.destroy(this);
    }

    fn deinitFromExec(this: *ThisInterpreter) void {
        log("deinit interpreter", .{});

        this.root_io.deref();
        this.root_shell.deinitImpl(false, true);
        this.releaseBindingRoots();
        this.args.deinit();

        this.allocator.destroy(this);
    }

    pub fn finalize(this: *ThisInterpreter) void {
        log("Interpreter(0x{x}) finalize", .{@intFromPtr(this)});
        this.deinitFromFinalizer();
    }

    pub fn destroy(this: *ThisInterpreter) void {
        this.finalize();
    }

    pub fn hasPendingActivity(this: *const ThisInterpreter) bool {
        return this.has_pending_activity.load(.seq_cst) > 0;
    }

    fn incrPendingActivityFlag(has_pending_activity: *std.atomic.Value(u32)) void {
        _ = has_pending_activity.fetchAdd(1, .seq_cst);
        log("Interpreter incr pending activity {d}", .{has_pending_activity.load(.seq_cst)});
    }

    fn decrPendingActivityFlag(has_pending_activity: *std.atomic.Value(u32)) void {
        _ = has_pending_activity.fetchSub(1, .seq_cst);
        log("Interpreter decr pending activity {d}", .{has_pending_activity.load(.seq_cst)});
    }

    pub fn rootIO(this: *const Interpreter) *const IO {
        return &this.root_io;
    }

    pub const Builtin = @import("./Builtin.zig");

    pub const IO = @import("./IO.zig");
    pub const IOReader = @import("./IOReader.zig");
    pub const IOReaderChildPtr = IOReader.ChildPtr;
    pub const IOWriter = @import("./IOWriter.zig");
};

/// Construct a tagged union of the state nodes provided in `TypesValue`.
/// The returned type has functions to call state node functions on the underlying type.
///
/// A state node must implement the following functions:
/// - `.start()`
/// - `.deinit()`
/// - `.childDone()`
///
/// In addition, a state node struct must declare a `pub const ChildPtr = StatePtrUnion(...)` variable.
/// This `ChildPtr` variable declares all the possible state nodes that can be a *child* of the state node.
pub fn StatePtrUnion(comptime TypesValue: anytype) type {
    return struct {
        ptr: Ptr,

        const Ptr = TaggedPointerUnion(TypesValue);
        const tag_values = @typeInfo(Ptr.Tag).@"enum".field_values;

        pub fn getChildPtrType(comptime Type: type) type {
            if (Type == Interpreter)
                return Interpreter.InterpreterChildPtr;
            if (!@hasDecl(Type, "ChildPtr")) {
                @compileError(@typeName(Type) ++ " does not have ChildPtr aksjdflkasjdflkasdjf");
            }
            return Type.ChildPtr;
        }

        pub fn scopedAllocator(this: @This()) if (bun.Environment.enableAllocScopes) *bun.AllocationScope else void {
            if (comptime !bun.Environment.enableAllocScopes) return;

            inline for (tag_values) |tag_value| {
                if (this.tagInt() == tag_value) {
                    const Ty = comptime Ptr.typeFromTag(tag_value);
                    Ptr.assert_type(Ty);
                    var casted = this.as(Ty);
                    if (comptime Ty == Interpreter) {
                        return &casted.__alloc_scope;
                    }
                    return casted.base.__alloc_scope.scopedAllocator();
                }
            }
            unknownTag(this.tagInt());
        }

        pub fn allocator(this: @This()) std.mem.Allocator {
            inline for (tag_values) |tag_value| {
                if (this.tagInt() == tag_value) {
                    const Ty = comptime Ptr.typeFromTag(tag_value);
                    Ptr.assert_type(Ty);
                    var casted = this.as(Ty);
                    if (comptime Ty == Interpreter) {
                        if (bun.Environment.enableAllocScopes) return casted.__alloc_scope.allocator();
                        return bun.default_allocator;
                    }
                    return casted.base.allocator();
                }
            }
            unknownTag(this.tagInt());
        }

        pub fn create(this: @This(), comptime Ty: type) *Ty {
            if (comptime bun.Environment.enableAllocScopes) {
                return bun.handleOom(this.allocator().create(Ty));
            }
            return bun.handleOom(bun.default_allocator.create(Ty));
        }

        pub fn destroy(this: @This(), ptr: anytype) void {
            if (comptime bun.Environment.enableAllocScopes) {
                this.allocator().destroy(ptr);
            } else {
                bun.default_allocator.destroy(ptr);
            }
        }

        /// Starts the state node.
        pub fn start(this: @This()) Yield {
            inline for (tag_values) |tag_value| {
                if (this.tagInt() == tag_value) {
                    const Ty = comptime Ptr.typeFromTag(tag_value);
                    Ptr.assert_type(Ty);
                    var casted = this.as(Ty);
                    return casted.start();
                }
            }
            unknownTag(this.tagInt());
        }

        /// Deinitializes the state node
        pub fn deinit(this: @This()) void {
            inline for (tag_values) |tag_value| {
                if (this.tagInt() == tag_value) {
                    const Ty = comptime Ptr.typeFromTag(tag_value);
                    Ptr.assert_type(Ty);
                    var casted = this.as(Ty);

                    casted.deinit();
                    return;
                }
            }
            unknownTag(this.tagInt());
        }

        /// Signals to the state node that one of its children completed with the
        /// given exit code
        pub fn childDone(this: @This(), child: anytype, exit_code: ExitCode) Yield {
            inline for (tag_values) |tag_value| {
                if (this.tagInt() == tag_value) {
                    const Ty = comptime Ptr.typeFromTag(tag_value);
                    Ptr.assert_type(Ty);
                    const child_ptr = brk: {
                        const ChildPtr = getChildPtrType(Ty);
                        break :brk ChildPtr.init(child);
                    };
                    var casted = this.as(Ty);
                    return casted.childDone(child_ptr, exit_code);
                }
            }
            unknownTag(this.tagInt());
        }

        pub fn unknownTag(tag: Ptr.TagInt) noreturn {
            return bun.Output.panic("Unknown tag for shell state node: {d}\n", .{tag});
        }

        pub fn tagInt(this: @This()) Ptr.TagInt {
            return @backingInt(this.ptr.tag());
        }

        pub fn tagName(this: @This()) []const u8 {
            return Ptr.typeNameFromTag(this.tagInt()).?;
        }

        pub fn init(_ptr: anytype) @This() {
            const tyinfo = @typeInfo(@TypeOf(_ptr));
            if (tyinfo != .pointer) @compileError("Only pass pointers to StatePtrUnion.init(), you gave us a: " ++ @typeName(@TypeOf(_ptr)));
            const Type = std.meta.Child(@TypeOf(_ptr));
            Ptr.assert_type(Type);

            return .{ .ptr = Ptr.init(_ptr) };
        }

        pub inline fn as(this: @This(), comptime Type: type) *Type {
            return this.ptr.as(Type);
        }
    };
}

pub fn closefd(fd: bun.FD) void {
    if (fd.closeAllowingBadFileDescriptor(null)) |err| {
        log("ERR closefd: {f}\n", .{err});
    }
}

const CmdEnvIter = struct {
    env: *const bun.StringArrayHashMap([:0]const u8),
    iter: bun.StringArrayHashMap([:0]const u8).Iterator,

    const Entry = struct {
        key: Key,
        value: Value,
    };

    const Value = struct {
        val: [:0]const u8,

        pub fn format(self: Value, writer: *std.Io.Writer) !void {
            try writer.writeAll(self.val);
        }
    };

    const Key = struct {
        val: []const u8,

        pub fn format(self: Key, writer: *std.Io.Writer) !void {
            try writer.writeAll(self.val);
        }

        pub fn eqlComptime(this: Key, comptime str: []const u8) bool {
            return bun.strings.eqlComptime(this.val, str);
        }
    };

    pub fn fromEnv(env: *const bun.StringArrayHashMap([:0]const u8)) CmdEnvIter {
        const iter = env.iterator();
        return .{
            .env = env,
            .iter = iter,
        };
    }

    pub fn len(self: *const CmdEnvIter) usize {
        return self.env.entries.len;
    }

    pub fn next(self: *CmdEnvIter) !?Entry {
        const entry = self.iter.next() orelse return null;
        return .{
            .key = .{ .val = entry.key_ptr.* },
            .value = .{ .val = entry.value_ptr.* },
        };
    }
};

/// A concurrent task, the idea is that this task is not heap allocated because
/// it will be in a field of one of the Shell state structs which will be heap
/// allocated.
pub fn ShellTask(
    comptime Ctx: type,
    /// Function to be called when the thread pool starts the task, this could
    /// be on anyone of the thread pool threads so be mindful of concurrency
    /// nuances
    comptime runInBackground_: fn (*Ctx) void,
    /// Function that is called on the main thread, once the event loop
    /// processes that the task is done
    comptime runFromMainThread_: fn (*Ctx) void,
    comptime debug: bun.Output.LogFunction,
) type {
    return struct {
        task: BackgroundTask = .{ .callback = &runInBackground },
        scheduler: Interpreter.Scheduler,
        main_task: Interpreter.Scheduler.Task = .{},
        // This is a poll because we want it to enter the uSockets loop
        ref: bun.Async.KeepAlive = .{},

        pub fn init(scheduler: Interpreter.Scheduler) @This() {
            return .{ .scheduler = scheduler };
        }

        pub fn schedule(this: *@This()) void {
            debug("schedule", .{});

            this.scheduler.ref(&this.ref);
            BackgroundWork.schedule(this.scheduler.backgroundTasks(), &this.task) catch |err| {
                const ctx: *Ctx = @fieldParentPtr("task", this);
                ctx.onScheduleError(err);
                this.onFinish();
            };
        }

        pub fn onFinish(this: *@This()) void {
            debug("onFinish", .{});
            this.scheduler.enqueue(&this.main_task, this);
        }

        pub fn runInBackground(task: *BackgroundTask) void {
            debug("runInBackground", .{});
            var this: *@This() = @fieldParentPtr("task", task);
            const ctx: *Ctx = @fieldParentPtr("task", this);
            runInBackground_(ctx);
            this.onFinish();
        }

        pub fn runFromMainThread(this: *@This()) void {
            debug("runFromJS", .{});
            const ctx: *Ctx = @fieldParentPtr("task", this);
            this.scheduler.unref(&this.ref);
            runFromMainThread_(ctx);
        }

        pub fn runFromMainThreadMini(this: *@This(), _: *void) void {
            this.runFromMainThread();
        }
    };
}

pub const IOWriterChildPtr = Interpreter.IOWriter.ChildPtr;

/// Shell modifications for syscalls, mostly to make windows work:
/// - Any function that returns a file descriptor will return a uv file descriptor
/// - Sometimes windows doesn't have `*at()` functions like `rmdirat` so we have to join the directory path with the target path
/// - Converts Posix absolute paths to Windows absolute paths on Windows
pub const ShellSyscall = struct {
    pub const unlinkatWithFlags = Syscall.unlinkatWithFlags;
    pub const rmdirat = Syscall.rmdirat;
    pub fn getPath(dirfd: anytype, to: [:0]const u8, buf: *bun.PathBuffer) Maybe([:0]const u8) {
        if (bun.Environment.isPosix) @compileError("Don't use this");
        if (bun.strings.eqlComptime(to[0..to.len], "/dev/null")) {
            return .{ .result = shell.WINDOWS_DEV_NULL };
        }
        if (ResolvePath.Platform.posix.isAbsolute(to[0..to.len])) {
            const dirpath = brk: {
                if (@TypeOf(dirfd) == bun.FD) break :brk switch (Syscall.getFdPath(dirfd, buf)) {
                    .result => |path| path,
                    .err => |e| return .{ .err = e.withFd(dirfd) },
                };
                break :brk dirfd;
            };
            const source_root = std.fs.path.parsePathWindows(u8, dirpath).root;
            std.mem.copyForwards(u8, buf[0..source_root.len], source_root);
            @memcpy(buf[source_root.len..][0 .. to.len - 1], to[1..]);
            buf[source_root.len + to.len - 1] = 0;
            return .{ .result = buf[0 .. source_root.len + to.len - 1 :0] };
        }
        if (ResolvePath.Platform.isAbsolute(.windows, to[0..to.len])) return .{ .result = to };

        var dirpath_buf: bun.PathBuffer = undefined;
        const dirpath = brk: {
            if (@TypeOf(dirfd) == bun.FD) break :brk switch (Syscall.getFdPath(dirfd, &dirpath_buf)) {
                .result => |path| path,
                .err => |e| return .{ .err = e.withFd(dirfd) },
            };
            break :brk dirfd;
        };

        const parts: []const []const u8 = &.{
            dirpath[0..dirpath.len],
            to[0..to.len],
        };
        const joined = std.mem.printSentinel(buf, "{f}", .{std.fs.path.fmtJoin(parts)}, 0) catch
            return .{ .err = Syscall.Error.fromCode(.NAMETOOLONG, .open) };
        return .{ .result = joined };
    }

    pub fn statat(dir: bun.FD, path_: [:0]const u8) Maybe(bun.Stat) {
        if (bun.Environment.isWindows) {
            const buf: *bun.PathBuffer = bun.path_buffer_pool.get();
            defer bun.path_buffer_pool.put(buf);
            const path = switch (getPath(dir, path_, buf)) {
                .err => |e| return .{ .err = e },
                .result => |p| p,
            };

            return switch (Syscall.stat(path)) {
                .err => |e| .{ .err = e.withPath(path_) },
                .result => |s| .{ .result = s },
            };
        }

        return Syscall.fstatat(dir, path_);
    }

    /// Same thing as bun.sys.openat on posix
    /// On windows it will convert paths for us
    pub fn openat(dir: bun.FD, path: [:0]const u8, flags: i32, perm: bun.Mode) Maybe(bun.FD) {
        if (bun.Environment.isWindows) {
            if (flags & bun.O.DIRECTORY != 0) {
                if (ResolvePath.Platform.posix.isAbsolute(path[0..path.len])) {
                    const buf: *bun.PathBuffer = bun.path_buffer_pool.get();
                    defer bun.path_buffer_pool.put(buf);
                    const p = switch (getPath(dir, path, buf)) {
                        .result => |p| p,
                        .err => |e| return .{ .err = e },
                    };
                    return switch (Syscall.openDirAtWindowsA(dir, p, .{ .iterable = true, .no_follow = flags & bun.O.NOFOLLOW != 0 })) {
                        .result => |fd| fd.makeLibUVOwnedForSyscall(.open, .close_on_fail),
                        .err => |e| .{ .err = e.withPath(path) },
                    };
                }
                return switch (Syscall.openDirAtWindowsA(dir, path, .{ .iterable = true, .no_follow = flags & bun.O.NOFOLLOW != 0 })) {
                    .result => |fd| fd.makeLibUVOwnedForSyscall(.open, .close_on_fail),
                    .err => |e| .{ .err = e.withPath(path) },
                };
            }

            const buf: *bun.PathBuffer = bun.path_buffer_pool.get();
            defer bun.path_buffer_pool.put(buf);
            const p = switch (getPath(dir, path, buf)) {
                .result => |p| p,
                .err => |e| return .{ .err = e },
            };
            return bun.sys.open(p, flags, perm);
        }

        const fd = switch (Syscall.openat(dir, path, flags, perm)) {
            .result => |fd| fd,
            .err => |e| return .{ .err = e.withPath(path) },
        };
        if (bun.Environment.isWindows) {
            return fd.makeLibUVOwnedForSyscall(.open, .close_on_fail);
        }
        return .{ .result = fd };
    }

    pub fn open(file_path: [:0]const u8, flags: bun.Mode, perm: bun.Mode) Maybe(bun.FD) {
        const fd = switch (Syscall.open(file_path, flags, perm)) {
            .result => |fd| fd,
            .err => |e| return .{ .err = e },
        };
        if (bun.Environment.isWindows) {
            return fd.makeLibUVOwnedForSyscall(.open, .close_on_fail);
        }
        return .{ .result = fd };
    }

    pub fn dup(fd: bun.FD) Maybe(bun.FD) {
        if (bun.Environment.isWindows) {
            return switch (Syscall.dup(fd)) {
                .result => |duped_fd| duped_fd.makeLibUVOwnedForSyscall(.dup, .close_on_fail),
                .err => |e| .{ .err = e },
            };
        }
        return Syscall.dup(fd);
    }
};

/// A task that can write to stdout and/or stderr
pub fn OutputTask(
    comptime Parent: type,
    comptime Callbacks: type,
) type {
    return struct {
        parent: *Parent,
        output: OutputSrc,
        state: enum {
            waiting_write_err,
            waiting_write_out,
            done,
        },

        pub fn deinit(this: *@This()) Yield {
            if (comptime bun.Environment.allow_assert) assert(this.state == .done);
            log("OutputTask({s}, 0x{x}) deinit", .{ @typeName(Parent), @intFromPtr(this) });
            defer bun.destroy(this);
            defer this.output.deinit();
            return Callbacks.onDone(this.parent);
        }

        pub fn start(this: *@This(), errbuf: ?[]const u8) Yield {
            log("OutputTask({s}, 0x{x}) start errbuf={s}", .{ @typeName(Parent), @intFromPtr(this), if (errbuf) |err| err[0..@min(128, err.len)] else "null" });
            this.state = .waiting_write_err;
            if (errbuf) |err| {
                if (Callbacks.writeErr(this.parent, this, err)) |yield| return yield;
                return this.next();
            }
            this.state = .waiting_write_out;
            if (Callbacks.writeOut(this.parent, this, &this.output)) |yield| return yield;
            Callbacks.onWriteOut(this.parent);
            this.state = .done;
            return this.deinit();
        }

        pub fn next(this: *@This()) Yield {
            switch (this.state) {
                .waiting_write_err => {
                    Callbacks.onWriteErr(this.parent);
                    this.state = .waiting_write_out;
                    if (Callbacks.writeOut(this.parent, this, &this.output)) |yield| return yield;
                    Callbacks.onWriteOut(this.parent);
                    this.state = .done;
                    return this.deinit();
                },
                .waiting_write_out => {
                    Callbacks.onWriteOut(this.parent);
                    this.state = .done;
                    return this.deinit();
                },
                .done => @panic("Invalid state"),
            }
        }

        pub fn onIOWriterChunk(this: *@This(), _: usize, err: ?bun.sys.SystemError) Yield {
            log("OutputTask({s}, 0x{x}) onIOWriterChunk", .{ @typeName(Parent), @intFromPtr(this) });
            if (err) |e| {
                e.deref();
            }

            switch (this.state) {
                .waiting_write_err => {
                    Callbacks.onWriteErr(this.parent);
                    this.state = .waiting_write_out;
                    if (Callbacks.writeOut(this.parent, this, &this.output)) |yield| return yield;
                    Callbacks.onWriteOut(this.parent);
                    this.state = .done;
                    return this.deinit();
                },
                .waiting_write_out => {
                    Callbacks.onWriteOut(this.parent);
                    this.state = .done;
                    return this.deinit();
                },
                .done => @panic("Invalid state"),
            }
        }
    };
}

/// All owned memory is assumed to be allocated with `bun.default_allocator`
pub const OutputSrc = union(enum) {
    arrlist: std.ArrayListUnmanaged(u8),
    owned_buf: []const u8,
    borrowed_buf: []const u8,

    pub fn slice(this: *OutputSrc) []const u8 {
        return switch (this.*) {
            .arrlist => this.arrlist.items[0..],
            .owned_buf => this.owned_buf,
            .borrowed_buf => this.borrowed_buf,
        };
    }

    pub fn deinit(this: *OutputSrc) void {
        switch (this.*) {
            .arrlist => {
                this.arrlist.deinit(bun.default_allocator);
            },
            .owned_buf => {
                bun.default_allocator.free(this.owned_buf);
            },
            .borrowed_buf => {},
        }
    }
};

/// Custom parse error for invalid options
pub const ParseError = union(enum) {
    illegal_option: []const u8,
    unsupported: []const u8,
    show_usage,
};
pub fn unsupportedFlag(comptime name: []const u8) []const u8 {
    return "unsupported option, please open a GitHub issue -- " ++ name ++ "\n";
}
pub const ParseFlagResult = union(enum) { continue_parsing, done, illegal_option: []const u8, unsupported: []const u8, show_usage };
pub fn FlagParser(comptime Opts: type) type {
    return struct {
        pub const Result = @import("../bun_core/result.zig").Result;

        pub fn parseFlags(opts: Opts, args: []const [*:0]const u8) Result(?[]const [*:0]const u8, ParseError) {
            var idx: usize = 0;
            if (args.len == 0) {
                return .{ .ok = null };
            }

            while (idx < args.len) : (idx += 1) {
                const flag = args[idx];
                switch (parseFlag(opts, flag[0..std.mem.len(flag)])) {
                    .done => {
                        const filepath_args = args[idx..];
                        return .{ .ok = filepath_args };
                    },
                    .continue_parsing => {},
                    .illegal_option => |opt_str| return .{ .err = .{ .illegal_option = opt_str } },
                    .unsupported => |unsp| return .{ .err = .{ .unsupported = unsp } },
                    .show_usage => return .{ .err = .show_usage },
                }
            }

            return .{ .err = .show_usage };
        }

        pub fn parseFlag(opts: Opts, flag: []const u8) ParseFlagResult {
            if (flag.len == 0) return .done;
            if (flag[0] != '-') return .done;

            if (flag.len == 1) return .{ .illegal_option = "-" };

            if (flag.len > 2 and flag[1] == '-') {
                if (opts.parseLong(flag)) |result| return result;
            }

            const small_flags = flag[1..];
            for (small_flags, 0..) |char, i| {
                if (opts.parseShort(char, small_flags, i)) |err| {
                    return err;
                }
            }

            return .continue_parsing;
        }
    };
}

pub fn unreachableState(context: []const u8, state: []const u8) noreturn {
    @branchHint(.cold);
    return bun.Output.panic("Bun shell has reached an unreachable state \"{s}\" in the {s} context. This indicates a bug, please open a GitHub issue.", .{ state, context });
}

const builtin = @import("builtin");

const bun = @import("bun");
const ResolvePath = bun.path;
const TaggedPointerUnion = bun.TaggedPointerUnion;
const assert = bun.assert;
const which = bun.which;
const Maybe = bun.sys.Maybe;

const ShellValue = @import("./ShellValue.zig");

const shell = bun.shell;
const Yield = shell.Yield;
const ast = shell.AST;

const windows = bun.windows;
const uv = windows.libuv;

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
