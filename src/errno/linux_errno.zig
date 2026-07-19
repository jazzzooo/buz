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
    EAGAIN = 11,
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
    EDEADLK = 35,
    ENAMETOOLONG = 36,
    ENOLCK = 37,
    ENOSYS = 38,
    ENOTEMPTY = 39,
    ELOOP = 40,
    EWOULDBLOCK = 41,
    ENOMSG = 42,
    EIDRM = 43,
    ECHRNG = 44,
    EL2NSYNC = 45,
    EL3HLT = 46,
    EL3RST = 47,
    ELNRNG = 48,
    EUNATCH = 49,
    ENOCSI = 50,
    EL2HLT = 51,
    EBADE = 52,
    EBADR = 53,
    EXFULL = 54,
    ENOANO = 55,
    EBADRQC = 56,
    EBADSLT = 57,
    EDEADLOCK = 58,
    EBFONT = 59,
    ENOSTR = 60,
    ENODATA = 61,
    ETIME = 62,
    ENOSR = 63,
    ENONET = 64,
    ENOPKG = 65,
    EREMOTE = 66,
    ENOLINK = 67,
    EADV = 68,
    ESRMNT = 69,
    ECOMM = 70,
    EPROTO = 71,
    EMULTIHOP = 72,
    EDOTDOT = 73,
    EBADMSG = 74,
    EOVERFLOW = 75,
    ENOTUNIQ = 76,
    EBADFD = 77,
    EREMCHG = 78,
    ELIBACC = 79,
    ELIBBAD = 80,
    ELIBSCN = 81,
    ELIBMAX = 82,
    ELIBEXEC = 83,
    EILSEQ = 84,
    ERESTART = 85,
    ESTRPIPE = 86,
    EUSERS = 87,
    ENOTSOCK = 88,
    EDESTADDRREQ = 89,
    EMSGSIZE = 90,
    EPROTOTYPE = 91,
    ENOPROTOOPT = 92,
    EPROTONOSUPPORT = 93,
    ESOCKTNOSUPPORT = 94,
    /// For Linux, EOPNOTSUPP is the real value
    /// but it's ~the same and is incompatible across operating systems
    /// https://lists.gnu.org/archive/html/bug-glibc/2002-08/msg00017.html
    ENOTSUP = 95,
    EPFNOSUPPORT = 96,
    EAFNOSUPPORT = 97,
    EADDRINUSE = 98,
    EADDRNOTAVAIL = 99,
    ENETDOWN = 100,
    ENETUNREACH = 101,
    ENETRESET = 102,
    ECONNABORTED = 103,
    ECONNRESET = 104,
    ENOBUFS = 105,
    EISCONN = 106,
    ENOTCONN = 107,
    ESHUTDOWN = 108,
    ETOOMANYREFS = 109,
    ETIMEDOUT = 110,
    ECONNREFUSED = 111,
    EHOSTDOWN = 112,
    EHOSTUNREACH = 113,
    EALREADY = 114,
    EINPROGRESS = 115,
    ESTALE = 116,
    EUCLEAN = 117,
    ENOTNAM = 118,
    ENAVAIL = 119,
    EISNAM = 120,
    EREMOTEIO = 121,
    EDQUOT = 122,
    ENOMEDIUM = 123,
    EMEDIUMTYPE = 124,
    ECANCELED = 125,
    ENOKEY = 126,
    EKEYEXPIRED = 127,
    EKEYREVOKED = 128,
    EKEYREJECTED = 129,
    EOWNERDEAD = 130,
    ENOTRECOVERABLE = 131,
    ERFKILL = 132,
    EHWPOISON = 133,

    pub const max = 134;

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
    pub const NONET: i32 = @backingInt(SystemErrno.ENONET);
    pub const NOSPC: i32 = @backingInt(SystemErrno.ENOSPC);
    pub const NOSYS: i32 = @backingInt(SystemErrno.ENOSYS);
    pub const NOTCONN: i32 = @backingInt(SystemErrno.ENOTCONN);
    pub const NOTDIR: i32 = @backingInt(SystemErrno.ENOTDIR);
    pub const NOTEMPTY: i32 = @backingInt(SystemErrno.ENOTEMPTY);
    pub const NOTSOCK: i32 = @backingInt(SystemErrno.ENOTSOCK);
    pub const NOTSUP: i32 = @backingInt(SystemErrno.ENOTSUP);
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
    pub const REMOTEIO: i32 = @backingInt(SystemErrno.EREMOTEIO);
    pub const NOTTY: i32 = @backingInt(SystemErrno.ENOTTY);
    pub const FTYPE: i32 = -bun.windows.libuv.UV_EFTYPE;
    pub const ILSEQ: i32 = @backingInt(SystemErrno.EILSEQ);
    pub const OVERFLOW: i32 = @backingInt(SystemErrno.EOVERFLOW);
    pub const SOCKTNOSUPPORT: i32 = @backingInt(SystemErrno.ESOCKTNOSUPPORT);
    pub const NODATA: i32 = @backingInt(SystemErrno.ENODATA);
    pub const UNATCH: i32 = @backingInt(SystemErrno.EUNATCH);
    pub const NOEXEC: i32 = @backingInt(SystemErrno.ENOEXEC);
};
pub fn getErrno(rc: anytype) E {
    const Type = @TypeOf(rc);

    return switch (Type) {
        // raw system calls from std.os.linux.* return usize or u64
        // the errno is stored in this value
        usize, u64 => std.os.linux.errno(rc),

        // glibc system call wrapper returns i32/int
        // the errno is stored in a thread local variable
        //
        // TODO: the inclusion of  'u32' and 'isize' seems suspicious
        i32, c_int, u32, isize, i64 => if (rc == -1)
            @fromBackingInt(@intCast(std.c._errno().*))
        else
            .SUCCESS,

        else => @compileError("Not implemented yet for type " ++ @typeName(Type)),
    };
}

const bun = @import("bun");
const std = @import("std");
