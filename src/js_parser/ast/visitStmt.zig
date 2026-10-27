pub fn VisitStmt(
    comptime parser_feature__typescript: bool,
    comptime parser_feature__jsx: JSXTransformType,
    comptime parser_feature__scan_only: bool,
) type {
    return struct {
        const P = js_parser.NewParser_(parser_feature__typescript, parser_feature__jsx, parser_feature__scan_only);
        const createDefaultName = P.createDefaultName;
        const is_typescript_enabled = P.is_typescript_enabled;

        pub fn visitAndAppendStmt(p: *P, stmts: *ListManaged(Stmt), stmt: *Stmt) anyerror!void {
            // By default any statement ends the const local prefix
            const was_after_after_const_local_prefix = p.current_scope.is_after_const_local_prefix;
            p.current_scope.is_after_const_local_prefix = true;

            switch (@as(Stmt.Tag, stmt.data)) {
                .s_directive, .s_comment, .s_empty => {
                    p.current_scope.is_after_const_local_prefix = was_after_after_const_local_prefix;
                    try stmts.append(stmt.*);
                },
                .s_type_script => {
                    p.current_scope.is_after_const_local_prefix = was_after_after_const_local_prefix;
                    return;
                },
                .s_debugger => {
                    p.current_scope.is_after_const_local_prefix = was_after_after_const_local_prefix;
                    if (p.define.drop_debugger) {
                        return;
                    }
                    try stmts.append(stmt.*);
                },

                inline .s_enum, .s_local => |tag| return @field(visitors, @tagName(tag))(p, stmts, stmt, @field(stmt.data, @tagName(tag)), was_after_after_const_local_prefix),
                inline else => |tag| return @field(visitors, @tagName(tag))(p, stmts, stmt, @field(stmt.data, @tagName(tag))),

                // Only used by the bundler for lazy export ASTs.
                .s_lazy_export => unreachable,
            }
        }

        const visitors = struct {
            pub fn s_import(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Import) !void {
                try p.recordDeclaredSymbol(data.namespace_ref);

                if (data.default_name) |default_name| {
                    try p.recordDeclaredSymbol(default_name.ref.?);
                }

                if (data.items.len > 0) {
                    for (data.items) |*item| {
                        try p.recordDeclaredSymbol(item.name.ref.?);
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_export_clause(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ExportClause) !void {
                // "export {foo}"
                var end: usize = 0;
                var any_replaced = false;
                if (p.options.features.replace_exports.count() > 0) {
                    for (data.items) |*item| {
                        const name = p.loadNameFromRef(item.name.ref.?);

                        const symbol = try p.findSymbol(item.alias_loc, name);
                        const ref = symbol.ref;

                        if (p.options.features.replace_exports.getPtr(name)) |entry| {
                            if (entry.* != .replace) p.ignoreUsage(symbol.ref);
                            _ = try p.injectReplacementExport(stmts, symbol.ref, stmt.loc, entry);
                            any_replaced = true;
                            continue;
                        }

                        if (p.symbols.items[ref.innerIndex()].kind == .unbound) {
                            // Silently strip exports of non-local symbols in TypeScript, since
                            // those likely correspond to type-only exports. But report exports of
                            // non-local symbols as errors in JavaScript.
                            if (!is_typescript_enabled) {
                                const r = js_lexer.rangeOfIdentifier(p.source, item.name.loc);
                                try p.log.addRangeErrorFmt(p.source, r, p.allocator, "\"{s}\" is not declared in this file", .{name});
                            }
                            continue;
                        }

                        item.name.ref = ref;
                        data.items[end] = item.*;
                        end += 1;
                    }
                } else {
                    for (data.items) |*item| {
                        const name = p.loadNameFromRef(item.name.ref.?);
                        const symbol = try p.findSymbol(item.alias_loc, name);
                        const ref = symbol.ref;

                        if (p.symbols.items[ref.innerIndex()].kind == .unbound) {
                            // Silently strip exports of non-local symbols in TypeScript, since
                            // those likely correspond to type-only exports. But report exports of
                            // non-local symbols as errors in JavaScript.
                            if (!is_typescript_enabled) {
                                const r = js_lexer.rangeOfIdentifier(p.source, item.name.loc);
                                try p.log.addRangeErrorFmt(p.source, r, p.allocator, "\"{s}\" is not declared in this file", .{name});
                                continue;
                            }
                            continue;
                        }

                        item.name.ref = ref;
                        data.items[end] = item.*;
                        end += 1;
                    }
                }

                const remove_for_tree_shaking = any_replaced and end == 0 and data.items.len > 0 and p.options.tree_shaking;
                data.items.len = end;

                if (remove_for_tree_shaking) {
                    return;
                }

                try stmts.append(stmt.*);
            }
            pub fn s_export_from(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ExportFrom) !void {

                // "export {foo} from 'path'"
                const name = p.loadNameFromRef(data.namespace_ref);

                data.namespace_ref = try p.newSymbol(.other, name);
                try p.current_scope.generated.append(p.allocator, data.namespace_ref);
                try p.recordDeclaredSymbol(data.namespace_ref);

                if (p.options.features.replace_exports.count() > 0) {
                    var j: usize = 0;
                    // This is a re-export and the symbols created here are used to reference
                    for (data.items) |item| {
                        const old_ref = item.name.ref.?;

                        if (p.options.features.replace_exports.count() > 0) {
                            if (p.options.features.replace_exports.getPtr(item.alias)) |entry| {
                                _ = try p.injectReplacementExport(stmts, old_ref, logger.Loc.Empty, entry);

                                continue;
                            }
                        }

                        const _name = p.loadNameFromRef(old_ref);

                        const ref = try p.newSymbol(.import, _name);
                        try p.current_scope.generated.append(p.allocator, ref);
                        try p.recordDeclaredSymbol(ref);
                        data.items[j] = item;
                        data.items[j].name.ref = ref;
                        j += 1;
                    }

                    data.items.len = j;

                    if (j == 0 and data.items.len > 0) {
                        return;
                    }
                } else {
                    // This is a re-export and the symbols created here are used to reference
                    for (data.items) |*item| {
                        const _name = p.loadNameFromRef(item.name.ref.?);
                        const ref = try p.newSymbol(.import, _name);
                        try p.current_scope.generated.append(p.allocator, ref);
                        try p.recordDeclaredSymbol(ref);
                        item.name.ref = ref;
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_export_star(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ExportStar) !void {

                // "export * from 'path'"
                const name = p.loadNameFromRef(data.namespace_ref);
                data.namespace_ref = try p.newSymbol(.other, name);
                try p.current_scope.generated.append(p.allocator, data.namespace_ref);
                try p.recordDeclaredSymbol(data.namespace_ref);

                // "export * as ns from 'path'"
                if (data.alias) |alias| {
                    if (p.options.features.replace_exports.count() > 0) {
                        if (p.options.features.replace_exports.getPtr(alias.original_name)) |entry| {
                            _ = try p.injectReplacementExport(stmts, try p.declareSymbol(.other, logger.Loc.Empty, alias.original_name), logger.Loc.Empty, entry);
                            return;
                        }
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_export_default(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ExportDefault) !void {
                try visitExportDefault(p, stmts, stmt, data);
                if (data.default_name.ref) |ref| {
                    try p.recordDeclaredSymbol(ref);
                }
            }

            fn visitExportDefault(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ExportDefault) !void {
                var mark_for_replace: bool = false;

                const orig_dead = p.is_control_flow_dead;
                if (p.options.features.replace_exports.count() > 0) {
                    if (p.options.features.replace_exports.getPtr("default")) |entry| {
                        p.is_control_flow_dead = p.options.features.dead_code_elimination and (entry.* != .replace);
                        mark_for_replace = true;
                    }
                }

                defer {
                    p.is_control_flow_dead = orig_dead;
                }

                switch (data.value) {
                    .expr => |expr| {
                        const was_anonymous_named_expr = expr.isAnonymousNamed();
                        const prev_decorator_class_name = p.decorator_class_name;
                        if (was_anonymous_named_expr and expr.data == .e_class and expr.data.e_class.should_lower_standard_decorators) {
                            p.decorator_class_name = js_ast.ClauseItem.default_alias;
                        }
                        data.value.expr = try p.visitExpr(expr);
                        p.decorator_class_name = prev_decorator_class_name;

                        if (p.is_control_flow_dead) {
                            return;
                        }

                        // Optionally preserve the name

                        data.value.expr = p.maybeKeepExprSymbolName(data.value.expr, js_ast.ClauseItem.default_alias, was_anonymous_named_expr);

                        // Discard type-only export default statements
                        if (is_typescript_enabled) {
                            switch (data.value.expr.data) {
                                .e_identifier => |ident| {
                                    if (!ident.ref.isSourceContentsSlice()) {
                                        const symbol = p.symbols.items[ident.ref.innerIndex()];
                                        if (symbol.kind == .unbound) {
                                            if (p.local_type_names.get(symbol.original_name)) |local_type| {
                                                if (local_type) {
                                                    // the name points to a type
                                                    // don't try to declare this symbol
                                                    data.default_name.ref = null;
                                                    return;
                                                }
                                            }
                                        }
                                    }
                                },
                                else => {},
                            }
                        }

                        if (data.default_name.ref.?.isSourceContentsSlice()) {
                            data.default_name = try createDefaultName(p, data.value.expr.loc);
                        }

                        if (p.options.features.react_fast_refresh and switch (data.value.expr.data) {
                            .e_arrow => true,
                            .e_call => |call| switch (call.target.data) {
                                .e_identifier => |id| id.ref == p.react_refresh.latest_signature_ref,
                                else => false,
                            },
                            else => false,
                        }) {
                            // declare a temporary ref for this
                            const temp_id = p.generateTempRef("default_export");
                            try p.current_scope.generated.append(p.allocator, temp_id);

                            try stmts.append(Stmt.alloc(S.Local, .{
                                .kind = .k_const,
                                .decls = try G.Decl.List.fromSlice(p.allocator, &.{
                                    .{
                                        .binding = Binding.alloc(p.allocator, B.Identifier{ .ref = temp_id }, stmt.loc),
                                        .value = data.value.expr,
                                    },
                                }),
                            }, stmt.loc));

                            data.value = .{ .expr = .initIdentifier(temp_id, stmt.loc) };

                            try p.emitReactRefreshRegister(stmts, "default", temp_id, .default);
                        }

                        if (p.options.features.server_components.wrapsExports()) {
                            data.value.expr = p.wrapValueForServerComponentReference(data.value.expr, "default");
                        }

                        // If there are lowered "using" declarations, change this into a "var"
                        if (p.current_scope.parent == null and p.will_wrap_module_in_try_catch_for_using) {
                            try stmts.ensureUnusedCapacity(2);

                            const decls = try p.allocator.alloc(G.Decl, 1);
                            decls[0] = .{
                                .binding = p.b(B.Identifier{ .ref = data.default_name.ref.? }, data.default_name.loc),
                                .value = data.value.expr,
                            };
                            stmts.appendAssumeCapacity(p.s(S.Local{
                                .decls = G.Decl.List.fromOwnedSlice(decls),
                            }, stmt.loc));
                            const items = try p.allocator.alloc(js_ast.ClauseItem, 1);
                            items[0] = js_ast.ClauseItem{
                                .alias = "default",
                                .alias_loc = data.default_name.loc,
                                .name = data.default_name,
                            };
                            stmts.appendAssumeCapacity(p.s(S.ExportClause{
                                .items = items,
                                .is_single_line = false,
                            }, stmt.loc));
                        }

                        if (mark_for_replace) {
                            const entry = p.options.features.replace_exports.getPtr("default").?;
                            if (entry.* == .replace) {
                                data.value.expr = entry.replace;
                            } else {
                                _ = try p.injectReplacementExport(stmts, Ref.None, logger.Loc.Empty, entry);
                                return;
                            }
                        }
                    },

                    .stmt => |s2| switch (s2.data) {
                        .s_function => |func| {
                            const name = if (func.func.name) |func_loc|
                                p.loadNameFromRef(func_loc.ref.?)
                            else name: {
                                func.func.name = data.default_name;
                                break :name js_ast.ClauseItem.default_alias;
                            };

                            var react_hook_data: ?ReactRefresh.HookContext = null;
                            const prev = p.react_refresh.hook_ctx_storage;
                            defer p.react_refresh.hook_ctx_storage = prev;
                            p.react_refresh.hook_ctx_storage = &react_hook_data;

                            func.func = try p.visitFunc(func.func, func.func.open_parens_loc);

                            if (p.is_control_flow_dead) {
                                return;
                            }

                            if (data.default_name.ref.?.isSourceContentsSlice()) {
                                data.default_name = try createDefaultName(p, stmt.loc);
                            }

                            if (react_hook_data) |*hook| {
                                try stmts.append(p.getReactRefreshHookSignalDecl(hook.signature_cb));

                                data.value = .{
                                    .expr = p.getReactRefreshHookSignalInit(hook, p.newExpr(
                                        E.Function{ .func = func.func },
                                        stmt.loc,
                                    )),
                                };
                            }

                            if (mark_for_replace) {
                                const entry = p.options.features.replace_exports.getPtr("default").?;
                                if (entry.* == .replace) {
                                    data.value = .{ .expr = entry.replace };
                                } else {
                                    _ = try p.injectReplacementExport(stmts, Ref.None, logger.Loc.Empty, entry);
                                    return;
                                }
                            }

                            if (p.options.features.react_fast_refresh and
                                (ReactRefresh.isComponentishName(name) or bun.strings.eqlComptime(name, "default")))
                            {
                                // If server components or react refresh had wrapped the value (convert to .expr)
                                // then a temporary variable must be emitted.
                                //
                                // > export default _s(function App() { ... }, "...")
                                // > $RefreshReg(App, "App.tsx:default")
                                //
                                // > const default_export = _s(function App() { ... }, "...")
                                // > export default default_export;
                                // > $RefreshReg(default_export, "App.tsx:default")
                                const ref = if (data.value == .expr) emit_temp_var: {
                                    const ref_to_use = brk: {
                                        if (func.func.name) |*loc_ref| {
                                            // Input:
                                            //
                                            //  export default function Foo() {}
                                            //
                                            // Output:
                                            //
                                            //  const Foo = _s(function Foo() {})
                                            //  export default Foo;
                                            if (loc_ref.ref) |ref| break :brk ref;
                                        }

                                        const temp_id = p.generateTempRef("default_export");
                                        try p.current_scope.generated.append(p.allocator, temp_id);
                                        break :brk temp_id;
                                    };

                                    try stmts.append(Stmt.alloc(S.Local, .{
                                        .kind = .k_const,
                                        .decls = try G.Decl.List.fromSlice(p.allocator, &.{
                                            .{
                                                .binding = Binding.alloc(p.allocator, B.Identifier{ .ref = ref_to_use }, stmt.loc),
                                                .value = data.value.expr,
                                            },
                                        }),
                                    }, stmt.loc));

                                    data.value = .{ .expr = .initIdentifier(ref_to_use, stmt.loc) };

                                    break :emit_temp_var ref_to_use;
                                } else data.default_name.ref.?;

                                if (p.options.features.server_components.wrapsExports()) {
                                    data.value = .{ .expr = p.wrapValueForServerComponentReference(if (data.value == .expr) data.value.expr else p.newExpr(E.Function{ .func = func.func }, stmt.loc), "default") };
                                }

                                try stmts.append(stmt.*);
                                try p.emitReactRefreshRegister(stmts, name, ref, .default);
                            } else {
                                if (p.options.features.server_components.wrapsExports()) {
                                    data.value = .{ .expr = p.wrapValueForServerComponentReference(p.newExpr(E.Function{ .func = func.func }, stmt.loc), "default") };
                                }

                                try stmts.append(stmt.*);
                            }

                            // if (func.func.name != null and func.func.name.?.ref != null) {
                            //     stmts.append(p.keepStmtSymbolName(func.func.name.?.loc, func.func.name.?.ref.?, name)) catch unreachable;
                            // }
                            return;
                        },
                        .s_class => |class| {
                            _ = try p.visitClass(s2.loc, &class.class, data.default_name.ref.?);

                            if (p.is_control_flow_dead)
                                return;

                            if (mark_for_replace) {
                                const entry = p.options.features.replace_exports.getPtr("default").?;
                                if (entry.* == .replace) {
                                    data.value = .{ .expr = entry.replace };
                                } else {
                                    _ = try p.injectReplacementExport(stmts, Ref.None, logger.Loc.Empty, entry);
                                    return;
                                }
                            }

                            if (data.default_name.ref.?.isSourceContentsSlice()) {
                                data.default_name = try createDefaultName(p, stmt.loc);
                            }

                            if (class.class.class_name == null and class.class.should_lower_standard_decorators) {
                                data.value = .{ .expr = p.lowerStandardDecoratorsExpr(&class.class, s2.loc, js_ast.ClauseItem.default_alias) };
                                if (p.options.features.server_components.wrapsExports()) {
                                    data.value.expr = p.wrapValueForServerComponentReference(data.value.expr, "default");
                                }
                                try stmts.append(stmt.*);
                                return;
                            }

                            // We only inject a name into classes when there is a decorator
                            if (class.class.has_decorators) {
                                if (class.class.class_name == null or
                                    class.class.class_name.?.ref == null)
                                {
                                    class.class.class_name = data.default_name;
                                }
                            }

                            // Lower the class (handles both TS legacy and standard decorators).
                            // Standard decorator lowering may produce prefix statements
                            // (variable declarations) before the class statement.
                            var class_stmts = p.lowerClass(.{ .stmt = s2 });

                            // Find the s_class statement in the returned list
                            var class_stmt_idx: usize = 0;
                            for (class_stmts, 0..) |cs, idx| {
                                if (cs.data == .s_class) {
                                    class_stmt_idx = idx;
                                    break;
                                }
                            }

                            // Emit any prefix statements before the export default
                            try stmts.appendSlice(class_stmts[0..class_stmt_idx]);

                            data.value.stmt = class_stmts[class_stmt_idx];
                            try stmts.append(stmt.*);

                            // Emit any suffix statements after the export default
                            if (class_stmt_idx + 1 < class_stmts.len) {
                                try stmts.appendSlice(class_stmts[class_stmt_idx + 1 ..]);
                            }

                            if (p.options.features.server_components.wrapsExports()) {
                                data.value = .{ .expr = p.wrapValueForServerComponentReference(p.newExpr(class.class, stmt.loc), "default") };
                            }

                            return;
                        },
                        else => {},
                    },
                }

                try stmts.append(stmt.*);
            }
            pub fn s_function(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Function) !void {
                // We mark it as dead, but the value may not actually be dead
                // We just want to be sure to not increment the usage counts for anything in the function
                const mark_as_dead = p.options.features.dead_code_elimination and data.func.flags.contains(.is_export) and
                    p.options.features.replace_exports.count() > 0 and p.isExportToEliminate(data.func.name.?.ref.?);
                const original_is_dead = p.is_control_flow_dead;

                if (mark_as_dead) {
                    p.is_control_flow_dead = true;
                }
                defer {
                    if (mark_as_dead) {
                        p.is_control_flow_dead = original_is_dead;
                    }
                }

                var react_hook_data: ?ReactRefresh.HookContext = null;
                const prev = p.react_refresh.hook_ctx_storage;
                defer p.react_refresh.hook_ctx_storage = prev;
                p.react_refresh.hook_ctx_storage = &react_hook_data;

                data.func = try p.visitFunc(data.func, data.func.open_parens_loc);

                const name_ref = data.func.name.?.ref.?;
                bun.assert(name_ref.tag == .symbol);
                const name_symbol = &p.symbols.items[name_ref.innerIndex()];
                const original_name = name_symbol.original_name;

                // Handle exporting this function from a namespace
                if (data.func.flags.contains(.is_export) and p.enclosing_namespace_arg_ref != null) {
                    data.func.flags.remove(.is_export);

                    const enclosing_namespace_arg_ref = p.enclosing_namespace_arg_ref orelse bun.outOfMemory();
                    try stmts.ensureUnusedCapacity(3);
                    stmts.appendAssumeCapacity(stmt.*);
                    stmts.appendAssumeCapacity(Stmt.assign(
                        p.newExpr(E.Dot{
                            .target = p.newExpr(E.Identifier{ .ref = enclosing_namespace_arg_ref }, stmt.loc),
                            .name = original_name,
                            .name_loc = data.func.name.?.loc,
                        }, stmt.loc),
                        p.newExpr(E.Identifier{ .ref = data.func.name.?.ref.? }, data.func.name.?.loc),
                    ));
                } else if (!mark_as_dead) {
                    if (name_symbol.remove_overwritten_function_declaration) {
                        return;
                    }

                    if (p.options.features.server_components.wrapsExports() and data.func.flags.contains(.is_export)) {
                        // Convert this into `export var <name> = registerClientReference(<func>, ...);`
                        const name = data.func.name.?;
                        // From the inner scope, have code reference the wrapped function.
                        data.func.name = null;
                        try stmts.append(p.s(S.Local{
                            .kind = .k_var,
                            .is_export = true,
                            .decls = try G.Decl.List.fromSlice(p.allocator, &.{.{
                                .binding = p.b(B.Identifier{ .ref = name_ref }, name.loc),
                                .value = p.wrapValueForServerComponentReference(
                                    p.newExpr(E.Function{ .func = data.func }, stmt.loc),
                                    original_name,
                                ),
                            }}),
                        }, stmt.loc));
                    } else {
                        try stmts.append(stmt.*);
                    }
                } else if (mark_as_dead) {
                    if (p.options.features.replace_exports.getPtr(original_name)) |replacement| {
                        _ = try p.injectReplacementExport(stmts, name_ref, data.func.name.?.loc, replacement);
                    }
                }

                if (p.options.features.react_fast_refresh) {
                    if (react_hook_data) |*hook| {
                        try stmts.append(p.getReactRefreshHookSignalDecl(hook.signature_cb));
                        try stmts.append(p.s(S.SExpr{
                            .value = p.getReactRefreshHookSignalInit(hook, Expr.initIdentifier(name_ref, logger.Loc.Empty)),
                        }, logger.Loc.Empty));
                    }

                    if (p.current_scope == p.module_scope) {
                        try p.handleReactRefreshRegister(stmts, original_name, name_ref, .named);
                    }
                }

                return;
            }

            pub fn s_class(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Class) !void {
                const mark_as_dead = p.options.features.dead_code_elimination and data.is_export and
                    p.options.features.replace_exports.count() > 0 and p.isExportToEliminate(data.class.class_name.?.ref.?);
                const original_is_dead = p.is_control_flow_dead;

                if (mark_as_dead) {
                    p.is_control_flow_dead = true;
                }
                defer {
                    if (mark_as_dead) {
                        p.is_control_flow_dead = original_is_dead;
                    }
                }

                _ = try p.visitClass(stmt.loc, &data.class, Ref.None);

                // Remove the export flag inside a namespace
                const was_export_inside_namespace = data.is_export and p.enclosing_namespace_arg_ref != null;
                if (was_export_inside_namespace) {
                    data.is_export = false;
                }

                const lowered = p.lowerClass(js_ast.StmtOrExpr{ .stmt = stmt.* });

                if (!mark_as_dead or was_export_inside_namespace)
                    // Lower class field syntax for browsers that don't support it
                    try stmts.appendSlice(lowered)
                else {
                    const ref = data.class.class_name.?.ref.?;
                    if (p.options.features.replace_exports.getPtr(p.loadNameFromRef(ref))) |replacement| {
                        if (try p.injectReplacementExport(stmts, ref, data.class.class_name.?.loc, replacement)) {
                            p.is_control_flow_dead = original_is_dead;
                        }
                    }
                }

                // Handle exporting this class from a namespace
                if (was_export_inside_namespace) {
                    try stmts.append(
                        Stmt.assign(
                            p.newExpr(
                                E.Dot{
                                    .target = p.newExpr(
                                        E.Identifier{ .ref = p.enclosing_namespace_arg_ref.? },
                                        stmt.loc,
                                    ),
                                    .name = p.symbols.items[data.class.class_name.?.ref.?.innerIndex()].original_name,
                                    .name_loc = data.class.class_name.?.loc,
                                },
                                stmt.loc,
                            ),
                            p.newExpr(
                                E.Identifier{ .ref = data.class.class_name.?.ref.? },
                                data.class.class_name.?.loc,
                            ),
                        ),
                    );
                }

                return;
            }
            pub fn s_export_equals(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ExportEquals) !void {
                // "module.exports = value"
                try stmts.append(
                    Stmt.assign(
                        p.@"module.exports"(stmt.loc),
                        try p.visitExpr(data.value),
                    ),
                );
                p.recordUsage(p.module_ref);
                return;
            }
            pub fn s_break(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Break) !void {
                if (data.label) |*label| {
                    const name = p.loadNameFromRef(label.ref orelse p.panicLoc("Expected label to have a ref", .{}, label.loc));
                    const res = p.findLabelSymbol(label.loc, name);
                    if (res.found) {
                        label.ref = res.ref;
                    } else {
                        data.label = null;
                    }
                } else if (!p.fn_or_arrow_data_visit.is_inside_loop and !p.fn_or_arrow_data_visit.is_inside_switch) {
                    const r = js_lexer.rangeOfIdentifier(p.source, stmt.loc);
                    try p.log.addRangeError(p.source, r, "Cannot use \"break\" here");
                }

                try stmts.append(stmt.*);
            }
            pub fn s_continue(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Continue) !void {
                if (data.label) |*label| {
                    const name = p.loadNameFromRef(label.ref orelse p.panicLoc("Expected continue label to have a ref", .{}, label.loc));
                    const res = p.findLabelSymbol(label.loc, name);
                    label.ref = res.ref;
                    if (res.found and !res.is_loop) {
                        const r = js_lexer.rangeOfIdentifier(p.source, stmt.loc);
                        try p.log.addRangeErrorFmt(p.source, r, p.allocator, "Cannot \"continue\" to label {s}", .{name});
                    }
                } else if (!p.fn_or_arrow_data_visit.is_inside_loop) {
                    const r = js_lexer.rangeOfIdentifier(p.source, stmt.loc);
                    try p.log.addRangeError(p.source, r, "Cannot use \"continue\" here");
                }

                try stmts.append(stmt.*);
            }
            pub fn s_label(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Label) !void {
                try p.pushScopeForVisitPass(.label, stmt.loc);
                const name = p.loadNameFromRef(data.name.ref.?);
                const ref = try p.newSymbol(.label, name);
                data.name.ref = ref;
                p.current_scope.label_ref = ref;
                switch (data.stmt.data) {
                    .s_for, .s_for_in, .s_for_of, .s_while, .s_do_while => {
                        p.current_scope.label_stmt_is_loop = true;
                    },
                    else => {},
                }

                data.stmt = try p.visitSingleStmt(data.stmt, StmtsKind.none);
                p.popScope();

                try stmts.append(stmt.*);
            }
            pub fn s_local(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Local, was_after_after_const_local_prefix: bool) !void {
                // TODO: Silently remove unsupported top-level "await" in dead code branches
                // (this was from 'await using' syntax)

                // Local statements do not end the const local prefix
                p.current_scope.is_after_const_local_prefix = was_after_after_const_local_prefix;

                const decls_len = if (!(data.is_export and p.options.features.replace_exports.entries.len > 0))
                    try p.visitDecls(data.decls.slice(), data.kind == .k_const, false)
                else
                    try p.visitDecls(data.decls.slice(), data.kind == .k_const, true);

                const is_now_dead = data.decls.len > 0 and decls_len == 0;
                if (is_now_dead) {
                    return;
                }

                data.decls.len = @as(u32, @truncate(decls_len));

                // Handle being exported inside a namespace
                if (data.is_export and p.enclosing_namespace_arg_ref != null) {
                    for (data.decls.slice()) |*d| {
                        if (d.value) |val| {
                            p.recordUsage((p.enclosing_namespace_arg_ref orelse unreachable));
                            // TODO: is it necessary to lowerAssign? why does esbuild do it _most_ of the time?
                            try stmts.append(p.s(S.SExpr{
                                .value = Expr.assign(Binding.toExpr(&d.binding, p.to_expr_wrapper_namespace), val),
                            }, stmt.loc));
                        }
                    }

                    return;
                }

                // Optimization: Avoid unnecessary "using" machinery by changing ones
                // initialized to "null" or "undefined" into a normal variable. Note that
                // "await using" still needs the "await", so we can't do it for those.
                if (p.options.features.minify_syntax and data.kind == .k_using) {
                    data.kind = .k_let;
                    for (data.decls.slice()) |*d| {
                        if (d.value) |val| {
                            if (val.data != .e_null and val.data != .e_undefined) {
                                data.kind = .k_using;
                                break;
                            }
                        }
                    }
                }

                // We must relocate vars in order to safely handle removing if/else depending on NODE_ENV.
                // Edgecase:
                //  `export var` is skipped because it's unnecessary. That *should* be a noop, but it loses the `is_export` flag if we're in HMR.
                const kind = p.selectLocalKind(data.kind);
                if (kind == .k_var and !data.is_export) {
                    const relocated = p.maybeRelocateVarsToTopLevel(data.decls.slice(), .normal);
                    if (relocated.ok) {
                        if (relocated.stmt) |new_stmt| {
                            try stmts.append(new_stmt);
                        }

                        return;
                    }
                }

                data.kind = kind;
                try stmts.append(stmt.*);

                if (p.options.features.react_fast_refresh and p.current_scope == p.module_scope) {
                    for (data.decls.slice()) |decl| try_register: {
                        const val = decl.value orelse break :try_register;
                        switch (val.data) {
                            // Assigning a component to a local.
                            .e_arrow, .e_function => {},

                            // A wrapped component.
                            .e_call => |call| switch (call.target.data) {
                                .e_identifier => |id| if (id.ref != p.react_refresh.latest_signature_ref)
                                    break :try_register,
                                else => break :try_register,
                            },
                            else => break :try_register,
                        }
                        const id = switch (decl.binding.data) {
                            .b_identifier => |id| id.ref,
                            else => break :try_register,
                        };
                        const original_name = p.symbols.items[id.innerIndex()].original_name;
                        try p.handleReactRefreshRegister(stmts, original_name, id, .named);
                    }
                }

                if (data.is_export and p.options.features.server_components.wrapsExports()) {
                    for (data.decls.slice()) |*decl| try_annotate: {
                        const val = decl.value orelse break :try_annotate;
                        const id = switch (decl.binding.data) {
                            .b_identifier => |id| id.ref,
                            else => break :try_annotate,
                        };
                        const original_name = p.symbols.items[id.innerIndex()].original_name;
                        decl.value = p.wrapValueForServerComponentReference(val, original_name);
                    }
                }

                return;
            }
            pub fn s_expr(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.SExpr) !void {
                const should_trim_primitive = p.options.features.dead_code_elimination and
                    (p.options.features.minify_syntax and data.value.isPrimitiveLiteral());
                p.stmt_expr_value = data.value.data;
                defer p.stmt_expr_value = .{ .e_missing = .{} };

                const is_top_level = p.current_scope == p.module_scope;

                data.value = try p.visitExpr(data.value);

                if (should_trim_primitive and data.value.isPrimitiveLiteral()) {
                    return;
                }

                // simplify unused
                data.value = SideEffects.simplifyUnusedExpr(p, data.value) orelse return;

                if (p.shouldUnwrapCommonJSToESM() and is_top_level and data.value.data == .e_binary) {
                    const bin = data.value.data.e_binary;
                    if (bin.op == .bin_assign and bin.left.data == .e_commonjs_export_identifier) {
                        const target = bin.left.data.e_commonjs_export_identifier;
                        if (target.export_index != .none) {
                            const index = @backingInt(target.export_index);
                            const entry = &p.commonjs_named_exports.values()[index];
                            bun.assert(entry.loc_ref.ref.?.eql(target.ref));
                            if (entry.needs_decl) {
                                const decls = try p.allocator.alloc(Decl, 1);
                                decls[0] = .{
                                    .binding = p.b(B.Identifier{ .ref = target.ref }, bin.left.loc),
                                    .value = bin.right,
                                };
                                const clause_items = try p.allocator.alloc(js_ast.ClauseItem, 1);
                                clause_items[0] = .{
                                    .alias = p.commonjs_named_exports.keys()[index],
                                    .alias_loc = bin.left.loc,
                                    .name = entry.loc_ref,
                                };
                                try p.declared_symbols.append(p.allocator, .{
                                    .ref = target.ref,
                                    .is_top_level = true,
                                });
                                try stmts.ensureUnusedCapacity(2);
                                const declaration = p.s(S.Local{
                                    .kind = .k_var,
                                    .was_commonjs_export = true,
                                    .decls = G.Decl.List.fromOwnedSlice(decls),
                                }, stmt.loc);
                                const export_clause = p.s(S.ExportClause{
                                    .items = clause_items,
                                    .is_single_line = true,
                                }, stmt.loc);
                                stmts.appendAssumeCapacity(declaration);
                                stmts.appendAssumeCapacity(export_clause);
                                entry.needs_decl = false;
                                p.esm_export_keyword = .{ .loc = stmt.loc, .len = 5 };
                                p.had_commonjs_named_exports_this_visit = true;
                                return;
                            }
                        }
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_throw(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Throw) !void {
                data.value = try p.visitExpr(data.value);
                try stmts.append(stmt.*);
            }
            pub fn s_return(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Return) !void {
                // Forbid top-level return inside modules with ECMAScript-style exports
                if (p.fn_or_arrow_data_visit.is_outside_fn_or_arrow) {
                    const where = where: {
                        if (p.esm_export_keyword.len > 0) {
                            break :where p.esm_export_keyword;
                        } else if (p.top_level_await_keyword.len > 0) {
                            break :where p.top_level_await_keyword;
                        } else {
                            break :where logger.Range.None;
                        }
                    };

                    if (where.len > 0) {
                        try p.log.addRangeError(p.source, where, "Top-level return cannot be used inside an ECMAScript module");
                    }
                }

                if (data.value) |val| {
                    data.value = try p.visitExpr(val);

                    // "return undefined;" can safely just always be "return;"
                    if (data.value != null and @as(Expr.Tag, data.value.?.data) == .e_undefined) {
                        // Returning undefined is implicit
                        data.value = null;
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_block(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Block) !void {
                {
                    try p.pushScopeForVisitPass(.block, stmt.loc);

                    // Pass the "is loop body" status on to the direct children of a block used
                    // as a loop body. This is used to enable optimizations specific to the
                    // topmost scope in a loop body block.
                    const kind = if (std.meta.eql(p.loop_body, stmt.data)) StmtsKind.loop_body else StmtsKind.none;
                    var _stmts = ListManaged(Stmt).fromOwnedSlice(p.allocator, data.stmts);
                    try p.visitStmts(&_stmts, kind);
                    data.stmts = _stmts.items;
                    p.popScope();
                }

                if (p.options.features.minify_syntax) {
                    // // trim empty statements
                    if (data.stmts.len == 0) {
                        try stmts.append(Stmt{ .data = Prefill.Data.SEmpty, .loc = stmt.loc });
                        return;
                    } else if (data.stmts.len == 1 and !statementCaresAboutScope(data.stmts[0])) {
                        // Unwrap blocks containing a single statement
                        try stmts.append(data.stmts[0]);
                        return;
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_with(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.With) !void {
                data.value = try p.visitExpr(data.value);

                try p.pushScopeForVisitPass(.with, data.body_loc);

                // This can be many different kinds of statements.
                // example code:
                //
                //      with(this.document.defaultView || Object.create(null))
                //         with(this.document)
                //           with(this.form)
                //             with(this.element)
                //
                data.body = try p.visitSingleStmt(data.body, StmtsKind.none);

                p.popScope();
                try stmts.append(stmt.*);
            }
            pub fn s_while(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.While) !void {
                data.test_ = try p.visitExpr(data.test_);
                data.body = try p.visitLoopBody(data.body);

                data.test_ = SideEffects.simplifyBoolean(p, data.test_);
                const result = SideEffects.toBoolean(p, data.test_.data);
                if (result.ok and result.side_effects == .no_side_effects) {
                    data.test_ = p.newExpr(E.Boolean{ .value = result.value }, data.test_.loc);
                }

                try stmts.append(stmt.*);
            }
            pub fn s_do_while(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.DoWhile) !void {
                data.body = try p.visitLoopBody(data.body);
                data.test_ = try p.visitExpr(data.test_);

                data.test_ = SideEffects.simplifyBoolean(p, data.test_);
                try stmts.append(stmt.*);
            }
            pub fn s_if(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.If) !void {
                const prev_in_branch = p.in_branch_condition;
                p.in_branch_condition = true;
                data.test_ = try p.visitExpr(data.test_);
                p.in_branch_condition = prev_in_branch;

                if (p.options.features.minify_syntax) {
                    data.test_ = SideEffects.simplifyBoolean(p, data.test_);
                }

                const effects = SideEffects.toBoolean(p, data.test_.data);
                if (effects.ok and !effects.value) {
                    const old = p.is_control_flow_dead;
                    p.is_control_flow_dead = true;
                    data.yes = try p.visitSingleStmt(data.yes, StmtsKind.none);
                    p.is_control_flow_dead = old;
                } else {
                    data.yes = try p.visitSingleStmt(data.yes, StmtsKind.none);
                }

                // The "else" clause is optional
                if (data.no) |no| {
                    if (effects.ok and effects.value) {
                        const old = p.is_control_flow_dead;
                        p.is_control_flow_dead = true;
                        defer p.is_control_flow_dead = old;
                        data.no = try p.visitSingleStmt(no, .none);
                    } else {
                        data.no = try p.visitSingleStmt(no, .none);
                    }

                    // Trim an "else" clause whose body was emptied by dead-code
                    // elimination. This avoids emitting `else {}` for e.g.
                    // `if (true) { A } else { B }` where B was pruned. Gated on
                    // the union of DCE and minify_syntax so the pre-existing
                    // `deadCodeElimination: false, minify: { syntax: true }`
                    // configuration (which already dropped the `else {}`)
                    // doesn't regress to `else ;`.
                    if (p.options.features.dead_code_elimination or p.options.features.minify_syntax) {
                        if (data.no) |no_stmt| {
                            const no_is_empty = switch (no_stmt.data) {
                                .s_empty => true,
                                .s_block => |block| block.stmts.len == 0,
                                else => false,
                            };
                            if (no_is_empty) {
                                data.no = null;
                            }
                        }
                    }
                }

                if (p.options.features.minify_syntax) {
                    if (effects.ok) {
                        if (effects.value) {
                            if (data.no == null or !SideEffects.shouldKeepStmtInDeadControlFlow(data.no.?, p.allocator)) {
                                if (effects.side_effects == .could_have_side_effects) {
                                    // Keep the condition if it could have side effects (but is still known to be truthy)
                                    if (SideEffects.simplifyUnusedExpr(p, data.test_)) |test_| {
                                        try stmts.append(p.s(S.SExpr{ .value = test_ }, test_.loc));
                                    }
                                }

                                return try p.appendIfBodyPreservingScope(stmts, data.yes);
                            } else {
                                // We have to keep the "no" branch
                            }
                        } else {
                            // The test is falsy
                            if (!SideEffects.shouldKeepStmtInDeadControlFlow(data.yes, p.allocator)) {
                                if (effects.side_effects == .could_have_side_effects) {
                                    // Keep the condition if it could have side effects (but is still known to be truthy)
                                    if (SideEffects.simplifyUnusedExpr(p, data.test_)) |test_| {
                                        try stmts.append(p.s(S.SExpr{ .value = test_ }, test_.loc));
                                    }
                                }

                                if (data.no == null) {
                                    return;
                                }

                                return try p.appendIfBodyPreservingScope(stmts, data.no.?);
                            }
                        }
                    }

                    // TODO: more if statement syntax minification
                    const can_remove_test = p.exprCanBeRemovedIfUnused(&data.test_);
                    switch (data.yes.data) {
                        .s_expr => |yes_expr| {
                            if (yes_expr.value.isMissing()) {
                                if (data.no == null) {
                                    if (can_remove_test) {
                                        return;
                                    }
                                } else if (data.no.?.isMissingExpr() and can_remove_test) {
                                    return;
                                }
                            }
                        },
                        .s_empty => {
                            if (data.no == null) {
                                if (can_remove_test) {
                                    return;
                                }
                            } else if (data.no.?.isMissingExpr() and can_remove_test) {
                                return;
                            }
                        },
                        else => {},
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_for(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.For) !void {
                try p.pushScopeForVisitPass(.block, stmt.loc);

                if (data.init) |initst| {
                    data.init = try p.visitForLoopInit(initst, false);
                }

                if (data.test_) |test_| {
                    data.test_ = SideEffects.simplifyBoolean(p, try p.visitExpr(test_));

                    const result = SideEffects.toBoolean(p, data.test_.?.data);
                    if (result.ok and result.value and result.side_effects == .no_side_effects) {
                        data.test_ = null;
                    }
                }

                if (data.update) |update| {
                    data.update = try p.visitExpr(update);
                }

                data.body = try p.visitLoopBody(data.body);

                if (data.init) |for_init| {
                    if (for_init.data == .s_local) {
                        // Potentially relocate "var" declarations to the top level. Note that this
                        // must be done inside the scope of the for loop or they won't be relocated.
                        if (for_init.data.s_local.kind == .k_var) {
                            const relocate = p.maybeRelocateVarsToTopLevel(for_init.data.s_local.decls.slice(), .normal);
                            if (relocate.stmt) |relocated| {
                                data.init = relocated;
                            }
                        }
                    }
                }

                p.popScope();

                try stmts.append(stmt.*);
            }
            pub fn s_for_in(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ForIn) !void {
                {
                    try p.pushScopeForVisitPass(.block, stmt.loc);
                    defer p.popScope();
                    _ = try p.visitForLoopInit(data.init, true);
                    data.value = try p.visitExpr(data.value);
                    data.body = try p.visitLoopBody(data.body);

                    // Check for a variable initializer
                    if (data.init.data == .s_local and data.init.data.s_local.kind == .k_var) {
                        // Lower for-in variable initializers in case the output is used in strict mode
                        var local = data.init.data.s_local;
                        if (local.decls.len == 1) {
                            var decl: *G.Decl = &local.decls.ptr[0];
                            if (decl.binding.data == .b_identifier) {
                                if (decl.value) |val| {
                                    try stmts.append(
                                        Stmt.assign(
                                            Expr.initIdentifier(decl.binding.data.b_identifier.ref, decl.binding.loc),
                                            val,
                                        ),
                                    );
                                    decl.value = null;
                                }
                            }
                        }

                        const relocate = p.maybeRelocateVarsToTopLevel(data.init.data.s_local.decls.slice(), RelocateVars.Mode.for_in_or_for_of);
                        if (relocate.stmt) |relocated_stmt| {
                            data.init = relocated_stmt;
                        }
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_for_of(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.ForOf) !void {
                try p.pushScopeForVisitPass(.block, stmt.loc);
                defer p.popScope();
                _ = try p.visitForLoopInit(data.init, true);
                data.value = try p.visitExpr(data.value);
                data.body = try p.visitLoopBody(data.body);

                if (data.init.data == .s_local) {
                    if (data.init.data.s_local.kind == .k_var) {
                        const relocate = p.maybeRelocateVarsToTopLevel(data.init.data.s_local.decls.slice(), RelocateVars.Mode.for_in_or_for_of);
                        if (relocate.stmt) |relocated_stmt| {
                            data.init = relocated_stmt;
                        }
                    }

                    // Handle "for (using x of y)" and "for (await using x of y)"
                    if (data.init.data == .s_local and data.init.data.s_local.kind.isUsing() and p.options.features.lower_using) {
                        // fn lowerUsingDeclarationInForOf()
                        const loc = data.init.loc;
                        const init2 = data.init.data.s_local;
                        const binding = init2.decls.at(0).binding;
                        var id = binding.data.b_identifier;
                        const temp_ref = p.generateTempRef(p.symbols.items[id.ref.inner_index].original_name);

                        const first = p.s(S.Local{
                            .kind = init2.kind,
                            .decls = bindings: {
                                const decls = try p.allocator.alloc(G.Decl, 1);
                                decls[0] = .{
                                    .binding = p.b(B.Identifier{ .ref = id.ref }, loc),
                                    .value = p.newExpr(E.Identifier{ .ref = temp_ref }, loc),
                                };
                                break :bindings G.Decl.List.fromOwnedSlice(decls);
                            },
                        }, loc);

                        const length = if (data.body.data == .s_block) data.body.data.s_block.stmts.len else 1;
                        const statement_count = std.math.add(usize, length, 1) catch return error.OutOfMemory;
                        const statements = try p.allocator.alloc(Stmt, statement_count);
                        statements[0] = first;
                        if (data.body.data == .s_block) {
                            @memcpy(statements[1..], data.body.data.s_block.stmts);
                        } else {
                            statements[1] = data.body;
                        }

                        var ctx = try P.LowerUsingDeclarationsContext.init(p);
                        ctx.scanStmts(p, statements);
                        const visited_stmts = ctx.finalize(p, statements, p.will_wrap_module_in_try_catch_for_using and p.current_scope.parent == null);
                        if (data.body.data == .s_block) {
                            data.body.data.s_block.stmts = visited_stmts.items;
                        } else {
                            data.body = p.s(S.Block{
                                .stmts = visited_stmts.items,
                            }, loc);
                        }
                        id.ref = temp_ref;
                        init2.kind = .k_const;
                    }
                }

                try stmts.append(stmt.*);
            }
            pub fn s_try(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Try) !void {
                try p.pushScopeForVisitPass(.block, stmt.loc);
                {
                    var _stmts = ListManaged(Stmt).fromOwnedSlice(p.allocator, data.body);
                    p.fn_or_arrow_data_visit.try_body_count += 1;
                    try p.visitStmts(&_stmts, StmtsKind.none);
                    p.fn_or_arrow_data_visit.try_body_count -= 1;
                    data.body = _stmts.items;
                }
                p.popScope();

                if (data.catch_) |*catch_| {
                    try p.pushScopeForVisitPass(.catch_binding, catch_.loc);
                    {
                        if (catch_.binding) |catch_binding| {
                            try p.visitBinding(catch_binding, null);
                        }
                        var _stmts = ListManaged(Stmt).fromOwnedSlice(p.allocator, catch_.body);
                        try p.pushScopeForVisitPass(.block, catch_.body_loc);
                        try p.visitStmts(&_stmts, StmtsKind.none);
                        p.popScope();
                        catch_.body = _stmts.items;
                    }
                    p.popScope();
                }

                if (data.finally) |*finally| {
                    try p.pushScopeForVisitPass(.block, finally.loc);
                    {
                        var _stmts = ListManaged(Stmt).fromOwnedSlice(p.allocator, finally.stmts);
                        try p.visitStmts(&_stmts, StmtsKind.none);
                        finally.stmts = _stmts.items;
                    }
                    p.popScope();
                }

                try stmts.append(stmt.*);
            }
            pub fn s_switch(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Switch) !void {
                data.test_ = try p.visitExpr(data.test_);
                {
                    try p.pushScopeForVisitPass(.block, data.body_loc);
                    defer p.popScope();
                    const old_is_inside_Swsitch = p.fn_or_arrow_data_visit.is_inside_switch;
                    p.fn_or_arrow_data_visit.is_inside_switch = true;
                    defer p.fn_or_arrow_data_visit.is_inside_switch = old_is_inside_Swsitch;
                    for (data.cases, 0..) |case, i| {
                        if (case.value) |val| {
                            data.cases[i].value = try p.visitExpr(val);
                            // TODO: error messages
                            // Check("case", *c.Value, c.Value.Loc)
                            //                 p.warnAboutTypeofAndString(s.Test, *c.Value)
                        }
                        var _stmts = ListManaged(Stmt).fromOwnedSlice(p.allocator, case.body);
                        try p.visitStmts(&_stmts, StmtsKind.none);
                        data.cases[i].body = _stmts.items;
                    }
                }
                // TODO: duplicate case checker

                try stmts.append(stmt.*);
            }

            pub fn s_enum(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Enum, was_after_after_const_local_prefix: bool) !void {

                // Do not end the const local prefix after TypeScript enums. We process
                // them first within their scope so that they are inlined into all code in
                // that scope. We don't want that to cause the const local prefix to end.
                p.current_scope.is_after_const_local_prefix = was_after_after_const_local_prefix;

                // Track cross-module enum constants during bundling. This
                // part of the code is different from esbuilt in that we are
                // only storing a list of enum indexes. At the time of
                // referencing, `esbuild` builds a separate hash map of hash
                // maps. We are avoiding that to reduce memory usage, since
                // enum inlining already uses alot of hash maps.
                if (p.current_scope == p.module_scope and p.options.bundle) {
                    try p.top_level_enums.append(p.allocator, data.name.ref.?);
                }

                try p.recordDeclaredSymbol(data.name.ref.?);
                try p.pushScopeForVisitPass(.entry, stmt.loc);
                defer p.popScope();
                try p.recordDeclaredSymbol(data.arg);

                const allocator = p.allocator;
                // Scan ahead for any variables inside this namespace. This must be done
                // ahead of time before visiting any statements inside the namespace
                // because we may end up visiting the uses before the declarations.
                // We need to convert the uses into property accesses on the namespace.
                for (data.values) |value| {
                    if (value.ref.isValid()) {
                        try p.is_exported_inside_namespace.put(allocator, value.ref, data.arg);
                    }
                }

                // Values without initializers are initialized to one more than the
                // previous value if the previous value is numeric. Otherwise values
                // without initializers are initialized to undefined.
                var next_numeric_value: ?f64 = 0.0;

                var value_exprs = try ListManaged(Expr).initCapacity(allocator, data.values.len);

                var all_values_are_pure = true;

                const exported_members = p.current_scope.ts_namespace.?.exported_members;

                // We normally don't fold numeric constants because they might increase code
                // size, but it's important to fold numeric constants inside enums since
                // that's what the TypeScript compiler does.
                const old_should_fold_typescript_constant_expressions = p.should_fold_typescript_constant_expressions;
                p.should_fold_typescript_constant_expressions = true;

                // Create an assignment for each enum value
                for (data.values) |*value| {
                    const name = value.name;

                    var has_string_value = false;
                    if (value.value) |enum_value| {
                        next_numeric_value = null;

                        const visited = try p.visitExpr(enum_value);

                        // "See through" any wrapped comments
                        const underlying_value = if (visited.data == .e_inlined_enum)
                            visited.data.e_inlined_enum.value
                        else
                            visited;
                        value.value = underlying_value;

                        switch (underlying_value.data) {
                            .e_number => |num| {
                                exported_members.getPtr(name).?.data = .{ .enum_number = num.value };

                                try p.ref_to_ts_namespace_member.put(
                                    p.allocator,
                                    value.ref,
                                    .{ .enum_number = num.value },
                                );

                                next_numeric_value = num.value + 1.0;
                            },
                            .e_string => |str| {
                                has_string_value = true;

                                exported_members.getPtr(name).?.data = .{ .enum_string = str };

                                try p.ref_to_ts_namespace_member.put(
                                    p.allocator,
                                    value.ref,
                                    .{ .enum_string = str },
                                );
                            },
                            else => {
                                if (visited.knownPrimitive() == .string) {
                                    has_string_value = true;
                                }

                                if (!p.exprCanBeRemovedIfUnused(&visited)) {
                                    all_values_are_pure = false;
                                }
                            },
                        }
                    } else if (next_numeric_value) |num| {
                        value.value = p.newExpr(E.Number{ .value = num }, value.loc);

                        next_numeric_value = num + 1;

                        exported_members.getPtr(name).?.data = .{ .enum_number = num };

                        try p.ref_to_ts_namespace_member.put(
                            p.allocator,
                            value.ref,
                            .{ .enum_number = num },
                        );
                    } else {
                        value.value = p.newExpr(E.Undefined{}, value.loc);
                    }

                    const is_assign_target = p.options.features.minify_syntax and bun.js_lexer.isIdentifier(value.name);

                    const name_as_e_string = if (!is_assign_target or !has_string_value)
                        p.newExpr(value.nameAsEString(allocator), value.loc)
                    else
                        null;

                    const assign_target = if (is_assign_target)
                        // "Enum.Name = value"
                        Expr.assign(
                            p.newExpr(E.Dot{
                                .target = p.newExpr(
                                    E.Identifier{ .ref = data.arg },
                                    value.loc,
                                ),
                                .name = value.name,
                                .name_loc = value.loc,
                            }, value.loc),
                            value.value.?,
                        )
                    else
                        // "Enum['Name'] = value"
                        Expr.assign(
                            p.newExpr(E.Index{
                                .target = p.newExpr(
                                    E.Identifier{ .ref = data.arg },
                                    value.loc,
                                ),
                                .index = name_as_e_string.?,
                            }, value.loc),
                            value.value.?,
                        );

                    p.recordUsage(data.arg);

                    // String-valued enums do not form a two-way map
                    if (has_string_value) {
                        try value_exprs.append(assign_target);
                    } else {
                        // "Enum[assignTarget] = 'Name'"
                        try value_exprs.append(
                            Expr.assign(
                                p.newExpr(E.Index{
                                    .target = p.newExpr(
                                        E.Identifier{ .ref = data.arg },
                                        value.loc,
                                    ),
                                    .index = assign_target,
                                }, value.loc),
                                name_as_e_string.?,
                            ),
                        );
                        p.recordUsage(data.arg);
                    }
                }

                p.should_fold_typescript_constant_expressions = old_should_fold_typescript_constant_expressions;

                var value_stmts = try ListManaged(Stmt).initCapacity(allocator, value_exprs.items.len);
                // Generate statements from expressions
                for (value_exprs.items) |expr| {
                    value_stmts.appendAssumeCapacity(p.s(S.SExpr{ .value = expr }, expr.loc));
                }
                value_exprs.deinit();
                try p.generateClosureForTypeScriptNamespaceOrEnum(
                    stmts,
                    stmt.loc,
                    data.is_export,
                    data.name.loc,
                    data.name.ref.?,
                    data.arg,
                    value_stmts.items,
                    all_values_are_pure,
                );
                return;
            }
            pub fn s_namespace(noalias p: *P, noalias stmts: *ListManaged(Stmt), noalias stmt: *Stmt, noalias data: *S.Namespace) !void {
                try p.recordDeclaredSymbol(data.name.ref.?);

                // Scan ahead for any variables inside this namespace. This must be done
                // ahead of time before visiting any statements inside the namespace
                // because we may end up visiting the uses before the declarations.
                // We need to convert the uses into property accesses on the namespace.
                for (data.stmts) |child_stmt| {
                    switch (child_stmt.data) {
                        .s_local => |local| {
                            if (local.is_export) {
                                p.markExportedDeclsInsideNamespace(data.arg, local.decls.slice());
                            }
                        },
                        else => {},
                    }
                }

                var prepend_temp_refs = PrependTempRefsOpts{ .kind = StmtsKind.fn_body };
                var prepend_list = ListManaged(Stmt).fromOwnedSlice(p.allocator, data.stmts);

                const old_enclosing_namespace_arg_ref = p.enclosing_namespace_arg_ref;
                p.enclosing_namespace_arg_ref = data.arg;
                try p.pushScopeForVisitPass(.entry, stmt.loc);
                try p.recordDeclaredSymbol(data.arg);
                try p.visitStmtsAndPrependTempRefs(&prepend_list, &prepend_temp_refs);
                p.popScope();
                p.enclosing_namespace_arg_ref = old_enclosing_namespace_arg_ref;

                try p.generateClosureForTypeScriptNamespaceOrEnum(
                    stmts,
                    stmt.loc,
                    data.is_export,
                    data.name.loc,
                    data.name.ref.?,
                    data.arg,
                    prepend_list.items,
                    false,
                );
                return;
            }
        };
    };
}

const string = []const u8;

const bun = @import("bun");
const assert = bun.assert;
const js_lexer = bun.js_lexer;
const logger = bun.logger;
const strings = bun.strings;

const js_ast = bun.ast;
const B = js_ast.B;
const Binding = js_ast.Binding;
const E = js_ast.E;
const Expr = js_ast.Expr;
const S = js_ast.S;
const Stmt = js_ast.Stmt;

const G = js_ast.G;
const Decl = G.Decl;

const js_parser = bun.js_parser;
const JSXTransformType = js_parser.JSXTransformType;
const Prefill = js_parser.Prefill;
const PrependTempRefsOpts = js_parser.PrependTempRefsOpts;
const ReactRefresh = js_parser.ReactRefresh;
const Ref = js_parser.Ref;
const RelocateVars = js_parser.RelocateVars;
const SideEffects = js_parser.SideEffects;
const StmtsKind = js_parser.StmtsKind;
const options = js_parser.options;
const statementCaresAboutScope = js_parser.statementCaresAboutScope;

const std = @import("std");
const List = std.ArrayList;
const ListManaged = std.array_list.Managed;
