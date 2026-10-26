//! Platform specific APIs for Darwin/macOS
//!
//! If an API can be implemented on multiple platforms,
//! it does not belong in this namespace.

/// Non-cancellable versions of various libc functions are undocumented
/// TODO: explain the $NOCANCEL problem
pub const nocancel = struct {
    const c = std.c;
    pub extern "c" fn @"recvfrom$NOCANCEL"(sockfd: c.fd_t, noalias buf: *anyopaque, len: usize, flags: u32, noalias src_addr: ?*c.sockaddr, noalias addrlen: ?*c.socklen_t) isize;
    pub extern "c" fn @"sendto$NOCANCEL"(sockfd: c.fd_t, buf: *const anyopaque, len: usize, flags: u32, dest_addr: ?*const c.sockaddr, addrlen: c.socklen_t) isize;
    pub extern "c" fn @"fcntl$NOCANCEL"(fd: c.fd_t, cmd: c_int, ...) c_int;
    // pub extern "c" fn @"sendmsg$NOCANCEL"(sockfd: c.fd_t, msg: *const std.x.os.Socket.Message, flags: c_int) isize;
    // pub extern "c" fn @"recvmsg$NOCANCEL"(sockfd: c.fd_t, msg: *std.x.os.Socket.Message, flags: c_int) isize;
    pub extern "c" fn @"connect$NOCANCEL"(sockfd: c.fd_t, sock_addr: *const c.sockaddr, addrlen: c.socklen_t) c_int;
    pub extern "c" fn @"accept$NOCANCEL"(sockfd: c.fd_t, noalias addr: ?*c.sockaddr, noalias addrlen: ?*c.socklen_t) c_int;
    pub extern "c" fn @"accept4$NOCANCEL"(sockfd: c.fd_t, noalias addr: ?*c.sockaddr, noalias addrlen: ?*c.socklen_t, flags: c_uint) c_int;
    pub extern "c" fn @"open$NOCANCEL"(path: [*:0]const u8, oflag: c_uint, ...) c_int;
    // https://opensource.apple.com/source/xnu/xnu-7195.81.3/libsyscall/wrappers/open-base.c
    pub extern "c" fn @"openat$NOCANCEL"(fd: c.fd_t, path: [*:0]const u8, oflag: c_uint, ...) c_int;
    pub extern "c" fn @"read$NOCANCEL"(fd: c.fd_t, buf: [*]u8, nbyte: usize) isize;
    pub extern "c" fn @"pread$NOCANCEL"(fd: c.fd_t, buf: [*]u8, nbyte: usize, offset: c.off_t) isize;
    pub extern "c" fn @"preadv$NOCANCEL"(fd: c.fd_t, uf: [*]std.posix.iovec, count: i32, offset: c.off_t) isize;
    pub extern "c" fn @"readv$NOCANCEL"(fd: c.fd_t, uf: [*]std.posix.iovec, count: i32) isize;
    pub extern "c" fn @"write$NOCANCEL"(fd: c.fd_t, buf: [*]const u8, nbyte: usize) isize;
    pub extern "c" fn @"writev$NOCANCEL"(fd: c.fd_t, buf: [*]const std.posix.iovec_const, count: i32) isize;
    pub extern "c" fn @"pwritev$NOCANCEL"(fd: c.fd_t, buf: [*]const std.posix.iovec_const, count: i32, offset: c.off_t) isize;
    pub extern "c" fn @"poll$NOCANCEL"(fds: [*]std.posix.pollfd, nfds: c_int, timeout: c_int) isize;
    pub extern "c" fn @"ppoll$NOCANCEL"(fds: [*]std.posix.pollfd, nfds: c_int, timeout: ?*const std.posix.timespec, sigmask: ?*const std.posix.sigset_t) isize;
};

pub const OSLog = struct {
    handle: *perf_c.BunPerfLog,

    pub fn init() ?OSLog {
        return .{ .handle = perf_c.bun_perf_log() orelse return null };
    }

    pub fn signpost(log: OSLog, name: i32) Signpost {
        return .{
            .id = perf_c.bun_perf_signpost_id(log.handle),
            .name = name,
            .log = log,
        };
    }

    pub const Signpost = struct {
        id: u64,
        name: i32,
        log: OSLog,

        pub fn emit(this: *const Signpost) void {
            perf_c.bun_perf_signpost_emit(this.log.handle, this.id, perf_c.BUN_PERF_EVENT, this.name);
        }

        pub const Interval = struct {
            signpost: Signpost,

            pub fn end(this: *const Interval) void {
                perf_c.bun_perf_signpost_emit(this.signpost.log.handle, this.signpost.id, perf_c.BUN_PERF_INTERVAL_END, this.signpost.name);
            }
        };

        pub fn interval(this: Signpost) Interval {
            perf_c.bun_perf_signpost_emit(this.log.handle, this.id, perf_c.BUN_PERF_INTERVAL_BEGIN, this.name);
            return Interval{
                .signpost = this,
            };
        }
    };
};

const bun = @import("bun");
const std = @import("std");
const perf_c = @import("perf-ffi");
