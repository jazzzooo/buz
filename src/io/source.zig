const log = bun.Output.scoped(.PipeSource, .hidden);

pub const Source = union(enum) {
    pipe: *Pipe,
    tty: *Tty,
    file: *File,
    sync_file: *File,

    const Pipe = uv.Pipe;
    const Tty = uv.uv_tty_t;

    pub const StreamRead = struct {
        const RefCount = bun.ptr.RefCount(@This(), "ref_count", destroy, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        ref_count: RefCount = .init(),
        source: Source,
        parent: ?*anyopaque,
        pending_buffer: []u8 = &.{},
        spare_buffer: []u8 = &.{},

        pub fn create(source: Source, parent: *anyopaque) bun.OOM!*StreamRead {
            bun.assert(source == .pipe or source == .tty);
            const this = try bun.default_allocator.create(StreamRead);
            this.* = .{ .source = source, .parent = parent };
            source.setData(this);
            return this;
        }

        pub fn allocate(this: *StreamRead, suggested_size: usize) bun.OOM![]u8 {
            const length = @min(@max(suggested_size, 1), 64 * 1024);
            if (this.pending_buffer.len == 0) this.pending_buffer = bun.take(&this.spare_buffer);
            if (this.pending_buffer.len < length) {
                const replacement = try bun.default_allocator.alloc(u8, length);
                bun.default_allocator.free(this.pending_buffer);
                this.pending_buffer = replacement;
            }
            return this.pending_buffer;
        }

        pub fn takeBuffer(this: *StreamRead, buffer: *const uv.uv_buf_t) []u8 {
            if (buffer.len == 0) return &.{};
            bun.assert(this.pending_buffer.ptr == buffer.base);
            bun.assert(this.pending_buffer.len == buffer.len);
            return bun.take(&this.pending_buffer);
        }

        pub fn recycle(this: *StreamRead, buffer: []u8) void {
            if (buffer.len > this.spare_buffer.len) {
                bun.default_allocator.free(this.spare_buffer);
                this.spare_buffer = buffer;
            } else {
                bun.default_allocator.free(buffer);
            }
        }

        pub fn detach(this: *StreamRead) void {
            this.parent = null;
            this.source.getHandle().close(onClose);
        }

        pub fn memoryCost(this: *const StreamRead) usize {
            return @sizeOf(StreamRead) + this.pending_buffer.len + this.spare_buffer.len;
        }

        fn onClose(handle: *uv.Handle) callconv(.c) void {
            const this = handle.getData(StreamRead).?;
            this.deref();
        }

        fn destroy(this: *StreamRead) void {
            // A canceled terminal read can suppress delivery of its allocated buffer.
            bun.default_allocator.free(this.pending_buffer);
            bun.default_allocator.free(this.spare_buffer);
            switch (this.source) {
                .pipe => |pipe| bun.default_allocator.destroy(pipe),
                .tty => |tty| bun.default_allocator.destroy(tty),
                else => unreachable,
            }
            bun.default_allocator.destroy(this);
        }
    };

    pub const StreamWrite = struct {
        request: uv.uv_write_t = std.mem.zeroes(uv.uv_write_t),
        iov: uv.uv_buf_t = undefined,
        stream: *uv.uv_stream_t,
        bytes: []u8,
        written: usize = 0,
        parent: ?*anyopaque,
        callback: *const fn (*anyopaque, uv.ReturnCode) void,

        pub fn start(stream: *uv.uv_stream_t, bytes: []const u8, parent: *anyopaque, callback: *const fn (*anyopaque, uv.ReturnCode) void) bun.sys.Maybe(*StreamWrite) {
            bun.assert(bytes.len != 0);
            const this = bun.default_allocator.create(StreamWrite) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
            const snapshot = bun.default_allocator.dupe(u8, bytes) catch {
                bun.default_allocator.destroy(this);
                return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
            };
            this.* = .{ .stream = stream, .bytes = snapshot, .parent = parent, .callback = callback };
            if (this.submit().toError(.write)) |err| {
                this.destroy();
                return .{ .err = err };
            }
            return .{ .result = this };
        }

        pub fn detach(this: *StreamWrite) void {
            this.parent = null;
        }

        fn submit(this: *StreamWrite) uv.ReturnCode {
            const remaining = this.bytes[this.written..];
            this.iov = .init(remaining[0..@min(remaining.len, 1024 * 1024)]);
            return uv.uv_write(&this.request, this.stream, @ptrCast(&this.iov), 1, onWrite);
        }

        fn onWrite(request: *uv.uv_write_t, status: uv.ReturnCode) callconv(.c) void {
            const this: *StreamWrite = @fieldParentPtr("request", request);
            if (this.parent == null) return this.destroy();
            if (status.errEnum() != null) return this.finish(status);
            this.written += this.iov.len;
            if (this.written == this.bytes.len) return this.finish(.zero);
            const result = this.submit();
            if (result.errEnum() != null) this.finish(result);
        }

        fn finish(this: *StreamWrite, status: uv.ReturnCode) void {
            defer this.destroy();
            if (bun.take(&this.parent)) |parent| this.callback(parent, status);
        }

        fn destroy(this: *StreamWrite) void {
            bun.default_allocator.free(this.bytes);
            bun.default_allocator.destroy(this);
        }
    };

    /// Owns the descriptor and request buffers through cancellation and callback delivery.
    pub const File = struct {
        loop: *uv.Loop,
        fs: uv.fs_t = std.mem.zeroes(uv.fs_t),
        iov: uv.uv_buf_t = undefined,
        file: uv.uv_file,
        io_buffer: []u8 = &.{},
        write_length: usize = 0,
        written: usize = 0,
        write_callback: ?*const fn (*uv.fs_t) callconv(.c) void = null,
        cancelled: bool = false,
        state: enum(u8) {
            deinitialized,
            operating,
            canceling,
            delivering,
            closing,
        } = .deinitialized,
        detached: bool = false,

        pub fn fromFS(fs: *uv.fs_t) *File {
            return @fieldParentPtr("fs", fs);
        }

        pub fn canStart(this: *const File) bool {
            return this.state == .deinitialized and !this.detached and this.fs.data != null;
        }

        pub fn prepare(this: *File) void {
            bun.assert(this.canStart());
            this.state = .operating;
            this.cancelled = false;
        }

        pub fn stop(this: *File) void {
            if (this.state != .operating) return;
            this.cancelled = true;
            this.state = .canceling;
            _ = uv.uv_cancel(@ptrCast(&this.fs));
        }

        pub fn detach(this: *File) void {
            this.fs.data = null;
            this.detached = true;
            this.stop();
            if (this.state == .deinitialized) this.startClose();
        }

        pub fn beginDelivery(this: *File) void {
            bun.assert(this.state == .operating or this.state == .canceling);
            this.fs.deinit();
            this.state = .delivering;
        }

        /// A null result ends access to this File; close submission can free it.
        pub fn endDelivery(this: *File) ?*anyopaque {
            bun.assert(this.state == .delivering);
            this.state = .deinitialized;
            if (this.detached) {
                this.startClose();
                return null;
            }
            return this.fs.data;
        }

        pub fn complete(this: *File) void {
            this.beginDelivery();
            _ = this.endDelivery();
        }

        pub fn read(this: *File, offset: i64, callback: *const fn (*uv.fs_t) callconv(.c) void) bun.sys.Maybe(void) {
            bun.assert(this.canStart());
            const buffer = this.ensureBuffer(64 * 1024) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .read) };
            this.iov = .init(buffer);
            this.prepare();
            if (uv.uv_fs_read(this.loop, &this.fs, this.file, @ptrCast(&this.iov), 1, offset, callback).toError(.read)) |err| {
                this.complete();
                return .{ .err = err };
            }
            return .success;
        }

        fn ensureBuffer(this: *File, length: usize) bun.OOM![]u8 {
            if (this.io_buffer.len < length) {
                const replacement = try bun.default_allocator.alloc(u8, length);
                bun.default_allocator.free(this.io_buffer);
                this.io_buffer = replacement;
            }
            return this.io_buffer[0..length];
        }

        pub fn write(this: *File, bytes: []const u8, callback: *const fn (*uv.fs_t) callconv(.c) void) bun.sys.Maybe(void) {
            bun.assert(this.canStart() and bytes.len != 0);
            const buffer = this.ensureBuffer(bytes.len) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .write) };
            @memcpy(buffer, bytes);
            this.write_length = bytes.len;
            this.written = 0;
            this.write_callback = callback;
            this.prepare();
            const result = this.submitWrite();
            if (result.toError(.write)) |err| {
                this.complete();
                return .{ .err = err };
            }
            return .success;
        }

        fn submitWrite(this: *File) uv.ReturnCode {
            const remaining = this.write_length - this.written;
            this.iov = .init(this.io_buffer[this.written..][0..@min(remaining, 1024 * 1024)]);
            return uv.uv_fs_write(this.loop, &this.fs, this.file, @ptrCast(&this.iov), 1, -1, onWrite);
        }

        fn onWrite(fs: *uv.fs_t) callconv(.c) void {
            const this = File.fromFS(fs);
            const callback = this.write_callback.?;
            if (fs.result.errEnum() != null) return callback(fs);
            const amount: usize = @intCast(fs.result.int());
            if (amount == 0) {
                fs.result = .init(uv.UV_EIO);
                return callback(fs);
            }
            bun.assert(amount <= this.iov.len);
            this.written += amount;
            if (this.written == this.write_length) return callback(fs);
            if (this.cancelled or this.detached) {
                fs.result = .init(uv.UV_ECANCELED);
                return callback(fs);
            }
            fs.deinit();
            const result = this.submitWrite();
            if (result.errEnum() != null) {
                fs.result = .init(result.int());
                callback(fs);
            }
        }

        fn startClose(this: *File) void {
            bun.assert(this.state == .deinitialized);
            const fd = this.file;
            this.file = -1;
            this.state = .closing;
            if (uv.uv_fs_close(this.loop, &this.fs, fd, onCloseComplete).errEnum() != null) {
                this.fs.deinit();
                _ = bun.FD.fromUV(fd).closeAllowingStandardIo(null);
                this.destroy();
            }
        }

        fn onCloseComplete(fs: *uv.fs_t) callconv(.c) void {
            const file = File.fromFS(fs);
            bun.assert(file.state == .closing);
            fs.deinit();
            file.destroy();
        }

        fn destroy(this: *File) void {
            bun.default_allocator.free(this.io_buffer);
            bun.default_allocator.destroy(this);
        }
    };

    pub fn isClosed(this: Source) bool {
        return switch (this) {
            .pipe => |pipe| pipe.isClosed(),
            .tty => |tty| tty.isClosed(),
            .sync_file, .file => |file| file.file == -1,
        };
    }

    pub fn memoryCost(this: Source) usize {
        return switch (this) {
            .pipe => @sizeOf(Pipe),
            .tty => @sizeOf(Tty),
            .file, .sync_file => |file| @sizeOf(File) + file.io_buffer.len,
        };
    }

    pub fn isActive(this: Source) bool {
        return switch (this) {
            .pipe => |pipe| pipe.isActive(),
            .tty => |tty| tty.isActive(),
            .sync_file, .file => true,
        };
    }

    pub fn getHandle(this: Source) *uv.Handle {
        return switch (this) {
            .pipe => @ptrCast(this.pipe),
            .tty => @ptrCast(this.tty),
            .sync_file, .file => unreachable,
        };
    }
    pub fn toStream(this: Source) *uv.uv_stream_t {
        return switch (this) {
            .pipe => this.pipe.asStream(),
            .tty => @ptrCast(this.tty),
            .sync_file, .file => unreachable,
        };
    }

    pub fn getFd(this: Source) bun.FD {
        return switch (this) {
            .pipe => |pipe| pipe.fd(),
            .tty => |tty| tty.fd(),
            .sync_file, .file => |file| .fromUV(file.file),
        };
    }

    pub fn setData(this: Source, data: ?*anyopaque) void {
        switch (this) {
            .pipe => |pipe| pipe.data = data,
            .tty => |tty| tty.data = data,
            .sync_file, .file => |file| file.fs.data = data,
        }
    }

    pub fn getData(this: Source) ?*anyopaque {
        return switch (this) {
            .pipe => |pipe| pipe.data,
            .tty => |tty| tty.data,
            .sync_file, .file => |file| file.fs.data,
        };
    }

    pub fn ref(this: Source) void {
        switch (this) {
            .pipe => this.pipe.ref(),
            .tty => this.tty.ref(),
            .sync_file, .file => return,
        }
    }

    pub fn unref(this: Source) void {
        switch (this) {
            .pipe => this.pipe.unref(),
            .tty => this.tty.unref(),
            .sync_file, .file => return,
        }
    }

    pub fn hasRef(this: Source) bool {
        return switch (this) {
            .pipe => |pipe| pipe.hasRef(),
            .tty => |tty| tty.hasRef(),
            .sync_file, .file => false,
        };
    }

    pub fn openPipe(loop: *uv.Loop, fd: bun.FD) bun.sys.Maybe(*Source.Pipe) {
        log("openPipe (fd = {f})", .{fd});
        const pipe = bun.default_allocator.create(Source.Pipe) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .open) };
        pipe.* = std.mem.zeroes(Source.Pipe);
        // we should never init using IPC here see ipc.zig
        switch (pipe.init(loop, false)) {
            .err => |err| {
                bun.destroy(pipe);
                return .{ .err = err };
            },
            else => {},
        }

        switch (pipe.open(fd)) {
            .err => |err| {
                pipe.closeAndDestroy();
                return .{
                    .err = err,
                };
            },
            .result => {},
        }

        finishStreamAdoption(fd);
        return .{ .result = pipe };
    }

    pub fn openTty(loop: *uv.Loop, fd: bun.FD) bun.sys.Maybe(*Source.Tty) {
        log("openTTY (fd = {f})", .{fd});
        const uv_fd = fd.uv();
        const tty = bun.default_allocator.create(Source.Tty) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .open) };
        switch (tty.init(loop, uv_fd)) {
            .err => |err| {
                bun.default_allocator.destroy(tty);
                return .{ .err = err };
            },
            .result => {},
        }

        finishStreamAdoption(fd);
        return .{ .result = tty };
    }

    fn finishStreamAdoption(fd: bun.FD) void {
        // libuv duplicates descriptors 0–2; Source consumes the original descriptor too.
        if (fd.uv() <= 2) _ = fd.closeAllowingStandardIo(null);
    }

    pub fn openFile(loop: *uv.Loop, fd: bun.FD) bun.sys.Maybe(*Source.File) {
        bun.assert(fd.isValid() and fd.uv() != -1);
        log("openFile (fd = {f})", .{fd});
        const file = bun.default_allocator.create(Source.File) catch return .{ .err = bun.sys.Error.fromCode(.NOMEM, .open) };

        file.* = .{ .loop = loop, .file = fd.uv() };
        return .{ .result = file };
    }

    pub fn open(loop: *uv.Loop, fd: bun.FD) bun.sys.Maybe(Source) {
        const rc = bun.windows.libuv.uv_guess_handle(fd.uv());
        log("open(fd: {f}, type: {s})", .{ fd, @tagName(rc) });

        switch (rc) {
            .named_pipe => {
                switch (openPipe(loop, fd)) {
                    .result => |pipe| return .{ .result = .{ .pipe = pipe } },
                    .err => |err| return .{ .err = err },
                }
            },
            .tty => {
                switch (openTty(loop, fd)) {
                    .result => |tty| return .{ .result = .{ .tty = tty } },
                    .err => |err| return .{ .err = err },
                }
            },
            .file => {
                return switch (openFile(loop, fd)) {
                    .result => |file| .{ .result = .{ .file = file } },
                    .err => |err| .{ .err = err },
                };
            },
            else => {
                const errno = bun.windows.getLastErrno();

                if (errno == .SUCCESS) {
                    return switch (openFile(loop, fd)) {
                        .result => |file| .{ .result = .{ .file = file } },
                        .err => |err| .{ .err = err },
                    };
                }

                return .{ .err = bun.sys.Error.fromCode(errno, .open) };
            },
        }
    }

    pub fn setRawMode(this: Source, value: bool) bun.sys.Maybe(void) {
        return switch (this) {
            .tty => |tty| {
                if (tty
                    .setMode(if (value) .vt else .normal)
                    .toError(.uv_tty_set_mode)) |err|
                {
                    return .{ .err = err };
                } else {
                    return .success;
                }
            },
            else => .{
                .err = .{
                    .errno = @backingInt(bun.sys.E.NOTSUP),
                    .syscall = .uv_tty_set_mode,
                    .fd = this.getFd(),
                },
            },
        };
    }
};

const bun = @import("bun");
const std = @import("std");
const uv = bun.windows.libuv;
