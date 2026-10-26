const Framework = @This();

is_built_in_react: bool,
file_system_router_types: []FileSystemRouterType,
server_components: ?ServerComponents = null,
react_fast_refresh: ?ReactFastRefresh = null,
built_in_modules: bun.StringArrayHashMap(BuiltInModule) = .empty,

pub fn react(io: std.Io, arena: Allocator) !Framework {
    return .{
        .is_built_in_react = true,
        .server_components = .{
            .separate_ssr_graph = true,
            .server_runtime_import = "react-server-dom-bun/server",
        },
        .react_fast_refresh = .{},
        .file_system_router_types = try arena.dupe(FileSystemRouterType, &.{
            .{
                .root = "pages",
                .prefix = "/",
                .entry_client = "bun-framework-react/client.tsx",
                .entry_server = "bun-framework-react/server.tsx",
                .ignore_underscores = true,
                .ignore_dirs = &.{ "node_modules", ".git" },
                .extensions = &.{ ".tsx", ".jsx" },
                .style = .nextjs_pages,
                .allow_layouts = true,
            },
        }),
        .built_in_modules = bun.StringArrayHashMap(BuiltInModule).init(arena, &.{
            "bun-framework-react/client.tsx",
            "bun-framework-react/server.tsx",
            "bun-framework-react/ssr.tsx",
        }, if (Environment.codegen_embed) &.{
            .{ .code = @embedFile("./bun-framework-react/client.tsx") },
            .{ .code = @embedFile("./bun-framework-react/server.tsx") },
            .{ .code = @embedFile("./bun-framework-react/ssr.tsx") },
        } else &.{
            .{ .code = bun.runtimeEmbedFile(io, .src, "bake/bun-framework-react/client.tsx") },
            .{ .code = bun.runtimeEmbedFile(io, .src, "bake/bun-framework-react/server.tsx") },
            .{ .code = bun.runtimeEmbedFile(io, .src, "bake/bun-framework-react/ssr.tsx") },
        }) catch |err| bun.handleOom(err),
    };
}

pub fn auto(
    arena: Allocator,
    resolver: *bun.resolver.Resolver,
    file_system_router_types: []const FileSystemRouterType,
) !Framework {
    var framework = Framework.none;

    if (file_system_router_types.len > 0) {
        framework = try react(resolver.io, arena);
        arena.free(framework.file_system_router_types);
        framework.file_system_router_types = try arena.dupe(FileSystemRouterType, file_system_router_types);
    }

    if (resolveOrNull(resolver, "react-refresh/runtime")) |refresh| {
        framework.react_fast_refresh = .{ .import_source = refresh };
    } else if (resolveOrNull(resolver, "react")) |_| {
        framework.react_fast_refresh = .{ .import_source = "react-refresh/runtime/index.js" };
        try framework.built_in_modules.put(
            arena,
            "react-refresh/runtime/index.js",
            if (Environment.codegen_embed)
                .{ .code = @embedFile("node-fallbacks/react-refresh.js") }
            else
                .{ .code = bun.runtimeEmbedFile(resolver.io, .codegen, "node-fallbacks/react-refresh.js") },
        );
    }

    return framework;
}

pub const none: Framework = .{
    .is_built_in_react = false,
    .file_system_router_types = &.{},
    .server_components = null,
    .react_fast_refresh = null,
    .built_in_modules = .empty,
};

pub const FileSystemRouterType = struct {
    root: []const u8,
    prefix: []const u8,
    entry_server: []const u8,
    entry_client: ?[]const u8,
    ignore_underscores: bool,
    ignore_dirs: []const []const u8,
    extensions: []const []const u8,
    style: FrameworkRouter.Style,
    allow_layouts: bool,
};

pub const BuiltInModule = union(enum) {
    import: []const u8,
    code: []const u8,
};

pub const ServerComponents = struct {
    separate_ssr_graph: bool = false,
    server_runtime_import: []const u8,
    server_register_client_reference: []const u8 = "registerClientReference",
    server_register_server_reference: []const u8 = "registerServerReference",
    client_register_server_reference: []const u8 = "registerServerReference",
};

pub const ReactFastRefresh = struct {
    import_source: []const u8 = "react-refresh/runtime",
};

pub const react_install_command = "bun i react@experimental react-dom@experimental react-server-dom-bun react-refresh@experimental";

pub fn addReactInstallCommandNote(log: *bun.logger.Log) !void {
    try log.addMsg(.{
        .kind = .note,
        .data = bun.logger.rangeData(null, bun.logger.Range.none, "Install the built in react integration with \"" ++ react_install_command ++ "\""),
    });
}

pub fn resolve(framework: Framework, server: *bun.resolver.Resolver, client: *bun.resolver.Resolver, arena: Allocator) !Framework {
    var resolved = framework;
    var had_errors = false;

    if (resolved.react_fast_refresh) |*react_fast_refresh| {
        framework.resolveHelper(client, &react_fast_refresh.import_source, &had_errors, "react refresh runtime");
    }

    if (resolved.server_components) |*server_components| {
        framework.resolveHelper(server, &server_components.server_runtime_import, &had_errors, "server components runtime");
    }

    for (resolved.file_system_router_types) |*router| {
        router.root = try std.fs.path.resolve(arena, &.{ server.fs.top_level_dir, router.root });
        if (router.entry_client) |*entry_client| framework.resolveHelper(client, entry_client, &had_errors, "client side entrypoint");
        framework.resolveHelper(client, &router.entry_server, &had_errors, "server side entrypoint");
    }

    if (had_errors) return error.ModuleNotFound;
    return resolved;
}

inline fn resolveHelper(framework: *const Framework, resolver: *bun.resolver.Resolver, path: *[]const u8, had_errors: *bool, description: []const u8) void {
    if (framework.built_in_modules.get(path.*)) |module| {
        switch (module) {
            .import => |resolved| path.* = resolved,
            .code => {},
        }
        return;
    }

    var result = resolver.resolve(resolver.fs.top_level_dir, path.*, .stmt) catch |err| {
        bun.Output.err(err, "Failed to resolve '{s}' for framework ({s})", .{ path.*, description });
        had_errors.* = true;
        return;
    };
    path.* = result.path().?.text;
}

inline fn resolveOrNull(resolver: *bun.resolver.Resolver, path: []const u8) ?[]const u8 {
    return (resolver.resolve(resolver.fs.top_level_dir, path, .stmt) catch {
        resolver.log.reset();
        return null;
    }).pathConst().?.text;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const Environment = bun.Environment;

const FrameworkRouter = @import("./FrameworkRouter.zig");
