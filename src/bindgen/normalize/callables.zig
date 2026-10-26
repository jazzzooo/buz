//! Callables: arguments, call plans, overload dispatch, domain errors, and
//! the functions, engine shims, native exports, and callbacks built on them.
const std = @import("std");
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const types = @import("types.zig");
const plans = @import("plans.zig");
const structural = @import("../structural.zig");
const Normalizer = normalize.Normalizer;
const Declared = normalize.Declared;
const Error = normalize.Error;

pub const RestMode = enum {
    none,
    values,
    count,
};

pub const ArgumentInputOperation = enum { convert, prepare_buffer, prepare_object_or_string, prepare_selected };
pub const ArgumentInputStep = struct { operation: ArgumentInputOperation, argument_index: u32 };
pub const ArgumentSelectionMember = struct { member_index: u32, values: []const u32 };
pub const ArgumentSelectionPlan = struct { source_index: u32, source_name: []const u8, selector: ir.EnumerationId, members: []const ArgumentSelectionMember };
pub const Arity = struct { minimum: u32, failure: ?@FieldType(ir.CppRequiredArgumentCheck, "failure") };
const CallFrame = struct { converter_receiver: bool };
pub const CallInputs = struct { arguments: []const schema.Argument, program: []const ArgumentInputStep, prepared_sources: []const bool, arity: Arity, frame: CallFrame };

pub const OverloadCaseDispatchPlan = struct {
    is_fallback: bool = false,
    minimum_argument_count: u32,
    maximum_argument_count: ?usize,
};

pub const OverloadComparisonPlan = struct {
    active: bool = false,
    overlap_minimum: usize = 0,
    overlap_maximum: ?usize = null,
    differing_argument_indices: []const usize = &.{},
};

pub const OverloadDispatch = struct {
    input_slot_count: u32,
    argument_count: ir.OverloadArgumentCount,
    minimum_required_case_index: u32,
    case_plans: []const OverloadCaseDispatchPlan,
    /// Row-major `[case][other case]`.
    comparison_plans: []const OverloadComparisonPlan,
};

pub fn normalizeAll(n: *Normalizer) Error!void {
    for (n.declared_engine_shims.items) |declared| {
        try n.engine_shims.append(n.arena, try engineShim(n, declared));
    }
    const callback_calls = try n.arena.alloc(ir.OutboundCall, n.callbacks.items.len);
    for (n.callbacks.items, callback_calls) |callback, *call| call.* = try callbackCall(n, callback.type);
    n.callback_calls = callback_calls;
    try n.functions.ensureTotalCapacity(n.arena, n.declared_functions.items.len);
    for (n.declared_functions.items, 0..) |declared, index| {
        n.functions.appendAssumeCapacity(try function(n, declared, .of(index), null));
    }
    for (n.declared_native_exports.items, 0..) |declared, index| {
        try n.native_exports.append(n.arena, try nativeExport(n, declared, .of(index)));
    }
}

fn qualified(n: *Normalizer, module_name: []const u8, name: []const u8) Error![]const u8 {
    return n.print("{s}_{s}", .{ module_name, name });
}

// ─── arguments ───

pub const ArgumentSource = struct {
    index: ?u32,
    presence: ir.Presence,
    missing: ir.Missing,
    name: []const u8,
};

pub fn argumentSource(arguments: []const schema.Argument, argument_index: usize) ArgumentSource {
    const raw = arguments[argument_index];
    const source_name = if (raw.options.source) |source| switch (source) {
        .argument => |name| name,
        .this_value => return .{ .index = null, .presence = .required, .missing = .undefined, .name = "this" },
        .cached_slot => |name| return .{ .index = null, .presence = .required, .missing = .undefined, .name = name },
    } else raw.name;
    var positional: u32 = 0;
    for (arguments[0 .. argument_index + 1]) |argument| {
        if (argument.options.source != null) continue;
        if (std.mem.eql(u8, argument.name, source_name)) return .{
            .index = positional,
            .presence = argument.options.presence,
            .missing = argument.options.missing,
            .name = source_name,
        };
        positional += 1;
    }
    unreachable;
}

/// An argument as normalization sees it: declared, or synthesized for a
/// receiver or a deferred value.
const ArgumentSpec = struct {
    name: []const u8,
    type: schema.Type,
    rest_type: ?schema.Type = null,
    conversion: struct {
        presence: ir.Presence,
        scalar: schema.ValueConversionOptions,
        rest_mode: RestMode,
    },
    ownership: ir.ArgumentOwnership = .borrowed,
    source: ?ir.ArgumentProjectionSource = null,
};

fn specOf(n: *Normalizer, argument: schema.Argument) Error!ArgumentSpec {
    const effective = normalize.effectiveArgumentType(argument);
    const options = argument.options;
    return .{
        .name = argument.name,
        .type = effective,
        .rest_type = try normalize.argumentRestType(n, argument),
        .conversion = .{
            .presence = options.presence,
            .scalar = plans.conversionOf(options.boolean_conversion, options.integer_conversion, options.number_conversion),
            .rest_mode = if (!options.rest) .none else if (effective == .discarded) .count else .values,
        },
        .ownership = options.ownership,
        .source = options.source,
    };
}

fn syntheticSpec(name: []const u8, t: schema.Type, conversion: schema.ValueConversionOptions) ArgumentSpec {
    return .{
        .name = name,
        .type = t,
        .conversion = .{
            .presence = .required,
            .scalar = conversion,
            .rest_mode = .none,
        },
    };
}

fn argumentWith(
    n: *Normalizer,
    comptime role: ir.Role,
    spec: ArgumentSpec,
    profile: ir.Profile,
    call: ?ir.DeferredCall,
    stored: bool,
) Error!ir.Argument(role) {
    const type_id = try types.ensure(n, spec.type);
    const rest_type = if (spec.rest_type) |rest| try types.ensure(n, rest) else null;
    const conversion = spec.conversion.scalar;
    const value = try plans.inputPlan(n, type_id, profile, conversion);
    const rest = if (rest_type) |rest| try plans.inputPlan(n, rest, profile, conversion) else null;
    const deferred: ?ir.InboundArgumentPlanId = if (role == .inbound_argument) switch (spec.type) {
        .lazy => |child| try storedArgumentPosition(n, syntheticSpec(spec.name, child.*, conversion), profile),
        else => null,
    } else null;
    const crossing = try n.positions.?.planArgument(role, .{
        .input = .{ .value = value, .rest = rest },
        .rest_mode = spec.conversion.rest_mode,
        .ownership = spec.ownership,
        .deferred = if (deferred) |id| if (call) |site| .{ .value = id, .call = site } else null else null,
        .stored = stored,
    });
    return .{
        .position = crossing.position,
        .rest_position = crossing.rest_position,
        .argument_name = spec.name,
        .is_projection = spec.source != null,
        .conversion = .{
            .presence = spec.conversion.presence,
            .rest = spec.conversion.rest_mode != .none,
        },
    };
}

fn storedArgumentPosition(n: *Normalizer, spec: ArgumentSpec, profile: ir.Profile) Error!ir.InboundArgumentPlanId {
    return (try argumentWith(n, .inbound_argument, spec, profile, null, true)).position;
}

pub fn receiverArgument(n: *Normalizer, comptime role: ir.Role, name: []const u8, t: schema.Type, profile: ir.Profile) Error!ir.Argument(role) {
    return argumentWith(n, role, syntheticSpec(name, t, .{}), profile, null, false);
}

const ArgumentOwner = struct { declaration: ir.DeclarationRef, overload_index: ?u32 = null };

pub fn normalizeArguments(n: *Normalizer, comptime role: ir.Role, arguments: []const schema.Argument, profile: ir.Profile, owner: ?ArgumentOwner) Error![]const ir.Argument(role) {
    const normalized = try n.arena.alloc(ir.Argument(role), arguments.len);
    for (arguments, normalized, 0..) |argument, *result, index| {
        result.* = try argumentWith(n, role, try specOf(n, argument), profile, if (owner) |site| .{ .declaration = site.declaration, .overload_index = site.overload_index, .argument_index = @intCast(index) } else null, false);
    }
    return normalized;
}

pub fn countRequired(arguments: []const schema.Argument) u32 {
    var count: u32 = 0;
    for (arguments) |argument| {
        if (argument.options.source != null) continue;
        if (argument.options.rest) break;
        if (argument.options.presence != .required) break;
        count += 1;
    }
    return count;
}

// ─── results and domain errors ───

pub fn domainErrors(n: *Normalizer, declarations: []const schema.DomainError) Error![]const ir.DomainErrorId {
    const errors = try n.arena.alloc(ir.DomainErrorId, declarations.len);
    for (declarations, errors) |declaration, *id| {
        const payload = try types.ensure(n, declaration.payload);
        const position = try n.positions.?.value(.inbound_result, payload, null, null);
        const factory = try n.domain_error_factory_index.getOrPut(n.arena, .{ .payload = position, .declaration = declaration.declaration });
        if (!factory.found_existing) factory.value_ptr.* = @intCast(n.domain_error_factory_index.count() - 1);
        id.* = .of(n.domain_errors.items.len);
        try n.domain_errors.append(n.arena, .{
            .position = position,
            .error_name = declaration.name,
        });
        try n.domain_error_inputs.append(n.arena, .{ .declaration = declaration.declaration, .factory = factory.value_ptr.* });
    }
    return errors;
}

// ─── call plans ───

const CallArgumentFacts = struct {
    facts: plans.InputFacts = .{},
    transfers_ownership: bool = false,

    fn add(call: *CallArgumentFacts, n: *const Normalizer, argument: anytype) void {
        call.facts = plans.mergeFacts(call.facts, plans.inputFacts(n, n.get(argument.position).input));
        call.transfers_ownership = call.transfers_ownership or n.get(argument.position).transfer;
    }
};

pub fn CallOptions(comptime role: ir.Role) type {
    return struct {
        realm: ir.EngineRealm = .current,
        throws: ir.NativeThrows = .js_exception,
        non_returning: bool = false,
        receiver: ?role.PlanId() = null,
        callee: ?role.PlanId() = null,
        checks_traps: bool = true,
    };
}

pub fn callPlan(
    n: *const Normalizer,
    comptime role: ir.Role,
    arguments: []const ir.Argument(role),
    result_position: if (role == .outbound_argument) ir.OutboundResultPlanId else void,
    invocation_arguments: []const ?ir.Argument(role),
    options: CallOptions(role),
) struct { plan: ir.CallPlan(role), frame: CallFrame } {
    var call: CallArgumentFacts = .{};
    for (arguments) |argument| {
        call.add(n, argument);
    }
    for (invocation_arguments) |maybe| if (maybe) |argument| {
        call.add(n, argument);
    };
    const lease_bit: u8 = 1 << 1;
    return .{
        .plan = if (role == .inbound_argument) .{
            .realm = options.realm,
            .throws = options.throws,
            .non_returning = options.non_returning,
            .receiver = options.receiver,
            .has_lazy_conversion = call.facts.contains_lazy_conversion,
            .has_lazy_arguments = for (arguments) |argument| {
                if (plans.codecOf(n, n.get(argument.position).input) == .lazy) break true;
            } else false,
            .acquires_byte_lease = call.facts.effective_buffer_mode_mask & lease_bit != 0,
            .transfers_argument_ownership = call.transfers_ownership,
        } else .{
            .realm = options.realm,
            .throws = options.throws,
            .receiver = options.receiver,
            .callee = options.callee,
            .requires_scope = scope: {
                if (n.get(result_position).requires_scope) break :scope true;
                for (arguments) |argument| if (n.get(argument.valuePosition()).requires_scope) break :scope true;
                for ([_]?ir.OutboundArgumentPlanId{ options.receiver, options.callee }) |maybe| {
                    if (maybe) |id| if (n.get(id).requires_scope) break :scope true;
                }
                break :scope false;
            },
            .transfers_argument_ownership = call.transfers_ownership,
            .checks_traps = options.checks_traps,
        },
        .frame = .{ .converter_receiver = call.facts.contains_call_receiver_conversion },
    };
}

pub fn selectionPlan(n: *Normalizer, arguments: anytype, index: usize, request: ir.ArgumentSelection) std.mem.Allocator.Error!ArgumentSelectionPlan {
    const source_index = for (arguments, 0..) |source, source_position| {
        if (std.mem.eql(u8, source.argument_name, request.source)) break source_position;
    } else unreachable;
    const selector = n.irType(n.get(arguments[source_index].position).type).data.enumeration;
    const selector_values = n.get(selector).enumeration_values;
    const value_plan = plans.plan(n, n.get(arguments[index].position).input);
    const members = n.irType(value_plan.type).data.union_type.union_members;
    const selection_members = try n.arena.alloc(ArgumentSelectionMember, members.len);
    for (members, selection_members, 0..) |member, *selected, member_index| {
        var values: std.ArrayList(u32) = .empty;
        for (request.cases) |case| {
            if (!std.mem.eql(u8, case.member, member.member_name)) continue;
            for (selector_values, 0..) |value, value_index| {
                if (std.mem.eql(u8, case.value, value.value_name)) try values.append(n.arena, @intCast(value_index));
            }
        }
        selected.* = .{ .member_index = @intCast(member_index), .values = values.items };
    }
    return .{
        .source_index = @intCast(source_index),
        .source_name = arguments[source_index].argument_name,
        .selector = selector,
        .members = selection_members,
    };
}

fn callInputs(n: *Normalizer, location: []const u8, arguments: []const ir.Argument(.inbound_argument), raw: []const schema.Argument, declared: ?[]const ir.ConversionStep, frame: CallFrame, arity: Arity) Error!CallInputs {
    const program = try inputProgram(n, location, arguments, raw, declared);
    const prepared_sources = try n.arena.alloc(bool, arguments.len);
    @memset(prepared_sources, false);
    for (program) |step| if (step.operation != .convert) {
        const source = argumentSource(raw, step.argument_index).index orelse return n.reject(location, "argument preparation requires a source position", .{});
        prepared_sources[source] = true;
    };
    return .{ .arguments = raw, .program = program, .prepared_sources = prepared_sources, .arity = arity, .frame = frame };
}

fn inputProgram(n: *Normalizer, location: []const u8, arguments: anytype, raw: []const schema.Argument, declared: ?[]const ir.ConversionStep) Error![]const ArgumentInputStep {
    const steps = declared orelse {
        const program = try n.arena.alloc(ArgumentInputStep, arguments.len);
        for (program, 0..) |*step, index| step.* = .{ .operation = .convert, .argument_index = @intCast(index) };
        return program;
    };
    const program = try n.arena.alloc(ArgumentInputStep, steps.len);
    const Preparation = enum { none, requested, ready };
    const preparation = try n.arena.alloc(Preparation, arguments.len);
    const converted = try n.arena.alloc(bool, arguments.len);
    @memset(preparation, .none);
    @memset(converted, false);
    for (steps) |step| if (step == .prepare) {
        for (arguments, 0..) |argument, index| {
            if (std.mem.eql(u8, step.prepare, argument.argument_name)) {
                const source = argumentSource(raw, index).index orelse continue;
                preparation[source] = .requested;
            }
        }
    };
    for (steps, program) |step, *output| {
        const name = switch (step) {
            inline else => |value| value,
        };
        const index = for (arguments, 0..) |argument, candidate| {
            if (std.mem.eql(u8, name, argument.argument_name)) break candidate;
        } else return n.reject(location, "conversion program names an unknown argument: {s}", .{name});
        const argument = arguments[index];
        const value = plans.plan(n, n.get(argument.position).input);
        if (raw[index].options.selection) |selection| {
            for (arguments, 0..) |source, source_index| {
                if (std.mem.eql(u8, source.argument_name, selection.source) and !converted[source_index])
                    return n.reject(location, "union selection precedes conversion of its selector", .{});
            }
        }
        if (converted[index]) return n.reject(location, "conversion program uses an already converted argument: {s}", .{name});
        const operation: ArgumentInputOperation = switch (step) {
            .convert => blk: {
                if (argument.is_projection) if (argumentSource(raw, index).index) |source| {
                    if (preparation[source] == .requested) return n.reject(location, "projection precedes preparation of its source: {s}", .{name});
                };
                converted[index] = true;
                break :blk .convert;
            },
            .prepare => blk: {
                const source = argumentSource(raw, index).index;
                if (source == null or argument.is_projection or argument.conversion.rest or argument.conversion.presence != .required or preparation[source.?] == .ready)
                    return n.reject(location, "preparation requires an unprepared, required positional argument: {s}", .{name});
                preparation[source.?] = .ready;
                if (raw[index].options.selection != null) break :blk .prepare_selected;
                const projection = n.projection(value.type);
                if (value.codec == .buffer and projection.buffer.?.effective_mode == .copy and projection.buffer.?.access == .read_only)
                    break :blk .prepare_buffer;
                if (value.codec == .union_type) if (n.rawType(value.type).union_type.options.input_tag) |tag| {
                    if (tag.string_shorthand) break :blk .prepare_object_or_string;
                };
                return n.reject(location, "argument type does not support staged conversion: {s}", .{name});
            },
        };
        output.* = .{ .operation = operation, .argument_index = @intCast(index) };
    }
    for (arguments, 0..) |argument, index| {
        if (!converted[index]) return n.reject(location, "conversion program omits argument: {s}", .{argument.argument_name});
    }
    return program;
}

// ─── overload dispatch ───

fn caseHasRest(case: *const ir.Function) bool {
    return case.args.len > 0 and case.args[case.args.len - 1].conversion.rest;
}

fn caseArgumentAt(case: *const ir.Function, index: usize) ?ir.Argument(.inbound_argument) {
    if (index < case.args.len) return case.args[index];
    return if (caseHasRest(case)) case.args[case.args.len - 1] else null;
}

fn overloadDispatch(n: *Normalizer, cases: []const *const ir.Function, profile: ir.Profile, declaration: schema.Overloads) Error!OverloadDispatch {
    const accepts_extra = declaration.options.accept_extra_arguments;
    const fallback_index: ?usize = if (declaration.options.fallback_case != null) cases.len - 1 else null;
    const clamps = profile == .webidl and accepts_extra and for (cases) |case| {
        if (caseHasRest(case)) break false;
    } else true;
    var maximum_count: u32 = 0;
    for (cases) |case| maximum_count = @max(maximum_count, @as(u32, @intCast(case.args.len)));
    const case_plans = try n.arena.alloc(OverloadCaseDispatchPlan, cases.len);
    var minimum_index: u32 = 0;
    var minimum: u32 = std.math.maxInt(u32);
    for (cases, case_plans, 0..) |case, *case_plan, index| {
        const inputs = n.declaration(case.id).inputs;
        if (inputs.arity.minimum < minimum) {
            minimum = inputs.arity.minimum;
            minimum_index = @intCast(index);
        }
        case_plan.* = .{
            .is_fallback = fallback_index == index,
            .minimum_argument_count = inputs.arity.minimum,
            .maximum_argument_count = if ((accepts_extra and !clamps) or caseHasRest(case)) null else case.args.len,
        };
    }
    const comparisons = try n.arena.alloc(OverloadComparisonPlan, std.math.mul(usize, cases.len, cases.len) catch return error.OutOfMemory);
    @memset(comparisons, .{});
    for (cases, declaration.cases, 0..) |case, raw, case_index| {
        if (case_plans[case_index].is_fallback) continue;
        for (cases, 0..) |other, other_index| {
            if (case_index == other_index) continue;
            const overlap_minimum = @max(case_plans[case_index].minimum_argument_count, case_plans[other_index].minimum_argument_count);
            const overlap_maximum = minimumMaximum(case_plans[case_index].maximum_argument_count, case_plans[other_index].maximum_argument_count);
            if (overlap_maximum) |maximum| if (overlap_minimum > maximum) continue;
            const differing = raw.options.discriminants orelse try differenceIndices(n, case, other);
            if (differing.len == 0) continue;
            comparisons[case_index * cases.len + other_index] = .{
                .active = true,
                .overlap_minimum = overlap_minimum,
                .overlap_maximum = overlap_maximum,
                .differing_argument_indices = differing,
            };
        }
    }
    return .{
        .input_slot_count = maximum_count,
        .argument_count = if (clamps) .{ .clamped = maximum_count } else .call_frame,
        .minimum_required_case_index = minimum_index,
        .case_plans = case_plans,
        .comparison_plans = comparisons,
    };
}

fn minimumMaximum(left: ?usize, right: ?usize) ?usize {
    if (left) |l| return if (right) |r| @min(l, r) else l;
    return right;
}

fn differenceIndices(n: *Normalizer, left: *const ir.Function, right: *const ir.Function) Error![]const usize {
    var indexes: std.ArrayList(usize) = .empty;
    for (0..@max(left.args.len, right.args.len)) |index| {
        const left_argument = caseArgumentAt(left, index) orelse continue;
        const right_argument = caseArgumentAt(right, index) orelse continue;
        if (n.get(left_argument.position).type.index == n.get(right_argument.position).type.index) continue;
        try indexes.append(n.arena, index);
    }
    return indexes.items;
}

// ─── functions ───

pub fn function(n: *Normalizer, declared: Declared, function_id: ir.FunctionId, overload_case_index: ?usize) Error!ir.Function {
    const options = declared.options;
    const overloads: ?schema.Overloads = switch (declared.arguments) {
        .overloads => |overloads| overloads,
        .list => null,
    };
    const overload_case: ?schema.OverloadCase = if (overload_case_index) |index| overloads.?.cases[index] else null;
    const raw_args: []const schema.Argument = if (overload_case) |case| case.args else declared.arguments.listOrEmpty();
    const is_overload_case = overload_case != null;
    const is_overloaded = !is_overload_case and overloads != null;
    const qualified_name = if (overload_case) |case|
        try n.print("{s}_{s}_overload_{s}", .{ declared.module_name, declared.function_name, case.name })
    else
        try qualified(n, declared.module_name, declared.function_name);
    const location = try n.print("{s}.{s}", .{ declared.module_name, declared.function_name });
    const dispatch_name = try n.print("bun_bindgen_dispatch_{s}", .{qualified_name});
    const host_name = try n.print("bun_bindgen_host_{s}", .{qualified_name});
    const profile = options.profile;

    const args = try normalizeArguments(n, .inbound_argument, raw_args, profile, .{
        .declaration = .{ .function = function_id },
        .overload_index = if (overload_case_index) |index| @intCast(index) else null,
    });

    var overload_case_ids: []const ir.OverloadCaseId = &.{};
    var dispatch: ?OverloadDispatch = null;
    if (is_overloaded) {
        const ids = try n.arena.alloc(ir.OverloadCaseId, overloads.?.cases.len);
        const cases = try n.arena.alloc(*const ir.Function, overloads.?.cases.len);
        for (ids, 0..) |*id, index| {
            id.* = .of(n.overload_cases.items.len);
            try n.overload_cases.append(n.arena, try function(n, declared, function_id, index));
        }
        for (ids, cases) |id, *case| case.* = &n.overload_cases.items[id.index];
        dispatch = try overloadDispatch(n, cases, profile, overloads.?);
        overload_case_ids = ids;
    }

    const member = declared.member;
    const owner: ?ir.ClassId = if (member) |m| m.owner else null;
    const return_type = try types.ensure(n, declared.result);
    const result_position = try n.positions.?.value(.inbound_result, return_type, null, owner);
    const domain_errors = try domainErrors(n, options.errors.errors);
    const completion_materializer: ?ir.EngineShimId = if (options.completion) |plan| if (plan.materializer) |materializer|
        .of(n.engineShimIdOf(materializer) orelse return n.reject(location, "a completion materializer must reference a declared engine operation", .{}))
    else
        null else null;
    const payload_position: ir.InboundResultPlanId = if (completion_materializer) |materializer| blk: {
        const shim = n.declared_engine_shims.items[materializer.index].shim;
        const payload_type = try types.ensure(n, normalize.effectiveArgumentType(shim.args[0]));
        break :blk try n.positions.?.value(.inbound_result, payload_type, null, null);
    } else result_position;
    const completion: ?ir.CompletionId = if (options.completion) |completion_options| completion: {
        const promise_type = try types.ensure(n, try normalize.completionPromiseType(n, declared.result));
        const id: ir.CompletionId = .of(n.completions.items.len);
        try n.completions.append(n.arena, .{
            .promise = try n.positions.?.value(.inbound_result, promise_type, null, null),
            .payload = payload_position,
            .deliver_symbol = try n.print("bun_bindgen_deliver_{s}", .{qualified_name}),
            .retention = completion_options.retention,
            .sender_drop = completion_options.sender_drop,
            .delivery = completion_options.delivery,
            .error_delivery = completion_options.error_delivery,
            .settlement = completion_options.settlement,
            .cpp_api = if (options.backend == .cpp) api: {
                const api_id: ir.CppCompletionApiId = .of(n.cpp_completion_apis.items.len);
                try n.cpp_completion_apis.append(n.arena, .{
                    .handle = try n.wires.?.handle(try n.print("BunBind_{s}_Completion", .{qualified_name})),
                    .codec = try n.print("BunBind_{s}_CompletionCodec", .{qualified_name}),
                    .create = try n.print("{s}_completion_create", .{dispatch_name}),
                    .clone = try n.print("{s}_completion_clone", .{dispatch_name}),
                    .release = try n.print("{s}_completion_release", .{dispatch_name}),
                    .finish = try n.print("{s}_completion_finish", .{dispatch_name}),
                    .settle = try n.print("{s}_completion_settle", .{dispatch_name}),
                });
                break :api api_id;
            } else null,
        });
        try n.completion_inputs.append(n.arena, .{
            .owner = if (is_overload_case) .{ .overload = .of(n.overload_cases.items.len) } else .{ .function = function_id },
            .materializer = completion_materializer,
        });
        break :completion id;
    } else null;
    const is_async = completion != null;
    const this_argument = if (options.this_value_type) |t| try receiverArgument(n, .inbound_argument, "bindingThis", t, profile) else null;
    const new_target_argument = if (options.new_target_type) |t| try receiverArgument(n, .inbound_argument, "bindingNewTarget", t, profile) else null;
    const callee_argument = if (options.callee_value_type) |t| try receiverArgument(n, .inbound_argument, "bindingCallee", t, profile) else null;
    const call_plan = callPlan(
        n,
        .inbound_argument,
        args,
        {},
        &.{ this_argument, new_target_argument, callee_argument },
        .{
            .receiver = if (member) |m| if (m.representation != .plain and !m.raw.kind.isStatic() and m.raw.kind != .constructor)
                try n.positions.?.planReceiver(m.owner)
            else
                null else null,
        },
    );

    const class_member: ?ir.ClassMemberFacts = if (member) |m| blk: {
        const raw = m.raw.options;
        const kind = m.raw.kind;
        break :blk .{
            .member_kind = kind,
            .is_illegal = raw.illegal,
            .typescript_async = raw.typescript_async,
            .native_reference_symbol = if (raw.native_reference) try n.print("bun_bindgen_factory_{s}_reference", .{qualified_name}) else null,
        };
    } else null;

    if (call_plan.frame.converter_receiver) receiver_check: {
        if (member != null or this_argument == null) {
            try n.fail(location, "receiver byte-length conversion requires a typed ArrayBufferView receiver", .{});
            break :receiver_check;
        }
        var receiver = plans.plan(n, n.get(this_argument.?.position).input);
        if (receiver.codec == .converted) receiver = plans.plan(n, receiver.codec.converted.converted_value);
        if (receiver.codec != .branded_value or
            (!structural.eql(n.rawType(receiver.type).branded_value.brand, schema.brandOf(schema.js_array_buffer_view)) and
                !structural.eql(n.rawType(receiver.type).branded_value.brand, schema.brandOf(schema.js_uint8_array))))
        {
            try n.fail(location, "receiver byte-length conversion requires a typed ArrayBufferView receiver", .{});
        }
    }

    const required_count = if (is_overloaded) blk: {
        var minimum: u32 = std.math.maxInt(u32);
        for (overloads.?.cases) |case| minimum = @min(minimum, countRequired(case.args));
        break :blk minimum;
    } else countRequired(raw_args);
    const exposed = n.isExposed(options.exposure) and (member == null or n.isExposed(member.?.exposure));

    const wire_prefix = try n.print("BunBind_{s}", .{qualified_name});
    const wire_args = if (is_overloaded) null else try n.wires.?.functionArguments(try n.print("{s}_Args", .{wire_prefix}), args, &.{ this_argument, new_target_argument, callee_argument });
    const wire_result_position = if (is_async and options.backend == .cpp) n.get(completion.?).payload else result_position;
    const wire_result = try n.wires.?.result(try n.print("{s}_Result", .{wire_prefix}), wire_result_position, domain_errors);
    const id: ir.FunctionIdRef = if (is_overload_case) .{ .overload = .of(n.overload_cases.items.len) } else .{ .function = function_id };
    var declaration = declared;
    declaration.overload_dispatch = dispatch;
    declaration.inputs = try callInputs(n, location, args, raw_args, if (is_overload_case) null else options.conversion_program, call_plan.frame, .{
        .minimum = required_count,
        .failure = switch (options.missing_required_arguments) {
            .profile_default => if (profile == .node) null else .arity,
            .convert_undefined => null,
            .arity_error => .arity,
            .failure => |failure| .{ .custom = .{ .value = failure, .return_value = .empty } },
        },
    });
    if (is_overload_case) {
        try n.declared_overloads.append(n.arena, declaration);
    } else n.declared_functions.items[function_id.index] = declaration;
    if (!is_overload_case and exposed) if (options.realm_identity) |identity| {
        const realm_id: ir.CppRealmFunctionId = .of(n.cpp_realm_functions.items.len);
        try n.cpp_realm_functions.append(n.arena, .{
            .symbol = try n.print("BunBindgenFunction_{s}_{s}", .{ declared.module_name, declared.function_name }),
            .name = identity.name,
            .host = host_name,
            .length = options.length orelse required_count,
            .visibility = identity.visibility,
        });
        try n.realm_functions.put(n.arena, function_id, realm_id);
    };
    return .{
        .result_position = result_position,
        .wire_args = wire_args,
        .wire_result = wire_result,
        .module_name = declared.module_name,
        .function_name = declared.function_name,
        .args = args,
        .id = id,
        .case_name = if (overload_case) |case| case.name else "",
        .overload_cases = overload_case_ids,
        .backend = options.backend,
        .domain_errors = domain_errors,
        .completion = completion,
        .call_plan = call_plan.plan,
        .this_argument = this_argument,
        .new_target_argument = new_target_argument,
        .callee_argument = callee_argument,
        .callback_data_type = if (options.callback_data) |data| data.zig_type else null,
        .has_caller_source_location = options.caller_source_location,
        .is_promise_reaction_handler = options.promise_reaction_handler,
        .predicate = if (is_overload_case) null else if (options.type_predicate) |predicate| try n.positions.?.value(.inbound_argument, try types.ensure(n, predicate), null, null) else null,
        .class_member = class_member,
        .implementation_name = if (member) |m| m.implementation else declared.function_name,
        .js_name = if (member) |m| m.js_name else declared.function_name,
        .dispatch_symbol = dispatch_name,
        .host_symbol = host_name,
        .destroy_result_symbol = if ((!is_overloaded or is_async) and n.positions.?.resultNeedsDestroy(payload_position, domain_errors)) try n.print("bun_bindgen_destroy_{s}_result", .{qualified_name}) else null,
        .js_length = if (is_overload_case) required_count else options.length orelse required_count,
        .exposed = exposed,
    };
}

// ─── engine shims ───

fn engineShim(n: *Normalizer, declared: Normalizer.DeclaredShim) Error!ir.EngineShim {
    const shim = declared.shim;
    const options = shim.options;
    const qualified_name = try qualified(n, declared.module_name, shim.name);
    const profile = options.profile;

    const args = try normalizeArguments(n, .outbound_argument, shim.args, profile, null);
    const return_type = try types.ensure(n, shim.result);
    const result_position = try n.positions.?.value(.outbound_result, return_type, if (options.result_source == .javascript) try plans.inputPlan(n, return_type, profile, .{}) else null, null);
    const call_plan = callPlan(n, .outbound_argument, args, result_position, &.{}, .{
        .realm = options.realm,
        .checks_traps = options.check_traps,
        .throws = switch (options.throws) {
            .never => .never,
            .js_exception => .js_exception,
            .out_of_memory => .out_of_memory,
        },
    });
    const thunk_symbol = try n.print("bun_bindgen_engine_{s}", .{qualified_name});
    const prefix = try n.print("BunBindEngine_{s}_{s}", .{ declared.module_name, shim.name });
    return .{
        .id = .of(n.engine_shims.items.len),
        .outbound = .{
            .result_position = result_position,
            .wire_args = try n.wires.?.outboundArguments(try n.print("{s}_Args", .{prefix}), args, null, null),
            .wire_result = try n.wires.?.result(try n.print("{s}_Result", .{prefix}), result_position, &.{}),
            .args = args,
            .call_plan = call_plan.plan,
            .entries = try n.arena.dupe(ir.OutboundEntry, &.{.{
                .symbol = thunk_symbol,
                .callee = .native,
            }}),
        },
        .module_name = declared.module_name,
        .shim_name = shim.name,
        .destroy_result_symbol = if (n.get(result_position).zig.destruction.wire) try n.print("{s}_destroy_transferred_result", .{thunk_symbol}) else null,
    };
}

// ─── native exports ───

fn nativeExport(n: *Normalizer, declared: Normalizer.DeclaredExport, id: ir.NativeExportId) Error!ir.NativeExport {
    const native_export = declared.native_export;
    const options = native_export.options;
    const qualified_name = try qualified(n, declared.module_name, native_export.name);

    const args = try normalizeArguments(n, .inbound_argument, native_export.args, .exact, .{ .declaration = .{ .native_export = id } });
    const return_type = try types.ensure(n, native_export.result);
    const result_position = try n.positions.?.value(.inbound_result, return_type, null, null);
    const domain_errors = try domainErrors(n, options.errors.errors);
    const call_plan = callPlan(n, .inbound_argument, args, {}, &.{}, .{
        .realm = options.realm,
        .throws = options.throws,
        .non_returning = options.non_returning,
    });
    const prefix = try n.print("BunBindNative_{s}_{s}", .{ declared.module_name, native_export.name });
    return .{
        .id = id,
        .result_position = result_position,
        .wire_args = try n.wires.?.arguments(try n.print("{s}_Args", .{prefix}), args),
        .wire_result = try n.wires.?.result(try n.print("{s}_Result", .{prefix}), result_position, domain_errors),
        .module_name = declared.module_name,
        .export_name = native_export.name,
        .args = args,
        .exposed = n.isExposed(options.exposure),
        .domain_errors = domain_errors,
        .call_plan = call_plan.plan,
        .dispatch_symbol = try n.print("bun_bindgen_native_{s}", .{qualified_name}),
        .destroy_result_symbol = if (n.positions.?.resultNeedsDestroy(result_position, domain_errors)) try n.print("bun_bindgen_destroy_native_{s}_result", .{qualified_name}) else null,
    };
}

// ─── callbacks ───

fn callbackCall(n: *Normalizer, id: ir.TypeId) Error!ir.OutboundCall {
    const raw = n.rawType(id).callback;
    const profile = raw.options.profile;

    const args = try normalizeArguments(n, .outbound_argument, raw.args, profile, null);
    const return_type = try types.ensure(n, raw.result);
    const result_position = try n.positions.?.value(.outbound_result, return_type, try plans.inputPlan(n, return_type, profile, .{}), null);
    const receiver = if (raw.options.receiver) |value| try n.positions.?.value(.outbound_argument, n.typeId(value), null, null) else null;
    const callee = try n.positions.?.value(.outbound_argument, id, null, null);
    const call_plan = callPlan(n, .outbound_argument, args, result_position, &.{}, .{ .receiver = receiver, .callee = callee });
    const hash = n.type_metadata.items[id.index].name_hash;
    const prefix = try n.print("BunBind_Callback_{x:0>16}", .{hash});
    const entries = try n.arena.alloc(ir.OutboundEntry, if (raw.options.schedule_next_tick) 2 else 1);
    entries[0] = .{ .symbol = try n.print("bun_bindgen_invoke_callback_{x:0>16}", .{hash}), .callee = .callback };
    if (raw.options.schedule_next_tick) entries[1] = .{ .symbol = try n.print("bun_bindgen_schedule_callback_{x:0>16}", .{hash}), .callee = .schedule };
    return .{
        .result_position = result_position,
        .wire_args = try n.wires.?.outboundArguments(try n.print("{s}_Args", .{prefix}), args, receiver, callee),
        .wire_result = try n.wires.?.result(try n.print("{s}_Result", .{prefix}), result_position, &.{}),
        .args = args,
        .call_plan = call_plan.plan,
        .entries = entries,
    };
}
