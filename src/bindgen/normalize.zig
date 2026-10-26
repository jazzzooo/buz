//! Normalization: lowers every schema declaration into the canonical IR.
//! It is total — every declaration is validated and planned whether or not a
//! consumer uses it — and produces no IR while any schema rule fails.
const mod_positions = @import("normalize/positions.zig");
const mod_wire = @import("normalize/wire.zig");
const mod_cpp_facts = @import("normalize/cpp_facts.zig");
const mod_cpp_codecs = @import("normalize/cpp_codecs.zig");
const mod_intern = @import("normalize/intern.zig");
const mod_surfaces = @import("normalize/surfaces.zig");
const mod_cpp_calls = @import("normalize/cpp_calls.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const structural = @import("structural.zig");
const validate = @import("normalize/validate.zig");
const types = @import("normalize/types.zig");
const plans = @import("normalize/plans.zig");
const plan_parts = @import("normalize/plan_parts.zig");
const callables = @import("normalize/callables.zig");
const classes = @import("normalize/classes.zig");
const manifest = @import("normalize/manifest.zig");

pub const Diagnostic = struct {
    /// The declaration the diagnostic is about, as `Module.declaration` path.
    location: []const u8,
    message: []const u8,
};

pub const Result = union(enum) {
    ir: ir.Ir,
    diagnostics: []const Diagnostic,
};

pub const Error = Allocator.Error || error{SchemaRule};

/// A C++ codec or adapter planning failure: `Unsupported` carries its reason in
/// `Normalizer.cpp_unsupported` until the declaration walk reports it.
pub const PlanError = Allocator.Error || error{Unsupported};

/// A memoized planning result, so a repeated request reports the same reason.
pub fn Planned(comptime T: type) type {
    return union(enum) { planned: T, unsupported: []const u8 };
}

/// A callable exactly as its schema declares it, with class members bound to
/// the class that declares them.
pub const Declared = struct {
    module: u32,
    module_name: []const u8,
    /// The module function name, or a member's wire name.
    function_name: []const u8,
    arguments: schema.Arguments,
    result: schema.Type,
    options: schema.FunctionOptions,
    member: ?Member = null,
    inputs: callables.CallInputs = undefined,
    overload_dispatch: ?callables.OverloadDispatch = null,
    cpp_implementation: ?ir.CppImplementationId = null,

    pub const Member = struct {
        owner: ir.ClassId,
        class_name: []const u8,
        exposure: ir.Exposure,
        representation: ir.ClassRepresentation,
        js_name: []const u8,
        implementation: []const u8,
        raw: *const schema.ClassMember,
    };
};

pub const Normalizer = struct {
    arena: Allocator,
    input: ir.Input,
    modules: []const schema.Module,
    source_stems: []const []const u8,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    /// Callables in function-ID order.
    declared_functions: std.ArrayList(Declared) = .empty,
    declared_overloads: std.ArrayList(Declared) = .empty,
    /// Per module, the first function ID.
    function_module_offsets: []u32 = &.{},
    /// Classes in class-ID order with their module.
    declared_classes: std.ArrayList(DeclaredClass) = .empty,
    class_module_offsets: []u32 = &.{},
    declared_engine_shims: std.ArrayList(DeclaredShim) = .empty,
    engine_shim_module_offsets: []u32 = &.{},
    declared_native_exports: std.ArrayList(DeclaredExport) = .empty,
    native_export_module_offsets: []u32 = &.{},
    declared_object_surfaces: std.ArrayList(*const schema.ObjectSurface) = .empty,
    declared_native_modules: std.ArrayList(DeclaredNativeModule) = .empty,

    raw_types: std.ArrayList(schema.Type) = .empty,
    type_index: structural.Map(schema.Type, u32) = .empty,
    /// Types collected from binding positions, in collection order; types
    /// reached only as metadata follow them.
    binding_type_count: u32 = 0,

    positions: ?*mod_positions.Planner = null,
    wires: ?*mod_wire.Builder = null,
    wire_types: []const ir.WireType = &.{},
    position_converters: std.enums.EnumArray(ir.Role, []const mod_positions.Planner.Converters) = .initFill(&.{}),
    cpp_facts: mod_cpp_facts.Table = .initFill(&.{}),
    types: std.ArrayList(ir.Type) = .empty,
    type_metadata: std.ArrayList(types.Metadata) = .empty,
    enumerations: std.ArrayList(ir.EnumerationType) = .empty,
    nominal_ownerships: std.ArrayList(ir.NominalOwnership) = .empty,
    external_refs: std.ArrayList(ir.ExternalRef) = .empty,
    promise_reactions: std.ArrayList(ir.PromiseReactionContext) = .empty,
    type_projections: []types.Projection = &.{},
    type_plans: []plans.TypePlans = &.{},
    inbound_argument_plans: std.ArrayList(plan_parts.Value(.inbound_argument)) = .empty,
    inbound_result_plans: std.ArrayList(plan_parts.Value(.inbound_result)) = .empty,
    outbound_argument_plans: std.ArrayList(plan_parts.Value(.outbound_argument)) = .empty,
    outbound_result_plans: std.ArrayList(plan_parts.Value(.outbound_result)) = .empty,
    inbound_argument_codecs: []mod_cpp_codecs.Store(.inbound_argument) = &.{},
    inbound_result_codecs: []mod_cpp_codecs.Store(.inbound_result) = &.{},
    outbound_argument_codecs: []mod_cpp_codecs.Store(.outbound_argument) = &.{},
    outbound_result_codecs: []mod_cpp_codecs.Store(.outbound_result) = &.{},
    api_types: structural.OrderedMap(ir.ApiType, void) = .empty,
    cpp_types: structural.OrderedMap(ir.CppType, void) = .empty,
    cpp_brand_matches: structural.OrderedMap(ir.CppBrandMatch, void) = .empty,
    brand_matches_by_name: std.StringHashMapUnmanaged(ir.CppBrandMatchId) = .empty,
    cpp_codec_failures: structural.OrderedMap(ir.CppCodecFailure, void) = .empty,
    cpp_unsupported: []const u8 = "",
    cpp_type_state: mod_cpp_facts.Types.State = .{},
    cpp_predicate_state: mod_cpp_facts.Predicates.State = .{},
    cpp_materializers: mod_cpp_codecs.Materialize.Tables = .{},
    cpp_native_state: mod_cpp_codecs.Native.State = .{},
    cpp_codec_state: mod_cpp_codecs.State = .{},
    cpp_input_state: mod_cpp_codecs.Input.State = .{},
    cpp_declarations: structural.OrderedMap(ir.CppDeclaration, void) = .empty,
    cpp_converter_declarations: structural.OrderedMap(ir.CppConverterDeclaration, void) = .empty,
    cpp_input_aggregate_requests: std.AutoHashMapUnmanaged(mod_cpp_facts.InputAggregateRequest, void) = .empty,
    cpp_result_aggregate_requests: std.AutoHashMapUnmanaged(ir.InboundResultPlanId, void) = .empty,
    cpp_converted_aggregate_requests: std.AutoHashMapUnmanaged(ir.InboundArgumentPlanId, void) = .empty,
    cpp_type_definitions: []const ir.CppTypeDefinition = &.{},
    cpp_input_declarations: std.ArrayList(ir.CppInputAggregateId) = .empty,
    cpp_value_tests: std.ArrayList(ir.CppValueTest) = .empty,
    cpp_dictionary_values: std.ArrayList(ir.CppDictionaryValue) = .empty,
    projection_ready: []bool = &.{},
    input_plans: std.ArrayList(plans.InputPlan) = .empty,
    input_facts: std.ArrayList(plans.InputFacts) = .empty,
    input_conversions: std.ArrayList(schema.ValueConversionOptions) = .empty,
    input_positions: []const ?ir.InboundArgumentPlanId = &.{},
    result_positions: []const ?ir.InboundResultPlanId = &.{},
    input_plan_index: structural.Map(plans.InputPlanKey, u32) = .empty,
    functions: std.ArrayList(ir.Function) = .empty,
    domain_errors: std.ArrayList(ir.DomainError) = .empty,
    domain_error_inputs: std.ArrayList(struct { declaration: schema.DomainErrorDeclaration, factory: u32 }) = .empty,
    domain_error_factory_index: structural.Map(struct { payload: ir.InboundResultPlanId, declaration: schema.DomainErrorDeclaration }, u32) = .empty,
    overload_cases: std.ArrayList(ir.Function) = .empty,
    completions: std.ArrayList(ir.CompletionPlan) = .empty,
    cpp_completion_apis: std.ArrayList(ir.CppCompletionApi) = .empty,
    completion_inputs: std.ArrayList(struct { owner: ir.FunctionIdRef, materializer: ?ir.EngineShimId }) = .empty,
    cpp_completions: std.ArrayList(ir.CppCompletionEncoder) = .empty,
    cpp_completion_index: []?ir.CppCompletionEncoderId = &.{},
    cpp_completion_deliveries: []const ir.CppCompletionDelivery = &.{},
    cpp_class_property_materializers: []const []const ir.CppMaterializerId(.outbound_argument) = &.{},
    cpp_class_slot_accessors: []const []const ?ir.CppCachedSlotAccessors = &.{},
    cpp_engine_calls: []const ir.CppOutboundCall = &.{},
    cpp_callback_calls: []const ?ir.CppOutboundCall = &.{},
    cpp_functions: []const ?ir.CppFunction = &.{},
    cpp_argument_frames: std.ArrayList(ir.CppArgumentFrame) = .empty,
    cpp_wire_results: std.ArrayList(ir.CppWireResult) = .empty,
    cpp_function_factories: []const ?ir.CppFunctionFactory = &.{},
    cpp_realm_functions: std.ArrayList(ir.CppRealmFunction) = .empty,
    realm_functions: std.AutoHashMapUnmanaged(ir.FunctionId, ir.CppRealmFunctionId) = .empty,
    cpp_implementations: std.ArrayList(ir.CppImplementation) = .empty,
    cpp_native_constructions: std.ArrayList(ir.CppNativeConstruction) = .empty,
    cpp_native_construction_index: []?ir.CppNativeConstructionId = &.{},
    cpp_engine_implementations: []const ir.CppEngineImplementation = &.{},
    cpp_overload_cases: []const ?ir.CppFunction = &.{},
    surface_factories: std.AutoHashMapUnmanaged(ir.FunctionId, void) = .empty,
    classes: std.ArrayList(ir.Class) = .empty,
    structured_clones: std.ArrayList(ir.StructuredClonePlan) = .empty,
    class_relations: []const ir.ClassRelations = &.{},
    class_declaration_order: []const ir.ClassId = &.{},
    class_initializers: []const ?ir.ClassInitializers = &.{},
    cpp_class_constructors: []const ?ir.CppClassConstructor = &.{},
    engine_shims: std.ArrayList(ir.EngineShim) = .empty,
    native_exports: std.ArrayList(ir.NativeExport) = .empty,
    cpp_native_exports: []const ?ir.CppNativeExport = &.{},
    domain_error_factories: std.ArrayList(ir.DomainErrorFactory) = .empty,
    cpp_domain_error_factories: std.ArrayList(ir.DomainErrorFactory) = .empty,
    cpp_engine_entries: []const ?ir.CppNativeEntry(.outbound_argument) = &.{},
    engine_native_support: []const bool = &.{},
    native_surface_exports: std.AutoHashMapUnmanaged(ir.NativeExportId, void) = .empty,
    callbacks: std.ArrayList(ir.Callback) = .empty,
    callback_calls: []const ir.OutboundCall = &.{},
    object_surfaces: std.ArrayList(ir.ObjectSurface) = .empty,
    object_surface_plans: []const ir.ObjectSurfacePlan = &.{},
    typescript_object_surfaces: []const ir.ObjectSurfaceId = &.{},
    native_module_headers: []const []const u8 = &.{},
    native_module_surfaces: std.ArrayList(ir.NativeModuleSurface) = .empty,

    pub fn declaration(n: *const Normalizer, id: ir.FunctionIdRef) *Declared {
        return switch (id) {
            .function => |function| &n.declared_functions.items[function.index],
            .overload => |overload| &n.declared_overloads.items[overload.index],
        };
    }

    pub const DeclaredClass = struct {
        module: u32,
        module_name: []const u8,
        class: *const schema.Class,
        value: schema.Type,
        /// Function IDs of the constructor, constructor call, and members.
        constructor: u32,
        constructor_call: ?u32,
        members: []const u32,
    };

    pub const DeclaredShim = struct {
        module_name: []const u8,
        shim: *const schema.EngineShim,
    };

    pub const DeclaredExport = struct {
        module_name: []const u8,
        native_export: *const schema.NativeExport,
    };

    pub const DeclaredNativeModule = struct {
        module: u32,
        native_module: *const schema.NativeModule,
    };

    pub fn fail(n: *Normalizer, location: []const u8, comptime format: []const u8, args: anytype) Error!void {
        try n.diagnostics.append(n.arena, .{
            .location = location,
            .message = try std.fmt.allocPrint(n.arena, format, args),
        });
    }

    /// Records a diagnostic and stops the current declaration.
    pub fn reject(n: *Normalizer, location: []const u8, comptime format: []const u8, args: anytype) Error {
        try n.fail(location, format, args);
        return error.SchemaRule;
    }

    pub fn requireValid(n: *const Normalizer) Error!void {
        if (n.diagnostics.items.len != 0) return error.SchemaRule;
    }

    pub fn unsupported(n: *Normalizer, comptime format: []const u8, args: anytype) PlanError {
        n.cpp_unsupported = try n.print(format, args);
        return error.Unsupported;
    }

    pub fn unsupportedValue(n: *Normalizer, id: anytype, comptime reason: []const u8) PlanError {
        return n.unsupported(reason ++ ": {s}", .{n.projection(n.get(id).type).semantic});
    }

    pub fn record(n: *const Normalizer, result: anytype) Allocator.Error!Planned(@typeInfo(@TypeOf(result)).error_union.payload) {
        return if (result) |value| .{ .planned = value } else |err| switch (err) {
            error.Unsupported => .{ .unsupported = n.cpp_unsupported },
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    pub fn replay(n: *Normalizer, planned: anytype) PlanError!@FieldType(@TypeOf(planned), "planned") {
        return switch (planned) {
            .planned => |value| value,
            .unsupported => |reason| {
                n.cpp_unsupported = reason;
                return error.Unsupported;
            },
        };
    }

    /// A copy whose planning leaves this normalizer untouched: lists, hash maps,
    /// and mutable slices are duplicated, immutable data is shared, and any
    /// other mutable reference is rejected.
    pub fn fork(n: *const Normalizer) Allocator.Error!Normalizer {
        return forked(n.arena, n.*);
    }

    pub fn normalize(n: *Normalizer) Allocator.Error!Result {
        const assembled = run(n) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SchemaRule => return .{ .diagnostics = n.diagnostics.items },
        };
        return .{ .ir = try mod_intern.canonicalize(n.arena, assembled) };
    }

    pub fn print(n: *Normalizer, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(n.arena, format, args);
    }

    pub fn create(n: *Normalizer, value: anytype) Allocator.Error!*const @TypeOf(value) {
        const pointer = try n.arena.create(@TypeOf(value));
        pointer.* = value;
        return pointer;
    }

    pub fn cppType(n: *Normalizer, value: ir.CppType) Allocator.Error!ir.CppTypeId {
        return .of((try n.cpp_types.getOrPut(n.arena, value)).index);
    }

    pub fn moduleIndex(n: *const Normalizer, name: []const u8) ?u32 {
        for (n.modules, 0..) |module, index| {
            if (std.mem.eql(u8, module.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn classId(n: *const Normalizer, name: schema.ClassName) ?u32 {
        const module = n.moduleIndex(name.module) orelse return null;
        for (n.modules[module].classes, 0..) |class, index| {
            if (std.mem.eql(u8, class.name, name.class)) return n.class_module_offsets[module] + @as(u32, @intCast(index));
        }
        return null;
    }

    pub fn functionIdOf(n: *const Normalizer, bound: schema.BoundFunction) ?u32 {
        const module = n.moduleIndex(bound.module) orelse return null;
        for (n.modules[module].functions, 0..) |*function, index| {
            if (function == bound.function) return n.function_module_offsets[module] + @as(u32, @intCast(index));
        }
        return null;
    }

    pub fn classIdOf(n: *const Normalizer, bound: schema.BoundClass) ?u32 {
        const module = n.moduleIndex(bound.module) orelse return null;
        for (n.modules[module].classes, 0..) |*class, index| {
            if (class == bound.class) return n.class_module_offsets[module] + @as(u32, @intCast(index));
        }
        return null;
    }

    pub fn engineShimIdOf(n: *const Normalizer, bound: schema.BoundEngineShim) ?u32 {
        const module = n.moduleIndex(bound.module) orelse return null;
        for (n.modules[module].engine_shims, 0..) |*shim, index| {
            if (shim == bound.shim) return n.engine_shim_module_offsets[module] + @as(u32, @intCast(index));
        }
        return null;
    }

    pub fn nativeExportIdOf(n: *const Normalizer, bound: schema.BoundNativeExport) ?u32 {
        const module = n.moduleIndex(bound.module) orelse return null;
        for (n.modules[module].native_exports, 0..) |*native_export, index| {
            if (native_export == bound.native_export) return n.native_export_module_offsets[module] + @as(u32, @intCast(index));
        }
        return null;
    }

    pub fn typeId(n: *const Normalizer, value: schema.Type) ir.TypeId {
        return .of(n.type_index.get(value) orelse
            std.debug.panic("semantic type is absent from the normalized binding manifest: {t}", .{value}));
    }

    fn Entity(comptime Id: type) type {
        if (@hasDecl(Id, "cpp_field")) return ir.Entity(Id);
        const Table = @FieldType(Normalizer, Id.table);
        if (@hasField(Table, "items")) return std.meta.Elem(@FieldType(Table, "items"));
        return ir.Entity(Id);
    }

    pub fn get(n: *const Normalizer, id: anytype) *const Entity(@TypeOf(id)) {
        if (@hasDecl(@TypeOf(id), "cpp_field")) return &@field(n.cppCodecs(id.position).*, @TypeOf(id).cpp_field).items[id.index];
        const table = @field(n, @TypeOf(id).table);
        const items = if (@hasField(@TypeOf(table), "items")) table.items else table.keys();
        return &items[id.index];
    }

    pub fn addCpp(n: *Normalizer, position: anytype, comptime field: []const u8, value: ir.Entity(ir.CppId(@TypeOf(position).role, field))) Allocator.Error!ir.CppId(@TypeOf(position).role, field) {
        const values = &@field(n.cppCodecs(position).*, field);
        for (values.items, 0..) |existing, index| if (structural.eql(existing, value)) return .{ .position = position, .index = @intCast(index) };
        const id: ir.CppId(@TypeOf(position).role, field) = .{ .position = position, .index = @intCast(values.items.len) };
        try values.append(n.arena, value);
        return id;
    }

    pub fn planList(n: *Normalizer, comptime role: ir.Role) *std.ArrayList(plan_parts.Value(role)) {
        return &@field(n, role.PlanId().table);
    }

    pub fn rolePlans(n: *const Normalizer, comptime role: ir.Role) []const plan_parts.Value(role) {
        return @field(n, role.PlanId().table).items;
    }

    pub fn converters(n: *const Normalizer, id: anytype) mod_positions.Planner.Converters {
        return n.position_converters.get(@TypeOf(id).role)[id.index];
    }

    pub fn cppCodecs(n: *const Normalizer, id: anytype) *mod_cpp_codecs.Store(@TypeOf(id).role) {
        return &n.roleCodecs(@TypeOf(id).role)[id.index];
    }

    pub fn roleCodecs(n: *const Normalizer, comptime role: ir.Role) []mod_cpp_codecs.Store(role) {
        return @field(n, @tagName(role) ++ "_codecs");
    }

    pub fn irType(n: *const Normalizer, id: ir.TypeId) *const ir.Type {
        return &n.types.items[id.index];
    }

    pub fn projection(n: *const Normalizer, id: ir.TypeId) *const types.Projection {
        std.debug.assert(n.projection_ready[id.index]);
        return &n.type_projections[id.index];
    }

    pub fn typePlans(n: *const Normalizer, id: ir.TypeId) *const plans.TypePlans {
        return &n.type_plans[id.index];
    }

    pub fn lazyCallSymbol(n: *Normalizer, deferred: ir.DeferredPosition) Allocator.Error![]const u8 {
        const call = deferred.call;
        const owner: struct { module: []const u8, name: []const u8 } = switch (call.declaration) {
            .function => |function| .{ .module = n.declared_functions.items[function.index].module_name, .name = n.declared_functions.items[function.index].function_name },
            .native_export => |export_| .{ .module = n.declared_native_exports.items[export_.index].module_name, .name = n.rawNativeExport(export_).name },
            .class => |class| .{ .module = n.declared_classes.items[class.index].module_name, .name = n.declared_classes.items[class.index].class.name },
        };
        const overload = if (call.overload_index) |index| try n.print("_case_{d}", .{index}) else "";
        return n.print("{s}_{s}{s}_arg_{d}", .{ owner.module, owner.name, overload, call.argument_index });
    }

    pub fn lazyFieldSymbol(n: *Normalizer, id: ir.InboundArgumentPlanId) Allocator.Error![]const u8 {
        const position = n.get(id).*;
        return n.print("{x:0>16}", .{structural.hash(.{ n.rawType(position.type), n.input_plans.items[position.input.index].profile, n.input_conversions.items[position.input.index] })});
    }

    pub fn rawType(n: *const Normalizer, id: ir.TypeId) schema.Type {
        return n.raw_types.items[id.index];
    }

    pub fn rawEngineShim(n: *const Normalizer, id: ir.EngineShimId) *const schema.EngineShim {
        return n.declared_engine_shims.items[id.index].shim;
    }

    pub fn rawNativeExport(n: *const Normalizer, id: ir.NativeExportId) *const schema.NativeExport {
        return n.declared_native_exports.items[id.index].native_export;
    }

    pub fn builtinGenerator(n: *const Normalizer, id: ir.FunctionId) []const u8 {
        return n.declared_functions.items[id.index].options.builtin.?;
    }

    pub fn isExposed(n: *const Normalizer, exposure: ir.Exposure) bool {
        return switch (exposure) {
            .never => false,
            .always => true,
            .target => |target| std.mem.eql(u8, target, n.input.target.name()),
            .os => |os| std.mem.eql(u8, os, n.input.target.osName()),
            .not_os => |os| !std.mem.eql(u8, os, n.input.target.osName()),
            .feature => |required| for (n.input.features) |enabled| {
                if (std.mem.eql(u8, required, enabled)) break true;
            } else false,
        };
    }
};

fn forked(arena: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    if (T == Allocator) return value;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isList(T)) {
                const list = try value.clone(arena);
                for (list.items) |*item| item.* = try forked(arena, item.*);
                return list;
            }
            if (comptime @hasDecl(T, "Managed") and T == T.Managed.Unmanaged) {
                var map = try value.clone(arena);
                var values = map.valueIterator();
                while (values.next()) |item| item.* = try forked(arena, item.*);
                return map;
            }
            if (comptime @hasDecl(T, "KV") and T == structural.OrderedMap(@FieldType(T.KV, "key"), @FieldType(T.KV, "value"))) {
                const map = try value.clone(arena);
                for (map.values()) |*item| item.* = try forked(arena, item.*);
                return map;
            }
            var copy = value;
            inline for (info.field_names) |name| @field(copy, name) = try forked(arena, @field(value, name));
            return copy;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try forked(arena, payload)),
        },
        .array => {
            var copy = value;
            for (&copy) |*item| item.* = try forked(arena, item.*);
            return copy;
        },
        .optional => return if (value) |payload| try forked(arena, payload) else null,
        .pointer => |pointer| {
            if (pointer.attrs.@"const") return value;
            if (pointer.size == .one) @panic("a normalizer fork cannot share mutable planner state");
            if (pointer.size != .slice) @compileError("normalizer forks cannot copy " ++ @typeName(T));
            const copy = try arena.dupe(pointer.child, value);
            for (copy) |*item| item.* = try forked(arena, item.*);
            return copy;
        },
        .int, .float, .bool, .@"enum", .void => return value,
        else => @compileError("normalizer forks cannot copy " ++ @typeName(T)),
    }
}

fn isList(comptime T: type) bool {
    if (!@hasField(T, "items")) return false;
    const Items = @FieldType(T, "items");
    return @typeInfo(Items) == .pointer and T == std.ArrayList(@typeInfo(Items).pointer.child);
}

pub fn isTypeScriptExposed(exposure: ir.Exposure) bool {
    return exposure != .never;
}

/// Normalizes the schema modules for one target. On any schema rule failure
/// the result carries every diagnostic and no IR.
pub fn normalize(
    arena: Allocator,
    modules: []const schema.Module,
    source_stems: []const []const u8,
    input: ir.Input,
) Allocator.Error!Result {
    var n: Normalizer = .{
        .arena = arena,
        .input = input,
        .modules = modules,
        .source_stems = source_stems,
    };
    return n.normalize();
}

fn run(n: *Normalizer) Error!ir.Ir {
    if (n.source_stems.len != n.modules.len) return n.reject("", "binding schema source stems must align with the schema modules", .{});
    try validate.input(n);
    try enumerateDeclarations(n);
    try validate.schemas(n);
    if (n.diagnostics.items.len != 0) return error.SchemaRule;
    try collectTypes(n);
    var wire_builder = try mod_wire.Builder.init(n);
    try types.normalizeAll(n, &wire_builder);
    if (n.diagnostics.items.len != 0) return error.SchemaRule;
    try wire_builder.planTypes();
    var positions: mod_positions.Planner = .{ .n = n, .wires = &wire_builder };
    n.positions = &positions;
    n.wires = &wire_builder;
    defer {
        n.positions = null;
        n.wires = null;
    }
    try callables.normalizeAll(n);
    try classes.normalizeAll(n);
    if (n.diagnostics.items.len != 0) return error.SchemaRule;
    try manifest.validate(n);
    if (n.diagnostics.items.len != 0) return error.SchemaRule;
    try positions.finish();
    try wire_builder.finish();
    n.wire_types = wire_builder.types.keys();
    n.positions = null;
    n.wires = null;
    try classes.emissionPlans(n);
    try mod_surfaces.normalizeAll(n);
    if (n.diagnostics.items.len != 0) return error.SchemaRule;
    try mod_cpp_facts.planAll(n);
    try validate.normalized(n);
    if (n.diagnostics.items.len != 0) return error.SchemaRule;
    try mod_cpp_codecs.prepare(n);
    try mod_cpp_calls.planAll(n);
    try mod_cpp_codecs.typeDefinitions(n);
    try mod_cpp_codecs.resultEncodingConverters(n);
    return manifest.assemble(n);
}

// ─── declaration enumeration ───

fn enumerateDeclarations(n: *Normalizer) Error!void {
    const module_count = n.modules.len;
    n.function_module_offsets = try n.arena.alloc(u32, module_count);
    n.class_module_offsets = try n.arena.alloc(u32, module_count);
    n.engine_shim_module_offsets = try n.arena.alloc(u32, module_count);
    n.native_export_module_offsets = try n.arena.alloc(u32, module_count);
    var class_offset: u32 = 0;
    for (n.modules, 0..) |*module, module_index_usize| {
        const module_index: u32 = @intCast(module_index_usize);
        n.function_module_offsets[module_index] = @intCast(n.declared_functions.items.len);
        n.class_module_offsets[module_index] = class_offset;
        class_offset += @intCast(module.classes.len);
        n.engine_shim_module_offsets[module_index] = @intCast(n.declared_engine_shims.items.len);
        n.native_export_module_offsets[module_index] = @intCast(n.declared_native_exports.items.len);
        for (module.functions) |function| {
            try n.declared_functions.append(n.arena, .{
                .module = module_index,
                .module_name = module.name,
                .function_name = function.name,
                .arguments = function.arguments,
                .result = function.result,
                .options = function.options,
            });
        }
        for (module.classes, 0..) |*class, class_index| {
            const class_id = n.class_module_offsets[module_index] + @as(u32, @intCast(class_index));
            const constructor: u32 = @intCast(n.declared_functions.items.len);
            try n.declared_functions.append(n.arena, try bindMember(n, module_index, module.name, class, class_id, &class.constructor, false));
            var constructor_call: ?u32 = null;
            if (class.options.constructor_call) |*call| {
                constructor_call = @intCast(n.declared_functions.items.len);
                try n.declared_functions.append(n.arena, try bindMember(n, module_index, module.name, class, class_id, call, true));
            }
            const members = try n.arena.alloc(u32, class.members.len);
            for (class.members, members) |*member, *id| {
                id.* = @intCast(n.declared_functions.items.len);
                try n.declared_functions.append(n.arena, try bindMember(n, module_index, module.name, class, class_id, member, false));
            }
            try n.declared_classes.append(n.arena, .{
                .module = module_index,
                .module_name = module.name,
                .class = class,
                .value = module.class_values[class_index],
                .constructor = constructor,
                .constructor_call = constructor_call,
                .members = members,
            });
        }
        for (module.engine_shims) |*shim| {
            try n.declared_engine_shims.append(n.arena, .{ .module_name = module.name, .shim = shim });
        }
        for (module.native_exports) |*native_export| {
            try n.declared_native_exports.append(n.arena, .{
                .module_name = module.name,
                .native_export = native_export,
            });
        }
    }
    // Object surfaces in manifest order: declared surfaces and the object
    // surfaces native modules re-export, each once.
    for (n.modules, 0..) |module, module_index| {
        for (module.surfaces) |*surface| {
            const candidate: *const schema.ObjectSurface = switch (surface.*) {
                .object => |*object| object,
                .native_module => |*native_module| blk: {
                    try n.declared_native_modules.append(n.arena, .{ .module = @intCast(module_index), .native_module = native_module });
                    break :blk switch (native_module.exports) {
                        .surface => |object| object,
                        .members => continue,
                    };
                },
            };
            const duplicate = for (n.declared_object_surfaces.items) |previous| {
                if (previous == candidate or structural.eql(previous.*, candidate.*)) break true;
            } else false;
            if (!duplicate) try n.declared_object_surfaces.append(n.arena, candidate);
        }
    }
}

fn bindMember(
    n: *Normalizer,
    module_index: u32,
    module_name: []const u8,
    class: *const schema.Class,
    class_id: u32,
    member: *const schema.ClassMember,
    is_constructor_call: bool,
) Error!Declared {
    const options = class.options;
    const member_options = member.options;
    const owner: schema.ClassName = .{ .module = module_name, .class = class.name };
    const implementation = member_options.implementation orelse if (is_constructor_call)
        "call"
    else switch (member.kind) {
        .constructor => "construct",
        else => member.name,
    };
    const wire_name = if (is_constructor_call)
        try n.print("{s}_call", .{class.name})
    else switch (member.kind) {
        .constructor => try n.print("{s}_construct", .{class.name}),
        else => try n.print("{s}_{t}_{s}", .{ class.name, member.kind, member.name }),
    };
    return .{
        .module = module_index,
        .module_name = module_name,
        .function_name = wire_name,
        .arguments = try bindThisArguments(n, member.arguments, owner),
        .result = try bindThisType(n, member.result, owner),
        .options = .{
            .backend = member_options.backend orelse options.backend,
            .builtin = member_options.builtin,
            .length = member_options.length,
            .profile = member_options.profile orelse options.profile,
            .missing_required_arguments = member_options.missing_required_arguments,
            .exposure = member_options.exposure,
            .errors = member_options.errors,
            .completion = member_options.completion,
            .conversion_program = member_options.conversion_program,
            .this_value_type = if (member_options.this_value_type) |t| try bindThisType(n, t, owner) else null,
            .new_target_type = if (member_options.new_target_type) |t| try bindThisType(n, t, owner) else null,
            .callee_value_type = if (member_options.callee_value_type) |t| try bindThisType(n, t, owner) else null,
            .caller_source_location = member_options.caller_source_location,
        },
        .member = .{
            .owner = .of(class_id),
            .class_name = class.name,
            .exposure = options.exposure,
            .representation = options.representation,
            .js_name = member.name,
            .implementation = implementation,
            .raw = member,
        },
    };
}

// ─── this-class reference binding ───

pub fn isThisClassRef(t: schema.Type) bool {
    return t == .class_ref and t.class_ref.target == null;
}

pub fn typeContainsThisClassRef(t: schema.Type) bool {
    if (isThisClassRef(t)) return true;
    return switch (t) {
        .lazy => |child| typeContainsThisClassRef(child.*),
        .optional => |optional| typeContainsThisClassRef(optional.child.*),
        .sequence => |sequence| typeContainsThisClassRef(sequence.child),
        .converted => |converted| typeContainsThisClassRef(converted.native) or typeContainsThisClassRef(converted.match),
        .callback => |callback| argumentsContainThisClassRef(callback.args) or typeContainsThisClassRef(callback.result) or
            (if (callback.options.receiver) |receiver| typeContainsThisClassRef(receiver) else false),
        .dictionary => |dictionary| for (dictionary.fields) |field| {
            if (typeContainsThisClassRef(field.type)) break true;
        } else false,
        .union_type => |union_type| for (union_type.members) |member| {
            if (typeContainsThisClassRef(effectiveUnionMemberType(member))) break true;
        } else false,
        .record => |record| typeContainsThisClassRef(record.key) or typeContainsThisClassRef(record.value),
        else => false,
    };
}

fn argumentsContainThisClassRef(arguments: []const schema.Argument) bool {
    for (arguments) |argument| {
        if (typeContainsThisClassRef(effectiveArgumentType(argument))) return true;
    }
    return false;
}

fn bindThisArguments(n: *Normalizer, arguments: schema.Arguments, owner: schema.ClassName) Error!schema.Arguments {
    switch (arguments) {
        .list => |list| return .{ .list = try bindThisArgumentList(n, list, owner) },
        .overloads => |overloads| {
            const contains = for (overloads.cases) |case| {
                if (argumentsContainThisClassRef(case.args)) break true;
            } else false;
            if (!contains) return arguments;
            const cases = try n.arena.dupe(schema.OverloadCase, overloads.cases);
            for (cases) |*case| {
                case.args = try bindThisArgumentList(n, case.args, owner);
            }
            return .{ .overloads = .{ .cases = cases, .options = overloads.options } };
        },
    }
}

fn bindThisArgumentList(n: *Normalizer, arguments: []const schema.Argument, owner: schema.ClassName) Error![]const schema.Argument {
    if (!argumentsContainThisClassRef(arguments)) return arguments;
    const bound = try n.arena.dupe(schema.Argument, arguments);
    for (bound) |*argument| {
        argument.type = try bindThisType(n, effectiveArgumentType(argument.*), owner);
    }
    return bound;
}

pub fn bindThisType(n: *Normalizer, t: schema.Type, owner: schema.ClassName) Error!schema.Type {
    if (isThisClassRef(t)) {
        var bound = t;
        bound.class_ref.target = owner;
        return bound;
    }
    if (!typeContainsThisClassRef(t)) return t;
    return switch (t) {
        .lazy => |child| .{ .lazy = try n.create(try bindThisType(n, child.*, owner)) },
        .optional => |optional| .{ .optional = .{ .child = try n.create(try bindThisType(n, optional.child.*, owner)), .mode = optional.mode } },
        .callback => |callback| .{ .callback = try n.create(schema.Callback{
            .name = callback.name,
            .args = try bindThisArgumentList(n, callback.args, owner),
            .result = try bindThisType(n, callback.result, owner),
            .options = .{
                .receiver = if (callback.options.receiver) |receiver| try bindThisType(n, receiver, owner) else null,
                .profile = callback.options.profile,
                .no_match_error = callback.options.no_match_error,
                .retains_async_context = callback.options.retains_async_context,
                .schedule_next_tick = callback.options.schedule_next_tick,
            },
        }) },
        .dictionary => |dictionary| blk: {
            const fields = try n.arena.dupe(schema.DictionaryField, dictionary.fields);
            for (fields) |*field| {
                field.type = try bindThisType(n, field.type, owner);
            }
            break :blk .{ .dictionary = try n.create(schema.Dictionary{ .name = dictionary.name, .fields = fields, .options = dictionary.options }) };
        },
        .union_type => |union_type| blk: {
            const members = try n.arena.dupe(schema.UnionMember, union_type.members);
            for (members) |*member| {
                member.type = try bindThisType(n, effectiveUnionMemberType(member.*), owner);
            }
            break :blk .{ .union_type = try n.create(schema.Union{ .name = union_type.name, .members = members, .options = union_type.options }) };
        },
        .sequence => |sequence| .{ .sequence = try n.create(schema.Sequence{ .child = try bindThisType(n, sequence.child, owner), .options = sequence.options }) },
        .record => |record| .{ .record = try n.create(schema.Record{
            .key = try bindThisType(n, record.key, owner),
            .value = try bindThisType(n, record.value, owner),
            .options = record.options,
        }) },
        .converted => |converted| .{ .converted = try n.create(schema.Converted{
            .native = try bindThisType(n, converted.native, owner),
            .match = try bindThisType(n, converted.match, owner),
            .converter = converted.converter,
            .options = converted.options,
        }) },
        else => t,
    };
}

// ─── effective declaration types ───

/// A contextual discard in a rest argument counts the discarded values.
pub fn effectiveArgumentType(argument: schema.Argument) schema.Type {
    if (argument.type == .discarded and argument.type.discarded.purpose == .contextual and argument.options.rest) {
        var effective = argument.type;
        effective.discarded.purpose = .count;
        return effective;
    }
    return argument.type;
}

/// The sequence a typed rest argument collects into.
pub fn argumentRestType(n: *Normalizer, argument: schema.Argument) Allocator.Error!?schema.Type {
    if (!argument.options.rest) return null;
    switch (argument.type) {
        .any, .discarded, .lazy => return null,
        else => return .{ .sequence = try n.create(schema.Sequence{ .child = argument.type, .options = .{} }) },
    }
}

pub fn completionPromiseType(n: *Normalizer, result: schema.Type) Allocator.Error!schema.Type {
    var promise = schema.js_promise.branded_value.*;
    promise.brand.promise_value = try n.create(result);
    return .{ .branded_value = try n.create(promise) };
}

/// A contextual discard in a union member classifies its input.
pub fn effectiveUnionMemberType(member: schema.UnionMember) schema.Type {
    if (member.type == .discarded and member.type.discarded.purpose == .contextual) {
        var effective = member.type;
        effective.discarded.purpose = .classification;
        return effective;
    }
    return member.type;
}

// ─── semantic type collection ───

/// Collects binding-position types before class metadata, interning each tree.
fn collectTypes(n: *Normalizer) Error!void {
    for (n.declared_functions.items) |declared| try collectFunctionTypes(n, declared);
    for (n.declared_engine_shims.items) |declared| try collectShimTypes(n, declared.shim.args, declared.shim.result);
    for (n.declared_native_exports.items) |declared| {
        const native_export = declared.native_export;
        try collectShimTypes(n, native_export.args, native_export.result);
        for (native_export.options.errors.errors) |domain_error| try appendTypeTree(n, domain_error.payload);
    }
    for (n.declared_classes.items) |declared| {
        for (declared.class.slots) |slot| try appendTypeTree(n, slot.type);
        for (declared.class.instance_properties) |property| try appendTypeTree(n, property.options.value);
    }
    for (n.declared_object_surfaces.items) |surface| try collectSurfaceTypes(n, surface.members);
    for (n.declared_native_modules.items) |declared| switch (declared.native_module.exports) {
        .members => |members| try collectSurfaceTypes(n, members),
        .surface => {},
    };
    n.binding_type_count = @intCast(n.raw_types.items.len);
    for (n.declared_classes.items) |declared| try appendTypeTree(n, declared.value);
}

fn collectSurfaceTypes(n: *Normalizer, members: []const schema.SurfaceMember) Error!void {
    for (members) |member| if (member.value == .empty_collection) try appendTypeTree(n, member.value.empty_collection.element);
}

fn collectShimTypes(n: *Normalizer, arguments: []const schema.Argument, result: schema.Type) Error!void {
    for (arguments) |argument| try appendArgumentTypeTree(n, argument);
    try appendTypeTree(n, result);
}

fn collectFunctionTypes(n: *Normalizer, declared: Declared) Error!void {
    const options = declared.options;
    if (declared.member != null and declared.member.?.raw.options.writable) try appendTypeTree(n, schema.none);
    if (options.this_value_type) |t| try appendTypeTree(n, t);
    if (options.new_target_type) |t| try appendTypeTree(n, t);
    if (options.callee_value_type) |t| try appendTypeTree(n, t);
    if (options.type_predicate) |t| try appendTypeTree(n, t);
    switch (declared.arguments) {
        .overloads => |overloads| for (overloads.cases) |case| {
            for (case.args) |argument| try appendArgumentTypeTree(n, argument);
        },
        .list => |list| for (list) |argument| try appendArgumentTypeTree(n, argument),
    }
    try appendTypeTree(n, declared.result);
    if (options.completion) |completion| {
        try appendTypeTree(n, try completionPromiseType(n, declared.result));
        if (completion.materializer) |materializer| try collectShimTypes(n, materializer.shim.args, materializer.shim.result);
    }
    for (options.errors.errors) |domain_error| try appendTypeTree(n, domain_error.payload);
}

pub fn appendArgumentTypeTree(n: *Normalizer, argument: schema.Argument) Error!void {
    try appendTypeTree(n, effectiveArgumentType(argument));
    if (try argumentRestType(n, argument)) |rest_type| try appendTypeTree(n, rest_type);
}

pub fn appendTypeTree(n: *Normalizer, t: schema.Type) Error!void {
    const entry = try n.type_index.getOrPut(n.arena, t);
    if (entry.found_existing) return;
    entry.value_ptr.* = @intCast(n.raw_types.items.len);
    try n.raw_types.append(n.arena, t);
    switch (t) {
        .lazy => |child| try appendTypeTree(n, child.*),
        .optional => |optional| try appendTypeTree(n, optional.child.*),
        .discarded => |discarded| try appendTypeTree(n, discarded.match_type.*),
        .converted => |converted| {
            try appendTypeTree(n, converted.native);
            try appendTypeTree(n, converted.match);
        },
        .branded_value => |branded| if (branded.promise_reaction) |reaction| {
            try appendTypeTree(n, reaction.owner_reference);
        },
        .callback => |callback| {
            if (callback.options.receiver) |receiver| try appendTypeTree(n, receiver);
            for (callback.args) |argument| try appendArgumentTypeTree(n, argument);
            try appendTypeTree(n, callback.result);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try appendTypeTree(n, field.type),
        .union_type => |union_type| {
            if (union_type.options.input_tag) |tag| if (tag.selector) |selector| try appendTypeTree(n, selector);
            for (union_type.members) |member| try appendTypeTree(n, effectiveUnionMemberType(member));
        },
        .sequence => |sequence| try appendTypeTree(n, sequence.child),
        .record => |record| {
            try appendTypeTree(n, record.key);
            try appendTypeTree(n, record.value);
        },
        else => {},
    }
}

pub fn fingerprint(canonical: ir.Ir) u64 {
    var hasher: std.hash.Wyhash = .init(ir.generator_abi_version);
    structural.update(&hasher, canonical);
    return hasher.final();
}
