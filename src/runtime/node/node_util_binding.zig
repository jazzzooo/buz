pub fn internalErrorName(
    _: bun.bindgen.CallContext(InternalErrorNameSchema),
    args: bun.bindgen.Args(InternalErrorNameSchema),
) bun.JSError!bun.bindgen.DOMString {
    const err_int = args.@"error";

    if (err_int == -4095) return bun.bindgen.DOMString.fromUTF8("EOF");
    if (err_int == -4094) return bun.bindgen.DOMString.fromUTF8("UNKNOWN");
    if (err_int == -3000) return bun.bindgen.DOMString.fromUTF8("EAI_ADDRFAMILY");
    if (err_int == -3001) return bun.bindgen.DOMString.fromUTF8("EAI_AGAIN");
    if (err_int == -3002) return bun.bindgen.DOMString.fromUTF8("EAI_BADFLAGS");
    if (err_int == -3003) return bun.bindgen.DOMString.fromUTF8("EAI_CANCELED");
    if (err_int == -3004) return bun.bindgen.DOMString.fromUTF8("EAI_FAIL");
    if (err_int == -3005) return bun.bindgen.DOMString.fromUTF8("EAI_FAMILY");
    if (err_int == -3006) return bun.bindgen.DOMString.fromUTF8("EAI_MEMORY");
    if (err_int == -3007) return bun.bindgen.DOMString.fromUTF8("EAI_NODATA");
    if (err_int == -3008) return bun.bindgen.DOMString.fromUTF8("EAI_NONAME");
    if (err_int == -3009) return bun.bindgen.DOMString.fromUTF8("EAI_OVERFLOW");
    if (err_int == -3010) return bun.bindgen.DOMString.fromUTF8("EAI_SERVICE");
    if (err_int == -3011) return bun.bindgen.DOMString.fromUTF8("EAI_SOCKTYPE");
    if (err_int == -3013) return bun.bindgen.DOMString.fromUTF8("EAI_BADHINTS");
    if (err_int == -3014) return bun.bindgen.DOMString.fromUTF8("EAI_PROTOCOL");

    if (err_int == -bun.sys.UV_E.@"2BIG") return bun.bindgen.DOMString.fromUTF8("E2BIG");
    if (err_int == -bun.sys.UV_E.ACCES) return bun.bindgen.DOMString.fromUTF8("EACCES");
    if (err_int == -bun.sys.UV_E.ADDRINUSE) return bun.bindgen.DOMString.fromUTF8("EADDRINUSE");
    if (err_int == -bun.sys.UV_E.ADDRNOTAVAIL) return bun.bindgen.DOMString.fromUTF8("EADDRNOTAVAIL");
    if (err_int == -bun.sys.UV_E.AFNOSUPPORT) return bun.bindgen.DOMString.fromUTF8("EAFNOSUPPORT");
    if (err_int == -bun.sys.UV_E.AGAIN) return bun.bindgen.DOMString.fromUTF8("EAGAIN");
    if (err_int == -bun.sys.UV_E.ALREADY) return bun.bindgen.DOMString.fromUTF8("EALREADY");
    if (err_int == -bun.sys.UV_E.BADF) return bun.bindgen.DOMString.fromUTF8("EBADF");
    if (err_int == -bun.sys.UV_E.BUSY) return bun.bindgen.DOMString.fromUTF8("EBUSY");
    if (err_int == -bun.sys.UV_E.CANCELED) return bun.bindgen.DOMString.fromUTF8("ECANCELED");
    if (err_int == -bun.sys.UV_E.CHARSET) return bun.bindgen.DOMString.fromUTF8("ECHARSET");
    if (err_int == -bun.sys.UV_E.CONNABORTED) return bun.bindgen.DOMString.fromUTF8("ECONNABORTED");
    if (err_int == -bun.sys.UV_E.CONNREFUSED) return bun.bindgen.DOMString.fromUTF8("ECONNREFUSED");
    if (err_int == -bun.sys.UV_E.CONNRESET) return bun.bindgen.DOMString.fromUTF8("ECONNRESET");
    if (err_int == -bun.sys.UV_E.DESTADDRREQ) return bun.bindgen.DOMString.fromUTF8("EDESTADDRREQ");
    if (err_int == -bun.sys.UV_E.EXIST) return bun.bindgen.DOMString.fromUTF8("EEXIST");
    if (err_int == -bun.sys.UV_E.FAULT) return bun.bindgen.DOMString.fromUTF8("EFAULT");
    if (err_int == -bun.sys.UV_E.HOSTUNREACH) return bun.bindgen.DOMString.fromUTF8("EHOSTUNREACH");
    if (err_int == -bun.sys.UV_E.INTR) return bun.bindgen.DOMString.fromUTF8("EINTR");
    if (err_int == -bun.sys.UV_E.INVAL) return bun.bindgen.DOMString.fromUTF8("EINVAL");
    if (err_int == -bun.sys.UV_E.IO) return bun.bindgen.DOMString.fromUTF8("EIO");
    if (err_int == -bun.sys.UV_E.ISCONN) return bun.bindgen.DOMString.fromUTF8("EISCONN");
    if (err_int == -bun.sys.UV_E.ISDIR) return bun.bindgen.DOMString.fromUTF8("EISDIR");
    if (err_int == -bun.sys.UV_E.LOOP) return bun.bindgen.DOMString.fromUTF8("ELOOP");
    if (err_int == -bun.sys.UV_E.MFILE) return bun.bindgen.DOMString.fromUTF8("EMFILE");
    if (err_int == -bun.sys.UV_E.MSGSIZE) return bun.bindgen.DOMString.fromUTF8("EMSGSIZE");
    if (err_int == -bun.sys.UV_E.NAMETOOLONG) return bun.bindgen.DOMString.fromUTF8("ENAMETOOLONG");
    if (err_int == -bun.sys.UV_E.NETDOWN) return bun.bindgen.DOMString.fromUTF8("ENETDOWN");
    if (err_int == -bun.sys.UV_E.NETUNREACH) return bun.bindgen.DOMString.fromUTF8("ENETUNREACH");
    if (err_int == -bun.sys.UV_E.NFILE) return bun.bindgen.DOMString.fromUTF8("ENFILE");
    if (err_int == -bun.sys.UV_E.NOBUFS) return bun.bindgen.DOMString.fromUTF8("ENOBUFS");
    if (err_int == -bun.sys.UV_E.NODEV) return bun.bindgen.DOMString.fromUTF8("ENODEV");
    if (err_int == -bun.sys.UV_E.NOENT) return bun.bindgen.DOMString.fromUTF8("ENOENT");
    if (err_int == -bun.sys.UV_E.NOMEM) return bun.bindgen.DOMString.fromUTF8("ENOMEM");
    if (err_int == -bun.sys.UV_E.NONET) return bun.bindgen.DOMString.fromUTF8("ENONET");
    if (err_int == -bun.sys.UV_E.NOSPC) return bun.bindgen.DOMString.fromUTF8("ENOSPC");
    if (err_int == -bun.sys.UV_E.NOSYS) return bun.bindgen.DOMString.fromUTF8("ENOSYS");
    if (err_int == -bun.sys.UV_E.NOTCONN) return bun.bindgen.DOMString.fromUTF8("ENOTCONN");
    if (err_int == -bun.sys.UV_E.NOTDIR) return bun.bindgen.DOMString.fromUTF8("ENOTDIR");
    if (err_int == -bun.sys.UV_E.NOTEMPTY) return bun.bindgen.DOMString.fromUTF8("ENOTEMPTY");
    if (err_int == -bun.sys.UV_E.NOTSOCK) return bun.bindgen.DOMString.fromUTF8("ENOTSOCK");
    if (err_int == -bun.sys.UV_E.NOTSUP) return bun.bindgen.DOMString.fromUTF8("ENOTSUP");
    if (err_int == -bun.sys.UV_E.PERM) return bun.bindgen.DOMString.fromUTF8("EPERM");
    if (err_int == -bun.sys.UV_E.PIPE) return bun.bindgen.DOMString.fromUTF8("EPIPE");
    if (err_int == -bun.sys.UV_E.PROTO) return bun.bindgen.DOMString.fromUTF8("EPROTO");
    if (err_int == -bun.sys.UV_E.PROTONOSUPPORT) return bun.bindgen.DOMString.fromUTF8("EPROTONOSUPPORT");
    if (err_int == -bun.sys.UV_E.PROTOTYPE) return bun.bindgen.DOMString.fromUTF8("EPROTOTYPE");
    if (err_int == -bun.sys.UV_E.ROFS) return bun.bindgen.DOMString.fromUTF8("EROFS");
    if (err_int == -bun.sys.UV_E.SHUTDOWN) return bun.bindgen.DOMString.fromUTF8("ESHUTDOWN");
    if (err_int == -bun.sys.UV_E.SPIPE) return bun.bindgen.DOMString.fromUTF8("ESPIPE");
    if (err_int == -bun.sys.UV_E.SRCH) return bun.bindgen.DOMString.fromUTF8("ESRCH");
    if (err_int == -bun.sys.UV_E.TIMEDOUT) return bun.bindgen.DOMString.fromUTF8("ETIMEDOUT");
    if (err_int == -bun.sys.UV_E.TXTBSY) return bun.bindgen.DOMString.fromUTF8("ETXTBSY");
    if (err_int == -bun.sys.UV_E.XDEV) return bun.bindgen.DOMString.fromUTF8("EXDEV");
    if (err_int == -bun.sys.UV_E.FBIG) return bun.bindgen.DOMString.fromUTF8("EFBIG");
    if (err_int == -bun.sys.UV_E.NOPROTOOPT) return bun.bindgen.DOMString.fromUTF8("ENOPROTOOPT");
    if (err_int == -bun.sys.UV_E.RANGE) return bun.bindgen.DOMString.fromUTF8("ERANGE");
    if (err_int == -bun.sys.UV_E.NXIO) return bun.bindgen.DOMString.fromUTF8("ENXIO");
    if (err_int == -bun.sys.UV_E.MLINK) return bun.bindgen.DOMString.fromUTF8("EMLINK");
    if (err_int == -bun.sys.UV_E.HOSTDOWN) return bun.bindgen.DOMString.fromUTF8("EHOSTDOWN");
    if (err_int == -bun.sys.UV_E.REMOTEIO) return bun.bindgen.DOMString.fromUTF8("EREMOTEIO");
    if (err_int == -bun.sys.UV_E.NOTTY) return bun.bindgen.DOMString.fromUTF8("ENOTTY");
    if (err_int == -bun.sys.UV_E.FTYPE) return bun.bindgen.DOMString.fromUTF8("EFTYPE");
    if (err_int == -bun.sys.UV_E.ILSEQ) return bun.bindgen.DOMString.fromUTF8("EILSEQ");
    if (err_int == -bun.sys.UV_E.OVERFLOW) return bun.bindgen.DOMString.fromUTF8("EOVERFLOW");
    if (err_int == -bun.sys.UV_E.SOCKTNOSUPPORT) return bun.bindgen.DOMString.fromUTF8("ESOCKTNOSUPPORT");
    if (err_int == -bun.sys.UV_E.NODATA) return bun.bindgen.DOMString.fromUTF8("ENODATA");
    if (err_int == -bun.sys.UV_E.UNATCH) return bun.bindgen.DOMString.fromUTF8("EUNATCH");
    if (err_int == -bun.sys.UV_E.NOEXEC) return bun.bindgen.DOMString.fromUTF8("ENOEXEC");

    const fmtstring = bun.handleOom(bun.String.createFormat("Unknown system error {d}", .{err_int}));
    return bun.bindgen.DOMString.fromBunString(fmtstring);
}

pub fn etimedoutErrorCode(
    _: bun.bindgen.CallContext(EtimedoutErrorCodeSchema),
    _: bun.bindgen.Args(EtimedoutErrorCodeSchema),
) bun.JSError!i32 {
    return -bun.sys.UV_E.TIMEDOUT;
}

pub fn enobufsErrorCode(
    _: bun.bindgen.CallContext(EnobufsErrorCodeSchema),
    _: bun.bindgen.Args(EnobufsErrorCodeSchema),
) bun.JSError!i32 {
    return -bun.sys.UV_E.NOBUFS;
}

/// `extractedSplitNewLines` for ASCII/Latin1 strings. Panics if passed a non-string.
/// Returns `undefined` if param is utf8 or utf16 and not fully ascii.
///
/// ```js
/// // util.js
/// const extractedNewLineRe = new RegExp("(?<=\\n)");
/// extractedSplitNewLines = value => RegExpPrototypeSymbolSplit(extractedNewLineRe, value);
/// ```
pub fn extractedSplitNewLinesFastPathStringsOnly(
    _: bun.bindgen.CallContext(SplitNewLinesSchema),
    args: bun.bindgen.Args(SplitNewLinesSchema),
) bun.JSError!bun.bindgen.Return(SplitNewLinesSchema) {
    return switch (args.value.unsafePtr("the generated entry frame owns the string until split copies each line into its result")) {
        .latin1 => |units| try split(.latin1, bun.default_allocator, units),
        .utf16 => |units| try split(.utf16, bun.default_allocator, units),
    };
}

fn split(
    comptime encoding: enum { latin1, utf16 },
    allocator: Allocator,
    buffer: anytype,
) bun.OOM!SplitNewLines {
    var fallback_buffer: [1024]u8 = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&fallback_buffer, allocator);
    const alloc = fallback.allocator();
    const Char = switch (encoding) {
        .latin1 => u8,
        .utf16 => u16,
    };

    var lines: std.ArrayListUnmanaged(bun.String) = .empty;
    defer {
        for (lines.items) |out| {
            out.deref();
        }
        lines.deinit(alloc);
    }

    var it: SplitNewlineIterator(Char) = .{ .buffer = buffer, .index = 0 };
    while (it.next()) |line| {
        const encoded_line = switch (encoding) {
            .latin1 => bun.String.cloneLatin1(line),
            .utf16 => bun.String.cloneUTF16(line),
        };
        errdefer encoded_line.deref();
        try lines.append(alloc, encoded_line);
    }

    return SplitNewLines.fromBunStrings(lines.items);
}

pub fn SplitNewlineIterator(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: ?usize,

        const Self = @This();

        /// Returns a slice of the next field, or null if splitting is complete.
        pub fn next(self: *Self) ?[]const T {
            const start = self.index orelse return null;

            if (std.mem.indexOfScalarPos(T, self.buffer, start, '\n')) |delim_start| {
                const end = delim_start + 1;
                const slice = self.buffer[start..end];
                self.index = end;
                return slice;
            } else {
                self.index = null;
                return self.buffer[start..];
            }
        }
    };
}

pub fn normalizeEncoding(
    _: bun.bindgen.CallContext(NormalizeEncodingSchema),
    args: bun.bindgen.Args(NormalizeEncodingSchema),
) bun.JSError!?bun.bindgen.DOMString {
    const str: bun.TextView = args.input.unsafePtr("the generated entry frame owns the encoding string until lookup finishes comparing it").textView();
    const encoding = if (str.len() == 0)
        NodeTypes.Encoding.utf8
    else if (str.inMapCaseInsensitive(NodeTypes.Encoding.map)) |enc|
        enc
    else
        return null;
    return try bun.bindgen.DOMString.fromUTF8(@tagName(encoding));
}

pub fn parseEnv(
    _: bun.bindgen.CallContext(ParseEnvSchema),
    args: bun.bindgen.Args(ParseEnvSchema),
) bun.JSError!bun.bindgen.Return(ParseEnvSchema) {
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const str = try args.content.toUTF8(allocator);
    defer str.deinit();

    var map = envloader.Map.init(allocator);
    var p = envloader.Loader.init(&map, allocator);
    try p.loadFromString(str.slice(), true, false);

    const Result = bun.bindgen.Return(ParseEnvSchema);
    const values = map.map.values();
    const value_slices = try allocator.alloc([]const u8, values.len);
    for (values, value_slices) |value, *slice| slice.* = value.value;
    return Result.fromUTF8Pairs(map.map.keys(), value_slices);
}

const string = []const u8;

const bun = @import("bun");
const NodeTypes = @import("./types.zig");
const envloader = @import("../../dotenv/env_loader.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const NodeUtilBindings = bun.bindgen.Module("NodeUtil");
const InternalErrorNameSchema = NodeUtilBindings.function("internalErrorName");
const EtimedoutErrorCodeSchema = NodeUtilBindings.function("etimedoutErrorCode");
const EnobufsErrorCodeSchema = NodeUtilBindings.function("enobufsErrorCode");
const SplitNewLinesSchema = NodeUtilBindings.function("splitNewLinesFastPathStringsOnly");
const SplitNewLines = @typeInfo(bun.bindgen.Return(SplitNewLinesSchema)).optional.child;
const NormalizeEncodingSchema = NodeUtilBindings.function("normalizeEncoding");
const ParseEnvSchema = NodeUtilBindings.function("parseEnv");
const InternalErrorNameBinding = bun.bindgen.Fn(InternalErrorNameSchema, internalErrorName);
const EtimedoutErrorCodeBinding = bun.bindgen.Fn(EtimedoutErrorCodeSchema, etimedoutErrorCode);
const EnobufsErrorCodeBinding = bun.bindgen.Fn(EnobufsErrorCodeSchema, enobufsErrorCode);
const SplitNewLinesBinding = bun.bindgen.Fn(SplitNewLinesSchema, extractedSplitNewLinesFastPathStringsOnly);
const NormalizeEncodingBinding = bun.bindgen.Fn(NormalizeEncodingSchema, normalizeEncoding);
const ParseEnvBinding = bun.bindgen.Fn(ParseEnvSchema, parseEnv);

comptime {
    _ = InternalErrorNameBinding;
    _ = EtimedoutErrorCodeBinding;
    _ = EnobufsErrorCodeBinding;
    _ = SplitNewLinesBinding;
    _ = NormalizeEncodingBinding;
    _ = ParseEnvBinding;
}
