const mod_plans = @import("plans.zig");
const mod_wire = @import("wire.zig");
const mod_api_types = @import("api_types.zig");
const mod_callables = @import("callables.zig");
const mod_codecs = @import("codecs.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const InputPlanId = mod_plans.InputPlanId;
const normalize = @import("../normalize.zig");
const structural = @import("../structural.zig");
const parts = @import("plan_parts.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

fn Key(comptime role_: ir.Role) type {
    return struct {
        pub const role = role_;

        input: InputPlanId,
        transfer: bool = false,
        native_class: ?ir.ClassId = null,
        record_entry: bool = false,
        stored: bool = false,
        native_heap: bool = false,
        form: Form(role_) = .value,
    };
}

fn Form(comptime role: ir.Role) type {
    return switch (role) {
        .inbound_argument => union(enum) {
            value,
            receiver: ir.ClassId,
            deferred: ir.DeferredPosition,
            rest: ir.InboundArgumentPlanId,
            count,
            lazy_rest: ir.DeferredPosition,
        },
        .outbound_argument => union(enum) { value, rest: ir.OutboundArgumentPlanId },
        .inbound_result, .outbound_result => enum { value },
    };
}

pub const Planner = struct {
    n: *Normalizer,
    wires: *mod_wire.Builder,
    index: struct {
        inbound_argument: structural.Map(Key(.inbound_argument), ir.InboundArgumentPlanId) = .empty,
        inbound_result: structural.Map(Key(.inbound_result), ir.InboundResultPlanId) = .empty,
        outbound_argument: structural.Map(Key(.outbound_argument), ir.OutboundArgumentPlanId) = .empty,
        outbound_result: structural.Map(Key(.outbound_result), ir.OutboundResultPlanId) = .empty,
    } = .{},

    pub const Converters = struct { input: ?ir.InboundArgumentPlanId, result: ?ir.InboundResultPlanId };

    pub fn finish(p: *Planner) Error!void {
        const n = p.n;
        const inputs = try n.arena.alloc(?ir.InboundArgumentPlanId, n.input_plans.items.len);
        for (n.input_plans.items, inputs, 0..) |input, *position, index| {
            position.* = if (p.supports(input.type, .inbound_argument, false)) try p.get(.inbound_argument, .{ .input = .of(index) }) else null;
        }
        n.input_positions = inputs;
        const results = try n.arena.alloc(?ir.InboundResultPlanId, n.types.items.len);
        for (n.types.items, results) |result, *position| {
            position.* = if (p.supports(result.id, .inbound_result, false)) try p.get(.inbound_result, .{
                .input = n.typePlans(result.id).input_plans[@backingInt(ir.Profile.exact)],
                .stored = true,
            }) else null;
        }
        n.result_positions = results;
        var apis: mod_api_types.Planner = .{ .positions = p };
        var converters: std.enums.EnumArray(ir.Role, std.ArrayList(Converters)) = .initFill(.empty);
        while (true) {
            var progressed = false;
            inline for (std.enums.values(ir.Role)) |role| {
                const planned = converters.getPtr(role);
                while (planned.items.len < n.rolePlans(role).len) {
                    const id: role.PlanId() = .of(planned.items.len);
                    try planned.append(n.arena, try p.converterPlans(id));
                    _ = try apis.get(id);
                    progressed = true;
                }
            }
            if (!progressed) break;
        }
        inline for (std.enums.values(ir.Role)) |role| n.position_converters.set(role, converters.get(role).items);
    }

    fn converterPlans(p: *Planner, id: anytype) Error!Converters {
        const position = p.n.get(id).*;
        const input = if (p.supports(position.type, .inbound_argument, false)) try p.get(.inbound_argument, .{
            .input = position.input,
            .transfer = position.transfer,
            .stored = position.stored,
            .native_heap = position.native_heap,
            .record_entry = position.record_entry,
            .native_class = position.native_class,
        }) else null;
        const result = if (@TypeOf(id).role == .inbound_result) id else if (p.supports(position.type, .inbound_result, false)) try p.get(.inbound_result, .{
            .input = position.input,
            .stored = true,
            .record_entry = position.record_entry,
            .native_class = position.native_class,
        }) else null;
        return .{ .input = input, .result = result };
    }

    pub fn planReceiver(p: *Planner, class: ir.ClassId) Error!ir.InboundArgumentPlanId {
        const value_type = p.n.typeId(p.n.declared_classes.items[class.index].value);
        return p.get(.inbound_argument, .{
            .input = p.n.typePlans(value_type).input_plans[@backingInt(ir.Profile.exact)],
            .form = .{ .receiver = class },
        });
    }

    pub fn resultNeedsDestroy(p: *const Planner, id: ir.InboundResultPlanId, domain_errors: []const ir.DomainErrorId) bool {
        if (p.n.get(id).*.zig.destruction.wire) return true;
        for (domain_errors) |domain_error| if (p.n.get(p.n.get(domain_error).position).*.zig.destruction.wire) return true;
        return false;
    }

    pub const ArgumentRequest = struct {
        input: struct { value: InputPlanId, rest: ?InputPlanId },
        rest_mode: mod_callables.RestMode,
        ownership: ir.ArgumentOwnership,
        deferred: ?ir.DeferredPosition,
        stored: bool,
    };

    pub fn planArgument(p: *Planner, comptime role: ir.Role, request: ArgumentRequest) Error!struct { position: role.PlanId(), rest_position: ?ir.RestPosition(role) } {
        const deferred = request.deferred;
        var key: Key(role) = .{
            .input = request.input.value,
            .transfer = request.ownership == .transfer,
            .stored = request.stored,
            .form = if (role == .inbound_argument) if (deferred) |value_| .{ .deferred = value_ } else .value else .value,
        };
        const position = try p.get(role, key);
        if (role == .inbound_result or role == .outbound_result) return .{ .position = position, .rest_position = null };
        const rest_position: ?ir.RestPosition(role) = if (request.rest_mode == .none) null else if (request.input.rest) |rest|
            .{ .typed = try p.get(role, .{ .input = rest }) }
        else rest: {
            key.form = if (role == .inbound_argument) if (request.rest_mode == .count)
                .count
            else if (deferred) |value_| .{ .lazy_rest = value_ } else .{ .rest = position } else .{ .rest = position };
            const rest_plan = try p.get(role, key);
            break :rest if (role == .inbound_argument) switch (key.form) {
                .count => .{ .count = rest_plan },
                .lazy_rest => .{ .lazy = rest_plan },
                .rest => .{ .values = rest_plan },
                .value, .receiver, .deferred => unreachable,
            } else .{ .values = rest_plan };
        };
        return .{ .position = position, .rest_position = rest_position };
    }

    pub fn value(p: *Planner, comptime role: ir.Role, t: ir.TypeId, input: ?InputPlanId, owner: ?ir.ClassId) Error!role.PlanId() {
        return p.get(role, .{ .input = input orelse p.n.typePlans(t).input_plans[@backingInt(ir.Profile.exact)], .native_class = owner });
    }

    fn childPosition(p: *Planner, parent: anytype, input: InputPlanId) Error!@TypeOf(parent).role.PlanId() {
        const role = @TypeOf(parent).role;
        var key = parent;
        key.input = input;
        key.record_entry = false;
        key.form = .value;
        key.native_heap = parent.native_heap or switch (p.n.input_plans.items[parent.input.index].codec) {
            .sequence, .record => true,
            else => false,
        };
        key.stored = parent.stored or switch (p.n.input_plans.items[parent.input.index].codec) {
            .dictionary, .union_type, .sequence, .record, .lazy => true,
            else => false,
        };
        return p.get(role, key);
    }

    pub fn get(p: *Planner, comptime role: ir.Role, requested: Key(role)) Error!role.PlanId() {
        var key = requested;
        const type_id = p.n.input_plans.items[key.input.index].type;
        const kind = p.n.irType(type_id).kind();
        if (kind != .native_instance) key.native_class = null;
        if (kind == .lazy) {
            // A lazy handle owns its conversion storage independently of its enclosing container.
            key.stored = false;
            key.native_heap = false;
        }
        if (@field(p.index, @tagName(role)).get(key)) |id| return id;
        const plan = try p.build(key);
        const id: role.PlanId() = .of(p.n.rolePlans(role).len);
        try p.n.planList(role).append(p.n.arena, plan);
        try @field(p.index, @tagName(role)).put(p.n.arena, key, id);
        return id;
    }

    fn build(p: *Planner, key: anytype) Error!parts.Value(@TypeOf(key).role) {
        const role = @TypeOf(key).role;
        const input = p.n.input_plans.items[key.input.index];
        var wire = p.wires.planned(input.type, role);
        const representation = (try p.buildRepresentation(key, &wire)).?;
        const lifetime_plan = p.lifetime(role, representation);
        const zig = try mod_codecs.build(p, role, key.input, representation, key.transfer);
        const position: parts.Value(role) = .{
            .type = input.type,
            .input = key.input,
            .transfer = key.transfer,
            .stored = key.stored,
            .native_heap = key.native_heap,
            .record_entry = key.record_entry,
            .native_class = key.native_class,
            .representation = representation,
            .wire = wire,
            .ownership = if (key.transfer) .transfer else lifetime_plan.ownership,
            .zig = zig,
            .requires_scope = lifetime_plan.requires_scope,
        };
        return position;
    }

    fn buildRepresentation(p: *Planner, key: anytype, wire: *ir.WireTypeId) Error!?ir.Representation(@TypeOf(key).role) {
        const role = @TypeOf(key).role;
        switch (role) {
            .inbound_argument => switch (key.form) {
                .value => {},
                .receiver => |class| {
                    wire.* = try p.wires.pointer(p.wires.named("BindNativeHandle"), false);
                    return .{ .leaf = .{ .native_receiver = class } };
                },
                .deferred => |deferred| return .{ .leaf = .{ .lazy_view = deferred } },
                .count => {
                    wire.* = try p.wires.scalar(.size_t);
                    return .{ .leaf = .{ .scalar = .usize } };
                },
                .lazy_rest => |deferred| {
                    wire.* = p.wires.named("BindJSValueSlice");
                    return .{ .leaf = .{ .lazy_rest = deferred } };
                },
                inline .rest => |element| {
                    wire.* = p.wires.named("BindJSValueSlice");
                    return .{ .rest = element };
                },
            },
            .outbound_argument => switch (key.form) {
                .value => {},
                inline .rest => |element| {
                    wire.* = p.wires.named("BindEncodedJSValueSlice");
                    return .{ .rest = element };
                },
            },
            .inbound_result, .outbound_result => switch (key.form) {
                .value => {},
            },
        }
        const input = p.n.input_plans.items[key.input.index];
        const t = p.n.irType(input.type).*;
        const is_argument = role == .inbound_argument or role == .outbound_argument;
        const inbound = role == .inbound_argument;
        return if (key.record_entry) blk: {
            const types = p.wires.types.keys();
            wire.* = types[types[wire.*.index].structure.fields[0].type.index].pointer.child;
            break :blk .{ .record_entry = .{ .key = try p.childPosition(key, input.codec.record.key), .value = try p.childPosition(key, input.codec.record.value) } };
        } else switch (t.data) {
            .void => if (role == .outbound_argument) null else .{ .leaf = .void },
            .boolean, .discarded, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => .{ .leaf = .{ .scalar = p.n.projection(t.id).scalar_kind.? } },
            .enumeration => .{ .leaf = .enumeration },
            .any, .engine_value, .branded_value => .{ .leaf = if (role == .outbound_argument and !key.transfer)
                .{ .js_value_operand = p.n.projection(t.id).js_value_kind.? }
            else if (inbound)
                .{ .js_value_view = p.n.projection(t.id).js_value_kind.? }
            else
                .{ .js_value_result = p.n.projection(t.id).js_value_kind.? } },
            .dom_string, .usv_string, .byte_string => .{ .leaf = if (role == .outbound_argument and !key.transfer) .string_operand else if (inbound) .string_view else .string_owned },
            .utf8_string => if (role == .inbound_result) .{ .leaf = .utf8_owned } else null,
            .node_path, .buffer => .{ .leaf = if (p.n.projection(t.id).buffer != null and p.n.projection(t.id).buffer.?.effective_mode == .lease)
                (if (role == .inbound_argument) .byte_lease else if (role == .inbound_result) .lease_owned else return null)
            else if (role == .outbound_argument)
                .bytes_operand
            else if (is_argument)
                .bytes_view
            else
                .bytes_owned },
            .native_slice => .{ .leaf = if (inbound) .native_slice_view else if (role == .outbound_argument) .native_slice else return null },
            .callback => .{ .leaf = if (is_argument) .callback_view else if (role == .outbound_result) .callback_result else .callback_owned },
            .class_ref => .{ .leaf = if (is_argument) .class_view else if (role == .outbound_result) .class_result else .class_owned },
            .external_ref => .{ .leaf = if (inbound) .external_view else if (role == .inbound_result) .external_owned else return null },
            .nominal_handle => |handle| .{ .leaf = switch (handle.ownership) {
                .borrowed => .nominal_borrow,
                .owned => |owner| if (!is_argument or key.transfer)
                    .{ .nominal_owned = owner }
                else if (role == .outbound_argument)
                    .{ .nominal_owner_borrow = owner }
                else
                    .nominal_borrow,
            } },
            .native_instance => if (role == .inbound_result) .{ .leaf = .{ .native_instance = key.native_class.? } } else null,
            .converted => .{ .converted = .{
                .match = try p.childPosition(key, input.codec.converted.match),
                .value = try p.childPosition(key, input.codec.converted.converted_value),
            } },
            .lazy => .{ .leaf = if (role == .outbound_argument) lazy: {
                const protocol = try p.get(.inbound_argument, .{
                    .input = key.input,
                    .transfer = key.transfer,
                    .stored = key.stored,
                    .native_heap = key.native_heap,
                    .record_entry = key.record_entry,
                    .native_class = key.native_class,
                });
                break :lazy .{ .lazy_operand = .{ .value = p.n.get(protocol).representation.leaf.lazy_field, .protocol = protocol } };
            } else if (inbound) .{ .lazy_field = try p.childPosition(key, input.codec.lazy) } else return null },
            .optional => .{ .optional = try p.childPosition(key, input.codec.optional.child) },
            .dictionary => |dictionary| blk: {
                const fields = try p.n.arena.alloc(ir.PositionField(role), input.codec.dictionary.len);
                for (dictionary.dictionary_fields, p.n.rawType(input.type).dictionary.fields, input.codec.dictionary, fields) |declaration, raw, field, *position| position.* = .{
                    .name = declaration.field_name,
                    .value = try p.childPosition(key, field),
                    .optional = declaration.storage == .optional,
                    .dictionary_source = raw.options.source == .dictionary,
                };
                break :blk .{ .dictionary = fields };
            },
            .union_type => blk: {
                const members = try p.n.arena.alloc(ir.PositionMember(role), input.codec.union_type.len);
                for (t.data.union_type.union_members, input.codec.union_type, members) |declaration, member, *position| position.* = .{ .name = declaration.member_name, .value = try p.childPosition(key, member) };
                break :blk .{ .union_type = members };
            },
            .sequence => .{ .sequence = try p.childPosition(key, input.codec.sequence.child) },
            .record => blk: {
                var entry = key;
                entry.record_entry = true;
                break :blk .{ .record = try p.get(role, entry) };
            },
        };
    }

    const Lifetime = struct {
        ownership: parts.WireOwnership = .plain,
        requires_scope: bool = false,

        fn merge(left: Lifetime, right: Lifetime) Lifetime {
            return .{
                .ownership = left.ownership.merge(right.ownership),
                .requires_scope = left.requires_scope or right.requires_scope,
            };
        }
    };

    fn childLifetime(p: *const Planner, id: anytype) Lifetime {
        const child = p.n.get(id);
        return .{ .ownership = child.ownership, .requires_scope = child.requires_scope };
    }

    fn lifetime(p: *const Planner, comptime role: ir.Role, representation: ir.Representation(role)) Lifetime {
        const borrowed: Lifetime = .{ .ownership = .borrowed };
        const scoped: Lifetime = .{ .ownership = .borrowed, .requires_scope = true };
        const transferred: Lifetime = .{ .ownership = .transfer };
        return switch (representation) {
            .converted => |conversion| p.childLifetime(conversion.apiValue()),
            .optional => |child| p.childLifetime(child),
            inline .dictionary, .union_type => |fields| aggregate: {
                var result: Lifetime = .{};
                for (fields) |field| result = result.merge(p.childLifetime(field.value));
                break :aggregate result;
            },
            .record_entry => |entry| p.childLifetime(entry.key).merge(p.childLifetime(entry.value)),
            inline .sequence, .record, .rest => |child| .{
                .ownership = if (role == .inbound_argument or role == .outbound_argument) .borrowed else .transfer,
                .requires_scope = role == .inbound_argument or p.n.get(child).requires_scope,
            },
            .leaf => |leaf| switch (role) {
                .inbound_argument => switch (leaf) {
                    .void, .scalar, .enumeration => .{},
                    .nominal_borrow, .nominal_owned => borrowed,
                    .js_value_view, .string_view, .bytes_view, .native_slice_view, .byte_lease, .callback_view, .class_view, .external_view, .native_receiver, .lazy_field, .lazy_view, .lazy_rest => scoped,
                },
                .inbound_result => switch (leaf) {
                    .void, .scalar, .enumeration => .{},
                    .nominal_borrow => borrowed,
                    .js_value_result => scoped,
                    .string_owned, .utf8_owned, .bytes_owned, .lease_owned, .callback_owned, .class_owned, .external_owned, .nominal_owned, .native_instance => transferred,
                },
                .outbound_argument => switch (leaf) {
                    .scalar, .enumeration => .{},
                    .string_operand, .string_owned, .bytes_operand, .native_slice, .nominal_borrow, .nominal_owner_borrow, .nominal_owned => borrowed,
                    .js_value_operand, .js_value_result, .callback_view, .class_view, .lazy_operand => scoped,
                },
                .outbound_result => switch (leaf) {
                    .void, .scalar, .enumeration => .{},
                    .nominal_borrow => borrowed,
                    .js_value_result => scoped,
                    .string_owned, .bytes_owned, .nominal_owned => transferred,
                    .callback_result, .class_result => .{ .ownership = .transfer, .requires_scope = true },
                },
            },
        };
    }

    pub fn supports(p: *const Planner, id: ir.TypeId, comptime role: ir.Role, native_heap: bool) bool {
        return switch (p.n.irType(id).data) {
            .converted => |converted| p.supports(converted.native_type, role, native_heap),
            .optional => |optional| p.supports(optional.child, role, native_heap),
            .dictionary => |dictionary| for (dictionary.dictionary_fields) |field| {
                if (!p.supports(field.field_type, role, native_heap)) break false;
            } else true,
            .union_type => |union_type| for (union_type.union_members) |member| {
                if (!p.supports(member.member_type, role, native_heap)) break false;
            } else true,
            .sequence => |sequence| p.supports(sequence.child, role, true),
            .record => |record| p.supports(record.key_type, role, true) and p.supports(record.value_type, role, true),
            .lazy => |child| role == .inbound_argument and p.supports(child, role, native_heap),
            .native_instance => false,
            .utf8_string => role == .inbound_result,
            .node_path, .native_slice => role == .inbound_argument,
            .any, .engine_value, .branded_value => role == .inbound_argument or !native_heap,
            .void, .boolean, .discarded, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64, .dom_string, .usv_string, .byte_string, .buffer, .callback, .nominal_handle, .class_ref, .external_ref, .enumeration => true,
        };
    }
};
