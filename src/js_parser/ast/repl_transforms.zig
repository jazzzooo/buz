/// REPL Transform module - transforms code for interactive REPL evaluation
///
/// This module provides transformations for REPL mode:
/// - Wraps the last expression in { value: expr } for result capture
/// - Wraps code with await in async IIFE with variable hoisting
/// - Hoists declarations for variable persistence across REPL lines
pub fn ReplTransforms(comptime P: type) type {
    return struct {
        /// Apply REPL-mode transforms to the AST.
        /// This transforms code for interactive evaluation:
        /// - Wraps the last expression in { value: expr } for result capture
        /// - Wraps code with await in async IIFE with variable hoisting
        pub fn apply(p: *P, parts: *ListManaged(js_ast.Part), allocator: Allocator) !void {
            // Skip transform if there's a top-level return (indicates module pattern)
            if (p.has_top_level_return) {
                return;
            }

            // Collect all statements
            var total_stmts_count: usize = 0;
            for (parts.items) |part| {
                total_stmts_count = std.math.add(usize, total_stmts_count, part.stmts.len) catch return error.OutOfMemory;
            }

            if (total_stmts_count == 0) {
                return;
            }

            // Collect all statements into a single array
            const all_stmts = try allocator.alloc(Stmt, total_stmts_count);
            defer allocator.free(all_stmts);
            var stmt_idx: usize = 0;
            for (parts.items) |part| {
                for (part.stmts) |stmt| {
                    all_stmts[stmt_idx] = stmt;
                    stmt_idx += 1;
                }
            }

            // Check if there's top-level await or imports (imports become dynamic awaited imports)
            var has_top_level_await = p.top_level_await_keyword.len > 0;
            if (!has_top_level_await) {
                for (all_stmts) |stmt| {
                    if (stmt.data == .s_import) {
                        has_top_level_await = true;
                        break;
                    }
                }
            }

            // Apply transform with is_async based on presence of top-level await
            try transformWithHoisting(p, parts, all_stmts, allocator, has_top_level_await);
        }

        /// Transform code with hoisting and IIFE wrapper
        /// @param is_async: true for async IIFE (when top-level await present), false for sync IIFE
        fn transformWithHoisting(
            p: *P,
            parts: *ListManaged(js_ast.Part),
            all_stmts: []Stmt,
            allocator: Allocator,
            is_async: bool,
        ) !void {
            if (all_stmts.len == 0) return;

            // Lists for hoisted declarations and inner statements
            var hoisted_stmts = ListManaged(Stmt).init(allocator);
            defer hoisted_stmts.deinit();
            var inner_stmts = ListManaged(Stmt).init(allocator);
            errdefer inner_stmts.deinit();
            try hoisted_stmts.ensureTotalCapacity(all_stmts.len);
            try inner_stmts.ensureTotalCapacity(all_stmts.len);

            // Process each statement - hoist all declarations for REPL persistence
            for (all_stmts) |stmt| {
                switch (stmt.data) {
                    .s_local => |local| {
                        // Hoist all declarations as var so they become context properties
                        // In sloppy mode, var at top level becomes a property of the global/context object
                        // This is essential for REPL variable persistence across vm.runInContext calls
                        const kind: S.Local.Kind = .k_var;

                        // Extract individual identifiers from binding patterns for hoisting
                        var hoisted_decl_list = ListManaged(G.Decl).init(allocator);
                        errdefer hoisted_decl_list.deinit();
                        for (local.decls.slice()) |decl| {
                            try extractIdentifiersFromBinding(p, decl.binding, &hoisted_decl_list);
                        }

                        if (hoisted_decl_list.items.len > 0) {
                            try hoisted_stmts.append(p.s(S.Local{
                                .kind = kind,
                                .decls = Decl.List.fromOwnedSlice(hoisted_decl_list.items),
                            }, stmt.loc));
                        }

                        // Create assignment expressions for the inner statements
                        for (local.decls.slice()) |decl| {
                            if (decl.value) |value| {
                                // Create assignment expression: binding = value
                                const assign_expr = try createBindingAssignment(p, decl.binding, value, allocator);
                                try inner_stmts.append(p.s(S.SExpr{ .value = assign_expr }, stmt.loc));
                            }
                        }
                    },
                    .s_function => |func| {
                        // For function declarations:
                        // Hoist as: var funcName;
                        // Inner: this.funcName = funcName; function funcName() {}
                        if (func.func.name) |name_loc| {
                            try hoisted_stmts.append(p.s(S.Local{
                                .kind = .k_var,
                                .decls = Decl.List.fromOwnedSlice(try allocator.dupe(G.Decl, &.{
                                    G.Decl{
                                        .binding = p.b(B.Identifier{ .ref = name_loc.ref.? }, name_loc.loc),
                                        .value = null,
                                    },
                                })),
                            }, stmt.loc));

                            // Add this.funcName = funcName assignment
                            const this_expr = p.newExpr(E.This{}, stmt.loc);
                            const this_dot = p.newExpr(E.Dot{
                                .target = this_expr,
                                .name = p.symbols.items[name_loc.ref.?.innerIndex()].original_name,
                                .name_loc = name_loc.loc,
                            }, stmt.loc);
                            const func_id = p.newExpr(E.Identifier{ .ref = name_loc.ref.? }, name_loc.loc);
                            const assign = p.newExpr(E.Binary{
                                .op = .bin_assign,
                                .left = this_dot,
                                .right = func_id,
                            }, stmt.loc);
                            try inner_stmts.append(p.s(S.SExpr{ .value = assign }, stmt.loc));
                        }
                        // Add the function declaration itself
                        try inner_stmts.append(stmt);
                    },
                    .s_class => |class| {
                        // For class declarations:
                        // Hoist as: var ClassName; (use var so it persists to vm context)
                        // Inner: ClassName = class ClassName {}
                        if (class.class.class_name) |name_loc| {
                            try hoisted_stmts.append(p.s(S.Local{
                                .kind = .k_var,
                                .decls = Decl.List.fromOwnedSlice(try allocator.dupe(G.Decl, &.{
                                    G.Decl{
                                        .binding = p.b(B.Identifier{ .ref = name_loc.ref.? }, name_loc.loc),
                                        .value = null,
                                    },
                                })),
                            }, stmt.loc));

                            // Convert class declaration to assignment: ClassName = class ClassName {}
                            const class_expr = p.newExpr(class.class, stmt.loc);
                            const class_id = p.newExpr(E.Identifier{ .ref = name_loc.ref.? }, name_loc.loc);
                            const assign = p.newExpr(E.Binary{
                                .op = .bin_assign,
                                .left = class_id,
                                .right = class_expr,
                            }, stmt.loc);
                            try inner_stmts.append(p.s(S.SExpr{ .value = assign }, stmt.loc));
                        } else {
                            try inner_stmts.append(stmt);
                        }
                    },
                    .s_import => |import_data| {
                        // Convert static imports to dynamic imports for REPL evaluation:
                        //   import X from 'mod'      -> var X = (await import('mod')).default
                        //   import { a, b } from 'mod' -> var {a, b} = await import('mod')
                        //   import * as X from 'mod'   -> var X = await import('mod')
                        //   import 'mod'              -> await import('mod')
                        const record = &p.import_records.items[import_data.import_record_index];
                        const import_options = try createImportOptions(p, record.*, allocator, stmt.loc);
                        record.kind = .dynamic;
                        const import_expr = p.newExpr(E.Import{
                            .expr = p.newExpr(E.String{ .data = record.path.text }, stmt.loc),
                            .import_record_index = import_data.import_record_index,
                            .options = import_options,
                        }, stmt.loc);
                        const await_expr = p.newExpr(E.Await{ .value = import_expr }, stmt.loc);

                        try convertImports(p, import_data, await_expr, &hoisted_stmts, &inner_stmts, allocator, stmt.loc);
                    },
                    .s_directive => |directive| {
                        // In REPL mode, treat directives (string literals) as expressions
                        const str_expr = p.newExpr(E.String{ .data = directive.value }, stmt.loc);
                        try inner_stmts.append(p.s(S.SExpr{ .value = str_expr }, stmt.loc));
                    },
                    else => {
                        try inner_stmts.append(stmt);
                    },
                }
            }

            // Wrap the last expression in return { value: expr }
            try wrapLastExpressionWithReturn(p, &inner_stmts, allocator);

            // Create the IIFE: (() => { ...inner_stmts... })() or (async () => { ... })()
            const arrow = p.newExpr(E.Arrow{
                .args = &.{},
                .body = .{ .loc = logger.Loc.Empty, .stmts = inner_stmts.items },
                .is_async = is_async,
            }, logger.Loc.Empty);

            const iife = p.newExpr(E.Call{
                .target = arrow,
                .args = ExprNodeList{},
            }, logger.Loc.Empty);

            // Final output: hoisted declarations + IIFE call
            const final_stmts_count = std.math.add(usize, hoisted_stmts.items.len, 1) catch return error.OutOfMemory;
            const final_stmts = try allocator.alloc(Stmt, final_stmts_count);
            for (hoisted_stmts.items, 0..) |stmt, j| {
                final_stmts[j] = stmt;
            }
            final_stmts[hoisted_stmts.items.len] = p.s(S.SExpr{ .value = iife }, logger.Loc.Empty);

            // Update parts
            if (parts.items.len > 0) {
                parts.items[0].stmts = final_stmts;
                parts.items.len = 1;
            }
        }

        fn createImportOptions(p: *P, record: bun.ImportRecord, allocator: Allocator, loc: logger.Loc) bun.OOM!Expr {
            var attributes: [3]G.Property = undefined;
            var count: usize = 0;
            if (record.loader) |loader| {
                attributes[count] = .{
                    .key = p.newExpr(E.String{ .data = "type" }, loc),
                    .value = p.newExpr(E.String{ .data = loader.importAttributeType() }, loc),
                };
                count += 1;
                if (loader == .sqlite_embedded) {
                    attributes[count] = .{
                        .key = p.newExpr(E.String{ .data = "embed" }, loc),
                        .value = p.newExpr(E.String{ .data = "true" }, loc),
                    };
                    count += 1;
                }
            }
            if (record.tag == .bake_resolve_to_ssr_graph) {
                attributes[count] = .{
                    .key = p.newExpr(E.String{ .data = "bunBakeGraph" }, loc),
                    .value = p.newExpr(E.String{ .data = "ssr" }, loc),
                };
                count += 1;
            }
            if (count == 0) return Expr.empty;
            var attribute_properties = try G.Property.List.fromSlice(allocator, attributes[0..count]);
            errdefer attribute_properties.deinit(allocator);
            const with = p.newExpr(E.Object{ .properties = attribute_properties, .is_single_line = true }, loc);
            const properties = try G.Property.List.fromSlice(allocator, &.{.{
                .key = p.newExpr(E.String{ .data = "with" }, loc),
                .value = with,
            }});
            return p.newExpr(E.Object{ .properties = properties, .is_single_line = true }, loc);
        }

        fn convertImports(
            p: *P,
            import_data: *const S.Import,
            await_expr: Expr,
            hoisted_stmts: *ListManaged(Stmt),
            inner_stmts: *ListManaged(Stmt),
            allocator: Allocator,
            loc: logger.Loc,
        ) !void {
            if (import_data.star_name_loc == null and import_data.default_name == null and import_data.items.len == 0) {
                try inner_stmts.append(p.s(S.SExpr{ .value = await_expr }, loc));
                return;
            }

            // Store the module in the namespace ref: var __ns = await import('mod')
            try hoisted_stmts.append(p.s(S.Local{
                .kind = .k_var,
                .decls = Decl.List.fromOwnedSlice(try allocator.dupe(G.Decl, &.{
                    G.Decl{
                        .binding = p.b(B.Identifier{ .ref = import_data.namespace_ref }, loc),
                        .value = null,
                    },
                })),
            }, loc));
            const ns_assign = p.newExpr(E.Binary{
                .op = .bin_assign,
                .left = p.newExpr(E.Identifier{ .ref = import_data.namespace_ref }, loc),
                .right = await_expr,
            }, loc);
            try inner_stmts.append(p.s(S.SExpr{ .value = ns_assign }, loc));

            if (import_data.default_name) |name| {
                try assignImportedBinding(p, import_data.namespace_ref, name, "default", hoisted_stmts, inner_stmts, allocator);
            }
            for (import_data.items) |item| {
                try assignImportedBinding(p, import_data.namespace_ref, item.name, item.alias, hoisted_stmts, inner_stmts, allocator);
            }
        }

        fn assignImportedBinding(
            p: *P,
            namespace_ref: js_ast.Ref,
            name: js_ast.LocRef,
            alias: []const u8,
            hoisted_stmts: *ListManaged(Stmt),
            inner_stmts: *ListManaged(Stmt),
            allocator: Allocator,
        ) !void {
            try hoisted_stmts.ensureUnusedCapacity(1);
            try inner_stmts.ensureUnusedCapacity(1);
            const decls = try Decl.List.fromSlice(allocator, &.{.{
                .binding = p.b(B.Identifier{ .ref = name.ref.? }, name.loc),
            }});
            hoisted_stmts.appendAssumeCapacity(p.s(S.Local{ .kind = .k_var, .decls = decls }, name.loc));
            const target = p.newExpr(E.Identifier{ .ref = namespace_ref }, name.loc);
            const value = if (bun.js_lexer.isIdentifier(alias))
                p.newExpr(E.Dot{ .target = target, .name = alias, .name_loc = name.loc }, name.loc)
            else
                p.newExpr(E.Index{ .target = target, .index = p.newExpr(E.String{ .data = alias }, name.loc) }, name.loc);
            const assignment = p.newExpr(E.Binary{
                .op = .bin_assign,
                .left = p.newExpr(E.Identifier{ .ref = name.ref.? }, name.loc),
                .right = value,
            }, name.loc);
            inner_stmts.appendAssumeCapacity(p.s(S.SExpr{ .value = assignment }, name.loc));
        }

        /// Wrap the last expression in return { value: expr }
        fn wrapLastExpressionWithReturn(p: *P, inner_stmts: *ListManaged(Stmt), allocator: Allocator) bun.OOM!void {
            if (inner_stmts.items.len > 0) {
                var last_idx: usize = inner_stmts.items.len;
                while (last_idx > 0) {
                    last_idx -= 1;
                    const last_stmt = inner_stmts.items[last_idx];
                    switch (last_stmt.data) {
                        .s_empty, .s_comment => continue,
                        .s_expr => |expr_data| {
                            // Wrap in return { value: expr }
                            const wrapped = try wrapExprInValueObject(p, expr_data.value, allocator);
                            inner_stmts.items[last_idx] = p.s(S.Return{ .value = wrapped }, last_stmt.loc);
                            break;
                        },
                        else => break,
                    }
                }
            }
        }

        /// Extract individual identifiers from a binding pattern for hoisting
        fn extractIdentifiersFromBinding(p: *P, binding: Binding, decls: *ListManaged(G.Decl)) bun.OOM!void {
            switch (binding.data) {
                .b_identifier => |ident| {
                    try decls.append(G.Decl{
                        .binding = p.b(B.Identifier{ .ref = ident.ref }, binding.loc),
                        .value = null,
                    });
                },
                .b_array => |arr| {
                    for (arr.items) |item| {
                        try extractIdentifiersFromBinding(p, item.binding, decls);
                    }
                },
                .b_object => |obj| {
                    for (obj.properties) |prop| {
                        try extractIdentifiersFromBinding(p, prop.value, decls);
                    }
                },
                .b_missing => {},
            }
        }

        /// Create { __proto__: null, value: expr } wrapper object
        /// Uses null prototype to create a clean data object
        fn wrapExprInValueObject(p: *P, expr: Expr, allocator: Allocator) bun.OOM!Expr {
            const properties = try allocator.alloc(G.Property, 2);
            // __proto__: null - creates null-prototype object
            properties[0] = G.Property{
                .key = p.newExpr(E.String{ .data = "__proto__" }, expr.loc),
                .value = p.newExpr(E.Null{}, expr.loc),
            };
            // value: expr - the actual result value
            properties[1] = G.Property{
                .key = p.newExpr(E.String{ .data = "value" }, expr.loc),
                .value = expr,
            };
            return p.newExpr(E.Object{
                .properties = G.Property.List.fromOwnedSlice(properties),
            }, expr.loc);
        }

        /// Create assignment expression from binding pattern
        fn createBindingAssignment(p: *P, binding: Binding, value: Expr, allocator: Allocator) bun.OOM!Expr {
            switch (binding.data) {
                .b_identifier => |ident| {
                    return p.newExpr(E.Binary{
                        .op = .bin_assign,
                        .left = p.newExpr(E.Identifier{ .ref = ident.ref }, binding.loc),
                        .right = value,
                    }, binding.loc);
                },
                .b_array => {
                    // For array destructuring, create: [a, b] = value
                    return p.newExpr(E.Binary{
                        .op = .bin_assign,
                        .left = try convertBindingToExpr(p, binding, allocator),
                        .right = value,
                    }, binding.loc);
                },
                .b_object => {
                    // For object destructuring, create: {a, b} = value
                    return p.newExpr(E.Binary{
                        .op = .bin_assign,
                        .left = try convertBindingToExpr(p, binding, allocator),
                        .right = value,
                    }, binding.loc);
                },
                .b_missing => {
                    // Return Missing expression to match convertBindingToExpr
                    return p.newExpr(E.Missing{}, binding.loc);
                },
            }
        }

        /// Convert a binding pattern to an expression (for assignment targets)
        /// Handles spread/rest patterns in arrays and objects to match Binding.toExpr behavior
        fn convertBindingToExpr(p: *P, binding: Binding, allocator: Allocator) bun.OOM!Expr {
            switch (binding.data) {
                .b_identifier => |ident| {
                    return p.newExpr(E.Identifier{ .ref = ident.ref }, binding.loc);
                },
                .b_array => |arr| {
                    const items = try allocator.alloc(Expr, arr.items.len);
                    errdefer allocator.free(items);
                    for (arr.items, 0..) |item, i| {
                        const expr = try convertBindingToExpr(p, item.binding, allocator);
                        // Check for spread pattern: if has_spread and this is the last element
                        if (arr.has_spread and i == arr.items.len - 1) {
                            items[i] = p.newExpr(E.Spread{ .value = expr }, expr.loc);
                        } else if (item.default_value) |default_val| {
                            items[i] = p.newExpr(E.Binary{
                                .op = .bin_assign,
                                .left = expr,
                                .right = default_val,
                            }, item.binding.loc);
                        } else {
                            items[i] = expr;
                        }
                    }
                    return p.newExpr(E.Array{
                        .items = ExprNodeList.fromOwnedSlice(items),
                        .is_single_line = arr.is_single_line,
                    }, binding.loc);
                },
                .b_object => |obj| {
                    const properties = try allocator.alloc(G.Property, obj.properties.len);
                    errdefer allocator.free(properties);
                    for (obj.properties, 0..) |prop, i| {
                        properties[i] = G.Property{
                            .flags = prop.flags,
                            .key = prop.key,
                            // Set kind to .spread if the property has spread flag
                            .kind = if (prop.flags.contains(.is_spread)) .spread else .normal,
                            .value = try convertBindingToExpr(p, prop.value, allocator),
                            .initializer = prop.default_value,
                        };
                    }
                    return p.newExpr(E.Object{
                        .properties = G.Property.List.fromOwnedSlice(properties),
                        .is_single_line = obj.is_single_line,
                    }, binding.loc);
                },
                .b_missing => {
                    return p.newExpr(E.Missing{}, binding.loc);
                },
            }
        }
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ListManaged = std.array_list.Managed;

const bun = @import("bun");
const logger = bun.logger;

const js_ast = bun.ast;
const B = js_ast.B;
const Binding = js_ast.Binding;
const E = js_ast.E;
const Expr = js_ast.Expr;
const ExprNodeList = js_ast.ExprNodeList;
const S = js_ast.S;
const Stmt = js_ast.Stmt;

const G = js_ast.G;
const Decl = G.Decl;
