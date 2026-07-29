pub const E = enum(u16) {
    SUCCESS = 0,
    PERM = 1,
    NOENT = 2,
    SRCH = 3,
    INTR = 4,
    IO = 5,
    NXIO = 6,
    @"2BIG" = 7,
    NOEXEC = 8,
    BADF = 9,
    CHILD = 10,
    AGAIN = 11,
    NOMEM = 12,
    ACCES = 13,
    FAULT = 14,
    NOTBLK = 15,
    BUSY = 16,
    EXIST = 17,
    XDEV = 18,
    NODEV = 19,
    NOTDIR = 20,
    ISDIR = 21,
    INVAL = 22,
    NFILE = 23,
    MFILE = 24,
    NOTTY = 25,
    TXTBSY = 26,
    FBIG = 27,
    NOSPC = 28,
    SPIPE = 29,
    ROFS = 30,
    MLINK = 31,
    PIPE = 32,
    DOM = 33,
    RANGE = 34,
    DEADLK = 35,
    NAMETOOLONG = 36,
    NOLCK = 37,
    NOSYS = 38,
    NOTEMPTY = 39,
    LOOP = 40,
    WOULDBLOCK = 41,
    NOMSG = 42,
    IDRM = 43,
    CHRNG = 44,
    L2NSYNC = 45,
    L3HLT = 46,
    L3RST = 47,
    LNRNG = 48,
    UNATCH = 49,
    NOCSI = 50,
    L2HLT = 51,
    BADE = 52,
    BADR = 53,
    XFULL = 54,
    NOANO = 55,
    BADRQC = 56,
    BADSLT = 57,
    DEADLOCK = 58,
    BFONT = 59,
    NOSTR = 60,
    NODATA = 61,
    TIME = 62,
    NOSR = 63,
    NONET = 64,
    NOPKG = 65,
    REMOTE = 66,
    NOLINK = 67,
    ADV = 68,
    SRMNT = 69,
    COMM = 70,
    PROTO = 71,
    MULTIHOP = 72,
    DOTDOT = 73,
    BADMSG = 74,
    OVERFLOW = 75,
    NOTUNIQ = 76,
    BADFD = 77,
    REMCHG = 78,
    LIBACC = 79,
    LIBBAD = 80,
    LIBSCN = 81,
    LIBMAX = 82,
    LIBEXEC = 83,
    ILSEQ = 84,
    RESTART = 85,
    STRPIPE = 86,
    USERS = 87,
    NOTSOCK = 88,
    DESTADDRREQ = 89,
    MSGSIZE = 90,
    PROTOTYPE = 91,
    NOPROTOOPT = 92,
    PROTONOSUPPORT = 93,
    SOCKTNOSUPPORT = 94,
    NOTSUP = 95,
    PFNOSUPPORT = 96,
    AFNOSUPPORT = 97,
    ADDRINUSE = 98,
    ADDRNOTAVAIL = 99,
    NETDOWN = 100,
    NETUNREACH = 101,
    NETRESET = 102,
    CONNABORTED = 103,
    CONNRESET = 104,
    NOBUFS = 105,
    ISCONN = 106,
    NOTCONN = 107,
    SHUTDOWN = 108,
    TOOMANYREFS = 109,
    TIMEDOUT = 110,
    CONNREFUSED = 111,
    HOSTDOWN = 112,
    HOSTUNREACH = 113,
    ALREADY = 114,
    INPROGRESS = 115,
    STALE = 116,
    UCLEAN = 117,
    NOTNAM = 118,
    NAVAIL = 119,
    ISNAM = 120,
    REMOTEIO = 121,
    DQUOT = 122,
    NOMEDIUM = 123,
    MEDIUMTYPE = 124,
    CANCELED = 125,
    NOKEY = 126,
    KEYEXPIRED = 127,
    KEYREVOKED = 128,
    KEYREJECTED = 129,
    OWNERDEAD = 130,
    NOTRECOVERABLE = 131,
    RFKILL = 132,
    HWPOISON = 133,
    UNKNOWN = 134,
    CHARSET = 135,
    EOF = 136,
    FTYPE = 137,

    UV_E2BIG = -uv.UV_E2BIG,
    UV_EACCES = -uv.UV_EACCES,
    UV_EADDRINUSE = -uv.UV_EADDRINUSE,
    UV_EADDRNOTAVAIL = -uv.UV_EADDRNOTAVAIL,
    UV_EAFNOSUPPORT = -uv.UV_EAFNOSUPPORT,
    UV_EAGAIN = -uv.UV_EAGAIN,
    UV_EAI_ADDRFAMILY = -uv.UV_EAI_ADDRFAMILY,
    UV_EAI_AGAIN = -uv.UV_EAI_AGAIN,
    UV_EAI_BADFLAGS = -uv.UV_EAI_BADFLAGS,
    UV_EAI_BADHINTS = -uv.UV_EAI_BADHINTS,
    UV_EAI_CANCELED = -uv.UV_EAI_CANCELED,
    UV_EAI_FAIL = -uv.UV_EAI_FAIL,
    UV_EAI_FAMILY = -uv.UV_EAI_FAMILY,
    UV_EAI_MEMORY = -uv.UV_EAI_MEMORY,
    UV_EAI_NODATA = -uv.UV_EAI_NODATA,
    UV_EAI_NONAME = -uv.UV_EAI_NONAME,
    UV_EAI_OVERFLOW = -uv.UV_EAI_OVERFLOW,
    UV_EAI_PROTOCOL = -uv.UV_EAI_PROTOCOL,
    UV_EAI_SERVICE = -uv.UV_EAI_SERVICE,
    UV_EAI_SOCKTYPE = -uv.UV_EAI_SOCKTYPE,
    UV_EALREADY = -uv.UV_EALREADY,
    UV_EBADF = -uv.UV_EBADF,
    UV_EBUSY = -uv.UV_EBUSY,
    UV_ECANCELED = -uv.UV_ECANCELED,
    UV_ECHARSET = -uv.UV_ECHARSET,
    UV_ECONNABORTED = -uv.UV_ECONNABORTED,
    UV_ECONNREFUSED = -uv.UV_ECONNREFUSED,
    UV_ECONNRESET = -uv.UV_ECONNRESET,
    UV_EDESTADDRREQ = -uv.UV_EDESTADDRREQ,
    UV_EEXIST = -uv.UV_EEXIST,
    UV_EFAULT = -uv.UV_EFAULT,
    UV_EFBIG = -uv.UV_EFBIG,
    UV_EHOSTUNREACH = -uv.UV_EHOSTUNREACH,
    UV_EINVAL = -uv.UV_EINVAL,
    UV_EINTR = -uv.UV_EINTR,
    UV_EISCONN = -uv.UV_EISCONN,
    UV_EIO = -uv.UV_EIO,
    UV_ELOOP = -uv.UV_ELOOP,
    UV_EISDIR = -uv.UV_EISDIR,
    UV_EMSGSIZE = -uv.UV_EMSGSIZE,
    UV_EMFILE = -uv.UV_EMFILE,
    UV_ENETDOWN = -uv.UV_ENETDOWN,
    UV_ENAMETOOLONG = -uv.UV_ENAMETOOLONG,
    UV_ENFILE = -uv.UV_ENFILE,
    UV_ENETUNREACH = -uv.UV_ENETUNREACH,
    UV_ENODEV = -uv.UV_ENODEV,
    UV_ENOBUFS = -uv.UV_ENOBUFS,
    UV_ENOMEM = -uv.UV_ENOMEM,
    UV_ENOENT = -uv.UV_ENOENT,
    UV_ENOPROTOOPT = -uv.UV_ENOPROTOOPT,
    UV_ENONET = -uv.UV_ENONET,
    UV_ENOSYS = -uv.UV_ENOSYS,
    UV_ENOSPC = -uv.UV_ENOSPC,
    UV_ENOTDIR = -uv.UV_ENOTDIR,
    UV_ENOTCONN = -uv.UV_ENOTCONN,
    UV_ENOTSOCK = -uv.UV_ENOTSOCK,
    UV_ENOTEMPTY = -uv.UV_ENOTEMPTY,
    UV_EOVERFLOW = -uv.UV_EOVERFLOW,
    UV_ENOTSUP = -uv.UV_ENOTSUP,
    UV_EPIPE = -uv.UV_EPIPE,
    UV_EPERM = -uv.UV_EPERM,
    UV_EPROTONOSUPPORT = -uv.UV_EPROTONOSUPPORT,
    UV_EPROTO = -uv.UV_EPROTO,
    UV_ERANGE = -uv.UV_ERANGE,
    UV_EPROTOTYPE = -uv.UV_EPROTOTYPE,
    UV_ESHUTDOWN = -uv.UV_ESHUTDOWN,
    UV_EROFS = -uv.UV_EROFS,
    UV_ESRCH = -uv.UV_ESRCH,
    UV_ESPIPE = -uv.UV_ESPIPE,
    UV_ETXTBSY = -uv.UV_ETXTBSY,
    UV_ETIMEDOUT = -uv.UV_ETIMEDOUT,
    UV_UNKNOWN = -uv.UV_UNKNOWN,
    UV_EXDEV = -uv.UV_EXDEV,
    UV_ENXIO = -uv.UV_ENXIO,
    UV_EOF = -uv.UV_EOF,
    UV_EHOSTDOWN = -uv.UV_EHOSTDOWN,
    UV_EMLINK = -uv.UV_EMLINK,
    UV_ENOTTY = -uv.UV_ENOTTY,
    UV_EREMOTEIO = -uv.UV_EREMOTEIO,
    UV_EILSEQ = -uv.UV_EILSEQ,
    UV_EFTYPE = -uv.UV_EFTYPE,
    UV_ENODATA = -uv.UV_ENODATA,
    UV_ESOCKTNOSUPPORT = -uv.UV_ESOCKTNOSUPPORT,
    UV_ERRNO_MAX = -uv.UV_ERRNO_MAX,
    UV_EUNATCH = -uv.UV_EUNATCH,
    UV_ENOEXEC = -uv.UV_ENOEXEC,
};

pub const S = struct {
    pub const IFMT = 0o170000;

    pub const IFDIR = 0o040000;
    pub const IFCHR = 0o020000;
    pub const IFBLK = 0o060000;
    pub const IFREG = 0o100000;
    pub const IFIFO = 0o010000;
    pub const IFLNK = 0o120000;
    pub const IFSOCK = 0o140000;

    pub const ISUID = 0o4000;
    pub const ISGID = 0o2000;
    pub const ISVTX = 0o1000;
    pub const IRUSR = 0o400;
    pub const IWUSR = 0o200;
    pub const IXUSR = 0o100;
    pub const IRWXU = 0o700;
    pub const IRGRP = 0o040;
    pub const IWGRP = 0o020;
    pub const IXGRP = 0o010;
    pub const IRWXG = 0o070;
    pub const IROTH = 0o004;
    pub const IWOTH = 0o002;
    pub const IXOTH = 0o001;
    pub const IRWXO = 0o007;

    pub inline fn ISREG(m: i32) bool {
        return m & IFMT == IFREG;
    }

    pub inline fn ISDIR(m: i32) bool {
        return m & IFMT == IFDIR;
    }

    pub inline fn ISCHR(m: i32) bool {
        return m & IFMT == IFCHR;
    }

    pub inline fn ISBLK(m: i32) bool {
        return m & IFMT == IFBLK;
    }

    pub inline fn ISFIFO(m: i32) bool {
        return m & IFMT == IFIFO;
    }

    pub inline fn ISLNK(m: i32) bool {
        return m & IFMT == IFLNK;
    }

    pub inline fn ISSOCK(m: i32) bool {
        return m & IFMT == IFSOCK;
    }
};

pub fn getErrno(rc: anytype) E {
    if (comptime @TypeOf(rc) == bun.windows.NTSTATUS) {
        return SystemErrno.fromNtStatus(rc).toE();
    }

    return SystemErrno.fromWin32(bun.windows.GetLastError()).toE();
}

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
    // made up erropr
    EUNKNOWN = 134,
    ECHARSET = 135,
    EOF = 136,
    EFTYPE = 137,

    UV_E2BIG = -uv.UV_E2BIG,
    UV_EACCES = -uv.UV_EACCES,
    UV_EADDRINUSE = -uv.UV_EADDRINUSE,
    UV_EADDRNOTAVAIL = -uv.UV_EADDRNOTAVAIL,
    UV_EAFNOSUPPORT = -uv.UV_EAFNOSUPPORT,
    UV_EAGAIN = -uv.UV_EAGAIN,
    UV_EAI_ADDRFAMILY = -uv.UV_EAI_ADDRFAMILY,
    UV_EAI_AGAIN = -uv.UV_EAI_AGAIN,
    UV_EAI_BADFLAGS = -uv.UV_EAI_BADFLAGS,
    UV_EAI_BADHINTS = -uv.UV_EAI_BADHINTS,
    UV_EAI_CANCELED = -uv.UV_EAI_CANCELED,
    UV_EAI_FAIL = -uv.UV_EAI_FAIL,
    UV_EAI_FAMILY = -uv.UV_EAI_FAMILY,
    UV_EAI_MEMORY = -uv.UV_EAI_MEMORY,
    UV_EAI_NODATA = -uv.UV_EAI_NODATA,
    UV_EAI_NONAME = -uv.UV_EAI_NONAME,
    UV_EAI_OVERFLOW = -uv.UV_EAI_OVERFLOW,
    UV_EAI_PROTOCOL = -uv.UV_EAI_PROTOCOL,
    UV_EAI_SERVICE = -uv.UV_EAI_SERVICE,
    UV_EAI_SOCKTYPE = -uv.UV_EAI_SOCKTYPE,
    UV_EALREADY = -uv.UV_EALREADY,
    UV_EBADF = -uv.UV_EBADF,
    UV_EBUSY = -uv.UV_EBUSY,
    UV_ECANCELED = -uv.UV_ECANCELED,
    UV_ECHARSET = -uv.UV_ECHARSET,
    UV_ECONNABORTED = -uv.UV_ECONNABORTED,
    UV_ECONNREFUSED = -uv.UV_ECONNREFUSED,
    UV_ECONNRESET = -uv.UV_ECONNRESET,
    UV_EDESTADDRREQ = -uv.UV_EDESTADDRREQ,
    UV_EEXIST = -uv.UV_EEXIST,
    UV_EFAULT = -uv.UV_EFAULT,
    UV_EFBIG = -uv.UV_EFBIG,
    UV_EHOSTUNREACH = -uv.UV_EHOSTUNREACH,
    UV_EINVAL = -uv.UV_EINVAL,
    UV_EINTR = -uv.UV_EINTR,
    UV_EISCONN = -uv.UV_EISCONN,
    UV_EIO = -uv.UV_EIO,
    UV_ELOOP = -uv.UV_ELOOP,
    UV_EISDIR = -uv.UV_EISDIR,
    UV_EMSGSIZE = -uv.UV_EMSGSIZE,
    UV_EMFILE = -uv.UV_EMFILE,
    UV_ENETDOWN = -uv.UV_ENETDOWN,
    UV_ENAMETOOLONG = -uv.UV_ENAMETOOLONG,
    UV_ENFILE = -uv.UV_ENFILE,
    UV_ENETUNREACH = -uv.UV_ENETUNREACH,
    UV_ENODEV = -uv.UV_ENODEV,
    UV_ENOBUFS = -uv.UV_ENOBUFS,
    UV_ENOMEM = -uv.UV_ENOMEM,
    UV_ENOENT = -uv.UV_ENOENT,
    UV_ENOPROTOOPT = -uv.UV_ENOPROTOOPT,
    UV_ENONET = -uv.UV_ENONET,
    UV_ENOSYS = -uv.UV_ENOSYS,
    UV_ENOSPC = -uv.UV_ENOSPC,
    UV_ENOTDIR = -uv.UV_ENOTDIR,
    UV_ENOTCONN = -uv.UV_ENOTCONN,
    UV_ENOTSOCK = -uv.UV_ENOTSOCK,
    UV_ENOTEMPTY = -uv.UV_ENOTEMPTY,
    UV_EOVERFLOW = -uv.UV_EOVERFLOW,
    UV_ENOTSUP = -uv.UV_ENOTSUP,
    UV_EPIPE = -uv.UV_EPIPE,
    UV_EPERM = -uv.UV_EPERM,
    UV_EPROTONOSUPPORT = -uv.UV_EPROTONOSUPPORT,
    UV_EPROTO = -uv.UV_EPROTO,
    UV_ERANGE = -uv.UV_ERANGE,
    UV_EPROTOTYPE = -uv.UV_EPROTOTYPE,
    UV_ESHUTDOWN = -uv.UV_ESHUTDOWN,
    UV_EROFS = -uv.UV_EROFS,
    UV_ESRCH = -uv.UV_ESRCH,
    UV_ESPIPE = -uv.UV_ESPIPE,
    UV_ETXTBSY = -uv.UV_ETXTBSY,
    UV_ETIMEDOUT = -uv.UV_ETIMEDOUT,
    UV_UNKNOWN = -uv.UV_UNKNOWN,
    UV_EXDEV = -uv.UV_EXDEV,
    UV_ENXIO = -uv.UV_ENXIO,
    UV_EOF = -uv.UV_EOF,
    UV_EHOSTDOWN = -uv.UV_EHOSTDOWN,
    UV_EMLINK = -uv.UV_EMLINK,
    UV_ENOTTY = -uv.UV_ENOTTY,
    UV_EREMOTEIO = -uv.UV_EREMOTEIO,
    UV_EILSEQ = -uv.UV_EILSEQ,
    UV_EFTYPE = -uv.UV_EFTYPE,
    UV_ENODATA = -uv.UV_ENODATA,
    UV_ESOCKTNOSUPPORT = -uv.UV_ESOCKTNOSUPPORT,
    UV_ERRNO_MAX = -uv.UV_ERRNO_MAX,
    UV_EUNATCH = -uv.UV_EUNATCH,
    UV_ENOEXEC = -uv.UV_ENOEXEC,

    pub const max = 138;

    pub const Error = error{
        EPERM,
        ENOENT,
        ESRCH,
        EINTR,
        EIO,
        ENXIO,
        E2BIG,
        ENOEXEC,
        EBADF,
        ECHILD,
        EAGAIN,
        ENOMEM,
        EACCES,
        EFAULT,
        ENOTBLK,
        EBUSY,
        EEXIST,
        EXDEV,
        ENODEV,
        ENOTDIR,
        EISDIR,
        EINVAL,
        ENFILE,
        EMFILE,
        ENOTTY,
        ETXTBSY,
        EFBIG,
        ENOSPC,
        ESPIPE,
        EROFS,
        EMLINK,
        EPIPE,
        EDOM,
        ERANGE,
        EDEADLK,
        ENAMETOOLONG,
        ENOLCK,
        ENOSYS,
        ENOTEMPTY,
        ELOOP,
        EWOULDBLOCK,
        ENOMSG,
        EIDRM,
        ECHRNG,
        EL2NSYNC,
        EL3HLT,
        EL3RST,
        ELNRNG,
        EUNATCH,
        ENOCSI,
        EL2HLT,
        EBADE,
        EBADR,
        EXFULL,
        ENOANO,
        EBADRQC,
        EBADSLT,
        EDEADLOCK,
        EBFONT,
        ENOSTR,
        ENODATA,
        ETIME,
        ENOSR,
        ENONET,
        ENOPKG,
        EREMOTE,
        ENOLINK,
        EADV,
        ESRMNT,
        ECOMM,
        EPROTO,
        EMULTIHOP,
        EDOTDOT,
        EBADMSG,
        EOVERFLOW,
        ENOTUNIQ,
        EBADFD,
        EREMCHG,
        ELIBACC,
        ELIBBAD,
        ELIBSCN,
        ELIBMAX,
        ELIBEXEC,
        EILSEQ,
        ERESTART,
        ESTRPIPE,
        EUSERS,
        ENOTSOCK,
        EDESTADDRREQ,
        EMSGSIZE,
        EPROTOTYPE,
        ENOPROTOOPT,
        EPROTONOSUPPORT,
        ESOCKTNOSUPPORT,
        ENOTSUP,
        EPFNOSUPPORT,
        EAFNOSUPPORT,
        EADDRINUSE,
        EADDRNOTAVAIL,
        ENETDOWN,
        ENETUNREACH,
        ENETRESET,
        ECONNABORTED,
        ECONNRESET,
        ENOBUFS,
        EISCONN,
        ENOTCONN,
        ESHUTDOWN,
        ETOOMANYREFS,
        ETIMEDOUT,
        ECONNREFUSED,
        EHOSTDOWN,
        EHOSTUNREACH,
        EALREADY,
        EINPROGRESS,
        ESTALE,
        EUCLEAN,
        ENOTNAM,
        ENAVAIL,
        EISNAM,
        EREMOTEIO,
        EDQUOT,
        ENOMEDIUM,
        EMEDIUMTYPE,
        ECANCELED,
        ENOKEY,
        EKEYEXPIRED,
        EKEYREVOKED,
        EKEYREJECTED,
        EOWNERDEAD,
        ENOTRECOVERABLE,
        ERFKILL,
        EHWPOISON,
        EUNKNOWN,
        ECHARSET,
        EOF,
        EFTYPE,
        Unexpected,
    };

    pub inline fn toE(this: SystemErrno) E {
        return @fromBackingInt(@intCast(@backingInt(this)));
    }

    const error_map: [SystemErrno.max]Error = brk: {
        var errors: [SystemErrno.max]Error = undefined;
        errors[@backingInt(SystemErrno.EPERM)] = error.EPERM;
        errors[@backingInt(SystemErrno.ENOENT)] = error.ENOENT;
        errors[@backingInt(SystemErrno.ESRCH)] = error.ESRCH;
        errors[@backingInt(SystemErrno.EINTR)] = error.EINTR;
        errors[@backingInt(SystemErrno.EIO)] = error.EIO;
        errors[@backingInt(SystemErrno.ENXIO)] = error.ENXIO;
        errors[@backingInt(SystemErrno.E2BIG)] = error.E2BIG;
        errors[@backingInt(SystemErrno.ENOEXEC)] = error.ENOEXEC;
        errors[@backingInt(SystemErrno.EBADF)] = error.EBADF;
        errors[@backingInt(SystemErrno.ECHILD)] = error.ECHILD;
        errors[@backingInt(SystemErrno.EAGAIN)] = error.EAGAIN;
        errors[@backingInt(SystemErrno.ENOMEM)] = error.ENOMEM;
        errors[@backingInt(SystemErrno.EACCES)] = error.EACCES;
        errors[@backingInt(SystemErrno.EFAULT)] = error.EFAULT;
        errors[@backingInt(SystemErrno.ENOTBLK)] = error.ENOTBLK;
        errors[@backingInt(SystemErrno.EBUSY)] = error.EBUSY;
        errors[@backingInt(SystemErrno.EEXIST)] = error.EEXIST;
        errors[@backingInt(SystemErrno.EXDEV)] = error.EXDEV;
        errors[@backingInt(SystemErrno.ENODEV)] = error.ENODEV;
        errors[@backingInt(SystemErrno.ENOTDIR)] = error.ENOTDIR;
        errors[@backingInt(SystemErrno.EISDIR)] = error.EISDIR;
        errors[@backingInt(SystemErrno.EINVAL)] = error.EINVAL;
        errors[@backingInt(SystemErrno.ENFILE)] = error.ENFILE;
        errors[@backingInt(SystemErrno.EMFILE)] = error.EMFILE;
        errors[@backingInt(SystemErrno.ENOTTY)] = error.ENOTTY;
        errors[@backingInt(SystemErrno.ETXTBSY)] = error.ETXTBSY;
        errors[@backingInt(SystemErrno.EFBIG)] = error.EFBIG;
        errors[@backingInt(SystemErrno.ENOSPC)] = error.ENOSPC;
        errors[@backingInt(SystemErrno.ESPIPE)] = error.ESPIPE;
        errors[@backingInt(SystemErrno.EROFS)] = error.EROFS;
        errors[@backingInt(SystemErrno.EMLINK)] = error.EMLINK;
        errors[@backingInt(SystemErrno.EPIPE)] = error.EPIPE;
        errors[@backingInt(SystemErrno.EDOM)] = error.EDOM;
        errors[@backingInt(SystemErrno.ERANGE)] = error.ERANGE;
        errors[@backingInt(SystemErrno.EDEADLK)] = error.EDEADLK;
        errors[@backingInt(SystemErrno.ENAMETOOLONG)] = error.ENAMETOOLONG;
        errors[@backingInt(SystemErrno.ENOLCK)] = error.ENOLCK;
        errors[@backingInt(SystemErrno.ENOSYS)] = error.ENOSYS;
        errors[@backingInt(SystemErrno.ENOTEMPTY)] = error.ENOTEMPTY;
        errors[@backingInt(SystemErrno.ELOOP)] = error.ELOOP;
        errors[@backingInt(SystemErrno.EWOULDBLOCK)] = error.EWOULDBLOCK;
        errors[@backingInt(SystemErrno.ENOMSG)] = error.ENOMSG;
        errors[@backingInt(SystemErrno.EIDRM)] = error.EIDRM;
        errors[@backingInt(SystemErrno.ECHRNG)] = error.ECHRNG;
        errors[@backingInt(SystemErrno.EL2NSYNC)] = error.EL2NSYNC;
        errors[@backingInt(SystemErrno.EL3HLT)] = error.EL3HLT;
        errors[@backingInt(SystemErrno.EL3RST)] = error.EL3RST;
        errors[@backingInt(SystemErrno.ELNRNG)] = error.ELNRNG;
        errors[@backingInt(SystemErrno.EUNATCH)] = error.EUNATCH;
        errors[@backingInt(SystemErrno.ENOCSI)] = error.ENOCSI;
        errors[@backingInt(SystemErrno.EL2HLT)] = error.EL2HLT;
        errors[@backingInt(SystemErrno.EBADE)] = error.EBADE;
        errors[@backingInt(SystemErrno.EBADR)] = error.EBADR;
        errors[@backingInt(SystemErrno.EXFULL)] = error.EXFULL;
        errors[@backingInt(SystemErrno.ENOANO)] = error.ENOANO;
        errors[@backingInt(SystemErrno.EBADRQC)] = error.EBADRQC;
        errors[@backingInt(SystemErrno.EBADSLT)] = error.EBADSLT;
        errors[@backingInt(SystemErrno.EDEADLOCK)] = error.EDEADLOCK;
        errors[@backingInt(SystemErrno.EBFONT)] = error.EBFONT;
        errors[@backingInt(SystemErrno.ENOSTR)] = error.ENOSTR;
        errors[@backingInt(SystemErrno.ENODATA)] = error.ENODATA;
        errors[@backingInt(SystemErrno.ETIME)] = error.ETIME;
        errors[@backingInt(SystemErrno.ENOSR)] = error.ENOSR;
        errors[@backingInt(SystemErrno.ENONET)] = error.ENONET;
        errors[@backingInt(SystemErrno.ENOPKG)] = error.ENOPKG;
        errors[@backingInt(SystemErrno.EREMOTE)] = error.EREMOTE;
        errors[@backingInt(SystemErrno.ENOLINK)] = error.ENOLINK;
        errors[@backingInt(SystemErrno.EADV)] = error.EADV;
        errors[@backingInt(SystemErrno.ESRMNT)] = error.ESRMNT;
        errors[@backingInt(SystemErrno.ECOMM)] = error.ECOMM;
        errors[@backingInt(SystemErrno.EPROTO)] = error.EPROTO;
        errors[@backingInt(SystemErrno.EMULTIHOP)] = error.EMULTIHOP;
        errors[@backingInt(SystemErrno.EDOTDOT)] = error.EDOTDOT;
        errors[@backingInt(SystemErrno.EBADMSG)] = error.EBADMSG;
        errors[@backingInt(SystemErrno.EOVERFLOW)] = error.EOVERFLOW;
        errors[@backingInt(SystemErrno.ENOTUNIQ)] = error.ENOTUNIQ;
        errors[@backingInt(SystemErrno.EBADFD)] = error.EBADFD;
        errors[@backingInt(SystemErrno.EREMCHG)] = error.EREMCHG;
        errors[@backingInt(SystemErrno.ELIBACC)] = error.ELIBACC;
        errors[@backingInt(SystemErrno.ELIBBAD)] = error.ELIBBAD;
        errors[@backingInt(SystemErrno.ELIBSCN)] = error.ELIBSCN;
        errors[@backingInt(SystemErrno.ELIBMAX)] = error.ELIBMAX;
        errors[@backingInt(SystemErrno.ELIBEXEC)] = error.ELIBEXEC;
        errors[@backingInt(SystemErrno.EILSEQ)] = error.EILSEQ;
        errors[@backingInt(SystemErrno.ERESTART)] = error.ERESTART;
        errors[@backingInt(SystemErrno.ESTRPIPE)] = error.ESTRPIPE;
        errors[@backingInt(SystemErrno.EUSERS)] = error.EUSERS;
        errors[@backingInt(SystemErrno.ENOTSOCK)] = error.ENOTSOCK;
        errors[@backingInt(SystemErrno.EDESTADDRREQ)] = error.EDESTADDRREQ;
        errors[@backingInt(SystemErrno.EMSGSIZE)] = error.EMSGSIZE;
        errors[@backingInt(SystemErrno.EPROTOTYPE)] = error.EPROTOTYPE;
        errors[@backingInt(SystemErrno.ENOPROTOOPT)] = error.ENOPROTOOPT;
        errors[@backingInt(SystemErrno.EPROTONOSUPPORT)] = error.EPROTONOSUPPORT;
        errors[@backingInt(SystemErrno.ESOCKTNOSUPPORT)] = error.ESOCKTNOSUPPORT;
        errors[@backingInt(SystemErrno.ENOTSUP)] = error.ENOTSUP;
        errors[@backingInt(SystemErrno.EPFNOSUPPORT)] = error.EPFNOSUPPORT;
        errors[@backingInt(SystemErrno.EAFNOSUPPORT)] = error.EAFNOSUPPORT;
        errors[@backingInt(SystemErrno.EADDRINUSE)] = error.EADDRINUSE;
        errors[@backingInt(SystemErrno.EADDRNOTAVAIL)] = error.EADDRNOTAVAIL;
        errors[@backingInt(SystemErrno.ENETDOWN)] = error.ENETDOWN;
        errors[@backingInt(SystemErrno.ENETUNREACH)] = error.ENETUNREACH;
        errors[@backingInt(SystemErrno.ENETRESET)] = error.ENETRESET;
        errors[@backingInt(SystemErrno.ECONNABORTED)] = error.ECONNABORTED;
        errors[@backingInt(SystemErrno.ECONNRESET)] = error.ECONNRESET;
        errors[@backingInt(SystemErrno.ENOBUFS)] = error.ENOBUFS;
        errors[@backingInt(SystemErrno.EISCONN)] = error.EISCONN;
        errors[@backingInt(SystemErrno.ENOTCONN)] = error.ENOTCONN;
        errors[@backingInt(SystemErrno.ESHUTDOWN)] = error.ESHUTDOWN;
        errors[@backingInt(SystemErrno.ETOOMANYREFS)] = error.ETOOMANYREFS;
        errors[@backingInt(SystemErrno.ETIMEDOUT)] = error.ETIMEDOUT;
        errors[@backingInt(SystemErrno.ECONNREFUSED)] = error.ECONNREFUSED;
        errors[@backingInt(SystemErrno.EHOSTDOWN)] = error.EHOSTDOWN;
        errors[@backingInt(SystemErrno.EHOSTUNREACH)] = error.EHOSTUNREACH;
        errors[@backingInt(SystemErrno.EALREADY)] = error.EALREADY;
        errors[@backingInt(SystemErrno.EINPROGRESS)] = error.EINPROGRESS;
        errors[@backingInt(SystemErrno.ESTALE)] = error.ESTALE;
        errors[@backingInt(SystemErrno.EUCLEAN)] = error.EUCLEAN;
        errors[@backingInt(SystemErrno.ENOTNAM)] = error.ENOTNAM;
        errors[@backingInt(SystemErrno.ENAVAIL)] = error.ENAVAIL;
        errors[@backingInt(SystemErrno.EISNAM)] = error.EISNAM;
        errors[@backingInt(SystemErrno.EREMOTEIO)] = error.EREMOTEIO;
        errors[@backingInt(SystemErrno.EDQUOT)] = error.EDQUOT;
        errors[@backingInt(SystemErrno.ENOMEDIUM)] = error.ENOMEDIUM;
        errors[@backingInt(SystemErrno.EMEDIUMTYPE)] = error.EMEDIUMTYPE;
        errors[@backingInt(SystemErrno.ECANCELED)] = error.ECANCELED;
        errors[@backingInt(SystemErrno.ENOKEY)] = error.ENOKEY;
        errors[@backingInt(SystemErrno.EKEYEXPIRED)] = error.EKEYEXPIRED;
        errors[@backingInt(SystemErrno.EKEYREVOKED)] = error.EKEYREVOKED;
        errors[@backingInt(SystemErrno.EKEYREJECTED)] = error.EKEYREJECTED;
        errors[@backingInt(SystemErrno.EOWNERDEAD)] = error.EOWNERDEAD;
        errors[@backingInt(SystemErrno.ENOTRECOVERABLE)] = error.ENOTRECOVERABLE;
        errors[@backingInt(SystemErrno.ERFKILL)] = error.ERFKILL;
        errors[@backingInt(SystemErrno.EHWPOISON)] = error.EHWPOISON;
        errors[@backingInt(SystemErrno.EUNKNOWN)] = error.EUNKNOWN;
        errors[@backingInt(SystemErrno.ECHARSET)] = error.ECHARSET;
        errors[@backingInt(SystemErrno.EOF)] = error.EOF;
        errors[@backingInt(SystemErrno.EFTYPE)] = error.EFTYPE;
        break :brk errors;
    };

    pub fn fromError(err: anyerror) ?SystemErrno {
        return switch (err) {
            error.EPERM => SystemErrno.EPERM,
            error.ENOENT => SystemErrno.ENOENT,
            error.ESRCH => SystemErrno.ESRCH,
            error.EINTR => SystemErrno.EINTR,
            error.EIO => SystemErrno.EIO,
            error.ENXIO => SystemErrno.ENXIO,
            error.E2BIG => SystemErrno.E2BIG,
            error.ENOEXEC => SystemErrno.ENOEXEC,
            error.EBADF => SystemErrno.EBADF,
            error.ECHILD => SystemErrno.ECHILD,
            error.EAGAIN => SystemErrno.EAGAIN,
            error.ENOMEM => SystemErrno.ENOMEM,
            error.EACCES => SystemErrno.EACCES,
            error.EFAULT => SystemErrno.EFAULT,
            error.ENOTBLK => SystemErrno.ENOTBLK,
            error.EBUSY => SystemErrno.EBUSY,
            error.EEXIST => SystemErrno.EEXIST,
            error.EXDEV => SystemErrno.EXDEV,
            error.ENODEV => SystemErrno.ENODEV,
            error.ENOTDIR => SystemErrno.ENOTDIR,
            error.EISDIR => SystemErrno.EISDIR,
            error.EINVAL => SystemErrno.EINVAL,
            error.ENFILE => SystemErrno.ENFILE,
            error.EMFILE => SystemErrno.EMFILE,
            error.ENOTTY => SystemErrno.ENOTTY,
            error.ETXTBSY => SystemErrno.ETXTBSY,
            error.EFBIG => SystemErrno.EFBIG,
            error.ENOSPC => SystemErrno.ENOSPC,
            error.ESPIPE => SystemErrno.ESPIPE,
            error.EROFS => SystemErrno.EROFS,
            error.EMLINK => SystemErrno.EMLINK,
            error.EPIPE => SystemErrno.EPIPE,
            error.EDOM => SystemErrno.EDOM,
            error.ERANGE => SystemErrno.ERANGE,
            error.EDEADLK => SystemErrno.EDEADLK,
            error.ENAMETOOLONG => SystemErrno.ENAMETOOLONG,
            error.ENOLCK => SystemErrno.ENOLCK,
            error.ENOSYS => SystemErrno.ENOSYS,
            error.ENOTEMPTY => SystemErrno.ENOTEMPTY,
            error.ELOOP => SystemErrno.ELOOP,
            error.EWOULDBLOCK => SystemErrno.EWOULDBLOCK,
            error.ENOMSG => SystemErrno.ENOMSG,
            error.EIDRM => SystemErrno.EIDRM,
            error.ECHRNG => SystemErrno.ECHRNG,
            error.EL2NSYNC => SystemErrno.EL2NSYNC,
            error.EL3HLT => SystemErrno.EL3HLT,
            error.EL3RST => SystemErrno.EL3RST,
            error.ELNRNG => SystemErrno.ELNRNG,
            error.EUNATCH => SystemErrno.EUNATCH,
            error.ENOCSI => SystemErrno.ENOCSI,
            error.EL2HLT => SystemErrno.EL2HLT,
            error.EBADE => SystemErrno.EBADE,
            error.EBADR => SystemErrno.EBADR,
            error.EXFULL => SystemErrno.EXFULL,
            error.ENOANO => SystemErrno.ENOANO,
            error.EBADRQC => SystemErrno.EBADRQC,
            error.EBADSLT => SystemErrno.EBADSLT,
            error.EDEADLOCK => SystemErrno.EDEADLOCK,
            error.EBFONT => SystemErrno.EBFONT,
            error.ENOSTR => SystemErrno.ENOSTR,
            error.ENODATA => SystemErrno.ENODATA,
            error.ETIME => SystemErrno.ETIME,
            error.ENOSR => SystemErrno.ENOSR,
            error.ENONET => SystemErrno.ENONET,
            error.ENOPKG => SystemErrno.ENOPKG,
            error.EREMOTE => SystemErrno.EREMOTE,
            error.ENOLINK => SystemErrno.ENOLINK,
            error.EADV => SystemErrno.EADV,
            error.ESRMNT => SystemErrno.ESRMNT,
            error.ECOMM => SystemErrno.ECOMM,
            error.EPROTO => SystemErrno.EPROTO,
            error.EMULTIHOP => SystemErrno.EMULTIHOP,
            error.EDOTDOT => SystemErrno.EDOTDOT,
            error.EBADMSG => SystemErrno.EBADMSG,
            error.EOVERFLOW => SystemErrno.EOVERFLOW,
            error.ENOTUNIQ => SystemErrno.ENOTUNIQ,
            error.EBADFD => SystemErrno.EBADFD,
            error.EREMCHG => SystemErrno.EREMCHG,
            error.ELIBACC => SystemErrno.ELIBACC,
            error.ELIBBAD => SystemErrno.ELIBBAD,
            error.ELIBSCN => SystemErrno.ELIBSCN,
            error.ELIBMAX => SystemErrno.ELIBMAX,
            error.ELIBEXEC => SystemErrno.ELIBEXEC,
            error.EILSEQ => SystemErrno.EILSEQ,
            error.ERESTART => SystemErrno.ERESTART,
            error.ESTRPIPE => SystemErrno.ESTRPIPE,
            error.EUSERS => SystemErrno.EUSERS,
            error.ENOTSOCK => SystemErrno.ENOTSOCK,
            error.EDESTADDRREQ => SystemErrno.EDESTADDRREQ,
            error.EMSGSIZE => SystemErrno.EMSGSIZE,
            error.EPROTOTYPE => SystemErrno.EPROTOTYPE,
            error.ENOPROTOOPT => SystemErrno.ENOPROTOOPT,
            error.EPROTONOSUPPORT => SystemErrno.EPROTONOSUPPORT,
            error.ESOCKTNOSUPPORT => SystemErrno.ESOCKTNOSUPPORT,
            error.ENOTSUP => SystemErrno.ENOTSUP,
            error.EPFNOSUPPORT => SystemErrno.EPFNOSUPPORT,
            error.EAFNOSUPPORT => SystemErrno.EAFNOSUPPORT,
            error.EADDRINUSE => SystemErrno.EADDRINUSE,
            error.EADDRNOTAVAIL => SystemErrno.EADDRNOTAVAIL,
            error.ENETDOWN => SystemErrno.ENETDOWN,
            error.ENETUNREACH => SystemErrno.ENETUNREACH,
            error.ENETRESET => SystemErrno.ENETRESET,
            error.ECONNABORTED => SystemErrno.ECONNABORTED,
            error.ECONNRESET => SystemErrno.ECONNRESET,
            error.ENOBUFS => SystemErrno.ENOBUFS,
            error.EISCONN => SystemErrno.EISCONN,
            error.ENOTCONN => SystemErrno.ENOTCONN,
            error.ESHUTDOWN => SystemErrno.ESHUTDOWN,
            error.ETOOMANYREFS => SystemErrno.ETOOMANYREFS,
            error.ETIMEDOUT => SystemErrno.ETIMEDOUT,
            error.ECONNREFUSED => SystemErrno.ECONNREFUSED,
            error.EHOSTDOWN => SystemErrno.EHOSTDOWN,
            error.EHOSTUNREACH => SystemErrno.EHOSTUNREACH,
            error.EALREADY => SystemErrno.EALREADY,
            error.EINPROGRESS => SystemErrno.EINPROGRESS,
            error.ESTALE => SystemErrno.ESTALE,
            error.EUCLEAN => SystemErrno.EUCLEAN,
            error.ENOTNAM => SystemErrno.ENOTNAM,
            error.ENAVAIL => SystemErrno.ENAVAIL,
            error.EISNAM => SystemErrno.EISNAM,
            error.EREMOTEIO => SystemErrno.EREMOTEIO,
            error.EDQUOT => SystemErrno.EDQUOT,
            error.ENOMEDIUM => SystemErrno.ENOMEDIUM,
            error.EMEDIUMTYPE => SystemErrno.EMEDIUMTYPE,
            error.ECANCELED => SystemErrno.ECANCELED,
            error.ENOKEY => SystemErrno.ENOKEY,
            error.EKEYEXPIRED => SystemErrno.EKEYEXPIRED,
            error.EKEYREVOKED => SystemErrno.EKEYREVOKED,
            error.EKEYREJECTED => SystemErrno.EKEYREJECTED,
            error.EOWNERDEAD => SystemErrno.EOWNERDEAD,
            error.ENOTRECOVERABLE => SystemErrno.ENOTRECOVERABLE,
            error.ERFKILL => SystemErrno.ERFKILL,
            error.EHWPOISON => SystemErrno.EHWPOISON,
            error.EUNKNOWN => SystemErrno.EUNKNOWN,
            error.ECHARSET => SystemErrno.ECHARSET,
            error.EOF => SystemErrno.EOF,
            error.EFTYPE => SystemErrno.EFTYPE,
            else => return null,
        };
    }
    pub fn toError(this: SystemErrno) Error {
        return error_map[@backingInt(this)];
    }

    pub fn fromErrno(code: c_int) ?SystemErrno {
        if (code < 0 or code >= max) return null;
        return @fromBackingInt(@intCast(code));
    }

    fn fromUv(code: c_int) SystemErrno {
        return @fromBackingInt(@intCast(@backingInt(uv.translateUVErrorToE(code))));
    }

    pub fn fromWin32(code: std.os.windows.Win32Error) SystemErrno {
        const raw = @backingInt(code);
        if (raw == @as(u32, @intCast(bun.c.ERROR_INVALID_REPARSE_DATA))) return .ENOENT;
        if (raw > std.math.maxInt(c_int)) return .EUNKNOWN;
        return fromUv(uv.uv_translate_sys_error(@intCast(raw)));
    }

    pub fn fromWinsock(code: bun.windows.WinsockError) SystemErrno {
        return fromUv(uv.uv_translate_sys_error(@backingInt(code)));
    }

    pub fn fromNtStatus(status: std.os.windows.NTSTATUS) SystemErrno {
        return switch (status) {
            .SUCCESS => .SUCCESS,
            .ACCESS_DENIED, .CANNOT_DELETE => .EPERM,
            .INVALID_HANDLE => .EBADF,
            .INVALID_PARAMETER, .OBJECT_NAME_INVALID => .EINVAL,
            .OBJECT_NAME_COLLISION => .EEXIST,
            .FILE_IS_A_DIRECTORY => .EISDIR,
            .OBJECT_PATH_NOT_FOUND, .OBJECT_NAME_NOT_FOUND => .ENOENT,
            .NOT_A_DIRECTORY => .ENOTDIR,
            .RETRY => .EAGAIN,
            .DIRECTORY_NOT_EMPTY => .ENOTEMPTY,
            .FILE_TOO_LARGE => .E2BIG,
            .NOT_SAME_DEVICE => .EXDEV,
            .DELETE_PENDING, .SHARING_VIOLATION => .EBUSY,
            .NOT_IMPLEMENTED, .INVALID_DEVICE_REQUEST, .ILLEGAL_FUNCTION => .ENOTSUP,
            else => fromWin32(bun.windows.RtlNtStatusToDosError(status)),
        };
    }
};

pub const UV_E = struct {
    pub const @"2BIG" = -uv.UV_E2BIG;
    pub const ACCES = -uv.UV_EACCES;
    pub const ADDRINUSE = -uv.UV_EADDRINUSE;
    pub const ADDRNOTAVAIL = -uv.UV_EADDRNOTAVAIL;
    pub const AFNOSUPPORT = -uv.UV_EAFNOSUPPORT;
    pub const AGAIN = -uv.UV_EAGAIN;
    pub const ALREADY = -uv.UV_EALREADY;
    pub const BADF = -uv.UV_EBADF;
    pub const BUSY = -uv.UV_EBUSY;
    pub const CANCELED = -uv.UV_ECANCELED;
    pub const CHARSET = -uv.UV_ECHARSET;
    pub const CONNABORTED = -uv.UV_ECONNABORTED;
    pub const CONNREFUSED = -uv.UV_ECONNREFUSED;
    pub const CONNRESET = -uv.UV_ECONNRESET;
    pub const DESTADDRREQ = -uv.UV_EDESTADDRREQ;
    pub const EXIST = -uv.UV_EEXIST;
    pub const FAULT = -uv.UV_EFAULT;
    pub const HOSTUNREACH = -uv.UV_EHOSTUNREACH;
    pub const INTR = -uv.UV_EINTR;
    pub const INVAL = -uv.UV_EINVAL;
    pub const IO = -uv.UV_EIO;
    pub const ISCONN = -uv.UV_EISCONN;
    pub const ISDIR = -uv.UV_EISDIR;
    pub const LOOP = -uv.UV_ELOOP;
    pub const MFILE = -uv.UV_EMFILE;
    pub const MSGSIZE = -uv.UV_EMSGSIZE;
    pub const NAMETOOLONG = -uv.UV_ENAMETOOLONG;
    pub const NETDOWN = -uv.UV_ENETDOWN;
    pub const NETUNREACH = -uv.UV_ENETUNREACH;
    pub const NFILE = -uv.UV_ENFILE;
    pub const NOBUFS = -uv.UV_ENOBUFS;
    pub const NODEV = -uv.UV_ENODEV;
    pub const NOENT = -uv.UV_ENOENT;
    pub const NOMEM = -uv.UV_ENOMEM;
    pub const NONET = -uv.UV_ENONET;
    pub const NOSPC = -uv.UV_ENOSPC;
    pub const NOSYS = -uv.UV_ENOSYS;
    pub const NOTCONN = -uv.UV_ENOTCONN;
    pub const NOTDIR = -uv.UV_ENOTDIR;
    pub const NOTEMPTY = -uv.UV_ENOTEMPTY;
    pub const NOTSOCK = -uv.UV_ENOTSOCK;
    pub const NOTSUP = -uv.UV_ENOTSUP;
    pub const PERM = -uv.UV_EPERM;
    pub const PIPE = -uv.UV_EPIPE;
    pub const PROTO = -uv.UV_EPROTO;
    pub const PROTONOSUPPORT = -uv.UV_EPROTONOSUPPORT;
    pub const PROTOTYPE = -uv.UV_EPROTOTYPE;
    pub const ROFS = -uv.UV_EROFS;
    pub const SHUTDOWN = -uv.UV_ESHUTDOWN;
    pub const SPIPE = -uv.UV_ESPIPE;
    pub const SRCH = -uv.UV_ESRCH;
    pub const TIMEDOUT = -uv.UV_ETIMEDOUT;
    pub const TXTBSY = -uv.UV_ETXTBSY;
    pub const XDEV = -uv.UV_EXDEV;
    pub const FBIG = -uv.UV_EFBIG;
    pub const NOPROTOOPT = -uv.UV_ENOPROTOOPT;
    pub const RANGE = -uv.UV_ERANGE;
    pub const NXIO = -uv.UV_ENXIO;
    pub const MLINK = -uv.UV_EMLINK;
    pub const HOSTDOWN = -uv.UV_EHOSTDOWN;
    pub const REMOTEIO = -uv.UV_EREMOTEIO;
    pub const NOTTY = -uv.UV_ENOTTY;
    pub const FTYPE = -uv.UV_EFTYPE;
    pub const ILSEQ = -uv.UV_EILSEQ;
    pub const OVERFLOW = -uv.UV_EOVERFLOW;
    pub const SOCKTNOSUPPORT = -uv.UV_ESOCKTNOSUPPORT;
    pub const NODATA = -uv.UV_ENODATA;
    pub const UNATCH = -uv.UV_EUNATCH;
    pub const NOEXEC = -uv.UV_ENOEXEC;
};

const bun = @import("bun");
const std = @import("std");

const uv = bun.windows.libuv;
