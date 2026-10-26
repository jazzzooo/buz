const std = @import("std");
const b = @import("bindgen_schema");
const blob = @import("binding_schema_Blob");
const buffer_host = @import("binding_schema_BufferHost");
const bun_jsc = @import("binding_schema_BunJSCModule");
const global_object = @import("binding_schema_GlobalObjectHost");
const node_util = @import("binding_schema_NodeUtil");
const native_module_host = @import("binding_schema_NativeModuleHost");
const object_url = @import("binding_schema_ObjectURLRegistry");
const webcore_events = @import("binding_schema_WebCoreEvents");

const namespace_member_options = b.SurfaceMemberOptions{ .attributes = .{} };

fn moduleFunctions(comptime module: b.Module, comptime names: anytype) [names.len]b.SurfaceMember {
    var result: [names.len]b.SurfaceMember = undefined;
    inline for (names, 0..) |name, index| {
        result[index] = b.surfaceFunction(name, module.function(name), namespace_member_options);
    }
    return result;
}

fn mappedModuleFunctions(comptime module: b.Module, comptime mappings: anytype) [mappings.len]b.SurfaceMember {
    var result: [mappings.len]b.SurfaceMember = undefined;
    inline for (mappings, 0..) |mapping, index| {
        result[index] = b.surfaceFunction(mapping[0], module.function(mapping[1]), namespace_member_options);
    }
    return result;
}

fn numberMember(
    comptime name: []const u8,
    comptime value: anytype,
    comptime exposure: b.Exposure,
) b.SurfaceMember {
    const options = b.SurfaceMemberOptions{
        .attributes = .{},
        .exposure = exposure,
        .header = "NodeConstantsModule.h",
    };
    if (@TypeOf(value) == comptime_int) return b.surfaceInteger(name, value, options);
    return b.surfaceExternalNumber(name, value, options);
}

fn numberMembers(comptime values: anytype) [values.len]b.SurfaceMember {
    @setEvalBranchQuota(100_000);
    var result: [values.len]b.SurfaceMember = undefined;
    inline for (values, 0..) |value, index| {
        result[index] = numberMember(value[0], value[1], nodeConstantExposure(value[0]));
    }
    return result;
}

fn externalNumberMembers(comptime names: anytype) [names.len]b.SurfaceMember {
    @setEvalBranchQuota(100_000);
    var result: [names.len]b.SurfaceMember = undefined;
    inline for (names, 0..) |name, index| {
        result[index] = numberMember(name, name, nodeConstantExposure(name));
    }
    return result;
}

fn nodeConstantExposure(comptime name: []const u8) b.Exposure {
    return node_constant_exposures.get(name) orelse .always;
}

const non_windows_node_constants = .{
    "RTLD_LAZY",
    "RTLD_NOW",
    "RTLD_GLOBAL",
    "RTLD_LOCAL",
    "EDQUOT",
    "EMULTIHOP",
    "ESTALE",
    "SIGTRAP",
    "SIGIOT",
    "SIGBUS",
    "SIGUSR1",
    "SIGUSR2",
    "SIGPIPE",
    "SIGALRM",
    "SIGCHLD",
    "SIGCONT",
    "SIGSTOP",
    "SIGTSTP",
    "SIGTTIN",
    "SIGTTOU",
    "SIGURG",
    "SIGXCPU",
    "SIGXFSZ",
    "SIGVTALRM",
    "SIGPROF",
    "SIGIO",
    "SIGSYS",
    "S_IFSOCK",
    "O_NOCTTY",
    "O_DIRECTORY",
    "O_NOFOLLOW",
    "O_SYNC",
    "O_DSYNC",
    "O_NONBLOCK",
};

const linux_node_constants = .{
    "RTLD_DEEPBIND",
    "SIGSTKFLT",
    "SIGPOLL",
    "SIGPWR",
    "O_NOATIME",
    "O_DIRECT",
};

const macos_node_constants = .{
    "SIGINFO",
    "O_SYMLINK",
};

const windows_node_constants = .{
    "WSAEINTR",
    "WSAEBADF",
    "WSAEACCES",
    "WSAEFAULT",
    "WSAEINVAL",
    "WSAEMFILE",
    "WSAEWOULDBLOCK",
    "WSAEINPROGRESS",
    "WSAEALREADY",
    "WSAENOTSOCK",
    "WSAEDESTADDRREQ",
    "WSAEMSGSIZE",
    "WSAEPROTOTYPE",
    "WSAENOPROTOOPT",
    "WSAEPROTONOSUPPORT",
    "WSAESOCKTNOSUPPORT",
    "WSAEOPNOTSUPP",
    "WSAEPFNOSUPPORT",
    "WSAEAFNOSUPPORT",
    "WSAEADDRINUSE",
    "WSAEADDRNOTAVAIL",
    "WSAENETDOWN",
    "WSAENETUNREACH",
    "WSAENETRESET",
    "WSAECONNABORTED",
    "WSAECONNRESET",
    "WSAENOBUFS",
    "WSAEISCONN",
    "WSAENOTCONN",
    "WSAESHUTDOWN",
    "WSAETOOMANYREFS",
    "WSAETIMEDOUT",
    "WSAECONNREFUSED",
    "WSAELOOP",
    "WSAENAMETOOLONG",
    "WSAEHOSTDOWN",
    "WSAEHOSTUNREACH",
    "WSAENOTEMPTY",
    "WSAEPROCLIM",
    "WSAEUSERS",
    "WSAEDQUOT",
    "WSAESTALE",
    "WSAEREMOTE",
    "WSASYSNOTREADY",
    "WSAVERNOTSUPPORTED",
    "WSANOTINITIALISED",
    "WSAEDISCON",
    "WSAENOMORE",
    "WSAECANCELLED",
    "WSAEINVALIDPROCTABLE",
    "WSAEINVALIDPROVIDER",
    "WSAEPROVIDERFAILEDINIT",
    "WSASYSCALLFAILURE",
    "WSASERVICE_NOT_FOUND",
    "WSATYPE_NOT_FOUND",
    "WSA_E_NO_MORE",
    "WSA_E_CANCELLED",
    "WSAEREFUSED",
    "SIGBREAK",
};

const ExposureEntry = struct { []const u8, b.Exposure };

fn exposureEntries(comptime names: anytype, comptime exposure: b.Exposure) [names.len]ExposureEntry {
    var result: [names.len]ExposureEntry = undefined;
    inline for (names, 0..) |name, index| result[index] = .{ name, exposure };
    return result;
}

const node_constant_exposures = std.StaticStringMap(b.Exposure).initComptime(
    exposureEntries(non_windows_node_constants, .{ .not_os = "windows" }) ++
        exposureEntries(linux_node_constants, .{ .os = "linux" }) ++
        exposureEntries(macos_node_constants, .{ .os = "macos" }) ++
        exposureEntries(windows_node_constants, .{ .os = "windows" }),
);

const node_buffer_options = b.SurfaceMemberOptions{
    .attributes = .{},
};

fn nodeBufferFunction(comptime name: []const u8, comptime declaration: b.BoundFunction) b.SurfaceMember {
    return b.surfaceFunction(name, declaration, node_buffer_options);
}

fn nodeBufferCppValue(comptime name: []const u8, comptime callback: []const u8) b.SurfaceMember {
    return b.surfaceLazyProperty(name, native_module_host.schema.function(callback), node_buffer_options);
}

const node_buffer_slow_buffer_surface = b.objectSurface("NodeBufferSlowBufferFunction", .{
    b.surfaceLazyProperty("prototype", buffer_host.schema.function("getJSBufferPrototype"), .{
        .attributes = .{ .writable = false, .enumerable = false, .configurable = false },
    }),
}, .{ .installation = .direct });

const node_buffer_constants_surface = b.objectSurface(
    "NodeBufferConstants",
    .{
        b.surfaceExternalNumber("MAX_LENGTH", "NodeBufferMaxLength", .{
            .attributes = .{},
            .header = "NodeBufferModule.h",
        }),
        b.surfaceExternalNumber("MAX_STRING_LENGTH", "NodeBufferMaxStringLength", .{
            .attributes = .{},
            .header = "NodeBufferModule.h",
        }),
    },
    .{ .installation = .direct },
);

const node_buffer_surface = b.objectSurface(
    "NodeBufferModule",
    .{
        b.surfaceLazyProperty("Buffer", buffer_host.schema.function("getJSBufferConstructor"), node_buffer_options),
        b.surfaceCallableValue("SlowBuffer", buffer_host.schema.function("constructSlowBuffer"), node_buffer_slow_buffer_surface, .{
            .attributes = .{},
            .constructable = true,
        }),
        b.surfaceLazyProperty("Blob", blob.blob, node_buffer_options),
        b.surfaceLazyProperty("File", blob.file, node_buffer_options),
        b.surfaceFunctionAccessor(
            "INSPECT_MAX_BYTES",
            buffer_host.schema.function("getInspectMaxBytes"),
            buffer_host.schema.function("setInspectMaxBytes"),
            .{
                .attributes = .{ .configurable = false },
            },
        ),
        b.surfaceExternalNumber("kMaxLength", "NodeBufferMaxLength", .{
            .attributes = .{},
            .header = "NodeBufferModule.h",
        }),
        b.surfaceExternalNumber("kStringMaxLength", "NodeBufferMaxStringLength", .{
            .attributes = .{},
            .header = "NodeBufferModule.h",
        }),
        b.surfaceObjectValue("constants", node_buffer_constants_surface, node_buffer_options),
        nodeBufferFunction("atob", global_object.schema.function("functionATOB")),
        nodeBufferFunction("btoa", global_object.schema.function("functionBTOA")),
        nodeBufferCppValue("transcode", "constructNodeBufferTranscode"),
        nodeBufferFunction("resolveObjectURL", object_url.schema.function("resolve")),
        nodeBufferFunction("isAscii", buffer_host.schema.function("isAscii")),
        nodeBufferFunction("isUtf8", buffer_host.schema.function("isUtf8")),
    },
    .{ .installation = .direct },
);

const node_buffer = b.nativeModule(
    "NodeBuffer",
    "node:buffer",
    node_buffer_surface,
    .{},
);

const node_constant_dlopen_members = externalNumberMembers(.{
    "RTLD_LAZY",
    "RTLD_NOW",
    "RTLD_GLOBAL",
    "RTLD_LOCAL",
    "RTLD_DEEPBIND",
});

const node_constant_errno_members = externalNumberMembers(.{
    "E2BIG",
    "EACCES",
    "EADDRINUSE",
    "EADDRNOTAVAIL",
    "EAFNOSUPPORT",
    "EAGAIN",
    "EALREADY",
    "EBADF",
    "EBADMSG",
    "EBUSY",
    "ECANCELED",
    "ECHILD",
    "ECONNABORTED",
    "ECONNREFUSED",
    "ECONNRESET",
    "EDEADLK",
    "EDESTADDRREQ",
    "EDOM",
    "EDQUOT",
    "EEXIST",
    "EFAULT",
    "EFBIG",
    "EHOSTUNREACH",
    "EIDRM",
    "EILSEQ",
    "EINPROGRESS",
    "EINTR",
    "EINVAL",
    "EIO",
    "EISCONN",
    "EISDIR",
    "ELOOP",
    "EMFILE",
    "EMLINK",
    "EMSGSIZE",
    "EMULTIHOP",
    "ENAMETOOLONG",
    "ENETDOWN",
    "ENETRESET",
    "ENETUNREACH",
    "ENFILE",
    "ENOBUFS",
    "ENODATA",
    "ENODEV",
    "ENOENT",
    "ENOEXEC",
    "ENOLCK",
    "ENOLINK",
    "ENOMEM",
    "ENOMSG",
    "ENOPROTOOPT",
    "ENOSPC",
    "ENOSR",
    "ENOSTR",
    "ENOSYS",
    "ENOTCONN",
    "ENOTDIR",
    "ENOTEMPTY",
    "ENOTSOCK",
    "ENOTSUP",
    "ENOTTY",
    "ENXIO",
    "EOPNOTSUPP",
    "EOVERFLOW",
    "EPERM",
    "EPIPE",
    "EPROTO",
    "EPROTONOSUPPORT",
    "EPROTOTYPE",
    "ERANGE",
    "EROFS",
    "ESPIPE",
    "ESRCH",
    "ESTALE",
    "ETIME",
    "ETIMEDOUT",
    "ETXTBSY",
    "EWOULDBLOCK",
    "EXDEV",
    "WSAEINTR",
    "WSAEBADF",
    "WSAEACCES",
    "WSAEFAULT",
    "WSAEINVAL",
    "WSAEMFILE",
    "WSAEWOULDBLOCK",
    "WSAEINPROGRESS",
    "WSAEALREADY",
    "WSAENOTSOCK",
    "WSAEDESTADDRREQ",
    "WSAEMSGSIZE",
    "WSAEPROTOTYPE",
    "WSAENOPROTOOPT",
    "WSAEPROTONOSUPPORT",
    "WSAESOCKTNOSUPPORT",
    "WSAEOPNOTSUPP",
    "WSAEPFNOSUPPORT",
    "WSAEAFNOSUPPORT",
    "WSAEADDRINUSE",
    "WSAEADDRNOTAVAIL",
    "WSAENETDOWN",
    "WSAENETUNREACH",
    "WSAENETRESET",
    "WSAECONNABORTED",
    "WSAECONNRESET",
    "WSAENOBUFS",
    "WSAEISCONN",
    "WSAENOTCONN",
    "WSAESHUTDOWN",
    "WSAETOOMANYREFS",
    "WSAETIMEDOUT",
    "WSAECONNREFUSED",
    "WSAELOOP",
    "WSAENAMETOOLONG",
    "WSAEHOSTDOWN",
    "WSAEHOSTUNREACH",
    "WSAENOTEMPTY",
    "WSAEPROCLIM",
    "WSAEUSERS",
    "WSAEDQUOT",
    "WSAESTALE",
    "WSAEREMOTE",
    "WSASYSNOTREADY",
    "WSAVERNOTSUPPORTED",
    "WSANOTINITIALISED",
    "WSAEDISCON",
    "WSAENOMORE",
    "WSAECANCELLED",
    "WSAEINVALIDPROCTABLE",
    "WSAEINVALIDPROVIDER",
    "WSAEPROVIDERFAILEDINIT",
    "WSASYSCALLFAILURE",
    "WSASERVICE_NOT_FOUND",
    "WSATYPE_NOT_FOUND",
    "WSA_E_NO_MORE",
    "WSA_E_CANCELLED",
    "WSAEREFUSED",
});

const node_constant_priority_members = numberMembers(.{
    .{ "PRIORITY_LOW", 19 },
    .{ "PRIORITY_BELOW_NORMAL", 10 },
    .{ "PRIORITY_NORMAL", 0 },
    .{ "PRIORITY_ABOVE_NORMAL", -7 },
    .{ "PRIORITY_HIGH", -14 },
    .{ "PRIORITY_HIGHEST", -20 },
});

const node_constant_signal_members = externalNumberMembers(.{
    "SIGHUP",
    "SIGINT",
    "SIGQUIT",
    "SIGILL",
    "SIGTRAP",
    "SIGABRT",
    "SIGIOT",
    "SIGBUS",
    "SIGFPE",
    "SIGKILL",
    "SIGUSR1",
    "SIGSEGV",
    "SIGUSR2",
    "SIGPIPE",
    "SIGALRM",
    "SIGTERM",
    "SIGCHLD",
    "SIGSTKFLT",
    "SIGCONT",
    "SIGSTOP",
    "SIGTSTP",
    "SIGBREAK",
    "SIGTTIN",
    "SIGTTOU",
    "SIGURG",
    "SIGXCPU",
    "SIGXFSZ",
    "SIGVTALRM",
    "SIGPROF",
    "SIGWINCH",
    "SIGIO",
    "SIGPOLL",
    "SIGPWR",
    "SIGINFO",
    "SIGSYS",
});

const node_constant_fs_base_members = numberMembers(.{
    .{ "UV_FS_SYMLINK_DIR", 1 },
    .{ "UV_FS_SYMLINK_JUNCTION", 2 },
    .{ "O_RDONLY", "O_RDONLY" },
    .{ "O_WRONLY", "O_WRONLY" },
    .{ "O_RDWR", "O_RDWR" },
    .{ "UV_DIRENT_UNKNOWN", 0 },
    .{ "UV_DIRENT_FILE", 1 },
    .{ "UV_DIRENT_DIR", 2 },
    .{ "UV_DIRENT_LINK", 3 },
    .{ "UV_DIRENT_FIFO", 4 },
    .{ "UV_DIRENT_SOCKET", 5 },
    .{ "UV_DIRENT_CHAR", 6 },
    .{ "UV_DIRENT_BLOCK", 7 },
    .{ "S_IFMT", "S_IFMT" },
    .{ "S_IFREG", "S_IFREG" },
    .{ "S_IFDIR", "S_IFDIR" },
    .{ "S_IFCHR", "S_IFCHR" },
});

const node_constant_fs_external_members = externalNumberMembers(.{
    "S_IFBLK",
    "S_IFIFO",
    "S_IFLNK",
    "S_IFSOCK",
    "O_CREAT",
    "O_EXCL",
});

const node_constant_file_map_members = [_]b.SurfaceMember{
    numberMember("UV_FS_O_FILEMAP", "UV_FS_O_FILEMAP", .always),
};

const node_constant_open_external_members = externalNumberMembers(.{
    "O_NOCTTY",
    "O_TRUNC",
    "O_APPEND",
    "O_DIRECTORY",
    "O_NOATIME",
    "O_NOFOLLOW",
    "O_SYNC",
    "O_DSYNC",
    "O_SYMLINK",
    "O_DIRECT",
    "O_NONBLOCK",
    "S_IRWXU",
    "S_IRUSR",
    "S_IWUSR",
    "S_IXUSR",
    "S_IRWXG",
    "S_IRGRP",
    "S_IWGRP",
    "S_IXGRP",
    "S_IRWXO",
    "S_IROTH",
    "S_IWOTH",
    "S_IXOTH",
    "F_OK",
    "R_OK",
    "W_OK",
    "X_OK",
});

const node_constant_copyfile_members = numberMembers(.{
    .{ "UV_FS_COPYFILE_EXCL", 1 },
    .{ "COPYFILE_EXCL", 1 },
    .{ "UV_FS_COPYFILE_FICLONE", 2 },
    .{ "COPYFILE_FICLONE", 2 },
    .{ "UV_FS_COPYFILE_FICLONE_FORCE", 4 },
    .{ "COPYFILE_FICLONE_FORCE", 4 },
});

const node_constant_ssl_members = numberMembers(.{
    .{ "OPENSSL_VERSION_NUMBER", "OPENSSL_VERSION_NUMBER" },
    .{ "SSL_OP_ALL", "SSL_OP_ALL" },
    .{ "SSL_OP_ALLOW_NO_DHE_KEX", 0 },
    .{ "SSL_OP_ALLOW_UNSAFE_LEGACY_RENEGOTIATION", "SSL_OP_ALLOW_UNSAFE_LEGACY_RENEGOTIATION" },
    .{ "SSL_OP_CIPHER_SERVER_PREFERENCE", "SSL_OP_CIPHER_SERVER_PREFERENCE" },
    .{ "SSL_OP_CISCO_ANYCONNECT", 0 },
    .{ "SSL_OP_COOKIE_EXCHANGE", 0 },
    .{ "SSL_OP_CRYPTOPRO_TLSEXT_BUG", 0 },
    .{ "SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS", "SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS" },
    .{ "SSL_OP_LEGACY_SERVER_CONNECT", "SSL_OP_LEGACY_SERVER_CONNECT" },
    .{ "SSL_OP_NO_COMPRESSION", "SSL_OP_NO_COMPRESSION" },
    .{ "SSL_OP_NO_ENCRYPT_THEN_MAC", 0 },
    .{ "SSL_OP_NO_QUERY_MTU", "SSL_OP_NO_QUERY_MTU" },
    .{ "SSL_OP_NO_RENEGOTIATION", "SSL_OP_NO_RENEGOTIATION" },
    .{ "SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION", "SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION" },
    .{ "SSL_OP_NO_SSLv2", "SSL_OP_NO_SSLv2" },
    .{ "SSL_OP_NO_SSLv3", "SSL_OP_NO_SSLv3" },
    .{ "SSL_OP_NO_TICKET", "SSL_OP_NO_TICKET" },
    .{ "SSL_OP_NO_TLSv1", "SSL_OP_NO_TLSv1" },
    .{ "SSL_OP_NO_TLSv1_1", "SSL_OP_NO_TLSv1_1" },
    .{ "SSL_OP_NO_TLSv1_2", "SSL_OP_NO_TLSv1_2" },
    .{ "SSL_OP_NO_TLSv1_3", "SSL_OP_NO_TLSv1_3" },
    .{ "SSL_OP_PRIORITIZE_CHACHA", 0 },
    .{ "SSL_OP_TLS_ROLLBACK_BUG", "SSL_OP_TLS_ROLLBACK_BUG" },
});

const node_constant_engine_members = numberMembers(.{
    .{ "ENGINE_METHOD_RSA", 0x0001 },
    .{ "ENGINE_METHOD_DSA", 0x0002 },
    .{ "ENGINE_METHOD_DH", 0x0004 },
    .{ "ENGINE_METHOD_RAND", 0x0008 },
    .{ "ENGINE_METHOD_EC", 0x0800 },
    .{ "ENGINE_METHOD_CIPHERS", 0x0040 },
    .{ "ENGINE_METHOD_DIGESTS", 0x0080 },
    .{ "ENGINE_METHOD_PKEY_METHS", 0x0200 },
    .{ "ENGINE_METHOD_PKEY_ASN1_METHS", 0x0400 },
    .{ "ENGINE_METHOD_ALL", 0xffff },
    .{ "ENGINE_METHOD_NONE", 0x0000 },
});

const node_constant_crypto_members = numberMembers(.{
    .{ "DH_CHECK_P_NOT_SAFE_PRIME", "DH_CHECK_P_NOT_SAFE_PRIME" },
    .{ "DH_CHECK_P_NOT_PRIME", "DH_CHECK_P_NOT_PRIME" },
    .{ "DH_UNABLE_TO_CHECK_GENERATOR", "DH_UNABLE_TO_CHECK_GENERATOR" },
    .{ "DH_NOT_SUITABLE_GENERATOR", "DH_NOT_SUITABLE_GENERATOR" },
    .{ "RSA_PKCS1_PADDING", "RSA_PKCS1_PADDING" },
    .{ "RSA_SSLV23_PADDING", 2 },
    .{ "RSA_NO_PADDING", "RSA_NO_PADDING" },
    .{ "RSA_PKCS1_OAEP_PADDING", "RSA_PKCS1_OAEP_PADDING" },
    .{ "RSA_X931_PADDING", 5 },
    .{ "RSA_PKCS1_PSS_PADDING", "RSA_PKCS1_PSS_PADDING" },
    .{ "RSA_PSS_SALTLEN_DIGEST", "RSA_PSS_SALTLEN_DIGEST" },
    .{ "RSA_PSS_SALTLEN_MAX_SIGN", -2 },
    .{ "RSA_PSS_SALTLEN_AUTO", "RSA_PSS_SALTLEN_AUTO" },
});

const node_constant_cipher_members = [_]b.SurfaceMember{
    b.surfaceString("defaultCoreCipherList", "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384:DHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA256:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!SRP:!CAMELLIA", .{
        .attributes = .{},
        .aliases = &.{b.surfaceAlias("defaultCipherList", .{})},
    }),
};

const node_constant_tls_members = externalNumberMembers(.{
    "TLS1_VERSION",
    "TLS1_1_VERSION",
    "TLS1_2_VERSION",
    "TLS1_3_VERSION",
});

const node_constant_point_members = numberMembers(.{
    .{ "POINT_CONVERSION_COMPRESSED", "POINT_CONVERSION_COMPRESSED" },
    .{ "POINT_CONVERSION_UNCOMPRESSED", "POINT_CONVERSION_UNCOMPRESSED" },
    .{ "POINT_CONVERSION_HYBRID", "POINT_CONVERSION_HYBRID" },
});

const process_binding_constants_dlopen_surface = b.objectSurface(
    "ProcessBindingConstantsDlopen",
    node_constant_dlopen_members,
    .{ .installation = .direct, .prototype = .null },
);

const process_binding_constants_errno_surface = b.objectSurface(
    "ProcessBindingConstantsErrno",
    node_constant_errno_members,
    .{ .installation = .direct, .prototype = .null },
);

const process_binding_constants_signals_surface = b.objectSurface(
    "ProcessBindingConstantsSignals",
    node_constant_signal_members,
    .{ .installation = .direct, .prototype = .null },
);

const process_binding_constants_priority_surface = b.objectSurface(
    "ProcessBindingConstantsPriority",
    node_constant_priority_members,
    .{ .installation = .direct, .prototype = .null },
);

pub const process_binding_constants_os_surface = b.objectSurface(
    "ProcessBindingConstantsOs",
    numberMembers(.{.{ "UV_UDP_REUSEADDR", 4 }}) ++ .{
        b.surfaceObjectValue("dlopen", process_binding_constants_dlopen_surface, namespace_member_options),
        b.surfaceObjectValue("errno", process_binding_constants_errno_surface, namespace_member_options),
        b.surfaceObjectValue("signals", process_binding_constants_signals_surface, namespace_member_options),
        b.surfaceObjectValue("priority", process_binding_constants_priority_surface, namespace_member_options),
    },
    .{ .installation = .direct, .prototype = .null },
);

pub const process_binding_constants_fs_surface = b.objectSurface(
    "ProcessBindingConstantsFs",
    node_constant_fs_base_members ++
        node_constant_fs_external_members ++
        node_constant_file_map_members ++
        node_constant_open_external_members ++
        node_constant_copyfile_members ++
        numberMembers(.{
            .{ "EXTENSIONLESS_FORMAT_JAVASCRIPT", 0 },
            .{ "EXTENSIONLESS_FORMAT_WASM", 1 },
        }),
    .{ .installation = .direct, .prototype = .null },
);

const process_binding_constants_obsolete_ssl_members = numberMembers(.{
    .{ "SSL_OP_MICROSOFT_SESS_ID_BUG", 0 },
    .{ "SSL_OP_NETSCAPE_CHALLENGE_BUG", 0 },
    .{ "SSL_OP_NETSCAPE_REUSE_CIPHER_CHANGE_BUG", 0 },
    .{ "SSL_OP_SSLREF2_REUSE_CERT_TYPE_BUG", 0 },
    .{ "SSL_OP_MICROSOFT_BIG_SSLV3_BUFFER", 0 },
    .{ "SSL_OP_MSIE_SSLV2_RSA_PADDING", 0 },
    .{ "SSL_OP_SSLEAY_080_CLIENT_DH_BUG", 0 },
    .{ "SSL_OP_TLS_D5_BUG", 0 },
    .{ "SSL_OP_TLS_BLOCK_PADDING_BUG", 0 },
    .{ "SSL_OP_SINGLE_ECDH_USE", 0 },
    .{ "SSL_OP_SINGLE_DH_USE", 0 },
    .{ "SSL_OP_EPHEMERAL_RSA", 0 },
    .{ "SSL_OP_PKCS1_CHECK_1", 0 },
    .{ "SSL_OP_PKCS1_CHECK_2", 0 },
    .{ "SSL_OP_NETSCAPE_CA_DN_BUG", 0 },
    .{ "SSL_OP_NETSCAPE_DEMO_CIPHER_CHANGE_BUG", 0 },
});

pub const process_binding_constants_crypto_surface = b.objectSurface(
    "ProcessBindingConstantsCrypto",
    node_constant_ssl_members ++
        process_binding_constants_obsolete_ssl_members ++
        node_constant_engine_members ++
        node_constant_crypto_members ++
        node_constant_cipher_members ++
        node_constant_tls_members ++
        node_constant_point_members,
    .{ .installation = .direct, .prototype = .null },
);

const node_constants_surface = b.objectSurface(
    "NodeConstantsModule",
    node_constant_dlopen_members ++
        node_constant_errno_members ++
        node_constant_priority_members ++
        node_constant_signal_members ++
        node_constant_fs_base_members ++
        node_constant_fs_external_members ++
        node_constant_file_map_members ++
        node_constant_open_external_members ++
        node_constant_copyfile_members ++
        node_constant_ssl_members ++
        node_constant_engine_members ++
        node_constant_crypto_members ++
        node_constant_cipher_members ++
        node_constant_tls_members ++
        node_constant_point_members,
    .{ .installation = .direct },
);

const node_constants = b.nativeModule("NodeConstants", "node:constants", node_constants_surface, .{});

const node_util_types_surface = b.objectSurface(
    "NodeUtilTypesModule",
    moduleFunctions(node_util.schema, .{
        "isExternal",
        "isDate",
        "isArgumentsObject",
        "isBigIntObject",
        "isBooleanObject",
        "isNumberObject",
        "isStringObject",
        "isSymbolObject",
        "isNativeError",
        "isRegExp",
        "isAsyncFunction",
        "isGeneratorFunction",
        "isGeneratorObject",
        "isPromise",
        "isMap",
        "isSet",
        "isMapIterator",
        "isSetIterator",
        "isWeakMap",
        "isWeakSet",
        "isArrayBuffer",
        "isDataView",
        "isSharedArrayBuffer",
        "isProxy",
        "isModuleNamespaceObject",
        "isAnyArrayBuffer",
        "isBoxedPrimitive",
        "isArrayBufferView",
        "isTypedArray",
        "isUint8Array",
        "isUint8ClampedArray",
        "isUint16Array",
        "isUint32Array",
        "isInt8Array",
        "isInt16Array",
        "isInt32Array",
        "isFloat16Array",
        "isFloat32Array",
        "isFloat64Array",
        "isBigInt64Array",
        "isBigUint64Array",
        "isKeyObject",
        "isCryptoKey",
        "isEventTarget",
    }),
    .{ .installation = .direct },
);

const node_util_types = b.nativeModule(
    "NodeUtilTypes",
    "node:util/types",
    node_util_types_surface,
    .{},
);

const bun_jsc_object_surface = b.objectSurface(
    "BunJSCModule",
    mappedModuleFunctions(bun_jsc.schema, .{
        .{ "callerSourceOrigin", "callerSourceOrigin" },
        .{ "jscDescribe", "jscDescribe" },
        .{ "describe", "jscDescribe" },
        .{ "jscDescribeArray", "jscDescribeArray" },
        .{ "describeArray", "jscDescribeArray" },
        .{ "drainMicrotasks", "drainMicrotasks" },
        .{ "edenGC", "edenGC" },
        .{ "fullGC", "fullGC" },
        .{ "gcAndSweep", "gcAndSweep" },
        .{ "getRandomSeed", "getRandomSeed" },
        .{ "heapSize", "heapSize" },
        .{ "heapStats", "heapStats" },
        .{ "startSamplingProfiler", "startSamplingProfiler" },
        .{ "samplingProfilerStackTraces", "samplingProfilerStackTraces" },
        .{ "noInline", "noInline" },
        .{ "isRope", "isRope" },
        .{ "memoryUsage", "memoryUsage" },
        .{ "noFTL", "noFTL" },
        .{ "noOSRExitFuzzing", "noOSRExitFuzzing" },
        .{ "numberOfDFGCompiles", "numberOfDFGCompiles" },
        .{ "optimizeNextInvocation", "optimizeNextInvocation" },
        .{ "releaseWeakRefs", "releaseWeakRefs" },
        .{ "reoptimizationRetryCount", "reoptimizationRetryCount" },
        .{ "setRandomSeed", "setRandomSeed" },
        .{ "startRemoteDebugger", "startRemoteDebugger" },
        .{ "totalCompileTime", "totalCompileTime" },
        .{ "getProtectedObjects", "getProtectedObjects" },
        .{ "generateHeapSnapshotForDebugging", "generateHeapSnapshotForDebugging" },
        .{ "profile", "profile" },
        .{ "codeCoverageForFile", "codeCoverageForFile" },
        .{ "setTimeZone", "setTimeZone" },
        .{ "setTimezone", "setTimeZone" },
        .{ "serialize", "serialize" },
        .{ "deserialize", "deserialize" },
        .{ "estimateShallowMemoryUsageOf", "estimateShallowMemoryUsageOf" },
        .{ "percentAvailableMemoryInUse", "percentAvailableMemoryInUse" },
    }),
    .{ .installation = .direct },
);

const bun_jsc_surface = b.nativeModule(
    "BunJSC",
    "bun:jsc",
    bun_jsc_object_surface,
    .{},
);

const utf8_validate = b.nativeModule(
    "UTF8Validate",
    "utf-8-validate",
    .{},
    .{
        .default = .{ .declaration = .{ .function = buffer_host.schema.function("isUtf8") } },
        .default_name = "utf8Validate",
    },
);

const bun_app_surface = b.objectSurface(
    "BunAppModule",
    .{b.surfaceLazyProperty("Response", native_module_host.schema.function("constructBunAppResponse"), .{
        .attributes = .{},
    })},
    .{ .installation = .direct },
);

const bun_app = b.nativeModule("BunApp", "bun:app", bun_app_surface, .{});

const node_string_decoder_surface = b.objectSurface(
    "NodeStringDecoderModule",
    .{b.surfaceLazyProperty("StringDecoder", native_module_host.schema.function("constructNodeStringDecoder"), .{
        .attributes = .{},
    })},
    .{ .installation = .direct },
);

const node_string_decoder = b.nativeModule("NodeStringDecoder", "node:string_decoder", node_string_decoder_surface, .{});

const abort_controller_surface = b.objectSurface(
    "AbortControllerModule",
    .{
        b.surfaceLazyProperty("AbortSignal", webcore_events.abort_signal, .{ .attributes = .{ .configurable = false } }),
        b.surfaceLazyProperty("AbortController", webcore_events.abort_controller, .{ .attributes = .{ .configurable = false } }),
        b.surfaceBoolean("__esModule", true, .{ .attributes = .{} }),
    },
    .{ .installation = .direct },
);

const abort_controller = b.nativeModule(
    "AbortControllerModule",
    "abort-controller",
    abort_controller_surface,
    .{
        .default = .{ .declaration = .{ .class = webcore_events.abort_controller } },
        .default_surface = .install,
        .attach_default_to_default = true,
        .default_attributes = .{ .configurable = false },
    },
);

pub const schema = b.moduleWithSurfaces("NativeModules", .{
    bun_jsc_surface,
    bun_app,
    node_buffer_constants_surface,
    node_buffer_slow_buffer_surface,
    node_buffer_surface,
    node_buffer,
    process_binding_constants_dlopen_surface,
    process_binding_constants_errno_surface,
    process_binding_constants_signals_surface,
    process_binding_constants_priority_surface,
    process_binding_constants_os_surface,
    process_binding_constants_fs_surface,
    process_binding_constants_crypto_surface,
    node_constants,
    node_string_decoder,
    node_util_types,
    utf8_validate,
    abort_controller,
});
