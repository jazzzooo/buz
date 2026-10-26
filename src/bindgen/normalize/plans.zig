//! JavaScript input recipes.
const std = @import("std");
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const types = @import("types.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

pub const InputPlanId = ir.Id("input_plans");

pub const InputCodec = union(enum) {
    none,
    discarded: struct { match: InputPlanId },
    boolean,
    integer,
    number,
    js_value,
    branded_value,
    lazy: InputPlanId,
    converted: struct { match: InputPlanId, converted_value: InputPlanId },
    string,
    utf8_string,
    node_path,
    buffer,
    native_slice,
    callback,
    optional: struct { child: InputPlanId, optional_mode: ir.OptionalMode, optional_matches_class_reference: bool },
    enumeration,
    dictionary: []const InputPlanId,
    union_type: []const InputPlanId,
    sequence: struct { child: InputPlanId },
    record: struct { key: InputPlanId, value: InputPlanId },
    nominal_handle,
    class_ref,
    external_ref,
    native_instance,
};

/// How one semantic type converts from JavaScript under one profile and
/// value-conversion rule. Crossing requirements live on position plans.
pub const InputPlan = struct {
    type: ir.TypeId,
    profile: ir.Profile,
    path_override: ?[]const u8,
    conversion_context: ir.ConversionContext,
    codec: InputCodec,
};

pub const TypePlans = struct { input_plans: [3]InputPlanId };

pub const InputFacts = struct {
    contains_custom_conversion: bool = false,
    contains_lazy_conversion: bool = false,
    contains_receiver_conversion: bool = false,
    contains_call_receiver_conversion: bool = false,
    contains_receiver_byte_length_conversion: bool = false,
    effective_buffer_mode_mask: u8 = 0,
    resolves_iterator_method: bool = false,
};

pub fn inputFacts(n: *const Normalizer, id: InputPlanId) InputFacts {
    return n.input_facts.items[id.index];
}

pub fn apiPositions(n: *const Normalizer) Error![]const ir.TypePlans {
    const aliases = try n.arena.alloc(ir.TypePlans, n.type_plans.len);
    for (n.type_plans, n.result_positions, aliases) |value, position, *output| output.* = .{
        .argument_position = n.input_positions[value.input_plans[@backingInt(ir.Profile.exact)].index],
        .result_position = position,
    };
    return aliases;
}

pub const InputPlanKey = struct {
    type: u32,
    profile: ir.Profile,
    conversion: schema.ValueConversionOptions,
};

pub fn unionContainsOnlyClassReferences(n: *const Normalizer, id: InputPlanId) bool {
    const input = n.input_plans.items[id.index];
    if (n.rawType(input.type).union_type.options.input_tag != null) return false;
    const members = input.codec.union_type;
    if (members.len == 0) return false;
    for (members) |member| if (n.input_plans.items[member.index].codec != .class_ref) return false;
    return true;
}

/// Plans default JavaScript inputs for each type and profile.
pub fn planAll(n: *Normalizer) Error!void {
    n.type_plans = try n.arena.alloc(TypePlans, n.types.items.len);
    for (0..n.types.items.len) |id| {
        n.type_plans[id] = .{
            .input_plans = .{
                try inputPlan(n, .of(id), .webidl, .{}),
                try inputPlan(n, .of(id), .node, .{}),
                try inputPlan(n, .of(id), .exact, .{}),
            },
        };
    }
}

pub fn plan(n: *const Normalizer, id: InputPlanId) *const InputPlan {
    return &n.input_plans.items[id.index];
}

pub fn codecOf(n: *const Normalizer, id: InputPlanId) std.meta.Tag(InputCodec) {
    return std.meta.activeTag(plan(n, id).codec);
}

fn effectiveBufferModeBit(mode: ir.BufferMode) u8 {
    return switch (mode) {
        .copy => 1 << 0,
        .lease => 1 << 1,
    };
}

pub fn mergeFacts(left: InputFacts, right: InputFacts) InputFacts {
    var result: InputFacts = undefined;
    inline for (@typeInfo(InputFacts).@"struct".field_names) |name| {
        @field(result, name) = if (comptime std.mem.eql(u8, name, "effective_buffer_mode_mask"))
            @field(left, name) | @field(right, name)
        else
            @field(left, name) or @field(right, name);
    }
    return result;
}

pub fn conversionOf(boolean: ir.BooleanConversion, integer: ir.IntegerConversion, number: ir.NumberConversion) schema.ValueConversionOptions {
    return .{ .boolean_conversion = boolean, .integer_conversion = integer, .number_conversion = number };
}

pub fn inputPlan(n: *Normalizer, id: ir.TypeId, profile: ir.Profile, conversion: schema.ValueConversionOptions) Error!InputPlanId {
    const key: InputPlanKey = .{ .type = id.index, .profile = profile, .conversion = conversion };
    if (n.input_plan_index.get(key)) |existing| return .of(existing);
    const value = try buildInputPlan(n, id, profile, conversion);
    const index: u32 = @intCast(n.input_plans.items.len);
    try n.input_plans.append(n.arena, value.plan);
    try n.input_facts.append(n.arena, value.facts);
    try n.input_conversions.append(n.arena, conversion);
    try n.input_plan_index.put(n.arena, key, index);
    return .of(index);
}

fn buildInputPlan(n: *Normalizer, id: ir.TypeId, profile: ir.Profile, conversion: schema.ValueConversionOptions) Error!struct { plan: InputPlan, facts: InputFacts } {
    const t = n.irType(id).*;
    const projection = n.projection(id);
    var facts: InputFacts = .{};
    var resolves_iterator_method = false;
    const codec: InputCodec = switch (t.data) {
        .void => .none,
        .boolean => .boolean,
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => blk: {
            if (conversion.integer_conversion == .node_receiver_byte_length) facts = .{
                .contains_receiver_conversion = true,
                .contains_call_receiver_conversion = true,
                .contains_receiver_byte_length_conversion = true,
            };
            break :blk .integer;
        },
        .f64 => .number,
        .any, .engine_value => .js_value,
        .branded_value => .branded_value,
        .discarded => blk: {
            const discarded = n.rawType(id).discarded;
            const match = try inputPlan(n, n.typeId(discarded.match_type.*), profile, .{});
            if (discarded.match == .semantic_type) {
                resolves_iterator_method = inputFacts(n, match).resolves_iterator_method;
            }
            break :blk .{ .discarded = .{ .match = match } };
        },
        .lazy => |child_type| blk: {
            const child = try inputPlan(n, child_type, profile, conversion);
            facts = inputFacts(n, child);
            facts.contains_lazy_conversion = true;
            resolves_iterator_method = inputFacts(n, child).resolves_iterator_method;
            break :blk .{ .lazy = child };
        },
        .converted => |converted| blk: {
            const match = try inputPlan(n, n.typeId(n.rawType(id).converted.match), profile, conversion);
            const value = try inputPlan(n, converted.native_type, profile, .{});
            facts = mergeFacts(inputFacts(n, match), inputFacts(n, value));
            facts.contains_custom_conversion = true;
            resolves_iterator_method = inputFacts(n, match).resolves_iterator_method;
            break :blk .{ .converted = .{ .match = match, .converted_value = value } };
        },
        .dom_string, .usv_string, .byte_string => .string,
        .utf8_string => .utf8_string,
        .node_path => .node_path,
        .buffer => blk: {
            facts.effective_buffer_mode_mask = effectiveBufferModeBit(projection.buffer.?.effective_mode);
            break :blk .buffer;
        },
        .native_slice => .native_slice,
        .callback => .callback,
        .optional => |optional| blk: {
            const child = try inputPlan(n, optional.child, profile, conversion);
            facts = inputFacts(n, child);
            resolves_iterator_method = inputFacts(n, child).resolves_iterator_method;
            break :blk .{ .optional = .{
                .child = child,
                .optional_mode = optional.optional_mode,
                .optional_matches_class_reference = optional.optional_mode == .matched and codecOf(n, child) == .class_ref,
            } };
        },
        .enumeration => .enumeration,
        .dictionary => |dictionary| blk: {
            const fields = try dictionaryFieldPlans(n, dictionary, n.rawType(id).dictionary.fields, profile);
            for (fields) |field| facts = mergeFacts(facts, inputFacts(n, field));
            break :blk .{ .dictionary = fields };
        },
        .union_type => |union_type| blk: {
            const raw = n.rawType(id).union_type;
            const members = try unionMemberPlans(n, union_type, raw.members, profile);
            for (members) |member| {
                facts = mergeFacts(facts, inputFacts(n, member));
                if (inputFacts(n, member).resolves_iterator_method) resolves_iterator_method = true;
            }
            if (raw.options.input_tag != null) resolves_iterator_method = false;
            break :blk .{ .union_type = members };
        },
        .sequence => |sequence| blk: {
            const options = n.rawType(id).sequence.options;
            const child = try inputPlan(n, sequence.child, profile, options.element_conversion);
            facts = inputFacts(n, child);
            resolves_iterator_method = options.container == .iterable;
            break :blk .{ .sequence = .{ .child = child } };
        },
        .record => |record| blk: {
            const key = try inputPlan(n, record.key_type, profile, .{});
            const value = try inputPlan(n, record.value_type, profile, .{});
            facts = mergeFacts(inputFacts(n, key), inputFacts(n, value));
            break :blk .{ .record = .{
                .key = key,
                .value = value,
            } };
        },
        .nominal_handle => .nominal_handle,
        .class_ref => .class_ref,
        .external_ref => .external_ref,
        .native_instance => .native_instance,
    };
    facts.resolves_iterator_method = resolves_iterator_method;
    return .{ .plan = .{
        .type = id,
        .profile = profile,
        .path_override = switch (t.data) {
            .dictionary => n.rawType(id).dictionary.options.user_facing_name,
            .converted => n.rawType(id).converted.options.name,
            else => null,
        },
        .conversion_context = conversionContext(n, id, profile, conversion),
        .codec = codec,
    }, .facts = facts };
}

fn dictionaryFieldPlans(n: *Normalizer, dictionary: ir.DictionaryType, raw_fields: []const schema.DictionaryField, parent_profile: ir.Profile) Error![]const InputPlanId {
    const fields = try n.arena.alloc(InputPlanId, dictionary.dictionary_fields.len);
    for (dictionary.dictionary_fields, raw_fields, fields) |field, raw, *field_plan| {
        const options = raw.options;
        const effective_profile = options.profile orelse parent_profile;
        field_plan.* = try inputPlan(n, field.field_type, effective_profile, conversionOf(options.boolean_conversion, options.integer_conversion, options.number_conversion));
    }
    return fields;
}

pub const DictionaryField = struct {
    declaration: ir.DictionaryField,
    options: schema.DictionaryFieldOptions,
    value: InputPlanId,
    js_name: []const u8,
    missing: ir.DictionaryFieldMissingPlan,
    presence: ir.DictionaryFieldPresence,
};

pub fn dictionaryField(n: *const Normalizer, id: InputPlanId, index: usize) DictionaryField {
    const input = plan(n, id);
    const dictionary = n.irType(input.type).data.dictionary;
    const field = dictionary.dictionary_fields[index];
    const raw_fields = n.rawType(input.type).dictionary.fields;
    const options = raw_fields[index].options;
    const name = if (options.source_field) |source| name: {
        for (raw_fields) |candidate| if (std.mem.eql(u8, candidate.name, source)) break :name candidate.propertyName();
        unreachable;
    } else raw_fields[index].propertyName();
    return .{
        .declaration = field,
        .options = options,
        .value = input.codec.dictionary[index],
        .js_name = name,
        .missing = switch (options.missing) {
            .undefined => .undefined,
            .undefined_or_null => .undefined_or_null,
            .absent => .absent,
        },
        .presence = types.dictionaryFieldPresence(options),
    };
}

fn unionMemberPlans(n: *Normalizer, union_type: ir.UnionType, raw_members: []const schema.UnionMember, profile: ir.Profile) Error![]const InputPlanId {
    const members = try n.arena.alloc(InputPlanId, union_type.union_members.len);
    for (union_type.union_members, raw_members, members) |member, raw, *member_plan| {
        member_plan.* = try inputPlan(n, member.member_type, profile, conversionOf(raw.options.boolean_conversion, raw.options.integer_conversion, raw.options.number_conversion));
    }
    return members;
}

fn conversionContext(n: *const Normalizer, id: ir.TypeId, profile: ir.Profile, conversion: schema.ValueConversionOptions) ir.ConversionContext {
    if (profile == .webidl and conversion.boolean_conversion != .strict and conversion.integer_conversion != .matching and
        conversion.integer_conversion != .saturate_validate and conversion.integer_conversion != .bounded_integer and
        conversion.integer_conversion != .truncate_clamp and conversion.integer_conversion != .modulo) return .none;
    const projection = n.projection(id);
    const needed = switch (projection.conversion_codec) {
        .boolean => conversion.boolean_conversion == .normal or conversion.boolean_conversion == .strict or conversion.boolean_conversion == .node_property_typeof,
        .number => switch (conversion.number_conversion) {
            .normal, .node_validate, .enforce_range => true,
            .coerce, .coerce_clamp, .coerce_truncate_or_default, .coerce_truncate_clamp, .coerce_wrap_clamp, .integer_or_infinity => false,
        },
        .string => projection.string.?.conversion == .profile,
        .external_ref => true,
        .enumeration => n.rawType(id).enumeration.options.node_invalid_value == null and n.rawType(id).enumeration.options.strict_errors == null,
        .integer => switch (conversion.integer_conversion) {
            .normal, .modulo, .enforce_range, .node_validate, .node_validate_with, .node_coerce, .node_validate_prose, .node_truncate, .node_receiver_byte_length, .truncate_saturate, .truncate_clamp, .saturate_validate, .bounded_integer, .matching => true,
            .coerce, .coerce_saturate, .coerce_truncate_or_default, .webidl, .to_length, .clamp => false,
        },
        else => false,
    };
    if (!needed) return .none;
    return switch (profile) {
        .webidl => .exact_literal,
        .node => if (conversion.integer_conversion == .node_coerce and conversion.integer_conversion.node_coerce.range_error == .predicate)
            .node_predicate_literal
        else if (conversion.integer_conversion == .node_validate_prose or
            (conversion.integer_conversion == .node_truncate and conversion.integer_conversion.node_truncate.range_error == .prose) or
            (conversion.integer_conversion == .node_receiver_byte_length and conversion.integer_conversion.node_receiver_byte_length.range_error == .prose))
            .node_prose_literal
        else
            .node_literal,
        .exact => .exact_literal,
    };
}
