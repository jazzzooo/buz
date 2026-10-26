pub const PluginRunner = struct {
    global_object: *jsc.JSGlobalObject,
    allocator: std.mem.Allocator,

    const ResolveSchema = bindgen.Module("ModuleLoader").engineShim("runOnResolvePlugins");
    pub const Target = bindgen.EngineArgumentType(ResolveSchema, "target");

    pub fn resolver(this: *PluginRunner) PluginResolver {
        return .{ .context = .init(this), .resolve_fn = resolve };
    }

    fn resolve(
        context: PluginResolver.Context,
        specifier: []const u8,
        importer: []const u8,
        _: *bun.logger.Log,
        _: bun.logger.Loc,
        target: PluginResolver.Target,
    ) bun.JSError!?Fs.Path {
        const this = context.get(*PluginRunner);
        const extracted_namespace = PluginResolver.extractNamespace(specifier);
        const has_namespace = extracted_namespace.len > 0 and !bun.strings.eqlComptime(extracted_namespace, "file");
        var namespace = try bindgen.DOMString.fromUTF8(if (has_namespace) extracted_namespace else "");
        defer namespace.deinit();
        var path = try bindgen.DOMString.fromUTF8(specifier[if (has_namespace) extracted_namespace.len + 1 else 0..]);
        defer path.deinit();
        var source = try bindgen.DOMString.fromUTF8(importer);
        defer source.deinit();
        var resolved = try this.run(&namespace, &path, &source, switch (target) {
            .browser => .browser,
            .bun => .bun,
            .node => .node,
        });
        defer bindgen.deinitReturn(ResolveSchema, &resolved);
        const result = if (resolved) |*value| value else return null;

        const path_bytes = try std.fmt.allocPrint(this.allocator, "{f}", .{result.path});
        errdefer this.allocator.free(path_bytes);
        const user_namespace = if (result.namespace_name) |*value| value.takeBunString() else bun.String.static("file");
        defer user_namespace.deref();
        const namespace_bytes = if (user_namespace.isEmpty() or user_namespace.eqlComptime("file"))
            "file"
        else if (user_namespace.eqlComptime("bun"))
            "bun"
        else if (user_namespace.eqlComptime("node"))
            "node"
        else
            try std.fmt.allocPrint(this.allocator, "{f}", .{user_namespace});
        return Fs.Path.initWithNamespace(path_bytes, namespace_bytes);
    }

    pub fn onResolveJSC(this: *const PluginRunner, namespace: bun.String, specifier: bun.String, importer: bun.String, target: Target) bun.JSError!?bun.String {
        var bound_namespace = if (namespace.isEmpty() or namespace.eqlComptime("file"))
            bindgen.DOMString.empty()
        else
            try bindgen.DOMString.fromBunString(namespace.dupeRef());
        defer bound_namespace.deinit();
        var bound_path = try bindgen.DOMString.fromBunString(specifier.dupeRef());
        defer bound_path.deinit();
        var bound_importer = try bindgen.DOMString.fromBunString(importer.dupeRef());
        defer bound_importer.deinit();
        var resolved = try this.run(&bound_namespace, &bound_path, &bound_importer, target);
        defer bindgen.deinitReturn(ResolveSchema, &resolved);
        const result = if (resolved) |*value| value else return null;

        const user_namespace = if (result.namespace_name) |*value| value.takeBunString() else bun.String.static("file");
        defer user_namespace.deref();
        const effective_namespace = if (user_namespace.isEmpty()) bun.String.static("file") else user_namespace;
        const combined = try std.fmt.allocPrint(this.allocator, "{f}:{f}", .{ effective_namespace, result.path });
        defer this.allocator.free(combined);
        var string = try bindgen.DOMString.fromUTF8(combined);
        return string.takeBunString();
    }

    fn run(
        this: *const PluginRunner,
        namespace: *const bindgen.DOMString,
        path: *const bindgen.DOMString,
        importer: *const bindgen.DOMString,
        target: Target,
    ) bun.JSError!bindgen.Return(ResolveSchema) {
        return bindgen.Engine(ResolveSchema).call(this.global_object, .{
            .namespaceName = namespace.operand(),
            .path = path.operand(),
            .source = importer.operand(),
            .target = target,
        });
    }
};

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
const Fs = bun.fs;
const jsc = bun.jsc;
const PluginResolver = @import("../bundler/PluginResolver.zig");
