const Self = @This();

context: Context,
vtable: *const VTable,

const Context = bun.bindgen.NativeCallbackContext(.vm);

const VTable = struct {
    pause_resume: *const fn (Context, bool) bool,
    verify_error: *const fn (Context) VerifyError,
    is_established: *const fn (Context) bool,
    set_timeout: *const fn (Context, c_uint) void,
    ssl: *const fn (Context) ?*BoringSSL.SSL,
    flush: *const fn (Context) void,
    write: *const fn (Context, []const u8) i32,
    raw_write: *const fn (Context, []const u8) i32,
    shutdown: *const fn (Context) void,
    shutdown_read: *const fn (Context) void,
    is_shutdown: *const fn (Context) bool,
    close: *const fn (Context) void,
    is_closed: *const fn (Context) bool,
};

pub fn init(transport: anytype, comptime pausable: bool) Self {
    const Pointer = @TypeOf(transport);
    const pointer_info = switch (@typeInfo(Pointer)) {
        .pointer => |info| info,
        else => @compileError("socket transport must be a pointer"),
    };
    if (pointer_info.size != .one) @compileError("socket transport must be a single-item pointer");

    const Adapter = struct {
        fn get(context: Context) Pointer {
            return context.get(Pointer);
        }

        fn setPaused(context: Context, pause: bool) bool {
            if (comptime !pausable) return false;
            const value = get(context);
            return if (pause) value.pauseStream() else value.resumeStream();
        }

        fn getVerifyError(context: Context) VerifyError {
            return get(context).sslError();
        }

        fn getIsEstablished(context: Context) bool {
            return get(context).isEstablished();
        }

        fn applyTimeout(context: Context, seconds: c_uint) void {
            get(context).setTimeout(seconds);
        }

        fn getSSL(context: Context) ?*BoringSSL.SSL {
            return get(context).ssl();
        }

        fn flushTransport(context: Context) void {
            get(context).flush();
        }

        fn writeEncoded(context: Context, data: []const u8) i32 {
            return get(context).encodeAndWrite(data);
        }

        fn writeRaw(context: Context, data: []const u8) i32 {
            return get(context).rawWrite(data);
        }

        fn shutdownTransport(context: Context) void {
            get(context).shutdown();
        }

        fn shutdownTransportRead(context: Context) void {
            get(context).shutdownRead();
        }

        fn getIsShutdown(context: Context) bool {
            return get(context).isShutdown();
        }

        fn closeTransport(context: Context) void {
            get(context).close();
        }

        fn getIsClosed(context: Context) bool {
            return get(context).isClosed();
        }

        const vtable: VTable = .{
            .pause_resume = setPaused,
            .verify_error = getVerifyError,
            .is_established = getIsEstablished,
            .set_timeout = applyTimeout,
            .ssl = getSSL,
            .flush = flushTransport,
            .write = writeEncoded,
            .raw_write = writeRaw,
            .shutdown = shutdownTransport,
            .shutdown_read = shutdownTransportRead,
            .is_shutdown = getIsShutdown,
            .close = closeTransport,
            .is_closed = getIsClosed,
        };
    };

    return .{
        .context = .init(transport),
        .vtable = &Adapter.vtable,
    };
}

pub fn pauseResume(self: Self, pause: bool) bool {
    return self.vtable.pause_resume(self.context, pause);
}

pub fn verifyError(self: Self) VerifyError {
    return self.vtable.verify_error(self.context);
}

pub fn isEstablished(self: Self) bool {
    return self.vtable.is_established(self.context);
}

pub fn setTimeout(self: Self, seconds: c_uint) void {
    self.vtable.set_timeout(self.context, seconds);
}

pub fn ssl(self: Self) ?*BoringSSL.SSL {
    return self.vtable.ssl(self.context);
}

pub fn flush(self: Self) void {
    self.vtable.flush(self.context);
}

pub fn write(self: Self, data: []const u8) i32 {
    return self.vtable.write(self.context, data);
}

pub fn rawWrite(self: Self, data: []const u8) i32 {
    return self.vtable.raw_write(self.context, data);
}

pub fn shutdown(self: Self) void {
    self.vtable.shutdown(self.context);
}

pub fn shutdownRead(self: Self) void {
    self.vtable.shutdown_read(self.context);
}

pub fn isShutdown(self: Self) bool {
    return self.vtable.is_shutdown(self.context);
}

pub fn close(self: Self) void {
    self.vtable.close(self.context);
}

pub fn isClosed(self: Self) bool {
    return self.vtable.is_closed(self.context);
}

pub fn eql(self: Self, other: Self) bool {
    return self.context.eql(other.context) and self.vtable == other.vtable;
}

const bun = @import("bun");
const BoringSSL = bun.BoringSSL.c;
const VerifyError = bun.uws.us_bun_verify_error_t;
