//! The plain-data binding IR shared by the binding generator and the
//! comptime bind.
const std = @import("std");

pub const vocabulary = @import("vocabulary.zig");

pub const generator_abi_version: u32 = 1;

pub const Target = enum {
    x86_64_linux,
    aarch64_linux,
    x86_64_macos,
    aarch64_macos,
    x86_64_windows,
    aarch64_windows,

    pub fn name(target: Target) []const u8 {
        return switch (target) {
            .x86_64_linux => "x86_64-linux",
            .aarch64_linux => "aarch64-linux",
            .x86_64_macos => "x86_64-macos",
            .aarch64_macos => "aarch64-macos",
            .x86_64_windows => "x86_64-windows",
            .aarch64_windows => "aarch64-windows",
        };
    }

    pub fn osName(target: Target) []const u8 {
        return switch (target) {
            .x86_64_linux, .aarch64_linux => "linux",
            .x86_64_macos, .aarch64_macos => "macos",
            .x86_64_windows, .aarch64_windows => "windows",
        };
    }

    pub fn parse(text: []const u8) ?Target {
        for (std.enums.values(Target)) |target| {
            if (std.mem.eql(u8, text, target.name())) return target;
        }
        return null;
    }
};

pub const Input = struct {
    target: Target,
    features: []const []const u8 = &.{},
};

// ─── vocabulary ───

pub const Backend = vocabulary.Backend;
pub const Profile = vocabulary.Profile;
pub const StringConversion = vocabulary.StringConversion;
pub const BufferMode = vocabulary.BufferMode;
pub const BufferSource = vocabulary.BufferSource;
pub const BufferAccess = vocabulary.BufferAccess;
pub const NativeSliceElement = vocabulary.NativeSliceElement;
pub const BufferResultRepresentation = vocabulary.BufferResultRepresentation;
pub const TypeKind = vocabulary.TypeKind;
pub const IntegerRepresentation = vocabulary.IntegerRepresentation;
pub const AnyPurpose = vocabulary.AnyPurpose;
pub const DiscardedMatch = vocabulary.DiscardedMatch;
pub const NodePathOptions = vocabulary.NodePathOptions;
pub const BufferOptions = vocabulary.BufferOptions;
pub const ResourceThread = vocabulary.ResourceThread;
pub const OptionalMode = vocabulary.OptionalMode;
pub const InternalModuleDefault = vocabulary.InternalModuleDefault;
pub const NodeInvalidEnumerationValue = vocabulary.NodeInvalidEnumerationValue;
pub const DictionaryPropertyLookup = vocabulary.DictionaryPropertyLookup;
pub const NodeSequenceFailure = vocabulary.NodeSequenceFailure;
pub const SequenceLengthLimit = vocabulary.SequenceLengthLimit;
pub const Missing = vocabulary.Missing;
pub const Presence = vocabulary.Presence;
pub const DefaultValue = vocabulary.DefaultValue;
pub const IntegerRange = vocabulary.IntegerRange;
pub const ConversionFailure = vocabulary.ConversionFailure;
pub const IntegerConversion = vocabulary.IntegerConversion;
pub const NodeNumberRangeError = vocabulary.NodeNumberRangeError;
pub const NumberConversion = vocabulary.NumberConversion;
pub const BooleanConversion = vocabulary.BooleanConversion;
pub const ReceiverByteLengthConversion = vocabulary.ReceiverByteLengthConversion;
pub const ArgumentOwnership = vocabulary.ArgumentOwnership;
pub const ArgumentSelection = vocabulary.ArgumentSelection;
pub const ArgumentProjectionSource = vocabulary.ArgumentProjectionSource;
pub const Exposure = vocabulary.Exposure;
pub const ErrorClass = vocabulary.ErrorClass;
pub const ErrorMessage = vocabulary.ErrorMessage;
pub const DOMExceptionName = vocabulary.DOMExceptionName;
pub const CompletionRetention = vocabulary.CompletionRetention;
pub const CompletionDrop = vocabulary.CompletionDrop;
pub const CompletionDelivery = vocabulary.CompletionDelivery;
pub const CompletionSettlement = vocabulary.CompletionSettlement;
pub const ConversionStep = vocabulary.ConversionStep;
pub const EngineRealm = vocabulary.EngineRealm;
pub const NativeThrows = vocabulary.NativeThrows;
pub const ClassRepresentation = vocabulary.ClassRepresentation;
pub const MemoryUsageAffinity = vocabulary.MemoryUsageAffinity;
pub const ClassMemberKind = vocabulary.ClassMemberKind;
pub const PropertySymbol = vocabulary.PropertySymbol;
pub const ClassMemberAliasKey = vocabulary.ClassMemberAliasKey;
pub const StructuredCloneOptions = vocabulary.StructuredCloneOptions;
pub const SurfacePropertyAttributes = vocabulary.SurfacePropertyAttributes;
pub const SurfacePropertyKey = vocabulary.SurfacePropertyKey;
pub const SurfaceMemberAlias = vocabulary.SurfaceMemberAlias;
pub const SurfaceMemberKind = vocabulary.SurfaceMemberKind;
pub const SurfaceConstant = vocabulary.SurfaceConstant;
pub const SurfaceEmptyCollection = vocabulary.SurfaceEmptyCollection;
pub const SurfaceLazyOwner = vocabulary.SurfaceLazyOwner;
pub const SurfaceFunctionVisibility = vocabulary.SurfaceFunctionVisibility;
pub const SurfaceInstallation = vocabulary.SurfaceInstallation;
pub const ObjectSurfacePrototype = vocabulary.ObjectSurfacePrototype;
pub const ObjectSurfaceIntegrity = vocabulary.ObjectSurfaceIntegrity;
pub const NativeModuleDefaultPolicy = vocabulary.NativeModuleDefaultPolicy;
pub const FocusedEngineIntegrationOptions = vocabulary.FocusedEngineIntegrationOptions;
pub const StringCoercionInput = vocabulary.StringCoercionInput;
pub const StringTypeErrorFormat = vocabulary.StringTypeErrorFormat;
pub const BufferTransferPolicy = vocabulary.BufferTransferPolicy;

// ─── plans ───

pub const ScalarKind = enum {
    boolean,
    discarded,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    usize,
    f64,
};

pub const JSValueKind = enum {
    any,
    branded,
    engine_value,
};

pub const StringKind = enum {
    dom_string,
    usv_string,
    byte_string,
};

pub const Role = enum {
    inbound_argument,
    inbound_result,
    outbound_argument,
    outbound_result,

    pub fn Plan(comptime role: Role) type {
        return switch (role) {
            .inbound_argument => InboundArgumentPlan,
            .inbound_result => InboundResultPlan,
            .outbound_argument => OutboundArgumentPlan,
            .outbound_result => OutboundResultPlan,
        };
    }

    pub fn PlanId(comptime role: Role) type {
        return switch (role) {
            .inbound_argument => InboundArgumentPlanId,
            .inbound_result => InboundResultPlanId,
            .outbound_argument => OutboundArgumentPlanId,
            .outbound_result => OutboundResultPlanId,
        };
    }

    pub fn result(comptime role: Role) Role {
        return switch (role) {
            .inbound_argument => .inbound_result,
            .outbound_argument => .outbound_result,
            .inbound_result, .outbound_result => @compileError("a call must have an argument role"),
        };
    }
};

pub const CppAggregateLocation = enum { public_header, converter_header };

pub const CppTypeField = struct { name: []const u8, type: CppTypeId, protects_sources: bool };

pub const CppTypeDefinition = struct {
    name: []const u8,
    location: CppAggregateLocation,
    protects_sources: bool,
    transferred_roots: bool,
    body: union(enum) {
        dictionary: []const CppTypeField,
        union_type: CppUnionDefinition,
    },
};

pub const CppUnionDefinition = struct {
    members: []const CppTypeField,
    visit: bool,
    selector: ?struct { type: CppTypeId, values: []const union(enum) { forward, constant: []const u8 } },
};

pub const DictionaryFieldPresence = enum {
    required_reject,
    required_convert_undefined,
    optional,
    default_value,
};

pub const ClassEmissionPlan = struct {
    has_children: bool,
    declaration: enum { none, bindings_header, engine_header, source },
};

pub const ClassOwnershipPlan = union(enum) {
    none,
    engine,
    native_shared: vocabulary.ReferenceThread,
    native_unique,

    pub fn isNativeShared(plan: ClassOwnershipPlan) bool {
        return std.meta.activeTag(plan) == .native_shared;
    }

    pub fn isNativeUnique(plan: ClassOwnershipPlan) bool {
        return std.meta.activeTag(plan) == .native_unique;
    }

    pub fn canReferenceOffThread(plan: ClassOwnershipPlan) bool {
        return switch (plan) {
            .native_shared => |thread| thread == .any,
            .none, .engine, .native_unique => false,
        };
    }
};

pub const ClassIdentityPlan = union(enum) {
    plain_value,
    fresh_wrapper,
    per_realm_registry: []const u8,
    engine_constructor_only,
    engine_wrapper_cache,
};

pub const ClassFinalizationPlan = union(enum) {
    none,
    engine,
    deferred_vm,
    inline_sweep,

    pub fn isDeferredVM(plan: ClassFinalizationPlan) bool {
        return std.meta.activeTag(plan) == .deferred_vm;
    }

    pub fn isInlineSweep(plan: ClassFinalizationPlan) bool {
        return std.meta.activeTag(plan) == .inline_sweep;
    }
};

pub const ClassTracingMode = enum {
    none,
    native_slots,
    engine_slots,
    engine_slots_and_additional_children,
};

pub const ClassTracingPlan = struct {
    mode: ClassTracingMode,
    reports_any_thread_native_memory: bool,
};

pub const ClassConstructionKind = enum {
    plain_object,
    engine_intrinsic,
    native_two_phase,
};

pub const ClassExternalInitialization = union(enum) {
    none,
    native_subclass: []const u8,
    root_native_subclass: []const u8,
};

pub const ClassConstructionPlan = struct {
    kind: ClassConstructionKind,
    external_initialization: ClassExternalInitialization,
    wrapper_created: ?[]const u8,
};

pub const ClassRuntimePlan = struct {
    ownership: ClassOwnershipPlan,
    identity: ClassIdentityPlan,
    finalization: ClassFinalizationPlan,
    tracing: ClassTracingPlan,
    construction: ClassConstructionPlan,
};

pub const ObjectSurfacePlan = struct {
    owned_by_native_modules: bool,
    used_as_object_value: bool,
    /// Exposed roots whose enable macros require this surface.
    header_roots: []const ObjectSurfaceId,
};

pub const CppSymbolReference = struct {
    symbol: []const u8,
    header: []const u8,
};

pub const CppBrandMatchId = Id("cpp_brand_matches");

pub const CppBrandMatch = union(enum) {
    value: CppSymbolReference,
    realm: CppSymbolReference,
    dynamic_cast: struct {
        type_name: []const u8,
        header: []const u8,
    },
    class_instance: struct {
        class: ClassId,
        match: enum { instance, initial_structure },
    },
};

pub const CppSourceDependency = union(enum) {
    header: []const u8,
    type_predicates,
    brand_match: CppBrandMatchId,
};

pub const PlainInitializerSource = struct {
    argument_name: []const u8,
    field_name: ?[]const u8,
    optional: bool,
};

pub const NativeModuleExportAlias = struct {
    name: []const u8,
    attributes: SurfacePropertyAttributes,
};

pub const CompletionId = Id("completions");

pub const CompletionPlan = struct {
    payload: InboundResultPlanId,
    promise: InboundResultPlanId,
    deliver_symbol: []const u8,
    retention: CompletionRetention,
    sender_drop: CompletionDrop,
    delivery: CompletionDelivery,
    error_delivery: CompletionDelivery,
    settlement: CompletionSettlement,
    cpp_api: ?CppCompletionApiId,
};

pub const StructuredCloneId = Id("structured_clones");

pub const StructuredClonePlan = struct {
    class: ClassId,
    tag: u8,
    serialization: union(enum) { bytes: vocabulary.ReferenceThread, shared: SharedStructuredClonePlan },
    serialize_symbol: []const u8,
    deserialize_symbol: []const u8,
    transferable: bool,
    storable: bool,
    unsupported_context: vocabulary.StructuredCloneUnsupportedContext,
};

pub const SharedStructuredClonePlan = struct {
    state: []const u8,
    handle: WireTypeId,
    release_symbol: []const u8,
};

pub const CppEngineClass = struct {
    native_type: CppTypeId,
    base_type: CppTypeId,
    cell_kind: vocabulary.EngineCellKind,
    estimated_size: bool,
};

pub const DictionaryFieldMissingPlan = enum {
    undefined,
    undefined_or_null,
    absent,
};

pub const DictionaryFieldStoragePlan = enum {
    direct,
    optional,
};

pub const ConversionContext = enum {
    none,
    node_literal,
    node_prose_literal,
    node_predicate_literal,
    exact_literal,
};

pub const OverloadArgumentCount = union(enum) {
    call_frame,
    clamped: usize,
};

// ─── identifiers ───

/// A typed index into one of the IR's entity tables.
pub fn Id(comptime entity: []const u8) type {
    return struct {
        index: u32,

        pub const table = entity;
        pub const role: Role = role: {
            for (std.enums.values(Role)) |candidate| {
                if (std.mem.startsWith(u8, entity, @tagName(candidate) ++ "_")) break :role candidate;
            }
            @compileError("this entity is not a crossing plan");
        };

        pub fn of(index: usize) @This() {
            return .{ .index = @intCast(index) };
        }
    };
}

pub const TypeId = Id("types");
pub const ApiTypeId = Id("api_types");
pub const WireTypeId = Id("wire_types");
pub const CppTypeId = Id("cpp_types");
pub const CppDeclarationId = Id("cpp_declarations");
pub const CppConverterDeclarationId = Id("cpp_converter_declarations");
pub const InboundArgumentPlanId = Id("inbound_argument_plans");
pub const InboundResultPlanId = Id("inbound_result_plans");
pub const OutboundArgumentPlanId = Id("outbound_argument_plans");
pub const OutboundResultPlanId = Id("outbound_result_plans");
pub const CppValueTestId = Id("cpp_value_tests");
pub const FunctionId = Id("functions");
pub const OverloadCaseId = Id("overload_cases");
pub const ClassId = Id("classes");
pub const EngineShimId = Id("engine_shims");
pub const NativeExportId = Id("native_exports");
pub const CallbackId = Id("callbacks");
pub const ModuleId = Id("modules");
pub const ObjectSurfaceId = Id("object_surfaces");

pub const ClassName = struct {
    module: []const u8,
    class: []const u8,
};

pub const WireScalar = enum {
    void,
    int8_t,
    uint8_t,
    int16_t,
    uint16_t,
    int32_t,
    uint32_t,
    int64_t,
    uint64_t,
    size_t,
    double,

    pub fn zigType(comptime scalar: WireScalar) type {
        return switch (scalar) {
            .void => void,
            .int8_t => i8,
            .uint8_t => u8,
            .int16_t => i16,
            .uint16_t => u16,
            .int32_t => i32,
            .uint32_t => u32,
            .int64_t => i64,
            .uint64_t => u64,
            .size_t => usize,
            .double => f64,
        };
    }
};

pub const WireField = struct {
    name: []const u8,
    type: WireTypeId,
};

pub const WireConstant = struct {
    name: []const u8,
    value: u64,
};

pub const WireAdapterInput = struct {
    field: []const u8,
    parameter: u32,
    operation: union(enum) { copy, boolean, nonnull_pointer: WireTypeId, slice: u32 },
};

pub const WireAdapter = struct {
    callee: WireTypeId,
    call_id: WireTypeId,
    context: WireTypeId,
    arguments: WireTypeId,
    result: WireTypeId,
    status: WireTypeId,
    result_field: ?[]const u8,
    inputs: []const WireAdapterInput,
};

pub const WireName = union(enum) {
    identifier: []const u8,
    lazy_result: []const u8,
    lazy_convert: []const u8,
    lazy_discard: []const u8,
    lazy_field_convert: []const u8,
    lazy_field_discard: []const u8,

    pub fn format(name: WireName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (name) {
            .identifier => |text| try writer.writeAll(text),
            inline else => |name_, tag| try writer.print(@field(symbol_formats, @tagName(tag)), .{name_}),
        }
    }

    pub fn alloc(name: WireName, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{f}", .{name});
    }

    pub fn comptimeName(comptime name: WireName) []const u8 {
        return switch (name) {
            .identifier => |text| text,
            inline else => |name_, tag| std.fmt.comptimePrint(@field(symbol_formats, @tagName(tag)), .{name_}),
        };
    }
};

pub const WirePointer = struct { child: WireTypeId, is_const: bool };
pub const WireAlias = struct { name: WireName, child: WireTypeId, constants: []const WireConstant };
pub const WireAggregate = struct { name: WireName, fields: []const WireField };
pub const WireFunctionPointer = struct { name: WireName, result: WireTypeId, parameters: []const WireTypeId };
pub const WireFunction = struct {
    name: WireName,
    result: WireTypeId,
    parameters: []const WireField,
    non_returning: bool,
    body: union(enum) { declaration, adapter: WireAdapter },
};

pub const WireType = union(enum) {
    scalar: WireScalar,
    pointer: WirePointer,
    opaque_handle: WireName,
    forward_structure: WireName,
    alias: WireAlias,
    structure: WireAggregate,
    @"union": WireAggregate,
    function_pointer: WireFunctionPointer,
    function: WireFunction,

    pub fn name(wire: WireType) ?WireName {
        return switch (wire) {
            .scalar, .pointer => null,
            .opaque_handle, .forward_structure => |value| value,
            inline .alias, .structure, .@"union", .function_pointer, .function => |value| value.name,
        };
    }
};

pub fn PositionField(comptime role: Role) type {
    return struct {
        name: []const u8,
        value: role.PlanId(),
        optional: bool,
        dictionary_source: bool = false,
    };
}

pub const CppBuiltin = enum { strict_boolean, unrestricted_double, strict_double, to_length, integer_or_infinity, webidl_i8, webidl_u8, webidl_i16, webidl_u16, webidl_i32, webidl_u32, webidl_i64, webidl_u64, webidl_dom_string, webidl_usv_string, webidl_byte_string, strict_dom_string, strict_usv_string, strict_byte_string };
pub const CppTemplate = enum { strict_boolean, node_property_boolean, number_integer_range, coerced_integer_default, modulo_integer, strict_integer, number_or_bigint_range, bigint_integer, bigint_range, number_integer, loose_integer, coerced_saturated_integer, saturated_integer, truncated_integer_clamp, saturated_integer_range, bounded_integer, integer_enforce_range, webidl_clamp, node_integer_diagnostic, matching_integer, clamped_number, number_enforce_range, normalized_integer, truncated_clamped_number, wrapped_clamped_number, number_range };
pub const CppTemplateArgument = union(enum) {
    type: CppTypeId,
    wire: WireTypeId,
    boolean: bool,
    integer: CppIntegerLiteral,
    double_bits: f64,
    string: []const u8,
    error_code: []const u8,
    integer_rejection: @FieldType(vocabulary.NodeIntegerValidation, "rejection"),
    number_range_error: vocabulary.NodeNumberRangeError,
};

pub const CppScalarConversion = struct {
    context: ConversionContext,
    failure: CppInputFailure,
    operation: union(enum) {
        boolean: enum { webidl, truthy, strict_true, not_strict_false },
        idl: CppTypeId,
        clamp: struct { idl: CppTypeId, wire: WireTypeId, range: CppIntegerRange },
        receiver_byte_length: ReceiverByteLengthConversion,
    },
};

pub const CppHandle = struct { wire: WireTypeId, const_pointee: bool };

pub const CppInputEncodeId = CppId(.inbound_argument, "input_encoders");

pub const CppInputEncode = struct {
    failure: CppInputFailure,
    operation: union(enum) {
        void,
        native: CppNativeEncodeId(.inbound_argument),
        helper,
        rest,
        byte_lease,
        value: JSValueKind,
        callback,
        class_ref,
        optional: CppInputEncodeId,
        entry: struct { key: CppNativeEncodeId(.inbound_argument), value: CppInputEncodeId },
        dictionary: []const struct {
            name: []const u8,
            operation: union(enum) { source, value: struct { encoder: CppInputEncodeId, optional: bool } },
        },
        union_type: []const struct { name: []const u8, encoder: CppInputEncodeId, tag: u16 },
        collection: struct {
            wire: WireTypeId,
            element: union(enum) { native: CppNativeEncodeId(.inbound_argument), sequence: CppInputEncodeId, record: CppInputEncodeId },
        },
    },
};

pub fn CppId(comptime role_: Role, comptime field: []const u8) type {
    return struct {
        position: role_.PlanId(),
        index: u32,

        pub const role = role_;
        pub const cpp_field = field;
    };
}

pub const CppInputId = CppId(.inbound_argument, "inputs");
pub const CppInputAggregateId = CppId(.inbound_argument, "input_aggregates");

pub const CppLazyInput = struct { value: CppInputId, protocol: InboundArgumentPlanId };
pub const CppRestPath = union(enum) { value: []const u8, element: struct { name: []const u8, conversion: CppStringInput } };
pub const CppLazyConversion = struct {
    index: u32,
    position: InboundArgumentPlanId,
    symbol: []const u8,
    conversion: CppLazyInput,
    result_wire: WireTypeId,
    path: CppRestPath,
    prepared_input: bool,
    rest: bool,
    discard: bool,
};
pub const CppLazyField = struct { input: CppInputId, symbol: []const u8 };
pub const CppLazyStorage = struct {
    symbol: []const u8,
    converters: []const CppLazyConversion,
    receiver: bool,
};
pub const CppPropertyLookup = struct {
    method: enum { get, get_if_exists, skip_object_prototype },
    first: []const u8,
    aliases: []const []const u8,
    missing: DictionaryFieldMissingPlan,
};
pub const CppPropertyRead = struct {
    failure: CppInputFailure,
    operation: union(enum) { private_symbol: []const u8, property: CppPropertyLookup },
};
pub const CppRequiredInput = struct { missing: DictionaryFieldMissingPlan, error_value: CppValueInputError, failure: CppInputFailure };
pub const CppDeferredInput = struct {
    conversion: CppLazyInput,
    source: union(enum) { value, property: CppPropertyRead, projected: []const u8, element },
    required: ?CppRequiredInput,
    prefetch: bool,
};
pub const CppFieldPath = union(enum) { absolute: []const u8, suffix: []const u8 };
pub const CppDictionaryValueId = Id("cpp_dictionary_values");
pub const CppDictionaryValue = struct {
    name: []const u8,
    input: CppInputId,
    path: CppFieldPath,
    missing: DictionaryFieldMissingPlan,
    presence: union(enum) { required_reject: CppRequiredInput, required_convert_undefined, default_value: CppDefaultValue(.inbound_argument), optional },
    tracks_lease_presence: bool,
    incompatible: ?struct { other: CppDictionaryValueId, primary: []const u8, current: []const u8 },
    unsupported: ?[]const u8,
};
pub const CppInputField = union(enum) { source: []const u8, value: CppDictionaryValueId };
pub const CppInputFailure = enum { empty, false_value, status };
pub const CppInputPreparation = struct {
    failure: CppInputFailure,
    operation: union(enum) {
        object_or_string,
        buffer: CppBufferCheck,
    },
};
pub const CppDictionaryFieldValue = union(enum) {
    convert: struct { input: CppInputId, optional: bool },
    prepare: CppInputPreparation,
};
pub const CppDictionaryInput = struct {
    path: ?[]const u8,
    object: union(enum) { webidl_nullable, exact_object, node_object: struct { reject_array: bool, reject_callable: bool } },
    object_error: CppValueInputError,
    snapshot: bool,
    fields: []const CppInputField,
    steps: []const union(enum) {
        read: struct { field: CppDictionaryValueId, reader: CppPropertyRead },
        source: []const u8,
        validate_string: struct { field: CppDictionaryValueId, error_value: CppValueInputError },
        lazy: struct { field: CppDictionaryValueId, input: CppDeferredInput },
        value: CppDictionaryValueStep,
    },
};
pub const CppDictionaryValueStep = struct { field: CppDictionaryValueId, read: ?CppPropertyRead, retain: bool, operation: CppDictionaryFieldValue };
pub const CppBufferCheck = struct {
    source: BufferSource,
    allow_detached: bool,
    allow_shared: bool,
    detached_failure: ?ConversionFailure,
    invalid: CppValueInputError,
};
pub const CppBufferCopy = struct { check: CppBufferCheck, failure: CppInputFailure };
pub const CppBufferLease = struct {
    check: CppBufferCheck,
    failure: CppInputFailure,
    writable: bool,
    allow_copy: bool,
    require_source_attachment: bool,
    copy_transfers: bool,
    snapshot_resizable: bool,
    copy_required: CppValueInputError,
    attachment_unavailable: CppValueInputError,
};
pub const CppBufferInput = union(enum) { copy: CppBufferCopy, lease: CppBufferLease };
pub const CppIdlInput = struct { type: CppTypeId, context: ConversionContext, failure: CppInputFailure };
pub const CppStringInput = struct {
    conversion: CppIdlInput,
    thread_safe: bool,
    nullish_failure: ?ConversionFailure,
    strict_failure: ?ConversionFailure,
    empty_rejection: ?vocabulary.StringEmptyRejection,
    input: union(enum) { any, object: CppValueInputError, string_or_boxed: CppValueInputError },
};
pub const CppInputErrorMessage = union(enum) { literal: []const u8, suffix: []const u8 };
pub const CppNodeExpectedError = enum { type, multiple_types, instance, range };
pub const CppValueInputError = union(enum) {
    custom: ConversionFailure,
    node_port,
    node_property_value: []const u8,
    node_type_or_instance: struct { expected_type: []const u8, expected_instances: []const u8 },
    node_string_property_type,
    webidl_integer_array,
    invalid_this: []const u8,
    node_invalid_this: []const u8,
    node_expected: struct {
        kind: CppNodeExpectedError,
        requirement: []const u8,
        source_suffix: ?[]const u8 = null,
    },
    node_value: struct { source_suffix: ?[]const u8 = null, reason: ?[]const u8 = null },
    javascript: struct { kind: enum { type, range }, message: CppInputErrorMessage },
};
pub const CppBrandedInput = struct { brand: CppBrandMatchId, failure: CppValueInputError };
pub const CppCallbackInput = struct { captures_context: bool, failure: CppValueInputError };
pub const CppClassInput = struct { reference: CppClassReference, failure: CppValueInputError };
pub const CppEnumerationFailure = union(enum) {
    prefix: ConversionFailure,
    value: struct { name: ?[]const u8 = null, error_value: CppValueInputError },
    node_coerced: struct {
        code: []const u8,
        prefix: []const u8,
        suffix: []const u8,
        non_string_error: ?CppValueInputError,
        text: enum { input, converted },
    },
};
pub const CppEnumerationUnmatched = union(enum) { value: u16, failure: CppEnumerationFailure };
pub const CppEnumerationInput = struct {
    type: CppTypeId,
    failure: CppInputFailure,
    values: []const struct { tag: u16, text: []const u8, aliases: []const []const u8 },
    ascii_case_insensitive: bool,
    numbers: ?CppEnumerationUnmatched,
    string: union(enum) { idl: CppIdlInput, coerced, reject_non_string: CppEnumerationFailure },
    unmatched: CppEnumerationUnmatched,
};
pub const CppRecordInput = struct {
    key: CppInputId,
    value: CppInputId,
    key_conversion: StringKind,
    object: enum { nullable, required },
    object_error: CppValueInputError,
};
pub const CppInputUnionMember = struct { name: []const u8, value: CppInputId, tag: u16 };
pub const CppUnionInput = struct {
    members: []const CppInputUnionMember,
    fallback: ?u32,
    operation: union(enum) {
        matching: struct { tests: []const CppValueTest, error_value: CppValueInputError },
        tagged: CppTaggedUnionInput,
    },
};
pub const CppTaggedUnionInput = struct {
    property: []const u8,
    tag_read: union(enum) { coerced: CppValueInputError, strict: CppValueInputError },
    object: union(enum) { shorthand, required: CppValueInputError },
    case_insensitive: bool,
    payload: union(enum) { object, property: []const u8 },
    cases: []const struct {
        member: u32,
        value: []const u8,
        aliases: []const []const u8,
        shorthand: union(enum) { none, object, field: CppDictionaryValueId },
    },
    unmatched: union(enum) { failure, raise: CppValueInputError },
};
pub const CppSequenceValidation = struct {
    selection: CppValueTest,
    failure: union(enum) { sequence: CppValueInputError, element: struct { kind: enum { type, instance }, expected: []const u8 } },
    failure_return: CppInputFailure,
};
pub const CppSequenceRead = struct { method: enum { property, direct_index }, failure: CppInputFailure };
pub const CppIndexedSequenceInput = struct {
    selection: CppValueTest,
    object_error: CppValueInputError,
    length_limit: ?SequenceLengthLimit,
    pattern: ?struct { member_tags: []const u16, incomplete_error: ConversionFailure },
    read: union(enum) {
        interleaved: CppSequenceRead,
        snapshot: CppSequenceRead,
        grouped: struct { sizes: []const u16, offsets: []const u16 },
        lazy: CppDeferredInput,
    },
};
pub const CppSequenceInput = struct {
    value: CppInputId,
    validation: ?CppSequenceValidation,
    too_long: CppValueInputError,
    operation: union(enum) {
        iterable: struct { snapshot: bool, object_error: ?CppValueInputError },
        indexed: CppIndexedSequenceInput,
    },
};

pub const CppInputAggregate = struct {
    wire: WireTypeId,
    value_type: CppTypeId,
    failure: CppInputFailure,
    encoder: CppInputEncodeId,
    result_encoder: ?CppResultEncoderId(.inbound_argument),
    receiver: bool,
    holds_byte_lease: bool,
    operation: union(enum) {
        dictionary: CppDictionaryInput,
        union_type: CppUnionInput,
        sequence: CppSequenceInput,
        record: CppRecordInput,
    },
};

pub const CppInput = struct {
    value_type: CppTypeId,
    failure: CppInputFailure,
    encoder: CppInputEncodeId,
    rooted: bool,
    call_receiver: bool,
    holds_byte_lease: bool,
    /// Element views can point into conversion state whose address must stay stable.
    collection_storage: bool,
    operation: union(enum) {
        void,
        discarded,
        scalar: CppScalarConversion,
        converted: struct { match: CppInputId, declaration: CppConverterDeclarationId, path: ?[]const u8 },
        optional: struct { value: CppInputId, presence: CppValueTest, tracks_lease_presence: bool },
        enumeration: CppEnumerationInput,
        string: CppStringInput,
        node_path: NodePathOptions,
        external_ref: CppIdlInput,
        value: JSValueKind,
        branded_value: CppBrandedInput,
        callback: CppCallbackInput,
        class_ref: CppClassInput,
        buffer: CppBufferInput,
        aggregate: CppInputAggregateId,
        lazy: CppDeferredInput,
    },
};

pub const CppJavaScriptDecodeId = CppId(.outbound_result, "javascript_decoders");

pub const CppJavaScriptDecode = struct {
    failure: CppInputFailure,
    operation: union(enum) {
        void,
        scalar: CppScalarConversion,
        value,
        branded: CppBrandedInput,
        callback: CppCallbackInput,
        string: CppStringInput,
        bytes: CppBufferCheck,
        aggregate: CppInputAggregateId,
        optional: struct { value: CppJavaScriptDecodeId, presence: CppValueTest },
    },
};

pub const CppType = union(enum) {
    builtin: CppBuiltin,
    template: struct { name: CppTemplate, arguments: []const CppTemplateArgument },
    conversion_failure: ConversionFailure,
    void,
    int,
    scalar: ScalarKind,
    any,
    js_value,
    encoded_js_value,
    js_object,
    size,
    monostate,
    any_sequence,
    wire: WireTypeId,
    wrapper_class: ClassId,
    string,
    bytes,
    scoped_bytes: BufferAccess,
    named: struct { name: []const u8, namespace: enum { global, binding, engine } },
    external_implementation: CppTypeId,
    native_class: ClassId,
    pointer: CppTypeId,
    const_pointer: CppTypeId,
    const_reference: CppTypeId,
    const_span: CppTypeId,
    span: CppTypeId,
    optional: CppTypeId,
    allocation_result: CppTypeId,
    vector: CppTypeId,
    lazy_argument: CppTypeId,
    result_sequence: CppTypeId,
    pair: struct { key: CppTypeId, value: CppTypeId },
    function_pointer: struct { result: CppTypeId, parameters: []const CppTypeId, convention: enum { c, host } },
    specialization: struct { name: []const u8, arguments: []const CppTypeId },
};

pub const CppConverterDeclaration = struct {
    symbol: []const u8,
    input: CppTypeId,
    result: CppTypeId,
    realm_free: bool,
    body: union(enum) {
        external,
        brand_cast: struct {
            brand: CppBrandMatchId,
            value: enum { javascript, opaque_value },
            mismatch: enum { absent, assert },
        },
    },
};

pub const CppDeclaration = union(enum) {
    structure: []const u8,
    class: []const u8,
    alias: struct { name: []const u8, type: CppTypeId },
    include: struct { path: []const u8, system: bool },
};

pub fn PositionMember(comptime role: Role) type {
    return struct {
        name: []const u8,
        value: role.PlanId(),
    };
}

pub const DeferredCall = struct {
    declaration: DeclarationRef,
    overload_index: ?u32 = null,
    argument_index: u32,
};

pub const DeferredPosition = struct {
    value: InboundArgumentPlanId,
    call: DeferredCall,
};

pub fn ConvertedPosition(comptime role: Role) type {
    return struct {
        match: role.PlanId(),
        value: role.PlanId(),

        pub fn apiValue(conversion: @This()) role.PlanId() {
            return if (role == .outbound_argument) conversion.match else conversion.value;
        }
    };
}

pub const LazyOperand = struct { value: InboundArgumentPlanId, protocol: InboundArgumentPlanId };

pub fn Representation(comptime role: Role) type {
    return union(enum) {
        converted: ConvertedPosition(role),
        optional: role.PlanId(),
        dictionary: []const PositionField(role),
        union_type: []const PositionMember(role),
        sequence: role.PlanId(),
        record: role.PlanId(),
        rest: if (role == .inbound_argument or role == .outbound_argument) role.PlanId() else noreturn,
        record_entry: struct { key: role.PlanId(), value: role.PlanId() },
        leaf: switch (role) {
            .inbound_argument => union(enum) {
                void,
                scalar: ScalarKind,
                enumeration,
                js_value_view: JSValueKind,
                string_view,
                bytes_view,
                native_slice_view,
                byte_lease,
                callback_view,
                class_view,
                external_view,
                nominal_borrow,
                nominal_owned: NominalOwnershipId,
                native_receiver: ClassId,
                lazy_field: InboundArgumentPlanId,
                lazy_view: DeferredPosition,
                lazy_rest: DeferredPosition,
            },
            .inbound_result => union(enum) {
                void,
                scalar: ScalarKind,
                enumeration,
                js_value_result: JSValueKind,
                string_owned,
                utf8_owned,
                bytes_owned,
                lease_owned,
                callback_owned,
                class_owned,
                external_owned,
                nominal_borrow,
                nominal_owned: NominalOwnershipId,
                native_instance: ClassId,
            },
            .outbound_argument => union(enum) {
                scalar: ScalarKind,
                enumeration,
                js_value_operand: JSValueKind,
                js_value_result: JSValueKind,
                string_operand,
                string_owned,
                bytes_operand,
                native_slice,
                callback_view,
                class_view,
                nominal_borrow,
                nominal_owner_borrow: NominalOwnershipId,
                nominal_owned: NominalOwnershipId,
                lazy_operand: LazyOperand,
            },
            .outbound_result => union(enum) {
                void,
                scalar: ScalarKind,
                enumeration,
                js_value_result: JSValueKind,
                string_owned,
                bytes_owned,
                callback_result,
                class_result,
                nominal_borrow,
                nominal_owned: NominalOwnershipId,
            },
        },
    };
}

pub const ApiType = struct {
    type: TypeId,
    representation: union(enum) {
        void,
        scalar: ScalarKind,
        enumeration,
        js_value_view: JSValueKind,
        js_value_operand: JSValueKind,
        js_value_result: JSValueKind,
        string_view,
        string_operand,
        string_owned,
        utf8_owned,
        bytes_view,
        bytes_operand,
        bytes_owned,
        native_slice,
        native_slice_view,
        byte_lease,
        lease_owned,
        callback_view,
        callback_owned,
        class_view,
        class_owned,
        external_view,
        external_owned,
        nominal_borrow,
        nominal_owner_borrow: NominalOwnershipId,
        nominal_owned: NominalOwnershipId,
        native: ClassId,
        optional: ApiTypeId,
        dictionary: struct { fields: []const ApiTypeId, system_error: bool },
        union_type: []const ApiTypeId,
        record_entry: struct { key: ApiTypeId, value: ApiTypeId, cleanup: EntryCleanup },
        sequence: Collection,
        record: Collection,
        rest: union(enum) { view: InboundArgumentPlanId, slice: Slice },
        lazy_view: LazyView,
        lazy_rest: LazyRest,
        lazy_field: struct { value: InboundArgumentPlanId, forward: OutboundArgumentPlanId, protocol: InboundArgumentPlanId, symbol: []const u8 },
        lazy_operand: InboundArgumentPlanId,
    },

    pub const Slice = struct { element: ApiTypeId, mutable: bool };
    pub const EntryCleanup = union(enum) { none, owned: InboundResultPlanId, scoped: OutboundResultPlanId };
    pub const Collection = union(enum) {
        view: View,
        owned: struct { element: InboundResultPlanId, wire: WireTypeId },
        scoped: ScopedCollection,
        slice: Slice,
    };
    pub const ScopedCollection = struct { owner: InboundResultPlanId, wire: WireTypeId };
    pub const View = struct { element: InboundArgumentPlanId, source: InboundArgumentPlanId };
    pub const LazyView = struct { symbol: []const u8, deferred: DeferredPosition, forward: OutboundArgumentPlanId, result_wire: WireTypeId };
    pub const LazyRest = struct { symbol: []const u8, deferred: DeferredPosition, result_wire: WireTypeId };
};

pub const CppImplementationId = Id("cpp_implementations");
pub const CppCompletionEncoderId = Id("cpp_completions");
pub const CppRealmFunctionId = Id("cpp_realm_functions");
pub const CppTypedField = struct { name: []const u8, type: CppTypeId };

pub const CppNativeParameterId = CppId(.inbound_argument, "parameters");

pub fn CppNativeEncodeId(comptime role: Role) type {
    return CppId(role, "native_encoders");
}

pub const CppCodecFailureId = Id("cpp_codec_failures");

pub const CppCodecFailure = struct {
    allocation: union(enum) {
        infallible,
        status,
        return_value: CppReturn,
        throw_value: struct { value: CppReturn, if_clear: bool },
    },
    exception: union(enum) { none, status, materialize: CppReturn, termination: CppReturn },
};

pub const CppNativeParameter = struct {
    failure: CppCodecFailureId,
    type: CppTypeId,
    operation: union(enum) {
        encode: CppNativeEncodeId(.inbound_argument),
        javascript: CppInputId,
        lazy: CppInputId,
        optional: CppNativeParameterId,
    },
};

pub fn CppCodecField(comptime ValueId: type) type {
    return struct {
        name: []const u8,
        value: ValueId,
        optional: bool,
        dictionary_source: bool = false,
    };
}

pub fn CppCodecMember(comptime ValueId: type) type {
    return struct { name: []const u8, value: ValueId };
}

pub fn CppEncodeOperation(comptime ValueId: type, comptime Leaf: type, comptime Collection: type) type {
    return union(enum) {
        converted: ValueId,
        leaf: Leaf,
        optional: ValueId,
        dictionary: []const CppCodecField(ValueId),
        union_type: []const CppCodecMember(ValueId),
        collection: Collection,
        entry: struct { key: ValueId, value: ValueId },
    };
}

pub fn CppNativeEncodingLeaf(comptime role: Role) type {
    return union(enum) {
        scalar: ScalarKind,
        enumeration,
        string,
        bytes,
        native_slice,
        value: CppJavaScriptValue,
        callback: bool,
        handle: switch (role) {
            .inbound_argument => union(enum) { external, nominal: CppHandle },
            .outbound_argument => CppHandle,
            .inbound_result, .outbound_result => @compileError("native C++ encoders require an argument role"),
        },
        lazy_handle,
    };
}

pub fn CppNativeEncode(comptime role: Role) type {
    return struct {
        wire: WireTypeId,
        failure: CppCodecFailureId,
        operation: CppEncodeOperation(CppNativeEncodeId(role), CppNativeEncodingLeaf(role), CppNativeEncodeId(role)),
        protects_sources: bool,
    };
}

pub const CppValueTest = union(enum) {
    always,
    null_value,
    undefined_value,
    nullish,
    boolean,
    number,
    big_int,
    int32,
    uint32,
    string,
    object,
    string_object,
    truthy,
    callback,
    array,
    iterable,
    uint8_array,
    uint8_view,
    uint32_array,
    integer_array,
    buffer_view,
    array_buffer,
    url,
    number_literal: f64,
    integer: struct { wire: WireTypeId, range: CppIntegerRange },
    brand: CppBrandMatchId,
    class: ClassId,
    external: []const u8,
    negate: CppValueTestId,
    any_of: []const CppValueTestId,
    all_of: []const CppValueTestId,
};

pub const CppJavaScriptValue = union(enum) { any, engine_value, branded: CppBrandMatchId };
pub const CppClassReference = union(enum) { native: ClassId, engine: ClassId };

/// Decoding a position's wire value into its C++ value, failing through `failure`.
pub fn CppDecode(comptime role: Role) type {
    return struct { position: role.PlanId(), failure: CppCodecFailureId };
}

/// A result helper that decodes its position's wire value into a caller's
/// C++ value, failing through `failure`.
pub const CppResultDecoder = struct {
    value_type: CppTypeId,
    wire: WireTypeId,
    allocates: bool,
    failure: CppCodecFailureId,
    body: CppDecodeBody(.inbound_result),
};

pub const CppDecodeConverter = struct {
    declaration: CppConverterDeclarationId,
    infallible: bool,
    path_override: ?[]const u8,
};

pub const CppLazyDecode = struct { value_type: CppTypeId, protocol: InboundArgumentPlanId };

/// How generated C++ decodes a position's wire value. The decode is the same
/// for every failure context: whichever decode reaches a node supplies its failure.
pub fn CppDecodePlan(comptime role: Role) type {
    return struct {
        value_type: CppTypeId,
        operation: union(enum) {
            body: CppDecodeBody(role),
            /// Aggregate results decode through the result helper of this position.
            helper: InboundResultPlanId,
        },
    };
}

/// Decodes the position's representation, each child through its own plan.
pub fn CppDecodeBody(comptime role: Role) type {
    return struct {
        /// Owned nominal handles in the decoded value are released unless decoding completes.
        cleanup: bool,
        roots: enum { none, enclosing, target },
        /// Present for converted outbound arguments, which decode their match and convert it.
        converter: ?CppDecodeConverter,
        /// The collection decodes into call-scoped storage and exposes a span.
        span: bool,
        leaf: ?CppDecodeLeaf(role),
    };
}

pub fn CppDecodeLeaf(comptime role: Role) type {
    return switch (role) {
        .outbound_argument => union(enum) {
            scalar: ScalarKind,
            enumeration: []const u16,
            encoded_value: CppJavaScriptValue,
            callback_borrow,
            class_borrow: CppClassReference,
            string_borrow,
            slice_borrow,
            handle_borrow,
            lazy: CppLazyDecode,
        },
        .inbound_result, .outbound_result => union(enum) {
            void,
            scalar: ScalarKind,
            enumeration: []const u16,
            encoded_value: CppJavaScriptValue,
            callback_root,
            class_root: CppClassReference,
            string_take,
            bytes_take,
            buffer_materialize: BufferResultRepresentation,
            handle_borrow,
            handle_take,
        },
        .inbound_argument => @compileError("C++ wire decoders require an outbound argument or result role"),
    };
}

pub fn CppResultEncoderId(comptime role: Role) type {
    return CppId(role, "result_encoders");
}

pub fn CppResultElement(comptime role: Role) type {
    return union(enum) { direct: CppResultEncoderId(role), sequence: CppResultEncoderId(role), record: CppResultEncoderId(role) };
}

pub fn CppResultEncoder(comptime role: Role) type {
    return struct {
        value_type: CppTypeId,
        requires_global: bool,
        wire: WireTypeId,
        operation: CppEncodeOperation(CppResultEncoderId(role), union(enum) {
            void,
            helper: if (role == .inbound_argument) void else CppResultEncoderId(.inbound_result),
            nominal_handle: CppHandle,
            scalar: ScalarKind,
            value: CppJavaScriptValue,
            callback: bool,
            class_ref: if (role == .inbound_argument) void else CppClassReference,
            string: struct { thread_safe: bool },
            bytes,
            enumeration: WireScalar,
        }, struct { wire: WireTypeId, element: CppResultElement(role) }),
    };
}

pub const InboundArgumentPlan = struct {
    pub const plan_role = Role.inbound_argument;

    api: ApiTypeId,
    type: TypeId,
    typescript: []const u8,
    transfer: bool,
    stored: bool,
    native_heap: bool,
    record_entry: bool,
    native_class: ?ClassId,
    representation: Representation(.inbound_argument),
    wire: WireTypeId,
    zig: ZigPlan(.inbound_argument),
    cpp: CppPlan(.inbound_argument),

    pub fn isVoid(plan: *const @This()) bool {
        return plan.representation == .leaf and plan.representation.leaf == .void;
    }
};
pub const InboundResultPlan = ValuePlan(.inbound_result);
pub const OutboundArgumentPlan = ValuePlan(.outbound_argument);
pub const OutboundResultPlan = ValuePlan(.outbound_result);

fn ValuePlan(comptime role: Role) type {
    return struct {
        pub const plan_role = role;

        api: ApiTypeId,
        type: TypeId,
        transfer: bool,
        stored: bool,
        native_heap: bool,
        record_entry: bool,
        native_class: ?ClassId,
        representation: Representation(role),
        wire: WireTypeId,
        zig: ZigPlan(role),
        cpp: CppPlan(role),
        pub fn isVoid(plan: *const @This()) bool {
            return if (role == .outbound_argument) false else plan.representation == .leaf and plan.representation.leaf == .void;
        }
    };
}

/// What generated C++ releases for a position. Composite values release
/// through their representation; the flags say whether anything in the
/// subtree needs releasing.
pub const CppRelease = struct {
    /// The value holds an owned nominal handle.
    owned_handles: bool,
    /// A result wire value abandoned on a pending exception holds something to release.
    pending: bool,
    /// What a pending leaf wire value releases.
    pending_leaf: ?CppPendingRelease,
};

pub const CppPendingRelease = union(enum) { root, class_ref, string, bytes, release_handle: []const u8 };

pub fn CppPlan(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => struct {
            inputs: []const CppInput,
            input_encoders: []const CppInputEncode,
            input_aggregates: []const CppInputAggregate,
            native_encoders: []const CppNativeEncode(role),
            parameters: []const CppNativeParameter,
            result_encoders: []const CppResultEncoder(role),
            materializers: []const CppMaterializer(role),
            release: CppRelease,
            lazy_field: ?CppLazyField,
        },
        .inbound_result => struct {
            result_encoders: []const CppResultEncoder(role),
            decoder_helper: ?CppResultDecoder,
            decode: ?CppDecodePlan(role),
            materializers: []const CppMaterializer(role),
            release: CppRelease,
        },
        .outbound_argument => struct {
            native_encoders: []const CppNativeEncode(role),
            decode: ?CppDecodePlan(role),
            materializers: []const CppMaterializer(role),
            release: CppRelease,
        },
        .outbound_result => struct {
            javascript_decoders: []const CppJavaScriptDecode,
            result_encoders: []const CppResultEncoder(role),
            decode: ?CppDecodePlan(role),
            materializers: []const CppMaterializer(role),
            release: CppRelease,
        },
    };
}

/// The Zig side of a position. Its composite structure is the position's
/// `representation`, which every walk recurses through; `leaf` holds the
/// operations of a leaf representation and is null otherwise.
pub fn ZigPlan(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => struct {
            leaf: ?ZigLeaf(.inbound_argument),
            destruction: ZigDestruction,
            requires_realm: bool,
            clone: ?ClonePlan,
        },
        .inbound_result => struct {
            leaf: ?ZigLeaf(.inbound_result),
            destruction: ZigDestruction,
            encode_allocates: bool,
            decode_allocates: bool,
            requires_realm: bool,
        },
        .outbound_argument => struct {
            leaf: ?ZigLeaf(.outbound_argument),
            destruction: ZigDestruction,
            encode_allocates: bool,
        },
        .outbound_result => struct {
            leaf: ?ZigLeaf(.outbound_result),
            destruction: ZigDestruction,
            decode_allocates: bool,
            requires_realm: bool,
        },
    };
}

/// Whether destroying a position's Zig value, or its transferred wire value,
/// releases anything anywhere in its structure.
pub const ZigDestruction = struct {
    api: bool = false,
    wire: bool = false,
};

pub fn ZigLeaf(comptime role: Role) type {
    return switch (role) {
        .inbound_argument, .outbound_result => struct {
            decode: ZigDecodeLeaf(role),
            destroy: ZigApiDestroy(role) = .none,
            release: ZigWireRelease(role) = .none,
        },
        .inbound_result => struct {
            encode: ZigEncodeLeaf(role),
            decode: ZigDecodeLeaf(role),
            destroy: ZigApiDestroy(role) = .none,
            release: ZigWireRelease(role) = .none,
        },
        .outbound_argument => struct {
            encode: ZigEncodeLeaf(role),
            destroy: ZigApiDestroy(role) = .none,
            release: ZigWireRelease(role) = .none,
        },
    };
}

pub fn ZigEncodeLeaf(comptime role: Role) type {
    return switch (role) {
        .inbound_result => union(enum) {
            void,
            scalar: ScalarKind,
            enumeration,
            value_result,
            take_wire,
            nominal_handle,
            pointer,
        },
        .outbound_argument => union(enum) {
            scalar: ScalarKind,
            enumeration,
            value_operand,
            value_result,
            scoped_handle,
            borrow_wire,
            borrow_transfer_handle,
            nominal_handle,
            native_slice,
        },
        .inbound_argument, .outbound_result => @compileError("this role does not encode Zig values"),
    };
}

pub fn ZigDecodeLeaf(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => union(enum) {
            void,
            scalar: ScalarKind,
            enumeration,
            scoped_view,
            token_view,
            adopt_wire,
            pointer,
        },
        .inbound_result => union(enum) {
            void,
            scalar: ScalarKind,
            enumeration,
            value_result: JSValueKind,
            adopt_wire,
            adopt_scoped,
            pointer,
        },
        .outbound_result => union(enum) {
            void,
            scalar: ScalarKind,
            enumeration,
            value_result: JSValueKind,
            adopt_wire,
            borrow_callback,
            borrow_class,
            pointer,
        },
        .outbound_argument => @compileError("this role does not decode Zig values"),
    };
}

pub fn ZigApiDestroy(comptime role: Role) type {
    return switch (role) {
        .inbound_argument, .outbound_argument, .outbound_result => enum { none, deinit },
        .inbound_result => union(enum) { none, deinit, native_instance: ClassId },
    };
}

pub fn HandleRelease(comptime role: Role) type {
    return if (role == .inbound_result) union(enum) {
        byte_lease,
        nominal: NominalOwnershipId,
        external: ExternalRefId,
        native: ClassId,
    } else NominalOwnershipId;
}

pub fn ZigWireRelease(comptime role: Role) type {
    return switch (role) {
        .inbound_argument, .outbound_argument => union(enum) { none, release_handle: HandleRelease(role) },
        .inbound_result, .outbound_result => union(enum) {
            none,
            root,
            string,
            bytes,
            release_handle: HandleRelease(role),
            class_ref,
        },
    };
}

pub const ClonePlan = struct {
    target: InboundResultPlanId,
    raises_exception: bool,
    /// How a leaf value is cloned; composite values clone through their representation.
    leaf: ?enum { value, engine_value, retain, allocate },
};

pub const CppMaterializationSource = enum { wire, native };

pub fn CppMaterializerId(comptime role: Role) type {
    return CppId(role, "materializers");
}

pub fn CppMaterializedField(comptime ValueId: type) type {
    return struct { name: []const u8, property: CppPropertyWrite, value: ValueId, optional: bool };
}

pub const CppPropertyWrite = union(enum) { name: []const u8, offset: u32 };
pub const CppObjectCreation = union(enum) { ordinary: ?[]const u8, null_prototype: ?[]const u8, class: ClassId };

pub fn CppDictionaryMaterialization(comptime ValueId: type) type {
    return struct { object: CppObjectCreation, fields: []const CppMaterializedField(ValueId) };
}

pub fn CppMaterializer(comptime role: Role) type {
    return struct {
        source: union(CppMaterializationSource) {
            wire: struct { type: WireTypeId, transfer: bool },
            native: CppTypeId,
        },
        operation: JavaScriptMaterialization(role),

        pub fn isVoid(self: @This()) bool {
            return self.operation == .leaf and self.operation.leaf == .void;
        }
    };
}

pub const CppScalarMaterialization = union(enum) {
    boolean,
    number,
    integer_number,
    integer_number_or_bigint,
    signed_bigint,
    unsigned_bigint,
    discarded: DiscardedMatch,
};

pub const CppOptionalAbsence = enum { undefined_value, null_value };
pub const CppMaterializedValue = enum { encoded, handle, root, any, native };

pub const CppMaterializationLeaf = union(enum) {
    void,
    scalar: CppScalarMaterialization,
    value: struct { read: CppMaterializedValue, brand: ?CppBrandMatchId },
    callback: CppMaterializedValue,
    string,
    utf8,
    buffer: BufferResultRepresentation,
    enumeration: EnumerationId,
    class: struct { id: ClassId, read: CppMaterializedValue },
};

pub fn JavaScriptMaterialization(comptime role: Role) type {
    const ChildId = CppMaterializerId(role);
    return union(enum) {
        leaf: CppMaterializationLeaf,
        optional: struct { value: ChildId, absence: CppOptionalAbsence },
        dictionary: CppDictionaryMaterialization(ChildId),
        union_type: []const CppCodecMember(ChildId),
        sequence: struct { value: ChildId, frozen: bool },
        record: struct { object: CppObjectCreation, value: ChildId },
    };
}

// ─── semantic types ───

pub const Brand = struct {
    brand_name: []const u8,
    cpp_match: CppBrandMatchId,
    promise_value_type: ?TypeId,
    constructor_class: ?ClassId,
};

pub const StringType = struct {
    string_thread_safe: bool,
};

pub const BufferType = struct {
    buffer_access: BufferAccess,
    buffer_result_representation: BufferResultRepresentation,
};

pub const NativeSliceType = struct {
    native_slice_element: NativeSliceElement,
    native_slice_access: BufferAccess,
};

pub const ConvertedType = struct {
    native_type: TypeId,
};

pub const PromiseReactionId = Id("promise_reactions");

pub const PromiseReactionContext = struct {
    context_name: []const u8,
    owner_type: CppTypeId,
    create: EngineShimId,
    adopt: EngineShimId,
    attach: EngineShimId,
    take: EngineShimId,
    destroy: NativeExportId,
};

pub const BrandedValueType = struct {
    brand: Brand,
    promise_reaction: ?PromiseReactionId,
};

pub const NominalOwnershipId = Id("nominal_ownerships");

pub const NominalOwnership = struct {
    destroy_thread: ResourceThread,
    release_symbol: []const u8,
    cpp_release: []const u8,
    byte_access: ?struct { symbol: []const u8, cpp_read: []const u8 },
};

pub const CppNominalHandle = struct { ownership: NominalOwnershipId, native_type: CppTypeId, wire: WireTypeId };
pub const CppResource = union(enum) { external: ExternalRefId, nominal: CppNominalHandle };

pub const NominalHandleType = struct {
    nominal_handle_name: []const u8,
    wire: WireTypeId,
    cpp_type: CppTypeId,
    const_pointee: bool,
    ownership: union(enum) { borrowed, owned: NominalOwnershipId },
    zig_type: ?[]const u8,
};

pub const ExternalRefId = Id("external_refs");

pub const ExternalRef = struct {
    external_name: []const u8,
    cpp_type: CppTypeId,
    cpp_idl: CppTypeId,
    zig_type: []const u8,
    brand: ?Brand,
    wire: WireTypeId,
    clone_symbol: []const u8,
    release_symbol: []const u8,
};

pub const ClassRefType = struct {
    class: ClassId,
};

pub const OptionalType = struct {
    child: TypeId,
    optional_mode: OptionalMode,
};

pub const ErrorCodeEntry = struct {
    tag: []const u8,
    value: u16,
    class: ErrorClass,
    code: []const u8,
    name_override: ?[]const u8,
};

pub const ErrorCodeCatalog = struct { enumeration: EnumerationId, codes: []const ErrorCodeEntry };

pub const EnumerationValue = struct {
    value_name: []const u8,
    js_value: []const u8,
    native_value: u16,
};

pub const EnumerationTag = enum { u8, u16 };

pub const EnumerationId = Id("enumerations");

pub const EnumerationType = struct {
    enumeration_name: []const u8,
    enumeration_values: []const EnumerationValue,
    header: enum { shared, error_codes, internal_modules },
    tag: EnumerationTag,
    cpp_name: []const u8,
};

pub const DictionaryField = struct {
    field_name: []const u8,
    field_type: TypeId,
    storage: DictionaryFieldStoragePlan,
};

pub const DictionaryType = struct {
    dictionary_name: []const u8,
    dictionary_fields: []const DictionaryField,
};

pub const UnionMember = struct {
    member_name: []const u8,
    member_type: TypeId,
};

pub const UnionType = struct {
    union_name: []const u8,
    union_members: []const UnionMember,
};

pub const SequenceType = struct {
    child: TypeId,
};

pub const RecordType = struct {
    key_type: TypeId,
    value_type: TypeId,
};

pub const TypeData = union(TypeKind) {
    void,
    boolean,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    usize,
    f64,
    any: AnyPurpose,
    discarded,
    lazy: TypeId,
    converted: ConvertedType,
    dom_string: StringType,
    usv_string: StringType,
    byte_string: StringType,
    utf8_string,
    node_path,
    buffer: BufferType,
    native_slice: NativeSliceType,
    callback: CallbackId,
    optional: OptionalType,
    enumeration: EnumerationId,
    dictionary: DictionaryType,
    union_type: UnionType,
    sequence: SequenceType,
    record: RecordType,
    nominal_handle: NominalHandleType,
    class_ref: ClassRefType,
    external_ref: ExternalRefId,
    branded_value: BrandedValueType,
    engine_value,
    native_instance,
};

pub const Type = struct {
    id: TypeId,
    data: TypeData,

    pub fn kind(value: *const Type) TypeKind {
        return std.meta.activeTag(value.data);
    }
};

pub const TypePlans = struct {
    argument_position: ?InboundArgumentPlanId,
    result_position: ?InboundResultPlanId,
};

// ─── type aliases and TypeScript ───

pub const TypeScriptField = struct { name: []const u8, optional: bool, value: []const u8 };
pub const TypeScriptTag = struct { property: []const u8, value_property: ?[]const u8, shorthand: bool };
pub const TypeScriptEnumerationValue = union(enum) { string: []const u8, number: u16 };

pub const TypeScriptDeclaration = union(enum) {
    enumeration: struct { name: []const u8, values: []const TypeScriptEnumerationValue },
    dictionary: struct { name: []const u8, fields: []const TypeScriptField },
    union_type: struct { name: []const u8, members: []const struct { value: []const u8, tag: ?[]const u8 }, tag: ?TypeScriptTag },
};

// ─── callables ───

pub const CppIntegerRange = struct { min: CppIntegerLiteral, max: CppIntegerLiteral };

pub const CppIntegerLiteral = union(enum) { signed: i64, unsigned: u32, signed_long: i64, unsigned_long: u64 };

pub const CppLiteral = union(enum) {
    boolean: bool,
    integer: CppIntegerLiteral,
    number: f64,
    string: []const u8,
    null_value,
    undefined_value,
    any_null,
    any_undefined,
    enumeration: struct { type: CppTypeId, value: u16 },
    empty_optional,
};

pub fn CppDefaultValue(comptime role: Role) type {
    return struct {
        position: role.PlanId(),
        wrappers: []const CppTypeId = &.{},
        operation: CppLiteral,
    };
}

pub const ArgumentConversion = struct {
    presence: Presence,
    rest: bool,
};

pub fn RestPosition(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => union(enum) {
            values: InboundArgumentPlanId,
            typed: InboundArgumentPlanId,
            count: InboundArgumentPlanId,
            lazy: InboundArgumentPlanId,

            pub fn plan(self: @This()) InboundArgumentPlanId {
                return switch (self) {
                    inline else => |id| id,
                };
            }
        },
        .outbound_argument => union(enum) {
            values: OutboundArgumentPlanId,
            typed: OutboundArgumentPlanId,

            pub fn plan(self: @This()) OutboundArgumentPlanId {
                return switch (self) {
                    inline else => |id| id,
                };
            }
        },
        .inbound_result, .outbound_result => noreturn,
    };
}

pub fn Argument(comptime role: Role) type {
    return struct {
        position: role.PlanId(),
        rest_position: ?RestPosition(role) = null,
        argument_name: []const u8,
        is_projection: bool,
        conversion: ArgumentConversion,

        pub fn valuePosition(argument: @This()) role.PlanId() {
            return if (argument.rest_position) |rest| rest.plan() else argument.position;
        }

        pub fn isOptional(argument: @This()) bool {
            return !argument.conversion.rest and argument.conversion.presence == .optional;
        }
    };
}

pub const DomainErrorId = Id("domain_errors");
pub const DomainError = struct {
    position: InboundResultPlanId,
    error_name: []const u8,
};

pub const CppErrorMessage = union(enum) { literal: []const u8, payload: enum { string, string_handle } };

pub const CppSystemError = struct {
    payload: enum { wire, native },
    detail: union(enum) {
        info,
        standard: struct { metadata_configurable: bool },
    },
};

pub const DomainErrorFactory = struct {
    symbol: []const u8,
    value_type: ?CppTypeId,
    name_override: ?struct { name: []const u8, enumerable: bool },
    operation: union(enum) {
        error_object: struct { class: ErrorClass, code: ?[]const u8, message: CppErrorMessage },
        dom_exception: struct { name: DOMExceptionName, message: CppErrorMessage },
        builtin_error: struct { group: []const u8, function: []const u8, materializer: CppMaterializerId(.inbound_result) },
        class_instance: CppMaterializerId(.inbound_result),
        aggregate_error: struct { message: []const u8, materializer: CppMaterializerId(.inbound_result) },
        system_error: CppSystemError,
    },
};

pub const CppCompletionApiId = Id("cpp_completion_apis");

pub const CppCompletionApi = struct {
    handle: WireTypeId,
    codec: []const u8,
    create: []const u8,
    clone: []const u8,
    release: []const u8,
    finish: []const u8,
    settle: []const u8,
};

pub fn CallPlan(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => struct {
            realm: EngineRealm,
            throws: NativeThrows,
            non_returning: bool,
            receiver: ?InboundArgumentPlanId,
            has_lazy_conversion: bool,
            has_lazy_arguments: bool,
            acquires_byte_lease: bool,
            transfers_argument_ownership: bool,
        },
        .outbound_argument => struct {
            realm: EngineRealm,
            throws: NativeThrows,
            requires_scope: bool,
            receiver: ?OutboundArgumentPlanId,
            callee: ?OutboundArgumentPlanId,
            transfers_argument_ownership: bool,
            checks_traps: bool,
        },
        .inbound_result, .outbound_result => @compileError("call plans require an argument role"),
    };
}

pub const ClassMemberFacts = struct {
    member_kind: ClassMemberKind,
    is_illegal: bool,
    typescript_async: bool,
    native_reference_symbol: ?[]const u8,
};

/// Call receivers normalize internal JSC scopes using strict JavaScript `this` semantics.
pub const CppReceiverSource = enum {
    frame,
    encoded,
    /// Native factories receive an explicit object whose identity must be preserved.
    surface,
};
pub const CppReceiverValue = enum { frame, encoded, surface, cpp, object };

pub const CppArgumentRead = union(enum) {
    receiver: CppReceiverValue,
    new_target,
    callee,
    setter_value,
    argument: struct { index: u32, unchecked: bool },
    slot: []const u8,
    prepared: u32,
};

pub const CppReturn = enum { empty, void, true_value, false_value, undefined_value, allocation_failure, monostate };

pub const CppArgumentMissing = union(enum) { never, undefined, nullish, omitted: u32 };
pub const CppArgumentDestination = union(enum) { cpp: []const u8, wire: []const u8 };
pub const CppArgumentValue = struct {
    input: CppInputId,
    read: CppArgumentRead,
    path: []const u8,
    presence: union(enum) { required, optional: CppArgumentMissing, default_value: struct { missing: CppArgumentMissing, value: CppDefaultValue(.inbound_argument) } },
    target: union(enum) { cpp: []const u8, wire: struct { field: []const u8, local_type: CppTypeId } },
};
pub const CppArgumentLazy = struct {
    input: CppLazyInput,
    read: CppArgumentRead,
    path: []const u8,
    missing: ?CppArgumentMissing,
    target: CppArgumentDestination,
};

pub const CppArgumentConversion = union(enum) {
    value: CppArgumentValue,
    lazy: CppArgumentLazy,
    rest: CppRestInput,
    prepare: struct { value: CppInputPreparation, read: CppArgumentRead, source_index: u32, path: []const u8 },
    selected: CppArgumentSelection,
};

pub const CppRestInput = union(enum) {
    borrowed_values: []const u8,
    values: CppRestValues,
    element: CppRestElement,
    count: struct { encoder: CppInputEncodeId, target: CppArgumentDestination },
};

pub const CppRestRead = enum { call_frame, overload_inputs };
pub const CppRestValues = struct { target: []const u8, read: CppRestRead, lazy: ?CppLazyInput, encoder: CppInputEncodeId };
pub const CppRestElement = struct {
    target: CppArgumentDestination,
    read: CppRestRead,
    value: CppInputId,
    failure: CppInputFailure,
    path: CppRestPath,
};

pub const CppCachedSlotAccessors = struct {
    getter: CppHostCall,
    setter: ?CppHostCall,
};

pub const CppCachedSlotRead = enum { value, callback, optional_callback };

pub const CppCachedSlotWrite = struct {
    name: []const u8,
    nullable: bool,
    input: CppInputId,
    output: enum { any, value, string },
};

pub const CppSelectedInputStorage = struct { name: []const u8, input: CppInputId };

pub const CppArgumentSelection = struct {
    target: []const u8,
    path: []const u8,
    selector: CppTypeId,
    source_name: []const u8,
    frame: ?struct { read: CppArgumentRead, storage: []const CppSelectedInputStorage, retain: ?u32 },
    members: []const struct {
        name: []const u8,
        values: []const []const u8,
        operation: union(enum) { none, prepare: CppInputPreparation, convert: CppInputId },
    },
};

pub const CppInboundArgument = struct {
    conversion: CppArgumentConversion,
    index: u32,
    prepared_input: ?u32 = null,
};

pub const CppReceiverCheck = struct {
    class: union(enum) { native: ClassId, engine: ClassId, constructor: ClassId },
    brand: ?CppBrandMatchId,
    invalid_this: union(enum) { no_op: CppReturn, throw, failure: ConversionFailure },
    failure_return: CppReturn,
};

pub const CppCacheAccess = struct {
    owner: ClassId,
    slot: u32,
    nullable_receiver: bool,
    read: CppCachedSlotRead,
};

pub const CppRequiredArgumentCheck = struct {
    minimum: u32,
    failure: union(enum) { arity, custom: struct { value: ConversionFailure, return_value: CppReturn } },
};

pub fn CppNativeArgument(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => struct { name: []const u8, path: []const u8, parameter: CppNativeParameterId },
        .outbound_argument => struct { name: []const u8, encoder: CppNativeEncodeId(role) },
        .inbound_result, .outbound_result => @compileError("C++ native arguments require an argument role"),
    };
}

pub const CppArgumentFrameId = Id("cpp_argument_frames");
pub const CppArgumentFrame = struct {
    pub const Transfer = struct { name: []const u8, position: InboundArgumentPlanId };

    wire_storage: bool,
    argument_roots: bool,
    deferred_conversions: bool,
    converter_receiver: ?CppReceiverValue,
    transferred: []const Transfer,
};

pub fn CppInboundInput(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => union(enum) {
            prepare_arguments: CppArgumentFrameId,
            retain_lazy_receiver: CppReceiverValue,
            check_receiver: CppReceiverCheck,
            read_cache: CppCacheAccess,
            borrow_receiver: ClassId,
            construct_structure: struct { class: ClassId, missing_new: ConversionFailure },
            javascript: CppInboundArgument,
            required_count: CppRequiredArgumentCheck,
            native: []const CppNativeArgument(role),
        },
        .outbound_argument => union(enum) {
            prepare_arguments: CppArgumentFrameId,
            native: []const CppNativeArgument(role),
        },
        .inbound_result, .outbound_result => @compileError("C++ call inputs require an argument role"),
    };
}

pub const CppImplementation = struct {
    symbol: []const u8,
    arguments: []const u8,
    context: union(enum) {
        call: struct { receiver: CppReceiverHandle, caller_source_origin: bool },
        engine_call: ClassId,
        engine_construct: ClassId,
        plain_construct: ClassId,
    },
    fields: []const CppTypedField,
    result: union(enum) {
        completion: CppCompletionEncoderId,
        sync: struct {
            type: CppTypeId,
            outcome: ?struct { name: []const u8, errors: []const CppDomainError },
            returns_value: bool,
            requires_context: bool,
        },
    },
};

pub const CppDomainError = struct {
    name: []const u8,
    payload: ?CppTypeId,
    raise_symbol: []const u8,
};

pub const CppNativeConstructionId = Id("cpp_native_constructions");

pub const CppNativeConstruction = struct {
    class: ClassId,
    cached_getters: []const FunctionId,
};

pub const CppReceiverHandle = enum { none, native, engine, callback_data };

pub const CppWireErrorFactory = struct { name: []const u8, factory: []const u8 };
pub const CppWireResultLayout = union(enum) { void, value, errors: []const CppWireErrorFactory };
pub const CppWireResultId = Id("cpp_wire_results");
pub const CppWireResult = struct {
    wire: WireTypeId,
    destroy: ?[]const u8,
    layout: CppWireResultLayout,
};

pub const CppWireCallee = struct {
    symbol: []const u8,
    arguments: WireTypeId,
    result: CppWireResultId,
    realm: EngineRealm,
    lazy_storage: ?CppLazyStorage,
    context: struct {
        promise: bool,
        receiver: CppReceiverHandle,
        caller_frame: bool,
        deferred: enum { none, local, engine_context },
    },
};

pub fn CppDecodedResult(comptime role: Role) type {
    if (role != .inbound_result and role != .outbound_result) @compileError("C++ decoded results require a result role");
    return struct { result: CppWireResultId, decoder: CppDecode(role), release_wire: bool };
}

pub const CppCallStatus = struct {
    realm: EngineRealm,
    throws: NativeThrows,
    non_returning: bool,

    pub const javascript: CppCallStatus = .{ .realm = .current, .throws = .js_exception, .non_returning = false };
};

pub fn CppInboundCall(comptime role: Role) type {
    return switch (role) {
        .inbound_argument => struct {
            pub const argument_role = role;

            prepare_receiver: ?CppReceiverSource = null,
            inputs: []const CppInboundInput(role) = &.{},
            status: CppCallStatus,
            codec_failure: CppCodecFailureId,
            callee: union(enum) {
                wire: CppWireCallee,
                builtin_constructor: ClassId,
                predicate: CppValueTest,
                reject: ConversionFailure,
                load_cache: struct { name: []const u8, read: CppCachedSlotRead },
                store_cache: CppCachedSlotWrite,
                cpp: CppImplementationId,
            },
            frame: ?CppArgumentFrameId = null,
            output: union(enum) {
                encode_value: union(enum) {
                    wire: struct { result: CppWireResultId, materializer: CppMaterializerId(.inbound_result), release_wire: bool },
                    cpp: struct { materializer: CppMaterializerId(.inbound_result), string_inputs: []const u32 },
                },
                decode_value: CppDecodedResult(.inbound_result),
                attach_native: struct { construction: CppNativeConstructionId, result: CppWireResultId },
                javascript: enum { value, object },
                constant: struct { value: CppReturn, release_wire: bool },
                promise: enum { wire, cpp },
            },
            cache: ?CppCacheAccess = null,
            failure_return: CppReturn = .empty,
        },
        .outbound_argument => struct {
            pub const argument_role = role;

            inputs: []const CppInboundInput(role),
            frame: CppArgumentFrameId,
            status: CppCallStatus,
            codec_failure: CppCodecFailureId,
            callee: CppWireCallee,
            output: union(enum) { void, decode_value: CppDecodedResult(.outbound_result) },
            failure_return: CppReturn,
        },
        .inbound_result, .outbound_result => @compileError("C++ inbound calls require an argument role"),
    };
}

pub const FunctionIdRef = union(enum) { function: FunctionId, overload: OverloadCaseId };

pub const CppHost = struct {
    pub const Frame = struct {
        linkage: enum { external_noexcept, internal_noexcept, internal },
        overload_inputs: bool,
        callback_data: bool,
        promise_body: ?[]const u8,
    };

    symbol: []const u8,
    signature: union(enum) { frame: Frame, getter: ?[]const u8, setter },
};

pub const CppHostCall = struct { host: CppHost, entry: *const CppInboundCall(.inbound_argument) };

pub const CppSurfaceEvaluator = struct {
    symbol: []const u8,
    promise: bool,
    entry: *const CppInboundCall(.inbound_argument),
};

pub const CppOverloadDispatch = struct {
    host: CppHost,
    name: []const u8,
    prepare_receiver: ?CppReceiverSource,
    receiver: ?CppReceiverCheck,
    input_slot_count: u32,
    argument_count: OverloadArgumentCount,
    underflow: union(enum) { none, reject: CppRequiredArgumentCheck, dispatch: u32 },
    cases: []const CppOverloadCase,
};

pub const CppOverloadCase = struct {
    declaration: OverloadCaseId,
    symbol: []const u8,
    minimum_argument_count: u32,
    maximum_argument_count: ?usize,
    comparisons: []const struct {
        overlap_minimum: usize,
        overlap_maximum: ?usize,
        arguments: []const struct { index: u32, selection: CppValueTest },
    },
};

pub const CppFunction = union(enum) {
    builtin,
    overload: CppOverloadDispatch,
    call: struct {
        host: CppHost,
        entry: *const CppInboundCall(.inbound_argument),
        surface: ?CppSurfaceEvaluator,
        writable: ?CppHostCall,
    },
};

/// A module function, a class constructor or constructor call, a class
/// member, or one case of an overloaded callable.
pub const Function = struct {
    id: FunctionIdRef,
    result_position: InboundResultPlanId,
    module_name: []const u8,
    function_name: []const u8,
    args: []const Argument(.inbound_argument),
    case_name: []const u8,
    overload_cases: []const OverloadCaseId,
    backend: Backend,
    domain_errors: []const DomainErrorId,
    completion: ?CompletionId,
    call_plan: CallPlan(.inbound_argument),
    this_argument: ?Argument(.inbound_argument),
    new_target_argument: ?Argument(.inbound_argument),
    callee_argument: ?Argument(.inbound_argument),
    callback_data_type: ?[]const u8,
    has_caller_source_location: bool,
    is_promise_reaction_handler: bool,
    predicate: ?InboundArgumentPlanId,
    class_member: ?ClassMemberFacts,
    implementation_name: []const u8,
    js_name: []const u8,
    dispatch_symbol: []const u8,
    host_symbol: []const u8,
    wire_args: ?WireTypeId = null,
    wire_result: WireTypeId,
    destroy_result_symbol: ?[]const u8,
    js_length: u32,
    exposed: bool,

    pub fn isAsync(function: *const Function) bool {
        return function.completion != null;
    }

    pub fn isOverloaded(function: *const Function) bool {
        return function.overload_cases.len != 0;
    }

    pub fn hasWireResult(function: *const Function) bool {
        return !function.isOverloaded() or function.isAsync();
    }
};

pub const OutboundCall = struct {
    result_position: OutboundResultPlanId,
    args: []const Argument(.outbound_argument),
    call_plan: CallPlan(.outbound_argument),
    wire_args: WireTypeId,
    wire_result: WireTypeId,
    entries: []const OutboundEntry,
};

pub const OutboundEntry = struct {
    symbol: []const u8,
    callee: enum { native, callback, schedule },
};

pub const EngineShim = struct {
    id: EngineShimId,
    outbound: OutboundCall,
    module_name: []const u8,
    shim_name: []const u8,
    destroy_result_symbol: ?[]const u8,
};

pub const CppOutboundContext = union(enum) { none, current: enum { unchecked, exception, termination } };

pub const CppOutboundCallbackArguments = struct {
    pub const Argument = struct { name: []const u8, materializer: CppMaterializerId(.outbound_argument), rest: bool };

    callee: CppDecode(.outbound_argument),
    receiver: ?CppMaterializerId(.outbound_argument),
    arguments: []const CppOutboundCallbackArguments.Argument,
    capacity: union(enum) { fixed: usize, rest: struct { name: []const u8, fixed: usize } },
};

pub const CppOutboundNativeCall = struct {
    pub const Transfer = struct { name: []const u8, position: OutboundArgumentPlanId };

    symbol: []const u8,
    arguments_type: CppTypeId,
    arguments: []const struct { name: []const u8, path: []const u8, decoder: CppDecode(.outbound_argument) },
    argument_storage: bool,
    context: CppOutboundContext,
    transferred: []const Transfer,
    allocation: bool,
};

pub const CppOutboundValue = struct {
    position: OutboundResultPlanId,
    destroy: []const u8,
    conversion: union(enum) {
        native: struct { encoder: CppResultEncoderId(.outbound_result), owned: ?OutboundResultPlanId },
        javascript: struct { decoder: CppJavaScriptDecodeId, path: []const u8 },
    },
};

pub const CppOutboundInvoke = struct {
    callee: union(enum) { native: CppOutboundNativeCall, callback: CppOutboundCallbackArguments },
    result: ?CppOutboundValue,
};

pub const CppOutboundEntry = struct {
    symbol: []const u8,
    operation: union(enum) { invoke: CppOutboundInvoke, schedule: CppOutboundCallbackArguments },
};

pub const CppOutboundCall = struct {
    wire_args: WireTypeId,
    wire_result: WireTypeId,
    entries: []const CppOutboundEntry,
};

pub const CppCompletionValue = struct {
    encoder: CppResultEncoderId(.inbound_result),
    cleanup: ?InboundResultPlanId,
    output: union(enum) {
        value: enum { direct, tagged },
        domain_error: struct { tag: u32, declaration: CppDomainError },
    },
};

pub const CppCompletionMaterializer = union(enum) {
    wire: CppMaterializerId(.inbound_result),
    engine: struct {
        api: CppCompletionApiId,
        arguments: []const u8,
        argument: []const u8,
        callee: []const u8,
        exception_check: enum { exception, termination },
        result: union(enum) { void, value: CppMaterializerId(.outbound_result), allocation: CppMaterializerId(.outbound_result) },
    },
};

pub const CppCompletionDelivery = struct {
    completion: CompletionId,
    wire: WireTypeId,
    destroy: ?[]const u8,
    layout: CppWireResultLayout,
    materializer: CppCompletionMaterializer,
};

pub const CppCompletionEncoder = struct {
    completion: CompletionId,
    api: CppCompletionApiId,
    wire: WireTypeId,
    value: union(enum) { value: CppTypeId, owned_handle: CppTypeId },
    entries: []const CppCompletionValue,
};

pub const CppNativeSignature = struct {
    pub const Parameter = struct { name: []const u8, type: union(enum) { native: CppNativeParameterId, direct: CppTypeId } };
    pub const GlobalScope = enum { exception, termination, checked_exception };

    symbol: []const u8,
    parameters: []const Parameter,
    result: CppTypeId,
    nodiscard: bool,
    context: union(enum) { none, global: GlobalScope, engine },
    non_returning: bool,
};

pub fn CppNativeEntry(comptime role: Role) type {
    return struct {
        signature: CppNativeSignature,
        namespace: enum { engine, zig_exports },
        call: *const CppInboundCall(role),
    };
}

pub const CppNativeExport = struct {
    element_aliases: []const CppTypedField,
    entry: CppNativeEntry(.inbound_argument),
    surface: ?CppNativeEntry(.inbound_argument),
};

pub const CppEngineImplementation = struct {
    arguments: struct { name: []const u8, fields: []const CppTypedField },
    result_alias: CppTypedField,
    signature: CppNativeSignature,
};

pub const NativeExport = struct {
    id: NativeExportId,
    result_position: InboundResultPlanId,
    module_name: []const u8,
    export_name: []const u8,
    args: []const Argument(.inbound_argument),
    exposed: bool,
    domain_errors: []const DomainErrorId,
    call_plan: CallPlan(.inbound_argument),
    wire_args: WireTypeId,
    wire_result: WireTypeId,
    dispatch_symbol: []const u8,
    destroy_result_symbol: ?[]const u8,
};

pub const Callback = struct {
    id: CallbackId,
    type: TypeId,
    callback_name: []const u8,
};

// ─── classes ───

pub const CachedSlot = struct {
    declared_type: TypeId,
    assigned_position: InboundArgumentPlanId,
    access: CachedSlotAccess,
    slot_name: []const u8,
    optional: bool,
    storage: CachedSlotStorage,
    get_symbol: []const u8,
    write: ?struct { set: []const u8, clear_weak: []const u8 },
};

/// Callback and JavaScript-value slots expose their cached value by engine identity
/// as a view of the assigned position's API; the other kinds are read only through
/// their typed slot accessors.
pub const CachedSlotAccess = union(enum) {
    callback,
    js_value: JSValueKind,
    class_ref,
    union_type,
    storage_only,
};

pub const CachedSlotStorage = enum { instance, constructor };

pub const InstanceProperty = struct {
    position: OutboundArgumentPlanId,
    property_name: []const u8,
};

pub const PlainInitializer = struct {
    property_name: []const u8,
    value: union(enum) { constant: struct { value: CppDefaultValue(.outbound_argument), materializer: CppMaterializerId(.outbound_argument) }, source: Source },

    pub const Source = struct {
        access: PlainInitializerSource,
        conversion: union(enum) { materialize: CppMaterializerId(.inbound_argument), bigint_quotient: u64 },
    };
};

pub const EngineWrapperDispatch = struct {
    native_type: CppTypeId,
    operation: union(enum) {
        direct,
        tagged: struct { discriminator: []const u8, cases: []const Case },
    },

    pub const Case = struct {
        tag: []const u8,
        operation: union(enum) { derived: CppTypeId, global_scope: CppTypeId, base },
    };
};

pub const CppClassMemberSymbol = union(enum) { native: []const u8, builtin: []const u8 };

pub const CppClassPropertyAttributes = struct {
    read_only: bool,
    enumerable: bool,
    configurable: bool,
    dom_attribute: bool,
};

pub const CppClassGetter = struct {
    implementation: CppClassMemberSymbol,
    setter: ?CppClassMemberSymbol,
};

pub const CppClassTableEntry = struct {
    name: []const u8,
    attributes: CppClassPropertyAttributes,
    value: union(enum) {
        function: struct { implementation: CppClassMemberSymbol, length: @FieldType(Function, "js_length") },
        accessor: CppClassGetter,
    },
};

pub const CppClassPropertyKey = union(enum) { name: []const u8, symbol: PropertySymbol, private_symbol: []const u8 };

pub const CppClassInstallation = union(enum) {
    property: struct {
        key: CppClassPropertyKey,
        attributes: CppClassPropertyAttributes,
        value: union(enum) {
            native: struct { symbol: []const u8, name: []const u8, length: @FieldType(Function, "js_length"), visibility: SurfaceFunctionVisibility },
            builtin: []const u8,
            accessor: CppClassGetter,
            constant: DefaultValue,
        },
    },
    aliases: struct {
        source: []const u8,
        targets: []const Alias,
    },
    to_string_tag,

    pub const Alias = struct { key: ClassMemberAliasKey, enumerable: bool };
};

pub const CppClassPropertySet = struct {
    table: []const CppClassTableEntry,
    installations: []const CppClassInstallation,
};

pub const CppClassProperties = struct {
    prototype: CppClassPropertySet,
    constructor: CppClassPropertySet,
    unforgeable: []const Unforgeable,

    pub const Unforgeable = struct {
        name: []const u8,
        attributes: CppClassPropertyAttributes,
        accessor: union(enum) { getter: CppClassGetter, setter: CppClassMemberSymbol },
    };
};

pub const CppClassInitialization = struct {
    prototype: Prototype,
    structure: union(enum) { class, plain: []const Property },
    constructor: ?union(enum) { function, class: ClassId },

    pub const Prototype = union(enum) { object, function, iterator, async_iterator, error_object, class: ClassId };
    pub const Property = union(enum) { name: []const u8, private_symbol: []const u8 };
};

pub const ClassRelations = struct {
    emission: ClassEmissionPlan,
    initialization: CppClassInitialization,
    properties: CppClassProperties,
    typescript: TypeScriptClass,
    engine_wrapper_dispatch: ?EngineWrapperDispatch,
    instance_value_type: ?TypeId,
    constructor_value_type: ?TypeId,
};

pub const TypeScriptPropertySymbol = enum {
    async_dispose,
    async_iterator,
    dispose,
    has_instance,
    iterator,
    match,
    match_all,
    replace,
    search,
    split,
    species,
    to_primitive,
    to_string_tag,
};

pub const TypeScriptPropertyKey = union(enum) { name: []const u8, symbol: TypeScriptPropertySymbol };

pub const TypeScriptClassMember = struct {
    is_static: bool,
    operation: union(enum) {
        iterator: enum { synchronous, asynchronous },
        method: struct { key: TypeScriptPropertyKey, declaration: FunctionIdRef },
        getter: struct { name: []const u8, declaration: FunctionIdRef, writable: bool },
        setter: struct { name: []const u8, argument: InboundArgumentPlanId },
        property: struct {
            key: TypeScriptPropertyKey,
            read_only: bool,
            value: union(enum) { type: TypeId, primitive: enum { boolean, number, string, null_value, undefined_value } },
        },
    },
};

pub const TypeScriptClass = struct {
    members: []const TypeScriptClassMember,
    declaration: union(enum) {
        class: []const FunctionIdRef,
        callable: struct { constructors: []const FunctionIdRef, calls: []const FunctionIdRef, members: []const TypeScriptClassMember },
    },
};

pub const ClassInitializers = struct {
    constructor: Entry,
    call: ?Entry,

    pub const Entry = struct { implementation: CppImplementationId, values: []const PlainInitializer };
};

pub const CppClassConstructor = struct {
    factory_symbol: []const u8,
    slots: []const u32,
    builtin: ?[]const u8,
    call: union(enum) {
        function: FunctionId,
        host: CppHostCall,
    },

    pub fn hasTracedState(constructor: CppClassConstructor) bool {
        return constructor.builtin != null or constructor.slots.len != 0;
    }
};

pub const Class = struct {
    id: ClassId,
    module_name: []const u8,
    class_name: []const u8,
    display_name: []const u8,
    brand: ?Brand,
    representation: union(ClassRepresentation) { native, engine: CppEngineClass, plain },
    runtime_plan: ClassRuntimePlan,
    parent: ?ClassId,
    upcast: ?struct { implementation: []const u8, symbol: []const u8 },
    instance_properties: []const InstanceProperty,
    create_symbol: []const u8,
    memory_usage: ?struct { affinity: MemoryUsageAffinity, symbol: []const u8 },
    pending_activity: ?[]const u8,
    immutable_prototype: bool,
    structured_clone: ?StructuredCloneId,
    constructor_call: ?FunctionId,
    slots: []const CachedSlot,
    declarations: []const FunctionId,
    exposed: bool,
    cpp_class_name: []const u8,
    cpp_prototype_name: []const u8,
    cpp_constructor_name: []const u8,
    get_constructor_symbol: []const u8,
    try_cast_symbol: []const u8,
    try_cast_direct_symbol: []const u8,
    wrap_native_symbol: []const u8,
    destroy_native_symbol: []const u8,
    destroy_pending_native_symbol: []const u8,
    release_native_on_vm_symbol: []const u8,
    native_type_symbol_prefix: []const u8,
    initialize_symbol: []const u8,
    constructor: FunctionId,
    /// The semantic type of the class's instance values.
    value_type: TypeId,
};

// ─── surfaces ───

pub const DeclarationRef = union(enum) {
    function: FunctionId,
    native_export: NativeExportId,
    class: ClassId,
};

pub const SurfaceMemberReference = struct { surface: ObjectSurfaceId, index: u32 };

pub const CppSurfaceFunctionName = union(enum) { none, named: []const u8, getter: []const u8, setter: []const u8 };

pub const CppSurfaceFunction = union(enum) {
    realm: CppRealmFunctionId,
    builtin: []const u8,
    native: struct {
        symbol: []const u8,
        length: @FieldType(Function, "js_length"),
        name: CppSurfaceFunctionName,
        visibility: SurfaceFunctionVisibility,
        constructable: bool,
    },
};

pub const CppRealmFunction = struct {
    symbol: []const u8,
    name: []const u8,
    host: []const u8,
    length: @FieldType(Function, "js_length"),
    visibility: SurfaceFunctionVisibility,
};

pub const CppFunctionFactory = struct {
    symbol: []const u8,
    abi: enum { value, reference },
    value: CppSurfaceFunction,
};

pub const CppSurfaceValue = union(enum) {
    function: CppSurfaceFunction,
    callback: SurfaceMemberReference,
    function_factory: []const u8,
    native_factory: []const u8,
    constructor: ClassId,
    object: ObjectSurfaceId,
    constant: SurfaceConstant,
    empty_collection: SurfaceEmptyCollection,
    self,
};

pub const CppSurfaceInitializer = union(enum) {
    value: CppSurfaceValue,
    callable: struct { function: CppSurfaceFunction, surface: ObjectSurfaceId },
};

pub const CppSurfaceAccessor = struct {
    getter: CppSurfaceFunction,
    setter: union(enum) { none, getter, function: CppSurfaceFunction },
};

pub const CppSurfaceInstallation = union(enum) {
    value: CppSurfaceValue,
    builtin: []const u8,
    native: struct { symbol: []const u8, length: @FieldType(Function, "js_length"), visibility: SurfaceFunctionVisibility },
    accessor: CppSurfaceAccessor,
};

pub const CppNativeModuleValue = union(enum) { value: CppSurfaceValue, accessor: CppSurfaceAccessor };

pub const SurfaceTableValue = union(enum) {
    function: struct { symbol: union(enum) { native: []const u8, builtin: []const u8 }, length: @FieldType(Function, "js_length"), constructable: bool },
    builtin_accessor: []const u8,
    property_callback,
    integer: i64,
    owner: struct { kind: SurfaceLazyOwner, class: []const u8, member: []const u8 },
};

pub const SurfaceType = union(enum) {
    declaration: JavaScriptDeclarationRef,
    value: TypeId,
    object: ObjectSurfaceId,
    self_object: ObjectSurfaceId,
    namespace,
    callable: struct { declaration: FunctionId, surface: ObjectSurfaceId },
    constant: union(enum) { string: []const u8, boolean: bool, string_type, boolean_type, number, symbol, undefined },
    collection: struct { kind: SurfaceEmptyCollection, element: TypeId },
};

pub const SurfaceTypeScriptMember = struct {
    key: TypeScriptPropertyKey,
    read_only: bool,
    type: SurfaceType,
};

pub const ObjectSurfaceMember = struct {
    property_name: []const u8,
    property_key: SurfacePropertyKey,
    attributes: SurfacePropertyAttributes,
    aliases: []const SurfaceMemberAlias,
    native_accessor: ?struct { name: []const u8, table_index: u32 },
    installation: union(enum) { table: SurfaceTableValue, direct: CppSurfaceInstallation, global: CppSurfaceValue },
    initializer: ?CppSurfaceInitializer,
    exposed: bool,
};

pub const CppSurfaceHashIndex = struct { value: i16, next: i16 };
pub const CppSurfaceHashTable = struct { value_count: u32, mask: u32, index: []const CppSurfaceHashIndex };

pub const ObjectSurface = struct {
    id: ObjectSurfaceId,
    surface_name: []const u8,
    members: []const ObjectSurfaceMember,
    typescript_members: []const SurfaceTypeScriptMember,
    exposed: bool,
    installation: union(SurfaceInstallation) { static_lookup: struct { table: CppSurfaceHashTable, install: bool }, reified, direct },
    global_class: ?[]const u8,
    prototype: ObjectSurfacePrototype,
    integrity: ObjectSurfaceIntegrity,
};

pub const NativeModuleExport = struct {
    export_name: []const u8,
    operation: CppNativeModuleValue,
    type: SurfaceType,
    aliases: []const NativeModuleExportAlias,
    attributes: SurfacePropertyAttributes,
    exposed: bool,
    typescript_exposed: bool,
};

pub const JavaScriptDeclarationRef = union(enum) {
    function: FunctionId,
    class: ClassId,
};

pub const NativeModuleSurfaceId = Id("native_module_surfaces");

pub const NativeModuleSurface = struct {
    surface_name: []const u8,
    specifier: []const u8,
    exports: []const NativeModuleExport,
    default: union(NativeModuleDefaultPolicy) {
        namespace,
        declaration: struct {
            target: JavaScriptDeclarationRef,
            value: CppSurfaceValue,
            installation: ?struct { self_property: ?SurfacePropertyAttributes },
        },
    },
    exposed: bool,
    typescript_exposed: bool,
    named_export_count: u32,
};

pub const InternalModuleEntry = struct {
    default_export: InternalModuleDefault,
    id: u16,
    name: []const u8,
    specifier: []const u8,
    aliases: []const []const u8,
    source: union(enum) {
        javascript: struct { path: []const u8, bundle_path: []const u8, url: []const u8 },
        native: NativeModuleSurfaceId,
    },
};

pub const InternalModuleRegistry = struct {
    enumeration: EnumerationId,
    modules: []const InternalModuleEntry,
    javascript_count: u32,
};

pub const StandaloneNativeExportHeaderPlan = struct {
    header: []const u8,
    exports: []const NativeExportId,
    nominal_handle_declarations: []const CppDeclarationId,
};

pub const FocusedEngineIntegration = struct {
    integration_name: []const u8,
    integration_options: FocusedEngineIntegrationOptions,
};

pub const Module = struct {
    module_name: []const u8,
    source_stem: []const u8,
    declarations: []const FunctionId,
    class_declarations: []const ClassId,
    engine_declarations: []const EngineShimId,
    native_declarations: []const NativeExportId,
    structured_clones: []const StructuredCloneId,
    focused_integrations: []const FocusedEngineIntegration,
};

/// The canonical IR of every binding declaration for one target.
pub const Ir = struct {
    abi: u32,
    target: Target,
    features: []const []const u8,
    modules: []const Module,
    types: []const Type,
    enumerations: []const EnumerationType,
    nominal_ownerships: []const NominalOwnership,
    cpp_resources: []const CppResource,
    external_refs: []const ExternalRef,
    promise_reactions: []const PromiseReactionContext,
    typescript_types: []const []const u8,
    typescript_declarations: []const TypeScriptDeclaration,
    type_plans: []const TypePlans,
    wire_types: []const WireType,
    cpp_types: []const CppType,
    cpp_brand_matches: []const CppBrandMatch,
    cpp_codec_failures: []const CppCodecFailure,
    cpp_declarations: []const CppDeclaration,
    cpp_header_declarations: []const CppDeclarationId,
    cpp_converter_declarations: []const CppConverterDeclaration,
    cpp_type_definitions: []const CppTypeDefinition,
    cpp_input_declarations: []const CppInputAggregateId,
    inbound_argument_plans: []const InboundArgumentPlan,
    inbound_result_plans: []const InboundResultPlan,
    outbound_argument_plans: []const OutboundArgumentPlan,
    outbound_result_plans: []const OutboundResultPlan,
    api_types: []const ApiType,
    domain_errors: []const DomainError,
    cpp_value_tests: []const CppValueTest,
    cpp_dictionary_values: []const CppDictionaryValue,
    /// Types at or past this index are reached only as metadata, such as
    /// promise settlement values, brand-cast operands, and class values.
    binding_type_count: u32,
    functions: []const Function,
    overload_cases: []const Function,
    completions: []const CompletionPlan,
    cpp_completion_apis: []const CppCompletionApi,
    cpp_completions: []const CppCompletionEncoder,
    cpp_completion_deliveries: []const CppCompletionDelivery,
    cpp_class_property_materializers: []const []const CppMaterializerId(.outbound_argument),
    cpp_class_slot_accessors: []const []const ?CppCachedSlotAccessors,
    cpp_engine_calls: []const CppOutboundCall,
    cpp_callback_calls: []const ?CppOutboundCall,
    /// Null for a function this target does not expose.
    cpp_functions: []const ?CppFunction,
    cpp_argument_frames: []const CppArgumentFrame,
    cpp_wire_results: []const CppWireResult,
    cpp_function_factories: []const ?CppFunctionFactory,
    cpp_realm_functions: []const CppRealmFunction,
    cpp_implementations: []const CppImplementation,
    cpp_native_constructions: []const CppNativeConstruction,
    cpp_engine_implementations: []const CppEngineImplementation,
    cpp_overload_cases: []const ?CppFunction,
    classes: []const Class,
    structured_clones: []const StructuredClonePlan,
    structured_clone_modules: []const ModuleId,
    class_relations: []const ClassRelations,
    class_initializers: []const ?ClassInitializers,
    cpp_class_constructors: []const ?CppClassConstructor,
    cpp_header_classes: []const ClassId,
    engine_shims: []const EngineShim,
    native_exports: []const NativeExport,
    cpp_native_exports: []const ?CppNativeExport,
    cpp_engine_entries: []const ?CppNativeEntry(.outbound_argument),
    callbacks: []const Callback,
    callback_calls: []const OutboundCall,
    object_surfaces: []const ObjectSurface,
    object_surface_plans: []const ObjectSurfacePlan,
    typescript_object_surfaces: []const ObjectSurfaceId,
    native_module_headers: []const []const u8,
    native_module_surfaces: []const NativeModuleSurface,
    error_catalog: ?ErrorCodeCatalog,
    internal_module_registry: ?InternalModuleRegistry,
    external_ref_declaration_headers: []const []const u8,
    cpp_source_dependencies: []const CppSourceDependency,
    private_symbols: []const []const u8,
    standalone_native_export_header_plans: []const StandaloneNativeExportHeaderPlan,
    promise_reaction_contexts: []const PromiseReactionId,
    engine_classes: []const ClassId,
    engine_class_headers: []const []const u8,
    domain_error_factories: []const DomainErrorFactory,
    cpp_domain_error_factories: []const DomainErrorFactory,
    interned_property_keys: []const []const u8,
    enumeration_strings: []const []const u8,

    pub fn functionById(ir: *const Ir, id: FunctionIdRef) *const Function {
        return switch (id) {
            .function => |function| ir.get(function),
            .overload => |overload| ir.get(overload),
        };
    }

    pub fn functionCpp(ir: *const Ir, function: *const Function) *const CppFunction {
        return switch (function.id) {
            .function => |id| &ir.cpp_functions[id.index].?,
            .overload => |id| &ir.cpp_overload_cases[id.index].?,
        };
    }

    pub fn get(ir: *const Ir, id: anytype) *const Entity(@TypeOf(id)) {
        if (@hasDecl(@TypeOf(id), "cpp_field")) return &@field(ir.get(id.position).cpp, @TypeOf(id).cpp_field)[id.index];
        return &@field(ir, @TypeOf(id).table)[id.index];
    }

    pub fn rolePlans(ir: *const Ir, comptime role: Role) []const role.Plan() {
        return @field(ir, role.PlanId().table);
    }

    pub fn typeScript(ir: *const Ir, type_id: TypeId) []const u8 {
        return ir.typescript_types[type_id.index];
    }

    pub fn argumentPosition(ir: *const Ir, type_id: TypeId) ?InboundArgumentPlanId {
        return ir.type_plans[type_id.index].argument_position;
    }

    pub fn resultPosition(ir: *const Ir, type_id: TypeId) ?InboundResultPlanId {
        return ir.type_plans[type_id.index].result_position;
    }
};

/// Formats of generated names that both the C++ and the comptime bind spell.
pub const symbol_formats = struct {
    pub const lazy_result = "BunBind_Lazy_{s}_Result";
    pub const lazy_convert = "bun_bindgen_lazy_{s}_convert";
    pub const lazy_discard = "bun_bindgen_lazy_{s}_discard";
    pub const lazy_field_convert = "bun_bindgen_lazy_field_{s}_convert";
    pub const lazy_field_discard = "bun_bindgen_lazy_field_{s}_discard";
};

/// Identifies a lazily read dictionary field's conversion.
pub fn lazyFieldKey(protocol: InboundArgumentPlanId) u64 {
    return @as(u64, protocol.index) + 1;
}

pub fn Entity(comptime IdType: type) type {
    if (@hasDecl(IdType, "cpp_field")) return @typeInfo(@FieldType(CppPlan(IdType.role), IdType.cpp_field)).pointer.child;
    return @typeInfo(@FieldType(Ir, IdType.table)).pointer.child;
}

pub fn fingerprintSymbol(fingerprint: u64) [40]u8 {
    var symbol: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&symbol, "bun_bindgen_fingerprint_{x:0>16}", .{fingerprint}) catch unreachable;
    return symbol;
}
