//! Static surfaces: object surfaces and native modules, with the usage,
//! dependency, and header plans their emission follows.
const mod_surface_table = @import("surface_table.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const InputPlanId = plans.InputPlanId;
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const typescript = @import("typescript.zig");
const plans = @import("plans.zig");
const structural = @import("../structural.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

const SurfaceFunctionAccessor = struct { getter: ir.FunctionId, setter: ?ir.FunctionId };
const SurfaceLazyValue = union(enum) { function: ir.FunctionId, native: ir.NativeExportId, class: ir.ClassId };
const SurfaceMemberValue = union(ir.SurfaceMemberKind) {
    function: ir.FunctionId,
    lazy_declaration: SurfaceLazyValue,
    object_value: ir.ObjectSurfaceId,
    callable_value: struct { declaration: ir.FunctionId, surface: ir.ObjectSurfaceId },
    self,
    accessor: union(enum) { builtin: ir.FunctionId, function: SurfaceFunctionAccessor },
    constant: ir.SurfaceConstant,
    empty_collection: struct { collection: ir.SurfaceEmptyCollection, element: ir.TypeId },
    lazy_owner: struct { owner: ir.SurfaceLazyOwner, member: []const u8 },
};

pub fn normalizeAll(n: *Normalizer) Error!void {
    for (n.declared_object_surfaces.items) |surface| {
        try n.object_surfaces.append(n.arena, try objectSurface(n, surface));
    }
    for (n.declared_native_modules.items) |declared| {
        try n.native_module_surfaces.append(n.arena, try nativeModuleSurface(n, declared.native_module));
    }
    try surfacePlans(n);
}

pub fn objectSurfaceIdOf(n: *const Normalizer, surface: *const schema.ObjectSurface) ?ir.ObjectSurfaceId {
    for (n.declared_object_surfaces.items, 0..) |candidate, index| {
        if (candidate == surface or structural.eql(candidate.*, surface.*)) return .of(index);
    }
    return null;
}

const Member = struct { value: SurfaceMemberValue, exposed: bool, typescript_exposed: bool };

const MemberVisibility = struct {
    runtime: bool = true,
    typescript: bool = true,

    fn function(self: *MemberVisibility, n: *const Normalizer, bound: schema.BoundFunction) ir.FunctionId {
        const id: ir.FunctionId = .of(n.functionIdOf(bound).?);
        self.runtime = self.runtime and n.get(id).exposed;
        self.typescript = self.typescript and typescript.functionExposed(n, id);
        return id;
    }

    fn class(self: *MemberVisibility, n: *const Normalizer, bound: schema.BoundClass) ir.ClassId {
        const id: ir.ClassId = .of(n.classIdOf(bound).?);
        self.runtime = self.runtime and n.get(id).exposed;
        self.typescript = self.typescript and normalize.isTypeScriptExposed(bound.class.options.exposure);
        return id;
    }

    fn exposure(self: *MemberVisibility, n: *const Normalizer, value: ir.Exposure) void {
        self.runtime = self.runtime and n.isExposed(value);
        self.typescript = self.typescript and normalize.isTypeScriptExposed(value);
    }
};

fn resolveMember(n: *Normalizer, member: schema.SurfaceMember) Member {
    var visibility: MemberVisibility = .{};
    const value: SurfaceMemberValue = switch (member.value) {
        .function => |bound| .{ .function = visibility.function(n, bound) },
        .lazy_declaration => |declaration| .{ .lazy_declaration = switch (declaration) {
            .function => |bound| .{ .function = visibility.function(n, bound) },
            .native => |bound| native: {
                const id = n.nativeExportIdOf(bound).?;
                visibility.runtime = n.native_exports.items[id].exposed;
                visibility.typescript = normalize.isTypeScriptExposed(bound.native_export.options.exposure);
                break :native .{ .native = .of(id) };
            },
            .class => |bound| .{ .class = visibility.class(n, bound) },
        } },
        .object_value => |surface| object: {
            visibility.exposure(n, surface.options.exposure);
            break :object .{ .object_value = objectSurfaceIdOf(n, surface).? };
        },
        .callable_value => |callable| function: {
            const id = visibility.function(n, callable.declaration);
            visibility.exposure(n, callable.surface.options.exposure);
            break :function .{ .callable_value = .{ .declaration = id, .surface = objectSurfaceIdOf(n, callable.surface).? } };
        },
        .accessor => |accessor| .{ .accessor = switch (accessor) {
            .builtin => |bound| .{ .builtin = visibility.function(n, bound) },
            .function => |pair| function: {
                const getter = visibility.function(n, pair.getter);
                const setter = if (pair.setter) |bound| visibility.function(n, bound) else null;
                break :function .{ .function = .{ .getter = getter, .setter = setter } };
            },
        } },
        .constant => |constant| .{ .constant = constant },
        .empty_collection => |collection| .{ .empty_collection = .{ .collection = collection.collection, .element = n.typeId(collection.element) } },
        .lazy_owner => |owner| .{ .lazy_owner = .{ .owner = owner.owner, .member = owner.member } },
        .self => .self,
    };
    visibility.exposure(n, member.options.exposure);
    return .{
        .value = value,
        .exposed = visibility.runtime,
        .typescript_exposed = visibility.typescript,
    };
}

fn surfaceMember(n: *Normalizer, member: schema.SurfaceMember, resolved: Member, installation: ir.SurfaceInstallation, cpp_class: ?[]const u8, reference: ir.SurfaceMemberReference, table_index: u32) Error!ir.ObjectSurfaceMember {
    const options = member.options;
    const value = resolved.value;
    const table = if (installation != .direct and options.placement == .inferred and member.key == .name)
        try surfaceTable(n, value, cpp_class, options.constructable)
    else
        null;
    return .{
        .property_name = member.propertyName(),
        .property_key = member.key,
        .attributes = options.attributes,
        .aliases = options.aliases,
        .native_accessor = if (resolved.exposed) if (options.native_accessor) |name| .{ .name = name, .table_index = table_index } else null else null,
        .installation = if (table) |value_|
            .{ .table = value_ }
        else if (options.placement == .global_static)
            .{ .global = try surfaceExpression(n, value, member, reference, member.options.function_name) }
        else
            .{ .direct = try surfaceDirect(n, value, member, reference) },
        .initializer = try surfaceInitializer(n, value, member, table != null),
        .exposed = resolved.exposed,
    };
}

fn surfaceTable(n: *Normalizer, value: SurfaceMemberValue, cpp_class: ?[]const u8, constructable: bool) Error!?ir.SurfaceTableValue {
    return switch (value) {
        .function => |id| function: {
            const declaration = n.functions.items[id.index];
            if (n.realm_functions.contains(id)) break :function .property_callback;
            break :function .{ .function = .{
                .symbol = switch (declaration.backend) {
                    .builtin => .{ .builtin = n.builtinGenerator(id) },
                    .zig, .cpp => .{ .native = declaration.host_symbol },
                },
                .length = declaration.js_length,
                .constructable = constructable,
            } };
        },
        .accessor => |accessor| switch (accessor) {
            .builtin => |getter| .{ .builtin_accessor = n.builtinGenerator(getter) },
            .function => null,
        },
        .constant => |constant| switch (constant) {
            .integer => |integer| .{ .integer = integer },
            .string, .external_string, .registered_symbol, .undefined, .external_boolean, .boolean => .property_callback,
            .external_number => null,
        },
        .lazy_owner => |owner| .{ .owner = .{ .kind = owner.owner, .class = cpp_class.?, .member = owner.member } },
        .lazy_declaration, .object_value, .callable_value, .empty_collection, .self => .property_callback,
    };
}

pub fn surfaceFunction(n: *Normalizer, id: ir.FunctionId, name: ir.CppSurfaceFunctionName, visibility: ir.SurfaceFunctionVisibility, constructable: bool) std.mem.Allocator.Error!ir.CppSurfaceFunction {
    const function = n.functions.items[id.index];
    if (n.realm_functions.get(id)) |realm| return .{ .realm = realm };
    return switch (function.backend) {
        .builtin => .{ .builtin = n.builtinGenerator(id) },
        .zig, .cpp => .{ .native = .{ .symbol = function.host_symbol, .length = function.js_length, .name = name, .visibility = visibility, .constructable = constructable } },
    };
}

pub fn functionFactorySymbol(n: *Normalizer, id: ir.FunctionId) std.mem.Allocator.Error![]const u8 {
    const function = n.get(id);
    return n.print("bun_bindgen_surface_value_{s}_{s}", .{ function.module_name, function.function_name });
}

pub fn nativeFactorySymbol(n: *Normalizer, id: ir.NativeExportId) std.mem.Allocator.Error![]const u8 {
    const native = n.get(id);
    return n.print("bunBindgenNativeSurface_{s}_{s}", .{ native.module_name, native.export_name });
}

fn surfaceExpression(n: *Normalizer, value: SurfaceMemberValue, member: schema.SurfaceMember, reference: ?ir.SurfaceMemberReference, name: ?[]const u8) Error!ir.CppSurfaceValue {
    return switch (value) {
        .function => |id| .{ .function = try surfaceFunction(n, id, if (name) |text| .{ .named = text } else .none, member.options.function_visibility, false) },
        .lazy_declaration => |declaration| switch (declaration) {
            .function => |id| if (reference) |callback| .{ .callback = callback } else .{ .function_factory = try functionFactorySymbol(n, id) },
            .native => |id| if (reference) |callback| .{ .callback = callback } else .{ .native_factory = try nativeFactorySymbol(n, id) },
            .class => |id| .{ .constructor = id },
        },
        .object_value, .callable_value => .{ .callback = reference.? },
        .constant => |constant| .{ .constant = constant },
        .empty_collection => |collection| .{ .empty_collection = collection.collection },
        .self => .self,
        .accessor, .lazy_owner => return n.reject(member.propertyName(), "unsupported global-static surface member: {s}", .{member.propertyName()}),
    };
}

fn surfaceInitializer(n: *Normalizer, value: SurfaceMemberValue, member: schema.SurfaceMember, table: bool) Error!?ir.CppSurfaceInitializer {
    return switch (value) {
        .lazy_declaration => |declaration| switch (declaration) {
            .function => |id| .{ .value = .{ .function_factory = try functionFactorySymbol(n, id) } },
            .native => |id| .{ .value = .{ .native_factory = try nativeFactorySymbol(n, id) } },
            .class => |id| if (table) .{ .value = .{ .constructor = id } } else null,
        },
        .object_value => |id| .{ .value = .{ .object = id } },
        .callable_value => |callable| .{ .callable = .{
            .function = try surfaceFunction(n, callable.declaration, .{ .named = member.options.function_name orelse member.propertyName() }, member.options.function_visibility, member.options.constructable),
            .surface = callable.surface,
        } },
        .function => |id| if (table and n.realm_functions.contains(id))
            .{ .value = .{ .function = try surfaceFunction(n, id, .{ .named = member.options.function_name orelse member.propertyName() }, member.options.function_visibility, false) } }
        else
            null,
        .self => if (table) .{ .value = .self } else null,
        .empty_collection => |collection| if (table) .{ .value = .{ .empty_collection = collection.collection } } else null,
        .constant => |constant| if (table and constant != .integer and constant != .external_number) .{ .value = .{ .constant = constant } } else null,
        .accessor, .lazy_owner => null,
    };
}

fn surfaceAccessor(n: *Normalizer, accessor: SurfaceFunctionAccessor, name: []const u8, reuse_getter: bool) Error!ir.CppSurfaceAccessor {
    return .{
        .getter = try surfaceFunction(n, accessor.getter, .{ .getter = name }, .public, false),
        .setter = if (accessor.setter) |setter|
            if (reuse_getter and setter.index == accessor.getter.index) .getter else .{ .function = try surfaceFunction(n, setter, .{ .setter = name }, .public, false) }
        else
            .none,
    };
}

fn surfaceDirect(n: *Normalizer, value: SurfaceMemberValue, member: schema.SurfaceMember, reference: ?ir.SurfaceMemberReference) Error!ir.CppSurfaceInstallation {
    return switch (value) {
        .function => |id| function: {
            const lowered = try surfaceFunction(n, id, .{ .named = member.options.function_name orelse member.propertyName() }, member.options.function_visibility, member.options.constructable);
            if (member.options.constructable) break :function .{ .value = .{ .function = lowered } };
            break :function switch (lowered) {
                .realm => .{ .value = .{ .function = lowered } },
                .builtin => |symbol| .{ .builtin = symbol },
                .native => |native| .{ .native = .{ .symbol = native.symbol, .length = native.length, .visibility = native.visibility } },
            };
        },
        .accessor => |accessor| switch (accessor) {
            .function => |pair| .{ .accessor = try surfaceAccessor(n, pair, member.propertyName(), true) },
            .builtin => return n.reject(member.propertyName(), "direct builtin accessors must use a function accessor: {s}", .{member.propertyName()}),
        },
        .lazy_owner => return n.reject(member.propertyName(), "direct lazy storage members are not supported: {s}", .{member.propertyName()}),
        .lazy_declaration, .object_value, .callable_value, .constant, .empty_collection, .self => .{ .value = try surfaceExpression(n, value, member, reference, member.options.function_name orelse member.propertyName()) },
    };
}

fn surfaceType(n: *const Normalizer, value: SurfaceMemberValue, self: ir.SurfaceType) ?ir.SurfaceType {
    return switch (value) {
        .function => |id| .{ .declaration = .{ .function = id } },
        .lazy_declaration => |declaration| switch (declaration) {
            .class => |id| .{ .declaration = .{ .class = id } },
            .function => |id| .{ .value = n.get(n.get(id).result_position).type },
            .native => |id| .{ .value = n.get(n.get(id).result_position).type },
        },
        .object_value => |id| .{ .object = id },
        .callable_value => |callable| .{ .callable = .{ .declaration = callable.declaration, .surface = callable.surface } },
        .accessor => |accessor| .{ .value = n.get(n.get(switch (accessor) {
            .builtin => |id| id,
            .function => |pair| pair.getter,
        }).result_position).type },
        .constant => |constant| .{ .constant = switch (constant) {
            .string => |text| .{ .string = text },
            .boolean => |boolean| .{ .boolean = boolean },
            .external_string => .string_type,
            .external_boolean => .boolean_type,
            .integer, .external_number => .number,
            .registered_symbol => .symbol,
            .undefined => .undefined,
        } },
        .empty_collection => |collection| .{ .collection = .{ .kind = collection.collection, .element = collection.element } },
        .self => self,
        .lazy_owner => null,
    };
}

fn typeScriptProperty(n: *Normalizer, output: *std.ArrayList(ir.SurfaceTypeScriptMember), key: ir.SurfacePropertyKey, read_only: bool, value: ir.SurfaceType) Error!void {
    const public_key: @FieldType(ir.SurfaceTypeScriptMember, "key") = switch (key) {
        .name => |name| .{ .name = name },
        .symbol => |symbol| typescript.key(.{ .symbol = symbol }) orelse return,
        .builtin_name, .engine_name, .engine_builtin_name => return,
    };
    try output.append(n.arena, .{ .key = public_key, .read_only = read_only, .type = value });
}

fn objectSurface(n: *Normalizer, surface: *const schema.ObjectSurface) Error!ir.ObjectSurface {
    const options = surface.options;
    const exposed = n.isExposed(options.exposure);
    const id: ir.ObjectSurfaceId = .of(n.object_surfaces.items.len);
    const members = try n.arena.alloc(ir.ObjectSurfaceMember, surface.members.len);
    var typescript_members: std.ArrayList(ir.SurfaceTypeScriptMember) = .empty;
    var member_count: u32 = 0;
    var has_supplemental_members = false;
    var has_global_static_members = false;
    for (surface.members, members, 0..) |member, *normalized, index| {
        const resolved = resolveMember(n, member);
        if (exposed and resolved.exposed) try requireSurfaceFactory(n, surface.name, member.propertyName(), resolved.value);
        normalized.* = try surfaceMember(n, member, resolved, options.installation, options.cpp_class, .{ .surface = id, .index = @intCast(index) }, member_count);
        if (resolved.typescript_exposed) {
            if (surfaceType(n, resolved.value, .{ .self_object = id })) |value| {
                try typeScriptProperty(n, &typescript_members, member.key, options.integrity == .frozen or !member.options.attributes.writable, value);
                for (member.options.aliases) |alias| try typeScriptProperty(n, &typescript_members, alias.key, options.integrity == .frozen or !alias.attributes.writable, value);
            }
        }
        if (!normalized.exposed) continue;
        if (normalized.installation == .table) member_count += 1;
        if (normalized.installation != .table or normalized.aliases.len != 0) has_supplemental_members = true;
        if (normalized.installation == .global) has_global_static_members = true;
    }
    return .{
        .surface_name = surface.name,
        .members = members,
        .typescript_members = typescript_members.items,
        .exposed = exposed,
        .installation = switch (options.installation) {
            .static_lookup => .{ .static_lookup = .{
                .table = try mod_surface_table.build(n, surface.name, members, member_count),
                .install = has_supplemental_members,
            } },
            .reified => .reified,
            .direct => .direct,
        },
        .global_class = if (has_global_static_members) options.cpp_class.? else null,
        .prototype = options.prototype,
        .integrity = options.integrity,
        .id = id,
    };
}

fn nativeModuleExport(n: *Normalizer, raw: schema.SurfaceMember, member: Member, reference: ?ir.SurfaceMemberReference, self_type: ir.SurfaceType) Error!ir.NativeModuleExport {
    const name = raw.propertyName();
    const aliases = try n.arena.alloc(ir.NativeModuleExportAlias, raw.options.aliases.len);
    for (raw.options.aliases, aliases) |alias, *normalized| normalized.* = .{ .name = alias.key.name, .attributes = alias.attributes };
    return .{
        .export_name = name,
        .operation = switch (member.value) {
            .accessor => |accessor| switch (accessor) {
                .function => |pair| .{ .accessor = try surfaceAccessor(n, pair, name, false) },
                .builtin => return n.reject(name, "native modules cannot export builtin accessors", .{}),
            },
            .lazy_owner => return n.reject(name, "native modules cannot export lazy owner storage", .{}),
            .function, .lazy_declaration, .object_value, .callable_value, .constant, .empty_collection, .self => .{ .value = try surfaceExpression(n, member.value, raw, switch (member.value) {
                .object_value, .callable_value => reference,
                else => null,
            }, raw.options.function_name orelse name) },
        },
        .type = surfaceType(n, member.value, self_type) orelse return n.reject(name, "native module export requires a declared value type", .{}),
        .aliases = aliases,
        .attributes = raw.options.attributes,
        .exposed = member.exposed,
        .typescript_exposed = member.typescript_exposed,
    };
}

fn nativeModuleSurface(n: *Normalizer, surface: *const schema.NativeModule) Error!ir.NativeModuleSurface {
    const options = surface.options;
    var visibility: MemberVisibility = .{};
    const default: @FieldType(ir.NativeModuleSurface, "default") = switch (options.default) {
        .declaration => |declaration| declared: {
            const target: ir.JavaScriptDeclarationRef = switch (declaration) {
                .function => |bound| .{ .function = visibility.function(n, bound) },
                .class => |bound| .{ .class = visibility.class(n, bound) },
            };
            break :declared .{ .declaration = .{
                .target = target,
                .value = switch (target) {
                    .function => |id| .{ .function = try surfaceFunction(n, id, .{ .named = options.default_name orelse n.get(id).function_name }, .public, true) },
                    .class => |id| .{ .constructor = id },
                },
                .installation = switch (options.default_surface) {
                    .none => null,
                    .install => .{ .self_property = if (options.attach_default_to_default) options.default_attributes else null },
                },
            } };
        },
        .namespace => .namespace,
    };
    const self_type: ir.SurfaceType = switch (default) {
        .declaration => |declaration| .{ .declaration = declaration.target },
        .namespace => .namespace,
    };
    const source: struct { members: []const schema.SurfaceMember, surface: ?ir.ObjectSurfaceId, exposure: ir.Exposure } = switch (surface.exports) {
        .surface => |object| .{ .members = object.members, .surface = objectSurfaceIdOf(n, object) orelse return n.reject(surface.name, "native modules require a declared export surface", .{}), .exposure = object.options.exposure },
        .members => |members| .{ .members = members, .surface = null, .exposure = .always },
    };
    visibility.exposure(n, options.exposure);
    visibility.exposure(n, source.exposure);
    const exposed = visibility.runtime;
    const exports = try n.arena.alloc(ir.NativeModuleExport, source.members.len);
    var named_export_count: u32 = 0;
    for (source.members, exports, 0..) |raw, *normalized, index| {
        const member = resolveMember(n, raw);
        if (exposed and member.exposed) try requireSurfaceFactory(n, surface.name, raw.propertyName(), member.value);
        normalized.* = try nativeModuleExport(n, raw, member, if (source.surface) |id| .{ .surface = id, .index = @intCast(index) } else null, self_type);
        if (normalized.exposed) named_export_count += 1 + @as(u32, @intCast(normalized.aliases.len));
    }
    return .{
        .surface_name = surface.name,
        .specifier = surface.specifier,
        .exports = exports,
        .default = default,
        .exposed = exposed,
        .typescript_exposed = visibility.typescript,
        .named_export_count = named_export_count,
    };
}

fn receiverIsPure(n: *const Normalizer, id: InputPlanId) bool {
    return switch (plans.plan(n, id).codec) {
        .js_value, .branded_value, .class_ref => true,
        .discarded => |discarded| n.rawType(plans.plan(n, id).type).discarded.match != .semantic_type or receiverIsPure(n, discarded.match),
        .converted => |converted| n.rawType(plans.plan(n, id).type).converted.converter.kind == .brand_cast and receiverIsPure(n, converted.match),
        .optional => |optional| receiverIsPure(n, optional.child),
        .union_type => |members| for (members) |member| {
            if (!receiverIsPure(n, member)) break false;
        } else true,
        else => false,
    };
}

fn requireSurfaceFactory(n: *Normalizer, owner: []const u8, name: []const u8, value: SurfaceMemberValue) Error!void {
    const id = switch (value) {
        .lazy_declaration => |declaration| switch (declaration) {
            .function => |function_id| function_id,
            .native => |native_id| return n.native_surface_exports.put(n.arena, native_id, {}),
            .class => return,
        },
        .function, .object_value, .callable_value, .accessor, .constant, .empty_collection, .lazy_owner, .self => return,
    };
    const function = n.get(id);
    const location = try n.print("{s}.{s}", .{ owner, name });
    if (function.backend == .builtin or function.isOverloaded() or function.class_member != null or
        function.args.len != 0 or function.callback_data_type != null or function.new_target_argument != null or
        function.callee_argument != null or function.has_caller_source_location)
        return n.fail(location, "lazy surface factories require native functions without JavaScript call-frame parameters: {s}", .{name});
    if (function.this_argument) |receiver| {
        if (!receiverIsPure(n, n.get(receiver.position).input))
            return n.fail(location, "lazy surface factory receivers require a pure value or class match: {s}", .{name});
    }
    try n.surface_factories.put(n.arena, id, {});
}

/// Surface values reference earlier surfaces, so one pass in declaration
/// order closes the relation.
fn surfacePlans(n: *Normalizer) Error!void {
    const count = n.object_surfaces.items.len;
    const Usage = struct {
        required: bool = false,
        owned: bool = false,
        object_value: bool = false,
        typescript: bool = false,
        header_roots: std.ArrayList(ir.ObjectSurfaceId) = .empty,
    };
    const usage = try n.arena.alloc(Usage, count);
    @memset(usage, .{});
    const reach = try n.arena.alloc(std.DynamicBitSetUnmanaged, count);
    for (n.object_surfaces.items, n.declared_object_surfaces.items, 0..) |surface, raw, root| {
        if (normalize.isTypeScriptExposed(raw.options.exposure)) {
            for (surface.typescript_members) |member| {
                if (typeScriptSurface(member.type)) |id| usage[id.index].typescript = true;
            }
        }
        reach[root] = try .initEmpty(n.arena, count);
        reach[root].set(root);
        for (surface.members, raw.members) |member, source| {
            if (!member.exposed) continue;
            const dependency = switch (source.value) {
                .object_value => |object| objectSurfaceIdOf(n, object).?.index,
                .callable_value => |callable| objectSurfaceIdOf(n, callable.surface).?.index,
                else => continue,
            };
            if (dependency >= root) {
                try n.fail(surface.surface_name, "object surface dependency does not precede its root: {s} -> {s}", .{
                    surface.surface_name,
                    n.object_surfaces.items[dependency].surface_name,
                });
                continue;
            }
            reach[root].setUnion(reach[dependency]);
            if (source.value == .object_value) usage[dependency].object_value = true;
        }
        if (surface.exposed) {
            var dependencies = reach[root].iterator(.{});
            while (dependencies.next()) |dependency| try usage[dependency].header_roots.append(n.arena, surface.id);
        }
    }
    for (n.native_module_surfaces.items, n.declared_native_modules.items) |surface, declared| {
        if (surface.typescript_exposed) {
            for (surface.exports) |module_export| {
                if (module_export.typescript_exposed) {
                    if (typeScriptSurface(module_export.type)) |id| usage[id.index].typescript = true;
                }
            }
        }
        if (!surface.exposed) continue;
        const members = switch (declared.native_module.exports) {
            .surface => |object| members_from_surface: {
                usage[objectSurfaceIdOf(n, object).?.index].owned = true;
                break :members_from_surface object.members;
            },
            .members => |members| members,
        };
        for (surface.exports, members) |module_export, member| {
            if (!module_export.exposed) continue;
            const referenced = switch (member.value) {
                .object_value => |source| objectSurfaceIdOf(n, source).?,
                .callable_value => |callable| objectSurfaceIdOf(n, callable.surface).?,
                else => continue,
            };
            var dependencies = reach[referenced.index].iterator(.{});
            while (dependencies.next()) |dependency| usage[dependency].required = true;
        }
    }
    var headers: std.StringArrayHashMapUnmanaged(void) = .empty;
    var typescript_surfaces: std.ArrayList(ir.ObjectSurfaceId) = .empty;
    for (n.object_surfaces.items, n.declared_object_surfaces.items, usage) |surface, raw, needed| {
        if (needed.typescript and normalize.isTypeScriptExposed(raw.options.exposure)) try typescript_surfaces.append(n.arena, surface.id);
        if (!needed.required) continue;
        for (surface.members, raw.members) |member, source| {
            if (member.exposed and source.options.header.len != 0) try headers.put(n.arena, source.options.header, {});
        }
    }
    for (n.native_module_surfaces.items, n.declared_native_modules.items) |surface, declared| {
        if (!surface.exposed) continue;
        const members = switch (declared.native_module.exports) {
            .surface => |source| source.members,
            .members => |members| members,
        };
        for (surface.exports, members) |module_export, member| {
            const header = member.options.header;
            if (module_export.exposed and header.len != 0) try headers.put(n.arena, header, {});
        }
    }
    const complete = try n.arena.alloc(ir.ObjectSurfacePlan, count);
    for (usage, complete) |needed, *output| {
        output.* = .{
            .owned_by_native_modules = needed.owned,
            .used_as_object_value = needed.object_value,
            .header_roots = needed.header_roots.items,
        };
    }
    n.object_surface_plans = complete;
    n.typescript_object_surfaces = typescript_surfaces.items;
    n.native_module_headers = headers.keys();
}

fn typeScriptSurface(value: ir.SurfaceType) ?ir.ObjectSurfaceId {
    return switch (value) {
        .object => |id| id,
        .callable => |callable| callable.surface,
        .declaration, .value, .self_object, .namespace, .constant, .collection => null,
    };
}
