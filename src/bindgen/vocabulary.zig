//! Shared vocabulary of the binding schema language and its IR: plain data
//! with no reference to schema declarations.
const std = @import("std");

pub const Backend = enum {
    zig,
    cpp,
    builtin,
};

pub const Profile = enum {
    webidl,
    node,
    exact,
};

pub const StringConversion = enum {
    profile,
    coerce,
};

pub const BufferMode = enum {
    copy,
    lease,
};

pub const BufferSource = enum {
    array_buffer_or_view,
    view,
    integer_typed_array,
    uint8_array,
    uint32_array,

    pub fn isIntegerTypedArray(source: BufferSource) bool {
        return switch (source) {
            .integer_typed_array, .uint8_array, .uint32_array => true,
            .array_buffer_or_view, .view => false,
        };
    }
};

pub const BufferAccess = enum {
    read_only,
    read_write,
};

pub const NativeSliceElement = enum {
    uint8,
    uint16,
    uint32,
    uint64,
};

pub const BufferResultRepresentation = enum {
    array_buffer,
    uint8_array,
    node_buffer,
    int8_array,
    int16_array,
    uint16_array,
    int32_array,
    uint32_array,
    float16_array,
    float32_array,
    float64_array,

    pub fn jsClassName(representation: BufferResultRepresentation) []const u8 {
        return switch (representation) {
            .array_buffer => "ArrayBuffer",
            .node_buffer => "Buffer",
            .uint8_array => "Uint8Array",
            .int8_array => "Int8Array",
            .int16_array => "Int16Array",
            .uint16_array => "Uint16Array",
            .int32_array => "Int32Array",
            .uint32_array => "Uint32Array",
            .float16_array => "Float16Array",
            .float32_array => "Float32Array",
            .float64_array => "Float64Array",
        };
    }
};

pub const TypeKind = enum {
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
    any,
    discarded,
    lazy,
    converted,
    dom_string,
    usv_string,
    byte_string,
    utf8_string,
    node_path,
    buffer,
    native_slice,
    callback,
    optional,
    enumeration,
    dictionary,
    union_type,
    sequence,
    record,
    nominal_handle,
    class_ref,
    external_ref,
    branded_value,
    engine_value,
    native_instance,
};

pub const IntegerRepresentation = enum {
    number,
    bigint,
    number_or_bigint,
};

pub const StringEmptyRejection = struct {
    code: []const u8,
    message: []const u8,
};

pub const StringCoercionOptions = struct {
    nullish_failure: ?ConversionFailure = null,
    empty_rejection: ?StringEmptyRejection = null,
    input: StringCoercionInput = .any,
    type_error_format: StringTypeErrorFormat = .profile,
    input_failure: ?ConversionFailure = null,
};

pub const AnyPurpose = enum {
    retention,
    pass_through,
    invocation,
};

pub const DiscardedMatch = union(enum) {
    semantic_type,
    null_literal,
    undefined_literal,
    false_literal,
    number_literal: f64,
};

pub const DiscardPurpose = enum {
    contextual,
    classification,
    presence,
    ignored,
    count,
};

pub const NodePathOptions = struct {
    file_url_strings: bool = false,
    boxed_strings: bool = false,
};

pub const BufferCopyFallback = enum { allow, refuse };

pub const BufferSourceAttachment = enum { optional, required };

pub const BufferTypeErrorFormat = enum { profile, node_type };

pub const BufferOptions = struct {
    type_error_format: BufferTypeErrorFormat = .profile,
    type_failure: ?ConversionFailure = null,
    allow_detached: bool = true,
    detached_failure: ?ConversionFailure = null,
    allow_shared: bool = true,
    copy_fallback: BufferCopyFallback = .allow,
    source_attachment: BufferSourceAttachment = .optional,
    transfer_policy: BufferTransferPolicy = .reject,
    result_representation: ?BufferResultRepresentation = null,

    pub fn resultRepresentation(options: BufferOptions) BufferResultRepresentation {
        return options.result_representation orelse .uint8_array;
    }
};

pub const CppBrandMatcher = struct {
    symbol: []const u8,
    header: []const u8,
};

pub const CppRealmBrandMatcher = struct {
    symbol: []const u8,
    header: []const u8,
};

pub const CppDynamicCastMatcher = struct {
    type_name: []const u8,
    header: []const u8,
};

pub const NominalHandleOwnership = enum {
    borrowed,
    owned,
};

pub const ResourceThread = enum {
    any,
    current,
    vm,
};

pub const CppType = union(enum) {
    void,
    int,
    named: []const u8,
    pointer: *const CppType,
    const_pointer: *const CppType,
    function_pointer: struct {
        result: *const CppType,
        parameters: []const CppType,
        convention: enum { c, host } = .c,
    },
    specialization: struct { name: []const u8, arguments: []const CppType },
};

pub const CppDeclaration = union(enum) {
    structure: []const u8,
    class: []const u8,
    alias: struct { name: []const u8, type: CppType },
    include: struct { path: []const u8, system: bool = false },
};

pub const NominalHandleOptions = struct {
    cpp_type: CppType,
    c_struct: ?[]const u8 = null,
    cpp_declarations: []const CppDeclaration = &.{},
    cpp_header: ?[]const u8 = null,
    cpp_read_bytes: ?[]const u8 = null,
    const_pointee: bool = false,
    raw_pointer_escape: ?[]const u8 = null,
    ownership: NominalHandleOwnership = .borrowed,
    cpp_release: []const u8 = "",
    zig_type: ?[]const u8 = null,
    access_thread: ?ResourceThread = null,
    destroy_thread: ?ResourceThread = null,
};

pub const BrandedValueSpecificity = enum {
    exact,
    generic,
};

pub const BrandedValueError = enum {
    type,
    instance,
    invalid_value,
    invalid_this,
};

pub const BrandedValueDefaults = struct {
    allows_null_default: bool = false,
    allows_undefined_default: bool = false,
    error_kind: BrandedValueError = .instance,
    expectation: ?[]const u8 = null,
    node_requirement: ?[]const u8 = null,
    node_expected_types: ?[]const []const u8 = null,
    specificity: BrandedValueSpecificity = .exact,
    no_match_error: ?ConversionFailure = null,
};

pub const ClassReferenceOptions = struct {
    no_match_error: ?ConversionFailure = null,
    node_expected_instances: ?[]const u8 = null,
};

pub const ClassValueMatch = enum { instance, initial_structure };

pub const ClassValueOptions = struct {
    match: ClassValueMatch = .instance,
};

pub const OptionalMode = enum {
    nullable,
    nullish,
    undefined,
    falsy,
    matched,
    /// Absent when the value is null, undefined, or an empty string.
    /// Matches config fields where an empty string means "use the default".
    nullish_or_empty_string,
};

pub const EnumerationValueOptions = struct {
    aliases: []const []const u8 = &.{},
    native_value: ?u16 = null,
    error_code: ?ErrorCodeOptions = null,
    internal_module: ?InternalModuleSource = null,
    internal_module_default: InternalModuleDefault = .property,
};

pub const InternalModuleDefault = enum { property, module_object };

pub const InternalModuleSource = union(enum) {
    javascript: []const u8,
    native,
};

pub const ErrorCodeOptions = struct {
    class: ErrorClass,
    code: []const u8,
    name: ?[]const u8 = null,
};

pub const EnumerationOptions = struct {
    cpp_name: ?[]const u8 = null,
    accept_native_numbers: bool = false,
    coerce: bool = false,
    ascii_case_insensitive: bool = false,
    invalid_value_error: EnumerationInvalidValueError = .range,
    invalid_value_failure: ?ConversionFailure = null,
    unrecognized_value: ?[]const u8 = null,
    node_invalid_value: ?NodeInvalidEnumerationValue = null,
    strict_errors: ?EnumerationErrors = null,
    tag: enum { u8, u16 } = .u8,
    error_catalog: bool = false,
    internal_module_registry: bool = false,
};

pub const EnumerationErrors = struct {
    invalid_type: ConversionFailure,
    invalid_value: ConversionFailure,
    invalid_string_prefix: ?ConversionFailure = null,
};

pub const EnumerationInvalidValueError = enum {
    type,
    range,
};

pub const NodeInvalidEnumerationValue = union(enum) {
    invalid_argument_value: struct {
        name: ?[]const u8 = null,
        reason: []const u8,
        coerce: bool = false,
        non_string_expected_type: ?[]const u8 = null,
        non_string_name: ?[]const u8 = null,
    },
    invalid_property_value: struct {
        name: ?[]const u8 = null,
        expected: []const u8,
        non_string_expected_type: ?[]const u8 = null,
        non_string_name: ?[]const u8 = null,
    },
    coerced_error: struct {
        code: []const u8,
        message_prefix: []const u8,
        message_suffix: []const u8 = "",
        non_string_expected_type: ?[]const u8 = null,
    },
};

pub const DictionaryFieldOptions = struct {
    source_field: ?[]const u8 = null,
    source: DictionaryFieldSource = .property,
    missing: DictionaryFieldMissing = .undefined,
    required: bool = false,
    missing_required: RequiredDictionaryFieldMissing = .reject,
    default_value: ?DefaultValue = null,
    boolean_conversion: BooleanConversion = .normal,
    integer_conversion: IntegerConversion = .normal,
    number_conversion: NumberConversion = .normal,
    deferred_reason: ?[]const u8 = null,
    lazy_property_read: LazyPropertyRead = .deferred,
    diagnostic_name: ?[]const u8 = null,
    js_name: ?[]const u8 = null,
    private_symbol: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    profile: ?Profile = null,
    node_unsupported: ?[]const u8 = null,
    enum_membership_after_fields: bool = false,
    node_incompatible_with: ?[]const u8 = null,
};

pub const LazyPropertyRead = enum { deferred, eager };

pub const DictionaryFieldSource = enum {
    property,
    dictionary,
};

pub const DictionaryFieldMissing = enum {
    undefined,
    undefined_or_null,
    /// Uses HasProperty followed by Get, preserving a present undefined value.
    absent,
};

pub const ResultObjectPrototype = enum {
    ordinary,
    null,
};

pub const DictionaryObjectError = enum { type, invalid_value };

pub const DictionaryInputSnapshot = enum {
    none,
    own_enumerable,
};

pub const DictionaryPropertyLookup = enum {
    ordinary,
    skip_object_prototype,
};

pub const DictionaryFieldReads = enum {
    interleaved,
    before_conversion,
};

pub const RequiredDictionaryFieldMissing = union(enum) {
    reject,
    convert_undefined,
    failure: ConversionFailure,
};

pub const UnionMemberOptions = struct {
    deferred_reason: ?[]const u8 = null,
    boolean_conversion: BooleanConversion = .normal,
    integer_conversion: IntegerConversion = .normal,
    number_conversion: NumberConversion = .normal,
};

pub const NodeUnionError = union(enum) {
    expected_type: []const u8,
    expected_instances: []const u8,
    type_or_instance: struct {
        expected_type: []const u8,
        expected_instances: []const u8,
    },
    invalid_value: ?[]const u8,
    invalid_property_value: []const u8,
    invalid_port,
};

pub const NodeSequenceErrorKind = enum {
    type,
    instance,
    invalid_this,
};

pub const NodeSequenceFailure = struct {
    kind: NodeSequenceErrorKind = .type,
    expected: []const u8,
    site: NodeSequenceFailureSite = .sequence,
};

pub const NodeSequenceFailureSite = enum {
    sequence,
    element,
};

pub const NodeSequenceError = struct {
    container: ?NodeSequenceFailure = null,
    element: NodeSequenceFailure,
};

pub const SequenceElementAccess = enum {
    property,
    direct_index,
};

pub const SequenceFlavor = enum {
    sequence,
    frozen_array,
};

pub const SequenceContainer = enum {
    array,
    iterable,
    array_like,
    concrete_array,

    pub fn isArray(container: SequenceContainer) bool {
        return container == .array or container == .concrete_array;
    }
};

pub const SequenceOptions = struct {
    input_length_limit: ?SequenceLengthLimit = null,
    element_deferred_reason: ?[]const u8 = null,
    element_pattern: ?SequenceElementPattern = null,
    snapshot_elements: bool = false,
    node_error: ?NodeSequenceError = null,
    element_access: SequenceElementAccess = .property,
    flavor: SequenceFlavor = .sequence,
    container: SequenceContainer = .array,
    element_conversion: ValueConversionOptions = .{},
};

pub const SequenceLengthLimit = struct {
    max: u32,
    failure: ConversionFailure,
};

pub const SequenceElementPattern = struct {
    members: []const []const u8,
    read_group_sizes: []const u16 = &.{},
    incomplete_error: ConversionFailure,
};

pub const RecordOptions = struct {
    value_deferred_reason: ?[]const u8 = null,
    result_prototype: ResultObjectPrototype = .ordinary,
    result_to_string_tag: ?[]const u8 = null,
};

pub const Missing = enum {
    undefined,
    undefined_or_null,
    omitted,
};

pub const Presence = enum {
    required,
    optional,
    default_value,
};

pub const DefaultValue = union(enum) {
    boolean: bool,
    signed: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,
    null,
    undefined,
};

pub const IntegerRange = struct {
    min: i128,
    max: i128,
};

pub const IntegerRangeFailure = struct {
    code: []const u8,
    argument_suffix: []const u8,
};

pub const SaturatedIntegerValidation = struct {
    range: IntegerRange,
    coerce: bool = false,
    failure: ?IntegerRangeFailure = null,
};

pub const ConversionFailure = struct {
    kind: union(enum) {
        generic_error,
        type_error,
        range_error,
        code: []const u8,
        dom_exception: DOMExceptionName,
    },
    message: []const u8,
};

pub const BoundedIntegerValidation = struct {
    range: IntegerRange,
    below: enum { reject, saturate } = .reject,
    above: enum { reject, saturate } = .reject,
    allow_infinity: bool = false,
    invalid: ConversionFailure,
    out_of_range: ConversionFailure,
};

pub const TruncatedIntegerClamp = struct {
    range: IntegerRange,
    nan: i128,
    coerce: bool = false,
};

pub const CoercedIntegerDefault = struct {
    range: IntegerRange,
    fallback: i128,
};

pub const NodeIntegerCoercion = struct {
    range: IntegerRange,
    range_error: enum { interval, bound, predicate } = .interval,
};

pub const NodeTruncatedIntegerValidation = struct {
    range: IntegerRange,
    range_error: enum { operators, prose } = .operators,
};

pub const NodeIntegerValidation = struct {
    range: IntegerRange,
    rejection: enum { safe_integer, property_value, port },
    fractional: enum { reject, truncate } = .reject,
};

pub const IntegerConversion = union(enum) {
    normal,
    /// Require safe integer Numbers or BigInts, then reduce modulo the declared width.
    modulo,
    coerce,
    /// ToInt32, then clamp to the wire integer's own range.
    coerce_saturate,
    truncate_saturate,
    /// Numbers truncate toward zero and saturate, including infinities; NaN uses the declared value.
    truncate_clamp: TruncatedIntegerClamp,
    /// ToNumber, then truncate; non-finite or out-of-range results use the fallback.
    coerce_truncate_or_default: CoercedIntegerDefault,
    saturate_validate: SaturatedIntegerValidation,
    bounded_integer: BoundedIntegerValidation,
    enforce_range: IntegerRange,
    clamp: IntegerRange,
    node_validate: IntegerRange,
    node_validate_with: NodeIntegerValidation,
    node_coerce: NodeIntegerCoercion,
    node_validate_prose: IntegerRange,
    node_truncate: NodeTruncatedIntegerValidation,
    node_receiver_byte_length: ReceiverByteLengthConversion,
    /// Select only exact integer Numbers in this range, including during overload matching.
    matching: IntegerRange,
    /// WebIDL ToNumber followed by integer truncation and modulo at the declared width.
    webidl,
    /// ECMAScript ToLength, in the range zero through the maximum safe integer.
    to_length,
};

pub const NodeNumberRangeError = enum {
    out_of_range,
    invalid_value,
};

pub const NodeNumberValidation = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    error_kind: NodeNumberRangeError = .out_of_range,
};

pub const NumberRange = struct {
    min: f64,
    max: f64,
};

pub const NumberRangeValidation = struct {
    range: NumberRange,
    error_message: []const u8,
    error_class: ErrorClass = .range_error,
};

pub const NumberIntegerNormalization = struct {
    range: NumberRange,
    fallback: f64,
};

pub const NumberIntegerWrapping = struct {
    bits: u6,
    range: NumberRange,
};

pub const NumberConversion = union(enum) {
    normal,
    coerce,
    coerce_clamp: NumberRange,
    enforce_range: NumberRangeValidation,
    coerce_truncate_or_default: NumberIntegerNormalization,
    /// Non-finite inputs use the fallback; finite inputs truncate before clamping.
    coerce_truncate_clamp: NumberIntegerNormalization,
    coerce_wrap_clamp: NumberIntegerWrapping,
    node_validate: NodeNumberValidation,
    integer_or_infinity,
};

pub const BooleanConversion = union(enum) {
    normal,
    node_property_typeof: []const u8,
    strict: ConversionFailure,
    truthy,
    strict_true,
    not_strict_false,
};

pub const ValueConversionOptions = struct {
    boolean_conversion: BooleanConversion = .normal,
    integer_conversion: IntegerConversion = .normal,
    number_conversion: NumberConversion = .normal,
};

pub const CustomConverterOptions = struct {
    may_invoke_js: bool = false,
    infallible: bool = false,
    realm_free: bool = false,
    audit_reason: ?[]const u8 = null,
};

pub const ConverterKind = enum {
    custom,
    brand_cast,
    json_stringify,
    headers_init,
    property_key,
};

pub const BrandCastFailure = enum {
    reject,
    absent,
    assert,
};

pub const BrandCastInput = enum {
    boundary,
    engine_value,
    optional_engine_value,
};

pub const BrandCastOptions = struct {
    name: ?[]const u8 = null,
    failure: BrandCastFailure = .reject,
    input: BrandCastInput = .boundary,
};

pub const ConvertedOptions = struct {
    name: ?[]const u8 = null,
};

pub const HeadersInitMode = enum {
    share,
    clone,
};

pub const ReceiverByteLengthConversion = struct {
    mode: enum { to_length, integer },
    bound: enum { live, at_preparation } = .live,
    range_error: enum { operators, prose } = .operators,

    pub const to_length: @This() = .{ .mode = .to_length };
    pub const integer: @This() = .{ .mode = .integer };
};

pub const ArgumentOwnership = enum {
    borrowed,
    transfer,
};

pub const ArgumentSelection = struct {
    source: []const u8,
    cases: []const struct { value: []const u8, member: []const u8 },
};

pub const ArgumentProjectionSource = union(enum) {
    argument: []const u8,
    this_value,
    cached_slot: []const u8,
};

pub const ArgumentOptions = struct {
    presence: Presence = .required,
    missing: Missing = .undefined,
    default_value: ?DefaultValue = null,
    boolean_conversion: BooleanConversion = .normal,
    integer_conversion: IntegerConversion = .normal,
    number_conversion: NumberConversion = .normal,
    deferred_reason: ?[]const u8 = null,
    rest: bool = false,
    ownership: ArgumentOwnership = .borrowed,
    source: ?ArgumentProjectionSource = null,
    selection: ?ArgumentSelection = null,
};

pub const OverloadCaseOptions = struct {
    discriminants: ?[]const usize = null,
};

pub const OverloadOptions = struct {
    ordered: bool = false,
    accept_extra_arguments: bool = false,
    /// Select by arity after earlier cases; the final case still runs its declared conversions.
    fallback_case: ?[]const u8 = null,
};

pub const Exposure = union(enum) {
    never,
    always,
    target: []const u8,
    os: []const u8,
    not_os: []const u8,
    feature: []const u8,
};

pub const DomainErrorMapping = enum {
    error_object,
    dom_exception,
    builtin_error,
    system_error,
    system_error_with_info,
    class_instance,
    aggregate_error,
};

pub const ErrorClass = enum {
    generic_error,
    type_error,
    range_error,
    syntax_error,
    uri_error,
};

pub const ErrorMessage = union(enum) {
    literal: []const u8,
    payload,
};

pub const DomainErrorOptions = struct {
    class: ErrorClass,
    code: ?[]const u8 = null,
    message: ErrorMessage,
    /// Overrides the error's `name` property after construction, for shapes
    /// like TODOError that are not a standard error class.
    name_override: ?[]const u8 = null,
    name_override_enumerable: bool = true,
};

pub const BuiltinErrorOptions = struct {
    group: []const u8,
    function: []const u8,
};

pub const AggregateErrorOptions = struct {
    message: []const u8,
};

pub const SystemErrorOptions = struct {
    name_override: ?[]const u8 = null,
    name_override_enumerable: bool = false,
    metadata_configurable: bool = false,
};

pub const DOMExceptionName = enum {
    AbortError,
    DataError,
    InvalidAccessError,
    InvalidCharacterError,
    InvalidStateError,
    NotSupportedError,
    OperationError,
    SyntaxError,
    UnknownError,
};

pub const CompletionRetention = enum {
    strong,
    weak,
    pending_activity,
};

pub const CompletionDrop = union(enum) {
    cancel,
    reject: []const u8,
    leave_pending,
};

pub const CompletionDelivery = enum {
    wire,
    vm,
};

pub const CompletionSettlement = enum {
    queued,
    ready_at_return,
};

pub const MissingRequiredArguments = union(enum) {
    profile_default,
    arity_error,
    convert_undefined,
    failure: ConversionFailure,
};

pub const RealmFunctionIdentity = struct {
    name: []const u8,
    visibility: SurfaceFunctionVisibility = .public,
};

pub const ConversionStep = union(enum) {
    prepare: []const u8,
    convert: []const u8,
};

pub const EngineThrows = enum {
    never,
    js_exception,
    out_of_memory,
};

pub const EngineRealm = enum {
    current,
    none,
};

pub const EngineAffinity = enum {
    vm,
    any,
};

pub const EngineResultSource = enum { native, javascript };

pub const EngineShimOptions = struct {
    throws: EngineThrows,
    realm: EngineRealm,
    affinity: EngineAffinity,
    check_traps: bool = true,
    profile: Profile = .exact,
    result_source: EngineResultSource = .native,

    pub const current_realm_throwing: EngineShimOptions = .{ .throws = .js_exception, .realm = .current, .affinity = .vm };
    pub const current_realm_node_throwing: EngineShimOptions = .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .profile = .node };
    pub const current_realm_nonthrowing: EngineShimOptions = .{ .throws = .never, .realm = .current, .affinity = .vm };
    pub const current_realm_unchecked: EngineShimOptions = .{ .throws = .never, .realm = .current, .affinity = .vm, .check_traps = false };
    pub const vm_thread_nonthrowing: EngineShimOptions = .{ .throws = .never, .realm = .none, .affinity = .vm, .check_traps = false };
    pub const vm_thread_allocating: EngineShimOptions = .{ .throws = .out_of_memory, .realm = .none, .affinity = .vm, .check_traps = false };
    pub const realm_independent: EngineShimOptions = .{ .throws = .never, .realm = .none, .affinity = .any, .check_traps = false };
    pub const realm_independent_allocating: EngineShimOptions = .{ .throws = .out_of_memory, .realm = .none, .affinity = .any, .check_traps = false };
};

pub const NativeThrows = enum { never, out_of_memory, js_exception };

pub const ClassOwnership = enum {
    shared,
    unique,
};

pub const ClassRepresentation = enum {
    native,
    engine,
    plain,
};

pub const MemoryUsageAffinity = enum {
    any,
    vm,
};

pub const InstancePropertyInitializer = union(enum) {
    constant: DefaultValue,
    argument: []const u8,
    argument_field: struct {
        argument: []const u8,
        field: []const u8,
    },
    argument_bigint_quotient: struct {
        argument: []const u8,
        divisor: u64,
    },
};

pub const InvalidThisBehavior = union(enum) {
    throw,
    no_op,
    failure: ConversionFailure,
};

pub const GetterAssignment = enum { reject, ignore };

pub const WrapperIdentity = enum {
    fresh,
    per_realm,
};

pub const ReferenceThread = enum {
    vm,
    any,
};

pub const LastRelease = union(enum) {
    deferred_vm,
    sweep: []const u8,

    pub fn isSweep(self: LastRelease) bool {
        return std.meta.activeTag(self) == .sweep;
    }

    pub fn isDeferredVM(self: LastRelease) bool {
        return std.meta.activeTag(self) == .deferred_vm;
    }

    pub fn eql(self: LastRelease, other: LastRelease) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .deferred_vm => true,
            .sweep => |reason| std.mem.eql(u8, reason, other.sweep),
        };
    }
};

pub const ClassPrototypeBase = enum {
    object,
    function,
    iterator,
    async_iterator,
};

pub const EngineCellKind = enum {
    object,
    event,
    dom_wrapper,
    as_json,
};

pub const EngineParentPrototype = enum {
    object,
    iterator,
    error_object,
};

pub const EngineParentConstructor = enum {
    function,
};

pub const EngineParentOptions = struct {
    cpp_class: CppType,
    cpp_impl: []const u8,
    header: []const u8,
    prototype: EngineParentPrototype,
    constructor: EngineParentConstructor,
    cell_kind: EngineCellKind = .object,
};

pub const EngineGlobalScopeProjection = struct {
    tag: []const u8,
    /// Native subtype whose globalObject() returns its existing JSGlobalObject, or null after detachment.
    cpp_type: []const u8,
};

pub const EngineNativeOptions = struct {
    /// C++ impl type, e.g. "Bun::WebViewEventTarget".
    cpp_type: []const u8,
    /// Header declaring it.
    header: []const u8,
    /// Native enum getter used to select the schema-declared derived wrapper.
    wrapper_discriminator: ?[]const u8 = null,
    /// Enum constant identifying this class in native wrapper dispatch.
    wrapper_tag: ?[]const u8 = null,
    wrapper_global_scope: ?EngineGlobalScopeProjection = null,
};

pub const ClassMemberKind = enum {
    constructor,
    method,
    getter,
    setter,
    static_method,
    static_getter,
    static_setter,

    pub fn isStatic(kind: ClassMemberKind) bool {
        return switch (kind) {
            .static_method, .static_getter, .static_setter => true,
            .constructor, .method, .getter, .setter => false,
        };
    }

    pub fn isGetter(kind: ClassMemberKind) bool {
        return switch (kind) {
            .getter, .static_getter => true,
            .constructor, .method, .setter, .static_method, .static_setter => false,
        };
    }

    pub fn isSetter(kind: ClassMemberKind) bool {
        return switch (kind) {
            .setter, .static_setter => true,
            .constructor, .method, .getter, .static_method, .static_getter => false,
        };
    }
};

pub const PropertySymbol = enum {
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
    inspect_custom,
};

pub const ClassMemberAliasKey = union(enum) {
    name: []const u8,
    symbol: PropertySymbol,
};

pub const ClassMemberAliasOptions = struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
};

pub const ClassMemberAlias = struct {
    key: ClassMemberAliasKey,
    options: ClassMemberAliasOptions,
};

pub const EngineTracing = enum {
    inherited,
    additional_children,
};

pub const ClassLifecycle = struct {
    wrapper_created: bool = false,
};

pub const IllegalConstructorErrors = struct {
    call: ConversionFailure,
    construct: ConversionFailure,
};

pub const CachedSlotOptions = struct {
    writable: bool = false,
    exposed: bool = true,
    storage: enum { instance, constructor } = .instance,
    private_symbol: ?[]const u8 = null,
};

pub const DataPropertyStorage = enum {
    prototype,
    constructor,
};

pub const DataPropertyOptions = struct {
    storage: DataPropertyStorage = .prototype,
    symbol: ?PropertySymbol = null,
    writable: bool = false,
    enumerable: bool = true,
    configurable: bool = true,
};

pub const StructuredCloneUnsupportedContext = enum { reject, empty_object };

pub const StructuredCloneOptions = struct {
    tag: u8,
    shared: ?SharedStructuredCloneOptions = null,
    transferable: bool = false,
    storable: bool = false,
    unsupported_context: StructuredCloneUnsupportedContext = .reject,
    serialize_thread: ReferenceThread = .vm,
    deserialize_thread: ReferenceThread = .vm,
};

pub const SharedStructuredCloneOptions = struct {
    state: []const u8,
    reason: []const u8,
};

pub const SurfacePropertyAttributes = struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
};

pub const SurfacePropertyKey = union(enum) {
    name: []const u8,
    symbol: PropertySymbol,
    builtin_name: []const u8,
    engine_name: []const u8,
    engine_builtin_name: []const u8,
};

pub const SurfaceMemberAlias = struct {
    key: SurfacePropertyKey,
    attributes: SurfacePropertyAttributes = .{},
};

pub const SurfaceMemberKind = enum {
    function,
    lazy_declaration,
    object_value,
    callable_value,
    self,
    accessor,
    constant,
    empty_collection,
    lazy_owner,
};

pub const SurfaceLazyDeclaration = enum {
    function,
    native,
    class,
};

pub const SurfaceAccessor = enum {
    builtin,
    function,
};

pub const SurfaceConstant = union(enum) {
    string: []const u8,
    external_string: []const u8,
    registered_symbol: []const u8,
    undefined,
    integer: i64,
    external_number: []const u8,
    external_boolean: []const u8,
    boolean: bool,
};

pub const SurfaceEmptyCollection = enum {
    array,
    set,
};

pub const SurfaceLazyOwner = enum {
    cell,
    class_structure,
};

pub const SurfaceMemberPlacement = enum {
    inferred,
    direct,
    global_static,
};

pub const SurfaceFunctionVisibility = enum {
    public,
    internal,
};

pub const SurfaceMemberOptions = struct {
    attributes: SurfacePropertyAttributes = .{ .configurable = false },
    constructable: bool = false,
    exposure: Exposure = .always,
    aliases: []const SurfaceMemberAlias = &.{},
    placement: SurfaceMemberPlacement = .inferred,
    function_visibility: SurfaceFunctionVisibility = .public,
    function_name: ?[]const u8 = null,
    header: []const u8 = "",
    native_accessor: ?[]const u8 = null,
};

pub const SurfaceInstallation = enum {
    static_lookup,
    reified,
    direct,
};

pub const ObjectSurfacePrototype = enum {
    ordinary,
    null,
};

pub const ObjectSurfaceIntegrity = enum {
    extensible,
    frozen,
};

pub const ObjectSurfaceOptions = struct {
    exposure: Exposure = .always,
    installation: SurfaceInstallation = .static_lookup,
    cpp_class: ?[]const u8 = null,
    prototype: ObjectSurfacePrototype = .ordinary,
    integrity: ObjectSurfaceIntegrity = .extensible,
};

pub const NativeModuleDefaultPolicy = enum {
    namespace,
    declaration,
};

pub const NativeModuleDefaultSurface = enum {
    none,
    install,
};

pub const FocusedEngineIntegrationKind = enum {
    callable_object,
    engine_value_operations,
    realm_control,
    vm_execution,
    script_evaluation,
    error_reporting,
    value_inspection,
    value_comparison,
    intrinsic_lazy_property,
    job_queue,
    runtime_keyed_property_namespace,
    macro_execution,
    literal_materialization,
};

pub const FocusedEngineIntegrationOptions = struct {
    kind: FocusedEngineIntegrationKind,
    backend: enum { cpp, zig } = .cpp,
    header: ?[]const u8 = null,
    implementation: []const u8,
    behavior: []const u8,
};

pub const StringCoercionInput = enum { any, string_or_boxed, object_only };

pub const StringTypeErrorFormat = enum { profile, property_typeof };

pub const BufferTransferPolicy = enum { reject, copy };
