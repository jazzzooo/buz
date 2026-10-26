pub fn init(
    framework: *Framework,
    arena: std.mem.Allocator,
    io: std.Io,
    log: *bun.logger.Log,
    mode: BakeCore.Mode,
    renderer: BakeCore.Graph,
    out: *bun.transpiler.Transpiler,
    bundler_options: *const BuildConfig.Subset,
) !void {
    const source_map: bun.options.SourceMapOption = switch (mode) {
        .development => .external,
        else => .none,
    };

    return initWithOptions(
        framework,
        arena,
        io,
        log,
        mode,
        renderer,
        out,
        bundler_options,
        source_map,
        null,
        null,
        null,
    );
}

pub fn initWithOptions(
    framework: *Framework,
    arena: std.mem.Allocator,
    io: std.Io,
    log: *bun.logger.Log,
    mode: BakeCore.Mode,
    renderer: BakeCore.Graph,
    out: *bun.transpiler.Transpiler,
    bundler_options: *const BuildConfig.Subset,
    source_map: bun.options.SourceMapOption,
    minify_whitespace: ?bool,
    minify_syntax: ?bool,
    minify_identifiers: ?bool,
) !void {
    const JSAst = bun.ast;

    var ast_memory_allocator: JSAst.ASTMemoryAllocator = undefined;
    ast_memory_allocator.initWithoutStack(arena);
    var ast_scope = JSAst.ASTMemoryAllocator.Scope{
        .previous = JSAst.Stmt.Data.Store.memory_allocator,
        .current = &ast_memory_allocator,
    };
    ast_scope.enter();
    defer ast_scope.exit();

    out.* = try bun.Transpiler.init(
        arena,
        io,
        log,
        std.mem.zeroes(bun.schema.api.TransformOptions),
        .{
            .javascript_semantics = bun.jsc.JavaScriptSemanticsEngine.javascript_semantics,
            .macro_context_factory = MacroEngine.context_factory,
            .bytecode_generator = BundlerEngine.bytecode_generator,
        },
        null,
    );

    out.options.target = switch (renderer) {
        .client => .browser,
        .server, .ssr => .bun,
    };
    out.options.public_path = switch (renderer) {
        .client => DevServerProtocol.client_prefix,
        .server, .ssr => "",
    };
    out.options.entry_points = &.{};
    out.options.log = log;
    out.options.output_format = switch (mode) {
        .development => .internal_bake_dev,
        .production_dynamic, .production_static => .esm,
    };
    out.options.out_extensions = bun.StringHashMap([]const u8).init(out.allocator);
    out.options.hot_module_reloading = mode == .development;
    out.options.code_splitting = mode != .development;
    out.options.output_dir = "";

    out.options.react_fast_refresh = mode == .development and renderer == .client and framework.react_fast_refresh != null;
    out.options.server_components = framework.server_components != null;

    out.options.conditions = try bun.options.ESMConditions.init(
        arena,
        out.options.target.defaultConditions(),
        out.options.target.isServerSide(),
        bundler_options.conditions.keys(),
    );
    if (renderer == .server and framework.server_components != null) {
        try out.options.conditions.appendSlice(&.{"react-server"});
    }
    if (mode == .development) {
        try out.options.conditions.appendSlice(&.{"development"});
    }
    if (renderer == .server or renderer == .ssr) {
        try out.options.conditions.appendSlice(&.{"node"});
    }

    out.options.production = mode != .development;
    out.options.tree_shaking = mode != .development;
    out.options.minify_syntax = minify_syntax orelse (mode != .development);
    out.options.minify_identifiers = minify_identifiers orelse (mode != .development);
    out.options.minify_whitespace = minify_whitespace orelse (mode != .development);
    out.options.css_chunking = true;
    out.options.framework = framework;
    out.options.inline_entrypoint_import_meta_main = true;
    if (bundler_options.ignoreDCEAnnotations) |ignore| {
        out.options.ignore_dce_annotations = ignore;
    }

    out.options.source_map = source_map;
    if (bundler_options.env != ._none) {
        out.options.env.behavior = bundler_options.env;
        out.options.env.prefix = bundler_options.env_prefix orelse "";
    }
    out.resolver.opts = out.options;

    out.configureLinker();
    try out.configureDefines();

    out.options.jsx.development = mode == .development;

    try BakeCore.addImportMetaDefines(out.options.define, mode, switch (renderer) {
        .client => .client,
        .server, .ssr => .server,
    });

    if ((bundler_options.define.keys.len + bundler_options.drop.count()) > 0) {
        for (bundler_options.define.keys, bundler_options.define.values) |key, value| {
            const parsed = try bun.options.Define.Data.parse(key, value, false, false, log, arena);
            try out.options.define.insert(key, parsed);
        }

        for (bundler_options.drop.keys()) |drop_item| {
            if (drop_item.len > 0) {
                const parsed = try bun.options.Define.Data.parse(drop_item, "", true, true, log, arena);
                try out.options.define.insert(drop_item, parsed);
            }
        }
    }

    if (mode != .development) {
        out.options.entry_naming = "_bun/[hash].[ext]";
        out.options.chunk_naming = "_bun/[hash].[ext]";
        out.options.asset_naming = "_bun/[hash].[ext]";
    }

    out.resolver.opts = out.options;
}

const std = @import("std");

const bun = @import("bun");

const BakeCore = @import("./BakeCore.zig");
const BuildConfig = @import("./BuildConfig.zig");
const DevServerProtocol = @import("./DevServerProtocol.zig");
const Framework = @import("./Framework.zig");
const BundlerEngine = @import("../bundler/BundlerEngine.zig");
const MacroEngine = @import("../js_parser_jsc/MacroEngine.zig");
