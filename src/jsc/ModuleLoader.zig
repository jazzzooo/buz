const ModuleLoader = @This();
const PluginRunner = @import("../bundler_jsc/PluginRunnerEngine.zig").PluginRunner;

pub const node_fallbacks = @import("../resolver/node_fallbacks.zig");
pub const AsyncModule = @import("./AsyncModule.zig").AsyncModule;
pub const RuntimeTranspilerStore = @import("./RuntimeTranspilerStore.zig").RuntimeTranspilerStore;
pub const HardcodedModule = @import("../resolve_builtins/HardcodedModule.zig").HardcodedModule;
pub const OwnedModulePromise = bun.bindgen.OwnedBrandedValue(bun.bindgen.PromiseResult.bindgen_semantic_type);

pub const CommonJSExtension = union(enum) {
    loader: options.Loader,
    custom: ResolvedSource.ExtensionCallback,
};

pub fn prepareCommonJSExtensionUpdate(context: anytype, args: bun.bindgen.Args(PrepareCommonJSExtensionSchema)) bun.JSError!bun.bindgen.Return(PrepareCommonJSExtensionSchema) {
    const globalThis = context.viewToken().globalObject();
    const vm = globalThis.bunVM();
    if (vm.isShuttingDown()) {
        const update = try bun.default_allocator.create(CommonJSExtensionUpdate);
        update.* = .{ .vm = null, .name = null, .replacement = null };
        return .initNative(update);
    }
    const name = try args.extension.toOwnedSlice(bun.default_allocator);
    errdefer bun.default_allocator.free(name);
    var replacement: ?CommonJSExtension = if (args.loader) |loader|
        .{ .loader = switch (loader) {
            inline else => |value| @field(options.Loader, @tagName(value)),
        } }
    else if (args.value) |value|
        .{ .custom = try value.toOwned() }
    else
        null;
    errdefer if (replacement) |*value| deinitCommonJSExtension(value);
    const update = try bun.default_allocator.create(CommonJSExtensionUpdate);
    errdefer bun.default_allocator.destroy(update);
    const reservations = std.math.add(usize, vm.commonjs_extension_reservations, 1) catch return error.OutOfMemory;
    const capacity = std.math.add(usize, vm.commonjs_custom_extensions.count(), reservations) catch return error.OutOfMemory;
    defer vm.transpiler.resolver.opts.extra_cjs_extensions = vm.commonjs_custom_extensions.keys();
    try vm.commonjs_custom_extensions.ensureTotalCapacity(bun.default_allocator, capacity);
    update.* = .{ .vm = vm, .name = name, .replacement = replacement, .next = vm.commonjs_extension_updates };
    if (update.next) |next| next.previous = update;
    vm.commonjs_extension_updates = update;
    vm.commonjs_extension_reservations = reservations;
    return .initNative(update);
}

pub fn finishCommonJSExtensionUpdate(args: *bun.bindgen.Args(FinishCommonJSExtensionSchema)) void {
    args.update.takeNative().finish(args.commit);
}

pub const CommonJSExtensionUpdate = struct {
    vm: ?*VirtualMachine,
    name: ?[]u8,
    replacement: ?CommonJSExtension,
    previous: ?*CommonJSExtensionUpdate = null,
    next: ?*CommonJSExtensionUpdate = null,

    fn finish(update: *CommonJSExtensionUpdate, commit: bool) void {
        const vm = update.vm orelse {
            bun.default_allocator.destroy(update);
            return;
        };
        if (commit) {
            if (update.replacement) |*replacement| {
                const entry = vm.commonjs_custom_extensions.getOrPutAssumeCapacity(update.name.?);
                if (entry.found_existing) {
                    deinitCommonJSExtension(entry.value_ptr);
                } else {
                    entry.key_ptr.* = update.name.?;
                    update.name = null;
                    if (bun.options.defaultLoaders.get(entry.key_ptr.*) != null)
                        vm.has_mutated_built_in_extensions += 1;
                }
                entry.value_ptr.* = takeCommonJSExtension(replacement);
            } else {
                removeCommonJSExtensionState(vm, update.name.?);
            }
            vm.transpiler.resolver.opts.extra_cjs_extensions = vm.commonjs_custom_extensions.keys();
        }
        update.cancel();
        bun.default_allocator.destroy(update);
    }

    fn cancel(update: *CommonJSExtensionUpdate) void {
        const vm = update.vm orelse return;
        if (update.previous) |previous| previous.next = update.next else vm.commonjs_extension_updates = update.next;
        if (update.next) |next| next.previous = update.previous;
        bun.assert(vm.commonjs_extension_reservations > 0);
        vm.commonjs_extension_reservations -= 1;
        if (update.replacement) |*value| deinitCommonJSExtension(value);
        if (update.name) |name| bun.default_allocator.free(name);
        update.vm = null;
        update.replacement = null;
        update.name = null;
        update.previous = null;
        update.next = null;
    }
};

pub fn ensurePluginRunner() void {
    const vm = jsc.VirtualMachine.get();
    if (vm.plugin_runner != null) return;
    vm.plugin_runner = PluginRunner{
        .global_object = vm.global,
        .allocator = vm.allocator,
    };
    vm.transpiler.linker.plugin_resolver = vm.plugin_runner.?.resolver();
}

fn deinitCommonJSExtension(extension: *CommonJSExtension) void {
    switch (extension.*) {
        .loader => {},
        .custom => |*root| root.deinit(),
    }
}

fn takeCommonJSExtension(extension: *CommonJSExtension) CommonJSExtension {
    return switch (extension.*) {
        .loader => |loader| .{ .loader = loader },
        .custom => |*root| .{ .custom = root.take() },
    };
}

fn removeCommonJSExtensionState(vm: *VirtualMachine, name: []const u8) void {
    const extensions = &vm.commonjs_custom_extensions;
    defer vm.transpiler.resolver.opts.extra_cjs_extensions = extensions.keys();

    if (extensions.fetchSwapRemove(name)) |removed| {
        bun.default_allocator.free(removed.key);
        if (bun.options.defaultLoaders.get(name) != null) {
            vm.has_mutated_built_in_extensions -= 1;
        }
        var value = removed.value;
        deinitCommonJSExtension(&value);
    }
}

pub fn deinitCommonJSExtensions(this: *ModuleLoader, vm: *VirtualMachine) void {
    bun.assert(&vm.module_loader == this);
    while (vm.commonjs_extension_updates) |update| update.cancel();
    vm.transpiler.resolver.opts.extra_cjs_extensions = &.{};
    for (vm.commonjs_custom_extensions.keys(), vm.commonjs_custom_extensions.values()) |key, *extension| {
        bun.default_allocator.free(key);
        deinitCommonJSExtension(extension);
    }
    vm.commonjs_custom_extensions.deinit(bun.default_allocator);
    vm.commonjs_custom_extensions = .empty;
    vm.has_mutated_built_in_extensions = 0;
}

fn findLongestRegisteredExtension(vm: *VirtualMachine, filename: []const u8) ?*const CommonJSExtension {
    const basename = std.fs.path.basename(filename);
    var next: usize = 0;
    while (bun.strings.indexOfCharPos(basename, '.', next)) |index| {
        next = index + 1;
        if (index == 0) continue;
        if (vm.commonjs_custom_extensions.getPtr(basename[index..])) |extension| {
            return extension;
        }
    }
    return null;
}

transpile_source_code_arena: ?*bun.ArenaAllocator = null,
eval_source: ?*logger.Source = null,

comptime {
    _ = ResolveAndFetchBuiltinModuleBinding;
    _ = FetchBuiltinModuleBinding;
    _ = TranspileFileBinding;
    _ = TranspileVirtualModuleCodeBinding;
    _ = RunVirtualModuleBinding;
    _ = ResolveEmbeddedNodeFileBinding;
    _ = IsBuiltinBinding;
}

pub var is_allowed_to_use_internal_testing_apis = false;

/// This must be called after calling transpileSourceCode
pub fn resetArena(this: *ModuleLoader, jsc_vm: *VirtualMachine) void {
    bun.assert(&jsc_vm.module_loader == this);
    if (this.transpile_source_code_arena) |arena| {
        if (jsc_vm.smol) {
            _ = arena.reset(.free_all);
        } else {
            _ = arena.reset(.{ .retain_with_limit = 8 * 1024 * 1024 });
        }
    }
}

pub fn resolveEmbeddedFile(vm: *VirtualMachine, path_buf: *bun.PathBuffer, input_path: []const u8, extname: []const u8) ?[]const u8 {
    if (input_path.len == 0) return null;
    var graph = vm.standalone_module_graph orelse return null;
    const file = graph.find(input_path) orelse return null;

    if (comptime Environment.isLinux) {
        // TODO: use /proc/fd/12346 instead! Avoid the copy!
    }

    // atomically write to a tmpfile and then move it to the final destination
    const tmpname_buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(tmpname_buf);
    const tmpfilename = bun.fs.FileSystem.tmpname(extname, tmpname_buf, bun.hash(file.name)) catch return null;

    const tmpdir: bun.FD = .fromStdDir(bun.fs.FileSystem.instance.tmpdir() catch return null);

    // First we open the tmpfile, to avoid any other work in the event of failure.
    const tmpfile = bun.Tmpfile.create(tmpdir, tmpfilename).unwrap() catch return null;
    defer tmpfile.fd.close();

    switch (bun.api.node.fs.NodeFS.writeFileWithPathBuffer(
        tmpname_buf, // not used

        .{
            .data = .{
                .encoded_slice = bun.String.Slice.fromUTF8NeverFree(file.contents),
            },
            .dirfd = tmpdir,
            .file = .{ .fd = tmpfile.fd },
            .encoding = .buffer,
        },
    )) {
        .err => {
            return null;
        },
        else => {},
    }
    return bun.path.joinAbsStringBuf(bun.fs.FileSystem.RealFS.tmpdirPath(vm.io), path_buf, &[_]string{tmpfilename}, .auto);
}

fn defaultLoader(jsc_vm: *VirtualMachine, filename: []const u8) options.Loader {
    const loader = jsc_vm.transpiler.options.loader(std.fs.path.extension(filename));
    return if (loader == .file) .js else loader;
}

pub const LoaderResult = struct {
    loader: ?options.Loader,
    virtual_source: ?*logger.Source,
    path: Fs.Path,
    is_main: bool,
    specifier: string,
    package_json: ?*const PackageJSON,
};

fn normalizeSpecifier(jsc_vm: *VirtualMachine, slice_: string) struct { string, string, string } {
    var slice = slice_;
    if (slice.len == 0) return .{ slice, slice, "" };

    if (strings.hasPrefix(slice, jsc_vm.origin.host)) {
        slice = slice[jsc_vm.origin.host.len..];
    }

    if (jsc_vm.origin.path.len > 1 and strings.hasPrefix(slice, jsc_vm.origin.path)) {
        slice = slice[jsc_vm.origin.path.len..];
    }

    const specifier = slice;
    var query: []const u8 = "";
    if (strings.indexOfChar(slice, '?')) |index| {
        query = slice[index..];
        slice = slice[0..index];
    }

    return .{ slice, specifier, query };
}

pub fn getLoaderAndVirtualSource(
    specifier_str: string,
    jsc_vm: *VirtualMachine,
    virtual_source_to_use: *?logger.Source,
    blob_to_deinit: *?jsc.WebCore.Blob,
    type_attribute_str: ?string,
) (bun.OOM || error{BlobNotFound})!LoaderResult {
    const normalized_file_path_from_specifier, const specifier, const query = normalizeSpecifier(jsc_vm, specifier_str);
    var path = Fs.Path.init(normalized_file_path_from_specifier);

    var loader: ?options.Loader = path.loader(&jsc_vm.transpiler.options.loaders);
    var virtual_source: ?*logger.Source = null;

    if (jsc_vm.module_loader.eval_source) |eval_source| {
        if (strings.endsWithComptime(specifier, bun.pathLiteral("/[eval]"))) {
            virtual_source = eval_source;
            loader = .tsx;
        }
        if (strings.endsWithComptime(specifier, bun.pathLiteral("/[stdin]"))) {
            virtual_source = eval_source;
            loader = .tsx;
        }
    }

    if (jsc.WebCore.ObjectURLRegistry.isBlobURL(specifier)) {
        if (try jsc.WebCore.ObjectURLRegistry.singleton().resolveAndDupe(jsc_vm.io, specifier["blob:".len..])) |blob| {
            blob_to_deinit.* = blob;
            loader = blob.getLoader(jsc_vm);

            if (blob.getFileName()) |filename| {
                const current_path = Fs.Path.init(filename);
                if (blob.needsToReadFile()) path = current_path;
            }

            if (!blob.needsToReadFile()) {
                virtual_source_to_use.* = .{
                    .path = path,
                    .contents = blob.sharedView(),
                };
                virtual_source = &virtual_source_to_use.*.?;
            }
        } else {
            return error.BlobNotFound;
        }
    }

    if (strings.eqlComptime(query, "?raw")) loader = .text;
    if (type_attribute_str) |attribute| {
        if (options.Loader.fromString(attribute)) |attribute_loader| loader = attribute_loader;
    }

    const is_main = strings.eqlLong(specifier, jsc_vm.main, true);
    const dir = std.fs.path.dirname(path.text);
    const is_js_like = if (loader) |resolved| resolved.isJavaScriptLike() else true;
    const package_json: ?*const PackageJSON = if (is_js_like and dir != null and std.fs.path.isAbsolute(dir.?))
        if (jsc_vm.transpiler.resolver.readDirInfo(dir.?) catch null) |dir_info|
            dir_info.package_json orelse dir_info.enclosing_package_json
        else
            null
    else
        null;

    return .{
        .loader = loader,
        .virtual_source = virtual_source,
        .path = path,
        .is_main = is_main,
        .specifier = specifier,
        .package_json = package_json,
    };
}

pub fn transpileSourceCode(
    jsc_vm: *VirtualMachine,
    specifier: string,
    referrer: string,
    input_specifier: String,
    path: Fs.Path,
    loader: options.Loader,
    module_type: options.ModuleType,
    log: *logger.Log,
    virtual_source: ?*const logger.Source,
    promise_ptr: ?*?OwnedModulePromise,
    source_code_printer: *js_printer.BufferPrinter,
    globalObject: ?*JSGlobalObject,
    comptime flags: FetchFlags,
) !ResolvedSource {
    const disable_transpilying = comptime flags.disableTranspiling();

    if (comptime disable_transpilying) {
        if (!(loader.isJavaScriptLike() or loader == .toml or loader == .yaml or loader == .json5 or loader == .text or loader == .json or loader == .jsonc)) {
            // Don't print "export default <file path>"
            return ResolvedSource{
                .source_code = bun.String.empty,
                .source_url = input_specifier.createIfDifferent(path.text),
            };
        }
    }

    switch (loader) {
        .js, .jsx, .ts, .tsx, .json, .jsonc, .toml, .yaml, .json5, .text, .md => {
            // Ensure that if there was an ASTMemoryAllocator in use, it's not used anymore.
            var ast_scope = js_ast.ASTMemoryAllocator.Scope{};
            ast_scope.enter();
            defer ast_scope.exit();

            jsc_vm.transpiler.resetStore();
            const hash = bun.Watcher.getHash(path.text);
            const is_main = jsc_vm.main.len == path.text.len and
                jsc_vm.main_hash == hash and
                strings.eqlLong(jsc_vm.main, path.text, false);

            var arena_: ?*bun.ArenaAllocator = brk: {
                // Attempt to reuse the Arena from the parser when we can
                // This code is potentially re-entrant, so only one Arena can be reused at a time
                // That's why we have to check if the Arena is null
                //
                // Using an Arena here is a significant memory optimization when loading many files
                if (jsc_vm.module_loader.transpile_source_code_arena) |shared| {
                    jsc_vm.module_loader.transpile_source_code_arena = null;
                    break :brk shared;
                }

                // we must allocate the arena so that the pointer it points to is always valid.
                const arena = try jsc_vm.allocator.create(bun.ArenaAllocator);
                arena.* = bun.ArenaAllocator.init(bun.default_allocator);
                break :brk arena;
            };

            var give_back_arena = true;
            defer {
                if (give_back_arena) {
                    if (jsc_vm.module_loader.transpile_source_code_arena == null) {
                        // when .print_source is used
                        // caller is responsible for freeing the arena
                        if (flags != .print_source) {
                            if (jsc_vm.smol) {
                                _ = arena_.?.reset(.free_all);
                            } else {
                                _ = arena_.?.reset(.{ .retain_with_limit = 8 * 1024 * 1024 });
                            }
                        }

                        jsc_vm.module_loader.transpile_source_code_arena = arena_;
                    } else {
                        arena_.?.deinit();
                        jsc_vm.allocator.destroy(arena_.?);
                    }
                }
            }

            var arena = arena_.?;
            const allocator = arena.allocator();

            const package_json = jsc_vm.bun_watcher.packageJsonForFile(hash);

            var cache = bun.js_parser.RuntimeTranspilerCache{
                .io = jsc_vm.io,
                .output_code_allocator = allocator,
                .sourcemap_allocator = bun.default_allocator,
                .esm_record_allocator = bun.default_allocator,
            };

            const old = jsc_vm.transpiler.log;
            jsc_vm.transpiler.log = log;
            jsc_vm.transpiler.linker.log = log;
            jsc_vm.transpiler.resolver.log = log;
            if (jsc_vm.transpiler.resolver.package_manager) |pm| {
                pm.log = log;
            }

            defer {
                jsc_vm.transpiler.log = old;
                jsc_vm.transpiler.linker.log = old;
                jsc_vm.transpiler.resolver.log = old;
                if (jsc_vm.transpiler.resolver.package_manager) |pm| {
                    pm.log = old;
                }
            }

            // this should be a cheap lookup because 24 bytes == 8 * 3 so it's read 3 machine words
            const is_node_override = strings.hasPrefixComptime(specifier, node_fallbacks.import_path);

            const macro_remappings = if (jsc_vm.macro_mode or !jsc_vm.has_any_macro_remappings or is_node_override)
                MacroRemap{}
            else
                jsc_vm.transpiler.options.macro_remap;

            var fallback_source: logger.Source = undefined;

            // We don't want cjs wrappers around non-js files
            const module_type_only_for_wrappables = switch (loader) {
                .js, .jsx, .ts, .tsx => module_type,
                else => .unknown,
            };

            var input_file_fd: FD = bun.invalid_fd;
            var parse_options = Transpiler.ParseOptions{
                .allocator = allocator,
                .path = path,
                .loader = loader,
                .dirname_fd = bun.invalid_fd,
                .file_fd_ptr = &input_file_fd,
                .macro_remappings = macro_remappings,
                .jsx = jsc_vm.transpiler.options.jsx,
                .emit_decorator_metadata = jsc_vm.transpiler.options.emit_decorator_metadata,
                .experimental_decorators = jsc_vm.transpiler.options.experimental_decorators,
                .virtual_source = virtual_source,
                .dont_bundle_twice = true,
                .allow_commonjs = true,
                .module_type = module_type_only_for_wrappables,
                .inject_jest_globals = jsc_vm.transpiler.options.rewrite_jest_for_tests,
                .keep_json_and_toml_as_one_statement = true,
                .allow_bytecode_cache = true,
                .set_breakpoint_on_first_line = is_main and
                    jsc_vm.debugger != null and
                    jsc_vm.debugger.?.set_breakpoint_on_first_line and
                    setBreakPointOnFirstLine(),
                .runtime_transpiler_cache = if (!disable_transpilying and !bun.js_parser.RuntimeTranspilerCache.is_disabled) &cache else null,
                .remove_cjs_module_wrapper = is_main and jsc_vm.module_loader.eval_source != null,
            };
            defer {
                if (input_file_fd.isValid()) {
                    input_file_fd.close();
                    input_file_fd = bun.invalid_fd;
                }
            }

            if (is_node_override) {
                if (node_fallbacks.contentsFromPath(jsc_vm.io, specifier)) |code| {
                    const fallback_path = Fs.Path.initWithNamespace(specifier, "node");
                    fallback_source = logger.Source{ .path = fallback_path, .contents = code };
                    parse_options.virtual_source = &fallback_source;
                }
            }

            var owned_virtual_source: logger.Source = undefined;
            if (promise_ptr != null) {
                if (parse_options.virtual_source) |virtual| {
                    owned_virtual_source = virtual.*;
                    owned_virtual_source.contents = try allocator.dupe(u8, virtual.contents);
                    owned_virtual_source.contents_is_recycled = false;
                    parse_options.virtual_source = &owned_virtual_source;
                }
            }

            var parse_result: ParseResult = switch (disable_transpilying or
                (loader == .json)) {
                inline else => |return_file_only| brk: {
                    break :brk (try jsc_vm.transpiler.parseMaybeReturnFileOnly(
                        parse_options,
                        null,
                        return_file_only,
                    )) orelse {
                        if (comptime !disable_transpilying) {
                            if (jsc_vm.isWatcherEnabled()) {
                                if (input_file_fd.isValid()) {
                                    if (!is_node_override and std.fs.path.isAbsolute(path.text) and !strings.contains(path.text, "node_modules")) {
                                        _ = jsc_vm.bun_watcher.addFileByPathSlow(path.text, loader, package_json);
                                    }
                                }
                            }
                        }

                        give_back_arena = false;
                        return error.ParseError;
                    };
                },
            };

            const source = &parse_result.source;

            if (parse_result.loader == .wasm) {
                return transpileSourceCode(
                    jsc_vm,
                    specifier,
                    referrer,
                    input_specifier,
                    path,
                    .wasm,
                    .unknown, // cjs/esm don't make sense for wasm
                    log,
                    &parse_result.source,
                    promise_ptr,
                    source_code_printer,
                    globalObject,
                    flags,
                );
            }

            if (comptime !disable_transpilying) {
                if (jsc_vm.isWatcherEnabled()) {
                    if (input_file_fd.isValid()) {
                        if (!is_node_override and std.fs.path.isAbsolute(path.text) and !strings.contains(path.text, "node_modules")) {
                            _ = jsc_vm.bun_watcher.addFileByPathSlow(path.text, loader, package_json);
                        }
                    }
                }
            }

            if (jsc_vm.transpiler.log.errors > 0) {
                give_back_arena = false;
                return error.ParseError;
            }

            if (loader == .json) {
                return ResolvedSource{
                    .source_code = bun.String.cloneUTF8(source.contents),
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .tag = .{ .source = .json_for_object_loader },
                };
            }

            if (comptime disable_transpilying) {
                return ResolvedSource{
                    .source_code = bun.String.cloneUTF8(source.contents),
                    .source_url = input_specifier.createIfDifferent(path.text),
                };
            }

            if (loader == .json or loader == .jsonc or loader == .toml or loader == .yaml or loader == .json5) {
                if (parse_result.empty) {
                    const exported = try jsc.ModuleLoaderEngine.emptyModuleExport(globalObject orelse jsc_vm.global);
                    return ResolvedSource{
                        .source_url = input_specifier.createIfDifferent(path.text),
                        .jsvalue_for_export = exported,
                        .tag = .{ .source = .exports_object },
                    };
                }

                const expression = parse_result.ast.parts.at(0).stmts[0].data.s_expr.value;
                const export_global = globalObject orelse jsc_vm.global;
                const exported = try ExpressionEngine.toOwnedValue(expression, allocator, export_global);
                return ResolvedSource{
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .jsvalue_for_export = exported,
                    .tag = .{ .source = .exports_object },
                };
            }

            if (parse_result.already_bundled != .none) {
                const bytecode_slice = parse_result.already_bundled.bytecodeSlice();
                return ResolvedSource{
                    .source_code = bun.String.cloneLatin1(source.contents),
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .already_bundled = true,
                    .bytecode_cache = if (bytecode_slice.len > 0)
                        .{ .owned = bytecode_slice }
                    else
                        null,
                    .is_commonjs_module = parse_result.already_bundled.isCommonJS(),
                };
            }

            if (parse_result.empty) {
                const was_cjs = (loader == .js or loader == .ts) and brk: {
                    const ext = std.fs.path.extension(source.path.text);
                    break :brk strings.eqlComptime(ext, ".cjs") or strings.eqlComptime(ext, ".cts");
                };
                if (was_cjs) {
                    return .{
                        .source_code = bun.String.static("(function(){})"),
                        .source_url = input_specifier.createIfDifferent(path.text),
                        .is_commonjs_module = true,
                        .tag = .{ .source = .javascript },
                    };
                }
            }

            if (cache.entry) |*entry| {
                const module_info: ?*analyze_transpiled_module.ModuleInfoDeserialized =
                    if (jsc_vm.useIsolationSourceProviderCache() and entry.metadata.module_type != .cjs and entry.esm_record.len > 0)
                        try analyze_transpiled_module.ModuleInfoDeserialized.createFromCachedRecord(entry.esm_record, bun.default_allocator)
                    else
                        null;

                jsc_vm.source_mappings.putMappings(source, .{
                    .list = .{ .items = @constCast(entry.sourcemap), .capacity = entry.sourcemap.len },
                    .allocator = bun.default_allocator,
                }) catch {};

                if (comptime Environment.allow_assert) {
                    dumpSourceString(jsc_vm, specifier, entry.output_code.byteSlice());
                }

                return ResolvedSource{
                    .source_code = switch (entry.output_code) {
                        .string => entry.output_code.string,
                        .utf8 => brk: {
                            const result = bun.String.cloneUTF8(entry.output_code.utf8);
                            cache.output_code_allocator.free(entry.output_code.utf8);
                            entry.output_code.utf8 = "";
                            break :brk result;
                        },
                    },
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .is_commonjs_module = entry.metadata.module_type == .cjs,
                    .module_info = if (module_info) |value| ResolvedSource.ModuleInfoHandle.initNative(value) else null,
                    .tag = .{
                        .source = brk: {
                            if (entry.metadata.module_type == .cjs and source.path.isFile()) {
                                const actual_package_json: *PackageJSON = package_json orelse brk2: {
                                    // this should already be cached virtually always so it's fine to do this
                                    const source_dir = std.fs.path.dirname(source.path.text) orelse break :brk .javascript;
                                    const dir_info = (jsc_vm.transpiler.resolver.readDirInfo(source_dir) catch null) orelse
                                        break :brk .javascript;

                                    break :brk2 dir_info.package_json orelse dir_info.enclosing_package_json;
                                } orelse break :brk .javascript;

                                if (actual_package_json.module_type == .esm) {
                                    break :brk .package_json_type_module;
                                }
                            }

                            break :brk .javascript;
                        },
                    },
                };
            }

            // We _must_ link because:
            // - node_modules bundle won't be properly
            try jsc_vm.transpiler.linker.link(
                path,
                &parse_result,
                jsc_vm.origin,
                .absolute_path,
                false,
                true,
            );

            if (parse_result.pending_imports.len > 0) {
                errdefer if (give_back_arena) {
                    bun.resolver.PendingResolution.deinitListItems(parse_result.pending_imports, bun.default_allocator);
                    parse_result.pending_imports.deinit(bun.default_allocator);
                };
                if (promise_ptr == null) {
                    return error.UnexpectedPendingResolution;
                }

                try jsc_vm.modules.enqueue(
                    globalObject.?,
                    .{
                        .parse_result = parse_result,
                        .path = path,
                        .loader = loader,
                        .watch_source = input_file_fd.isValid(),
                        .package_json = package_json,
                        .promise_ptr = promise_ptr,
                        .specifier = specifier,
                        .referrer = referrer,
                        .arena = arena,
                    },
                );
                give_back_arena = false;
                return error.AsyncModule;
            }

            const is_commonjs_module = parse_result.ast.has_commonjs_export_names or parse_result.ast.exports_kind == .cjs;
            const module_info: ?*analyze_transpiled_module.ModuleInfo =
                if (jsc_vm.useIsolationSourceProviderCache() and !is_commonjs_module and loader.isJavaScriptLike())
                    analyze_transpiled_module.ModuleInfo.create(bun.default_allocator, loader.isTypeScript()) catch null
                else
                    null;
            errdefer if (module_info) |mi| mi.destroy();
            if (module_info) |mi| mi.flags.has_tla = !parse_result.ast.top_level_await_keyword.isEmpty();

            var printer = source_code_printer.*;
            printer.ctx.reset();
            defer source_code_printer.* = printer;
            _ = brk: {
                var mapper = jsc_vm.sourceMapHandler(&printer);

                break :brk try jsc_vm.transpiler.printWithSourceMap(
                    parse_result,
                    @TypeOf(&printer),
                    &printer,
                    .esm_ascii,
                    mapper.get(),
                    module_info,
                );
            };

            if (comptime Environment.dump_source) {
                dumpSource(jsc_vm, specifier, &printer);
            }

            defer {
                if (is_main) {
                    jsc_vm.has_loaded = true;
                }
            }

            const module_info_deserialized: ?*analyze_transpiled_module.ModuleInfoDeserialized = if (module_info) |mi| mi.asDeserialized() else null;

            if (jsc_vm.isWatcherEnabled()) {
                var resolved_source = jsc_vm.refCountedResolvedSource(printer.ctx.written, input_specifier, path.text, null, false);
                resolved_source.is_commonjs_module = is_commonjs_module;
                resolved_source.module_info = if (module_info_deserialized) |value| ResolvedSource.ModuleInfoHandle.initNative(value) else null;
                return resolved_source;
            }

            // Pass along package.json type "module" if set.
            const kind: ResolvedSource.SourceKind = switch (loader) {
                .json, .jsonc => .json_for_object_loader,
                .js, .jsx, .ts, .tsx => brk: {
                    const module_type_ = if (package_json) |pkg| pkg.module_type else module_type;

                    break :brk switch (module_type_) {
                        .esm => .package_json_type_module,
                        .cjs => .package_json_type_commonjs,
                        else => .javascript,
                    };
                },
                else => .javascript,
            };

            return .{
                .source_code = brk: {
                    const written = printer.ctx.getWritten();
                    const result = cache.output_code orelse bun.String.cloneLatin1(written);

                    if (written.len > 1024 * 1024 * 2 or jsc_vm.smol) {
                        printer.ctx.buffer.deinit();
                    }

                    break :brk result;
                },
                .source_url = input_specifier.createIfDifferent(path.text),
                .is_commonjs_module = is_commonjs_module,
                .module_info = if (module_info_deserialized) |value| ResolvedSource.ModuleInfoHandle.initNative(value) else null,
                .tag = .{ .source = kind },
            };
        },
        .napi => return error.NativeAddonImport,
        .wasm => {
            if (strings.eqlComptime(referrer, "undefined") and strings.eqlLong(jsc_vm.main, path.text, true)) {
                if (virtual_source) |source| {
                    if (globalObject) |globalThis| {
                        try bun.bindgen.Engine(InstallWasmSourceBytesSchema).call(globalThis, .{
                            .bytes = bun.bindgen.BytesOperand.fromSlice(source.contents),
                        });
                    }
                }
                return ResolvedSource{
                    .source_code = bun.String.static(@embedFile("../js/wasi-runner.js")),
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .tag = .{ .source = .esm },
                };
            }

            return transpileSourceCode(
                jsc_vm,
                specifier,
                referrer,
                input_specifier,
                path,
                .file,
                .unknown, // cjs/esm don't make sense for wasm
                log,
                virtual_source,
                promise_ptr,
                source_code_printer,
                globalObject,
                flags,
            );
        },

        .sqlite_embedded, .sqlite => {
            const sqlite_module_source_code_string = brk: {
                if (jsc_vm.hot_reload == .hot) {
                    break :brk
                    \\// Generated code
                    \\import {Database} from 'bun:sqlite';
                    \\const {path} = import.meta;
                    \\
                    \\// Don't reload the database if it's already loaded
                    \\const registry = (globalThis[Symbol.for("bun:sqlite:hot")] ??= new Map());
                    \\
                    \\export let db = registry.get(path);
                    \\export const __esModule = true;
                    \\if (!db) {
                    \\   // Load the database
                    \\   db = new Database(path);
                    \\   registry.set(path, db);
                    \\}
                    \\
                    \\export default db;
                    ;
                }

                break :brk
                \\// Generated code
                \\import {Database} from 'bun:sqlite';
                \\export const db = new Database(import.meta.path);
                \\
                \\export const __esModule = true;
                \\export default db;
                ;
            };

            return ResolvedSource{
                .source_code = bun.String.cloneUTF8(sqlite_module_source_code_string),
                .source_url = input_specifier.createIfDifferent(path.text),
                .tag = .{ .source = .esm },
            };
        },

        .html => {
            if (flags.disableTranspiling()) {
                return ResolvedSource{
                    .source_code = bun.String.empty,
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .tag = .{ .source = .esm },
                };
            }

            if (globalObject == null) {
                return error.NotSupported;
            }

            const html_bundle = try jsc.API.HTMLBundle.init(path.text);
            var html_bundle_ref = try bun.api.HTMLBundle.toClassRef(html_bundle, globalObject.?);
            defer html_bundle_ref.deinit();
            return ResolvedSource{
                .jsvalue_for_export = html_bundle_ref.takeEngineRoot(),
                .source_url = input_specifier.createIfDifferent(path.text),
                .tag = .{ .source = .export_default_object },
            };
        },

        else => {
            if (flags.disableTranspiling()) {
                return ResolvedSource{
                    .source_code = bun.String.empty,
                    .source_url = input_specifier.createIfDifferent(path.text),
                    .tag = .{ .source = .esm },
                };
            }

            if (virtual_source == null) {
                if (jsc_vm.isWatcherEnabled()) auto_watch: {
                    if (std.fs.path.isAbsolute(path.text) and !strings.contains(path.text, "node_modules")) {
                        const input_fd: bun.FD = brk: {
                            // kqueue watchers need a file descriptor to receive event notifications on it.
                            if (bun.Watcher.requires_file_descriptors) {
                                switch (bun.sys.open(
                                    &(std.posix.toPosixPath(path.text) catch break :auto_watch),
                                    bun.Watcher.watch_open_flags,
                                    0,
                                )) {
                                    .err => break :auto_watch,
                                    .result => |fd| break :brk fd,
                                }
                            } else {
                                // Otherwise, don't even bother opening it.
                                break :brk .invalid;
                            }
                        };
                        const hash = bun.Watcher.getHash(path.text);
                        switch (jsc_vm.bun_watcher.addFile(
                            input_fd,
                            path.text,
                            hash,
                            loader,
                            .invalid,
                            null,
                            true,
                        )) {
                            .err => {
                                if (comptime Environment.isMac) {
                                    // If any error occurs and we just
                                    // opened the file descriptor to
                                    // receive event notifications on
                                    // it, we should close it.
                                    if (input_fd.isValid()) {
                                        input_fd.close();
                                    }
                                }

                                // we don't consider it a failure if we cannot watch the file
                                // they didn't open the file
                            },
                            .result => {},
                        }
                    }
                }
            }

            var path_string = brk: {
                if (!jsc_vm.origin.isEmpty()) {
                    const public_path = try jsc.API.Bun.getPublicPathWithAssetPrefix(
                        jsc_vm.allocator,
                        specifier,
                        jsc_vm.transpiler.fs.top_level_dir,
                        jsc_vm.origin,
                        "",
                        .auto,
                    );
                    defer jsc_vm.allocator.free(public_path);
                    break :brk try bun.bindgen.DOMString.fromUTF8(public_path);
                }

                break :brk try bun.bindgen.DOMString.fromUTF8(path.text);
            };
            defer path_string.deinit();
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(globalObject.?);
            defer scope.deinit();
            const value = try scope.engineIn("js_strings", "stringToJS").call(.{ .value = path_string.operand() });

            return ResolvedSource{
                .jsvalue_for_export = try value.eraseBrandToEngineRoot(),
                .source_url = input_specifier.createIfDifferent(path.text),
                .tag = .{ .source = .export_default_object },
            };
        },
    }
}

fn resolveAndFetchBuiltinModule(
    jsc_vm: *VirtualMachine,
    specifier: bun.String,
    ret: *jsc.ResolvedSourceResult,
) bool {
    const alias = HardcodedModule.Alias.bun_aliases.getWithEql(specifier, bun.String.eqlComptime) orelse
        return false;
    const hardcoded = HardcodedModule.map.get(alias.path) orelse {
        bun.debugAssert(false);
        return false;
    };
    ret.* = .ok(
        getHardcodedModule(jsc_vm, specifier, hardcoded) orelse
            return false,
    );
    return true;
}

fn fetchBuiltinModuleForBindings(
    jsc_vm: *VirtualMachine,
    globalObject: *JSGlobalObject,
    specifier: bun.String,
    referrer: bun.String,
    ret: *jsc.ResolvedSourceResult,
) bun.JSError!bool {
    var log = logger.Log.init(jsc_vm.transpiler.allocator);
    defer log.deinit();

    if (ModuleLoader.fetchBuiltinModule(
        jsc_vm,
        specifier,
    ) catch |err| {
        if (err == error.AsyncModule) {
            unreachable;
        }

        try VirtualMachine.processFetchLog(globalObject, specifier, referrer, &log, ret, err);
        return true;
    }) |builtin| {
        ret.* = jsc.ResolvedSourceResult.ok(builtin);
        return true;
    } else {
        return false;
    }
}

const always_sync_modules = .{"reflect-metadata"};

fn transpileFile(
    jsc_vm: *VirtualMachine,
    globalObject: *JSGlobalObject,
    specifier: bun.String,
    referrer: bun.String,
    type_attribute: ?bun.String,
    ret: *?jsc.ResolvedSourceResult,
    allow_promise: bool,
    is_commonjs_require: bool,
    _force_loader_type: bun.schema.api.Loader,
) bun.JSError!?OwnedModulePromise {
    const force_loader_type: bun.options.Loader.Optional = .fromAPI(_force_loader_type);
    var log = logger.Log.init(jsc_vm.transpiler.allocator);
    defer log.deinit();

    var _specifier = try specifier.toUTF8(jsc_vm.allocator);
    defer _specifier.deinit();
    var referrer_slice = try referrer.toUTF8(jsc_vm.allocator);
    defer referrer_slice.deinit();

    var type_attribute_str: ?string = null;
    if (type_attribute) |attribute| if (attribute.asUTF8()) |attr_utf8| {
        type_attribute_str = attr_utf8;
    };

    var virtual_source_to_use: ?logger.Source = null;
    var blob_to_deinit: ?jsc.WebCore.Blob = null;
    var lr = getLoaderAndVirtualSource(_specifier.slice(), jsc_vm, &virtual_source_to_use, &blob_to_deinit, type_attribute_str) catch |err| switch (err) {
        error.BlobNotFound => {
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(globalObject);
            defer scope.deinit();
            var message = try bun.bindgen.DOMString.fromUTF8("Blob not found");
            defer message.deinit();
            const value = try jsc.NodeError.create(&scope, .MODULE_NOT_FOUND, &message);
            ret.* = .fail(try value.eraseBrandToEngineRoot());
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer if (blob_to_deinit) |*blob| blob.deinit();

    if (force_loader_type.unwrap()) |loader_type| {
        @branchHint(.unlikely);
        bun.assert(!is_commonjs_require);
        lr.loader = loader_type;
    } else if (is_commonjs_require and jsc_vm.has_mutated_built_in_extensions > 0) {
        @branchHint(.unlikely);
        if (findLongestRegisteredExtension(jsc_vm, _specifier.slice())) |entry| {
            switch (entry.*) {
                .loader => |loader| {
                    lr.loader = loader;
                },
                .custom => |*strong| {
                    ret.* = jsc.ResolvedSourceResult.ok(ResolvedSource{
                        .source_code = bun.String.empty,
                        .source_url = .empty,
                        .cjs_custom_extension = strong.clone(),
                        .tag = .{ .source = .common_js_custom_extension },
                    });
                    return null;
                },
            }
        }
    }

    const path_extension = std.fs.path.extension(lr.path.text);
    const module_type: options.ModuleType = brk: {
        const ext = path_extension;
        // regular expression /.[cm][jt]s$/
        if (ext.len == ".cjs".len) {
            if (strings.eqlComptimeIgnoreLen(ext, ".cjs"))
                break :brk .cjs;
            if (strings.eqlComptimeIgnoreLen(ext, ".mjs"))
                break :brk .esm;
            if (strings.eqlComptimeIgnoreLen(ext, ".cts"))
                break :brk .cjs;
            if (strings.eqlComptimeIgnoreLen(ext, ".mts"))
                break :brk .esm;
        }
        // regular expression /.[jt]s$/
        if (ext.len == ".ts".len) {
            if (strings.eqlComptimeIgnoreLen(ext, ".js") or
                strings.eqlComptimeIgnoreLen(ext, ".ts"))
            {
                // Use the package.json module type if it exists
                break :brk if (lr.package_json) |pkg|
                    pkg.module_type
                else
                    .unknown;
            }
        }
        // For JSX TSX and other extensions, let the file contents.
        break :brk .unknown;
    };
    const pkg_name: ?[]const u8 = if (lr.package_json) |pkg|
        if (pkg.name.len > 0) pkg.name else null
    else
        null;

    // We only run the transpiler concurrently when we can.
    // Today, that's:
    //
    //   Import Statements (import 'foo')
    //   Import Expressions (import('foo'))
    //
    transpile_async: {
        if (comptime bun.FeatureFlags.concurrent_transpiler) {
            const concurrent_loader = lr.loader orelse .file;
            if (blob_to_deinit == null and
                allow_promise and
                (jsc_vm.has_loaded or jsc_vm.is_in_preload) and
                concurrent_loader.isJavaScriptLike() and
                !lr.is_main and
                // Plugins make this complicated,
                // TODO: allow running concurrently when no onLoad handlers match a plugin.
                jsc_vm.plugin_runner == null and jsc_vm.transpiler_store.enabled)
            {
                // This absolutely disgusting hack is a workaround in cases
                // where an async import is made to a CJS file with side
                // effects that other modules depend on, without incurring
                // the cost of transpiling/loading CJS modules synchronously.
                //
                // The cause of this comes from the fact that we immediately
                // and synchronously evaluate CJS modules after they've been
                // transpiled, but transpiling (which, for async imports,
                // happens in a thread pool), can resolve in whatever order.
                // This messes up module execution order.
                //
                // This is only _really_ important for
                // import("some-polyfill") cases, the most impactful of
                // which is `reflect-metadata`. People could also use
                // require or just preload their polyfills, but they aren't
                // doing this. This hack makes important polyfills work without
                // incurring the cost of transpiling/loading CJS modules
                // synchronously. The proper fix is to evaluate CJS modules
                // at the same time as ES modules. This is blocked by the
                // fact that we need exports from CJS modules and our parser
                // doesn't record them.
                if (pkg_name) |pkg_name_| {
                    inline for (always_sync_modules) |always_sync_specifier| {
                        if (bun.strings.eqlComptime(pkg_name_, always_sync_specifier)) {
                            break :transpile_async;
                        }
                    }
                }

                // TODO: check if the resolved source must be transpiled synchronously
                return try jsc_vm.transpiler_store.transpile(
                    jsc_vm,
                    globalObject,
                    specifier.dupeRef(),
                    lr.path,
                    referrer.dupeRef(),
                    concurrent_loader,
                    lr.package_json,
                );
            }
        }
    }

    const synchronous_loader: options.Loader = lr.loader orelse loader: {
        if (jsc_vm.has_loaded or jsc_vm.is_in_preload) {
            // Extensionless files in this context are treated as the JS loader
            if (path_extension.len == 0) {
                break :loader .tsx;
            }

            // Unknown extensions are to be treated as file loader
            if (is_commonjs_require) {
                if (jsc_vm.commonjs_custom_extensions.entries.len > 0 and
                    jsc_vm.has_mutated_built_in_extensions == 0)
                {
                    @branchHint(.unlikely);
                    if (findLongestRegisteredExtension(jsc_vm, lr.path.text)) |entry| {
                        switch (entry.*) {
                            .loader => |loader| break :loader loader,
                            .custom => |*strong| {
                                ret.* = jsc.ResolvedSourceResult.ok(ResolvedSource{
                                    .source_code = bun.String.empty,
                                    .source_url = .empty,
                                    .cjs_custom_extension = strong.clone(),
                                    .tag = .{ .source = .common_js_custom_extension },
                                });
                                return null;
                            },
                        }
                    }
                }

                // For Node.js compatibility, requiring a file with an
                // unknown extension will be treated as a JS file
                break :loader .ts;
            }

            // For ESM, Bun treats unknown extensions as file loader
            break :loader .file;
        } else {
            // Unless it's potentially the main module
            // This is important so that "bun run ./foo-i-have-no-extension" works
            break :loader .tsx;
        }
    };

    if (comptime Environment.allow_assert)
        debug("transpile({s}, {s}, sync)", .{ lr.specifier, @tagName(synchronous_loader) });

    defer jsc_vm.module_loader.resetArena(jsc_vm);

    var promise: ?OwnedModulePromise = null;
    defer if (promise) |*value| value.deinit();
    ret.* = jsc.ResolvedSourceResult.ok(
        ModuleLoader.transpileSourceCode(
            jsc_vm,
            lr.specifier,
            referrer_slice.slice(),
            specifier,
            lr.path,
            synchronous_loader,
            module_type,
            &log,
            lr.virtual_source,
            if (allow_promise) &promise else null,
            VirtualMachine.source_code_printer.?,
            globalObject,
            FetchFlags.transpile,
        ) catch |err| {
            switch (err) {
                error.AsyncModule => {
                    bun.assert(promise != null);
                    return promise.?.take();
                },
                error.OutOfMemory, error.JSTerminated => |failure| return failure,
                error.JSError => {
                    ret.* = .fail(try jsc.ModuleLoaderEngine.takeFailureAsRoot(globalObject, error.JSError));
                    return null;
                },
                else => {
                    var failure: jsc.ResolvedSourceResult = undefined;
                    try VirtualMachine.processFetchLog(globalObject, specifier, referrer, &log, &failure, err);
                    ret.* = failure;
                    return null;
                },
            }
        },
    );
    return if (promise) |*value| value.take() else null;
}

fn bindRunVirtualModule(
    context: bun.bindgen.CallContext(RunVirtualModuleSchema),
    args: bun.bindgen.Args(RunVirtualModuleSchema),
) bun.JSError!bun.bindgen.Return(RunVirtualModuleSchema) {
    return jsc.ModuleLoaderEngine.runVirtualModule(context, args);
}

fn getHardcodedModule(jsc_vm: *VirtualMachine, specifier: bun.String, hardcoded: HardcodedModule) ?ResolvedSource {
    analytics.Features.builtin_modules.insert(hardcoded);
    return switch (hardcoded) {
        .@"bun:main" => if (jsc_vm.entry_point.generated) .{
            .source_code = bun.String.cloneUTF8(jsc_vm.entry_point.contents),
            .source_url = specifier.dupeRef(),
            .tag = .{ .source = .esm },
            .source_code_needs_deref = true,
        } else null,
        .@"bun:internal-for-testing" => {
            if (!Environment.isDebug) {
                if (!is_allowed_to_use_internal_testing_apis)
                    return null;
            }
            return jsSyntheticModule("bun:internal-for-testing");
        },
        .@"bun:wrap" => .{
            .source_code = String.cloneUTF8(Runtime.Runtime.sourceCode(jsc_vm.io)),
            .source_url = specifier.dupeRef(),
        },
        inline else => |tag| jsSyntheticModule(@tagName(tag)),
    };
}

pub fn fetchBuiltinModule(jsc_vm: *VirtualMachine, specifier: bun.String) !?ResolvedSource {
    if (HardcodedModule.map.getWithEql(specifier, bun.String.eqlComptime)) |hardcoded| {
        return getHardcodedModule(jsc_vm, specifier, hardcoded);
    }

    if (jsc_vm.standalone_module_graph) |graph| {
        const specifier_utf8 = try specifier.toUTF8(bun.default_allocator);
        defer specifier_utf8.deinit();
        if (graph.files.getPtr(specifier_utf8.slice())) |file| {
            if (file.loader == .sqlite or file.loader == .sqlite_embedded) {
                const code =
                    \\/* Generated code */
                    \\import {Database} from 'bun:sqlite';
                    \\import {readFileSync} from 'node:fs';
                    \\export const db = new Database(readFileSync(import.meta.path));
                    \\
                    \\export const __esModule = true;
                    \\export default db;
                ;
                return .{
                    .source_code = bun.String.static(code),
                    .source_url = specifier.dupeRef(),
                    .source_code_needs_deref = false,
                };
            }

            const module_info = if (file.module_info.len > 0)
                try analyze_transpiled_module.ModuleInfoDeserialized.createFromCachedRecord(file.module_info, bun.default_allocator)
            else
                null;
            return .{
                .source_code = file.toWTFString(),
                .source_url = specifier.dupeRef(),
                // bytecode_origin_path is the path used when generating bytecode; must match for cache hits
                .bytecode_origin_path = if (file.bytecode_origin_path.len > 0) bun.String.cloneUTF8(file.bytecode_origin_path) else bun.String.empty,
                .source_code_needs_deref = false,
                .bytecode_cache = if (file.bytecode.len > 0) .{ .borrowed = file.bytecode } else null,
                .module_info = if (module_info) |value| ResolvedSource.ModuleInfoHandle.initNative(value) else null,
                .is_commonjs_module = file.module_format == .cjs,
            };
        }
    }

    return null;
}

fn transpileVirtualModule(
    globalObject: *JSGlobalObject,
    specifier_string: bun.String,
    referrer: bun.String,
    source_code: []const u8,
    loader: options.Loader,
    ret: *jsc.ResolvedSourceResult,
) bun.JSError!void {
    const jsc_vm = globalObject.bunVM();
    // Plugin runner is not required for virtual modules created via build.module()
    // bun.assert(jsc_vm.plugin_runner != null);

    var specifier_slice = try specifier_string.toUTF8(jsc_vm.allocator);
    const specifier = specifier_slice.slice();
    defer specifier_slice.deinit();
    var referrer_slice = try referrer.toUTF8(jsc_vm.allocator);
    defer referrer_slice.deinit();

    var virtual_source = logger.Source.initPathString(specifier, source_code);
    var log = logger.Log.init(jsc_vm.allocator);
    const path = Fs.Path.init(specifier);

    defer log.deinit();
    defer jsc_vm.module_loader.resetArena(jsc_vm);

    ret.* = jsc.ResolvedSourceResult.ok(
        ModuleLoader.transpileSourceCode(
            jsc_vm,
            specifier_slice.slice(),
            referrer_slice.slice(),
            specifier_string,
            path,
            loader,
            .unknown,
            &log,
            &virtual_source,
            null,
            VirtualMachine.source_code_printer.?,
            globalObject,
            FetchFlags.transpile,
        ) catch |err| {
            switch (err) {
                error.OutOfMemory, error.JSTerminated => |failure| return failure,
                error.JSError => {
                    ret.* = .fail(try jsc.ModuleLoaderEngine.takeFailureAsRoot(globalObject, error.JSError));
                    return;
                },
                else => {
                    try VirtualMachine.processFetchLog(globalObject, specifier_string, referrer, &log, ret, err);
                    return;
                },
            }
        },
    );
    analytics.Features.virtual_modules += 1;
}

fn retainDOMString(value: bun.bindgen.DOMStringView) bun.String {
    var owned = value.toOwned();
    return owned.takeBunString();
}

fn bindResolveAndFetchBuiltinModule(
    context: bun.bindgen.CallContext(ResolveAndFetchBuiltinModuleSchema),
    args: bun.bindgen.Args(ResolveAndFetchBuiltinModuleSchema),
) bun.JSError!bun.bindgen.Return(ResolveAndFetchBuiltinModuleSchema) {
    const specifier = retainDOMString(args.specifier);
    defer specifier.deref();
    var result: jsc.ResolvedSourceResult = undefined;
    const globalObject = context.viewToken().globalObject();
    if (!resolveAndFetchBuiltinModule(globalObject.bunVM(), specifier, &result)) return null;
    return try result.takeWire(context);
}

fn bindFetchBuiltinModule(
    context: bun.bindgen.CallContext(FetchBuiltinModuleSchema),
    args: bun.bindgen.Args(FetchBuiltinModuleSchema),
) bun.JSError!bun.bindgen.Return(FetchBuiltinModuleSchema) {
    const globalObject = context.viewToken().globalObject();
    const specifier = retainDOMString(args.specifier);
    defer specifier.deref();
    const referrer = retainDOMString(args.referrer);
    defer referrer.deref();
    var result: jsc.ResolvedSourceResult = undefined;
    if (!try fetchBuiltinModuleForBindings(globalObject.bunVM(), globalObject, specifier, referrer, &result)) return null;
    return try result.takeWire(context);
}

fn bindTranspileFile(
    context: bun.bindgen.CallContext(TranspileFileSchema),
    args: bun.bindgen.Args(TranspileFileSchema),
) bun.JSError!bun.bindgen.Return(TranspileFileSchema) {
    const globalObject = context.viewToken().globalObject();
    const specifier = retainDOMString(args.specifier);
    defer specifier.deref();
    const referrer = retainDOMString(args.referrer);
    defer referrer.deref();
    const type_attribute: ?bun.String = if (args.typeAttribute) |value| retainDOMString(value) else null;
    defer if (type_attribute) |value| value.deref();
    var result: ?jsc.ResolvedSourceResult = null;
    defer if (result) |*value| value.deinit();
    var promise = try transpileFile(
        globalObject.bunVM(),
        globalObject,
        specifier,
        referrer,
        type_attribute,
        &result,
        args.allowPromise,
        args.isCommonJSRequire,
        @fromBackingInt(@backingInt(args.forceLoaderType)),
    );
    defer if (promise) |*value| value.deinit();
    const converted_result = if (result) |*value| try value.takeWire(context) else null;
    return .{
        .promise = if (promise) |*value| value.toResult(context) else null,
        .result = converted_result,
    };
}

fn bindTranspileVirtualModuleCode(
    context: bun.bindgen.CallContext(TranspileVirtualModuleCodeSchema),
    args: bun.bindgen.Args(TranspileVirtualModuleCodeSchema),
) bun.JSError!bun.bindgen.Return(TranspileVirtualModuleCodeSchema) {
    const globalObject = context.viewToken().globalObject();
    const specifier = retainDOMString(args.specifier);
    defer specifier.deref();
    const referrer = retainDOMString(args.referrer);
    defer referrer.deref();
    const source_code = try args.sourceCode.toUTF8(globalObject.bunVM().allocator);
    defer source_code.deinit();
    const loader: options.Loader = if (args.loader) |loader| switch (loader) {
        ._none => unreachable,
        inline else => |value| @field(options.Loader, @tagName(value)),
    } else blk: {
        const filename = try specifier.toUTF8(globalObject.bunVM().allocator);
        defer filename.deinit();
        break :blk defaultLoader(globalObject.bunVM(), filename.slice());
    };
    var result: jsc.ResolvedSourceResult = undefined;
    try transpileVirtualModule(
        globalObject,
        specifier,
        referrer,
        source_code.slice(),
        loader,
        &result,
    );
    return try result.takeWireAs(bun.bindgen.Return(TranspileVirtualModuleCodeSchema), context);
}

inline fn jsSyntheticModule(comptime specifier: []const u8) ResolvedSource {
    return ResolvedSource{
        .source_code = bun.String.empty,
        .source_url = bun.String.static(specifier),
        .tag = .{ .builtin = bun.bindgen.enumConstant(BuiltinModuleId, specifier) },
        .source_code_needs_deref = false,
    };
}

/// Dumps the module source to a file in /tmp/bun-debug-src/{filepath}
///
/// This can technically fail if concurrent access across processes happens, or permission issues.
/// Errors here should always be ignored.
pub const FetchFlags = enum {
    transpile,
    print_source,
    print_source_and_clone,

    pub fn disableTranspiling(this: FetchFlags) bool {
        return this != .transpile;
    }
};

fn bindResolveEmbeddedNodeFile(
    args: bun.bindgen.Args(ResolveEmbeddedNodeFileSchema),
) bun.OOM!bun.bindgen.Return(ResolveEmbeddedNodeFileSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    if (vm.standalone_module_graph == null) return null;

    const input_path = try args.path.toUTF8(bun.default_allocator);
    defer input_path.deinit();
    const path_buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(path_buf);
    const result = ModuleLoader.resolveEmbeddedFile(vm, path_buf, input_path.slice(), "node") orelse return null;
    return try bun.bindgen.DOMString.fromUTF8(result);
}

fn bindIsBuiltin(
    args: bun.bindgen.Args(IsBuiltinSchema),
) bun.bindgen.Return(IsBuiltinSchema) {
    const specifier = args.specifier.unsafePtr("the generated native export frame owns the specifier bytes until builtin-module lookup returns");
    return HardcodedModule.Alias.bun_aliases.get(specifier) != null;
}

const debug = Output.scoped(.ModuleLoader, .hidden);

const string = []const u8;

const Fs = @import("../resolver/fs.zig");
const Runtime = @import("../js_parser/runtime.zig");
pub const ExpressionEngine = @import("../js_parser_jsc/ExpressionEngine.zig");
const analyze_transpiled_module = @import("../bundler/analyze_transpiled_module.zig");
const ast = @import("../options_types/import_record.zig");
const std = @import("std");

const options = @import("../bundler/options.zig");
const ModuleType = options.ModuleType;

const MacroRemap = @import("../resolver/package_json.zig").MacroMap;
const PackageJSON = @import("../resolver/package_json.zig").PackageJSON;

const dumpSource = @import("./RuntimeTranspilerStore.zig").dumpSource;
const dumpSourceString = @import("./RuntimeTranspilerStore.zig").dumpSourceString;
const setBreakPointOnFirstLine = @import("./RuntimeTranspilerStore.zig").setBreakPointOnFirstLine;

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const Output = bun.Output;
const String = bun.String;
const Transpiler = bun.Transpiler;
const analytics = bun.analytics;
const js_ast = bun.ast;
const js_printer = bun.js_printer;
const logger = bun.logger;
const strings = bun.strings;
const Arena = bun.allocators.MimallocArena;

const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const InstallWasmSourceBytesSchema = ModuleLoaderBindings.engineShim("installWasmSourceBytes");
const ResolveAndFetchBuiltinModuleSchema = ModuleLoaderBindings.nativeExport("resolveAndFetchBuiltinModule");
const FetchBuiltinModuleSchema = ModuleLoaderBindings.nativeExport("fetchBuiltinModule");
const BuiltinModuleId = schema: {
    const SourceType = bun.bindgen.UnionMemberType(FetchBuiltinModuleSchema.ReturnType.child, "value");
    const TagType = bun.bindgen.DictionaryFieldType(SourceType, "tag");
    break :schema bun.bindgen.UnionMemberType(TagType, "builtin");
};
const TranspileFileSchema = ModuleLoaderBindings.nativeExport("transpileFile");
const TranspileVirtualModuleCodeSchema = ModuleLoaderBindings.nativeExport("transpileVirtualModuleCode");
const RunVirtualModuleSchema = ModuleLoaderBindings.nativeExport("runVirtualModule");
const ResolveEmbeddedNodeFileSchema = ModuleLoaderBindings.nativeExport("resolveEmbeddedNodeFile");
const IsBuiltinSchema = ModuleLoaderBindings.nativeExport("moduleLoaderIsBuiltin");
const PrepareCommonJSExtensionSchema = ModuleLoaderBindings.nativeExport("prepareCommonJSExtensionUpdate");
const FinishCommonJSExtensionSchema = ModuleLoaderBindings.nativeExport("finishCommonJSExtensionUpdate");
const ResolveAndFetchBuiltinModuleBinding = bun.bindgen.Fn(ResolveAndFetchBuiltinModuleSchema, bindResolveAndFetchBuiltinModule);
const FetchBuiltinModuleBinding = bun.bindgen.Fn(FetchBuiltinModuleSchema, bindFetchBuiltinModule);
const TranspileFileBinding = bun.bindgen.Fn(TranspileFileSchema, bindTranspileFile);
const TranspileVirtualModuleCodeBinding = bun.bindgen.Fn(TranspileVirtualModuleCodeSchema, bindTranspileVirtualModuleCode);
const RunVirtualModuleBinding = bun.bindgen.Fn(RunVirtualModuleSchema, bindRunVirtualModule);
const ResolveEmbeddedNodeFileBinding = bun.bindgen.Fn(ResolveEmbeddedNodeFileSchema, bindResolveEmbeddedNodeFile);
const IsBuiltinBinding = bun.bindgen.Fn(IsBuiltinSchema, bindIsBuiltin);

const jsc = bun.jsc;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const ResolvedSource = bun.jsc.ResolvedSource;
const VirtualMachine = bun.jsc.VirtualMachine;
const Bun = jsc.API.Bun;

const ParseResult = bun.transpiler.ParseResult;
