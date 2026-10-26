/// This implements the JavaScript SourceMap class from Node.js.
///
const JSSourceMap = @This();

bindgen_state: bindgen.ClassState = .{},
sourcemap: ParsedSourceMapRef,
strings: bindgen.OwnedNative(SourceMapStrings, .any),
payload: ?bindgen.Root = null,
line_lengths: ?bindgen.Root = null,

/// TODO: when we implement --enable-source-map CLI flag, set this to true.
pub var @"--enable-source-maps" = false;

fn findSourceMap(
    context: bindgen.CallContext(FindSourceMapSchema),
    args: bindgen.Args(FindSourceMapSchema),
) bindgen.CallError(FindSourceMapSchema)!bindgen.Return(FindSourceMapSchema) {

    // Node.js doesn't enable source maps by default.
    // In Bun, we do use them for almost all files since we transpile almost all files
    // If we enable this by default, we don't have a `payload` object since we don't internally create one.
    // This causes Next.js to emit errors like the below on start:
    //       .next/server/chunks/ssr/[root-of-the-server]__012ba519._.js: Invalid source map. Only conformant source maps can be used to filter stack frames. Cause: TypeError: payload is not an Object. (evaluating '"sections" in payload')
    if (!@"--enable-source-maps") {
        return null;
    }

    const source_url_input = args.source_url orelse return null;
    const converted_source_url = try source_url_input.convert(context);
    const source_url_view = switch (converted_source_url.value) {
        .string => |value| value,
        .ignored => return null,
    };
    const allocator = bun.default_allocator;
    var source_url = try source_url_view.toOwnedSlice(allocator);
    defer allocator.free(source_url);
    if (bun.strings.hasPrefix(source_url, "node:") or bun.strings.hasPrefix(source_url, "bun:") or bun.strings.hasPrefix(source_url, "data:")) {
        return null;
    }

    if (bun.strings.indexOf(source_url, "://")) |source_url_index| {
        if (bun.strings.eqlComptime(source_url[0..source_url_index], "file")) {
            var input = try bindgen.ThreadSafeDOMString.fromUTF8(source_url);
            defer input.deinit();
            var path = (try bindgen.Engine(URLPathFromFileURLSchema).call(.{ .input = input.operand() })) orelse {
                const message = try std.fmt.allocPrint(bun.default_allocator, "Invalid URL: {s}", .{source_url});
                defer bun.default_allocator.free(message);
                return context.fail(.invalid_url, try bindgen.DOMString.fromUTF8(message));
            };
            defer path.deinit();
            const path_bytes = try path.toOwnedSlice(allocator);
            allocator.free(source_url);
            source_url = path_bytes;
        }
    }

    const this = owned: {
        var source_map = try bun.api.SourceMapEngine.lookup(source_url) orelse return null;
        errdefer source_map.deinit();
        const known_sources = source_map.get().external_source_names;
        const sources = try allocator.alloc([]const u16, @max(known_sources.len, 1));
        var initialized: usize = 0;
        errdefer {
            for (sources[0..initialized]) |source| allocator.free(source);
            allocator.free(sources);
        }
        for (sources, 0..) |*source, index| {
            source.* = try bun.strings.toUTF16AllocForReal(allocator, if (known_sources.len == 0) source_url else known_sources[index], false, false);
            initialized += 1;
        }
        const strings = try allocator.create(SourceMapStrings);
        errdefer allocator.destroy(strings);
        strings.* = .{ .sources = sources };
        const instance = try allocator.create(JSSourceMap);
        instance.* = .{
            .sourcemap = .adopt(source_map.take()),
            .strings = .init(strings),
        };
        break :owned instance;
    };

    return try SourceMapClass.adoptResult(this, context);
}

fn copyStrings(
    input: anytype,
) bun.OOM![][]const u16 {
    var strings = std.array_list.Managed([]const u16).init(bun.default_allocator);
    errdefer {
        for (strings.items) |str| bun.default_allocator.free(str);
        strings.deinit();
    }

    if (input) |field| switch (field) {
        .values => |values| {
            try strings.ensureTotalCapacityPrecise(values.len());
            var iterator = values.iterator();
            while (iterator.next()) |item| {
                const units = try bun.default_allocator.alloc(u16, item.value.length());
                for (units, 0..) |*unit, index| unit.* = item.value.codeUnitAt(index).?;
                strings.appendAssumeCapacity(units);
            }
        },
        .ignored => {},
    };

    return strings.toOwnedSlice();
}

pub fn construct(
    context: bindgen.CallContext(SourceMapConstructorSchema),
    args: bindgen.Args(SourceMapConstructorSchema),
) bindgen.CallError(SourceMapConstructorSchema)!*JSSourceMap {
    const payload_root = try args.payload.source_identity.toRoot();
    errdefer {
        var root = payload_root;
        root.deinit();
    }
    var line_lengths: ?bindgen.Root = null;
    errdefer if (line_lengths) |*root| root.deinit();
    if (args.options) |input| switch (input) {
        .options => |options| {
            if (options.lineLengths) |field| {
                if (field) |value| line_lengths = try value.toRoot();
            }
        },
        .ignored => {},
    };

    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const mappings_str = try args.payload.mappings.toUTF8(arena_allocator);
    defer mappings_str.deinit();

    const owned_sources = try copyStrings(args.payload.sources);
    errdefer deinitStrings(owned_sources);
    const owned_names = try copyStrings(args.payload.names);
    errdefer deinitStrings(owned_names);

    // Parse the VLQ mappings
    const parse_result = bun.SourceMap.Mapping.parse(
        bun.default_allocator,
        mappings_str.slice(),
        null, // estimated_mapping_count
        std.math.cast(i32, owned_sources.len) orelse return error.OutOfMemory,
        null,
        .{ .allow_names = true, .sort = true },
    );

    var mapping_list = switch (parse_result) {
        .success => |parsed| parsed,
        .fail => |fail| {
            if (fail.err == error.OutOfMemory) return error.OutOfMemory;
            const message = if (fail.loc.toNullable()) |loc|
                try std.fmt.allocPrint(bun.default_allocator, "{s} at {d}", .{ fail.msg, loc.start })
            else
                try bun.default_allocator.dupe(u8, fail.msg);
            defer bun.default_allocator.free(message);
            return context.fail(.invalid_mappings, try bindgen.DOMString.fromUTF8(message));
        },
    };
    errdefer mapping_list.mappings.deinit(bun.default_allocator);

    const parsed = try bun.default_allocator.create(bun.SourceMap.ParsedSourceMap);
    errdefer bun.default_allocator.destroy(parsed);
    parsed.* = mapping_list;
    const strings = try bun.default_allocator.create(SourceMapStrings);
    errdefer bun.default_allocator.destroy(strings);
    strings.* = .{ .sources = owned_sources, .names = owned_names };
    const source_map = try bun.default_allocator.create(JSSourceMap);
    source_map.* = .{
        .sourcemap = .adopt(parsed),
        .strings = .init(strings),
        .payload = payload_root,
        .line_lengths = line_lengths,
    };

    return source_map;
}

pub fn memoryCost(this: *const JSSourceMap) usize {
    const strings = this.strings.get();
    var bytes = @sizeOf(JSSourceMap) + @sizeOf(SourceMapStrings) +
        (strings.sources.len + strings.names.len) * @sizeOf([]const u16) + this.sourcemap.get().memoryCost();
    for (strings.sources) |source| bytes += source.len * @sizeOf(u16);
    for (strings.names) |name| bytes += name.len * @sizeOf(u16);
    return bytes;
}

pub fn memoryUsage(this: *const JSSourceMap, _: bun.bindgen.MemoryUsageContext(.any)) usize {
    return this.memoryCost();
}

pub fn getPayload(
    this: *JSSourceMap,
    context: bindgen.CallContext(SourceMapPayloadSchema),
    _: bindgen.Args(SourceMapPayloadSchema),
) bun.JSError!bindgen.Return(SourceMapPayloadSchema) {
    return takeRoot(context, &this.payload);
}

pub fn getLineLengths(
    this: *JSSourceMap,
    context: bindgen.CallContext(SourceMapLineLengthsSchema),
    _: bindgen.Args(SourceMapLineLengthsSchema),
) bun.JSError!bindgen.Return(SourceMapLineLengthsSchema) {
    return takeRoot(context, &this.line_lengths);
}

fn takeRoot(context: anytype, value: *?bindgen.Root) bindgen.AnyResult {
    var root = value.* orelse return .initUndefined(context);
    value.* = null;
    return .fromOwnedRoot(&root, context);
}

fn mappingName(this: *const JSSourceMap, mapping: *const bun.SourceMap.Mapping) bun.OOM!?bindgen.DOMString {
    const name_index = mapping.nameIndex();
    if (name_index >= 0) {
        if (this.sourcemap.get().mappings.getName(name_index)) |name| {
            return try bindgen.DOMString.fromUTF8(name);
        } else {
            const index: usize = @intCast(name_index);
            if (index < this.strings.get().names.len) {
                return try bindgen.DOMString.fromUTF16(this.strings.get().names[index]);
            }
        }
    }
    return null;
}

fn sourceName(this: *const JSSourceMap, mapping: *const bun.SourceMap.Mapping) bun.OOM!?bindgen.DOMString {
    const source_index = mapping.sourceIndex();
    if (source_index >= 0 and @as(usize, @intCast(source_index)) < this.strings.get().sources.len) {
        return try bindgen.DOMString.fromUTF16(this.strings.get().sources[@intCast(source_index)]);
    }

    return null;
}

pub fn findOrigin(
    this: *JSSourceMap,
    _: bindgen.CallContext(SourceMapFindOriginSchema),
    args: bindgen.Args(SourceMapFindOriginSchema),
) bun.JSError!bindgen.Return(SourceMapFindOriginSchema) {
    const mapping = this.sourcemap.get().findMapping(.fromZeroBased(args.lineNumber), .fromZeroBased(args.columnNumber)) orelse
        return .{ .empty = .{} };
    var name = try mappingName(this, &mapping);
    errdefer if (name) |*value| value.deinit();
    var source = try sourceName(this, &mapping);
    errdefer if (source) |*value| value.deinit();
    return .{ .origin = .{
        .name = name,
        .line = mapping.originalLine(),
        .column = mapping.originalColumn(),
        .file_name = source,
    } };
}

pub fn findEntry(
    this: *JSSourceMap,
    _: bindgen.CallContext(SourceMapFindEntrySchema),
    args: bindgen.Args(SourceMapFindEntrySchema),
) bun.JSError!bindgen.Return(SourceMapFindEntrySchema) {
    const mapping = this.sourcemap.get().findMapping(.fromZeroBased(args.lineNumber), .fromZeroBased(args.columnNumber)) orelse
        return .{ .empty = .{} };
    var name = try mappingName(this, &mapping);
    errdefer if (name) |*value| value.deinit();
    var source = try sourceName(this, &mapping);
    errdefer if (source) |*value| value.deinit();
    return .{ .entry = .{
        .generated_line = mapping.generatedLine(),
        .generated_column = mapping.generatedColumn(),
        .original_line = mapping.originalLine(),
        .original_column = mapping.originalColumn(),
        .original_source = source,
        .name = name,
    } };
}

fn deinitStrings(strings: []const []const u16) void {
    for (strings) |value| bun.default_allocator.free(value);
    bun.default_allocator.free(strings);
}

fn deinit(this: *JSSourceMap) void {
    if (this.payload) |*payload| payload.deinit();
    if (this.line_lengths) |*line_lengths| line_lengths.deinit();
    this.strings.deinit();
    this.sourcemap.deinit();
    bun.destroy(this);
}

pub fn destroy(this: *JSSourceMap) void {
    this.deinit();
}

const bun = @import("bun");
const std = @import("std");

const bindgen = bun.bindgen;
const ParsedSourceMapRef = bindgen.RefNative(bun.SourceMap.ParsedSourceMap, .any);

const SourceMapStrings = struct {
    sources: []const []const u16 = &.{},
    names: []const []const u16 = &.{},

    pub fn destroy(strings: *SourceMapStrings) void {
        deinitStrings(strings.sources);
        deinitStrings(strings.names);
        bun.destroy(strings);
    }
};

const SourceMapBindingModule = bindgen.Module("SourceMap");
const URLPathFromFileURLSchema = bindgen.Module("urls").engineShim("urlPathFromFileURL");
const SourceMapSchema = SourceMapBindingModule.class("SourceMap");
const SourceMapConstructorSchema = SourceMapSchema.constructor();
const SourceMapFindEntrySchema = SourceMapSchema.member("findEntry");
const SourceMapFindOriginSchema = SourceMapSchema.member("findOrigin");
const SourceMapLineLengthsSchema = SourceMapSchema.member("lineLengths");
const SourceMapPayloadSchema = SourceMapSchema.member("payload");
const SourceMapClass = bindgen.Class(SourceMapSchema, JSSourceMap);
const NodeModuleModuleBindings = bun.bindgen.Module("NodeModuleModule");
const FindSourceMapSchema = NodeModuleModuleBindings.function("findSourceMap");
const FindSourceMapBinding = bun.bindgen.Fn(FindSourceMapSchema, findSourceMap);

comptime {
    _ = FindSourceMapBinding;
    _ = SourceMapClass;
}
