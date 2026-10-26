const debug = bun.Output.scoped(.Transpiler, .visible);

pub const JSBundler = struct {
    const OwnedString = bun.MutableString;

    pub const FileMap = CoreFileMap;

    pub const Config = struct {
        target: Target = Target.browser,
        entry_points: bun.StringSet = bun.StringSet.init(bun.default_allocator),
        hot: bool = false,
        react_fast_refresh: bool = false,
        define: bun.StringMap = bun.StringMap.init(bun.default_allocator, false),
        loaders: ?api.LoaderMap = null,
        dir: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        outdir: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        rootdir: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        serve: Serve = .{},
        jsx: api.Jsx = .{
            .factory = "",
            .fragment = "",
            .runtime = .automatic,
            .import_source = "",
            .development = true, // Default to development mode like old Pragma
        },
        force_node_env: options.BundleOptions.ForceNodeEnv = .unspecified,
        code_splitting: bool = false,
        minify: Minify = .{},
        no_macros: bool = false,
        ignore_dce_annotations: bool = false,
        emit_dce_annotations: ?bool = null,
        names: Names = .{},
        external: bun.StringSet = bun.StringSet.init(bun.default_allocator),
        allow_unresolved: ?bun.StringSet = null,
        source_map: options.SourceMapOption = .none,
        public_path: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        conditions: bun.StringSet = bun.StringSet.init(bun.default_allocator),
        packages: options.PackagesOption = .bundle,
        format: options.Format = .esm,
        bytecode: bool = false,
        banner: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        footer: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        /// Path to write JSON metafile (if specified via metafile object) - TEST: moved here
        metafile_json_path: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        /// Path to write markdown metafile (if specified via metafile object) - TEST: moved here
        metafile_markdown_path: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        css_chunking: bool = false,
        drop: bun.StringSet = bun.StringSet.init(bun.default_allocator),
        features: options.FeatureSet = .empty,
        throw_on_error: bool = true,
        env_behavior: api.DotEnvBehavior = .disable,
        env_prefix: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        tsconfig_override: OwnedString = OwnedString.initEmpty(bun.default_allocator),
        compile: ?CompileOptions = null,
        /// In-memory files that can be used as entrypoints or imported.
        /// These files do not need to exist on disk.
        files: FileMap = .{},
        /// Generate metafile (JSON module graph)
        metafile: bool = false,
        /// Package names whose barrel files should be optimized.
        /// Named imports from these packages will only load the submodules
        /// that are actually used instead of parsing all re-exported submodules.
        optimize_imports: bun.StringSet = bun.StringSet.init(bun.default_allocator),

        pub const CompileOptions = struct {
            compile_target: CompileTarget = .{},
            exec_argv: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            executable_path: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            windows_hide_console: bool = false,
            windows_icon_path: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            windows_title: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            windows_publisher: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            windows_version: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            windows_description: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            windows_copyright: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            outfile: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            autoload_dotenv: bool = true,
            autoload_bunfig: bool = true,
            autoload_tsconfig: bool = false,
            autoload_package_json: bool = false,

            pub fn fromSchema(
                globalThis: *jsc.JSGlobalObject,
                context: anytype,
                field_optional: anytype,
                compile_target: ?CompileTarget,
                allocator: std.mem.Allocator,
            ) !?CompileOptions {
                var this = CompileOptions{
                    .exec_argv = OwnedString.initEmpty(allocator),
                    .executable_path = OwnedString.initEmpty(allocator),
                    .windows_icon_path = OwnedString.initEmpty(allocator),
                    .windows_title = OwnedString.initEmpty(allocator),
                    .windows_publisher = OwnedString.initEmpty(allocator),
                    .windows_version = OwnedString.initEmpty(allocator),
                    .windows_description = OwnedString.initEmpty(allocator),
                    .windows_copyright = OwnedString.initEmpty(allocator),
                    .outfile = OwnedString.initEmpty(allocator),
                    .compile_target = compile_target orelse .{},
                };
                errdefer this.deinit();

                const field = field_optional orelse {
                    this.deinit();
                    return null;
                };
                const object = switch (field.*) {
                    .flag => |flag| {
                        if (!flag) {
                            this.deinit();
                            return null;
                        }
                        return this;
                    },
                    .text => |*text| {
                        const utf8 = try text.toUTF8(bun.default_allocator);
                        defer utf8.deinit();
                        this.compile_target = try jsc.API.BundlerOptionsEngine.compileTargetFromSlice(globalThis, utf8.slice());
                        return this;
                    },
                    .options => |*options_dict| options_dict,
                    .invalid => return context.fail(.invalid_compile, {}),
                };

                if (object.target) |*target_field| {
                    if (target_field.*) |*text| {
                        const utf8 = try text.toUTF8(bun.default_allocator);
                        defer utf8.deinit();
                        this.compile_target = try jsc.API.BundlerOptionsEngine.compileTargetFromSlice(globalThis, utf8.slice());
                    }
                }

                if (object.execArgv) |*exec_argv_field| switch (exec_argv_field.*) {
                    .list => |*list| {
                        var iterator = list.iterator();
                        var index: usize = 0;
                        while (iterator.next()) |element| : (index += 1) {
                            const utf8 = try element.value.toUTF8(bun.default_allocator);
                            defer utf8.deinit();
                            if (index != 0) try this.exec_argv.appendChar(' ');
                            try this.exec_argv.appendSlice(utf8.slice());
                        }
                    },
                    .ignored => {},
                };

                if (object.executablePath) |*executable_path_field| {
                    if (executable_path_field.*) |*text| {
                        const utf8 = try text.toUTF8(bun.default_allocator);
                        defer utf8.deinit();
                        if (bun.sys.existsAtType(bun.FD.cwd(), utf8.slice()).unwrapOr(.directory) != .file) {
                            return context.fail(.invalid_executable_path, {});
                        }

                        try this.executable_path.appendSliceExact(utf8.slice());
                    }
                }

                if (object.windows) |*windows_field| switch (windows_field.*) {
                    .options => |*windows| {
                        if (windows.hideConsole) |flag| this.windows_hide_console = flag;

                        if (windows.icon) |*icon_field| {
                            if (icon_field.*) |*text| {
                                const utf8 = try text.toUTF8(bun.default_allocator);
                                defer utf8.deinit();
                                if (bun.sys.existsAtType(bun.FD.cwd(), utf8.slice()).unwrapOr(.directory) != .file) {
                                    return context.fail(.invalid_windows_icon, {});
                                }

                                try this.windows_icon_path.appendSliceExact(utf8.slice());
                            }
                        }

                        inline for (.{
                            .{ "title", "windows_title" },
                            .{ "publisher", "windows_publisher" },
                            .{ "version", "windows_version" },
                            .{ "description", "windows_description" },
                            .{ "copyright", "windows_copyright" },
                        }) |pair| {
                            if (@field(windows, pair[0])) |*text_field| {
                                if (text_field.*) |*text| {
                                    const utf8 = try text.toUTF8(bun.default_allocator);
                                    defer utf8.deinit();
                                    try @field(this, pair[1]).appendSliceExact(utf8.slice());
                                }
                            }
                        }
                    },
                    .ignored => {},
                };

                if (object.outfile) |*outfile_field| {
                    if (outfile_field.*) |*text| {
                        const utf8 = try text.toUTF8(bun.default_allocator);
                        defer utf8.deinit();
                        try this.outfile.appendSliceExact(utf8.slice());
                    }
                }

                if (object.autoloadDotenv) |flag| this.autoload_dotenv = flag;
                if (object.autoloadBunfig) |flag| this.autoload_bunfig = flag;
                if (object.autoloadTsconfig) |flag| this.autoload_tsconfig = flag;
                if (object.autoloadPackageJson) |flag| this.autoload_package_json = flag;

                return this;
            }

            pub fn deinit(this: *CompileOptions) void {
                this.exec_argv.deinit();
                this.executable_path.deinit();
                this.windows_icon_path.deinit();
                this.windows_title.deinit();
                this.windows_publisher.deinit();
                this.windows_version.deinit();
                this.windows_description.deinit();
                this.windows_copyright.deinit();
                this.outfile.deinit();
            }
        };

        pub const List = bun.StringArrayHashMap(Config);

        fn appendPrefixedName(target: *OwnedString, text: []const u8) bun.OOM!void {
            if (!strings.hasPrefixComptime(text, "./")) {
                try target.appendSliceExact("./");
            }
            try target.appendSliceExact(text);
        }

        fn appendStringSet(
            list: anytype,
            set: *bun.StringSet,
        ) bun.JSError!void {
            var iterator = list.iterator();
            while (iterator.next()) |element| {
                const utf8 = try element.value.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                try set.insert(utf8.slice());
            }
        }

        fn appendText(text: anytype, target: *OwnedString) bun.OOM!void {
            const utf8 = try text.toUTF8(bun.default_allocator);
            defer utf8.deinit();
            try target.appendSliceExact(utf8.slice());
        }

        fn featureSet(list: anytype) bun.JSError!options.FeatureSet {
            var names = try options.FeatureSet.OwnedNames.Builder.init(list.len());
            errdefer names.deinit();
            var iterator = list.iterator();
            while (iterator.next()) |element| {
                names.appendOwned(.fromOwnedSlice(try element.value.toOwnedSlice(bun.default_allocator)));
            }
            return options.FeatureSet.fromOwned(names.finish());
        }

        pub fn fromSchema(
            globalThis: *jsc.JSGlobalObject,
            context: anytype,
            generated: anytype,
            target: Target,
            did_set_target: bool,
            compile: ?CompileOptions,
            allocator: std.mem.Allocator,
        ) !Config {
            var this = Config{
                .entry_points = bun.StringSet.init(allocator),
                .external = bun.StringSet.init(allocator),
                .optimize_imports = bun.StringSet.init(allocator),
                .define = bun.StringMap.init(allocator, true),
                .dir = OwnedString.initEmpty(allocator),
                .outdir = OwnedString.initEmpty(allocator),
                .rootdir = OwnedString.initEmpty(allocator),
                .names = .{
                    .owned_entry_point = OwnedString.initEmpty(allocator),
                    .owned_chunk = OwnedString.initEmpty(allocator),
                    .owned_asset = OwnedString.initEmpty(allocator),
                },
            };
            errdefer this.deinit(allocator);
            this.target = target;
            this.compile = compile;

            if (generated.macros) |flag| this.no_macros = !flag;

            if (generated.bytecode) |bytecode| {
                this.bytecode = bytecode;

                if (bytecode) {
                    // Default to CJS for bytecode, since esm doesn't really work yet.
                    this.format = .cjs;
                    if (did_set_target and this.target != .bun) {
                        return context.fail(.invalid_bytecode_target, {});
                    }
                    this.target = .bun;
                }
            }

            if (generated.reactFastRefresh) |flag| this.react_fast_refresh = flag;

            var has_out_dir = false;
            if (generated.outdir) |*field| {
                if (field.*) |*text| {
                    try appendText(text, &this.outdir);
                    has_out_dir = true;
                }
            }

            if (generated.banner) |*field| {
                if (field.*) |*text| try appendText(text, &this.banner);
            }

            if (generated.footer) |*field| {
                if (field.*) |*text| try appendText(text, &this.footer);
            }

            if (generated.sourcemap) |*field| switch (field.*) {
                .flag => |flag| {
                    if (flag) {
                        this.source_map = if (has_out_dir) .linked else .@"inline";
                    }
                },
                .named => |named| this.source_map = switch (named) {
                    .none => .none,
                    .inlined => .@"inline",
                    .external => .external,
                    .linked => .linked,
                },
                .ignored => {},
            };

            if (generated.env) |*field| switch (field.*) {
                .flag => |flag| this.env_behavior = if (flag) .load_all else .disable,
                .count => |count| {
                    if (count == 0) {
                        this.env_behavior = .disable;
                    } else if (count == 1) {
                        this.env_behavior = .load_all;
                    } else {
                        return context.fail(.invalid_env, {});
                    }
                },
                .name => |*name| {
                    const utf8 = try name.toUTF8(bun.default_allocator);
                    defer utf8.deinit();
                    const slice = utf8.slice();
                    if (strings.eqlComptime(slice, "inline")) {
                        this.env_behavior = .load_all;
                    } else if (strings.eqlComptime(slice, "disable")) {
                        this.env_behavior = .disable;
                    } else if (strings.indexOfChar(slice, '*')) |asterisk| {
                        if (asterisk > 0) {
                            this.env_behavior = .prefix;
                            try this.env_prefix.appendSliceExact(slice[0..asterisk]);
                        } else {
                            this.env_behavior = .load_all;
                        }
                    } else {
                        return context.fail(.invalid_env, {});
                    }
                },
                .nulled => this.env_behavior = .disable,
                .invalid => return context.fail(.invalid_env, {}),
            };

            if (generated.packages) |*field| switch (field.*) {
                .value => |value| this.packages = switch (value) {
                    .bundle => .bundle,
                    .external => .external,
                },
                .ignored => {},
            };

            if (generated.jsx) |*field| switch (field.*) {
                .options => |*jsx| {
                    if (jsx.runtime) |runtime| switch (runtime) {
                        .classic, .react => this.jsx.runtime = .classic,
                        .automatic, .react_jsx, .react_jsxdev => {
                            this.jsx.runtime = .automatic;
                            this.jsx.development = true;
                        },
                    };
                    if (jsx.factory) |*factory_field| {
                        if (factory_field.*) |*text| {
                            this.jsx.factory = try text.toOwnedSlice(allocator);
                        }
                    }
                    if (jsx.fragment) |*fragment_field| {
                        if (fragment_field.*) |*text| {
                            this.jsx.fragment = try text.toOwnedSlice(allocator);
                        }
                    }
                    if (jsx.importSource) |*import_source_field| {
                        if (import_source_field.*) |*text| {
                            this.jsx.import_source = try text.toOwnedSlice(allocator);
                        }
                    }
                    if (jsx.development) |dev| this.jsx.development = dev;
                    if (jsx.sideEffects) |flag| this.jsx.side_effects = flag;
                },
                .invalid => return context.fail(.invalid_jsx, {}),
            };

            if (generated.format) |*field| switch (field.*) {
                .value => |value| {
                    this.format = switch (value) {
                        .esm => .esm,
                        .iife => .iife,
                        .cjs => .cjs,
                        .internal_bake_dev => .internal_bake_dev,
                    };
                    if (this.bytecode and this.format != .cjs and this.format != .esm) {
                        return context.fail(.invalid_bytecode_format, {});
                    }
                },
                .ignored => {},
            };

            if (generated.splitting) |flag| this.code_splitting = flag;

            if (generated.minify) |*field| switch (field.*) {
                .all => |all| {
                    this.minify.whitespace = all;
                    this.minify.syntax = all;
                    this.minify.identifiers = all;
                },
                .options => |*minify| {
                    if (minify.whitespace) |flag| this.minify.whitespace = flag;
                    if (minify.syntax) |flag| this.minify.syntax = flag;
                    if (minify.identifiers) |flag| this.minify.identifiers = flag;
                    if (minify.keepNames) |flag| this.minify.keep_names = flag;
                },
            };

            entrypoints: {
                if (generated.entrypoints) |*field| switch (field.*) {
                    .list => |*list| {
                        try appendStringSet(list, &this.entry_points);
                        if (this.entry_points.count() == 0) return context.fail(.missing_entrypoints, {});
                        break :entrypoints;
                    },
                    .ignored => {},
                };
                return context.fail(.missing_entrypoints, {});
            }

            if (generated.files) |*files| {
                this.files = try FileMap.fromSchema(files);
            }

            if (generated.emitDCEAnnotations) |flag| this.emit_dce_annotations = flag;
            if (generated.ignoreDCEAnnotations) |flag| this.ignore_dce_annotations = flag;

            if (generated.conditions) |*field| switch (field.*) {
                .text => |*text| {
                    const utf8 = try text.toUTF8(bun.default_allocator);
                    defer utf8.deinit();
                    try this.conditions.insert(utf8.slice());
                },
                .list => |*list| try appendStringSet(list, &this.conditions),
                .nulled => {},
                .invalid => return context.fail(.invalid_conditions, {}),
            };

            root: {
                var explicit_root = false;
                const path: bun.String.Slice = brk: {
                    if (generated.root) |*field| {
                        if (field.*) |*text| {
                            explicit_root = true;
                            break :brk try text.toUTF8(bun.default_allocator);
                        }
                    }

                    const entry_points = this.entry_points.keys();

                    if (entry_points.len == 1) {
                        break :brk bun.String.Slice.fromUTF8NeverFree(std.fs.path.dirname(entry_points[0]) orelse ".");
                    }

                    break :brk bun.String.Slice.fromUTF8NeverFree(resolve_path.commonDirectory(entry_points) orelse ".");
                };
                defer path.deinit();

                var dir = bun.openDirAbsoluteNotForDeletingOrRenaming(path.slice()) catch |err| {
                    if (!explicit_root and err == error.ENOENT) {
                        // Virtual entrypoints need not have a physical parent directory.
                        try this.rootdir.appendSliceExact(bun.fs.FileSystem.instance.top_level_dir);
                        break :root;
                    }
                    return globalThis.throwPretty("{s}: failed to open root directory: {s}", .{ @errorName(err), path.slice() });
                };
                defer dir.close(globalThis.bunVM().io);

                var rootdir_buf: bun.PathBuffer = undefined;
                const rootdir = bun.getFdPath(bun.FD.fromStdDir(dir), &rootdir_buf) catch |err| {
                    return globalThis.throwPretty("{s}: failed to get full root directory path: {s}", .{ @errorName(err), path.slice() });
                };
                try this.rootdir.appendSliceExact(rootdir);
            }

            if (generated.external) |*field| switch (field.*) {
                .list => |*list| try appendStringSet(list, &this.external),
                .ignored => {},
            };

            if (generated.allowUnresolved) |*field| switch (field.*) {
                .list => |*list| {
                    this.allow_unresolved = bun.StringSet.init(bun.default_allocator);
                    try appendStringSet(list, &this.allow_unresolved.?);
                },
                .nulled => {},
                .invalid => return context.fail(.invalid_allow_unresolved, {}),
            };

            if (generated.drop) |*field| switch (field.*) {
                .list => |*list| try appendStringSet(list, &this.drop),
                .ignored => {},
            };

            if (generated.features) |*field| switch (field.*) {
                .list => |*list| this.features = try featureSet(list),
                .ignored => {},
            };

            if (generated.optimizeImports) |*field| switch (field.*) {
                .list => |*list| try appendStringSet(list, &this.optimize_imports),
                .ignored => {},
            };

            if (generated.publicPath) |*field| {
                if (field.*) |*text| try appendText(text, &this.public_path);
            }

            if (generated.naming) |*field| switch (field.*) {
                .text => |*text| {
                    const utf8 = try text.toUTF8(bun.default_allocator);
                    defer utf8.deinit();
                    if (utf8.slice().len > 0) {
                        try appendPrefixedName(&this.names.owned_entry_point, utf8.slice());
                        this.names.entry_point.data = this.names.owned_entry_point.list.items;
                    }
                },
                .parts => |*parts| {
                    if (parts.entry) |*entry_field| {
                        if (entry_field.*) |*text| {
                            const utf8 = try text.toUTF8(bun.default_allocator);
                            defer utf8.deinit();
                            try appendPrefixedName(&this.names.owned_entry_point, utf8.slice());
                            this.names.entry_point.data = this.names.owned_entry_point.list.items;
                        }
                    }
                    if (parts.chunk) |*chunk_field| {
                        if (chunk_field.*) |*text| {
                            const utf8 = try text.toUTF8(bun.default_allocator);
                            defer utf8.deinit();
                            try appendPrefixedName(&this.names.owned_chunk, utf8.slice());
                            this.names.chunk.data = this.names.owned_chunk.list.items;
                        }
                    }
                    if (parts.asset) |*asset_field| {
                        if (asset_field.*) |*text| {
                            const utf8 = try text.toUTF8(bun.default_allocator);
                            defer utf8.deinit();
                            try appendPrefixedName(&this.names.owned_asset, utf8.slice());
                            this.names.asset.data = this.names.owned_asset.list.items;
                        }
                    }
                },
                .invalid => return context.fail(.invalid_naming, {}),
            };

            if (generated.define) |*define| {
                for (0..define.len()) |index| {
                    const entry = define.at(index).?;
                    const name = try entry.key.toUTF8(bun.default_allocator);
                    defer name.deinit();
                    if (name.length() == 0) continue;
                    const value = try entry.value.toUTF8(bun.default_allocator);
                    defer value.deinit();

                    const key = try bun.default_allocator.dupe(u8, name.slice());
                    // .insert clones the value, but not the key
                    try this.define.insert(key, if (value.length() == 0) "\"\"" else value.slice());
                }
            }

            if (generated.loader) |*loaders| {
                var loader_names: std.ArrayListUnmanaged(string) = .empty;
                errdefer {
                    for (loader_names.items) |name| bun.default_allocator.free(name);
                    loader_names.deinit(allocator);
                }
                var loader_values: std.ArrayListUnmanaged(api.Loader) = .empty;
                errdefer loader_values.deinit(allocator);

                try loader_names.ensureTotalCapacityPrecise(allocator, loaders.len());
                try loader_values.ensureTotalCapacityPrecise(allocator, loaders.len());

                for (0..loaders.len()) |index| {
                    const entry = loaders.at(index).?;
                    const name = try entry.key.toUTF8(bun.default_allocator);
                    defer name.deinit();
                    if (name.length() == 0) continue;
                    if (name.slice()[0] != '.' or name.length() < 2) {
                        return context.fail(.invalid_loader_extension, {});
                    }

                    loader_values.appendAssumeCapacity(switch (entry.value) {
                        .js => .js,
                        .ts => .ts,
                        .jsx => .jsx,
                        .tsx => .tsx,
                        .css => .css,
                        .file => .file,
                        .json => .json,
                        .toml => .toml,
                        .yaml => .yaml,
                        .json5 => .json5,
                        .wasm => .wasm,
                        .napi => .napi,
                        .dataurl => .dataurl,
                        .base64 => .base64,
                        .text => .text,
                        .sqlite => .sqlite,
                        .html => .html,
                        .md => .md,
                    });
                    loader_names.appendAssumeCapacity(try bun.default_allocator.dupe(u8, name.slice()));
                }

                this.loaders = api.LoaderMap{
                    .extensions = loader_names.items,
                    .loaders = loader_values.items,
                };
            }

            if (generated.throw_on_error) |*field| switch (field.*) {
                .flag => |flag| this.throw_on_error = flag,
                .invalid => return globalThis.throwInvalidArgumentType("build", "throw", "boolean"),
            };

            if (generated.metafile) |*field| switch (field.*) {
                .flag => |flag| this.metafile = flag,
                .text => |*text| {
                    // metafile: "path/to/meta.json" - shorthand for { json: "..." }
                    this.metafile = true;
                    try appendText(text, &this.metafile_json_path);
                },
                .parts => |*parts| {
                    this.metafile = true;
                    if (parts.json) |*json_field| {
                        if (json_field.*) |*text| try appendText(text, &this.metafile_json_path);
                    }
                    if (parts.markdown) |*markdown_field| {
                        if (markdown_field.*) |*text| try appendText(text, &this.metafile_markdown_path);
                    }
                },
                .nulled => {},
                .invalid => return context.fail(.invalid_metafile, {}),
            };

            if (try CompileOptions.fromSchema(
                globalThis,
                context,
                if (generated.compile) |*compile_field| compile_field else null,
                if (this.compile) |*existing| existing.compile_target else null,
                bun.default_allocator,
            )) |resolved_compile| {
                if (this.compile) |*existing| existing.deinit();
                this.compile = resolved_compile;
            }

            if (this.compile) |*compile_options| {
                // When compile + target=browser + all HTML entrypoints, produce standalone HTML.
                // Otherwise, default to bun executable compile.
                const has_all_html_entrypoints = brk: {
                    if (this.entry_points.count() == 0) break :brk false;
                    for (this.entry_points.keys()) |ep| {
                        if (!strings.hasSuffixComptime(ep, ".html")) break :brk false;
                    }
                    break :brk true;
                };
                const is_standalone_html = this.target == .browser and has_all_html_entrypoints;
                if (!is_standalone_html) {
                    this.target = .bun;

                    const define_keys = compile_options.compile_target.defineKeys();
                    const define_values = compile_options.compile_target.defineValues();
                    for (define_keys, define_values) |key, value| {
                        try this.define.insert(key, value);
                    }

                    const base_public_path = bun.StandaloneModuleGraph.targetBasePublicPath(this.compile.?.compile_target.os, "root/");
                    try this.public_path.append(base_public_path);

                    // When using --compile, only `external` sourcemaps work, as we do not
                    // look at the source map comment. Override any other sourcemap type.
                    if (this.source_map != .none) {
                        this.source_map = .external;
                    }

                    if (compile_options.outfile.isEmpty()) {
                        const entry_point = this.entry_points.keys()[0];
                        var outfile = std.fs.path.basename(entry_point);
                        const ext = std.fs.path.extension(outfile);
                        if (ext.len > 0) {
                            outfile = outfile[0 .. outfile.len - ext.len];
                        }

                        if (strings.eqlComptime(outfile, "index")) {
                            outfile = std.fs.path.basename(std.fs.path.dirname(entry_point) orelse "index");
                        }

                        if (strings.eqlComptime(outfile, "bun")) {
                            outfile = std.fs.path.basename(std.fs.path.dirname(entry_point) orelse "bun");
                        }

                        // If argv[0] is "bun" or "bunx", we don't check if the binary is standalone
                        if (strings.eqlComptime(outfile, "bun") or strings.eqlComptime(outfile, "bunx")) {
                            return context.fail(.compile_outfile_named_bun, {});
                        }

                        try compile_options.outfile.appendSliceExact(outfile);
                    }
                }
            }

            // ESM bytecode requires compile because module_info (import/export metadata)
            // is only available in compiled binaries. Without it, JSC must parse the file
            // twice (once for module analysis, once for bytecode), which is a deopt.
            if (this.bytecode and this.format == .esm and this.compile == null) {
                return context.fail(.bytecode_requires_compile, {});
            }

            // Validate standalone HTML mode: compile + browser target + all HTML entrypoints
            if (this.compile != null and this.target == .browser) {
                const has_all_html = brk: {
                    if (this.entry_points.count() == 0) break :brk false;
                    for (this.entry_points.keys()) |ep| {
                        if (!strings.hasSuffixComptime(ep, ".html")) break :brk false;
                    }
                    break :brk true;
                };
                if (has_all_html and this.code_splitting) {
                    return context.fail(.html_splitting_browser_compile, {});
                }
            }

            return this;
        }

        pub const Names = struct {
            owned_entry_point: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            entry_point: options.PathTemplate = options.PathTemplate.file,
            owned_chunk: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            chunk: options.PathTemplate = options.PathTemplate.chunk,

            owned_asset: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            asset: options.PathTemplate = options.PathTemplate.asset,

            pub fn deinit(self: *Names) void {
                self.owned_entry_point.deinit();
                self.owned_chunk.deinit();
                self.owned_asset.deinit();
            }
        };

        pub const Minify = struct {
            whitespace: bool = false,
            identifiers: bool = false,
            syntax: bool = false,
            keep_names: bool = false,
        };

        pub const Serve = struct {
            handler_path: OwnedString = OwnedString.initEmpty(bun.default_allocator),
            prefix: OwnedString = OwnedString.initEmpty(bun.default_allocator),

            pub fn deinit(self: *Serve, allocator: std.mem.Allocator) void {
                _ = allocator;
                self.handler_path.deinit();
                self.prefix.deinit();
            }
        };

        pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
            self.entry_points.deinit();
            self.external.deinit();
            if (self.allow_unresolved) |*a| a.deinit();
            self.define.deinit();
            self.dir.deinit();
            self.serve.deinit(allocator);
            if (self.loaders) |loaders| {
                for (loaders.extensions) |ext| {
                    bun.default_allocator.free(ext);
                }
                bun.default_allocator.free(loaders.loaders);
                bun.default_allocator.free(loaders.extensions);
            }
            // Free JSX allocated strings
            if (self.jsx.factory.len > 0) {
                allocator.free(self.jsx.factory);
                self.jsx.factory = "";
            }
            if (self.jsx.fragment.len > 0) {
                allocator.free(self.jsx.fragment);
                self.jsx.fragment = "";
            }
            if (self.jsx.import_source.len > 0) {
                allocator.free(self.jsx.import_source);
                self.jsx.import_source = "";
            }
            self.names.deinit();
            self.outdir.deinit();
            self.rootdir.deinit();
            self.public_path.deinit();
            self.conditions.deinit();
            self.drop.deinit();
            self.features.deinit();
            self.banner.deinit();
            if (self.compile) |*compile| {
                compile.deinit();
            }
            self.env_prefix.deinit();
            self.footer.deinit();
            self.tsconfig_override.deinit();
            self.optimize_imports.deinit();
            self.files.deinit();
            self.metafile_json_path.deinit();
            self.metafile_markdown_path.deinit();
        }
    };

    /// `Bun.build(config)`
    pub fn buildFn(
        context: bun.bindgen.CallContext(BuildFunctionSchema),
        args: bun.bindgen.Args(BuildFunctionSchema),
    ) bun.bindgen.CallError(BuildFunctionSchema)!void {
        const globalThis = context.viewToken().globalObject();
        const config_argument = args.config orelse return context.fail(.missing_config, {});
        const config_source = args.configSource;

        const vm = globalThis.bunVM();

        if (vm.macro_mode) return context.fail(.macro_build, {});

        const head_converted = try config_argument.convert(context);
        const head = switch (head_converted.value) {
            .head => |*head| head,
            .invalid => return context.fail(.missing_config, {}),
        };

        var target: Target = .browser;
        var did_set_target = false;
        var seeded_compile: ?Config.CompileOptions = null;
        var seeded_compile_owned = true;
        defer if (seeded_compile_owned) if (seeded_compile) |*resolved| resolved.deinit();
        if (head.target) |*target_field| {
            if (target_field.*) |*text| {
                const utf8 = try text.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                if (strings.hasPrefixComptime(utf8.slice(), "bun-")) {
                    seeded_compile = .{
                        .compile_target = try jsc.API.BundlerOptionsEngine.compileTargetFromSlice(globalThis, utf8.slice()),
                        .exec_argv = OwnedString.initEmpty(bun.default_allocator),
                        .executable_path = OwnedString.initEmpty(bun.default_allocator),
                        .windows_icon_path = OwnedString.initEmpty(bun.default_allocator),
                        .windows_title = OwnedString.initEmpty(bun.default_allocator),
                        .windows_publisher = OwnedString.initEmpty(bun.default_allocator),
                        .windows_version = OwnedString.initEmpty(bun.default_allocator),
                        .windows_description = OwnedString.initEmpty(bun.default_allocator),
                        .windows_copyright = OwnedString.initEmpty(bun.default_allocator),
                        .outfile = OwnedString.initEmpty(bun.default_allocator),
                    };
                    target = .bun;
                    did_set_target = true;
                } else {
                    target = options.Target.Map.get(utf8.slice()) orelse {
                        const message = try std.fmt.allocPrint(
                            bun.default_allocator,
                            "Expected target to be one of 'browser', 'node', 'bun', 'macro', or 'bun-<target>', got {s}",
                            .{utf8.slice()},
                        );
                        defer bun.default_allocator.free(message);
                        return context.fail(.invalid_target, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
                    };
                    did_set_target = true;
                }
            }
        }

        // Plugins run first because they are allowed to mutate the config object.
        var plugins: ?*Plugin = null;
        errdefer if (plugins) |plugin| plugin.deinit();
        if (head.plugins) |*plugins_field| switch (plugins_field.*) {
            .list => |*list| {
                for (0..list.len()) |i| {
                    const element = list.at(i).?;
                    const plugin_entry = switch (element) {
                        .plugin => |*entry| entry,
                        .invalid => return context.fail(.plugin_not_object, {}),
                    };

                    name: {
                        if (plugin_entry.name) |*name_field| {
                            if (name_field.*) |*name| {
                                if (name.length() == 0) return context.fail(.plugin_empty_name, {});
                                break :name;
                            }
                        }
                        return context.fail(.plugin_missing_name, {});
                    }

                    const setup = setup: {
                        if (plugin_entry.setup) |*setup_field| switch (setup_field.*) {
                            .callback => |*callback| break :setup callback,
                            .invalid => {},
                        };
                        return context.fail(.plugin_missing_setup, {});
                    };

                    const bun_plugins: *Plugin = plugins orelse brk: {
                        plugins = try Plugin.create(
                            context,
                            switch (target) {
                                .bun, .bun_macro => .bun,
                                .node => .node,
                                else => .browser,
                            },
                        );
                        break :brk plugins.?;
                    };

                    const is_last = i == list.len() - 1;
                    try bun_plugins.runSetup(
                        context,
                        setup,
                        config_source,
                        i == 0,
                        is_last,
                        false,
                    );
                }
            },
            .ignored => {},
        };

        // The rest of the configuration converts only after the plugins ran.
        const rest = try args.configRest.convert(context);

        seeded_compile_owned = false;
        var config = try Config.fromSchema(globalThis, context, &rest.value, target, did_set_target, seeded_compile, bun.default_allocator);
        errdefer config.deinit(bun.default_allocator);

        var view = context.completion();
        const build_completion = try JSBundleCompletion.JSBundleCompletionTask.BuildCompletion.take(&view, {});
        try JSBundleCompletion.generateFromJavaScript(
            config,
            plugins,
            globalThis,
            build_completion,
        );
        plugins = null;
    }

    pub const Resolve = bun.bundle_v2.PluginResolve;
    pub const Load = bun.bundle_v2.PluginLoad;

    const ResolveReaction = PluginReaction(Resolve, OnResolveFulfilledSchema);
    const LoadReaction = PluginReaction(Load, OnLoadFulfilledSchema);

    fn PluginReaction(comptime Operation: type, comptime FulfilledSchema: type) type {
        return struct {
            const Self = @This();
            pending: ?*Operation,
            armed: bool = false,
            closed: bool = false,
            settling: bool = false,
            dispatcher: *Plugin.Dispatcher,
            active: Plugin.Dispatcher.Active = undefined,
            ref_count: RefCount = .init(),

            const RefCount = bun.ptr.RefCount(Self, "ref_count", destroy, .{});
            pub const ref = RefCount.ref;
            pub const deref = RefCount.deref;
            const Reaction = bun.bindgen.PromiseReaction(FulfilledSchema.args[1].ArgumentType, Self);

            fn create(operation: *Operation, plugin: *Plugin) !*Self {
                if (operation.bv2.isCancelRequested()) return error.Canceled;
                const reaction = try bun.tryNew(Self, .{ .pending = operation, .dispatcher = plugin.dispatcher });
                plugin.dispatcher.ref();
                reaction.active = .{
                    .context = .init(reaction),
                    .cancellation = operation.bv2.cancellationToken(),
                    .cancel = cancelActive,
                };
                reaction.ref();
                if (!plugin.dispatcher.addActive(&reaction.active)) {
                    operation.bv2.requestCancel();
                    reaction.pending = null;
                    reaction.deref();
                    reaction.deref();
                    return error.Canceled;
                }
                return reaction;
            }

            fn take(this: *Self) ?*Operation {
                const pending = this.pending;
                this.pending = null;
                if (this.dispatcher.removeActive(&this.active)) this.deref();
                return pending;
            }

            fn beginSettlement(this: *Self) bool {
                const operation = this.pending orelse return false;
                bun.assert(!this.settling);
                this.settling = true;
                if (operation.bv2.isCancelRequested()) {
                    this.cancel();
                    return false;
                }
                return true;
            }

            fn failCallback(this: *Self, err: anyerror) void {
                if (this.take()) |operation| operation.failCallback(err);
            }

            fn cancel(this: *Self) void {
                this.closed = true;
                if (this.take()) |operation| {
                    operation.bv2.requestCancel();
                    operation.failCallback(error.Canceled);
                }
            }

            fn cancelActive(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
                const reaction = raw.get(*Self);
                defer reaction.deref();
                reaction.cancel();
            }

            pub fn releasePromiseReactionRef(this: *Self) void {
                if (this.armed) {
                    if (this.take()) |operation| operation.failCallback(error.PluginCallbackAbandoned);
                }
                this.deref();
            }

            fn failException(this: *Self, scope: *bun.bindgen.FocusedEngineScope, err: bun.JSError) void {
                if (err == error.OutOfMemory) {
                    this.failCallback(err);
                    return;
                }
                const exception = scope.takeThrownException(err) catch {
                    this.failCallback(error.Terminated);
                    return;
                };
                if (!this.beginSettlement()) return;
                var description = scope.engine(PluginDescribeExceptionSchema).call(.{ .exception = exception.operand(scope).asEngine() }) catch |description_error| {
                    this.failCallback(description_error);
                    if (description_error == error.JSError) {
                        _ = scope.takeThrownException(description_error) catch return;
                    }
                    return;
                };
                defer description.message.deinit();
                const operation = this.take() orelse return;
                if (Operation == Resolve) {
                    Plugin.recordResolveError(operation, &description.message, description.conversionFailed);
                } else {
                    Plugin.recordLoadError(operation, &description.message, description.conversionFailed);
                }
            }

            fn destroy(this: *Self) void {
                bun.assert(this.pending == null and !this.active.registered);
                this.dispatcher.deref();
                bun.destroy(this);
            }
        };
    }

    fn onResolveFulfilled(
        context: bun.bindgen.CallContext(OnResolveFulfilledSchema),
        args: bun.bindgen.Args(OnResolveFulfilledSchema),
    ) bun.JSError!void {
        const reaction = ResolveReaction.Reaction.take(args.context) orelse return;
        defer reaction.deref();
        if (!reaction.beginSettlement()) return;
        const result = args.result.convert(context) catch |err| {
            reaction.failCallback(err);
            return err;
        };
        const resolve = reaction.take() orelse return;
        if (resolve.bv2.isCancelRequested()) return resolve.failCallback(error.Canceled);
        if (result.value) |value| {
            const path_utf8 = value.path.toUTF8(bun.default_allocator) catch |err| {
                resolve.failCallback(err);
                return err;
            };
            defer path_utf8.deinit();
            const path = bun.default_allocator.dupe(u8, path_utf8.slice()) catch |err| {
                resolve.failCallback(err);
                return err;
            };
            errdefer bun.default_allocator.free(path);

            const namespace_utf8 = value.namespaceString.toUTF8(bun.default_allocator) catch |err| {
                resolve.failCallback(err);
                return err;
            };
            defer namespace_utf8.deinit();
            const namespace = bun.default_allocator.dupe(u8, namespace_utf8.slice()) catch |err| {
                resolve.failCallback(err);
                return err;
            };
            errdefer bun.default_allocator.free(namespace);

            resolve.value = .{
                .success = .{
                    .path = path,
                    .namespace = namespace,
                    .external = value.external,
                },
            };
        } else {
            resolve.value = .no_match;
        }
        resolve.bv2.onResolveAsync(resolve);
    }

    fn onResolveRejected(
        context: bun.bindgen.CallContext(OnResolveRejectedSchema),
        args: bun.bindgen.Args(OnResolveRejectedSchema),
    ) bun.JSError!void {
        const reaction = ResolveReaction.Reaction.take(args.context) orelse return;
        defer reaction.deref();
        if (!reaction.beginSettlement()) return;
        var description = context.engineIn("JSBundlerPlugin", "describeException").call(.{ .exception = args.reason.operand(context).asEngine() }) catch |err| {
            reaction.failCallback(err);
            return err;
        };
        defer description.message.deinit();
        const resolve = reaction.take() orelse return;
        if (resolve.bv2.isCancelRequested()) return resolve.failCallback(error.Canceled);
        Plugin.recordResolveError(resolve, &description.message, description.conversionFailed);
    }

    pub const LoadDeferContext = struct {
        bindgen_state: bun.bindgen.ClassState = .{},
        reaction: bun.bindgen.RefNative(LoadReaction, .vm),

        pub fn destroy(this: *LoadDeferContext) void {
            this.reaction.deinit();
            bun.destroy(this);
        }

        pub fn bindDefer(
            this: *LoadDeferContext,
            context: bun.bindgen.CallContext(OnDeferSchema),
            _: bun.bindgen.Args(OnDeferSchema),
        ) bun.bindgen.CallError(OnDeferSchema)!bun.bindgen.Return(OnDeferSchema) {
            const reaction = this.reaction.get();
            if (reaction.closed or reaction.settling) return context.fail(.inactive, {});
            const load = reaction.pending orelse return context.fail(.inactive, {});
            if (load.bv2.isCancelRequested()) return context.fail(.inactive, {});
            if (load.called_defer) return context.fail(.already_deferred, {});
            const deferred = try bun.default_allocator.create(Load.Deferred);
            var completion = context.completion();
            deferred.* = .{ .load = load, .completion = completion.take() };
            load.onDefer(deferred);
        }
    };

    fn onLoadFulfilled(
        context: bun.bindgen.CallContext(OnLoadFulfilledSchema),
        args: bun.bindgen.Args(OnLoadFulfilledSchema),
    ) bun.JSError!void {
        const reaction = LoadReaction.Reaction.take(args.context) orelse return;
        defer reaction.deref();
        if (!reaction.beginSettlement()) return;
        const result = args.result.convert(context) catch |err| {
            reaction.failCallback(err);
            return err;
        };
        const load = reaction.take() orelse return;
        if (load.bv2.isCancelRequested()) return load.failCallback(error.Canceled);
        if (result.value) |value| {
            const source_code = switch (value.contents) {
                .buffer => |buffer| buffer.dupe(bun.default_allocator) catch |err| {
                    load.failCallback(err);
                    return err;
                },
                .string => |contents| text: {
                    var utf8 = contents.toUTF8(bun.default_allocator) catch |err| {
                        load.failCallback(err);
                        return err;
                    };
                    defer utf8.deinit();
                    break :text utf8.intoOwnedSlice(bun.default_allocator) catch |err| {
                        load.failCallback(err);
                        return err;
                    };
                },
            };
            load.value = .{
                .success = .{
                    .loader = switch (value.loader) {
                        inline else => |loader| @field(options.Loader, @tagName(loader)),
                    },
                    .source_code = source_code,
                },
            };
        } else {
            load.value = .no_match;
        }
        load.bv2.onLoadAsync(load);
    }

    fn onLoadRejected(
        context: bun.bindgen.CallContext(OnLoadRejectedSchema),
        args: bun.bindgen.Args(OnLoadRejectedSchema),
    ) bun.JSError!void {
        const reaction = LoadReaction.Reaction.take(args.context) orelse return;
        defer reaction.deref();
        if (!reaction.beginSettlement()) return;
        var description = context.engineIn("JSBundlerPlugin", "describeException").call(.{ .exception = args.reason.operand(context).asEngine() }) catch |err| {
            reaction.failCallback(err);
            return err;
        };
        defer description.message.deinit();
        const load = reaction.take() orelse return;
        if (load.bv2.isCancelRequested()) return load.failCallback(error.Canceled);
        Plugin.recordLoadError(load, &description.message, description.conversionFailed);
    }

    pub const Plugin = struct {
        pub const State = opaque {};
        const Dispatcher = @import("../../bundler_jsc/PluginDispatcherEngine.zig").Dispatcher(Plugin);

        const RefCount = bun.ptr.RefCount(Plugin, "ref_count", destroy, .{});
        pub const ref = RefCount.ref;
        pub const deinit = RefCount.deref;

        ref_count: RefCount = .init(),
        value: bun.bindgen.OwnedBrandedValue(PluginValueSchema),
        state: *State,
        dispatcher: *Dispatcher,

        pub fn host(this: *Plugin) BundlerPluginHost {
            return .{
                .context = .init(this),
                .vtable = &host_vtable,
            };
        }

        pub fn cancelBuild(this: *Plugin, cancellation: *bun.BundleV2.Cancellation) void {
            this.dispatcher.cancelBuild(cancellation);
        }

        const host_vtable = BundlerPluginHost.VTable{
            .has_any_matches = struct {
                fn call(context: BundlerPluginHost.Context, path: *const Fs.Path, is_on_load: bool) bun.OOM!bool {
                    return context.get(*Plugin).hasAnyMatches(path, is_on_load);
                }
            }.call,
            .has_on_before_parse_plugins = struct {
                fn call(context: BundlerPluginHost.Context) bool {
                    return context.get(*Plugin).hasOnBeforeParsePlugins();
                }
            }.call,
            .call_on_before_parse_plugins = struct {
                fn call(
                    context: BundlerPluginHost.Context,
                    plugin_context: *anyopaque,
                    namespace: []const u8,
                    path: []const u8,
                    arguments: ?*anyopaque,
                    result: ?*anyopaque,
                ) bun.OOM!u32 {
                    return context.get(*Plugin).callOnBeforeParsePlugins(
                        @ptrCast(@alignCast(plugin_context)),
                        namespace,
                        path,
                        if (arguments) |value| @ptrCast(@alignCast(value)) else null,
                        if (result) |value| @ptrCast(@alignCast(value)) else null,
                    );
                }
            }.call,
            .dispatch = struct {
                fn call(context: BundlerPluginHost.Context, request: *BundlerPluginHost.Request) void {
                    context.get(*Plugin).dispatcher.post(request);
                }
            }.call,
            .cancel_build = struct {
                fn call(context: BundlerPluginHost.Context, cancellation: *bun.BundleV2.Cancellation) void {
                    context.get(*Plugin).cancelBuild(cancellation);
                }
            }.call,
        };

        pub fn create(context: anytype, target: PluginTarget) bun.JSError!*Plugin {
            var value = try context.engineIn("JSBundlerPlugin", "create").call(.{
                .target = target,
            });
            defer value.deinit();
            const state = context.engineIn("JSBundlerPlugin", "pluginState").call(.{
                .plugin = value.operand(context),
            });
            const plugin = try bun.default_allocator.create(Plugin);
            errdefer bun.destroy(plugin);
            plugin.* = .{
                .value = try value.toOwned(),
                .state = state,
                .dispatcher = undefined,
            };
            errdefer plugin.value.deinit();
            plugin.dispatcher = try Dispatcher.create(plugin, jsc.VirtualMachine.get());
            return plugin;
        }

        pub fn createInRealm(global: *jsc.JSGlobalObject, target: PluginTarget) bun.JSError!*Plugin {
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const result = try scope.engine(PluginCreateSchema).call(.{ .target = target });
            var value = try result.toOwned();
            errdefer value.deinit();
            const state = scope.engine(PluginStateSchema).call(.{ .plugin = value.operand(&scope) });
            const plugin = try bun.default_allocator.create(Plugin);
            errdefer bun.destroy(plugin);
            plugin.* = .{
                .value = value.take(),
                .state = state,
                .dispatcher = undefined,
            };
            errdefer plugin.value.deinit();
            plugin.dispatcher = try Dispatcher.create(plugin, global.bunVM());
            return plugin;
        }

        pub fn callOnBeforeParsePlugins(this: *Plugin, ctx: *bun.ParseTask.OnBeforeParsePlugin, namespace: []const u8, path: []const u8, on_before_parse_args: ?*bun.ParseTask.OnBeforeParsePlugin.OnBeforeParseArguments, on_before_parse_result: ?*bun.ParseTask.OnBeforeParsePlugin.OnBeforeParseResult) bun.OOM!u32 {
            var namespace_string = try bun.bindgen.ThreadSafeDOMString.fromUTF8(namespace);
            defer namespace_string.deinit();
            var path_string = try bun.bindgen.ThreadSafeDOMString.fromUTF8(path);
            defer path_string.deinit();
            if (!this.dispatcher.lockState()) return 0;
            defer this.dispatcher.unlockState();
            return bun.bindgen.Engine(PluginCallOnBeforeParsePluginsSchema).call(.{
                .state = this.state,
                .bunContext = ctx,
                .namespaceString = namespace_string.operand(),
                .path = path_string.operand(),
                .onBeforeParseArguments = on_before_parse_args,
                .onBeforeParseResult = on_before_parse_result,
            });
        }

        pub fn hasOnBeforeParsePlugins(this: *Plugin) bool {
            if (!this.dispatcher.lockState()) return false;
            defer this.dispatcher.unlockState();
            return bun.bindgen.Engine(PluginHasOnBeforeParsePluginsSchema).call(.{ .state = this.state });
        }

        fn destroy(this: *Plugin) void {
            this.dispatcher.close();
            this.dispatcher.deref();
            bun.bindgen.Engine(PluginTombstoneSchema).call(.{ .state = this.state });
            this.value.deinit();
            bun.destroy(this);
        }

        pub fn runSetup(
            this: *Plugin,
            context: anytype,
            setup: anytype,
            config: anytype,
            is_first: bool,
            is_last: bool,
            is_bake: bool,
        ) bun.JSError!void {
            return JSBundlerPluginEngine.runSetup(
                context,
                &this.value,
                setup,
                config,
                is_first,
                is_last,
                is_bake,
            );
        }

        pub fn hasAnyMatches(
            this: *Plugin,
            path: *const Fs.Path,
            is_onLoad: bool,
        ) bun.OOM!bool {
            const tracer = bun.perf.trace("JSBundler.hasAnyMatches");
            defer tracer.end();

            var namespace_string = if (path.isFile())
                bun.bindgen.ThreadSafeDOMString.empty()
            else
                try bun.bindgen.ThreadSafeDOMString.fromUTF8(path.namespace);
            defer namespace_string.deinit();
            var path_string = try bun.bindgen.ThreadSafeDOMString.fromUTF8(path.text);
            defer path_string.deinit();
            if (!this.dispatcher.lockState()) return false;
            defer this.dispatcher.unlockState();
            return bun.bindgen.Engine(PluginAnyMatchesSchema).call(.{
                .state = this.state,
                .namespaceString = namespace_string.operand(),
                .path = path_string.operand(),
                .isOnLoad = is_onLoad,
            });
        }

        pub fn matchOnLoad(
            this: *Plugin,
            path: []const u8,
            namespace: []const u8,
            context: *Load,
            default_loader: options.Loader,
            is_server_side: bool,
        ) void {
            const tracer = bun.perf.trace("JSBundler.matchOnLoad");
            defer tracer.end();
            debug("JSBundler.matchOnLoad(0x{x}, {s}, {s})", .{ @intFromPtr(this), namespace, path });
            var namespace_string = bun.bindgen.DOMString.fromUTF8(if (namespace.len == 0) "file" else namespace) catch return context.failOutOfMemory();
            defer namespace_string.deinit();
            var path_string = bun.bindgen.DOMString.fromUTF8(path) catch return context.failOutOfMemory();
            defer path_string.deinit();
            const reaction = LoadReaction.create(context, this) catch |err| return context.failCallback(err);
            defer reaction.deref();
            const binding = bun.default_allocator.create(LoadDeferContext) catch {
                if (reaction.take()) |load| load.failOutOfMemory();
                return;
            };
            binding.* = .{ .reaction = .init(reaction) };
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            this.value.initScope(&scope);
            defer scope.deinit();
            var defer_context = LoadDeferClass.adoptNativeRef(binding, scope.viewToken().globalObject()) catch |err|
                return reaction.failException(&scope, err);
            defer defer_context.deinit();
            const promise_result = scope.engine(PluginMatchOnLoadSchema).call(.{
                .plugin = this.value.operand(&scope),
                .namespaceString = namespace_string.operand(),
                .path = path_string.operand(),
                .deferContext = defer_context.operand(&scope),
                .defaultLoader = switch (default_loader) {
                    inline else => |loader| @field(bun.bindgen.EngineArgumentType(PluginMatchOnLoadSchema, "defaultLoader"), @tagName(loader)),
                },
                .isServerSide = is_server_side,
            }) catch |err| return reaction.failException(&scope, err);
            var promise = promise_result.toOwned() catch |err| return reaction.failException(&scope, err);
            defer promise.deinit();
            if (reaction.closed) return reaction.cancel();
            reaction.ref();
            LoadReaction.Reaction.attach(
                &scope,
                promise.operand(&scope).asPromise(),
                reaction,
                OnLoadFulfilledBinding,
                OnLoadRejectedBinding,
            ) catch |err| return reaction.failException(&scope, err);
            if (reaction.closed) return reaction.cancel();
            reaction.armed = true;
        }

        pub fn matchOnResolve(
            this: *Plugin,
            path: []const u8,
            namespace: []const u8,
            importer: []const u8,
            context: *Resolve,
            import_record_kind: bun.ImportKind,
        ) void {
            const tracer = bun.perf.trace("JSBundler.matchOnResolve");
            defer tracer.end();
            var namespace_string = if (strings.eqlComptime(namespace, "file"))
                bun.bindgen.DOMString.empty()
            else
                bun.bindgen.DOMString.fromUTF8(namespace) catch return context.failOutOfMemory();
            defer namespace_string.deinit();
            var path_string = bun.bindgen.DOMString.fromUTF8(path) catch return context.failOutOfMemory();
            defer path_string.deinit();
            var importer_string = bun.bindgen.DOMString.fromUTF8(importer) catch return context.failOutOfMemory();
            defer importer_string.deinit();
            const reaction = ResolveReaction.create(context, this) catch |err| return context.failCallback(err);
            defer reaction.deref();
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            this.value.initScope(&scope);
            defer scope.deinit();
            const promise_result = scope.engine(PluginMatchOnResolveSchema).call(.{
                .plugin = this.value.operand(&scope),
                .namespaceString = namespace_string.operand(),
                .path = path_string.operand(),
                .importer = importer_string.operand(),
                .kind = import_record_kind.toBinding(bun.bindgen.EngineArgumentType(PluginMatchOnResolveSchema, "kind")),
            }) catch |err| return reaction.failException(&scope, err);
            var promise = promise_result.toOwned() catch |err| return reaction.failException(&scope, err);
            defer promise.deinit();
            if (reaction.closed) return reaction.cancel();
            reaction.ref();
            ResolveReaction.Reaction.attach(
                &scope,
                promise.operand(&scope).asPromise(),
                reaction,
                OnResolveFulfilledBinding,
                OnResolveRejectedBinding,
            ) catch |err| return reaction.failException(&scope, err);
            if (reaction.closed) return reaction.cancel();
            reaction.armed = true;
        }

        pub fn loadAndResolvePluginsForServe(
            this: *Plugin,
            plugins: []const bun.bindgen.DOMString,
            bunfig_folder: bun.bindgen.DOMString,
        ) bun.JSError!bun.bindgen.OwnedBrandedValue(PluginLoadAndResolvePluginsForServeSchema.ReturnType) {
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            this.value.initScope(&scope);
            defer scope.deinit();
            const operation = scope.engine(PluginLoadAndResolvePluginsForServeSchema);
            const Name = std.meta.Elem(@FieldType(@TypeOf(operation).Args, "plugins"));
            const names = try bun.default_allocator.alloc(Name, plugins.len);
            defer bun.default_allocator.free(names);
            for (plugins, names) |*plugin, *name| name.* = plugin.operand();
            const result = try operation.call(.{
                .plugin = this.value.operand(&scope),
                .plugins = names,
                .bunfigFolder = bunfig_folder.operand(),
            });
            return result.toOwned();
        }

        pub const LoadAndResolvePluginsForServeResult = bun.bindgen.BrandedValueResult(
            PluginLoadAndResolvePluginsForServeSchema.ReturnType,
        );

        pub const LoadAndResolvePluginsForServePromise = bun.bindgen.StrongPromise(
            LoadAndResolvePluginsForServeResult,
        );

        fn recordLoadError(load: *Load, message: anytype, conversion_failed: bool) void {
            load.value = .{ .err = msgFromPluginException(load.path, message, conversion_failed) catch return load.failOutOfMemory() };
            load.bv2.onLoadAsync(load);
        }

        fn recordResolveError(resolve: *Resolve, message: anytype, conversion_failed: bool) void {
            resolve.value = .{ .err = msgFromPluginException(resolve.import_record.source_file, message, conversion_failed) catch return resolve.failOutOfMemory() };
            resolve.bv2.onResolveAsync(resolve);
        }

        fn msgFromPluginException(file: []const u8, message_value: anytype, conversion_failed: bool) bun.OOM!logger.OwnedMessage {
            var message = try message_value.toUTF8(bun.default_allocator);
            defer message.deinit();
            return logger.OwnedMessage.copy(.{
                .data = .{
                    .text = message.slice(),
                    .location = .{
                        .file = file,
                        .line = if (conversion_failed) -1 else 0,
                        .column = if (conversion_failed) -1 else 0,
                    },
                },
            });
        }
    };
};

const JSBundlerPluginBindings = bun.bindgen.Module("JSBundlerPlugin");
const PluginCreateSchema = JSBundlerPluginBindings.engineShim("create");
const PluginValueSchema = PluginCreateSchema.ReturnType;
const PluginStateSchema = JSBundlerPluginBindings.engineShim("pluginState");
const PluginTarget = @FieldType(bun.bindgen.Args(PluginCreateSchema), "target");
const PluginAnyMatchesSchema = JSBundlerPluginBindings.engineShim("anyMatches");
const PluginMatchOnLoadSchema = JSBundlerPluginBindings.engineShim("matchOnLoad");
const PluginMatchOnResolveSchema = JSBundlerPluginBindings.engineShim("matchOnResolve");
const PluginDescribeExceptionSchema = JSBundlerPluginBindings.engineShim("describeException");
const PluginLoadAndResolvePluginsForServeSchema = JSBundlerPluginBindings.engineShim("loadAndResolvePluginsForServe");
const PluginTombstoneSchema = JSBundlerPluginBindings.engineShim("tombstone");
const PluginCallOnBeforeParsePluginsSchema = JSBundlerPluginBindings.engineShim("callOnBeforeParsePlugins");
const PluginHasOnBeforeParsePluginsSchema = JSBundlerPluginBindings.engineShim("hasOnBeforeParsePlugins");
const OnResolveFulfilledSchema = JSBundlerPluginBindings.function("onResolveFulfilled");
const OnResolveRejectedSchema = JSBundlerPluginBindings.function("onResolveRejected");
const OnLoadFulfilledSchema = JSBundlerPluginBindings.function("onLoadFulfilled");
const OnLoadRejectedSchema = JSBundlerPluginBindings.function("onLoadRejected");
const LoadDeferClassSchema = JSBundlerPluginBindings.class("BundlerLoadDefer");
const LoadDeferClass = bun.bindgen.Class(LoadDeferClassSchema, JSBundler.LoadDeferContext);
const OnDeferSchema = LoadDeferClassSchema.member("defer");
const OnResolveFulfilledBinding = bun.bindgen.Fn(OnResolveFulfilledSchema, JSBundler.onResolveFulfilled);
const OnResolveRejectedBinding = bun.bindgen.Fn(OnResolveRejectedSchema, JSBundler.onResolveRejected);
const OnLoadFulfilledBinding = bun.bindgen.Fn(OnLoadFulfilledSchema, JSBundler.onLoadFulfilled);
const OnLoadRejectedBinding = bun.bindgen.Fn(OnLoadRejectedSchema, JSBundler.onLoadRejected);

comptime {
    _ = OnResolveFulfilledBinding;
    _ = OnResolveRejectedBinding;
    _ = OnLoadFulfilledBinding;
    _ = OnLoadRejectedBinding;
    _ = LoadDeferClass;
}

pub const BuildArtifact = struct {
    pub const Binding = BuildArtifactClass;
    pub const Handle = BuildArtifactClass.Handle;
    pub const Ref = bun.bindgen.ClassRef(BuildArtifactSchema);

    bindgen_state: bun.bindgen.ClassState = .{},

    blob: jsc.WebCore.Blob,
    loader: options.Loader = .file,
    path: bun.bindgen.OwnedBytes = .empty(),
    hash: u64 = std.math.maxInt(u64),
    output_kind: OutputKind,

    pub const OutputKind = @import("../../bundler/OutputKind.zig").OutputKind;

    pub fn deinit(this: *BuildArtifact) void {
        this.blob.deinit();
        this.path.deinit();
    }

    pub fn destroy(this: *BuildArtifact) void {
        this.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(_: *const BuildArtifact, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(BuildArtifact);
    }

    pub fn inspectCustom(_: *BuildArtifact, context: bun.bindgen.CallContext(BuildArtifactInspectSchema), args: bun.bindgen.Args(BuildArtifactInspectSchema)) bun.JSError!bun.bindgen.DOMString {
        return jsc.ConsoleObject.formatClassRefForBinding(context, args);
    }

    pub fn adoptResult(this: *BuildArtifact, context: anytype) bun.JSError!Ref {
        return BuildArtifactClass.adoptResult(this, context);
    }

    pub fn getBlobValue(
        this: *BuildArtifact,
        context: bun.bindgen.CallContext(BuildArtifactBlobValueSchema),
        _: bun.bindgen.Args(BuildArtifactBlobValueSchema),
    ) bun.JSError!bun.bindgen.Return(BuildArtifactBlobValueSchema) {
        var blob = try this.blob.dupe();
        defer blob.deinit();
        return (try jsc.WebCore.Blob.new(&blob)).toBindingRef(context);
    }

    pub fn getSlice(
        this: *BuildArtifact,
        context: bun.bindgen.CallContext(BuildArtifactSliceSchema),
        args: bun.bindgen.Args(BuildArtifactSliceSchema),
    ) bun.JSError!bun.bindgen.Return(BuildArtifactSliceSchema) {
        const blob = try this.blob.getSliceWithArguments(args.start, args.end, args.contentType);
        return blob.toBindingRef(context);
    }

    pub fn getStreamNative(
        this: *BuildArtifact,
        context: bun.bindgen.CallContext(BuildArtifactStreamNativeSchema),
        args: bun.bindgen.Args(BuildArtifactStreamNativeSchema),
    ) bun.JSError!bun.bindgen.Return(BuildArtifactStreamNativeSchema) {
        const globalThis = context.viewToken().globalObject();
        var stream = try this.blob.getStreamWithChunkSize(
            globalThis,
            args.chunkSize,
        );
        defer stream.deinit();
        return .{
            .stream = stream.toResult(context),
            .cache = this.blob.shouldCacheStream(),
        };
    }

    pub fn getPath(
        this: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactPathSchema),
        _: bun.bindgen.Args(BuildArtifactPathSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        return bun.bindgen.DOMString.fromUTF8(this.path.slice());
    }

    pub fn getLoader(
        this: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactLoaderSchema),
        _: bun.bindgen.Args(BuildArtifactLoaderSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        return bun.bindgen.DOMString.fromUTF8(@tagName(this.loader));
    }

    pub fn getHash(
        this: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactHashSchema),
        _: bun.bindgen.Args(BuildArtifactHashSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        var buf: [512]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "{f}", .{bun.fmt.truncatedHash32(this.hash)}) catch @panic("Unexpected");
        return bun.bindgen.DOMString.fromUTF8(out);
    }

    pub fn getSize(
        this: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactSizeSchema),
        _: bun.bindgen.Args(BuildArtifactSizeSchema),
    ) bun.JSError!f64 {
        return this.blob.getSize();
    }

    pub fn getMimeType(
        this: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactMimeTypeSchema),
        _: bun.bindgen.Args(BuildArtifactMimeTypeSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        return this.blob.getType();
    }

    pub fn getOutputKind(
        this: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactOutputKindSchema),
        _: bun.bindgen.Args(BuildArtifactOutputKindSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        return bun.bindgen.DOMString.fromUTF8(@tagName(this.output_kind));
    }

    pub fn getSourceMap(
        _: *BuildArtifact,
        _: bun.bindgen.CallContext(BuildArtifactSourceMapSchema),
        _: bun.bindgen.Args(BuildArtifactSourceMapSchema),
    ) bun.JSError!bun.bindgen.Return(BuildArtifactSourceMapSchema) {
        return null;
    }

    pub fn linkSourceMap(owner: *Ref, source_map: *const Ref) void {
        BuildArtifactSourceMapSlot.setOnOwned(owner, source_map);
    }

    pub fn writeFormat(this: *BuildArtifact, wrapper: *const Ref, globalThis: *jsc.JSGlobalObject, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
        const Writer = @TypeOf(writer);

        try writer.writeAll(comptime Output.prettyFmt("<r>BuildArtifact ", enable_ansi_colors));

        try writer.print(comptime Output.prettyFmt("(<blue>{s}<r>) {{\n", enable_ansi_colors), .{@tagName(this.output_kind)});

        {
            formatter.indent += 1;

            defer formatter.indent -= 1;
            try formatter.writeIndent(Writer, writer);
            try writer.print(
                comptime Output.prettyFmt(
                    "<r>path<r>: <green>\"{s}\"<r>",
                    enable_ansi_colors,
                ),
                .{this.path.slice()},
            );
            try formatter.printComma(Writer, writer, enable_ansi_colors);
            try writer.writeAll("\n");

            try formatter.writeIndent(Writer, writer);
            try writer.print(
                comptime Output.prettyFmt(
                    "<r>loader<r>: <green>\"{s}\"<r>",
                    enable_ansi_colors,
                ),
                .{@tagName(this.loader)},
            );

            try formatter.printComma(Writer, writer, enable_ansi_colors);
            try writer.writeAll("\n");

            try formatter.writeIndent(Writer, writer);

            try writer.print(
                comptime Output.prettyFmt(
                    "<r>kind<r>: <green>\"{s}\"<r>",
                    enable_ansi_colors,
                ),
                .{@tagName(this.output_kind)},
            );

            if (this.hash != 0) {
                try formatter.printComma(Writer, writer, enable_ansi_colors);
                try writer.writeAll("\n");

                try formatter.writeIndent(Writer, writer);
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r>hash<r>: <green>\"{f}\"<r>",
                        enable_ansi_colors,
                    ),
                    .{bun.fmt.truncatedHash32(this.hash)},
                );
            }

            try formatter.printComma(Writer, writer, enable_ansi_colors);
            try writer.writeAll("\n");

            try formatter.writeIndent(Writer, writer);
            formatter.resetLine();
            try this.blob.writeFormat(Formatter, formatter, writer, enable_ansi_colors);

            if (this.output_kind != .sourcemap) {
                try formatter.printComma(Writer, writer, enable_ansi_colors);
                try writer.writeAll("\n");
                try formatter.writeIndent(Writer, writer);
                try writer.writeAll(
                    comptime Output.prettyFmt(
                        "<r>sourcemap<r>: ",
                        enable_ansi_colors,
                    ),
                );

                if (try BuildArtifactSourceMapSlot.getOwned(wrapper)) |sourcemap_ref| {
                    var sourcemap = sourcemap_ref;
                    defer sourcemap.deinit();
                    try sourcemap.get(BuildArtifact).writeFormat(&sourcemap, globalThis, Formatter, formatter, writer, enable_ansi_colors);
                } else {
                    try writer.writeAll(
                        comptime Output.prettyFmt(
                            "<yellow>null<r>",
                            enable_ansi_colors,
                        ),
                    );
                }
            }
        }
        try writer.writeAll("\n");
        try formatter.writeIndent(Writer, writer);
        try writer.writeAll("}");
        formatter.resetLine();
    }
};

const BuildArtifactBindingModule = bun.bindgen.Module("BuildArtifact");
const BunObjectBindingModule = bun.bindgen.Module("BunObject");
const BuildFunctionSchema = BunObjectBindingModule.function("buildNative");
const BuildFunctionBinding = bun.bindgen.Fn(BuildFunctionSchema, JSBundler.buildFn);
const BuildArtifactSchema = BuildArtifactBindingModule.class("BuildArtifact");
const BuildArtifactClass = bun.bindgen.Class(BuildArtifactSchema, BuildArtifact);
const BuildArtifactInspectSchema = BuildArtifactSchema.member("inspectCustom");
const BuildArtifactBlobValueSchema = BuildArtifactSchema.member("blobValue");
const BuildArtifactHashSchema = BuildArtifactSchema.member("hash");
const BuildArtifactOutputKindSchema = BuildArtifactSchema.member("kind");
const BuildArtifactLoaderSchema = BuildArtifactSchema.member("loader");
const BuildArtifactPathSchema = BuildArtifactSchema.member("path");
const BuildArtifactSizeSchema = BuildArtifactSchema.member("size");
const BuildArtifactSliceSchema = BuildArtifactSchema.member("slice");
const BuildArtifactSourceMapSchema = BuildArtifactSchema.member("sourcemap");
const BuildArtifactStreamNativeSchema = BuildArtifactSchema.member("streamNative");
const BuildArtifactMimeTypeSchema = BuildArtifactSchema.member("type");
const BuildArtifactSourceMapSlot = BuildArtifactClass.CachedClassRefSlot("sourcemap");

comptime {
    _ = BuildFunctionBinding;
    _ = BuildArtifactClass;
}

const string = []const u8;

const CompileTarget = @import("../../options_types/CompileTarget.zig");
const BundlerPluginHost = @import("../../bundler/PluginHost.zig");
const CoreFileMap = @import("../../bundler/FileMap.zig");
const Fs = @import("../../resolver/fs.zig");
const _resolver = @import("../../resolver/resolver.zig");
const resolve_path = @import("../../paths/resolve_path.zig");
const std = @import("std");

const options = @import("../../bundler/options.zig");
const Loader = options.Loader;
const Target = options.Target;

const bun = @import("bun");
const JSError = bun.JSError;
const Output = bun.Output;
const String = bun.String;
const Transpiler = bun.transpiler;
const WebCore = bun.webcore;
const logger = bun.logger;
const strings = bun.strings;
const BundleV2 = bun.bundle_v2.BundleV2;
const Index = bun.ast.Index;
const api = bun.schema.api;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const Blob = jsc.WebCore.Blob;
const JSBundlerPluginEngine = @import("./JSBundlerPluginEngine.zig");
const JSBundleCompletion = @import("../../bundler_jsc/JSBundleCompletionTaskEngine.zig");
