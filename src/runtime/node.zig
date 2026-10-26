//! Node.js APIs in Bun. Access this namespace with `bun.api.node`
pub const signal = if (Environment.isWindows) @import("./node/uv_signal_handle_windows.zig") else struct {};
pub const parse_args = @import("./node/util/parse_args.zig");
pub const buffer_bindings = @import("./node/buffer.zig");
pub const assert_bindings = @import("./node/node_assert_binding.zig");
pub const http_bindings = @import("./node/node_http_binding.zig");
pub const net_bindings = @import("./node/node_net_binding.zig");
pub const util_bindings = @import("./node/node_util_binding.zig");
pub const zlib_bindings = @import("./node/node_zlib_binding.zig");

/// node:fs
pub const fs = @import("./node/node_fs.zig");
/// node:path
pub const path = @import("./node/path.zig");
/// node:crypto
/// node:os
pub const os = @import("./node/node_os.zig");
/// node:process
pub const process = @import("./node/node_process.zig");
pub const ErrorCode = @import("./node/nodejs_error_code.zig").Code;

pub const PathOrBlob = @import("./node/PathOrBlob.zig").WithBlob(bun.webcore.Blob);
pub const Dirent = types.Dirent;
pub const FileSystemFlags = types.FileSystemFlags;
pub const PathOrFileDescriptor = types.PathOrFileDescriptor;
pub const PathLike = types.PathLike;
pub const CallbackTask = types.CallbackTask;
pub const jsAssertEncodingValid = types.jsAssertEncodingValid;
pub const Encoding = types.Encoding;
pub const NodeBuffer = types.NodeBuffer;
pub const StringOrBuffer = types.StringOrBuffer;
pub const BlobOrStringOrBuffer = types.BlobOrStringOrBuffer;

pub const FSEvents = @import("./node/fs_events.zig");
pub const Stats = stat.Stats;
pub const StatsBig = stat.StatsBig;
pub const StatsSmall = stat.StatsSmall;

pub const StatFSSmall = statfs.StatFSSmall;
pub const StatFSBig = statfs.StatFSBig;
pub const StatFS = statfs.StatFS;

pub const uid_t = if (Environment.isPosix) std.posix.uid_t else bun.windows.libuv.uv_uid_t;
pub const gid_t = if (Environment.isPosix) std.posix.gid_t else bun.windows.libuv.uv_gid_t;

pub const time_like = @import("./node/time_like.zig");
pub const TimeLike = time_like.TimeLike;

/// Node.js expects the error to include contextual information
/// - "syscall"
/// - "path"
/// - "errno"
///
/// We can't really use Zig's error handling for syscalls because Node.js expects the "real" errno to be returned
/// and various issues with std.posix that make it too unstable for arbitrary user input (e.g. how .BADF is marked as unreachable)
pub fn Maybe(comptime ReturnType: type, comptime ErrorType: type) type {
    return SysMaybe(sys, ReturnType, ErrorType);
}

pub const stat = @import("./node/Stat.zig");
const statfs = @import("./node/StatFS.zig");
pub const types = @import("./node/types.zig");

const bun = @import("bun");
const Environment = bun.Environment;
const sys = bun.sys;
const SysMaybe = @import("../sys/Maybe.zig").Maybe;

const std = @import("std");
