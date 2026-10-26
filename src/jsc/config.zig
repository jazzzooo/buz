pub fn configureTransformOptionsForBunVM(allocator: std.mem.Allocator, _args: api.TransformOptions) !api.TransformOptions {
    var args = _args;

    args.write = false;
    args.resolve = api.ResolveMode.lazy;
    return try configureTransformOptionsForBun(allocator, args);
}

pub fn configureTransformOptionsForBun(_: std.mem.Allocator, _args: api.TransformOptions) !api.TransformOptions {
    var args = _args;
    args.target = api.Target.bun;
    return args;
}

pub const OwnedMacroConfiguration = struct {
    arena: std.heap.ArenaAllocator,
    args: api.TransformOptions,
    environment: *bun.DotEnv.Loader.Snapshot,
    log: bun.logger.Log,

    pub fn create(args: api.TransformOptions, environment: *const bun.DotEnv.Loader, level: bun.logger.Log.Level) bun.OOM!*OwnedMacroConfiguration {
        const snapshot = try bun.default_allocator.create(OwnedMacroConfiguration);
        errdefer bun.default_allocator.destroy(snapshot);
        const owned_environment = try bun.DotEnv.Loader.Snapshot.create(environment);
        errdefer owned_environment.destroy();
        snapshot.* = .{
            .arena = .init(bun.default_allocator),
            .args = undefined,
            .environment = owned_environment,
            .log = bun.logger.Log.init(bun.default_allocator),
        };
        errdefer snapshot.arena.deinit();
        errdefer snapshot.log.deinit();
        snapshot.log.level = level;
        snapshot.args = try copyOptionValue(api.TransformOptions, snapshot.arena.allocator(), args);
        return snapshot;
    }

    pub fn destroy(snapshot: *OwnedMacroConfiguration) void {
        snapshot.log.deinit();
        snapshot.environment.destroy();
        snapshot.arena.deinit();
        bun.default_allocator.destroy(snapshot);
    }
};

fn copyOptionValue(comptime T: type, arena: std.mem.Allocator, source: T) bun.OOM!T {
    if (T == api.TransformOptions or T == api.Jsx or T == api.StringMap or T == api.LoaderMap) {
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names) |field| {
            @field(result, field) = try copyOptionValue(@FieldType(T, field), arena, @field(source, field));
        }
        return result;
    }
    if (T == []const u8) return arena.dupe(u8, source);
    if (T == [:0]const u8) return arena.dupeSentinel(u8, source, 0);
    if (T == []const api.Loader) return arena.dupe(api.Loader, source);
    if (T == []const []const u8) {
        const result = try arena.alloc([]const u8, source.len);
        for (source, result) |text, *copy| copy.* = try arena.dupe(u8, text);
        return result;
    }
    return switch (@typeInfo(T)) {
        .optional => |optional| if (source) |value| try copyOptionValue(optional.child, arena, value) else null,
        .bool, .int, .@"enum" => source,
        else => @compileError("transform option requires an explicit snapshot copy: " ++ @typeName(T)),
    };
}

test "macro configuration owns nested options and environment" {
    var key = "CONFIG".*;
    var value = "before".*;
    var directory = "/tmp".*;
    var loaders = [_]api.Loader{.tsx};
    var environment_map = bun.DotEnv.Map.init(std.testing.allocator);
    defer environment_map.map.deinit(std.testing.allocator);
    try environment_map.put(&key, &value);
    var environment = bun.DotEnv.Loader.init(&environment_map, std.testing.allocator);
    var args = std.mem.zeroes(api.TransformOptions);
    args.define = .{ .keys = &.{&key}, .values = &.{&value} };
    args.absolute_working_dir = &directory;
    args.feature_flags = &.{&key};
    args.loaders = .{ .extensions = &.{".custom"}, .loaders = &loaders };
    args.serve_plugins = &.{&value};
    args.allow_addons = false;
    const snapshot = try OwnedMacroConfiguration.create(args, &environment, .warn);
    defer snapshot.destroy();
    key[0] = 'X';
    value[0] = 'X';
    directory[1] = 'x';
    loaders[0] = .js;
    try std.testing.expectEqualStrings("CONFIG", snapshot.args.define.?.keys[0]);
    try std.testing.expectEqualStrings("before", snapshot.args.define.?.values[0]);
    try std.testing.expectEqualStrings("/tmp", snapshot.args.absolute_working_dir.?);
    try std.testing.expectEqualStrings("CONFIG", snapshot.args.feature_flags[0]);
    try std.testing.expectEqual(api.Loader.tsx, snapshot.args.loaders.?.loaders[0]);
    try std.testing.expectEqualStrings("before", snapshot.args.serve_plugins.?[0]);
    try std.testing.expectEqual(@as(?bool, false), snapshot.args.allow_addons);
    try std.testing.expectEqualStrings("before", snapshot.environment.loader.get("CONFIG").?);
}

const bun = @import("bun");
const std = @import("std");
const api = bun.schema.api;
