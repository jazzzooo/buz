last_part: *js_ast.Part,
// files in node modules will not get hot updates, so the code generation
// can be a bit more concise for re-exports
is_in_node_modules: bool,
imports_seen: std.HashMapUnmanaged(ImportKey, ImportRef, ImportKey.Context, std.hash_map.default_max_load_percentage) = .empty,
export_star_props: std.ArrayListUnmanaged(G.Property) = .empty,
export_props: std.ArrayListUnmanaged(G.Property) = .empty,
stmts: std.ArrayListUnmanaged(Stmt) = .empty,

pub fn deinit(ctx: *ConvertESMExportsForHmr, allocator: std.mem.Allocator) void {
    ctx.imports_seen.deinit(allocator);
    ctx.export_star_props.deinit(allocator);
    ctx.export_props.deinit(allocator);
    ctx.stmts.deinit(allocator);
}

const ImportRef = struct {
    /// Index into ConvertESMExportsForHmr.stmts
    stmt_index: u32,
};

const ImportKey = struct {
    path: []const u8,
    namespace: []const u8,
    kind: bun.ImportKind,
    tag: ImportRecord.Tag,
    loader: ?bun.options.Loader,
    source_index: u32,
    flags: u16,
    is_disabled: bool,
    is_symlink: bool,

    fn init(record: ImportRecord) ImportKey {
        var flags = record.flags;
        flags.is_unused = false;
        flags.contains_import_star = false;
        flags.contains_default_alias = false;
        flags.contains_es_module_alias = false;
        flags.calls_runtime_re_export_fn = false;
        flags.was_originally_bare_import = false;
        flags.was_injected_by_macro = false;
        return .{
            .path = record.path.text,
            .namespace = record.path.namespace,
            .kind = record.kind,
            .tag = record.tag,
            .loader = record.loader,
            .source_index = record.source_index.get(),
            .flags = @bitCast(flags),
            .is_disabled = record.path.is_disabled,
            .is_symlink = record.path.is_symlink,
        };
    }

    const Context = struct {
        pub fn hash(_: @This(), key: ImportKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key.path.len);
            hasher.update(key.path);
            std.hash.autoHash(&hasher, key.namespace.len);
            hasher.update(key.namespace);
            std.hash.autoHash(&hasher, .{ key.kind, key.tag, key.loader, key.source_index, key.flags, key.is_disabled, key.is_symlink });
            return hasher.final();
        }

        pub fn eql(_: @This(), a: ImportKey, b: ImportKey) bool {
            return strings.eql(a.path, b.path) and strings.eql(a.namespace, b.namespace) and
                a.kind == b.kind and a.tag == b.tag and a.loader == b.loader and
                a.source_index == b.source_index and a.flags == b.flags and
                a.is_disabled == b.is_disabled and a.is_symlink == b.is_symlink;
        }
    };
};

const DeduplicatedImportResult = struct {
    namespace_ref: Ref,
    import_record_index: u32,
};

test "HMR import identity preserves resolution and loader distinctions" {
    const allocator = std.testing.allocator;
    var imports: @FieldType(ConvertESMExportsForHmr, "imports_seen") = .empty;
    defer imports.deinit(allocator);
    const record = ImportRecord{ .range = .None, .path = bun.fs.Path.init("./value"), .kind = .stmt };
    const key = ImportKey.init(record);
    try imports.put(allocator, key, .{ .stmt_index = 0 });

    const copied_path = try allocator.dupe(u8, record.path.text);
    defer allocator.free(copied_path);
    var same = record;
    same.path.text = copied_path;
    same.flags.contains_import_star = true;
    same.flags.contains_default_alias = true;
    same.flags.is_unused = true;
    try std.testing.expectEqual(@as(u32, 0), imports.get(ImportKey.init(same)).?.stmt_index);

    var other = key;
    other.loader = .text;
    try imports.put(allocator, other, .{ .stmt_index = 1 });
    other = key;
    other.namespace = "plugin";
    try imports.put(allocator, other, .{ .stmt_index = 2 });
    other = key;
    other.source_index = 7;
    try imports.put(allocator, other, .{ .stmt_index = 3 });
    other = key;
    other.tag = .bake_resolve_to_ssr_graph;
    try imports.put(allocator, other, .{ .stmt_index = 4 });
    try std.testing.expectEqual(@as(u32, 5), imports.count());
    try std.testing.expectEqual(@as(u32, 0), imports.get(key).?.stmt_index);
}

pub fn convertStmt(ctx: *ConvertESMExportsForHmr, p: anytype, stmt: Stmt) !void {
    const new_stmt = switch (stmt.data) {
        else => brk: {
            break :brk stmt;
        },
        .s_local => |st| stmt: {
            if (!st.is_export) {
                break :stmt stmt;
            }

            st.is_export = false;

            var new_len: usize = 0;
            for (st.decls.slice()) |*decl_ptr| {
                const decl = decl_ptr.*; // explicit copy to avoid aliasinng
                const value = decl.value orelse {
                    st.decls.mut(new_len).* = decl;
                    new_len += 1;
                    try ctx.visitBindingToExport(p, decl.binding);
                    continue;
                };

                switch (decl.binding.data) {
                    .b_missing => {},

                    .b_identifier => |id| {
                        const symbol = p.symbols.items[id.ref.inner_index];

                        // if the symbol is not used, we don't need to preserve
                        // a binding in this scope. we can move it to the exports object.
                        if (symbol.use_count_estimate == 0 and value.canBeMoved()) {
                            try ctx.export_props.append(p.allocator, .{
                                .key = Expr.init(E.String, .{ .data = symbol.original_name }, decl.binding.loc),
                                .value = value,
                            });
                        } else {
                            st.decls.mut(new_len).* = decl;
                            new_len += 1;
                            try ctx.visitBindingToExport(p, decl.binding);
                        }
                    },

                    else => {
                        st.decls.mut(new_len).* = decl;
                        new_len += 1;
                        try ctx.visitBindingToExport(p, decl.binding);
                    },
                }
            }
            if (new_len == 0) {
                return;
            }
            st.decls.len = @intCast(new_len);

            break :stmt stmt;
        },
        .s_export_default => |st| stmt: {
            // When React Fast Refresh needs to tag the default export, the statement
            // cannot be moved, since a local reference is required.
            if (p.options.features.react_fast_refresh and
                st.value == .stmt and st.value.stmt.data == .s_function)
            fast_refresh_edge_case: {
                const symbol = st.value.stmt.data.s_function.func.name orelse
                    break :fast_refresh_edge_case;
                const name = p.symbols.items[symbol.ref.?.inner_index].original_name;
                if (ReactRefresh.isComponentishName(name)) {
                    // Lower to a function statement, and reference the function in the export list.
                    try ctx.export_props.append(p.allocator, .{
                        .key = Expr.init(E.String, .{ .data = "default" }, stmt.loc),
                        .value = Expr.initIdentifier(symbol.ref.?, stmt.loc),
                    });
                    break :stmt st.value.stmt;
                }
                // All other functions can be properly moved.
            }

            // Try to move the export default expression to the end.
            const can_be_moved_to_inner_scope = switch (st.value) {
                .stmt => |s| switch (s.data) {
                    .s_class => |c| c.class.canBeMoved() and (if (c.class.class_name) |name|
                        p.symbols.items[name.ref.?.inner_index].use_count_estimate == 0
                    else
                        true),
                    .s_function => |f| if (f.func.name) |name|
                        p.symbols.items[name.ref.?.inner_index].use_count_estimate == 0
                    else
                        true,
                    else => unreachable,
                },
                .expr => |e| switch (e.data) {
                    .e_identifier => true,
                    else => e.canBeMoved(),
                },
            };
            if (can_be_moved_to_inner_scope) {
                try ctx.export_props.append(p.allocator, .{
                    .key = Expr.init(E.String, .{ .data = "default" }, stmt.loc),
                    .value = st.value.toExpr(),
                });
                // no statement emitted
                return;
            }

            // Otherwise, an identifier must be exported
            switch (st.value) {
                .expr => {
                    const temp_id = p.generateTempRef("default_export");
                    try ctx.last_part.declared_symbols.append(p.allocator, .{ .ref = temp_id, .is_top_level = true });
                    try ctx.last_part.symbol_uses.putNoClobber(p.allocator, temp_id, .{ .count_estimate = 1 });

                    try ctx.export_props.append(p.allocator, .{
                        .key = Expr.init(E.String, .{ .data = "default" }, stmt.loc),
                        .value = Expr.initIdentifier(temp_id, stmt.loc),
                    });

                    break :stmt Stmt.alloc(S.Local, .{
                        .kind = .k_const,
                        .decls = try G.Decl.List.fromSlice(p.allocator, &.{
                            .{
                                .binding = Binding.alloc(p.allocator, B.Identifier{ .ref = temp_id }, stmt.loc),
                                .value = st.value.toExpr(),
                            },
                        }),
                    }, stmt.loc);
                },
                .stmt => |s| {
                    try ctx.export_props.append(p.allocator, .{
                        .key = Expr.init(E.String, .{ .data = "default" }, stmt.loc),
                        .value = Expr.initIdentifier(switch (s.data) {
                            .s_class => |class| class.class.class_name.?.ref.?,
                            .s_function => |func| func.func.name.?.ref.?,
                            else => unreachable,
                        }, stmt.loc),
                    });
                    break :stmt s;
                },
            }
        },
        .s_class => |st| stmt: {

            // Strip the "export" keyword
            if (!st.is_export) {
                break :stmt stmt;
            }

            // Export as CommonJS
            try ctx.export_props.append(p.allocator, .{
                .key = Expr.init(E.String, .{
                    .data = p.symbols.items[st.class.class_name.?.ref.?.inner_index].original_name,
                }, stmt.loc),
                .value = Expr.initIdentifier(st.class.class_name.?.ref.?, stmt.loc),
            });

            st.is_export = false;

            break :stmt stmt;
        },
        .s_function => |st| stmt: {
            // Strip the "export" keyword
            if (!st.func.flags.contains(.is_export)) break :stmt stmt;

            st.func.flags.remove(.is_export);

            try ctx.visitRefToExport(
                p,
                st.func.name.?.ref.?,
                null,
                stmt.loc,
                false,
            );

            break :stmt stmt;
        },
        .s_export_clause => |st| {
            for (st.items) |item| {
                const ref = item.name.ref.?;
                try ctx.visitRefToExport(p, ref, item.alias, item.name.loc, false);
            }

            return; // do not emit a statement here
        },
        .s_export_from => |st| {
            const import_items = try p.allocator.alloc(js_ast.ClauseItem, st.items.len);
            errdefer p.allocator.free(import_items);
            for (st.items, import_items) |item, *import_item| {
                import_item.* = .{
                    .alias = item.original_name,
                    .alias_loc = item.name.loc,
                    .name = item.name,
                    .original_name = p.symbols.items[item.name.ref.?.innerIndex()].original_name,
                };
            }
            const deduped = try ctx.deduplicatedImport(
                p,
                st.import_record_index,
                st.namespace_ref,
                import_items,
                stmt.loc,
                null,
                stmt.loc,
            );
            for (st.items) |item| {
                const ref = item.name.ref.?;
                const symbol = &p.symbols.items[ref.innerIndex()];
                // Always set the namespace alias using the deduplicated import
                // record. When two `export { ... } from` statements reference
                // the same source, the second import record is marked unused
                // and its items are merged into the first. The symbols may
                // already have a namespace_alias from ImportScanner pointing at
                // the now-unused record, so we must update it.
                symbol.namespace_alias = .{
                    .namespace_ref = deduped.namespace_ref,
                    .alias = item.original_name,
                    .import_record_index = deduped.import_record_index,
                };
                try ctx.visitRefToExport(
                    p,
                    ref,
                    item.alias,
                    item.name.loc,
                    !ctx.is_in_node_modules, // live binding when this may be replaced
                );
            }
            return;
        },
        .s_export_star => |st| {
            const deduped = try ctx.deduplicatedImport(
                p,
                st.import_record_index,
                st.namespace_ref,
                &.{},
                stmt.loc,
                null,
                stmt.loc,
            );

            if (st.alias) |alias| {
                // 'export * as ns from' creates one named property.
                try ctx.export_props.append(p.allocator, .{
                    .key = Expr.init(E.String, .{ .data = alias.original_name }, stmt.loc),
                    .value = Expr.initIdentifier(deduped.namespace_ref, stmt.loc),
                });
            } else {
                // 'export * from' creates a spread, hoisted at the top.
                try ctx.export_star_props.append(p.allocator, .{
                    .kind = .spread,
                    .value = Expr.initIdentifier(deduped.namespace_ref, stmt.loc),
                });
            }
            return;
        },
        // De-duplicate import statements. It is okay to disregard
        // named/default imports here as we always rewrite them as
        // full qualified property accesses (needed for live-bindings)
        .s_import => |st| {
            _ = try ctx.deduplicatedImport(
                p,
                st.import_record_index,
                st.namespace_ref,
                st.items,
                st.star_name_loc,
                st.default_name,
                stmt.loc,
            );
            return;
        },
    };

    try ctx.stmts.append(p.allocator, new_stmt);
}

/// Deduplicates imports, returning a previously used Ref and import record
/// index if present.
fn deduplicatedImport(
    ctx: *ConvertESMExportsForHmr,
    p: anytype,
    import_record_index: u32,
    namespace_ref: Ref,
    items: []js_ast.ClauseItem,
    star_name_loc: ?logger.Loc,
    default_name: ?js_ast.LocRef,
    loc: logger.Loc,
) !DeduplicatedImportResult {
    const ir = &p.import_records.items[import_record_index];
    const key = ImportKey.init(ir.*);
    if (ctx.imports_seen.get(key)) |existing| {
        const stmt = ctx.stmts.items[existing.stmt_index].data.s_import;
        const merged_items = if (items.len == 0)
            stmt.items
        else if (stmt.items.len == 0)
            items
        else
            try std.mem.concat(p.allocator, js_ast.ClauseItem, &.{ stmt.items, items });
        // Disable this one since an older record is getting used.  It isn't
        // practical to delete this import record entry since an import or
        // require expression can exist.
        const surviving_record = &p.import_records.items[stmt.import_record_index];
        surviving_record.flags.contains_import_star = surviving_record.flags.contains_import_star or ir.flags.contains_import_star;
        surviving_record.flags.contains_default_alias = surviving_record.flags.contains_default_alias or ir.flags.contains_default_alias;
        surviving_record.flags.contains_es_module_alias = surviving_record.flags.contains_es_module_alias or ir.flags.contains_es_module_alias;
        surviving_record.flags.calls_runtime_re_export_fn = surviving_record.flags.calls_runtime_re_export_fn or ir.flags.calls_runtime_re_export_fn;
        surviving_record.flags.was_originally_bare_import = surviving_record.flags.was_originally_bare_import or ir.flags.was_originally_bare_import;
        surviving_record.flags.was_injected_by_macro = surviving_record.flags.was_injected_by_macro or ir.flags.was_injected_by_macro;
        ir.flags.is_unused = true;

        // The surviving record may have been marked is_unused by barrel
        // optimization (when the first export-from statement's exports
        // were all deferred). Since we are merging new items into it,
        // clear is_unused so the import is actually emitted.
        surviving_record.flags.is_unused = false;

        stmt.items = merged_items;
        if (namespace_ref.isValid()) {
            if (!stmt.namespace_ref.isValid()) {
                stmt.namespace_ref = namespace_ref;
            } else if (!stmt.namespace_ref.eql(namespace_ref)) {
                // Erase this namespace ref, but since it may be used in
                // existing AST trees, a link must be established.
                const symbol = &p.symbols.items[namespace_ref.innerIndex()];
                symbol.use_count_estimate = 0;
                symbol.link = stmt.namespace_ref;
                if (@hasField(@typeInfo(@TypeOf(p)).pointer.child, "symbol_uses")) {
                    _ = p.symbol_uses.swapRemove(namespace_ref);
                }
            }
        }
        if (stmt.star_name_loc == null) if (star_name_loc) |stl| {
            stmt.star_name_loc = stl;
        };
        if (stmt.default_name == null) if (default_name) |dn| {
            stmt.default_name = dn;
        };
        return .{ .namespace_ref = stmt.namespace_ref, .import_record_index = stmt.import_record_index };
    }

    const stmt_index = std.math.cast(u32, ctx.stmts.items.len) orelse return error.OutOfMemory;
    try ctx.imports_seen.ensureUnusedCapacity(p.allocator, 1);
    try ctx.stmts.ensureUnusedCapacity(p.allocator, 1);
    const stmt = Stmt.alloc(S.Import, .{
        .import_record_index = import_record_index,
        .is_single_line = true,
        .default_name = default_name,
        .items = items,
        .namespace_ref = namespace_ref,
        .star_name_loc = star_name_loc,
    }, loc);

    ctx.stmts.appendAssumeCapacity(stmt);
    ctx.imports_seen.putAssumeCapacityNoClobber(key, .{ .stmt_index = stmt_index });
    return .{ .namespace_ref = namespace_ref, .import_record_index = import_record_index };
}

fn visitBindingToExport(ctx: *ConvertESMExportsForHmr, p: anytype, binding: Binding) !void {
    switch (binding.data) {
        .b_missing => {},
        .b_identifier => |id| {
            try ctx.visitRefToExport(p, id.ref, null, binding.loc, false);
        },
        .b_array => |array| {
            for (array.items) |item| {
                try ctx.visitBindingToExport(p, item.binding);
            }
        },
        .b_object => |object| {
            for (object.properties) |item| {
                try ctx.visitBindingToExport(p, item.value);
            }
        },
    }
}

fn visitRefToExport(
    ctx: *ConvertESMExportsForHmr,
    p: anytype,
    ref: Ref,
    export_symbol_name: ?[]const u8,
    loc: logger.Loc,
    is_live_binding_source: bool,
) !void {
    const symbol = p.symbols.items[ref.inner_index];
    const id = if (symbol.kind == .import)
        Expr.init(E.ImportIdentifier, .{ .ref = ref }, loc)
    else
        Expr.initIdentifier(ref, loc);
    if (is_live_binding_source or (symbol.kind == .import and !ctx.is_in_node_modules) or symbol.has_been_assigned_to) {
        const key = Expr.init(E.String, .{
            .data = export_symbol_name orelse symbol.original_name,
        }, loc);

        // 'get abc() { return abc }'
        try ctx.export_props.append(p.allocator, .{
            .kind = .get,
            .key = key,
            .value = Expr.init(E.Function, .{ .func = .{
                .body = .{
                    .stmts = try p.allocator.dupe(Stmt, &.{
                        Stmt.alloc(S.Return, .{ .value = id }, loc),
                    }),
                    .loc = loc,
                },
            } }, loc),
        });
        // no setter is added since live bindings are read-only
    } else {
        // 'abc,'
        try ctx.export_props.append(p.allocator, .{
            .key = Expr.init(E.String, .{
                .data = export_symbol_name orelse symbol.original_name,
            }, loc),
            .value = id,
        });
    }
}

pub fn finalize(ctx: *ConvertESMExportsForHmr, p: anytype, all_parts: []js_ast.Part) !void {
    if (ctx.export_star_props.items.len > 0) {
        if (ctx.export_props.items.len == 0) {
            ctx.export_props = ctx.export_star_props;
            ctx.export_star_props = .empty;
        } else {
            try ctx.export_props.insertSlice(p.allocator, 0, ctx.export_star_props.items);
        }
    }

    if (ctx.export_props.items.len > 0) {
        const obj = Expr.init(E.Object, .{
            .properties = G.Property.List.moveFromList(&ctx.export_props),
        }, logger.Loc.Empty);

        // `hmr.exports = ...`
        try ctx.stmts.append(p.allocator, Stmt.alloc(S.SExpr, .{
            .value = Expr.assign(
                Expr.init(E.Dot, .{
                    .target = Expr.initIdentifier(p.hmr_api_ref, logger.Loc.Empty),
                    .name = "exports",
                    .name_loc = logger.Loc.Empty,
                }, logger.Loc.Empty),
                obj,
            ),
        }, logger.Loc.Empty));

        // mark a dependency on module_ref so it is renamed
        try ctx.last_part.symbol_uses.put(p.allocator, p.module_ref, .{ .count_estimate = 1 });
        try ctx.last_part.declared_symbols.append(p.allocator, .{ .ref = p.module_ref, .is_top_level = true });
    }

    if (p.options.features.react_fast_refresh and p.react_refresh.register_used) {
        try ctx.stmts.append(p.allocator, Stmt.alloc(S.SExpr, .{
            .value = Expr.init(E.Call, .{
                .target = Expr.init(E.Dot, .{
                    .target = Expr.initIdentifier(p.hmr_api_ref, .Empty),
                    .name = "reactRefreshAccept",
                    .name_loc = .Empty,
                }, .Empty),
                .args = .empty,
            }, .Empty),
        }, .Empty));
    }

    bun.assert(all_parts.len > 0 and ctx.last_part == &all_parts[all_parts.len - 1]);
    const last_part_index = std.math.cast(u32, all_parts.len - 1) orelse return error.OutOfMemory;
    var declared_count = p.declared_symbols.len();
    var import_count = p.import_records_for_current_part.items.len;
    var use_count: usize = 0;
    for (all_parts[0 .. all_parts.len - 1]) |*part| {
        declared_count = std.math.add(usize, declared_count, part.declared_symbols.len()) catch return error.OutOfMemory;
        import_count = std.math.add(usize, import_count, part.import_record_indices.len) catch return error.OutOfMemory;
        use_count = std.math.add(usize, use_count, part.symbol_uses.count()) catch return error.OutOfMemory;
        try part.dependencies.ensureTotalCapacity(p.allocator, 1);
    }
    try ctx.last_part.declared_symbols.ensureUnusedCapacity(p.allocator, declared_count);
    try ctx.last_part.import_record_indices.ensureUnusedCapacity(p.allocator, import_count);
    try ctx.last_part.symbol_uses.ensureUnusedCapacity(p.allocator, use_count);
    const stmts = try ctx.stmts.toOwnedSlice(p.allocator);

    for (all_parts[0 .. all_parts.len - 1]) |*part| {
        ctx.last_part.declared_symbols.appendListAssumeCapacity(part.declared_symbols);
        ctx.last_part.import_record_indices.appendSliceAssumeCapacity(
            part.import_record_indices.slice(),
        );
        for (part.symbol_uses.keys(), part.symbol_uses.values()) |k, v| {
            const gop = ctx.last_part.symbol_uses.getOrPutAssumeCapacity(k);
            if (!gop.found_existing) {
                gop.value_ptr.* = v;
            } else {
                gop.value_ptr.count_estimate +|= v.count_estimate;
            }
        }
        part.stmts = &.{};
        part.declared_symbols.entries.len = 0;
        part.tag = .dead_due_to_inlining;
        part.dependencies.clearRetainingCapacity();
        part.dependencies.appendAssumeCapacity(.{
            .part_index = last_part_index,
            .source_index = p.source.index,
        });
    }

    ctx.last_part.import_record_indices.appendSliceAssumeCapacity(
        p.import_records_for_current_part.items,
    );
    ctx.last_part.declared_symbols.appendListAssumeCapacity(p.declared_symbols);

    ctx.last_part.stmts = stmts;
    ctx.last_part.tag = .none;
}

const bun = @import("bun");
const strings = bun.strings;
const ImportRecord = bun.ImportRecord;
const logger = bun.logger;

const js_ast = bun.ast;
const B = js_ast.B;
const Binding = js_ast.Binding;
const E = js_ast.E;
const Expr = js_ast.Expr;
const LocRef = js_ast.LocRef;
const S = js_ast.S;
const Stmt = js_ast.Stmt;

const G = js_ast.G;
const Decl = G.Decl;
const Property = G.Property;

const js_parser = bun.js_parser;
const ConvertESMExportsForHmr = js_parser.ConvertESMExportsForHmr;
const ReactRefresh = js_parser.ReactRefresh;
const Ref = js_parser.Ref;
const options = js_parser.options;

const std = @import("std");
const List = std.ArrayListUnmanaged;
