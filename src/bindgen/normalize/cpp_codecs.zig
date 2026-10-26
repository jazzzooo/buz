const schema = @import("bindgen_schema");
const mod_cpp_facts = @import("cpp_facts.zig");
const mod_converter_declarations = @import("converter_declarations.zig");
const mod_plans = @import("plans.zig");
const mod_types = @import("types.zig");
const CodecModule = @This();
const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const Normalizer = normalize.Normalizer;
const Error = std.mem.Allocator.Error;
const PlanError = normalize.PlanError;
const Planned = normalize.Planned;
const failures = CodecModule.Failures;

pub fn Store(comptime role: ir.Role) type {
    const info = @typeInfo(ir.CppPlan(role)).@"struct";
    const field_count = comptime count: {
        var count: usize = 0;
        for (info.field_types) |T| if (@typeInfo(T) == .pointer) {
            count += 1;
        };
        break :count count;
    };
    var names: [field_count][]const u8 = undefined;
    var types: [field_count]type = undefined;
    var attributes: [field_count]std.lang.Type.Struct.FieldAttributes = undefined;
    var index: usize = 0;
    for (info.field_names, info.field_types) |name, T| {
        if (@typeInfo(T) != .pointer) continue;
        names[index] = name;
        types[index] = std.ArrayList(@typeInfo(T).pointer.child);
        attributes[index] = .{ .default_value_ptr = &@as(types[index], .empty) };
        index += 1;
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

fn Decodes(comptime role: ir.Role) type {
    return []?Planned(ir.CppDecodePlan(role));
}

fn Encoders(comptime role: ir.Role) type {
    return struct {
        values: []?Planned(ir.CppResultEncoderId(role)) = &.{},
        children: []?Planned(ir.CppResultEncoderId(role)) = &.{},
    };
}

pub const State = struct {
    encoders: struct {
        inbound_argument: Encoders(.inbound_argument) = .{},
        inbound_result: Encoders(.inbound_result) = .{},
        outbound_result: Encoders(.outbound_result) = .{},
    } = .{},
    javascript: []?Planned(ir.CppJavaScriptDecodeId) = &.{},
    helpers: []?Planned(ir.CppResultDecoder) = &.{},
    decodes: struct {
        inbound_result: Decodes(.inbound_result) = &.{},
        outbound_argument: Decodes(.outbound_argument) = &.{},
        outbound_result: Decodes(.outbound_result) = &.{},
    } = .{},
};

pub fn encode(n: *Normalizer, id: anytype) PlanError!ir.CppResultEncoderId(@TypeOf(id).role) {
    var planner: Planner = .{ .n = n };
    return planner.encode(id);
}

pub fn decode(n: *Normalizer, id: anytype, failure: ir.CppCodecFailureId) PlanError!ir.CppDecode(@TypeOf(id).role) {
    var planner: Planner = .{ .n = n };
    return planner.decode(id, failure);
}

/// A position's decode plan, or null when nothing decodes it. Planning
/// failures are reported before the plans are read.
pub fn decodePlan(n: *const Normalizer, id: anytype) ?ir.CppDecodePlan(@TypeOf(id).role) {
    return (@field(n.cpp_codec_state.decodes, @tagName(@TypeOf(id).role))[id.index] orelse return null).planned;
}

pub fn decoderHelper(n: *const Normalizer, id: ir.InboundResultPlanId) ?ir.CppResultDecoder {
    return (n.cpp_codec_state.helpers[id.index] orelse return null).planned;
}

pub fn javascript(n: *Normalizer, id: ir.OutboundResultPlanId) PlanError!ir.CppJavaScriptDecodeId {
    var planner: Planner = .{ .n = n };
    return planner.javascript(id);
}

pub fn classReference(n: *const Normalizer, class: ir.ClassId) ?ir.CppClassReference {
    return switch (n.classes.items[class.index].representation) {
        .native => .{ .native = class },
        .engine => .{ .engine = class },
        .plain => null,
    };
}

pub fn requireClassReference(n: *Normalizer, class: ir.ClassId) PlanError!ir.CppClassReference {
    return classReference(n, class) orelse n.unsupported("instances of the plain class {s} have no engine reference", .{n.get(class).class_name});
}

const Planner = struct {
    n: *Normalizer,

    fn cached(p: *Planner, table: anytype, id: anytype, comptime build: []const u8) @TypeOf(@field(Planner, build)(p, id)) {
        if (table.*[id.index]) |planned| return p.n.replay(planned);
        const result = @field(Planner, build)(p, id);
        std.debug.assert(table.*[id.index] == null);
        table.*[id.index] = try p.n.record(result);
        return result;
    }

    pub fn encode(p: *Planner, id: anytype) PlanError!ir.CppResultEncoderId(@TypeOf(id).role) {
        const table = &@field(p.n.cpp_codec_state.encoders, @tagName(@TypeOf(id).role)).values;
        return p.cached(table, id, "buildEncode");
    }

    fn buildEncode(p: *Planner, id: anytype) PlanError!ir.CppResultEncoderId(@TypeOf(id).role) {
        const target = p.n.converters(id).result orelse return p.n.unsupportedValue(id, "this value has no C++ result converter");
        const value_type = (if (@TypeOf(id).role == .inbound_argument) mod_cpp_facts.Types.input(p.n, id).value else mod_cpp_facts.Types.result(p.n, id).produced) orelse
            return p.n.unsupportedValue(id, "this value has no C++ value type");
        const operation = try encodeOperation(p.n, id, p);
        const plan: ir.CppResultEncoder(@TypeOf(id).role) = .{ .value_type = value_type, .requires_global = mod_cpp_facts.get(p.n, target).decode_requires_realm, .wire = p.n.get(target).wire, .operation = operation };
        return p.n.addCpp(id, "result_encoders", plan);
    }

    pub const dictionary_sources = false;
    pub fn Id(comptime role: ir.Role) type {
        return ir.CppResultEncoderId(role);
    }
    pub fn Operation(comptime role: ir.Role) type {
        return @FieldType(ir.CppResultEncoder(role), "operation");
    }

    pub fn encodeConverted(p: *Planner, id: anytype, conversion: ir.ConvertedPosition(@TypeOf(id).role)) PlanError!Id(@TypeOf(id).role) {
        return p.encode(conversion.apiValue());
    }

    pub fn collection(p: *Planner, id: anytype, child: @TypeOf(id), record: bool) PlanError!@FieldType(Operation(@TypeOf(id).role), "collection") {
        const target = p.n.converters(id).result orelse return p.n.unsupportedValue(id, "this value has no C++ result converter");
        return .{
            .wire = p.collectionWire(target) orelse return p.n.unsupportedValue(id, "this value has no C++ collection result"),
            .element = if (record) try p.encodeRecordValue(child) else try p.encodeCollectionValue(child),
        };
    }

    pub fn encodeLeaf(p: *Planner, id: anytype) PlanError!@FieldType(Operation(@TypeOf(id).role), "leaf") {
        const position = p.n.get(id).*;
        const t = p.n.irType(position.type);
        const leaf_ = position.representation.leaf;
        const unencodable = "this value has no C++ result encoding";
        if (@TypeOf(id).role == .outbound_argument) @compileError("outbound arguments are encoded natively");
        return switch (leaf_) {
            inline else => |value, tag| switch (comptime mod_cpp_facts.leafKind(tag)) {
                .void => .void,
                .scalar => .{ .scalar = value },
                .enumeration => .{ .enumeration = switch (p.n.get(t.data.enumeration).tag) {
                    .u8 => .uint8_t,
                    .u16 => .uint16_t,
                } },
                .js_value_view, .js_value_result => .{ .value = mod_cpp_facts.javascriptValue(p.n, position.type, value) },
                .callback_view, .callback_owned, .callback_result => .{ .callback = p.n.rawType(position.type).callback.options.retains_async_context },
                .class_view => .class_ref,
                .class_owned, .class_result => .{ .class_ref = try requireClassReference(p.n, t.data.class_ref.class) },
                .string_view, .string_owned => .{ .string = .{ .thread_safe = p.n.projection(t.id).string.?.thread_safe } },
                .bytes_view, .bytes_owned => if (p.n.projection(t.id).buffer != null) .bytes else p.n.unsupportedValue(id, unencodable),
                .nominal_borrow, .nominal_owned => .{ .nominal_handle = mod_cpp_facts.nominalHandle(p.n, position.type) },
                .native_slice_view, .byte_lease, .external_view, .native_receiver, .lazy_field, .lazy_view, .lazy_rest,
                .utf8_owned, .lease_owned, .external_owned, .native_instance => p.n.unsupportedValue(id, unencodable),
                .js_value_operand, .string_operand, .bytes_operand, .native_slice, .nominal_owner_borrow, .lazy_operand =>
                    @compileError("outbound arguments are encoded natively"),
            },
        };
    }

    pub fn encodeChild(p: *Planner, id: anytype) PlanError!ir.CppResultEncoderId(@TypeOf(id).role) {
        const table = &@field(p.n.cpp_codec_state.encoders, @tagName(@TypeOf(id).role)).children;
        return p.cached(table, id, "buildEncodeChild");
    }

    /// An aggregate child encodes through a helper: an inbound argument through
    /// its nested semantic converter, a result through its result converter's
    /// standalone encoder.
    fn buildEncodeChild(p: *Planner, id: anytype) PlanError!ir.CppResultEncoderId(@TypeOf(id).role) {
        const encoded = try p.encode(id);
        const encoder = p.n.get(encoded).*;
        switch (encoder.operation) {
            .dictionary, .union_type, .collection => {},
            .leaf, .converted, .optional, .entry => return encoded,
        }
        const operation: @FieldType(ir.CppResultEncoder(@TypeOf(id).role), "operation") = if (@TypeOf(id).role == .inbound_argument)
            .{ .leaf = .helper }
        else
            .{ .leaf = .{ .helper = try p.encode(p.n.converters(id).result orelse return p.n.unsupportedValue(id, "this value has no C++ result converter")) } };
        return p.n.addCpp(id, "result_encoders", .{
            .value_type = encoder.value_type,
            .requires_global = encoder.requires_global,
            .wire = encoder.wire,
            .operation = operation,
        });
    }

    fn encodeCollectionValue(p: *Planner, id: anytype) PlanError!ir.CppResultElement(@TypeOf(id).role) {
        const encoded = try p.encodeChild(id);
        return if (@TypeOf(id).role == .inbound_argument and mod_cpp_facts.get(p.n, id).collection_storage) .{ .sequence = encoded } else .{ .direct = encoded };
    }

    fn encodeRecordValue(p: *Planner, id: anytype) PlanError!ir.CppResultElement(@TypeOf(id).role) {
        const encoded = try p.encode(id);
        return if (@TypeOf(id).role == .inbound_argument and mod_cpp_facts.get(p.n, p.n.get(id).representation.record_entry.value).collection_storage) .{ .record = encoded } else .{ .direct = encoded };
    }

    fn collectionWire(p: *const Planner, id: ir.InboundResultPlanId) ?ir.WireTypeId {
        return switch (p.n.get(id).representation) {
            inline .sequence, .record, .rest => |child| p.n.get(child).wire,
            .converted, .optional, .dictionary, .union_type, .record_entry, .leaf => null,
        };
    }

    fn javascript(p: *Planner, id: ir.OutboundResultPlanId) PlanError!ir.CppJavaScriptDecodeId {
        const table = &p.n.cpp_codec_state.javascript;
        return p.cached(table, id, "buildJavaScript");
    }

    fn buildJavaScript(p: *Planner, id: ir.OutboundResultPlanId) PlanError!ir.CppJavaScriptDecodeId {
        const position = p.n.get(id).*;
        const input = p.n.input_plans.items[position.input.index];
        const operation: @FieldType(ir.CppJavaScriptDecode, "operation") = switch (input.codec) {
            .none => .void,
            .boolean, .integer, .number => .{ .scalar = try CodecModule.Scalar.build(p.n, id, .status) },
            .js_value => .value,
            .branded_value => .{ .branded = try CodecModule.InputErrors.branded(p.n, id) },
            .callback => .{ .callback = CodecModule.InputErrors.callback(p.n, id) },
            .string => .{ .string = try CodecModule.Input.string(p.n, id, .status) },
            .buffer => buffer: {
                const projection = p.n.projection(position.type).buffer.?;
                if (projection.effective_mode != .copy) return p.n.unsupportedValue(id, "typed callback buffers require copy ownership");
                break :buffer .{ .bytes = try CodecModule.Buffer.result(p.n, id, projection) };
            },
            // The semantic converter's `encodeResult` writes the converted value
            // to the wire; `resultEncodingConverters` exposes it once planning ends.
            .dictionary, .sequence, .record, .union_type => aggregate: {
                const converter = p.n.converters(id).input orelse return p.n.unsupportedValue(id, "this value has no C++ JavaScript input converter");
                _ = try p.encode(converter);
                break :aggregate .{ .aggregate = try CodecModule.Input.aggregate(p.n, converter) };
            },
            .optional => .{ .optional = .{
                .value = try p.javascript(position.representation.optional),
                .presence = mod_cpp_facts.Predicates.presence(p.n, id) orelse return p.n.unsupportedValue(id, "this value has no optional presence test"),
            } },
            .discarded, .converted, .enumeration, .class_ref => return p.n.unsupportedValue(id, "typed callback and engine JavaScript results support this value only inside an aggregate"),
            .lazy, .utf8_string, .node_path, .native_slice, .external_ref, .native_instance, .nominal_handle => return p.n.unsupportedValue(id, "this binding type cannot be a typed callback or engine JavaScript result"),
        };
        return p.n.addCpp(id, "javascript_decoders", .{ .failure = .status, .operation = operation });
    }

    fn decode(p: *Planner, id: anytype, failure: ir.CppCodecFailureId) PlanError!ir.CppDecode(@TypeOf(id).role) {
        _ = try p.planDecode(id);
        return .{ .position = id, .failure = failure };
    }

    fn planDecode(p: *Planner, id: anytype) PlanError!ir.CppDecodePlan(@TypeOf(id).role) {
        const table = &@field(p.n.cpp_codec_state.decodes, @tagName(@TypeOf(id).role));
        return p.cached(table, id, "buildDecode");
    }

    /// Aggregate results decode through their result converter's helper.
    fn buildDecode(p: *Planner, id: anytype) PlanError!ir.CppDecodePlan(@TypeOf(id).role) {
        const role = @TypeOf(id).role;
        const value_type = (if (role == .outbound_argument) mod_cpp_facts.Types.input(p.n, id).value else mod_cpp_facts.Types.result(p.n, id).decoded) orelse
            return p.n.unsupportedValue(id, "this value has no C++ value type");
        if (role != .outbound_argument and decodesAggregate(p.n.get(id).representation)) if (p.n.converters(id).result) |target| {
            _ = try p.planDecodeHelper(target);
            return .{ .value_type = value_type, .operation = .{ .helper = target } };
        };
        return .{ .value_type = value_type, .operation = .{ .body = try p.decodeBody(id) } };
    }

    fn planDecodeHelper(p: *Planner, id: ir.InboundResultPlanId) PlanError!ir.CppResultDecoder {
        const table = &p.n.cpp_codec_state.helpers;
        return p.cached(table, id, "buildDecodeHelper");
    }

    fn buildDecodeHelper(p: *Planner, id: ir.InboundResultPlanId) PlanError!ir.CppResultDecoder {
        return .{
            .value_type = mod_cpp_facts.Types.result(p.n, id).decoded orelse return p.n.unsupportedValue(id, "this value has no C++ value type"),
            .wire = p.n.get(id).wire,
            .allocates = mod_cpp_facts.get(p.n, id).decode_allocates,
            .failure = try failures.decoder(p.n, .inbound_result),
            .body = try p.decodeBody(id),
        };
    }

    fn decodeBody(p: *Planner, id: anytype) PlanError!ir.CppDecodeBody(@TypeOf(id).role) {
        const role = @TypeOf(id).role;
        const position = p.n.get(id).*;
        try p.planChildren(position.representation);
        const facts = mod_cpp_facts.get(p.n, id).*;
        return .{
            .cleanup = role != .outbound_argument and facts.contains_owned_handle,
            .roots = if (role == .outbound_argument) .none else if (decodesAggregate(position.representation) and facts.decode_requires_realm) .target else .enclosing,
            .converter = if (role == .outbound_argument and position.representation == .converted) .{
                .declaration = try mod_converter_declarations.declaration(p.n, id),
                .infallible = p.n.rawType(position.type).converted.converter.options.infallible,
                .path_override = p.n.input_plans.items[position.input.index].path_override,
            } else null,
            .span = facts.sequence_span,
            .leaf = switch (position.representation) {
                .leaf => |leaf| try p.decodeLeaf(id, leaf),
                else => null,
            },
        };
    }

    fn planChildren(p: *Planner, representation: anytype) PlanError!void {
        switch (representation) {
            .converted => |conversion| _ = try p.planDecode(conversion.apiValue()),
            .optional => |child| _ = try p.planDecode(child),
            inline .dictionary, .union_type => |fields| for (fields) |field| {
                _ = try p.planDecode(field.value);
            },
            inline .sequence, .record, .rest => |child| _ = try p.planDecode(child),
            .record_entry => |entry| {
                _ = try p.planDecode(entry.key);
                _ = try p.planDecode(entry.value);
            },
            .leaf => {},
        }
    }

    fn decodesAggregate(representation: anytype) bool {
        return switch (representation) {
            .dictionary, .union_type, .sequence, .record, .rest => true,
            .converted, .optional, .record_entry, .leaf => false,
        };
    }

    fn decodeLeaf(p: *Planner, id: anytype, leaf: @FieldType(ir.Representation(@TypeOf(id).role), "leaf")) PlanError!ir.CppDecodeLeaf(@TypeOf(id).role) {
        const position = p.n.get(id).*;
        const undecodable = "this value has no C++ wire decoding";
        if (@TypeOf(id).role == .inbound_argument) @compileError("inbound arguments are decoded by their input conversions");
        return switch (leaf) {
            inline else => |value, tag| switch (comptime mod_cpp_facts.leafKind(tag)) {
                .void => .void,
                .scalar => .{ .scalar = value },
                .enumeration => .{ .enumeration = try CodecModule.Enumeration.nativeTags(p.n, position.type) },
                .js_value_operand, .js_value_result => .{ .encoded_value = mod_cpp_facts.javascriptValue(p.n, position.type, value) },
                .callback_owned, .callback_result => .callback_root,
                .callback_view => .callback_borrow,
                .class_owned, .class_result => .{ .class_root = try requireClassReference(p.n, p.n.irType(position.type).data.class_ref.class) },
                .class_view => .{ .class_borrow = try requireClassReference(p.n, p.n.irType(position.type).data.class_ref.class) },
                .string_owned => if (@TypeOf(id).role == .outbound_argument) .string_borrow else .string_take,
                .string_operand => .string_borrow,
                .bytes_owned => if (mod_cpp_facts.get(p.n, id).buffer_materialization) |representation| .{ .buffer_materialize = representation } else .bytes_take,
                .bytes_operand, .native_slice => .slice_borrow,
                .nominal_borrow, .nominal_owner_borrow => .handle_borrow,
                .nominal_owned => if (@TypeOf(id).role == .outbound_argument) .handle_borrow else .handle_take,
                // Zig forces the operand through its lazy-field protocol.
                .lazy_operand => lazy: {
                    _ = try CodecModule.Input.lazyField(p.n, value.protocol);
                    break :lazy .{ .lazy = .{
                        .value_type = mod_cpp_facts.Types.input(p.n, value.value).value orelse return p.n.unsupportedValue(value.value, "this value has no C++ value type"),
                        .protocol = value.protocol,
                    } };
                },
                .utf8_owned, .lease_owned, .external_owned, .native_instance => p.n.unsupportedValue(id, undecodable),
                .js_value_view, .string_view, .bytes_view, .native_slice_view, .byte_lease, .external_view,
                .native_receiver, .lazy_field, .lazy_view, .lazy_rest =>
                    @compileError("inbound arguments are decoded by their input conversions"),
            },
        };
    }
};

pub fn encodeOperation(n: *Normalizer, id: anytype, planner: anytype) PlanError!@typeInfo(@TypeOf(planner)).pointer.child.Operation(@TypeOf(id).role) {
    const P = @typeInfo(@TypeOf(planner)).pointer.child;
    const role = @TypeOf(id).role;
    const Child = P.Id(role);
    return switch (n.get(id).representation) {
        .converted => |conversion| .{ .converted = try planner.encodeConverted(id, conversion) },
        .optional => |child| .{ .optional = try planner.encodeChild(child) },
        .dictionary => |fields| dictionary: {
            const values = try n.arena.alloc(ir.CppCodecField(Child), fields.len);
            for (fields, values) |field, *value| {
                if (field.dictionary_source and !P.dictionary_sources) return n.unsupportedValue(id, "dictionary sources have no C++ result encoding");
                value.* = .{
                    .name = field.name,
                    .value = try planner.encodeChild(field.value),
                    .optional = field.optional,
                    .dictionary_source = field.dictionary_source,
                };
            }
            break :dictionary .{ .dictionary = values };
        },
        .union_type => |members| members: {
            const values = try n.arena.alloc(ir.CppCodecMember(Child), members.len);
            for (members, values) |member, *value| value.* = .{ .name = member.name, .value = try planner.encodeChild(member.value) };
            break :members .{ .union_type = values };
        },
        inline .sequence, .record => |child, tag| .{ .collection = try planner.collection(id, child, tag == .record) },
        .rest => n.unsupportedValue(id, "rest values have no C++ encoding"),
        .record_entry => |entry| .{ .entry = .{ .key = try planner.encode(entry.key), .value = try planner.encodeChild(entry.value) } },
        .leaf => .{ .leaf = try planner.encodeLeaf(id) },
    };
}

pub const Defaults = struct {
    fn nativePosition(n: *const Normalizer, id: anytype) @TypeOf(id) {
        const position = n.get(id).*;
        return switch (position.representation) {
            .converted => |conversion| nativePosition(n, conversion.value),
            .dictionary, .optional, .record, .record_entry, .rest, .sequence, .union_type, .leaf => id,
        };
    }

    pub fn initializers(n: *Normalizer, class: ir.ClassId, function: *const ir.Function, implementation: ir.CppImplementationId) PlanError!ir.ClassInitializers.Entry {
        const properties = n.get(class).instance_properties;
        const result = try n.arena.alloc(ir.PlainInitializer, properties.len);
        for (properties, n.declared_classes.items[class.index].class.instance_properties, result) |property, raw, *output| {
            const initializer = raw.options.initializer.?;
            const argument_name = switch (initializer) {
                .constant => |constant| {
                    const value = try lower(n, property.position, constant);
                    output.* = .{ .property_name = property.property_name, .value = .{ .constant = .{
                        .value = value,
                        .materializer = try CodecModule.Materialize.planJavaScript(n, value.position, .native),
                    } } };
                    continue;
                },
                .argument => |name| name,
                .argument_field => |field| field.argument,
                .argument_bigint_quotient => |quotient| quotient.argument,
            };
            const argument = for (function.args) |argument| {
                if (std.mem.eql(u8, argument.argument_name, argument_name)) break argument;
            } else unreachable;
            var position = nativePosition(n, argument.position);
            const field_name = if (initializer == .argument_field) initializer.argument_field.field else null;
            if (field_name) |name| {
                position = for (n.get(position).*.representation.dictionary) |field| {
                    if (std.mem.eql(u8, field.name, name)) break nativePosition(n, field.value);
                } else unreachable;
            }
            const divisor = if (initializer == .argument_bigint_quotient) initializer.argument_bigint_quotient.divisor else null;
            output.* = .{
                .property_name = property.property_name,
                .value = .{ .source = .{
                    .access = .{ .argument_name = argument_name, .field_name = field_name, .optional = argument.conversion.presence == .optional },
                    .conversion = if (divisor) |value| .{ .bigint_quotient = value } else .{ .materialize = try CodecModule.Materialize.planJavaScript(n, position, .native) },
                } },
            };
        }
        return .{ .implementation = implementation, .values = result };
    }

    fn defaultType(n: *Normalizer, id: anytype) PlanError!ir.CppTypeId {
        return try mod_cpp_facts.Types.leafType(n, n.get(id).type) orelse n.unsupportedValue(id, "this value has no C++ default literal");
    }

    pub fn lower(n: *Normalizer, id: anytype, value: ir.DefaultValue) PlanError!ir.CppDefaultValue(@TypeOf(id).role) {
        const position = n.get(id).*;
        const t = n.irType(position.type);
        if (position.representation == .optional and value != .null) {
            const result = try lower(n, position.representation.optional, value);
            const wrappers = try n.arena.alloc(ir.CppTypeId, result.wrappers.len + 1);
            wrappers[0] = try n.cppType(.{ .optional = if (result.wrappers.len == 0) try defaultType(n, result.position) else result.wrappers[0] });
            @memcpy(wrappers[1..], result.wrappers);
            return .{ .position = id, .wrappers = wrappers, .operation = result.operation };
        }
        if (position.representation == .converted) return lower(n, position.representation.converted.apiValue(), value);
        const operation: ir.CppLiteral = if (position.representation == .optional) .empty_optional else switch (value) {
            .boolean => |boolean| .{ .boolean = boolean },
            .signed, .unsigned => number: {
                const kind = n.projection(position.type).scalar_kind.?;
                const integer: i128 = if (value == .signed) value.signed else value.unsigned;
                break :number if (kind == .f64) .{ .number = @floatFromInt(integer) } else .{ .integer = mod_cpp_facts.integerLiteral(kind, integer).? };
            },
            .float => |number| .{ .number = number },
            .string => |string| if (t.data == .enumeration) .{ .enumeration = .{
                .type = try defaultType(n, id),
                .value = for (n.get(t.data.enumeration).enumeration_values) |member| {
                    if (std.mem.eql(u8, member.js_value, string)) break member.native_value;
                } else unreachable,
            } } else .{ .string = string },
            .null => if (n.projection(t.id).js_value_kind == .any) .any_null else .null_value,
            .undefined => if (n.projection(t.id).js_value_kind == .any) .any_undefined else .undefined_value,
        };
        return .{ .position = id, .operation = operation };
    }
};

pub const Native = struct {
    fn Key(comptime role: ir.Role) type {
        return struct { position: role.PlanId(), failure: ir.CppCodecFailureId };
    }

    pub const State = struct {
        encoders: struct {
            inbound_argument: std.AutoHashMapUnmanaged(Key(.inbound_argument), Planned(ir.CppNativeEncodeId(.inbound_argument))) = .empty,
            outbound_argument: std.AutoHashMapUnmanaged(Key(.outbound_argument), Planned(ir.CppNativeEncodeId(.outbound_argument))) = .empty,
        } = .{},
        parameters: std.AutoHashMapUnmanaged(Key(.inbound_argument), Planned(ir.CppNativeParameterId)) = .empty,
    };

    pub fn parameter(n: *Normalizer, id: ir.InboundArgumentPlanId, failure: ir.CppCodecFailureId) PlanError!ir.CppNativeParameterId {
        const key: Key(.inbound_argument) = .{ .position = id, .failure = failure };
        if (n.cpp_native_state.parameters.get(key)) |planned| return n.replay(planned);
        const result = buildParameter(n, id, failure);
        try n.cpp_native_state.parameters.putNoClobber(n.arena, key, try n.record(result));
        return result;
    }

    fn buildParameter(n: *Normalizer, id: ir.InboundArgumentPlanId, failure: ir.CppCodecFailureId) PlanError!ir.CppNativeParameterId {
        const operation: @FieldType(ir.CppNativeParameter, "operation") = switch (mod_cpp_facts.nativeParameter(n, id)) {
            .javascript => .{ .javascript = try CodecModule.Input.value(n, id, true, .false_value) },
            .lazy => .{ .lazy = try CodecModule.Input.value(n, id, true, .false_value) },
            .encode => .{ .encode = try encoder(n, id, failure) },
            .optional => |child| .{ .optional = try parameter(n, child, failure) },
        };
        return n.addCpp(id, "parameters", .{
            .failure = failure,
            .type = mod_cpp_facts.Types.input(n, id).parameter orelse return n.unsupportedValue(id, "this value has no C++ native parameter type"),
            .operation = operation,
        });
    }

    pub fn encoder(n: *Normalizer, id: anytype, failure: ir.CppCodecFailureId) PlanError!ir.CppNativeEncodeId(@TypeOf(id).role) {
        const role = @TypeOf(id).role;
        const index = &@field(n.cpp_native_state.encoders, @tagName(role));
        const key: Key(role) = .{ .position = id, .failure = failure };
        if (index.get(key)) |planned| return n.replay(planned);
        const result = buildEncoder(n, id, failure);
        try index.put(n.arena, key, try n.record(result));
        return result;
    }

    fn buildEncoder(n: *Normalizer, id: anytype, failure: ir.CppCodecFailureId) PlanError!ir.CppNativeEncodeId(@TypeOf(id).role) {
        const role = @TypeOf(id).role;
        const position = n.get(id).*;
        var planner: Encoder = .{ .n = n, .failure = failure };
        const operation = try CodecModule.encodeOperation(n, id, &planner);
        const value: ir.CppNativeEncode(role) = .{ .wire = position.wire, .failure = failure, .operation = operation, .protects_sources = protectsSources(n, id, operation) };
        return n.addCpp(id, "native_encoders", value);
    }

    const Encoder = struct {
        n: *Normalizer,
        failure: ir.CppCodecFailureId,
        pub const dictionary_sources = true;

        pub fn Id(comptime role: ir.Role) type {
            return ir.CppNativeEncodeId(role);
        }
        pub fn Operation(comptime role: ir.Role) type {
            return @FieldType(ir.CppNativeEncode(role), "operation");
        }

        pub fn encode(p: *Encoder, id: anytype) PlanError!Id(@TypeOf(id).role) {
            return encoder(p.n, id, p.failure);
        }

        pub fn encodeChild(p: *Encoder, id: anytype) PlanError!Id(@TypeOf(id).role) {
            return p.encode(id);
        }

        pub fn encodeConverted(p: *Encoder, id: anytype, conversion: ir.ConvertedPosition(@TypeOf(id).role)) PlanError!Id(@TypeOf(id).role) {
            if (@TypeOf(id).role == .outbound_argument) return p.n.unsupportedValue(id, "converted engine operands have no native C++ encoding");
            return p.encode(conversion.apiValue());
        }

        pub fn collection(p: *Encoder, id: anytype, child: @TypeOf(id), record: bool) PlanError!Id(@TypeOf(id).role) {
            _ = record;
            return p.encode(child);
        }

        /// A lazy field crosses as a handle that Zig forces through its
        /// protocol. The protocol's conversion is recorded before the field's
        /// own input encoder, which also encodes the field as a handle.
        pub fn encodeLeaf(p: *Encoder, id: anytype) PlanError!ir.CppNativeEncodingLeaf(@TypeOf(id).role) {
            const leaf = mod_cpp_facts.nativeEncodingLeaf(p.n, id) orelse return p.n.unsupportedValue(id, "this value has no native C++ encoding");
            if (@TypeOf(id).role == .inbound_argument and p.n.get(id).representation.leaf == .lazy_field and !p.n.cpp_input_state.lazy_fields.contains(id))
                _ = try CodecModule.Input.lazyField(p.n, id);
            return leaf;
        }
    };

    fn protectsSources(n: *const Normalizer, id: anytype, operation: @FieldType(ir.CppNativeEncode(@TypeOf(id).role), "operation")) bool {
        return switch (operation) {
            .leaf => |leaf| switch (leaf) {
                .value, .callback => mod_cpp_facts.get(n, id).protects_native,
                .scalar, .enumeration, .string, .bytes, .native_slice, .handle, .lazy_handle => false,
            },
            .converted, .optional, .collection => |child| n.get(child).protects_sources,
            inline .dictionary, .union_type => |fields| fields: {
                for (fields) |field| if (n.get(field.value).protects_sources) break :fields true;
                break :fields false;
            },
            .entry => |entry| n.get(entry.key).protects_sources or n.get(entry.value).protects_sources,
        };
    }
};

pub const Materialize = struct {
    fn Key(comptime role: ir.Role) type {
        return struct { position: role.PlanId(), source: ir.CppMaterializationSource };
    }
    pub fn State(comptime role: ir.Role) type {
        return std.AutoHashMapUnmanaged(Key(role), Planned(ir.CppMaterializerId(role)));
    }

    pub const Tables = struct {
        inbound_argument: Materialize.State(.inbound_argument) = .empty,
        inbound_result: Materialize.State(.inbound_result) = .empty,
        outbound_argument: Materialize.State(.outbound_argument) = .empty,
        outbound_result: Materialize.State(.outbound_result) = .empty,
    };

    pub fn planJavaScript(n: *Normalizer, id: anytype, source: ir.CppMaterializationSource) PlanError!ir.CppMaterializerId(@TypeOf(id).role) {
        const table = &@field(n.cpp_materializers, @tagName(@TypeOf(id).role));
        const key: Key(@TypeOf(id).role) = .{ .position = id, .source = source };
        if (table.get(key)) |planned| return n.replay(planned);
        const result = build(n, id, source);
        try table.putNoClobber(n.arena, key, try n.record(result));
        return result;
    }

    fn build(n: *Normalizer, id: anytype, source: ir.CppMaterializationSource) PlanError!ir.CppMaterializerId(@TypeOf(id).role) {
        const position = n.get(id).*;
        const t = n.irType(position.type);
        const materialization: ir.JavaScriptMaterialization(@TypeOf(id).role) = switch (position.representation) {
            .converted => |conversion| return planJavaScript(n, conversion.apiValue(), source),
            .optional => |child| .{ .optional = .{
                .value = try planJavaScript(n, child, source),
                .absence = optionalAbsence(t.data.optional.optional_mode) orelse return n.unsupportedValue(id, "matched optional values have no JavaScript absence"),
            } },
            .dictionary => |fields| .{ .dictionary = try materializedDictionary(n, id, fields, source) },
            .union_type => |members| .{ .union_type = try materializedMembers(n, id, members, source) },
            .sequence => |child| .{ .sequence = .{ .value = try planJavaScript(n, child, source), .frozen = n.rawType(position.type).sequence.options.flavor == .frozen_array } },
            .record => |entry| .{ .record = .{ .object = object(n.rawType(position.type).record.options.result_prototype, n.rawType(position.type).record.options.result_to_string_tag), .value = try planJavaScript(n, n.get(entry).representation.record_entry.value, source) } },
            .rest, .record_entry => return n.unsupportedValue(id, "this value cannot be materialized as JavaScript"),
            .leaf => .{ .leaf = mod_cpp_facts.materializationLeaf(n, id, source) orelse return n.unsupportedValue(id, "this value cannot be materialized as JavaScript") },
        };
        return n.addCpp(id, "materializers", .{
            .source = switch (source) {
                .wire => .{ .wire = .{ .type = position.wire, .transfer = position.ownership == .transfer } },
                .native => .{ .native = (if (@TypeOf(id).role == .inbound_argument or @TypeOf(id).role == .outbound_argument) mod_cpp_facts.Types.input(n, id).value else mod_cpp_facts.Types.result(n, id).logical) orelse
                    return n.unsupportedValue(id, "this value has no C++ value type") },
            },
            .operation = materialization,
        });
    }

    fn materializedDictionary(n: *Normalizer, id: anytype, fields: anytype, source: ir.CppMaterializationSource) PlanError!ir.CppDictionaryMaterialization(ir.CppMaterializerId(@TypeOf(id).role)) {
        const result = try n.arena.alloc(ir.CppMaterializedField(ir.CppMaterializerId(@TypeOf(id).role)), fields.len);
        const dictionary = n.rawType(n.get(id).type).dictionary;
        for (fields, result, 0..) |field_, *output, index| output.* = .{
            .name = field_.name,
            .property = if (dictionary.options.result_class != null) .{ .offset = @intCast(index) } else .{ .name = dictionary.fields[index].propertyName() },
            .value = try planJavaScript(n, field_.value, source),
            .optional = field_.optional,
        };
        return .{ .object = dictionaryObject(n, dictionary.options), .fields = result };
    }

    fn materializedMembers(n: *Normalizer, id: anytype, members: anytype, source: ir.CppMaterializationSource) PlanError![]const ir.CppCodecMember(ir.CppMaterializerId(@TypeOf(id).role)) {
        const result = try n.arena.alloc(ir.CppCodecMember(ir.CppMaterializerId(@TypeOf(id).role)), members.len);
        for (members, result) |member, *output| output.* = .{ .name = member.name, .value = try planJavaScript(n, member.value, source) };
        return result;
    }

    pub fn dictionaryObject(n: *const Normalizer, options: schema.DictionaryOptions) ir.CppObjectCreation {
        if (options.result_class) |name| return .{ .class = .of(n.classId(.{ .module = name.module, .class = name.class.name }).?) };
        return object(options.result_prototype, options.result_to_string_tag);
    }

    pub fn object(prototype: schema.ResultObjectPrototype, tag: ?[]const u8) ir.CppObjectCreation {
        return switch (prototype) {
            .ordinary => .{ .ordinary = tag },
            .null => .{ .null_prototype = tag },
        };
    }

    pub fn optionalAbsence(mode: ir.OptionalMode) ?ir.CppOptionalAbsence {
        return switch (mode) {
            .undefined => .undefined_value,
            .nullable, .nullish, .falsy, .nullish_or_empty_string => .null_value,
            .matched => null,
        };
    }
};

pub const Input = struct {
    const errors = CodecModule.InputErrors;

    const Key = struct { position: ir.InboundArgumentPlanId, names_path: bool, failure: ir.CppInputFailure };

    pub const State = struct {
        aggregates: std.AutoHashMapUnmanaged(ir.InboundArgumentPlanId, Planned(ir.CppInputAggregateId)) = .empty,
        /// The conversion behind each planned lazy-field protocol.
        lazy_fields: std.AutoHashMapUnmanaged(ir.InboundArgumentPlanId, ir.CppInputId) = .empty,
        values: std.AutoHashMapUnmanaged(Key, Planned(ir.CppInputId)) = .empty,
    };

    pub fn lazyField(n: *Normalizer, id: ir.InboundArgumentPlanId) PlanError!ir.CppInputId {
        return (try lazy(n, id, true, .false_value)).value;
    }

    pub fn value(n: *Normalizer, id: ir.InboundArgumentPlanId, names_path: bool, failure: ir.CppInputFailure) PlanError!ir.CppInputId {
        const key: Key = .{ .position = id, .names_path = names_path, .failure = failure };
        if (n.cpp_input_state.values.get(key)) |planned| return n.replay(planned);
        const result = buildValue(n, id, names_path, failure);
        try n.cpp_input_state.values.putNoClobber(n.arena, key, try n.record(result));
        return result;
    }

    fn buildValue(n: *Normalizer, id: ir.InboundArgumentPlanId, names_path: bool, failure: ir.CppInputFailure) PlanError!ir.CppInputId {
        const position = n.get(id).*;
        const input = n.input_plans.items[position.input.index];
        const facts = mod_plans.inputFacts(n, position.input);
        const unconvertible = "this value has no C++ JavaScript input converter";
        const value_type = mod_cpp_facts.Types.input(n, id).value orelse return n.unsupportedValue(id, unconvertible);
        const operation: @FieldType(ir.CppInput, "operation") = switch (position.representation) {
            .converted => |conversion| .{ .converted = .{
                .match = try value(n, conversion.match, true, failure),
                .declaration = try mod_converter_declarations.declaration(n, id),
                .path = input.path_override,
            } },
            .optional => |child| .{ .optional = .{
                .value = try value(n, child, names_path, failure),
                .presence = mod_cpp_facts.Predicates.presence(n, id) orelse return n.unsupportedValue(id, "this value has no optional presence test"),
                .tracks_lease_presence = facts.effective_buffer_mode_mask & 2 != 0,
            } },
            .dictionary, .union_type, .sequence, .record => .{ .aggregate = try aggregate(n, id) },
            .record_entry, .rest => return n.unsupportedValue(id, unconvertible),
            .leaf => |leaf| switch (leaf) {
                .void => .void,
                .scalar => |kind| if (kind == .discarded) .discarded else .{ .scalar = try CodecModule.Scalar.build(n, id, failure) },
                .enumeration => .{ .enumeration = try CodecModule.Enumeration.build(n, id, value_type, failure) },
                .string_view => if (input.codec == .utf8_string) return n.unsupportedValue(id, unconvertible) else .{ .string = try string(n, id, failure) },
                .bytes_view => if (input.codec == .node_path) .{ .node_path = n.rawType(position.type).node_path } else if (input.codec == .buffer) .{ .buffer = try CodecModule.Buffer.input(n, id, n.projection(position.type).buffer.?, names_path, failure) } else return n.unsupportedValue(id, unconvertible),
                .byte_lease => .{ .buffer = try CodecModule.Buffer.input(n, id, n.projection(position.type).buffer.?, names_path, failure) },
                .external_view => .{ .external_ref = .{
                    .type = n.get(n.irType(position.type).data.external_ref).cpp_idl,
                    .context = input.conversion_context,
                    .failure = failure,
                } },
                .js_value_view => |kind| switch (kind) {
                    .any, .engine_value => .{ .value = kind },
                    .branded => .{ .branded_value = try errors.branded(n, id) },
                },
                .callback_view => .{ .callback = errors.callback(n, id) },
                .class_view => .{ .class_ref = .{
                    .reference = try requireClassReference(n, n.irType(position.type).data.class_ref.class),
                    .failure = try errors.classReference(n, id),
                } },
                .lazy_field => |child| lazy: {
                    const conversion = try value(n, child, true, .false_value);
                    try n.cpp_input_state.lazy_fields.put(n.arena, id, conversion);
                    break :lazy .{ .lazy = .{ .conversion = .{ .value = conversion, .protocol = n.converters(id).input orelse return n.unsupportedValue(id, unconvertible) }, .source = .value, .required = null, .prefetch = false } };
                },
                .lazy_view => |deferred| .{ .lazy = .{ .conversion = .{ .value = try value(n, deferred.value, names_path, failure), .protocol = n.converters(id).input orelse return n.unsupportedValue(id, unconvertible) }, .source = .value, .required = null, .prefetch = false } },
                .native_slice_view, .nominal_borrow, .nominal_owned, .native_receiver, .lazy_rest => return n.unsupportedValue(id, unconvertible),
            },
        };
        const codec: ir.CppInput = .{
            .value_type = value_type,
            .failure = failure,
            .encoder = try CodecModule.InputEncode.value(n, id, operation, failure),
            .rooted = mod_cpp_facts.get(n, id).roots_input,
            .call_receiver = facts.contains_call_receiver_conversion,
            .holds_byte_lease = facts.effective_buffer_mode_mask & 2 != 0,
            .collection_storage = mod_cpp_facts.get(n, id).collection_storage,
            .operation = operation,
        };
        return n.addCpp(id, "inputs", codec);
    }

    pub fn aggregate(n: *Normalizer, id: ir.InboundArgumentPlanId) PlanError!ir.CppInputAggregateId {
        if (n.cpp_input_state.aggregates.get(id)) |planned| return n.replay(planned);
        const result = buildAggregate(n, id);
        try n.cpp_input_state.aggregates.putNoClobber(n.arena, id, try n.record(result));
        return result;
    }

    /// The converter's `encodeResult` is exposed after planning, for the
    /// converters that JavaScript-sourced results need.
    fn buildAggregate(n: *Normalizer, id: ir.InboundArgumentPlanId) PlanError!ir.CppInputAggregateId {
        const position = n.get(id).*;
        const input = n.input_plans.items[position.input.index];
        const value_type = mod_cpp_facts.Types.input(n, id).value orelse return n.unsupportedValue(id, "this value has no C++ JavaScript input converter");
        const operation: @FieldType(ir.CppInputAggregate, "operation") = switch (position.representation) {
            .dictionary => |fields| .{ .dictionary = try CodecModule.Dictionary.build(n, id, fields) },
            .union_type => |members| union_input: {
                const children = try n.arena.alloc(ir.CppInputUnionMember, members.len);
                for (members, children, 1..) |member, *child, tag| child.* = .{
                    .name = member.name,
                    .value = try value(n, member.value, true, .false_value),
                    .tag = @intCast(tag),
                };
                break :union_input .{ .union_type = try CodecModule.Union.build(n, id, children) };
            },
            .sequence => |child| .{ .sequence = try CodecModule.Sequence.build(n, id, try value(n, child, true, .false_value)) },
            .record => |entry_id| record: {
                const entry = n.get(entry_id).representation.record_entry;
                const key_input = try value(n, entry.key, true, .false_value);
                if (n.get(key_input).operation != .string) return n.unsupportedValue(entry.key, "record keys must convert from strings");
                break :record .{ .record = .{
                    .key = key_input,
                    .value = try value(n, entry.value, true, .false_value),
                    .object = if (input.profile == .webidl) .nullable else .required,
                    .object_error = errors.standard(input.profile, .type, " must be an object", "object"),
                    .key_conversion = n.projection(n.get(entry.key).type).string.?.kind,
                } };
            },
            .converted, .optional, .record_entry, .rest, .leaf => return n.unsupportedValue(id, "this value has no C++ aggregate input"),
        };
        const facts = mod_plans.inputFacts(n, position.input);
        const result = try n.addCpp(id, "input_aggregates", .{
            .wire = position.wire,
            .value_type = value_type,
            .failure = .false_value,
            .encoder = try CodecModule.InputEncode.aggregate(n, id, operation),
            .result_encoder = null,
            .receiver = facts.contains_receiver_conversion,
            .holds_byte_lease = facts.effective_buffer_mode_mask & 2 != 0,
            .operation = operation,
        });
        try n.cpp_input_declarations.append(n.arena, result);
        return result;
    }

    pub fn lazy(n: *Normalizer, id: ir.InboundArgumentPlanId, names_path: bool, failure: ir.CppInputFailure) PlanError!ir.CppLazyInput {
        return n.get(try value(n, id, names_path, failure)).operation.lazy.conversion;
    }

    pub fn preparation(n: *Normalizer, id: ir.CppInputId) Error!ir.CppInputPreparation {
        const input = n.get(id);
        return .{ .failure = input.failure, .operation = switch (input.operation) {
            .buffer => .{ .buffer = try CodecModule.Buffer.preparation(n, id.position, n.projection(n.get(id.position).type).buffer.?) },
            .aggregate => |aggregate_id| switch (n.get(aggregate_id).operation) {
                .union_type => .object_or_string,
                .dictionary, .sequence, .record => unreachable,
            },
            .void, .discarded, .scalar, .converted, .optional, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .lazy => unreachable,
        } };
    }

    pub fn string(n: *Normalizer, id: anytype, failure: ir.CppInputFailure) PlanError!ir.CppStringInput {
        const position = n.get(id);
        const input = n.input_plans.items[position.input.index];
        const projection = n.projection(position.type).string orelse return n.unsupportedValue(id, "this value has no C++ string conversion");
        return .{
            .thread_safe = projection.thread_safe,
            .nullish_failure = projection.nullish_failure,
            .strict_failure = projection.strict_failure,
            .empty_rejection = projection.empty_rejection,
            .input = switch (projection.coercion_input) {
                .any => .any,
                .object_only => .{ .object = if (projection.input_failure) |type_failure| .{ .custom = type_failure } else errors.standard(input.profile, .type, " must be an object", "object") },
                .string_or_boxed => .{ .string_or_boxed = if (projection.input_failure) |type_failure| .{ .custom = type_failure } else if (projection.type_error_format == .property_typeof) .node_string_property_type else errors.standard(input.profile, .type, " must be a string", "string") },
            },
            .conversion = .{
                .context = input.conversion_context,
                .failure = failure,
                .type = try n.cppType(.{ .builtin = if (input.conversion_context == .none) switch (projection.kind) {
                    .dom_string => .webidl_dom_string,
                    .usv_string => .webidl_usv_string,
                    .byte_string => .webidl_byte_string,
                } else switch (projection.kind) {
                    .dom_string => .strict_dom_string,
                    .usv_string => .strict_usv_string,
                    .byte_string => .strict_byte_string,
                } }),
            },
        };
    }
};

pub const InputEncode = struct {
    fn append(n: *Normalizer, position: ir.InboundArgumentPlanId, failure: ir.CppInputFailure, operation: @FieldType(ir.CppInputEncode, "operation")) Error!ir.CppInputEncodeId {
        return n.addCpp(position, "input_encoders", .{ .failure = failure, .operation = operation });
    }

    fn nativeEncoder(n: *Normalizer, id: ir.InboundArgumentPlanId, failure: ir.CppInputFailure) PlanError!ir.CppNativeEncodeId(.inbound_argument) {
        return CodecModule.Native.encoder(n, id, try CodecModule.Failures.input(n, failure));
    }

    pub fn value(n: *Normalizer, id: ir.InboundArgumentPlanId, operation: @FieldType(ir.CppInput, "operation"), failure: ir.CppInputFailure) PlanError!ir.CppInputEncodeId {
        return append(n, id, failure, switch (operation) {
            .void => .void,
            .discarded, .scalar, .enumeration, .string, .node_path, .external_ref, .lazy => .{ .native = try nativeEncoder(n, id, failure) },
            .converted => .{ .native = try nativeEncoder(n, n.get(id).representation.converted.value, failure) },
            .optional => |optional| .{ .optional = n.get(optional.value).encoder },
            .buffer => |buffer| switch (buffer) {
                .copy => .{ .native = try nativeEncoder(n, id, failure) },
                .lease => .byte_lease,
            },
            .value => |kind| .{ .value = kind },
            .branded_value => .{ .value = .branded },
            .callback => .callback,
            .class_ref => .class_ref,
            .aggregate => .helper,
        });
    }

    pub fn aggregate(n: *Normalizer, id: ir.InboundArgumentPlanId, operation: @FieldType(ir.CppInputAggregate, "operation")) PlanError!ir.CppInputEncodeId {
        return append(n, id, .false_value, switch (operation) {
            .dictionary => |dictionary| dictionary_encoder: {
                const fields = n.get(id).representation.dictionary;
                const result = try n.arena.alloc(@typeInfo(@FieldType(@FieldType(ir.CppInputEncode, "operation"), "dictionary")).pointer.child, dictionary.fields.len);
                for (dictionary.fields, fields, result) |field, position, *output| output.* = switch (field) {
                    .source => |name| .{ .name = name, .operation = .source },
                    .value => |field_id| encoded_field: {
                        const value_field = n.get(field_id);
                        break :encoded_field .{ .name = value_field.name, .operation = .{ .value = .{ .encoder = n.get(value_field.input).encoder, .optional = position.optional } } };
                    },
                };
                break :dictionary_encoder .{ .dictionary = result };
            },
            .union_type => |union_input| union_encoder: {
                const members = union_input.members;
                const result = try n.arena.alloc(@typeInfo(@FieldType(@FieldType(ir.CppInputEncode, "operation"), "union_type")).pointer.child, members.len);
                for (members, result) |member, *output| output.* = .{ .name = member.name, .encoder = n.get(member.value).encoder, .tag = member.tag };
                break :union_encoder .{ .union_type = result };
            },
            .sequence => |sequence| .{ .collection = .{
                .wire = n.get(sequence.value.position).wire,
                .element = try element(n, sequence.value),
            } },
            .record => |record| record_encoder: {
                const entry = n.get(id).representation.record;
                break :record_encoder .{ .collection = .{
                    .wire = n.get(entry).wire,
                    .element = if (n.get(record.value).collection_storage) .{ .record = try append(n, entry, .false_value, .{ .entry = .{
                        .key = try nativeEncoder(n, record.key.position, .false_value),
                        .value = n.get(record.value).encoder,
                    } }) } else .{ .native = try nativeEncoder(n, entry, .false_value) },
                } };
            },
        });
    }

    fn element(n: *Normalizer, id: ir.CppInputId) PlanError!@FieldType(@FieldType(@FieldType(ir.CppInputEncode, "operation"), "collection"), "element") {
        const input = n.get(id);
        return if (input.collection_storage)
            .{ .sequence = input.encoder }
        else
            .{ .native = try nativeEncoder(n, id.position, input.failure) };
    }

    pub fn rest(n: *Normalizer, position: ir.RestPosition(.inbound_argument)) PlanError!ir.CppInputEncodeId {
        return append(n, position.plan(), .empty, switch (position) {
            .values, .lazy => .rest,
            .count => |id| .{ .native = try nativeEncoder(n, id, .empty) },
            .typed => |id| return n.get(try CodecModule.Input.value(n, id, true, .false_value)).encoder,
        });
    }
};

pub const InputErrors = struct {
    const Kind = enum { type, instance, invalid_value, range, invalid_this };

    pub fn standard(profile: ir.Profile, kind: Kind, suffix: []const u8, requirement: []const u8) ir.CppValueInputError {
        return conversion(profile, kind, .{ .suffix = suffix }, requirement, null);
    }

    pub fn conversion(profile: ir.Profile, kind: Kind, message: ir.CppInputErrorMessage, requirement: []const u8, source_suffix: ?[]const u8) ir.CppValueInputError {
        return switch (kind) {
            .invalid_this => .{ .invalid_this = requirement },
            .invalid_value => if (profile == .node) .{ .node_value = .{ .source_suffix = source_suffix } } else .{ .javascript = .{ .kind = .type, .message = message } },
            .type, .instance, .range => if (profile == .node) .{ .node_expected = .{
                .kind = if (kind == .type) .type else if (kind == .instance) .instance else .range,
                .requirement = requirement,
                .source_suffix = source_suffix,
            } } else .{ .javascript = .{ .kind = if (kind == .range) .range else .type, .message = message } },
        };
    }

    pub fn branded(n: *Normalizer, id: anytype) Error!ir.CppBrandedInput {
        const position = n.get(id);
        const value = n.irType(position.type).data.branded_value;
        const options = n.rawType(position.type).branded_value.options;
        const profile = n.input_plans.items[position.input.index].profile;
        return .{
            .brand = value.brand.cpp_match,
            .failure = failure: {
                if (options.no_match_error) |custom| break :failure .{ .custom = custom };
                if (profile == .node) if (options.node_expected_types) |types| {
                    const prefix = try std.mem.join(n.arena, ", ", types[0 .. types.len - 1]);
                    break :failure .{ .node_expected = .{
                        .kind = .multiple_types,
                        .requirement = try n.print("{s}{s}{s}", .{ prefix, if (types.len == 2) " or " else ", or ", types[types.len - 1] }),
                    } };
                };
                break :failure conversion(profile, switch (options.error_kind) {
                    .type => .type,
                    .instance => .instance,
                    .invalid_value => .invalid_value,
                    .invalid_this => .invalid_this,
                }, if (@TypeOf(id).role == .outbound_result)
                    .{ .literal = try n.print("Typed callback result must be {s}", .{options.expectation orelse try n.print("a {s}", .{value.brand.brand_name})}) }
                else
                    .{ .suffix = try n.print(" must be {s}", .{options.expectation orelse try n.print("a {s}", .{value.brand.brand_name})}) }, options.node_requirement orelse value.brand.brand_name, null);
            },
        };
    }

    pub fn callback(n: *const Normalizer, id: anytype) ir.CppCallbackInput {
        const position = n.get(id);
        const options = n.rawType(position.type).callback.options;
        return .{
            .captures_context = options.retains_async_context,
            .failure = if (options.no_match_error) |failure| .{ .custom = failure } else conversion(
                n.input_plans.items[position.input.index].profile,
                .type,
                if (@TypeOf(id).role == .outbound_result) .{ .literal = "Typed callback result must be callable" } else .{ .suffix = " must be callable" },
                "function",
                null,
            ),
        };
    }

    pub fn classReference(n: *Normalizer, id: ir.InboundArgumentPlanId) Error!ir.CppValueInputError {
        const position = n.get(id);
        const reference = n.irType(position.type).data.class_ref;
        const options = n.rawType(position.type).class_ref.options;
        if (options.no_match_error) |failure| return .{ .custom = failure };
        if (options.node_expected_instances) |expected| return .{ .node_expected = .{ .kind = .instance, .requirement = expected } };
        const class_name = n.get(reference.class).class_name;
        return conversion(n.input_plans.items[position.input.index].profile, .instance, .{ .literal = try n.print("Expected a {s} instance", .{class_name}) }, class_name, null);
    }
};

pub fn release(n: *const Normalizer, id: anytype) ir.CppRelease {
    const facts = mod_cpp_facts.get(n, id);
    return .{
        .owned_handles = facts.contains_owned_handle,
        .pending = facts.pending_release,
        .pending_leaf = mod_cpp_facts.pendingRelease(n, id),
    };
}

pub const Scalar = struct {
    const Argument = ir.CppTemplateArgument;

    pub fn build(n: *normalize.Normalizer, id: anytype, failure_return: ir.CppInputFailure) PlanError!ir.CppScalarConversion {
        const position = n.get(id).*;
        const input = &n.input_plans.items[position.input.index];
        const conversion = n.input_conversions.items[position.input.index];
        const builder: Builder = .{ .n = n, .input = input, .conversion = conversion, .wire = position.wire, .kind = n.projection(position.type).scalar_kind.? };
        const unsupported = "this numeric conversion has no C++ implementation";
        const operation: @FieldType(ir.CppScalarConversion, "operation") = switch (input.codec) {
            .boolean => (try builder.boolean()) orelse return n.unsupportedValue(id, unsupported),
            .integer => switch (conversion.integer_conversion) {
                .node_receiver_byte_length => |receiver| .{ .receiver_byte_length = receiver },
                .clamp => |range| .{ .clamp = .{ .idl = (try builder.integer()) orelse return n.unsupportedValue(id, unsupported), .wire = position.wire, .range = mod_cpp_facts.integerRange(builder.kind, range) } },
                .normal, .modulo, .coerce, .coerce_saturate, .truncate_saturate, .truncate_clamp, .coerce_truncate_or_default, .saturate_validate, .bounded_integer, .enforce_range, .node_validate, .node_validate_with, .node_coerce, .node_validate_prose, .node_truncate, .matching, .webidl, .to_length => .{ .idl = (try builder.integer()) orelse return n.unsupportedValue(id, unsupported) },
            },
            .number => .{ .idl = try builder.number() },
            .none, .discarded, .js_value, .branded_value, .lazy, .converted, .string, .utf8_string, .node_path, .buffer, .native_slice, .callback, .optional, .enumeration, .dictionary, .union_type, .sequence, .record, .nominal_handle, .class_ref, .external_ref, .native_instance => return n.unsupportedValue(id, "this value is not numeric"),
        };
        return .{ .context = input.conversion_context, .failure = failure_return, .operation = operation };
    }

    const Builder = struct {
        n: *normalize.Normalizer,
        input: *const mod_plans.InputPlan,
        conversion: schema.ValueConversionOptions,
        wire: ir.WireTypeId,
        kind: ir.ScalarKind,

        fn builtin(b: Builder, name: ir.CppBuiltin) Error!ir.CppTypeId {
            return b.n.cppType(.{ .builtin = name });
        }

        fn template(b: Builder, name: ir.CppTemplate, arguments: []const Argument) Error!ir.CppTypeId {
            return b.n.cppType(.{ .template = .{ .name = name, .arguments = try b.n.arena.dupe(Argument, arguments) } });
        }

        fn failure(b: Builder, value: ir.ConversionFailure) Error!Argument {
            return .{ .type = try b.n.cppType(.{ .conversion_failure = value }) };
        }

        fn literal(b: Builder, value: i128) Argument {
            return .{ .integer = mod_cpp_facts.integerLiteral(b.kind, value).? };
        }

        fn ranged(b: Builder, name: ir.CppTemplate, range: ir.IntegerRange, suffix: []const Argument) Error!ir.CppTypeId {
            var arguments: std.ArrayList(Argument) = .empty;
            try arguments.appendSlice(b.n.arena, &.{ .{ .wire = b.wire }, b.literal(range.min), b.literal(range.max) });
            try arguments.appendSlice(b.n.arena, suffix);
            return b.n.cppType(.{ .template = .{ .name = name, .arguments = arguments.items } });
        }

        fn boolean(b: Builder) Error!?@FieldType(ir.CppScalarConversion, "operation") {
            const conversion = b.conversion.boolean_conversion;
            if (b.input.conversion_context != .none) return .{ .idl = switch (conversion) {
                .strict => |validation| try b.template(.strict_boolean, &.{try b.failure(validation)}),
                .node_property_typeof => |name| try b.template(.node_property_boolean, &.{.{ .string = name }}),
                .normal, .truthy, .strict_true, .not_strict_false => try b.builtin(.strict_boolean),
            } };
            return .{ .boolean = switch (conversion) {
                .normal => .webidl,
                .truthy => .truthy,
                .strict_true => .strict_true,
                .not_strict_false => .not_strict_false,
                .strict, .node_property_typeof => return null,
            } };
        }

        fn webInteger(b: Builder) Error!?ir.CppTypeId {
            return try b.builtin(switch (b.kind) {
                .i8 => .webidl_i8,
                .u8 => .webidl_u8,
                .i16 => .webidl_i16,
                .u16 => .webidl_u16,
                .i32 => .webidl_i32,
                .u32 => .webidl_u32,
                .i64 => .webidl_i64,
                .u64, .usize => .webidl_u64,
                .boolean, .discarded, .f64 => return null,
            });
        }

        fn integer(b: Builder) Error!?ir.CppTypeId {
            const representation = b.n.projection(b.input.type).integer_representation.?;
            const conversion = b.conversion.integer_conversion;
            const contextual = b.input.conversion_context != .none;
            if (representation != .number) switch (conversion) {
                .normal, .modulo, .coerce_truncate_or_default, .node_validate, .node_validate_prose, .node_coerce => {},
                .coerce, .coerce_saturate, .truncate_saturate, .truncate_clamp, .saturate_validate, .bounded_integer, .enforce_range, .clamp, .node_validate_with, .node_truncate, .node_receiver_byte_length, .matching, .webidl, .to_length => return null,
            };
            const wire: Argument = .{ .wire = b.wire };
            return switch (conversion) {
                .normal => switch (representation) {
                    .number => if (contextual) try b.template(.number_integer, &.{wire}) else try b.webInteger(),
                    .number_or_bigint => try b.template(.strict_integer, &.{wire}),
                    .bigint => try b.template(.bigint_integer, &.{wire}),
                },
                .modulo => try b.template(.modulo_integer, &.{ wire, .{ .boolean = representation != .bigint }, .{ .boolean = representation != .number } }),
                .node_coerce => |validation| try b.ranged(.number_integer_range, validation.range, &.{ .{ .boolean = false }, .{ .boolean = true }, .{ .boolean = validation.range_error == .bound }, .{ .boolean = representation == .number_or_bigint } }),
                .coerce_truncate_or_default => |normalization| try b.ranged(.coerced_integer_default, normalization.range, &.{ b.literal(normalization.fallback), .{ .boolean = representation == .number_or_bigint } }),
                .node_validate, .node_validate_prose => |range| try b.ranged(switch (representation) {
                    .number => .number_integer_range,
                    .number_or_bigint => .number_or_bigint_range,
                    .bigint => .bigint_range,
                }, range, &.{}),
                .coerce => try b.template(.loose_integer, &.{wire}),
                .coerce_saturate => try b.template(.coerced_saturated_integer, &.{wire}),
                .truncate_saturate => try b.template(.saturated_integer, &.{ wire, .{ .boolean = !contextual } }),
                .truncate_clamp => |normalization| try b.ranged(.truncated_integer_clamp, normalization.range, &.{ b.literal(normalization.nan), .{ .boolean = normalization.coerce } }),
                .saturate_validate => |validation| try b.ranged(.saturated_integer_range, validation.range, &.{
                    .{ .boolean = validation.coerce },
                    .{ .boolean = validation.failure != null },
                    .{ .error_code = if (validation.failure) |failure_| failure_.code else "ERR_OUT_OF_RANGE" },
                    .{ .string = if (validation.failure) |failure_| failure_.argument_suffix else "" },
                }),
                .bounded_integer => |validation| try b.ranged(.bounded_integer, validation.range, &.{
                    .{ .boolean = validation.below == .saturate },
                    .{ .boolean = validation.above == .saturate },
                    .{ .boolean = validation.allow_infinity },
                    try b.failure(validation.invalid),
                    try b.failure(validation.out_of_range),
                }),
                .webidl => try b.webInteger(),
                .to_length => try b.builtin(.to_length),
                .enforce_range => |range| try b.ranged(if (contextual) .number_integer_range else .integer_enforce_range, range, &.{}),
                .clamp => try b.template(.webidl_clamp, &.{.{ .type = (try b.webInteger()) orelse return null }}),
                .node_validate_with => |validation| try b.ranged(.node_integer_diagnostic, validation.range, &.{ .{ .integer_rejection = validation.rejection }, .{ .boolean = validation.fractional == .truncate } }),
                .node_truncate => |validation| try b.ranged(.number_integer_range, validation.range, &.{.{ .boolean = true }}),
                .matching => |range| try b.ranged(.matching_integer, range, &.{}),
                .node_receiver_byte_length => null,
            };
        }

        fn number(b: Builder) Error!ir.CppTypeId {
            return switch (b.conversion.number_conversion) {
                .normal => b.builtin(if (b.input.conversion_context == .none) .unrestricted_double else .strict_double),
                .coerce => b.builtin(.unrestricted_double),
                .coerce_clamp => |range| b.template(.clamped_number, &.{ .{ .double_bits = range.min }, .{ .double_bits = range.max } }),
                .enforce_range => |validation| b.template(.number_enforce_range, &.{ .{ .double_bits = validation.range.min }, .{ .double_bits = validation.range.max }, .{ .boolean = b.input.conversion_context == .none }, .{ .boolean = validation.error_class == .type_error }, .{ .string = validation.error_message } }),
                .coerce_truncate_or_default, .coerce_truncate_clamp => |normalization| b.template(if (b.conversion.number_conversion == .coerce_truncate_or_default) .normalized_integer else .truncated_clamped_number, &.{ .{ .double_bits = normalization.range.min }, .{ .double_bits = normalization.range.max }, .{ .double_bits = normalization.fallback } }),
                .coerce_wrap_clamp => |normalization| b.template(.wrapped_clamped_number, &.{ .{ .integer = .{ .signed = normalization.bits } }, .{ .double_bits = normalization.range.min }, .{ .double_bits = normalization.range.max } }),
                .integer_or_infinity => b.builtin(.integer_or_infinity),
                .node_validate => |validation| b.template(.number_range, &.{ .{ .boolean = validation.min != null }, .{ .double_bits = validation.min orelse 0 }, .{ .boolean = validation.max != null }, .{ .double_bits = validation.max orelse 0 }, .{ .number_range_error = validation.error_kind } }),
            };
        }
    };
};

pub const Enumeration = struct {
    const errors = CodecModule.InputErrors;

    pub fn nativeTags(n: *Normalizer, id: ir.TypeId) Error![]const u16 {
        const values = n.get(n.irType(id).data.enumeration).enumeration_values;
        const tags = try n.arena.alloc(u16, values.len);
        for (values, tags) |value, *tag| tag.* = value.native_value;
        return tags;
    }

    pub fn build(n: *Normalizer, id: ir.InboundArgumentPlanId, value_type: ir.CppTypeId, failure_return: ir.CppInputFailure) Error!ir.CppEnumerationInput {
        const position = n.get(id);
        const input = n.input_plans.items[position.input.index];
        const enumeration = n.get(n.irType(position.type).data.enumeration).*;
        const raw = n.rawType(position.type).enumeration;
        const options = raw.options;
        const values = try n.arena.alloc(@typeInfo(@FieldType(ir.CppEnumerationInput, "values")).pointer.child, enumeration.enumeration_values.len);
        for (enumeration.enumeration_values, raw.values, values) |value, declared, *output| output.* = .{ .tag = value.native_value, .text = value.js_value, .aliases = declared.options.aliases };
        return .{
            .type = value_type,
            .failure = failure_return,
            .values = values,
            .ascii_case_insensitive = options.ascii_case_insensitive,
            .numbers = if (options.accept_native_numbers) unmatched(enumeration, options, input.profile, false) else null,
            .unmatched = unmatched(enumeration, options, input.profile, true),
            .string = try stringConversion(n, options, input, failure_return),
        };
    }

    fn stringConversion(n: *Normalizer, options: schema.EnumerationOptions, input: mod_plans.InputPlan, failure: ir.CppInputFailure) Error!@FieldType(ir.CppEnumerationInput, "string") {
        if (options.coerce) return .coerced;
        if (options.strict_errors) |strict| return .{ .reject_non_string = .{ .value = .{ .error_value = .{ .custom = strict.invalid_type } } } };
        if (input.profile == .node) if (options.node_invalid_value) |invalid| switch (invalid) {
            .invalid_argument_value => |details| {
                if (details.coerce) return .coerced;
                return .{ .reject_non_string = nonStringFailure(invalid, details.non_string_expected_type, details.non_string_name) };
            },
            .invalid_property_value => |details| return .{ .reject_non_string = nonStringFailure(invalid, details.non_string_expected_type, details.non_string_name) },
            .coerced_error => return .coerced,
        };
        return .{ .idl = .{
            .type = try n.cppType(.{ .builtin = if (input.profile == .webidl) .webidl_dom_string else .strict_dom_string }),
            .context = if (input.profile == .webidl) .none else input.conversion_context,
            .failure = failure,
        } };
    }

    fn nonStringFailure(invalid: ir.NodeInvalidEnumerationValue, expected: ?[]const u8, name: ?[]const u8) ir.CppEnumerationFailure {
        return if (expected) |requirement|
            .{ .value = .{ .name = name, .error_value = .{ .node_expected = .{ .kind = .type, .requirement = requirement } } } }
        else
            nodeFailure(invalid, false);
    }

    fn unmatched(enumeration: ir.EnumerationType, options: schema.EnumerationOptions, profile: ir.Profile, string_input: bool) ir.CppEnumerationUnmatched {
        if (options.unrecognized_value) |name| for (enumeration.enumeration_values) |value| {
            if (std.mem.eql(u8, name, value.value_name)) return .{ .value = value.native_value };
        };
        if (options.invalid_value_failure) |failure| return .{ .failure = .{ .value = .{ .error_value = .{ .custom = failure } } } };
        if (options.strict_errors) |strict| {
            if (string_input) if (strict.invalid_string_prefix) |prefix| return .{ .failure = .{ .prefix = prefix } };
            return .{ .failure = .{ .value = .{ .error_value = .{ .custom = strict.invalid_value } } } };
        }
        if (options.node_invalid_value) |failure| return .{ .failure = nodeFailure(failure, string_input) };
        return .{ .failure = .{ .value = .{
            .error_value = errors.standard(profile, switch (options.invalid_value_error) {
                .type => .type,
                .range => .range,
            }, " has an invalid enumeration value", "one of the declared enumeration values"),
        } } };
    }

    fn nodeFailure(failure: ir.NodeInvalidEnumerationValue, string_input: bool) ir.CppEnumerationFailure {
        return switch (failure) {
            .invalid_argument_value => |details| .{ .value = .{ .name = details.name, .error_value = .{ .node_value = .{ .reason = details.reason } } } },
            .invalid_property_value => |details| .{ .value = .{ .name = details.name, .error_value = .{ .node_property_value = details.expected } } },
            .coerced_error => |details| .{ .node_coerced = .{
                .code = details.code,
                .prefix = details.message_prefix,
                .suffix = details.message_suffix,
                .non_string_error = if (details.non_string_expected_type) |expected| .{ .node_expected = .{ .kind = .type, .requirement = expected } } else null,
                .text = if (string_input) .converted else .input,
            } },
        };
    }
};

pub const Buffer = struct {
    const errors = CodecModule.InputErrors;
    const BufferProjection = mod_types.BufferProjection;

    pub fn input(n: *Normalizer, id: ir.InboundArgumentPlanId, projection: BufferProjection, names_path: bool, failure: ir.CppInputFailure) Error!ir.CppBufferInput {
        const profile = n.input_plans.items[n.get(id).input.index].profile;
        const source = check(profile, projection, n.rawType(n.get(id).type).buffer.options, projection.allow_detached, if (names_path)
            .{ .suffix = try n.print(" must be an attached {s}", .{description(projection.source)}) }
        else
            .{ .literal = try n.print("Expected an attached {s}", .{description(projection.source)}) });
        return switch (projection.effective_mode) {
            .copy => .{ .copy = .{ .check = source, .failure = failure } },
            .lease => .{ .lease = .{
                .check = source,
                .failure = failure,
                .writable = projection.isWritable(),
                .allow_copy = projection.copy_fallback == .allow,
                .require_source_attachment = projection.source_attachment == .required,
                .copy_transfers = projection.transfer_policy == .copy,
                .snapshot_resizable = projection.snapshot_resizable_on_retention,
                .copy_required = errors.conversion(profile, .type, .{ .literal = "Buffer cannot be used without copying its bytes" }, "a buffer that can be leased without copying", null),
                .attachment_unavailable = errors.standard(profile, .type, " cannot preserve source attachment", "a buffer whose source can remain attached"),
            } },
        };
    }

    pub fn preparation(n: *Normalizer, id: ir.InboundArgumentPlanId, projection: BufferProjection) Error!ir.CppBufferCheck {
        return check(n.input_plans.items[n.get(id).input.index].profile, projection, n.rawType(n.get(id).type).buffer.options, true, .{ .literal = try n.print("Expected an attached {s}", .{description(projection.source)}) });
    }

    pub fn result(n: *Normalizer, id: ir.OutboundResultPlanId, projection: BufferProjection) Error!ir.CppBufferCheck {
        return check(n.input_plans.items[n.get(id).input.index].profile, projection, n.rawType(n.get(id).type).buffer.options, projection.allow_detached, .{ .literal = try n.print("Typed callback result must be an attached {s}", .{description(projection.source)}) });
    }

    fn check(profile: ir.Profile, projection: BufferProjection, options: ir.BufferOptions, allow_detached: bool, message: ir.CppInputErrorMessage) ir.CppBufferCheck {
        return .{
            .source = projection.source,
            .allow_detached = allow_detached,
            .allow_shared = projection.allow_shared,
            .detached_failure = options.detached_failure,
            .invalid = if (options.type_failure) |failure| .{ .custom = failure } else if (options.type_error_format == .node_type)
                errors.conversion(.node, .type, message, nodeRequirement(projection), null)
            else if (profile == .webidl and projection.requiresIntegerTypedArray())
                .webidl_integer_array
            else
                errors.conversion(profile, .instance, message, nodeRequirement(projection), null),
        };
    }

    fn description(source: ir.BufferSource) []const u8 {
        return switch (source) {
            .uint8_array => "Uint8Array",
            .uint32_array => "Uint32Array",
            .array_buffer_or_view => "ArrayBuffer or ArrayBufferView",
            .view, .integer_typed_array => "ArrayBufferView",
        };
    }

    fn nodeRequirement(projection: BufferProjection) []const u8 {
        return switch (projection.source) {
            .uint8_array => "Uint8Array",
            .uint32_array => "Uint32Array",
            .array_buffer_or_view => if (projection.isWritable()) "ArrayBuffer or ArrayBufferView" else "ArrayBuffer, Buffer, TypedArray, or DataView",
            .view, .integer_typed_array => "Buffer, TypedArray, or DataView",
        };
    }
};

pub const Dictionary = struct {
    const inputs = CodecModule.Input;
    const plans = mod_plans;
    const errors = CodecModule.InputErrors;
    const Step = @typeInfo(@FieldType(ir.CppDictionaryInput, "steps")).pointer.child;

    pub fn build(n: *Normalizer, id: ir.InboundArgumentPlanId, fields: []const ir.PositionField(.inbound_argument)) PlanError!ir.CppDictionaryInput {
        const position = n.get(id).*;
        const input = n.input_plans.items[position.input.index];
        const raw = n.rawType(position.type).dictionary;

        const values = try n.arena.alloc(ir.CppInputField, fields.len);
        for (fields, values, 0..) |field, *output, index| {
            const semantic = plans.dictionaryField(n, position.input, index);
            if (field.dictionary_source) {
                if (n.input_plans.items[semantic.value.index].codec == .branded_value and input.profile == .webidl)
                    return n.unsupported("an object-typed dictionary source requires a non-nullable dictionary conversion", .{});
                output.* = .{ .source = field.name };
                continue;
            }
            if (semantic.presence == .required_convert_undefined and semantic.missing != .undefined)
                return n.unsupported("required dictionary fields that convert undefined must read a missing property as undefined: {s}", .{semantic.declaration.field_name});
            const field_presence = mod_types.dictionaryFieldPresence(semantic.options);
            const value: ir.CppDictionaryValue = .{
                .name = field.name,
                .input = try inputs.value(n, field.value, true, .false_value),
                .path = if (semantic.options.diagnostic_name) |path| .{ .absolute = path } else .{ .suffix = try n.print(".{s}", .{semantic.js_name}) },
                .missing = semantic.missing,
                .presence = switch (field_presence) {
                    .required_reject => .{ .required_reject = required(n, semantic) },
                    .required_convert_undefined => .required_convert_undefined,
                    .default_value => .{ .default_value = try CodecModule.Defaults.lower(n, field.value, semantic.options.default_value.?) },
                    .optional => .optional,
                },
                .tracks_lease_presence = field_presence == .optional and mod_plans.inputFacts(n, n.get(field.value).input).effective_buffer_mode_mask & 2 != 0,
                .incompatible = if (semantic.options.node_incompatible_with) |name| incompatible: {
                    for (fields[0..index], values[0..index], 0..) |previous, previous_value, previous_index| {
                        if (!std.mem.eql(u8, previous.name, name)) continue;
                        break :incompatible .{
                            .other = switch (previous_value) {
                                .value => |previous_id| previous_id,
                                .source => unreachable,
                            },
                            .primary = (plans.dictionaryField(n, position.input, previous_index)).js_name,
                            .current = semantic.js_name,
                        };
                    }
                    unreachable;
                } else null,
                .unsupported = semantic.options.node_unsupported,
            };
            const field_id: ir.CppDictionaryValueId = .of(n.cpp_dictionary_values.items.len);
            try n.cpp_dictionary_values.append(n.arena, value);
            output.* = .{ .value = field_id };
        }
        var steps: std.ArrayList(Step) = .empty;
        if (raw.options.field_reads == .before_conversion) {
            for (values, 0..) |field, index| switch (field) {
                .source => {},
                .value => |field_id| try steps.append(n.arena, .{ .read = .{ .field = field_id, .reader = read(plans.dictionaryField(n, position.input, index), raw.options.property_lookup) } }),
            };
        }
        for (try fieldSteps(n, raw.fields, raw.options.finish_fields)) |step| switch (values[step.index]) {
            .source => |name| try steps.append(n.arena, .{ .source = name }),
            .value => |field_id| {
                const field = n.get(field_id).*;
                const semantic = plans.dictionaryField(n, position.input, step.index);
                if (step.kind == .validate) {
                    try steps.append(n.arena, .{ .validate_string = .{
                        .field = field_id,
                        .error_value = errors.standard(n.input_plans.items[semantic.value.index].profile, .type, " must be a string", "string"),
                    } });
                    continue;
                }
                switch (n.get(field.input).operation) {
                    .lazy => |lazy| {
                        try steps.append(n.arena, .{ .lazy = .{ .field = field_id, .input = .{
                            .conversion = lazy.conversion,
                            .source = if (semantic.options.source_field) |name| .{ .projected = name } else .{ .property = read(semantic, raw.options.property_lookup) },
                            .required = switch (field.presence) {
                                .required_reject => |check| check,
                                .required_convert_undefined, .default_value, .optional => null,
                            },
                            .prefetch = semantic.options.lazy_property_read == .eager,
                        } } });
                        continue;
                    },
                    .void, .discarded, .scalar, .converted, .optional, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .buffer, .aggregate => {},
                }
                try steps.append(n.arena, .{ .value = .{
                    .field = field_id,
                    .read = if (raw.options.field_reads == .interleaved and step.kind != .finish) read(semantic, raw.options.property_lookup) else null,
                    .retain = step.kind == .prepare,
                    .operation = switch (step.kind) {
                        .convert, .finish => .{ .convert = .{ .input = field.input, .optional = field.presence == .optional } },
                        .prepare => .{ .prepare = try inputs.preparation(n, field.input) },
                        .validate => unreachable,
                    },
                } });
            },
        };
        return .{
            .path = input.path_override,
            .object = switch (raw.options.object_profile orelse input.profile) {
                .webidl => .webidl_nullable,
                .exact => .exact_object,
                .node => .{ .node_object = .{ .reject_array = !raw.options.node_allow_array, .reject_callable = !raw.options.node_allow_callable } },
            },
            .object_error = if (raw.options.object_error) |failure| .{ .custom = failure } else errors.standard(
                raw.options.object_error_profile orelse raw.options.object_profile orelse input.profile,
                switch (raw.options.object_error_kind) {
                    .type => .type,
                    .invalid_value => .invalid_value,
                },
                " must be an object",
                "object",
            ),
            .snapshot = raw.options.input_snapshot == .own_enumerable,
            .fields = values,
            .steps = steps.items,
        };
    }

    fn required(n: *const Normalizer, field: plans.DictionaryField) ir.CppRequiredInput {
        return .{
            .missing = field.missing,
            .failure = .false_value,
            .error_value = switch (field.options.missing_required) {
                .failure => |failure| .{ .custom = failure },
                .reject, .convert_undefined => errors.standard(n.input_plans.items[field.value.index].profile, .type, " is required", switch (field.missing) {
                    .absent => "a present property",
                    .undefined => "a value other than undefined",
                    .undefined_or_null => "a value other than undefined or null",
                }),
            },
        };
    }

    fn read(field: plans.DictionaryField, lookup: ir.DictionaryPropertyLookup) ir.CppPropertyRead {
        std.debug.assert(field.options.source == .property and field.options.source_field == null);
        const operation: @FieldType(ir.CppPropertyRead, "operation") = if (field.options.private_symbol) |symbol|
            .{ .private_symbol = symbol }
        else
            .{ .property = .{
                .method = if (lookup == .skip_object_prototype) .skip_object_prototype else if (field.missing == .absent) .get_if_exists else .get,
                .first = field.js_name,
                .aliases = field.options.aliases,
                .missing = field.missing,
            } };
        return .{ .failure = .false_value, .operation = operation };
    }

    const FieldStep = struct { index: usize, kind: enum { convert, prepare, validate, finish } };

    fn fieldSteps(n: *Normalizer, fields: []const schema.DictionaryField, finish: []const []const u8) Error![]const FieldStep {
        var steps: std.ArrayList(FieldStep) = .empty;
        for (fields, 0..) |field, index| {
            const prepared = for (finish) |name| {
                if (std.mem.eql(u8, name, field.name)) break true;
            } else false;
            try steps.append(n.arena, .{ .index = index, .kind = if (prepared) .prepare else if (field.options.enum_membership_after_fields) .validate else .convert });
        }
        for (fields, 0..) |field, index| {
            if (field.options.enum_membership_after_fields) try steps.append(n.arena, .{ .index = index, .kind = .finish });
        }
        for (finish) |name| {
            for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, name, field.name)) try steps.append(n.arena, .{ .index = index, .kind = .finish });
            }
        }
        return steps.items;
    }
};

pub const Sequence = struct {
    const standard = CodecModule.InputErrors.standard;

    pub fn build(n: *Normalizer, id: ir.InboundArgumentPlanId, child: ir.CppInputId) PlanError!ir.CppSequenceInput {
        const position = n.get(id).*;
        const profile = n.input_plans.items[position.input.index].profile;
        const options = n.rawType(position.type).sequence.options;
        const indistinguishable = "this value cannot distinguish a JavaScript input";

        const node_error = if (profile == .node) options.node_error else null;
        if (node_error != null and mod_plans.inputFacts(n, n.get(child.position).input).resolves_iterator_method)
            return n.unsupportedValue(id, "sequence elements cannot use prepared conversions");
        return .{
            .value = child,
            .validation = if (node_error) |failure| .{
                .selection = mod_cpp_facts.Predicates.selection(n, child.position) orelse return n.unsupportedValue(child.position, indistinguishable),
                .failure = elementFailure(failure.element),
                .failure_return = .false_value,
            } else null,
            .too_long = standard(profile, .range, " is too large", if (options.container == .iterable) "<= 4294967295 elements" else "<= 4294967295"),
            .operation = if (options.container == .iterable) .{ .iterable = .{
                .snapshot = options.snapshot_elements,
                .object_error = if (profile == .webidl) standard(profile, .type, " must be an iterable object", "object") else null,
            } } else .{ .indexed = .{
                .selection = mod_cpp_facts.Predicates.selection(n, id) orelse return n.unsupportedValue(id, indistinguishable),
                .object_error = containerError(profile, options),
                .length_limit = options.input_length_limit,
                .pattern = if (options.element_pattern) |pattern| .{ .member_tags = try memberTags(n, n.get(n.get(child).operation.aggregate).operation.union_type.members, pattern.members), .incomplete_error = pattern.incomplete_error } else null,
                .read = try read(n, child, options),
            } },
        };
    }

    fn containerError(profile: ir.Profile, options: schema.SequenceOptions) ir.CppValueInputError {
        const message = if (options.container == .array_like) " must be an array-like object" else " must be an array";
        if (profile == .node) if (options.node_error) |node_error| if (node_error.container) |failure| return switch (failure.kind) {
            .type, .instance => standard(.node, if (failure.kind == .type) .type else .instance, message, failure.expected),
            .invalid_this => .{ .node_invalid_this = failure.expected },
        };
        return standard(profile, .type, message, if (options.container == .array_like) "Object" else "Array");
    }

    fn elementFailure(failure: ir.NodeSequenceFailure) @FieldType(ir.CppSequenceValidation, "failure") {
        return switch (failure.kind) {
            .invalid_this => .{ .sequence = .{ .node_invalid_this = failure.expected } },
            .type, .instance => if (failure.site == .sequence) .{ .sequence = .{ .node_expected = .{
                .kind = if (failure.kind == .type) .type else .instance,
                .requirement = failure.expected,
            } } } else .{ .element = .{ .kind = if (failure.kind == .type) .type else .instance, .expected = failure.expected } },
        };
    }

    fn memberTags(n: *Normalizer, members: []const ir.CppInputUnionMember, names: []const []const u8) Error![]const u16 {
        const tags = try n.arena.alloc(u16, names.len);
        for (names, tags) |name, *tag| {
            for (members) |member| {
                if (std.mem.eql(u8, name, member.name)) {
                    tag.* = member.tag;
                    break;
                }
            } else unreachable;
        }
        return tags;
    }

    fn read(n: *Normalizer, child: ir.CppInputId, options: schema.SequenceOptions) Error!@FieldType(ir.CppIndexedSequenceInput, "read") {
        switch (n.get(child).operation) {
            .lazy => |lazy| return .{ .lazy = .{ .conversion = lazy.conversion, .source = .element, .required = null, .prefetch = false } },
            .void, .discarded, .scalar, .converted, .optional, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .buffer, .aggregate => {},
        }
        if (options.element_pattern) |pattern| if (pattern.read_group_sizes.len != 0) {
            const sizes = try n.arena.alloc(u16, pattern.members.len);
            const offsets = try n.arena.alloc(u16, pattern.members.len);
            @memset(sizes, 0);
            var start: usize = 0;
            for (pattern.read_group_sizes) |size| {
                sizes[start] = size;
                for (0..size) |offset| offsets[start + offset] = @intCast(offset);
                start += size;
            }
            return .{ .grouped = .{ .sizes = sizes, .offsets = offsets } };
        };
        const indexed: ir.CppSequenceRead = .{ .method = switch (options.element_access) {
            .property => .property,
            .direct_index => .direct_index,
        }, .failure = .false_value };
        return if (options.snapshot_elements) .{ .snapshot = indexed } else .{ .interleaved = indexed };
    }
};

pub const Union = struct {
    const errors = CodecModule.InputErrors;
    const standard = errors.standard;

    pub fn build(n: *Normalizer, id: ir.InboundArgumentPlanId, members: []const ir.CppInputUnionMember) PlanError!ir.CppUnionInput {
        const position = n.get(id).*;
        const input = n.input_plans.items[position.input.index];

        const options = n.rawType(position.type).union_type.options;
        const fallback: ?u32 = if (options.fallback_on_conversion_error) fallback: {
            const name = options.fallback_member.?;
            for (members, 0..) |member, index| if (std.mem.eql(u8, name, member.name)) break :fallback @intCast(index);
            unreachable;
        } else null;
        if (options.input_tag) |tag| {
            const Case = @typeInfo(@FieldType(ir.CppTaggedUnionInput, "cases")).pointer.child;
            var cases = try std.ArrayList(Case).initCapacity(n.arena, members.len - @intFromBool(fallback != null));
            for (members, 0..) |member, index| {
                if (fallback == @as(u32, @intCast(index))) continue;
                const selector = mod_types.selectorValue(member.name, if (tag.selector) |selector| selector.enumeration else null);
                cases.appendAssumeCapacity(.{
                    .member = @intCast(index),
                    .value = selector.js_value,
                    .aliases = selector.aliases,
                    .shorthand = if (tag.string_shorthand)
                        if (try shorthandField(n, member.value, tag.tag_property)) |field| .{ .field = field } else .object
                    else
                        .none,
                });
            }
            return .{
                .members = members,
                .fallback = fallback,
                .operation = .{ .tagged = .{
                    .property = tag.tag_property,
                    .tag_read = if (tag.coerce_tag) .{ .coerced = standard(input.profile, .type, " is required", "a value other than undefined") } else .{ .strict = standard(input.profile, .type, " must be a string", "a string") },
                    .object = if (tag.string_shorthand) .shorthand else .{ .required = standard(input.profile, .type, " must be a tagged object", "a tagged object") },
                    .case_insensitive = if (tag.selector) |selector| selector.enumeration.options.ascii_case_insensitive else false,
                    .payload = if (tag.value_property) |property| .{ .property = property } else .object,
                    .cases = cases.items,
                    .unmatched = if (fallback != null) .failure else .{ .raise = if (options.no_match_error) |failure| .{ .custom = failure } else errors.conversion(
                        input.profile,
                        .invalid_value,
                        .{ .suffix = " has an unknown union tag" },
                        "a declared union tag",
                        try n.print(".{s}", .{tag.tag_property}),
                    ) },
                } },
            };
        }
        const tests = try n.arena.alloc(ir.CppValueTest, members.len);
        for (members, tests) |member, *test_| {
            const is_fallback = if (options.fallback_member) |name| std.mem.eql(u8, member.name, name) else false;
            test_.* = if (is_fallback) .always else mod_cpp_facts.Predicates.selection(n, member.value.position) orelse
                return n.unsupportedValue(member.value.position, "this value cannot distinguish a JavaScript input");
        }
        return .{ .members = members, .fallback = fallback, .operation = .{ .matching = .{ .tests = tests, .error_value = noMatch(input.profile, options) } } };
    }

    fn noMatch(profile: ir.Profile, options: schema.UnionOptions) ir.CppValueInputError {
        if (options.no_match_error) |failure| return .{ .custom = failure };
        if (profile == .node) if (options.node_error) |failure| return switch (failure) {
            .invalid_port => .node_port,
            .invalid_property_value => |expected| .{ .node_property_value = expected },
            .invalid_value => |reason| .{ .node_value = .{ .reason = reason } },
            .type_or_instance => |expected| .{ .node_type_or_instance = .{ .expected_type = expected.expected_type, .expected_instances = expected.expected_instances } },
            .expected_type => |expected| standard(profile, .type, " does not match any union member", expected),
            .expected_instances => |expected| standard(profile, .instance, " does not match any union member", expected),
        };
        return standard(profile, .type, " does not match any union member", "a supported union member");
    }

    fn shorthandField(n: *Normalizer, input: ir.CppInputId, property: []const u8) Error!?ir.CppDictionaryValueId {
        const input_id = n.get(input.position).input;
        const metadata = switch (n.input_plans.items[input_id.index].codec) {
            .dictionary => |dictionary| dictionary,
            else => return null,
        };
        if (metadata.len != 1) return null;
        const field = mod_plans.dictionaryField(n, input_id, 0);
        if (!std.mem.eql(u8, field.js_name, property) or field.options.node_unsupported != null or field.options.node_incompatible_with != null) return null;
        if (n.input_plans.items[field.value.index].codec != .string) return null;
        const string = n.projection(field.declaration.field_type).string orelse return null;
        if (string.kind != .dom_string) return null;
        const aggregate = switch (n.get(input).operation) {
            .aggregate => |aggregate_id| n.get(aggregate_id),
            else => return null,
        };
        const fields = switch (aggregate.operation) {
            .dictionary => |dictionary| dictionary.fields,
            .union_type, .sequence, .record => return null,
        };
        return switch (fields[0]) {
            .value => |value| value,
            .source => null,
        };
    }
};

pub const Failures = struct {
    pub fn intern(n: *Normalizer, value: ir.CppCodecFailure) Error!ir.CppCodecFailureId {
        return .of((try n.cpp_codec_failures.getOrPut(n.arena, value)).index);
    }

    pub fn inbound(n: *Normalizer, realm: ir.EngineRealm, throws: ir.NativeThrows, result: ir.CppReturn) Error!ir.CppCodecFailureId {
        return intern(n, .{
            .allocation = switch (throws) {
                .js_exception => .{ .throw_value = .{ .value = result, .if_clear = true } },
                .out_of_memory => .{ .return_value = result },
                .never => .infallible,
            },
            .exception = if (realm == .none) .none else if (throws == .js_exception) .{ .materialize = result } else .{ .termination = result },
        });
    }

    pub fn nativeReturn(n: *const Normalizer, export_: *const ir.NativeExport) ir.CppReturn {
        return if (export_.call_plan.throws == .out_of_memory) .allocation_failure else if (n.get(export_.result_position).isVoid()) .void else .empty;
    }

    pub fn nativeExport(n: *Normalizer, export_: *const ir.NativeExport) Error!ir.CppCodecFailureId {
        return inbound(n, export_.call_plan.realm, export_.call_plan.throws, nativeReturn(n, export_));
    }

    pub fn input(n: *Normalizer, failure: ir.CppInputFailure) Error!ir.CppCodecFailureId {
        const result: ir.CppReturn = switch (failure) {
            .empty => .empty,
            .false_value => .false_value,
            .status => return intern(n, .{ .allocation = .status, .exception = .status }),
        };
        return intern(n, .{ .allocation = .{ .throw_value = .{ .value = result, .if_clear = false } }, .exception = .{ .materialize = result } });
    }

    pub fn decoder(n: *Normalizer, comptime role: ir.Role) Error!ir.CppCodecFailureId {
        return intern(n, if (role == .outbound_argument)
            .{ .allocation = .status, .exception = .status }
        else
            .{ .allocation = .{ .return_value = .false_value }, .exception = .none });
    }
};

fn allocateCache(n: *Normalizer, comptime role: ir.Role, table: anytype) Error!void {
    const Entry = @typeInfo(@typeInfo(@TypeOf(table)).pointer.child).pointer.child;
    table.* = try n.arena.alloc(Entry, n.rolePlans(role).len);
    @memset(table.*, null);
}

pub fn prepare(n: *Normalizer) Error!void {
    const state = &n.cpp_codec_state;
    inline for (std.enums.values(ir.Role)) |role| {
        const stores = try n.arena.alloc(Store(role), n.rolePlans(role).len);
        @memset(stores, .{});
        @field(n, @tagName(role) ++ "_codecs") = stores;
        if (comptime @hasField(@TypeOf(state.encoders), @tagName(role))) {
            const encoders = &@field(state.encoders, @tagName(role));
            try allocateCache(n, role, &encoders.values);
            try allocateCache(n, role, &encoders.children);
        }
        if (comptime @hasField(@TypeOf(state.decodes), @tagName(role)))
            try allocateCache(n, role, &@field(state.decodes, @tagName(role)));
    }
    try allocateCache(n, .outbound_result, &state.javascript);
    try allocateCache(n, .inbound_result, &state.helpers);
}

/// Exposes `encodeResult` on the semantic converters that convert a
/// JavaScript-sourced aggregate result, and on the nested converters their
/// encoders delegate to.
pub fn resultEncodingConverters(n: *Normalizer) Error!void {
    for (n.roleCodecs(.outbound_result)) |codecs| for (codecs.javascript_decoders.items) |decoder| switch (decoder.operation) {
        .aggregate => |aggregate| exposeResultEncoder(n, aggregate),
        .void, .scalar, .value, .branded, .callback, .string, .bytes, .optional => {},
    };
}

fn exposeResultEncoder(n: *Normalizer, aggregate: ir.CppInputAggregateId) void {
    const converter = &n.cppCodecs(aggregate.position).input_aggregates.items[aggregate.index];
    if (converter.result_encoder != null) return;
    const encoder = n.cpp_codec_state.encoders.inbound_argument.values[aggregate.position.index].?.planned;
    converter.result_encoder = encoder;
    exposeNestedResultEncoders(n, encoder);
}

fn exposeNestedResultEncoders(n: *Normalizer, id: ir.CppResultEncoderId(.inbound_argument)) void {
    switch (n.get(id).operation) {
        .leaf => |leaf| if (leaf == .helper) exposeResultEncoder(n, n.cpp_input_state.aggregates.get(id.position).?.planned),
        .converted, .optional => |child| exposeNestedResultEncoders(n, child),
        inline .dictionary, .union_type => |fields| for (fields) |field| exposeNestedResultEncoders(n, field.value),
        .collection => |collection| switch (collection.element) {
            inline else => |element| exposeNestedResultEncoders(n, element),
        },
        .entry => |entry| {
            exposeNestedResultEncoders(n, entry.key);
            exposeNestedResultEncoders(n, entry.value);
        },
    }
}

pub fn errorFactory(n: *Normalizer, id: ir.DomainErrorId, comptime native: bool) PlanError![]const u8 {
    const input = n.domain_error_inputs.items[id.index];
    const symbol = try n.print(if (native) "raiseBindingDomainError_{d}" else "createBindingDomainError_{d}", .{input.factory});
    const factories = if (native) &n.cpp_domain_error_factories else &n.domain_error_factories;
    for (factories.items) |factory| {
        if (std.mem.eql(u8, factory.symbol, symbol)) return factory.symbol;
    }
    const position = n.get(id).position;
    try factories.append(n.arena, .{
        .symbol = symbol,
        .value_type = if (n.get(position).isVoid()) null else if (native)
            mod_cpp_facts.Types.resultValue(n, position)
        else
            try n.cppType(.{ .wire = n.get(position).wire }),
        .name_override = switch (input.declaration) {
            .error_object => |options| if (options.name_override) |name| .{ .name = name, .enumerable = options.name_override_enumerable } else null,
            .system_error => |options| if (options.name_override) |name| .{ .name = name, .enumerable = options.name_override_enumerable } else null,
            .dom_exception, .builtin_error, .system_error_with_info, .class_instance, .aggregate_error => null,
        },
        .operation = switch (input.declaration) {
            .error_object => |options| .{ .error_object = .{ .class = options.class, .code = options.code, .message = errorMessage(native, options.message) } },
            .dom_exception => |options| .{ .dom_exception = .{ .name = options.exception, .message = errorMessage(native, options.message) } },
            .builtin_error => |options| .{ .builtin_error = .{ .group = options.group, .function = options.function, .materializer = try errorMaterializer(n, position, native) } },
            .class_instance => .{ .class_instance = try errorMaterializer(n, position, native) },
            .aggregate_error => |options| .{ .aggregate_error = .{ .message = options.message, .materializer = try errorMaterializer(n, position, native) } },
            .system_error => |options| .{ .system_error = .{
                .payload = if (native) .native else .wire,
                .detail = .{ .standard = .{ .metadata_configurable = options.metadata_configurable } },
            } },
            .system_error_with_info => .{ .system_error = .{ .payload = if (native) .native else .wire, .detail = .info } },
        },
    });
    return symbol;
}

fn errorMessage(comptime native: bool, message: ir.ErrorMessage) ir.CppErrorMessage {
    return switch (message) {
        .literal => |literal| .{ .literal = literal },
        .payload => .{ .payload = if (native) .string else .string_handle },
    };
}

fn errorMaterializer(n: *Normalizer, position: ir.InboundResultPlanId, comptime native: bool) PlanError!ir.CppMaterializerId(.inbound_result) {
    return CodecModule.Materialize.planJavaScript(n, position, if (native) .native else .wire);
}

fn aggregateRequestsByType(n: *Normalizer, comptime Request: type, requests: *const std.AutoHashMapUnmanaged(Request, void)) Error![]const ?Request {
    const selected = try n.arena.alloc(?Request, n.types.items.len);
    @memset(selected, null);
    var iterator = requests.keyIterator();
    while (iterator.next()) |request| {
        const position = if (Request == mod_cpp_facts.InputAggregateRequest) request.position else request.*;
        const slot = &selected[n.get(position).type.index];
        if (slot.*) |previous| {
            if (Request == mod_cpp_facts.InputAggregateRequest) {
                if (request.location != previous.location) {
                    if (request.location == .public_header) slot.* = request.*;
                    continue;
                }
            }
            const previous_position = if (Request == mod_cpp_facts.InputAggregateRequest) previous.position else previous;
            if (position.index >= previous_position.index) continue;
        }
        slot.* = request.*;
    }
    return selected;
}

pub fn typeDefinitions(n: *Normalizer) Error!void {
    try mod_cpp_facts.markAggregates(n);
    const inputs = try aggregateRequestsByType(n, mod_cpp_facts.InputAggregateRequest, &n.cpp_input_aggregate_requests);
    const results = try aggregateRequestsByType(n, ir.InboundResultPlanId, &n.cpp_result_aggregate_requests);
    const converted = try aggregateRequestsByType(n, ir.InboundArgumentPlanId, &n.cpp_converted_aggregate_requests);
    var definitions: std.ArrayList(ir.CppTypeDefinition) = .empty;
    for (try mod_cpp_facts.bindingTypeOrder(n)) |type_id| {
        const t = n.irType(type_id);
        if (t.data != .dictionary and t.data != .union_type) continue;
        if (inputs[type_id.index]) |request| try definitions.append(n.arena, try typeDefinition(n, request.position, request.location, false));
        if (results[type_id.index]) |id| {
            try definitions.append(n.arena, try typeDefinition(n, id, .public_header, true));
        } else if (converted[type_id.index]) |id| {
            try definitions.append(n.arena, try typeDefinition(n, id, .public_header, true));
        }
    }
    n.cpp_type_definitions = definitions.items;
}

fn typeDefinition(n: *Normalizer, id: anytype, location: ir.CppAggregateLocation, logical: bool) Error!ir.CppTypeDefinition {
    const position = n.get(id).*;
    const t = n.irType(position.type);
    const name = n.type_metadata.items[t.id.index].cpp_name.?;
    const body: @FieldType(ir.CppTypeDefinition, "body") = switch (position.representation) {
        .converted, .optional, .sequence, .record, .rest, .record_entry => unreachable,
        .dictionary => |fields| .{ .dictionary = try definitionFields(n, fields, logical, true) },
        .union_type => |members| try unionDefinition(n, t.id, try definitionFields(n, members, logical, false), logical),
        .leaf => unreachable,
    };
    return .{
        .name = if (logical) try n.print("{s}Result", .{name}) else name,
        .location = location,
        .protects_sources = logical and mod_cpp_facts.get(n, id).contains_engine_reference,
        .transferred_roots = logical and mod_cpp_facts.get(n, id).decode_requires_realm,
        .body = body,
    };
}

fn definitionFieldType(n: *Normalizer, id: anytype, logical: bool) Error!ir.CppTypeId {
    return (if (logical) mod_cpp_facts.Types.result(n, id).logical else mod_cpp_facts.Types.input(n, id).value) orelse unreachable;
}

fn definitionFields(n: *Normalizer, fields: anytype, logical: bool, comptime dictionary: bool) Error![]const ir.CppTypeField {
    const members = try n.arena.alloc(ir.CppTypeField, fields.len);
    for (fields, members) |field, *member| {
        const value_type = if (dictionary and !logical and field.dictionary_source)
            try n.cppType(.{ .named = .{ .name = "CppDictionarySource", .namespace = .binding } })
        else if (dictionary and field.optional)
            try n.cppType(.{ .optional = try definitionFieldType(n, field.value, logical) })
        else
            try definitionFieldType(n, field.value, logical);
        member.* = .{ .name = field.name, .type = value_type, .protects_sources = logical and mod_cpp_facts.get(n, field.value).contains_engine_reference };
    }
    return members;
}

fn unionDefinition(n: *Normalizer, type_id: ir.TypeId, members: []const ir.CppTypeField, logical: bool) Error!@FieldType(ir.CppTypeDefinition, "body") {
    const UnionBody = @FieldType(@FieldType(ir.CppTypeDefinition, "body"), "union_type");
    const Selector = @typeInfo(@FieldType(UnionBody, "selector")).optional.child;
    const selector: ?Selector = if (!logical) selector: {
        const raw = n.rawType(type_id).union_type;
        const tag = raw.options.input_tag orelse break :selector null;
        const enum_type = n.get(n.irType(n.typeId(tag.selector orelse break :selector null)).data.enumeration);
        const values = try n.arena.alloc(@typeInfo(@FieldType(Selector, "values")).pointer.child, members.len);
        for (raw.members, values) |member, *value| {
            const fallback = if (raw.options.fallback_member) |name| std.mem.eql(u8, member.name, name) else false;
            value.* = if (fallback) .forward else .{ .constant = (mod_types.selectorValue(member.name, if (tag.selector) |selector| selector.enumeration else null)).value_name };
        }
        break :selector .{ .type = try n.cppType(.{ .named = .{ .name = enum_type.cpp_name, .namespace = .binding } }), .values = values };
    } else null;
    return .{ .union_type = .{ .members = members, .visit = !logical, .selector = selector } };
}
