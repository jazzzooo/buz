const mod_positions = @import("positions.zig");
const mod_plans = @import("plans.zig");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const Positions = mod_positions.Planner;
const Error = normalize.Error;

pub const Planner = struct {
    positions: *Positions,

    fn forward(p: *Planner, id: ir.InboundArgumentPlanId) Error!ir.OutboundArgumentPlanId {
        const value = p.positions.n.get(id).*;
        return p.positions.get(.outbound_argument, .{
            .input = value.input,
            .transfer = value.transfer,
            .stored = value.stored,
            .native_heap = value.native_heap,
            .record_entry = value.record_entry,
            .native_class = value.native_class,
        });
    }

    fn storage(p: *Planner, id: anytype, comptime role: ir.Role) Error!role.PlanId() {
        const n = p.positions.n;
        const position = n.get(id).*;
        return p.positions.get(role, .{
            .input = if (role == .inbound_argument and mod_plans.inputFacts(n, position.input).contains_lazy_conversion) position.input else n.typePlans(position.type).input_plans[@backingInt(ir.Profile.exact)],
            .record_entry = position.representation == .record_entry,
            .stored = role == .inbound_result,
        });
    }

    fn intern(p: *Planner, value: ir.ApiType) Error!ir.ApiTypeId {
        const n = p.positions.n;
        return .of((try n.api_types.getOrPut(n.arena, value)).index);
    }

    fn children(p: *Planner, values: anytype) Error![]const ir.ApiTypeId {
        const normalized = try p.positions.n.arena.alloc(ir.ApiTypeId, values.len);
        for (values, normalized) |value, *output| output.* = try p.get(value.value);
        return normalized;
    }

    fn collection(p: *Planner, id: anytype, child: @TypeOf(id)) Error!ir.ApiType.Collection {
        const n = p.positions.n;
        const position = n.get(id).*;
        return switch (@TypeOf(id).role) {
            .inbound_argument => .{ .view = .{ .element = try p.storage(child, .inbound_argument), .source = try p.storage(id, .inbound_argument) } },
            .outbound_argument => .{ .slice = .{ .element = try p.get(child), .mutable = position.ownership == .transfer } },
            .inbound_result, .outbound_result => result: {
                if (@TypeOf(id).role == .outbound_result) if (n.get(child).requires_scope)
                    break :result .{ .scoped = .{ .owner = try p.storage(id, .inbound_result), .wire = position.wire } };
                break :result .{ .owned = .{ .element = try p.storage(child, .inbound_result), .wire = position.wire } };
            },
        };
    }

    pub fn get(p: *Planner, id: anytype) Error!ir.ApiTypeId {
        const n = p.positions.n;
        const position = n.get(id).*;
        if (position.api) |api| return api;
        const representation: @FieldType(ir.ApiType, "representation") = switch (position.representation) {
            .converted => |conversion| {
                const api = try p.get(conversion.apiValue());
                n.planList(@TypeOf(id).role).items[id.index].api = api;
                return api;
            },
            .optional => |child| .{ .optional = try p.get(child) },
            .dictionary => |fields| .{ .dictionary = .{
                .fields = try p.children(fields),
                .system_error = (@TypeOf(id).role == .inbound_result or @TypeOf(id).role == .outbound_result) and n.type_metadata.items[position.type.index].is_system_error_payload,
            } },
            .union_type => |members| .{ .union_type = try p.children(members) },
            .record_entry => |entry| .{ .record_entry = .{
                .key = try p.get(entry.key),
                .value = try p.get(entry.value),
                .cleanup = if (@TypeOf(id).role == .outbound_result) .{ .scoped = id } else if (position.ownership == .transfer) .{ .owned = try p.storage(id, .inbound_result) } else .none,
            } },
            .sequence => |child| .{ .sequence = try p.collection(id, child) },
            .record => |child| .{ .record = try p.collection(id, child) },
            inline .rest => |child| .{ .rest = switch (@TypeOf(id).role) {
                .inbound_argument => .{ .view = child },
                .outbound_argument => .{ .slice = .{ .element = try p.get(child), .mutable = position.ownership == .transfer } },
                .inbound_result, .outbound_result => @compileError("results have no rest representation"),
            } },
            .leaf => |leaf| switch (@TypeOf(id).role) {
                .inbound_argument => switch (leaf) {
                    .native_receiver => |class| .{ .native = class },
                    .lazy_view => |deferred| lazy: {
                        const symbol = try n.lazyCallSymbol(deferred);
                        break :lazy .{ .lazy_view = .{ .symbol = symbol, .deferred = deferred, .forward = try p.forward(id), .result_wire = try n.wires.?.deferredResult(symbol, deferred.value) } };
                    },
                    .lazy_rest => |deferred| lazy: {
                        const symbol = try n.lazyCallSymbol(deferred);
                        break :lazy .{ .lazy_rest = .{ .symbol = symbol, .deferred = deferred, .result_wire = try n.wires.?.deferredResult(symbol, deferred.value) } };
                    },
                    .lazy_field => |child| .{ .lazy_field = .{
                        .symbol = try n.lazyFieldSymbol(id),
                        .value = child,
                        .forward = try p.forward(id),
                        .protocol = id,
                    } },
                    inline else => |payload, tag| @unionInit(@FieldType(ir.ApiType, "representation"), @tagName(tag), payload),
                },
                .inbound_result => switch (leaf) {
                    .native_instance => |class| .{ .native = class },
                    inline else => |payload, tag| @unionInit(@FieldType(ir.ApiType, "representation"), @tagName(tag), payload),
                },
                .outbound_argument => switch (leaf) {
                    .lazy_operand => |lazy| .{ .lazy_operand = lazy.protocol },
                    inline else => |payload, tag| @unionInit(@FieldType(ir.ApiType, "representation"), @tagName(tag), payload),
                },
                .outbound_result => switch (leaf) {
                    .callback_result => .callback_view,
                    .class_result => .class_view,
                    inline else => |payload, tag| @unionInit(@FieldType(ir.ApiType, "representation"), @tagName(tag), payload),
                },
            },
        };
        const api = try p.intern(.{ .type = position.type, .representation = representation });
        n.planList(@TypeOf(id).role).items[id.index].api = api;
        return api;
    }
};
