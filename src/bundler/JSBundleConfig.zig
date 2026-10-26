pub fn configure(
    config: anytype,
    io: std.Io,
    log: *Logger.Log,
    engine_capabilities: Transpiler.EngineCapabilities,
    env: *bun.DotEnv.Loader,
    transpiler: *Transpiler,
    allocator: std.mem.Allocator,
) !void {
    transpiler.* = try bun.Transpiler.init(
        allocator,
        io,
        log,
        api.TransformOptions{
            .define = if (config.define.count() > 0) config.define.toAPI() else null,
            .entry_points = config.entry_points.keys(),
            .target = config.target.toAPI(),
            .absolute_working_dir = if (config.dir.list.items.len > 0)
                config.dir.sliceWithSentinel()
            else
                null,
            .inject = &.{},
            .external = config.external.keys(),
            .main_fields = &.{},
            .extension_order = &.{},
            .env_files = &.{},
            .conditions = config.conditions.map.keys(),
            .ignore_dce_annotations = config.ignore_dce_annotations,
            .drop = config.drop.map.keys(),
            .bunfig_path = "",
            .jsx = config.jsx,
        },
        engine_capabilities,
        env,
    );
    transpiler.options.env.behavior = config.env_behavior;
    transpiler.options.env.prefix = config.env_prefix.slice();
    transpiler.options.bundler_feature_flags = config.features.view();
    if (config.force_node_env != .unspecified) {
        transpiler.options.force_node_env = config.force_node_env;
    }

    transpiler.options.entry_points = config.entry_points.keys();
    transpiler.options.jsx = .{
        .factory = if (config.jsx.factory.len > 0)
            try options.JSX.Pragma.memberListToComponentsIfDifferent(allocator, &.{}, config.jsx.factory)
        else
            options.JSX.Pragma.Defaults.Factory,
        .fragment = if (config.jsx.fragment.len > 0)
            try options.JSX.Pragma.memberListToComponentsIfDifferent(allocator, &.{}, config.jsx.fragment)
        else
            options.JSX.Pragma.Defaults.Fragment,
        .runtime = config.jsx.runtime,
        .development = config.jsx.development,
        .package_name = if (config.jsx.import_source.len > 0) config.jsx.import_source else "react",
        .classic_import_source = if (config.jsx.import_source.len > 0) config.jsx.import_source else "react",
        .side_effects = config.jsx.side_effects,
        .parse = true,
        .import_source = .{
            .development = if (config.jsx.import_source.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/jsx-dev-runtime", .{config.jsx.import_source})
            else
                "react/jsx-dev-runtime",
            .production = if (config.jsx.import_source.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/jsx-runtime", .{config.jsx.import_source})
            else
                "react/jsx-runtime",
        },
    };
    transpiler.options.no_macros = config.no_macros;
    transpiler.options.loaders = try options.loadersFromTransformOptions(allocator, config.loaders, config.target);
    transpiler.options.entry_naming = config.names.entry_point.data;
    transpiler.options.chunk_naming = config.names.chunk.data;
    transpiler.options.asset_naming = config.names.asset.data;

    transpiler.options.output_format = config.format;
    transpiler.options.bytecode = config.bytecode;
    transpiler.options.compile = config.compile != null;
    if (config.compile) |compile_options| {
        transpiler.options.public_path = bun.StandaloneModuleGraph.targetBasePublicPath(
            compile_options.compile_target.os,
            "root/",
        );
    } else {
        transpiler.options.public_path = config.public_path.list.items;
    }

    transpiler.options.output_dir = config.outdir.slice();
    transpiler.options.root_dir = config.rootdir.slice();
    transpiler.options.minify_syntax = config.minify.syntax;
    transpiler.options.minify_whitespace = config.minify.whitespace;
    transpiler.options.minify_identifiers = config.minify.identifiers;
    transpiler.options.keep_names = config.minify.keep_names;
    transpiler.options.inlining = config.minify.syntax;
    transpiler.options.source_map = config.source_map;
    transpiler.options.packages = config.packages;
    transpiler.options.allow_unresolved = if (config.allow_unresolved) |*value|
        options.AllowUnresolved.fromStrings(value.keys())
    else
        .all;
    transpiler.options.code_splitting = config.code_splitting;
    transpiler.options.emit_dce_annotations = config.emit_dce_annotations orelse !config.minify.whitespace;
    transpiler.options.ignore_dce_annotations = config.ignore_dce_annotations;
    transpiler.options.css_chunking = config.css_chunking;
    transpiler.options.compile_to_standalone_html = standalone: {
        if (config.compile == null or config.target != .browser) break :standalone false;
        for (config.entry_points.keys()) |entry_point| {
            if (!bun.strings.hasSuffixComptime(entry_point, ".html")) break :standalone false;
        }
        break :standalone config.entry_points.count() > 0;
    };
    if (transpiler.options.compile_to_standalone_html) {
        transpiler.options.compile = false;
        config.compile.?.deinit();
        config.compile = null;
    }
    transpiler.options.banner = config.banner.slice();
    transpiler.options.footer = config.footer.slice();
    transpiler.options.react_fast_refresh = config.react_fast_refresh;
    transpiler.options.metafile = config.metafile;
    transpiler.options.metafile_json_path = config.metafile_json_path.slice();
    transpiler.options.metafile_markdown_path = config.metafile_markdown_path.slice();
    if (config.optimize_imports.count() > 0) {
        transpiler.options.optimize_imports = &config.optimize_imports;
    }

    if (transpiler.options.compile) {
        transpiler.options.emit_dce_annotations = false;
    }

    transpiler.configureLinker();
    try transpiler.configureDefines();

    if (!transpiler.options.production) {
        try transpiler.options.conditions.appendSlice(&.{"development"});
    }
    transpiler.resolver.env_loader = transpiler.env;
    transpiler.resolver.opts = transpiler.options;
}

const std = @import("std");

const bun = @import("bun");
const api = bun.schema.api;
const Logger = bun.logger;
const options = bun.options;
const Transpiler = bun.transpiler.Transpiler;
