const schema = @import("bindgen_schema");
const FactsModule = @This();
const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const Normalizer = normalize.Normalizer;
const Error = std.mem.Allocator.Error;
const plans = @import("plans.zig");

const LeafKind = enum {
    void, scalar, enumeration,
    js_value_view, js_value_result, js_value_operand,
    string_view, string_owned, string_operand,
    bytes_view, bytes_owned, bytes_operand,
    byte_lease, lease_owned,
    native_slice_view, native_slice,
    nominal_borrow, nominal_owned, nominal_owner_borrow,
    callback_view, callback_owned, callback_result,
    class_view, class_owned, class_result,
    external_view, external_owned,
    lazy_field, lazy_view, lazy_operand,
    native_receiver, lazy_rest, utf8_owned, native_instance,
};

pub fn leafKind(comptime tag: anytype) LeafKind {
    return @field(LeafKind, @tagName(tag));
}

pub const Facts = struct {
    argument_allocates: bool = false,
    has_aggregate: bool = false,
    input_storage: bool = false,
    protects_native: bool = false,
    decode_allocates: bool = false,
    result_encoding_allocates: bool = false,
    native_encoding_supported: bool = false,
    collection_storage: bool = false,
    sequence_span: bool = false,
    roots_input: bool = false,
    contains_collection: bool = false,
    contains_owned_handle: bool = false,
    pending_release: bool = false,
    contains_engine_reference: bool = false,
    result_requires_root_context: bool = false,
    decode_requires_realm: bool = false,
    buffer_materialization: ?ir.BufferResultRepresentation = null,

    fn merge(facts: *Facts, child: Facts) void {
        facts.pending_release = facts.pending_release or child.pending_release;
        facts.contains_collection = facts.contains_collection or child.contains_collection;
        facts.contains_owned_handle = facts.contains_owned_handle or child.contains_owned_handle;
        facts.contains_engine_reference = facts.contains_engine_reference or child.contains_engine_reference;
        facts.result_requires_root_context = facts.result_requires_root_context or child.result_requires_root_context;
        facts.decode_requires_realm = facts.decode_requires_realm or child.decode_requires_realm;
        facts.native_encoding_supported = facts.native_encoding_supported and child.native_encoding_supported;
        facts.decode_allocates = facts.decode_allocates or child.decode_allocates;
        facts.result_encoding_allocates = facts.result_encoding_allocates or child.result_encoding_allocates;
    }
};

fn PositionTable(comptime Value: type) type {
    return std.enums.EnumArray(ir.Role, []?Value);
}

fn allocatePositions(comptime Value: type, n: *const Normalizer) Error!PositionTable(Value) {
    var table: PositionTable(Value) = undefined;
    inline for (std.enums.values(ir.Role)) |role| {
        const values = try n.arena.alloc(?Value, n.rolePlans(role).len);
        @memset(values, null);
        table.set(role, values);
    }
    return table;
}

pub const Table = PositionTable(Facts);

pub fn get(n: *const Normalizer, id: anytype) *const Facts {
    return &n.cpp_facts.get(@TypeOf(id).role)[id.index].?;
}

pub fn planAll(n: *Normalizer) Error!void {
    n.cpp_facts = try allocatePositions(Facts, n);
    inline for (std.enums.values(ir.Role)) |role| {
        for (0..n.rolePlans(role).len) |index| _ = resolve(n, @as(role.PlanId(), .of(index)));
    }
    const supported = try n.arena.alloc(bool, n.engine_shims.items.len);
    for (n.engine_shims.items, supported) |shim, *output| {
        output.* = n.rawEngineShim(shim.id).options.result_source == .javascript and !shim.outbound.call_plan.transfers_argument_ownership and supported: {
            for (shim.outbound.args) |argument| {
                if (argument.conversion.rest or !nativeEncodingSupported(n, argument.position)) break :supported false;
            }
            break :supported true;
        };
    }
    n.engine_native_support = supported;
    try FactsModule.Predicates.planAll(n);
    try FactsModule.Types.planAll(n);
}

fn resolve(n: *Normalizer, id: anytype) Facts {
    const entry = &n.cpp_facts.get(@TypeOf(id).role)[id.index];
    if (entry.*) |facts| return facts;
    entry.* = build(n, id);
    return entry.*.?;
}

fn build(n: *Normalizer, id: anytype) Facts {
    const role = @TypeOf(id).role;
    const position = n.get(id).*;
    const representation = position.representation;
    if (role == .inbound_argument) if (representation == .leaf and representation.leaf == .native_receiver) return .{};
    const input = n.input_plans.items[position.input.index];
    var facts: Facts = .{
        .native_encoding_supported = role == .inbound_argument or role == .outbound_argument,
        .sequence_span = role == .outbound_argument and (representation == .sequence or representation == .rest) and !position.stored,
    };
    switch (representation) {
        .converted => |conversion| {
            const native = resolve(n, conversion.value);
            facts.input_storage = true;
            facts.argument_allocates = native.argument_allocates;
            facts.has_aggregate = native.has_aggregate;
            facts.merge(resolve(n, conversion.apiValue()));
            if (role == .outbound_argument) facts.native_encoding_supported = false;
        },
        .optional => |child| {
            const value = resolve(n, child);
            facts.input_storage = value.input_storage;
            facts.argument_allocates = value.argument_allocates;
            facts.has_aggregate = value.has_aggregate;
            facts.collection_storage = value.collection_storage;
            facts.merge(value);
        },
        inline .dictionary, .union_type => |fields, tag| {
            facts.has_aggregate = true;
            facts.collection_storage = true;
            for (fields) |field| {
                const value = resolve(n, field.value);
                const dictionary_source = if (tag == .dictionary) field.dictionary_source else false;
                facts.input_storage = facts.input_storage or (value.input_storage and !dictionary_source);
                facts.argument_allocates = facts.argument_allocates or value.argument_allocates or dictionary_source;
                facts.merge(value);
            }
        },
        inline .sequence, .record, .rest => |child, tag| {
            const value = resolve(n, child);
            facts.input_storage = value.input_storage;
            facts.argument_allocates = tag != .rest or value.argument_allocates;
            facts.has_aggregate = tag != .rest or value.has_aggregate;
            facts.collection_storage = tag != .rest or value.collection_storage;
            facts.merge(value);
            facts.contains_collection = true;
            facts.pending_release = role != .outbound_argument or value.pending_release;
            if (tag == .rest) facts.native_encoding_supported = false;
            facts.result_requires_root_context = facts.contains_engine_reference;
            facts.decode_allocates = true;
            facts.result_encoding_allocates = true;
        },
        .record_entry => |entry| {
            const key = resolve(n, entry.key);
            const value = resolve(n, entry.value);
            facts.has_aggregate = true;
            facts.collection_storage = true;
            facts.argument_allocates = true;
            facts.input_storage = value.input_storage;
            facts.merge(key);
            facts.merge(value);
        },
        .leaf => |leaf| {
            facts.pending_release = pendingRelease(n, id) != null;
            facts.native_encoding_supported = switch (role) {
                .inbound_argument, .outbound_argument => nativeEncodingLeaf(n, id) != null,
                .inbound_result, .outbound_result => false,
            };
            facts.contains_owned_handle = leaf == .nominal_owned;
            const lazy: ?ir.InboundArgumentPlanId = switch (role) {
                .inbound_argument => switch (leaf) {
                    .lazy_field => |child| child,
                    .lazy_view, .lazy_rest => |deferred| deferred.value,
                    .void, .scalar, .enumeration, .js_value_view, .string_view, .bytes_view, .native_slice_view, .byte_lease, .callback_view, .class_view, .external_view, .nominal_borrow, .nominal_owned, .native_receiver => null,
                },
                .outbound_argument => switch (leaf) {
                    .lazy_operand => |operand| operand.value,
                    .scalar, .enumeration, .js_value_operand, .js_value_result, .string_operand, .string_owned, .bytes_operand, .native_slice, .callback_view, .class_view, .nominal_borrow, .nominal_owner_borrow, .nominal_owned => null,
                },
                .inbound_result, .outbound_result => null,
            };
            if (lazy) |child| {
                facts.collection_storage = true;
                facts.argument_allocates = (resolve(n, child)).argument_allocates;
            }
            switch (input.codec) {
                .js_value, .branded_value => {
                    facts.input_storage = true;
                    facts.contains_engine_reference = true;
                    facts.protects_native = position.native_heap or role == .outbound_argument;
                    facts.roots_input = position.stored;
                },
                .callback, .class_ref => {
                    facts.input_storage = true;
                    facts.contains_engine_reference = true;
                    facts.decode_requires_realm = true;
                    facts.decode_allocates = position.stored;
                    facts.result_encoding_allocates = true;
                    facts.roots_input = position.stored;
                    if (input.codec == .callback) {
                        facts.argument_allocates = n.rawType(position.type).callback.options.retains_async_context;
                        facts.protects_native = position.native_heap or role == .outbound_argument;
                    }
                },
                .node_path => facts.input_storage = true,
                .string => facts.result_encoding_allocates = n.projection(position.type).string.?.thread_safe,
                .buffer => {
                    facts.result_encoding_allocates = true;
                    facts.input_storage = true;
                    const buffer = n.projection(position.type).buffer.?;
                    if (buffer.effective_mode == .copy) {
                        facts.buffer_materialization = if (buffer.result_representation_explicit and !position.stored) buffer.result_representation else null;
                        facts.decode_allocates = facts.buffer_materialization != null;
                    }
                },
                .none, .discarded, .boolean, .integer, .number, .lazy, .utf8_string, .native_slice, .nominal_handle, .external_ref, .enumeration, .native_instance, .converted, .optional, .dictionary, .union_type, .sequence, .record => {},
            }
        },
    }
    // Inbound results are encoded by Zig; outbound results are encoded by C++.
    if (role == .inbound_result) facts.result_encoding_allocates = position.zig.encode_allocates;
    facts.pending_release = facts.pending_release and position.zig.destruction.wire;
    facts.collection_storage = facts.collection_storage or facts.input_storage;
    facts.argument_allocates = facts.argument_allocates or facts.protects_native;
    return facts;
}

pub fn pendingRelease(n: *const Normalizer, id: anytype) ?ir.CppPendingRelease {
    const role = @TypeOf(id).role;
    return switch (role) {
        .inbound_argument, .outbound_argument => null,
        .inbound_result, .outbound_result => switch ((n.get(id).zig.leaf orelse return null).release) {
            .none => null,
            .root => .root,
            .class_ref => .class_ref,
            .string => .string,
            .bytes => .bytes,
            .release_handle => |handle| if (role == .inbound_result) switch (handle) {
                .nominal => null,
                .byte_lease => .{ .release_handle = "bun_bindgen_byte_lease_release" },
                .external => |external| .{ .release_handle = n.get(external).release_symbol },
                .native => |class| .{ .release_handle = n.get(class).destroy_pending_native_symbol },
            } else null,
        },
    };
}

pub const NativeParameter = union(enum) {
    javascript,
    lazy,
    optional: ir.InboundArgumentPlanId,
    encode,
};

pub fn nativeParameter(n: *const Normalizer, id: ir.InboundArgumentPlanId) NativeParameter {
    const position = n.get(id);
    return switch (plans.plan(n, position.input).codec) {
        .converted, .class_ref => .javascript,
        .string => if (n.projection(position.type).string.?.conversion == .coerce) .javascript else .encode,
        .lazy => .lazy,
        .optional => |optional| if (optional.optional_matches_class_reference) .javascript else optional: {
            const child = position.representation.optional;
            switch (plans.plan(n, n.get(child).input).codec) {
                .string, .external_ref => break :optional .encode,
                else => break :optional if (nativeParameter(n, child) == .encode) .encode else .{ .optional = child },
            }
        },
        .union_type => if (plans.unionContainsOnlyClassReferences(n, position.input)) .javascript else .encode,
        else => .encode,
    };
}

pub fn nativeEncodingSupported(n: *const Normalizer, id: anytype) bool {
    return get(n, id).native_encoding_supported;
}

pub const InputAggregateRequest = struct { position: ir.InboundArgumentPlanId, location: ir.CppAggregateLocation };

fn markAggregate(n: *Normalizer, id: anytype, location: ?ir.CppAggregateLocation) Error!void {
    if (@TypeOf(id) == ir.InboundArgumentPlanId and location == null) {
        if (n.converters(id).result) |result| return markAggregate(n, result, null);
    }
    const position = n.get(id).*;
    if (position.representation == .dictionary or position.representation == .union_type) {
        if (@TypeOf(id) == ir.InboundArgumentPlanId) {
            if (location) |header| {
                const key: InputAggregateRequest = .{ .position = id, .location = header };
                if (n.cpp_input_aggregate_requests.contains(key)) return;
                try n.cpp_input_aggregate_requests.putNoClobber(n.arena, key, {});
            } else {
                if (n.cpp_converted_aggregate_requests.contains(id)) return;
                try n.cpp_converted_aggregate_requests.putNoClobber(n.arena, id, {});
            }
        } else {
            if (n.cpp_result_aggregate_requests.contains(id)) return;
            try n.cpp_result_aggregate_requests.putNoClobber(n.arena, id, {});
        }
    }
    switch (position.representation) {
        .converted => |conversion| {
            if (location != null) {
                try markAggregate(n, conversion.match, .public_header);
                try markAggregate(n, conversion.value, .public_header);
            }
            try markAggregate(n, conversion.apiValue(), null);
        },
        inline .optional, .sequence, .record, .rest => |child| try markAggregate(n, child, location),
        .dictionary => |fields| for (fields) |field| try markAggregate(n, field.value, location),
        .union_type => |members| for (members) |member| try markAggregate(n, member.value, location),
        .record_entry => |entry| {
            try markAggregate(n, entry.key, location);
            try markAggregate(n, entry.value, location);
        },
        .leaf => |leaf| switch (@TypeOf(id).role) {
            .inbound_argument => switch (leaf) {
                .lazy_field => |child| if (location != null) try markAggregate(n, child, location),
                .lazy_view, .lazy_rest => |deferred| if (location != null) try markAggregate(n, deferred.value, location),
                .void, .scalar, .enumeration, .js_value_view, .string_view, .bytes_view, .native_slice_view, .byte_lease, .callback_view, .class_view, .external_view, .nominal_borrow, .nominal_owned, .native_receiver => {},
            },
            .inbound_result => switch (leaf) {
                .void, .scalar, .enumeration, .js_value_result, .string_owned, .utf8_owned, .bytes_owned, .lease_owned, .callback_owned, .class_owned, .external_owned, .nominal_borrow, .nominal_owned, .native_instance => {},
            },
            .outbound_argument, .outbound_result => @compileError("aggregate declarations use their inbound converter plans"),
        },
    }
}

fn markFunctionAggregates(n: *Normalizer, function: ir.Function) Error!void {
    if (!function.exposed or function.backend == .builtin) return;
    const location: ir.CppAggregateLocation = if (function.backend == .cpp) .public_header else .converter_header;
    for ([_]?ir.Argument(.inbound_argument){ function.this_argument, function.new_target_argument, function.callee_argument }) |argument| {
        if (argument) |value| try markAggregate(n, value.position, location);
    }
    for (function.args) |argument| {
        try markAggregate(n, argument.position, location);
        if (argument.rest_position) |rest| try markAggregate(n, rest.plan(), location);
    }
    if (function.backend == .cpp) {
        for (function.domain_errors) |domain_error| try markAggregate(n, n.get(domain_error).position, null);
        try markAggregate(n, if (function.completion) |completion| n.get(completion).payload else function.result_position, null);
    }
    for (function.overload_cases) |id| try markFunctionAggregates(n, n.get(id).*);
}

pub fn markAggregates(n: *Normalizer) Error!void {
    for (n.rolePlans(.inbound_argument), 0..) |position, index| {
        if (position.type.index < n.binding_type_count and position.representation == .converted) try markAggregate(n, ir.InboundArgumentPlanId.of(index), .public_header);
    }
    for (n.callback_calls) |call| {
        if (n.converters(call.result_position).input) |input| try markAggregate(n, input, .converter_header);
    }
    for (n.functions.items) |function| try markFunctionAggregates(n, function);
    for (n.engine_shims.items) |shim| {
        for (shim.outbound.args) |argument| if (n.converters(argument.position).input) |input| try markAggregate(n, input, .public_header);
        if (n.rawEngineShim(shim.id).options.result_source == .javascript) {
            if (n.converters(shim.outbound.result_position).input) |input| try markAggregate(n, input, .converter_header);
        }
        if (n.rawEngineShim(shim.id).options.result_source == .native or n.engine_native_support[shim.id.index]) {
            if (n.converters(shim.outbound.result_position).result) |result| try markAggregate(n, result, null);
        }
    }
    for (n.native_exports.items) |native_export| {
        if (!native_export.exposed) continue;
        for (native_export.args) |argument| try markAggregate(n, argument.position, .public_header);
        try markAggregate(n, native_export.result_position, null);
    }
}

fn scalarMaterialization(n: *const normalize.Normalizer, type_id: ir.TypeId, kind: ir.ScalarKind) ir.CppScalarMaterialization {
    return switch (kind) {
        .boolean => .boolean,
        .f64 => .number,
        .discarded => .{ .discarded = n.rawType(type_id).discarded.match },
        .i8, .i16, .i32, .i64 => switch (n.projection(type_id).integer_representation.?) {
            .number => .integer_number,
            .number_or_bigint => .integer_number_or_bigint,
            .bigint => .signed_bigint,
        },
        .u8, .u16, .u32, .u64, .usize => switch (n.projection(type_id).integer_representation.?) {
            .number => .integer_number,
            .number_or_bigint => .integer_number_or_bigint,
            .bigint => .unsigned_bigint,
        },
    };
}

pub fn materializationLeaf(n: *const Normalizer, id: anytype, source: ir.CppMaterializationSource) ?ir.CppMaterializationLeaf {
    const position = n.get(id).*;
    const t = n.irType(position.type);
    const read: ir.CppMaterializedValue = if (source == .native) .native else switch (@TypeOf(id).role) {
        .inbound_argument, .outbound_argument => .handle,
        .inbound_result, .outbound_result => .root,
    };
    return switch (position.representation.leaf) {
        inline else => |value, tag| switch (comptime leafKind(tag)) {
            .void => .void,
            .scalar => .{ .scalar = scalarMaterialization(n, t.id, value) },
            .js_value_view, .js_value_result, .js_value_operand => .{ .value = .{
                .read = if (source == .native) (if (t.data == .any) .any else .native) else if (@TypeOf(id).role == .inbound_argument) .handle else .encoded,
                .brand = if (t.data == .branded_value and !(source == .native and @TypeOf(id).role == .inbound_argument)) t.data.branded_value.brand.cpp_match else null,
            } },
            .callback_view, .callback_owned, .callback_result => .{ .callback = read },
            .class_view, .class_owned, .class_result => .{ .class = .{ .id = t.data.class_ref.class, .read = read } },
            .string_view, .string_owned, .string_operand => .string,
            .utf8_owned => if (source == .wire) .utf8 else null,
            .bytes_view, .bytes_owned, .bytes_operand => .{ .buffer = (n.projection(t.id).buffer orelse return null).result_representation },
            .enumeration => .{ .enumeration = t.data.enumeration },
            .native_slice_view, .native_slice, .byte_lease, .lease_owned, .external_view, .external_owned,
            .nominal_borrow, .nominal_owned, .nominal_owner_borrow, .native_receiver, .native_instance,
            .lazy_field, .lazy_view, .lazy_rest, .lazy_operand => null,
        },
    };
}

pub fn nativeEncodingLeaf(n: *const Normalizer, id: anytype) ?ir.CppNativeEncodingLeaf(@TypeOf(id).role) {
    const role = @TypeOf(id).role;
    const position = n.get(id).*;
    const leaf = position.representation.leaf;
    if (role == .inbound_result or role == .outbound_result) @compileError("native C++ encoders require an argument plan");
    return switch (leaf) {
        inline else => |value, tag| switch (comptime leafKind(tag)) {
            .scalar => .{ .scalar = value },
            .enumeration => .enumeration,
            .js_value_view, .js_value_operand, .js_value_result => .{ .value = javascriptValue(n, position.type, value) },
            .string_view, .string_operand, .string_owned => .string,
            .bytes_view, .bytes_operand => .bytes,
            .native_slice_view, .native_slice => .native_slice,
            .callback_view => .{ .callback = n.rawType(position.type).callback.options.retains_async_context },
            .external_view => .{ .handle = .external },
            .nominal_borrow, .nominal_owner_borrow, .nominal_owned => .{
                .handle = if (role == .inbound_argument) .{ .nominal = nominalHandle(n, position.type) } else nominalHandle(n, position.type),
            },
            .lazy_field, .lazy_view, .lazy_operand => .lazy_handle,
            .void, .byte_lease, .class_view, .native_receiver, .lazy_rest => null,
            .callback_owned, .callback_result, .class_owned, .class_result, .bytes_owned,
            .utf8_owned, .lease_owned, .external_owned, .native_instance =>
                @compileError("native C++ encoders require an argument plan"),
        },
    };
}

pub fn javascriptValue(n: *const Normalizer, type_id: ir.TypeId, kind: ir.JSValueKind) ir.CppJavaScriptValue {
    return switch (kind) {
        .any => .any,
        .engine_value => .engine_value,
        .branded => .{ .branded = n.irType(type_id).data.branded_value.brand.cpp_match },
    };
}

pub fn nominalHandle(n: *const Normalizer, type_id: ir.TypeId) ir.CppHandle {
    const handle = n.irType(type_id).data.nominal_handle;
    return .{ .wire = handle.wire, .const_pointee = handle.const_pointee };
}

pub fn integerLiteral(kind: ir.ScalarKind, value: i128) ?ir.CppIntegerLiteral {
    return switch (kind) {
        .i64 => .{ .signed_long = @intCast(value) },
        .u64, .usize => .{ .unsigned_long = @intCast(value) },
        .u32 => .{ .unsigned = @intCast(value) },
        .i8, .u8, .i16, .u16, .i32 => .{ .signed = @intCast(value) },
        .boolean, .discarded, .f64 => null,
    };
}

pub fn integerRange(kind: ir.ScalarKind, range: ir.IntegerRange) ir.CppIntegerRange {
    return .{ .min = integerLiteral(kind, range.min).?, .max = integerLiteral(kind, range.max).? };
}

pub const Types = struct {
    pub const InputTypes = struct {
        value: ?ir.CppTypeId = null,
        parameter: ?ir.CppTypeId = null,
        converter_result: ?ir.CppTypeId = null,
        converter_input: ?ir.CppTypeId = null,
    };

    pub const ResultTypes = struct {
        logical: ?ir.CppTypeId = null,
        decoded: ?ir.CppTypeId = null,
        produced: ?ir.CppTypeId = null,
    };

    pub const State = struct {
        inputs: PositionTable(InputTypes) = .initFill(&.{}),
        results: PositionTable(ResultTypes) = .initFill(&.{}),
    };

    pub fn input(n: *const Normalizer, id: anytype) InputTypes {
        return n.cpp_type_state.inputs.get(@TypeOf(id).role)[id.index].?;
    }

    pub fn result(n: *const Normalizer, id: anytype) ResultTypes {
        return n.cpp_type_state.results.get(@TypeOf(id).role)[id.index].?;
    }

    pub fn fromSchema(n: *Normalizer, value: schema.CppType) Error!ir.CppTypeId {
        return n.cppType(switch (value) {
            .void => .void,
            .int => .int,
            .named => |name| .{ .named = .{ .name = name, .namespace = .global } },
            .pointer => |child| .{ .pointer = try fromSchema(n, child.*) },
            .const_pointer => |child| .{ .const_pointer = try fromSchema(n, child.*) },
            .function_pointer => |function| function: {
                const parameters = try n.arena.alloc(ir.CppTypeId, function.parameters.len);
                for (function.parameters, parameters) |parameter, *output| output.* = try fromSchema(n, parameter);
                break :function .{ .function_pointer = .{
                    .result = try fromSchema(n, function.result.*),
                    .parameters = parameters,
                    .convention = switch (function.convention) {
                        .c => .c,
                        .host => .host,
                    },
                } };
            },
            .specialization => |specialization| specialization: {
                const arguments = try n.arena.alloc(ir.CppTypeId, specialization.arguments.len);
                for (specialization.arguments, arguments) |argument, *output| output.* = try fromSchema(n, argument);
                break :specialization .{ .specialization = .{ .name = specialization.name, .arguments = arguments } };
            },
        });
    }

    pub fn declaration(n: *Normalizer, value: schema.CppDeclaration) Error!ir.CppDeclarationId {
        const normalized: ir.CppDeclaration = switch (value) {
            .structure => |name| .{ .structure = name },
            .class => |name| .{ .class = name },
            .alias => |alias| .{ .alias = .{ .name = alias.name, .type = try fromSchema(n, alias.type) } },
            .include => |include| .{ .include = .{ .path = include.path, .system = include.system } },
        };
        return .of((try n.cpp_declarations.getOrPut(n.arena, normalized)).index);
    }

    pub fn planAll(n: *Normalizer) Error!void {
        n.cpp_type_state = .{
            .inputs = try allocatePositions(InputTypes, n),
            .results = try allocatePositions(ResultTypes, n),
        };
        var planner: Planner = .{ .n = n };
        inline for (std.enums.values(ir.Role)) |role| {
            for (0..n.rolePlans(role).len) |index| _ = try planner.value(@as(role.PlanId(), .of(index)));
        }
        inline for (std.enums.values(ir.Role)) |role| {
            for (0..n.rolePlans(role).len) |index| _ = try planner.input(@as(role.PlanId(), .of(index)));
        }
    }

    pub fn inputValue(n: *const Normalizer, id: anytype) ir.CppTypeId {
        return input(n, id).value.?;
    }

    pub fn resultValue(n: *const Normalizer, id: anytype) ir.CppTypeId {
        return result(n, id).logical.?;
    }

    pub fn leafType(n: *Normalizer, id: ir.TypeId) Error!?ir.CppTypeId {
        const t = n.irType(id);
        return switch (t.data) {
            .void => try n.cppType(.void),
            .boolean, .discarded, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => try n.cppType(.{ .scalar = n.projection(t.id).scalar_kind.? }),
            .any => try n.cppType(.any),
            .engine_value, .branded_value, .callback => try n.cppType(.js_value),
            .dom_string, .usv_string, .byte_string => try n.cppType(.string),
            .buffer => |buffer| if (n.rawType(id).buffer.mode == .lease) try n.cppType(.{ .scoped_bytes = buffer.buffer_access }) else null,
            .native_slice => |slice| slice: {
                const element = try n.cppType(.{ .scalar = switch (slice.native_slice_element) {
                    .uint8 => .u8,
                    .uint16 => .u16,
                    .uint32 => .u32,
                    .uint64 => .u64,
                } });
                break :slice try n.cppType(if (slice.native_slice_access == .read_write) .{ .span = element } else .{ .const_span = element });
            },
            .nominal_handle => |handle| handle.cpp_type,
            .external_ref => |external| try n.cppType(.{ .external_implementation = n.get(external).cpp_idl }),
            .enumeration => |enumeration| try n.cppType(.{ .named = .{ .name = n.get(enumeration).cpp_name, .namespace = .binding } }),
            .dictionary, .union_type => try n.cppType(.{ .named = .{ .name = n.type_metadata.items[id.index].cpp_name.?, .namespace = .binding } }),
            .utf8_string, .node_path, .class_ref, .native_instance, .converted, .optional, .lazy, .sequence, .record => null,
        };
    }

    const Planner = struct {
        n: *Normalizer,

        fn wrap(p: *const Planner, comptime kind: @EnumLiteral(), child: ?ir.CppTypeId) Error!?ir.CppTypeId {
            return if (child) |id| try p.n.cppType(@unionInit(ir.CppType, @tagName(kind), id)) else null;
        }

        fn named(p: *const Planner, name: []const u8) Error!ir.CppTypeId {
            return p.n.cppType(.{ .named = .{ .name = name, .namespace = .binding } });
        }

        fn inputString(p: *Planner, type_id: ir.TypeId, storage: ?ir.CppTypeId) Error!InputTypes {
            return .{
                .value = storage,
                .parameter = if (p.n.projection(type_id).string.?.conversion == .coerce) try p.n.cppType(.js_value) else try p.wrap(.const_reference, try p.n.cppType(.string)),
                .converter_result = storage,
            };
        }

        fn inputBytes(p: *Planner, type_id: ir.TypeId) Error!InputTypes {
            const byte = try p.n.cppType(.{ .scalar = .u8 });
            return .{
                .value = try p.wrap(.const_span, byte),
                .parameter = if (p.n.irType(type_id).kind() == .node_path) null else try p.wrap(.const_span, byte),
                .converter_result = try p.wrap(.vector, byte),
            };
        }

        fn inputClass(p: *Planner, class_id: ir.ClassId) Error!InputTypes {
            return .{
                .value = switch (p.n.get(class_id).representation) {
                    .engine => |engine| try p.n.cppType(.{ .pointer = engine.native_type }),
                    .native => try p.n.cppType(.{ .pointer = try p.n.cppType(.{ .native_class = class_id }) }),
                    .plain => null,
                },
                .parameter = try p.n.cppType(.js_value),
            };
        }

        fn inputConverted(p: *Planner, conversion: anytype) Error!InputTypes {
            const native = try p.input(conversion.value);
            const match = try p.input(conversion.match);
            return .{
                .value = native.converter_result,
                .parameter = try p.n.cppType(.js_value),
                .converter_result = native.converter_result,
                .converter_input = switch (p.n.input_plans.items[p.n.get(conversion.match).input.index].codec) {
                    .dictionary, .union_type, .sequence, .record, .optional, .string, .buffer => try p.wrap(.const_reference, match.value),
                    else => match.value,
                },
            };
        }

        fn inputOptional(p: *Planner, id: anytype, child_id: @TypeOf(id)) Error!InputTypes {
            const child = try p.input(child_id);
            const codec = p.n.input_plans.items[p.n.get(child_id).input.index].codec;
            return .{
                .value = try p.wrap(.optional, child.value),
                .parameter = if (p.n.input_plans.items[p.n.get(id).input.index].codec.optional.optional_matches_class_reference)
                    try p.n.cppType(.js_value)
                else if (codec == .string or codec == .external_ref)
                    try p.wrap(.const_reference, try p.wrap(.optional, child.value))
                else
                    try p.wrap(.optional, child.parameter),
                .converter_result = try p.wrap(.optional, child.converter_result),
            };
        }

        fn inputAggregate(p: *Planner, id: anytype, fields: anytype, storage: ?ir.CppTypeId, comptime dictionary: bool) Error!InputTypes {
            for (fields) |field| {
                if (comptime dictionary) {
                    if (field.dictionary_source) continue;
                }
                if ((try p.input(field.value)).value == null) return .{};
            }
            return .{
                .value = storage,
                .parameter = if (!dictionary and plans.unionContainsOnlyClassReferences(p.n, p.n.get(id).input)) try p.n.cppType(.js_value) else storage,
                .converter_result = result(p.n, id).logical,
            };
        }

        fn inputSequence(p: *Planner, id: anytype, child_id: @TypeOf(id)) Error!InputTypes {
            const child = try p.input(child_id);
            return .{
                .value = if (FactsModule.get(p.n, id).sequence_span) try p.wrap(.const_span, child.value) else try p.wrap(.vector, child.value),
                .parameter = try p.wrap(.const_span, child.value),
                .converter_result = try p.wrap(.vector, child.converter_result),
            };
        }

        fn inputRecord(p: *Planner, id: anytype) Error!InputTypes {
            const entry = try p.input(id);
            return .{ .value = try p.wrap(.vector, entry.value), .parameter = try p.wrap(.const_span, entry.value) };
        }

        fn resultBytes(p: *Planner, id: anytype) Error!ResultTypes {
            const bytes = try p.n.cppType(.bytes);
            if (p.n.irType(p.n.get(id).type).kind() == .node_path) return .{ .logical = bytes };
            return .{
                .logical = bytes,
                .decoded = if (FactsModule.get(p.n, id).buffer_materialization != null) try p.n.cppType(.js_value) else bytes,
                .produced = bytes,
            };
        }

        fn resultOptional(p: *Planner, id: anytype) Error!ResultTypes {
            const child = try p.value(id);
            return .{
                .logical = try p.wrap(.optional, child.logical),
                .decoded = try p.wrap(.optional, child.decoded),
                .produced = try p.wrap(.optional, child.produced),
            };
        }

        fn resultAggregate(p: *Planner, id: anytype, fields: anytype) Error!ResultTypes {
            for (fields) |field| if ((try p.value(field.value)).logical == null) return .{};
            return p.aggregate(id);
        }

        fn resultSequence(p: *Planner, id: anytype) Error!ResultTypes {
            const child = try p.value(id);
            const protects_values = FactsModule.get(p.n, id).contains_engine_reference;
            const logical = if (protects_values) try p.wrap(.result_sequence, child.logical) else try p.wrap(.vector, child.logical);
            return .{
                .logical = logical,
                .decoded = logical,
                .produced = if (protects_values) try p.wrap(.result_sequence, child.produced) else try p.wrap(.vector, child.produced),
            };
        }

        fn input(p: *Planner, id: anytype) Error!InputTypes {
            const entry = &p.n.cpp_type_state.inputs.get(@TypeOf(id).role)[id.index];
            if (entry.*) |existing| return existing;
            entry.* = try p.buildInput(id);
            return entry.*.?;
        }



        fn inputLeaf(p: *Planner, id: anytype, leaf: anytype, storage: ?ir.CppTypeId) Error!InputTypes {
            const type_id = p.n.get(id).type;
            return switch (leaf) {
                inline else => |payload, tag| switch (comptime leafKind(tag)) {
                    .void, .enumeration => inputStorage(storage),
                    .scalar => inputStorage(try p.n.cppType(.{ .scalar = payload })),
                    .js_value_view, .js_value_result, .js_value_operand => .{
                        .value = storage,
                        .parameter = storage,
                        .converter_result = if (p.n.projection(type_id).js_value_kind == .branded) storage else null,
                    },
                    .string_view, .string_owned, .string_operand => try p.inputString(type_id, storage),
                    .bytes_view, .bytes_owned, .bytes_operand => try p.inputBytes(type_id),
                    .byte_lease, .lease_owned => .{ .value = storage },
                    .native_slice_view, .native_slice, .nominal_borrow, .nominal_owned, .nominal_owner_borrow,
                    .callback_view, .callback_owned, .callback_result => .{ .value = storage, .parameter = storage },
                    .class_view, .class_owned, .class_result => try p.inputClass(p.n.irType(type_id).data.class_ref.class),
                    .external_view, .external_owned => .{ .value = storage, .parameter = try p.wrap(.const_reference, storage), .converter_result = storage },
                    .lazy_field => .{ .value = try p.wrap(.lazy_argument, (try p.input(payload)).value), .parameter = try p.n.cppType(.js_value) },
                    .lazy_view, .lazy_operand => .{ .value = try p.wrap(.lazy_argument, (try p.input(payload.value)).value), .parameter = try p.n.cppType(.js_value) },
                    .native_receiver, .lazy_rest, .utf8_owned, .native_instance => .{},
                },
            };
        }

        fn buildInput(p: *Planner, id: anytype) Error!InputTypes {
            const position = p.n.get(id);
            const storage = try leafType(p.n, position.type);
            const base: InputTypes = switch (position.representation) {
                .converted => |conversion| try p.inputConverted(conversion),
                .optional => |child| try p.inputOptional(id, child),
                inline .dictionary, .union_type => |fields, tag| try p.inputAggregate(id, fields, storage, tag == .dictionary),
                .sequence => |child| try p.inputSequence(id, child),
                .record => |entry| try p.inputRecord(entry),
                inline .rest => |child| if (@TypeOf(id).role == .outbound_argument) try p.inputSequence(id, child) else .{},
                .record_entry => |entry| .{ .value = if ((try p.input(entry.key)).value) |key| if ((try p.input(entry.value)).value) |item| try p.n.cppType(.{ .pair = .{ .key = key, .value = item } }) else null else null },
                .leaf => |leaf| try p.inputLeaf(id, leaf, storage),
            };
            return .{
                .value = base.value,
                .parameter = base.parameter,
                .converter_result = base.converter_result,
                .converter_input = if (position.representation == .converted) base.converter_input else try p.n.cppType(.js_value),
            };
        }

        fn aggregate(p: *const Planner, id: anytype) Error!ResultTypes {
            const leaf_type = (try leafType(p.n, p.n.get(id).type)).?;
            const name = try p.named(try p.n.print("{s}Result", .{p.n.get(leaf_type).named.name}));
            return .{ .logical = name, .decoded = name, .produced = name };
        }

        fn pair(p: *Planner, entry: anytype) Error!ResultTypes {
            const key = try p.value(entry.key);
            const item = try p.value(entry.value);
            return .{
                .logical = try p.pairType(key.logical, item.logical),
                .decoded = try p.pairType(key.decoded, item.decoded),
                .produced = try p.pairType(key.produced, item.produced),
            };
        }

        fn pairType(p: *Planner, key: ?ir.CppTypeId, item: ?ir.CppTypeId) Error!?ir.CppTypeId {
            return try p.n.cppType(.{ .pair = .{ .key = key orelse return null, .value = item orelse return null } });
        }

        fn value(p: *Planner, id: anytype) Error!ResultTypes {
            const entry = &p.n.cpp_type_state.results.get(@TypeOf(id).role)[id.index];
            if (entry.*) |existing| return existing;
            entry.* = try p.buildValue(id);
            return entry.*.?;
        }

        fn resultLeaf(p: *Planner, id: anytype, leaf: anytype, storage: ?ir.CppTypeId) Error!ResultTypes {
            return switch (leaf) {
                inline else => |payload, tag| switch (comptime leafKind(tag)) {
                    .scalar => resultStorage(try p.n.cppType(.{ .scalar = payload })),
                    .void, .enumeration, .string_view, .string_owned, .string_operand,
                    .callback_view, .callback_owned, .callback_result,
                    .nominal_borrow, .nominal_owned, .nominal_owner_borrow => resultStorage(storage),
                    .js_value_view, .js_value_result, .js_value_operand => .{
                        .logical = storage,
                        .decoded = storage,
                        .produced = try p.n.cppType(.js_value),
                    },
                    .class_view, .class_owned, .class_result => resultStorage(try p.n.cppType(.js_value)),
                    .external_view, .external_owned => .{ .logical = storage, .produced = storage },
                    .bytes_view, .bytes_owned, .bytes_operand => try p.resultBytes(id),
                    .native_slice_view, .native_slice, .byte_lease, .lease_owned,
                    .native_receiver, .lazy_field, .lazy_view, .lazy_rest, .lazy_operand,
                    .utf8_owned, .native_instance => .{},
                },
            };
        }

        fn buildValue(p: *Planner, id: anytype) Error!ResultTypes {
            const position = p.n.get(id);
            const storage = try leafType(p.n, position.type);
            const types: ResultTypes = switch (position.representation) {
                .converted => |conversion| try p.value(conversion.value),
                .optional => |child| try p.resultOptional(child),
                inline .dictionary, .union_type => |fields| try p.resultAggregate(id, fields),
                .sequence, .record => |child| try p.resultSequence(child),
                .rest => .{},
                .record_entry => |entry| try p.pair(entry),
                .leaf => |leaf| try p.resultLeaf(id, leaf, storage),
            };
            return types;
        }
    };

    fn inputStorage(value: ?ir.CppTypeId) InputTypes {
        return .{ .value = value, .parameter = value, .converter_result = value };
    }

    fn resultStorage(value: ?ir.CppTypeId) ResultTypes {
        return .{ .logical = value, .decoded = value, .produced = value };
    }
};

pub const Predicates = struct {
    const InputPlanId = plans.InputPlanId;
    const Test = ir.CppValueTest;
    const Entry = struct {
        selection: union(enum) { unplanned, planned: ?Test } = .unplanned,
        presence: ?Test = null,
    };

    pub const State = struct {
        entries: []Entry = &.{},
    };

    pub fn planAll(n: *Normalizer) Error!void {
        const entries = try n.arena.alloc(Entry, n.input_plans.items.len);
        @memset(entries, .{});
        n.cpp_predicate_state.entries = entries;
        var planner: Planner = .{ .n = n };
        for (n.input_plans.items, entries, 0..) |plan, *entry, index| {
            const id: InputPlanId = .of(index);
            _ = try planner.inputSelection(id);
            entry.presence = if (plan.codec == .optional) try planner.presence(id) else null;
        }
    }

    pub fn selection(n: *const Normalizer, id: anytype) ?Test {
        return n.cpp_predicate_state.entries[n.get(id).input.index].selection.planned;
    }

    pub fn presence(n: *const Normalizer, id: anytype) ?Test {
        return n.cpp_predicate_state.entries[n.get(id).input.index].presence;
    }

    const Planner = struct {
        n: *Normalizer,

        fn add(p: *const Planner, test_: Test) Error!ir.CppValueTestId {
            const id: ir.CppValueTestId = .of(p.n.cpp_value_tests.items.len);
            try p.n.cpp_value_tests.append(p.n.arena, test_);
            return id;
        }

        fn children(p: *const Planner, tests: []const Test) Error![]const ir.CppValueTestId {
            const ids = try p.n.arena.alloc(ir.CppValueTestId, tests.len);
            for (tests, ids) |test_, *id| id.* = try p.add(test_);
            return ids;
        }

        fn anyOf(p: *const Planner, tests: []const Test) Error!Test {
            return .{ .any_of = try p.children(tests) };
        }

        fn negate(p: *const Planner, test_: Test) Error!Test {
            return if (test_ == .negate) p.n.cpp_value_tests.items[test_.negate.index] else .{ .negate = try p.add(test_) };
        }

        fn inputSelection(p: *Planner, id: InputPlanId) Error!?Test {
            const entry = &p.n.cpp_predicate_state.entries[id.index];
            switch (entry.selection) {
                .planned => |cached| return cached,
                .unplanned => {},
            }
            const input = p.n.input_plans.items[id.index];
            const t = p.n.irType(input.type);
            const test_: ?Test = switch (input.codec) {
                .none, .utf8_string, .native_slice, .native_instance, .nominal_handle => null,
                .converted => try p.inputSelection(input.codec.converted.match),
                .lazy => |child| try p.inputSelection(child),
                .discarded => |discarded| switch (p.n.rawType(t.id).discarded.match) {
                    .semantic_type => try p.inputSelection(discarded.match),
                    .null_literal => .null_value,
                    .undefined_literal => .undefined_value,
                    .false_literal => null,
                    .number_literal => |value| .{ .number_literal = value },
                },
                .boolean => .boolean,
                .integer => switch (p.n.projection(t.id).integer_representation.?) {
                    .bigint => .big_int,
                    .number_or_bigint => try p.anyOf(&.{ .number, .big_int }),
                    .number => if (p.n.input_conversions.items[id.index].integer_conversion == .matching) p.integer(id) else .number,
                },
                .number => .number,
                .string => switch (p.n.projection(t.id).string.?.coercion_input) {
                    .object_only => .object,
                    .string_or_boxed => try p.anyOf(&.{ .string, .string_object }),
                    else => .string,
                },
                .enumeration => if (p.n.rawType(t.id).enumeration.options.accept_native_numbers) try p.anyOf(&.{ .string, .number }) else .string,
                .buffer => blk: {
                    const buffer = p.n.projection(t.id).buffer.?;
                    break :blk if (buffer.requiresUint8Array()) .uint8_array else if (buffer.requiresUint32Array()) .uint32_array else if (buffer.requiresIntegerTypedArray()) .integer_array else if (buffer.allowsArrayBuffer()) try p.anyOf(&.{ .buffer_view, .array_buffer }) else .buffer_view;
                },
                .external_ref => if (p.n.get(t.data.external_ref).brand) |brand| .{ .brand = brand.cpp_match } else .{ .external = p.n.rawType(t.id).external_ref.options.cpp_match.symbol },
                .class_ref => .{ .class = t.data.class_ref.class },
                .branded_value => .{ .brand = t.data.branded_value.brand.cpp_match },
                .callback => .callback,
                .dictionary, .record => .object,
                .sequence => switch (p.n.rawType(input.type).sequence.options.container) {
                    .array => .array,
                    .concrete_array => .{ .brand = p.n.type_metadata.items[t.id.index].sequence_container_match.? },
                    .array_like => .object,
                    .iterable => .iterable,
                },
                .js_value => .always,
                .optional => |optional| blk: {
                    const presence_test = try p.presence(id);
                    if (optional.optional_mode == .matched or optional.optional_mode == .nullish_or_empty_string) break :blk null;
                    const child = try p.inputSelection(optional.child) orelse break :blk null;
                    break :blk try p.anyOf(&.{ try p.negate(presence_test.?), child });
                },
                .union_type => |members| blk: {
                    const options = p.n.rawType(input.type).union_type.options;
                    if (options.input_tag != null) break :blk null;
                    if (options.fallback_member != null) break :blk .always;
                    const tests = try p.n.arena.alloc(Test, members.len);
                    for (members, tests) |member, *member_test| member_test.* = try p.inputSelection(member) orelse break :blk null;
                    break :blk try p.anyOf(tests);
                },
                .node_path => if (p.n.rawType(input.type).node_path.boxed_strings) try p.anyOf(&.{ .string, .uint8_view, .url, .string_object }) else try p.anyOf(&.{ .string, .uint8_view, .url }),
            };
            entry.selection = .{ .planned = test_ };
            return test_;
        }

        fn integer(p: *const Planner, id: InputPlanId) Test {
            const input = p.n.input_plans.items[id.index];
            return .{ .integer = .{
                .wire = p.n.get(p.n.input_positions[id.index].?).wire,
                .range = FactsModule.integerRange(p.n.projection(input.type).scalar_kind.?, p.n.input_conversions.items[id.index].integer_conversion.matching),
            } };
        }

        fn presence(p: *Planner, id: InputPlanId) Error!?Test {
            const input = p.n.input_plans.items[id.index];
            return switch (input.codec.optional.optional_mode) {
                .nullable => try p.negate(.null_value),
                .nullish => try p.negate(.nullish),
                .undefined => try p.negate(.undefined_value),
                .falsy => .truthy,
                .nullish_or_empty_string => try p.negate(try p.anyOf(&.{ .nullish, .{ .all_of = try p.children(&.{ .string, try p.negate(.truthy) }) } })),
                .matched => blk: {
                    const child = p.n.input_plans.items[input.codec.optional.child.index];
                    break :blk switch (child.codec) {
                        .boolean => .boolean,
                        .number => .number,
                        .integer => switch (p.n.input_conversions.items[input.codec.optional.child.index].integer_conversion) {
                            .matching => p.integer(input.codec.optional.child),
                            .truncate_clamp => .number,
                            else => switch (p.n.projection(child.type).scalar_kind.?) {
                                .i32 => .int32,
                                .u32 => .uint32,
                                else => null,
                            },
                        },
                        .string => .string,
                        .enumeration, .branded_value, .class_ref, .external_ref => try p.inputSelection(input.codec.optional.child),
                        else => null,
                    };
                },
            };
        }
    };

    pub fn argumentSelection(n: *Normalizer, argument: ir.Argument(.inbound_argument), missing: ir.Missing) normalize.PlanError!ir.CppValueTest {
        const selected = selection(n, argument.position) orelse return n.unsupportedValue(argument.position, "this value cannot distinguish a JavaScript input");
        if (argument.conversion.presence == .required) return selected;
        const absent: ir.CppValueTest = switch (missing) {
            .omitted => return selected,
            .undefined => .undefined_value,
            .undefined_or_null => .nullish,
        };
        const planner: Planner = .{ .n = n };
        return planner.anyOf(&.{ absent, selected });
    }
};

pub fn bindingTypeOrder(n: *Normalizer) std.mem.Allocator.Error![]const ir.TypeId {
    const visited = try n.arena.alloc(bool, n.binding_type_count);
    @memset(visited, false);
    var order: std.ArrayList(ir.TypeId) = try .initCapacity(n.arena, n.binding_type_count);
    for (0..n.binding_type_count) |id| appendBindingTypeTree(n, visited, &order, .of(id));
    return order.items;
}

fn appendBindingTypeTree(n: *const Normalizer, visited: []bool, order: *std.ArrayList(ir.TypeId), id: ir.TypeId) void {
    if (visited[id.index]) return;
    visited[id.index] = true;
    switch (n.irType(id).data) {
        .converted => |converted| {
            appendBindingTypeTree(n, visited, order, converted.native_type);
            appendBindingTypeTree(n, visited, order, n.typeId(n.rawType(id).converted.match));
        },
        .lazy => |child| appendBindingTypeTree(n, visited, order, child),
        .optional => |optional| appendBindingTypeTree(n, visited, order, optional.child),
        .sequence => |sequence| appendBindingTypeTree(n, visited, order, sequence.child),
        .record => |record| {
            appendBindingTypeTree(n, visited, order, record.key_type);
            appendBindingTypeTree(n, visited, order, record.value_type);
        },
        .dictionary => |dictionary| for (dictionary.dictionary_fields) |field| appendBindingTypeTree(n, visited, order, field.field_type),
        .union_type => |union_type| for (union_type.union_members) |member| appendBindingTypeTree(n, visited, order, member.member_type),
        else => {},
    }
    order.appendAssumeCapacity(id);
}
