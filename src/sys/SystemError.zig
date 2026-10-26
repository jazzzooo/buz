pub const SystemError = struct {
    errno: c_int = 0,
    code: String = .empty,
    message: String,
    path: String = .empty,
    syscall: String = .empty,
    hostname: String = .empty,
    fd: c_int = std.math.minInt(c_int),
    dest: String = .empty,

    pub fn Maybe(comptime Result: type) type {
        return union(enum) {
            err: SystemError,
            result: Result,
        };
    }

    pub fn getErrno(this: *const SystemError) bun.sys.E {
        // `bun.sys.Error.toSystemErrorData` stores the negated errno expected by Node.
        return @fromBackingInt(@intCast(-this.errno));
    }

    pub fn deref(this: *const SystemError) void {
        this.path.deref();
        this.code.deref();
        this.message.deref();
        this.syscall.deref();
        this.hostname.deref();
        this.dest.deref();
    }

    pub fn ref(this: *SystemError) void {
        this.path.ref();
        this.code.ref();
        this.message.ref();
        this.syscall.ref();
        this.hostname.ref();
        this.dest.ref();
    }

    pub fn format(self: SystemError, writer: *std.Io.Writer) !void {
        if (!self.path.isEmpty()) {
            switch (bun.Output.enable_ansi_colors_stderr) {
                inline else => |enable_colors| try writer.print(
                    comptime bun.Output.prettyFmt(
                        "<r><red>{f}<r><d>:<r> <b>{f}<r>: {f} <d>({f}())<r>",
                        enable_colors,
                    ),
                    .{
                        self.code,
                        self.path,
                        self.message,
                        self.syscall,
                    },
                ),
            }
        } else switch (bun.Output.enable_ansi_colors_stderr) {
            inline else => |enable_colors| try writer.print(
                comptime bun.Output.prettyFmt(
                    "<r><red>{f}<r><d>:<r> {f} <d>({f}())<r>",
                    enable_colors,
                ),
                .{
                    self.code,
                    self.message,
                    self.syscall,
                },
            ),
        }
    }
};

const std = @import("std");

const bun = @import("bun");
const String = bun.String;
