//! Comptime views of the binding IR the generator serializes. Each view is a
//! type keyed by IR data, so a semantic type, plan, or declaration has
//! exactly one view and views compare by identity.
const std = @import("std");
const ir = @import("bindgen_ir");
const doc = @import("document.zig");
const Manifest = @This();

// Read metadata through comptime calls so it never becomes an addressable runtime constant.
pub fn binding() doc.Binding {
    if (!@inComptime()) @compileError("binding metadata is only available at comptime");
    return @import("binding_ir");
}

pub inline fn get(comptime id: anytype) @typeInfo(@FieldType(doc.Binding, @TypeOf(id).table)).pointer.child {
    return comptime @field(binding(), @TypeOf(id).table)[id.index];
}

pub const function_count = binding().functions.len;
pub const engine_shim_count = binding().engine_shims.len;

fn PositionFieldView(comptime role: ir.Role) type {
    return struct { name: []const u8, value: role.PlanId(), optional: bool };
}
fn PositionMemberView(comptime role: ir.Role) type {
    return struct { name: []const u8, value: role.PlanId() };
}

pub inline fn positionFields(comptime id: anytype) [get(id).values.len]PositionFieldView(@TypeOf(id).role) {
    return comptime fields: {
        const set = get(id);
        const declarations = SemanticType(set.type).dictionary_fields;
        var result: [set.values.len]PositionFieldView(@TypeOf(id).role) = undefined;
        for (declarations, set.values, &result) |declaration, value, *field| field.* = .{
            .name = declaration.field_name,
            .value = value,
            .optional = declaration.storage == .optional,
        };
        break :fields result;
    };
}

pub inline fn positionMembers(comptime id: anytype) [get(id).values.len]PositionMemberView(@TypeOf(id).role) {
    return comptime fields: {
        const set = get(id);
        const declarations = SemanticType(set.type).union_members;
        var result: [set.values.len]PositionMemberView(@TypeOf(id).role) = undefined;
        for (declarations, set.values, &result) |declaration, value, *member| member.* = .{ .name = declaration.member_name, .value = value };
        break :fields result;
    };
}

/// Branch quota of the declarations that build arrays of views or scan IR
/// tables; view constructors themselves stay quota-free so their calls
/// remain memoizable.
const eval_branch_quota = 1_000_000;

fn typeOf(comptime id: ir.TypeId) doc.Type {
    return binding().types[id.index];
}

/// Whether `T` is a semantic type view.
pub fn isSemanticType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "bindgen_ir_type"),
        else => false,
    };
}

pub fn requireSemanticType(comptime T: type) void {
    if (comptime !isSemanticType(T)) @compileError("expected a binding semantic type, found " ++ @typeName(T));
}

// ─── semantic types ───

pub fn SemanticType(comptime id: ir.TypeId) type {
    const t = typeOf(id);
    const data = t.data;
    const payload = switch (comptime data) {
        .external_ref => |external| get(external),
        .enumeration => |enumeration| get(enumeration),
        inline .void, .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64, .any, .discarded, .lazy, .converted, .dom_string, .usv_string, .byte_string, .utf8_string, .node_path, .buffer, .native_slice, .callback, .optional, .dictionary, .union_type, .sequence, .record, .nominal_handle, .class_ref, .branded_value, .engine_value, .native_instance => |value| value,
    };
    const View = struct {
        pub const bindgen_ir_type = {};
        pub const type_id = id;
        pub const kind = std.meta.activeTag(t.data);
        pub const string_kind: ir.StringKind = @field(ir.StringKind, @tagName(std.meta.activeTag(t.data)));
        pub const string_thread_safe = payload.string_thread_safe;
        pub const native_slice_element = payload.native_slice_element;
        pub const native_slice_access = payload.native_slice_access;
        pub const buffer_access = payload.buffer_access;
        pub const buffer_result_representation = payload.buffer_result_representation;
        pub const const_pointee = payload.const_pointee;
        pub const ConvertedValue = SemanticType(payload.native_type);
        pub const PromiseValueType = if (data == .branded_value) if (get(payload.brand).promise_value_type) |value| SemanticType(value) else void else void;

        pub const child = SemanticType(switch (data) {
            .lazy => |child_id| child_id,
            .optional => |optional| optional.child,
            .sequence => |sequence| sequence.child,
            else => @compileError("binding type has no child type"),
        });

        pub const Brand = switch (data) {
            .branded_value => |branded| BrandView(branded.brand),
            .external_ref => |external| if (get(external).brand) |brand| BrandView(brand) else void,
            else => @compileError("binding type has no brand"),
        };
        pub const has_brand = Brand != void;
        pub const promise_reaction = promiseReaction(data);
        pub const is_promise_reaction_context = promise_reaction != null;

        pub const nominal_handle_name = payload.nominal_handle_name;
        pub const nominal_handle_wire = payload.wire;
        pub const zig_type = switch (data) {
            .nominal_handle => |handle| handle.zig_type,
            .external_ref => |external| get(external).zig_type,
            else => @compileError("binding type has no Zig type"),
        };

        pub const external_name = payload.external_name;
        pub const external_handle_wire = payload.wire;
        pub const external_clone_symbol = payload.clone_symbol;
        pub const external_release_symbol = payload.release_symbol;

        pub const ReferencedClass = Class(payload.class);

        pub const optional_mode = payload.optional_mode;

        pub const enumeration_name = payload.enumeration_name;
        pub const enumeration_values = payload.enumeration_values;

        pub const Native = switch (data) {
            .enumeration => |enumeration| native: {
                @setEvalBranchQuota(eval_branch_quota);
                break :native EnumerationNative(get(enumeration));
            },
            .nominal_handle => @This(),
            else => @compileError("binding type has no native representation"),
        };

        pub const dictionary_name = payload.dictionary_name;
        pub const dictionary_fields = typeViews(payload.dictionary_fields, DictionaryField);

        pub const union_name = payload.union_name;
        pub const union_members = typeViews(payload.union_members, UnionMember);

        pub const KeyType = SemanticType(payload.key_type);
        pub const ValueType = SemanticType(payload.value_type);

        pub const callback_name = binding().callbacks[payload.index].callback_name;
        pub const ReturnType = SemanticType(get(binding().callbacks[payload.index].outbound.result_position).type);

        pub const callback_id = payload;
        pub const args = typeViews(binding().callbacks[payload.index].outbound.args, Argument);
    };
    return View;
}

fn promiseReaction(comptime data: doc.TypeData) ?doc.PromiseReactionContext {
    return switch (data) {
        .branded_value => |value| if (value.promise_reaction) |id| get(id) else null,
        .void, .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64, .any, .discarded, .lazy, .converted, .dom_string, .usv_string, .byte_string, .utf8_string, .node_path, .buffer, .native_slice, .callback, .optional, .enumeration, .dictionary, .union_type, .sequence, .record, .nominal_handle, .class_ref, .external_ref, .engine_value, .native_instance => null,
    };
}

fn EnumerationNative(comptime enumeration: doc.EnumerationType) type {
    const count = enumeration.enumeration_values.len;
    const Tag = switch (enumeration.tag) {
        .u8 => u8,
        .u16 => u16,
    };
    var names: [count][]const u8 = undefined;
    var values: [count]Tag = undefined;
    for (enumeration.enumeration_values, &names, &values) |value, *name, *native| {
        name.* = value.value_name;
        native.* = @intCast(value.native_value);
    }
    return EnumFromValues(Tag, count, names, values);
}

/// Keyed by value so enumerations declaring the same values share one native type.
fn EnumFromValues(comptime Tag: type, comptime count: usize, comptime names: [count][]const u8, comptime values: [count]Tag) type {
    return @Enum(Tag, .exhaustive, &names, &values);
}

fn typeViews(comptime values: anytype, comptime View: anytype) [values.len]type {
    @setEvalBranchQuota(eval_branch_quota);
    var views: [values.len]type = undefined;
    for (values, &views) |value, *view| view.* = View(value);
    return views;
}

fn DictionaryField(comptime field: doc.DictionaryField) type {
    const View = struct {
        pub const field_name = field.field_name;
        pub const FieldType = SemanticType(field.field_type);
        pub const storage = field.storage;
    };
    return View;
}

fn UnionMember(comptime member: doc.UnionMember) type {
    const View = struct {
        pub const member_name = member.member_name;
        pub const MemberType = SemanticType(member.member_type);
    };
    return View;
}

fn BrandView(comptime id: doc.BrandId) type {
    const brand = get(id);
    const View = struct {
        pub const brand_name = brand.brand_name;
        pub const is_promise = brand.promise_value_type != null;
        pub const PromiseValueType = if (brand.promise_value_type) |value| SemanticType(value) else void;
        pub const constructor_class = brand.constructor_class;
    };
    return View;
}

// Each lookup by name scans its IR table once, in a declaration of a type
// keyed by the name.

fn NamedLookup(comptime Id: type, comptime name_field: []const u8, comptime noun: []const u8, comptime name: []const u8) type {
    return struct {
        pub const id: Id = found: {
            @setEvalBranchQuota(eval_branch_quota);
            for (@field(binding(), Id.table), 0..) |candidate, index| {
                if (std.mem.eql(u8, @field(candidate, name_field), name)) break :found .of(index);
            }
            @compileError("binding manifest has no " ++ noun ++ " named " ++ name);
        };
    };
}

const ModuleTable = enum { functions, classes, engine_shims, native_exports };

fn ModuleDeclarationLookup(comptime module_id: ir.ModuleId, comptime table: ModuleTable, comptime name: []const u8) type {
    const fields = switch (table) {
        .functions => .{ "declarations", "function_name", "function" },
        .classes => .{ "class_declarations", "class_name", "class" },
        .engine_shims => .{ "engine_declarations", "shim_name", "engine shim" },
        .native_exports => .{ "native_declarations", "export_name", "native export" },
    };
    const module = get(module_id);
    const ids = @field(module, fields[0]);
    return struct {
        pub const id: std.meta.Elem(@TypeOf(ids)) = found: {
            @setEvalBranchQuota(eval_branch_quota);
            for (ids) |candidate| {
                if (std.mem.eql(u8, @field(get(candidate), fields[1]), name)) break :found candidate;
            }
            @compileError("binding schema " ++ module.module_name ++ " has no " ++ fields[2] ++ " named " ++ name);
        };
    };
}

/// A class member by JavaScript name, and by kind when an accessor pair
/// shares the name.
fn ClassMemberLookup(comptime class_id: ir.ClassId, comptime member_name: []const u8, comptime kind: ?ir.ClassMemberKind) type {
    const Lookup = struct {
        pub const id: ir.FunctionId = found: {
            @setEvalBranchQuota(eval_branch_quota);
            var match: ?ir.FunctionId = null;
            for (binding().classes[class_id.index].declarations) |member_id| {
                const candidate = binding().functions[member_id.index];
                if (!std.mem.eql(u8, candidate.js_name, member_name)) continue;
                if (kind) |required| {
                    if (candidate.class_member) |member| if (member.member_kind == required) break :found member_id;
                } else {
                    if (match != null) @compileError("binding class member is an accessor pair; use memberKind: " ++ member_name);
                    match = member_id;
                }
            }
            break :found match orelse if (kind == null)
                @compileError("binding class has no member named " ++ member_name)
            else
                @compileError("binding class has no member with the requested name and kind: " ++ member_name);
        };
    };
    return Lookup;
}


fn SemanticTypeLookup(comptime kind: ir.TypeKind, comptime name: []const u8) type {
    const Lookup = struct {
        pub const id: ir.TypeId = found: {
            @setEvalBranchQuota(eval_branch_quota);
            for (binding().types, 0..) |t, index| {
                if (std.meta.activeTag(t.data) != kind) continue;
                const type_name = switch (t.data) {
                    .nominal_handle => |handle| handle.nominal_handle_name,
                    .enumeration => |enumeration| get(enumeration).enumeration_name,
                    .dictionary => |dictionary| dictionary.dictionary_name,
                    .union_type => |union_type| union_type.union_name,
                    .external_ref => |external| get(external).external_name,
                    .branded_value => |branded| get(branded.brand).brand_name,
                    .callback => |callback| binding().callbacks[callback.index].callback_name,
                    else => continue,
                };
                if (std.mem.eql(u8, type_name, name)) break :found .of(index);
            }
            @compileError("binding manifest has no " ++ @tagName(kind) ++ " type named " ++ name);
        };
    };
    return Lookup;
}

pub inline fn argumentPosition(comptime T: type) ?ir.InboundArgumentPlanId {
    requireSemanticType(T);
    return comptime typeOf(T.type_id).argument;
}

pub inline fn resultPosition(comptime T: type) ?ir.InboundResultPlanId {
    requireSemanticType(T);
    return comptime typeOf(T.type_id).result;
}

// ─── callables ───

pub fn Argument(comptime argument: anytype) type {
    const View = struct {
        pub const argument_name = argument.argument_name;
        pub const position = argument.position;
        pub const value_position = argument.value_position;

        pub const ArgumentType = SemanticType(get(argument.position).type);

        pub const optional = argument.optional;
    };
    return View;
}

fn DomainError(comptime id: ir.DomainErrorId) type {
    const domain_error = get(id);
    const View = struct {
        pub const error_name = domain_error.error_name;
        pub const position = domain_error.position;
        pub const PayloadType = SemanticType(get(domain_error.position).type);
    };
    return View;
}

/// The completion of `Owner` as seen by the materialized payload it transfers.
fn CompletionPayload(comptime Owner: type, comptime payload: ir.InboundResultPlanId) type {
    if (payload.index == Owner.result_position.index) return Owner;
    const View = struct {
        pub const is_async = true;
        pub const backend = Owner.backend;
        pub const ReturnType = SemanticType(get(payload).type);
        pub const result_position = payload;

        pub const domain_errors = Owner.domain_errors;
        pub const destroy_result_symbol = Owner.destroy_result_symbol;
        pub const completion = Owner.completion;
        pub const wire_result = Owner.wire_result;
    };
    return View;
}

pub fn Function(comptime id: ir.FunctionId) type {
    return Callable(id, null);
}

/// A module function, class declaration, or one case of an overloaded one.
fn Callable(comptime parent_id: ir.FunctionId, comptime overload_index: ?usize) type {
    const function = if (overload_index) |index|
        binding().overload_cases[binding().functions[parent_id.index].overload_cases[index].index]
    else
        binding().functions[parent_id.index];
    const facts = function.class_member;
    const View = struct {
        pub const bindgen_bound_function = {};
        pub const function_id = parent_id;
        pub const id = parent_id.index;
        pub const module_name = function.module_name;
        pub const function_name = function.function_name;

        pub const args = typeViews(function.args, Argument);
        pub const is_overloaded = (function.overload_cases.len != 0);

        pub const case_name = function.case_name;
        pub const overload_cases = views: {
            @setEvalBranchQuota(eval_branch_quota);
            break :views overloadCases(parent_id, function.overload_cases.len);
        };

        pub const ReturnType = SemanticType(get(function.result_position).type);
        pub const backend = function.backend;
        pub const domain_errors = typeViews(function.domain_errors, DomainError);
        pub const completion = if (function.completion) |completion_id| get(completion_id) else null;
        pub const is_async = (function.completion != null);
        pub const completion_payload = if (function.completion) |completion_id| CompletionPayload(@This(), get(completion_id).payload) else @This();
        pub const result_position = function.result_position;

        pub const call_plan = get(function.call_plan);
        pub const invocation_args = typeViews(function.invocation_args, Argument);
        pub const has_callback_data = function.callback_data_type != null;
        pub const callback_data_type = function.callback_data_type;
        pub const has_caller_source_location = function.has_caller_source_location;
        pub const is_promise_reaction_handler = function.is_promise_reaction_handler;
        pub const is_class_member = facts != null;

        pub const member_kind = if (facts) |member| member.member_kind else null;
        pub const is_illegal = if (facts) |member| member.is_illegal else false;

        pub const native_reference_symbol = if (facts) |member| member.native_reference_symbol else null;
        pub const implementation_name = function.implementation_name;
        pub const implementation = if (facts != null) function.implementation_name else null;
        pub const js_name = function.js_name;
        pub const dispatch_symbol = function.dispatch_symbol;
        pub const host_symbol = function.host_symbol;
        pub const wire_args = if (function.wire_args) |wire_id| wire_id else null;
        pub const wire_result = function.wire_result;
        pub const destroy_result_symbol = function.destroy_result_symbol;
        pub const js_length = function.js_length;
        pub const exposed = function.exposed;

        pub fn OverloadAt(comptime index: usize) type {
            if (!(function.overload_cases.len != 0)) @compileError("binding function does not declare overloads");
            if (index >= function.overload_cases.len) @compileError("binding overload index is out of bounds");
            return Callable(parent_id, index);
        }
    };
    return View;
}

fn overloadCases(comptime parent_id: ir.FunctionId, comptime count: usize) [count]type {
    var views: [count]type = undefined;
    for (&views, 0..) |*view, index| view.* = Callable(parent_id, index);
    return views;
}

pub fn EngineShim(comptime shim_id: ir.EngineShimId) type {
    const shim = binding().engine_shims[shim_id.index];
    const View = struct {
        pub const bindgen_bound_engine_shim = {};
        pub const engine_shim_id = shim_id;
        pub const id = shim_id.index;
        pub const module_name = shim.module_name;
        pub const shim_name = shim.shim_name;
        pub const args = typeViews(shim.outbound.args, Argument);
        pub const ReturnType = SemanticType(get(shim.outbound.result_position).type);
        pub const throws = @This().call_plan.throws;
        pub const realm = @This().call_plan.realm;
        pub const result_position = shim.outbound.result_position;

        pub const call_plan = get(shim.outbound.call_plan);
        pub const wire_args = shim.outbound.wire_args;
        pub const wire_result = shim.outbound.wire_result;
        pub const thunk_symbol = shim.outbound.thunk_symbol;
        pub const destroy_result_symbol = shim.destroy_result_symbol;
        pub const domain_errors = .{};
    };
    return View;
}

pub fn NativeExport(comptime export_id: ir.NativeExportId) type {
    const native_export = binding().native_exports[export_id.index];
    const View = struct {
        pub const bindgen_bound_native_export = {};
        pub const native_export_id = export_id;
        pub const id = export_id.index;
        pub const module_name = native_export.module_name;
        pub const export_name = native_export.export_name;
        pub const function_name = native_export.export_name;
        pub const args = typeViews(native_export.args, Argument);
        pub const ReturnType = SemanticType(get(native_export.result_position).type);
        pub const throws = @This().call_plan.throws;
        pub const realm = @This().call_plan.realm;
        pub const non_returning = @This().call_plan.non_returning;
        pub const exposed = native_export.exposed;
        pub const domain_errors = typeViews(native_export.domain_errors, DomainError);
        pub const result_position = native_export.result_position;

        pub const call_plan = get(native_export.call_plan);
        pub const wire_args = native_export.wire_args;
        pub const wire_result = native_export.wire_result;
        pub const dispatch_symbol = native_export.dispatch_symbol;
        pub const destroy_result_symbol = native_export.destroy_result_symbol;
    };
    return View;
}

pub fn Callback(comptime id: ir.CallbackId) type {
    const callback = binding().callbacks[id.index];
    const View = struct {
        const Declaration = @This();

        pub const callback_id = id;
        pub const type_id = callback.type.index;
        pub const SemanticType = Manifest.SemanticType(callback.type);
        pub const callback_name = callback.callback_name;

        pub const args = typeViews(callback.outbound.args, Argument);
        pub const ReturnType = Manifest.SemanticType(get(callback.outbound.result_position).type);

        pub const result_position = callback.outbound.result_position;

        pub const call_plan = get(callback.outbound.call_plan);
        pub const wire_args = callback.outbound.wire_args;
        pub const wire_result = callback.outbound.wire_result;

        pub const thunk_symbol = callback.outbound.thunk_symbol;

        pub const Scheduled = if (callback.schedule_symbol) |symbol| struct {
            pub const args = Declaration.args;
            pub const result_position = Declaration.result_position;

            pub const call_plan = Declaration.call_plan;
            pub const wire_args = Declaration.wire_args;
            pub const wire_result = Declaration.wire_result;
            pub const thunk_symbol = symbol;
        } else struct {};
    };
    return View;
}

/// The typed-callback declaration of a callback semantic type.
pub fn callbackOf(comptime T: type) type {
    requireSemanticType(T);
    if (T.kind != .callback) @compileError("binding type is not a callback");
    return Callback(T.callback_id);
}

// ─── classes ───

fn CachedSlot(comptime slot: doc.CachedSlot) type {
    const View = struct {
        pub const slot_name = slot.slot_name;
        pub const assigned_position = slot.assigned_position;
        pub const access = slot.access;
        pub const ValueType = SemanticType(get(slot.assigned_position).type);
        pub const SlotType = SemanticType(slot.declared_type);

        pub const optional = slot.optional;
        pub const storage = slot.storage;
        pub const get_symbol = slot.get_symbol;
        pub const write = slot.write;
    };
    return View;
}

fn InstanceProperty(comptime property: doc.InstanceProperty) type {
    const View = struct {
        pub const property_name = property.property_name;
        pub const position = property.position;
        pub const ValueType = SemanticType(get(property.position).type);
    };
    return View;
}

pub fn Class(comptime declaration_id: ir.ClassId) type {
    const class = binding().classes[declaration_id.index];
    const View = struct {
        pub const bindgen_bound_class = {};
        pub const class_id = declaration_id;
        pub const id = declaration_id.index;
        pub const module_name = class.module_name;
        pub const class_name = class.class_name;

        pub const Brand = if (class.brand) |brand| BrandView(brand) else void;
        pub const has_brand = class.brand != null;
        pub const representation = class.representation;

        pub const runtime_plan = class.runtime_plan;
        pub const has_parent = class.parent != null;
        pub const Parent = if (class.parent) |parent| Class(parent) else void;
        pub const upcast = class.upcast;
        pub const instance_properties = typeViews(class.instance_properties, InstanceProperty);
        pub const create_symbol = class.create_symbol;
        pub const memory_usage = class.memory_usage;
        pub const pending_activity = class.pending_activity;
        pub const structured_clone: ?doc.StructuredClonePlan = if (class.structured_clone) |clone_id| get(clone_id) else null;
        pub const has_structured_clone = class.structured_clone != null;
        pub const ConstructorCall = if (class.constructor_call) |declaration| Function(declaration) else void;
        pub const callable = if (ConstructorCall == void) false else ConstructorCall.exposed;

        pub const slots = typeViews(class.slots, CachedSlot);

        pub const declarations = typeViews(class.declarations, Function);
        pub const exposed = class.exposed;
        pub const get_constructor_symbol = class.get_constructor_symbol;
        pub const try_cast_symbol = class.try_cast_symbol;
        pub const try_cast_direct_symbol = class.try_cast_direct_symbol;
        pub const wrap_native_symbol = class.wrap_native_symbol;
        pub const destroy_native_symbol = class.destroy_native_symbol;
        pub const destroy_pending_native_symbol = class.destroy_pending_native_symbol;
        pub const release_native_on_vm_symbol = class.release_native_on_vm_symbol;
        pub const native_type_symbol_prefix = class.native_type_symbol_prefix;
        pub const Constructor = Function(class.constructor);

        pub const ValueType = SemanticType(class.value_type);
        pub const InstanceValueType = SemanticType(class.instance_value_type orelse if (class.brand) |brand|
            @compileError("binding class instance brand is not represented by exactly one schema semantic type: " ++ BrandView(brand).brand_name)
        else
            @compileError("binding class instance is not branded: " ++ class.module_name ++ "." ++ class.class_name));
        pub const ConstructorValueType = SemanticType(class.constructor_value_type orelse
            @compileError("binding class constructor is not represented by a schema semantic type: " ++ class.module_name ++ "." ++ class.class_name));

        pub fn constructor() type {
            return Constructor;
        }

        pub fn constructorCall() type {
            if (class.constructor_call == null) @compileError("binding class has no constructor call declaration");
            return ConstructorCall;
        }

        pub fn member(comptime member_name: []const u8) type {
            return Function(ClassMemberLookup(declaration_id, member_name, null).id);
        }

        pub fn memberKind(comptime member_name: []const u8, comptime kind: ir.ClassMemberKind) type {
            return Function(ClassMemberLookup(declaration_id, member_name, kind).id);
        }
    };
    return View;
}

// ─── modules ───

pub fn Module(comptime id: ir.ModuleId) type {
    const module = binding().modules[id.index];
    const View = struct {
        pub const module_id = id;
        pub const module_name = module.module_name;

        pub fn function(comptime function_name: []const u8) type {
            return Function(ModuleDeclarationLookup(id, .functions, function_name).id);
        }

        pub fn class(comptime class_name: []const u8) type {
            return Class(ModuleDeclarationLookup(id, .classes, class_name).id);
        }

        pub fn engineShim(comptime shim_name: []const u8) type {
            return EngineShim(ModuleDeclarationLookup(id, .engine_shims, shim_name).id);
        }

        pub fn nativeExport(comptime export_name: []const u8) type {
            return NativeExport(ModuleDeclarationLookup(id, .native_exports, export_name).id);
        }
    };
    return View;
}

pub fn moduleNamed(comptime module_name: []const u8) type {
    return Module(NamedLookup(ir.ModuleId, "module_name", "module", module_name).id);
}

pub fn engineShimByName(comptime module_name: []const u8, comptime shim_name: []const u8) type {
    return moduleNamed(module_name).engineShim(shim_name);
}

// ─── lookups by declaration ───

pub fn FunctionId(comptime FunctionSchema: type) usize {
    if (!@hasDecl(FunctionSchema, "bindgen_bound_function")) @compileError("bindgen function schemas must be obtained from a schema module");
    return FunctionSchema.function_id.index;
}

pub fn FunctionAt(comptime function_id: usize) type {
    return Function(.of(function_id));
}

pub fn EngineShimId(comptime EngineShimSchema: type) usize {
    if (!@hasDecl(EngineShimSchema, "bindgen_bound_engine_shim")) @compileError("bindgen engine shim schemas must be obtained from a schema module");
    return EngineShimSchema.engine_shim_id.index;
}

pub fn EngineShimAt(comptime shim_id: usize) type {
    return EngineShim(.of(shim_id));
}

pub fn EngineShimIdByName(comptime module_name: []const u8, comptime shim_name: []const u8) usize {
    return engineShimByName(module_name, shim_name).engine_shim_id.index;
}

pub fn NativeExportId(comptime NativeExportSchema: type) usize {
    if (!@hasDecl(NativeExportSchema, "bindgen_bound_native_export")) @compileError("bindgen native export schemas must be obtained from a schema module");
    return NativeExportSchema.native_export_id.index;
}

pub fn NativeExportAt(comptime export_id: usize) type {
    return NativeExport(.of(export_id));
}

pub fn ClassId(comptime ClassSchema: type) usize {
    if (!@hasDecl(ClassSchema, "bindgen_bound_class")) {
        @compileError("bindgen class schemas must be obtained from a schema module");
    }
    return ClassSchema.class_id.index;
}

pub fn ClassAt(comptime class_id: usize) type {
    return Class(.of(class_id));
}

pub fn ClassInstanceValueType(comptime class_id: usize) type {
    return ClassAt(class_id).InstanceValueType;
}

pub fn ClassConstructorValueType(comptime class_id: usize) type {
    return ClassAt(class_id).ConstructorValueType;
}

pub fn TypeId(comptime T: type) usize {
    requireSemanticType(T);
    return T.type_id.index;
}

pub fn semanticTypeNamed(comptime kind: ir.TypeKind, comptime name: []const u8) type {
    return SemanticType(SemanticTypeLookup(kind, name).id);
}

// ─── plan queries ───

fn sameClass(comptime Left: type, comptime Right: type) bool {
    return Left.class_id.index == Right.class_id.index;
}

pub fn classIsOrInherits(comptime ClassView: type, comptime Ancestor: type) bool {
    if (sameClass(ClassView, Ancestor)) return true;
    if (!ClassView.has_parent) return false;
    return classIsOrInherits(ClassView.Parent, Ancestor);
}

pub fn typeContainsClass(comptime Type: type, comptime ClassInfo: type) bool {
    return switch (Type.kind) {
        .class_ref => sameClass(Type.ReferencedClass, ClassInfo),
        .branded_value => if (Type.Brand.constructor_class) |class|
            class.index == ClassInfo.class_id.index
        else if (Type.PromiseValueType != void)
            typeContainsClass(Type.PromiseValueType, ClassInfo)
        else
            false,
        .converted => typeContainsClass(Type.ConvertedValue, ClassInfo),
        .optional, .sequence => typeContainsClass(Type.child, ClassInfo),
        .dictionary => inline for (Type.dictionary_fields) |Field| {
            if (typeContainsClass(Field.FieldType, ClassInfo)) break true;
        } else false,
        .union_type => inline for (Type.union_members) |Member| {
            if (typeContainsClass(Member.MemberType, ClassInfo)) break true;
        } else false,
        .record => typeContainsClass(Type.KeyType, ClassInfo) or typeContainsClass(Type.ValueType, ClassInfo),
        else => false,
    };
}

pub fn validateCompletionSenderFailure(comptime completion: doc.CompletionPlan) void {
    if (completion.error_delivery == .vm) @compileError("VM-materialized completion errors must use MaterializationContext.fail");
}

// ─── symbols ───

pub fn CallbackSchema(comptime callback_name: []const u8) type {
    return SemanticType(binding().callbacks[NamedLookup(ir.CallbackId, "callback_name", "callback", callback_name).id.index].type);
}
