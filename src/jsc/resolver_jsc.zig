//! Host fns / C++ exports for `node:module` `_nodeModulePaths`. Extracted from
//! `resolver/resolver.zig` so `resolver/` has no JSC references.

fn bindNodeModulePaths(
    _: bun.bindgen.CallContext(NodeModulePathsSchema),
    args: bun.bindgen.Args(NodeModulePathsSchema),
) bun.JSError!bun.bindgen.Return(NodeModulePathsSchema) {
    const sliced = try args.path.toUTF8(bun.default_allocator);
    defer sliced.deinit();
    var paths = try nodeModulePaths(sliced.slice(), false);
    defer paths.deinit();
    return try bun.bindgen.Return(NodeModulePathsSchema).fromBunStrings(paths.list.items);
}

fn nodeModulePaths(in_str: []const u8, use_dirname: bool) bun.OOM!NodeModulePaths {
    var result = NodeModulePaths.init();
    errdefer result.deinit();

    const base_path = if (use_dirname) std.fs.path.dirname(in_str) orelse in_str else in_str;
    const buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(buf);

    const full_path = bun.path.joinAbsStringBuf(
        bun.fs.FileSystem.instance.top_level_dir,
        buf,
        &.{base_path},
        .auto,
    );
    const root_index = switch (bun.Environment.os) {
        .windows => std.fs.path.parsePathWindows(u8, full_path).root.len,
        else => 1,
    };
    var root_path: []const u8 = full_path[0..root_index];
    if (full_path.len > root_path.len) {
        var it = std.mem.splitBackwardsScalar(u8, full_path[root_index..], std.fs.path.sep);
        while (it.next()) |part| {
            if (strings.eqlComptime(part, "node_modules"))
                continue;

            const path = try bun.String.createFormat(
                "{s}{s}" ++ std.fs.path.sep_str ++ "node_modules",
                .{
                    root_path,
                    it.buffer[0 .. (if (it.index) |i| i + 1 else 0) + part.len],
                },
            );
            errdefer path.deref();
            try result.list.append(path);
        }
    }

    while (root_path.len > 0 and bun.path.Platform.auto.isSeparator(root_path[root_path.len - 1])) {
        root_path.len -= 1;
    }

    const root_module_path = try bun.String.createFormat(
        "{s}" ++ std.fs.path.sep_str ++ "node_modules",
        .{root_path},
    );
    errdefer root_module_path.deref();
    try result.list.append(root_module_path);

    return result;
}

fn bindResolverNodeModulePaths(
    _: bun.bindgen.CallContext(ResolverNodeModulePathsSchema),
    args: bun.bindgen.Args(ResolverNodeModulePathsSchema),
) bun.JSError!bun.bindgen.Return(ResolverNodeModulePathsSchema) {
    const path = try args.path.toUTF8(bun.default_allocator);
    defer path.deinit();
    var paths = try nodeModulePaths(path.slice(), args.useDirname);
    defer paths.deinit();
    return bun.bindgen.Return(ResolverNodeModulePathsSchema).fromBunStrings(paths.list.items);
}

const NodeModulePaths = struct {
    list: std.array_list.Managed(bun.String),

    fn init() NodeModulePaths {
        return .{ .list = .init(bun.default_allocator) };
    }

    fn deinit(this: *NodeModulePaths) void {
        for (this.list.items) |path| path.deref();
        this.list.deinit();
    }
};

comptime {
    _ = ResolverNodeModulePathsBinding;
    _ = NodeModulePathsBinding;
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const PathBindings = bun.bindgen.Module("Path");
const ResolverNodeModulePathsSchema = PathBindings.nativeExport("resolverNodeModulePaths");
const ResolverNodeModulePathsBinding = bun.bindgen.Fn(ResolverNodeModulePathsSchema, bindResolverNodeModulePaths);
const NodeModuleBindings = bun.bindgen.Module("NodeModuleModule");
const NodeModulePathsSchema = NodeModuleBindings.function("_nodeModulePaths");
const NodeModulePathsBinding = bun.bindgen.Fn(NodeModulePathsSchema, bindNodeModulePaths);
