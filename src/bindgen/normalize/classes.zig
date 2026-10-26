//! Classes: surfaces, slots, properties, runtime plans, and engine wrappers.
const mod_cpp_facts = @import("cpp_facts.zig");
const validate = @import("validate.zig");
const mod_typescript = @import("typescript.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const types = @import("types.zig");
const plans = @import("plans.zig");
const structural = @import("../structural.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

pub fn normalizeAll(n: *Normalizer) Error!void {
    const parents = try n.arena.alloc(?ir.ClassId, n.declared_classes.items.len);
    for (n.declared_classes.items, parents) |declared, *parent| parent.* = if (resolveParent(n, declared)) |id| .of(id) else null;
    for (n.declared_classes.items) |declared| {
        try n.classes.append(n.arena, try class(n, declared, parents));
    }
    for (n.classes.items) |normalized| try validateClass(n, normalized);
}

/// The class a parent declaration names: declared in the same module, or
/// in another module of the manifest.
pub fn resolveParent(n: *const Normalizer, declared: Normalizer.DeclaredClass) ?u32 {
    const parent = (declared.class.options.parent orelse return null);
    const parent_class = switch (parent) {
        .class => |class_value| class_value,
        .engine => return null,
    };
    const module = n.modules[declared.module];
    for (module.classes, 0..) |*candidate, index| {
        if (candidate == parent_class or structural.eql(candidate.*, parent_class.*)) return n.class_module_offsets[declared.module] + @as(u32, @intCast(index));
    }
    for (n.modules, 0..) |other, module_index| {
        for (other.classes, 0..) |*candidate, index| {
            if (candidate == parent_class or structural.eql(candidate.*, parent_class.*)) return n.class_module_offsets[module_index] + @as(u32, @intCast(index));
        }
    }
    return null;
}

fn runtimePlan(n: *Normalizer, options: schema.ClassOptions, prefix: []const u8) Error!ir.ClassRuntimePlan {
    return .{
        .ownership = switch (options.representation) {
            .plain => .none,
            .engine => .engine,
            .native => switch (options.ownership) {
                .shared => .{ .native_shared = options.reference_thread },
                .unique => .native_unique,
            },
        },
        .identity = switch (options.representation) {
            .plain => .plain_value,
            .native => switch (options.identity) {
                .fresh => .fresh_wrapper,
                .per_realm => .{ .per_realm_registry = try n.print("{s}_native_generation", .{prefix}) },
            },
            .engine => switch (options.identity) {
                .fresh => .engine_constructor_only,
                .per_realm => .engine_wrapper_cache,
            },
        },
        .finalization = switch (options.representation) {
            .plain => .none,
            .engine => .engine,
            .native => switch (options.last_release) {
                .deferred_vm => .deferred_vm,
                .sweep => .inline_sweep,
            },
        },
        .tracing = .{
            .mode = switch (options.representation) {
                .plain => .none,
                .native => .native_slots,
                .engine => switch (options.engine_tracing) {
                    .inherited => .engine_slots,
                    .additional_children => .engine_slots_and_additional_children,
                },
            },
            .reports_any_thread_native_memory = options.representation == .native and options.memory_usage != null and options.memory_usage.? == .any,
        },
        .construction = .{
            .kind = switch (options.representation) {
                .plain => .plain_object,
                .engine => .engine_intrinsic,
                .native => .native_two_phase,
            },
            .external_initialization = if (options.representation == .native and !options.final) initialization: {
                const symbol = try n.print("{s}_initialize_external_native", .{prefix});
                break :initialization if (options.parent == null) .{ .root_native_subclass = symbol } else .{ .native_subclass = symbol };
            } else .none,
            .wrapper_created = if (options.lifecycle.wrapper_created) try n.print("{s}_wrapper_created", .{prefix}) else null,
        },
    };
}

fn engineClass(n: *Normalizer, declared: Normalizer.DeclaredClass, parents: []const ?ir.ClassId) Error!ir.CppEngineClass {
    const options = declared.class.options;
    const location = try n.print("{s}.{s}", .{ declared.module_name, declared.class.name });
    const parent = options.parent orelse return n.reject(location, "an engine class must declare an engine parent", .{});
    const native = options.engine_native orelse return n.reject(location, "an engine class must declare its engine native type", .{});
    const base_type = switch (parent) {
        .engine => |engine| try mod_cpp_facts.Types.fromSchema(n, engine.cpp_class),
        .class => try n.cppType(.{ .wrapper_class = parents[n.classes.items.len] orelse
            return n.reject(location, "parent class is absent from the binding manifest", .{}) }),
    };
    const cell_kind = cell_kind: {
        var ancestor_index = n.classes.items.len;
        for (0..n.declared_classes.items.len) |_| {
            const ancestor = n.declared_classes.items[ancestor_index];
            const base = ancestor.class.options.parent orelse
                return n.reject(location, "an engine base class must declare an engine parent", .{});
            switch (base) {
                .engine => |engine| break :cell_kind engine.cell_kind,
                .class => ancestor_index = (parents[ancestor_index] orelse
                    return n.reject(location, "parent class is absent from the binding manifest", .{})).index,
            }
        }
        return n.reject(location, "engine class inheritance contains a cycle", .{});
    };
    return .{
        .native_type = try n.cppType(.{ .named = .{ .name = native.cpp_type, .namespace = .global } }),
        .base_type = base_type,
        .cell_kind = cell_kind,
        .estimated_size = options.memory_usage != null,
    };
}

fn structuredClonePlan(n: *Normalizer, class_id: ir.ClassId, prefix: []const u8, options: ?ir.StructuredCloneOptions) Error!?ir.StructuredCloneId {
    const value = options orelse return null;
    const id: ir.StructuredCloneId = .of(n.structured_clones.items.len);
    try n.structured_clones.append(n.arena, .{
        .class = class_id,
        .tag = value.tag,
        .serialization = if (value.shared) |shared| .{ .shared = .{
            .state = shared.state,
            .handle = try n.wires.?.handle(try n.print("{s}_SharedCloneState", .{prefix})),
            .release_symbol = try n.print("{s}_structured_clone_shared_release", .{prefix}),
        } } else .{ .bytes = value.serialize_thread },
        .serialize_symbol = try n.print("{s}_structured_clone_serialize", .{prefix}),
        .deserialize_symbol = try n.print("{s}_structured_clone_deserialize", .{prefix}),
        .transferable = value.transferable,
        .storable = value.storable,
        .unsupported_context = value.unsupported_context,
    });
    return id;
}

pub fn slotCachesMember(n: *const Normalizer, class_: *const ir.Class, slot: ir.CachedSlot) bool {
    for (class_.declarations) |id| {
        const function = n.get(id);
        const member = function.class_member.?;
        const cache_name = n.declaration(function.id).member.?.raw.options.cache orelse continue;
        if ((slot.storage == .constructor) == member.member_kind.isStatic() and std.mem.eql(u8, cache_name, slot.slot_name)) return true;
    }
    return false;
}

pub fn slotSymbols(n: *Normalizer, class_: *const ir.Class, slot: ir.CachedSlot) std.mem.Allocator.Error!struct { getter: []const u8, setter: ?[]const u8 } {
    return .{
        .getter = try n.print("{s}_get_cached_{s}", .{ class_.cpp_class_name, slot.slot_name }),
        .setter = if (slot.write != null) try n.print("set{s}_get_cached_{s}", .{ class_.cpp_class_name, slot.slot_name }) else null,
    };
}

fn class(n: *Normalizer, declared: Normalizer.DeclaredClass, parents: []const ?ir.ClassId) Error!ir.Class {
    const raw = declared.class;
    const options = raw.options;
    const qualified_name = try n.print("{s}_{s}", .{ declared.module_name, raw.name });
    const cpp_name = try n.print("BunBindgen_{s}", .{qualified_name});
    const symbol_prefix = try n.print("bun_bindgen_class_{s}", .{qualified_name});
    const profile = options.profile;

    const declarations = try n.arena.alloc(ir.FunctionId, declared.members.len);
    for (declared.members, declarations) |member, *declaration| declaration.* = .of(member);

    const slots = try n.arena.alloc(ir.CachedSlot, raw.slots.len);
    for (raw.slots, slots) |slot, *normalized| {
        const slot_type = try types.ensure(n, slot.type);
        const input_plan = try plans.inputPlan(n, slot_type, profile, .{});
        const optional = n.irType(slot_type).kind() == .optional;
        const value_type = if (optional) n.irType(slot_type).data.optional.child else slot_type;
        const value_input = if (optional) plans.plan(n, input_plan).codec.optional.child else input_plan;
        const storage: ir.CachedSlotStorage = switch (slot.options.storage) {
            .instance => .instance,
            .constructor => .constructor,
        };
        normalized.* = .{
            .assigned_position = try n.positions.?.value(.inbound_argument, value_type, value_input, null),
            .access = switch (n.irType(value_type).kind()) {
                .callback => .callback,
                .any => .{ .js_value = .any },
                .engine_value => .{ .js_value = .engine_value },
                .branded_value => .{ .js_value = .branded },
                .class_ref => .class_ref,
                .union_type => .union_type,
                else => .storage_only,
            },
            .slot_name = slot.name,
            .declared_type = slot_type,
            .optional = optional,
            .storage = storage,
            .get_symbol = try n.print("bun_bindgen_class_{s}_{s}_slot_{s}_get", .{ declared.module_name, raw.name, slot.name }),
            .write = if (slot.options.writable) .{
                .set = try n.print("bun_bindgen_class_{s}_{s}_slot_{s}_set", .{ declared.module_name, raw.name, slot.name }),
                .clear_weak = try n.print("bun_bindgen_class_{s}_{s}_slot_{s}_clear_weak", .{ declared.module_name, raw.name, slot.name }),
            } else null,
        };
    }

    const instance_properties = try n.arena.alloc(ir.InstanceProperty, raw.instance_properties.len);
    for (raw.instance_properties, instance_properties) |property, *normalized| {
        const value_type = try types.ensure(n, property.options.value);
        const input = try plans.inputPlan(n, value_type, profile, .{});
        normalized.* = .{
            .position = try n.positions.?.value(.outbound_argument, value_type, input, null),
            .property_name = property.name,
        };
    }

    const id: ir.ClassId = .of(n.classes.items.len);
    return .{
        .id = id,
        .module_name = declared.module_name,
        .class_name = raw.name,
        .display_name = options.display_name orelse raw.name,
        .brand = if (options.brand) |brand| try types.normalizeBrandValue(n, brand) else null,
        .representation = switch (options.representation) {
            .native => .native,
            .plain => .plain,
            .engine => .{ .engine = try engineClass(n, declared, parents) },
        },
        .runtime_plan = try runtimePlan(n, options, symbol_prefix),
        .parent = parents[n.classes.items.len],
        .upcast = if (options.upcast) |implementation| .{
            .implementation = implementation,
            .symbol = try n.print("{s}_upcast", .{symbol_prefix}),
        } else null,
        .instance_properties = instance_properties,
        .create_symbol = try n.print("{s}_create", .{symbol_prefix}),
        .memory_usage = if (options.representation == .native) if (options.memory_usage) |affinity| .{
            .affinity = affinity,
            .symbol = try n.print("{s}_memory_usage", .{symbol_prefix}),
        } else null else null,
        .pending_activity = if (options.has_pending_activity) try n.print("{s}_has_pending_activity", .{symbol_prefix}) else null,
        .immutable_prototype = options.immutable_prototype,
        .structured_clone = try structuredClonePlan(n, .of(n.classes.items.len), symbol_prefix, options.structured_clone),
        .constructor_call = if (declared.constructor_call) |call| .of(call) else null,
        .slots = slots,
        .declarations = declarations,
        .exposed = n.isExposed(options.exposure),
        .cpp_class_name = cpp_name,
        .cpp_prototype_name = try n.print("{s}Prototype", .{cpp_name}),
        .cpp_constructor_name = try n.print("{s}Constructor", .{cpp_name}),
        .get_constructor_symbol = try n.print("{s}_constructor", .{symbol_prefix}),
        .try_cast_symbol = try n.print("{s}_try_cast", .{symbol_prefix}),
        .try_cast_direct_symbol = try n.print("{s}_try_cast_direct", .{symbol_prefix}),
        .wrap_native_symbol = try n.print("{s}_wrap_native", .{symbol_prefix}),
        .destroy_native_symbol = try n.print("{s}_destroy_native", .{symbol_prefix}),
        .destroy_pending_native_symbol = try n.print("{s}_destroy_pending_native", .{symbol_prefix}),
        .release_native_on_vm_symbol = try n.print("{s}_release_native_on_vm", .{symbol_prefix}),
        .native_type_symbol_prefix = try n.print("{s}_native_type", .{symbol_prefix}),
        .initialize_symbol = try n.print("initializeBindgenClass_{s}", .{qualified_name}),
        .constructor = .of(declared.constructor),
        .value_type = n.typeId(declared.value),
    };
}

fn hasPrototypeSymbol(n: *const Normalizer, properties: []const schema.DataProperty, declarations: []const ir.FunctionId, symbol: ir.PropertySymbol) bool {
    for (properties) |property| {
        if (property.options.storage != .prototype) continue;
        switch (property.key) {
            .symbol => |key| if (key == symbol) return true,
            .name => {},
        }
    }
    for (declarations) |declaration| {
        const member = n.functions.items[declaration.index];
        const facts = member.class_member.?;
        if (!member.exposed or facts.member_kind.isStatic()) continue;
        const options = n.declaration(member.id).member.?.raw.options;
        if (options.symbol == symbol) return true;
        for (options.aliases) |alias| switch (alias.key) {
            .symbol => |key| if (key == symbol) return true,
            .name => {},
        };
    }
    return false;
}

fn engineWrapperDispatch(n: *Normalizer, id: ir.ClassId, engine: ir.CppEngineClass) Error!ir.EngineWrapperDispatch {
    const native_type = engine.native_type;
    const native = n.declared_classes.items[id.index].class.options.engine_native.?;
    const discriminator = native.wrapper_discriminator orelse return .{ .native_type = native_type, .operation = .direct };
    var cases: std.ArrayList(ir.EngineWrapperDispatch.Case) = .empty;
    for (n.classes.items) |child| {
        if (!child.exposed) continue;
        const child_type = switch (child.representation) {
            .engine => |child_engine| child_engine.native_type,
            .native, .plain => continue,
        };
        const parent = child.parent orelse continue;
        if (parent.index != id.index) continue;
        const location = try n.print("{s}.{s}", .{ child.module_name, child.class_name });
        const tag = n.declared_classes.items[child.id.index].class.options.engine_native.?.wrapper_tag orelse
            return n.reject(location, "derived engine wrapper requires a native tag: {s}", .{child.class_name});
        if (child.runtime_plan.identity != .engine_wrapper_cache)
            return n.reject(location, "polymorphic engine wrappers require per-realm identity: {s}", .{child.class_name});
        if (native.wrapper_tag) |base_tag| {
            if (std.mem.eql(u8, tag, base_tag)) return n.reject(location, "derived wrapper tag duplicates its base tag", .{});
        }
        if (native.wrapper_global_scope) |projection| {
            if (std.mem.eql(u8, tag, projection.tag)) return n.reject(location, "derived wrapper tag duplicates its global scope tag", .{});
        }
        for (cases.items) |previous| {
            if (std.mem.eql(u8, tag, previous.tag)) return n.reject(location, "duplicate derived engine wrapper tag", .{});
        }
        try cases.append(n.arena, .{ .tag = tag, .operation = .{ .derived = child_type } });
    }
    if (native.wrapper_global_scope) |projection| {
        try cases.append(n.arena, .{ .tag = projection.tag, .operation = .{ .global_scope = try n.cppType(.{ .named = .{ .name = projection.cpp_type, .namespace = .global } }) } });
    }
    if (native.wrapper_tag) |tag| try cases.append(n.arena, .{ .tag = tag, .operation = .base });
    return .{
        .native_type = native_type,
        .operation = .{ .tagged = .{ .discriminator = discriminator, .cases = cases.items } },
    };
}

fn memberSymbol(n: *Normalizer, id: ir.FunctionId) Error!ir.CppClassMemberSymbol {
    const member = n.get(id);
    return switch (member.backend) {
        .zig, .cpp => .{ .native = member.host_symbol },
        .builtin => .{ .builtin = n.builtinGenerator(id) },
    };
}

fn propertyAttributes(options: schema.ClassMemberOptions, read_only: bool, dom_attribute: bool) ir.CppClassPropertyAttributes {
    return .{
        .read_only = read_only and options.getter_assignment == .reject,
        .enumerable = options.enumerable,
        .configurable = options.configurable,
        .dom_attribute = dom_attribute,
    };
}

fn memberKey(member: *const ir.Function, options: schema.ClassMemberOptions) ir.CppClassPropertyKey {
    return if (options.symbol) |symbol| .{ .symbol = symbol } else if (options.private_symbol) |symbol| .{ .private_symbol = symbol } else .{ .name = member.js_name };
}

fn classProperties(n: *Normalizer, class_: *const ir.Class) Error!ir.CppClassProperties {
    const Key = struct { name: []const u8, static: bool, unforgeable: bool };
    const Pair = struct { has_getter: bool = false, setter: ?ir.FunctionId = null };
    var pairs: structural.Map(Key, Pair) = .empty;
    for (class_.declarations) |id| {
        const member = n.get(id);
        const facts = member.class_member.?;
        const options = n.declaration(member.id).member.?.raw.options;
        if (!member.exposed or options.symbol != null or options.private_symbol != null or (!facts.member_kind.isGetter() and !facts.member_kind.isSetter())) continue;
        const pair = try pairs.getOrPut(n.arena, .{ .name = member.js_name, .static = facts.member_kind.isStatic(), .unforgeable = options.unforgeable });
        if (!pair.found_existing) pair.value_ptr.* = .{};
        if (facts.member_kind.isGetter()) pair.value_ptr.has_getter = true else pair.value_ptr.setter = id;
    }

    var prototype: std.ArrayList(ir.CppClassTableEntry) = .empty;
    var constructor: std.ArrayList(ir.CppClassTableEntry) = .empty;
    var unforgeable: std.ArrayList(ir.CppClassProperties.Unforgeable) = .empty;
    for (class_.declarations) |id| {
        const member = n.get(id);
        const facts = member.class_member.?;
        const options = n.declaration(member.id).member.?.raw.options;
        if (!member.exposed or options.symbol != null or options.private_symbol != null) continue;
        const table = if (facts.member_kind.isStatic()) &constructor else &prototype;
        switch (facts.member_kind) {
            .method, .static_method => try table.append(n.arena, .{
                .name = member.js_name,
                .attributes = propertyAttributes(options, false, false),
                .value = .{ .function = .{ .implementation = try memberSymbol(n, id), .length = member.js_length } },
            }),
            .getter, .static_getter, .setter, .static_setter => {
                const pair = pairs.get(.{ .name = member.js_name, .static = facts.member_kind.isStatic(), .unforgeable = options.unforgeable }).?;
                if (facts.member_kind.isGetter()) {
                    const getter: ir.CppClassGetter = .{
                        .implementation = try memberSymbol(n, id),
                        .setter = if (pair.setter) |setter| try memberSymbol(n, setter) else if (options.writable) .{ .native = try n.print("{s}_writable_setter", .{member.host_symbol}) } else null,
                    };
                    if (options.unforgeable) {
                        try unforgeable.append(n.arena, .{
                            .name = member.js_name,
                            .attributes = propertyAttributes(options, getter.setter == null, false),
                            .accessor = .{ .getter = getter },
                        });
                    } else {
                        try table.append(n.arena, .{
                            .name = member.js_name,
                            .attributes = propertyAttributes(options, getter.setter == null, getter.implementation == .native and
                                (facts.member_kind.isStatic() or (class_.representation != .plain and options.invalid_this == .throw))),
                            .value = .{ .accessor = getter },
                        });
                    }
                } else {
                    if (pair.has_getter) continue;
                    if (!options.unforgeable) return n.reject(try n.print("{s}.{s}", .{ member.module_name, member.function_name }), "{s}setter-only accessors are not supported: {s}", .{ if (facts.member_kind.isStatic()) "static " else "", member.js_name });
                    try unforgeable.append(n.arena, .{
                        .name = member.js_name,
                        .attributes = propertyAttributes(options, false, false),
                        .accessor = .{ .setter = try memberSymbol(n, id) },
                    });
                }
            },
            .constructor => return n.reject(try n.print("{s}.{s}", .{ member.module_name, member.function_name }), "class member lists cannot contain constructors", .{}),
        }
    }
    for (class_.slots, n.declared_classes.items[class_.id.index].class.slots) |slot, raw| {
        if (slot.storage != .instance or !raw.options.exposed or slotCachesMember(n, class_, slot) or raw.options.private_symbol != null) continue;
        const symbols = try slotSymbols(n, class_, slot);
        try prototype.append(n.arena, .{
            .name = slot.slot_name,
            .attributes = .{ .read_only = slot.write == null, .enumerable = true, .configurable = true, .dom_attribute = true },
            .value = .{ .accessor = .{
                .implementation = .{ .native = symbols.getter },
                .setter = if (symbols.setter) |setter| .{ .native = setter } else null,
            } },
        });
    }
    const installations = try classInstallations(n, class_);
    return .{
        .prototype = .{ .table = prototype.items, .installations = installations.prototype },
        .constructor = .{ .table = constructor.items, .installations = installations.constructor },
        .unforgeable = unforgeable.items,
    };
}

fn classInstallations(n: *Normalizer, class_: *const ir.Class) Error!struct { prototype: []const ir.CppClassInstallation, constructor: []const ir.CppClassInstallation } {
    var prototype: std.ArrayList(ir.CppClassInstallation) = .empty;
    var constructor: std.ArrayList(ir.CppClassInstallation) = .empty;
    for (class_.slots, n.declared_classes.items[class_.id.index].class.slots) |slot, raw| {
        if (!raw.options.exposed or slotCachesMember(n, class_, slot)) continue;
        const symbol = raw.options.private_symbol orelse continue;
        const symbols = try slotSymbols(n, class_, slot);
        const output = if (slot.storage == .constructor) &constructor else &prototype;
        try output.append(n.arena, .{ .property = .{
            .key = .{ .private_symbol = symbol },
            .attributes = .{ .read_only = slot.write == null, .enumerable = false, .configurable = true, .dom_attribute = false },
            .value = .{ .accessor = .{
                .implementation = .{ .native = symbols.getter },
                .setter = if (symbols.setter) |setter| .{ .native = setter } else null,
            } },
        } });
    }
    for (class_.declarations) |id| {
        const member = n.get(id);
        const facts = member.class_member.?;
        if (!member.exposed) continue;
        const options = n.declaration(member.id).member.?.raw.options;
        const output = if (facts.member_kind.isStatic()) &constructor else &prototype;
        const key = memberKey(member, options);
        if (key == .name) continue;
        const implementation = try memberSymbol(n, id);
        if (key == .private_symbol and implementation == .builtin)
            return n.reject(try n.print("{s}.{s}", .{ member.module_name, member.function_name }), "private-symbol members cannot be builtins: {s}", .{key.private_symbol});
        try output.append(n.arena, .{ .property = .{
            .key = key,
            .attributes = .{ .read_only = implementation == .native, .enumerable = false, .configurable = true, .dom_attribute = false },
            .value = switch (implementation) {
                .native => |symbol| if (key == .private_symbol and facts.member_kind.isGetter())
                    .{ .accessor = .{ .implementation = .{ .native = symbol }, .setter = null } }
                else
                    .{ .native = .{
                        .symbol = symbol,
                        .name = options.display_name orelse if (key == .private_symbol) member.implementation_name else member.js_name,
                        .length = member.js_length,
                        .visibility = if (key == .private_symbol) .internal else .public,
                    } },
                .builtin => |symbol| .{ .builtin = symbol },
            },
        } });
    }
    for (class_.declarations) |id| {
        const member = n.get(id);
        const facts = member.class_member.?;
        const aliases = n.declaration(member.id).member.?.raw.options.aliases;
        if (!member.exposed or aliases.len == 0) continue;
        const targets = try n.arena.alloc(ir.CppClassInstallation.Alias, aliases.len);
        for (aliases, targets) |alias, *target| target.* = .{ .key = alias.key, .enumerable = alias.options.enumerable };
        const output = if (facts.member_kind.isStatic()) &constructor else &prototype;
        try output.append(n.arena, .{ .aliases = .{ .source = member.js_name, .targets = targets } });
    }
    const properties = n.declared_classes.items[class_.id.index].class.properties;
    for (properties) |property| {
        const output = if (property.options.storage == .constructor) &constructor else &prototype;
        try output.append(n.arena, .{ .property = .{
            .key = switch (property.key) {
                .name => |name| .{ .name = name },
                .symbol => |symbol| .{ .symbol = symbol },
            },
            .attributes = .{ .read_only = !property.options.writable, .enumerable = property.options.enumerable, .configurable = property.options.configurable, .dom_attribute = false },
            .value = .{ .constant = property.value },
        } });
    }
    if (!hasPrototypeSymbol(n, properties, class_.declarations, .to_string_tag)) try prototype.append(n.arena, .to_string_tag);
    return .{ .prototype = prototype.items, .constructor = constructor.items };
}

fn classInitialization(n: *Normalizer, class_: *const ir.Class) Error!ir.CppClassInitialization {
    const raw = n.declared_classes.items[class_.id.index].class;
    const options = raw.options;
    const prototype: ir.CppClassInitialization.Prototype = if (options.parent) |parent| switch (parent) {
        .engine => |engine| switch (engine.prototype) {
            .object => .object,
            .iterator => .iterator,
            .error_object => .error_object,
        },
        .class => .{ .class = class_.parent orelse return n.reject(try n.print("{s}.{s}", .{ class_.module_name, class_.class_name }), "class parent is absent from the binding manifest", .{}) },
    } else switch (options.prototype_base) {
        .object => .object,
        .function => .function,
        .iterator => .iterator,
        .async_iterator => .async_iterator,
    };
    return .{
        .prototype = prototype,
        .structure = switch (class_.representation) {
            .native, .engine => .class,
            .plain => plain: {
                const properties = try n.arena.alloc(ir.CppClassInitialization.Property, class_.instance_properties.len);
                for (raw.instance_properties, properties) |property, *key| key.* = if (property.options.private_symbol) |symbol| .{ .private_symbol = symbol } else .{ .name = property.name };
                break :plain .{ .plain = properties };
            },
        },
        .constructor = if (n.get(class_.constructor).exposed) if (class_.parent) |parent| .{ .class = parent } else .function else null,
    };
}

pub fn emissionPlans(n: *Normalizer) Error!void {
    const Facts = struct {
        referenced: bool = false,
        has_children: bool,
        constructor_type: ?ir.TypeId = null,
    };
    const facts = try n.arena.alloc(Facts, n.classes.items.len);
    for (n.declared_classes.items, facts) |declared, *item| item.* = .{ .has_children = !declared.class.options.final };
    var instance_types: structural.Map(ir.Brand, ?ir.TypeId) = .empty;
    for (n.types.items[0..n.binding_type_count]) |t| {
        switch (t.data) {
            .class_ref => |class_ref| facts[class_ref.class.index].referenced = true,
            .branded_value => |branded| {
                const entry = try instance_types.getOrPut(n.arena, branded.brand);
                entry.value_ptr.* = if (entry.found_existing) null else t.id;
                if (branded.brand.constructor_class) |class_id| {
                    if (facts[class_id.index].constructor_type == null) facts[class_id.index].constructor_type = t.id;
                }
                switch (n.get(branded.brand.cpp_match).*) {
                    .class_instance => |instance| facts[instance.class.index].referenced = true,
                    .value, .realm, .dynamic_cast => {},
                }
            },
            else => {},
        }
    }
    for (n.classes.items) |normalized| {
        if (normalized.parent) |parent| if (normalized.exposed) {
            facts[parent.index].has_children = true;
        };
    }
    const relations = try n.arena.alloc(ir.ClassRelations, n.classes.items.len);
    for (n.classes.items, relations, facts) |normalized, *output, item| output.* = .{
        .emission = .{
            .has_children = item.has_children,
            .declaration = if (!normalized.exposed) .none else switch (normalized.representation) {
                .plain => .none,
                .engine => .engine_header,
                .native => if (item.has_children or item.referenced) .bindings_header else .source,
            },
        },
        .initialization = try classInitialization(n, &normalized),
        .properties = try classProperties(n, &normalized),
        .typescript = try mod_typescript.class(n, &normalized),
        .engine_wrapper_dispatch = switch (normalized.representation) {
            .engine => |engine| if (normalized.runtime_plan.identity == .engine_wrapper_cache) try engineWrapperDispatch(n, normalized.id, engine) else null,
            .native, .plain => null,
        },
        .instance_value_type = if (normalized.brand) |brand| instance_types.get(brand) orelse null else null,
        .constructor_value_type = item.constructor_type,
    };
    n.class_relations = relations;
}

fn validateEngineNativeCppType(n: *Normalizer, location: []const u8, cpp_type: []const u8) Error!void {
    if (std.mem.indexOf(u8, cpp_type, "::") == null)
        return n.fail(location, "an engine class native type must be namespace-qualified: {s}", .{cpp_type});
    var components = std.mem.splitSequence(u8, cpp_type, "::");
    while (components.next()) |component| {
        if (!validate.isIdentifier(component)) return n.fail(location, "an engine class native type must be forward-declarable: {s}", .{cpp_type});
    }
}

fn validateClass(n: *Normalizer, normalized: ir.Class) Error!void {
    const location = try n.print("{s}.{s}", .{ normalized.module_name, normalized.class_name });
    const options = n.declared_classes.items[normalized.id.index].class.options;
    if (normalized.representation == .engine) {
        const native = options.engine_native.?;
        try validateEngineNativeCppType(n, location, native.cpp_type);
        if (native.wrapper_discriminator) |getter| {
            if (!validate.isIdentifier(getter)) try n.fail(location, "engine wrapper discriminator must name a native getter", .{});
            if (normalized.runtime_plan.identity != .engine_wrapper_cache) try n.fail(location, "polymorphic engine wrappers require per-realm identity", .{});
        }
        if (native.wrapper_tag) |tag| {
            try validateEngineNativeCppType(n, location, tag);
            const parent_discriminates = if (normalized.parent) |parent| n.declared_classes.items[parent.index].class.options.engine_native.?.wrapper_discriminator != null else false;
            if (native.wrapper_discriminator == null and !parent_discriminates) try n.fail(location, "engine wrapper tag has no parent discriminator", .{});
        }
        if (native.wrapper_global_scope) |projection| {
            if (native.wrapper_discriminator == null) try n.fail(location, "global scope projection requires a wrapper discriminator", .{});
            try validateEngineNativeCppType(n, location, projection.tag);
            try validateEngineNativeCppType(n, location, projection.cpp_type);
            if (native.wrapper_tag) |tag| {
                if (std.mem.eql(u8, tag, projection.tag)) try n.fail(location, "global scope tag duplicates its base tag", .{});
            }
        }
    }
    if (!normalized.exposed) return;
    if (normalized.parent) |parent| {
        if (!n.classes.items[parent.index].exposed) try n.fail(location, "an exposed generated class cannot inherit from a class excluded from the target", .{});
    }
    const engine = normalized.representation == .engine;
    const plain = normalized.representation == .plain;
    const constructor = n.functions.items[normalized.constructor.index];
    if (constructor.exposed) {
        if (!constructor.class_member.?.is_illegal) {
            if (engine or plain) {
                if (constructor.backend != .cpp) try n.fail(location, "engine and plain class constructors require a C++ backend", .{});
            } else if (constructor.backend != .zig) {
                try n.fail(location, "native-representation constructors create Zig state and require a Zig backend", .{});
            }
        }
        if (constructor.isAsync()) try n.fail(location, "generated class constructors cannot be asynchronous", .{});
        if (normalized.parent) |parent| {
            if (!n.functions.items[n.classes.items[parent.index].constructor.index].exposed)
                try n.fail(location, "a generated class constructor cannot inherit from an unexposed parent constructor", .{});
        }
    }
    if (normalized.constructor_call) |id| {
        const call = n.get(id);
        if (call.exposed) {
            if (!constructor.exposed) try n.fail(location, "a generated constructor call requires an exposed constructor", .{});
            if (engine or plain) {
                if (call.backend != .cpp) try n.fail(location, "engine and plain constructor calls require a C++ backend", .{});
            } else if (call.backend != .zig and call.backend != .builtin) {
                try n.fail(location, "native constructor calls require a Zig or builtin backend", .{});
            }
        }
    }
    if (options.prototype_base == .function) {
        if (constructor.exposed) try n.fail(location, "a Function.prototype-based class cannot expose its constructor", .{});
        if (normalized.parent != null) try n.fail(location, "a Function.prototype-based class cannot inherit from another generated class", .{});
    }
    for (normalized.declarations) |declaration| {
        const member = n.functions.items[declaration.index];
        if (!member.exposed) continue;
        const facts = member.class_member.?;
        if (!constructor.exposed and facts.member_kind.isStatic())
            try n.fail(location, "a generated class without an exposed constructor cannot declare exposed static members", .{});
        if (engine) {
            if (member.backend == .cpp and !facts.member_kind.isStatic() and
                (member.this_argument != null or member.new_target_argument != null or member.callee_argument != null or member.has_caller_source_location))
                try n.fail(location, "engine class C++ members do not receive invocation values", .{});
            if (n.declaration(member.id).member.?.raw.options.cache_on_construction) try n.fail(location, "engine classes do not support constructor-time caching", .{});
        }
        if (plain) {
            if (member.isOverloaded()) try n.fail(location, "plain class members do not support overloads", .{});
            if (n.declaration(member.id).member.?.raw.options.cache != null) try n.fail(location, "plain class instances have no cached slots", .{});
        }
    }
    for (n.declared_classes.items[normalized.id.index].class.properties) |property| {
        if (property.options.storage == .constructor and !constructor.exposed)
            try n.fail(location, "a generated class without an exposed constructor cannot declare constructor data properties", .{});
    }
    if (options.prototype_base == .function) {
        for (normalized.slots, n.declared_classes.items[normalized.id.index].class.slots) |slot, raw| {
            if (slot.storage == .instance and raw.options.exposed and !slotCachesMember(n, &normalized, slot))
                try n.fail(location, "Function.prototype-based classes do not support exposed standalone slot {s}", .{slot.slot_name});
        }
    }
    if (!constructor.exposed) for (normalized.slots) |slot| {
        if (slot.storage == .constructor) {
            try n.fail(location, "a generated class without an exposed constructor cannot declare constructor cached slots", .{});
            break;
        }
    };
}
