pub fn WithIntegration(comptime Integration: type) type {
    const Stdio = Integration.Stdio;
    return union(enum) {
        const Writable = @This();

        pipe: Integration.SinkHandle,
        fd: bun.FD,
        buffer: Integration.BufferWriterHandle,
        memfd: bun.FD,
        inherit: void,
        ignore: void,

        pub fn memoryCost(this: *const Writable) usize {
            return switch (this.*) {
                .pipe => |pipe| Integration.sinkMemoryCost(pipe),
                .buffer => |buffer| buffer.memoryCost(),
                // TODO: memfd
                else => 0,
            };
        }

        pub fn hasPendingActivity(this: *const Writable) bool {
            return switch (this.*) {
                .pipe => false,

                // we mark them as .ignore when they are closed, so this must be true
                .buffer => true,
                else => false,
            };
        }

        pub fn ref(this: *Writable) void {
            switch (this.*) {
                .pipe => {
                    Integration.updateSinkRef(this.pipe, true);
                },
                .buffer => {
                    this.buffer.updateRef(true);
                },
                else => {},
            }
        }

        pub fn unref(this: *Writable) void {
            switch (this.*) {
                .pipe => {
                    Integration.updateSinkRef(this.pipe, false);
                },
                .buffer => {
                    this.buffer.updateRef(false);
                },
                else => {},
            }
        }

        // When the stream has closed we need to be notified to prevent a use-after-free
        // We can test for this use-after-free by enabling hot module reloading on a file and then saving it twice
        pub fn onClose(this: *Writable, _: ?bun.sys.Error) void {
            const process = Integration.owner(this);

            Integration.clearStdinSinkReference(process);

            const writable = this.*;
            this.* = .{ .ignore = {} };
            switch (writable) {
                .buffer => {
                    writable.buffer.deref();
                },
                .pipe => {
                    Integration.releaseSink(writable.pipe);
                },
                else => {},
            }

            Integration.stdinDestroyed(process);
        }
        pub fn onReady(_: *Writable, _: ?usize, _: ?usize) void {}
        pub fn onStart(_: *Writable) void {}

        pub fn init(
            context: anytype,
            stdio: *Stdio,
            event_loop: Integration.LoopHandle,
            subprocess: Integration.ProcessHandle,
            result: *StdioResult,
            stdin_is_readable_stream: *bool,
        ) bun.bindgen.CallError(@TypeOf(context))!Writable {
            Integration.assertStdioResult(result.*);

            if (Environment.isWindows) {
                switch (stdio.*) {
                    .pipe, .readable_stream => {
                        const pipe = try Integration.createPipe(context, stdio, event_loop, subprocess, result, stdin_is_readable_stream) orelse
                            return .{ .inherit = {} };
                        return .{ .pipe = pipe };
                    },

                    .blob, .retained_bytes => {
                        const writer = try Integration.createBufferWriter(stdio, event_loop, subprocess, result) orelse return .ignore;
                        return .{ .buffer = writer };
                    },
                    .fd => |fd| {
                        return Writable{ .fd = fd };
                    },
                    .dup2 => |dup2| {
                        return Writable{ .fd = dup2.to.toFd() };
                    },
                    .inherit => {
                        return Writable{ .inherit = {} };
                    },
                    .memfd, .ignore => {
                        return Writable{ .ignore = {} };
                    },
                    .ipc, .capture => {
                        return Writable{ .ignore = {} };
                    },
                }
            }

            switch (stdio.*) {
                .dup2 => @panic("TODO dup2 stdio"),
                .pipe, .readable_stream => {
                    const pipe = (try Integration.createPipe(context, stdio, event_loop, subprocess, result, stdin_is_readable_stream)).?;
                    return .{ .pipe = pipe };
                },

                .blob, .retained_bytes => {
                    const writer = try Integration.createBufferWriter(stdio, event_loop, subprocess, result) orelse return .ignore;
                    return .{ .buffer = writer };
                },
                .memfd => |memfd| {
                    bun.assert(memfd != bun.invalid_fd);
                    stdio.* = .ignore;
                    _ = result.take();
                    return Writable{ .memfd = memfd };
                },
                .fd => |fd| {
                    return Writable{ .fd = fd };
                },
                .inherit => {
                    return Writable{ .inherit = {} };
                },
                .ignore => {
                    return Writable{ .ignore = {} };
                },
                .ipc, .capture => {
                    return Writable{ .ignore = {} };
                },
            }
        }

        pub fn toBindingResult(this: *Writable, context: anytype, subprocess: Integration.ProcessHandle) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            if (Integration.stdinIsReadableStream(subprocess)) return .{ .undefined = true };
            return switch (this.*) {
                .fd => |fd| .{ .fd = try this.transferFD(context, fd) },
                .memfd, .ignore, .buffer, .inherit => .{ .undefined = true },
                .pipe => |pipe| {
                    this.* = .{ .ignore = {} };
                    return .{ .sink = try Integration.takeSinkResult(context, subprocess, pipe) };
                },
            };
        }

        fn transferFD(this: *Writable, context: anytype, fd: bun.FD) bun.bindgen.CallError(@TypeOf(context))!i32 {
            return switch (Integration.fdToBindingInt32(fd)) {
                .result => |owned| owned,
                .err => |err| {
                    this.* = .{ .ignore = {} };
                    return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
                },
            };
        }

        pub fn finalize(this: *Writable) void {
            const subprocess = Integration.owner(this);
            Integration.clearStdinSinkReference(subprocess);

            return switch (this.*) {
                .pipe => |pipe| {
                    Integration.finalizeSink(this, pipe);

                    this.* = .{ .ignore = {} };
                },
                .buffer => |buffer| {
                    this.* = .ignore;
                    buffer.detach();
                    buffer.updateRef(false);
                    buffer.close();
                    buffer.deref();
                },
                .memfd => |fd| {
                    _ = fd.closeAllowingStandardIo(null);
                    this.* = .{ .ignore = {} };
                },
                .ignore => {},
                .fd, .inherit => {},
            };
        }

        pub fn close(this: *Writable) void {
            switch (this.*) {
                .pipe => |pipe| {
                    Integration.endSink(pipe);
                },
                .memfd => |fd| {
                    _ = fd.closeAllowingStandardIo(null);
                    this.* = .{ .ignore = {} };
                },
                .fd => {
                    this.* = .{ .ignore = {} };
                },
                .buffer => {
                    this.buffer.close();
                },
                .ignore => {},
                .inherit => {},
            }
        }
    };
}

const bun = @import("bun");
const Environment = bun.Environment;
const BlobSize = @import("../../../webcore/BlobSize.zig").SizeType;
const StdioResult = bun.spawn.process.SpawnProcessResult.StdioResult;
