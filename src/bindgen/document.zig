const std = @import("std");
const ir = @import("bindgen_ir");
const structural = @import("structural.zig");

pub const Binding = struct {
    target: ir.Target,
    focused_integrations: []const []const u8,
    modules: []const Module,
    types: []const Type,
    enumerations: []const EnumerationType,
    nominal_ownerships: []const NominalOwnership,
    external_refs: []const ExternalRef,
    promise_reactions: []const PromiseReactionContext,
    wire_types: []const WireType,
    inbound_argument_plans: []const Plan(.inbound_argument),
    inbound_result_plans: []const Plan(.inbound_result),
    outbound_argument_plans: []const Plan(.outbound_argument),
    outbound_result_plans: []const Plan(.outbound_result),
    api_types: []const ApiType,
    domain_errors: []const ir.DomainError,
    completions: []const CompletionPlan,
    cpp_completion_apis: []const CppCompletionApi,
    functions: []const Function,
    overload_cases: []const Function,
    classes: []const Class,
    structured_clones: []const StructuredClonePlan,
    engine_shims: []const EngineShim,
    native_exports: []const NativeExport,
    callbacks: []const Callback,
    brands: []const Brand,
    inbound_argument_fields: []const FieldSet(.inbound_argument),
    inbound_result_fields: []const FieldSet(.inbound_result),
    outbound_argument_fields: []const FieldSet(.outbound_argument),
    outbound_result_fields: []const FieldSet(.outbound_result),
    inbound_argument_members: []const MemberSet(.inbound_argument),
    inbound_result_members: []const MemberSet(.inbound_result),
    outbound_argument_members: []const MemberSet(.outbound_argument),
    outbound_result_members: []const MemberSet(.outbound_result),
    inbound_argument_call_plans: []const CallPlan(.inbound_argument),
    outbound_argument_call_plans: []const CallPlan(.outbound_argument),
};

pub const Module = Select(ir.Module, .{ "module_name", "declarations", "class_declarations", "engine_declarations", "native_declarations" }, .{});

pub const Type = struct {
    data: TypeData,
    argument: ?ir.InboundArgumentPlanId,
    result: ?ir.InboundResultPlanId,
};

pub const TypeData = union(ir.TypeKind) {
    void,
    boolean,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    usize,
    f64,
    any,
    discarded,
    lazy: ir.TypeId,
    converted: struct { native_type: ir.TypeId },
    dom_string: String,
    usv_string: String,
    byte_string: String,
    utf8_string,
    node_path,
    buffer: ir.BufferType,
    native_slice: ir.NativeSliceType,
    callback: ir.CallbackId,
    optional: ir.OptionalType,
    enumeration: ir.EnumerationId,
    dictionary: struct { dictionary_name: []const u8, dictionary_fields: []const DictionaryField },
    union_type: struct { union_name: []const u8, union_members: []const UnionMember },
    sequence: struct { child: ir.TypeId },
    record: struct { key_type: ir.TypeId, value_type: ir.TypeId },
    nominal_handle: NominalHandle,
    class_ref: struct { class: ir.ClassId },
    external_ref: ir.ExternalRefId,
    branded_value: struct { brand: BrandId, promise_reaction: ?ir.PromiseReactionId },
    engine_value,
    native_instance,
};

const String = struct { string_thread_safe: bool };
pub const BrandId = ir.Id("brands");
pub const Brand = struct { brand_name: []const u8, promise_value_type: ?ir.TypeId, constructor_class: ?ir.ClassId };
pub const PromiseReactionContext = Select(ir.PromiseReactionContext, .{ "create", "adopt", "attach", "take", "destroy" }, .{});
pub const EnumerationValue = ir.EnumerationValue;
pub const EnumerationType = Select(ir.EnumerationType, .{ "enumeration_name", "enumeration_values", "tag" }, .{ .enumeration_values = []const EnumerationValue });
pub const DictionaryField = ir.DictionaryField;
pub const UnionMember = Select(ir.UnionMember, .{ "member_name", "member_type" }, .{});
pub const NominalOwnership = Select(ir.NominalOwnership, .{ "destroy_thread", "release_symbol", "byte_access" }, .{ .byte_access = ?struct { symbol: []const u8 } });
const NominalHandle = Select(ir.NominalHandleType, .{ "nominal_handle_name", "const_pointee", "zig_type", "wire" }, .{});
const ExternalRef = Select(ir.ExternalRef, .{ "external_name", "zig_type", "brand", "wire", "clone_symbol", "release_symbol" }, .{ .brand = ?BrandId });

pub const WireType = union(enum) {
    scalar: ir.WireScalar,
    pointer: ir.WirePointer,
    opaque_handle: ir.WireName,
    forward_structure: ir.WireName,
    alias: ir.WireAlias,
    structure: ir.WireAggregate,
    @"union": ir.WireAggregate,
    function_pointer: ir.WireFunctionPointer,
    function: WireFunction,
};

pub const WireFunction = struct {
    name: ir.WireName,
    result: ir.WireTypeId,
    parameters: []const ir.WireField,
    non_returning: bool,
    inline_definition: bool,
};

pub fn FieldsId(comptime role: ir.Role) type {
    return ir.Id(@tagName(role) ++ "_fields");
}
pub fn MembersId(comptime role: ir.Role) type {
    return ir.Id(@tagName(role) ++ "_members");
}
pub fn CallPlanId(comptime role: ir.Role) type {
    return ir.Id(@tagName(role) ++ "_call_plans");
}
pub fn FieldSet(comptime role: ir.Role) type {
    return struct { type: ir.TypeId, values: []const role.PlanId() };
}
pub const MemberSet = FieldSet;

pub fn Plan(comptime role: ir.Role) type {
    return Select(role.Plan(), if (role == .inbound_argument or role == .outbound_argument) .{ "api", "type", "wire", "representation", "zig", "transfer" } else .{ "api", "type", "wire", "representation", "zig" }, .{
        .representation = Representation(role),
    });
}

/// A position's composite structure. The bind reads leaf behavior from the
/// plan's `zig.leaf`, so leaves carry no payload here.
pub fn Representation(comptime role: ir.Role) type {
    const Source = ir.Representation(role);
    const source_names = @typeInfo(Source).@"union".field_names;
    var names: [source_names.len][]const u8 = undefined;
    var values: [source_names.len]u8 = undefined;
    var types: [source_names.len]type = undefined;
    var count: usize = 0;
    for (source_names, 0..) |name, index| {
        const Field = @FieldType(Source, name);
        if (Field == noreturn) continue;
        names[count] = name;
        values[count] = index;
        types[count] = if (std.mem.eql(u8, name, "leaf")) void else BindingData(Field);
        count += 1;
    }
    const Tag = @Enum(u8, .exhaustive, names[0..count], values[0..count]);
    return @Union(.auto, Tag, names[0..count], types[0..count], &@splat(.{}));
}

pub const ApiType = ir.ApiType;

pub fn Argument(comptime role: ir.Role) type {
    return Select(ir.Argument(role), .{ "argument_name", "position", "value_position", "optional" }, .{
        .value_position = role.PlanId(),
        .optional = bool,
    });
}

pub const CompletionPlan = ir.CompletionPlan;
pub const CppCompletionApi = Select(ir.CppCompletionApi, .{ "handle", "create", "clone", "release", "finish", "settle" }, .{});
pub const CallPlan = ir.CallPlan;

pub const ClassMemberFacts = Select(ir.ClassMemberFacts, .{ "member_kind", "is_illegal", "native_reference_symbol" }, .{});

pub const Function = Select(ir.Function, .{
    "module_name",     "function_name",      "args",                       "case_name",                   "overload_cases", "backend",
    "domain_errors",   "completion",         "result_position",            "call_plan",                   "invocation_args",
    "callback_data_type", "has_caller_source_location", "is_promise_reaction_handler", "class_member",   "implementation_name",
    "js_name",         "dispatch_symbol",    "host_symbol",                "wire_args",                   "wire_result",    "destroy_result_symbol",
    "js_length",       "exposed",
}, .{
    .args = []const Argument(.inbound_argument),
    .class_member = ?ClassMemberFacts,
    .call_plan = CallPlanId(.inbound_argument),
    .invocation_args = []const Argument(.inbound_argument),
});

pub const OutboundCall = struct {
    args: []const Argument(.outbound_argument),
    result_position: ir.OutboundResultPlanId,
    call_plan: CallPlanId(.outbound_argument),
    wire_args: ir.WireTypeId,
    wire_result: ir.WireTypeId,
    thunk_symbol: []const u8,
};
pub const EngineShim = Select(ir.EngineShim, .{ "module_name", "shim_name", "outbound", "destroy_result_symbol" }, .{ .outbound = OutboundCall });
pub const NativeExport = Select(ir.NativeExport, .{ "module_name", "export_name", "args", "exposed", "domain_errors", "result_position", "call_plan", "wire_args", "wire_result", "dispatch_symbol", "destroy_result_symbol" }, .{
    .args = []const Argument(.inbound_argument),
    .call_plan = CallPlanId(.inbound_argument),
});
pub const Callback = struct {
    type: ir.TypeId,
    callback_name: []const u8,
    outbound: OutboundCall,
    schedule_symbol: ?[]const u8,
};
pub const CachedSlot = ir.CachedSlot;
pub const InstanceProperty = ir.InstanceProperty;
pub const ClassRuntimePlan = struct {
    ownership: ir.ClassOwnershipPlan,
    native_generation: ?[]const u8,
    finalization: ir.ClassFinalizationPlan,
    construction: struct { initialize_external_native: ?[]const u8, wrapper_created: ?[]const u8 },
};
pub const StructuredClonePlan = Select(ir.StructuredClonePlan, .{ "serialization", "serialize_symbol", "deserialize_symbol" }, .{});
pub const Class = Select(ir.Class, .{
    "module_name",            "class_name",      "brand",                  "representation",         "runtime_plan",          "parent",                        "upcast",                      "instance_properties",
    "create_symbol",          "memory_usage",    "pending_activity",       "structured_clone",       "constructor_call",      "slots",                         "declarations",                "exposed",
    "get_constructor_symbol", "try_cast_symbol", "try_cast_direct_symbol", "wrap_native_symbol",     "destroy_native_symbol", "destroy_pending_native_symbol", "release_native_on_vm_symbol", "native_type_symbol_prefix",
    "constructor",            "value_type",      "instance_value_type",    "constructor_value_type",
}, .{
    .brand = ?BrandId,
    .representation = ir.ClassRepresentation,
    .instance_value_type = ?ir.TypeId,
    .constructor_value_type = ?ir.TypeId,
    .runtime_plan = ClassRuntimePlan,
    .instance_properties = []const InstanceProperty,
    .slots = []const CachedSlot,
});

pub fn create(arena: std.mem.Allocator, source: *const ir.Ir) std.mem.Allocator.Error!Binding {
    var builder: Builder = .{ .arena = arena, .source = source };
    var binding: Binding = undefined;
    inline for (@typeInfo(Binding).@"struct".field_names) |name| {
        if (comptime @hasField(Builder, name)) continue;
        if (comptime std.mem.eql(u8, name, "focused_integrations")) {
            var paths: std.ArrayList([]const u8) = .empty;
            for (source.modules) |module| for (module.focused_integrations) |integration| {
                if (integration.integration_options.backend == .zig) try paths.append(arena, integration.integration_options.implementation);
            };
            binding.focused_integrations = paths.items;
            continue;
        }
        @field(binding, name) = try builder.project(@FieldType(Binding, name), @field(source.*, name), null);
    }
    inline for (@typeInfo(Binding).@"struct".field_names) |name| {
        if (comptime @hasField(Builder, name)) @field(binding, name) = @field(builder, name).values.keys();
    }
    return structural.Graph(.{
        ir.TypeId,
        ir.InboundArgumentPlanId,
        ir.InboundResultPlanId,
        ir.OutboundArgumentPlanId,
        ir.OutboundResultPlanId,
        ir.ApiTypeId,
        ir.DomainErrorId,
        ir.EnumerationId,
        ir.NominalOwnershipId,
        ir.ExternalRefId,
        ir.PromiseReactionId,
        ir.WireTypeId,
        ir.CppCompletionApiId,
        BrandId,
        FieldsId(.inbound_argument),
        FieldsId(.inbound_result),
        FieldsId(.outbound_argument),
        FieldsId(.outbound_result),
        MembersId(.inbound_argument),
        MembersId(.inbound_result),
        MembersId(.outbound_argument),
        MembersId(.outbound_result),
        CallPlanId(.inbound_argument),
        CallPlanId(.outbound_argument),
    }).intern(arena, binding);
}

fn Select(comptime Source: type, comptime fields: anytype, comptime overrides: anytype) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |name, index| {
        names[index] = name;
        types[index] = if (@hasField(@TypeOf(overrides), name)) @field(overrides, name) else @FieldType(Source, name);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn BindingData(comptime T: type) type {
    return BindingType(T).Value;
}

fn BindingType(comptime T: type) type {
    return struct {
        const Value = result: {
            for (std.enums.values(ir.Role)) |role| {
                if (T == []const ir.PositionField(role)) break :result FieldsId(role);
                if (T == []const ir.PositionMember(role)) break :result MembersId(role);
            }
            break :result switch (@typeInfo(T)) {
                .optional => |optional| ?BindingData(optional.child),
                .pointer => |pointer| if (BindingData(pointer.child) == pointer.child) T else []const BindingData(pointer.child),
                inline .@"struct", .@"union" => |info| fields: {
                    const names = info.field_names;
                    var types: [names.len]type = undefined;
                    var changed = false;
                    for (names, 0..) |name, index| {
                        types[index] = BindingData(@FieldType(T, name));
                        changed = changed or types[index] != @FieldType(T, name);
                    }
                    if (!changed) break :fields T;
                    break :fields switch (@typeInfo(T)) {
                        .@"struct" => @Struct(.auto, null, names, &types, &@splat(.{})),
                        .@"union" => |u| @Union(.auto, u.tag_type, names, &types, &@splat(.{})),
                        else => unreachable,
                    };
                },
                else => T,
            };
        };
    };
}

fn Pool(comptime Value: type, comptime Id: type) type {
    return struct {
        values: structural.OrderedMap(Value, void) = .empty,

        fn intern(pool: *@This(), arena: std.mem.Allocator, value: Value) std.mem.Allocator.Error!Id {
            return .of((try pool.values.getOrPut(arena, value)).index);
        }
    };
}

const Builder = struct {
    arena: std.mem.Allocator,
    source: *const ir.Ir,
    brands: Pool(Brand, BrandId) = .{},
    inbound_argument_fields: Pool(FieldSet(.inbound_argument), FieldsId(.inbound_argument)) = .{},
    inbound_result_fields: Pool(FieldSet(.inbound_result), FieldsId(.inbound_result)) = .{},
    outbound_argument_fields: Pool(FieldSet(.outbound_argument), FieldsId(.outbound_argument)) = .{},
    outbound_result_fields: Pool(FieldSet(.outbound_result), FieldsId(.outbound_result)) = .{},
    inbound_argument_members: Pool(MemberSet(.inbound_argument), MembersId(.inbound_argument)) = .{},
    inbound_result_members: Pool(MemberSet(.inbound_result), MembersId(.inbound_result)) = .{},
    outbound_argument_members: Pool(MemberSet(.outbound_argument), MembersId(.outbound_argument)) = .{},
    outbound_result_members: Pool(MemberSet(.outbound_result), MembersId(.outbound_result)) = .{},
    inbound_argument_call_plans: Pool(CallPlan(.inbound_argument), CallPlanId(.inbound_argument)) = .{},
    outbound_argument_call_plans: Pool(CallPlan(.outbound_argument), CallPlanId(.outbound_argument)) = .{},

    /// Normalization gives each brand name one matcher, so dropping it merges
    /// only brands that are the same.
    fn brand(b: *Builder, value: ir.Brand) std.mem.Allocator.Error!BrandId {
        const projected: Brand = .{ .brand_name = value.brand_name, .promise_value_type = value.promise_value_type, .constructor_class = value.constructor_class };
        return b.brands.intern(b.arena, projected);
    }

    fn project(b: *Builder, comptime T: type, value: anytype, inherited_owner: ?ir.TypeId) std.mem.Allocator.Error!T {
        const source = b.source;
        const arena = b.arena;
        const owner = owner: {
            inline for (std.enums.values(ir.Role)) |role| if (@TypeOf(value) == role.Plan()) break :owner value.type;
            break :owner inherited_owner;
        };
        if (T == @TypeOf(value)) return value;
        if (T == void) return {};
        if (T == ir.ClassRepresentation) return std.meta.activeTag(value);
        if (T == BrandId) return b.brand(value);
        inline for (std.enums.values(ir.Role)) |role| {
            if (T == FieldsId(role) or T == MembersId(role)) {
                // The bind reads names and optionality from the owner's semantic type.
                const owner_data = source.types[owner.?.index].data;
                if (T == FieldsId(role)) {
                    for (owner_data.dictionary.dictionary_fields, value) |declaration, field| {
                        if (!std.mem.eql(u8, declaration.field_name, field.name) or field.optional != (declaration.storage == .optional))
                            @panic("dictionary positions disagree with their type");
                    }
                } else {
                    for (owner_data.union_type.union_members, value) |declaration, member| {
                        if (!std.mem.eql(u8, declaration.member_name, member.name)) @panic("union positions disagree with their type");
                    }
                }
                const children = try arena.alloc(role.PlanId(), value.len);
                for (value, children) |child, *id| id.* = child.value;
                const data: FieldSet(role) = .{ .type = owner.?, .values = children };
                return if (T == FieldsId(role)) @field(b, @tagName(role) ++ "_fields").intern(arena, data) else @field(b, @tagName(role) ++ "_members").intern(arena, data);
            }
            if (T == Representation(role)) return switch (value) {
                .leaf => .leaf,
                inline else => |payload, tag| if (comptime @hasField(T, @tagName(tag)))
                    @unionInit(T, @tagName(tag), try b.project(@FieldType(T, @tagName(tag)), payload, owner))
                else
                    unreachable,
            };
        }

        inline for (.{ ir.Role.inbound_argument, ir.Role.outbound_argument }) |role| {
            if (T == Argument(role)) return .{
                .argument_name = value.argument_name,
                .position = value.position,
                .value_position = value.valuePosition(),
                .optional = value.isOptional(),
            };
            if (T == CallPlanId(role)) {
                const call = try b.project(CallPlan(role), value, owner);
                return @field(b, @tagName(role) ++ "_call_plans").intern(arena, call);
            }
        }
        if (T == Type) return .{
            .data = try b.project(TypeData, value.data, value.id),
            .argument = source.argumentPosition(value.id),
            .result = source.resultPosition(value.id),
        };
        if (T == ClassRuntimePlan) return .{
            .ownership = value.ownership,
            .native_generation = switch (value.identity) {
                .per_realm_registry => |symbol| symbol,
                .plain_value, .fresh_wrapper, .engine_constructor_only, .engine_wrapper_cache => null,
            },
            .finalization = value.finalization,
            .construction = .{
                .initialize_external_native = switch (value.construction.external_initialization) {
                    .native_subclass, .root_native_subclass => |symbol| symbol,
                    .none => null,
                },
                .wrapper_created = value.construction.wrapper_created,
            },
        };
        if (T == Callback) {
            const call = source.callback_calls[value.id.index];
            return .{
                .type = value.type,
                .callback_name = value.callback_name,
                .outbound = try b.project(OutboundCall, call, null),
                .schedule_symbol = for (call.entries) |entry| {
                    if (entry.callee == .schedule) break entry.symbol;
                } else null,
            };
        }
        return switch (@typeInfo(T)) {
            .optional => |optional| if (value) |child| try b.project(optional.child, child, owner) else null,
            .pointer => |pointer| pointer: {
                const items = try arena.alloc(pointer.child, value.len);
                for (value, items) |item, *output| output.* = try b.project(pointer.child, item, owner);
                break :pointer items;
            },
            .@"struct" => |info| object: {
                var output: T = undefined;
                inline for (info.field_names) |name| {
                    @field(output, name) = if (comptime T == Class and (std.mem.eql(u8, name, "instance_value_type") or std.mem.eql(u8, name, "constructor_value_type")))
                        @field(source.class_relations[value.id.index], name)
                    else if (comptime T == WireFunction and std.mem.eql(u8, name, "inline_definition"))
                        value.body != .declaration
                    else if (comptime T == EngineShim and std.mem.eql(u8, name, "destroy_result_symbol"))
                        if (source.cpp_engine_entries[value.id.index] != null) value.destroy_result_symbol else null
                    else if (comptime T == OutboundCall and std.mem.eql(u8, name, "thunk_symbol"))
                        value.entries[0].symbol
                    else if (comptime T == Function and std.mem.eql(u8, name, "invocation_args")) arguments: {
                        var arguments: std.ArrayList(Argument(.inbound_argument)) = .empty;
                        inline for (.{ value.this_argument, value.new_target_argument, value.callee_argument }) |optional| {
                            if (optional) |argument| try arguments.append(arena, try b.project(Argument(.inbound_argument), argument, owner));
                        }
                        break :arguments arguments.items;
                    } else
                        try b.project(@FieldType(T, name), @field(value, name), owner);
                }
                break :object output;
            },
            .@"union" => tagged: {
                switch (value) {
                    inline else => |payload, tag| break :tagged @unionInit(T, @tagName(tag), try b.project(@FieldType(T, @tagName(tag)), payload, owner)),
                }
            },
            else => @compileError("binding document projection has incompatible field types"),
        };
    }
};
