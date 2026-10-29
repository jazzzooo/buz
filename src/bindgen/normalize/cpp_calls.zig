const mod_cpp_facts = @import("cpp_facts.zig");
const mod_cpp_codecs = @import("cpp_codecs.zig");
const mod_surfaces = @import("surfaces.zig");
const mod_plans = @import("plans.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const Normalizer = normalize.Normalizer;
const Error = std.mem.Allocator.Error;
const PlanError = normalize.PlanError;
const cpp_types = mod_cpp_facts.Types;
const failures = mod_cpp_codecs.Failures;
const callables = @import("callables.zig");
const classes = @import("classes.zig");

const FunctionChecks = struct {
    required_count: ?ir.CppRequiredArgumentCheck,
    receiver: ?ir.CppReceiverCheck,
};

const EngineCallee = struct { symbol: []const u8, arguments_type: ir.CppTypeId };
const OutboundResultSource = union(enum) { native, javascript: []const u8 };

const Phase = enum { exposed, unexposed };

/// Plans the C++ adapter of every declaration, planning codecs as the adapters
/// need them, and reports each unsupported codec at the declaration that needs
/// it. Exposed declarations are planned into the IR; the rest are planned on a
/// discarded fork, so a declaration excluded from this target is still checked.
pub fn planAll(n: *Normalizer) normalize.Error!void {
    n.cpp_completion_index = try n.arena.alloc(?ir.CppCompletionEncoderId, n.completions.items.len);
    @memset(n.cpp_completion_index, null);
    n.cpp_native_construction_index = try n.arena.alloc(?ir.CppNativeConstructionId, n.classes.items.len);
    @memset(n.cpp_native_construction_index, null);
    try planPhase(n, .exposed);
    var fork = try n.fork();
    planPhase(&fork, .unexposed) catch |err| switch (err) {
        error.SchemaRule => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
    try n.diagnostics.appendSlice(n.arena, fork.diagnostics.items[n.diagnostics.items.len..]);
    try n.requireValid();
}

fn planPhase(n: *Normalizer, comptime phase: Phase) normalize.Error!void {
    if (phase == .exposed) {
        try engineImplementations(n);
        try n.requireValid();
        try completionDeliveries(n);
    }
    try propertyMaterializers(n, phase);
    try slotAccessors(n, phase);
    if (phase == .exposed) try callbackCalls(n);
    try functions(n, phase);
    try n.requireValid();
    try nativeExports(n, phase);
    if (phase == .exposed) {
        try engineEntries(n);
        try classConstructors(n);
    }
    try classInitializers(n, phase);
}

fn included(exposed: bool, comptime phase: Phase) bool {
    return exposed == (phase == .exposed);
}

/// The planned value, or null after reporting why the declaration at
/// `location` cannot be planned.
fn reported(n: *Normalizer, location: []const u8, planned: anytype) normalize.Error!?@typeInfo(@TypeOf(planned)).error_union.payload {
    return planned catch |err| switch (err) {
        error.Unsupported => {
            try n.fail(location, "{s}", .{n.cpp_unsupported});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn declarationName(n: *Normalizer, module_name: []const u8, name: []const u8) Error![]const u8 {
    return n.print("{s}.{s}", .{ module_name, name });
}

fn inputValue(n: *Normalizer, id: anytype) PlanError!ir.CppTypeId {
    return cpp_types.input(n, id).value orelse n.unsupportedValue(id, "this value has no C++ JavaScript input converter");
}

fn resultValue(n: *Normalizer, id: anytype) PlanError!ir.CppTypeId {
    return cpp_types.result(n, id).logical orelse n.unsupportedValue(id, "this value has no C++ result type");
}

fn engineImplementations(n: *Normalizer) normalize.Error!void {
    const calls = try n.arena.alloc(ir.CppOutboundCall, n.engine_shims.items.len);
    const implementations = try n.arena.alloc(ir.CppEngineImplementation, n.engine_shims.items.len);
    for (n.engine_shims.items, calls, implementations) |*shim, *call, *implementation_| {
        const planned = try reported(n, try declarationName(n, shim.module_name, shim.shim_name), engineImplementation(n, shim)) orelse continue;
        call.* = planned.call;
        implementation_.* = planned.implementation;
    }
    n.cpp_engine_calls = calls;
    n.cpp_engine_implementations = implementations;
}

const EngineImplementation = struct { call: ir.CppOutboundCall, implementation: ir.CppEngineImplementation };

fn engineImplementation(n: *Normalizer, shim: *const ir.EngineShim) PlanError!EngineImplementation {
    std.debug.assert(shim.outbound.entries.len == 1);
    std.debug.assert(shim.outbound.entries[0].callee == .native);
    const arguments_name = try n.print("BunBindgenEngine_{s}_{s}_Arguments", .{ shim.module_name, shim.shim_name });
    const native: EngineCallee = .{
        .symbol = try n.print("bunBindgenEngine_{s}_{s}", .{ shim.module_name, shim.shim_name }),
        .arguments_type = try n.cppType(.{ .named = .{ .name = arguments_name, .namespace = .engine } }),
    };
    const call = try outboundCall(n, &shim.outbound, .{ .native = try outboundNativeCall(n, shim, native) }, switch (n.rawEngineShim(shim.id).options.result_source) {
        .native => .native,
        .javascript => .{ .javascript = try n.print("{s} result", .{shim.shim_name}) },
    });
    const value_type = switch (call.entries[0].operation) {
        .invoke => |invoke| if (invoke.result) |result| switch (result.conversion) {
            .native => |value| n.get(value.encoder).value_type,
            .javascript => try n.cppType(.js_value),
        } else try n.cppType(.void),
        .schedule => unreachable,
    };
    const result_name = try n.print("BunBindgenEngine_{s}_{s}_Return", .{ shim.module_name, shim.shim_name });
    const fields = try n.arena.alloc(ir.CppTypedField, shim.outbound.args.len);
    for (shim.outbound.args, fields) |argument, *field| field.* = .{ .name = argument.argument_name, .type = try inputValue(n, argument.position) };
    return .{ .call = call, .implementation = .{
        .arguments = .{ .name = arguments_name, .fields = fields },
        .result_alias = .{ .name = result_name, .type = if (shim.outbound.call_plan.throws == .out_of_memory) try n.cppType(.{ .allocation_result = value_type }) else value_type },
        .signature = .{
            .symbol = native.symbol,
            .parameters = try n.arena.dupe(ir.CppNativeSignature.Parameter, &.{.{
                .name = "nativeArgs",
                .type = .{ .direct = try n.cppType(.{ .const_reference = native.arguments_type }) },
            }}),
            .result = try n.cppType(.{ .named = .{ .name = result_name, .namespace = .engine } }),
            .nodiscard = shim.outbound.call_plan.throws == .out_of_memory,
            .context = if (shim.outbound.call_plan.realm == .current) .engine else .none,
            .non_returning = false,
        },
    } };
}

fn completionOwner(n: *const Normalizer, index: usize) *const ir.Function {
    return switch (n.completion_inputs.items[index].owner) {
        .function => |id| n.get(id),
        .overload => |id| n.get(id),
    };
}

/// Every completion is delivered, since Zig settles its promise whether or not
/// the function is exposed to JavaScript.
fn completionDeliveries(n: *Normalizer) normalize.Error!void {
    const deliveries = try n.arena.alloc(ir.CppCompletionDelivery, n.completions.items.len);
    for (deliveries, 0..) |*output, index| {
        const owner = completionOwner(n, index);
        output.* = try reported(n, try declarationName(n, owner.module_name, owner.function_name), completionDelivery(n, index)) orelse continue;
    }
    n.cpp_completion_deliveries = deliveries;
}

fn completionDelivery(n: *Normalizer, index: usize) PlanError!ir.CppCompletionDelivery {
    const completion = n.completions.items[index];
    const owner = completionOwner(n, index);
    return .{
        .completion = .of(index),
        .wire = owner.wire_result,
        .destroy = owner.destroy_result_symbol,
        .layout = try wireResultLayout(n, completion.payload, owner.domain_errors),
        .materializer = if (n.completion_inputs.items[index].materializer) |shim|
            .{ .engine = try completionMaterializer(n, shim, completion.cpp_api.?) }
        else
            .{ .wire = try mod_cpp_codecs.Materialize.planJavaScript(n, completion.payload, .wire) },
    };
}

fn propertyMaterializers(n: *Normalizer, comptime phase: Phase) normalize.Error!void {
    const properties = try n.arena.alloc([]const ir.CppMaterializerId(.outbound_argument), n.classes.items.len);
    for (n.classes.items, properties) |class, *output| {
        output.* = &.{};
        if (!included(class.exposed, phase)) continue;
        output.* = try reported(n, try declarationName(n, class.module_name, class.class_name), classPropertyMaterializers(n, class)) orelse continue;
    }
    n.cpp_class_property_materializers = properties;
}

fn classPropertyMaterializers(n: *Normalizer, class: ir.Class) PlanError![]const ir.CppMaterializerId(.outbound_argument) {
    const values = try n.arena.alloc(ir.CppMaterializerId(.outbound_argument), class.instance_properties.len);
    for (class.instance_properties, values) |property, *value| value.* = try mod_cpp_codecs.Materialize.planJavaScript(n, property.position, .wire);
    return values;
}

fn slotAccessors(n: *Normalizer, comptime phase: Phase) normalize.Error!void {
    const slot_accessors = try n.arena.alloc([]const ?ir.CppCachedSlotAccessors, n.classes.items.len);
    for (n.classes.items, slot_accessors) |class, *output| {
        const values = try n.arena.alloc(?ir.CppCachedSlotAccessors, class.slots.len);
        @memset(values, null);
        output.* = values;
        if (!included(class.exposed, phase)) continue;
        for (class.slots, n.declared_classes.items[class.id.index].class.slots, values) |slot, raw, *value| {
            if (!raw.options.exposed or classes.slotCachesMember(n, &class, slot)) continue;
            value.* = try reported(n, try declarationName(n, class.module_name, class.class_name), cachedSlotAccessors(n, class, slot));
        }
    }
    n.cpp_class_slot_accessors = slot_accessors;
}

fn callbackCalls(n: *Normalizer) normalize.Error!void {
    const callback_calls = try n.arena.alloc(?ir.CppOutboundCall, n.callbacks.items.len);
    for (n.callbacks.items, callback_calls) |callback, *output| {
        output.* = null;
        if (callback.type.index >= n.binding_type_count) continue;
        output.* = try reported(n, callback.callback_name, callbackCall(n, callback));
    }
    n.cpp_callback_calls = callback_calls;
}

fn callbackCall(n: *Normalizer, callback: ir.Callback) PlanError!ir.CppOutboundCall {
    const call = &n.callback_calls[callback.id.index];
    const arguments = try n.arena.alloc(@typeInfo(@FieldType(ir.CppOutboundCallbackArguments, "arguments")).pointer.child, call.args.len);
    for (call.args, arguments) |argument, *value| value.* = .{
        .name = argument.argument_name,
        .materializer = try mod_cpp_codecs.Materialize.planJavaScript(n, argument.position, .wire),
        .rest = argument.conversion.rest,
    };
    const callee = call.call_plan.callee.?;
    return outboundCall(n, call, .{ .callback = .{
        .callee = try mod_cpp_codecs.decode(n, callee, try failures.decoder(n, .outbound_argument)),
        .arguments = arguments,
        .receiver = if (call.call_plan.receiver) |receiver| try mod_cpp_codecs.Materialize.planJavaScript(n, receiver, .wire) else null,
        .capacity = if (arguments.len != 0 and arguments[arguments.len - 1].rest)
            .{ .rest = .{ .name = arguments[arguments.len - 1].name, .fixed = arguments.len - 1 } }
        else
            .{ .fixed = arguments.len },
    } }, .{ .javascript = try n.print("{s} callback result", .{callback.callback_name}) });
}

fn functions(n: *Normalizer, comptime phase: Phase) normalize.Error!void {
    const planned = try n.arena.alloc(?ir.CppFunction, n.functions.items.len);
    const factories = try n.arena.alloc(?ir.CppFunctionFactory, n.functions.items.len);
    const cases = try n.arena.alloc(?ir.CppFunction, n.overload_cases.items.len);
    @memset(planned, null);
    @memset(factories, null);
    @memset(cases, null);
    for (n.functions.items, planned, factories, 0..) |*f, *output, *factory, index| {
        if (!included(f.exposed, phase)) continue;
        const name = try declarationName(n, f.module_name, f.function_name);
        output.* = try reported(n, name, function(n, f));
        factory.* = try functionFactory(n, .of(index));
        for (f.overload_cases) |case| cases[case.index] = try reported(n, name, function(n, n.get(case)));
    }
    n.cpp_functions = planned;
    n.cpp_function_factories = factories;
    n.cpp_overload_cases = cases;
}

fn nativeExports(n: *Normalizer, comptime phase: Phase) normalize.Error!void {
    const exports = try n.arena.alloc(?ir.CppNativeExport, n.native_exports.items.len);
    for (n.native_exports.items, exports) |*export_, *output| {
        output.* = null;
        if (!included(export_.exposed, phase)) continue;
        output.* = try reported(n, try declarationName(n, export_.module_name, export_.export_name), nativeExport(n, export_));
    }
    n.cpp_native_exports = exports;
}

fn nativeExport(n: *Normalizer, export_: *const ir.NativeExport) PlanError!ir.CppNativeExport {
    const plan_ = export_.call_plan;
    const symbol = try n.print("bunBindgenZig_{s}_{s}", .{ export_.module_name, export_.export_name });
    const parameters = try n.arena.alloc(ir.CppNativeParameterId, export_.args.len);

    const failure = try failures.nativeExport(n, export_);
    for (export_.args, parameters) |argument, *parameter| parameter.* = try mod_cpp_codecs.Native.parameter(n, argument.position, failure);
    const call = try nativeExportCall(n, export_, parameters, false);
    const declarations = try n.arena.alloc(ir.CppNativeSignature.Parameter, parameters.len);
    for (export_.args, parameters, declarations) |argument, parameter, *declaration| declaration.* = .{
        .name = try n.print("nativeArgument_{s}", .{argument.argument_name}),
        .type = .{ .native = parameter },
    };
    const result_type = try nativeResultType(n, call);
    return .{
        .element_aliases = try elementAliases(n, export_, symbol),
        .entry = .{
            .namespace = .zig_exports,
            .signature = .{
                .symbol = symbol,
                .parameters = declarations,
                .result = if (plan_.throws == .out_of_memory) try n.cppType(.{ .allocation_result = result_type }) else result_type,
                .nodiscard = plan_.throws == .out_of_memory,
                .context = if (plan_.realm == .current) .{ .global = if (plan_.throws == .js_exception) .exception else .termination } else .none,
                .non_returning = plan_.non_returning,
            },
            .call = call,
        },
        .surface = if (n.native_surface_exports.contains(export_.id)) .{
            .namespace = .zig_exports,
            .signature = .{
                .symbol = try mod_surfaces.nativeFactorySymbol(n, export_.id),
                .parameters = &.{},
                .result = try n.cppType(.encoded_js_value),
                .nodiscard = false,
                .context = .{ .global = .checked_exception },
                .non_returning = false,
            },
            .call = try nativeExportCall(n, export_, parameters, true),
        } else null,
    };
}

fn engineEntries(n: *Normalizer) normalize.Error!void {
    const engine_entries = try n.arena.alloc(?ir.CppNativeEntry(.outbound_argument), n.engine_shims.items.len);
    for (n.engine_shims.items, engine_entries) |*shim, *entry| {
        entry.* = null;
        if (!n.engine_native_support[shim.id.index]) continue;
        entry.* = try reported(n, try declarationName(n, shim.module_name, shim.shim_name), engineEntry(n, shim));
    }
    n.cpp_engine_entries = engine_entries;
}

fn engineEntry(n: *Normalizer, shim: *const ir.EngineShim) PlanError!ir.CppNativeEntry(.outbound_argument) {
    const failure = try failures.inbound(n, .current, .js_exception, .empty);
    const frame = try argumentFrame(n, .{
        .wire_storage = true,
        .argument_roots = true,
        .deferred_conversions = false,
        .converter_receiver = null,
        .transferred = &.{},
    });
    const inputs = try n.arena.alloc(ir.CppInboundInput(.outbound_argument), 1 + @as(usize, @intFromBool(shim.outbound.args.len != 0)));
    inputs[0] = .{ .prepare_arguments = frame };
    const arguments = try n.arena.alloc(ir.CppNativeArgument(.outbound_argument), shim.outbound.args.len);
    for (shim.outbound.args, arguments) |argument, *output| output.* = .{
        .encoder = try mod_cpp_codecs.Native.encoder(n, argument.position, failure),
        .name = argument.argument_name,
    };
    if (arguments.len != 0) inputs[1] = .{ .native = arguments };
    const wire_result = try wireResult(n, shim.outbound.wire_result, shim.destroy_result_symbol, shim.outbound.result_position, &.{});
    const call = try n.create(ir.CppInboundCall(.outbound_argument){
        .frame = frame,
        .codec_failure = failure,
        .inputs = inputs,
        .status = ir.CppCallStatus.javascript,
        .callee = .{
            .symbol = shim.outbound.entries[0].symbol,
            .arguments = shim.outbound.wire_args,
            .result = wire_result,
            .realm = shim.outbound.call_plan.realm,
            .lazy_storage = null,
            .context = .{ .promise = false, .receiver = .none, .caller_frame = false, .deferred = .engine_context },
        },
        .output = if (n.get(shim.outbound.result_position).*.isVoid()) .void else .{ .decode_value = .{
            .result = wire_result,
            .decoder = try mod_cpp_codecs.decode(n, shim.outbound.result_position, failure),
            .release_wire = !mod_cpp_facts.get(n, shim.outbound.result_position).contains_collection,
        } },
        .failure_return = .empty,
    });
    return .{
        .namespace = .engine,
        .signature = .{
            .symbol = try n.print("{s}_call", .{n.cpp_engine_implementations[shim.id.index].signature.symbol}),
            .parameters = n.cpp_engine_implementations[shim.id.index].signature.parameters,
            .result = try n.cppType(.{ .optional = try nativeResultType(n, call) }),
            .nodiscard = false,
            .context = .engine,
            .non_returning = false,
        },
        .call = call,
    };
}

fn classConstructors(n: *Normalizer) Error!void {
    const constructors = try n.arena.alloc(?ir.CppClassConstructor, n.classes.items.len);
    for (n.classes.items, constructors) |class, *output| output.* = try classConstructor(n, class);
    n.cpp_class_constructors = constructors;
}

fn classInitializers(n: *Normalizer, comptime phase: Phase) normalize.Error!void {
    const initializers = try n.arena.alloc(?ir.ClassInitializers, n.classes.items.len);
    for (n.classes.items, initializers) |class, *output| {
        output.* = null;
        if (!included(class.exposed, phase)) continue;
        output.* = try reported(n, try declarationName(n, class.module_name, class.class_name), classInitializer(n, class)) orelse continue;
    }
    n.class_initializers = initializers;
}

fn classInitializer(n: *Normalizer, class: ir.Class) PlanError!?ir.ClassInitializers {
    const raw = n.declared_classes.items[class.id.index].class;
    if (raw.constructor.options.illegal or raw.instance_properties.len == 0 or raw.instance_properties[0].options.initializer == null) return null;
    const constructor = n.get(class.constructor);
    return .{
        .constructor = try mod_cpp_codecs.Defaults.initializers(n, class.id, constructor, try implementation(n, constructor)),
        .call = if (class.constructor_call) |id| try mod_cpp_codecs.Defaults.initializers(n, class.id, n.get(id), try implementation(n, n.get(id))) else null,
    };
}

fn outboundNativeCall(n: *Normalizer, shim: *const ir.EngineShim, native: EngineCallee) PlanError!ir.CppOutboundNativeCall {
    const call = &shim.outbound;
    const raw = n.rawEngineShim(shim.id).args;
    const arguments = try n.arena.alloc(@typeInfo(@FieldType(ir.CppOutboundNativeCall, "arguments")).pointer.child, call.args.len);
    var transferred: std.ArrayList(ir.CppOutboundNativeCall.Transfer) = .empty;
    var argument_storage = false;
    for (call.args, arguments, 0..) |argument, *value, index| {
        const decoder = try mod_cpp_codecs.decode(n, argument.position, try failures.decoder(n, .outbound_argument));
        value.* = .{ .name = argument.argument_name, .path = callables.argumentSource(raw, index).name, .decoder = decoder };
        argument_storage = argument_storage or mod_cpp_facts.get(n, argument.position).contains_collection;
        if (n.get(argument.position).transfer) try transferred.append(n.arena, .{ .name = argument.argument_name, .position = argument.position });
    }
    return .{
        .symbol = native.symbol,
        .arguments_type = native.arguments_type,
        .arguments = arguments,
        .argument_storage = argument_storage,
        .context = if (call.call_plan.realm == .none) .none else .{ .current = if (!call.call_plan.checks_traps) .unchecked else switch (call.call_plan.throws) {
            .js_exception => .exception,
            .never, .out_of_memory => .termination,
        } },
        .allocation = call.call_plan.throws == .out_of_memory,
        .transferred = transferred.items,
    };
}

fn outboundCall(n: *Normalizer, call: *const ir.OutboundCall, callee: @FieldType(ir.CppOutboundInvoke, "callee"), source: OutboundResultSource) PlanError!ir.CppOutboundCall {
    const entries = try n.arena.alloc(ir.CppOutboundEntry, call.entries.len);
    for (call.entries, entries) |entry, *output| {
        if (entry.callee == .schedule) {
            output.* = .{ .symbol = entry.symbol, .operation = .{ .schedule = callee.callback } };
            continue;
        }
        std.debug.assert((entry.callee == .native) == (callee == .native));
        output.* = .{ .symbol = entry.symbol, .operation = .{ .invoke = .{
            .callee = callee,
            .result = if (n.get(call.result_position).isVoid()) null else .{
                .position = call.result_position,
                .destroy = try n.print("{s}_destroy_pending_result", .{entry.symbol}),
                .conversion = switch (source) {
                    .javascript => |path| .{ .javascript = .{
                        .decoder = try mod_cpp_codecs.javascript(n, call.result_position),
                        .path = path,
                    } },
                    .native => .{ .native = .{
                        .encoder = try mod_cpp_codecs.encode(n, call.result_position),
                        .owned = if (mod_cpp_facts.get(n, call.result_position).contains_owned_handle) call.result_position else null,
                    } },
                },
            },
        } } };
    }
    return .{ .wire_args = call.wire_args, .wire_result = call.wire_result, .entries = entries };
}

fn nativeResultType(n: *Normalizer, call: anytype) Error!ir.CppTypeId {
    return if (comptime @TypeOf(call.*).argument_role == .outbound_argument) switch (call.output) {
        .void => n.cppType(.monostate),
        .decode_value => |result| mod_cpp_codecs.decodePlan(n, result.decoder.position).?.value_type,
    } else switch (call.output) {
        .constant => n.cppType(.void),
        .decode_value => |result| mod_cpp_codecs.decodePlan(n, result.decoder.position).?.value_type,
        .encode_value, .attach_native, .javascript, .promise => unreachable,
    };
}

fn functionFactory(n: *Normalizer, id: ir.FunctionId) Error!?ir.CppFunctionFactory {
    const f = n.get(id);
    if (!f.exposed) return null;
    if (f.class_member) |member| {
        const symbol = member.native_reference_symbol orelse return null;
        const declaration = n.declaration(f.id).member.?;
        return .{
            .symbol = symbol,
            .abi = .reference,
            .value = try mod_surfaces.surfaceFunction(n, id, .{ .named = declaration.raw.options.display_name orelse f.js_name }, .public, false),
        };
    }
    if (f.callback_data_type != null) return null;
    return .{
        .symbol = try n.print("bun_bindgen_source_function_{s}_{s}_value", .{ n.source_stems[n.declared_functions.items[id.index].module], f.function_name }),
        .abi = .value,
        .value = try mod_surfaces.surfaceFunction(n, id, .{ .named = f.function_name }, .public, false),
    };
}

fn classConstructor(n: *Normalizer, class: ir.Class) Error!?ir.CppClassConstructor {
    const constructor = n.get(class.constructor);
    if (!class.exposed or !constructor.exposed) return null;
    var slots: std.ArrayList(u32) = .empty;
    for (class.slots, 0..) |slot, index| {
        if (slot.storage == .constructor) try slots.append(n.arena, @intCast(index));
    }
    const call = if (class.constructor_call) |id| if (n.get(id).exposed) id else null else null;
    return .{
        .factory_symbol = try n.print("bun_bindgen_source_class_{s}_{s}_value", .{ n.source_stems[n.declared_classes.items[class.id.index].module], class.class_name }),
        .slots = slots.items,
        .builtin = if (call) |id| switch (n.get(id).backend) {
            .zig, .cpp => null,
            .builtin => n.builtinGenerator(id),
        } else null,
        .call = try constructorCall(n, class, call),
    };
}

fn constructorFailure(n: *Normalizer, id: ir.ClassId, comptime operation: enum { call, construct }) Error!ir.ConversionFailure {
    const raw = n.declared_classes.items[id.index].class;
    if (operation == .call) if (raw.options.constructor_call_error) |failure| return failure;
    if (raw.options.illegal_constructor_errors) |failures_| return switch (operation) {
        .call => failures_.call,
        .construct => failures_.construct,
    };
    return .{
        .kind = .{ .code = "ERR_ILLEGAL_CONSTRUCTOR" },
        .message = if (operation == .construct or raw.constructor.options.illegal)
            "Illegal constructor"
        else
            try n.print("Class constructor {s} cannot be invoked without 'new'", .{raw.name}),
    };
}

fn constructorCall(n: *Normalizer, class: ir.Class, call: ?ir.FunctionId) Error!@FieldType(ir.CppClassConstructor, "call") {
    if (call) |id| switch (n.get(id).backend) {
        .zig, .cpp => return .{ .function = id },
        .builtin => {},
    };
    return .{ .host = .{
        .host = .{
            .symbol = if (call) |id| n.get(id).host_symbol else try n.print("{s}_call", .{class.cpp_constructor_name}),
            .signature = .{ .frame = .{ .linkage = .internal, .overload_inputs = false, .callback_data = false, .promise_body = null } },
        },
        .entry = try n.create(ir.CppInboundCall(.inbound_argument){
            .codec_failure = try failures.inbound(n, .current, .js_exception, .empty),
            .status = ir.CppCallStatus.javascript,
            .callee = if (call != null) .{ .builtin_constructor = class.id } else .{ .reject = try constructorFailure(n, class.id, .call) },
            .output = if (call != null) .{ .javascript = .value } else .{ .constant = .{ .value = .empty, .release_wire = false } },
        }),
    } };
}

fn wireResultLayout(n: *Normalizer, position: anytype, domain_errors: []const ir.DomainErrorId) PlanError!ir.CppWireResultLayout {
    if (domain_errors.len == 0) return if (n.get(position).isVoid()) .void else .value;
    const errors = try n.arena.alloc(ir.CppWireErrorFactory, domain_errors.len);
    for (domain_errors, errors) |id, *output| output.* = .{
        .name = n.get(id).error_name,
        .factory = try mod_cpp_codecs.errorFactory(n, id, false),
    };
    return .{ .errors = errors };
}

fn wireResult(n: *Normalizer, wire: ir.WireTypeId, destroy: ?[]const u8, position: anytype, domain_errors: []const ir.DomainErrorId) PlanError!ir.CppWireResultId {
    const id: ir.CppWireResultId = .of(n.cpp_wire_results.items.len);
    try n.cpp_wire_results.append(n.arena, .{ .wire = wire, .destroy = destroy, .layout = try wireResultLayout(n, position, domain_errors) });
    return id;
}

fn argumentFrame(n: *Normalizer, frame: ir.CppArgumentFrame) Error!ir.CppArgumentFrameId {
    const id: ir.CppArgumentFrameId = .of(n.cpp_argument_frames.items.len);
    try n.cpp_argument_frames.append(n.arena, frame);
    return id;
}

fn nativeExportCall(n: *Normalizer, export_: *const ir.NativeExport, parameters: []const ir.CppNativeParameterId, surface: bool) PlanError!*const ir.CppInboundCall(.inbound_argument) {
    const plan = export_.call_plan;
    const raw = n.rawNativeExport(export_.id).args;
    var transferred: std.ArrayList(ir.CppArgumentFrame.Transfer) = .empty;
    if (!surface) for (export_.args) |argument| {
        if (n.get(argument.position).transfer) try transferred.append(n.arena, .{ .name = argument.argument_name, .position = argument.position });
    };
    const frame = try argumentFrame(n, .{
        .wire_storage = !surface and plan.realm == .current,
        .argument_roots = !surface and plan.realm == .current,
        .deferred_conversions = plan.acquires_byte_lease,
        .converter_receiver = null,
        .transferred = transferred.items,
    });
    const has_native_arguments = !surface and parameters.len != 0;
    const inputs = try n.arena.alloc(ir.CppInboundInput(.inbound_argument), 1 + @as(usize, @intFromBool(has_native_arguments)));
    inputs[0] = .{ .prepare_arguments = frame };
    if (has_native_arguments) {
        const arguments = try n.arena.alloc(ir.CppNativeArgument(.inbound_argument), parameters.len);
        for (export_.args, parameters, arguments, 0..) |argument, parameter, *output, index| output.* = .{
            .name = argument.argument_name,
            .path = callables.argumentSource(raw, index).name,
            .parameter = parameter,
        };
        inputs[1] = .{ .native = arguments };
    }
    const failure = if (surface) try failures.inbound(n, .current, .js_exception, .empty) else try failures.nativeExport(n, export_);
    const is_void = n.get(export_.result_position).*.isVoid();
    const wire_result = try wireResult(n, export_.wire_result, export_.destroy_result_symbol, export_.result_position, export_.domain_errors);
    return n.create(ir.CppInboundCall(.inbound_argument){
        .frame = frame,
        .codec_failure = failure,
        .inputs = inputs,
        .status = if (surface) ir.CppCallStatus.javascript else .{ .realm = plan.realm, .throws = plan.throws, .non_returning = plan.non_returning },
        .callee = .{ .wire = .{
            .symbol = export_.dispatch_symbol,
            .arguments = export_.wire_args,
            .result = wire_result,
            .realm = plan.realm,
            .lazy_storage = try lazyStorage(n, export_.dispatch_symbol, export_.args, raw, plan),
            .context = .{
                .promise = false,
                .receiver = .none,
                .caller_frame = false,
                .deferred = if (plan.acquires_byte_lease) .local else .none,
            },
        } },
        .output = if (surface) .{ .encode_value = .{ .wire = .{
            .result = wire_result,
            .materializer = try mod_cpp_codecs.Materialize.planJavaScript(n, export_.result_position, .wire),
            .release_wire = !n.get(export_.result_position).zig.destruction.wire,
        } } } else if (is_void) .{ .constant = .{
            .value = if (plan.throws == .out_of_memory) .empty else .void,
            .release_wire = true,
        } } else .{ .decode_value = .{
            .result = wire_result,
            .decoder = try mod_cpp_codecs.decode(n, export_.result_position, failure),
            .release_wire = !mod_cpp_facts.get(n, export_.result_position).contains_collection,
        } },
        .failure_return = if (surface) .empty else failures.nativeReturn(n, export_),
    });
}

fn function(n: *Normalizer, f: *const ir.Function) PlanError!ir.CppFunction {
    const inputs = n.declaration(f.id).inputs;
    const checks: FunctionChecks = .{
        .required_count = if (inputs.arity.minimum != 0) if (inputs.arity.failure) |failure| .{
            .minimum = inputs.arity.minimum,
            .failure = failure,
        } else null else null,
        .receiver = try receiverCheck(n, f, if (f.class_member != null and f.class_member.?.member_kind.isSetter()) .false_value else .undefined_value, .empty),
    };
    return if (f.backend == .builtin) .builtin else if (f.isOverloaded()) .{ .overload = try overload(n, f, checks) } else body: {
        const host = try hostEntry(n, f);
        const entry = try lowerFunction(n, f, checks, receiverSource(host));
        const surface: ?ir.FunctionId = switch (f.id) {
            .function => |id| if (n.surface_factories.contains(id)) id else null,
            .overload => null,
        };
        const writable = if (n.declaration(f.id).member) |member| member.raw.options.writable else false;
        break :body .{ .call = .{
            .host = host,
            .entry = entry,
            .surface = if (surface) |id| .{
                .symbol = try mod_surfaces.functionFactorySymbol(n, id),
                .promise = switch (host.signature) {
                    .frame => |frame| frame.promise_body != null,
                    .getter => |body_symbol| body_symbol != null,
                    .setter => false,
                },
                .entry = try lowerFunction(n, f, checks, .surface),
            } else null,
            .writable = if (writable) .{
                .host = .{ .symbol = try n.print("{s}_writable_setter", .{f.host_symbol}), .signature = .setter },
                .entry = try writableCall(n, f, entry.cache.?),
            } else null,
        } };
    };
}

fn hostEntry(n: *Normalizer, function_: *const ir.Function) Error!ir.CppHost {
    const member = function_.class_member;
    const result = n.irType(n.get(function_.result_position).type);
    const rejects_exceptions = switch (function_.id) {
        .function => |id| n.declared_functions.items[id.index].options.profile == .webidl and
            (if (member) |facts| facts.member_kind != .constructor else true) and
            (function_.completion != null or (result.kind() == .branded_value and result.data.branded_value.brand.promise_value_type != null)),
        .overload => false,
    };
    const promise_body = if (rejects_exceptions) try n.print("{s}_body", .{function_.host_symbol}) else null;
    const frame: ir.CppHost.Frame = .{
        .linkage = if (member != null) .internal else if (function_.id == .overload) .internal_noexcept else .external_noexcept,
        .overload_inputs = function_.id == .overload,
        .callback_data = function_.callback_data_type != null and !function_.isOverloaded(),
        .promise_body = promise_body,
    };
    return .{
        .symbol = function_.host_symbol,
        .signature = if (member) |facts| switch (facts.member_kind) {
            .getter, .static_getter => .{ .getter = promise_body },
            .setter, .static_setter => .setter,
            .constructor, .method, .static_method => .{ .frame = frame },
        } else .{ .frame = frame },
    };
}

fn overload(n: *Normalizer, function_: *const ir.Function, checks: FunctionChecks) PlanError!ir.CppOverloadDispatch {
    const host = try hostEntry(n, function_);
    const dispatch = n.declaration(function_.id).overload_dispatch.?;
    const cases = try n.arena.alloc(ir.CppOverloadCase, function_.overload_cases.len);
    for (function_.overload_cases, dispatch.case_plans, cases, 0..) |case_id, case_plan, *output, index| {
        const declaration = n.get(case_id);
        const declared_inputs = n.declaration(declaration.id).inputs;
        const Comparison = @typeInfo(@FieldType(ir.CppOverloadCase, "comparisons")).pointer.child;
        var comparisons: std.ArrayList(Comparison) = .empty;
        for (dispatch.comparison_plans[index * cases.len ..][0..cases.len]) |comparison| {
            if (!comparison.active) continue;
            const arguments = try n.arena.alloc(@typeInfo(@FieldType(Comparison, "arguments")).pointer.child, comparison.differing_argument_indices.len);
            for (comparison.differing_argument_indices, arguments) |argument_index, *argument| {
                const source_index = @min(argument_index, declaration.args.len - 1);
                const source = declaration.args[source_index];
                argument.* = .{ .index = @intCast(argument_index), .selection = try mod_cpp_facts.Predicates.argumentSelection(n, source, declared_inputs.arguments[source_index].options.missing) };
            }
            try comparisons.append(n.arena, .{ .overlap_minimum = comparison.overlap_minimum, .overlap_maximum = comparison.overlap_maximum, .arguments = arguments });
        }
        output.* = .{
            .declaration = case_id,
            .symbol = declaration.host_symbol,
            .minimum_argument_count = case_plan.minimum_argument_count,
            .maximum_argument_count = case_plan.maximum_argument_count,
            .comparisons = comparisons.items,
        };
    }
    return .{
        .host = host,
        .name = if (function_.class_member != null) function_.js_name else function_.function_name,
        .prepare_receiver = if (checks.receiver != null) receiverSource(host) else null,
        .receiver = checks.receiver,
        .input_slot_count = dispatch.input_slot_count,
        .argument_count = dispatch.argument_count,
        .underflow = if (cases[dispatch.minimum_required_case_index].minimum_argument_count == 0) .none else if (checks.required_count) |check| .{ .reject = check } else .{ .dispatch = dispatch.minimum_required_case_index },
        .cases = cases,
    };
}

fn receiverHandle(n: *const Normalizer, function_: *const ir.Function) ir.CppReceiverHandle {
    if (n.declaration(function_.id).member) |member| {
        if (!member.raw.kind.isStatic() and member.raw.kind != .constructor) return switch (n.get(member.owner).representation) {
            .native => .native,
            .engine => .engine,
            .plain => .none,
        };
    }
    return if (function_.callback_data_type != null) .callback_data else .none;
}

fn receiverSource(host: ir.CppHost) ir.CppReceiverSource {
    return switch (host.signature) {
        .frame => .frame,
        .getter, .setter => .encoded,
    };
}

fn lowerFunction(n: *Normalizer, f: *const ir.Function, checks: FunctionChecks, this_source: ir.CppReceiverSource) PlanError!*const ir.CppInboundCall(.inbound_argument) {
    const planned = n.declaration(f.id).inputs;
    const member = n.declaration(f.id).member;
    const is_setter = if (member) |m| m.raw.kind.isSetter() else false;
    const this_value: ir.CppReceiverValue = switch (this_source) {
        .frame => .frame,
        .encoded => .encoded,
        .surface => .surface,
    };
    const constructor: ?ir.ClassId = if (member) |m| if (m.raw.kind == .constructor) m.owner else null else null;
    const illegal: ?ir.ClassId = if (member) |m| if (m.raw.options.illegal) m.owner else null else null;
    const cache = try cacheAccess(n, f);
    const callee: @FieldType(ir.CppInboundCall(.inbound_argument), "callee") = if (illegal) |owner|
        .{ .reject = try constructorFailure(n, owner, .construct) }
    else if (f.predicate) |predicate|
        .{ .predicate = mod_cpp_facts.Predicates.selection(n, predicate) orelse return n.unsupportedValue(predicate, "this value cannot distinguish a JavaScript input") }
    else if (f.backend == .zig)
        .{ .wire = .{
            .symbol = f.dispatch_symbol,
            .arguments = f.wire_args.?,
            .result = try wireResult(n, f.wire_result, f.destroy_result_symbol, f.result_position, f.domain_errors),
            .realm = f.call_plan.realm,
            .lazy_storage = try lazyStorage(n, f.dispatch_symbol, f.args, planned.arguments, f.call_plan),
            .context = .{
                .promise = f.completion != null,
                .receiver = receiverHandle(n, f),
                .caller_frame = f.has_caller_source_location,
                .deferred = if (f.call_plan.acquires_byte_lease) .local else .none,
            },
        } }
    else
        .{ .cpp = try implementation(n, f) };
    const wire_result: ?ir.CppWireResultId = switch (callee) {
        .wire => |wire| wire.result,
        .cpp, .builtin_constructor, .predicate, .reject, .load_cache, .store_cache => null,
    };
    const retains_receiver = switch (callee) {
        .wire => |wire| if (wire.lazy_storage) |storage| storage.receiver else false,
        .cpp, .builtin_constructor, .predicate, .reject, .load_cache, .store_cache => false,
    };
    const uses_receiver = checks.receiver != null or cache != null or f.this_argument != null;
    var frame: ?ir.CppArgumentFrameId = null;
    var inputs: std.ArrayList(ir.CppInboundInput(.inbound_argument)) = .empty;
    if (illegal == null) {
        if (f.predicate != null) {
            if (checks.required_count) |check| try inputs.append(n.arena, .{ .required_count = check });
        } else {
            if (checks.receiver) |check| try inputs.append(n.arena, .{ .check_receiver = check });
            if (cache) |access| try inputs.append(n.arena, .{ .read_cache = access });
            if (checks.receiver) |check| switch (check.class) {
                .native => |owner| try inputs.append(n.arena, .{ .borrow_receiver = owner }),
                .engine, .constructor => {},
            };
            if (constructor) |owner| try inputs.append(n.arena, .{ .construct_structure = .{
                .class = owner,
                .missing_new = try constructorFailure(n, owner, .call),
            } });
            const frame_id = try argumentFrame(n, .{
                .wire_storage = f.backend == .zig and wireArgumentStorage(n, f),
                .argument_roots = false,
                .deferred_conversions = f.call_plan.acquires_byte_lease,
                .converter_receiver = if (planned.frame.converter_receiver) if (f.backend == .cpp) .cpp else this_value else null,
                .transferred = &.{},
            });
            frame = frame_id;
            try inputs.append(n.arena, .{ .prepare_arguments = frame_id });
            if (f.this_argument) |argument| try appendArgument(n, &inputs, f, argument, @intCast(f.args.len), .{ .receiver = this_value }, .convert);
            if (retains_receiver) {
                try inputs.append(n.arena, .{ .retain_lazy_receiver = this_value });
            }
            if (!is_setter) if (checks.required_count) |check| try inputs.append(n.arena, .{ .required_count = check });
            if (f.new_target_argument) |argument| try appendArgument(n, &inputs, f, argument, @intCast(f.args.len + 1), .new_target, .convert);
            if (f.callee_argument) |argument| try appendArgument(n, &inputs, f, argument, @intCast(f.args.len + 2), .callee, .convert);
            for (planned.program) |step| {
                try appendArgument(n, &inputs, f, f.args[step.argument_index], step.argument_index, if (is_setter) .setter_value else null, step.operation);
            }
        }
    }
    return n.create(ir.CppInboundCall(.inbound_argument){
        .prepare_receiver = if (illegal == null and f.predicate == null and uses_receiver) this_source else null,
        .codec_failure = try failures.inbound(n, f.call_plan.realm, f.call_plan.throws, .empty),
        .inputs = inputs.items,
        .status = .{ .realm = f.call_plan.realm, .throws = f.call_plan.throws, .non_returning = f.call_plan.non_returning },
        .callee = callee,
        .frame = frame,
        .output = if (illegal != null)
            .{ .constant = .{ .value = .empty, .release_wire = false } }
        else if (f.completion != null)
            .{ .promise = switch (callee) {
                .wire => .wire,
                .cpp => .cpp,
                .builtin_constructor, .predicate, .reject, .load_cache, .store_cache => unreachable,
            } }
        else if (constructor) |owner|
            if (n.get(owner).representation == .native) .{ .attach_native = .{
                .construction = try nativeConstruction(n, owner),
                .result = wire_result.?,
            } } else .{ .javascript = .object }
        else if (is_setter)
            .{ .constant = .{ .value = .true_value, .release_wire = callee == .wire } }
        else
            .{ .encode_value = if (callee == .cpp or callee == .predicate) .{ .cpp = .{
                .materializer = try mod_cpp_codecs.Materialize.planJavaScript(n, f.result_position, .native),
                .string_inputs = try stringResultInputs(n, f),
            } } else .{ .wire = .{
                .result = wire_result.?,
                .materializer = try mod_cpp_codecs.Materialize.planJavaScript(n, f.result_position, .wire),
                .release_wire = !n.get(f.result_position).zig.destruction.wire,
            } } },
        .cache = cache,
        .failure_return = .empty,
    });
}

fn stringResultInputs(n: *Normalizer, function_: *const ir.Function) Error![]const u32 {
    if (n.projection(n.get(function_.result_position).type).conversion_codec != .string) return &.{};
    var inputs: std.ArrayList(u32) = .empty;
    for (function_.args, 0..) |argument, index| {
        if (!argument.conversion.rest and mod_plans.codecOf(n, n.get(argument.position).input) == .string) try inputs.append(n.arena, @intCast(index));
    }
    return inputs.items;
}

fn nativeConstruction(n: *Normalizer, class: ir.ClassId) Error!ir.CppNativeConstructionId {
    if (n.cpp_native_construction_index[class.index]) |existing| return existing;
    var getters: std.ArrayList(ir.FunctionId) = .empty;
    for (n.get(class).declarations) |id| {
        const member = n.get(id);
        if (!member.exposed or !n.declaration(member.id).member.?.raw.options.cache_on_construction) continue;
        try getters.append(n.arena, id);
    }
    const id: ir.CppNativeConstructionId = .of(n.cpp_native_constructions.items.len);
    try n.cpp_native_constructions.append(n.arena, .{ .class = class, .cached_getters = getters.items });
    n.cpp_native_construction_index[class.index] = id;
    return id;
}

fn wireArgumentStorage(n: *const Normalizer, f: *const ir.Function) bool {
    for (f.args) |argument| if (mod_cpp_facts.get(n, argument.valuePosition()).has_aggregate) return true;
    for ([_]?ir.Argument(.inbound_argument){ f.this_argument, f.new_target_argument, f.callee_argument }) |maybe| {
        if (maybe) |argument| if (mod_cpp_facts.get(n, argument.position).has_aggregate) return true;
    }
    return false;
}

fn appendArgument(n: *Normalizer, inputs: *std.ArrayList(ir.CppInboundInput(.inbound_argument)), f: *const ir.Function, argument: ir.Argument(.inbound_argument), index: u32, expression: ?ir.CppArgumentRead, operation: callables.ArgumentInputOperation) PlanError!void {
    const planned = n.declaration(f.id).inputs;
    const declaration = if (index < planned.arguments.len) planned.arguments[index] else null;
    const source: callables.ArgumentSource = if (declaration != null) callables.argumentSource(planned.arguments, index) else .{ .index = null, .presence = .required, .missing = .undefined, .name = argument.argument_name };
    const source_slot = if (declaration) |declared| if (declared.options.source) |input_source| switch (input_source) {
        .cached_slot => |slot| slot,
        .argument, .this_value => null,
    } else null else null;
    const selection = if (declaration) |declared| declared.options.selection else null;
    const raw: ir.CppArgumentRead = expression orelse if (source_slot) |slot|
        .{ .slot = slot }
    else if (source.index) |source_index|
        .{ .argument = .{ .index = source_index, .unchecked = argument.conversion.presence == .required and planned.arity.failure != null } }
    else
        .{ .receiver = .frame };
    const prepared_source: ?u32 = if (expression == null and source_slot == null) if (source.index) |source_index| (if (planned.prepared_sources[source_index]) source_index else null) else null else null;
    const prepared = prepared_source != null;
    const read: ir.CppArgumentRead = if (prepared_source) |source_index| .{ .prepared = source_index } else raw;
    const conversion: ir.CppArgumentConversion = if (selection) |request| selected: {
        break :selected .{ .selected = try argumentSelection(n, f, argument, source.name, try callables.selectionPlan(n, f.args, index, request), operation, prepared, raw) };
    } else switch (operation) {
        .convert => try argumentConversion(n, f, argument, source, read, if (declaration) |declared| declared.options.default_value else null),
        .prepare_buffer, .prepare_object_or_string => .{ .prepare = .{
            .value = try mod_cpp_codecs.Input.preparation(n, try mod_cpp_codecs.Input.value(n, argument.position, false, .empty)),
            .read = raw,
            .source_index = source.index.?,
            .path = source.name,
        } },
        .prepare_selected => unreachable,
    };
    try inputs.append(n.arena, .{ .javascript = .{
        .conversion = conversion,
        .index = index,
        .prepared_input = if (expression == null and source_slot == null and (f.id == .overload) and !argument.conversion.rest) source.index else null,
    } });
}

fn receiverCheck(n: *Normalizer, f: *const ir.Function, no_op_return: ir.CppReturn, failure_return: ir.CppReturn) PlanError!?ir.CppReceiverCheck {
    const position = f.call_plan.receiver orelse return null;
    const member = n.declaration(f.id).member.?;
    const class = try mod_cpp_codecs.requireClassReference(n, n.get(position).representation.leaf.native_receiver);
    return .{
        .class = switch (class) {
            .native => |id| .{ .native = id },
            .engine => |id| .{ .engine = id },
        },
        .brand = if (n.get(member.owner).brand) |brand| brand.cpp_match else null,
        .invalid_this = switch (member.raw.options.invalid_this) {
            .no_op => .{ .no_op = no_op_return },
            .throw => .throw,
            .failure => |failure| .{ .failure = failure },
        },
        .failure_return = failure_return,
    };
}

fn cacheAccess(n: *Normalizer, f: *const ir.Function) Error!?ir.CppCacheAccess {
    const member = n.declaration(f.id).member orelse return null;
    const name = member.raw.options.cache orelse return null;
    const class = n.get(member.owner);
    for (class.slots, 0..) |slot, index| {
        if (!std.mem.eql(u8, name, slot.slot_name)) continue;
        return .{
            .owner = member.owner,
            .slot = @intCast(index),
            .nullable_receiver = member.raw.kind.isStatic(),
            .read = cachedSlotRead(slot),
        };
    }
    unreachable;
}

fn writableCall(n: *Normalizer, f: *const ir.Function, cache: ir.CppCacheAccess) PlanError!*const ir.CppInboundCall(.inbound_argument) {
    const slot = n.classes.items[cache.owner.index].slots[cache.slot];
    const check = (try receiverCheck(n, f, .false_value, .false_value)) orelse
        return n.unsupported("writable cached members require a class receiver: {s}", .{f.js_name});
    return n.create(ir.CppInboundCall(.inbound_argument){
        .prepare_receiver = .encoded,
        .inputs = try n.arena.dupe(ir.CppInboundInput(.inbound_argument), &.{.{ .check_receiver = check }}),
        .codec_failure = try failures.inbound(n, .current, .js_exception, .false_value),
        .status = ir.CppCallStatus.javascript,
        .callee = .{ .store_cache = try cachedSlotWrite(n, slot) },
        .output = .{ .constant = .{ .value = .true_value, .release_wire = false } },
        .failure_return = .false_value,
    });
}

fn cachedSlotAccessors(n: *Normalizer, class: ir.Class, slot: ir.CachedSlot) PlanError!ir.CppCachedSlotAccessors {
    const symbols = try classes.slotSymbols(n, &class, slot);
    return .{
        .getter = .{
            .host = .{ .symbol = symbols.getter, .signature = .{ .getter = null } },
            .entry = try n.create(ir.CppInboundCall(.inbound_argument){
                .prepare_receiver = .encoded,
                .inputs = try n.arena.dupe(ir.CppInboundInput(.inbound_argument), &.{.{ .check_receiver = try slotReceiverCheck(n, class, slot, .empty) }}),
                .codec_failure = try failures.inbound(n, .current, .js_exception, .empty),
                .status = ir.CppCallStatus.javascript,
                .callee = .{ .load_cache = .{ .name = slot.slot_name, .read = cachedSlotRead(slot) } },
                .output = .{ .javascript = .value },
            }),
        },
        .setter = if (symbols.setter) |symbol| .{
            .host = .{ .symbol = symbol, .signature = .setter },
            .entry = try n.create(ir.CppInboundCall(.inbound_argument){
                .prepare_receiver = .encoded,
                .inputs = try n.arena.dupe(ir.CppInboundInput(.inbound_argument), &.{.{ .check_receiver = try slotReceiverCheck(n, class, slot, .false_value) }}),
                .codec_failure = try failures.inbound(n, .current, .js_exception, .false_value),
                .status = ir.CppCallStatus.javascript,
                .callee = .{ .store_cache = try cachedSlotWrite(n, slot) },
                .output = .{ .constant = .{ .value = .true_value, .release_wire = false } },
                .failure_return = .false_value,
            }),
        } else null,
    };
}

fn slotReceiverCheck(n: *Normalizer, class: ir.Class, slot: ir.CachedSlot, failure: ir.CppReturn) PlanError!ir.CppReceiverCheck {
    return .{
        .class = switch (slot.storage) {
            .constructor => .{ .constructor = class.id },
            .instance => switch (class.representation) {
                .native => .{ .native = class.id },
                .engine => .{ .engine = class.id },
                .plain => return n.unsupported("plain class instances cannot hold cached slots: {s}", .{slot.slot_name}),
            },
        },
        .brand = null,
        .invalid_this = .{ .failure = .{
            .kind = .type_error,
            .message = try n.print("Expected a {s} {s}", .{ class.class_name, switch (slot.storage) {
                .constructor => "constructor",
                .instance => "instance",
            } }),
        } },
        .failure_return = failure,
    };
}

fn cachedSlotRead(slot: ir.CachedSlot) ir.CppCachedSlotRead {
    return if (slot.access == .callback) (if (slot.optional) .optional_callback else .callback) else .value;
}

fn cachedSlotWrite(n: *Normalizer, slot: ir.CachedSlot) PlanError!ir.CppCachedSlotWrite {
    const input = try mod_cpp_codecs.Input.value(n, slot.assigned_position, true, .false_value);
    return .{
        .name = slot.slot_name,
        .nullable = slot.optional,
        .input = input,
        .output = switch (n.get(input).operation) {
            .value => |kind| switch (kind) {
                .any => .any,
                .engine_value, .branded => .value,
            },
            .branded_value, .callback => .value,
            .string => .string,
            .void, .discarded, .scalar, .converted, .optional, .enumeration, .node_path, .external_ref, .class_ref, .buffer, .aggregate, .lazy => unreachable,
        },
    };
}

fn completionMaterializer(n: *Normalizer, id: ir.EngineShimId, api: ir.CppCompletionApiId) PlanError!@FieldType(ir.CppCompletionMaterializer, "engine") {
    const shim = n.get(id);
    const implementation_ = n.cpp_engine_implementations[id.index];
    return .{
        .api = api,
        .arguments = implementation_.arguments.name,
        .argument = shim.outbound.args[0].argument_name,
        .callee = implementation_.signature.symbol,
        .exception_check = switch (shim.outbound.call_plan.throws) {
            .js_exception => .exception,
            .never, .out_of_memory => .termination,
        },
        .result = if (shim.outbound.call_plan.throws == .out_of_memory)
            .{ .allocation = try mod_cpp_codecs.Materialize.planJavaScript(n, shim.outbound.result_position, .native) }
        else if (n.get(shim.outbound.result_position).isVoid())
            .void
        else
            .{ .value = try mod_cpp_codecs.Materialize.planJavaScript(n, shim.outbound.result_position, .native) },
    };
}

fn completionEncoder(n: *Normalizer, id: ir.CompletionId, owner: *const ir.Function) PlanError!ir.CppCompletionEncoderId {
    if (n.cpp_completion_index[id.index]) |existing| return existing;
    const completion = n.get(id);

    const entries = try n.arena.alloc(ir.CppCompletionValue, 1 + owner.domain_errors.len);
    for (entries, 0..) |*output, tag| {
        const position = if (tag == 0) completion.payload else n.get(owner.domain_errors[tag - 1]).position;
        output.* = .{
            .encoder = try mod_cpp_codecs.encode(n, position),
            .cleanup = if (mod_cpp_facts.get(n, position).pending_release) position else null,
            .output = if (tag == 0)
                .{ .value = if (owner.domain_errors.len == 0) .direct else .tagged }
            else
                .{ .domain_error = .{ .tag = @intCast(tag), .declaration = try domainError(n, owner.domain_errors[tag - 1]) } },
        };
    }
    const value = entries[0].encoder;
    const value_type = if (n.get(completion.payload).isVoid()) try n.cppType(.monostate) else try resultValue(n, completion.payload);
    const codec: ir.CppCompletionEncoder = .{
        .completion = id,
        .api = completion.cpp_api.?,
        .wire = owner.wire_result,
        .value = if (n.get(value).operation == .leaf and n.get(value).operation.leaf == .nominal_handle) .{ .owned_handle = value_type } else .{ .value = value_type },
        .entries = entries,
    };
    const codec_id: ir.CppCompletionEncoderId = .of(n.cpp_completions.items.len);
    try n.cpp_completions.append(n.arena, codec);
    n.cpp_completion_index[id.index] = codec_id;
    return codec_id;
}

fn argumentConversion(n: *Normalizer, function_: *const ir.Function, argument: ir.Argument(.inbound_argument), source: callables.ArgumentSource, read: ir.CppArgumentRead, default_value: ?ir.DefaultValue) PlanError!ir.CppArgumentConversion {
    const inputs = mod_cpp_codecs.Input;
    const target: ir.CppArgumentDestination = if (function_.backend == .cpp) .{ .cpp = argument.argument_name } else .{ .wire = argument.argument_name };
    if (argument.conversion.rest) {
        const rest = argument.rest_position.?;
        const rest_read: ir.CppRestRead = if (function_.id == .overload) .overload_inputs else .call_frame;
        const conversion: ir.CppRestInput = switch (rest) {
            .typed => |position| typed: {
                const input = try inputs.value(n, n.get(position).representation.sequence, true, .false_value);
                break :typed .{ .element = .{
                    .target = target,
                    .value = input,
                    .read = rest_read,
                    .failure = .empty,
                    .path = restPath(n, input, argument.argument_name),
                } };
            },
            .values => if (target == .cpp) .{ .borrowed_values = argument.argument_name } else .{ .values = .{ .target = argument.argument_name, .read = rest_read, .lazy = null, .encoder = try mod_cpp_codecs.InputEncode.rest(n, rest) } },
            .count => .{ .count = .{ .encoder = try mod_cpp_codecs.InputEncode.rest(n, rest), .target = target } },
            .lazy => .{ .values = .{ .target = argument.argument_name, .read = rest_read, .lazy = try inputs.lazy(n, argument.position, true, .false_value), .encoder = try mod_cpp_codecs.InputEncode.rest(n, rest) } },
        };
        return .{ .rest = conversion };
    }
    const names_path = n.input_plans.items[n.get(argument.position).input.index].codec == .lazy and function_.backend != .cpp;
    const input = try inputs.value(n, argument.position, names_path, if (names_path) .false_value else .empty);
    return switch (n.get(input).operation) {
        .lazy => |deferred| .{ .lazy = .{
            .input = deferred.conversion,
            .read = read,
            .path = source.name,
            .target = target,
            .missing = switch (argument.conversion.presence) {
                .required => null,
                .optional => argumentMissing(argument, source),
                .default_value => unreachable,
            },
        } },
        .void, .discarded, .scalar, .converted, .optional, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .buffer, .aggregate => .{ .value = .{
            .input = input,
            .read = read,
            .path = source.name,
            .presence = switch (argument.conversion.presence) {
                .required => .required,
                .optional => .{ .optional = argumentMissing(argument, source) },
                .default_value => .{ .default_value = .{
                    .missing = argumentMissing(argument, source),
                    .value = try mod_cpp_codecs.Defaults.lower(n, argument.position, default_value.?),
                } },
            },
            .target = switch (target) {
                .cpp => |field| .{ .cpp = field },
                .wire => |field| .{ .wire = .{ .field = field, .local_type = try argumentType(n, argument) } },
            },
        } },
    };
}

fn argumentMissing(argument: ir.Argument(.inbound_argument), source: callables.ArgumentSource) ir.CppArgumentMissing {
    if (argument.is_projection and source.presence == .required) return .never;
    return switch (source.missing) {
        .undefined => .undefined,
        .undefined_or_null => .nullish,
        .omitted => .{ .omitted = source.index.? },
    };
}

fn lazyStorage(n: *Normalizer, symbol: []const u8, arguments: []const ir.Argument(.inbound_argument), raw: []const schema.Argument, call_plan: ir.CallPlan(.inbound_argument)) PlanError!?ir.CppLazyStorage {
    const converters = try lazyConverters(n, arguments, raw, call_plan.acquires_byte_lease);
    if (converters.len == 0) return null;
    return .{
        .symbol = try n.print("{s}_LazyStorage", .{symbol}),
        .converters = converters,
        .receiver = for (converters) |converter| {
            if (n.get(converter.conversion.value).call_receiver) break true;
        } else false,
    };
}

fn lazyApi(n: *const Normalizer, position: ir.InboundArgumentPlanId) struct { symbol: []const u8, result_wire: ir.WireTypeId } {
    return switch (n.get(n.get(position).api.?).representation) {
        inline .lazy_view, .lazy_rest => |lazy| .{ .symbol = lazy.symbol, .result_wire = lazy.result_wire },
        else => unreachable,
    };
}

fn lazyConverters(n: *Normalizer, arguments: []const ir.Argument(.inbound_argument), raw: []const schema.Argument, discard: bool) PlanError![]const ir.CppLazyConversion {
    var result: std.ArrayList(ir.CppLazyConversion) = .empty;
    for (arguments, 0..) |argument, index| {
        if (n.input_plans.items[n.get(argument.position).input.index].codec != .lazy) continue;
        const conversion = try mod_cpp_codecs.Input.lazy(n, argument.position, true, .false_value);
        const position = argument.valuePosition();
        const child_input = n.get(conversion.value.position).input;
        const child = n.input_plans.items[child_input.index];
        const name = callables.argumentSource(raw, index).name;
        const path = if (child.codec == .dictionary) child.path_override orelse name else name;
        const api = lazyApi(n, position);
        try result.append(n.arena, .{
            .index = @intCast(index),
            .position = position,
            .symbol = api.symbol,
            .conversion = conversion,
            .result_wire = api.result_wire,
            .path = if (argument.conversion.rest) restPath(n, conversion.value, path) else .{ .value = path },
            .prepared_input = mod_plans.inputFacts(n, child_input).resolves_iterator_method and usesPreparedInput(n, conversion.value),
            .rest = argument.conversion.rest,
            .discard = discard,
        });
    }
    return result.items;
}

fn restPath(n: *const Normalizer, id: ir.CppInputId, name: []const u8) ir.CppRestPath {
    return switch (n.get(id).operation) {
        .string => |conversion| .{ .element = .{ .name = name, .conversion = conversion } },
        .void, .discarded, .scalar, .converted, .optional, .enumeration, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .buffer, .aggregate, .lazy => .{ .value = name },
    };
}

fn usesPreparedInput(n: *const Normalizer, id: ir.CppInputId) bool {
    return switch (n.get(id).operation) {
        .aggregate, .lazy => true,
        .converted => |converted| usesPreparedInput(n, converted.match),
        .optional => |optional| usesPreparedInput(n, optional.value),
        .void, .discarded, .scalar, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .buffer => false,
    };
}

fn argumentSelection(n: *Normalizer, function_: *const ir.Function, argument: ir.Argument(.inbound_argument), path: []const u8, selection: callables.ArgumentSelectionPlan, operation: callables.ArgumentInputOperation, prepared: bool, read: ir.CppArgumentRead) PlanError!ir.CppArgumentSelection {
    const prepare = operation != .convert;
    const input = n.get(try mod_cpp_codecs.Input.value(n, argument.position, true, .false_value));
    const source_members = n.get(input.operation.aggregate).operation.union_type.members;
    const storage = try n.arena.alloc(ir.CppSelectedInputStorage, source_members.len);
    for (source_members, storage) |source, *output| output.* = .{
        .name = source.name,
        .input = try mod_cpp_codecs.Input.value(n, source.value.position, true, .empty),
    };
    const enumeration = n.get(selection.selector);
    const members = try n.arena.alloc(@typeInfo(@FieldType(ir.CppArgumentSelection, "members")).pointer.child, selection.members.len);
    for (selection.members, members) |selected, *member| {
        const source = storage[selected.member_index];
        const conversion = source.input;
        const values = try n.arena.alloc([]const u8, selected.values.len);
        for (selected.values, values) |index, *name| name.* = enumeration.enumeration_values[index].value_name;
        const buffer = n.get(conversion).operation == .buffer;
        member.* = .{
            .name = source.name,
            .values = values,
            .operation = if (prepare and buffer)
                .{ .prepare = try mod_cpp_codecs.Input.preparation(n, conversion) }
            else if (prepare or !prepared or buffer)
                .{ .convert = conversion }
            else
                .none,
        };
    }
    return .{
        .selector = try inputValue(n, function_.args[selection.source_index].position),
        .target = argument.argument_name,
        .path = path,
        .source_name = selection.source_name,
        .frame = if (prepare or !prepared) .{
            .read = read,
            .storage = storage,
            .retain = if (prepare) read.argument.index else null,
        } else null,
        .members = members,
    };
}

fn argumentType(n: *Normalizer, argument: ir.Argument(.inbound_argument)) PlanError!ir.CppTypeId {
    const value_type = if (argument.rest_position) |rest| switch (rest) {
        .values => try n.cppType(.any_sequence),
        .typed => |position| try n.cppType(.{ .const_span = try inputValue(n, n.get(position).representation.sequence) }),
        .count => try n.cppType(.size),
        .lazy => |position| try inputValue(n, position),
    } else try inputValue(n, argument.position);
    return if (argument.conversion.presence == .optional) n.cppType(.{ .optional = value_type }) else value_type;
}

fn domainError(n: *Normalizer, id: ir.DomainErrorId) PlanError!ir.CppDomainError {
    const failure = n.get(id);
    return .{
        .name = failure.error_name,
        .payload = if (n.get(failure.position).isVoid()) null else try resultValue(n, failure.position),
        .raise_symbol = try mod_cpp_codecs.errorFactory(n, id, true),
    };
}

fn implementation(n: *Normalizer, function_: *const ir.Function) PlanError!ir.CppImplementationId {
    if (n.declaration(function_.id).cpp_implementation) |id| return id;
    const qualified_name = switch (function_.id) {
        .function => try n.print("{s}_{s}", .{ function_.module_name, function_.function_name }),
        .overload => try n.print("{s}_{s}_overload_{s}", .{ function_.module_name, function_.function_name, function_.case_name }),
    };
    const member = n.declaration(function_.id).member;
    const constructor = if (member) |value| value.raw.kind == .constructor else false;
    const call_context: @FieldType(@FieldType(ir.CppImplementation, "context"), "call") = .{
        .receiver = receiverHandle(n, function_),
        .caller_source_origin = function_.has_caller_source_location,
    };
    const context: @FieldType(ir.CppImplementation, "context") = context: {
        const facts = member orelse break :context .{ .call = call_context };
        if (facts.raw.kind.isStatic()) break :context .{ .call = call_context };
        const owner = facts.owner;
        break :context switch (n.get(owner).representation) {
            .native => .{ .call = call_context },
            .plain => if (constructor) .{ .plain_construct = owner } else .{ .call = call_context },
            .engine => if (constructor) .{ .engine_construct = owner } else .{ .engine_call = owner },
        };
    };
    var fields: std.ArrayList(ir.CppTypedField) = .empty;
    for ([_]?ir.Argument(.inbound_argument){ function_.this_argument, function_.new_target_argument, function_.callee_argument }) |argument| {
        if (argument) |value| try fields.append(n.arena, .{ .name = value.argument_name, .type = try argumentType(n, value) });
    }
    for (function_.args) |argument| try fields.append(n.arena, .{ .name = argument.argument_name, .type = try argumentType(n, argument) });
    const errors = try n.arena.alloc(ir.CppDomainError, if (function_.completion == null) function_.domain_errors.len else 0);
    for (function_.domain_errors[0..errors.len], errors) |failure, *output| output.* = try domainError(n, failure);
    const result = n.get(function_.result_position);
    const declaration: ir.CppImplementation = .{
        .symbol = try n.print("bunBindgenCpp_{s}", .{qualified_name}),
        .arguments = try n.print("BunBindgenCpp_{s}_Arguments", .{qualified_name}),
        .context = context,
        .fields = fields.items,
        .result = if (function_.completion) |completion| .{ .completion = try completionEncoder(n, completion, function_) } else .{ .sync = .{
            .type = switch (context) {
                .engine_construct => |class_id| try n.cppType(.{ .pointer = try n.cppType(.{ .wrapper_class = class_id }) }),
                .plain_construct => try n.cppType(.{ .pointer = try n.cppType(.js_object) }),
                .call, .engine_call => try resultValue(n, function_.result_position),
            },
            .outcome = if (errors.len == 0) null else .{ .name = try n.print("BunBindgenCpp_{s}_Return", .{qualified_name}), .errors = errors },
            .returns_value = constructor or (!result.isVoid() and n.irType(result.type).kind() != .discarded),
            .requires_context = requiresResultContext(n, function_),
        } },
    };
    const id: ir.CppImplementationId = .of(n.cpp_implementations.items.len);
    try n.cpp_implementations.append(n.arena, declaration);
    n.declaration(function_.id).cpp_implementation = id;
    return id;
}

fn elementAliases(n: *Normalizer, export_: *const ir.NativeExport, symbol: []const u8) PlanError![]const ir.CppTypedField {
    var aliases: std.ArrayList(ir.CppTypedField) = .empty;
    for (export_.args) |argument| switch (n.get(argument.position).representation) {
        .sequence => |child| try aliases.append(n.arena, .{ .name = try n.print("{s}_{s}_Element", .{ symbol, argument.argument_name }), .type = try inputValue(n, child) }),
        .converted, .optional, .dictionary, .union_type, .record, .record_entry, .rest => {},
        .leaf => |leaf| switch (leaf) {
            .void, .scalar, .enumeration, .js_value_view, .string_view, .bytes_view, .native_slice_view, .byte_lease, .callback_view, .class_view, .external_view, .nominal_borrow, .nominal_owned, .native_receiver, .lazy_field, .lazy_view, .lazy_rest => {},
        },
    };
    return aliases.items;
}

fn requiresResultContext(n: *const Normalizer, function_: *const ir.Function) bool {
    if (mod_cpp_facts.get(n, function_.result_position).result_requires_root_context) return true;
    for (function_.domain_errors) |failure| if (mod_cpp_facts.get(n, n.get(failure).position).result_requires_root_context) return true;
    return false;
}
