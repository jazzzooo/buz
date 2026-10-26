pub fn AstMaybe(
    comptime parser_feature__typescript: bool,
    comptime parser_feature__jsx: JSXTransformType,
    comptime parser_feature__scan_only: bool,
) type {
    return struct {
        const P = js_parser.NewParser_(parser_feature__typescript, parser_feature__jsx, parser_feature__scan_only);

        pub fn maybeRelocateVarsToTopLevel(p: *P, decls: []const G.Decl, mode: RelocateVars.Mode) RelocateVars {
            // Only do this when the scope is not already top-level and when we're not inside a function.
            if (p.current_scope == p.module_scope) {
                return .{ .ok = false };
            }

            var scope = p.current_scope;
            while (!scope.kindStopsHoisting()) {
                if (comptime Environment.allow_assert) assert(scope.parent != null);
                scope = scope.parent.?;
            }

            if (scope != p.module_scope) {
                return .{ .ok = false };
            }

            var value: Expr = Expr{ .loc = logger.Loc.Empty, .data = Expr.Data{ .e_missing = E.Missing{} } };

            for (decls) |decl| {
                const binding = Binding.toExpr(
                    &decl.binding,
                    p.to_expr_wrapper_hoisted,
                );
                if (decl.value) |decl_value| {
                    value = value.joinWithComma(Expr.assign(binding, decl_value), p.allocator);
                } else if (mode == .for_in_or_for_of) {
                    value = value.joinWithComma(binding, p.allocator);
                }
            }

            if (value.data == .e_missing) {
                return .{ .ok = true };
            }

            return .{ .stmt = p.s(S.SExpr{ .value = value }, value.loc), .ok = true };
        }

        // EDot nodes represent a property access. This function may return an
        // expression to replace the property access with. It assumes that the
        // target of the EDot expression has already been visited.
        pub fn maybeRewritePropertyAccess(
            p: *P,
            loc: logger.Loc,
            target: js_ast.Expr,
            name: string,
            name_loc: logger.Loc,
            identifier_opts: IdentifierOpts,
        ) anyerror!?Expr {
            sw: switch (target.data) {
                .e_identifier => |id| {
                    // Rewrite property accesses on explicit namespace imports as an identifier.
                    // This lets us replace them easily in the printer to rebind them to
                    // something else without paying the cost of a whole-tree traversal during
                    // module linking just to rewrite these EDot expressions.
                    if (p.options.bundle) {
                        if (p.import_items_for_namespace.getPtr(id.ref)) |import_items| {
                            const ref = (import_items.get(name) orelse brk: {
                                // Generate a new import item symbol in the module scope
                                const new_item = LocRef{
                                    .loc = name_loc,
                                    .ref = try p.newSymbol(.import, name),
                                };
                                try p.module_scope.generated.append(p.allocator, new_item.ref.?);

                                try import_items.put(p.allocator, name, new_item);
                                try p.is_import_item.put(p.allocator, new_item.ref.?, {});

                                var symbol = &p.symbols.items[new_item.ref.?.innerIndex()];

                                // Mark this as generated in case it's missing. We don't want to
                                // generate errors for missing import items that are automatically
                                // generated.
                                symbol.import_item_status = .generated;

                                break :brk new_item;
                            }).ref.?;

                            // Undo the usage count for the namespace itself. This is used later
                            // to detect whether the namespace symbol has ever been "captured"
                            // or whether it has just been used to read properties off of.
                            //
                            // The benefit of doing this is that if both this module and the
                            // imported module end up in the same module group and the namespace
                            // symbol has never been captured, then we don't need to generate
                            // any code for the namespace at all.
                            p.ignoreUsage(id.ref);

                            // Track how many times we've referenced this symbol
                            p.recordUsage(ref);

                            return p.handleIdentifier(
                                name_loc,
                                E.Identifier{ .ref = ref },
                                name,
                                .{
                                    .assign_target = identifier_opts.assign_target,
                                    .is_call_target = identifier_opts.is_call_target,
                                    .is_delete_target = identifier_opts.is_delete_target,

                                    // If this expression is used as the target of a call expression, make
                                    // sure the value of "this" is preserved.
                                    .was_originally_identifier = false,
                                },
                            );
                        }
                    }

                    if (!p.is_control_flow_dead and id.ref.eql(p.module_ref)) {
                        // Rewrite "module.require()" to "require()" for Webpack compatibility.
                        // See https://github.com/webpack/webpack/pull/7750 for more info.
                        // This also makes correctness a little easier.
                        if (identifier_opts.is_call_target and strings.eqlComptime(name, "require")) {
                            p.ignoreUsage(p.module_ref);
                            return p.valueForRequire(name_loc);
                        } else if (!p.commonjs_named_exports_deoptimized and strings.eqlComptime(name, "exports")) {
                            if (identifier_opts.assign_target != .none) {
                                p.commonjs_module_exports_assigned_deoptimized = true;
                            }

                            // Deoptimizations:
                            //      delete module.exports
                            //      module.exports();
                            if (identifier_opts.is_call_target or identifier_opts.is_delete_target or identifier_opts.assign_target != .none) {
                                p.deoptimizeCommonJSNamedExports();
                                return null;
                            }

                            // rewrite `module.exports` to `exports`
                            return .{ .data = .{ .e_special = .module_exports }, .loc = name_loc };
                        } else if (p.options.bundle and strings.eqlComptime(name, "id") and identifier_opts.assign_target == .none) {
                            // inline module.id
                            p.ignoreUsage(p.module_ref);
                            return p.newExpr(E.String.init(p.source.path.pretty), name_loc);
                        } else if (p.options.bundle and strings.eqlComptime(name, "filename") and identifier_opts.assign_target == .none) {
                            // inline module.filename
                            p.ignoreUsage(p.module_ref);
                            return p.newExpr(E.String.init(std.fs.path.basename(p.source.path.text)), name_loc);
                        } else if (p.options.bundle and strings.eqlComptime(name, "path") and identifier_opts.assign_target == .none) {
                            // inline module.path
                            p.ignoreUsage(p.module_ref);
                            return p.newExpr(E.String.init(p.source.path.pretty), name_loc);
                        }
                    }

                    if (p.shouldUnwrapCommonJSToESM()) {
                        if (!p.is_control_flow_dead and id.ref.eql(p.exports_ref)) {
                            if (!p.commonjs_named_exports_deoptimized) {
                                if (identifier_opts.is_delete_target) {
                                    p.deoptimizeCommonJSNamedExports();
                                    return null;
                                }

                                const entry = try ensureCommonJSExport(p, name, name_loc);
                                p.ignoreUsage(id.ref);
                                p.recordUsage(entry.ref);

                                return p.newExpr(
                                    E.CommonJSExportIdentifier{
                                        .ref = entry.ref,
                                        .export_index = entry.index,
                                    },
                                    name_loc,
                                );
                            } else if (p.options.features.commonjs_at_runtime and identifier_opts.assign_target != .none) {
                                p.has_commonjs_export_names = true;
                            }
                        }
                    }

                    // Handle references to namespaces or namespace members
                    if (p.ts_namespace.expr == .e_identifier and
                        id.ref.eql(p.ts_namespace.expr.e_identifier.ref) and
                        identifier_opts.assign_target == .none and
                        !identifier_opts.is_delete_target)
                    {
                        return maybeRewritePropertyAccessForNamespace(p, name, &target, loc, name_loc);
                    }
                },
                .e_string => |str| {
                    if (p.options.features.minify_syntax) {
                        // minify "long-string".length to 11
                        if (strings.eqlComptime(name, "length")) {
                            if (str.javascriptLength()) |len| {
                                return p.newExpr(E.Number{ .value = @floatFromInt(len) }, loc);
                            }
                        }
                    }
                },
                .e_inlined_enum => |ie| {
                    continue :sw ie.value.data;
                },
                .e_object => |obj| {
                    if (comptime FeatureFlags.inline_properties_in_transpiler) {
                        if (p.options.features.minify_syntax) {
                            // Rewrite a property access like this:
                            //   { f: () => {} }.f
                            // To:
                            //   () => {}
                            //
                            // To avoid thinking too much about edgecases, only do this for:
                            //   1) Objects with a single property
                            //   2) Not a method, not a computed property
                            if (obj.properties.len == 1 and
                                !identifier_opts.is_delete_target and
                                identifier_opts.assign_target == .none and !identifier_opts.is_call_target)
                            {
                                const prop: G.Property = obj.properties.ptr[0];
                                if (prop.value != null and
                                    prop.flags.count() == 0 and
                                    prop.key != null and
                                    prop.key.?.data == .e_string and
                                    prop.key.?.data.e_string.eql([]const u8, name) and
                                    !bun.strings.eqlComptime(name, "__proto__"))
                                {
                                    return prop.value.?;
                                }
                            }
                        }
                    }
                },
                .e_import_meta => {
                    if (strings.eqlComptime(name, "main")) {
                        return p.valueForImportMetaMain(false, target.loc);
                    }

                    if (strings.eqlComptime(name, "hot")) {
                        return .{ .data = .{
                            .e_special = if (p.options.features.hot_module_reloading) .hot_enabled else .hot_disabled,
                        }, .loc = loc };
                    }

                    // Inline import.meta properties for Bake
                    if (p.options.framework != null or (p.options.bundle and p.options.output_format == .cjs)) {
                        if (strings.eqlComptime(name, "dir") or strings.eqlComptime(name, "dirname")) {
                            // Inline import.meta.dir
                            return p.newExpr(E.String.init(std.fs.path.dirname(p.source.path.text) orelse "."), name_loc);
                        } else if (strings.eqlComptime(name, "file")) {
                            // Inline import.meta.file (filename only)
                            return p.newExpr(E.String.init(std.fs.path.basename(p.source.path.text)), name_loc);
                        } else if (strings.eqlComptime(name, "path")) {
                            // Inline import.meta.path (full path)
                            return p.newExpr(E.String.init(p.source.path.text), name_loc);
                        } else if (strings.eqlComptime(name, "url")) {
                            // Inline import.meta.url as file:// URL
                            const url = p.import_meta_url orelse @panic("import.meta.url lowering requires JavaScript semantics during parse preparation");
                            return p.newExpr(E.String.init(url), name_loc);
                        }
                    }

                    // Make all property accesses on `import.meta.url` side effect free.
                    return p.newExpr(
                        E.Dot{
                            .target = target,
                            .name = name,
                            .name_loc = name_loc,
                            .can_be_removed_if_unused = true,
                        },
                        target.loc,
                    );
                },
                .e_require_call_target => {
                    if (strings.eqlComptime(name, "main")) {
                        return .{ .loc = loc, .data = .e_require_main };
                    }
                },
                .e_import_identifier => |id| {
                    // Symbol uses due to a property access off of an imported symbol are tracked
                    // specially. This lets us do tree shaking for cross-file TypeScript enums.
                    if (p.options.bundle and !p.is_control_flow_dead) {
                        const use = p.symbol_uses.getPtr(id.ref).?;
                        use.count_estimate -|= 1;
                        // note: this use is not removed as we assume it exists later

                        // Add a special symbol use instead
                        const gop = try p.import_symbol_property_uses.getOrPutValue(
                            p.allocator,
                            id.ref,
                            .{},
                        );
                        const inner_use = try gop.value_ptr.getOrPutValue(
                            p.allocator,
                            name,
                            .{},
                        );
                        inner_use.value_ptr.count_estimate +|= 1;
                    }
                },
                inline .e_dot, .e_index => |data, tag| {
                    if (p.ts_namespace.expr == tag and
                        data == @field(p.ts_namespace.expr, @tagName(tag)) and
                        identifier_opts.assign_target == .none and
                        !identifier_opts.is_delete_target)
                    {
                        return maybeRewritePropertyAccessForNamespace(p, name, &target, loc, name_loc);
                    }
                },
                .e_special => |special| switch (special) {
                    .module_exports => {
                        if (p.shouldUnwrapCommonJSToESM()) {
                            if (!p.is_control_flow_dead) {
                                if (!p.commonjs_named_exports_deoptimized) {
                                    if (identifier_opts.is_delete_target) {
                                        p.deoptimizeCommonJSNamedExports();
                                        return null;
                                    }

                                    const entry = try ensureCommonJSExport(p, name, name_loc);
                                    p.recordUsage(entry.ref);

                                    return p.newExpr(
                                        E.CommonJSExportIdentifier{
                                            .ref = entry.ref,
                                            .export_index = entry.index,
                                            // Record this as from module.exports
                                            .base = .module_dot_exports,
                                        },
                                        name_loc,
                                    );
                                } else if (p.options.features.commonjs_at_runtime and identifier_opts.assign_target != .none) {
                                    p.has_commonjs_export_names = true;
                                }
                            }
                        }
                    },
                    .hot_enabled, .hot_disabled => {
                        const enabled = p.options.features.hot_module_reloading;
                        if (bun.strings.eqlComptime(name, "data")) {
                            return if (enabled)
                                .{ .data = .{ .e_special = .hot_data }, .loc = loc }
                            else
                                Expr.init(E.Object, .{}, loc);
                        }
                        if (bun.strings.eqlComptime(name, "accept")) {
                            if (!enabled) {
                                p.method_call_must_be_replaced_with_undefined = true;
                                return .{ .data = .e_undefined, .loc = loc };
                            }
                            return .{ .data = .{
                                .e_special = .hot_accept,
                            }, .loc = loc };
                        }
                        const lookup_table = comptime bun.ComptimeStringMap(void, [_]struct { [:0]const u8, void }{
                            .{ "decline", {} },
                            .{ "dispose", {} },
                            .{ "prune", {} },
                            .{ "invalidate", {} },
                            .{ "on", {} },
                            .{ "off", {} },
                            .{ "send", {} },
                        });
                        if (lookup_table.has(name)) {
                            if (enabled) {
                                return Expr.init(E.Dot, .{
                                    .target = Expr.initIdentifier(p.hmr_api_ref, target.loc),
                                    .name = name,
                                    .name_loc = name_loc,
                                }, loc);
                            } else {
                                p.method_call_must_be_replaced_with_undefined = true;
                                return .{ .data = .e_undefined, .loc = loc };
                            }
                        } else {
                            // This error is a bit out of place since the HMR
                            // API is validated in the parser instead of at
                            // runtime. When the API is not validated in this
                            // way, the developer may unintentionally read or
                            // write internal fields of HMRModule.
                            try p.log.addErrorFmt(
                                p.source,
                                loc,
                                p.allocator,
                                "import.meta.hot.{s} does not exist",
                                .{name},
                            );
                            return .{ .data = .e_undefined, .loc = loc };
                        }
                    },
                    else => {},
                },
                else => {},
            }

            return null;
        }

        const CommonJSExport = struct {
            ref: Ref,
            index: E.CommonJSExportIdentifier.ExportIndex,
        };

        fn ensureCommonJSExport(p: *P, name: string, loc: logger.Loc) anyerror!CommonJSExport {
            if (p.commonjs_named_exports.getIndex(name)) |index| {
                return .{
                    .ref = p.commonjs_named_exports.values()[index].loc_ref.ref.?,
                    .index = @fromBackingInt(@intCast(index)),
                };
            }
            const index = std.math.cast(u32, p.commonjs_named_exports.count()) orelse return error.OutOfMemory;
            if (index == std.math.maxInt(u32)) return error.OutOfMemory;
            try p.commonjs_named_exports.ensureUnusedCapacity(p.allocator, 1);
            const symbol_name = try std.fmt.allocPrint(p.allocator, "${f}", .{bun.fmt.fmtIdentifier(name)});
            const ref = p.newSymbol(.other, symbol_name) catch |err| {
                p.allocator.free(symbol_name);
                return err;
            };
            try p.module_scope.generated.append(p.allocator, ref);
            p.commonjs_named_exports.putAssumeCapacityNoClobber(name, .{
                .loc_ref = .{ .loc = loc, .ref = ref },
                .needs_decl = true,
            });
            return .{ .ref = ref, .index = @fromBackingInt(index) };
        }

        fn maybeRewritePropertyAccessForNamespace(
            p: *P,
            name: string,
            target: *const Expr,
            loc: logger.Loc,
            name_loc: logger.Loc,
        ) ?Expr {
            if (p.ts_namespace.map.?.get(name)) |value| {
                switch (value.data) {
                    .enum_number => |num| {
                        p.ignoreUsageOfIdentifierInDotChain(target.*);
                        return p.wrapInlinedEnum(
                            .{ .loc = loc, .data = .{ .e_number = .{ .value = num } } },
                            name,
                        );
                    },

                    .enum_string => |str| {
                        p.ignoreUsageOfIdentifierInDotChain(target.*);
                        return p.wrapInlinedEnum(
                            .{ .loc = loc, .data = .{ .e_string = str } },
                            name,
                        );
                    },

                    .namespace => |namespace| {
                        // If this isn't a constant, return a clone of this property access
                        // but with the namespace member data associated with it so that
                        // more property accesses off of this property access are recognized.
                        const expr = p.newExpr(E.Dot{
                            .target = target.*,
                            .name = name,
                            .name_loc = name_loc,
                        }, loc);

                        p.ts_namespace = .{
                            .expr = expr.data,
                            .map = namespace,
                        };

                        return expr;
                    },

                    else => {},
                }
            }

            return null;
        }

        pub fn checkIfDefinedHelper(p: *P, expr: Expr) !Expr {
            return p.newExpr(
                E.Binary{
                    .op = .bin_strict_eq,
                    .left = p.newExpr(
                        E.Unary{
                            .op = .un_typeof,
                            .value = expr,
                            .flags = .{
                                .was_originally_typeof_identifier = expr.data == .e_identifier,
                            },
                        },
                        logger.Loc.Empty,
                    ),
                    .right = p.newExpr(
                        E.String{ .data = "undefined" },
                        logger.Loc.Empty,
                    ),
                },
                logger.Loc.Empty,
            );
        }

        pub fn maybeDefinedHelper(p: *P, identifier_expr: Expr) !Expr {
            return p.newExpr(
                E.If{
                    .test_ = try p.checkIfDefinedHelper(identifier_expr),
                    .yes = p.newExpr(
                        E.Identifier{
                            .ref = (try p.findSymbol(logger.Loc.Empty, "Object")).ref,
                        },
                        logger.Loc.Empty,
                    ),
                    .no = identifier_expr,
                },
                logger.Loc.Empty,
            );
        }

        pub fn maybeCommaSpreadError(p: *P, _comma_after_spread: ?logger.Loc) bun.OOM!void {
            const comma_after_spread = _comma_after_spread orelse return;
            if (comma_after_spread.start == -1) return;

            try p.log.addRangeError(p.source, logger.Range{ .loc = comma_after_spread, .len = 1 }, "Unexpected \",\" after rest pattern");
        }
    };
}

const string = []const u8;

const bun = @import("bun");
const Environment = bun.Environment;
const FeatureFlags = bun.FeatureFlags;
const assert = bun.assert;
const js_lexer = bun.js_lexer;
const logger = bun.logger;
const strings = bun.strings;

const js_ast = bun.ast;
const Binding = js_ast.Binding;
const E = js_ast.E;
const Expr = js_ast.Expr;
const LocRef = js_ast.LocRef;
const S = js_ast.S;
const Stmt = js_ast.Stmt;
const Symbol = js_ast.Symbol;

const G = js_ast.G;

const js_parser = bun.js_parser;
const Ref = js_parser.Ref;
const IdentifierOpts = js_parser.IdentifierOpts;
const JSXTransformType = js_parser.JSXTransformType;
const RelocateVars = js_parser.RelocateVars;
const TypeScript = js_parser.TypeScript;
const options = js_parser.options;

const std = @import("std");
const List = std.ArrayListUnmanaged;
