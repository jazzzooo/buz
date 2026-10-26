//! Manifest-wide plans and the assembled IR.
const mod_cpp_facts = @import("cpp_facts.zig");
const mod_plan_parts = @import("plan_parts.zig");
const mod_typescript = @import("typescript.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const plans = @import("plans.zig");
const cpp_types = mod_cpp_facts.Types;
const structural = @import("../structural.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

fn UniqueList(comptime T: type) type {
    return struct {
        values: structural.OrderedMap(T, void) = .empty,

        fn add(list: *@This(), n: *Normalizer, value: T) Error!void {
            try list.values.put(n.arena, value, {});
        }

        fn slice(list: *const @This()) []const T {
            return list.values.keys();
        }
    };
}

const StringList = UniqueList([]const u8);
const SourceDependencies = UniqueList(ir.CppSourceDependency);
const CppDeclarations = UniqueList(ir.CppDeclarationId);

fn bindingTypes(n: *const Normalizer) []const ir.Type {
    return n.types.items[0..n.binding_type_count];
}

/// Checks the manifest-wide rules normalization alone can decide.
pub fn validate(n: *Normalizer) Error!void {
    var catalog_count: usize = 0;
    var registry_count: usize = 0;
    for (bindingTypes(n)) |t| {
        if (t.data != .enumeration) continue;
        switch (n.get(t.data.enumeration).header) {
            .error_codes => catalog_count += 1,
            .internal_modules => registry_count += 1,
            .shared => {},
        }
    }
    if (catalog_count > 1) try n.fail("", "the engine supports one error code catalog", .{});
    if (registry_count > 1) try n.fail("", "the engine supports one internal module registry", .{});
}

pub fn assemble(n: *Normalizer) Error!ir.Ir {
    const modules = try n.arena.alloc(ir.Module, n.modules.len);
    var structured_clone_modules: std.ArrayList(ir.ModuleId) = .empty;
    for (n.modules, modules, 0..) |module, *normalized, index| {
        const function_offset = n.function_module_offsets[index];
        const class_offset = n.class_module_offsets[index];
        const declarations = try n.arena.alloc(ir.FunctionId, module.functions.len);
        for (declarations, 0..) |*id, offset| id.* = .of(function_offset + offset);
        const class_declarations = try n.arena.alloc(ir.ClassId, module.classes.len);
        for (class_declarations, 0..) |*id, offset| id.* = .of(class_offset + offset);
        const engine_declarations = try n.arena.alloc(ir.EngineShimId, module.engine_shims.len);
        for (engine_declarations, 0..) |*id, offset| id.* = .of(n.engine_shim_module_offsets[index] + offset);
        const native_declarations = try n.arena.alloc(ir.NativeExportId, module.native_exports.len);
        for (native_declarations, 0..) |*id, offset| id.* = .of(n.native_export_module_offsets[index] + offset);
        const integrations = try n.arena.alloc(ir.FocusedEngineIntegration, module.focused_integrations.len);
        for (module.focused_integrations, integrations) |integration, *normalized_integration| {
            normalized_integration.* = .{ .integration_name = integration.name, .integration_options = integration.options };
        }
        var clones: std.ArrayList(ir.StructuredCloneId) = .empty;
        var reverse = std.mem.reverseIterator(class_declarations);
        while (reverse.next()) |id| {
            const class = n.classes.items[id.index];
            if (class.exposed) if (class.structured_clone) |clone| try clones.append(n.arena, clone);
        }
        if (clones.items.len != 0) try structured_clone_modules.append(n.arena, .of(index));
        normalized.* = .{
            .module_name = module.name,
            .source_stem = n.source_stems[index],
            .declarations = declarations,
            .class_declarations = class_declarations,
            .engine_declarations = engine_declarations,
            .native_declarations = native_declarations,
            .structured_clones = clones.items,
            .focused_integrations = integrations,
        };
    }
    // Schema order places parent classes before their children.
    std.mem.reverse(ir.ModuleId, structured_clone_modules.items);

    var error_catalog: ?ir.ErrorCodeCatalog = null;
    var cpp_resources: std.ArrayList(ir.CppResource) = .empty;
    var header_declarations: CppDeclarations = .{};
    var external_declaration_headers: StringList = .{};
    var source_dependencies: SourceDependencies = .{};
    var promise_reaction_contexts: std.ArrayList(ir.PromiseReactionId) = .empty;
    var enumeration_strings: StringList = .{};
    for (bindingTypes(n)) |t| {
        switch (t.data) {
            .enumeration => |id| {
                const enumeration = n.get(id);
                if (enumeration.header == .error_codes) error_catalog = try errorCodeCatalog(n, id, n.rawType(t.id).enumeration);
                for (enumeration.enumeration_values) |value| try enumeration_strings.add(n, value.js_value);
            },
            .external_ref => |id| {
                try cpp_resources.append(n.arena, .{ .external = id });
                const options = n.rawType(t.id).external_ref.options;
                try external_declaration_headers.add(n, options.cpp_declaration_header);
                try source_dependencies.add(n, .{ .header = options.cpp_conversion_header });
                try source_dependencies.add(n, .{ .header = options.cpp_match.header });
            },
            .nominal_handle => |handle| {
                for (n.rawType(t.id).nominal_handle.options.cpp_declarations) |declaration| try header_declarations.add(n, try cpp_types.declaration(n, declaration));
                switch (handle.ownership) {
                    .borrowed => {},
                    .owned => |owner| try cpp_resources.append(n.arena, .{ .nominal = .{
                        .ownership = owner,
                        .native_type = handle.cpp_type,
                        .wire = handle.wire,
                    } }),
                }
            },
            .branded_value => |branded| {
                if (branded.promise_reaction) |reaction| try promise_reaction_contexts.append(n.arena, reaction);
            },
            else => {},
        }
    }

    var cpp_header_classes: std.ArrayList(ir.ClassId) = .empty;
    var engine_classes: std.ArrayList(ir.ClassId) = .empty;
    var engine_class_headers: StringList = .{};
    for (n.class_declaration_order) |id| {
        switch (n.class_relations[id.index].emission.declaration) {
            .none, .source => continue,
            .bindings_header => {
                try cpp_header_classes.append(n.arena, id);
                continue;
            },
            .engine_header => try engine_classes.append(n.arena, id),
        }
        const options = n.declared_classes.items[id.index].class.options;
        if (options.parent) |parent| switch (parent) {
            .engine => |engine| try engine_class_headers.add(n, engine.header),
            .class => {},
        };
        if (options.engine_native) |native| try engine_class_headers.add(n, native.header);
    }

    try sourceTypeDependencies(n, &source_dependencies);
    const standalone_headers = try standaloneHeaderPlans(n);
    const complete = try mod_plan_parts.finish(n);
    const typescript_types = try n.arena.alloc([]const u8, n.type_projections.len);
    for (n.type_projections, typescript_types) |projection, *value| value.* = projection.typescript;
    const derived = .{
        .abi = ir.generator_abi_version,
        .target = n.input.target,
        .features = n.input.features,
        .modules = modules,
        .cpp_resources = cpp_resources.items,
        .typescript_types = typescript_types,
        .typescript_declarations = try mod_typescript.typeDeclarations(n),
        .type_plans = try plans.apiPositions(n),
        .cpp_header_declarations = header_declarations.slice(),
        .inbound_argument_plans = complete.inbound_argument,
        .inbound_result_plans = complete.inbound_result,
        .outbound_argument_plans = complete.outbound_argument,
        .outbound_result_plans = complete.outbound_result,
        .structured_clone_modules = structured_clone_modules.items,
        .cpp_header_classes = cpp_header_classes.items,
        .error_catalog = error_catalog,
        .internal_module_registry = try internalModuleRegistry(n),
        .external_ref_declaration_headers = external_declaration_headers.slice(),
        .cpp_source_dependencies = source_dependencies.slice(),
        .private_symbols = try privateSymbols(n),
        .standalone_native_export_header_plans = standalone_headers,
        .promise_reaction_contexts = promise_reaction_contexts.items,
        .engine_classes = engine_classes.items,
        .engine_class_headers = engine_class_headers.slice(),
        .interned_property_keys = try internedPropertyKeys(n),
        .enumeration_strings = enumeration_strings.slice(),
    };
    var result: ir.Ir = undefined;
    inline for (@typeInfo(ir.Ir).@"struct".field_names) |name| {
        if (comptime @hasField(@TypeOf(derived), name)) {
            @field(result, name) = @field(derived, name);
        } else {
            const source = @field(n, name);
            const Field = @FieldType(ir.Ir, name);
            @field(result, name) = if (@TypeOf(source) == Field)
                source
            else if (@TypeOf(source) == std.ArrayList(std.meta.Elem(Field)))
                source.items
            else if (@TypeOf(source) == structural.OrderedMap(std.meta.Elem(Field), void))
                source.keys()
            else
                @compileError("unhandled normalized IR field: " ++ name);
        }
    }
    return result;
}

// ─── internal module registry ───

fn errorCodeCatalog(n: *Normalizer, id: ir.EnumerationId, declaration: *const schema.Enumeration) Error!ir.ErrorCodeCatalog {
    const enumeration = n.get(id);
    const codes = try n.arena.alloc(ir.ErrorCodeEntry, enumeration.enumeration_values.len);
    for (enumeration.enumeration_values, declaration.values, codes) |value, raw, *code| {
        const options = raw.options.error_code.?;
        code.* = .{
            .tag = value.value_name,
            .value = value.native_value,
            .class = options.class,
            .code = options.code,
            .name_override = options.name,
        };
    }
    return .{ .enumeration = id, .codes = codes };
}

fn internalModuleSourceURL(n: *Normalizer, path: []const u8) Error![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(n.arena, "builtin://");
    const prefix = bytes.items.len;
    for (path[0 .. path.len - 3]) |byte| {
        const next = if (std.ascii.isAlphanumeric(byte)) byte else '/';
        if (next == '/' and bytes.items.len > prefix and bytes.items[bytes.items.len - 1] == '/') continue;
        try bytes.append(n.arena, next);
    }
    return bytes.items;
}

fn internalModuleRegistry(n: *Normalizer) Error!?ir.InternalModuleRegistry {
    const registry_id = for (bindingTypes(n), 0..) |t, id| {
        if (t.data == .enumeration and n.get(t.data.enumeration).header == .internal_modules) break id;
    } else return null;
    const enumeration_id = n.types.items[registry_id].data.enumeration;
    const enumeration = n.get(enumeration_id);
    const declaration = n.rawType(.of(registry_id)).enumeration;
    const entries = try n.arena.alloc(ir.InternalModuleEntry, enumeration.enumeration_values.len);
    var javascript_count: u32 = 0;
    for (enumeration.enumeration_values, declaration.values, entries) |value, raw, *entry| {
        const source = raw.options.internal_module.?;
        entry.* = .{
            .default_export = raw.options.internal_module_default,
            .id = value.native_value,
            .name = value.value_name,
            .specifier = value.js_value,
            .aliases = raw.options.aliases,
            .source = switch (source) {
                .javascript => |path| javascript: {
                    javascript_count += 1;
                    break :javascript .{ .javascript = .{
                        .path = path,
                        .bundle_path = try n.print("{s}.js", .{path[0 .. path.len - 3]}),
                        .url = try internalModuleSourceURL(n, path),
                    } };
                },
                .native => .{ .native = for (n.native_module_surfaces.items, 0..) |surface, surface_index| {
                    if (surface.exposed and std.mem.eql(u8, surface.specifier, value.js_value)) break ir.NativeModuleSurfaceId.of(surface_index);
                } else unreachable },
            },
        };
    }
    return .{ .enumeration = enumeration_id, .modules = entries, .javascript_count = javascript_count };
}

fn sourceTypeDependencies(n: *Normalizer, dependencies: *SourceDependencies) Error!void {
    for (bindingTypes(n)) |t| switch (t.data) {
        .nominal_handle => if (n.rawType(t.id).nominal_handle.options.cpp_header) |header| try dependencies.add(n, .{ .header = header }),
        .external_ref => |id| if (n.get(id).brand) |brand| try dependencies.add(n, .{ .brand_match = brand.cpp_match }),
        .branded_value => |branded| try dependencies.add(n, .{ .brand_match = branded.brand.cpp_match }),
        .sequence => if (n.type_metadata.items[t.id.index].sequence_container_match) |matcher| try dependencies.add(n, .{ .brand_match = matcher }),
        .node_path => try dependencies.add(n, .type_predicates),
        else => {},
    };
    for (n.classes.items) |class| {
        if (class.exposed) if (class.brand) |brand| try dependencies.add(n, .{ .brand_match = brand.cpp_match });
    }
    for (n.cpp_converter_declarations.keys()) |declaration| switch (declaration.body) {
        .external => {},
        .brand_cast => |cast| try dependencies.add(n, .{ .brand_match = cast.brand }),
    };
}

// ─── strings ───

fn privateSymbols(n: *Normalizer) Error![]const []const u8 {
    var symbols: StringList = .{};
    for (n.classes.items) |class| {
        if (!class.exposed) continue;
        const raw = n.declared_classes.items[class.id.index].class;
        for (raw.instance_properties) |property| if (property.options.private_symbol) |symbol| try symbols.add(n, symbol);
        for (raw.slots) |slot| if (slot.options.exposed) if (slot.options.private_symbol) |symbol| try symbols.add(n, symbol);
        for (class.declarations) |id| {
            const member = n.functions.items[id.index];
            if (member.exposed) if (n.declaration(member.id).member.?.raw.options.private_symbol) |symbol| try symbols.add(n, symbol);
        }
    }
    return symbols.slice();
}

fn addFunctionKeys(n: *Normalizer, keys: *StringList, function: ir.Function) Error!void {
    try keys.add(n, function.js_name);
    if (n.declaration(function.id).member) |member| for (member.raw.options.aliases) |alias| {
        try addPropertyKey(n, keys, alias.key);
    };
}

fn addPropertyKey(n: *Normalizer, keys: *StringList, key: anytype) Error!void {
    switch (key) {
        .name => |name| try keys.add(n, name),
        else => {},
    }
}

fn internedPropertyKeys(n: *Normalizer) Error![]const []const u8 {
    var keys: StringList = .{};
    try keys.add(n, "info");
    for (bindingTypes(n)) |t| switch (t.data) {
        .dictionary => for (n.rawType(t.id).dictionary.fields) |raw| {
            try keys.add(n, raw.propertyName());
            for (raw.options.aliases) |alias| try keys.add(n, alias);
        },
        .union_type => if (n.rawType(t.id).union_type.options.input_tag) |tag| {
            try keys.add(n, tag.tag_property);
            if (tag.value_property) |property| try keys.add(n, property);
        },
        else => {},
    };
    for (n.functions.items) |function| try addFunctionKeys(n, &keys, function);
    for (n.classes.items) |class| {
        for (n.declared_classes.items[class.id.index].class.properties) |property| try addPropertyKey(n, &keys, property.key);
        for (class.instance_properties) |property| try keys.add(n, property.property_name);
        for (class.slots) |slot| try keys.add(n, slot.slot_name);
    }
    for (n.native_module_surfaces.items) |surface| {
        for (surface.exports) |module_export| {
            try keys.add(n, module_export.export_name);
            for (module_export.aliases) |alias| try keys.add(n, alias.name);
        }
    }
    for (n.object_surfaces.items) |surface| {
        for (surface.members) |member| {
            try addPropertyKey(n, &keys, member.property_key);
            for (member.aliases) |alias| try addPropertyKey(n, &keys, alias.key);
        }
    }
    return keys.slice();
}

// ─── standalone native export headers ───

fn markNativeTypes(n: *const Normalizer, used: []bool, id: ir.TypeId) void {
    if (used[id.index]) return;
    used[id.index] = true;
    switch (n.irType(id).data) {
        .lazy => |child| markNativeTypes(n, used, child),
        .optional => |optional| markNativeTypes(n, used, optional.child),
        .sequence => |sequence| markNativeTypes(n, used, sequence.child),
        .converted => |converted| markNativeTypes(n, used, converted.native_type),
        .dictionary => |dictionary| for (dictionary.dictionary_fields) |field| markNativeTypes(n, used, field.field_type),
        .union_type => |union_type| for (union_type.union_members) |member| markNativeTypes(n, used, member.member_type),
        .record => |record| {
            markNativeTypes(n, used, record.key_type);
            markNativeTypes(n, used, record.value_type);
        },
        else => {},
    }
}

fn standaloneHeaderPlans(n: *Normalizer) Error![]const ir.StandaloneNativeExportHeaderPlan {
    var headers: structural.OrderedMap([]const u8, std.ArrayList(ir.NativeExportId)) = .empty;
    for (n.native_exports.items) |native_export| {
        const header = n.rawNativeExport(native_export.id).options.standalone_header orelse continue;
        const entry = try headers.getOrPut(n.arena, header);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        if (native_export.exposed) try entry.value_ptr.append(n.arena, native_export.id);
    }
    const result = try n.arena.alloc(ir.StandaloneNativeExportHeaderPlan, headers.count());
    if (result.len == 0) return result;
    const used = try n.arena.alloc(bool, n.types.items.len);
    defer n.arena.free(used);
    for (headers.keys(), headers.values(), result) |header, exports, *header_plan| {
        @memset(used, false);
        for (exports.items) |export_id| {
            const native_export = n.get(export_id);
            markNativeTypes(n, used, n.get(native_export.result_position).type);
            for (native_export.args) |argument| markNativeTypes(n, used, n.get(argument.position).type);
        }
        var declarations: CppDeclarations = .{};
        for (bindingTypes(n)) |t| {
            if (!used[t.id.index]) continue;
            const raw = switch (n.rawType(t.id)) {
                .nominal_handle => |handle| handle.options.cpp_declarations,
                else => continue,
            };
            for (raw) |declaration| try declarations.add(n, try cpp_types.declaration(n, declaration));
        }
        header_plan.* = .{ .header = header, .exports = exports.items, .nominal_handle_declarations = declarations.slice() };
    }
    return result;
}
