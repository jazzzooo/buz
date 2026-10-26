pub const BlobSource = union(enum) {
    empty,
    file: File,
    buffer: Buffer,

    pub const File = struct {
        pathlike: PathOrFileDescriptor,
        mime_type: MimeType,
        allocator: std.mem.Allocator,
    };

    pub const Buffer = struct {
        bytes: []const u8,
        allocator: std.mem.Allocator,
        mime_type: MimeType,
    };

    pub fn deinit(this: *BlobSource) void {
        switch (this.*) {
            .empty => {},
            .file => |file| {
                if (file.pathlike == .path and file.pathlike.path == .string) {
                    file.allocator.free(@constCast(file.pathlike.path.slice()));
                } else {
                    file.pathlike.deinit();
                }
            },
            .buffer => |buffer| buffer.allocator.free(buffer.bytes),
        }
        this.* = .empty;
    }

    pub fn takeFile(this: *BlobSource) File {
        const file = this.file;
        this.* = .empty;
        return file;
    }

    pub fn takeBuffer(this: *BlobSource) Buffer {
        const buffer = this.buffer;
        this.* = .empty;
        return buffer;
    }
};

pub const BuildArtifactInput = struct {
    source: BlobSource,
    path: []u8,
    hash: u64,
    loader: Loader,
    output_kind: OutputKind,

    pub fn deinit(this: *BuildArtifactInput) void {
        this.source.deinit();
        bun.default_allocator.free(this.path);
        this.path = &.{};
    }

    pub fn takePath(this: *BuildArtifactInput) []u8 {
        const path = this.path;
        this.path = &.{};
        return path;
    }
};

pub fn takeBuildArtifact(this: *OutputFile, owned_pathname: []u8) bun.OOM!?BuildArtifactInput {
    errdefer bun.default_allocator.free(owned_pathname);
    const source: BlobSource = switch (this.value) {
        .move, .pending => @panic("Unexpected pending output file"),
        .noop => {
            bun.default_allocator.free(owned_pathname);
            return null;
        },
        .copy => |copy| .{ .file = .{
            .pathlike = if (copy.fd.isValid())
                .{ .fd = copy.fd }
            else
                .{ .path = .{ .string = bun.PathString.init(try bun.default_allocator.dupe(u8, copy.pathname)) } },
            .mime_type = this.loader.toMimeType(&.{owned_pathname}),
            .allocator = bun.default_allocator,
        } },
        .saved => .{ .file = .{
            .pathlike = .{ .path = .{ .string = bun.PathString.init(try bun.default_allocator.dupe(u8, owned_pathname)) } },
            .mime_type = this.loader.toMimeType(&.{owned_pathname}),
            .allocator = bun.default_allocator,
        } },
        .buffer => |buffer| .{ .buffer = .{
            .bytes = buffer.bytes,
            .allocator = buffer.allocator,
            .mime_type = this.loader.toMimeType(&.{owned_pathname}),
        } },
    };
    this.value = emptyValue();
    return .{
        .source = source,
        .path = owned_pathname,
        .hash = this.hash,
        .loader = this.input_loader,
        .output_kind = this.output_kind,
    };
}

pub fn takeBlob(this: *OutputFile, allocator: std.mem.Allocator) bun.OOM!BlobSource {
    const mime_type = this.loader.toMimeType(&.{ this.dest_path, this.src_path.text });
    const source: BlobSource = switch (this.value) {
        .move, .pending => @panic("Unexpected pending output file"),
        .noop => @panic("Cannot convert noop output file to blob"),
        .copy => |copy| .{ .file = .{
            .pathlike = if (copy.fd.isValid())
                .{ .fd = copy.fd }
            else
                .{ .path = .{ .string = bun.PathString.init(try allocator.dupe(u8, copy.pathname)) } },
            .mime_type = mime_type,
            .allocator = allocator,
        } },
        .saved => .{ .file = .{
            .pathlike = .{ .path = .{ .string = bun.PathString.init(try allocator.dupe(u8, this.src_path.text)) } },
            .mime_type = mime_type,
            .allocator = allocator,
        } },
        .buffer => |buffer| .{ .buffer = .{
            .bytes = buffer.bytes,
            .allocator = buffer.allocator,
            .mime_type = mime_type,
        } },
    };
    this.value = emptyValue();
    return source;
}

fn emptyValue() OutputFile.Value {
    return .{ .buffer = .{ .allocator = bun.default_allocator, .bytes = &.{} } };
}

const OutputFile = @import("./OutputFile.zig");
const OutputKind = @import("./OutputKind.zig").OutputKind;
const Loader = @import("./options.zig").Loader;
const std = @import("std");
const bun = @import("bun");
const MimeType = bun.http.MimeType;
const PathOrFileDescriptor = @import("../runtime/node/types.zig").PathOrFileDescriptor;
