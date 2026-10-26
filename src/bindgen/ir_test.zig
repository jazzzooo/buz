//! Normalization tests: each case normalizes a schema fixture and checks the
//! plain-data IR the generator renders and the comptime bind consumes.
const std = @import("std");
const ir = @import("bindgen_ir");
const b = @import("bindgen_schema");
const test_schema = @import("bindgen_test_schema");
const archetypes = @import("binding_schema_archetypes");
const normalize = @import("normalize.zig");
const emitter = @import("emitter.zig");
const structural = @import("structural.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test {
    _ = @import("value_encoding.zig");
    _ = @import("normalize/intern.zig");
}

const linux: ir.Input = .{ .target = .x86_64_linux };

test "surface-only collection elements are normalized before planning" {
    const element = comptime b.enumeration("SurfaceElement", .{b.enumerationValue("item", "item")});
    const surface = comptime b.objectSurface("EmptyCollections", .{
        b.surfaceEmptyArray("items", element, .{}),
    }, .{ .installation = .direct });
    var f: Fixture = try .init(&.{b.moduleWithSurfaces("SurfaceOnly", .{surface})}, linux);
    defer f.deinit();
    const type_id = try f.typeId(element);
    try expect(f.ir.get(type_id).data == .enumeration);
    try expectEqualStrings("SurfaceElement", try f.typeScript(element));
    const declaration = for (f.ir.typescript_declarations) |declaration| {
        if (declaration == .enumeration and std.mem.eql(u8, declaration.enumeration.name, "SurfaceElement")) break declaration.enumeration;
    } else return error.TestMissingTypeScriptDeclaration;
    try expectEqual(@as(usize, 1), declaration.values.len);
    try expectEqualStrings("item", declaration.values[0].string);
}

fn classProperty(installations: []const ir.CppClassInstallation, key: ir.CppClassPropertyKey) !@FieldType(ir.CppClassInstallation, "property") {
    for (installations) |installation| switch (installation) {
        .property => |property| if (structural.eql(property.key, key)) return property,
        .aliases, .to_string_tag => {},
    };
    return error.TestMissingClassProperty;
}

fn classTableEntry(table: []const ir.CppClassTableEntry, name: []const u8) !ir.CppClassTableEntry {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return error.TestMissingClassProperty;
}

fn domainErrorFactory(factories: []const ir.DomainErrorFactory, symbol: []const u8) !*const ir.DomainErrorFactory {
    for (factories) |*factory| {
        if (std.mem.eql(u8, factory.symbol, symbol)) return factory;
    }
    return error.TestMissingDomainErrorFactory;
}

fn outboundResult(program: ir.CppOutboundCall) !ir.CppOutboundValue {
    for (program.entries) |entry| switch (entry.operation) {
        .invoke => |invoke| if (invoke.result) |result| return result,
        .schedule => {},
    };
    return error.TestMissingOutboundResult;
}

test "conversion rules distinguish plans while identical storage shares an API type" {
    var f: Fixture = try .init(&.{b.module("profile_storage", .{
        b.function("exact", .{b.argument("value", b.boolean, .{})}, b.none, .{ .profile = .exact }),
        b.function("webidl", .{b.argument("value", b.boolean, .{})}, b.none, .{ .profile = .webidl }),
    })}, linux);
    defer f.deinit();
    const exact = try f.function("profile_storage", "exact");
    const webidl = try f.function("profile_storage", "webidl");
    try expect(exact.args[0].position.index != webidl.args[0].position.index);
    try expectEqual(f.ir.get(exact.args[0].position).api, f.ir.get(webidl.args[0].position).api);
    try expectEqualStrings("boolean", f.ir.get(exact.args[0].position).typescript);
    const exact_conversion = f.scalar((try f.inputConversion(exact, 0)).value.input);
    const webidl_conversion = f.scalar((try f.inputConversion(webidl, 0)).value.input);
    try expectEqual(ir.CppBuiltin.strict_boolean, f.ir.get(exact_conversion.operation.idl).builtin);
    try expect(webidl_conversion.operation.boolean == .webidl);
}

test "native entries root JavaScript arguments before allocating wire storage" {
    var f: Fixture = try .init(&.{b.moduleWithNativeExports("inbound_entries", .{}, .{
        b.nativeExportWithOptions("current", .{
            b.argument("first", b.sequence(b.dom_string), .{}),
            b.argument("values", b.sequence(b.invocation_any), .{}),
        }, b.none, .{ .realm = .current, .throws = .js_exception }),
    })}, linux);
    defer f.deinit();
    const current_export = try f.nativeExport("inbound_entries", "current");
    const current_entry = f.ir.cpp_native_exports[current_export.id.index].?.entry;
    const cpp_source = try f.emitted("SchemaBindings0.cpp");
    const start = std.mem.indexOf(u8, cpp_source, current_entry.signature.symbol) orelse return error.TestMissingNativeEntry;
    const body_start = cpp_source[start..];
    const end = std.mem.indexOf(u8, body_start, "\n}\n") orelse return error.TestMissingNativeEntry;
    const body = body_start[0..end];
    const rooting = std.mem.indexOf(u8, body, ".tryProtect(") orelse return error.TestMissingNativeRoots;
    const allocation = std.mem.indexOf(u8, body, "wireStorage.allocateZeroed<") orelse return error.TestMissingNativeAllocation;
    try expect(rooting < allocation);
}

test "outbound operands share wire types and require a scope for borrowed results" {
    const arguments = comptime .{
        b.argument("value", b.invocation_any, .{}),
        b.argument("text", b.dom_string, .{}),
        b.argument("bytes", b.buffer(.copy), .{}),
        b.argument("items", b.sequence(b.dom_string), .{}),
        b.argument("record", b.record(b.dom_string, b.int32), .{}),
        b.argument("entry", b.dictionary("WireEntry", .{
            b.dictionaryField("value", b.invocation_any, .{ .required = true }),
            b.dictionaryField("text", b.dom_string, .{ .required = true }),
        }), .{}),
    };
    const callback_type = comptime b.callback("PositionCallback", arguments, b.any, .{
        .receiver = b.invocation_any,
    });
    var f: Fixture = try .init(&.{b.moduleWithEngineShims("positions", .{
        b.function("accept", .{ b.argument("value", b.any, .{}), b.argument("callback", callback_type, .{}) }, b.any, .{}),
    }, .{
        b.engineShim("echo", arguments, b.any, .{ .throws = .js_exception, .realm = .current, .affinity = .vm }),
    })}, linux);
    defer f.deinit();
    const function = try f.function("positions", "accept");
    const shim = try f.engineShim("positions", "echo");
    const callback = try f.callback(callback_type);
    const callback_call = f.callbackCall(callback);
    const input = f.ir.get(function.args[0].position);
    const operand = f.ir.get(shim.outbound.args[0].position);
    const result = f.ir.get(shim.outbound.result_position);
    try expectEqual(ir.Representation(.inbound_argument){ .leaf = .{ .js_value_view = .any } }, input.representation);
    try expectEqual(ir.Representation(.outbound_argument){ .leaf = .{ .js_value_operand = .any } }, operand.representation);
    try expectEqual(ir.Representation(.outbound_result){ .leaf = .{ .js_value_result = .any } }, result.representation);
    try expect(input.wire.index != operand.wire.index);
    try expectEqual(operand.wire, f.ir.get(callback_call.args[0].position).wire);
    const callback_fields = f.ir.get(callback_call.wire_args).structure.fields;
    const engine_fields = f.ir.get(shim.outbound.wire_args).structure.fields;
    const callback_program = (try f.callbackProgram(callback)).entries[0].operation.invoke.callee.callback;
    try expectEqual(arguments.len, callback_program.capacity.fixed);
    for (callback_call.args, callback_program.arguments, engine_fields, callback_fields[2..]) |argument, cpp_argument, engine_field, callback_field| {
        try expectEqual(f.ir.get(argument.position).wire, callback_field.type);
        try expectEqual(engine_field.type, callback_field.type);
        try expectEqual(f.ir.get(argument.position).wire, f.ir.get(cpp_argument.materializer).source.wire.type);
    }
    try expectEqual(operand.wire, f.ir.get(callback_call.call_plan.receiver.?).wire);
    try expect(shim.outbound.call_plan.requires_scope);
    const native_result = f.ir.get((try outboundResult(f.ir.cpp_engine_calls[shim.id.index])).conversion.native.encoder);
    try expectEqual(result.wire, native_result.wire);
    try expect(f.ir.get(native_result.value_type).* == .js_value);
}

test "outbound roots and their collections decode as call-scoped views" {
    const callback = comptime b.callback("ScopedReturnedCallback", .{}, b.none, .{ .receiver = null });
    const class = comptime b.classRef(test_schema.counter);
    var f: Fixture = try .init(&.{ test_schema.schema, b.moduleWithEngineShims("scoped_results", .{}, .{
        b.engineShim("callback", .{}, callback, .{ .realm = .current, .throws = .js_exception, .affinity = .vm }),
        b.engineShim("class", .{}, class, .{ .realm = .current, .throws = .js_exception, .affinity = .vm }),
        b.engineShim("callbacks", .{}, b.sequence(callback), .{ .realm = .current, .throws = .js_exception, .affinity = .vm }),
        b.engineShim("classes", .{}, b.record(b.dom_string, class), .{ .realm = .current, .throws = .js_exception, .affinity = .vm }),
    }) }, linux);
    defer f.deinit();
    const returned_callback = f.ir.get((try f.engineShim("scoped_results", "callback")).outbound.result_position);
    const returned_class = f.ir.get((try f.engineShim("scoped_results", "class")).outbound.result_position);
    try expect(returned_callback.zig.leaf.?.decode == .borrow_callback);
    try expect(returned_class.zig.leaf.?.decode == .borrow_class);
    try expect(f.ir.get(returned_callback.api).representation == .callback_view);
    try expect(f.ir.get(returned_class.api).representation == .class_view);
    try expect((try f.engineShim("scoped_results", "callback")).outbound.call_plan.requires_scope);
    try expect((try f.engineShim("scoped_results", "class")).outbound.call_plan.requires_scope);
    for ([_]*const ir.OutboundResultPlan{ returned_callback, returned_class }) |plan| {
        try expect(!plan.zig.destruction.api);
        try expect(plan.zig.destruction.wire);
    }
    inline for (.{ "callbacks", "classes" }) |name| {
        const shim = try f.engineShim("scoped_results", name);
        const result = f.ir.get(shim.outbound.result_position);
        try expect(shim.outbound.call_plan.requires_scope);
        try expect(!result.zig.destruction.api);
        try expect(result.zig.destruction.wire);
        switch (f.ir.get(result.api).representation) {
            .sequence, .record => |storage| {
                const collection = storage.scoped;
                const owner = f.ir.get(collection.owner);
                try expectEqual(result.wire, owner.wire);
                try expect(owner.zig.destruction.api);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "clone plans retain owned resources without duplicating exclusive handles" {
    const fixture = comptime b.moduleWithNativeExports("clone_plans", .{}, .{b.nativeExportWithOptions(
        "inspect",
        .{
            b.argument("owned", b.sequence(owned_native_handle), .{}),
            b.argument("borrowed", b.sequence(other_native_handle), .{}),
            b.argument("strings", b.sequence(b.thread_safe_dom_string), .{}),
        },
        b.none,
        .{ .realm = .current, .throws = .js_exception },
    )});
    var f: Fixture = try .init(&.{fixture}, linux);
    defer f.deinit();
    const declaration = try f.nativeExport("clone_plans", "inspect");
    const owned = f.ir.get(declaration.args[0].position);
    try expect(owned.zig.clone == null);
    try expect(f.ir.get(owned.representation.sequence).zig.clone == null);
    const borrowed = f.ir.get(declaration.args[1].position);
    try expect(borrowed.zig.clone.?.leaf == null);
    try expect(f.ir.get(borrowed.representation.sequence).zig.clone.?.leaf == .value);
    const borrowed_type = try f.typeId(other_native_handle);
    const borrowed_handle = f.at(borrowed_type).data.nominal_handle;
    try expectEqual(borrowed_handle.wire, f.ir.get(f.ir.get(borrowed.representation.sequence).wire).pointer.child);
    const strings = f.ir.get(declaration.args[2].position);
    try expect(strings.zig.clone.?.leaf == null);
    const string = f.ir.get(strings.representation.sequence);
    try expect(string.zig.clone.?.leaf == .allocate);
    try expect(!string.zig.clone.?.raises_exception);
    try expect(f.ir.get(string.zig.clone.?.target).zig.leaf.?.release == .string);
    try expectEqual(@as(usize, 1), f.ir.cpp_resources.len);
    try expectEqual((try f.typeOf(owned_native_handle)).data.nominal_handle.ownership.owned, f.ir.cpp_resources[0].nominal.ownership);
    const document = try @import("document.zig").create(f.arena.allocator(), &f.ir);
    const projected_handle = for (document.types) |type_| {
        if (type_.data == .nominal_handle and std.mem.eql(u8, type_.data.nominal_handle.nominal_handle_name, borrowed_handle.nominal_handle_name)) break type_.data.nominal_handle;
    } else return error.TestMissingType;
    try expectEqualStrings(try f.wireSpelling(borrowed_handle.wire), try document.wire_types[projected_handle.wire.index].opaque_handle.alloc(f.arena.allocator()));
}

test "engine scope requirements follow argument and result positions" {
    var f: Fixture = try .init(&.{b.moduleWithEngineShims("scopes", .{}, .{
        b.engineShim("nativeText", .{b.argument("value", b.thread_safe_dom_string, .{})}, b.thread_safe_dom_string, .{ .realm = .none, .throws = .out_of_memory, .affinity = .any, .check_traps = false }),
        b.engineShim("inspect", .{b.argument("value", b.engine_value, .{})}, b.size, .{ .realm = .current, .throws = .never, .check_traps = false, .affinity = .vm }),
        b.engineShim("produce", .{}, b.engine_value, .{ .realm = .current, .throws = .js_exception, .affinity = .vm }),
    })}, linux);
    defer f.deinit();
    const native = try f.engineShim("scopes", "nativeText");
    const inspect = try f.engineShim("scopes", "inspect");
    const produce = try f.engineShim("scopes", "produce");
    try expect(f.ir.get(native.outbound.args[0].position).representation.leaf == .string_operand);
    try expect(!native.outbound.call_plan.requires_scope);
    try expect(f.ir.get(inspect.outbound.args[0].position).zig.leaf.?.encode == .value_operand);
    try expect(inspect.outbound.call_plan.requires_scope);
    try expect(f.ir.get(produce.outbound.result_position).zig.leaf.?.decode == .value_result);
    try expect(produce.outbound.call_plan.requires_scope);
    const native_call = f.ir.cpp_engine_calls[native.id.index].entries[0].operation.invoke.callee.native;
    try expect(native_call.context == .none);
    try expect(native_call.allocation);
    const inspect_call = f.ir.cpp_engine_calls[inspect.id.index].entries[0].operation.invoke.callee.native;
    try expect(inspect_call.context.current == .unchecked);
    try expect(!inspect_call.allocation);
    const produce_call = f.ir.cpp_engine_calls[produce.id.index].entries[0].operation.invoke.callee.native;
    try expect(produce_call.context.current == .exception);
}

/// A schema set normalized for one target.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    ir: ir.Ir,
    type_index: @FieldType(normalize.Normalizer, "type_index"),

    fn init(comptime modules: []const b.Module, input: ir.Input) !Fixture {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        var stems: [modules.len][]const u8 = undefined;
        for (modules, &stems) |module, *stem| stem.* = module.name;
        var normalizer: normalize.Normalizer = .{ .arena = arena.allocator(), .modules = modules, .source_stems = &stems, .input = input };
        switch (try normalizer.normalize()) {
            .ir => |normalized| return .{ .arena = arena, .ir = normalized, .type_index = normalizer.type_index },
            .diagnostics => |diagnostics| {
                for (diagnostics) |diagnostic| std.debug.print("{s}: {s}\n", .{ diagnostic.location, diagnostic.message });
                return error.TestUnexpectedDiagnostic;
            },
        }
    }

    fn wireSpelling(f: *Fixture, id: ir.WireTypeId) ![]const u8 {
        return emitter.renderWireType(&f.ir, f.arena.allocator(), id);
    }

    fn emitted(f: *Fixture, name: []const u8) ![]const u8 {
        var emission: emitter.Emitter = .{ .ir = &f.ir, .arena = f.arena.allocator(), .fingerprint = 0, .cpp_shard_count = 1 };
        for (try emitter.emitAll(&emission)) |file| {
            if (std.mem.eql(u8, file.name, name)) return file.data;
        }
        return error.TestMissingEmittedFile;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    /// The interned semantic type structurally equal to `t`.
    fn typeId(f: *const Fixture, t: b.Type) !ir.TypeId {
        return .of(f.type_index.get(t) orelse {
            std.debug.print("no {t} semantic type\n", .{t});
            return error.TestMissingSemanticType;
        });
    }

    fn typeOf(f: *const Fixture, t: b.Type) !*const ir.Type {
        return f.at(try f.typeId(t));
    }

    fn at(f: *const Fixture, id: ir.TypeId) *const ir.Type {
        return &f.ir.types[id.index];
    }

    fn inputConversion(f: *const Fixture, function_: *const ir.Function, index: usize) !ir.CppArgumentConversion {
        const call = switch (f.ir.functionCpp(function_).*) {
            .call => |call| call.entry,
            .builtin, .overload => return error.TestMissingInputConversion,
        };
        for (call.inputs) |input| switch (input) {
            .javascript => |argument| switch (argument.conversion) {
                .value, .lazy, .rest => if (argument.index == index) return argument.conversion,
                .prepare, .selected => {},
            },
            .prepare_arguments, .retain_lazy_receiver, .check_receiver, .read_cache, .borrow_receiver, .construct_structure, .required_count, .native => {},
        };
        return error.TestMissingInputConversion;
    }

    fn findDefinition(f: *const Fixture, name: []const u8) ?*const ir.CppTypeDefinition {
        for (f.ir.cpp_type_definitions) |*definition_| if (std.mem.eql(u8, definition_.name, name)) return definition_;
        return null;
    }

    fn definition(f: *const Fixture, name: []const u8) !*const ir.CppTypeDefinition {
        return f.findDefinition(name) orelse error.TestMissingCppDefinition;
    }

    fn resultMaterializer(f: *const Fixture, function_: *const ir.Function) ir.CppMaterializerId(.inbound_result) {
        return switch (f.ir.functionCpp(function_).call.entry.output.encode_value) {
            .wire => |value| value.materializer,
            .cpp => |value| value.materializer,
        };
    }

    fn requiredCheck(f: *const Fixture, function_: *const ir.Function) ?ir.CppRequiredArgumentCheck {
        for (f.ir.functionCpp(function_).call.entry.inputs) |input| switch (input) {
            .required_count => |check| return check,
            .prepare_arguments, .retain_lazy_receiver, .check_receiver, .read_cache, .borrow_receiver, .construct_structure, .javascript, .native => {},
        };
        return null;
    }

    fn callbackProgram(f: *const Fixture, callback_: *const ir.Callback) !ir.CppOutboundCall {
        return f.ir.cpp_callback_calls[callback_.id.index] orelse error.TestMissingCallbackProgram;
    }

    fn callbackCall(f: *const Fixture, callback_: *const ir.Callback) *const ir.OutboundCall {
        return &f.ir.callback_calls[callback_.id.index];
    }

    fn engineArgument(f: *const Fixture, shim: *const ir.EngineShim, index: usize) *const ir.CppDecodePlan(.outbound_argument) {
        return f.decodePlan(f.ir.cpp_engine_calls[shim.id.index].entries[0].operation.invoke.callee.native.arguments[index].decoder.position);
    }

    fn decodePlan(f: *const Fixture, position: anytype) *const ir.CppDecodePlan(@TypeOf(position).role) {
        return &f.ir.get(position).cpp.decode.?;
    }

    fn resultDecoder(f: *const Fixture, position: ir.InboundResultPlanId) *const ir.CppResultDecoder {
        return &f.ir.get(position).cpp.decoder_helper.?;
    }

    fn aggregate(f: *const Fixture, id: ir.CppInputId) *const ir.CppInputAggregate {
        return f.ir.get(f.ir.get(id).operation.aggregate);
    }

    fn scalar(f: *const Fixture, id: ir.CppInputId) ir.CppScalarConversion {
        return f.ir.get(id).operation.scalar;
    }

    fn scalarType(f: *const Fixture, id: ir.CppInputId) *const ir.CppType {
        return f.ir.get(f.scalar(id).operation.idl);
    }

    fn typeScript(f: *const Fixture, t: b.Type) ![]const u8 {
        return f.ir.typeScript(try f.typeId(t));
    }

    fn argumentPosition(f: *const Fixture, t: b.Type) !?ir.InboundArgumentPlanId {
        return f.ir.argumentPosition(try f.typeId(t));
    }

    fn resultPosition(f: *const Fixture, t: b.Type) !?ir.InboundResultPlanId {
        return f.ir.resultPosition(try f.typeId(t));
    }

    fn function(f: *const Fixture, module_name: []const u8, function_name: []const u8) !*const ir.Function {
        for (f.ir.functions) |*candidate| {
            if (candidate.class_member == null and std.mem.eql(u8, candidate.module_name, module_name) and
                std.mem.eql(u8, candidate.function_name, function_name)) return candidate;
        }
        return error.TestMissingFunction;
    }

    fn boundFunction(f: *const Fixture, bound: b.BoundFunction) !*const ir.Function {
        return f.function(bound.module, bound.function.name);
    }

    fn case(f: *const Fixture, function_: *const ir.Function, index: usize) *const ir.Function {
        return f.ir.get(function_.overload_cases[index]);
    }

    fn class(f: *const Fixture, module_name: []const u8, class_name: []const u8) !*const ir.Class {
        for (f.ir.classes) |*candidate| {
            if (std.mem.eql(u8, candidate.module_name, module_name) and std.mem.eql(u8, candidate.class_name, class_name)) return candidate;
        }
        return error.TestMissingClass;
    }

    fn member(f: *const Fixture, owner: *const ir.Class, member_name: []const u8) !*const ir.Function {
        for (owner.declarations) |id| {
            const candidate = f.ir.get(id);
            if (std.mem.eql(u8, candidate.js_name, member_name)) return candidate;
        }
        return error.TestMissingMember;
    }

    fn memberKind(f: *const Fixture, owner: *const ir.Class, member_name: []const u8, kind: ir.ClassMemberKind) !*const ir.Function {
        for (owner.declarations) |id| {
            const candidate = f.ir.get(id);
            if (std.mem.eql(u8, candidate.js_name, member_name) and candidate.class_member.?.member_kind == kind) return candidate;
        }
        return error.TestMissingMember;
    }

    fn engineShim(f: *const Fixture, module_name: []const u8, shim_name: []const u8) !*const ir.EngineShim {
        for (f.ir.engine_shims) |*candidate| {
            if (std.mem.eql(u8, candidate.module_name, module_name) and std.mem.eql(u8, candidate.shim_name, shim_name)) return candidate;
        }
        return error.TestMissingEngineShim;
    }

    fn nativeExport(f: *const Fixture, module_name: []const u8, export_name: []const u8) !*const ir.NativeExport {
        for (f.ir.native_exports) |*candidate| {
            if (std.mem.eql(u8, candidate.module_name, module_name) and std.mem.eql(u8, candidate.export_name, export_name)) return candidate;
        }
        return error.TestMissingNativeExport;
    }

    fn callback(f: *const Fixture, t: b.Type) !*const ir.Callback {
        return f.ir.get((try f.typeOf(t)).data.callback);
    }
};

/// The fingerprint the generator would link a schema set with.
fn fingerprint(comptime modules: []const b.Module, input: ir.Input) !u64 {
    var f: Fixture = try .init(modules, input);
    defer f.deinit();
    return normalize.fingerprint(f.ir);
}

fn testSchema() !Fixture {
    return .init(&.{test_schema.schema}, linux);
}

test "synchronous C++ domain errors do not require wire factories" {
    const failure = comptime b.domainError("invalid", b.dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    });
    const options: b.FunctionOptions = comptime .{ .backend = .cpp, .errors = b.domainErrors(.{failure}) };
    var f: Fixture = try .init(&.{b.module("cpp_errors", .{
        b.function("value", .{}, b.int32, options),
        b.function("empty", .{}, b.none, options),
        b.function("overloaded", b.overloads(.{
            b.overloadCase("number", .{b.argument("input", b.int32, .{})}),
            b.overloadCase("string", .{b.argument("input", b.dom_string, .{})}),
        }, .{}), b.int32, options),
    })}, linux);
    defer f.deinit();
    try expectEqual(@as(usize, 0), f.ir.domain_error_factories.len);
    try expectEqual(@as(usize, 1), f.ir.cpp_domain_error_factories.len);
    try expect(f.ir.cpp_domain_error_factories[0].operation.error_object.message.payload == .string);
    for (f.ir.modules[0].declarations) |id| {
        try expectEqual(@as(usize, 1), f.ir.get(id).domain_errors.len);
        try expect(!f.ir.get(id).isAsync());
    }
    const overloaded = f.ir.get(f.ir.modules[0].declarations[2]);
    for (overloaded.overload_cases) |id| try expectEqual(@as(usize, 1), f.ir.get(id).domain_errors.len);
}

test "C++ overload errors declare aggregate codecs and result roots" {
    const payload = comptime b.dictionary("FailureDetails", .{
        b.dictionaryField("values", b.sequence(b.any), .{ .required = true }),
    });
    const hidden_payload = comptime b.dictionaryWithOptions("HiddenFailureDetails", .{
        b.dictionaryField("label", b.dom_string, .{ .required = true }),
    }, .{ .cpp_name = "HiddenFailureDetails" });
    var f: Fixture = try .init(&.{b.module("cpp_error_aggregate", .{
        b.function("check", b.overloads(.{
            b.overloadCase("number", .{b.argument("input", b.int32, .{})}),
            b.overloadCase("string", .{b.argument("input", b.dom_string, .{})}),
        }, .{}), b.none, .{
            .backend = .cpp,
            .errors = b.domainErrors(.{b.builtinError("invalid", payload, .{ .group = "errors", .function = "createFailure" })}),
        }),
        b.function("unavailable", .{}, b.none, .{
            .backend = .cpp,
            .exposure = .never,
            .errors = b.domainErrors(.{b.builtinError("hidden", hidden_payload, .{ .group = "errors", .function = "createFailure" })}),
        }),
    })}, linux);
    defer f.deinit();
    const payload_id = f.ir.get((try f.function("cpp_error_aggregate", "check")).domain_errors[0]).position;
    const materializer = f.ir.cpp_domain_error_factories[0].operation.builtin_error.materializer;
    try expect(f.ir.get(materializer).operation == .dictionary);
    try expect(f.ir.get(payload_id).zig.destruction.wire);
    _ = try f.definition(f.ir.get(f.ir.get(materializer).source.native).named.name);
    for (f.ir.get(f.ir.modules[0].declarations[0]).overload_cases) |id| {
        const declaration = f.ir.get(id);
        const call = f.ir.functionCpp(declaration).call.entry;
        const signature = f.ir.get(call.callee.cpp).result.sync;
        try expect(signature.requires_context);
        try expectEqualStrings("invalid", signature.outcome.?.errors[0].name);
        try expect(signature.outcome.?.errors[0].payload != null);
        try expectEqualStrings(f.ir.cpp_domain_error_factories[0].symbol, signature.outcome.?.errors[0].raise_symbol);
    }
    const hidden_id = f.ir.get((try f.function("cpp_error_aggregate", "unavailable")).domain_errors[0]).position;
    for (f.ir.inbound_result_plans) |position| if (position.cpp.decoder_helper) |helper| try expect(helper.wire.index != f.ir.get(hidden_id).wire.index);
    try expect(f.findDefinition("HiddenFailureDetailsResult") == null);
    try expectEqual(@as(usize, 1), f.ir.cpp_domain_error_factories.len);
}

test "builtin constructor calls trace their cached function" {
    var f: Fixture = try .init(&.{b.moduleWithClasses("builtin_constructor_call", .{}, .{
        b.class("Callable", b.constructor(.{}, .{}), .{}, .{}, .{
            .ownership = .unique,
            .identity = .fresh,
            .constructor_call = b.constructorCall(.{b.argument("value", b.any, .{})}, b.classRefByName("builtin_constructor_call", "Callable"), .{
                .backend = .builtin,
                .builtin = "fixtureConstructorCallCodeGenerator",
            }),
        }),
    })}, linux);
    defer f.deinit();
    const class = f.ir.get(f.ir.modules[0].class_declarations[0]);
    const constructor = f.ir.cpp_class_constructors[class.id.index].?;
    try expect(constructor.hasTracedState());
    try expectEqual(@as(usize, 0), constructor.slots.len);
    try expectEqualStrings("fixtureConstructorCallCodeGenerator", constructor.builtin.?);
}

fn engineResultSourceModule(comptime source: b.EngineResultSource) b.Module {
    const result = b.dictionary("EngineResultRecord", .{
        b.dictionaryField("path", b.nonEmptyString(b.dom_string, .{
            .code = "ERR_INVALID_ARG_VALUE",
            .message = "path must not be empty",
        }), .{ .required = true }),
        b.dictionaryField("label", b.dom_string, .{}),
    });
    return b.moduleWithDeclarations("engine_result_source", .{}, .{}, .{
        b.engineShim("read", .{}, result, .{
            .throws = .js_exception,
            .realm = .current,
            .affinity = .vm,
            .result_source = source,
        }),
    }, .{});
}

test "JavaScript engine results select semantic conversion" {
    var javascript: Fixture = try .init(&.{engineResultSourceModule(.javascript)}, linux);
    defer javascript.deinit();
    var native: Fixture = try .init(&.{engineResultSourceModule(.native)}, linux);
    defer native.deinit();
    const shim = javascript.ir.get(javascript.ir.modules[0].engine_declarations[0]);
    const converted_result = try outboundResult(javascript.ir.cpp_engine_calls[shim.id.index]);
    try expect(converted_result.conversion == .javascript);
    try expectEqual(shim.outbound.result_position, converted_result.position);
    try expectEqualStrings("read result", converted_result.conversion.javascript.path);
    const decoder = javascript.ir.get(converted_result.conversion.javascript.decoder);
    const aggregate = javascript.ir.get(decoder.operation.aggregate);
    const result_encoder = javascript.ir.get(aggregate.result_encoder.?);
    const result_plan = javascript.ir.get(shim.outbound.result_position);
    try expect(decoder.operation == .aggregate);
    try expect(result_encoder.operation == .dictionary);
    try expect(result_plan.zig.destruction.wire);
    const path_field = javascript.ir.get(javascript.ir.get(decoder.operation.aggregate).operation.dictionary.fields[0].value);
    const path = javascript.ir.get(path_field.input).operation.string;
    try expectEqual(ir.ConversionContext.exact_literal, path.conversion.context);
    try expectEqualStrings("path must not be empty", path.empty_rejection.?.message);
    const native_shim = native.ir.get(native.ir.modules[0].engine_declarations[0]);
    const native_result = try outboundResult(native.ir.cpp_engine_calls[native_shim.id.index]);
    try expect(native_result.conversion == .native);
    try expectEqual(native_shim.outbound.result_position, native_result.position);
}

test "callback and engine JavaScript results preserve declared conversion profiles" {
    inline for ([_]struct { profile: b.Profile, context: ir.ConversionContext }{
        .{ .profile = .exact, .context = .exact_literal },
        .{ .profile = .webidl, .context = .none },
        .{ .profile = .node, .context = .node_literal },
    }) |case| {
        const callback = comptime b.callback("ProfiledResult", .{}, b.int32, .{ .receiver = null, .profile = case.profile });
        var f: Fixture = try .init(&.{b.moduleWithEngineShims("result_profiles", .{
            b.function("use", .{b.argument("callback", callback, .{})}, b.none, .{}),
        }, .{
            b.engineShim("read", .{}, b.int32, .{
                .realm = .current,
                .throws = .js_exception,
                .affinity = .vm,
                .result_source = .javascript,
                .profile = case.profile,
            }),
        })}, linux);
        defer f.deinit();
        const callback_ = try f.callback(callback);
        const shim = try f.engineShim("result_profiles", "read");
        const callback_result = try outboundResult(try f.callbackProgram(callback_));
        const engine_result = try outboundResult(f.ir.cpp_engine_calls[shim.id.index]);
        try expectEqual(f.callbackCall(callback_).result_position, callback_result.position);
        try expectEqual(shim.outbound.result_position, engine_result.position);
        try expectEqual(callback_result.position, engine_result.position);
        try expectEqual(case.context, f.ir.get(callback_result.conversion.javascript.decoder).operation.scalar.context);
        try expectEqual(case.context, f.ir.get(engine_result.conversion.javascript.decoder).operation.scalar.context);
        try expectEqualStrings("ProfiledResult callback result", callback_result.conversion.javascript.path);
    }
}

fn methodReferenceModule(comptime enabled: bool) b.Module {
    return b.moduleWithClasses("method_reference", .{}, .{b.class("Methods", b.constructor(.{}, .{}), .{
        b.method("read", .{}, b.uint32, .{ .native_reference = enabled, .display_name = "readNative", .length = 3 }),
        b.staticMethod("parse", .{}, b.uint32, .{ .backend = .cpp, .native_reference = enabled }),
        b.method("inspect", .{}, b.dom_string, .{
            .backend = .builtin,
            .builtin = "fixtureInspectCodeGenerator",
            .native_reference = enabled,
        }),
        b.method("hidden", .{}, b.none, .{ .native_reference = enabled, .exposure = .never }),
    }, .{}, .{ .ownership = .unique })});
}

test "native method references are normalized for every backend" {
    var with_references: Fixture = try .init(&.{methodReferenceModule(true)}, linux);
    defer with_references.deinit();
    var without_references: Fixture = try .init(&.{methodReferenceModule(false)}, linux);
    defer without_references.deinit();
    const with_class = try with_references.class("method_reference", "Methods");
    const without_class = try without_references.class("method_reference", "Methods");
    for ([_][2][]const u8{
        .{ "read", "bun_bindgen_factory_method_reference_Methods_method_read_reference" },
        .{ "parse", "bun_bindgen_factory_method_reference_Methods_static_method_parse_reference" },
        .{ "inspect", "bun_bindgen_factory_method_reference_Methods_method_inspect_reference" },
    }) |entry| {
        const member = try with_references.member(with_class, entry[0]);
        const factory = with_references.ir.cpp_function_factories[member.id.function.index].?;
        try expectEqualStrings(entry[1], member.class_member.?.native_reference_symbol.?);
        try expectEqualStrings(entry[1], factory.symbol);
        try expect(factory.abi == .reference);
        const without = try without_references.member(without_class, entry[0]);
        try expect(without.class_member.?.native_reference_symbol == null);
        try expect(without_references.ir.cpp_function_factories[without.id.function.index] == null);
    }
    const read = try with_references.member(with_class, "read");
    const read_value = with_references.ir.cpp_function_factories[read.id.function.index].?.value.native;
    try expectEqualStrings(read.host_symbol, read_value.symbol);
    try expectEqualStrings("readNative", read_value.name.named);
    try expectEqual(@as(u32, 3), read_value.length);
    try expect(read_value.visibility == .public);
    try expect(!read_value.constructable);
    const parse = try with_references.member(with_class, "parse");
    const parse_value = with_references.ir.cpp_function_factories[parse.id.function.index].?.value.native;
    try expectEqualStrings(parse.host_symbol, parse_value.symbol);
    try expectEqualStrings("parse", parse_value.name.named);
    const inspect = try with_references.member(with_class, "inspect");
    try expectEqualStrings("fixtureInspectCodeGenerator", with_references.ir.cpp_function_factories[inspect.id.function.index].?.value.builtin);
    const hidden = try with_references.member(with_class, "hidden");
    try expect(with_references.ir.cpp_function_factories[hidden.id.function.index] == null);
    try expect(with_references.ir.get(with_class.constructor).class_member.?.native_reference_symbol == null);
    try expect(with_references.ir.cpp_function_factories[with_class.constructor.index] == null);
}

fn unionNodeErrorModule(comptime node_error: ?b.NodeUnionError) b.Module {
    const value = b.unionType("NodeErrorInput", .{
        b.unionMember("text", b.dom_string),
        b.unionMember("number", b.double),
    }, .{ .node_error = node_error });
    return b.module("union_error", .{
        b.function("read", .{b.argument("value", value, .{})}, b.none, .{ .profile = .node }),
    });
}

test "Node union no-match error selection participates in the normalized contract" {
    const policies = [_]struct { ?b.NodeUnionError, ir.CppValueInputError }{
        .{ null, .{ .node_expected = .{ .kind = .type, .requirement = "a supported union member" } } },
        .{ .{ .expected_type = "string" }, .{ .node_expected = .{ .kind = .type, .requirement = "string" } } },
        .{ .{ .expected_type = "number" }, .{ .node_expected = .{ .kind = .type, .requirement = "number" } } },
        .{ .{ .expected_instances = "Date" }, .{ .node_expected = .{ .kind = .instance, .requirement = "Date" } } },
        .{ .{ .expected_instances = "URL" }, .{ .node_expected = .{ .kind = .instance, .requirement = "URL" } } },
        .{ .{ .type_or_instance = .{ .expected_type = "string", .expected_instances = "Date" } }, .{ .node_type_or_instance = .{ .expected_type = "string", .expected_instances = "Date" } } },
        .{ .{ .type_or_instance = .{ .expected_type = "number", .expected_instances = "Date" } }, .{ .node_type_or_instance = .{ .expected_type = "number", .expected_instances = "Date" } } },
        .{ .{ .type_or_instance = .{ .expected_type = "string", .expected_instances = "URL" } }, .{ .node_type_or_instance = .{ .expected_type = "string", .expected_instances = "URL" } } },
        .{ .{ .invalid_value = null }, .{ .node_value = .{} } },
        .{ .{ .invalid_value = "must be a string" }, .{ .node_value = .{ .reason = "must be a string" } } },
        .{ .{ .invalid_value = "must be a number" }, .{ .node_value = .{ .reason = "must be a number" } } },
        .{ .{ .invalid_property_value = "a string" }, .{ .node_property_value = "a string" } },
        .{ .{ .invalid_property_value = "a number" }, .{ .node_property_value = "a number" } },
        .{ .invalid_port, .node_port },
    };
    inline for (policies) |policy| {
        var f: Fixture = try .init(&.{unionNodeErrorModule(policy[0])}, linux);
        defer f.deinit();
        const read = f.ir.get(f.ir.modules[0].declarations[0]);
        try std.testing.expectEqualDeep(policy[1], f.aggregate((try f.inputConversion(read, 0)).value.input).operation.union_type.operation.matching.error_value);
    }
}

fn unionLiteralErrorModule(comptime failure: b.ConversionFailure, comptime profile: b.Profile) b.Module {
    const value = b.unionType("LiteralErrorInput", .{
        b.unionMember("text", b.dom_string),
        b.unionMember("flag", b.boolean),
    }, .{ .no_match_error = failure });
    return b.module("union_literal_error", .{
        b.function("read", .{b.argument("value", value, .{})}, b.none, .{ .profile = profile }),
    });
}

test "union no-match failures preserve literal behavior across profiles" {
    const failure: b.ConversionFailure = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "string or boolean required",
    };
    inline for (.{ b.Profile.webidl, b.Profile.node, b.Profile.exact }) |profile| {
        var f: Fixture = try .init(&.{unionLiteralErrorModule(failure, profile)}, linux);
        defer f.deinit();
        const read = f.ir.get(f.ir.modules[0].declarations[0]);
        const normalized = f.aggregate((try f.inputConversion(read, 0)).value.input).operation.union_type.operation.matching.error_value.custom;
        try expectEqualStrings(failure.kind.code, normalized.kind.code);
        try expectEqualStrings(failure.message, normalized.message);
    }
}

fn dictionaryOptionsModule(comptime name: []const u8, comptime options: b.DictionaryOptions, comptime profile: b.Profile) b.Module {
    return b.module(name, .{
        b.function("read", .{b.argument("options", b.dictionaryWithOptions("ObjectErrorOptions", .{}, options), .{})}, b.none, .{ .profile = profile }),
    });
}

test "dictionary literal errors preserve input profiles" {
    const failure: b.ConversionFailure = .{ .kind = .generic_error, .message = "options object required" };
    inline for (.{ b.Profile.webidl, b.Profile.node, b.Profile.exact }) |profile| {
        var f: Fixture = try .init(&.{dictionaryOptionsModule("literal_object_error", .{ .object_error = failure }, profile)}, linux);
        defer f.deinit();
        const read = f.ir.get(f.ir.modules[0].declarations[0]);
        const dictionary = f.aggregate((try f.inputConversion(read, 0)).value.input).operation.dictionary;
        const expected: std.meta.Tag(@FieldType(ir.CppDictionaryInput, "object")) = switch (profile) {
            .webidl => .webidl_nullable,
            .node => .node_object,
            .exact => .exact_object,
        };
        try expectEqual(expected, std.meta.activeTag(dictionary.object));
        try expect(dictionary.object_error.custom.kind == .generic_error);
        try expectEqualStrings(failure.message, dictionary.object_error.custom.message);
    }
}

test "dictionary object errors are normalized" {
    var type_error: Fixture = try .init(&.{dictionaryOptionsModule("object_error", .{ .object_error_kind = .type }, .node)}, linux);
    defer type_error.deinit();
    var value_error: Fixture = try .init(&.{dictionaryOptionsModule("object_error", .{ .object_error_kind = .invalid_value }, .node)}, linux);
    defer value_error.deinit();
    const type_plan = type_error.aggregate((try type_error.inputConversion(type_error.ir.get(type_error.ir.modules[0].declarations[0]), 0)).value.input).operation.dictionary;
    const value_plan = value_error.aggregate((try value_error.inputConversion(value_error.ir.get(value_error.ir.modules[0].declarations[0]), 0)).value.input).operation.dictionary;
    try expectEqual(ir.CppNodeExpectedError.type, type_plan.object_error.node_expected.kind);
    try expect(value_plan.object_error == .node_value);
}

test "property-key projections preserve the source and protect result storage" {
    const module = comptime b.module("property_key_projection", .{
        b.function("keys", .{
            b.argument("original", b.any, .{}),
            b.argumentProjection("key", "original", b.to_property_key, "The original value is forwarded before deferred key conversion"),
        }, b.sequence(b.property_key), .{ .backend = .cpp, .profile = .exact }),
    });
    var f: Fixture = try .init(&.{module}, linux);
    defer f.deinit();
    const keys = try f.boundFunction(comptime module.function("keys"));
    const key_input = f.ir.get((try f.inputConversion(keys, 1)).lazy.input.value);
    const key = key_input.operation.converted;
    try expect(keys.args[1].is_projection);
    try expectEqual(@as(u32, 0), (try f.inputConversion(keys, 1)).lazy.read.argument.index);
    try expect(keys.call_plan.has_lazy_conversion);
    try expectEqualStrings("bunBindgenToPropertyKey", f.ir.get(key.declaration).symbol);
    try expect(!f.ir.get(key.declaration).realm_free);
    try expect(f.ir.get(key.match).operation == .value);
    const result = try f.definition(f.ir.get(key_input.value_type).named.name);
    try expect(result.protects_sources);
}

test "internal module identity and source metadata have one authority" {
    const ids = comptime b.enumerationWithOptions("RegistryId", .{
        b.enumerationValueWithOptions("Entry", "test:entry", .{
            .internal_module = .{ .javascript = "internal/registry_entry.ts" },
            .internal_module_default = .module_object,
            .aliases = &.{"internal/registry_entry"},
        }),
        b.enumerationValueWithOptions("Native", "test:native", .{ .internal_module = .native }),
    }, .{ .tag = .u16, .internal_module_registry = true });
    const object = comptime b.objectSurface("RegistryNativeObject", .{b.surfaceInteger("answer", 42, .{})}, .{ .installation = .direct });
    var f: Fixture = try .init(&.{
        b.module("registry_calls", .{
            b.function("get", .{b.argument("id", ids, .{})}, b.none, .{ .profile = .exact }),
        }),
        b.moduleWithSurfaces("registry_native", .{
            b.nativeModule("RegistryHidden", "test:hidden", object, .{ .exposure = .never }),
            b.nativeModule("RegistryNative", "test:native", object, .{}),
        }),
    }, linux);
    defer f.deinit();
    const registry = f.ir.internal_module_registry.?;
    const enumeration = f.ir.get(registry.enumeration);
    try expectEqual((try f.typeOf(ids)).data.enumeration, registry.enumeration);
    try expectEqual(@as(u32, 1), registry.javascript_count);
    try expectEqual(@as(usize, 2), registry.modules.len);
    try expectEqual(ir.EnumerationTag.u16, enumeration.tag);
    try expect(enumeration.header == .internal_modules);
    try expectEqual(@as(u16, 0), enumeration.enumeration_values[0].native_value);
    try expectEqual(@as(u16, 1), enumeration.enumeration_values[1].native_value);
    const javascript = registry.modules[0].source.javascript;
    try expectEqualStrings("internal/registry_entry.ts", javascript.path);
    try expectEqualStrings("internal/registry_entry.js", javascript.bundle_path);
    try expectEqualStrings("builtin://internal/registry/entry", javascript.url);
    try expectEqualStrings("internal/registry_entry", registry.modules[0].aliases[0]);
    try expectEqualStrings("RegistryNative", f.ir.get(registry.modules[1].source.native).surface_name);
    const module_manifest = try std.json.parseFromSlice(struct {
        registry: struct {
            javascriptCount: u32,
            modules: []const struct { source: ?[]const u8, bundlePath: ?[]const u8 },
        },
    }, f.arena.allocator(), try f.emitted("NativeModuleManifest.json"), .{ .ignore_unknown_fields = true });
    defer module_manifest.deinit();
    try expectEqual(@as(u32, 1), module_manifest.value.registry.javascriptCount);
    const modules = module_manifest.value.registry.modules;
    try expectEqualStrings(javascript.path, modules[0].source.?);
    try expectEqualStrings(javascript.bundle_path, modules[0].bundlePath.?);
    try expect(modules[1].source == null);
    try expect(modules[1].bundlePath == null);
    try expectEqual(ir.InternalModuleDefault.module_object, registry.modules[0].default_export);
    try expectEqual(ir.InternalModuleDefault.property, registry.modules[1].default_export);
}

test "native input plans protect collection values without allocating for inline values" {
    const item = comptime b.dictionary("SharedInputItem", .{
        b.dictionaryField("value", b.int32, .{ .required = true }),
    });
    const items = comptime b.sequence(item);
    const converted_item = comptime b.converted(item, b.dom_string, b.customConverter("convertInputProjectionFixture", .{
        .audit_reason = "the fixture verifies that native serialization is independent of the JavaScript conversion profile",
        .infallible = true,
        .realm_free = true,
    }), .{});
    const inline_value = comptime b.dictionary("NativeInlineValue", .{
        b.dictionaryField("value", b.invocation_any, .{ .required = true }),
    });
    const callback = comptime b.callback("ProduceSharedItems", .{}, items, .{ .receiver = null, .profile = .exact });
    var f: Fixture = try .init(&.{b.moduleWithNativeExports("input_projections", .{
        b.function("cpp", .{b.argument("items", items, .{})}, b.none, .{ .backend = .cpp, .profile = .exact }),
        b.function("zig", .{ b.argument("items", items, .{}), b.argument("callback", callback, .{}) }, b.none, .{ .profile = .exact }),
        b.function("node", .{b.argument("item", converted_item, .{})}, b.none, .{ .profile = .node }),
    }, .{
        b.nativeExportWithOptions("native", .{b.argument("items", items, .{})}, b.none, .{ .realm = .current, .throws = .js_exception }),
        b.nativeExportWithOptions("inline", .{b.argument("item", inline_value, .{})}, b.none, .{ .realm = .current }),
        b.nativeExportWithOptions("collection", .{b.argument("items", b.sequence(inline_value), .{})}, b.none, .{ .realm = .current, .throws = .js_exception }),
        b.nativeExportWithOptions("converted", .{b.argument("item", converted_item, .{})}, b.none, .{ .realm = .current, .throws = .js_exception }),
        b.nativeExportWithOptions("optionalConverted", .{b.argument("item", b.optional(converted_item), .{})}, b.none, .{ .realm = .current, .throws = .js_exception }),
    })}, linux);
    defer f.deinit();
    const cpp_items = f.aggregate((try f.inputConversion(try f.function("input_projections", "cpp"), 0)).value.input);
    try expect(cpp_items.operation == .sequence);
    try expect(f.aggregate(cpp_items.operation.sequence.value).operation == .dictionary);
    const callback_decoder = f.ir.get((try outboundResult(try f.callbackProgram(try f.callback(callback)))).conversion.javascript.decoder);
    const callback_items = f.ir.get(callback_decoder.operation.aggregate);
    try expect(callback_items.result_encoder != null);
    try expect(f.aggregate(callback_items.operation.sequence.value).result_encoder != null);
    const inline_parameter = f.ir.get(f.ir.cpp_native_exports[1].?.entry.signature.parameters[0].type.native);
    try expect(inline_parameter.operation == .encode);
    try expect(!f.ir.get(inline_parameter.operation.encode).protects_sources);
    const collection_parameter = f.ir.get(f.ir.cpp_native_exports[2].?.entry.signature.parameters[0].type.native);
    const collection = f.ir.get(collection_parameter.operation.encode);
    try expect(collection.protects_sources);
    const collection_item = f.ir.get(collection.operation.collection);
    const field = f.ir.get(collection_item.operation.dictionary[0].value);
    try expect(field.protects_sources);
    try expect(field.operation.leaf.value == .any);
    const converted = f.ir.get(f.ir.cpp_native_exports[3].?.entry.signature.parameters[0].type.native);
    try expect(converted.operation == .javascript);
    const optional = f.ir.get(f.ir.cpp_native_exports[4].?.entry.signature.parameters[0].type.native);
    try expect(optional.operation == .optional);
    try expect(f.ir.get(optional.operation.optional).operation == .javascript);
}

test "realm-free native exports declare allocation failures without acquiring a realm" {
    const resource = comptime b.nominalHandle("NativeAllocationResource", .{
        .cpp_type = .{ .pointer = &.{ .named = "NativeAllocationResource" } },
        .cpp_declarations = &.{.{ .structure = "NativeAllocationResource" }},
        .ownership = .owned,
        .cpp_release = "releaseNativeAllocationResource",
        .destroy_thread = .any,
        .access_thread = .any,
    });
    var f: Fixture = try .init(&.{b.moduleWithNativeExports("native_allocation", .{}, .{
        b.nativeExportWithOptions("copy", .{b.argument("input", b.buffer(.copy), .{})}, b.buffer(.copy), .{ .throws = .out_of_memory }),
        b.nativeExport("length", .{b.argument("input", b.buffer(.copy), .{})}, b.size),
        b.nativeExport("releaseOptional", .{b.argument("resource", b.optional(resource), .{ .ownership = .transfer })}, b.none),
        b.nativeExportWithOptions("abort", .{}, b.none, .{ .non_returning = true }),
    })}, linux);
    defer f.deinit();
    const copy = f.ir.get(f.ir.modules[0].native_declarations[0]);
    const length = f.ir.get(f.ir.modules[0].native_declarations[1]);
    const release_optional = f.ir.get(f.ir.modules[0].native_declarations[2]);
    try expectEqual(b.NativeThrows.out_of_memory, copy.call_plan.throws);
    try expectEqual(b.EngineRealm.none, copy.call_plan.realm);
    try expectEqual(b.NativeThrows.never, length.call_plan.throws);
    try expect(release_optional.call_plan.transfers_argument_ownership);
    try expect(f.ir.get(release_optional.args[0].position).transfer);
    const copy_entry = f.ir.cpp_native_exports[copy.id.index].?.entry;
    try expect(copy_entry.signature.nodiscard);
    try expectEqual(f.decodePlan(copy_entry.call.output.decode_value.decoder.position).value_type, f.ir.get(copy_entry.signature.result).allocation_result);
    const never_returns = f.ir.cpp_native_exports[3].?.entry;
    try expect(never_returns.signature.non_returning);
    try expect(never_returns.signature.context == .none);
    try expect(never_returns.call.status.non_returning);
    const transfer_entry = f.ir.cpp_native_exports[release_optional.id.index].?.entry;
    try expect(f.ir.get(transfer_entry.signature.result).* == .void);
    const transfer_call = transfer_entry.call;
    const frame = f.ir.get(transfer_call.frame.?);
    try expect(!frame.wire_storage);
    try expect(!frame.argument_roots);
    try expect(!frame.deferred_conversions);
    try expectEqual(@as(usize, 1), frame.transferred.len);
    try expectEqualStrings("resource", frame.transferred[0].name);
    try expectEqual(release_optional.args[0].position, frame.transferred[0].position);
    try expectEqual(transfer_call.frame.?, transfer_call.inputs[0].prepare_arguments);
    try expectEqual(@as(usize, 1), f.ir.cpp_resources.len);
    const handle = f.ir.cpp_resources[0].nominal;
    const ownership = f.ir.get(handle.ownership);
    try expectEqualStrings("releaseNativeAllocationResource", ownership.cpp_release);
    try expect(ownership.byte_access == null);
    const argument = f.ir.get(f.ir.get(release_optional.args[0].position).representation.optional);
    try expectEqual(f.ir.get(argument.wire).pointer.child, handle.wire);
}

test "realm-free engine allocation contracts include nested results" {
    const result = comptime b.dictionary("IsolatedResult", .{
        b.dictionaryField("label", b.optional(b.thread_safe_dom_string), .{ .required = true }),
    });
    const realm_free: b.EngineShimOptions = .{ .throws = .never, .realm = .none, .affinity = .any, .check_traps = false };
    var f: Fixture = try .init(&.{b.moduleWithDeclarations("engine_allocation", .{}, .{}, .{
        b.engineShim("copy", .{}, result, .{ .throws = .out_of_memory, .realm = .none, .affinity = .any, .check_traps = false }),
        b.engineShim("length", .{b.argument("bytes", b.nativeSlice(.uint64, .read_only), .{})}, b.size, realm_free),
    }, .{})}, linux);
    defer f.deinit();
    const copy = try f.engineShim("engine_allocation", "copy");
    const length = try f.engineShim("engine_allocation", "length");
    try expect(copy.outbound.call_plan.throws == .out_of_memory);
    try expect(!copy.outbound.call_plan.checks_traps);
    const copy_implementation = f.ir.cpp_engine_implementations[copy.id.index];
    try expect(copy_implementation.signature.context == .none);
    try expect(copy_implementation.signature.nodiscard);
    try expectEqual(f.ir.get((try outboundResult(f.ir.cpp_engine_calls[copy.id.index])).conversion.native.encoder).value_type, f.ir.get(copy_implementation.result_alias.type).allocation_result);
    try expectEqualStrings(copy_implementation.result_alias.name, f.ir.get(copy_implementation.signature.result).named.name);
    const length_implementation = f.ir.cpp_engine_implementations[length.id.index];
    try expect(length_implementation.signature.context == .none);
    try expect(!length_implementation.signature.nodiscard);
    try expectEqualStrings("bytes", length_implementation.arguments.fields[0].name);
    try expectEqual(f.engineArgument(length, 0).value_type, length_implementation.arguments.fields[0].type);
    try expect(f.ir.cpp_engine_entries[length.id.index] == null);
    try expect(f.engineArgument(length, 0).operation.body.leaf.? == .slice_borrow);
    try expectEqual(ir.ScalarKind.u64, f.ir.get(f.ir.get(f.engineArgument(length, 0).value_type).const_span).scalar);
}

test "result codecs share aggregate helpers and JavaScript materialization" {
    const scalar = comptime b.unionType("ResultScalar", .{
        b.unionMember("text", b.dom_string),
        b.unionMember("number", b.int32),
    }, .{});
    const sequence = comptime b.sequence(scalar);
    const record = comptime b.record(b.dom_string, sequence);
    const dictionary = comptime b.dictionary("ResultDictionary", .{
        b.dictionaryField("values", record, .{ .required = true }),
    });
    const unused = comptime b.dictionary("InputOnlyDictionary", .{
        b.dictionaryField("value", b.boolean, .{ .required = true }),
    });
    const completion = comptime b.dictionary("CompletionOnlyDictionary", .{
        b.dictionaryField("value", b.dom_string, .{ .required = true }),
    });
    const callback_result = comptime b.sequence(b.boolean);
    const callback = comptime b.callback("ResultConsumer", .{b.argument("value", dictionary, .{})}, callback_result, .{
        .receiver = null,
    });
    var f: Fixture = try .init(&.{b.moduleWithDeclarations("result_converters", .{
        b.function("cpp", .{}, dictionary, .{ .backend = .cpp }),
        b.function("wire", .{}, dictionary, .{}),
        b.function("callback", .{ b.argument("callback", callback, .{}), b.argument("input", unused, .{}) }, b.none, .{}),
        b.function("completion", .{}, completion, .{
            .exposure = .never,
            .completion = .{ .retention = .strong, .sender_drop = .leave_pending, .delivery = .vm },
        }),
    }, .{}, .{
        b.engineShim("engine", .{}, b.optional(dictionary), .{
            .throws = .never,
            .realm = .current,
            .affinity = .vm,
        }),
    }, .{
        b.nativeExportWithOptions("native", .{}, dictionary, .{ .throws = .out_of_memory }),
    })}, linux);
    defer f.deinit();
    const native_export = try f.nativeExport("result_converters", "native");
    const engine = try f.engineShim("result_converters", "engine");
    const encoded_optional = f.ir.get((try outboundResult(f.ir.cpp_engine_calls[engine.id.index])).conversion.native.encoder);
    const encoded_dictionary = f.ir.get(f.ir.get(encoded_optional.operation.optional).operation.leaf.helper);
    const encoded_record = f.ir.get(f.ir.get(encoded_dictionary.operation.dictionary[0].value).operation.leaf.helper);
    const encoded_entry = f.ir.get(encoded_record.operation.collection.element.direct);
    const encoded_sequence = f.ir.get(f.ir.get(encoded_entry.operation.entry.value).operation.leaf.helper);
    const encoded_scalar = f.ir.get(f.ir.get(encoded_sequence.operation.collection.element.direct).operation.leaf.helper);
    try expect(f.ir.get(encoded_scalar.operation.union_type[0].value).operation.leaf == .string);
    try expectEqual(ir.ScalarKind.i32, f.ir.get(encoded_scalar.operation.union_type[1].value).operation.leaf.scalar);
    const native_dictionary = f.ir.get(f.resultMaterializer(try f.function("result_converters", "cpp"))).operation.dictionary.fields;
    const native_record = f.ir.get(native_dictionary[0].value).operation.record;
    const native_sequence = f.ir.get(native_record.value).operation.sequence;
    const native_union = f.ir.get(native_sequence.value).operation.union_type;
    try expect(f.ir.get(native_union[0].value).operation.leaf == .string);
    try expect(f.ir.get(native_union[1].value).operation.leaf.scalar == .integer_number);
    const unused_wire = f.ir.get(f.ir.type_plans[(try f.typeId(unused)).index].result_position.?).wire;
    for (f.ir.inbound_result_plans) |position| if (position.cpp.decoder_helper) |helper| try expect(helper.wire.index != unused_wire.index);
    try expect(!f.ir.cpp_native_exports[native_export.id.index].?.entry.call.output.decode_value.release_wire);
    const decoded_root = f.decodePlan(f.ir.cpp_native_exports[native_export.id.index].?.entry.call.output.decode_value.decoder.position).operation.helper;
    const decoded_record = f.decodePlan(f.ir.get(decoded_root).representation.dictionary[0].value).operation.helper;
    const decoded_entry = f.ir.get(decoded_record).representation.record;
    try expect(f.decodePlan(decoded_entry).operation == .body);
    const decoded_sequence = f.decodePlan(f.ir.get(decoded_entry).representation.record_entry.value).operation.helper;
    const decoded_scalar = f.decodePlan(f.ir.get(decoded_sequence).representation.sequence).operation.helper;
    try expect(!f.resultDecoder(decoded_scalar).allocates);
    try expect(f.resultDecoder(decoded_root).allocates);
    const completion_id = (try f.function("result_converters", "completion")).completion.?;
    const completion_contract = f.ir.get(completion_id);
    const completion_plan = f.ir.get(completion_contract.payload);
    const delivery = f.ir.cpp_completion_deliveries[completion_id.index];
    try expect(delivery.layout == .value);
    try expectEqual(completion_plan.wire, f.ir.get(delivery.materializer.wire).source.wire.type);
    const wire_function = try f.function("result_converters", "wire");
    try expectEqual(f.ir.get(wire_function.result_position).wire, f.ir.get(f.resultMaterializer(wire_function)).source.wire.type);
    try expect(!f.ir.functionCpp(wire_function).call.entry.output.encode_value.wire.release_wire);
    const callback_declaration = try f.callback(callback);
    try expectEqual(f.ir.get(f.callbackCall(callback_declaration).args[0].position).wire, f.ir.get((try f.callbackProgram(callback_declaration)).entries[0].operation.invoke.callee.callback.arguments[0].materializer).source.wire.type);
    try expectEqual(@as(usize, 0), f.ir.cpp_completions.len);
    const callback_plan = f.ir.get(f.callbackCall(try f.callback(callback)).result_position);
    const callback_decoder = f.ir.get((try outboundResult(try f.callbackProgram(callback_declaration))).conversion.javascript.decoder);
    const callback_input = f.ir.get(callback_decoder.operation.aggregate);
    const callback_encoder = f.ir.get(callback_input.result_encoder.?);
    try expect(callback_plan.zig.destruction.wire);
    try expect(callback_encoder.operation == .collection);
    try expect(f.ir.get(callback_encoder.operation.collection.element.direct).operation.leaf.scalar == .boolean);
}

test "domain error factories share mappings across sync and completion calls" {
    const first = comptime b.domainError("first", b.thread_safe_dom_string, .{ .class = .type_error, .code = "ERR_FIRST", .message = .payload });
    const alias = comptime b.domainError("alias", b.thread_safe_dom_string, .{ .class = .type_error, .code = "ERR_FIRST", .message = .payload });
    const distinct = comptime b.domainError("distinct", b.thread_safe_dom_string, .{ .class = .type_error, .code = "ERR_DISTINCT", .message = .payload });
    const unused = comptime b.domainError("unused", b.thread_safe_dom_string, .{ .class = .range_error, .message = .payload });
    var f: Fixture = try .init(&.{b.module("error_factories", .{
        b.function("sync", .{}, b.none, .{ .errors = b.domainErrors(.{first}) }),
        b.function("async", .{}, b.none, .{
            .errors = b.domainErrors(.{ alias, distinct }),
            .completion = .{ .retention = .strong, .sender_drop = .leave_pending, .delivery = .vm },
        }),
        b.function("cpp_async", .{}, b.none, .{
            .backend = .cpp,
            .profile = .webidl,
            .errors = b.domainErrors(.{alias}),
            .completion = .{},
        }),
        b.function("unused", .{}, b.none, .{ .errors = b.domainErrors(.{unused}), .exposure = .never }),
    })}, linux);
    defer f.deinit();
    const sync_result = f.ir.get(f.ir.functionCpp(try f.function("error_factories", "sync")).call.entry.callee.wire.result);
    const async_result = f.ir.get(f.ir.functionCpp(try f.function("error_factories", "async")).call.entry.callee.wire.result);
    try expectEqual(@as(usize, 2), f.ir.domain_error_factories.len);
    try expectEqual(@as(usize, 1), f.ir.cpp_domain_error_factories.len);
    try expectEqualStrings(sync_result.layout.errors[0].factory, async_result.layout.errors[0].factory);
    try expect(!std.mem.eql(u8, async_result.layout.errors[0].factory, async_result.layout.errors[1].factory));
}

test "wide enumeration tags and error catalogs retain their normalized contracts" {
    const wide = comptime b.enumerationWithOptions("WideTags", .{
        b.enumerationValueWithOptions("first", "first", .{ .native_value = 256, .aliases = &.{"initial"} }),
        b.enumerationValueWithOptions("last", "last", .{ .native_value = 65535 }),
    }, .{ .tag = .u16, .accept_native_numbers = true });
    const catalog = comptime b.errorCodeEnumeration("TestErrorCode", .{
        b.domainError("ERR_TEST", b.dom_string, .{ .class = .type_error, .code = "ERR_TEST", .message = .payload }),
        b.domainError("ERR_URI", b.dom_string, .{
            .class = .uri_error,
            .code = "ERR_URI",
            .name_override = "NamedURIError",
            .message = .payload,
        }),
    });
    var f: Fixture = try .init(&.{b.module("wide_enumerations", .{
        b.function("wide", .{b.argument("value", wide, .{})}, wide, .{ .profile = .exact }),
        b.function("errorCode", .{b.argument("value", catalog, .{})}, catalog, .{ .profile = .exact }),
    })}, linux);
    defer f.deinit();
    const wide_id = try f.typeId(wide);
    const wide_declaration = f.at(wide_id).data.enumeration;
    const wide_enumeration = f.ir.get(wide_declaration);
    const catalog_id = try f.typeId(catalog);
    const catalog_enumeration = f.ir.get(f.at(catalog_id).data.enumeration);
    const error_codes = f.ir.error_catalog.?;
    try expectEqual(f.at(catalog_id).data.enumeration, error_codes.enumeration);
    try expectEqual(ir.EnumerationTag.u16, wide_enumeration.tag);
    try expectEqual(@as(u16, 65535), wide_enumeration.enumeration_values[1].native_value);
    const catalog_argument = (try f.function("wide_enumerations", "errorCode")).args[0].position;
    try expectEqualStrings("uint16_t", try f.wireSpelling(f.ir.get(f.ir.get(catalog_argument).wire).alias.child));
    try expectEqual(@as(u16, 0), catalog_enumeration.enumeration_values[0].native_value);
    try expect(catalog_enumeration.header == .error_codes);
    try expect(wide_enumeration.header == .shared);
    try expectEqualStrings("ERR_TEST", error_codes.codes[0].tag);
    try expectEqual(@as(u16, 0), error_codes.codes[0].value);
    try expect(error_codes.codes[0].name_override == null);
    try expectEqual(ir.ErrorClass.uri_error, error_codes.codes[1].class);
    try expectEqualStrings("NamedURIError", error_codes.codes[1].name_override.?);
    const typescript = for (f.ir.typescript_declarations) |declaration| switch (declaration) {
        .enumeration => |enumeration| if (std.mem.eql(u8, enumeration.name, "WideTags")) break enumeration,
        .dictionary, .union_type => {},
    } else return error.MissingTypeScriptDeclaration;
    const expected: []const ir.TypeScriptEnumerationValue = &.{
        .{ .string = "first" }, .{ .string = "initial" }, .{ .number = 256 },
        .{ .string = "last" },  .{ .number = 65535 },
    };
    try expect(structural.eql(expected, typescript.values));
    const wide_function = try f.function("wide_enumerations", "wide");
    const input = f.ir.get((try f.inputConversion(wide_function, 0)).value.input).operation.enumeration;
    try expectEqualStrings("initial", input.values[0].aliases[0]);
    try expect(input.numbers != null);
    const document = try @import("document.zig").create(f.arena.allocator(), &f.ir);
    const serialized_function = document.functions[wide_function.id.function.index];
    const serialized_type = document.inbound_argument_plans[serialized_function.args[0].position.index].type;
    const serialized_id = document.types[serialized_type.index].data.enumeration;
    const serialized = document.enumerations[serialized_id.index];
    try expectEqualStrings("WideTags", serialized.enumeration_name);
    try expectEqual(ir.EnumerationTag.u16, serialized.tag);
    try expectEqual(@as(u16, 65535), serialized.enumeration_values[1].native_value);
    try expect(!@hasField(@TypeOf(serialized), "cpp_name"));
    try expect(!@hasField(@TypeOf(serialized), "header"));
    const metadata = try std.json.parseFromSlice(struct {
        errorCodes: []const struct { tag: []const u8, value: u16, code: []const u8, name: []const u8, constructor: []const u8 },
    }, f.arena.allocator(), try f.emitted("SchemaBindingsLinkMetadata.json"), .{ .ignore_unknown_fields = true });
    defer metadata.deinit();
    try expectEqualStrings("ERR_TEST", metadata.value.errorCodes[0].tag);
    try expectEqual(@as(u16, 0), metadata.value.errorCodes[0].value);
    try expectEqualStrings("TypeError", metadata.value.errorCodes[0].name);
    try expectEqualStrings("NamedURIError", metadata.value.errorCodes[1].name);
    try expectEqualStrings("URIError", metadata.value.errorCodes[1].constructor);
}

const bigint_uint64 = b.integerRepresentation(b.uint64, .bigint);
const integer_representation_schema = b.module("integer_representation_test", .{
    b.function("roundTrip", .{b.argument("value", bigint_uint64, .{})}, bigint_uint64, .{ .profile = .exact }),
});

const value_brand = b.brandedValueWithBrand(b.cppBrand("NormalizedValueBrand", .{
    .symbol = "Bun::isNormalizedValue",
    .header = "NormalizedValue.h",
}, "unknown"), .{});
const realm_brand = b.brandedValueWithBrand(b.cppRealmBrand("NormalizedRealmBrand", .{
    .symbol = "Bun::isNormalizedRealmValue",
    .header = "NormalizedRealmValue.h",
}, "unknown"), .{});
const dynamic_cast_brand = b.brandedValueWithBrand(b.cppDynamicCastBrand("NormalizedDynamicCastBrand", .{
    .type_name = "Bun::NormalizedCell",
    .header = "NormalizedCell.h",
}, "unknown"), .{});
const brand_normalization_schema = b.module("brand_normalization_test", .{b.function(
    "inspect",
    .{
        b.argument("value", value_brand, .{}),
        b.argument("realm", realm_brand, .{}),
        b.argument("dynamic", dynamic_cast_brand, .{}),
        b.argument("promise", b.promise(b.uint32), .{}),
        b.argument("otherValue", b.brandedValueWithBrand(b.cppBrand("OtherNormalizedValueBrand", .{
            .symbol = "Bun::isNormalizedValue",
            .header = "NormalizedValue.h",
        }, "unknown"), .{}), .{}),
        b.argument("otherHeader", b.brandedValueWithBrand(b.cppBrand("OtherNormalizedHeaderBrand", .{
            .symbol = "Bun::isNormalizedValue",
            .header = "OtherNormalizedValue.h",
        }, "unknown"), .{}), .{}),
    },
    b.none,
    .{ .profile = .exact },
)});

const conversion_union = b.unionType("ConversionNormalizationUnion", .{
    b.unionMember("number", b.int32),
    b.unionMember("string", b.dom_string),
}, .{ .node_error = .{ .expected_type = "number or string" } });
const conversion_sequence = b.sequenceWithOptions(b.int32, .{ .node_error = .{
    .container = .{ .expected = "Array" },
    .element = .{ .kind = .instance, .expected = "integer", .site = .element },
} });
const conversion_enumeration = b.enumerationWithOptions("ConversionNormalizationEnumeration", .{
    b.enumerationValue("enabled", "enabled"),
    b.enumerationValue("disabled", "disabled"),
}, .{ .node_invalid_value = .{ .invalid_argument_value = .{
    .name = "mode",
    .reason = "must be enabled or disabled",
    .non_string_expected_type = "string",
} } });
const conversion_non_empty_string = b.coerceStringWithOptions(b.dom_string, .{
    .empty_rejection = .{
        .code = "ERR_INVALID_ARG_VALUE",
        .message = "value cannot be empty",
    },
});
const conversion_schema = b.module("conversion_normalization_test", .{
    b.function(
        "convert",
        .{
            b.argument("flag", b.boolean, .{ .boolean_conversion = .strict_true }),
            b.argument("count", b.int32, .{ .integer_conversion = .{ .clamp = .{ .min = -10, .max = 10 } } }),
            b.argument("ratio", b.double, .{ .number_conversion = .{ .node_validate = .{
                .min = 0,
                .max = 1,
                .error_kind = .invalid_value,
            } } }),
            b.argument("choice", conversion_union, .{}),
            b.argument("values", conversion_sequence, .{}),
            b.argument("mode", conversion_enumeration, .{}),
            b.argument("text", conversion_non_empty_string, .{}),
        },
        b.none,
        .{ .profile = .node },
    ),
});

const cpp_plan_separate_dictionary = b.dictionaryWithOptions("CppPlanSeparateDictionary", .{
    b.dictionaryField("value", b.buffer(.copy), .{ .required = true }),
}, .{ .cpp_name = "CppPlanSeparateDictionary" });
const cpp_plan_result_union = b.unionType("CppPlanResultUnion", .{
    b.unionMember("integer", b.uint32),
    b.unionMember("string", b.dom_string),
}, .{ .cpp_name = "CppPlanResultUnion" });
const cpp_plan_wire_dictionary = b.dictionaryWithOptions("CppPlanWireDictionary", .{
    b.dictionaryField("value", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "CppPlanWireDictionary" });
const cpp_plan_dictionary_source = b.dictionary("CppPlanDictionarySource", .{
    b.dictionaryField("source", b.engine_value, .{ .source = .dictionary, .required = true }),
});
const cpp_plan_converted_scalar = b.converted(
    b.int32,
    b.int32,
    b.customConverter("cppPlanConvertScalar", .{
        .infallible = true,
        .realm_free = true,
        .audit_reason = "tests scalar converter planning",
    }),
    .{},
);
const cpp_plan_profiled_converted_dictionary = b.dictionary("CppPlanProfiledConvertedDictionary", .{
    b.dictionaryField("value", cpp_plan_converted_scalar, .{ .profile = .webidl }),
});
const cpp_plan_schema = b.module("cpp_plan_test", .{
    b.function("separate", .{b.argument("value", cpp_plan_separate_dictionary, .{})}, cpp_plan_separate_dictionary, .{ .backend = .cpp }),
    b.function("resultOnly", .{}, cpp_plan_result_union, .{ .backend = .cpp }),
    b.function("zigOnly", .{b.argument("value", cpp_plan_wire_dictionary, .{})}, b.none, .{ .backend = .zig }),
    b.function("dictionarySources", .{b.argument("value", b.sequence(cpp_plan_dictionary_source), .{})}, b.none, .{ .backend = .cpp }),
    b.function("convertedScalars", .{b.argument("value", b.sequence(cpp_plan_converted_scalar), .{})}, b.none, .{ .backend = .zig }),
    b.function(
        "profiledConvertedDictionaries",
        .{b.argument("value", b.sequence(cpp_plan_profiled_converted_dictionary), .{})},
        b.none,
        .{ .backend = .zig, .profile = .exact },
    ),
});

const surface_declarations = b.moduleWithDeclarations(
    "surface_declarations",
    .{
        b.function("defaultValue", .{}, b.any, .{ .backend = .cpp, .length = 0 }),
        b.function("classify", .{b.argument("value", b.discardAny(.classification), .{})}, b.boolean, .{ .backend = .cpp, .length = 2 }),
    },
    .{},
    .{},
    .{b.nativeExportWithOptions("constructSurfaceProperty", .{}, b.dom_string, .{ .throws = .out_of_memory })},
);
const test_nested_object_surface = b.objectSurface(
    "TestNestedObjectSurface",
    .{b.surfaceInteger("answer", 42, .{})},
    .{ .installation = .direct, .prototype = .null, .integrity = .frozen },
);
const test_native_object_surface = b.objectSurface(
    "TestNativeObjectSurface",
    .{
        b.surfaceFunction("classify", surface_declarations.function("classify"), .{
            .aliases = &.{b.surfaceAlias("isClassified", .{})},
        }),
        b.surfaceLazyProperty("property", surface_declarations.nativeExport("constructSurfaceProperty"), .{
            .attributes = .{ .writable = false },
            .exposure = .{ .not_os = "windows" },
            .header = "SurfaceDefault.h",
        }),
        b.surfaceObjectValue("nested", test_nested_object_surface, .{ .exposure = .{ .not_os = "windows" } }),
    },
    .{ .installation = .direct },
);
const test_native_surface = b.nativeModule("TestNativeSurface", "test:native-surface", test_native_object_surface, .{
    .default = .{ .declaration = .{ .function = surface_declarations.function("defaultValue") } },
    .default_surface = .install,
});
const surface_owner = b.moduleWithSurfaces("surface_owner", .{ test_nested_object_surface, test_native_surface });

const fallback_union = b.unionType("FallbackUnion", .{
    b.unionMember("number", b.double),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .fallback_member = "string" });
const fallback_union_schema = b.module("fallback_union_test", .{
    b.function("coerce", .{b.argument("value", fallback_union, .{})}, b.none, .{}),
});

const node_path_schema = b.module("node_path_test", .{
    b.function("inspect", .{b.argument("path", b.node_path, .{})}, b.none, .{ .profile = .node }),
});

const lazy_rest_schema = b.module("lazy_rest_test", .{b.function(
    "resolve",
    .{b.lazyRest("paths", b.dom_string, "the fixture verifies lazy rest normalization")},
    b.dom_string,
    .{ .backend = .zig, .profile = .node },
)});

const discard_purpose_union = b.unionType("DiscardPurposeUnion", .{
    b.unionMember("number", b.double),
    b.unionMember("fallback", b.discarded),
}, .{ .ordered = true, .fallback_member = "fallback" });
const discard_purpose_options = b.dictionary("DiscardPurposeOptions", .{
    b.dictionaryField("marker", b.discardAny(.presence), .{}),
});
const discard_purpose_schema = b.module("discard_purpose_test", .{
    b.function("classifyUnion", .{b.argument("value", discard_purpose_union, .{})}, b.none, .{}),
    b.function("classifyOverload", b.overloads(.{
        b.overloadCase("number", .{b.argument("value", b.double, .{})}),
        b.overloadCase("fallback", .{b.argument("value", b.discardAny(.classification), .{})}),
    }, .{ .ordered = true }), b.none, .{}),
    b.function("ignore", .{b.argument("value", b.discardAny(.ignored), .{})}, b.none, .{}),
    b.function("checkPresence", .{b.argument("options", discard_purpose_options, .{})}, b.none, .{}),
    b.function("count", .{b.rest("values", b.discarded)}, b.none, .{}),
});

const string_promise = b.promise(b.dom_string);
const engine_value_schema = b.module("engine_value_test", .{
    b.function("pass", .{b.argument("value", b.engine_value, .{})}, b.engine_value, .{}),
    b.function("makePromise", .{}, string_promise, .{}),
});

const extra_argument_overload_schema = b.module("extra_argument_overload_test", .{b.function(
    "select",
    b.overloads(.{
        b.overloadCase("integer", .{b.argument("value", b.int32, .{})}),
        b.overloadCase("string", .{b.argument("value", b.dom_string, .{})}),
    }, .{ .ordered = true, .accept_extra_arguments = true }),
    b.none,
    .{},
)});

const required_argument_policy_schema = b.module("required_argument_policy_test", .{
    b.function("nodeArityError", .{b.argument("value", b.int32, .{})}, b.none, .{ .profile = .node, .missing_required_arguments = .arity_error }),
    b.function("exactUndefinedConversion", .{b.argument("value", b.int32, .{})}, b.none, .{ .profile = .exact, .missing_required_arguments = .convert_undefined }),
});

const converted_file_mode_input = b.unionType("ConvertedFileModeInput", .{
    b.unionMember("number", b.uint32),
    b.unionMember("octal", b.dom_string),
}, .{});
const converted_file_mode = b.converted(
    b.uint32,
    converted_file_mode_input,
    b.customConverter("convertFileMode", .{ .audit_reason = "tests converted file-mode normalization" }),
    .{ .name = "options.mode" },
);

const explicit_enumeration = b.enumerationWithOptions("ExplicitEnumeration", .{
    b.enumerationValueWithOptions("zero", "zero", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("seven", "seven", .{ .native_value = 7 }),
}, .{ .cpp_name = "ExplicitEnumerationNative" });
const empty_enumeration = b.enumeration("EmptyEnumeration", .{
    b.enumerationValue("empty", ""),
});
const enumeration_schema = b.module("enumeration_test", .{
    b.function("consume", .{ b.argument("numbered", explicit_enumeration, .{}), b.argument("blank", empty_enumeration, .{}) }, b.none, .{}),
});

const realm_free_any_thread: b.EngineShimOptions = .{
    .throws = .never,
    .realm = .none,
    .affinity = .any,
    .check_traps = false,
};

const realm_independent_engine_schema = b.moduleWithEngineShims("realm_independent_test", .{}, .{
    b.engineShim("isNonzero", .{b.argument("value", b.uint64, .{})}, b.boolean, realm_free_any_thread),
});

const native_slice_schema = b.moduleWithEngineShims("native_slice_test", .{}, .{b.engineShim(
    "fill",
    .{
        b.argument("input", b.nativeSlice(.uint16, .read_only), .{}),
        b.argument("output", b.nativeSlice(.uint32, .read_write), .{}),
    },
    b.none,
    realm_free_any_thread,
)});

const native_slice_export_schema = b.moduleWithNativeExports("native_slice_export_test", .{}, .{b.nativeExportWithOptions(
    "copy",
    .{
        b.argument("input", b.nativeSlice(.uint16, .read_only), .{}),
        b.argument("output", b.nativeSlice(.uint32, .read_write), .{}),
    },
    b.none,
    .{ .throws = .never, .realm = .none },
)});

const owned_native_handle = b.nominalHandle("OwnedNativeArgument", .{
    .cpp_type = .{ .pointer = &.{ .named = "OwnedNativeArgument" } },
    .c_struct = "OwnedNativeArgument",
    .cpp_declarations = &.{.{ .structure = "OwnedNativeArgument" }},
    .cpp_read_bytes = "readOwnedNativeArgumentBytes",
    .ownership = .owned,
    .cpp_release = "releaseOwnedNativeArgument",
    .access_thread = .any,
    .destroy_thread = .any,
});
const other_native_handle = b.nominalHandle("OtherNativeArgument", .{
    .cpp_type = .{ .pointer = &.{ .named = "OtherNativeArgument" } },
    .cpp_declarations = &.{.{ .structure = "OtherNativeArgument" }},
    .access_thread = .vm,
});
const owned_native_export_schema = b.moduleWithNativeExports("owned_native_argument_test", .{}, .{
    b.nativeExportWithOptions(
        "consume",
        .{b.argument("value", owned_native_handle, .{ .ownership = .transfer })},
        b.none,
        .{ .standalone_header = "OwnedNativeArgument" },
    ),
    b.nativeExportWithOptions("create", .{}, owned_native_handle, .{ .standalone_header = "OwnedNativeArgument" }),
});

const native_dictionary_result = b.dictionary("NativeDictionaryResult", .{
    b.dictionaryField("value", b.dom_string, .{ .required = true }),
    b.dictionaryField("present", b.boolean, .{ .required = true }),
});
const native_dictionary_result_schema = b.moduleWithNativeExports("native_dictionary_result_test", .{}, .{
    b.nativeExport("create", .{}, native_dictionary_result),
});

const native_export_exposure_schema = b.moduleWithNativeExports("native_export_exposure_test", .{}, .{
    b.nativeExportWithOptions("windowsProbe", .{}, b.boolean, .{ .exposure = .{ .os = "windows" } }),
});

const converted_native_input = b.converted(
    b.uint32,
    b.dom_string,
    b.customConverter("convertNativeInput", .{ .audit_reason = "tests native-export converted inputs" }),
    .{},
);
const converted_native_dictionary = b.dictionaryWithOptions("ConvertedNativeDictionary", .{
    b.dictionaryField("value", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "ConvertedNativeDictionary" });
const converted_native_dictionary_input = b.converted(
    converted_native_dictionary,
    b.dom_string,
    b.customConverter("convertNativeDictionaryInput", .{ .audit_reason = "tests nested native-export converted inputs" }),
    .{},
);
const converted_native_export_schema = b.moduleWithNativeExports("converted_native_export_test", .{}, .{
    b.nativeExportWithOptions("consume", .{b.argument("value", converted_native_input, .{})}, b.none, .{ .throws = .js_exception, .realm = .current }),
    b.nativeExportWithOptions("consumeDictionary", .{b.argument("value", converted_native_dictionary_input, .{})}, b.none, .{ .throws = .js_exception, .realm = .current }),
    b.nativeExportWithOptions("consumeDirectDictionary", .{b.argument("value", converted_native_dictionary, .{})}, b.none, .{ .throws = .js_exception, .realm = .current }),
    b.nativeExportWithOptions(
        "consumeLazy",
        .{b.argument("value", b.lazy(b.dom_string), .{ .deferred_reason = "the fixture verifies native lazy normalization" })},
        b.none,
        .{ .throws = .js_exception, .realm = .current },
    ),
});

const invocation_metadata_schema = b.module("invocation_metadata_test", .{
    b.function("inspect", .{b.rest("values", b.invocation_any)}, b.any, .{
        .this_value_type = b.invocation_any,
        .callee_value_type = b.invocation_any,
        .caller_source_location = true,
    }),
    b.function("inspectCpp", .{}, b.none, .{ .backend = .cpp, .caller_source_location = true }),
});

const invocation_conversion_schema = b.module("invocation_conversion_test", .{b.function(
    "inspect",
    .{},
    b.none,
    .{
        .profile = .exact,
        .this_value_type = b.buffer(.copy),
        .callee_value_type = converted_file_mode,
    },
)});

const receiver_conversion_schema = b.module("receiver_conversion_test", .{
    b.function(
        "read",
        .{b.argument("index", b.size, .{ .integer_conversion = .{ .node_receiver_byte_length = .integer } })},
        b.uint32,
        .{ .backend = .cpp, .profile = .node, .this_value_type = b.js_array_buffer_view },
    ),
    b.function(
        "readLazy",
        .{b.argument("index", b.lazy(b.size), .{
            .integer_conversion = .{ .node_receiver_byte_length = .integer },
            .deferred_reason = "the fixture verifies lazy receiver conversion",
        })},
        b.uint32,
        .{ .backend = .zig, .profile = .node, .this_value_type = b.js_array_buffer_view },
    ),
    b.function(
        "readLazyLabel",
        .{
            b.argument("index", b.size, .{ .integer_conversion = .{ .node_receiver_byte_length = .integer } }),
            b.argument("label", b.lazy(b.dom_string), .{ .deferred_reason = "the label is converted after the eager receiver-dependent index" }),
        },
        b.uint32,
        .{ .profile = .node, .this_value_type = b.js_array_buffer_view },
    ),
});

const function_prototype_schema = b.moduleWithClasses("function_prototype_test", .{}, .{b.class(
    "FunctionPrototypeClass",
    b.constructor(.{}, .{ .exposure = .never }),
    .{b.getter("value", b.int32, .{
        .backend = .builtin,
        .builtin = "functionPrototypeClassValueCodeGenerator",
    })},
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .prototype_base = .function,
    },
)});

const constructor_this_schema = b.moduleWithClasses("constructor_this_test", .{}, .{b.class(
    "ConstructorThis",
    b.constructor(.{}, .{ .this_value_type = b.invocation_any }),
    .{},
    .{},
    .{ .ownership = .unique },
)});

const engine_inventory_schema = b.moduleWithClasses("engine_inventory_test", .{}, .{b.class(
    "InventoryEngine",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.setter("value", b.int32, .{ .backend = .cpp, .unforgeable = true, .configurable = false }),
        b.getter("value", b.int32, .{ .backend = .cpp, .unforgeable = true, .configurable = false }),
        b.setter("writeOnly", b.int32, .{ .backend = .cpp, .unforgeable = true, .configurable = false }),
    },
    .{b.cachedSlot("cache", b.dom_string, .{ .writable = true })},
    .{
        .representation = .engine,
        .engine_intrinsic = "test inventory engine wrapper",
        .identity = .per_realm,
        .memory_usage = .vm,
        .parent = b.engineParent(.{
            .cpp_class = .{ .named = "Test::JSInventoryEngine" },
            .cpp_impl = "Test::InventoryEngine",
            .header = "InventoryEngine.h",
            .prototype = .object,
            .constructor = .function,
        }),
        .engine_native = .{
            .cpp_type = "Test::InventoryEngine",
            .header = "InventoryEngine.h",
        },
    },
)});

const exposure_test = b.moduleWithClasses(
    "exposure_test",
    .{
        b.function("linuxOnly", .{}, b.none, .{ .exposure = .{ .target = "x86_64-linux" } }),
        b.function("macOnly", .{}, b.none, .{ .exposure = .{ .target = "aarch64-macos" } }),
        b.function("featureOnly", .{}, b.none, .{ .exposure = .{ .feature = "experimental" } }),
    },
    .{
        b.class(
            "FeatureClass",
            b.constructor(.{}, .{}),
            .{b.method("enabledMember", .{}, b.none, .{ .exposure = .{ .feature = "experimental" } })},
            .{},
            .{ .fresh_identity_reason = "the fixture creates one wrapper for each feature-class object" },
        ),
        b.class(
            "HiddenConstructorClass",
            b.constructor(.{}, .{ .exposure = .never }),
            .{},
            .{},
            .{ .fresh_identity_reason = "the fixture creates one wrapper for each hidden-constructor object" },
        ),
        b.class(
            "SplitAccessorClass",
            b.constructor(.{}, .{ .exposure = .never }),
            .{
                b.getter("value", b.any, .{}),
                b.setter("value", b.dom_string, .{}),
            },
            .{},
            .{ .ownership = .unique },
        ),
        b.class(
            "CacheAliasClass",
            b.constructor(.{}, .{}),
            .{
                b.getter("canonical", b.dom_string, .{
                    .implementation = "getValue",
                    .cache = "value",
                    .cache_on_construction = true,
                }),
                b.getter("alias", b.dom_string, .{ .implementation = "getAlias", .cache = "value" }),
            },
            .{b.cachedSlot("value", b.dom_string, .{})},
            .{ .ownership = .unique },
        ),
        b.class(
            "InvalidatableCacheClass",
            b.constructor(.{}, .{ .exposure = .never }),
            .{b.getter("value", b.retained_any, .{ .cache = "value" })},
            .{b.cachedSlot("value", b.retained_any, .{ .writable = true, .exposed = false })},
            .{ .ownership = .unique },
        ),
        b.class(
            "ConstructorCacheClass",
            b.constructor(.{}, .{}),
            .{b.staticGetter("value", b.dom_string, .{ .cache = "value" })},
            .{b.cachedSlot("value", b.dom_string, .{ .storage = .constructor })},
            .{ .ownership = .unique },
        ),
    },
);

const imported_base = b.class("ImportedBase", b.constructor(.{}, .{}), .{}, .{}, .{ .ownership = .unique });
const imported_child = b.class("ImportedChild", b.constructor(.{}, .{}), .{}, .{}, .{
    .ownership = .unique,
    .parent = b.parentClass(imported_base),
    .upcast = "asImportedBase",
});
const imported_base_module = b.moduleWithClasses("imported_base", .{}, .{imported_base});
const imported_child_module = b.moduleWithClasses("imported_child", .{}, .{imported_child});
const imported_reference_module = b.module("imported_reference", .{
    b.function("accept", .{b.argument("value", b.classRef(imported_base_module.class("ImportedBase")), .{})}, b.boolean, .{}),
});

const self_ref_input = b.unionType("SelfRefInput", .{
    b.unionMember("self", b.this_class_ref),
    b.unionMember("label", b.dom_string),
}, .{});
const self_ref_module = b.moduleWithClasses("self_ref", .{}, .{b.class(
    "Fluent",
    b.constructor(.{}, .{}),
    .{
        b.method("chain", .{}, b.this_class_ref, .{ .this_value_type = b.this_class_ref }),
        b.staticMethod("accept", .{b.argument("value", b.lazy(self_ref_input), .{
            .deferred_reason = "the fixture verifies lazy self-reference normalization",
        })}, b.boolean, .{}),
    },
    .{},
    .{ .backend = .zig, .fresh_identity_reason = "the fixture creates one wrapper for each fluent object" },
)});

test "normalization resolves class parents across schema modules" {
    const leaf = comptime b.class("ImportedLeaf", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .parent = b.parentClass(imported_child),
        .upcast = "asImportedChild",
    });
    const leaves = comptime b.moduleWithClasses("imported_leaf", .{}, .{leaf});
    var f: Fixture = try .init(&.{ imported_base_module, imported_child_module, leaves }, linux);
    defer f.deinit();
    const base = try f.class("imported_base", "ImportedBase");
    const child = try f.class("imported_child", "ImportedChild");
    const leaf_class = try f.class("imported_leaf", "ImportedLeaf");
    const parent = f.ir.get(child.parent.?);
    try expectEqualStrings("imported_base", parent.module_name);
    try expectEqualStrings("ImportedBase", parent.class_name);
    const initialization = f.ir.class_relations[child.id.index].initialization;
    try expectEqual(base.id, initialization.prototype.class);
    try expectEqual(base.id, initialization.constructor.?.class);
    try expect(initialization.structure == .class);
    try expect(f.ir.class_relations[base.id.index].emission.has_children);
    try expect(f.ir.class_relations[base.id.index].emission.declaration == .bindings_header);
    try expect(f.ir.class_relations[child.id.index].emission.declaration == .bindings_header);
    try expect(f.ir.class_relations[leaf_class.id.index].emission.declaration == .source);
    try std.testing.expectEqualSlices(ir.ClassId, &.{ base.id, child.id }, f.ir.cpp_header_classes);
}

test "normalization resolves class references across schema modules" {
    var f: Fixture = try .init(&.{ imported_base_module, imported_reference_module }, linux);
    defer f.deinit();
    const class = try f.class("imported_base", "ImportedBase");
    const accept = try f.function("imported_reference", "accept");
    const reference = f.at(f.ir.get(accept.args[0].position).type);
    try expectEqual(b.TypeKind.class_ref, reference.kind());
    try expectEqualStrings("imported_base", f.ir.get(reference.data.class_ref.class).module_name);
    try expectEqualStrings("ImportedBase", f.ir.get(reference.data.class_ref.class).class_name);
    const cpp_pointer = f.ir.get(f.ir.get((try f.inputConversion(accept, 0)).value.input).value_type).pointer;
    try expectEqual(reference.data.class_ref.class, f.ir.get(cpp_pointer).native_class);

    try expectEqualStrings("BindClassRefView", try f.wireSpelling(f.ir.get(f.ir.type_plans[reference.id.index].argument_position.?).wire));
    try expect(f.ir.get(accept.args[0].position).zig.leaf.?.decode == .scoped_view);

    try expectEqualStrings("BindClassRef", try f.wireSpelling(f.ir.get(f.ir.type_plans[reference.id.index].result_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[reference.id.index].result_position.?).zig.leaf.?.release == .class_ref);
    try expectEqualStrings("ImportedBase", f.ir.typeScript(reference.id));
    try expect(f.ir.class_relations[class.id.index].emission.declaration == .bindings_header);
}

test "lazy self-reference unions preserve member conversions" {
    var f: Fixture = try .init(&.{self_ref_module}, linux);
    defer f.deinit();
    const accept = try f.member(try f.class("self_ref", "Fluent"), "accept");
    const child = f.ir.get(f.ir.get(accept.args[0].position).representation.leaf.lazy_view.value).representation.union_type;
    try expect(f.ir.get(child[0].value).representation.leaf == .class_view);
    try expect(f.ir.get(child[1].value).representation != .leaf or f.ir.get(child[1].value).representation.leaf != .class_view);
}

test "normalization owns external reference declarations and C++ source dependencies" {
    var f = try testSchema();
    defer f.deinit();
    const declaration_headers = f.ir.external_ref_declaration_headers;
    const source_dependencies = f.ir.cpp_source_dependencies;
    try expect(declaration_headers.len != 0);
    try expect(source_dependencies.len != 0);
    try expectEqualStrings("BunIDLExternalRefs.h", declaration_headers[0]);
    for (declaration_headers, 0..) |header, index| {
        for (declaration_headers[0..index]) |previous| try expect(!std.mem.eql(u8, previous, header));
    }
    for (source_dependencies, 0..) |dependency, index| {
        for (source_dependencies[0..index]) |previous| try expect(!structural.eql(previous, dependency));
    }
    for (f.ir.types[0..f.ir.binding_type_count]) |type_| switch (type_.data) {
        .external_ref => |id| {
            const external = f.ir.get(id);
            try expect(f.ir.get(external.wire).* == .opaque_handle);
            const argument = f.ir.get(f.ir.argumentPosition(type_.id).?);
            const pointer = f.ir.get(argument.wire).pointer;
            try expect(pointer.is_const);
            try expectEqual(external.wire, pointer.child);
            const planned = for (f.ir.cpp_resources) |resource| switch (resource) {
                .external => |reference| if (reference.index == id.index) break true,
                .nominal => {},
            } else false;
            try expect(planned);
        },
        else => {},
    };
}

test "structured clone dispatch checks descendants before ancestors across modules" {
    const base = comptime b.class("CloneBase", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .structured_clone = .{ .tag = 231 },
    });
    const hidden = comptime b.class("HiddenClone", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .exposure = .never,
        .structured_clone = .{ .tag = 232 },
    });
    const child = comptime b.class("CloneChild", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .parent = b.parentClass(base),
        .upcast = "asBase",
        .structured_clone = .{ .tag = 233 },
    });
    const grandchild = comptime b.class("CloneGrandchild", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .parent = b.parentClass(child),
        .upcast = "asChild",
        .structured_clone = .{ .tag = 234 },
    });
    var f: Fixture = try .init(&.{
        b.moduleWithClasses("clone_base", .{}, .{base}),
        b.moduleWithClasses("clone_hidden", .{}, .{hidden}),
        b.moduleWithClasses("clone_child", .{}, .{ child, grandchild }),
    }, linux);
    defer f.deinit();
    const child_class = try f.class("clone_child", "CloneChild");
    const grandchild_class = try f.class("clone_child", "CloneGrandchild");
    try std.testing.expectEqualSlices(ir.ModuleId, &.{ .of(2), .of(0) }, f.ir.structured_clone_modules);
    try std.testing.expectEqualSlices(ir.StructuredCloneId, &.{ grandchild_class.structured_clone.?, child_class.structured_clone.? }, f.ir.modules[2].structured_clones);
    try expectEqual(@as(usize, 0), f.ir.modules[1].structured_clones.len);
}

test "normalization resolves this-class result references" {
    var f: Fixture = try .init(&.{self_ref_module}, linux);
    defer f.deinit();
    const chain = try f.member(try f.class("self_ref", "Fluent"), "chain");
    const reference = f.at(f.ir.get(chain.result_position).type);
    try expectEqual(b.TypeKind.class_ref, reference.kind());
    try expectEqualStrings("self_ref", f.ir.get(reference.data.class_ref.class).module_name);
    try expectEqualStrings("Fluent", f.ir.get(reference.data.class_ref.class).class_name);

    try expect(f.ir.get(chain.result_position).zig.leaf.?.release == .class_ref);
}

test "normalization resolves this-class argument references" {
    var f: Fixture = try .init(&.{self_ref_module}, linux);
    defer f.deinit();
    const accept = try f.member(try f.class("self_ref", "Fluent"), "accept");
    const input = f.at(f.at(f.ir.get(accept.args[0].position).type).data.lazy).data.union_type;
    const reference = f.at(input.union_members[0].member_type);
    try expectEqual(b.TypeKind.class_ref, reference.kind());
    try expectEqualStrings("self_ref", f.ir.get(reference.data.class_ref.class).module_name);
    try expectEqualStrings("Fluent", f.ir.get(reference.data.class_ref.class).class_name);

    try expect(f.ir.get(f.ir.type_plans[reference.id.index].argument_position.?).zig.leaf.?.decode == .scoped_view);
}

test "class receiver plans reference their owner" {
    var f = try testSchema();
    defer f.deinit();
    try expect((try f.boundFunction(test_schema.add)).class_member == null);
    const counter = try f.class("bindgen_test", "Counter");
    const increment = try f.member(counter, "increment");
    try expectEqual(counter.id, f.ir.get(increment.call_plan.receiver.?).representation.leaf.native_receiver);
    const sum = try f.member(counter, "sum");
    try expectEqual(counter.id, f.ir.get(f.case(sum, 0).call_plan.receiver.?).representation.leaf.native_receiver);
}

test "structurally equal semantic types are one type" {
    var f = try testSchema();
    defer f.deinit();
    const equivalent = comptime b.callback("Reducer", .{
        b.argument("value", b.int32, .{}),
        b.argument("label", b.dom_string, .{}),
    }, b.int32, .{ .receiver = null, .profile = .exact });
    try expectEqual((try f.typeId(test_schema.reducer)).index, (try f.typeId(equivalent)).index);
}

fn listener(comptime options: b.ArgumentOptions) b.Type {
    return b.callback("Listener", .{b.argument("values", b.int32, options)}, b.none, .{
        .receiver = null,
    });
}

test "fingerprints follow nested declarations and the normalization input" {
    try expect(structural.hash(comptime listener(.{})) != structural.hash(comptime listener(.{ .rest = true })));
    try expect(try fingerprint(&.{methodReferenceModule(true)}, linux) != try fingerprint(&.{methodReferenceModule(false)}, linux));
    try expect(try fingerprint(&.{exposure_test}, linux) !=
        try fingerprint(&.{exposure_test}, .{ .target = .x86_64_linux, .features = &.{"experimental"} }));
    try expect(try fingerprint(&.{test_schema.schema}, linux) != try fingerprint(&.{test_schema.schema}, .{ .target = .aarch64_linux }));
}

test "link fingerprints include static surface values" {
    const first = comptime b.moduleWithSurfaces("surface_fingerprint", .{
        b.objectSurface("Config", .{b.surfaceString("mode", "first", .{})}, .{ .installation = .direct }),
    });
    const second = comptime b.moduleWithSurfaces("surface_fingerprint", .{
        b.objectSurface("Config", .{b.surfaceString("mode", "second", .{})}, .{ .installation = .direct }),
    });
    try expect(try fingerprint(&.{first}, linux) != try fingerprint(&.{second}, linux));
}

test "normalization makes C++ brand matching exhaustive" {
    var f: Fixture = try .init(&.{brand_normalization_schema}, linux);
    defer f.deinit();
    const inspect = try f.function("brand_normalization_test", "inspect");
    for ([_]ir.CppBrandMatch{
        .{ .value = .{ .symbol = "Bun::isNormalizedValue", .header = "NormalizedValue.h" } },
        .{ .realm = .{ .symbol = "Bun::isNormalizedRealmValue", .header = "NormalizedRealmValue.h" } },
        .{ .dynamic_cast = .{ .type_name = "Bun::NormalizedCell", .header = "NormalizedCell.h" } },
        .{ .value = .{ .symbol = "Bun::isNormalizedValue", .header = "OtherNormalizedValue.h" } },
    }, [_]usize{ 0, 1, 2, 5 }) |expected, index| {
        const matcher = f.at(f.ir.get(inspect.args[index].position).type).data.branded_value.brand.cpp_match;
        try expect(structural.eql(expected, f.ir.get(matcher).*));
        const planned = for (f.ir.cpp_source_dependencies) |dependency| switch (dependency) {
            .brand_match => |id| if (id.index == matcher.index) break true,
            .header, .type_predicates => {},
        } else false;
        try expect(planned);
    }
    const first = f.at(f.ir.get(inspect.args[0].position).type).data.branded_value.brand;
    const other = f.at(f.ir.get(inspect.args[4].position).type).data.branded_value.brand;
    try expect(!std.mem.eql(u8, first.brand_name, other.brand_name));
    try expectEqual(first.cpp_match, other.cpp_match);
    const promise = f.at(f.ir.get(inspect.args[3].position).type).data.branded_value.brand;
    try expect(promise.promise_value_type != null);
    try expectEqual(b.TypeKind.u32, f.at(promise.promise_value_type.?).kind());
}

test "normalization preserves realm-independent engine capabilities" {
    var f: Fixture = try .init(&.{realm_independent_engine_schema}, linux);
    defer f.deinit();
    const shim = try f.engineShim("realm_independent_test", "isNonzero");
    try expect(shim.outbound.call_plan.throws == .never);
    try expectEqual(b.EngineRealm.none, shim.outbound.call_plan.realm);
    try expect(!shim.outbound.call_plan.requires_scope);
    try expect(!shim.outbound.call_plan.checks_traps);
    try expect(!f.ir.get(shim.outbound.result_position).zig.destruction.wire);
}

fn expectNativeSlices(f: *Fixture, arguments: anytype) !void {
    const input = f.at(f.ir.get(arguments[0].position).type).data.native_slice;
    const output = f.at(f.ir.get(arguments[1].position).type).data.native_slice;
    try expectEqual(ir.NativeSliceElement.uint16, input.native_slice_element);
    try expectEqual(b.BufferAccess.read_only, input.native_slice_access);
    try expectEqualStrings("BindConstNativeU16Slice", try f.wireSpelling(f.ir.get(arguments[0].position).wire));
    try expectEqual(ir.NativeSliceElement.uint32, output.native_slice_element);
    try expectEqual(b.BufferAccess.read_write, output.native_slice_access);
    try expectEqualStrings("BindNativeU32Slice", try f.wireSpelling(f.ir.get(arguments[1].position).wire));
}

test "native slices preserve element type and access" {
    var f: Fixture = try .init(&.{native_slice_schema}, linux);
    defer f.deinit();
    const shim = try f.engineShim("native_slice_test", "fill");
    try expectNativeSlices(&f, shim.outbound.args);
}

test "native exports accept direct native slices" {
    var f: Fixture = try .init(&.{native_slice_export_schema}, linux);
    defer f.deinit();
    try expectNativeSlices(&f, (try f.nativeExport("native_slice_export_test", "copy")).args);
}

test "nominal handles are distinct from integers and one another" {
    try expect(owned_native_handle == .nominal_handle);
    try expect(structural.hash(owned_native_handle) != structural.hash(b.uint64));
    try expect(structural.hash(owned_native_handle) != structural.hash(other_native_handle));
    var f: Fixture = try .init(&.{owned_native_export_schema}, linux);
    defer f.deinit();
    const handle = try f.typeOf(owned_native_handle);
    const consume = try f.nativeExport("owned_native_argument_test", "consume");
    const pointer = f.ir.get(f.ir.get(consume.args[0].position).wire).pointer;
    try expect(!pointer.is_const);
    const nominal = handle.data.nominal_handle;
    try expectEqual(pointer.child, nominal.wire);
    try expect(nominal.ownership == .owned);
    try expect(!nominal.const_pointee);
    const ownership = f.ir.get(nominal.ownership.owned);
    try expectEqualStrings("readOwnedNativeArgumentBytes", ownership.byte_access.?.cpp_read);
    try expectEqualStrings("never", f.ir.typeScript(handle.id));
    try expectEqual(@as(usize, 1), f.ir.cpp_resources.len);
    const resource = f.ir.cpp_resources[0].nominal;
    try expectEqual(nominal.ownership.owned, resource.ownership);
    try expectEqual(nominal.cpp_type, resource.native_type);
    try expectEqual(pointer.child, resource.wire);
}

test "modules preserve native export declaration order" {
    var f: Fixture = try .init(&.{owned_native_export_schema}, linux);
    defer f.deinit();
    const declarations = f.ir.modules[0].native_declarations;
    try expectEqualStrings("consume", f.ir.get(declarations[0]).export_name);
    try expectEqualStrings("create", f.ir.get(declarations[1]).export_name);
}

test "native exports transfer owned nominal handle arguments" {
    var f: Fixture = try .init(&.{owned_native_export_schema}, linux);
    defer f.deinit();
    const native_export = try f.nativeExport("owned_native_argument_test", "consume");
    const argument = native_export.args[0];
    try expect(f.ir.get(argument.position).transfer);
    try expect(native_export.call_plan.transfers_argument_ownership);
    try expect(f.ir.get(argument.position).zig.leaf.?.decode == .adopt_wire);
}

test "native exports transfer owned nominal handle results" {
    var f: Fixture = try .init(&.{owned_native_export_schema}, linux);
    defer f.deinit();
    const native_export = try f.nativeExport("owned_native_argument_test", "create");
    try expect(f.ir.get(native_export.result_position).zig.leaf.?.encode == .take_wire);
    try expect(native_export.destroy_result_symbol != null);
}

test "engine calls retain cleanup plans for transferred inputs and owned results" {
    const choice = comptime b.unionType("OwnedNativeArgumentChoice", .{
        b.unionMember("number", b.int32),
        b.unionMember("resource", owned_native_handle),
    }, .{ .ordered = true });
    const fields = comptime b.dictionary("OwnedNativeArgumentFields", .{
        b.dictionaryField("count", b.size, .{ .required = true }),
        b.dictionaryField("choice", choice, .{ .required = true }),
    });
    var f: Fixture = try .init(&.{b.moduleWithEngineShims("engine_ownership", .{}, .{
        b.engineShim("consume", .{b.argument("resource", owned_native_handle, .{ .ownership = .transfer })}, b.none, realm_free_any_thread),
        b.engineShim("replace", .{
            b.argument("resources", b.sequence(owned_native_handle), .{ .ownership = .transfer }),
            b.argument("borrowed", owned_native_handle, .{}),
        }, b.optional(owned_native_handle), .{ .realm = .current, .throws = .out_of_memory, .affinity = .vm }),
        b.engineShim("consumeChoice", .{b.argument("value", fields, .{ .ownership = .transfer })}, b.none, realm_free_any_thread),
    })}, linux);
    defer f.deinit();
    const consume = try f.engineShim("engine_ownership", "consume");
    const consume_call = f.ir.cpp_engine_calls[consume.id.index].entries[0].operation.invoke;
    try expect(consume_call.result == null);
    try expect(consume_call.callee.native.context == .none);
    try expect(!consume_call.callee.native.argument_storage);
    try expectEqual(consume.outbound.args[0].position, consume_call.callee.native.transferred[0].position);
    const replace = try f.engineShim("engine_ownership", "replace");
    const replace_call = f.ir.cpp_engine_calls[replace.id.index].entries[0].operation.invoke;
    const native = replace_call.callee.native;
    try expect(native.argument_storage);
    try expectEqual(@as(usize, 1), native.transferred.len);
    try expectEqualStrings("resources", native.transferred[0].name);
    try expectEqual(replace.outbound.args[0].position, native.transferred[0].position);
    try expectEqual(replace.outbound.result_position, replace_call.result.?.conversion.native.owned.?);
    try expectEqual(replace.outbound.result_position, replace_call.result.?.position);
    try expect(f.decodePlan(native.arguments[0].decoder.position).operation == .body);
    try expect(f.ir.get(native.arguments[0].decoder.position).representation == .sequence);
    const consume_choice = try f.engineShim("engine_ownership", "consumeChoice");
    const choice_fields = f.ir.get(consume_choice.outbound.args[0].position).representation.dictionary;
    for (choice_fields) |field| try expectEqual(std.mem.eql(u8, field.name, "choice"), f.ir.get(field.value).cpp.release.owned_handles);
    const choice_field = for (choice_fields) |field| {
        if (std.mem.eql(u8, field.name, "choice")) break f.ir.get(field.value);
    } else return error.TestUnexpectedResult;
    const choice_members = choice_field.representation.union_type;
    for (choice_members, 0..) |member, index| try expectEqual(index == 1, f.ir.get(member.value).cpp.release.owned_handles);
    try expectEqualStrings("resource", choice_members[1].name);
    try expectEqual((try f.typeOf(owned_native_handle)).data.nominal_handle.ownership.owned, f.ir.get(choice_members[1].value).representation.leaf.nominal_owned);
}

test "normalization groups standalone native export headers" {
    var f: Fixture = try .init(&.{ owned_native_export_schema, b.moduleWithNativeExports("other_native_argument", .{}, .{
        b.nativeExport("borrow", .{b.argument("value", other_native_handle, .{})}, b.none),
    }) }, linux);
    defer f.deinit();
    try expectEqual(@as(usize, 1), f.ir.standalone_native_export_header_plans.len);
    const plan = f.ir.standalone_native_export_header_plans[0];
    try expectEqualStrings("OwnedNativeArgument", plan.header);
    try expectEqual(@as(usize, 2), plan.exports.len);
    try expectEqual(@as(usize, 1), plan.nominal_handle_declarations.len);
    try expectEqualStrings("OwnedNativeArgument", f.ir.get(plan.nominal_handle_declarations[0]).structure);
    try expectEqual(@as(usize, 2), f.ir.cpp_header_declarations.len);
    try expectEqual(plan.nominal_handle_declarations[0], f.ir.cpp_header_declarations[0]);
    try expectEqualStrings("OtherNativeArgument", f.ir.get(f.ir.cpp_header_declarations[1]).structure);
}

test "standalone C adapters carry their signature and conversions in wire types" {
    var f: Fixture = try .init(&.{ owned_native_export_schema, b.moduleWithNativeExports("native_c_adapter", .{}, .{
        b.nativeExportWithOptions("consume", .{
            b.argument("enabled", b.boolean, .{}),
            b.argument("values", b.nativeSlice(.uint16, .read_only), .{}),
        }, b.int32, .{ .standalone_header = "NativeCAdapter" }),
    }) }, linux);
    defer f.deinit();
    const consume = try f.nativeExport("native_c_adapter", "consume");
    const declaration = for (f.ir.wire_types) |wire_type| {
        if (wire_type.name()) |name| if (std.mem.eql(u8, try name.alloc(f.arena.allocator()), "bunBindgenC_native_c_adapter_consume")) break wire_type;
    } else return error.MissingWireAdapter;
    const signature = declaration.function;
    const adapter = signature.body.adapter;
    try expectEqualStrings(consume.dispatch_symbol, try f.wireSpelling(adapter.callee));
    try expectEqualStrings("BindStatus", try f.wireSpelling(adapter.status));
    try expectEqual(@as(usize, 3), signature.parameters.len);
    try expectEqualStrings("uint8_t", try f.wireSpelling(signature.parameters[0].type));
    try expectEqualStrings("const uint16_t*", try f.wireSpelling(signature.parameters[1].type));
    try expectEqualStrings("size_t", try f.wireSpelling(signature.parameters[2].type));
    try expect(adapter.inputs[0].operation == .boolean);
    try expectEqual(@as(u32, 2), adapter.inputs[1].operation.slice);
    try expectEqualStrings("value", adapter.result_field.?);
    const owned_declaration = for (f.ir.wire_types) |wire_type| {
        if (wire_type.name()) |name| if (std.mem.eql(u8, try name.alloc(f.arena.allocator()), "bunBindgenC_owned_native_argument_test_consume")) break wire_type;
    } else return error.MissingWireAdapter;
    const handle = f.ir.get(owned_declaration.function.parameters[0].type).pointer;
    try expect(f.ir.get(handle.child).* == .forward_structure);
    try expectEqualStrings("OwnedNativeArgument", try f.wireSpelling(handle.child));
    try expect(owned_declaration.function.body.adapter.inputs[0].operation == .nonnull_pointer);
}

test "native exports transfer dictionary results containing owned values" {
    var f: Fixture = try .init(&.{native_dictionary_result_schema}, linux);
    defer f.deinit();
    const native_export = try f.nativeExport("native_dictionary_result_test", "create");
    try expect(f.ir.get(native_export.result_position).zig.destruction.wire);
}

test "native exports retain converted semantic inputs" {
    var f: Fixture = try .init(&.{converted_native_export_schema}, linux);
    defer f.deinit();
    const native_export = try f.nativeExport("converted_native_export_test", "consume");
    const converted = f.at(f.ir.get(native_export.args[0].position).type);
    try expectEqual(b.TypeKind.converted, converted.kind());
    try expectEqual(b.TypeKind.u32, f.at(converted.data.converted.native_type).kind());
    try expectEqualStrings("uint32_t", try f.wireSpelling(f.ir.get(f.ir.type_plans[converted.id.index].argument_position.?).wire));
}

test "native exports retain converted dictionaries" {
    var f: Fixture = try .init(&.{converted_native_export_schema}, linux);
    defer f.deinit();
    const dictionary = try f.typeOf(converted_native_dictionary);
    const native_export = try f.nativeExport("converted_native_export_test", "consumeDictionary");
    try expectEqual(f.ir.get(f.ir.type_plans[dictionary.id.index].argument_position.?).wire, f.ir.get(native_export.args[0].position).wire);
    const parameter = f.ir.get(f.ir.cpp_native_exports[native_export.id.index].?.entry.signature.parameters[0].type.native);
    const converter = f.ir.get(parameter.operation.javascript);
    const result = try f.definition(f.ir.get(converter.value_type).named.name);
    try expectEqualStrings("ConvertedNativeDictionaryResult", result.name);
}

test "current-realm native exports accept dictionary arguments" {
    var f: Fixture = try .init(&.{converted_native_export_schema}, linux);
    defer f.deinit();
    const dictionary = try f.typeOf(converted_native_dictionary);
    const native_export = try f.nativeExport("converted_native_export_test", "consumeDirectDictionary");
    try expectEqual(f.ir.get(f.ir.type_plans[dictionary.id.index].argument_position.?).wire, f.ir.get(native_export.args[0].position).wire);
}

test "current-realm native exports retain lazy arguments" {
    var f: Fixture = try .init(&.{converted_native_export_schema}, linux);
    defer f.deinit();
    const native_export = try f.nativeExport("converted_native_export_test", "consumeLazy");
    const lazy = f.at(f.ir.get(native_export.args[0].position).type);
    try expectEqual(b.TypeKind.lazy, lazy.kind());
    try expectEqualStrings("BindLazyArgumentHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[lazy.id.index].argument_position.?).wire));
    try expectEqualStrings("BindStringHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[f.at(lazy.data.lazy).id.index].result_position.?).wire));
    const storage = f.ir.cpp_native_exports[native_export.id.index].?.entry.call.callee.wire.lazy_storage.?;
    try expectEqual(@as(usize, 1), storage.converters.len);
    try expectEqual(native_export.args[0].position, storage.converters[0].position);
    try expect(!storage.receiver);
}

test "normalization preserves declared invocation metadata" {
    var f: Fixture = try .init(&.{invocation_metadata_schema}, linux);
    defer f.deinit();
    const inspect = try f.function("invocation_metadata_test", "inspect");
    try expect(inspect.this_argument != null);
    try expect(inspect.callee_argument != null);
    try expect(inspect.has_caller_source_location);
    try expect(inspect.new_target_argument == null);
    try expect(f.ir.functionCpp(inspect).call.entry.callee.wire.context.caller_frame);
    const cpp = f.ir.functionCpp(try f.function("invocation_metadata_test", "inspectCpp")).call.entry.callee.cpp;
    try expect(f.ir.get(cpp).context.call.caller_source_origin);
    try expect(f.ir.get(cpp).context.call.receiver == .none);
}

test "call plans preserve lazy conversion and lease requirements" {
    var f: Fixture = try .init(&.{ test_schema.schema, invocation_conversion_schema, receiver_conversion_schema }, linux);
    defer f.deinit();
    const lazy_converted = try f.function("bindgen_test", "inspectLazyConvertedLabel");
    const lease = try f.boundFunction(test_schema.inspect_lease_after_callback);
    const invocation = try f.function("invocation_conversion_test", "inspect");
    const receiver = try f.function("receiver_conversion_test", "read");
    const lazy_receiver = try f.function("receiver_conversion_test", "readLazy");

    try expect(lazy_converted.call_plan.has_lazy_conversion);
    try expect(lease.call_plan.acquires_byte_lease);
    const callee_conversion = (try f.inputConversion(invocation, @intCast(invocation.args.len + 2))).value.input;
    try expect(f.ir.get(callee_conversion).operation == .converted);
    try expectEqual(@as(?ir.CppReceiverValue, .cpp), f.ir.get(f.ir.functionCpp(receiver).call.entry.frame.?).converter_receiver);
    try expect(lazy_receiver.call_plan.has_lazy_conversion);
    try expectEqual(@as(?ir.CppReceiverValue, .frame), f.ir.get(f.ir.functionCpp(lazy_receiver).call.entry.frame.?).converter_receiver);
    const lease_frame = f.ir.get(f.ir.functionCpp(lease).call.entry.frame.?);
    try expect(lease_frame.deferred_conversions);
    const inputs = f.ir.functionCpp(lazy_receiver).call.entry.inputs;
    try expect(inputs[0] == .prepare_arguments);
    try expect(inputs[1] == .javascript);
    try expectEqual(lazy_receiver.this_argument.?.position, inputs[1].javascript.conversion.value.input.position);
    try expect(inputs[2].retain_lazy_receiver == .frame);
    const storage = f.ir.functionCpp(lazy_receiver).call.entry.callee.wire.lazy_storage.?;
    try expect(storage.receiver);
    try expectEqual(@as(usize, 1), storage.converters.len);
    const lazy_label = try f.function("receiver_conversion_test", "readLazyLabel");
    try expect(lazy_label.call_plan.has_lazy_arguments);
    const label_call = f.ir.functionCpp(lazy_label).call.entry;
    try expectEqual(@as(?ir.CppReceiverValue, .frame), f.ir.get(label_call.frame.?).converter_receiver);
    try expect(!label_call.callee.wire.lazy_storage.?.receiver);
    for (label_call.inputs) |input| try expect(input != .retain_lazy_receiver);
}

fn expectLazyConverter(f: *const Fixture, function: *const ir.Function, index: usize) !void {
    const argument = function.args[index];
    const storage = f.ir.functionCpp(function).call.entry.callee.wire.lazy_storage.?;
    const converter = for (storage.converters) |value| {
        if (value.index == index) break value;
    } else return error.MissingLazyConverter;
    try expectEqual((if (argument.rest_position) |rest| rest.plan() else argument.position), converter.position);
    const program = f.ir.get(f.ir.get(converter.position).api).representation;
    const symbol_name, const expected = switch (program) {
        inline .lazy_view, .lazy_rest => |lazy| .{ lazy.symbol, lazy.result_wire },
        else => return error.MissingLazyConverter,
    };
    const symbol: ir.WireName = .{ .lazy_convert = symbol_name };
    const declaration = for (f.ir.wire_types) |wire_type| {
        if (wire_type.name()) |name| if (structural.eql(name, symbol)) break wire_type.function;
    } else return error.MissingLazyConverter;
    const result = declaration.parameters[declaration.parameters.len - 1];
    try expectEqual(expected, f.ir.get(result.type).pointer.child);
}

test "normalization preserves lazy rest conversion" {
    var f: Fixture = try .init(&.{lazy_rest_schema}, linux);
    defer f.deinit();
    const resolve = try f.function("lazy_rest_test", "resolve");
    const argument = resolve.args[0];
    const lazy = f.at(f.ir.get(argument.position).type);
    try expect(argument.conversion.rest);
    try expectEqual(b.TypeKind.lazy, lazy.kind());
    try expectEqual(b.TypeKind.dom_string, f.at(lazy.data.lazy).kind());
    try expectEqualStrings("BindLazyArgumentHandle*", try f.wireSpelling(f.ir.get(argument.position).wire));
    try expectLazyConverter(&f, resolve, 0);
}

test "discarded inputs preserve classification, presence, and count operations" {
    var f: Fixture = try .init(&.{discard_purpose_schema}, linux);
    defer f.deinit();
    const classify = try f.function("discard_purpose_test", "classifyUnion");
    const union_input = f.aggregate((try f.inputConversion(classify, 0)).value.input).operation.union_type;
    try expect(union_input.operation.matching.tests[1] == .always);
    try expect(f.ir.get(union_input.members[1].value).operation == .discarded);
    const overload = try f.function("discard_purpose_test", "classifyOverload");
    try expect(f.ir.get((try f.inputConversion(f.case(overload, 1), 0)).value.input).operation == .discarded);
    const ignored = try f.function("discard_purpose_test", "ignore");
    try expect(f.ir.get((try f.inputConversion(ignored, 0)).value.input).operation == .discarded);
    const presence = try f.function("discard_purpose_test", "checkPresence");
    const field = f.ir.get(f.aggregate((try f.inputConversion(presence, 0)).value.input).operation.dictionary.fields[0].value);
    try expect(field.presence == .optional);
    try expect(f.ir.get(field.input).operation == .discarded);
    const count = try f.function("discard_purpose_test", "count");
    try expect((try f.inputConversion(count, 0)).rest == .count);
    try expectEqual(ir.ScalarKind.usize, f.ir.get(count.args[0].rest_position.?.plan()).representation.leaf.scalar);
}

test "normalization preserves union member conversion policies" {
    const conversion_union_type = comptime b.unionType("ConversionPolicyUnion", .{
        b.unionMemberWithOptions("boolean", b.boolean, .{ .boolean_conversion = .strict_true }),
        b.unionMemberWithOptions("integer", b.uint32, .{ .integer_conversion = .webidl }),
        b.unionMemberWithOptions("number", b.double, .{ .number_conversion = .coerce }),
    }, .{ .ordered = true });
    var f: Fixture = try .init(&.{b.module("union_conversion_policy_test", .{
        b.function("consume", .{b.argument("value", conversion_union_type, .{})}, b.none, .{}),
    })}, linux);
    defer f.deinit();
    const members = f.aggregate((try f.inputConversion(try f.function("union_conversion_policy_test", "consume"), 0)).value.input).operation.union_type.members;
    try expect(f.scalar(members[0].value).operation.boolean == .strict_true);
    try expectEqual(ir.CppBuiltin.webidl_u32, f.scalarType(members[1].value).builtin);
    try expectEqual(ir.CppBuiltin.unrestricted_double, f.scalarType(members[2].value).builtin);
}

fn consumeModule(comptime name: []const u8, comptime argument: b.Argument, comptime profile: b.Profile) b.Module {
    return b.module(name, .{b.function("consume", .{argument}, b.none, .{ .profile = profile })});
}

test "strict enumeration errors override coercing profiles" {
    const errors: b.EnumerationErrors = .{
        .invalid_type = .{ .kind = .type_error, .message = "string required" },
        .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_VALUE" }, .message = "unknown mode" },
    };
    const mode = comptime b.enumerationWithOptions("StrictMode", .{
        b.enumerationValue("enabled", "enabled"),
        b.enumerationValue("disabled", "disabled"),
    }, .{ .strict_errors = errors });
    inline for (.{ b.Profile.webidl, b.Profile.node, b.Profile.exact }) |profile| {
        var f: Fixture = try .init(&.{consumeModule("strict_enumeration_test", b.argument("value", mode, .{}), profile)}, linux);
        defer f.deinit();
        const conversion = f.ir.get((try f.inputConversion(try f.function("strict_enumeration_test", "consume"), 0)).value.input).operation.enumeration;
        try expect(conversion.string.reject_non_string.value.error_value.custom.kind == .type_error);
        try expectEqualStrings("unknown mode", conversion.unmatched.failure.value.error_value.custom.message);
    }
}

test "strict nullable boolean failures remain explicit across profiles" {
    const failure: b.ConversionFailure = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "enabled must be a boolean",
    };
    const options = comptime b.dictionary("StrictBooleanOptions", .{
        archetypes.strictBooleanField("enabled", b.optionalNullish(b.boolean), failure, .{}),
    });
    inline for (.{ b.Profile.webidl, b.Profile.node, b.Profile.exact }) |profile| {
        var f: Fixture = try .init(&.{consumeModule("strict_boolean_test", b.argument("options", options, .{}), profile)}, linux);
        defer f.deinit();
        const dictionary = f.aggregate((try f.inputConversion(try f.function("strict_boolean_test", "consume"), 0)).value.input).operation.dictionary.fields;
        const child = f.ir.get(f.ir.get(dictionary[0].value).input).operation.optional.value;
        try expect(f.scalar(child).context != .none);
        const template = f.scalarType(child).template;
        try expectEqual(ir.CppTemplate.strict_boolean, template.name);
        const normalized = f.ir.get(template.arguments[0].type).conversion_failure;
        try expectEqualStrings(failure.kind.code, normalized.kind.code);
        try expectEqualStrings(failure.message, normalized.message);
    }
}

test "truncated integers retain Number matching and explicit NaN behavior across profiles" {
    const range: b.IntegerRange = .{ .min = 0, .max = 9007199254740991 };
    const value = comptime archetypes.truncatedIntegerOrIgnored("ClampedIntegerInput", b.size, .{ .range = range, .nan = range.max });
    inline for (.{ b.Profile.webidl, b.Profile.node, b.Profile.exact }) |profile| {
        var f: Fixture = try .init(&.{consumeModule("truncated_integer_test", b.argument("value", value, .{}), profile)}, linux);
        defer f.deinit();
        const union_input = f.aggregate((try f.inputConversion(try f.function("truncated_integer_test", "consume"), 0)).value.input).operation.union_type;
        const members = union_input.members;
        const policy = f.scalarType(members[0].value).template;
        try expectEqual(ir.CppTemplate.truncated_integer_clamp, policy.name);
        try expectEqual(@as(u64, @intCast(range.min)), policy.arguments[1].integer.unsigned_long);
        try expectEqual(@as(u64, @intCast(range.max)), policy.arguments[2].integer.unsigned_long);
        try expectEqual(@as(u64, @intCast(range.max)), policy.arguments[3].integer.unsigned_long);
        try expect(f.scalar(members[0].value).context != .none);
        try expect(union_input.operation.matching.tests[1] == .always);
    }
}

test "bounded integer policies survive nullable lowering" {
    const validation: b.BoundedIntegerValidation = .{
        .range = .{ .min = 0, .max = 960 },
        .below = .saturate,
        .invalid = .{ .kind = .type_error, .message = "integer required" },
        .out_of_range = .{ .kind = .{ .code = "ERR_OUT_OF_RANGE" }, .message = "integer too large" },
    };
    var f: Fixture = try .init(&.{consumeModule("bounded_integer_test", b.argument("value", b.optionalNullish(b.uint16), .{
        .integer_conversion = .{ .bounded_integer = validation },
    }), .exact)}, linux);
    defer f.deinit();
    const optional = f.ir.get((try f.inputConversion(try f.function("bounded_integer_test", "consume"), 0)).value.input).operation.optional.value;
    const policy = f.scalarType(optional).template;
    try expectEqual(ir.CppTemplate.bounded_integer, policy.name);
    try expectEqual(@as(i64, 0), policy.arguments[1].integer.signed);
    try expectEqual(@as(i64, 960), policy.arguments[2].integer.signed);
    try expect(policy.arguments[3].boolean and !policy.arguments[4].boolean);
    const invalid = f.ir.get(policy.arguments[6].type).conversion_failure;
    const out_of_range = f.ir.get(policy.arguments[7].type).conversion_failure;
    try expect(invalid.kind == .type_error);
    try expectEqualStrings("ERR_OUT_OF_RANGE", out_of_range.kind.code);
    try expectEqualStrings("integer required", invalid.message);
    try expectEqualStrings("integer too large", out_of_range.message);
}

fn numberRangeUsesTypeError(comptime error_class: b.ErrorClass) !bool {
    var f: Fixture = try .init(&.{consumeModule("number_range_error_test", b.argument("value", b.lazy(b.double), .{
        .deferred_reason = "native state is checked before validating the number",
        .number_conversion = .{ .enforce_range = .{
            .range = .{ .min = 0, .max = 100 },
            .error_message = "number is outside the supported range",
            .error_class = error_class,
        } },
    }), .exact)}, linux);
    defer f.deinit();
    const child = (try f.inputConversion(try f.function("number_range_error_test", "consume"), 0)).lazy.input.value;
    const conversion = f.scalarType(child).template;
    try expectEqual(ir.CppTemplate.number_enforce_range, conversion.name);
    return conversion.arguments[3].boolean;
}

test "number range error classes survive lazy normalization" {
    try expect(try numberRangeUsesTypeError(.type_error));
    try expect(!try numberRangeUsesTypeError(.range_error));
}

test "truncated clamp normalization retains its range and nonfinite fallback" {
    const value = comptime b.unionType("TruncatedClampValue", .{
        b.unionMemberWithOptions("number", b.double, .{
            .number_conversion = .{ .coerce_truncate_clamp = .{
                .range = .{ .min = 256, .max = 4096 },
                .fallback = 256,
            } },
        }),
        b.unionMember("ignored", b.discardAny(.ignored)),
    }, .{ .ordered = true, .fallback_member = "ignored" });
    var f: Fixture = try .init(&.{consumeModule("truncated_clamp_test", b.argument("value", value, .{}), .node)}, linux);
    defer f.deinit();
    const union_input = f.aggregate((try f.inputConversion(try f.function("truncated_clamp_test", "consume"), 0)).value.input).operation.union_type;
    const members = union_input.members;
    const policy = f.scalarType(members[0].value).template;
    try expectEqual(ir.CppTemplate.truncated_clamped_number, policy.name);
    try expectEqual(@as(f64, 256), policy.arguments[0].double_bits);
    try expectEqual(@as(f64, 4096), policy.arguments[1].double_bits);
    try expectEqual(@as(f64, 256), policy.arguments[2].double_bits);
    try expect(union_input.operation.matching.tests[1] == .always);
}

test "sequence element conversion policies normalize" {
    const bytes = comptime b.sequenceWithOptions(b.uint8, .{ .element_conversion = .{ .integer_conversion = .truncate_saturate } });
    const booleans = comptime b.sequenceWithOptions(b.boolean, .{ .element_conversion = .{ .boolean_conversion = .truthy } });
    const numbers = comptime b.sequenceWithOptions(b.double, .{
        .container = .iterable,
        .element_conversion = .{ .number_conversion = .coerce },
    });
    var f: Fixture = try .init(&.{b.module("sequence_conversion_policy_test", .{b.function(
        "consume",
        .{ b.argument("bytes", bytes, .{}), b.argument("booleans", booleans, .{}), b.argument("numbers", numbers, .{}) },
        b.none,
        .{ .profile = .exact },
    )})}, linux);
    defer f.deinit();
    const function = try f.function("sequence_conversion_policy_test", "consume");
    const byte_element = f.aggregate((try f.inputConversion(function, 0)).value.input).operation.sequence.value;
    const boolean_element = f.aggregate((try f.inputConversion(function, 1)).value.input).operation.sequence.value;
    const number_element = f.aggregate((try f.inputConversion(function, 2)).value.input).operation.sequence.value;
    try expectEqual(ir.CppTemplate.saturated_integer, f.scalarType(byte_element).template.name);
    try expectEqual(ir.ConversionContext.exact_literal, f.scalar(byte_element).context);
    try expect(f.scalar(boolean_element).operation.boolean == .truthy);
    try expectEqual(ir.ConversionContext.none, f.scalar(boolean_element).context);
    try expectEqual(ir.CppBuiltin.unrestricted_double, f.scalarType(number_element).builtin);
    try expectEqual(ir.ConversionContext.none, f.scalar(number_element).context);
    try expect(f.aggregate((try f.inputConversion(function, 2)).value.input).operation.sequence.operation == .iterable);
}

test "normalization preserves overload trailing argument policy" {
    var f: Fixture = try .init(&.{extra_argument_overload_schema}, linux);
    defer f.deinit();
    const select = try f.function("extra_argument_overload_test", "select");
    const dispatch = f.ir.functionCpp(select).overload;
    try expectEqual(ir.OverloadArgumentCount{ .clamped = 1 }, dispatch.argument_count);
    try expectEqual(@as(u32, 1), dispatch.underflow.reject.minimum);
    for (dispatch.cases) |case| {
        try expectEqual(@as(u32, 1), case.minimum_argument_count);
        try expectEqualStrings(f.ir.get(case.declaration).host_symbol, case.symbol);
    }
    try expectEqual(@as(?usize, 1), dispatch.cases[0].maximum_argument_count);
    try expectEqual(@as(?usize, 1), dispatch.cases[1].maximum_argument_count);
    const first = dispatch.cases[0].comparisons[0];
    try expectEqual(@as(usize, 1), first.overlap_minimum);
    try expectEqual(@as(?usize, 1), first.overlap_maximum);
    try expectEqual(@as(usize, 1), first.arguments.len);
    try expectEqual(@as(u32, 0), first.arguments[0].index);
}

test "overload underflow dispatches to the smallest required case" {
    const overloads = comptime b.overloads(.{
        b.overloadCase("pair", .{ b.argument("number", b.int32, .{}), b.argument("flag", b.boolean, .{}) }),
        b.overloadCase("text", .{b.argument("value", b.dom_string, .{})}),
    }, .{});
    const failure: b.ConversionFailure = .{ .kind = .type_error, .message = "Expected at least one value" };
    var f: Fixture = try .init(&.{b.module("overload_underflow", .{
        b.function("convertMissing", overloads, b.none, .{ .profile = .exact, .missing_required_arguments = .convert_undefined }),
        b.function("custom", overloads, b.none, .{ .profile = .exact, .missing_required_arguments = .{ .failure = failure } }),
        b.function("empty", b.overloads(.{
            b.overloadCase("none", .{}),
            b.overloadCase("number", .{b.argument("value", b.int32, .{})}),
        }, .{}), b.none, .{ .profile = .exact }),
    })}, linux);
    defer f.deinit();
    const function = try f.function("overload_underflow", "convertMissing");
    const dispatch = f.ir.functionCpp(function).overload;
    try expectEqual(@as(u32, 2), dispatch.cases[0].minimum_argument_count);
    try expectEqual(@as(u32, 1), dispatch.cases[1].minimum_argument_count);
    try expectEqual(@as(u32, 1), dispatch.underflow.dispatch);
    const empty = f.ir.functionCpp(try f.function("overload_underflow", "empty")).overload;
    try expect(empty.underflow == .none);
    try expectEqual(@as(u32, 0), empty.cases[0].minimum_argument_count);
    const custom = try f.function("overload_underflow", "custom");
    const rejection = f.ir.functionCpp(custom).overload.underflow.reject;
    try expectEqual(@as(u32, 1), rejection.minimum);
    try expect(rejection.failure.custom.value.kind == .type_error);
    try expectEqualStrings(failure.message, rejection.failure.custom.value.message);
    try expect(rejection.failure.custom.return_value == .empty);
    const case_check = f.requiredCheck(f.case(custom, 0)).?;
    try expectEqual(@as(u32, 2), case_check.minimum);
    try expectEqualStrings(failure.message, case_check.failure.custom.value.message);
}

test "overload fallback preserves arity and typed conversion" {
    var f: Fixture = try .init(&.{b.module("overload_fallback_test", .{b.function(
        "consume",
        b.overloads(.{
            b.overloadCase("string", .{b.argument("value", b.dom_string, .{})}),
            b.overloadCase("byte", .{b.argument("value", b.uint8, .{ .integer_conversion = .webidl })}),
        }, .{ .ordered = true, .fallback_case = "byte" }),
        b.none,
        .{ .profile = .node },
    )})}, linux);
    defer f.deinit();
    const consume = try f.function("overload_fallback_test", "consume");
    const dispatch = f.ir.functionCpp(consume).overload;
    try expectEqual(@as(?usize, 1), dispatch.cases[1].maximum_argument_count);
    try expectEqual(@as(u32, 1), dispatch.cases[1].minimum_argument_count);
    try expectEqual(@as(usize, 1), dispatch.cases[0].comparisons.len);
    try expectEqual(@as(usize, 0), dispatch.cases[1].comparisons.len);
    try expectEqual(ir.CppBuiltin.webidl_u8, f.scalarType((try f.inputConversion(f.case(consume, 1), 0)).value.input).builtin);
}

test "explicit overload discriminants leave trailing coercions to dispatch" {
    const arguments = comptime .{
        b.argument("buffer", b.js_any_array_buffer_object, .{}),
        b.argument("offset", b.lazy(b.double), .{
            .number_conversion = .coerce,
            .deferred_reason = "buffer detachment is checked before coercing the offset",
        }),
    };
    var f: Fixture = try .init(&.{b.module("overload_discriminants_test", .{b.function(
        "consume",
        b.overloads(.{
            b.overloadCaseWithOptions("buffer", arguments, .{ .discriminants = &.{0} }),
            b.overloadCase("other", .{b.rest("values", b.discarded)}),
        }, .{ .ordered = true, .fallback_case = "other" }),
        b.none,
        .{ .profile = .exact },
    )})}, linux);
    defer f.deinit();
    const consume = try f.function("overload_discriminants_test", "consume");
    const arguments_to_match = f.ir.functionCpp(consume).overload.cases[0].comparisons[0].arguments;
    try expectEqual(@as(usize, 1), arguments_to_match.len);
    try expectEqual(@as(u32, 0), arguments_to_match[0].index);
    try expectEqual(@as(usize, 2), f.case(consume, 0).args.len);
}

test "array-like sequences preserve indexed traversal and snapshot policy" {
    const indexed = comptime b.sequenceWithOptions(b.uint8, .{
        .container = .array_like,
        .element_conversion = .{ .integer_conversion = .webidl },
    });
    const snapshot = comptime b.sequenceWithOptions(b.uint8, .{
        .container = .array_like,
        .snapshot_elements = true,
        .element_conversion = .{ .integer_conversion = .webidl },
    });
    var f: Fixture = try .init(&.{b.module("array_like_sequence_test", .{b.function(
        "consume",
        .{ b.argument("indexed", indexed, .{}), b.argument("snapshot", snapshot, .{}) },
        b.none,
        .{ .profile = .exact },
    )})}, linux);
    defer f.deinit();
    const consume = try f.function("array_like_sequence_test", "consume");
    const indexed_plan = f.aggregate((try f.inputConversion(consume, 0)).value.input).operation.sequence.operation.indexed;
    const snapshot_plan = f.aggregate((try f.inputConversion(consume, 1)).value.input).operation.sequence.operation.indexed;
    try expect(indexed_plan.selection == .object);
    try expect(indexed_plan.read.interleaved.method == .property);
    try expect(snapshot_plan.read.snapshot.method == .property);
}

test "iterable snapshots exhaust the iterator before element conversion" {
    var f: Fixture = try .init(&.{consumeModule("iterable_snapshot_test", b.argument("values", b.sequenceWithOptions(b.uint8, .{
        .container = .iterable,
        .snapshot_elements = true,
        .element_conversion = .{ .integer_conversion = .webidl },
    }), .{}), .exact)}, linux);
    defer f.deinit();
    const function = try f.function("iterable_snapshot_test", "consume");
    const traversal = f.aggregate((try f.inputConversion(function, 0)).value.input).operation.sequence.operation.iterable;
    try expect(traversal.snapshot);
}

test "normalization owns conversion context selection" {
    const basic_enumeration = comptime b.enumeration("ConversionContextEnumeration", .{
        b.enumerationValue("enabled", "enabled"),
    });
    var f: Fixture = try .init(&.{
        b.module("conversion_context_test", .{
            b.function("consume", .{
                b.argument("flag", b.boolean, .{}),
                b.argument("count", b.int32, .{}),
                b.argument("text", b.dom_string, .{}),
                b.argument("ratio", b.double, .{}),
                b.argument("signal", b.abort_signal, .{}),
                b.argument("mode", basic_enumeration, .{}),
            }, b.none, .{ .profile = .exact }),
            b.function("webEnum", .{
                b.argument("mode", basic_enumeration, .{}),
                b.argument("count", b.int32, .{}),
                b.argument("signal", b.abort_signal, .{}),
            }, b.none, .{ .profile = .webidl }),
            b.function("nodeEnum", .{
                b.argument("mode", basic_enumeration, .{}),
                b.argument("flag", b.boolean, .{}),
                b.argument("ratio", b.double, .{}),
                b.argument("signal", b.abort_signal, .{}),
            }, b.none, .{ .profile = .node }),
            b.function("nodeProse", .{
                b.argument("count", b.int32, .{ .integer_conversion = .{ .node_validate_prose = .{ .min = 0, .max = 10 } } }),
                b.argument("ratio", b.double, .{ .number_conversion = .coerce }),
            }, b.none, .{ .profile = .node }),
        }),
        conversion_schema,
    }, linux);
    defer f.deinit();
    const exact = try f.function("conversion_context_test", "consume");
    const node = try f.function("conversion_context_test", "nodeEnum");
    const web = try f.function("conversion_context_test", "webEnum");
    const node_prose = try f.function("conversion_context_test", "nodeProse");
    try expectEqual(ir.ConversionContext.node_literal, f.scalar((try f.inputConversion(node, 1)).value.input).context);
    try expectEqual(ir.ConversionContext.node_prose_literal, f.scalar((try f.inputConversion(node_prose, 0)).value.input).context);
    try expectEqual(ir.ConversionContext.exact_literal, f.ir.get((try f.inputConversion(exact, 2)).value.input).operation.string.conversion.context);
    try expectEqual(ir.ConversionContext.none, f.scalar((try f.inputConversion(web, 1)).value.input).context);
    try expectEqual(ir.ConversionContext.exact_literal, f.scalar((try f.inputConversion(exact, 1)).value.input).context);
    try expectEqual(ir.ConversionContext.node_literal, f.scalar((try f.inputConversion(node, 2)).value.input).context);
    try expectEqual(ir.ConversionContext.none, f.scalar((try f.inputConversion(node_prose, 1)).value.input).context);
    try expectEqual(ir.ConversionContext.exact_literal, f.ir.get((try f.inputConversion(exact, 4)).value.input).operation.external_ref.context);
    try expectEqual(ir.ConversionContext.node_literal, f.ir.get((try f.inputConversion(node, 3)).value.input).operation.external_ref.context);
    try expectEqual(ir.ConversionContext.none, f.ir.get((try f.inputConversion(web, 2)).value.input).operation.external_ref.context);
    const web_input = f.ir.get((try f.inputConversion(web, 0)).value.input).operation.enumeration;
    const node_input = f.ir.get((try f.inputConversion(node, 0)).value.input).operation.enumeration;
    const exact_input = f.ir.get((try f.inputConversion(exact, 5)).value.input).operation.enumeration;
    const custom_input = f.ir.get((try f.inputConversion(try f.function("conversion_normalization_test", "convert"), 5)).value.input).operation.enumeration;
    try expectEqual(ir.ConversionContext.none, web_input.string.idl.context);
    try expectEqual(ir.ConversionContext.node_literal, node_input.string.idl.context);
    try expectEqual(ir.ConversionContext.exact_literal, exact_input.string.idl.context);
    try expectEqual(ir.CppBuiltin.webidl_dom_string, f.ir.get(web_input.string.idl.type).builtin);
    try expectEqual(ir.CppBuiltin.strict_dom_string, f.ir.get(node_input.string.idl.type).builtin);
    try expectEqual(ir.CppBuiltin.strict_dom_string, f.ir.get(exact_input.string.idl.type).builtin);
    try expectEqualStrings("string", custom_input.string.reject_non_string.value.error_value.node_expected.requirement);
}

test "normalization owns the recursive input conversion program" {
    var f = try testSchema();
    defer f.deinit();
    const options_function = try f.boundFunction(test_schema.echo_test_options);
    const options_argument = options_function.args[0];
    const options_conversion = (try f.inputConversion(options_function, 0)).value;
    const options_program = f.aggregate(options_conversion.input).operation.dictionary;
    try expectEqualStrings("options", options_conversion.path);
    try expect(options_program.object == .exact_object);
    try expect(f.ir.get(options_function.result_position).zig.destruction.wire);
    try expect(f.ir.get(f.ir.functionCpp(options_function).call.entry.frame.?).wire_storage);
    try expectEqual(@as(usize, 5), options_program.fields.len);
    try expect(f.ir.get(options_program.fields[0].value).presence == .required_reject);
    try expect(f.ir.get(options_program.fields[1].value).presence == .optional);
    try expect(f.ir.get(options_program.fields[2].value).presence == .default_value);
    const crossing = f.ir.get(options_argument.position);
    const enabled_default = f.ir.get(options_program.fields[2].value).presence.default_value;
    try expect(enabled_default.operation.boolean);
    try expectEqual(crossing.representation.dictionary[2].value, enabled_default.position);
    const metadata = f.ir.get(options_program.fields[3].value);
    try expectEqualStrings(".metadata", metadata.path.suffix);
    const mode = f.ir.get(f.aggregate(metadata.input).operation.dictionary.fields[0].value);
    try expectEqualStrings(".mode", mode.path.suffix);
    const label_read = options_program.steps[1].value.read.?.operation.property;
    try expectEqualStrings("label", label_read.first);
    try expectEqual(@as(usize, 0), label_read.aliases.len);

    const bundle_function = try f.boundFunction(test_schema.round_trip_test_bundle);
    const bundle_program = f.aggregate((try f.inputConversion(bundle_function, 0)).value.input).operation.dictionary;
    const scalars = f.aggregate(f.ir.get(bundle_program.fields[1].value).input).operation.sequence;
    const scalar = f.aggregate(scalars.value).operation.union_type;
    const lookup = f.aggregate(f.ir.get(bundle_program.fields[2].value).input).operation.record;
    try expectEqual(@as(usize, 3), scalar.members.len);
    try expectEqualStrings(".scalars", f.ir.get(bundle_program.fields[1].value).path.suffix);
    try expectEqualStrings(".lookup", f.ir.get(bundle_program.fields[2].value).path.suffix);
    try expect(f.ir.get(lookup.key).operation == .string);
    try expect(f.aggregate(lookup.value).operation == .union_type);

    const cleanup = f.ir.get(bundle_function.result_position);
    const cleanup_fields = cleanup.representation.dictionary;
    try expect(cleanup.zig.destruction.wire);
    const scalars_result = f.ir.get(cleanup_fields[1].value);
    const lookup_result = f.ir.get(cleanup_fields[2].value);
    const lookup_entry = f.ir.get(lookup_result.representation.record).representation.record_entry;
    try expect(scalars_result.zig.destruction.wire);
    try expect(f.ir.get(scalars_result.representation.sequence).zig.destruction.wire);
    try expect(lookup_result.zig.destruction.wire);
    try expect(f.ir.get(lookup_entry.key).zig.leaf.?.release == .string);
    try expect(f.ir.get(lookup_entry.value).zig.destruction.wire);

    const typed_rest = f.callbackCall(try f.callback(test_schema.typed_rest_callback)).args[1];
    const rest = f.ir.get(typed_rest.rest_position.?.plan());
    try expectEqual(b.TypeKind.sequence, f.at(rest.type).kind());
    try expectEqual(ir.ScalarKind.i32, f.ir.get(rest.representation.sequence).representation.leaf.scalar);
}

test "normalization resolves missing required argument policy" {
    var f: Fixture = try .init(&.{ test_schema.schema, node_path_schema, required_argument_policy_schema }, linux);
    defer f.deinit();
    const node = try f.function("node_path_test", "inspect");
    const add = try f.boundFunction(test_schema.add);
    const arity = try f.function("required_argument_policy_test", "nodeArityError");
    const convert = try f.function("required_argument_policy_test", "exactUndefinedConversion");
    try expect(f.requiredCheck(node) == null);
    try expect(f.requiredCheck(add).?.failure == .arity);
    try expect(f.requiredCheck(arity).?.failure == .arity);
    try expect(f.requiredCheck(convert) == null);
    try expect(!(try f.inputConversion(node, 0)).value.read.argument.unchecked);
    try expect((try f.inputConversion(add, 0)).value.read.argument.unchecked);
    try expect(!(try f.inputConversion(convert, 0)).value.read.argument.unchecked);
}

test "normalization preserves class prototype bases" {
    var f: Fixture = try .init(&.{function_prototype_schema}, linux);
    defer f.deinit();
    const class = try f.class("function_prototype_test", "FunctionPrototypeClass");
    const initialization = f.ir.class_relations[class.id.index].initialization;
    try expect(initialization.prototype == .function);
    try expect(initialization.constructor == null);
}

test "normalization preserves constructor this values" {
    var f: Fixture = try .init(&.{constructor_this_schema}, linux);
    defer f.deinit();
    const constructor = f.ir.get((try f.class("constructor_this_test", "ConstructorThis")).constructor);
    try expect(constructor.this_argument != null);
    try expect(constructor.new_target_argument == null);
}

test "bound declarations reference class contracts" {
    var f: Fixture = try .init(&.{function_prototype_schema}, linux);
    defer f.deinit();
    const class = try f.class("function_prototype_test", "FunctionPrototypeClass");
    const member = f.ir.get(class.declarations[0]);
    const owner = f.ir.get(f.ir.get(member.call_plan.receiver.?).representation.leaf.native_receiver);
    try expectEqualStrings("function_prototype_test", member.module_name);
    try expectEqualStrings("FunctionPrototypeClass", owner.class_name);
    try expect(owner.runtime_plan.ownership == .native_unique);
    try expect(owner.runtime_plan.finalization == .deferred_vm);
    try expectEqual(member, try f.member(class, "value"));
}

test "normalization interns semantic types and resolves function lowering" {
    var f: Fixture = try .init(&.{
        test_schema.schema,
        fallback_union_schema,
        integer_representation_schema,
        conversion_schema,
        enumeration_schema,
        node_path_schema,
        engine_value_schema,
        b.module("integer_projection_test", .{b.function("consume", .{
            b.argument("i8", b.int8, .{}),
            b.argument("u8", b.uint8, .{}),
            b.argument("i16", b.int16, .{}),
            b.argument("u16", b.uint16, .{}),
            b.argument("i32", b.int32, .{}),
            b.argument("u32", b.uint32, .{}),
            b.argument("i64", b.int64, .{}),
            b.argument("u64", b.uint64, .{}),
        }, b.none, .{})}),
    }, linux);
    defer f.deinit();
    const fallback = f.aggregate((try f.inputConversion(try f.function("fallback_union_test", "coerce"), 0)).value.input).operation.union_type;
    try expectEqualStrings("string", fallback.members[1].name);
    try expect(fallback.operation.matching.tests[1] == .always);
    _ = try f.typeId(test_schema.test_scalars);
    const add = try f.boundFunction(test_schema.add);
    try expectEqualStrings("bun_bindgen_dispatch_bindgen_test_add", add.dispatch_symbol);
    try expectEqual(@as(u32, 1), f.requiredCheck(add).?.minimum);
    try expectEqualStrings("uint64_t", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.size)).id.index].result_position.?).wire));
    inline for (.{
        .{ b.int8, ir.ScalarKind.i8, "int8_t" },
        .{ b.uint8, ir.ScalarKind.u8, "uint8_t" },
        .{ b.int16, ir.ScalarKind.i16, "int16_t" },
        .{ b.uint16, ir.ScalarKind.u16, "uint16_t" },
        .{ b.int32, ir.ScalarKind.i32, "int32_t" },
        .{ b.uint32, ir.ScalarKind.u32, "uint32_t" },
        .{ b.int64, ir.ScalarKind.i64, "int64_t" },
        .{ b.uint64, ir.ScalarKind.u64, "uint64_t" },
    }) |entry| {
        const position = f.ir.get(f.ir.argumentPosition(try f.typeId(entry[0])).?);
        try expectEqual(entry[1], position.representation.leaf.scalar);
        try expectEqualStrings(entry[2], try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(entry[0])).id.index].argument_position.?).wire));
        try expectEqualStrings("number", try f.typeScript(entry[0]));
    }
    const bigint = f.resultMaterializer(try f.function("integer_representation_test", "roundTrip"));
    try expect(f.ir.get(bigint).operation.leaf.scalar == .unsigned_bigint);
    try expectEqualStrings("bigint", try f.typeScript(bigint_uint64));
    try expectEqualStrings("uint64_t", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(bigint_uint64)).id.index].result_position.?).wire));
    const uint64_conversion = f.scalarType((try f.inputConversion(try f.boundFunction(test_schema.echo_uint64), 0)).value.input).template;
    try expectEqual(std.math.maxInt(u64), uint64_conversion.arguments[2].integer.unsigned_long);
    const converted_function = try f.function("conversion_normalization_test", "convert");
    try expect(f.scalar((try f.inputConversion(converted_function, 0)).value.input).operation.boolean == .strict_true);
    const clamp = f.scalar((try f.inputConversion(converted_function, 1)).value.input).operation.clamp;
    try expectEqual(@as(i64, -10), clamp.range.min.signed);
    try expectEqual(@as(i64, 10), clamp.range.max.signed);
    const number = f.scalarType((try f.inputConversion(converted_function, 2)).value.input).template;
    try expectEqual(ir.CppTemplate.number_range, number.name);
    try expect(number.arguments[0].boolean and number.arguments[2].boolean);
    try expectEqual(@as(f64, 0), number.arguments[1].double_bits);
    try expectEqual(@as(f64, 1), number.arguments[3].double_bits);
    try expectEqual(ir.NodeNumberRangeError.invalid_value, number.arguments[4].number_range_error);
    const choice_error = f.aggregate((try f.inputConversion(converted_function, 3)).value.input).operation.union_type.operation.matching.error_value.node_expected;
    try expectEqualStrings("number or string", choice_error.requirement);
    try expectEqual(ir.CppNodeExpectedError.type, choice_error.kind);
    const converted_sequence = f.aggregate((try f.inputConversion(converted_function, 4)).value.input).operation.sequence;
    const sequence_error = converted_sequence.validation.?.failure;
    try expect(sequence_error.element.kind == .instance);
    try expectEqualStrings(
        "must be enabled or disabled",
        f.ir.get((try f.inputConversion(converted_function, 5)).value.input).operation.enumeration.unmatched.failure.value.error_value.node_value.reason.?,
    );
    const non_empty_string = f.ir.get((try f.inputConversion(converted_function, 6)).value.input).operation.string;
    try expectEqualStrings("ERR_INVALID_ARG_VALUE", non_empty_string.empty_rejection.?.code);
    try expectEqualStrings("value cannot be empty", non_empty_string.empty_rejection.?.message);

    const test_mode = try f.typeOf(test_schema.test_mode);
    try expectEqualStrings("BindgenTestMode", f.ir.typeScript(test_mode.id));
    for (f.ir.get(test_mode.data.enumeration).enumeration_values) |value| {
        if (std.mem.eql(u8, value.value_name, "safe")) try expectEqual(@as(u16, 2), value.native_value);
    }
    const explicit = f.ir.get((try f.typeOf(explicit_enumeration)).data.enumeration);
    try expectEqual(@as(u16, 0), explicit.enumeration_values[0].native_value);
    try expectEqual(@as(u16, 7), explicit.enumeration_values[1].native_value);
    try expectEqualStrings("ExplicitEnumerationNative", explicit.cpp_name);
    try expectEqualStrings("", f.ir.get((try f.typeOf(empty_enumeration)).data.enumeration).enumeration_values[0].js_value);

    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(test_schema.test_options)).id.index].result_position.?).zig.destruction.wire);

    try expectEqualStrings("const BindStringHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.dom_string)).id.index].argument_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.dom_string)).id.index].argument_position.?).zig.leaf.?.decode == .token_view);
    try expectEqualStrings("BindStringHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.dom_string)).id.index].result_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.dom_string)).id.index].result_position.?).zig.leaf.?.release == .string);

    try expect((try f.typeOf(b.thread_safe_dom_string)).data.dom_string.string_thread_safe);
    try expectEqualStrings("BindStringHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.thread_safe_dom_string)).id.index].result_position.?).wire));

    try expectEqualStrings("BindByteSlice", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.utf8_string)).id.index].result_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.utf8_string)).id.index].result_position.?).zig.leaf.?.release == .bytes);
    try expectEqualStrings("string", try f.typeScript(b.utf8_string));

    try expectEqualStrings("BindConstByteSlice", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.node_path)).id.index].argument_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.node_path)).id.index].argument_position.?).zig.leaf.?.decode == .token_view);
    try expectEqualStrings("string | Uint8Array | URL", try f.typeScript(b.node_path));

    try expect(f.ir.get(f.ir.get((try f.inputConversion(try f.boundFunction(test_schema.echo_any), 0)).value.input).value_type).* == .any);
    try expectEqual(ir.JSValueKind.any, f.ir.get(f.ir.get((try f.boundFunction(test_schema.echo_any)).args[0].position).api).representation.js_value_view);
    try expectEqualStrings("const BindJSValueHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.any)).id.index].argument_position.?).wire));

    try expectEqualStrings("BindEncodedJSValue", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.any)).id.index].result_position.?).wire));
    try expect(!f.ir.get(f.ir.type_plans[(try f.typeOf(b.any)).id.index].result_position.?).zig.destruction.wire);

    try expectEqualStrings("Promise<string>", try f.typeScript(string_promise));
    try expectEqualStrings("const BindJSValueHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(string_promise)).id.index].argument_position.?).wire));
    try expectEqual(ir.JSValueKind.branded, f.ir.get((try f.argumentPosition(string_promise)).?).representation.leaf.js_value_view);
    try expectEqualStrings("BindEncodedJSValue", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(string_promise)).id.index].result_position.?).wire));

    try expectEqual(ir.JSValueKind.engine_value, f.ir.get(f.ir.get(f.ir.argumentPosition(try f.typeId(b.engine_value)).?).api).representation.js_value_view);
    try expectEqualStrings("const BindJSValueHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.engine_value)).id.index].argument_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.engine_value)).id.index].argument_position.?).zig.leaf.?.decode == .scoped_view);

    try expectEqualStrings("BindEncodedJSValue", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.engine_value)).id.index].result_position.?).wire));
    try expect(!f.ir.get(f.ir.type_plans[(try f.typeOf(b.engine_value)).id.index].result_position.?).zig.destruction.wire);
    try expectEqualStrings("unknown", try f.typeScript(b.engine_value));

    const lazy_options_function = try f.boundFunction(test_schema.inspect_lazy_options);
    try expectEqualStrings("BindLazyArgumentHandle*", try f.wireSpelling(f.ir.get(lazy_options_function.args[0].position).wire));
    try expect(f.ir.get(lazy_options_function.args[0].position).zig.leaf.?.decode == .scoped_view);
    try expectEqualStrings("BindgenTestOptions", f.ir.typeScript(f.ir.get(lazy_options_function.args[0].position).type));
    try expectLazyConverter(&f, lazy_options_function, 0);

    const invocation_this = try f.boundFunction(test_schema.invocation_this);
    try expect(invocation_this.this_argument != null);
    try expect(invocation_this.new_target_argument == null);

    const presence = try f.boundFunction(test_schema.classify_presence);
    try expectEqual(@as(u32, 0), (try f.inputConversion(presence, 0)).value.presence.optional.omitted);
    try expectEqual(@as(u32, 2), presence.js_length);
    try expect(f.requiredCheck(presence) == null);

    const rest = try f.boundFunction(test_schema.inspect_rest);
    try expectEqual(@as(u32, 1), f.requiredCheck(rest).?.minimum);
    try expect(rest.args[1].conversion.rest);

    const nullable_string_type = f.at(f.ir.get((try f.boundFunction(test_schema.echo_nullable_string)).args[0].position).type);

    try expectEqual(b.TypeKind.dom_string, f.at(nullable_string_type.data.optional.child).kind());
    try expectEqualStrings("(string) | null", f.ir.typeScript(nullable_string_type.id));
    try expect(f.ir.get(f.ir.type_plans[nullable_string_type.id.index].result_position.?).zig.destruction.wire);

    const optional_native_string = try f.nativeExport("bindgen_test", "optionalNativeString");
    const optional_result = f.at(f.ir.get(optional_native_string.result_position).type);
    try expectEqual(b.EngineRealm.none, optional_native_string.call_plan.realm);
    try expect(f.ir.get(optional_native_string.result_position).zig.destruction.wire);
    try expectEqual(b.TypeKind.optional, optional_result.kind());
    try expectEqual(b.TypeKind.dom_string, f.at(optional_result.data.optional.child).kind());

    const native_string_sequence = try f.nativeExport("bindgen_test", "nativeStringSequenceLength");
    const sequence = f.at(f.ir.get(native_string_sequence.args[0].position).type);
    try expectEqual(b.EngineRealm.current, native_string_sequence.call_plan.realm);
    try expectEqual(b.TypeKind.sequence, sequence.kind());
    try expectEqual(b.TypeKind.dom_string, f.at(sequence.data.sequence.child).kind());
    try expect(f.ir.get(f.ir.get(native_string_sequence.args[0].position).api).representation.sequence == .view);

    const reducer = try f.callback(test_schema.reducer);
    try expectEqualStrings("Reducer", reducer.callback_name);
    try expectEqualStrings("((value: number, label: string) => number)", try f.typeScript(test_schema.reducer));
    try expectEqualStrings("BindRootHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(test_schema.reducer)).id.index].result_position.?).wire));
    const reducer_label = f.ir.get(f.callbackCall(reducer).args[1].position);

    try expectEqualStrings("const BindStringHandle*", try f.wireSpelling(reducer_label.wire));
    try expect(reducer_label.zig.leaf.?.encode == .borrow_wire);
    const rest_callback = try f.callback(test_schema.rest_callback);
    try expect(f.callbackCall(rest_callback).args[1].conversion.rest);
    try expectEqualStrings("((prefix: number, ...values: unknown[]) => number)", try f.typeScript(test_schema.rest_callback));
    const bytes_mapper = try f.callback(test_schema.bytes_mapper);
    try expect(f.ir.get(f.callbackCall(bytes_mapper).args[0].position).representation.leaf == .bytes_operand);

    const domain_error = try f.boundFunction(test_schema.domain_error);
    const error_factories = f.ir.get(f.ir.functionCpp(domain_error).call.entry.callee.wire.result).layout.errors;
    try expectEqual(@as(usize, 4), domain_error.domain_errors.len);
    try expectEqualStrings("rejected", f.ir.get(domain_error.domain_errors[0]).error_name);
    try expectEqualStrings("ERR_BINDGEN_TEST", (try domainErrorFactory(f.ir.domain_error_factories, error_factories[0].factory)).operation.error_object.code.?);
    try expect((try domainErrorFactory(f.ir.domain_error_factories, error_factories[2].factory)).operation == .system_error);
    try expectEqual(try f.typeId(b.system_error_payload), f.ir.get(f.ir.get(domain_error.domain_errors[2]).position).type);
    try expectEqualStrings("runtime_failure", f.ir.get(domain_error.domain_errors[3]).error_name);

    const completion = try f.boundFunction(test_schema.async_result);
    try expect(completion.isAsync());
    try expectEqual(ir.CompletionRetention.strong, f.ir.get(completion.completion.?).retention);
    try expectEqualStrings("binding completion dropped", f.ir.get(completion.completion.?).sender_drop.reject);

    const utf8_completion = try f.boundFunction(test_schema.async_utf8_strings);
    const utf8_result = f.at(f.ir.get(utf8_completion.result_position).type);
    try expect(utf8_completion.isAsync());
    try expectEqual(b.TypeKind.sequence, utf8_result.kind());
    try expectEqual(b.TypeKind.utf8_string, f.at(utf8_result.data.sequence.child).kind());

    const weak_completion = try f.boundFunction(test_schema.async_weak_echo);
    try expect(weak_completion.isAsync());
    try expectEqual(ir.CompletionRetention.weak, f.ir.get(weak_completion.completion.?).retention);

    const pending_completion = try f.boundFunction(test_schema.async_pending_echo);
    try expect(pending_completion.isAsync());
    try expectEqual(ir.CompletionRetention.pending_activity, f.ir.get(pending_completion.completion.?).retention);

    const counter = try f.class("bindgen_test", "Counter");
    try expect(counter.runtime_plan.ownership.isNativeUnique());
    const receiver = f.ir.get((try f.member(counter, "increment")).call_plan.receiver.?);
    try expectEqual(ir.Role.inbound_argument, @TypeOf(receiver.*).plan_role);
    try expectEqual(ir.Representation(.inbound_argument){ .leaf = .{ .native_receiver = counter.id } }, receiver.representation);
    try expectEqualStrings("BindNativeHandle*", try f.wireSpelling(receiver.wire));
    try expect((try f.member(counter, "increment")).call_plan.realm == .current);
    try expect(f.ir.get(counter.constructor).call_plan.receiver == null);
    try expect(!counter.runtime_plan.ownership.canReferenceOffThread());
    try expect(counter.runtime_plan.identity == .fresh_wrapper);
    try expect(counter.runtime_plan.finalization.isDeferredVM());
    try expectEqual(ir.ClassConstructionKind.native_two_phase, counter.runtime_plan.construction.kind);
    try expect(counter.runtime_plan.tracing.reports_any_thread_native_memory);
    try expectEqual(b.MemoryUsageAffinity.any, counter.memory_usage.?.affinity);
    try expect(counter.pending_activity != null);
    try expectEqualStrings("bun_bindgen_class_bindgen_test_Counter_wrapper_created", counter.runtime_plan.construction.wrapper_created.?);
    const prototype_installations = f.ir.class_relations[counter.id.index].properties.prototype.installations;
    const prototype_table = f.ir.class_relations[counter.id.index].properties.prototype.table;
    const constructor_installations = f.ir.class_relations[counter.id.index].properties.constructor.installations;
    try expectEqualStrings((try f.member(counter, "toPrimitive")).host_symbol, (try classProperty(prototype_installations, .{ .symbol = .to_primitive })).value.native.symbol);
    try expectEqualStrings((try f.member(counter, "inspectCustom")).host_symbol, (try classProperty(prototype_installations, .{ .symbol = .inspect_custom })).value.native.symbol);
    try expect(f.ir.get(counter.constructor).new_target_argument != null);
    try expectEqualStrings("bun_bindgen_class_bindgen_test_Counter_constructor", counter.get_constructor_symbol);
    try expectEqualStrings("getValue", (try f.memberKind(counter, "value", .getter)).implementation_name);
    try expectEqualStrings("cached", counter.slots[0].slot_name);
    try expect(counter.slots[0].write != null);
    const hidden_cached = for (counter.slots, 0..) |slot, index| {
        if (std.mem.eql(u8, slot.slot_name, "hiddenCached")) break index;
    } else return error.TestMissingSlot;
    try expect(f.ir.cpp_class_slot_accessors[counter.id.index][hidden_cached] == null);
    try expectEqualStrings("Counter", (try classProperty(prototype_installations, .{ .name = "label" })).value.constant.string);
    const version = try classProperty(constructor_installations, .{ .name = "version" });
    try expectEqual(@as(u64, 1), version.value.constant.unsigned);
    try expect(!version.attributes.read_only);
    try expectEqualStrings((try f.member(counter, "privateIncrement")).host_symbol, (try classProperty(prototype_installations, .{ .private_symbol = "pull" })).value.native.symbol);
    const builtin_member = try f.member(counter, "incrementViaBuiltin");
    try expectEqual(b.Backend.builtin, builtin_member.backend);
    try expectEqualStrings("bindgenTestCounterIncrementCodeGenerator", (try classTableEntry(prototype_table, "incrementViaBuiltin")).value.function.implementation.builtin);
    const builtin_getter = try f.memberKind(counter, "doubledViaBuiltin", .getter);
    try expectEqual(b.Backend.builtin, builtin_getter.backend);
    try expectEqualStrings("bindgenTestCounterDoubledCodeGenerator", (try classTableEntry(prototype_table, "doubledViaBuiltin")).value.accessor.implementation.builtin);

    const builtin_function = try f.boundFunction(test_schema.builtin_add);
    try expectEqual(b.Backend.builtin, builtin_function.backend);
    try expectEqualStrings("bindgenTestBuiltinAddCodeGenerator", f.ir.cpp_function_factories[builtin_function.id.function.index].?.value.builtin);

    const cpp_function = try f.boundFunction(test_schema.cpp_add);
    try expectEqual(b.Backend.cpp, cpp_function.backend);
    const cpp_implementation = f.ir.get(f.ir.functionCpp(cpp_function).call.entry.callee.cpp);
    try expectEqualStrings("BunBindgenCpp_bindgen_test_cppAdd_Arguments", cpp_implementation.arguments);
    try expectEqualStrings("bunBindgenCpp_bindgen_test_cppAdd", cpp_implementation.symbol);

    const get_index = try f.engineShim("bindgen_test", "getIndex");
    try expect(get_index.outbound.call_plan.throws == .js_exception);
    try expectEqual(b.EngineRealm.current, get_index.outbound.call_plan.realm);
    try expect(get_index.outbound.call_plan.requires_scope);
    try expect(f.ir.get(get_index.outbound.result_position).zig.leaf.?.decode == .value_result);
    try expect(f.at(f.ir.get(get_index.outbound.result_position).type).kind() != .optional);
    const get_index_implementation = f.ir.cpp_engine_implementations[get_index.id.index];
    try expectEqualStrings("BunBindgenEngine_bindgen_test_getIndex_Arguments", get_index_implementation.arguments.name);
    try expectEqualStrings("bunBindgenEngine_bindgen_test_getIndex", get_index_implementation.signature.symbol);
    try expectEqualStrings("bun_bindgen_engine_bindgen_test_getIndex", get_index.outbound.entries[0].symbol);

    const cpp_member = try f.member(counter, "incrementViaCpp");
    try expectEqual(b.Backend.cpp, cpp_member.backend);
    try expectEqualStrings("bunBindgenCpp_bindgen_test_Counter_method_incrementViaCpp", f.ir.get(f.ir.functionCpp(cpp_member).call.entry.callee.cpp).symbol);

    const scaled_counter = try f.class("bindgen_test", "ScaledCounter");
    try expectEqualStrings("Counter", f.ir.get(scaled_counter.parent.?).class_name);
    try expectEqualStrings("asCounter", scaled_counter.upcast.?.implementation);
    try expectEqualStrings("bun_bindgen_class_bindgen_test_ScaledCounter_upcast", scaled_counter.upcast.?.symbol);
    try expectEqual(b.MemoryUsageAffinity.vm, scaled_counter.memory_usage.?.affinity);

    const shared_counter = try f.class("bindgen_test", "SharedCounter");
    try expect(shared_counter.runtime_plan.ownership.isNativeShared());
    try expect(shared_counter.runtime_plan.identity == .per_realm_registry);
    try expect(shared_counter.runtime_plan.ownership.canReferenceOffThread());
    try expect(shared_counter.runtime_plan.finalization.isDeferredVM());
    try expectEqualStrings("bun_bindgen_class_bindgen_test_SharedCounter_native_generation", shared_counter.runtime_plan.identity.per_realm_registry);

    const shared_scaled_counter = try f.class("bindgen_test", "SharedScaledCounter");
    try expect(shared_scaled_counter.runtime_plan.ownership.isNativeShared());
    try expectEqualStrings("SharedCounter", f.ir.get(shared_scaled_counter.parent.?).class_name);
    try expectEqualStrings("asSharedCounter", shared_scaled_counter.upcast.?.implementation);

    const clone_box = try f.class("bindgen_test", "CloneBox");
    const clone_plan = f.ir.get(clone_box.structured_clone.?);
    try expectEqual(@as(u8, 249), clone_plan.tag);
    try expectEqual(b.ReferenceThread.any, clone_plan.serialization.bytes);
    try expectEqualStrings("bun_bindgen_class_bindgen_test_CloneBox_structured_clone_serialize", clone_plan.serialize_symbol);
    try expectEqualStrings("bun_bindgen_class_bindgen_test_CloneBox_structured_clone_deserialize", clone_plan.deserialize_symbol);

    const sweep_box = try f.class("bindgen_test", "SweepBox");
    const sweep_call = f.ir.get(sweep_box.constructor_call.?);
    try expect(sweep_box.runtime_plan.finalization.isInlineSweep());
    try expect(sweep_call.exposed);
    try expectEqual(sweep_box.constructor_call.?, f.ir.cpp_class_constructors[sweep_box.id.index].?.call.function);
    try expectEqualStrings("call", sweep_call.implementation_name);
    try expectEqualStrings("bun_bindgen_host_bindgen_test_SweepBox_call", sweep_call.host_symbol);
    try expectEqualStrings("bun_bindgen_dispatch_bindgen_test_SweepBox_call", sweep_call.dispatch_symbol);
    const sweep_shared_box = try f.class("bindgen_test", "SweepSharedBox");
    try expect(sweep_shared_box.runtime_plan.ownership.isNativeShared());
    try expect(sweep_shared_box.runtime_plan.finalization.isDeferredVM());

    try expectEqualStrings("BindNativeHandle*", try f.wireSpelling(f.ir.get(f.ir.get(counter.constructor).result_position).wire));
    try expect(f.ir.get(f.ir.get(counter.constructor).result_position).zig.leaf.?.release == .release_handle);
}

test "native export exposure follows the target" {
    var linux_fixture: Fixture = try .init(&.{native_export_exposure_schema}, linux);
    defer linux_fixture.deinit();
    var windows_fixture: Fixture = try .init(&.{native_export_exposure_schema}, .{ .target = .aarch64_windows });
    defer windows_fixture.deinit();
    try expect(!(try linux_fixture.nativeExport("native_export_exposure_test", "windowsProbe")).exposed);
    try expect((try windows_fixture.nativeExport("native_export_exposure_test", "windowsProbe")).exposed);
}

fn projected(comptime t: b.Type, comptime options: b.FunctionOptions) !Fixture {
    return .init(&.{b.module("projection_test", .{b.function("consume", .{b.argument("value", t, .{})}, b.none, options)})}, linux);
}

test "lease lowering requires the engine byte lease" {
    var f = try projected(b.buffer(.lease), .{});
    defer f.deinit();
    const buffer = f.ir.get((try f.inputConversion(try f.function("projection_test", "consume"), 0)).value.input).operation.buffer;
    try expect(buffer == .lease);

    try expectEqualStrings("const BindByteLeaseHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.buffer(.lease))).id.index].argument_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.buffer(.lease))).id.index].argument_position.?).zig.leaf.?.decode == .scoped_view);

    try expectEqualStrings("BindByteLeaseHandle*", try f.wireSpelling(f.ir.get(f.ir.type_plans[(try f.typeOf(b.buffer(.lease))).id.index].result_position.?).wire));
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(b.buffer(.lease))).id.index].result_position.?).zig.leaf.?.release == .release_handle);
}

test "buffer view checks exclude bare ArrayBuffers" {
    var f = try projected(b.bufferView(.copy), .{ .profile = .node });
    defer f.deinit();
    const buffer = f.ir.get((try f.inputConversion(try f.function("projection_test", "consume"), 0)).value.input).operation.buffer.copy;
    try expectEqualStrings("ArrayBufferView", try f.typeScript(b.bufferView(.copy)));
    try expectEqual(ir.BufferSource.view, buffer.check.source);
}

test "dictionary property presence is part of conversion" {
    const dictionary = comptime b.dictionary("PropertyPresence", .{
        b.dictionaryField("value", b.engine_value, .{ .missing = .absent, .aliases = &.{"fallback"} }),
    });
    var f = try projected(dictionary, .{ .backend = .cpp, .profile = .exact });
    defer f.deinit();
    const program = f.aggregate((try f.inputConversion(try f.function("projection_test", "consume"), 0)).value.input).operation.dictionary;
    const field = f.ir.get(program.fields[0].value);
    const read = program.steps[0].value.read.?.operation.property;
    try expectEqual(ir.DictionaryFieldMissingPlan.absent, field.missing);
    try expect(field.presence == .optional);
    try expectEqualStrings("value", read.first);
    try expectEqualStrings("fallback", read.aliases[0]);
}

test "writable buffer views retain mutable leases" {
    var f = try projected(b.writableBufferView(.lease), .{ .profile = .node });
    defer f.deinit();
    const buffer = f.ir.get((try f.inputConversion(try f.function("projection_test", "consume"), 0)).value.input).operation.buffer.lease;
    try expectEqualStrings("ArrayBufferView", try f.typeScript(b.writableBufferView(.lease)));
    try expect(buffer.writable);
}

test "buffer checks preserve typed-array requirements" {
    var f = try projected(b.uint8Array(.copy), .{});
    defer f.deinit();
    const buffer = f.ir.get((try f.inputConversion(try f.function("projection_test", "consume"), 0)).value.input).operation.buffer.copy;
    try expectEqual(ir.BufferSource.uint8_array, buffer.check.source);
}

test "converted semantics separate physical values from JavaScript matching" {
    var f = try projected(converted_file_mode, .{ .profile = .node });
    defer f.deinit();
    const converted = try f.typeOf(converted_file_mode);
    const argument = (try f.function("projection_test", "consume")).args[0];
    const position = f.ir.get(f.ir.get(argument.position).representation.converted.apiValue());
    try expectEqual(ir.ScalarKind.u32, position.representation.leaf.scalar);
    const conversion = f.ir.get((try f.inputConversion(try f.function("projection_test", "consume"), 0)).value.input).operation.converted;
    try expectEqualStrings("convertFileMode", f.ir.get(conversion.declaration).symbol);
    try expectEqualStrings("uint32_t", try f.wireSpelling(f.ir.get(f.ir.type_plans[f.at(try f.typeId(converted_file_mode)).id.index].argument_position.?).wire));

    try expectEqualStrings("ConvertedFileModeInput", f.ir.typeScript(converted.id));
    try expectEqualStrings("options.mode", conversion.path.?);
}

test "nested aggregates retain cloning and destruction plans" {
    const string_input = comptime b.unionType("NestedProjectionString", .{
        b.unionMember("value", b.dom_string),
        b.unionMember("ignored", b.discarded),
    }, .{ .ordered = true, .fallback_member = "ignored" });
    const number_input = comptime b.unionType("NestedProjectionNumber", .{
        b.unionMember("value", b.double),
        b.unionMember("ignored", b.discarded),
    }, .{ .ordered = true, .fallback_member = "ignored" });
    const options = comptime b.dictionary("NestedProjectionOptions", .{
        b.dictionaryField("continuation_token", b.optionalNullish(string_input), .{ .default_value = .null }),
        b.dictionaryField("delimiter", b.optionalNullish(string_input), .{ .default_value = .null }),
        b.dictionaryField("encoding_type", b.optionalNullish(string_input), .{ .default_value = .null }),
        b.dictionaryField("fetch_owner", b.boolean, .{}),
        b.dictionaryField("max_keys", b.optionalNullish(number_input), .{ .default_value = .null }),
        b.dictionaryField("prefix", b.optionalNullish(string_input), .{ .default_value = .null }),
        b.dictionaryField("start_after", b.optionalNullish(string_input), .{ .default_value = .null }),
    });
    const input = comptime b.unionType("NestedProjectionInput", .{
        b.unionMember("options", options),
        b.unionMember("ignored", b.discarded),
    }, .{ .ordered = true, .fallback_member = "ignored" });
    var f = try projected(input, .{ .profile = .exact });
    defer f.deinit();
    try expect(!f.ir.get(f.ir.type_plans[(try f.typeOf(input)).id.index].argument_position.?).zig.destruction.wire);
    try expect(f.ir.get(f.ir.type_plans[(try f.typeOf(input)).id.index].result_position.?).zig.destruction.wire);
    const position = f.ir.get((try f.function("projection_test", "consume")).args[0].position);
    try expect(position.zig.clone.?.leaf == null);
    try expect(f.ir.get(position.zig.clone.?.target).zig.destruction.wire);
}

test "nominal handles preserve current-thread destruction" {
    const handle = comptime b.nominalHandle("CurrentThreadResource", .{
        .cpp_type = .{ .pointer = &.{ .named = "CurrentThreadResource" } },
        .cpp_declarations = &.{.{ .structure = "CurrentThreadResource" }},
        .ownership = .owned,
        .cpp_release = "releaseCurrentThreadResource",
        .access_thread = .current,
        .destroy_thread = .current,
    });
    var f: Fixture = try .init(&.{b.moduleWithNativeExports("current_thread_resource", .{}, .{
        b.nativeExport("consume", .{b.argument("value", handle, .{ .ownership = .transfer })}, b.none),
    })}, linux);
    defer f.deinit();
    const nominal = (try f.typeOf(handle)).data.nominal_handle;
    try expectEqual(ir.ResourceThread.current, f.ir.get(nominal.ownership.owned).destroy_thread);
}

test "engine result affinity excludes later nominal handle access" {
    const handle = comptime b.nominalHandle("VMAccessResult", .{
        .cpp_type = .{ .pointer = &.{ .named = "VMAccessResult" } },
        .cpp_declarations = &.{.{ .structure = "VMAccessResult" }},
        .access_thread = .vm,
    });
    var f: Fixture = try .init(&.{b.moduleWithEngineShims("vm_access_result", .{}, .{
        b.engineShim("create", .{}, handle, realm_free_any_thread),
    })}, linux);
    defer f.deinit();
    const shim = try f.engineShim("vm_access_result", "create");
    try expect(!shim.outbound.call_plan.requires_scope);
}

test "normalization owns C++ aggregate declaration exposure" {
    var f: Fixture = try .init(&.{cpp_plan_schema}, linux);
    defer f.deinit();
    const separate = try f.definition("CppPlanSeparateDictionary");
    try expectEqual(ir.CppAggregateLocation.public_header, separate.location);
    const separate_result = try f.definition("CppPlanSeparateDictionaryResult");
    try expectEqual(ir.CppAggregateLocation.public_header, separate_result.location);
    try expect(f.ir.get(separate.body.dictionary[0].type).* == .const_span);
    try expect(f.ir.get(separate_result.body.dictionary[0].type).* == .bytes);
    try expect(f.findDefinition("CppPlanResultUnion") == null);
    const result_only = try f.definition("CppPlanResultUnionResult");
    try expectEqual(ir.CppAggregateLocation.public_header, result_only.location);
    try expect(!result_only.body.union_type.visit);
    const wire_argument = try f.definition("CppPlanWireDictionary");
    try expectEqual(ir.CppAggregateLocation.converter_header, wire_argument.location);
    try expect(f.findDefinition("CppPlanWireDictionaryResult") == null);
}

test "lazy conversion protocols are independent of enclosing storage" {
    const reason = "force the value after validating its enclosing request";
    const lazy = comptime b.lazy(archetypes.coerced_dom_string);
    const options = comptime b.dictionary("StoredLazyOptions", .{
        b.dictionaryField("value", lazy, .{ .required = true, .deferred_reason = reason }),
    });
    const values = comptime b.sequenceWithOptions(lazy, .{ .element_deferred_reason = reason });
    var f: Fixture = try .init(&.{b.moduleWithEngineShims("stored_lazy", .{
        b.function("consume", .{ b.argument("options", options, .{}), b.argument("values", values, .{}) }, b.none, .{ .profile = .exact }),
    }, .{
        b.engineShim("force", .{b.argument("value", lazy, .{ .deferred_reason = reason })}, b.size, .{ .realm = .current, .throws = .js_exception, .affinity = .vm, .profile = .exact }),
    })}, linux);
    defer f.deinit();
    const function = try f.function("stored_lazy", "consume");
    const dictionary = f.ir.get(function.args[0].position).representation.dictionary;
    const field = f.ir.get(f.ir.get(dictionary[0].value).api).representation.lazy_field;
    const element = f.ir.get(function.args[1].position).representation.sequence;
    const item = f.ir.get(f.ir.get(element).api).representation.lazy_field;
    const operand = (try f.engineShim("stored_lazy", "force")).outbound.args[0].position;
    try expectEqual(field.protocol, item.protocol);
    try expectEqual(field.protocol, f.ir.get(operand).representation.leaf.lazy_operand.protocol);
    try expectEqual(f.ir.get(operand).api, f.ir.get(field.forward).api);
    try expect(f.ir.get(field.protocol).cpp.lazy_field != null);
    var declared = false;
    for (f.ir.wire_types) |wire_type| if (wire_type.name()) |name| {
        if (name == .lazy_field_convert and std.mem.eql(u8, name.lazy_field_convert, field.symbol)) declared = true;
    };
    try expect(declared);
}

test "C++ argument types distinguish borrowed top-level sequences from stored fields" {
    const items = comptime b.sequence(b.int32);
    const options = comptime b.dictionaryWithOptions("SequenceOptions", .{
        b.dictionaryField("items", items, .{ .required = true }),
    }, .{ .cpp_name = "SequenceOptions" });
    var f: Fixture = try .init(&.{b.moduleWithEngineShims("cpp_sequences", .{}, .{
        b.engineShim("consume", .{ b.argument("items", items, .{}), b.argument("options", options, .{}) }, b.none, .{ .realm = .current, .throws = .js_exception, .affinity = .vm }),
    })}, linux);
    defer f.deinit();
    const shim = try f.engineShim("cpp_sequences", "consume");
    const direct = f.engineArgument(shim, 0);
    const options_position = f.ir.cpp_engine_calls[shim.id.index].entries[0].operation.invoke.callee.native.arguments[1].decoder.position;
    const field = f.decodePlan(f.ir.get(options_position).representation.dictionary[0].value);
    try expect(direct.operation.body.span);
    try expect(!field.operation.body.span);
    const direct_type = f.ir.cpp_engine_implementations[shim.id.index].arguments.fields[0].type;
    const field_type = field.value_type;
    try expectEqual(ir.ScalarKind.i32, f.ir.get(f.ir.get(direct_type).const_span).scalar);
    try expectEqual(ir.ScalarKind.i32, f.ir.get(f.ir.get(field_type).vector).scalar);
    try expectEqual(field_type, (try f.definition("SequenceOptions")).body.dictionary[0].type);
}

test "custom converter aggregate byte fields have owning C++ storage" {
    const bytes = comptime b.dictionaryWithOptions("CustomByteFields", .{
        b.dictionaryField("bytes", b.buffer(.copy), .{ .required = true }),
        b.dictionaryField("path", b.node_path, .{ .required = true }),
    }, .{ .cpp_name = "CustomByteFields" });
    const converted = comptime b.converted(bytes, b.dom_string, b.customConverter("produceByteFields", .{
        .audit_reason = "produces independently owned bytes and paths",
    }), .{});
    var f: Fixture = try .init(&.{b.module("custom_bytes", .{
        b.function("consume", .{b.argument("value", converted, .{})}, b.none, .{ .profile = .exact }),
    })}, linux);
    defer f.deinit();
    const input = f.ir.get((try f.inputConversion(try f.function("custom_bytes", "consume"), 0)).value.input);
    try expectEqualStrings("CustomByteFieldsResult", f.ir.get(input.value_type).named.name);
    const declaration = try f.definition("CustomByteFieldsResult");
    for (declaration.body.dictionary) |field| try expect(f.ir.get(field.type).* == .bytes);
    try expectEqual(ir.CppAggregateLocation.public_header, declaration.location);
    try expectEqual(ir.CppAggregateLocation.public_header, (try f.definition("CustomByteFields")).location);
}

test "normalized plans own C++ storage and rooting decisions" {
    const sequence_type = comptime b.sequence(b.engine_value);
    var f: Fixture = try .init(&.{
        test_schema.schema,
        owned_native_export_schema,
        b.module("engine_sequence", .{
            b.function("accept", .{b.argument("values", sequence_type, .{})}, b.none, .{ .profile = .exact }),
        }),
    }, linux);
    defer f.deinit();
    const echo_any = try f.boundFunction(test_schema.echo_any);
    const any = f.ir.get(echo_any.result_position);
    try expect(any.zig.leaf.?.decode == .value_result);
    try expect(f.ir.get(f.resultMaterializer(echo_any)).operation.leaf.value.read == .encoded);

    try expect((try f.resultPosition(sequence_type)) == null);
    const accept = try f.function("engine_sequence", "accept");
    const sequence = f.ir.get(accept.args[0].position);
    const element = f.aggregate((try f.inputConversion(accept, 0)).value.input).operation.sequence.value;
    try expect(f.ir.get(sequence.api).representation.sequence == .view);
    try expect(f.ir.get(element).rooted);

    const callback = f.ir.get((try f.resultPosition(test_schema.reducer)).?);
    try expect(f.ir.get(callback.api).representation == .callback_owned);
    const echo_callback = try f.function("bindgen_test", "echoCallback");
    try expect(f.ir.get(f.resultMaterializer(echo_callback)).operation.leaf.callback == .root);

    const owned = f.ir.get((try f.resultPosition(owned_native_handle)).?);
    try expect(owned.cpp.release.owned_handles);
    try expect(owned.zig.leaf.?.release == .release_handle);

    try expect((try f.boundFunction(test_schema.echo_dom_string)).destroy_result_symbol != null);
    try expect((try f.boundFunction(test_schema.add)).destroy_result_symbol != null);
    try expect((try f.boundFunction(test_schema.echo_int8)).destroy_result_symbol == null);
    try expect((try f.callbackProgram(try f.callback(test_schema.rest_callback))).entries[0].operation.invoke.callee.callback.capacity == .rest);
    try expect((try f.callbackProgram(try f.callback(test_schema.reducer))).entries[0].operation.invoke.callee.callback.capacity == .fixed);
}

test "input converters own C++ collection storage decisions" {
    var f: Fixture = try .init(&.{cpp_plan_schema}, linux);
    defer f.deinit();
    const dictionary_sequence_id = (try f.inputConversion(try f.function("cpp_plan_test", "dictionarySources"), 0)).value.input;
    const dictionary_sequence = f.ir.get(dictionary_sequence_id);
    const dictionary = f.ir.get(f.aggregate(dictionary_sequence_id).operation.sequence.value);
    try expect(dictionary.collection_storage);
    try expect(dictionary_sequence.collection_storage);

    const converted_sequence = f.aggregate((try f.inputConversion(try f.function("cpp_plan_test", "convertedScalars"), 0)).value.input);
    const converted = f.ir.get(converted_sequence.operation.sequence.value);
    try expect(converted.collection_storage);

    const profiled_sequence = f.aggregate((try f.inputConversion(try f.function("cpp_plan_test", "profiledConvertedDictionaries"), 0)).value.input).operation.sequence;
    const profiled_dictionary = f.aggregate(profiled_sequence.value).operation.dictionary;
    const profiled_field = f.ir.get(f.ir.get(profiled_dictionary.fields[0].value).input).operation.converted;
    try expectEqual(ir.ConversionContext.none, f.scalar(profiled_field.match).context);
    try expectEqual(ir.CppBuiltin.webidl_i32, f.scalarType(profiled_field.match).builtin);
}

test "normalization resolves target and feature exposure from explicit input" {
    var without_feature: Fixture = try .init(&.{exposure_test}, linux);
    defer without_feature.deinit();
    const feature_class = try without_feature.class("exposure_test", "FeatureClass");
    const hidden_class = try without_feature.class("exposure_test", "HiddenConstructorClass");
    const hidden_constructor = without_feature.ir.get(hidden_class.constructor);
    try expect(feature_class.runtime_plan.finalization.isDeferredVM());
    try expect((try without_feature.function("exposure_test", "linuxOnly")).exposed);
    try expect(!(try without_feature.function("exposure_test", "macOnly")).exposed);
    try expect(!(try without_feature.function("exposure_test", "featureOnly")).exposed);
    try expect(!(try without_feature.member(feature_class, "enabledMember")).exposed);
    const feature_typescript = without_feature.ir.class_relations[feature_class.id.index].typescript;
    try expectEqualStrings("enabledMember", feature_typescript.members[0].operation.method.key.name);
    try expect(!hidden_constructor.exposed);
    try expectEqual(@as(usize, 0), without_feature.ir.class_relations[hidden_class.id.index].typescript.declaration.class.len);
    try expect(without_feature.ir.cpp_class_constructors[hidden_class.id.index] == null);

    var with_feature: Fixture = try .init(&.{exposure_test}, .{ .target = .x86_64_linux, .features = &.{"experimental"} });
    defer with_feature.deinit();
    try expect((try with_feature.function("exposure_test", "featureOnly")).exposed);
    try expect((try with_feature.member(try with_feature.class("exposure_test", "FeatureClass"), "enabledMember")).exposed);
}

test "normalization preserves split accessor types" {
    var f: Fixture = try .init(&.{exposure_test}, linux);
    defer f.deinit();
    const class = try f.class("exposure_test", "SplitAccessorClass");
    try expectEqual(b.TypeKind.any, f.at(f.ir.get((try f.memberKind(class, "value", .getter)).result_position).type).kind());
    try expectEqual(b.TypeKind.dom_string, f.at(f.ir.get((try f.memberKind(class, "value", .setter)).args[0].position).type).kind());
    const table = f.ir.class_relations[class.id.index].properties.prototype.table;
    try expectEqual(@as(usize, 1), table.len);
    const getter = table[0].value.accessor;
    try expect(f.ir.functionCpp(try f.memberKind(class, "value", .getter)).call.host.signature == .getter);
    try expect(f.ir.functionCpp(try f.memberKind(class, "value", .setter)).call.host.signature == .setter);
    try expectEqualStrings((try f.memberKind(class, "value", .getter)).host_symbol, getter.implementation.native);
    try expectEqualStrings((try f.memberKind(class, "value", .setter)).host_symbol, getter.setter.?.native);
    try expect(!table[0].attributes.read_only);
}

test "normalization preserves shared getter cache aliases" {
    var f: Fixture = try .init(&.{exposure_test}, linux);
    defer f.deinit();
    const class = try f.class("exposure_test", "CacheAliasClass");
    const canonical = try f.member(class, "canonical");
    const alias = try f.member(class, "alias");
    const canonical_cache = f.ir.functionCpp(canonical).call.entry.cache.?;
    try expectEqualStrings("value", f.ir.get(canonical_cache.owner).slots[canonical_cache.slot].slot_name);
    const alias_cache = f.ir.functionCpp(alias).call.entry.cache.?;
    try expectEqualStrings("value", f.ir.get(alias_cache.owner).slots[alias_cache.slot].slot_name);
    const construction = f.ir.get(f.ir.functionCpp(f.ir.get(class.constructor)).call.entry.output.attach_native.construction);
    try expectEqual(class.id, construction.class);
    try expectEqual(@as(usize, 1), construction.cached_getters.len);
    try expectEqual(canonical.id.function, construction.cached_getters[0]);
    try expectEqualStrings("getAlias", alias.implementation_name);
    const inputs = f.ir.functionCpp(alias).call.entry.inputs;
    try expect(inputs[0] == .check_receiver);
    try expect(inputs[1] == .read_cache);
    try expect(inputs[2] == .borrow_receiver);
    try expect(inputs[3] == .prepare_arguments);
    try expectEqual(inputs[0].check_receiver.class.native, inputs[2].borrow_receiver);
    try expectEqual(class.id, inputs[2].borrow_receiver);
    try expect(f.ir.cpp_class_slot_accessors[class.id.index][0] == null);
    const table = f.ir.class_relations[class.id.index].properties.prototype.table;
    try expectEqual(@as(usize, 2), table.len);
    try expect(table[0].value.accessor.setter == null);
    try expect(table[0].attributes.read_only);
}

test "normalization preserves internal invalidatable getter caches" {
    var f: Fixture = try .init(&.{exposure_test}, linux);
    defer f.deinit();
    const class = try f.class("exposure_test", "InvalidatableCacheClass");
    const cache = f.ir.functionCpp(try f.member(class, "value")).call.entry.cache.?;
    try expectEqualStrings("value", f.ir.get(cache.owner).slots[cache.slot].slot_name);
    try expect(class.slots[0].write != null);
    try expect(f.ir.cpp_class_slot_accessors[class.id.index][0] == null);
}

test "normalization preserves constructor getter caches" {
    var f: Fixture = try .init(&.{exposure_test}, linux);
    defer f.deinit();
    const class = try f.class("exposure_test", "ConstructorCacheClass");
    const value = try f.member(class, "value");
    try expectEqual(b.ClassMemberKind.static_getter, value.class_member.?.member_kind);
    const cache = f.ir.functionCpp(value).call.entry.cache.?;
    try expectEqualStrings("value", f.ir.get(cache.owner).slots[cache.slot].slot_name);
    try expect(class.slots[0].storage == .constructor);
    const constructor = f.ir.cpp_class_constructors[class.id.index].?;
    try std.testing.expectEqualSlices(u32, &.{0}, constructor.slots);
    try expect(constructor.hasTracedState());
    try expect(constructor.builtin == null);
    try expect(constructor.call.host.entry.callee == .reject);
    const table = f.ir.class_relations[class.id.index].properties.constructor.table;
    try expectEqual(@as(usize, 1), table.len);
    try expectEqualStrings("value", table[0].name);
    try expect(table[0].attributes.dom_attribute);
}

test "normalization owns engine class inventories" {
    var f: Fixture = try .init(&.{engine_inventory_schema}, linux);
    defer f.deinit();
    try expectEqual(@as(usize, 1), f.ir.engine_classes.len);
    try expectEqual(@as(usize, 1), f.ir.engine_class_headers.len);
    try expectEqualStrings("InventoryEngine.h", f.ir.engine_class_headers[0]);
    const engine_class = f.ir.get(f.ir.engine_classes[0]);
    try expect(f.ir.class_relations[engine_class.id.index].emission.declaration == .engine_header);
    try expect(engine_class.runtime_plan.ownership == .engine);
    try expect(engine_class.runtime_plan.identity == .engine_wrapper_cache);
    try expect(engine_class.runtime_plan.finalization == .engine);
    try expectEqual(ir.ClassTracingMode.engine_slots, engine_class.runtime_plan.tracing.mode);
    try expectEqual(ir.ClassConstructionKind.engine_intrinsic, engine_class.runtime_plan.construction.kind);
    try expect(f.ir.class_relations[engine_class.id.index].initialization.prototype == .object);
}

test "engine wrapper dispatch lowers derived, global and base cases" {
    inline for (.{ false, true }) |concrete_base| {
        const base = comptime b.class("WrapperBase", b.constructor(.{}, .{ .exposure = .never }), .{}, .{}, .{
            .representation = .engine,
            .engine_intrinsic = "native wrapper selection and wrapper-cache identity",
            .identity = .per_realm,
            .final = false,
            .parent = b.engineParent(.{
                .cpp_class = .{ .named = "Test::JSWrapperBase" },
                .cpp_impl = "Test::WrapperBase",
                .header = "WrapperBase.h",
                .prototype = .object,
                .constructor = .function,
                .cell_kind = .event,
            }),
            .engine_native = .{
                .cpp_type = "Test::WrapperBase",
                .header = "WrapperBase.h",
                .wrapper_discriminator = "wrapperKind",
                .wrapper_tag = if (concrete_base) "Test::WrapperKind::base" else null,
                .wrapper_global_scope = .{ .tag = "Test::WrapperKind::global", .cpp_type = "Test::GlobalScope" },
            },
        });
        const child = comptime b.class("WrapperChild", b.constructor(.{}, .{ .exposure = .never }), .{}, .{}, .{
            .representation = .engine,
            .engine_intrinsic = "native subtype wrapper-cache identity",
            .identity = .per_realm,
            .parent = b.parentClass(base),
            .engine_native = .{ .cpp_type = "Test::WrapperChild", .header = "WrapperChild.h", .wrapper_tag = "Test::WrapperKind::child" },
        });
        var f: Fixture = try .init(&.{b.moduleWithClasses("wrapper_dispatch", .{}, .{ base, child })}, linux);
        defer f.deinit();
        const base_class = try f.class("wrapper_dispatch", "WrapperBase");
        const child_class = try f.class("wrapper_dispatch", "WrapperChild");
        try expect(child_class.upcast == null);
        try expect(child_class.runtime_plan.construction.wrapper_created == null);
        try std.testing.expectEqualSlices(ir.ClassId, &.{ base_class.id, child_class.id }, f.ir.engine_classes);
        const child_engine = child_class.representation.engine;
        try expect(base_class.representation.engine.cell_kind == .event);
        try expect(child_engine.cell_kind == .event);
        try expectEqual(base_class.id, f.ir.get(child_engine.base_type).wrapper_class);
        try expectEqual(base_class.id, f.ir.class_relations[child_class.id.index].initialization.prototype.class);
        const dispatch = f.ir.class_relations[base_class.id.index].engine_wrapper_dispatch.?;
        const tagged = dispatch.operation.tagged;
        try expectEqualStrings("wrapperKind", tagged.discriminator);
        try expectEqual(@as(usize, if (concrete_base) 3 else 2), tagged.cases.len);
        try expectEqualStrings("Test::WrapperKind::child", tagged.cases[0].tag);
        try expectEqual(child_engine.native_type, tagged.cases[0].operation.derived);
        try expectEqualStrings("Test::WrapperKind::global", tagged.cases[1].tag);
        try expectEqualStrings("Test::GlobalScope", f.ir.get(tagged.cases[1].operation.global_scope).named.name);
        if (concrete_base) {
            try expectEqualStrings("Test::WrapperKind::base", tagged.cases[2].tag);
            try expect(tagged.cases[2].operation == .base);
        }
        try expect(f.ir.class_relations[child_class.id.index].engine_wrapper_dispatch.?.operation == .direct);
    }
}

test "native module surfaces normalize independently from binding namespaces" {
    var f: Fixture = try .init(&.{ surface_declarations, surface_owner }, linux);
    defer f.deinit();
    try expectEqual(@as(usize, 1), f.ir.native_module_surfaces.len);
    const surface = f.ir.native_module_surfaces[0];
    try expectEqualStrings("test:native-surface", surface.specifier);
    try expect(surface.default == .declaration);
    try expectEqual(@as(u32, 4), surface.named_export_count);
    try expect(!surface.exports[1].attributes.writable);
    try expect(surface.exports[1].exposed);
    const native_export = try f.nativeExport("surface_declarations", "constructSurfaceProperty");
    try expectEqual(b.NativeThrows.out_of_memory, native_export.call_plan.throws);
    const factory_entry = f.ir.cpp_native_exports[native_export.id.index].?.surface.?;
    try expectEqualStrings(factory_entry.signature.symbol, surface.exports[1].operation.value.native_factory);
    try expectEqualStrings(factory_entry.signature.symbol, f.ir.object_surfaces[1].members[1].initializer.?.value.native_factory);
    try expect(f.ir.get(factory_entry.signature.result).* == .encoded_js_value);
    try expect(factory_entry.signature.context == .global);
    try expect(factory_entry.signature.context.global == .checked_exception);
    try expectEqual(@as(usize, 0), factory_entry.signature.parameters.len);
    const factory = factory_entry.call;
    try expectEqual(factory.callee.wire.result, f.ir.cpp_native_exports[native_export.id.index].?.entry.call.callee.wire.result);
    try expectEqual(factory.callee.wire.result, factory.output.encode_value.wire.result);
    try expectEqual(ir.EngineRealm.current, factory.status.realm);
    try expectEqual(ir.EngineRealm.none, factory.callee.wire.realm);
    try expectEqual(ir.NativeThrows.js_exception, factory.status.throws);
    try expect(factory.output == .encode_value);
    try expectEqual(f.ir.get(native_export.result_position).wire, f.ir.get(factory.output.encode_value.wire.materializer).source.wire.type);
    try expectEqualStrings("defaultValue", f.ir.get(surface.default.declaration.target.function).function_name);
    const nested = f.ir.object_surfaces[0];
    const native_object = f.ir.object_surfaces[1];
    try expectEqual(b.ObjectSurfacePrototype.null, nested.prototype);
    try expectEqual(b.ObjectSurfaceIntegrity.frozen, nested.integrity);
    try expectEqual(@as(usize, 1), nested.typescript_members.len);
    try expect(nested.typescript_members[0].read_only);
    try expect(!native_object.typescript_members[0].read_only);
    try expect(!native_object.typescript_members[1].read_only);
    try expect(native_object.typescript_members[2].read_only);
    try expect(f.ir.object_surface_plans[nested.id.index].used_as_object_value);
    try expect(f.ir.object_surface_plans[native_object.id.index].owned_by_native_modules);
    try std.testing.expectEqualSlices(ir.ObjectSurfaceId, &.{ nested.id, native_object.id }, f.ir.object_surface_plans[nested.id.index].header_roots);
    try std.testing.expectEqualSlices(ir.ObjectSurfaceId, &.{nested.id}, f.ir.typescript_object_surfaces);
    try expectEqual(@as(usize, 1), f.ir.native_module_headers.len);
    try expectEqualStrings("SurfaceDefault.h", f.ir.native_module_headers[0]);
}

test "native module surface conditions normalize against the target" {
    var f: Fixture = try .init(&.{ surface_declarations, surface_owner }, .{ .target = .x86_64_windows });
    defer f.deinit();
    const surface = f.ir.native_module_surfaces[0];
    try expectEqual(@as(u32, 2), surface.named_export_count);
    try expect(!surface.exports[1].exposed);
    try expect(surface.exports[1].typescript_exposed);
    try expect(!surface.exports[2].exposed);
    try expect(surface.exports[2].typescript_exposed);
    const native_export = try f.nativeExport("surface_declarations", "constructSurfaceProperty");
    try expect(f.ir.cpp_native_exports[native_export.id.index].?.surface == null);
    try expect(!f.ir.object_surface_plans[0].used_as_object_value);
    try std.testing.expectEqualSlices(ir.ObjectSurfaceId, &.{.of(0)}, f.ir.object_surface_plans[0].header_roots);
    try std.testing.expectEqualSlices(ir.ObjectSurfaceId, &.{.of(0)}, f.ir.typescript_object_surfaces);
    try expectEqual(@as(usize, 0), f.ir.native_module_headers.len);
}
