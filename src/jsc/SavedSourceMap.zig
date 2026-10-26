const SavedSourceMap = @This();

/// This is a pointer to the map located on the VirtualMachine struct
map: *HashTable,
io: std.Io,
mutex: std.Io.Mutex = .init,
next_registration: u64 = 1,

/// Decoded sync windows, guarded by `mutex` and invalidated before freeing a blob.
find_cache: InternalSourceMap.FindCache = .{},

pub fn init(this: *SavedSourceMap, io: std.Io, map: *HashTable) void {
    this.* = .{
        .io = io,
        .map = map,
    };

    this.map.lockPointers();
}

pub inline fn lock(map: *SavedSourceMap) void {
    map.mutex.lockUncancelable(map.io);
    map.map.unlockPointers();
}

pub inline fn unlock(map: *SavedSourceMap) void {
    map.map.lockPointers();
    map.mutex.unlock(map.io);
}

/// `InternalSourceMap` is the storage for runtime-transpiled modules.
/// `ParsedSourceMap` is materialized lazily from owned source-map input.
pub const Value = bun.TaggedPointerUnion(.{
    ParsedSourceMap,
    SourceMapInput,
    InternalSourceMap,
});

pub const MissingSourceMapNoteInfo = struct {
    pub var storage: bun.PathBuffer = undefined;
    pub var path: ?[]const u8 = null;
    pub var seen_invalid = false;

    pub fn print() void {
        if (seen_invalid) return;
        if (path) |note| {
            Output.note("missing sourcemaps for {s}", .{note});
            Output.note("consider bundling with '--sourcemap' to get unminified traces", .{});
        }
    }
};

pub fn putInput(this: *SavedSourceMap, path: []const u8, input: *SourceMapInput) bun.OOM!u64 {
    const stored_path = try StoredPath.create(path);
    errdefer stored_path.deref();
    this.lock();
    defer this.unlock();
    const registration = this.next_registration;
    const next = std.math.add(u64, registration, 1) catch return error.OutOfMemory;
    try this.putValueLocked(stored_path, Value.init(input), registration);
    this.next_registration = next;
    return registration;
}

pub fn removeRegistration(this: *SavedSourceMap, registration: u64, path: bun.bindgen.DOMStringView) void {
    this.lock();
    defer this.unlock();

    const entry = this.map.getEntryAdapted(path, PathLookup{}) orelse return;
    if (registration != 0 and entry.value_ptr.registration == registration) {
        this.removeValueLocked(entry.key_ptr.*);
    }
}

pub const StoredPath = struct {
    const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "references", StoredPath.destroy, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    bytes: []const u8,
    references: RefCount = .init(),

    fn create(path: []const u8) bun.OOM!*StoredPath {
        const bytes = try bun.default_allocator.dupe(u8, path);
        errdefer bun.default_allocator.free(bytes);
        const stored = try bun.default_allocator.create(StoredPath);
        stored.* = .{ .bytes = bytes };
        return stored;
    }

    fn destroy(path: *StoredPath) void {
        bun.default_allocator.free(path.bytes);
        bun.default_allocator.destroy(path);
    }
};

const Entry = struct {
    value: Value,
    path: *StoredPath,
    registration: u64,

    fn deinit(entry: Entry) void {
        entry.path.deref();
        destroyValue(entry.value);
    }
};

fn destroyValue(value: Value) void {
    if (value.get(ParsedSourceMap)) |map| {
        map.deref();
    } else if (value.get(SourceMapInput)) |input| {
        input.deref();
    } else if (value.get(InternalSourceMap)) |ism| {
        (InternalSourceMap{ .data = @as([*]u8, @ptrCast(ism)) }).deinit();
    }
}

pub const HashTable = bun.StringHashMap(Entry);

const PathLookup = struct {
    pub fn hash(_: @This(), path: anytype) u64 {
        return path.hashUTF8();
    }

    pub fn eql(_: @This(), path: anytype, key: []const u8) bool {
        if (@TypeOf(path) == bun.TextView) return path.eqlUTF8View(.{ .utf8 = key });
        return path.eqlUTF8(key);
    }
};

pub fn onSourceMapChunk(this: *SavedSourceMap, chunk: SourceMap.Chunk, source: *const logger.Source) anyerror!void {
    try this.putMappings(source, chunk.buffer);
}

pub const SourceMapHandler = js_printer.SourceMapHandler.For(SavedSourceMap, onSourceMapChunk);

pub fn deinit(this: *SavedSourceMap) void {
    {
        this.lock();
        defer this.unlock();

        var iter = this.map.valueIterator();
        while (iter.next()) |val| {
            val.deinit();
        }
    }

    this.map.unlockPointers();
    this.map.deinit();
}

pub fn putMappings(this: *SavedSourceMap, source: *const logger.Source, mappings: MutableString) !void {
    // --hot can re-read a file mid-rewrite (truncate + write) and transpile
    // a comment-only prefix into a 0-mapping map. Overwriting a real map
    // with that would make any still-unreported error from the previous
    // transpile remap against nothing and leak transpiled coords. A map
    // with no mappings can never answer a lookup, so dropping it is never
    // worse than installing it.
    if (mappings.list.items.len >= InternalSourceMap.header_size) {
        const incoming: InternalSourceMap = .{ .data = mappings.list.items.ptr };
        if (incoming.mappingCount() == 0) {
            this.lock();
            defer this.unlock();
            if (this.map.contains(source.path.text)) return;
        }
    }

    const blob = try bun.default_allocator.dupe(u8, mappings.list.items);
    errdefer bun.default_allocator.free(blob);
    try this.putValue(source.path.text, Value.init(bun.cast(*InternalSourceMap, blob.ptr)));
}

pub fn putValue(this: *SavedSourceMap, path: []const u8, value: Value) bun.OOM!void {
    const stored_path = try StoredPath.create(path);
    errdefer stored_path.deref();
    this.lock();
    defer this.unlock();

    try this.putValueLocked(stored_path, value, 0);
}

fn putValueLocked(this: *SavedSourceMap, stored_path: *StoredPath, value: Value, registration: u64) bun.OOM!void {
    const entry = try this.map.getOrPut(stored_path.bytes);
    this.find_cache.invalidateAll();
    entry.key_ptr.* = stored_path.bytes;
    if (entry.found_existing) entry.value_ptr.deinit();
    entry.value_ptr.* = .{ .value = value, .path = stored_path, .registration = registration };
}

fn removeValueLocked(this: *SavedSourceMap, path: []const u8) void {
    const entry = this.map.fetchRemove(path) orelse return;
    this.find_cache.invalidateAll();
    entry.value.deinit();
}

/// You must call `sourcemap.map.deref()` or you will leak memory
fn getWithContent(
    this: *SavedSourceMap,
    path: string,
    hint: SourceMap.ParseUrlResultHint,
) bun.OOM!SourceMap.ParseUrl {
    // This lock is for the hash table
    this.lock();

    // This mapping entry is only valid while the mutex is locked
    const mapping = this.map.getEntry(path) orelse {
        this.unlock();
        return .{};
    };

    switch (mapping.value_ptr.value.tag()) {
        @field(Value.Tag, @typeName(InternalSourceMap)) => {
            // Runtime-transpiled module. Wrap the blob in a refcounted
            // ParsedSourceMap shell (no VLQ decode, no Mapping.List) so callers
            // can hold a ref while the table mutates. The shell takes ownership
            // of the blob.
            defer this.unlock();
            const ism: InternalSourceMap = .{
                .data = @as([*]u8, @ptrCast(mapping.value_ptr.value.as(InternalSourceMap))),
            };
            const result = try bun.default_allocator.create(ParsedSourceMap);
            result.* = .{
                .ref_count = .init(),
                .input_line_count = ism.inputLineCount(),
                .internal = ism,
            };
            mapping.value_ptr.value = Value.init(result);
            result.ref();
            return .{ .map = result };
        },
        @field(Value.Tag, @typeName(ParsedSourceMap)) => {
            defer this.unlock();
            const map = mapping.value_ptr.value.as(ParsedSourceMap);
            map.ref();
            return .{ .map = map };
        },
        @field(Value.Tag, @typeName(SourceMapInput)) => {
            const input = mapping.value_ptr.value.as(SourceMapInput);
            input.ref();
            defer input.deref();
            const stored_path = mapping.value_ptr.path;
            stored_path.ref();
            defer stored_path.deref();
            const registration = mapping.value_ptr.registration;
            this.unlock();
            return this.loadInput(input, stored_path.bytes, registration, hint);
        },
        else => {
            if (Environment.allow_assert) {
                @panic("Corrupt pointer tag");
            }
            this.unlock();

            return .{};
        },
    }
}

fn loadInput(
    this: *SavedSourceMap,
    input: *SourceMapInput,
    path: []const u8,
    registration: u64,
    hint: SourceMap.ParseUrlResultHint,
) bun.OOM!SourceMap.ParseUrl {
    const parsed = try source_provider_jsc.getSourceMap(this.io, input, path, .none, hint) orelse SourceMap.ParseUrl{};

    this.lock();
    defer this.unlock();
    if (this.map.getEntry(path)) |entry| {
        if (entry.value_ptr.registration == registration and entry.value_ptr.value.get(SourceMapInput) == input) {
            if (parsed.map) |map| {
                map.ref();
                destroyValue(entry.value_ptr.value);
                entry.value_ptr.value = Value.init(map);
                this.find_cache.invalidateAll();
            } else {
                if (path.len <= MissingSourceMapNoteInfo.storage.len) {
                    const storage = MissingSourceMapNoteInfo.storage[0..path.len];
                    @memcpy(storage, path);
                    MissingSourceMapNoteInfo.path = storage;
                }
                this.removeValueLocked(path);
            }
        }
    }

    return parsed;
}

/// You must `deref()` the returned value or you will leak memory
pub fn get(this: *SavedSourceMap, path: string) bun.OOM!?*ParsedSourceMap {
    return (try this.getWithContent(path, .mappings_only)).map;
}

/// The returned path and value are borrowed until the mutex is released.
pub fn getEntryLocked(this: *SavedSourceMap, path: bun.TextView) ?Entry {
    return this.map.getAdapted(path, PathLookup{});
}

pub fn resolveMapping(
    this: *SavedSourceMap,
    path: []const u8,
    line: bun.Ordinal,
    column: bun.Ordinal,
    source_handling: SourceMap.SourceContentHandling,
) bun.OOM!?SourceMap.Mapping.Lookup {
    const parse = try this.getWithContent(path, switch (source_handling) {
        .no_source_contents => .mappings_only,
        .source_contents => .{ .all = .{ .line = @max(line.zeroBased(), 0), .column = @max(column.zeroBased(), 0) } },
    });
    const map = parse.map orelse {
        if (parse.source_contents) |contents| bun.default_allocator.free(contents);
        return null;
    };

    const mapping = parse.mapping orelse
        map.findMapping(line, column) orelse {
        map.deref();
        if (parse.source_contents) |contents| bun.default_allocator.free(contents);
        return null;
    };

    return .{
        .mapping = mapping,
        .source_map = map,
        .prefetched_source_code = parse.source_contents,
    };
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const MutableString = bun.MutableString;
const Output = bun.Output;
const js_printer = bun.js_printer;
const logger = bun.logger;

const SourceMap = bun.SourceMap;
const InternalSourceMap = SourceMap.InternalSourceMap;
const ParsedSourceMap = SourceMap.ParsedSourceMap;
const SourceMapInput = SourceMap.SourceMapInput;
const source_provider_jsc = @import("../sourcemap_jsc/SourceProviderEngine.zig");
