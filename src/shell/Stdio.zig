pub const Stdio = union(enum) {
    inherit,
    capture: struct { buf: *bun.ByteList },
    ignore,
    fd: bun.FD,
    dup2: struct {
        out: StdioKind,
        to: StdioKind,
    },
    blob: bun.webcore.Blob.Any,
    leased_bytes: bun.bindgen.OwnedMutableLease(u8),
    retained_bytes: bun.bindgen.OwnedLease(u8),
    memfd: bun.FD,
    pipe,
    ipc,

    pub const ToSpawnOptsError = enum {
        stdin_used_as_out,
        out_used_as_stdin,
        blob_used_as_out,

        pub fn toStr(this: ToSpawnOptsError) []const u8 {
            return switch (this) {
                .stdin_used_as_out => "Stdin cannot be used for stdout or stderr",
                .out_used_as_stdin => "Stdout and stderr cannot be used for stdin",
                .blob_used_as_out => "Blobs are immutable, and cannot be used for stdout/stderr",
            };
        }
    };

    const SpawnOptionResult = union(enum) {
        result: bun.spawn.SpawnOptions.Stdio,
        err: ToSpawnOptsError,
    };

    pub fn deinit(this: *Stdio) void {
        switch (this.*) {
            .leased_bytes => |*bytes| bytes.deinit(),
            .retained_bytes => |*bytes| bytes.deinit(),
            .blob => |*blob| blob.detach(),
            .memfd => |fd| _ = fd.closeAllowingStandardIo(null),
            else => {},
        }
        this.* = .ignore;
    }

    pub fn buffersInput(this: Stdio) bool {
        return switch (this) {
            .leased_bytes, .retained_bytes, .blob => true,
            else => false,
        };
    }

    pub fn buffersOutput(this: Stdio) bool {
        return switch (this) {
            .capture, .leased_bytes, .retained_bytes, .blob, .pipe => true,
            .ipc => Environment.isWindows,
            else => false,
        };
    }

    pub fn asSpawnOption(this: *Stdio, index: i32) SpawnOptionResult {
        return if (comptime Environment.isWindows)
            this.toWindows(index)
        else
            this.toPosix(index);
    }

    fn toPosix(this: *Stdio, index: i32) SpawnOptionResult {
        return .{ .result = switch (this.*) {
            .blob => |blob| result: {
                const fd = bun.FD.Stdio.fromInt(index).?.fd();
                if (blob.needsToReadFile()) {
                    if (blob.store()) |store| {
                        if (store.data.file.pathlike == .fd) {
                            const source_fd = store.data.file.pathlike.fd;
                            if (source_fd == fd) break :result .inherit;
                            if (source_fd.stdioTag()) |tag| switch (tag) {
                                .std_in => if (index == 1 or index == 2) return .{ .err = .stdin_used_as_out },
                                .std_out, .std_err => if (index == 0) return .{ .err = .out_used_as_stdin },
                            };
                            break :result .{ .pipe = source_fd };
                        }
                        break :result .{ .path = store.data.file.pathlike.path.slice() };
                    }
                }
                if (index == 1 or index == 2) return .{ .err = .blob_used_as_out };
                break :result .buffer;
            },
            .dup2 => |dup2| .{ .dup2 = .{ .out = dup2.out, .to = dup2.to } },
            .capture, .leased_bytes, .retained_bytes => .buffer,
            .pipe => if (index == 0) .ignore else .buffer,
            .ipc => .ipc,
            .fd => |fd| .{ .pipe = fd },
            .memfd => |fd| .{ .pipe = fd },
            .inherit => .inherit,
            .ignore => .ignore,
        } };
    }

    fn toWindows(this: *Stdio, index: i32) SpawnOptionResult {
        return .{ .result = switch (this.*) {
            .blob => |blob| result: {
                const fd = bun.FD.Stdio.fromInt(index).?.fd();
                if (blob.needsToReadFile()) {
                    if (blob.store()) |store| {
                        if (store.data.file.pathlike == .fd) {
                            const source_fd = store.data.file.pathlike.fd;
                            if (source_fd == fd) break :result .inherit;
                            if (source_fd.stdioTag()) |tag| switch (tag) {
                                .std_in => if (index == 1 or index == 2) return .{ .err = .stdin_used_as_out },
                                .std_out, .std_err => if (index == 0) return .{ .err = .out_used_as_stdin },
                            };
                            break :result .{ .pipe = source_fd };
                        }
                        break :result .{ .path = store.data.file.pathlike.path.slice() };
                    }
                }
                if (index == 1 or index == 2) return .{ .err = .blob_used_as_out };
                break :result .{ .buffer = createPipe() };
            },
            .capture, .leased_bytes, .retained_bytes => .{ .buffer = createPipe() },
            .pipe => if (index == 0) .ignore else .{ .buffer = createPipe() },
            .ipc => .{ .ipc = createPipe() },
            .fd => |fd| .{ .pipe = fd },
            .dup2 => |dup2| .{ .dup2 = .{ .out = dup2.out, .to = dup2.to } },
            .inherit => .inherit,
            .ignore => .ignore,
            .memfd => unreachable,
        } };
    }

    pub fn assignBlob(this: *Stdio, source: bun.webcore.Blob.Any, index: i32) ?ToSpawnOptsError {
        var blob = source;
        const fd = bun.FD.Stdio.fromInt(index).?.fd();
        if (blob.needsToReadFile()) {
            if (blob.store()) |store| {
                if (store.data.file.pathlike == .fd and store.data.file.pathlike.fd != fd) {
                    if (store.data.file.pathlike.fd.stdioTag()) |tag| switch (tag) {
                        .std_in => if (index == 1 or index == 2) {
                            blob.detach();
                            return .stdin_used_as_out;
                        },
                        .std_out, .std_err => if (index == 0) {
                            blob.detach();
                            return .out_used_as_stdin;
                        },
                    };
                }
                this.* = .{ .blob = blob };
                return null;
            }
        }
        if (index == 1 or index == 2) {
            blob.detach();
            return .blob_used_as_out;
        }
        if (blob.fastSize() == 0) {
            blob.detach();
            this.* = .ignore;
            return null;
        }
        this.* = .{ .blob = blob };
        return null;
    }
};

pub const Source = union(enum) {
    blob: bun.webcore.Blob.Any,
    leased_bytes: bun.bindgen.OwnedMutableLease(u8),
    retained_bytes: bun.bindgen.OwnedLease(u8),
    detached,

    pub fn memoryCost(this: *const Source) usize {
        return switch (this.*) {
            .blob => this.blob.memoryCost(),
            .retained_bytes, .leased_bytes, .detached => 0,
        };
    }

    pub fn slice(this: *const Source) []const u8 {
        return switch (this.*) {
            .blob => this.blob.slice(),
            .retained_bytes => this.retained_bytes.unsafePtr("StaticPipeWriter owns Source's input lease until releaseInput clears its buffer after I/O finishes, then detaches Source"),
            .leased_bytes, .detached => @panic("source has no direct byte slice"),
        };
    }

    pub fn detach(this: *Source) void {
        switch (this.*) {
            .blob => this.blob.detach(),
            .leased_bytes => this.leased_bytes.deinit(),
            .retained_bytes => this.retained_bytes.deinit(),
            .detached => {},
        }
        this.* = .detached;
    }
};

pub const Result = bun.spawn.process.SpawnProcessResult.StdioResult;

fn createPipe() *uv.Pipe {
    return bun.new(uv.Pipe, std.mem.zeroes(uv.Pipe));
}

const std = @import("std");
const bun = @import("bun");
const Environment = bun.Environment;
const StdioKind = @import("../runtime/api/bun/StdioKind.zig").StdioKind;
const uv = bun.windows.libuv;
