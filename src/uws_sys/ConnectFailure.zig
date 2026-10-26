pub const ConnectFailure = extern struct {
    system_error: c_int = 0,
    dns_error: c_int = 0,
    poll_error: PollFailure = .{},

    pub fn hasError(this: ConnectFailure) bool {
        return this.system_error != 0 or this.dns_error != 0 or this.poll_error.domain != .none;
    }

    pub fn systemErrno(this: ConnectFailure) ?bun.sys.SystemErrno {
        return if (this.poll_error.domain != .none)
            this.poll_error.systemErrno()
        else
            (PollFailure{ .domain = .system, .code = this.system_error }).systemErrno();
    }

    pub fn isOutOfMemory(this: ConnectFailure) bool {
        if (this.systemErrno()) |err| if (err == .ENOMEM) return true;
        if (this.dns_error != 0) {
            if (bun.c_ares.Error.initEAI(this.dns_error)) |err| return err == .ENOMEM;
        }
        return false;
    }
};

const PollFailure = @import("./PollFailure.zig").PollFailure;
const bun = @import("bun");
