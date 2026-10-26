const Store = @This();

pub const Timestamp = u52;
pub const uninitialized_timestamp = std.math.maxInt(Timestamp);

data: Data,

mime_type: MimeType = .none,
ref_count: std.atomic.Value(u32) = .init(1),
is_all_ascii: ?bool = null,
allocator: std.mem.Allocator,

pub fn memoryCost(this: *const Store) usize {
    return if (this.hasOneRef()) @sizeOf(@This()) + switch (this.data) {
        .bytes => this.data.bytes.len,
        .file => 0,
        .s3 => |s3| s3.estimatedSize(),
    } else 0;
}

pub fn getPath(this: *const Store) ?[]const u8 {
    return switch (this.data) {
        .bytes => |*bytes| bytes.fileName(),
        .file => |*file| if (file.pathlike == .path) file.pathlike.path.slice() else null,
        .s3 => |*s3| s3.pathlike.slice(),
    };
}

pub fn size(this: *const Store) SizeType {
    return switch (this.data) {
        .bytes => this.data.bytes.len,
        .s3, .file => BlobSize.max_size,
    };
}

pub const Map = std.HashMap(u64, *Store, bun.IdentityContext(u64), 80);

pub const Data = union(enum) {
    bytes: Bytes,
    file: File,
    s3: S3,
};

pub fn ref(this: *Store) void {
    const old = this.ref_count.fetchAdd(1, .monotonic);
    assert(old > 0);
}

pub fn hasOneRef(this: *const Store) bool {
    return this.ref_count.load(.monotonic) == 1;
}

pub fn external(ptr: ?*anyopaque, _: ?*u8, _: usize) void {
    if (ptr == null) return;
    var this = bun.cast(*Store, ptr);
    this.deref();
}
pub fn initS3WithReferencedCredentials(pathlike: node.PathLike, mime_type: ?MimeType, credentials: *bun.S3.S3Credentials, allocator: std.mem.Allocator) !*Store {
    var path = pathlike;
    errdefer path.deinit();
    try path.toThreadSafe();

    const store = try bun.default_allocator.create(Store);
    store.* = .{
        .data = .{
            .s3 = S3.initWithReferencedCredentials(
                path,
                mime_type orelse brk: {
                    const sliced = path.slice();
                    if (sliced.len > 0) {
                        var extname = std.fs.path.extension(sliced);
                        extname = std.mem.trim(u8, extname, ".");
                        if (MimeType.byExtensionNoDefault(extname)) |mime| {
                            break :brk mime;
                        }
                    }
                    break :brk null;
                },
                credentials,
            ),
        },
        .allocator = allocator,
        .ref_count = std.atomic.Value(u32).init(1),
    };
    return store;
}

pub fn initS3(pathlike: node.PathLike, mime_type: ?MimeType, credentials: bun.S3.S3Credentials, allocator: std.mem.Allocator) !*Store {
    var path = pathlike;
    errdefer path.deinit();
    try path.toThreadSafe();

    const store = try bun.default_allocator.create(Store);
    errdefer bun.default_allocator.destroy(store);
    store.* = .{
        .data = .{
            .s3 = try S3.init(
                path,
                mime_type orelse brk: {
                    const sliced = path.slice();
                    if (sliced.len > 0) {
                        var extname = std.fs.path.extension(sliced);
                        extname = std.mem.trim(u8, extname, ".");
                        if (MimeType.byExtensionNoDefault(extname)) |mime| {
                            break :brk mime;
                        }
                    }
                    break :brk null;
                },
                credentials,
            ),
        },
        .allocator = allocator,
        .ref_count = std.atomic.Value(u32).init(1),
    };
    return store;
}
/// Consumes the path, including on failure; file descriptors remain borrowed.
pub fn initFile(pathlike: node.PathOrFileDescriptor, mime_type: ?MimeType, allocator: std.mem.Allocator) bun.OOM!*Store {
    const store = bun.default_allocator.create(Store) catch |err| {
        var file = File.init(pathlike, mime_type);
        file.deinit(allocator);
        return err;
    };
    store.* = .{
        .data = .{
            .file = File.init(
                pathlike,
                mime_type orelse brk: {
                    if (pathlike == .path) {
                        const sliced = pathlike.path.slice();
                        if (sliced.len > 0) {
                            var extname = std.fs.path.extension(sliced);
                            extname = std.mem.trim(u8, extname, ".");
                            if (MimeType.byExtensionNoDefault(extname)) |mime| {
                                break :brk mime;
                            }
                        }
                    }

                    break :brk null;
                },
            ),
        },
        .allocator = allocator,
        .ref_count = std.atomic.Value(u32).init(1),
    };
    return store;
}

pub fn initStdio(fd: bun.FD, is_atty: bool) bun.OOM!*Store {
    const store = try initFile(.{ .fd = fd }, null, bun.default_allocator);
    store.data.file.is_atty = is_atty;
    switch (bun.sys.fstat(fd)) {
        .result => |stat| store.data.file.mode = @intCast(stat.mode),
        .err => {},
    }
    return store;
}

/// Consumes `bytes`, including on failure; they must come from `allocator`.
pub fn init(bytes: []u8, allocator: std.mem.Allocator) bun.OOM!*Store {
    errdefer allocator.free(bytes);
    const store = try bun.default_allocator.create(Store);
    errdefer bun.destroy(store);
    store.* = .{
        .data = .{
            .bytes = try Bytes.init(bytes, allocator),
        },
        .allocator = allocator,
        .ref_count = .init(1),
    };
    return store;
}

pub fn initByteResource(resource: *bun.bindgen.OwnedByteResource) bun.OOM!*Store {
    const store = try bun.default_allocator.create(Store);
    errdefer bun.destroy(store);
    store.* = .{
        .data = .{
            .bytes = try Bytes.initByteResource(resource),
        },
        .allocator = bun.default_allocator,
        .ref_count = .init(1),
    };
    return store;
}

pub fn initExecutable(bytes: bun.StandaloneModuleGraph.ExecutableFileBytes) bun.OOM!*Store {
    const len = std.math.cast(SizeType, bytes.contents.len) orelse return error.OutOfMemory;
    const store = try bun.default_allocator.create(Store);
    store.* = .{
        .data = .{ .bytes = .{ .backing = .{ .executable = bytes }, .len = len } },
        .allocator = bun.default_allocator,
    };
    return store;
}

pub fn initByteList(bytes: *bun.bindgen.OwnedByteList) bun.OOM!*Store {
    const len = std.math.cast(SizeType, bytes.length()) orelse return error.OutOfMemory;
    _ = std.math.cast(SizeType, bytes.capacity()) orelse return error.OutOfMemory;
    const store = try bun.default_allocator.create(Store);
    const list = bytes.takeManaged();
    store.* = .{
        .data = .{ .bytes = .{
            .backing = .{ .allocation = .fromManaged(list) },
            .len = len,
        } },
        .allocator = list.allocator,
    };
    return store;
}

pub fn sharedView(this: Store) []const u8 {
    if (this.data == .bytes)
        return this.data.bytes.slice();

    return &[_]u8{};
}

pub fn deref(this: *Store) void {
    const old = this.ref_count.fetchSub(1, .monotonic);
    assert(old >= 1);
    if (old == 1) {
        this.deinit();
    }
}

pub fn deinit(this: *Store) void {
    const allocator = this.allocator;

    switch (this.data) {
        .bytes => |*bytes| {
            bytes.deinit();
        },
        .file => |*file| file.deinit(allocator),
        .s3 => |*s3| {
            s3.deinit(allocator);
        },
    }

    bun.destroy(this);
}

pub const SerializeTag = enum(u8) {
    file = 0,
    bytes = 1,
    empty = 2,
};

pub const SerializedFileDescriptor = if (bun.Environment.isWindows) u64 else i32;

pub fn serialize(this: *Store, comptime Writer: type, writer: Writer) !void {
    switch (this.data) {
        .file => |file| {
            const pathlike_tag: node.PathOrFileDescriptor.SerializeTag = if (file.pathlike == .fd) .fd else .path;
            try writer.writeInt(u8, @backingInt(pathlike_tag), .little);

            switch (file.pathlike) {
                .fd => |fd| {
                    try writer.writeInt(SerializedFileDescriptor, @bitCast(fd), .little);
                },
                .path => |path| {
                    const path_slice = path.slice();
                    const path_length = std.math.cast(u32, path_slice.len) orelse return error.OutOfMemory;
                    try writer.writeInt(u32, path_length, .little);
                    try writer.writeAll(path_slice);
                },
            }
        },
        .s3 => |s3| {
            const pathlike_tag: node.PathOrFileDescriptor.SerializeTag = .path;
            try writer.writeInt(u8, @backingInt(pathlike_tag), .little);

            const path_slice = s3.pathlike.slice();
            const path_length = std.math.cast(u32, path_slice.len) orelse return error.OutOfMemory;
            try writer.writeInt(u32, path_length, .little);
            try writer.writeAll(path_slice);
        },
        .bytes => |*bytes| try serializeBytes(bytes, bytes.slice(), Writer, writer),
    }
}

pub fn serializeByteView(this: *Store, bytes: []const u8, comptime Writer: type, writer: Writer) !void {
    const store_bytes = switch (this.data) {
        .bytes => |*value| value,
        else => unreachable,
    };
    try serializeBytes(store_bytes, bytes, Writer, writer);
}

fn serializeBytes(store_bytes: *const Bytes, bytes: []const u8, comptime Writer: type, writer: Writer) !void {
    const length = std.math.cast(u32, bytes.len) orelse return error.OutOfMemory;
    try writer.writeInt(u32, length, .little);
    try writer.writeAll(bytes);

    const stored_name = store_bytes.fileName() orelse "";
    const name_length = std.math.cast(u32, stored_name.len) orelse return error.OutOfMemory;
    try writer.writeInt(u32, name_length, .little);
    try writer.writeAll(stored_name);
}

/// A blob store that references a file on disk.
pub const File = struct {
    pathlike: node.PathOrFileDescriptor,
    mime_type: MimeType = MimeType.other,
    is_atty: ?bool = null,
    mode: bun.Mode = 0,
    seekable: ?bool = null,
    max_size: SizeType = BlobSize.max_size,
    // milliseconds since ECMAScript epoch
    last_modified: Timestamp = uninitialized_timestamp,

    pub fn init(pathlike: node.PathOrFileDescriptor, mime_type: ?MimeType) File {
        return .{ .pathlike = pathlike, .mime_type = mime_type orelse MimeType.other };
    }

    pub fn deinit(this: *File, allocator: std.mem.Allocator) void {
        if (this.pathlike == .path) {
            if (this.pathlike.path == .string) {
                allocator.free(@constCast(this.pathlike.path.slice()));
            } else {
                this.pathlike.path.deinit();
            }
        }
    }
};

/// An S3 Blob Store
pub const S3 = struct {
    pathlike: node.PathLike,
    mime_type: MimeType = .other,
    credentials: ?*S3Credentials,
    options: bun.S3.MultiPartUploadOptions = .{},
    acl: ?bun.S3.ACL = null,
    storage_class: ?bun.S3.StorageClass = null,
    request_payer: bool = false,

    pub fn getCredentials(this: *const @This()) *S3Credentials {
        bun.assert(this.credentials != null);
        return this.credentials.?;
    }

    pub fn path(this: *@This()) []const u8 {
        var path_name = bun.URL.parse(this.pathlike.slice()).s3Path();
        // normalize start and ending
        if (strings.endsWith(path_name, "/")) {
            path_name = path_name[0 .. path_name.len - 1];
        } else if (strings.endsWith(path_name, "\\")) {
            path_name = path_name[0 .. path_name.len - 1];
        }
        if (strings.startsWith(path_name, "/")) {
            path_name = path_name[1..];
        } else if (strings.startsWith(path_name, "\\")) {
            path_name = path_name[1..];
        }
        return path_name;
    }

    pub fn initWithReferencedCredentials(pathlike: node.PathLike, mime_type: ?MimeType, credentials: *S3Credentials) S3 {
        credentials.ref();
        return .{
            .credentials = credentials,
            .pathlike = pathlike,
            .mime_type = mime_type orelse MimeType.other,
        };
    }
    pub fn init(pathlike: node.PathLike, mime_type: ?MimeType, credentials: S3Credentials) bun.OOM!S3 {
        return .{
            .credentials = try credentials.dupe(),
            .pathlike = pathlike,
            .mime_type = mime_type orelse MimeType.other,
        };
    }
    pub fn estimatedSize(this: *const @This()) usize {
        return this.pathlike.estimatedSize() + if (this.credentials) |credentials| credentials.estimatedSize() else 0;
    }

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        if (this.pathlike == .string) {
            allocator.free(@constCast(this.pathlike.slice()));
        } else {
            this.pathlike.deinit();
        }
        this.pathlike = .{
            .string = bun.PathString.empty,
        };
        if (this.credentials) |credentials| {
            credentials.deref();
            this.credentials = null;
        }
    }

    const S3Credentials = bun.S3.S3Credentials;
};

pub const Bytes = struct {
    backing: Backing,
    len: SizeType = 0,

    stored_name: bun.bindgen.OwnedByteList = .init(bun.default_allocator),

    pub const Backing = union(enum) {
        allocation: bun.bindgen.OwnedByteList,
        resource: bun.bindgen.OwnedByteResource,
        executable: bun.StandaloneModuleGraph.ExecutableFileBytes,
    };

    fn sizeType(value: usize) bun.OOM!SizeType {
        return std.math.cast(SizeType, value) orelse error.OutOfMemory;
    }

    /// Takes ownership of `bytes`, which must have been allocated with
    /// `allocator`.
    pub fn init(bytes: []u8, allocator: std.mem.Allocator) bun.OOM!Bytes {
        const len = try sizeType(bytes.len);
        return .{
            .backing = .{ .allocation = .fromOwnedSlice(allocator, bytes) },
            .len = len,
        };
    }

    pub fn initCapacity(bytes: []u8, len: usize, allocator: std.mem.Allocator) bun.OOM!Bytes {
        bun.assert(len <= bytes.len);
        _ = try sizeType(bytes.len);
        return .{
            .backing = .{ .allocation = .fromManaged(.{
                .items = bytes[0..len],
                .capacity = bytes.len,
                .allocator = allocator,
            }) },
            .len = try sizeType(len),
        };
    }

    pub fn initByteResource(resource: *bun.bindgen.OwnedByteResource) bun.OOM!Bytes {
        const len = resource.length();
        const representable_len = try sizeType(len);
        return .{
            .backing = .{ .resource = resource.take() },
            .len = representable_len,
        };
    }

    pub fn initEmptyWithName(name: []u8, allocator: std.mem.Allocator) Bytes {
        return .{
            .backing = .{ .allocation = .init(allocator) },
            .len = 0,
            .stored_name = .fromOwnedSlice(allocator, name),
        };
    }

    pub fn slice(this: *const Bytes) []const u8 {
        return switch (this.backing) {
            .allocation => |*allocation| allocation.slice()[0..this.len],
            .resource => |*resource| resource.slice()[0..this.len],
            .executable => |bytes| bytes.contents[0..this.len],
        };
    }

    pub fn fileName(this: *const Bytes) ?[]const u8 {
        if (this.stored_name.length() > 0) return this.stored_name.slice();
        return switch (this.backing) {
            .executable => |bytes| bytes.name,
            .allocation, .resource => null,
        };
    }

    pub fn takeManaged(this: *Bytes) ?std.array_list.Managed(u8) {
        var result = switch (this.backing) {
            .allocation => |*allocation| allocation.takeManaged(),
            .resource, .executable => return null,
        };
        result.items = result.items[0..this.len];
        this.len = 0;
        return result;
    }

    pub fn deinit(this: *Bytes) void {
        this.stored_name.deinit();
        switch (this.backing) {
            .allocation => |*allocation| allocation.deinit(),
            .resource => |*resource| resource.deinit(),
            .executable => {},
        }
        this.backing = .{ .allocation = .init(bun.default_allocator) };
        this.len = 0;
    }
};

const std = @import("std");

const bun = @import("bun");
const assert = bun.assert;
const strings = bun.strings;
const MimeType = bun.http.MimeType;
const node = @import("../../node/PathLike.zig");
const BlobSize = @import("../BlobSize.zig");
const SizeType = BlobSize.SizeType;
