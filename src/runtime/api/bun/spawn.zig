const SpawnActions = struct {
    cwd: ?[:0]u8 = null,
    actions: std.ArrayListUnmanaged(c.BunSpawnAction) = .empty,

    pub fn init() !SpawnActions {
        return .{};
    }

    pub fn deinit(self: *SpawnActions) void {
        if (self.cwd) |cwd| bun.default_allocator.free(cwd);
        for (self.actions.items) |action| {
            if (action.kind == c.BUN_SPAWN_OPEN) {
                const path: [*:0]const u8 = @ptrCast(action.path);
                bun.default_allocator.free(bun.span(path));
            }
        }
        self.actions.deinit(bun.default_allocator);
        self.* = undefined;
    }

    pub fn open(self: *SpawnActions, fd: bun.FD, path: []const u8, flags: u32, mode: i32) !void {
        const posix_path = try std.posix.toPosixPath(path);
        return self.openZ(fd, &posix_path, flags, mode);
    }

    pub fn openZ(self: *SpawnActions, fd: bun.FD, path: [*:0]const u8, flags: u32, mode: i32) !void {
        const owned_path = try bun.default_allocator.dupeSentinel(u8, bun.span(path), 0);
        errdefer bun.default_allocator.free(owned_path);
        try self.actions.append(bun.default_allocator, .{
            .kind = c.BUN_SPAWN_OPEN,
            .path = owned_path.ptr,
            .flags = @bitCast(flags),
            .mode = @intCast(mode),
            .fds = .{ fd.native(), 0 },
        });
    }

    pub fn close(self: *SpawnActions, fd: bun.FD) !void {
        try self.actions.append(bun.default_allocator, .{
            .kind = c.BUN_SPAWN_CLOSE,
            .fds = .{ fd.native(), 0 },
        });
    }

    pub fn dup2(self: *SpawnActions, fd: bun.FD, newfd: bun.FD) !void {
        try self.actions.append(bun.default_allocator, .{
            .kind = c.BUN_SPAWN_DUP2,
            .fds = .{ fd.native(), newfd.native() },
        });
    }

    pub fn inherit(self: *SpawnActions, fd: bun.FD) !void {
        try self.dup2(fd, fd);
    }

    pub fn chdir(self: *SpawnActions, path: []const u8) !void {
        const posix_path = try std.posix.toPosixPath(path);
        const replacement = try bun.default_allocator.dupeSentinel(u8, std.mem.sliceTo(&posix_path, 0), 0);
        if (self.cwd) |cwd| bun.default_allocator.free(cwd);
        self.cwd = replacement;
    }
};

const SpawnAttributes = struct {
    detached: bool = false,
    new_process_group: bool = false,
    pty_slave_fd: i32 = -1,
    flags: u16 = 0,
    reset_signals: bool = false,
    linux_pdeathsig: i32 = 0,

    pub fn init() !SpawnAttributes {
        return .{};
    }

    pub fn deinit(_: *SpawnAttributes) void {}

    pub fn get(self: SpawnAttributes) !u16 {
        return self.flags;
    }

    pub fn set(self: *SpawnAttributes, flags: u16) !void {
        self.flags = flags;
        if (comptime @hasDecl(bun.c, "POSIX_SPAWN_SETSID")) {
            self.detached = (flags & bun.c.POSIX_SPAWN_SETSID) != 0;
        }
    }

    pub fn resetSignals(self: *SpawnAttributes) !void {
        self.reset_signals = true;
    }
};

pub const PosixSpawn = struct {
    pub const Actions = SpawnActions;
    pub const Attr = SpawnAttributes;

    pub const WaitPidResult = struct {
        pid: pid_t,
        status: u32,
    };

    pub fn spawnZ(
        path: [*:0]const u8,
        actions: ?Actions,
        attr: ?Attr,
        argv: [*:null]?[*:0]const u8,
        envp: [*:null]?[*:0]const u8,
    ) Maybe(pid_t) {
        const attributes = attr orelse Attr{};
        const action_items: []const c.BunSpawnAction = if (actions) |a| a.actions.items else &.{};
        const request: c.BunSpawnRequest = .{
            .cwd = if (actions) |a| if (a.cwd) |cwd| cwd.ptr else null else null,
            .actions = if (action_items.len > 0) action_items.ptr else null,
            .actions_len = action_items.len,
            .pty_slave_fd = attributes.pty_slave_fd,
            .linux_pdeathsig = attributes.linux_pdeathsig,
            .flags = attributes.flags,
            .detached = @intFromBool(attributes.detached),
            .new_process_group = @intFromBool(attributes.new_process_group),
            .reset_signals = @intFromBool(attributes.reset_signals),
        };
        var pid: i32 = 0;
        const result = c.bun_spawn(&pid, path, &request, @ptrCast(argv), @ptrCast(envp));
        if (comptime bun.Environment.allow_assert) {
            bun.sys.syslog("bun_spawn({s}) = {d} ({d})", .{ bun.span(path), result, pid });
        }
        if (result == 0) return .{ .result = pid };
        return .{ .err = .{
            .errno = @intCast(result),
            .syscall = .posix_spawn,
            .path = bun.span(path),
        } };
    }

    pub fn waitpid(pid: pid_t, flags: u32) Maybe(WaitPidResult) {
        var status: c_int = 0;
        while (true) {
            const rc = system.waitpid(pid, &status, @as(c_int, @intCast(flags)));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return .{ .result = .{
                    .pid = @intCast(rc),
                    .status = @bitCast(status),
                } },
                .INTR => continue,
                else => return bun.sys.Maybe(WaitPidResult).errnoSys(rc, .waitpid).?,
            }
        }
    }

    pub fn wait4(pid: pid_t, flags: u32, usage: ?*process.Rusage) Maybe(WaitPidResult) {
        var status: c_int = 0;
        while (true) {
            const rc = system.wait4(pid, &status, @as(c_int, @intCast(flags)), @ptrCast(usage));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return .{ .result = .{
                    .pid = @intCast(rc),
                    .status = @bitCast(status),
                } },
                .INTR => continue,
                else => return bun.sys.Maybe(WaitPidResult).errnoSys(rc, .waitpid).?,
            }
        }
    }

    pub const process = @import("./process.zig");
    pub const Process = process.Process;
    pub const SpawnOptions = process.SpawnOptions;
    pub const Status = process.Status;
    pub const sync = process.sync;
    pub const spawnProcess = process.spawnProcess;
    pub const WindowsSpawnResult = process.WindowsSpawnResult;
    pub const PosixSpawnResult = process.PosixSpawnResult;
    pub const SpawnProcessResult = process.SpawnProcessResult;
    pub const WindowsSpawnOptions = process.WindowsSpawnOptions;
    pub const Rusage = process.Rusage;
};

const std = @import("std");
const bun = @import("bun");
const c = @import("libc-spawn");
const Maybe = bun.sys.Maybe;
const pid_t = std.posix.pid_t;
const system = std.posix.system;
