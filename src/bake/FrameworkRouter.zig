//! Discovers routes from the filesystem, as instructed by the framework
//! configuration. Agnotic to all different paradigms. Supports incrementally
//! updating for DevServer, or serializing to a binary for use in production.

const FrameworkRouter = @This();

/// Metadata for route files is specified out of line, either in DevServer where
/// it is an IncrementalGraph(.server).FileIndex or the production build context
/// where it is an entrypoint index.
pub const OpaqueFileId = bun.GenericIndex(u32, opaque {});

/// Absolute path to root directory of the router.
root: []const u8,
types: []Type,
routes: std.ArrayList(Route),
/// Keys are full URL, with leading /, no trailing /
/// Value is Route Index
static_routes: StaticRouteMap,
/// A flat list of all dynamic patterns.
///
/// Used to detect routes that have the same effective URL. Examples:
/// - `/hello/[foo]/bar` and `/hello/[baz]`bar`
/// - `/(one)/abc/def` and `/(two)/abc/def`
///
/// Note that file that match to the same exact route are already caught as
/// errors since the Route cannot store a list of files. Examples:
/// - `/about/index.tsx` and `/about.tsx` with style `.nextjs-pages`
/// Key in this map is EncodedPattern.
///
/// Root files are not caught using this technique, since every route tree has a
/// root. This check is special cased.
// TODO: no code to sort this data structure
dynamic_routes: DynamicRouteMap,

/// Arena allocator for pattern strings.
///
/// This should be passed into `EncodedPattern.initFromParts` or should be the
/// allocator used to allocate `StaticRoute.route_path`.
///
/// Q: Why use this and not just free the strings for `EncodedPattern` and
///    `StaticRoute` manually?
///
/// A: Inside `fr.insert(...)` we iterate over `EncodedPattern/StaticRoute`,
///    turning them into a bunch of `Route.Part`s, and we discard the original
///    `EncodePattern/StaticRoute` structure.
///
///    In this process it's too easy to lose the original base pointer and
///    length of the entire allocation. So we'll just allocate everything in
///    this arena to ensure that everything gets freed.
///
///    Thank you to `AllocationScope` for catching this! Hell yeah!
pattern_string_arena: bun.ArenaAllocator,

/// The above structure is optimized for incremental updates, but
/// production has a different set of requirements:
/// - Trivially serializable to a binary file (no pointers)
/// - As little memory indirection as possible.
/// - Routes cannot be updated after serilaization.
pub const Serialized = struct {
    // TODO:
};

const StaticRouteMap = bun.StringArrayHashMap(Route.Index);
const DynamicRouteMap = std.array_hash_map.Custom(EncodedPattern, Route.Index, EncodedPattern.EffectiveURLContext, true);

/// A logical route, for which layouts are looked up on after resolving a route.
pub const Route = struct {
    part: Part,
    type: Type.Index,

    parent: Index.Optional,
    first_child: Route.Index.Optional,
    next_sibling: Route.Index.Optional,

    // Note: A route may be associated with no files, in which it is just a
    // construct for building the tree.
    file_page: OpaqueFileId.Optional = .none,
    file_layout: OpaqueFileId.Optional = .none,
    // file_not_found: OpaqueFileId.Optional = .none,

    /// Only used by DevServer, if this route is 1. navigatable & 2. has been requested at least once
    bundle: BakeCore.RouteBundleIndex.Optional = .none,

    inline fn filePtr(r: *Route, file_kind: FileKind) *OpaqueFileId.Optional {
        return &switch (file_kind) {
            inline else => |kind| @field(r, "file_" ++ @tagName(kind)),
        };
    }

    pub const FileKind = enum {
        page,
        layout,
        // not_found,
    };

    pub const Index = bun.GenericIndex(u31, Route);
};

/// Native code for `FrameworkFileSystemRouterType`
pub const Type = struct {
    abs_root: []const u8,
    prefix: []const u8 = "/",
    ignore_underscores: bool = false,
    ignore_dirs: []const []const u8 = &.{ ".git", "node_modules" },
    extensions: []const []const u8,
    style: Style,
    allow_layouts: bool,
    /// `FrameworkRouter` itself does not use this value.
    client_file: OpaqueFileId.Optional,
    /// `FrameworkRouter` itself does not use this value.
    server_file: OpaqueFileId,
    /// `FrameworkRouter` itself does not use this value.
    server_file_string: ?bun.String,

    pub fn rootRouteIndex(type_index: Index) Route.Index {
        return Route.Index.init(type_index.get());
    }

    pub const Index = bun.GenericIndex(u8, Type);
};

pub fn initEmpty(root: []const u8, types: []Type, allocator: Allocator) !FrameworkRouter {
    bun.assert(std.fs.path.isAbsolute(root));

    var routes = try std.ArrayList(Route).initCapacity(allocator, types.len);
    errdefer routes.deinit(allocator);

    for (types, 0..) |*ty, type_index| {
        ty.abs_root = bun.strings.withoutTrailingSlashWindowsPath(ty.abs_root);
        bun.assert(bun.strings.hasPrefix(ty.abs_root, root));

        routes.appendAssumeCapacity(.{
            .part = .{ .text = "" },
            .type = Type.Index.init(@intCast(type_index)),
            .parent = .none,
            .next_sibling = .none,
            .first_child = .none,
            .file_page = .none,
            .file_layout = .none,
            // .file_not_found = .none,
        });
    }
    return .{
        .root = bun.strings.withoutTrailingSlashWindowsPath(root),
        .types = types,
        .routes = routes,
        .dynamic_routes = .{},
        .static_routes = .{},
        .pattern_string_arena = bun.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(fr: *FrameworkRouter, allocator: Allocator) void {
    for (fr.types) |*router_type| {
        if (router_type.server_file_string) |server_file_string| server_file_string.deref();
    }
    fr.routes.deinit(allocator);
    fr.static_routes.deinit(allocator);
    fr.dynamic_routes.deinit(allocator);
    allocator.free(fr.types);
    fr.pattern_string_arena.deinit();
}

pub fn memoryCost(fr: *FrameworkRouter) usize {
    var cost: usize = @sizeOf(FrameworkRouter);
    cost += fr.routes.capacity * @sizeOf(Route);
    cost += StaticRouteMap.DataList.capacityInBytes(fr.static_routes.entries.capacity);
    cost += DynamicRouteMap.DataList.capacityInBytes(fr.dynamic_routes.entries.capacity);
    return cost;
}

pub fn scanAll(fr: *FrameworkRouter, allocator: Allocator, r: *Resolver, ctx: anytype) !void {
    for (fr.types, 0..) |ty, i| {
        _ = ty;
        try fr.scan(allocator, FrameworkRouter.Type.Index.init(@intCast(i)), r, ctx);
    }
}

/// Route patterns are serialized in a stable byte format so it can be treated
/// as a string, while easily decodable as []Part.
pub const EncodedPattern = struct {
    data: []const u8,

    /// `/` is represented by zero bytes
    pub const root: EncodedPattern = .{ .data = &.{} };

    pub fn patternSerializedLength(parts: []const Part) usize {
        var size: usize = 0;
        for (parts) |part| {
            size += @sizeOf(u32) + switch (part) {
                inline else => |t| t.len,
            };
        }
        return size;
    }

    pub fn initFromParts(parts: []const Part, allocator: Allocator) !EncodedPattern {
        const slice = try allocator.alloc(u8, patternSerializedLength(parts));
        var writer = std.Io.Writer.fixed(slice);
        for (parts) |part|
            part.writeAsSerialized(&writer) catch
                unreachable; // enough space
        bun.assert(writer.end == writer.buffer.len);
        return .{ .data = slice };
    }

    pub fn iterate(p: EncodedPattern) Iterator {
        return .{ .pattern = p, .offset = 0 };
    }

    const Iterator = struct {
        pattern: EncodedPattern,
        offset: usize,

        pub fn readWithSize(it: Iterator) struct { Part, usize } {
            const header: Part.SerializedHeader = @bitCast(mem.readInt(
                u32,
                it.pattern.data[it.offset..][0..@sizeOf(u32)],
                .little,
            ));
            return .{
                switch (header.tag) {
                    inline else => |tag| @unionInit(
                        Part,
                        @tagName(tag),
                        it.pattern.data[it.offset + @sizeOf(u32) ..][0..header.len],
                    ),
                },
                @sizeOf(u32) + header.len,
            };
        }

        pub fn peek(it: Iterator) Part {
            return it.readWithSize().@"0";
        }

        pub fn next(it: *Iterator) ?Part {
            if (it.offset >= it.pattern.data.len)
                return null;
            const part, const len = it.readWithSize();
            it.offset += len;
            return part;
        }
    };

    pub fn effectiveURLHash(k: EncodedPattern) usize {
        // The strategy is to write all bytes, then hash them. Avoiding
        // multiple hash calls on small chunks. Allocation is not needed
        // since the upper bound is known (file path limits)
        var stack_space: [std.fs.max_path_bytes * 2]u8 = undefined;
        var writer = std.Io.Writer.fixed(&stack_space);
        const w = &writer;
        var it = k.iterate();
        while (it.next()) |item| switch (item) {
            .text => |text| {
                w.writeAll("/") catch unreachable;
                w.writeAll(text) catch unreachable;
            },
            // param names are not visible
            .param => w.writeAll(":") catch unreachable,
            .catch_all => w.writeAll(":.") catch unreachable,
            .catch_all_optional => w.writeAll(":?") catch unreachable,
            // groups are completely unobservable
            .group => continue,
        };
        return bun.hash(writer.buffered());
    }

    fn matches(p: EncodedPattern, path: []const u8, params: *MatchedParams) bool {
        params.len = 0;
        var it = p.iterate();
        var i: usize = 1;
        while (it.next()) |part| {
            switch (part) {
                .text => |expect| {
                    if (path.len < i + expect.len or
                        !(path.len == i + expect.len or path[i + expect.len] == '/'))
                        return false;
                    if (!strings.eql(path[i..][0..expect.len], expect))
                        return false;
                    i += 1 + expect.len;
                },
                .param => |name| {
                    const end = strings.indexOfCharPos(path, '/', i) orelse path.len;
                    params.append(name, path[i..end], path);
                    i = if (end == path.len) end else end + 1;
                },
                .catch_all_optional, .catch_all => |name| {
                    // Capture remaining path segments as individual parameters
                    if (i < path.len) {
                        var segment_start = i;
                        while (segment_start < path.len) {
                            const segment_end = strings.indexOfCharPos(path, '/', segment_start) orelse path.len;
                            if (segment_start < segment_end) {
                                params.append(name, path[segment_start..segment_end], path);
                            }
                            segment_start = if (segment_end == path.len) segment_end else segment_end + 1;
                        }
                    }
                    return true;
                },
                .group => continue,
            }
        }
        return i == path.len;
    }

    pub const EffectiveURLContext = struct {
        pub fn hash(_: @This(), p: EncodedPattern) u32 {
            return @truncate(p.effectiveURLHash());
        }

        pub fn eql(_: @This(), a: EncodedPattern, b: EncodedPattern, _: usize) bool {
            return a.effectiveURLHash() == b.effectiveURLHash();
        }
    };
};

/// Wrapper around a slice to provide same interface to be used in `insert`
/// but with the allocation being backed by a plain string, which each
/// part separated by slashes.
const StaticPattern = struct {
    route_path: []const u8,

    pub fn iterate(p: StaticPattern) Iterator {
        return .{ .pattern = p, .offset = 0 };
    }

    const Iterator = struct {
        pattern: StaticPattern,
        offset: usize,

        pub fn readWithSize(it: Iterator) struct { Part, usize } {
            const next_i = bun.strings.indexOfCharPos(it.pattern.route_path, '/', it.offset + 1) orelse
                it.pattern.route_path.len;
            const text = it.pattern.route_path[it.offset + 1 .. next_i];
            return .{ .{ .text = text }, text.len + 1 };
        }

        pub fn peek(it: Iterator) Part {
            return it.readWithSize().@"0";
        }

        pub fn next(it: *Iterator) ?Part {
            if (it.offset >= it.pattern.route_path.len)
                return null;
            const part, const len = it.readWithSize();
            it.offset += len;
            return part;
        }
    };
};

pub const Part = BakeCore.RoutePart;

pub const ParsedPattern = BakeCore.ParsedPattern;

pub const Style = union(enum) {
    nextjs_pages,
    nextjs_app_ui,
    nextjs_app_routes,
    custom: u8,
};

pub const PatternParseError = BakeCore.PatternParseError;

const InsertError = error{ RouteCollision, OutOfMemory };
const InsertKind = enum {
    static,
    dynamic,

    fn Pattern(kind: InsertKind) type {
        return switch (kind) {
            .dynamic => EncodedPattern,
            .static => StaticPattern,
        };
    }
};

/// Insert a new file, potentially creating a Route for that file.
/// Moves ownership of EncodedPattern into the FrameworkRouter.
///
/// This function is designed so that any insertion order will create an
/// equivalent routing tree, but it does not guarantee that route indices
/// would match up if a different insertion order was picked.
pub fn insert(
    fr: *FrameworkRouter,
    alloc: Allocator,
    ty: Type.Index,
    comptime insertion_kind: InsertKind,
    pattern: insertion_kind.Pattern(),
    file_kind: Route.FileKind,
    file_path: []const u8,
    ctx: anytype,
    /// When `error.RouteCollision` is returned, this is set to the existing file index.
    out_colliding_file_id: *OpaqueFileId,
) InsertError!void {
    // The root route is the index of the type
    const root_route = Type.rootRouteIndex(ty);

    const new_route_index = brk: {
        var input_it = pattern.iterate();
        var current_part = input_it.next() orelse
            break :brk root_route;

        var route_index = root_route;
        var route = fr.routePtr(root_route);
        outer: while (true) {
            var next = route.first_child.unwrap();
            while (next) |current| {
                const child = fr.routePtr(current);
                if (current_part.eql(child.part)) {
                    current_part = input_it.next() orelse
                        break :brk current; // found it!

                    route_index = current;
                    route = fr.routePtr(current);
                    continue :outer;
                }
                next = fr.routePtr(next.?).next_sibling.unwrap() orelse
                    break;
            }

            // Must add to this child
            var new_route_index = try fr.newRoute(alloc, .{
                .part = current_part,
                .type = ty,
                .parent = route_index.toOptional(),
                .first_child = .none,
                .next_sibling = .none,
            });

            if (next) |attach| {
                fr.routePtr(attach).next_sibling = new_route_index.toOptional();
            } else {
                fr.routePtr(route_index).first_child = new_route_index.toOptional();
            }

            // Build each part out as another node in the routing graph. This makes
            // inserting routes simpler to implement, but could technically be avoided.
            while (input_it.next()) |next_part| {
                const newer_route_index = try fr.newRoute(alloc, .{
                    .part = next_part,
                    .type = ty,
                    .parent = new_route_index.toOptional(),
                    .first_child = .none,
                    .next_sibling = .none,
                });
                fr.routePtr(new_route_index).first_child = newer_route_index.toOptional();
                new_route_index = newer_route_index;
            }

            break :brk new_route_index;
        }
    };

    const file_id = try ctx.getFileIdForRouter(file_path, new_route_index, file_kind);

    const new_route = fr.routePtr(new_route_index);
    if (new_route.filePtr(file_kind).unwrap()) |existing| {
        if (existing == file_id) {
            return; // exact match already exists. Hot-reloading code hits this
        }
        out_colliding_file_id.* = existing;
        return error.RouteCollision;
    }
    new_route.filePtr(file_kind).* = file_id.toOptional();

    if (file_kind == .page) switch (insertion_kind) {
        .static => {
            const gop = try fr.static_routes.getOrPut(
                alloc,
                if (pattern.route_path.len == 0) "/" else pattern.route_path,
            );
            if (gop.found_existing) {
                @panic("TODO: propagate aliased route error");
            }
            gop.value_ptr.* = new_route_index;
        },
        .dynamic => {
            const gop = try fr.dynamic_routes.getOrPut(alloc, pattern);
            if (gop.found_existing) {
                @panic("TODO: propagate aliased route error");
            }
            gop.value_ptr.* = new_route_index;
        },
    };
}

/// An enforced upper bound of 64 unique patterns allows routing to use no heap allocation
pub const MatchedParams = struct {
    pub const max_count = 64;

    entries: [max_count]Entry = undefined,
    len: u8 = 0,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    fn append(self: *MatchedParams, key: []const u8, value: []const u8, path: []const u8) void {
        if (self.len >= max_count) {
            bun.Output.panic("Route pattern matched more than {d} parameters. Path: {s}", .{ max_count, path });
        }
        self.entries[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }
};

/// Fast enough for development to be seamless, but avoids building a
/// complicated data structure that production uses to efficiently map
/// urls to routes instead of this tree-traversal algorithm.
pub fn matchSlow(fr: *FrameworkRouter, path: []const u8, params: *MatchedParams) ?Route.Index {
    params.len = 0;

    bun.assert(path[0] == '/');
    if (fr.static_routes.get(path)) |static| {
        return static;
    }

    for (fr.dynamic_routes.keys(), 0..) |pattern, i| {
        if (pattern.matches(path, params)) {
            return fr.dynamic_routes.values()[i];
        }
    }

    return null;
}

pub fn routePtr(fr: *FrameworkRouter, i: Route.Index) *Route {
    return &fr.routes.items[i.get()];
}

pub fn typePtr(fr: *FrameworkRouter, i: Type.Index) *Type {
    return &fr.types[i.get()];
}

fn newRoute(fr: *FrameworkRouter, alloc: Allocator, route_data: Route) !Route.Index {
    const i = fr.routes.items.len;
    try fr.routes.append(alloc, route_data);
    return Route.Index.init(@intCast(i));
}

fn newEdge(fr: *FrameworkRouter, alloc: Allocator, edge_data: Route.Edge) !Route.Edge.Index {
    if (fr.freed_edges.pop()) |i| {
        fr.edges.items[i.get()] = edge_data;
        return i;
    } else {
        const i = fr.edges.items.len;
        try fr.edges.append(alloc, edge_data);
        return Route.Edge.Index.init(i);
    }
}

pub const TinyLog = BakeCore.TinyLog;

pub const InsertionContext = struct {
    pub fn wrap(comptime T: type, context: *T) Context(T) {
        comptime {
            if (!@hasDecl(T, "getFileIdForRouter")) @compileError(@typeName(T) ++ " must implement getFileIdForRouter");
            if (!@hasDecl(T, "onRouterSyntaxError")) @compileError(@typeName(T) ++ " must implement onRouterSyntaxError");
            if (!@hasDecl(T, "onRouterCollisionError")) @compileError(@typeName(T) ++ " must implement onRouterCollisionError");
            if (!@hasDecl(T, "parseCustomRoute")) @compileError(@typeName(T) ++ " must implement parseCustomRoute");
        }
        return .{ .context = context };
    }

    fn ParseResult(comptime T: type) type {
        return @typeInfo(@TypeOf(T.parseCustomRoute)).@"fn".return_type.?;
    }

    fn Context(comptime T: type) type {
        return struct {
            context: *T,

            pub fn getFileIdForRouter(self: @This(), abs_path: []const u8, associated_route: Route.Index, kind: Route.FileKind) bun.OOM!OpaqueFileId {
                return self.context.getFileIdForRouter(abs_path, associated_route, kind);
            }

            pub fn onRouterSyntaxError(self: @This(), rel_path: []const u8, log: TinyLog) bun.OOM!void {
                return self.context.onRouterSyntaxError(rel_path, log);
            }

            pub fn onRouterCollisionError(self: @This(), rel_path: []const u8, other_id: OpaqueFileId, file_kind: Route.FileKind) bun.OOM!void {
                return self.context.onRouterCollisionError(rel_path, other_id, file_kind);
            }

            pub fn parseCustomRoute(
                self: @This(),
                style_index: u8,
                file_path: []const u8,
                log: *TinyLog,
                allocator: Allocator,
            ) ParseResult(T) {
                return self.context.parseCustomRoute(style_index, file_path, log, allocator);
            }
        };
    }
};

pub fn scan(
    fw: *FrameworkRouter,
    alloc: Allocator,
    ty: Type.Index,
    r: *Resolver,
    ctx: anytype,
) !void {
    const t = &fw.types[ty.get()];
    bun.assert(!strings.hasSuffixComptime(t.abs_root, "/"));
    bun.assert(std.fs.path.isAbsolute(t.abs_root));
    const root_info = r.readDirInfoIgnoreError(t.abs_root) orelse
        return;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try fw.scanInner(alloc, t, ty, r, root_info, &arena_state, ctx);
}

fn scanInner(
    fr: *FrameworkRouter,
    alloc: Allocator,
    t: *const Type,
    t_index: Type.Index,
    r: *Resolver,
    dir_info: *const DirInfo,
    arena_state: *std.heap.ArenaAllocator,
    ctx: anytype,
) !void {
    const fs = r.fs;
    const fs_impl = &fs.fs;

    if (dir_info.getEntriesConst()) |entries| {
        var it = entries.data.iterator();
        outer: while (it.next()) |entry| {
            const file = entry.value_ptr.*;
            const base = file.base();
            switch (file.kind(fs_impl, false)) {
                .dir => {
                    if (t.ignore_underscores and bun.strings.hasPrefixComptime(base, "_"))
                        continue :outer;

                    for (t.ignore_dirs) |banned_dir| {
                        if (bun.strings.eqlLong(base, banned_dir, true)) {
                            continue :outer;
                        }
                    }

                    if (r.readDirInfoIgnoreError(fs.abs(&.{ file.dir, file.base() }))) |child_info| {
                        try fr.scanInner(alloc, t, t_index, r, child_info, arena_state, ctx);
                    }
                },
                .file => {
                    const ext = std.fs.path.extension(base);

                    if (t.extensions.len > 0) {
                        for (t.extensions) |allowed_ext| {
                            if (strings.eql(ext, allowed_ext)) break;
                        } else continue :outer;
                    }

                    const absolute_path = fs.abs(&.{ file.dir, file.base() });
                    const full_rel_path = try std.fs.path.relative(
                        arena_state.allocator(),
                        fr.root,
                        null,
                        fr.root,
                        absolute_path,
                    );
                    bun.path.platformToPosixInPlace(u8, full_rel_path);
                    const rel_path = if (t.abs_root.len == fr.root.len)
                        try std.fmt.allocPrint(arena_state.allocator(), "/{s}", .{full_rel_path})
                    else
                        full_rel_path[t.abs_root.len - fr.root.len - 1 ..];
                    var log = TinyLog.empty;
                    defer _ = arena_state.reset(.retain_capacity);
                    const parsed = (switch (t.style) {
                        .nextjs_pages => BakeCore.parseNextJsPages(rel_path, ext, &log, t.allow_layouts, arena_state.allocator()),
                        .nextjs_app_ui => BakeCore.parseNextJsApp(rel_path, ext, &log, t.allow_layouts, arena_state.allocator(), .ui),
                        .nextjs_app_routes => BakeCore.parseNextJsApp(rel_path, ext, &log, t.allow_layouts, arena_state.allocator(), .routes),
                        .custom => |style_index| ctx.parseCustomRoute(style_index, rel_path, &log, arena_state.allocator()),
                    } catch |err| switch (err) {
                        error.InvalidRoutePattern => {
                            log.cursor_at += @intCast(t.abs_root.len - fr.root.len);
                            try ctx.onRouterSyntaxError(full_rel_path, log);
                            continue :outer;
                        },
                        else => |e| return e,
                    }) orelse continue :outer;

                    if (parsed.kind == .page and t.ignore_underscores and bun.strings.hasPrefixComptime(base, "_"))
                        continue :outer;

                    var static_total_len: usize = 0;
                    var param_count: usize = 0;
                    for (parsed.parts) |part| {
                        switch (part) {
                            .text => |data| static_total_len += 1 + data.len,

                            .param,
                            .catch_all,
                            .catch_all_optional,
                            => param_count += 1,

                            .group => {},
                        }
                    }

                    if (param_count > 64) {
                        log.write("Pattern cannot have more than 64 param", .{});
                        try ctx.onRouterSyntaxError(full_rel_path, log);
                        continue :outer;
                    }

                    var out_colliding_file_id: OpaqueFileId = undefined;

                    const file_kind: Route.FileKind = switch (parsed.kind) {
                        .page => .page,
                        .layout => .layout,
                        .extra => @panic("TODO: associate extra files with route"),
                    };

                    const result = switch (param_count > 0) {
                        inline else => |has_dynamic_comptime| result: {
                            const pattern = if (has_dynamic_comptime)
                                try EncodedPattern.initFromParts(parsed.parts, fr.pattern_string_arena.allocator())
                            else static_route: {
                                const allocation = try fr.pattern_string_arena.allocator().alloc(u8, static_total_len);
                                var writer = std.Io.Writer.fixed(allocation);
                                for (parsed.parts) |part|
                                    switch (part) {
                                        .text => |data| {
                                            writer.writeAll("/") catch unreachable;
                                            writer.writeAll(data) catch unreachable;
                                        },
                                        .group => {},
                                        .param, .catch_all, .catch_all_optional => unreachable,
                                    };
                                bun.assert(writer.end == allocation.len);
                                break :static_route StaticPattern{ .route_path = allocation };
                            };

                            break :result fr.insert(
                                alloc,
                                t_index,
                                if (has_dynamic_comptime) .dynamic else .static,
                                pattern,
                                file_kind,
                                fs.abs(&.{ file.dir, file.base() }),
                                ctx,
                                &out_colliding_file_id,
                            );
                        },
                    };

                    result catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        error.RouteCollision => {
                            try ctx.onRouterCollisionError(
                                full_rel_path,
                                out_colliding_file_id,
                                file_kind,
                            );
                        },
                    };
                },
            }
        }
    }
}

const std = @import("std");
const BakeCore = @import("./BakeCore.zig");

const bun = @import("bun");
const strings = bun.strings;

const DirInfo = bun.resolver.DirInfo;
const Resolver = bun.resolver.Resolver;

const mem = std.mem;
const Allocator = mem.Allocator;
