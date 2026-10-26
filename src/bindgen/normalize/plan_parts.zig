const mod_plans = @import("plans.zig");
const mod_cpp_codecs = @import("cpp_codecs.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const InputPlanId = mod_plans.InputPlanId;
const normalize = @import("../normalize.zig");

pub const WireOwnership = enum {
    plain,
    borrowed,
    transfer,

    pub fn merge(left: WireOwnership, right: WireOwnership) WireOwnership {
        if (left == .transfer or right == .transfer) return .transfer;
        if (left == .borrowed or right == .borrowed) return .borrowed;
        return .plain;
    }
};

pub fn Value(comptime role: ir.Role) type {
    return struct {
        pub const plan_role = role;

        api: ?ir.ApiTypeId = null,
        type: @FieldType(role.Plan(), "type"),
        input: InputPlanId,
        transfer: @FieldType(role.Plan(), "transfer"),
        stored: @FieldType(role.Plan(), "stored"),
        native_heap: @FieldType(role.Plan(), "native_heap"),
        record_entry: @FieldType(role.Plan(), "record_entry"),
        native_class: @FieldType(role.Plan(), "native_class"),
        representation: @FieldType(role.Plan(), "representation"),
        wire: @FieldType(role.Plan(), "wire"),
        ownership: WireOwnership,
        requires_scope: bool,
        zig: @FieldType(role.Plan(), "zig"),

        pub fn isVoid(value: *const @This()) bool {
            return if (role == .outbound_argument) false else (value.representation == .leaf and value.representation.leaf == .void);
        }
    };
}

pub fn assemble(n: *normalize.Normalizer, id: anytype, codecs: mod_cpp_codecs.Store(@TypeOf(id).role)) normalize.Error!@TypeOf(id).role.Plan() {
    const role = @TypeOf(id).role;
    const value = n.get(id).*;
    var emission: ir.CppPlan(role) = undefined;
    inline for (@typeInfo(ir.CppPlan(role)).@"struct".field_names) |name| {
        @field(emission, name) = if (@hasField(@TypeOf(codecs), name))
            @field(codecs, name).items
        else if (comptime std.mem.eql(u8, name, "release"))
            mod_cpp_codecs.release(n, id)
        else if (comptime std.mem.eql(u8, name, "decode"))
            mod_cpp_codecs.decodePlan(n, id)
        else if (comptime std.mem.eql(u8, name, "decoder_helper"))
            mod_cpp_codecs.decoderHelper(n, id)
        else if (comptime std.mem.eql(u8, name, "lazy_field"))
            if (n.cpp_input_state.lazy_fields.get(id)) |input| .{ .input = input, .symbol = try n.lazyFieldSymbol(id) } else null
        else
            @compileError("unhandled C++ plan field: " ++ name);
    }
    var result: role.Plan() = undefined;
    inline for (@typeInfo(role.Plan()).@"struct".field_names) |name| {
        @field(result, name) = if (comptime std.mem.eql(u8, name, "api"))
            value.api.?
        else if (comptime std.mem.eql(u8, name, "cpp"))
            emission
        else if (comptime std.mem.eql(u8, name, "typescript"))
            n.projection(value.type).inputTypeScript()
        else
            @field(value, name);
    }
    return result;
}

pub const Plans = struct {
    inbound_argument: []const ir.InboundArgumentPlan,
    inbound_result: []const ir.InboundResultPlan,
    outbound_argument: []const ir.OutboundArgumentPlan,
    outbound_result: []const ir.OutboundResultPlan,
};

pub fn finish(n: *normalize.Normalizer) normalize.Error!Plans {
    return .{
        .inbound_argument = try finishRole(n, .inbound_argument),
        .inbound_result = try finishRole(n, .inbound_result),
        .outbound_argument = try finishRole(n, .outbound_argument),
        .outbound_result = try finishRole(n, .outbound_result),
    };
}

fn finishRole(n: *normalize.Normalizer, comptime role: ir.Role) normalize.Error![]const role.Plan() {
    const result = try n.arena.alloc(role.Plan(), n.rolePlans(role).len);
    for (n.roleCodecs(role), result, 0..) |codecs, *complete, index| complete.* = try assemble(n, @as(role.PlanId(), .of(index)), codecs);
    return result;
}
