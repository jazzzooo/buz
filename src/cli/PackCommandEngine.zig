const bun = @import("bun");
const std = @import("std");

const libarchive = @import("../libarchive/libarchive.zig").lib;
const Archive = libarchive.Archive;
const File = bun.sys.File;
const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const ReadTarballSchema = InternalTestingBindings.function("readTarball");

pub fn jsReadTarball(
    context: bun.bindgen.CallContext(ReadTarballSchema),
    args: bun.bindgen.Args(ReadTarballSchema),
) bun.bindgen.CallError(ReadTarballSchema)!bun.bindgen.Return(ReadTarballSchema) {
    return readTarballFromBinding(context, args);
}

pub fn readTarballFromBinding(
    context: anytype,
    args: bun.bindgen.Args(ReadTarballSchema),
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    const Return = bun.bindgen.Return(ReadTarballSchema);
    const Entries = @FieldType(Return, "entries");
    const Entry = Entries.Element;
    const tarball_path = try args.path.toUTF8(bun.default_allocator);
    defer tarball_path.deinit();

    const tarball_file = File.from(std.Io.Dir.cwd().openFile(globalThis.bunVM().io, tarball_path.slice(), .{}) catch |err| {
        return failReadTarball(context, "failed to open tarball file \"{s}\": {s}", .{ tarball_path.slice(), @errorName(err) });
    });
    defer tarball_file.close();

    const tarball = tarball_file.readToEnd(bun.default_allocator).unwrap() catch |err| {
        return failReadTarball(context, "failed to read tarball contents \"{s}\": {s}", .{ tarball_path.slice(), @errorName(err) });
    };
    defer bun.default_allocator.free(tarball);

    var sha1_digest: bun.sha.SHA1.Digest = undefined;
    var sha1 = bun.sha.SHA1.init();
    defer sha1.deinit();
    sha1.update(tarball);
    sha1.final(&sha1_digest);
    const shasum_bytes = std.fmt.bytesToHex(sha1_digest, .lower);
    var shasum = try bun.bindgen.DOMString.fromUTF8(&shasum_bytes);
    errdefer shasum.deinit();

    var sha512_digest: bun.sha.SHA512.Digest = undefined;
    var sha512 = bun.sha.SHA512.init();
    defer sha512.deinit();
    sha512.update(tarball);
    sha512.final(&sha512_digest);
    var base64_buf: [std.base64.standard.Encoder.calcSize(bun.sha.SHA512.digest)]u8 = undefined;
    const encode_count = bun.simdutf.base64.encode(&sha512_digest, &base64_buf, false);
    var integrity = try bun.bindgen.DOMString.fromUTF8(base64_buf[0..encode_count]);
    errdefer integrity.deinit();

    var entries_info = std.array_list.Managed(Entry).init(bun.default_allocator);
    defer {
        for (entries_info.items) |*entry| deinitTarballEntry(entry);
        entries_info.deinit();
    }

    const archive = Archive.readNew();
    var archive_closed = false;
    defer {
        if (!archive_closed) _ = archive.readClose();
        _ = archive.readFree();
    }

    switch (archive.readSupportFormatTar()) {
        .failed, .fatal, .warn => {
            return failReadTarball(context, "failed to support tar: {s}", .{archive.errorString()});
        },
        else => {},
    }
    switch (archive.readSupportFormatGnutar()) {
        .failed, .fatal, .warn => {
            return failReadTarball(context, "failed to support gnutar: {s}", .{archive.errorString()});
        },
        else => {},
    }
    switch (archive.readSupportFilterGzip()) {
        .failed, .fatal, .warn => {
            return failReadTarball(context, "failed to support gzip compression: {s}", .{archive.errorString()});
        },
        else => {},
    }

    switch (archive.readSetOptions("read_concatenated_archives")) {
        .failed, .fatal, .warn => {
            return failReadTarball(context, "failed to set read_concatenated_archives option: {s}", .{archive.errorString()});
        },
        else => {},
    }

    switch (archive.readOpenMemory(tarball)) {
        .failed, .fatal, .warn => {
            return failReadTarball(context, "failed to open archive in memory: {s}", .{archive.errorString()});
        },
        else => {},
    }

    var archive_entry: *Archive.Entry = undefined;
    var header_status = archive.readNextHeader(&archive_entry);

    var read_buf = std.array_list.Managed(u8).init(bun.default_allocator);
    defer read_buf.deinit();

    while (header_status != .eof) : (header_status = archive.readNextHeader(&archive_entry)) {
        switch (header_status) {
            .eof => unreachable,
            .retry => continue,
            .failed, .fatal => {
                return failReadTarball(context, "failed to read archive header: {s}", .{Archive.errorString(@ptrCast(archive))});
            },
            else => {
                var pathname = if (bun.Environment.isWindows) blk: {
                    const pathname_w = archive_entry.pathnameW();
                    var result = std.array_list.Managed(u8).init(bun.default_allocator);
                    defer result.deinit();
                    try bun.strings.toUTF8AppendToList(&result, pathname_w);
                    break :blk try bun.bindgen.DOMString.fromUTF8(result.items);
                } else try bun.bindgen.DOMString.fromUTF8(archive_entry.pathname());
                errdefer pathname.deinit();

                const kind = bun.sys.kindFromMode(archive_entry.filetype());
                const perm = archive_entry.perm();
                var kind_string = try bun.bindgen.DOMString.fromUTF8(@tagName(kind));
                errdefer kind_string.deinit();
                var contents: ?bun.bindgen.DOMString = null;
                errdefer if (contents) |*value| value.deinit();

                if (kind == .file) {
                    const size: usize = @intCast(archive_entry.size());
                    bun.handleOom(read_buf.resize(size));
                    defer read_buf.clearRetainingCapacity();

                    const read = archive.readData(read_buf.items);
                    if (read < 0) {
                        const pathname_utf8 = try pathname.toUTF8(bun.default_allocator);
                        defer pathname_utf8.deinit();
                        return failReadTarball(context, "failed to read archive entry \"{s}\": {s}", .{
                            pathname_utf8.slice(),
                            Archive.errorString(@ptrCast(archive)),
                        });
                    }
                    read_buf.items.len = @intCast(read);
                    contents = try bun.bindgen.DOMString.fromUTF8(read_buf.items);
                }

                try entries_info.append(.{
                    .pathname = pathname,
                    .kind = kind_string,
                    .perm = @intCast(perm),
                    .contents = contents,
                });
                pathname = bun.bindgen.DOMString.empty();
                kind_string = bun.bindgen.DOMString.empty();
                contents = null;
            },
        }
    }

    const close_status = archive.readClose();
    archive_closed = true;
    switch (close_status) {
        .failed, .fatal, .warn => {
            return failReadTarball(context, "failed to close read archive: {s}", .{archive.errorString()});
        },
        else => {},
    }

    const entries = try Entries.fromOwnedSlice(entries_info.items);
    entries_info.items.len = 0;
    return .{
        .entries = entries,
        .size = tarball.len,
        .shasum = shasum,
        .integrity = integrity,
    };
}

fn deinitTarballEntry(entry: anytype) void {
    entry.pathname.deinit();
    entry.kind.deinit();
    if (entry.contents) |*contents| contents.deinit();
}

fn failReadTarball(
    context: bun.bindgen.CallContext(ReadTarballSchema),
    comptime format: [:0]const u8,
    values: anytype,
) bun.bindgen.CallError(ReadTarballSchema) {
    const message = bun.String.createFormat(format, values) catch return error.OutOfMemory;
    const payload = bun.bindgen.DOMString.fromBunString(message) catch return error.OutOfMemory;
    return context.fail(.operation_failed, payload);
}
