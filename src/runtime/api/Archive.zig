const Archive = @This();

pub fn inspectCustom(_: *Archive, context: bindgen.CallContext(ArchiveInspectSchema), args: bindgen.Args(ArchiveInspectSchema)) bun.JSError!bindgen.DOMString {
    return @import("./ArchiveEngine.zig").inspect(context, args);
}

bindgen_state: bindgen.ClassState = .{},
/// The underlying data for the archive - uses Blob.Store for thread-safe ref counting
store: bindgen.RefNative(Store, .any),
/// Compression settings for this archive
compress: Compression = .none,

/// Compression options for the archive
pub const Compression = union(enum) {
    none,
    gzip: struct {
        /// Compression level: 1 (fastest) to 12 (maximum compression). Default is 6.
        level: u8 = 6,
    },
};

pub const Handle = Binding.Handle;

pub fn destroy(this: *Archive) void {
    this.store.deinit();
    bun.destroy(this);
}

pub fn byteLength(this: *const Archive) usize {
    return this.store.get().sharedView().len;
}

pub fn fileCount(this: *const Archive) u32 {
    return countFilesInArchive(this.store.get().sharedView());
}

/// Configure archive for reading tar/tar.gz
fn configureArchiveReader(archive: *libarchive.lib.Archive) void {
    _ = archive.readSupportFormatTar();
    _ = archive.readSupportFormatGnutar();
    _ = archive.readSupportFilterGzip();
    _ = archive.readSetOptions("read_concatenated_archives");
}

/// Count the number of files in an archive
fn countFilesInArchive(data: []const u8) u32 {
    const archive = libarchive.lib.Archive.readNew();
    defer _ = archive.readFree();
    configureArchiveReader(archive);

    if (archive.readOpenMemory(data) != .ok) {
        return 0;
    }

    var count: u32 = 0;
    var entry: *libarchive.lib.Archive.Entry = undefined;
    while (archive.readNextHeader(&entry) == .ok) {
        if (entry.filetype() == @backingInt(libarchive.lib.FileType.regular)) {
            count += 1;
        }
    }

    return count;
}

/// Constructor: new Archive(data, options?)
/// Creates an Archive from either:
/// - An object { [path: string]: Blob | string | ArrayBufferView | ArrayBufferLike }
/// - A Blob, ArrayBufferView, or ArrayBufferLike (assumes it's already a valid archive)
/// Options:
/// - compress: "gzip" - Enable gzip compression
/// - level: number (1-12) - Compression level (default 6)
/// When no options are provided, no compression is applied
pub fn construct(
    context: bindgen.CallContext(ArchiveConstructorSchema),
    args: bindgen.Args(ArchiveConstructorSchema),
) bindgen.CallError(ArchiveConstructorSchema)!*Archive {
    const compress = if (args.options) |options|
        try compressionFromOptions(ArchiveConstructorSchema, context, options)
    else
        .none;
    const data_arg = args.data orelse return context.fail(.invalid_data, {});

    const converted = try data_arg.convert(context);
    return switch (converted.value) {
        .blob => |*blob_ref| if (blob_ref.get().storePtr()) |store| archive: {
            const value = try bun.default_allocator.create(Archive);
            value.* = .{ .store = .init(store), .compress = compress };
            break :archive value;
        } else context.fail(.invalid_data, {}),
        .buffer => |buffer| try createArchive(try buffer.dupe(bun.default_allocator), compress),
        .entries => |*entries| try createArchive(try buildTarballForCall(ArchiveConstructorSchema, context, entries), compress),
        .invalid => context.fail(.invalid_data, {}),
    };
}

fn compressionFromOptions(
    comptime Schema: type,
    context: bindgen.CallContext(Schema),
    options: anytype,
) bindgen.CallError(Schema)!Compression {
    const settings = options orelse return .none;
    if (settings.compress == null) return .none;
    const level = settings.level orelse 6;
    if (level < 1 or level > 12) return context.fail(.invalid_compression_level, {});
    return .{ .gzip = .{ .level = level } };
}

fn createArchive(data: []u8, compress: Compression) bun.OOM!*Archive {
    const store = try Store.init(data, bun.default_allocator);
    errdefer store.deref();
    const archive = try bun.default_allocator.create(Archive);
    archive.* = .{ .store = .adopt(store), .compress = compress };
    return archive;
}

const TarballBuildError = error{
    OutOfMemory,
    ArchiveFormatError,
    ArchiveOpenError,
    ArchiveHeaderError,
    ArchiveWriteError,
    ArchiveFinishEntryError,
    ArchiveCloseError,
};

fn buildTarballForCall(
    comptime Schema: type,
    context: bindgen.CallContext(Schema),
    entries: anytype,
) bindgen.CallError(Schema)![]u8 {
    return buildTarballFromEntries(entries) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ArchiveFormatError => context.fail(.archive_format_error, {}),
        error.ArchiveOpenError => context.fail(.archive_open_error, {}),
        error.ArchiveHeaderError => context.fail(.archive_header_error, {}),
        error.ArchiveWriteError => context.fail(.archive_write_error, {}),
        error.ArchiveFinishEntryError => context.fail(.archive_finish_entry_error, {}),
        error.ArchiveCloseError => context.fail(.archive_close_error, {}),
    };
}

fn buildTarballFromEntries(entries: anytype) TarballBuildError![]u8 {
    const allocator = bun.default_allocator;
    const lib = libarchive.lib;

    var growing_buffer = lib.GrowingBuffer.init(allocator);
    errdefer growing_buffer.deinit();

    const archive = lib.Archive.writeNew();
    defer _ = archive.writeFree();

    if (archive.writeSetFormatPaxRestricted() != .ok) {
        return error.ArchiveFormatError;
    }

    if (lib.archive_write_open2(
        @ptrCast(archive),
        @ptrCast(&growing_buffer),
        &lib.GrowingBuffer.openCallback,
        &lib.GrowingBuffer.writeCallback,
        &lib.GrowingBuffer.closeCallback,
        null,
    ) != 0) {
        return error.ArchiveOpenError;
    }

    const entry = lib.Archive.Entry.new();
    defer entry.free();

    const now_secs: isize = @intCast(bun.timespec.realNow().sec);

    for (0..entries.len()) |index| {
        const archive_entry = entries.at(index).?;
        const key_slice = try archive_entry.key.toUTF8(allocator);
        defer key_slice.deinit();
        if (key_slice.length() == 0) continue;
        const key_str = try allocator.dupeSentinel(u8, key_slice.slice(), 0);
        defer allocator.free(key_str);

        var string_data = bun.String.Slice.empty;
        defer string_data.deinit();
        const data = switch (archive_entry.value) {
            .blob => |*blob_ref| blob_ref.get().sharedView(),
            .buffer => |buffer| buffer.unsafePtr("the binding frame owns each copied archive payload until archive.writeData returns"),
            .string => |*string| data: {
                string_data = try string.toUTF8(allocator);
                break :data string_data.slice();
            },
        };

        _ = entry.clear();
        entry.setPathnameUtf8(key_str);
        entry.setSize(@intCast(data.len));
        entry.setFiletype(@backingInt(lib.FileType.regular));
        entry.setPerm(0o644);
        entry.setMtime(now_secs, 0);

        if (archive.writeHeader(entry) != .ok) {
            return error.ArchiveHeaderError;
        }
        if (archive.writeData(data) < 0) {
            return error.ArchiveWriteError;
        }
        if (archive.writeFinishEntry() != .ok) {
            return error.ArchiveFinishEntryError;
        }
    }

    if (archive.writeClose() != .ok) {
        return error.ArchiveCloseError;
    }

    return growing_buffer.toOwnedSlice() catch error.OutOfMemory;
}

/// Static method: Archive.write(path, data, options?)
/// Creates and writes an archive to disk in one operation.
/// For Archive instances, uses the archive's compression settings unless overridden by options.
/// Options:
///   - gzip: { level?: number } - Override compression settings
pub fn write(
    context: bindgen.CallContext(ArchiveWriteSchema),
    args: bindgen.Args(ArchiveWriteSchema),
) bindgen.CallError(ArchiveWriteSchema)!void {
    const path = args.path orelse return context.fail(.invalid_path, {});
    const path_slice = try path.toUTF8(bun.default_allocator);
    defer path_slice.deinit();
    const options_compress = if (args.options) |options| compression: {
        const converted = try options.convert(context);
        break :compression try compressionFromOptions(ArchiveWriteSchema, context, converted.value);
    } else .none;
    const data_arg = args.data orelse return context.fail(.invalid_data, {});

    const converted = try data_arg.convert(context);
    var compress = options_compress;
    const write_data: WriteContext.Data = switch (converted.value) {
        .archive => |*archive_ref| archive_data: {
            const archive = archive_ref.get(Archive);
            if (compress == .none) compress = archive.compress;
            break :archive_data .{ .store = archive.store.get() };
        },
        .blob => |*blob_ref| if (blob_ref.get().storePtr()) |store|
            .{ .store = store }
        else
            return context.fail(.invalid_data, {}),
        .buffer => |buffer| .{ .owned = try buffer.dupe(bun.default_allocator) },
        .entries => |*entries| .{ .owned = try buildTarballForCall(ArchiveWriteSchema, context, entries) },
        .invalid => return context.fail(.invalid_data, {}),
    };
    startWriteTask(context, write_data, path_slice.slice(), compress);
}

/// Instance method: archive.extract(path, options?)
/// Extracts the archive to the given path
/// Options:
///   - glob: string | string[] - Only extract files matching the glob pattern(s). Supports negative patterns with "!".
/// Returns Promise<number> with count of extracted files
pub fn extract(
    this: *Archive,
    context: bindgen.CallContext(ArchiveExtractSchema),
    args: bindgen.Args(ArchiveExtractSchema),
) bindgen.CallError(ArchiveExtractSchema)!void {
    const path = args.path orelse return context.fail(.invalid_path, {});
    const path_slice = try path.toUTF8(bun.default_allocator);
    defer path_slice.deinit();

    var glob_patterns: ?[]const []const u8 = null;
    errdefer {
        if (glob_patterns) |patterns| freePatterns(patterns);
    }
    if (args.options) |options| {
        const converted = try options.convert(context);
        if (converted.value) |*settings| {
            if (settings.glob) |*patterns| {
                glob_patterns = switch (patterns.*) {
                    .invalid => return context.fail(.invalid_glob, {}),
                    else => try ownPatterns(patterns),
                };
            }
        }
    }

    var completion = context.completion();
    const path_copy = bun.default_allocator.dupe(u8, path_slice.slice()) catch {
        if (glob_patterns) |patterns| freePatterns(patterns);
        completion.outOfMemory();
        return;
    };
    const task = bun.default_allocator.create(ExtractTask) catch {
        bun.default_allocator.free(path_copy);
        if (glob_patterns) |patterns| freePatterns(patterns);
        completion.outOfMemory();
        return;
    };
    const store = this.store.get();
    store.ref();
    task.* = .{
        .ctx = .{
            .store = store,
            .io = bun.current_runtime.io(),
            .path = path_copy,
            .glob_patterns = glob_patterns,
        },
        .completion = completion.take(),
    };
    task.schedule(bun.current_runtime.backgroundTasks());
}

fn ownPatterns(patterns: anytype) bun.OOM!?[]const []const u8 {
    const allocator = bun.default_allocator;
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (result.items) |pattern| allocator.free(pattern);
        result.deinit(allocator);
    }

    switch (patterns.*) {
        .single => |*pattern| try appendPattern(&result, pattern),
        .multiple => |*values| {
            try result.ensureTotalCapacity(allocator, values.len());
            var iterator = values.iterator();
            while (iterator.next()) |pattern_| {
                const pattern = pattern_;
                try appendPattern(&result, &pattern.value);
            }
        },
        .invalid => unreachable,
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return null;
    }
    return try result.toOwnedSlice(allocator);
}

fn appendPattern(result: *std.ArrayListUnmanaged([]const u8), pattern: anytype) bun.OOM!void {
    const allocator = bun.default_allocator;
    const utf8 = try pattern.toUTF8(allocator);
    defer utf8.deinit();
    if (utf8.length() == 0) return;
    const copy = try allocator.dupe(u8, utf8.slice());
    errdefer allocator.free(copy);
    try result.append(allocator, copy);
}

fn freePatterns(patterns: []const []const u8) void {
    for (patterns) |p| bun.default_allocator.free(p);
    bun.default_allocator.free(patterns);
}

/// Instance method: archive.blob()
/// Returns Promise<Blob> with the archive data (compressed if gzip was set in options)
pub fn blobNative(
    this: *Archive,
    context: bindgen.CallContext(ArchiveBlobNativeSchema),
    _: bindgen.Args(ArchiveBlobNativeSchema),
) bindgen.CallError(ArchiveBlobNativeSchema)!void {
    startBytesTask(ArchiveBlobNativeSchema, context, this.store.get(), this.compress);
}

/// Instance method: archive.bytes()
/// Returns Promise<Uint8Array> with the archive data (compressed if gzip was set in options)
pub fn bytes(
    this: *Archive,
    context: bindgen.CallContext(ArchiveBytesSchema),
    _: bindgen.Args(ArchiveBytesSchema),
) bindgen.CallError(ArchiveBytesSchema)!void {
    startBytesTask(ArchiveBytesSchema, context, this.store.get(), this.compress);
}

/// Instance method: archive.files(glob?)
/// Returns Promise<Map<string, File>> with archive file contents
pub fn filesNative(
    this: *Archive,
    context: bindgen.CallContext(ArchiveFilesNativeSchema),
    args: bindgen.Args(ArchiveFilesNativeSchema),
) bindgen.CallError(ArchiveFilesNativeSchema)!void {
    var glob_patterns: ?[]const []const u8 = null;
    errdefer if (glob_patterns) |patterns| freePatterns(patterns);
    if (args.glob) |glob| {
        if (glob) |*patterns| {
            glob_patterns = switch (patterns.*) {
                .invalid => return context.fail(.invalid_glob, {}),
                else => try ownPatterns(patterns),
            };
        }
    }

    startFilesTask(context, this.store.get(), glob_patterns);
}

// ============================================================================
// Task Contexts
// ============================================================================

const ExtractContext = struct {
    const Result = union(enum) {
        success: u32,
        err: error{ ReadError, ConcurrencyUnavailable },
    };

    store: *Store,
    io: std.Io,
    path: []const u8,
    glob_patterns: ?[]const []const u8,
    result: Result = .{ .err = error.ReadError },

    fn run(this: *ExtractContext) Result {
        // If we have glob patterns, use filtered extraction
        if (this.glob_patterns != null) {
            const count = extractToDiskFiltered(
                this.io,
                this.store.sharedView(),
                this.path,
                this.glob_patterns,
            ) catch return .{ .err = error.ReadError };
            return .{ .success = count };
        }

        // Otherwise use the fast path without filtering
        const count = libarchive.Archiver.extractToDisk(
            this.io,
            this.store.sharedView(),
            this.path,
            null,
            void,
            {},
            .{ .depth_to_skip = 0, .close_handles = true, .log = false, .npm = false },
        ) catch return .{ .err = error.ReadError };
        return .{ .success = count };
    }

    fn deinit(this: *ExtractContext) void {
        this.store.deref();
        bun.default_allocator.free(this.path);
        if (this.glob_patterns) |patterns| freePatterns(patterns);
    }
};

const ExtractTask = struct {
    ctx: ExtractContext,
    completion: bindgen.OwnedCompletion(ArchiveExtractSchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(this: *ExtractTask, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &this.task) catch |err| {
            this.ctx.result = .{ .err = err };
            this.finish();
        };
    }

    fn run(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *ExtractTask = @fieldParentPtr("task", work_task);
        this.ctx.result = this.ctx.run();
        this.finish();
    }

    fn cancel(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *ExtractTask = @fieldParentPtr("task", work_task);
        this.completion.release();
        this.deinit();
    }

    fn finish(this: *ExtractTask) void {
        defer this.deinit();
        switch (this.ctx.result) {
            .success => |count| this.completion.resolve(count),
            .err => |err| switch (err) {
                error.ReadError => this.completion.fail(.read_error, {}),
                error.ConcurrencyUnavailable => this.completion.fail(.concurrency_unavailable, {}),
            },
        }
    }

    fn deinit(this: *ExtractTask) void {
        this.ctx.deinit();
        bun.destroy(this);
    }
};

const BlobContext = struct {
    const Error = error{ OutOfMemory, GzipInitFailed, GzipCompressFailed, ConcurrencyUnavailable };
    const Result = union(enum) {
        compressed: []u8,
        uncompressed: void,
        err: Error,
    };

    store: *Store,
    io: std.Io,
    compress: Compression,
    result: Result = .{ .uncompressed = {} },

    fn run(this: *BlobContext) Result {
        switch (this.compress) {
            .gzip => |opts| {
                return .{ .compressed = compressGzip(this.io, this.store.sharedView(), opts.level) catch |e| return .{ .err = e } };
            },
            .none => return .{ .uncompressed = {} },
        }
    }

    fn deinit(this: *BlobContext) void {
        this.store.deref();
        if (this.result == .compressed) bun.default_allocator.free(this.result.compressed);
    }
};

fn BytesTask(comptime FunctionSchema: type) type {
    return struct {
        const Self = @This();

        ctx: BlobContext,
        completion: bindgen.OwnedCompletion(FunctionSchema),
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        pub fn schedule(this: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
            bun.BackgroundWork.schedule(background_tasks, &this.task) catch |err| {
                this.ctx.result = .{ .err = err };
                this.finish();
            };
        }

        fn run(work_task: *bun.BackgroundTaskGroup.Task) void {
            const this: *Self = @fieldParentPtr("task", work_task);
            this.ctx.result = this.ctx.run();
            this.finish();
        }

        fn cancel(work_task: *bun.BackgroundTaskGroup.Task) void {
            const this: *Self = @fieldParentPtr("task", work_task);
            this.completion.release();
            this.deinit();
        }

        fn finish(this: *Self) void {
            defer this.deinit();
            switch (this.ctx.result) {
                .compressed => |data| {
                    const owned_bytes = bindgen.OwnedBytes.fromSlice(data) catch {
                        this.completion.outOfMemory();
                        return;
                    };
                    this.completion.resolve(owned_bytes);
                },
                .uncompressed => {
                    const owned_bytes = bindgen.OwnedBytes.fromSlice(this.ctx.store.sharedView()) catch {
                        this.completion.outOfMemory();
                        return;
                    };
                    this.completion.resolve(owned_bytes);
                },
                .err => |err| switch (err) {
                    error.OutOfMemory => this.completion.outOfMemory(),
                    error.GzipInitFailed => this.completion.fail(.gzip_init_failed, {}),
                    error.GzipCompressFailed => this.completion.fail(.gzip_compress_failed, {}),
                    error.ConcurrencyUnavailable => this.completion.fail(.concurrency_unavailable, {}),
                },
            }
        }

        fn deinit(this: *Self) void {
            this.ctx.deinit();
            bun.destroy(this);
        }
    };
}

fn startBytesTask(
    comptime FunctionSchema: type,
    context: bindgen.CallContext(FunctionSchema),
    store: *Store,
    compress: Compression,
) void {
    var completion = context.completion();
    const Task = BytesTask(FunctionSchema);
    const task = bun.default_allocator.create(Task) catch {
        completion.outOfMemory();
        return;
    };
    store.ref();
    task.* = .{
        .ctx = .{
            .store = store,
            .io = bun.current_runtime.io(),
            .compress = compress,
        },
        .completion = completion.take(),
    };
    task.schedule(bun.current_runtime.backgroundTasks());
}

const WriteContext = struct {
    const Error = error{ OutOfMemory, GzipInitFailed, GzipCompressFailed, ConcurrencyUnavailable };
    const Result = union(enum) {
        success: void,
        err: Error,
        sys_err: bun.sys.Error,
    };
    const Data = union(enum) {
        owned: []u8,
        store: *Store,
    };

    data: Data,
    io: std.Io,
    path: [:0]const u8,
    compress: Compression,
    result: Result = .{ .success = {} },

    fn run(this: *WriteContext) Result {
        const source_data = switch (this.data) {
            .owned => |d| d,
            .store => |s| s.sharedView(),
        };
        const data_to_write = switch (this.compress) {
            .gzip => |opts| compressGzip(this.io, source_data, opts.level) catch |e| return .{ .err = e },
            .none => source_data,
        };
        defer if (this.compress != .none) bun.default_allocator.free(data_to_write);

        const file = switch (bun.sys.File.openat(.cwd(), this.path, bun.O.CREAT | bun.O.WRONLY | bun.O.TRUNC, 0o644)) {
            .err => |err| return .{ .sys_err = err.clone(bun.default_allocator) },
            .result => |f| f,
        };
        defer file.close();

        return switch (file.writeAll(data_to_write)) {
            .err => |err| .{ .sys_err = err.clone(bun.default_allocator) },
            .result => .{ .success = {} },
        };
    }

    fn deinit(this: *WriteContext) void {
        switch (this.data) {
            .owned => |d| bun.default_allocator.free(d),
            .store => |s| s.deref(),
        }
        bun.default_allocator.free(this.path);
        if (this.result == .sys_err) {
            var sys_err = this.result.sys_err;
            sys_err.deinit();
        }
    }
};

const WriteTask = struct {
    ctx: WriteContext,
    completion: bindgen.OwnedCompletion(ArchiveWriteSchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(this: *WriteTask, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &this.task) catch |err| {
            this.ctx.result = .{ .err = err };
            this.finish();
        };
    }

    fn run(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *WriteTask = @fieldParentPtr("task", work_task);
        this.ctx.result = this.ctx.run();
        this.finish();
    }

    fn cancel(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *WriteTask = @fieldParentPtr("task", work_task);
        this.completion.release();
        this.deinit();
    }

    fn finish(this: *WriteTask) void {
        defer this.deinit();
        switch (this.ctx.result) {
            .success => this.completion.resolve({}),
            .err => |err| switch (err) {
                error.OutOfMemory => this.completion.outOfMemory(),
                error.GzipInitFailed => this.completion.fail(.gzip_init_failed, {}),
                error.GzipCompressFailed => this.completion.fail(.gzip_compress_failed, {}),
                error.ConcurrencyUnavailable => this.completion.fail(.concurrency_unavailable, {}),
            },
            .sys_err => |sys_err| {
                const system_error = bindgen.SystemError.fromSysError(sys_err) catch {
                    this.completion.outOfMemory();
                    return;
                };
                this.completion.fail(.system, system_error);
            },
        }
    }

    fn deinit(this: *WriteTask) void {
        this.ctx.deinit();
        bun.destroy(this);
    }
};

fn startWriteTask(
    context: bindgen.CallContext(ArchiveWriteSchema),
    data: WriteContext.Data,
    path: []const u8,
    compress: Compression,
) void {
    const path_z = bun.default_allocator.dupeSentinel(u8, path, 0) catch {
        if (data == .owned) bun.default_allocator.free(data.owned);
        var completion = context.completion();
        completion.outOfMemory();
        return;
    };
    if (data == .store) {
        data.store.ref();
    }
    var completion = context.completion();
    const task = bun.default_allocator.create(WriteTask) catch {
        var owned_context: WriteContext = .{
            .data = data,
            .io = undefined,
            .path = path_z,
            .compress = compress,
        };
        owned_context.deinit();
        completion.outOfMemory();
        return;
    };
    task.* = .{
        .ctx = .{
            .data = data,
            .io = bun.current_runtime.io(),
            .path = path_z,
            .compress = compress,
        },
        .completion = completion.take(),
    };
    task.schedule(bun.current_runtime.backgroundTasks());
}

const FilesContext = struct {
    const FileEntry = struct { path: []u8, data: []u8, mtime: i64 };
    const FileEntryList = std.ArrayList(FileEntry);
    const Error = error{ OutOfMemory, ReadError, ConcurrencyUnavailable };
    const Result = union(enum) {
        success: FileEntryList,
        libarchive_err: [*:0]u8,
        err: Error,

        fn deinit(self: *Result) void {
            switch (self.*) {
                .libarchive_err => |s| bun.default_allocator.free(std.mem.span(s)),
                .success => |*list| freeEntries(list),
                .err => {},
            }
        }
    };

    fn freeEntries(list: *FileEntryList) void {
        for (list.items) |e| {
            bun.default_allocator.free(e.path);
            if (e.data.len > 0) bun.default_allocator.free(e.data);
        }
        list.deinit(bun.default_allocator);
    }

    store: *Store,
    glob_patterns: ?[]const []const u8,
    result: Result = .{ .err = error.ReadError },

    fn cloneErrorString(archive: *libarchive.lib.Archive) ?[*:0]u8 {
        const err_str = archive.errorString();
        if (err_str.len == 0) return null;
        return bun.default_allocator.dupeSentinel(u8, err_str, 0) catch null;
    }

    fn run(this: *FilesContext) std.mem.Allocator.Error!Result {
        const lib = libarchive.lib;
        const archive = lib.Archive.readNew();
        defer _ = archive.readFree();
        configureArchiveReader(archive);

        if (archive.readOpenMemory(this.store.sharedView()) != .ok) {
            return if (cloneErrorString(archive)) |err| .{ .libarchive_err = err } else .{ .err = error.ReadError };
        }

        var entries: FileEntryList = .empty;
        errdefer freeEntries(&entries);

        var entry: *lib.Archive.Entry = undefined;
        while (archive.readNextHeader(&entry) == .ok) {
            if (entry.filetype() != @backingInt(lib.FileType.regular)) continue;

            const pathname = entry.pathnameUtf8();
            // Apply glob pattern filtering (supports both positive and negative patterns)
            if (this.glob_patterns) |patterns| {
                if (!matchGlobPatterns(patterns, pathname)) continue;
            }

            const size: usize = @intCast(@max(entry.size(), 0));
            const mtime = entry.mtime();

            // Read data first before allocating path
            var data: []u8 = &.{};
            if (size > 0) {
                data = try bun.default_allocator.alloc(u8, size);
                var total_read: usize = 0;
                while (total_read < size) {
                    const read = archive.readData(data[total_read..]);
                    if (read < 0) {
                        // Read error - returned as a normal Result (not a Zig error), so the
                        // errdefer above won't fire. Free the current buffer and all previously
                        // collected entries manually to avoid leaking them.
                        bun.default_allocator.free(data);
                        freeEntries(&entries);
                        return if (cloneErrorString(archive)) |err| .{ .libarchive_err = err } else .{ .err = error.ReadError };
                    }
                    if (read == 0) break;
                    total_read += @intCast(read);
                }
            }
            errdefer if (data.len > 0) bun.default_allocator.free(data);

            const path_copy = try bun.default_allocator.dupe(u8, pathname);
            errdefer bun.default_allocator.free(path_copy);

            try entries.append(bun.default_allocator, .{ .path = path_copy, .data = data, .mtime = mtime });
        }

        return .{ .success = entries };
    }

    fn deinit(this: *FilesContext) void {
        this.result.deinit();
        this.store.deref();
        if (this.glob_patterns) |patterns| freePatterns(patterns);
    }
};

const FilesTask = struct {
    ctx: FilesContext,
    completion: bindgen.OwnedCompletion(ArchiveFilesNativeSchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(this: *FilesTask, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &this.task) catch |err| {
            this.ctx.result = .{ .err = err };
            this.finish();
        };
    }

    fn run(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *FilesTask = @fieldParentPtr("task", work_task);
        this.ctx.result = this.ctx.run() catch |err| .{ .err = err };
        this.finish();
    }

    fn cancel(work_task: *bun.BackgroundTaskGroup.Task) void {
        const this: *FilesTask = @fieldParentPtr("task", work_task);
        this.completion.release();
        this.deinit();
    }

    fn finish(this: *FilesTask) void {
        defer this.deinit();
        switch (this.ctx.result) {
            .success => |*entries| this.resolveEntries(entries),
            .libarchive_err => |message| {
                const owned_message = bindgen.ThreadSafeDOMString.fromUTF8(std.mem.span(message)) catch {
                    this.completion.outOfMemory();
                    return;
                };
                this.completion.fail(.archive_error, owned_message);
            },
            .err => |err| switch (err) {
                error.OutOfMemory => this.completion.outOfMemory(),
                error.ReadError => this.completion.fail(.read_error, {}),
                error.ConcurrencyUnavailable => this.completion.fail(.concurrency_unavailable, {}),
            },
        }
    }

    fn resolveEntries(this: *FilesTask, entries: *FilesContext.FileEntryList) void {
        const Result = bindgen.Return(ArchiveFilesNativeSchema);
        var values = Result.Builder.init(entries.items.len) catch {
            this.completion.outOfMemory();
            return;
        };
        defer values.deinit();

        for (entries.items) |*source| {
            var path = bindgen.UTF8String.fromSlice(source.path) catch {
                this.completion.outOfMemory();
                return;
            };
            const data = bindgen.OwnedBytes.fromSlice(source.data) catch {
                path.deinit();
                this.completion.outOfMemory();
                return;
            };
            values.appendOwned(.{
                .path = path,
                .data = data,
                .mtime = @floatFromInt(source.mtime),
            });
        }
        this.completion.resolve(values.finish());
    }

    fn deinit(this: *FilesTask) void {
        this.ctx.deinit();
        bun.destroy(this);
    }
};

fn startFilesTask(
    context: bindgen.CallContext(ArchiveFilesNativeSchema),
    store: *Store,
    glob_patterns: ?[]const []const u8,
) void {
    var completion = context.completion();
    const task = bun.default_allocator.create(FilesTask) catch {
        if (glob_patterns) |patterns| freePatterns(patterns);
        completion.outOfMemory();
        return;
    };
    store.ref();
    task.* = .{
        .ctx = .{ .store = store, .glob_patterns = glob_patterns },
        .completion = completion.take(),
    };
    task.schedule(bun.current_runtime.backgroundTasks());
}

// ============================================================================
// Helpers
// ============================================================================

fn compressGzip(io: std.Io, data: []const u8, level: u8) ![]u8 {
    libdeflate.load(io);

    const compressor = libdeflate.Compressor.alloc(@intCast(level)) orelse return error.GzipInitFailed;
    defer compressor.deinit();

    const max_size = compressor.maxBytesNeeded(data, .gzip);

    // Use stack buffer for small data, heap for large
    const stack_threshold = 256 * 1024;
    var stack_buf: [stack_threshold]u8 = undefined;

    if (max_size <= stack_threshold) {
        const result = compressor.gzip(data, &stack_buf);
        if (result.status != .success) return error.GzipCompressFailed;
        return bun.default_allocator.dupe(u8, stack_buf[0..result.written]);
    }

    const output = try bun.default_allocator.alloc(u8, max_size);
    errdefer bun.default_allocator.free(output);

    const result = compressor.gzip(data, output);
    if (result.status != .success) return error.GzipCompressFailed;

    return bun.default_allocator.realloc(output, result.written) catch {
        const exact = try bun.default_allocator.dupe(u8, output[0..result.written]);
        bun.default_allocator.free(output);
        return exact;
    };
}

/// Check if a path is safe (no absolute paths or path traversal)
fn isSafePath(pathname: []const u8) bool {
    // Reject empty paths
    if (pathname.len == 0) return false;

    // Reject absolute paths
    if (pathname[0] == '/' or pathname[0] == '\\') return false;

    // Check for Windows drive letters (e.g., "C:")
    if (pathname.len >= 2 and pathname[1] == ':') return false;

    // Reject paths with ".." components
    var iter = std.mem.splitScalar(u8, pathname, '/');
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
        // Also check Windows-style separators
        var win_iter = std.mem.splitScalar(u8, component, '\\');
        while (win_iter.next()) |win_component| {
            if (std.mem.eql(u8, win_component, "..")) return false;
        }
    }

    return true;
}

/// Match a path against multiple glob patterns with support for negative patterns.
/// Positive patterns: at least one must match for the path to be included.
/// Negative patterns (starting with "!"): if any matches, the path is excluded.
/// Returns true if the path should be included, false if excluded.
fn matchGlobPatterns(patterns: []const []const u8, pathname: []const u8) bool {
    var has_positive_patterns = false;
    var matches_positive = false;

    for (patterns) |pattern| {
        // Check if it's a negative pattern
        if (pattern.len > 0 and pattern[0] == '!') {
            // Negative pattern - if it matches, exclude the file
            const neg_pattern = pattern[1..];
            if (neg_pattern.len > 0 and bun.glob.match(neg_pattern, pathname).matches()) {
                return false;
            }
        } else {
            // Positive pattern - at least one must match
            has_positive_patterns = true;
            if (bun.glob.match(pattern, pathname).matches()) {
                matches_positive = true;
            }
        }
    }

    // If there are no positive patterns, include everything (that wasn't excluded)
    // If there are positive patterns, at least one must match
    return !has_positive_patterns or matches_positive;
}

/// Extract archive to disk with glob pattern filtering.
/// Supports negative patterns with "!" prefix (e.g., "!node_modules/**").
fn extractToDiskFiltered(
    io: std.Io,
    file_buffer: []const u8,
    root: []const u8,
    glob_patterns: ?[]const []const u8,
) !u32 {
    const lib = libarchive.lib;
    const archive = lib.Archive.readNew();
    defer _ = archive.readFree();
    configureArchiveReader(archive);

    if (archive.readOpenMemory(file_buffer) != .ok) {
        return error.ReadError;
    }

    // Open/create target directory using bun.sys
    const cwd = bun.FD.cwd();
    cwd.makePath(io, u8, root) catch {};
    const dir_fd: bun.FD = brk: {
        if (std.fs.path.isAbsolute(root)) {
            break :brk bun.sys.openA(root, bun.O.RDONLY | bun.O.DIRECTORY, 0).unwrap() catch return error.OpenError;
        } else {
            break :brk bun.sys.openatA(cwd, root, bun.O.RDONLY | bun.O.DIRECTORY, 0).unwrap() catch return error.OpenError;
        }
    };
    defer _ = dir_fd.close();

    var count: u32 = 0;
    var entry: *lib.Archive.Entry = undefined;

    while (archive.readNextHeader(&entry) == .ok) {
        const pathname = entry.pathnameUtf8();

        // Validate path safety (reject absolute paths, path traversal)
        if (!isSafePath(pathname)) continue;

        // Apply glob pattern filtering. Supports negative patterns with "!" prefix.
        // Positive patterns: at least one must match
        // Negative patterns: if any matches, the file is excluded
        if (glob_patterns) |patterns| {
            if (!matchGlobPatterns(patterns, pathname)) continue;
        }

        const filetype = entry.filetype();
        const kind = bun.sys.kindFromMode(filetype);

        switch (kind) {
            .directory => {
                dir_fd.makePath(io, u8, pathname) catch |err| switch (err) {
                    // Directory already exists - don't count as extracted
                    error.PathAlreadyExists => continue,
                    else => continue,
                };
                count += 1;
            },
            .file => {
                const size: usize = @intCast(@max(entry.size(), 0));
                // Sanitize permissions: use entry perms masked to 0o777, or default 0o644
                const entry_perm = entry.perm();
                const mode: bun.Mode = if (entry_perm != 0)
                    @intCast(entry_perm & 0o777)
                else
                    0o644;

                // Create parent directories if needed (ignore expected errors)
                if (std.fs.path.dirname(pathname)) |parent_dir| {
                    dir_fd.makePath(io, u8, parent_dir) catch |err| switch (err) {
                        // Expected: directory already exists
                        error.PathAlreadyExists => {},
                        // Permission errors: skip this file, will fail at openat
                        error.AccessDenied => {},
                        // Other errors: skip, will fail at openat
                        else => {},
                    };
                }

                // Create and write the file using bun.sys
                const file_fd: bun.FD = bun.sys.openat(
                    dir_fd,
                    pathname,
                    bun.O.WRONLY | bun.O.CREAT | bun.O.TRUNC,
                    mode,
                ).unwrap() catch continue;

                var write_success = true;
                if (size > 0) {
                    // Read archive data and write to file
                    var remaining = size;
                    var buf: [64 * 1024]u8 = undefined;
                    while (remaining > 0) {
                        const to_read = @min(remaining, buf.len);
                        const read = archive.readData(buf[0..to_read]);
                        if (read <= 0) {
                            write_success = false;
                            break;
                        }
                        const bytes_read: usize = @intCast(read);
                        // Write all bytes, handling partial writes
                        var written: usize = 0;
                        while (written < bytes_read) {
                            const w = file_fd.write(buf[written..bytes_read]).unwrap() catch {
                                write_success = false;
                                break;
                            };
                            if (w == 0) {
                                write_success = false;
                                break;
                            }
                            written += w;
                        }
                        if (!write_success) break;
                        remaining -= bytes_read;
                    }
                }
                _ = file_fd.close();

                if (write_success) {
                    count += 1;
                } else {
                    // Remove partial file on failure
                    _ = dir_fd.unlinkat(pathname);
                }
            },
            .sym_link => {
                const link_target = entry.symlink();
                // Validate symlink target is also safe
                if (!isSafePath(link_target)) continue;
                // Symlinks are only extracted on POSIX systems (Linux/macOS).
                // On Windows, symlinks are skipped since they require elevated privileges.
                if (bun.Environment.isPosix) {
                    bun.sys.symlinkat(link_target, dir_fd, pathname).unwrap() catch |err| {
                        switch (err) {
                            error.EPERM, error.ENOENT => {
                                if (std.fs.path.dirname(pathname)) |parent| {
                                    dir_fd.makePath(io, u8, parent) catch {};
                                }
                                _ = bun.sys.symlinkat(link_target, dir_fd, pathname).unwrap() catch continue;
                            },
                            else => continue,
                        }
                    };
                    count += 1;
                }
            },
            else => {},
        }
    }

    return count;
}

const libarchive = @import("../../libarchive/libarchive.zig");
const libdeflate = @import("../../libdeflate_sys/libdeflate.zig");
const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;
const Store = @import("../webcore/blob/Store.zig");

const ArchiveBindingModule = bindgen.Module("Archive");
const ArchiveSchema = ArchiveBindingModule.class("Archive");
const ArchiveConstructorSchema = ArchiveSchema.constructor();
const ArchiveInspectSchema = ArchiveSchema.member("inspectCustom");
const ArchiveBlobNativeSchema = ArchiveSchema.member("blobNative");
const ArchiveBytesSchema = ArchiveSchema.member("bytes");
const ArchiveExtractSchema = ArchiveSchema.member("extract");
const ArchiveFilesNativeSchema = ArchiveSchema.member("filesNative");
const ArchiveWriteSchema = ArchiveSchema.member("write");
pub const Binding = bindgen.Class(ArchiveSchema, Archive);

comptime {
    _ = Binding;
}
