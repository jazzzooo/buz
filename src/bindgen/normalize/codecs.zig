const std = @import("std");
const mod_plans = @import("plans.zig");
const mod_positions = @import("positions.zig");
const ir = @import("bindgen_ir");
const InputPlanId = mod_plans.InputPlanId;
const normalize = @import("../normalize.zig");
const Positions = mod_positions.Planner;
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

pub fn build(p: *Positions, comptime role: ir.Role, input: InputPlanId, representation: ir.Representation(role), transfer: bool) Error!ir.ZigPlan(role) {
    const builder: Builder(role) = .{ .n = p.n, .type = p.n.input_plans.items[input.index].type, .representation = representation, .transfer = transfer };
    const leaf = builder.leaf();
    const effects = builder.effects(leaf);
    var result: ir.ZigPlan(role) = undefined;
    inline for (@typeInfo(ir.ZigPlan(role)).@"struct".field_names) |name| {
        @field(result, name) = if (comptime std.mem.eql(u8, name, "leaf"))
            leaf
        else if (comptime std.mem.eql(u8, name, "destruction"))
            .{ .api = effects.destroy_api, .wire = effects.release_wire }
        else if (@hasField(@TypeOf(effects), name))
            @field(effects, name)
        else if (comptime std.mem.eql(u8, name, "clone"))
            try clone(p, input, representation)
        else
            @compileError("unhandled Zig plan field: " ++ name);
    }
    return result;
}

fn Builder(comptime role: ir.Role) type {
    return struct {
        const Self = @This();
        n: *const Normalizer,
        type: ir.TypeId,
        representation: ir.Representation(role),
        transfer: bool,

        fn leaf(p: *const Self) ?ir.ZigLeaf(role) {
            const value = switch (p.representation) {
                .leaf => |leaf_value| leaf_value,
                else => return null,
            };
            return switch (role) {
                .inbound_argument => switch (value) {
                    .void => .{ .decode = .void },
                    .scalar => |kind| .{ .decode = .{ .scalar = kind } },
                    .enumeration => .{ .decode = .enumeration },
                    .js_value_view, .callback_view, .class_view, .byte_lease, .lazy_field, .lazy_view, .lazy_rest => .{ .decode = .scoped_view },
                    .string_view, .bytes_view, .native_slice_view, .external_view => .{ .decode = .token_view },
                    .nominal_owned => |owner| p.adoptedOwner(.{ .release_handle = owner }),
                    .nominal_borrow, .native_receiver => .{ .decode = .pointer },
                },
                .inbound_result => switch (value) {
                    .void => .{ .encode = .void, .decode = .void },
                    .scalar => |kind| .{ .encode = .{ .scalar = kind }, .decode = .{ .scalar = kind } },
                    .enumeration => .{ .encode = .enumeration, .decode = .enumeration },
                    .js_value_result => |kind| .{ .encode = .value_result, .decode = .{ .value_result = kind } },
                    .string_owned => p.adoptedOwner(.string),
                    .utf8_owned, .bytes_owned => p.adoptedOwner(.bytes),
                    .lease_owned => p.adoptedOwner(.{ .release_handle = .byte_lease }),
                    .callback_owned => .{ .encode = .take_wire, .decode = .adopt_scoped, .destroy = .deinit, .release = .root },
                    .class_owned => .{ .encode = .take_wire, .decode = .adopt_scoped, .destroy = .deinit, .release = .class_ref },
                    .external_owned => p.adoptedOwner(.{ .release_handle = .{ .external = p.n.irType(p.type).data.external_ref } }),
                    .nominal_owned => |owner| p.adoptedOwner(.{ .release_handle = .{ .nominal = owner } }),
                    .nominal_borrow => .{ .encode = .nominal_handle, .decode = .pointer },
                    .native_instance => |class| .{
                        .encode = .pointer,
                        .decode = .pointer,
                        .destroy = .{ .native_instance = class },
                        .release = .{ .release_handle = .{ .native = class } },
                    },
                },
                .outbound_argument => switch (value) {
                    .scalar => |kind| .{ .encode = .{ .scalar = kind } },
                    .enumeration => .{ .encode = .enumeration },
                    .js_value_operand => .{ .encode = .value_operand },
                    .js_value_result => .{ .encode = .value_result },
                    .callback_view, .class_view, .lazy_operand => .{ .encode = .scoped_handle },
                    .string_operand, .bytes_operand, .nominal_owner_borrow => .{ .encode = .borrow_wire },
                    .string_owned => .{ .encode = .borrow_wire, .destroy = .deinit },
                    .nominal_owned => |owner| .{ .encode = .borrow_transfer_handle, .destroy = .deinit, .release = .{ .release_handle = owner } },
                    .nominal_borrow => .{ .encode = .nominal_handle },
                    .native_slice => .{ .encode = .native_slice },
                },
                .outbound_result => switch (value) {
                    .void => .{ .decode = .void },
                    .scalar => |kind| .{ .decode = .{ .scalar = kind } },
                    .enumeration => .{ .decode = .enumeration },
                    .js_value_result => |kind| .{ .decode = .{ .value_result = kind } },
                    .string_owned => p.adoptedOwner(.string),
                    .bytes_owned => p.adoptedOwner(.bytes),
                    .callback_result => .{ .decode = .borrow_callback, .release = .root },
                    .class_result => .{ .decode = .borrow_class, .release = .class_ref },
                    .nominal_owned => |owner| p.adoptedOwner(.{ .release_handle = owner }),
                    .nominal_borrow => .{ .decode = .pointer },
                },
            };
        }

        fn adoptedOwner(_: *const Self, release: ir.ZigWireRelease(role)) ir.ZigLeaf(role) {
            if (role == .inbound_result) return .{ .encode = .take_wire, .decode = .adopt_wire, .destroy = .deinit, .release = release };
            return .{ .decode = .adopt_wire, .destroy = .deinit, .release = release };
        }

        const Effects = struct {
            encode_allocates: bool = false,
            decode_allocates: bool = false,
            requires_realm: bool = false,
            destroy_api: bool = false,
            release_wire: bool = false,

            fn merge(left: Effects, right: Effects) Effects {
                var result: Effects = undefined;
                inline for (@typeInfo(Effects).@"struct".field_names) |name| {
                    @field(result, name) = @field(left, name) or @field(right, name);
                }
                return result;
            }
        };

        fn childEffects(p: *const Self, id: role.PlanId()) Effects {
            const child = p.n.get(id).zig;
            var result: Effects = .{
                .destroy_api = child.destruction.api,
                .release_wire = child.destruction.wire,
            };
            inline for (@typeInfo(Effects).@"struct".field_names) |name| {
                if (@hasField(@TypeOf(child), name)) @field(result, name) = @field(child, name);
            }
            return result;
        }

        fn effects(p: *const Self, leaf_: ?ir.ZigLeaf(role)) Effects {
            return switch (p.representation) {
                .converted => |conversion| p.childEffects(conversion.apiValue()),
                .optional => |child| p.childEffects(child),
                inline .dictionary, .union_type => |fields| aggregate: {
                    var result: Effects = .{};
                    for (fields) |field| result = result.merge(p.childEffects(field.value));
                    break :aggregate result;
                },
                .record_entry => |entry| p.childEffects(entry.key).merge(p.childEffects(entry.value)),
                inline .sequence, .record, .rest => |child| collection: {
                    const scoped = role == .outbound_result and p.n.get(child).requires_scope;
                    const borrowed = role == .inbound_argument or (role == .outbound_argument and !p.transfer);
                    break :collection .{
                        .encode_allocates = role == .outbound_argument,
                        .decode_allocates = scoped,
                        .requires_realm = role == .inbound_argument or scoped or p.childEffects(child).requires_realm,
                        .destroy_api = !borrowed and !scoped,
                        .release_wire = !borrowed,
                    };
                },
                .leaf => leaf: {
                    var result: Effects = switch (role) {
                        .inbound_argument => switch (leaf_.?.decode) {
                            .scoped_view => .{ .requires_realm = true },
                            .void, .scalar, .enumeration, .token_view, .adopt_wire, .pointer => .{},
                        },
                        .inbound_result => switch (leaf_.?.decode) {
                            .value_result => .{ .requires_realm = true },
                            .adopt_scoped => .{ .decode_allocates = true, .requires_realm = true },
                            .void, .scalar, .enumeration, .adopt_wire, .pointer => .{},
                        },
                        .outbound_result => switch (leaf_.?.decode) {
                            .value_result => .{ .requires_realm = true },
                            .borrow_callback, .borrow_class => .{ .decode_allocates = true, .requires_realm = true },
                            .void, .scalar, .enumeration, .adopt_wire, .pointer => .{},
                        },
                        .outbound_argument => .{},
                    };
                    result.destroy_api = leaf_.?.destroy != .none;
                    result.release_wire = leaf_.?.release != .none;
                    break :leaf result;
                },
            };
        }

    };
}

fn clone(p: *Positions, input: InputPlanId, representation: ir.Representation(.inbound_argument)) Error!?ir.ClonePlan {
    const t = p.n.irType(p.n.input_plans.items[input.index].type);
    if (!p.supports(t.id, .inbound_result, false)) return null;
    const target = try p.get(.inbound_result, .{
        .input = p.n.typePlans(t.id).input_plans[@backingInt(ir.Profile.exact)],
        .stored = true,
        .record_entry = representation == .record_entry,
    });
    var raises_exception = false;
    const leaf: @FieldType(ir.ClonePlan, "leaf") = switch (representation) {
        .converted => |conversion| converted: {
            raises_exception = (childClone(p, conversion.apiValue()) orelse return null).raises_exception;
            break :converted null;
        },
        .optional => |child| optional: {
            raises_exception = (childClone(p, child) orelse return null).raises_exception;
            break :optional null;
        },
        inline .dictionary, .union_type => |fields| aggregate: {
            for (fields) |field| {
                const child = childClone(p, field.value) orelse return null;
                raises_exception = raises_exception or child.raises_exception;
            }
            break :aggregate null;
        },
        .sequence, .record => |child| slice: {
            if (p.n.get(target).*.requires_scope) return null;
            raises_exception = (childClone(p, child) orelse return null).raises_exception;
            break :slice null;
        },
        .record_entry => |entry| record: {
            const key_clone = childClone(p, entry.key) orelse return null;
            const value_clone = childClone(p, entry.value) orelse return null;
            raises_exception = key_clone.raises_exception or value_clone.raises_exception;
            break :record null;
        },
        .rest => return null,
        .leaf => |value| switch (value) {
            .void, .scalar, .enumeration => .value,
            .nominal_borrow => if (t.data.nominal_handle.ownership == .owned) return null else .value,
            .js_value_view => .engine_value,
            .string_view => if (p.n.projection(t.id).string.?.thread_safe) .allocate else .retain,
            .external_view => .retain,
            .bytes_view, .byte_lease => .allocate,
            .callback_view, .class_view => allocated: {
                raises_exception = true;
                break :allocated .allocate;
            },
            .native_slice_view, .nominal_owned, .native_receiver, .lazy_field, .lazy_view, .lazy_rest => return null,
        },
    };
    return .{ .target = target, .raises_exception = raises_exception, .leaf = leaf };
}

fn childClone(p: *Positions, id: ir.InboundArgumentPlanId) ?ir.ClonePlan {
    return p.n.get(id).zig.clone;
}
