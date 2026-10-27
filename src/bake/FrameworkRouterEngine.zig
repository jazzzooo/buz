pub const Style = union(enum) {
    nextjs_pages,
    nextjs_app_ui,
    nextjs_app_routes,
    javascript_defined: bindgen.Callback(bindgen.CallbackSchema("FrameworkRouteStyleCallback")),

    pub fn fromArgument(value: anytype) bun.JSError!Style {
        return switch (value) {
            .preset => |preset| switch (preset) {
                .nextjs_pages => .nextjs_pages,
                .nextjs_app_ui => .nextjs_app_ui,
                .nextjs_app_routes => .nextjs_app_routes,
            },
            .callback => |callback| .{ .javascript_defined = try callback.toOwned() },
        };
    }

    pub fn deinit(style: *Style) void {
        switch (style.*) {
            .javascript_defined => |*callback| callback.deinit(),
            else => {},
        }
    }

    pub fn take(style: *Style) Style {
        const owned = style.*;
        style.* = .nextjs_pages;
        return owned;
    }

    pub fn toRouterStyle(style: Style, custom_index: u8) FrameworkRouter.Style {
        return switch (style) {
            .nextjs_pages => .nextjs_pages,
            .nextjs_app_ui => .nextjs_app_ui,
            .nextjs_app_routes => .nextjs_app_routes,
            .javascript_defined => .{ .custom = custom_index },
        };
    }

    pub fn parse(
        style: *const Style,
        file_path: []const u8,
        extension: []const u8,
        log: *TinyLog,
        allow_layouts: bool,
        allocator: Allocator,
    ) ParseError!?FrameworkRouter.ParsedPattern {
        bun.assert(file_path[0] == '/');
        return switch (style.*) {
            .nextjs_pages => BakeCore.parseNextJsPages(file_path, extension, log, allow_layouts, allocator),
            .nextjs_app_ui => BakeCore.parseNextJsApp(file_path, extension, log, allow_layouts, allocator, .ui),
            .nextjs_app_routes => BakeCore.parseNextJsApp(file_path, extension, log, allow_layouts, allocator, .routes),
            .javascript_defined => style.parseCustom(file_path, log, allocator),
        };
    }

    pub fn parseCustom(
        style: *const Style,
        file_path: []const u8,
        log: *TinyLog,
        allocator: Allocator,
    ) ParseError!?FrameworkRouter.ParsedPattern {
        const callback = switch (style.*) {
            .javascript_defined => |*callback| callback,
            else => unreachable,
        };
        var candidate_path = try bindgen.DOMString.fromUTF8(file_path);
        defer candidate_path.deinit();

        var invocation: @TypeOf(callback.*).Invocation = undefined;
        callback.beginInvocation(&invocation);
        defer invocation.deinit();
        var result = (try invocation.call(.{ .candidatePath = candidate_path.operand() })) orelse return null;
        defer result.pattern.deinit();
        const pattern = try result.pattern.toUTF8(allocator);
        defer pattern.deinit();
        return .{
            .kind = switch (result.type) {
                .route => .page,
                .layout => .layout,
                .extra => .extra,
            },
            .parts = try BakeCore.parseCustomPattern(pattern.slice(), log, allocator),
        };
    }
};

const JSFrameworkRouterState = struct {
    router: FrameworkRouter,
    root: []u8,
    style: Style,
    files: std.ArrayList(bun.String) = .empty,
    stored_parse_errors: std.ArrayList(struct {
        rel_path: []const u8,
        log: TinyLog,
    }) = .empty,

    fn init(options: anytype) bun.JSError!JSFrameworkRouterState {
        const root = try options.root.toUTF8(bun.default_allocator);
        defer root.deinit();

        var style = try Style.fromArgument(options.style);
        errdefer style.deinit();

        const abs_root = try std.fs.path.resolve(bun.default_allocator, &.{ bun.fs.FileSystem.instance.top_level_dir, root.slice() });
        errdefer bun.default_allocator.free(abs_root);

        const types = try bun.default_allocator.dupe(Type, &.{.{
            .abs_root = abs_root,
            .ignore_underscores = false,
            .extensions = &.{ ".tsx", ".ts", ".jsx", ".js" },
            .style = style.toRouterStyle(0),
            .allow_layouts = true,
            .client_file = undefined,
            .server_file = undefined,
            .server_file_string = null,
        }});
        errdefer bun.default_allocator.free(types);

        return .{
            .router = try FrameworkRouter.initEmpty(abs_root, types, bun.default_allocator),
            .root = abs_root,
            .style = style,
        };
    }

    fn deinit(this: *JSFrameworkRouterState) void {
        for (this.files.items) |file| file.deref();
        this.files.deinit(bun.default_allocator);

        for (this.stored_parse_errors.items) |item| bun.default_allocator.free(item.rel_path);
        this.stored_parse_errors.deinit(bun.default_allocator);

        this.style.deinit();
        this.router.deinit(bun.default_allocator);
        bun.default_allocator.free(this.root);
        this.* = undefined;
    }

    pub fn destroy(this: *JSFrameworkRouterState) void {
        this.deinit();
        bun.destroy(this);
    }
};

pub fn matchedParamsToRecord(params: *const MatchedParams, comptime Record: type) bun.OOM!Record {
    const Value = @FieldType(Record.Entry, "value");
    const Strings = @FieldType(Value, "strings");
    var entries: [MatchedParams.max_count]Record.Entry = undefined;
    var initialized: usize = 0;
    errdefer for (entries[0..initialized]) |*entry| entry.deinit();

    var grouped: [MatchedParams.max_count]bool = @splat(false);
    for (params.entries[0..params.len], 0..) |param, index| {
        if (grouped[index]) continue;
        var values: [MatchedParams.max_count][]const u8 = undefined;
        var value_count: usize = 0;
        for (params.entries[index..params.len], index..) |candidate, candidate_index| {
            if (!bun.strings.eql(candidate.key, param.key)) continue;
            values[value_count] = candidate.value;
            value_count += 1;
            grouped[candidate_index] = true;
        }
        var key = try bindgen.DOMString.fromUTF8(param.key);
        errdefer key.deinit();
        const value: Value = if (value_count == 1)
            .{ .string = try bindgen.DOMString.fromUTF8(values[0]) }
        else
            .{ .strings = try Strings.fromUTF8Slices(values[0..value_count]) };
        entries[initialized] = .{ .key = key, .value = value };
        initialized += 1;
    }
    return Record.fromOwnedSlice(entries[0..initialized]);
}

pub const JSFrameworkRouter = struct {
    bindgen_state: bindgen.ClassState = .{},
    state: JSFrameworkRouterOwnedState,

    pub fn construct(
        context: bindgen.CallContext(FrameworkFileSystemRouterConstructorSchema),
        args: bindgen.Args(FrameworkFileSystemRouterConstructorSchema),
    ) bindgen.CallError(FrameworkFileSystemRouterConstructorSchema)!*JSFrameworkRouter {
        const global = context.viewToken().globalObject();
        const options = args.options orelse return context.fail(.missing_options, {});
        const jsfr = bun.new(JSFrameworkRouter, .{
            .state = .init(bun.new(JSFrameworkRouterState, try JSFrameworkRouterState.init(&options))),
        });
        errdefer jsfr.deinit();

        try jsfr.state.get().router.scan(
            bun.default_allocator,
            Type.Index.init(0),
            &global.bunVM().transpiler.resolver,
            InsertionContext.wrap(JSFrameworkRouter, jsfr),
        );
        if (jsfr.state.get().stored_parse_errors.items.len > 0) {
            const errors = try context.engine(CreateScanErrorArraySchema).call(.{
                .length = jsfr.state.get().stored_parse_errors.items.len,
            });
            for (jsfr.state.get().stored_parse_errors.items, 0..) |*item, i| {
                const message_bytes = try std.fmt.allocPrint(bun.default_allocator, "Invalid route {f}: {s}", .{
                    bun.fmt.quote(item.rel_path),
                    item.log.message(),
                });
                defer bun.default_allocator.free(message_bytes);
                var message = try bindgen.DOMString.fromUTF8(message_bytes);
                defer message.deinit();
                try context.engine(AppendScanErrorSchema).call(.{
                    .array = errors.operand(context),
                    .index = @as(u32, @intCast(i)),
                    .message = message.operand(),
                });
            }
            try context.engine(ThrowScanAggregateErrorSchema).call(.{ .errors = errors.operand(context) });
            unreachable;
        }

        return jsfr;
    }

    pub fn matchNative(
        jsfr: *JSFrameworkRouter,
        _: bindgen.CallContext(FrameworkFileSystemRouterMatchNativeSchema),
        args: bindgen.Args(FrameworkFileSystemRouterMatchNativeSchema),
    ) bun.JSError!bindgen.Return(FrameworkFileSystemRouterMatchNativeSchema) {
        const path = try args.path.toUTF8(bun.default_allocator);
        defer path.deinit();

        var params_out: MatchedParams = undefined;
        if (jsfr.state.get().router.matchSlow(path.slice(), &params_out)) |index| {
            var sfb_buffer: [4096]u8 = undefined;
            var sfb: std.heap.BufferFirstAllocator = .init(&sfb_buffer, bun.default_allocator);
            const alloc = sfb.allocator();

            const MatchResult = @typeInfo(bindgen.Return(FrameworkFileSystemRouterMatchNativeSchema)).optional.child;
            const Params = @FieldType(MatchResult, "params");
            const RouteSequence = @FieldType(MatchResult, "route");

            var params = try matchedParamsToRecord(&params_out, Params);
            errdefer params.deinit();

            var segment_count: usize = 0;
            var current: ?Route.Index = index;
            while (current) |route_index| {
                segment_count += 1;
                current = jsfr.state.get().router.routePtr(route_index).parent.unwrap();
            }
            var segments = try RouteSequence.Builder.init(segment_count);
            errdefer segments.deinit();
            current = index;
            while (current) |route_index| {
                const route = jsfr.state.get().router.routePtr(route_index);
                segments.appendOwned(try jsfr.routeSegment(route, alloc));
                current = route.parent.unwrap();
            }

            var route = segments.finish();
            route.reverse();
            return .{
                .params = params,
                .hasParams = params_out.len != 0,
                .route = route,
            };
        }

        return null;
    }

    fn routeSegment(jsfr: *JSFrameworkRouter, route: *const Route, allocator: Allocator) bun.OOM!@FieldType(
        @typeInfo(bindgen.Return(FrameworkFileSystemRouterMatchNativeSchema)).optional.child,
        "route",
    ).Element {
        const Segment = @FieldType(
            @typeInfo(bindgen.Return(FrameworkFileSystemRouterMatchNativeSchema)).optional.child,
            "route",
        ).Element;
        var part = try partToDOMString(route.part, allocator);
        errdefer part.deinit();
        var page = try jsfr.fileIdToDOMString(route.file_page);
        errdefer if (page) |*value| value.deinit();
        var layout = try jsfr.fileIdToDOMString(route.file_layout);
        errdefer if (layout) |*value| value.deinit();
        return Segment{ .part = part, .page = page, .layout = layout };
    }

    fn fileIdToDOMString(jsfr: *JSFrameworkRouter, id: OpaqueFileId.Optional) bun.OOM!?bindgen.DOMString {
        const index = id.unwrap() orelse return null;
        return @as(?bindgen.DOMString, try bindgen.DOMString.fromBunString(jsfr.state.get().files.items[index.get()].dupeRef()));
    }

    pub fn toJSONNative(
        jsfr: *JSFrameworkRouter,
        _: bindgen.CallContext(FrameworkFileSystemRouterToJSONNativeSchema),
        _: bindgen.Args(FrameworkFileSystemRouterToJSONNativeSchema),
    ) bun.JSError!bindgen.Return(FrameworkFileSystemRouterToJSONNativeSchema) {
        var sfb_buffer: [4096]u8 = undefined;
        var sfb: std.heap.BufferFirstAllocator = .init(&sfb_buffer, bun.default_allocator);
        const alloc = sfb.allocator();
        const Result = bindgen.Return(FrameworkFileSystemRouterToJSONNativeSchema);
        const Entry = Result.Element;

        const routes = jsfr.state.get().router.routes.items;
        var entries = try Result.Builder.init(routes.len);
        errdefer entries.deinit();
        for (routes) |*route| {
            var entry = Entry{
                .part = try partToDOMString(route.part, alloc),
                .page = null,
                .layout = null,
                .parent = if (route.parent.unwrap()) |parent| @intCast(parent.get()) else null,
            };
            errdefer entry.part.deinit();
            entry.page = try jsfr.fileIdToDOMString(route.file_page);
            errdefer if (entry.page) |*value| value.deinit();
            entry.layout = try jsfr.fileIdToDOMString(route.file_layout);
            entries.appendOwned(entry);
        }

        return entries.finish();
    }

    fn deinit(this: *JSFrameworkRouter) void {
        this.state.deinit();
        bun.destroy(this);
    }

    pub fn destroy(this: *JSFrameworkRouter) void {
        this.deinit();
    }

    pub fn parseRoutePattern(
        context: bindgen.CallContext(FrameworkFileSystemRouterParseRoutePatternSchema),
        args: bindgen.Args(FrameworkFileSystemRouterParseRoutePatternSchema),
    ) bindgen.CallError(FrameworkFileSystemRouterParseRoutePatternSchema)!bindgen.Return(FrameworkFileSystemRouterParseRoutePatternSchema) {
        var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const filepath = try args.pattern.toUTF8(alloc);
        defer filepath.deinit();
        if (filepath.slice().len == 0 or filepath.slice()[0] != '/')
            return context.fail(.invalid_pattern, try bindgen.DOMString.fromUTF8("route pattern must start with '/'"));
        var style = try Style.fromArgument(args.style);
        defer style.deinit();

        var log = TinyLog.empty;
        const parsed = (style.parse(filepath.slice(), std.fs.path.extension(filepath.slice()), &log, true, alloc) catch |err| switch (err) {
            error.InvalidRoutePattern => {
                const message = try std.fmt.allocPrint(alloc, "{s} ({d}:{d})", .{ log.message(), log.cursor_at, log.cursor_len });
                return context.fail(.invalid_pattern, try bindgen.DOMString.fromUTF8(message));
            },
            else => |e| return e,
        }) orelse
            return null;

        var rendered = try std.Io.Writer.Allocating.initCapacity(alloc, filepath.slice().len);
        defer rendered.deinit();
        for (parsed.parts) |part| part.toStringForInternalUse(&rendered.writer) catch return error.OutOfMemory;

        const Result = @typeInfo(bindgen.Return(FrameworkFileSystemRouterParseRoutePatternSchema)).optional.child;
        return Result{
            .kind = switch (parsed.kind) {
                .page => .page,
                .layout => .layout,
                .extra => .extra,
            },
            .pattern = try bindgen.DOMString.fromUTF8(rendered.written()),
        };
    }

    fn partToDOMString(part: Part, temp_allocator: Allocator) bun.OOM!bindgen.DOMString {
        var rendered = std.Io.Writer.Allocating.init(temp_allocator);
        defer rendered.deinit();
        part.toStringForInternalUse(&rendered.writer) catch return error.OutOfMemory;
        return bindgen.DOMString.fromUTF8(rendered.written());
    }

    pub fn getFileIdForRouter(jsfr: *JSFrameworkRouter, abs_path: []const u8, _: Route.Index, _: Route.FileKind) !OpaqueFileId {
        const file = bun.String.cloneUTF8(abs_path);
        errdefer file.deref();
        try jsfr.state.get().files.append(bun.default_allocator, file);
        return OpaqueFileId.init(@intCast(jsfr.state.get().files.items.len - 1));
    }

    pub fn onRouterSyntaxError(jsfr: *JSFrameworkRouter, rel_path: []const u8, log: TinyLog) !void {
        const rel_path_dupe = try bun.default_allocator.dupe(u8, rel_path);
        errdefer bun.default_allocator.free(rel_path_dupe);
        try jsfr.state.get().stored_parse_errors.append(bun.default_allocator, .{
            .rel_path = rel_path_dupe,
            .log = log,
        });
    }

    pub fn onRouterCollisionError(
        jsfr: *JSFrameworkRouter,
        relative_path: []const u8,
        _: OpaqueFileId,
        file_kind: Route.FileKind,
    ) bun.OOM!void {
        var log = TinyLog.empty;
        log.write("Multiple {s} matching the same route pattern is ambiguous", .{switch (file_kind) {
            .page => "pages",
            .layout => "layouts",
        }});
        return jsfr.onRouterSyntaxError(relative_path, log);
    }

    pub fn parseCustomRoute(
        jsfr: *JSFrameworkRouter,
        style_index: u8,
        file_path: []const u8,
        log: *TinyLog,
        allocator: Allocator,
    ) ParseError!?FrameworkRouter.ParsedPattern {
        bun.assert(style_index == 0);
        return jsfr.state.get().style.parseCustom(file_path, log, allocator);
    }
};

pub const ParseError = bun.JSError || BakeCore.PatternParseError;

const std = @import("std");
const BakeCore = @import("./BakeCore.zig");

const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;

const FrameworkRouter = @import("./FrameworkRouter.zig");
const InsertionContext = FrameworkRouter.InsertionContext;
const MatchedParams = FrameworkRouter.MatchedParams;
const OpaqueFileId = FrameworkRouter.OpaqueFileId;
const Part = FrameworkRouter.Part;
const Route = FrameworkRouter.Route;
const TinyLog = FrameworkRouter.TinyLog;
const Type = FrameworkRouter.Type;
const Allocator = std.mem.Allocator;

const JSFrameworkRouterOwnedState = bindgen.OwnedNative(JSFrameworkRouterState, .vm);

const FrameworkFileSystemRouterBindingModule = bindgen.Module("FrameworkFileSystemRouter");
const FrameworkFileSystemRouterSchema = FrameworkFileSystemRouterBindingModule.class("FrameworkFileSystemRouter");
const FrameworkFileSystemRouterConstructorSchema = FrameworkFileSystemRouterSchema.constructor();
const FrameworkFileSystemRouterParseRoutePatternSchema = FrameworkFileSystemRouterBindingModule.function("parseRoutePattern");
const FrameworkFileSystemRouterMatchNativeSchema = FrameworkFileSystemRouterSchema.member("matchNative");
const FrameworkFileSystemRouterToJSONNativeSchema = FrameworkFileSystemRouterSchema.member("toJSONNative");
const CreateScanErrorArraySchema = FrameworkFileSystemRouterBindingModule.engineShim("createScanErrorArray");
const AppendScanErrorSchema = FrameworkFileSystemRouterBindingModule.engineShim("appendScanError");
const ThrowScanAggregateErrorSchema = FrameworkFileSystemRouterBindingModule.engineShim("throwScanAggregateError");
const FrameworkFileSystemRouterClass = bindgen.Class(FrameworkFileSystemRouterSchema, JSFrameworkRouter);
const FrameworkFileSystemRouterParseRoutePatternBinding = bindgen.Fn(
    FrameworkFileSystemRouterParseRoutePatternSchema,
    JSFrameworkRouter.parseRoutePattern,
);

comptime {
    _ = FrameworkFileSystemRouterClass;
    _ = FrameworkFileSystemRouterParseRoutePatternBinding;
}
