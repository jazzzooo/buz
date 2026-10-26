pub const PollFailure = extern struct {
    domain: enum(c_int) { none, system, libuv, mach } = .none,
    code: c_int = 0,

    pub fn toZigError(this: PollFailure) anyerror {
        const errno = this.systemErrno() orelse return error.Unexpected;
        if (errno == .ENOMEM) return error.OutOfMemory;
        const native_errno: bun.sys.E = if (bun.Environment.isWindows) errno.toE() else @fromBackingInt(@backingInt(errno));
        return bun.sys.Error.fromCode(native_errno, .poll).toZigErr();
    }

    pub fn systemErrno(this: PollFailure) ?bun.sys.SystemErrno {
        return switch (this.domain) {
            .none, .mach => null,
            .system => if (this.code == 0)
                null
            else if (comptime bun.Environment.isWindows)
                bun.sys.SystemErrno.fromWinsock(@as(bun.windows.WinsockError, @fromBackingInt(this.code)))
            else
                bun.sys.SystemErrno.init(this.code),
            .libuv => if (this.code >= 0)
                null
            else if (comptime bun.Environment.isWindows)
                bun.sys.SystemErrno.fromUv(this.code)
            else
                bun.sys.SystemErrno.init(-@as(i64, this.code)),
        };
    }
};

const bun = @import("bun");
