const std = @import("std");
const ir = @import("bindgen_ir");
const structural = @import("../structural.zig");
const Allocator = std.mem.Allocator;

pub fn canonicalize(arena: Allocator, source: ir.Ir) Allocator.Error!ir.Ir {
    var result = try structural.Graph(.{
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
        ir.CppTypeId,
        ir.CppBrandMatchId,
        ir.CppCodecFailureId,
        ir.CppDeclarationId,
        ir.CppConverterDeclarationId,
        ir.CppValueTestId,
        ir.CppImplementationId,
        ir.CppArgumentFrameId,
        ir.CppWireResultId,
        ir.CppCompletionApiId,
        ir.CppCompletionEncoderId,
        ir.CppRealmFunctionId,
        ir.CppNativeConstructionId,
        ir.CppDictionaryValueId,
    }).intern(arena, source);
    var declarations: std.AutoArrayHashMapUnmanaged(ir.CppInputAggregateId, void) = .empty;
    defer declarations.deinit(arena);
    for (result.cpp_input_declarations) |id| try declarations.put(arena, id, {});
    result.cpp_input_declarations = try arena.dupe(ir.CppInputAggregateId, declarations.keys());
    return result;
}

test "complete cyclic content determines identity across typed tables" {
    const Plan = ir.Id("plans");
    const Api = ir.Id("apis");
    const Source = struct {
        plans: []const struct { api: Api, transfer: bool, child: Plan },
        apis: []const struct { plan: Plan },
        roots: []const Plan,
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source: Source = .{
        .plans = &.{
            .{ .api = .of(0), .transfer = false, .child = .of(0) },
            .{ .api = .of(1), .transfer = false, .child = .of(1) },
            .{ .api = .of(2), .transfer = true, .child = .of(2) },
            .{ .api = .of(0), .transfer = false, .child = .of(2) },
        },
        .apis = &.{ .{ .plan = .of(0) }, .{ .plan = .of(1) }, .{ .plan = .of(2) } },
        .roots = &.{ .of(1), .of(2), .of(3) },
    };
    const result = try structural.Graph(.{ Plan, Api }).intern(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 3), result.plans.len);
    try std.testing.expectEqual(@as(usize, 2), result.apis.len);
    try std.testing.expectEqualSlices(Plan, &.{ .of(0), .of(1), .of(2) }, result.roots);
    try std.testing.expectEqual(Plan.of(0), result.plans[0].child);
    try std.testing.expectEqual(Plan.of(1), result.plans[1].child);
    try std.testing.expectEqual(Plan.of(1), result.plans[2].child);
    try std.testing.expectEqual(Plan.of(1), result.apis[1].plan);
    try std.testing.expect(structural.eql(result, try structural.Graph(.{ Plan, Api }).intern(arena.allocator(), result)));
}
