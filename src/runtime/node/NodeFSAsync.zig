pub const Runtime = struct {
    background_tasks: *bun.BackgroundTaskGroup,
    io: ?std.Io,
};

pub fn functionNeedsIo(comptime function: anytype, comptime asynchronous: bool) bool {
    return switch (function) {
        .copyFile, .cp, .rm => true,
        .readdir => asynchronous,
        else => false,
    };
}

pub fn requiresNodeFSForSchedule(comptime function: anytype) bool {
    if (!Environment.isWindows) return false;
    return switch (function) {
        .open, .close, .read, .write, .readv, .writev, .statfs => true,
        else => false,
    };
}

pub fn Work(
    comptime FS: type,
    comptime ReturnType: type,
    comptime ArgumentType: type,
    comptime function: std.meta.DeclEnum(FS.NodeFS),
    comptime Owner: type,
    comptime field_name: []const u8,
) type {
    if (!Environment.isWindows) {
        return BackgroundWork(FS, ReturnType, ArgumentType, function, Owner, field_name);
    }

    return switch (function) {
        .open, .close, .read, .write, .readv, .writev, .statfs => UVWork(FS, ReturnType, ArgumentType, function, Owner, field_name),
        else => BackgroundWork(FS, ReturnType, ArgumentType, function, Owner, field_name),
    };
}

fn Result(comptime T: type) type {
    return union(enum) {
        result: T,
        err: bun.bindgen.SystemError,
        out_of_memory,

        fn fromSys(value: bun.sys.Maybe(T)) @This() {
            return switch (value) {
                .result => |result| .{ .result = result },
                .err => |err| .{ .err = bun.bindgen.SystemError.fromSysError(err) catch return .out_of_memory },
            };
        }
    };
}

fn BackgroundWork(
    comptime FS: type,
    comptime ReturnType: type,
    comptime ArgumentType: type,
    comptime function_name: std.meta.DeclEnum(FS.NodeFS),
    comptime Owner: type,
    comptime field_name: []const u8,
) type {
    const function = switch (function_name) {
        .read, .readv, .writev => ArgumentType.execute,
        else => @field(FS.NodeFS, @tagName(function_name)),
    };
    return struct {
        args: ArgumentType,
        io: ?std.Io,
        result: Result(ReturnType) = undefined,
        has_result: bool = false,
        task: bun.BackgroundTaskGroup.Task = .{ .callback = run, .on_cancel = cancel },

        const Self = @This();

        pub fn init(args: ArgumentType, io: ?std.Io) Self {
            return .{ .args = args, .io = io };
        }

        pub fn schedule(work: *Self, group: *bun.BackgroundTaskGroup, _: *FS.NodeFS) bun.OOM!void {
            try work.args.toThreadSafe();
            bun.BackgroundWork.schedule(group, &work.task) catch {
                work.result = .fromSys(.{ .err = bun.sys.Error.fromCode(.AGAIN, .TODO) });
                work.has_result = true;
                owner(work).finish();
            };
        }

        pub fn deinit(work: *Self, result_consumed: bool) void {
            if (work.has_result) switch (work.result) {
                .err => |*err| if (!result_consumed) err.deinit(),
                .result => |*result| if (!result_consumed) FS.deinitSuccess(result),
                .out_of_memory => {},
            };
            work.args.deinit();
        }

        fn owner(work: *Self) *Owner {
            return @alignCast(@fieldParentPtr(field_name, work));
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const work: *Self = @alignCast(@fieldParentPtr("task", task));
            var node_fs = FS.NodeFS{ .runtime_io = work.io };
            work.result = .fromSys(function(&node_fs, work.args, .async));
            work.has_result = true;
            owner(work).finish();
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const work: *Self = @alignCast(@fieldParentPtr("task", task));
            owner(work).cancel();
        }
    };
}

fn UVWork(
    comptime FS: type,
    comptime ReturnType: type,
    comptime ArgumentType: type,
    comptime function_name: std.meta.DeclEnum(FS.NodeFS),
    comptime Owner: type,
    comptime field_name: []const u8,
) type {
    return struct {
        args: ArgumentType,
        req: uv.fs_t = std.mem.zeroes(uv.fs_t),
        result: Result(ReturnType) = undefined,
        has_result: bool = false,

        const Self = @This();

        pub fn init(args: ArgumentType, _: ?std.Io) Self {
            return .{ .args = args };
        }

        pub fn schedule(work: *Self, _: *bun.BackgroundTaskGroup, node_fs: *FS.NodeFS) bun.OOM!void {
            try work.args.toThreadSafe();
            const log = bun.sys.syslog;
            const loop = uv.Loop.get();
            work.req.data = work;
            switch (comptime function_name) {
                .open => {
                    const args: FS.Arguments.Open = work.args;
                    const path = if (bun.strings.eqlComptime(args.path.slice(), "/dev/null")) "\\\\.\\NUL" else args.path.sliceZ(&node_fs.sync_error_buf);
                    var flags: c_int = @backingInt(args.flags);
                    flags = uv.O.fromBunO(flags);
                    var mode: c_int = @intCast(args.mode);
                    if (mode == 0) mode = 0o644;
                    const rc = uv.uv_fs_open(loop, &work.req, path.ptr, flags, mode, &callback);
                    log("uv open({s}, {d}, {d}) = scheduled", .{ path, flags, mode });
                    work.handleScheduleResult(node_fs, rc, false);
                },
                .close => {
                    const fd = work.args.fd.uv();
                    if (fd == 1 or fd == 2) {
                        log("uv close({}) SKIPPED", .{fd});
                        work.result = .{ .result = std.mem.zeroes(ReturnType) };
                        work.has_result = true;
                        owner(work).finish();
                        return;
                    }
                    const rc = uv.uv_fs_close(loop, &work.req, fd, &callback);
                    log("uv close({d}) = scheduled", .{fd});
                    work.handleScheduleResult(node_fs, rc, false);
                },
                .read => {
                    const args = work.args;
                    const bytes = args.bytes();
                    const rc = uv.uv_fs_read(loop, &work.req, args.fd.uv(), &.{uv.uv_buf_t.init(bytes)}, 1, args.position orelse -1, &callback);
                    log("uv read({d}) = scheduled", .{args.fd.uv()});
                    work.handleScheduleResult(node_fs, rc, false);
                },
                .write => {
                    const args: FS.Arguments.Write = work.args;
                    var bytes = args.buffer.slice();
                    bytes = bytes[@min(bytes.len, args.offset)..];
                    bytes = bytes[0..@min(bytes.len, args.length)];
                    const rc = uv.uv_fs_write(loop, &work.req, args.fd.uv(), &.{uv.uv_buf_t.init(bytes)}, 1, args.position orelse -1, &callback);
                    log("uv write({d}) = scheduled", .{args.fd.uv()});
                    work.handleScheduleResult(node_fs, rc, false);
                },
                .readv, .writev => {
                    const args = work.args;
                    const bufs = args.iovecs;
                    if (function_name == .writev and bufs.len == 0) {
                        work.result = .{ .result = std.mem.zeroes(ReturnType) };
                        work.has_result = true;
                        owner(work).finish();
                        return;
                    }
                    const position: i64 = args.position orelse -1;
                    const total = args.storage.len;
                    const rc = if (function_name == .readv)
                        uv.uv_fs_read(loop, &work.req, args.fd.uv(), bufs.ptr, @intCast(bufs.len), position, &callback)
                    else
                        uv.uv_fs_write(loop, &work.req, args.fd.uv(), bufs.ptr, @intCast(bufs.len), position, &callback);
                    log("uv {s}({d}, {*}, {d}, {d}, {d} total bytes) = scheduled", .{ @tagName(function_name), args.fd.uv(), bufs.ptr, bufs.len, position, total });
                    work.handleScheduleResult(node_fs, rc, false);
                },
                .statfs => {
                    const path = work.args.path.sliceZ(&node_fs.sync_error_buf);
                    const rc = uv.uv_fs_statfs(loop, &work.req, path.ptr, &callbackWithRequest);
                    log("uv statfs({s}) = scheduled", .{path});
                    work.handleScheduleResult(node_fs, rc, true);
                },
                else => comptime unreachable,
            }
        }

        pub fn deinit(work: *Self, result_consumed: bool) void {
            if (work.has_result) switch (work.result) {
                .err => |*err| if (!result_consumed) err.deinit(),
                .result => |*result| if (!result_consumed) FS.deinitSuccess(result),
                .out_of_memory => {},
            };
            work.args.deinit();
        }

        fn owner(work: *Self) *Owner {
            return @alignCast(@fieldParentPtr(field_name, work));
        }

        fn callback(req: *uv.fs_t) callconv(.c) void {
            const work: *Self = @ptrCast(@alignCast(req.data.?));
            var node_fs = FS.NodeFS{};
            work.result = .fromSys(@field(FS.NodeFS, "uv_" ++ @tagName(function_name))(&node_fs, work.args, @backingInt(req.result)));
            uv.uv_fs_req_cleanup(req);
            work.finishCallback();
        }

        fn callbackWithRequest(req: *uv.fs_t) callconv(.c) void {
            const work: *Self = @ptrCast(@alignCast(req.data.?));
            var node_fs = FS.NodeFS{};
            work.result = .fromSys(@field(FS.NodeFS, "uv_" ++ @tagName(function_name))(&node_fs, work.args, req, @backingInt(req.result)));
            uv.uv_fs_req_cleanup(req);
            work.finishCallback();
        }

        fn finishCallback(work: *Self) void {
            work.has_result = true;
            owner(work).finish();
        }

        fn handleScheduleResult(
            work: *Self,
            node_fs: *FS.NodeFS,
            rc: uv.ReturnCode,
            comptime callback_uses_request: bool,
        ) void {
            if (rc == .zero) return;
            work.result = .fromSys(if (callback_uses_request)
                @field(FS.NodeFS, "uv_" ++ @tagName(function_name))(node_fs, work.args, &work.req, rc.int())
            else
                @field(FS.NodeFS, "uv_" ++ @tagName(function_name))(node_fs, work.args, rc.int()));
            work.req.deinit();
            work.finishCallback();
        }
    };
}

const bun = @import("bun");
const Environment = bun.Environment;
const std = @import("std");
const uv = bun.windows.libuv;
