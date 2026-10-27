const JSTranspiler = @This();

pub const getConstructor = TranspilerClass.constructor;

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    transpiler: bindgen.OwnedNative(JSTranspiler, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.transpiler.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(_: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(JSBinding) + @sizeOf(JSTranspiler);
    }

    pub fn construct(
        context: bindgen.CallContext(TranspilerConstructorSchema),
        args: bindgen.Args(TranspilerConstructorSchema),
    ) bindgen.CallError(TranspilerConstructorSchema)!*JSBinding {
        return bun.api.JSTranspilerEngine.construct(context, args);
    }

    pub fn scan(
        this: *JSBinding,
        context: bindgen.CallContext(TranspilerScanSchema),
        args: bindgen.Args(TranspilerScanSchema),
    ) bindgen.CallError(TranspilerScanSchema)!bindgen.Return(TranspilerScanSchema) {
        return this.transpiler.get().scan(
            context,
            args.code,
            args.loader,
        );
    }

    pub fn scanImports(
        this: *JSBinding,
        context: bindgen.CallContext(TranspilerScanImportsSchema),
        args: bindgen.Args(TranspilerScanImportsSchema),
    ) bindgen.CallError(TranspilerScanImportsSchema)!bindgen.Return(TranspilerScanImportsSchema) {
        return this.transpiler.get().scanImports(
            context,
            args.code,
            args.loader,
        );
    }

    pub fn transform(
        this: *JSBinding,
        context: bindgen.CallContext(TranspilerTransformSchema),
        args: bindgen.Args(TranspilerTransformSchema),
    ) bindgen.CallError(TranspilerTransformSchema)!void {
        try this.transpiler.get().transform(
            context,
            args.code,
            args.loader,
        );
    }

    pub fn transformSync(
        this: *JSBinding,
        context: bindgen.CallContext(TranspilerTransformSyncSchema),
        args: bindgen.Args(TranspilerTransformSyncSchema),
    ) bindgen.CallError(TranspilerTransformSyncSchema)!bindgen.DOMString {
        return this.transpiler.get().transformSync(
            context,
            args.code,
            args.loaderOrContext,
            args.context,
        );
    }
};

transpiler: bun.transpiler.Transpiler,
config: Config,
arena: bun.ArenaAllocator,
ref_count: RefCount = .initExactRefs(1),

const RefCount = bun.ptr.ThreadSafeRefCount(JSTranspiler, "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

const default_transform_options: api.TransformOptions = brk: {
    var opts = std.mem.zeroes(api.TransformOptions);
    opts.disable_hmr = true;
    opts.target = api.Target.browser;
    break :brk opts;
};

pub const Config = struct {
    defines: bindgen.OwnedNativeSlice(DefineEntry, .any) = .empty,
    external: bindgen.OwnedNativeSlice(bindgen.OwnedBytes, .any) = .empty,
    target: api.Target = .browser,
    source_map: @FieldType(api.TransformOptions, "source_map") = null,
    packages: @FieldType(api.TransformOptions, "packages") = null,
    default_loader: options.Loader = options.Loader.jsx,
    macros: bindgen.OwnedNativeSlice(MacroPackage, .any) = .empty,
    tsconfig: TSConfigSettings = .{},
    log: logger.Log,
    export_overrides: bindgen.OwnedNativeSlice(ExportOverride, .any) = .empty,
    allow_runtime: bool = false,
    auto_import_jsx: bool = false,
    inlining: bool = false,
    tree_shaking: bool = false,
    trim_unused_imports: ?bool = null,

    dead_code_elimination: bool = true,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    no_macros: bool = false,
    repl_mode: bool = false,

    pub fn fromSchema(
        this: *Config,
        context: bindgen.CallContext(TranspilerConstructorSchema),
        generated: anytype,
    ) bindgen.CallError(TranspilerConstructorSchema)!void {
        var json_cache: BundlerCache.Json = .{};
        if (generated.define) |*define| {
            var entries = try bindgen.OwnedNativeSlice(DefineEntry, .any).Builder.init(define.len());
            errdefer entries.deinit();
            for (0..define.len()) |index| {
                const entry = define.at(index).?;
                var key = try ownString(entry.key);
                errdefer key.deinit();
                entries.appendOwned(.{
                    .key = key,
                    .value = if (entry.value.length() == 0)
                        try bindgen.OwnedBytes.fromSlice("\"\"")
                    else
                        try ownString(entry.value),
                });
            }
            this.defines = entries.finish();
        }

        if (generated.external) |*external| {
            var externals = std.array_list.Managed(bindgen.OwnedBytes).init(bun.default_allocator);
            defer {
                for (externals.items) |*value| value.deinit();
                externals.deinit();
            }
            switch (external.*) {
                .string => |*value| {
                    if (value.length() > 0) {
                        try externals.ensureUnusedCapacity(1);
                        externals.appendAssumeCapacity(try ownString(value));
                    }
                },
                .strings => |*entries| {
                    try externals.ensureTotalCapacityPrecise(entries.len());
                    for (0..entries.len()) |index| {
                        const value = entries.at(index).?;
                        if (value.length() == 0) continue;
                        externals.appendAssumeCapacity(try ownString(value));
                    }
                },
            }
            this.external = .fromOwnedSlice(try externals.toOwnedSlice());
        }

        if (generated.loader) |loader| {
            const resolved = loaderFromBinding(loader);
            if (!resolved.isJavaScriptLike()) {
                return context.fail(.unsupported_loader, {});
            }
            this.default_loader = resolved;
        }

        if (generated.target) |target| {
            const resolved: Target = switch (target) {
                .browser => .browser,
                .bun => .bun,
                .bun_macro => .bun_macro,
                .node => .node,
            };
            this.target = resolved.toAPI();
        }

        if (generated.tsconfig) |*tsconfig| {
            const utf8 = try tsconfig.toUTF8(bun.default_allocator);
            defer utf8.deinit();
            if (utf8.length() > 0) {
                var arena = bun.ArenaAllocator.init(bun.default_allocator);
                defer arena.deinit();
                var ast_memory: JSAst.ASTMemoryAllocator = undefined;
                var ast_scope = ast_memory.enter(arena.allocator());
                defer ast_scope.exit();
                if (try TSConfigJSON.parse(
                    arena.allocator(),
                    &this.log,
                    &logger.Source.initPathString("tsconfig.json", utf8.slice()),
                    &json_cache,
                )) |parsed_tsconfig| {
                    defer parsed_tsconfig.deinit();
                    this.tsconfig = try TSConfigSettings.copy(parsed_tsconfig);
                }
            }
        }

        if (generated.macro) |*macro| switch (macro.*) {
            .enabled => |enabled| this.no_macros = !enabled,
            .map => |*map| macros: {
                const utf8 = try map.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                if (utf8.length() == 0) break :macros;
                var arena = bun.ArenaAllocator.init(bun.default_allocator);
                defer arena.deinit();
                var ast_memory: JSAst.ASTMemoryAllocator = undefined;
                var ast_scope = ast_memory.enter(arena.allocator());
                defer ast_scope.exit();
                const source = &logger.Source.initPathString("macros.json", utf8.slice());
                const json = (try json_cache.parseJSON(
                    &this.log,
                    source,
                    arena.allocator(),
                    .json,
                    false,
                )) orelse break :macros;
                const parsed = try PackageJSON.parseMacrosJSON(arena.allocator(), json, &this.log, source);
                this.macros = try MacroPackage.copyMap(parsed);
            },
        };

        if (generated.autoImportJSX) |flag| this.auto_import_jsx = flag;
        if (generated.allowBunRuntime) |flag| this.allow_runtime = flag;
        if (generated.inlining) |flag| this.inlining = flag;
        if (generated.minifyWhitespace) |flag| this.minify_whitespace = flag;
        if (generated.deadCodeElimination) |flag| this.dead_code_elimination = flag;
        if (generated.replMode) |flag| this.repl_mode = flag;

        if (generated.minify) |*minify| switch (minify.*) {
            .all => |all| {
                this.minify_whitespace = all;
                this.minify_syntax = all;
                this.minify_identifiers = all;
            },
            .options => |*minify_options| {
                if (minify_options.whitespace) |flag| this.minify_whitespace = flag;
                if (minify_options.syntax) |flag| this.minify_syntax = flag;
                if (minify_options.identifiers) |flag| this.minify_identifiers = flag;
            },
        };

        if (generated.sourcemap) |*sourcemap| switch (sourcemap.*) {
            .flag => |flag| this.source_map = if (flag)
                options.SourceMapOption.@"inline".toAPI()
            else
                options.SourceMapOption.none.toAPI(),
            .named => |named| {
                const resolved: options.SourceMapOption = switch (named) {
                    .none => .none,
                    .inlined => .@"inline",
                    .external => .external,
                    .linked => .linked,
                };
                this.source_map = resolved.toAPI();
            },
        };

        if (generated.packages) |packages| {
            const resolved: options.PackagesOption = switch (packages) {
                .bundle => .bundle,
                .external => .external,
            };
            this.packages = resolved.toAPI();
        }

        var tree_shaking: ?bool = generated.treeShaking;
        const trim_unused_imports: ?bool = generated.trimUnusedImports;

        if (generated.exports) |*exports| {
            var replacements = std.array_list.Managed(ExportOverride).init(bun.default_allocator);
            defer {
                for (replacements.items) |*replacement| replacement.deinit();
                replacements.deinit();
            }
            var replacement_indices = bun.StringHashMap(usize).init(bun.default_allocator);
            defer replacement_indices.deinit();

            if (exports.eliminate) |*eliminate| {
                for (0..eliminate.len()) |index| {
                    const name = eliminate.at(index).?;
                    if (name.length() == 0) continue;
                    try putExportOverride(&replacements, &replacement_indices, .{
                        .key = try ownString(name),
                        .value = .delete,
                    });
                }
            }

            if (exports.replace) |*replace| {
                for (0..replace.len()) |index| {
                    const entry = replace.at(index).?;

                    var key = try ownString(entry.key);
                    defer key.deinit();
                    if (!JSLexer.isIdentifier(key.slice())) {
                        return context.fail(
                            .invalid_export_identifier,
                            try invalidIdentifierMessage(key.slice()),
                        );
                    }

                    const value: ExportOverride.Value = switch (entry.value) {
                        .value => |*primitive| .{ .replace = try exportReplacementValue(primitive) },
                        .pair => |*pair| pair_value: {
                            if (pair.len() != 2) {
                                return context.fail(.invalid_export_replacement, {});
                            }

                            const name = pair.at(0).?;
                            const replacement = pair.at(1).?;

                            const name_text = switch (name) {
                                .text => |*text| text,
                                else => return context.fail(.invalid_export_replacement, {}),
                            };
                            var replacement_value = (try exportInjectValue(&replacement)) orelse {
                                return context.fail(.invalid_export_replacement, {});
                            };
                            errdefer replacement_value.deinit();

                            var owned_name = try ownString(name_text);
                            defer owned_name.deinit();
                            if (!JSLexer.isIdentifier(owned_name.slice())) {
                                return context.fail(
                                    .invalid_export_identifier,
                                    try invalidIdentifierMessage(owned_name.slice()),
                                );
                            }

                            break :pair_value .{ .inject = .{
                                .name = owned_name.take(),
                                .value = replacement_value,
                            } };
                        },
                    };
                    try putExportOverride(&replacements, &replacement_indices, .{
                        .key = key.take(),
                        .value = value,
                    });
                }
            }

            tree_shaking = tree_shaking orelse (replacements.items.len > 0);
            this.export_overrides = .fromOwnedSlice(try replacements.toOwnedSlice());
        }

        if (generated.logLevel) |log_level| {
            this.log.level = switch (log_level) {
                .verbose => .verbose,
                .debug => .debug,
                .info => .info,
                .warn => .warn,
                .err => .err,
            };
        }

        this.tree_shaking = tree_shaking orelse false;
        this.trim_unused_imports = trim_unused_imports orelse this.tree_shaking;
    }

    fn materializeExportOverrides(this: *const Config, allocator: std.mem.Allocator) bun.OOM!Runtime.Features.ReplaceableExport.Map {
        var replacements: Runtime.Features.ReplaceableExport.Map = .empty;
        errdefer replacements.deinit(allocator);
        try replacements.ensureUnusedCapacity(allocator, this.export_overrides.slice().len);
        for (this.export_overrides.slice()) |*replacement| {
            const native_value: Runtime.Features.ReplaceableExport = switch (replacement.value) {
                .delete => .{ .delete = {} },
                .replace => |*value| .{ .replace = try value.toExpr(allocator) },
                .inject => |*value| .{ .inject = .{
                    .name = value.name.slice(),
                    .value = try value.value.toExpr(allocator),
                } },
            };
            replacements.putAssumeCapacityNoClobber(replacement.key.slice(), native_value);
        }
        return replacements;
    }

    fn transformOptions(this: *const Config, arena: std.mem.Allocator) bun.OOM!api.TransformOptions {
        var result = default_transform_options;
        result.target = this.target;
        result.source_map = this.source_map;
        result.packages = this.packages;
        const definitions = this.defines.slice();
        if (definitions.len > 0) {
            const keys = try arena.alloc([]const u8, definitions.len);
            const values = try arena.alloc([]const u8, definitions.len);
            for (definitions, keys, values) |*entry, *key, *value| {
                key.* = entry.key.slice();
                value.* = entry.value.slice();
            }
            result.define = .{ .keys = keys, .values = values };
        }
        const external = this.external.slice();
        const paths = try arena.alloc([]const u8, external.len);
        for (external, paths) |*entry, *path| path.* = entry.slice();
        result.external = paths;
        return result;
    }

    fn materializeMacros(this: *const Config, arena: std.mem.Allocator) bun.OOM!MacroMap {
        var result: MacroMap = .empty;
        try result.ensureUnusedCapacity(arena, this.macros.slice().len);
        for (this.macros.slice()) |*package| {
            var imports: MacroImportReplacementMap = .empty;
            try imports.ensureUnusedCapacity(arena, package.imports.slice().len);
            for (package.imports.slice()) |*entry| {
                imports.putAssumeCapacityNoClobber(entry.name.slice(), entry.path.slice());
            }
            result.putAssumeCapacityNoClobber(package.path.slice(), imports);
        }
        return result;
    }

    fn deinit(this: *Config) void {
        this.log.deinit();
        this.defines.deinit();
        this.external.deinit();
        this.export_overrides.deinit();
        this.macros.deinit();
        this.tsconfig.deinit();
    }
};

const DefineEntry = struct {
    key: bindgen.OwnedBytes,
    value: bindgen.OwnedBytes,

    pub fn deinit(this: *DefineEntry) void {
        this.key.deinit();
        this.value.deinit();
    }
};

const OwnedStrings = bindgen.OwnedNativeSlice(bindgen.OwnedBytes, .any);

fn copyStrings(source: []const []const u8) bun.OOM!OwnedStrings {
    var values = try OwnedStrings.Builder.init(source.len);
    errdefer values.deinit();
    for (source) |text| values.appendOwned(try bindgen.OwnedBytes.fromSlice(text));
    return values.finish();
}

fn stringViews(source: *const OwnedStrings, arena: std.mem.Allocator) bun.OOM![]const []const u8 {
    const values = try arena.alloc([]const u8, source.slice().len);
    for (source.slice(), values) |*text, *value| value.* = text.slice();
    return values;
}

const TSConfigSettings = struct {
    jsx_factory: ?OwnedStrings = null,
    jsx_fragment: ?OwnedStrings = null,
    jsx_import_source: ?ImportSource = null,
    jsx_runtime: ?options.JSX.Runtime = null,
    jsx_development: ?bool = null,
    emit_decorator_metadata: bool = false,
    experimental_decorators: bool = false,

    const ImportSource = struct {
        development: bindgen.OwnedBytes,
        production: bindgen.OwnedBytes,

        fn copy(source: options.JSX.Pragma.ImportSource) bun.OOM!ImportSource {
            var development = try bindgen.OwnedBytes.fromSlice(source.development);
            errdefer development.deinit();
            return .{
                .development = development,
                .production = try bindgen.OwnedBytes.fromSlice(source.production),
            };
        }

        fn deinit(this: *ImportSource) void {
            this.development.deinit();
            this.production.deinit();
        }
    };

    fn copy(source: *const TSConfigJSON) bun.OOM!TSConfigSettings {
        var result: TSConfigSettings = .{
            .emit_decorator_metadata = source.emit_decorator_metadata,
            .experimental_decorators = source.experimental_decorators,
        };
        errdefer result.deinit();
        if (source.jsx_flags.contains(.factory)) result.jsx_factory = try copyStrings(source.jsx.factory);
        if (source.jsx_flags.contains(.fragment)) result.jsx_fragment = try copyStrings(source.jsx.fragment);
        if (source.jsx_flags.contains(.import_source)) result.jsx_import_source = try ImportSource.copy(source.jsx.import_source);
        if (source.jsx_flags.contains(.runtime)) result.jsx_runtime = source.jsx.runtime;
        if (source.jsx_flags.contains(.development)) result.jsx_development = source.jsx.development;
        return result;
    }

    fn apply(this: *const TSConfigSettings, base: options.JSX.Pragma, arena: std.mem.Allocator) bun.OOM!options.JSX.Pragma {
        var result = base;
        if (this.jsx_factory) |*factory| result.factory = try stringViews(factory, arena);
        if (this.jsx_fragment) |*fragment| result.fragment = try stringViews(fragment, arena);
        if (this.jsx_import_source) |*source| {
            result.import_source = .{
                .development = source.development.slice(),
                .production = source.production.slice(),
            };
        }
        if (this.jsx_runtime) |runtime| result.runtime = runtime;
        if (this.jsx_development) |development| result.development = development;
        return result;
    }

    fn deinit(this: *TSConfigSettings) void {
        if (this.jsx_factory) |*factory| factory.deinit();
        if (this.jsx_fragment) |*fragment| fragment.deinit();
        if (this.jsx_import_source) |*source| source.deinit();
        this.* = .{};
    }
};

const MacroPackage = struct {
    path: bindgen.OwnedBytes,
    imports: bindgen.OwnedNativeSlice(Import, .any),

    const Import = struct {
        name: bindgen.OwnedBytes,
        path: bindgen.OwnedBytes,

        pub fn deinit(this: *Import) void {
            this.name.deinit();
            this.path.deinit();
        }
    };

    fn copyImports(source: MacroImportReplacementMap) bun.OOM!bindgen.OwnedNativeSlice(Import, .any) {
        var imports = try bindgen.OwnedNativeSlice(Import, .any).Builder.init(source.count());
        errdefer imports.deinit();
        for (source.keys(), source.values()) |key, path| {
            var name = try bindgen.OwnedBytes.fromSlice(key);
            errdefer name.deinit();
            imports.appendOwned(.{ .name = name, .path = try bindgen.OwnedBytes.fromSlice(path) });
        }
        return imports.finish();
    }

    fn copyMap(source: MacroMap) bun.OOM!bindgen.OwnedNativeSlice(MacroPackage, .any) {
        var packages = try bindgen.OwnedNativeSlice(MacroPackage, .any).Builder.init(source.count());
        errdefer packages.deinit();
        for (source.keys(), source.values()) |key, imports| {
            var path = try bindgen.OwnedBytes.fromSlice(key);
            errdefer path.deinit();
            packages.appendOwned(.{ .path = path, .imports = try copyImports(imports) });
        }
        return packages.finish();
    }

    pub fn deinit(this: *MacroPackage) void {
        this.path.deinit();
        this.imports.deinit();
    }
};

const ExportValue = union(enum) {
    text: bindgen.OwnedBytes,
    number: f64,
    flag: bool,
    null_value,
    undefined_value,

    fn toExpr(this: *const ExportValue, allocator: std.mem.Allocator) bun.OOM!JSAst.Expr {
        return switch (this.*) {
            .text => |*text| try stringExpr(text.slice(), allocator),
            .number => |value| .{ .data = .{ .e_number = .{ .value = value } }, .loc = logger.Loc.Empty },
            .flag => |value| .{ .data = .{ .e_boolean = .{ .value = value } }, .loc = logger.Loc.Empty },
            .null_value => .{ .data = .{ .e_null = .{} }, .loc = logger.Loc.Empty },
            .undefined_value => .{ .data = .{ .e_undefined = .{} }, .loc = logger.Loc.Empty },
        };
    }

    fn deinit(this: *ExportValue) void {
        if (this.* == .text) this.text.deinit();
        this.* = .undefined_value;
    }
};

const ExportOverride = struct {
    key: bindgen.OwnedBytes,
    value: Value,

    const Value = union(enum) {
        delete,
        replace: ExportValue,
        inject: struct { name: bindgen.OwnedBytes, value: ExportValue },

        fn deinit(this: *Value) void {
            switch (this.*) {
                .delete => {},
                .replace => |*value| value.deinit(),
                .inject => |*value| {
                    value.name.deinit();
                    value.value.deinit();
                },
            }
            this.* = .delete;
        }
    };

    fn take(this: *ExportOverride) ExportOverride {
        const result = this.*;
        this.* = .{ .key = .empty(), .value = .delete };
        return result;
    }

    pub fn deinit(this: *ExportOverride) void {
        this.key.deinit();
        this.value.deinit();
    }
};

/// Consumes value on both success and failure.
fn putExportOverride(list: *std.array_list.Managed(ExportOverride), indices: *bun.StringHashMap(usize), value: ExportOverride) bun.OOM!void {
    var owned = value;
    errdefer owned.deinit();
    if (indices.getEntry(owned.key.slice())) |entry| {
        entry.key_ptr.* = owned.key.slice();
        const previous = &list.items[entry.value_ptr.*];
        previous.deinit();
        previous.* = owned;
        return;
    }
    try list.ensureUnusedCapacity(1);
    try indices.put(owned.key.slice(), list.items.len);
    list.appendAssumeCapacity(owned);
}

fn invalidIdentifierMessage(name: []const u8) bun.OOM!bindgen.DOMString {
    const message = try std.fmt.allocPrint(
        bun.default_allocator,
        "\"{s}\" is not a valid ECMAScript identifier",
        .{name},
    );
    defer bun.default_allocator.free(message);
    return bindgen.DOMString.fromUTF8(message);
}

fn stringExpr(text: []const u8, allocator: std.mem.Allocator) bun.OOM!JSAst.Expr {
    const out = try allocator.create(JSAst.E.String);
    errdefer allocator.destroy(out);
    out.* = .{ .data = try allocator.dupe(u8, text) };
    return .{ .data = .{ .e_string = out }, .loc = logger.Loc.Empty };
}

fn ownString(value: anytype) bun.OOM!bindgen.OwnedBytes {
    return .fromDefaultAllocatedSlice(try value.toOwnedSlice(bun.default_allocator));
}

fn exportReplacementValue(primitive: anytype) bun.OOM!ExportValue {
    return switch (primitive.*) {
        .text => |*text| .{ .text = try ownString(text) },
        .number => |value| .{ .number = value },
        .flag => |value| .{ .flag = value },
        .null_value => .null_value,
        .undefined_value => .undefined_value,
    };
}

fn exportInjectValue(item: anytype) bun.OOM!?ExportValue {
    return switch (item.*) {
        .text => |*text| .{ .text = try ownString(text) },
        .number => |value| .{ .number = value },
        .flag => |value| .{ .flag = value },
        .null_value => .null_value,
        .undefined_value => .undefined_value,
        .invalid => null,
    };
}

pub const TransformTask = struct {
    task: bun.BackgroundTaskGroup.Task = .{
        .callback = &runInBackground,
        .on_cancel = &cancel,
    },
    completion: TransformCompletion.Owned,
    input_code: []u8,
    output_code: bindgen.OwnedBytes = .empty(),
    js_instance: *JSTranspiler,
    environment: *bun.DotEnv.Loader.Snapshot,
    log: logger.Log,
    err: ?anyerror = null,
    loader: Loader,

    pub fn schedule(this: *TransformTask, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &this.task) catch |err| {
            this.err = err;
            this.completion.complete(this);
        };
    }

    fn runInBackground(task: *bun.BackgroundTaskGroup.Task) void {
        const this: *TransformTask = @alignCast(@fieldParentPtr("task", task));
        this.run() catch |err| {
            this.err = err;
        };
        this.completion.complete(this);
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const this: *TransformTask = @alignCast(@fieldParentPtr("task", task));
        this.err = error.ConcurrencyUnavailable;
        this.completion.complete(this);
    }

    pub fn run(this: *TransformTask) bun.OOM!void {
        var arena = MimallocArena.init();
        defer arena.deinit();

        const allocator = arena.allocator();
        var ast_memory_allocator = try allocator.create(JSAst.ASTMemoryAllocator);
        var ast_scope = ast_memory_allocator.enter(allocator);
        defer ast_scope.exit();

        var compiler: bun.Transpiler = undefined;
        try initializeInvocation(&compiler, this.js_instance, allocator, &this.log, &this.environment.loader);
        defer compiler.destroyMacroContext();

        const parse_result = (try getParseResult(this.js_instance, &compiler, allocator, this.input_code, this.loader)) orelse {
            this.err = error.ParseError;
            return;
        };

        if (parse_result.empty) {
            return;
        }

        var buffer_writer = JSPrinter.BufferWriter.init(allocator);
        try buffer_writer.buffer.list.ensureTotalCapacity(allocator, 512);
        buffer_writer.reset();

        var printer = JSPrinter.BufferPrinter.init(buffer_writer);
        const printed = compiler.print(parse_result, @TypeOf(&printer), &printer, .esm_ascii) catch |err| {
            this.err = err;
            return;
        };

        if (printed > 0) {
            buffer_writer = printer.ctx;
            buffer_writer.buffer.list.items = buffer_writer.written;
            this.output_code = try bindgen.OwnedBytes.fromSlice(buffer_writer.written);
        }
    }

    fn deinit(this: *TransformTask) void {
        this.log.deinit();
        bun.default_allocator.free(this.input_code);
        this.output_code.deinit();
        this.environment.destroy();
        this.js_instance.deref();
        bun.destroy(this);
    }
};

const TransformCompletionOps = struct {
    pub fn materialize(
        comptime FunctionSchema: type,
        context: bindgen.MaterializationContext(FunctionSchema),
        task: *TransformTask,
    ) bindgen.CallError(FunctionSchema)!bindgen.Return(FunctionSchema) {
        if (task.err) |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        if (task.log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(&task.log, context);
        if (task.log.hasAny() or task.err != null) {
            const message = if (task.err) |err|
                @errorName(err)
            else
                "Transform failed";
            return context.fail(.transform_failed, try bindgen.ThreadSafeDOMString.fromUTF8(message));
        }
        return bindgen.DOMString.fromUTF8(task.output_code.slice());
    }

    pub const destroyPayload = TransformTask.deinit;
};

const TransformCompletion = bindgen.MaterializedCompletion(
    TranspilerTransformSchema,
    TransformTask,
    void,
    TransformCompletionOps,
);

pub const RuntimeEnvironment = struct {
    io: std.Io,
    engine_capabilities: Transpiler.Transpiler.EngineCapabilities,
    env: @FieldType(Transpiler.Transpiler, "env"),
};

pub fn create(
    environment: RuntimeEnvironment,
    context: bindgen.CallContext(TranspilerConstructorSchema),
    options_argument: anytype,
) bindgen.CallError(TranspilerConstructorSchema)!*JSTranspiler {
    const this = try bun.default_allocator.create(JSTranspiler);
    this.* = .{
        .config = .{
            .log = logger.Log.init(bun.default_allocator),
        },
        .arena = bun.ArenaAllocator.init(bun.default_allocator),
        .transpiler = undefined,
    };
    errdefer {
        this.config.deinit();
        this.arena.deinit();
        this.ref_count.clearWithoutDestructor();
        bun.destroy(this);
    }

    const allocator = this.arena.allocator();
    if (options_argument) |options_view| {
        try this.config.fromSchema(context, &options_view);
    }
    const config = &this.config;

    if (config.log.hasAny()) {
        if (config.log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(&config.log, context);
        return context.fail(.create_failed, try bindgen.DOMString.fromUTF8("Failed to create transpiler"));
    }

    const log = &config.log;
    this.transpiler = Transpiler.Transpiler.init(
        allocator,
        environment.io,
        log,
        try config.transformOptions(allocator),
        environment.engine_capabilities,
        environment.env,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (log.hasAny()) {
            if (log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(log, context);
            return context.fail(.create_failed, try bindgen.DOMString.fromUTF8("Failed to create transpiler"));
        }

        return context.fail(.create_failed, try bindgen.DOMString.fromUTF8(@errorName(err)));
    };
    const transpiler = &this.transpiler;
    errdefer transpiler.feature_flags.deinit();
    transpiler.options.no_macros = config.no_macros;
    transpiler.configureLinkerWithAutoJSX(false);
    transpiler.options.env.behavior = .disable;
    transpiler.configureDefines() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (log.hasAny()) {
            if (log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(log, context);
            return context.fail(.create_failed, try bindgen.DOMString.fromUTF8("Failed to load define"));
        }
        return context.fail(.create_failed, try bindgen.DOMString.fromUTF8(@errorName(err)));
    };

    // REPL mode disables DCE to preserve expressions like `42`
    transpiler.options.dead_code_elimination = config.dead_code_elimination and !config.repl_mode;
    transpiler.options.minify_whitespace = config.minify_whitespace;

    // Keep defaults for these
    if (config.minify_syntax)
        transpiler.options.minify_syntax = true;

    if (config.minify_identifiers)
        transpiler.options.minify_identifiers = true;

    transpiler.options.transform_only = !config.allow_runtime;

    transpiler.options.tree_shaking = config.tree_shaking;
    transpiler.options.trim_unused_imports = config.trim_unused_imports;
    transpiler.options.allow_runtime = config.allow_runtime;
    transpiler.options.auto_import_jsx = config.auto_import_jsx;
    transpiler.options.inlining = config.inlining;
    transpiler.options.hot_module_reloading = false;
    transpiler.options.react_fast_refresh = false;
    transpiler.options.repl_mode = config.repl_mode;

    return this;
}

pub fn destroy(this: *JSTranspiler) void {
    this.deref();
}

pub fn deinit(this: *JSTranspiler) void {
    this.transpiler.destroyMacroContext();
    this.transpiler.feature_flags.deinit();
    this.config.deinit();
    this.arena.deinit();
    bun.destroy(this);
}

/// Check if code looks like an object literal that would be misinterpreted as a block
/// Returns true if code starts with { (after whitespace) and doesn't end with ;
/// This matches Node.js REPL behavior for object literal disambiguation
fn isLikelyObjectLiteral(code: []const u8) bool {
    // Skip leading whitespace
    var start: usize = 0;
    while (start < code.len and (code[start] == ' ' or code[start] == '\t' or code[start] == '\n' or code[start] == '\r')) {
        start += 1;
    }

    // Check if starts with {
    if (start >= code.len or code[start] != '{') {
        return false;
    }

    // Skip trailing whitespace
    var end: usize = code.len;
    while (end > 0 and (code[end - 1] == ' ' or code[end - 1] == '\t' or code[end - 1] == '\n' or code[end - 1] == '\r')) {
        end -= 1;
    }

    // Check if ends with semicolon - if so, it's likely a block statement
    if (end > 0 and code[end - 1] == ';') {
        return false;
    }

    return true;
}

fn initializeInvocation(compiler: *bun.Transpiler, instance: *const JSTranspiler, allocator: std.mem.Allocator, log: *logger.Log, environment: *bun.DotEnv.Loader) bun.OOM!void {
    const resolve_results = try allocator.create(Transpiler.ResolveResults);
    resolve_results.* = Transpiler.ResolveResults.init(allocator);
    compiler.* = instance.transpiler;
    compiler.feature_flags = .empty;
    compiler.macro_context = null;
    compiler.allocator = allocator;
    compiler.env = environment;
    compiler.log = log;
    compiler.options.log = log;
    compiler.options.macro_remap = try instance.config.materializeMacros(allocator);
    compiler.options.jsx = try instance.config.tsconfig.apply(compiler.options.jsx, allocator);
    compiler.options.emit_decorator_metadata = instance.config.tsconfig.emit_decorator_metadata;
    compiler.options.experimental_decorators = instance.config.tsconfig.experimental_decorators;
    compiler.resolver = bun.resolver.Resolver.init1(allocator, compiler.io, log, compiler.fs, compiler.options, compiler.engine_capabilities.javascript_semantics);
    compiler.resolver.env_loader = environment;
    compiler.resolve_queue = Transpiler.ResolveQueue.init(allocator);
    compiler.resolve_results = resolve_results;
    compiler.output_files = .init(allocator);
    compiler.configureLinkerWithAutoJSX(false);
}

fn getParseResult(this: *const JSTranspiler, compiler: *bun.Transpiler, allocator: std.mem.Allocator, code: []const u8, loader: ?Loader) bun.OOM!?Transpiler.ParseResult {
    const resolved_loader = loader orelse this.config.default_loader;
    const name = resolved_loader.stdinName();

    // In REPL mode, wrap potential object literals in parentheses
    // If code starts with { and doesn't end with ; it might be an object literal
    // that would otherwise be parsed as a block statement
    const processed_code: []const u8 = if (this.config.repl_mode and isLikelyObjectLiteral(code))
        try std.fmt.allocPrint(allocator, "({s})", .{code})
    else
        code;

    const source = &logger.Source.initPathString(name, processed_code);

    const parse_options = Transpiler.Transpiler.ParseOptions{
        .allocator = allocator,
        .macro_remappings = compiler.options.macro_remap,
        .dirname_fd = .invalid,
        .file_descriptor = null,
        .loader = resolved_loader,
        .jsx = compiler.options.jsx,
        .path = source.path,
        .virtual_source = source,
        .replace_exports = try this.config.materializeExportOverrides(allocator),
        .experimental_decorators = compiler.options.experimental_decorators,
        .emit_decorator_metadata = compiler.options.emit_decorator_metadata,
    };

    return compiler.parse(parse_options, null);
}

const BindingStringOrBuffer = union(enum) {
    string: bun.String.Slice,
    buffer: []const u8,

    fn from(value: anytype) bun.OOM!BindingStringOrBuffer {
        return switch (value) {
            .string => |text| .{ .string = try text.toUTF8(bun.default_allocator) },
            .buffer => |buffer| .{ .buffer = buffer.unsafePtr("the generated entry frame owns the source lease until synchronous scanning or transpilation consumes its bytes") },
        };
    }

    fn slice(value: *const BindingStringOrBuffer) []const u8 {
        return switch (value.*) {
            .string => |*text| text.slice(),
            .buffer => |bytes| bytes,
        };
    }

    fn deinit(value: *BindingStringOrBuffer) void {
        switch (value.*) {
            .string => |*text| text.deinit(),
            .buffer => {},
        }
    }
};

fn scanFailure(context: anytype, log: *logger.Log, fallback: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    if (log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(log, context);
    const payload = bindgen.DOMString.fromUTF8(fallback) catch return error.OutOfMemory;
    return context.fail(.parse_failed, payload);
}

fn scan(
    this: *JSTranspiler,
    context: bindgen.CallContext(TranspilerScanSchema),
    code_arg: anytype,
    loader_arg: anytype,
) bindgen.CallError(TranspilerScanSchema)!bindgen.Return(TranspilerScanSchema) {
    var code_holder = try BindingStringOrBuffer.from(code_arg);
    defer code_holder.deinit();
    const code = code_holder.slice();

    const loader = if (loader_arg) |arg| loaderFromBinding(arg) else null;

    var arena = MimallocArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    var log = logger.Log.init(arena.backingAllocator());
    defer log.deinit();
    var compiler: bun.Transpiler = undefined;
    try initializeInvocation(&compiler, this, allocator, &log, this.transpiler.env);
    defer compiler.destroyMacroContext();
    var ast_memory_allocator = try allocator.create(JSAst.ASTMemoryAllocator);
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    var parse_result = (try getParseResult(this, &compiler, allocator, code, loader)) orelse
        return scanFailure(context, &log, "Failed to parse");

    if (log.hasAny()) {
        return scanFailure(context, &log, "Failed to parse");
    }

    var imports = try namedImportsToBinding(
        @FieldType(bindgen.Return(TranspilerScanSchema), "imports"),
        parse_result.ast.import_records.slice(),
        this.config.trim_unused_imports orelse false,
    );
    errdefer imports.deinit();

    const exports = try namedExportsToBinding(
        @FieldType(bindgen.Return(TranspilerScanSchema), "exports"),
        &parse_result.ast.named_exports,
    );
    return .{ .imports = imports, .exports = exports };
}

fn transform(
    this: *JSTranspiler,
    context: bindgen.CallContext(TranspilerTransformSchema),
    code_arg: anytype,
    loader_arg: anytype,
) bindgen.CallError(TranspilerTransformSchema)!void {
    const code = try NodeTypes.StringOrBuffer.fromBindgen(code_arg, .utf8);
    defer code.deinit();

    const loader = if (loader_arg) |arg| loaderFromBinding(arg) else null;
    const input_code = try bun.default_allocator.dupe(u8, code.slice());
    errdefer bun.default_allocator.free(input_code);
    const environment = try bun.DotEnv.Loader.Snapshot.create(this.transpiler.env);
    errdefer environment.destroy();

    const task = try bun.default_allocator.create(TransformTask);
    errdefer bun.default_allocator.destroy(task);

    var completion = context.completion();
    const owned = try TransformCompletion.take(&completion, {});
    this.ref();
    task.* = .{
        .completion = owned,
        .input_code = input_code,
        .log = logger.Log.init(bun.default_allocator),
        .loader = loader orelse this.config.default_loader,
        .js_instance = this,
        .environment = environment,
    };
    task.log.level = this.config.log.level;
    task.schedule(bun.current_runtime.backgroundTasks());
}

fn transformSync(
    this: *JSTranspiler,
    context: bindgen.CallContext(TranspilerTransformSyncSchema),
    code_arg: anytype,
    loader_or_context_arg: anytype,
    context_arg: anytype,
) bindgen.CallError(TranspilerTransformSyncSchema)!bindgen.DOMString {
    var arena = MimallocArena.init();
    defer arena.deinit();
    const code_holder = try NodeTypes.StringOrBuffer.fromBindgen(code_arg, .utf8);
    defer code_holder.deinit();
    const code = code_holder.slice();

    var js_ctx: ?bindgen.Root = null;
    defer if (js_ctx) |*root| root.deinit();
    const loader: ?Loader = if (loader_or_context_arg) |arg| switch (arg) {
        .loader => |value| loaderFromBinding(value),
        .context => |value| context: {
            js_ctx = try value.toRoot();
            break :context null;
        },
    } else null;

    if (context_arg) |value| {
        if (js_ctx) |*previous| previous.deinit();
        js_ctx = try value.toRoot();
    }

    const allocator = arena.allocator();

    var ast_memory_allocator = try allocator.create(JSAst.ASTMemoryAllocator);
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    var log = logger.Log.init(arena.backingAllocator());
    defer log.deinit();
    log.level = this.config.log.level;
    var compiler: bun.Transpiler = undefined;
    try initializeInvocation(&compiler, this, allocator, &log, this.transpiler.env);
    defer compiler.destroyMacroContext();
    if (js_ctx) |*root| {
        (try compiler.ensureMacroContext()).setJavascriptObject(root);
    }
    const parse_result = (try getParseResult(this, &compiler, allocator, code, loader)) orelse {
        if (log.hasAny()) {
            if (log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(&log, context);
            return context.fail(.transform_failed, try bindgen.ThreadSafeDOMString.fromUTF8("Parse error"));
        }

        return context.fail(.transform_failed, try bindgen.ThreadSafeDOMString.fromUTF8("Failed to parse code"));
    };

    if (log.hasAny()) {
        if (log.msgs.items.len > 0) return LoggerEngine.failDiagnostics(&log, context);
        return context.fail(.transform_failed, try bindgen.ThreadSafeDOMString.fromUTF8("Parse error"));
    }

    var buffer_writer = JSPrinter.BufferWriter.init(allocator);
    try buffer_writer.buffer.growIfNeeded(code.len);
    buffer_writer.buffer.list.expandToCapacity();
    buffer_writer.reset();
    var printer = JSPrinter.BufferPrinter.init(buffer_writer);
    _ = compiler.print(parse_result, @TypeOf(&printer), &printer, .esm_ascii) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return context.fail(.transform_failed, try bindgen.ThreadSafeDOMString.fromUTF8(@errorName(err)));
    };

    return bindgen.DOMString.fromUTF8(printer.ctx.written);
}

fn namedExportsToBinding(
    comptime Sequence: type,
    named_exports: *JSAst.Ast.NamedExports,
) bun.OOM!Sequence {
    if (named_exports.count() == 0) return Sequence.fromUTF8Slices(&.{});

    named_exports.sort(strings.StringArrayByIndexSorter{
        .keys = named_exports.keys(),
    });
    return Sequence.fromUTF8Slices(named_exports.keys());
}

fn namedImportsToBinding(
    comptime Sequence: type,
    import_records: []const ImportRecord,
    trim_unused_imports: bool,
) bun.OOM!Sequence {
    var values: std.ArrayList(Sequence.Element) = .empty;
    defer values.deinit(bun.default_allocator);
    errdefer for (values.items) |*value| value.path.deinit();

    for (import_records) |record| {
        if (record.flags.is_internal) continue;
        if (trim_unused_imports and record.flags.is_unused) continue;

        var path = try bindgen.DOMString.fromUTF8(record.path.text);
        errdefer path.deinit();
        try values.append(bun.default_allocator, .{
            .path = path,
            .kind = record.kind.toBinding(@FieldType(Sequence.Element, "kind")),
        });
    }

    return Sequence.fromOwnedSlice(values.items);
}

fn scanImports(
    this: *JSTranspiler,
    context: bindgen.CallContext(TranspilerScanImportsSchema),
    code_arg: anytype,
    loader_arg: anytype,
) bindgen.CallError(TranspilerScanImportsSchema)!bindgen.Return(TranspilerScanImportsSchema) {
    var code_holder = try BindingStringOrBuffer.from(code_arg);
    defer code_holder.deinit();
    const code = code_holder.slice();

    var loader: Loader = this.config.default_loader;
    if (loader_arg) |arg| {
        loader = loaderFromBinding(arg);
    }

    if (!loader.isJavaScriptLike()) {
        return context.fail(.unsupported_loader, {});
    }

    var arena = MimallocArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast_memory_allocator = try allocator.create(JSAst.ASTMemoryAllocator);
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    var log = logger.Log.init(arena.backingAllocator());
    defer log.deinit();
    var compiler: bun.Transpiler = undefined;
    try initializeInvocation(&compiler, this, allocator, &log, this.transpiler.env);
    defer compiler.destroyMacroContext();

    var source = logger.Source.initPathString(loader.stdinName(), code);
    source.normalizeText(allocator) catch return error.OutOfMemory;
    const transpiler = &compiler;
    var opts = JSParser.Parser.Options.init(compiler.options.jsx, loader);
    opts.javascript_semantics = transpiler.engine_capabilities.javascript_semantics;
    opts.macro_context = try compiler.ensureMacroContext();

    var scan_pass_result = ScanPassResult.init(allocator);
    transpiler.resolver.caches.js.scan(
        transpiler.allocator,
        &scan_pass_result,
        opts,
        transpiler.options.define,
        &log,
        &source,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return scanFailure(context, &log, @errorName(err));
    };

    if (log.hasAny()) {
        return scanFailure(context, &log, "Failed to scan imports");
    }

    return namedImportsToBinding(
        bindgen.Return(TranspilerScanImportsSchema),
        scan_pass_result.import_records.items,
        this.config.trim_unused_imports orelse false,
    );
}

fn loaderFromBinding(value: anytype) Loader {
    return switch (value) {
        ._none => .file,
        inline else => |loader| @field(Loader, @tagName(loader)),
    };
}

const string = []const u8;

const std = @import("std");
const ImportRecord = @import("../../options_types/import_record.zig").ImportRecord;
const Runtime = @import("../../js_parser/runtime.zig").Runtime;
const TSConfigJSON = @import("../../resolver/tsconfig_json.zig").TSConfigJSON;
const NodeTypes = @import("../node/types.zig");
const LoggerEngine = @import("../../logger_jsc/LoggerEngine.zig");

const options = @import("../../bundler/options.zig");
const Loader = options.Loader;
const Target = options.Target;

const MacroMap = @import("../../resolver/package_json.zig").MacroMap;
const MacroImportReplacementMap = @import("../../resolver/package_json.zig").MacroImportReplacementMap;
const PackageJSON = @import("../../resolver/package_json.zig").PackageJSON;
const BundlerCache = @import("../../bundler/cache.zig");

const bun = @import("bun");
const JSLexer = bun.js_lexer;
const JSPrinter = bun.js_printer;
const Transpiler = bun.transpiler;
const logger = bun.logger;
const strings = bun.strings;
const MimallocArena = bun.allocators.MimallocArena;
const api = bun.schema.api;

const JSAst = bun.ast;
const Expr = JSAst.Expr;

const JSParser = bun.js_parser;
const ScanPassResult = JSParser.ScanPassResult;

const bindgen = bun.bindgen;

const TranspilerBindingModule = bindgen.Module("Transpiler");
const TranspilerSchema = TranspilerBindingModule.class("Transpiler");
const TranspilerClass = bindgen.Class(TranspilerSchema, JSTranspiler.JSBinding);
const TranspilerConstructorSchema = TranspilerSchema.constructor();
const TranspilerScanSchema = TranspilerSchema.member("scan");
const TranspilerScanImportsSchema = TranspilerSchema.member("scanImports");
const TranspilerTransformSchema = TranspilerSchema.member("transform");
const TranspilerTransformSyncSchema = TranspilerSchema.member("transformSync");

comptime {
    _ = TranspilerClass;
}
