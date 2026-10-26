pub const BlobOrStringOrBuffer = union(enum) {
    blob: @import("../webcore/blob/SharedBytes.zig"),
    string_or_buffer: StringOrBuffer,

    pub fn deinit(this: *const BlobOrStringOrBuffer) void {
        switch (this.*) {
            .blob => |blob| {
                var owned = blob;
                owned.deinit();
            },
            .string_or_buffer => |*str| {
                str.deinit();
            },
        }
    }

    pub fn slice(this: *const BlobOrStringOrBuffer) []const u8 {
        return switch (this.*) {
            .blob => |*blob| blob.slice(),
            .string_or_buffer => |*str| str.slice(),
        };
    }

    pub fn byteLength(this: *const BlobOrStringOrBuffer) usize {
        return this.slice().len;
    }

    pub fn fromBindgen(value: anytype, encoding: Encoding) bun.JSError!BlobOrStringOrBuffer {
        return switch (value) {
            .blob => |view| blob: {
                const blob = view.get();
                break :blob .{ .blob = blob.retainBytes() };
            },
            .buffer => |view| .{ .string_or_buffer = try StringOrBuffer.fromBindgenBuffer(view) },
            .string => |view| .{ .string_or_buffer = try StringOrBuffer.fromBindgenString(view, encoding) },
        };
    }
};

pub const NodeBuffer = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    pub const empty: NodeBuffer = .{ .borrowed = "" };

    pub fn borrow(bytes: []const u8) NodeBuffer {
        return .{ .borrowed = bytes };
    }

    pub fn adoptDefault(bytes: []u8) NodeBuffer {
        return if (bytes.len == 0) empty else .{ .owned = bytes };
    }

    pub fn copy(bytes: []const u8) bun.OOM!NodeBuffer {
        if (bytes.len == 0) return empty;
        return .{ .owned = try bun.default_allocator.dupe(u8, bytes) };
    }

    pub fn slice(this: *const NodeBuffer) []const u8 {
        return switch (this.*) {
            .borrowed => |bytes| bytes,
            .owned => |bytes| bytes,
        };
    }

    pub fn takeDefaultOwned(this: *NodeBuffer) ?[]u8 {
        return switch (this.*) {
            .borrowed => null,
            .owned => |bytes| {
                this.* = empty;
                return bytes;
            },
        };
    }

    pub fn deinit(this: *NodeBuffer) void {
        switch (this.*) {
            .borrowed => {},
            .owned => |bytes| bun.default_allocator.free(bytes),
        }
        this.* = empty;
    }
};

pub const StringOrBuffer = union(enum) {
    string: bun.SliceWithUnderlyingString,
    threadsafe_string: bun.SliceWithUnderlyingString,
    encoded_slice: bun.String.Slice,
    buffer: NodeBuffer,
    binding_lease: bun.bindgen.OwnedLease(u8),

    pub const empty = StringOrBuffer{ .encoded_slice = bun.String.Slice.empty };

    pub fn toThreadSafe(this: *@This()) bun.OOM!void {
        if (this.* == .buffer and this.buffer == .owned) return;
        const buffer = try NodeBuffer.copy(this.slice());
        this.deinit();
        this.* = .{ .buffer = buffer };
    }

    pub fn slice(this: *const StringOrBuffer) []const u8 {
        return switch (this.*) {
            .binding_lease => |*lease| lease.unsafePtr("StringOrBuffer owns the lease while its bytes are in use"),
            inline else => |*str| str.slice(),
        };
    }

    pub fn deinit(this: *const StringOrBuffer) void {
        switch (this.*) {
            inline .threadsafe_string, .string => |*str| {
                str.deinit();
            },
            .encoded_slice => |*encoded| {
                encoded.deinit();
            },
            .binding_lease => |lease| {
                var owned = lease;
                owned.deinit();
            },
            .buffer => |buffer| {
                var owned = buffer;
                owned.deinit();
            },
        }
    }

    pub fn fromBindgen(value: anytype, encoding: Encoding) bun.OOM!StringOrBuffer {
        return switch (value) {
            .buffer => |view| fromBindgenBuffer(view),
            .string => |view| fromBindgenString(view, encoding),
        };
    }

    pub fn fromBindgenBuffer(view: anytype) bun.OOM!StringOrBuffer {
        return .{ .binding_lease = try view.toOwned() };
    }

    pub fn fromBindgenString(view: anytype, encoding: Encoding) bun.OOM!StringOrBuffer {
        var owned = view.toOwned();
        var bun_string = owned.takeBunString();
        defer bun_string.deref();

        if (encoding != .utf8 and !bun_string.isEmpty()) {
            return .{
                .encoded_slice = bun.String.Slice.init(bun.default_allocator, try bun_string.encode(encoding)),
            };
        }

        var sliced = try bun_string.toThreadSafeSlice(bun.default_allocator);
        if (sliced.underlying.isEmpty()) {
            return .{ .encoded_slice = sliced.utf8 };
        }
        return .{ .threadsafe_string = sliced };
    }
};

/// https://github.com/nodejs/node/blob/master/lib/buffer.js#L587
/// See `webcore.encoding` for encoding and decoding functions.
/// must match src/jsc/bindings/BufferEncodingType.h
pub const Encoding = enum(u8) {
    utf8,
    ucs2,
    utf16le,
    latin1,
    ascii,
    base64,
    base64url,
    hex,

    /// Refer to the buffer's encoding
    buffer,

    pub const map = bun.ComptimeStringMap(Encoding, .{
        .{ "utf-8", Encoding.utf8 },
        .{ "utf8", Encoding.utf8 },
        .{ "ucs-2", Encoding.utf16le },
        .{ "ucs2", Encoding.utf16le },
        .{ "utf-16le", Encoding.utf16le },
        .{ "utf16le", Encoding.utf16le },
        .{ "binary", Encoding.latin1 },
        .{ "latin1", Encoding.latin1 },
        .{ "ascii", Encoding.ascii },
        .{ "base64", Encoding.base64 },
        .{ "hex", Encoding.hex },
        .{ "buffer", Encoding.buffer },
        .{ "base64url", Encoding.base64url },
    });

    /// Caller must verify the value is a string
    pub fn from(slice: []const u8) ?Encoding {
        return strings.inMapCaseInsensitive(slice, map);
    }

    pub fn fromBindgen(value: anytype) Encoding {
        if (comptime @hasField(@TypeOf(value), "buffer")) {
            return switch (value) {
                .utf8 => .utf8,
                .utf16le => .utf16le,
                .latin1 => .latin1,
                .ascii => .ascii,
                .base64 => .base64,
                .base64url => .base64url,
                .hex => .hex,
                .buffer => .buffer,
            };
        }
        return switch (value) {
            .utf8 => .utf8,
            .utf16le => .utf16le,
            .latin1 => .latin1,
            .ascii => .ascii,
            .base64 => .base64,
            .base64url => .base64url,
            .hex => .hex,
        };
    }
};

/// This is used on the windows implementation of realpath, which is in javascript
pub fn jsAssertEncodingValid(
    _: bun.bindgen.CallContext(AssertEncodingValidSchema),
    _: bun.bindgen.Args(AssertEncodingValidSchema),
) bun.JSError!void {}

pub const PathLike = PathModule.PathLike;
pub const PathOrFileDescriptor = PathModule.PathOrFileDescriptor;

pub const FileSystemFlags = enum(c_int) {
    pub const tag_type = @typeInfo(FileSystemFlags).@"enum".tag_type;
    const O = bun.O;

    /// Open file for appending. The file is created if it does not exist.
    a = O.APPEND | O.WRONLY | O.CREAT,
    /// Open file for reading. An exception occurs if the file does not exist.
    r = O.RDONLY,
    /// Open file for writing. The file is created (if it does not exist) or truncated (if it exists).
    w = O.WRONLY | O.CREAT,

    _,

    pub fn asInt(flags: FileSystemFlags) tag_type {
        return @backingInt(flags);
    }
};

/// A class representing a directory stream.
///
/// Created by {@link opendir}, {@link opendirSync}, or `fsPromises.opendir()`.
///
/// ```js
/// import { opendir } from 'fs/promises';
///
/// try {
///   const dir = await opendir('./');
///   for await (const dirent of dir)
///     console.log(dirent.name);
/// } catch (err) {
///   console.error(err);
/// }
/// ```
///
/// When using the async iterator, the `fs.Dir` object will be automatically
/// closed after the iterator exits.
/// @since v12.12.0
pub const Dirent = struct {
    name: bun.String,
    path: bun.String,
    // not publicly exposed
    kind: Kind,

    pub const Kind = std.Io.File.Kind;

    pub fn toResult(this: *const Dirent, comptime Result: type) bun.OOM!Result {
        var name = try bun.bindgen.DOMString.fromBunString(this.name.dupeRef());
        errdefer name.deinit();
        var path = try bun.bindgen.DOMString.fromBunString(this.path.dupeRef());
        errdefer path.deinit();
        var parent_path = path.clone();
        errdefer parent_path.deinit();
        return .{
            .name = name,
            .path = path,
            .data = switch (this.kind) {
                .file => bun.windows.libuv.UV_DIRENT_FILE,
                .block_device => bun.windows.libuv.UV_DIRENT_BLOCK,
                .character_device => bun.windows.libuv.UV_DIRENT_CHAR,
                .directory => bun.windows.libuv.UV_DIRENT_DIR,
                // event_port is deliberate there.
                .event_port, .named_pipe => bun.windows.libuv.UV_DIRENT_FIFO,
                .unix_domain_socket => bun.windows.libuv.UV_DIRENT_SOCKET,
                .sym_link => bun.windows.libuv.UV_DIRENT_LINK,
                .whiteout, .door, .unknown => bun.windows.libuv.UV_DIRENT_UNKNOWN,
            },
            .parentPath = parent_path,
        };
    }

    pub fn deref(this: *const Dirent) void {
        this.name.deref();
        this.path.deref();
    }
};

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const PathModule = @import("./PathLike.zig");

const NodeFSBindings = bun.bindgen.Module("NodeFS");
const AssertEncodingValidSchema = NodeFSBindings.function("assertEncodingValid");
const AssertEncodingValidBinding = bun.bindgen.Fn(AssertEncodingValidSchema, jsAssertEncodingValid);

comptime {
    _ = AssertEncodingValidBinding;
}
