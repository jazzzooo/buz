pub const Mode = std.posix.mode_t;
pub const E = std.posix.E;
pub const S = std.posix.S;

pub const SystemErrno = enum(u16) {
    SUCCESS = 0,
    EPERM = 1,
    ENOENT = 2,
    ESRCH = 3,
    EINTR = 4,
    EIO = 5,
    ENXIO = 6,
    E2BIG = 7,
    ENOEXEC = 8,
    EBADF = 9,
    ECHILD = 10,
    EDEADLK = 11,
    ENOMEM = 12,
    EACCES = 13,
    EFAULT = 14,
    ENOTBLK = 15,
    EBUSY = 16,
    EEXIST = 17,
    EXDEV = 18,
    ENODEV = 19,
    ENOTDIR = 20,
    EISDIR = 21,
    EINVAL = 22,
    ENFILE = 23,
    EMFILE = 24,
    ENOTTY = 25,
    ETXTBSY = 26,
    EFBIG = 27,
    ENOSPC = 28,
    ESPIPE = 29,
    EROFS = 30,
    EMLINK = 31,
    EPIPE = 32,
    EDOM = 33,
    ERANGE = 34,
    EAGAIN = 35,
    EINPROGRESS = 36,
    EALREADY = 37,
    ENOTSOCK = 38,
    EDESTADDRREQ = 39,
    EMSGSIZE = 40,
    EPROTOTYPE = 41,
    ENOPROTOOPT = 42,
    EPROTONOSUPPORT = 43,
    ESOCKTNOSUPPORT = 44,
    EOPNOTSUPP = 45,
    EPFNOSUPPORT = 46,
    EAFNOSUPPORT = 47,
    EADDRINUSE = 48,
    EADDRNOTAVAIL = 49,
    ENETDOWN = 50,
    ENETUNREACH = 51,
    ENETRESET = 52,
    ECONNABORTED = 53,
    ECONNRESET = 54,
    ENOBUFS = 55,
    EISCONN = 56,
    ENOTCONN = 57,
    ESHUTDOWN = 58,
    ETOOMANYREFS = 59,
    ETIMEDOUT = 60,
    ECONNREFUSED = 61,
    ELOOP = 62,
    ENAMETOOLONG = 63,
    EHOSTDOWN = 64,
    EHOSTUNREACH = 65,
    ENOTEMPTY = 66,
    EPROCLIM = 67,
    EUSERS = 68,
    EDQUOT = 69,
    ESTALE = 70,
    EREMOTE = 71,
    EBADRPC = 72,
    ERPCMISMATCH = 73,
    EPROGUNAVAIL = 74,
    EPROGMISMATCH = 75,
    EPROCUNAVAIL = 76,
    ENOLCK = 77,
    ENOSYS = 78,
    EFTYPE = 79,
    EAUTH = 80,
    ENEEDAUTH = 81,
    EIDRM = 82,
    ENOMSG = 83,
    EOVERFLOW = 84,
    ECANCELED = 85,
    EILSEQ = 86,
    ENOATTR = 87,
    EDOOFUS = 88,
    EBADMSG = 89,
    EMULTIHOP = 90,
    ENOLINK = 91,
    EPROTO = 92,
    ENOTCAPABLE = 93,
    ECAPMODE = 94,
    ENOTRECOVERABLE = 95,
    EOWNERDEAD = 96,
    EINTEGRITY = 97,

    pub const max = 98;

    pub fn init(code: anytype) ?SystemErrno {
        if (code < 0) {
            if (code <= -max) {
                return null;
            }
            return @fromBackingInt(@intCast(-code));
        }
        if (code >= max) return null;
        return @fromBackingInt(@intCast(code));
    }
};

pub const UV_E = struct {
    pub const @"2BIG": i32 = @backingInt(SystemErrno.E2BIG);
    pub const ACCES: i32 = @backingInt(SystemErrno.EACCES);
    pub const ADDRINUSE: i32 = @backingInt(SystemErrno.EADDRINUSE);
    pub const ADDRNOTAVAIL: i32 = @backingInt(SystemErrno.EADDRNOTAVAIL);
    pub const AFNOSUPPORT: i32 = @backingInt(SystemErrno.EAFNOSUPPORT);
    pub const AGAIN: i32 = @backingInt(SystemErrno.EAGAIN);
    pub const ALREADY: i32 = @backingInt(SystemErrno.EALREADY);
    pub const BADF: i32 = @backingInt(SystemErrno.EBADF);
    pub const BUSY: i32 = @backingInt(SystemErrno.EBUSY);
    pub const CANCELED: i32 = @backingInt(SystemErrno.ECANCELED);
    pub const CHARSET: i32 = -bun.windows.libuv.UV_ECHARSET;
    pub const CONNABORTED: i32 = @backingInt(SystemErrno.ECONNABORTED);
    pub const CONNREFUSED: i32 = @backingInt(SystemErrno.ECONNREFUSED);
    pub const CONNRESET: i32 = @backingInt(SystemErrno.ECONNRESET);
    pub const DESTADDRREQ: i32 = @backingInt(SystemErrno.EDESTADDRREQ);
    pub const EXIST: i32 = @backingInt(SystemErrno.EEXIST);
    pub const FAULT: i32 = @backingInt(SystemErrno.EFAULT);
    pub const HOSTUNREACH: i32 = @backingInt(SystemErrno.EHOSTUNREACH);
    pub const INTR: i32 = @backingInt(SystemErrno.EINTR);
    pub const INVAL: i32 = @backingInt(SystemErrno.EINVAL);
    pub const IO: i32 = @backingInt(SystemErrno.EIO);
    pub const ISCONN: i32 = @backingInt(SystemErrno.EISCONN);
    pub const ISDIR: i32 = @backingInt(SystemErrno.EISDIR);
    pub const LOOP: i32 = @backingInt(SystemErrno.ELOOP);
    pub const MFILE: i32 = @backingInt(SystemErrno.EMFILE);
    pub const MSGSIZE: i32 = @backingInt(SystemErrno.EMSGSIZE);
    pub const NAMETOOLONG: i32 = @backingInt(SystemErrno.ENAMETOOLONG);
    pub const NETDOWN: i32 = @backingInt(SystemErrno.ENETDOWN);
    pub const NETUNREACH: i32 = @backingInt(SystemErrno.ENETUNREACH);
    pub const NFILE: i32 = @backingInt(SystemErrno.ENFILE);
    pub const NOBUFS: i32 = @backingInt(SystemErrno.ENOBUFS);
    pub const NODEV: i32 = @backingInt(SystemErrno.ENODEV);
    pub const NOENT: i32 = @backingInt(SystemErrno.ENOENT);
    pub const NOMEM: i32 = @backingInt(SystemErrno.ENOMEM);
    pub const NONET: i32 = -bun.windows.libuv.UV_ENONET;
    pub const NOSPC: i32 = @backingInt(SystemErrno.ENOSPC);
    pub const NOSYS: i32 = @backingInt(SystemErrno.ENOSYS);
    pub const NOTCONN: i32 = @backingInt(SystemErrno.ENOTCONN);
    pub const NOTDIR: i32 = @backingInt(SystemErrno.ENOTDIR);
    pub const NOTEMPTY: i32 = @backingInt(SystemErrno.ENOTEMPTY);
    pub const NOTSOCK: i32 = @backingInt(SystemErrno.ENOTSOCK);
    pub const NOTSUP: i32 = -bun.windows.libuv.UV_ENOTSUP;
    pub const PERM: i32 = @backingInt(SystemErrno.EPERM);
    pub const PIPE: i32 = @backingInt(SystemErrno.EPIPE);
    pub const PROTO: i32 = @backingInt(SystemErrno.EPROTO);
    pub const PROTONOSUPPORT: i32 = @backingInt(SystemErrno.EPROTONOSUPPORT);
    pub const PROTOTYPE: i32 = @backingInt(SystemErrno.EPROTOTYPE);
    pub const ROFS: i32 = @backingInt(SystemErrno.EROFS);
    pub const SHUTDOWN: i32 = @backingInt(SystemErrno.ESHUTDOWN);
    pub const SPIPE: i32 = @backingInt(SystemErrno.ESPIPE);
    pub const SRCH: i32 = @backingInt(SystemErrno.ESRCH);
    pub const TIMEDOUT: i32 = @backingInt(SystemErrno.ETIMEDOUT);
    pub const TXTBSY: i32 = @backingInt(SystemErrno.ETXTBSY);
    pub const XDEV: i32 = @backingInt(SystemErrno.EXDEV);
    pub const FBIG: i32 = @backingInt(SystemErrno.EFBIG);
    pub const NOPROTOOPT: i32 = @backingInt(SystemErrno.ENOPROTOOPT);
    pub const RANGE: i32 = @backingInt(SystemErrno.ERANGE);
    pub const NXIO: i32 = @backingInt(SystemErrno.ENXIO);
    pub const MLINK: i32 = @backingInt(SystemErrno.EMLINK);
    pub const HOSTDOWN: i32 = @backingInt(SystemErrno.EHOSTDOWN);
    pub const REMOTEIO: i32 = -bun.windows.libuv.UV_EREMOTEIO;
    pub const NOTTY: i32 = @backingInt(SystemErrno.ENOTTY);
    pub const FTYPE: i32 = @backingInt(SystemErrno.EFTYPE);
    pub const ILSEQ: i32 = @backingInt(SystemErrno.EILSEQ);
    pub const OVERFLOW: i32 = @backingInt(SystemErrno.EOVERFLOW);
    pub const SOCKTNOSUPPORT: i32 = @backingInt(SystemErrno.ESOCKTNOSUPPORT);
    pub const NODATA: i32 = -bun.windows.libuv.UV_ENODATA;
    pub const UNATCH: i32 = -bun.windows.libuv.UV_EUNATCH;
    pub const NOEXEC: i32 = @backingInt(SystemErrno.ENOEXEC);
};

pub fn getErrno(rc: anytype) E {
    const T = @TypeOf(rc);
    // Libc wrappers return -1 on failure with the actual errno in
    // thread-local errno. Some Zig std signatures (e.g. copy_file_range) use
    // `usize`, so a kernel -1 arrives as maxInt(usize) — comparing that to
    // comptime -1 is always false. Bitcast unsigned inputs to signed first
    // (matches linux_errno.zig).
    const info = @typeInfo(T);
    const is_neg1 = if (info == .int and info.int.signedness == .unsigned)
        @as(@Int(.signed, info.int.bits), @bitCast(rc)) == -1
    else
        rc == -1;
    if (is_neg1) {
        return @fromBackingInt(@intCast(std.c._errno().*));
    }
    return .SUCCESS;
}

const bun = @import("bun");
const std = @import("std");
