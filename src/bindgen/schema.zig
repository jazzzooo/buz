//! The binding schema language. Combinators build plain declarative values;
//! every schema rule is checked by normalization in the binding generator.
const std = @import("std");
const ir = @import("bindgen_ir");
const vocabulary = ir.vocabulary;

// ─── semantic types ───

/// A semantic type. Composite payloads live behind pointers so a type is a
/// small value; identity is the complete structure.
pub const Type = union(TypeKind) {
    void,
    boolean,
    i8: Integer,
    u8: Integer,
    i16: Integer,
    u16: Integer,
    i32: Integer,
    u32: Integer,
    i64: Integer,
    u64: Integer,
    usize: Integer,
    f64,
    any: AnyPurpose,
    discarded: Discarded,
    lazy: *const Type,
    converted: *const Converted,
    dom_string: String,
    usv_string: String,
    byte_string: String,
    utf8_string,
    node_path: NodePathOptions,
    buffer: *const Buffer,
    native_slice: NativeSlice,
    callback: *const Callback,
    optional: Optional,
    enumeration: *const Enumeration,
    dictionary: *const Dictionary,
    union_type: *const Union,
    sequence: *const Sequence,
    record: *const Record,
    nominal_handle: *const NominalHandle,
    class_ref: ClassRef,
    external_ref: *const ExternalRef,
    branded_value: *const BrandedValue,
    engine_value,
    native_instance,

    pub fn kind(t: Type) TypeKind {
        return std.meta.activeTag(t);
    }
};

pub const Integer = struct {
    /// Null keeps the default Number representation without declaring it.
    representation: ?IntegerRepresentation = null,
};

pub const String = struct {
    thread_safe: bool = false,
    conversion: StringConversion = .profile,
    nullish_failure: ?ConversionFailure = null,
    empty_rejection: ?StringEmptyRejection = null,
    coercion_input: StringCoercionInput = .any,
    type_error_format: StringTypeErrorFormat = .profile,
    input_failure: ?ConversionFailure = null,
    strict_failure: ?ConversionFailure = null,
};

pub const Discarded = struct {
    match_type: *const Type,
    match: DiscardedMatch,
    purpose: DiscardPurpose,
};

pub const Converter = struct {
    kind: ConverterKind,
    name: []const u8,
    options: CustomConverterOptions,
    brand_cast: ?BrandCast = null,
};

pub const BrandCast = struct {
    match: *const Type,
    failure: BrandCastFailure,
    input: BrandCastInput,
};

pub const Converted = struct {
    native: Type,
    match: Type,
    converter: Converter,
    options: ConvertedOptions,
};

pub const Buffer = struct {
    mode: BufferMode,
    source: BufferSource,
    access: BufferAccess,
    options: BufferOptions,
};

pub const NativeSlice = struct {
    element: NativeSliceElement,
    access: BufferAccess,
};

pub const Callback = struct {
    name: []const u8,
    args: []const Argument,
    result: Type,
    options: CallbackOptions,
};

pub const Optional = struct {
    child: *const Type,
    mode: OptionalMode,
};

pub const EnumerationValue = struct {
    name: []const u8,
    value: []const u8,
    options: EnumerationValueOptions,
};

pub const Enumeration = struct {
    name: []const u8,
    values: []const EnumerationValue,
    options: EnumerationOptions,
};

pub const DictionaryField = struct {
    name: []const u8,
    type: Type,
    options: DictionaryFieldOptions,

    pub fn propertyName(field: DictionaryField) []const u8 {
        return field.options.js_name orelse field.name;
    }
};

pub const DictionaryOptions = struct {
    user_facing_name: ?[]const u8 = null,
    cpp_name: ?[]const u8 = null,
    object_profile: ?Profile = null,
    object_error_profile: ?Profile = null,
    object_error_kind: DictionaryObjectError = .type,
    object_error: ?ConversionFailure = null,
    node_allow_array: bool = false,
    node_allow_callable: bool = false,
    input_snapshot: DictionaryInputSnapshot = .none,
    property_lookup: DictionaryPropertyLookup = .ordinary,
    field_reads: DictionaryFieldReads = .interleaved,
    finish_fields: []const []const u8 = &.{},
    result_prototype: ResultObjectPrototype = .ordinary,
    result_to_string_tag: ?[]const u8 = null,
    result_class: ?BoundClass = null,
};

pub const Dictionary = struct {
    name: []const u8,
    fields: []const DictionaryField,
    options: DictionaryOptions,
};

pub const UnionMember = struct {
    name: []const u8,
    type: Type,
    options: UnionMemberOptions,
};

pub const UnionInputTag = struct {
    tag_property: []const u8,
    value_property: ?[]const u8 = null,
    selector: ?Type = null,
    string_shorthand: bool = false,
    coerce_tag: bool = false,
};

pub const UnionOptions = struct {
    ordered: bool = false,
    fallback_member: ?[]const u8 = null,
    fallback_on_conversion_error: bool = false,
    node_error: ?NodeUnionError = null,
    no_match_error: ?ConversionFailure = null,
    cpp_name: ?[]const u8 = null,
    input_tag: ?UnionInputTag = null,
};

pub const Union = struct {
    name: []const u8,
    members: []const UnionMember,
    options: UnionOptions,
};

pub const Sequence = struct {
    child: Type,
    options: SequenceOptions,
};

pub const Record = struct {
    key: Type,
    value: Type,
    options: RecordOptions,
};

pub const NominalHandle = struct {
    name: []const u8,
    options: NominalHandleOptions,
};

pub const ClassName = struct {
    module: []const u8,
    class: []const u8,
};

pub const ClassRef = struct {
    /// Null names the class that declares the member.
    target: ?ClassName,
    options: ClassReferenceOptions = .{},
};

pub const ExternalRefOptions = struct {
    cpp_type: []const u8,
    cpp_idl: []const u8,
    cpp_declaration_header: []const u8,
    cpp_conversion_header: []const u8,
    cpp_match: CppBrandMatcher,
    zig_type: []const u8,
    brand: ?Brand = null,
};

pub const ExternalRef = struct {
    name: []const u8,
    options: ExternalRefOptions,
};

pub const BrandMatcher = union(enum) {
    instance_class: InstanceClass,
    value: CppBrandMatcher,
    realm: CppRealmBrandMatcher,
    dynamic_cast: CppDynamicCastMatcher,
};

pub const InstanceClass = struct {
    class: ClassName,
    match: ClassValueMatch,
};

pub const Brand = struct {
    name: []const u8,
    matcher: BrandMatcher,
    typescript_type: []const u8,
    promise_value: ?*const Type = null,
    constructor_class: ?ClassName = null,
};

pub const PromiseReactionContext = struct {
    name: []const u8,
    tag: []const u8,
    owner_reference: Type,
};

pub const BrandedValue = struct {
    brand: Brand,
    options: BrandedValueDefaults,
    promise_reaction: ?PromiseReactionContext = null,
};

// ─── declarations ───

pub const Argument = struct {
    name: []const u8,
    type: Type,
    options: ArgumentOptions,
};

pub const OverloadCase = struct {
    name: []const u8,
    args: []const Argument,
    options: OverloadCaseOptions,
};

pub const Overloads = struct {
    cases: []const OverloadCase,
    options: OverloadOptions,
};

pub const Arguments = union(enum) {
    list: []const Argument,
    overloads: Overloads,

    pub fn listOrEmpty(arguments: Arguments) []const Argument {
        return switch (arguments) {
            .list => |list| list,
            .overloads => &.{},
        };
    }
};

pub const DomainErrorDeclaration = union(DomainErrorMapping) {
    error_object: DomainErrorOptions,
    dom_exception: struct { exception: DOMExceptionName, message: ErrorMessage },
    builtin_error: BuiltinErrorOptions,
    system_error: SystemErrorOptions,
    system_error_with_info,
    class_instance,
    aggregate_error: AggregateErrorOptions,
};

pub const DomainError = struct {
    name: []const u8,
    payload: Type,
    declaration: DomainErrorDeclaration,
};

pub const DomainErrors = struct {
    errors: []const DomainError = &.{},
};

pub const CallbackData = struct {
    zig_type: []const u8,
};

pub const CompletionOptions = struct {
    retention: CompletionRetention = .strong,
    sender_drop: CompletionDrop = .leave_pending,
    delivery: CompletionDelivery = .wire,
    error_delivery: CompletionDelivery = .wire,
    settlement: CompletionSettlement = .queued,
    materializer: ?BoundEngineShim = null,
};

pub const FunctionOptions = struct {
    realm_identity: ?RealmFunctionIdentity = null,
    backend: Backend = .zig,
    builtin: ?[]const u8 = null,
    length: ?u16 = null,
    profile: Profile = .webidl,
    missing_required_arguments: MissingRequiredArguments = .profile_default,
    exposure: Exposure = .always,
    errors: DomainErrors = .{},
    completion: ?CompletionOptions = null,
    this_value_type: ?Type = null,
    new_target_type: ?Type = null,
    callee_value_type: ?Type = null,
    callback_data: ?CallbackData = null,
    caller_source_location: bool = false,
    promise_reaction_handler: bool = false,
    type_predicate: ?Type = null,
    conversion_program: ?[]const ConversionStep = null,
};

pub const Function = struct {
    name: []const u8,
    arguments: Arguments,
    result: Type,
    options: FunctionOptions,
};

pub const EngineShim = struct {
    name: []const u8,
    args: []const Argument,
    result: Type,
    options: EngineShimOptions,
};

pub const NativeExportOptions = struct {
    throws: NativeThrows = .never,
    realm: EngineRealm = .none,
    non_returning: bool = false,
    standalone_header: ?[]const u8 = null,
    exposure: Exposure = .always,
    errors: DomainErrors = .{},

    pub const current_realm_throwing: NativeExportOptions = .{ .throws = .js_exception, .realm = .current };
    pub const current_realm_nonthrowing: NativeExportOptions = .{ .throws = .never, .realm = .current };
    pub const allocating: NativeExportOptions = .{ .throws = .out_of_memory };
};

pub const NativeExport = struct {
    name: []const u8,
    args: []const Argument,
    result: Type,
    options: NativeExportOptions,
};

pub const ClassMemberOptions = struct {
    backend: ?Backend = null,
    builtin: ?[]const u8 = null,
    length: ?u16 = null,
    profile: ?Profile = null,
    missing_required_arguments: MissingRequiredArguments = .profile_default,
    exposure: Exposure = .always,
    errors: DomainErrors = .{},
    completion: ?CompletionOptions = null,
    conversion_program: ?[]const ConversionStep = null,
    implementation: ?[]const u8 = null,
    native_reference: bool = false,
    symbol: ?PropertySymbol = null,
    this_value_type: ?Type = null,
    new_target_type: ?Type = null,
    callee_value_type: ?Type = null,
    caller_source_location: bool = false,
    deferred_reason: ?[]const u8 = null,
    typescript_async: bool = false,
    invalid_this: InvalidThisBehavior = .throw,
    getter_assignment: GetterAssignment = .reject,
    cache: ?[]const u8 = null,
    cache_on_construction: bool = false,
    writable: bool = false,
    enumerable: bool = true,
    configurable: bool = false,
    private_symbol: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    aliases: []const ClassMemberAlias = &.{},
    illegal: bool = false,
    unforgeable: bool = false,
};

pub const ClassMember = struct {
    name: []const u8,
    kind: ClassMemberKind,
    arguments: Arguments,
    result: Type,
    options: ClassMemberOptions,
};

pub const CachedSlot = struct {
    name: []const u8,
    type: Type,
    options: CachedSlotOptions,
};

pub const DataProperty = struct {
    name: []const u8,
    key: ClassMemberAliasKey,
    value: DefaultValue,
    options: DataPropertyOptions,
};

pub const InstancePropertyOptions = struct {
    value: Type,
    /// Key the property by this private symbol instead of the name.
    private_symbol: ?[]const u8 = null,
    initializer: ?InstancePropertyInitializer = null,
};

pub const InstanceProperty = struct {
    name: []const u8,
    options: InstancePropertyOptions,
};

pub const ClassParent = union(enum) {
    class: *const Class,
    engine: EngineParentOptions,
};

pub const ClassOptions = struct {
    constructor_call_error: ?ConversionFailure = null,
    illegal_constructor_errors: ?IllegalConstructorErrors = null,
    backend: Backend = .zig,
    profile: Profile = .webidl,
    exposure: Exposure = .always,
    display_name: ?[]const u8 = null,
    brand: ?Brand = null,
    representation: ClassRepresentation = .native,
    engine_intrinsic: ?[]const u8 = null,
    plain_reason: ?[]const u8 = null,
    ownership: ClassOwnership = .shared,
    identity: WrapperIdentity = .fresh,
    fresh_identity_reason: ?[]const u8 = null,
    reference_thread: ReferenceThread = .vm,
    last_release: LastRelease = .deferred_vm,
    parent: ?ClassParent = null,
    upcast: ?[]const u8 = null,
    engine_native: ?EngineNativeOptions = null,
    memory_usage: ?MemoryUsageAffinity = null,
    has_pending_activity: bool = false,
    lifecycle: ClassLifecycle = .{},
    engine_tracing: EngineTracing = .inherited,
    immutable_prototype: bool = false,
    prototype_base: ClassPrototypeBase = .object,
    structured_clone: ?StructuredCloneOptions = null,
    constructor_call: ?ClassMember = null,
    final: bool = true,
};

pub const Class = struct {
    name: []const u8,
    constructor: ClassMember,
    members: []const ClassMember,
    slots: []const CachedSlot,
    properties: []const DataProperty,
    instance_properties: []const InstanceProperty,
    options: ClassOptions,
};

// ─── surfaces ───

pub const LazyDeclaration = union(SurfaceLazyDeclaration) {
    function: BoundFunction,
    native: BoundNativeExport,
    class: BoundClass,
};

pub const SurfaceFunctionAccessor = struct {
    getter: BoundFunction,
    setter: ?BoundFunction,
};

pub const SurfaceAccessorValue = union(SurfaceAccessor) {
    builtin: BoundFunction,
    function: SurfaceFunctionAccessor,
};

pub const SurfaceCallableValue = struct {
    declaration: BoundFunction,
    surface: *const ObjectSurface,
};

pub const SurfaceEmptyCollectionValue = struct {
    collection: SurfaceEmptyCollection,
    element: Type,
};

pub const SurfaceLazyOwnerValue = struct {
    owner: SurfaceLazyOwner,
    member: []const u8,
};

pub const SurfaceMemberValue = union(SurfaceMemberKind) {
    function: BoundFunction,
    lazy_declaration: LazyDeclaration,
    object_value: *const ObjectSurface,
    callable_value: SurfaceCallableValue,
    self,
    accessor: SurfaceAccessorValue,
    constant: SurfaceConstant,
    empty_collection: SurfaceEmptyCollectionValue,
    lazy_owner: SurfaceLazyOwnerValue,
};

pub const SurfaceMember = struct {
    key: SurfacePropertyKey,
    value: SurfaceMemberValue,
    options: SurfaceMemberOptions,

    pub fn propertyName(member: SurfaceMember) []const u8 {
        return switch (member.key) {
            .name, .builtin_name, .engine_name, .engine_builtin_name => |name| name,
            .symbol => |symbol| @tagName(symbol),
        };
    }
};

pub const ObjectSurface = struct {
    name: []const u8,
    members: []const SurfaceMember,
    options: ObjectSurfaceOptions,
};

pub const NativeModuleDefault = union(NativeModuleDefaultPolicy) {
    namespace,
    declaration: NativeModuleDeclaration,
};

pub const NativeModuleDeclaration = union(enum) {
    function: BoundFunction,
    class: BoundClass,
};

pub const NativeModuleOptions = struct {
    default: NativeModuleDefault = .namespace,
    exposure: Exposure = .always,
    default_surface: NativeModuleDefaultSurface = .none,
    attach_default_to_default: bool = false,
    default_attributes: SurfacePropertyAttributes = .{},
    default_name: ?[]const u8 = null,
};

pub const NativeModuleExports = union(enum) {
    members: []const SurfaceMember,
    surface: *const ObjectSurface,
};

pub const NativeModule = struct {
    name: []const u8,
    specifier: []const u8,
    exports: NativeModuleExports,
    options: NativeModuleOptions,
};

pub const Surface = union(enum) {
    native_module: NativeModule,
    object: ObjectSurface,
};

pub const FocusedEngineIntegration = struct {
    name: []const u8,
    options: FocusedEngineIntegrationOptions,
};

// ─── modules and bound references ───

pub const BoundFunction = struct {
    module: []const u8,
    function: *const Function,
};

pub const BoundClass = struct {
    module: []const u8,
    class: *const Class,

    pub fn name(bound: BoundClass) ClassName {
        return .{ .module = bound.module, .class = bound.class.name };
    }
};

pub const BoundEngineShim = struct {
    module: []const u8,
    shim: *const EngineShim,
};

pub const BoundNativeExport = struct {
    module: []const u8,
    native_export: *const NativeExport,
};

pub const Module = struct {
    name: []const u8,
    functions: []const Function,
    classes: []const Class,
    /// The instance value type of each class, parallel to `classes`.
    class_values: []const Type,
    engine_shims: []const EngineShim,
    native_exports: []const NativeExport,
    surfaces: []const Surface,
    focused_integrations: []const FocusedEngineIntegration = &.{},

    pub fn function(comptime self: Module, comptime function_name: []const u8) BoundFunction {
        @setEvalBranchQuota(schema_eval_branch_quota);
        for (self.functions) |*candidate| {
            if (std.mem.eql(u8, candidate.name, function_name)) return .{ .module = self.name, .function = candidate };
        }
        @compileError("binding schema " ++ self.name ++ " has no function named " ++ function_name);
    }

    pub fn class(comptime self: Module, comptime class_name: []const u8) BoundClass {
        @setEvalBranchQuota(schema_eval_branch_quota);
        for (self.classes) |*candidate| {
            if (std.mem.eql(u8, candidate.name, class_name)) return .{ .module = self.name, .class = candidate };
        }
        @compileError("binding schema " ++ self.name ++ " has no class named " ++ class_name);
    }

    pub fn engineShim(comptime self: Module, comptime shim_name: []const u8) BoundEngineShim {
        @setEvalBranchQuota(schema_eval_branch_quota);
        for (self.engine_shims) |*candidate| {
            if (std.mem.eql(u8, candidate.name, shim_name)) return .{ .module = self.name, .shim = candidate };
        }
        @compileError("binding schema " ++ self.name ++ " has no engine shim named " ++ shim_name);
    }

    pub fn nativeExport(comptime self: Module, comptime export_name: []const u8) BoundNativeExport {
        @setEvalBranchQuota(schema_eval_branch_quota);
        for (self.native_exports) |*candidate| {
            if (std.mem.eql(u8, candidate.name, export_name)) return .{ .module = self.name, .native_export = candidate };
        }
        @compileError("binding schema " ++ self.name ++ " has no native export named " ++ export_name);
    }
};

/// Schema evaluation is one comptime declaration per binding surface, so the
/// combinators raise its branch quota rather than every schema module.
const schema_eval_branch_quota = 10_000_000;

fn sliceOf(comptime T: type, comptime items: anytype) []const T {
    @setEvalBranchQuota(schema_eval_branch_quota);
    if (@typeInfo(@TypeOf(items)) == .pointer) return items;
    const array: [items.len]T = items;
    return &array;
}

fn pointerTo(comptime value: anytype) *const @TypeOf(value) {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return &value;
}

// ─── type combinators ───

pub const none: Type = .void;
pub const boolean: Type = .boolean;
pub const int8: Type = .{ .i8 = .{} };
pub const uint8: Type = .{ .u8 = .{} };
pub const int16: Type = .{ .i16 = .{} };
pub const uint16: Type = .{ .u16 = .{} };
pub const int32: Type = .{ .i32 = .{} };
pub const uint32: Type = .{ .u32 = .{} };
pub const int64: Type = .{ .i64 = .{} };
pub const uint64: Type = .{ .u64 = .{} };
pub const size: Type = .{ .usize = .{} };
pub const double: Type = .f64;
pub const any: Type = .{ .any = .pass_through };
pub const retained_any: Type = .{ .any = .retention };
pub const invocation_any: Type = .{ .any = .invocation };
pub const engine_value: Type = .engine_value;
pub const utf8_string: Type = .utf8_string;
pub const native_instance: Type = .native_instance;
pub const this_class_ref: Type = .{ .class_ref = .{ .target = null } };

/// Declares the JavaScript representation of an integer type.
pub fn integerRepresentation(comptime integer: Type, comptime representation: IntegerRepresentation) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    var result = integer;
    switch (result) {
        inline .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => |*payload| {
            if (payload.representation != null)
                @compileError("an integer semantic type can declare its JavaScript representation only once");
            payload.representation = representation;
        },
        else => @compileError("integerRepresentation requires an integer semantic type"),
    }
    return result;
}

fn discardedType(comptime match_type: Type, comptime match: DiscardedMatch, comptime purpose: DiscardPurpose) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .discarded = .{ .match_type = pointerTo(match_type), .match = match, .purpose = purpose } };
}

pub const discarded = discardedType(any, .semantic_type, .contextual);
pub const null_literal = discardedType(any, .null_literal, .classification);
pub const undefined_literal = discardedType(any, .undefined_literal, .classification);
pub const false_literal = discardedType(any, .false_literal, .classification);

pub fn numberLiteral(comptime value: f64) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return discardedType(any, .{ .number_literal = value }, .classification);
}

pub fn discard(comptime match_type: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return discardedType(match_type, .semantic_type, .contextual);
}

pub fn discardAny(comptime purpose: DiscardPurpose) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return discardWithPurpose(any, purpose);
}

pub fn discardWithPurpose(comptime match_type: Type, comptime purpose: DiscardPurpose) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (purpose) {
        .classification, .presence, .ignored => discardedType(match_type, .semantic_type, purpose),
        .contextual, .count => @compileError(
            "discardAny requires classification, presence, or ignored; union classification and rest counting derive from their structural context",
        ),
    };
}

fn stringType(comptime kind: TypeKind, comptime string: String) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (kind) {
        .dom_string => .{ .dom_string = string },
        .usv_string => .{ .usv_string = string },
        .byte_string => .{ .byte_string = string },
        else => unreachable,
    };
}

pub const dom_string: Type = .{ .dom_string = .{} };
pub const usv_string: Type = .{ .usv_string = .{} };
pub const byte_string: Type = .{ .byte_string = .{} };
pub const thread_safe_dom_string: Type = .{ .dom_string = .{ .thread_safe = true } };
pub const thread_safe_usv_string: Type = .{ .usv_string = .{ .thread_safe = true } };
pub const thread_safe_byte_string: Type = .{ .byte_string = .{ .thread_safe = true } };

fn stringPayload(comptime string_type: Type) String {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (string_type) {
        .dom_string, .usv_string, .byte_string => |string| string,
        else => @compileError("this combinator requires a DOMString, USVString, or ByteString type"),
    };
}

pub fn coerceString(comptime string_type: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return coerceStringWithOptions(string_type, .{});
}

/// Accepts only primitive strings, using `failure` for every non-string input.
/// String kind, thread safety, and empty-string constraints are preserved;
/// normalization rejects coercion input restrictions and competing failure policies.
pub fn strictString(comptime string_type: Type, comptime failure: ConversionFailure) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    var string = stringPayload(string_type);
    string.strict_failure = failure;
    return stringType(string_type.kind(), string);
}

pub fn nonEmptyString(comptime string_type: Type, comptime rejection: StringEmptyRejection) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    var string = stringPayload(string_type);
    string.empty_rejection = rejection;
    return stringType(string_type.kind(), string);
}

pub fn coerceStringWithOptions(comptime string_type: Type, comptime options: StringCoercionOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    const base = stringPayload(string_type);
    return stringType(string_type.kind(), .{
        .thread_safe = base.thread_safe,
        .conversion = .coerce,
        .nullish_failure = options.nullish_failure,
        .empty_rejection = options.empty_rejection,
        .coercion_input = options.input,
        .type_error_format = options.type_error_format,
        .input_failure = options.input_failure,
        .strict_failure = base.strict_failure,
    });
}

pub fn nodePath(comptime options: NodePathOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .node_path = options };
}

pub const node_path = nodePath(.{});

fn bufferType(comptime mode: BufferMode, comptime source: BufferSource, comptime access: BufferAccess, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .buffer = pointerTo(Buffer{ .mode = mode, .source = source, .access = access, .options = options }) };
}

pub fn buffer(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferWithOptions(mode, .{});
}

pub fn bufferWithOptions(comptime mode: BufferMode, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .array_buffer_or_view, .read_only, options);
}

pub fn bufferResult(comptime representation: BufferResultRepresentation) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(.copy, .uint8_array, .read_only, .{ .result_representation = representation });
}

pub const node_buffer = bufferResult(.node_buffer);
pub const array_buffer_result = bufferResult(.array_buffer);
pub const uint8_array_result = bufferResult(.uint8_array);

pub fn bufferView(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferViewWithOptions(mode, .{});
}

pub fn bufferViewWithOptions(comptime mode: BufferMode, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .view, .read_only, options);
}

pub fn writableBufferView(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return writableBufferViewWithOptions(mode, .{});
}

pub fn writableBufferViewWithOptions(comptime mode: BufferMode, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .view, .read_write, options);
}

pub fn writableBuffer(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return writableBufferWithOptions(mode, .{});
}

pub fn writableBufferWithOptions(comptime mode: BufferMode, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .array_buffer_or_view, .read_write, options);
}

pub fn writableIntegerTypedArray(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .integer_typed_array, .read_write, .{});
}

pub fn writableUint8Array(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .uint8_array, .read_write, .{});
}

pub fn writableUint8ArrayWithOptions(comptime mode: BufferMode, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .uint8_array, .read_write, options);
}

pub fn uint8Array(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .uint8_array, .read_only, .{});
}

pub fn uint8ArrayWithOptions(comptime mode: BufferMode, comptime options: BufferOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .uint8_array, .read_only, options);
}

pub fn uint32Array(comptime mode: BufferMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return bufferType(mode, .uint32_array, .read_only, .{});
}

pub fn nativeSlice(comptime element: NativeSliceElement, comptime access: BufferAccess) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .native_slice = .{ .element = element, .access = access } };
}

pub fn lazy(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .lazy = pointerTo(child) };
}

pub fn cppBrand(comptime name: []const u8, comptime matcher: CppBrandMatcher, comptime ts_type: []const u8) Brand {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .matcher = .{ .value = matcher }, .typescript_type = ts_type };
}

pub fn cppRealmBrand(comptime name: []const u8, comptime matcher: CppRealmBrandMatcher, comptime ts_type: []const u8) Brand {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .matcher = .{ .realm = matcher }, .typescript_type = ts_type };
}

pub fn cppDynamicCastBrand(comptime name: []const u8, comptime matcher: CppDynamicCastMatcher, comptime ts_type: []const u8) Brand {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .matcher = .{ .dynamic_cast = matcher }, .typescript_type = ts_type };
}

pub fn nominalHandle(comptime name: []const u8, comptime options: NominalHandleOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .nominal_handle = pointerTo(NominalHandle{ .name = name, .options = options }) };
}

pub const external_bytes_owner = nominalHandle("ExternalBytesOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "BindByteOwnerHandle" } },
    .cpp_declarations = &.{.{ .structure = "BindByteOwnerHandle" }},
    .cpp_read_bytes = "externalBytesOwnerBytes",
    .ownership = .owned,
    .cpp_release = "releaseExternalBytesOwner",
    .access_thread = .any,
    .destroy_thread = .any,
    .zig_type = "bindgen.ExternalBytesOwnerHandle",
});

fn externalRef(comptime name: []const u8, comptime options: ExternalRefOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .external_ref = pointerTo(ExternalRef{ .name = name, .options = options }) };
}

pub fn brandedValueWithBrand(comptime brand: Brand, comptime options: BrandedValueDefaults) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .branded_value = pointerTo(BrandedValue{ .brand = brand, .options = options }) };
}

/// The brand of a branded value type.
pub fn brandOf(comptime branded: Type) Brand {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (branded) {
        .branded_value => |value| value.brand,
        else => @compileError("brandOf requires a branded value type"),
    };
}

pub fn promise(comptime value_type: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return brandedValueWithBrand(.{
        .name = "JSPromise",
        .matcher = .{ .value = .{
            .symbol = "Bun::Bindgen::TypePredicates::isPromise",
            .header = "BindgenTypePredicates.h",
        } },
        .typescript_type = "Promise<unknown>",
        .promise_value = pointerTo(value_type),
    }, .{});
}

pub fn classRef(comptime target: BoundClass) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classRefWithOptions(target, .{});
}

pub fn classRefWithOptions(comptime target: BoundClass, comptime options: ClassReferenceOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .class_ref = .{ .target = target.name(), .options = options } };
}

/// A class reference resolved by name, for sibling and recursive references
/// that cannot import an already-bound class declaration.
pub fn classRefByName(comptime module_name: []const u8, comptime class_name: []const u8) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classRefByNameWithOptions(module_name, class_name, .{});
}

pub fn classRefByNameWithOptions(comptime module_name: []const u8, comptime class_name: []const u8, comptime options: ClassReferenceOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .class_ref = .{ .target = .{ .module = module_name, .class = class_name }, .options = options } };
}

pub fn classValue(comptime target: BoundClass) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classValueNamed(target.name(), .{});
}

pub fn classValueWithOptions(comptime target: BoundClass, comptime options: ClassValueOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classValueNamed(target.name(), options);
}

pub fn classValueByName(comptime module_name: []const u8, comptime class_name: []const u8) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classValueNamed(.{ .module = module_name, .class = class_name }, .{});
}

pub fn classValueByNameWithOptions(comptime module_name: []const u8, comptime class_name: []const u8, comptime options: ClassValueOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classValueNamed(.{ .module = module_name, .class = class_name }, options);
}

fn classValueNamed(comptime target: ClassName, comptime options: ClassValueOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return brandedValueWithBrand(.{
        .name = target.module ++ "_" ++ target.class ++ (if (options.match == .instance) "Value" else "InitialStructureValue"),
        .matcher = .{ .instance_class = .{ .class = target, .match = options.match } },
        .typescript_type = target.class,
    }, .{ .node_requirement = target.class });
}

pub fn classConstructor(comptime target: BoundClass) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    const name = target.name();
    return brandedValueWithBrand(.{
        .name = name.module ++ name.class ++ "Constructor",
        .matcher = .{ .value = .{
            .symbol = "Bun::Bindgen::TypePredicates::isConstructor",
            .header = "BindgenTypePredicates.h",
        } },
        .typescript_type = "typeof " ++ name.class,
        .constructor_class = name,
    }, .{
        .error_kind = .type,
        .expectation = "a constructor",
        .node_requirement = "constructor",
    });
}

pub const blob_brand = cppBrand("Blob", .{
    .symbol = "WebCore::Blob::isInstance",
    .header = "blob.h",
}, "Blob");

pub const readable_stream_brand = cppBrand("ReadableStream", .{
    .symbol = "WebCore::isReadableStream",
    .header = "ReadableStream.h",
}, "ReadableStream");

pub const writable_stream_brand = cppBrand("WritableStream", .{
    .symbol = "Bun::Bindgen::Custom::bunBindgenIsWritableStream",
    .header = "BindgenCustom.h",
}, "WritableStream");

pub const transform_stream_brand = cppBrand("TransformStream", .{
    .symbol = "Bun::Bindgen::Custom::bunBindgenIsTransformStream",
    .header = "BindgenCustom.h",
}, "TransformStream");

pub const array_buffer_brand = cppBrand("ArrayBuffer", .{
    .symbol = "Bun::Bindgen::Custom::bunBindgenIsArrayBuffer",
    .header = "BindgenCustom.h",
}, "ArrayBuffer");

pub const abort_signal = externalRef("AbortSignal", .{
    .cpp_type = "WebCore::AbortSignal",
    .cpp_idl = "Bun::IDLAbortSignalRef",
    .cpp_declaration_header = "BunIDLExternalRefs.h",
    .cpp_conversion_header = "BunIDLConvertAbortSignal.h",
    .cpp_match = .{ .symbol = "Bun::Bindgen::ExternalRefs::matchesAbortSignal", .header = "BunIDLConvertAbortSignal.h" },
    .zig_type = "webcore.AbortSignal",
});

pub const blob = externalRef("Blob", .{
    .cpp_type = "WebCore::BlobImpl",
    .cpp_idl = "Bun::IDLBlobRef",
    .cpp_declaration_header = "BunIDLExternalRefs.h",
    .cpp_conversion_header = "BunIDLConvertBlob.h",
    .cpp_match = .{ .symbol = "Bun::Bindgen::ExternalRefs::matchesBlob", .header = "BunIDLConvertBlob.h" },
    .zig_type = "webcore.Blob",
    .brand = blob_brand,
});

pub const fetch_headers = externalRef("FetchHeaders", .{
    .cpp_type = "WebCore::FetchHeaders",
    .cpp_idl = "Bun::IDLFetchHeadersRef",
    .cpp_declaration_header = "BunIDLExternalRefs.h",
    .cpp_conversion_header = "BunIDLConvertFetchHeaders.h",
    .cpp_match = .{ .symbol = "Bun::Bindgen::ExternalRefs::matchesFetchHeaders", .header = "BunIDLConvertFetchHeaders.h" },
    .zig_type = "webcore.FetchHeaders",
});

pub const form_data = externalRef("FormData", .{
    .cpp_type = "WebCore::DOMFormData",
    .cpp_idl = "Bun::IDLDOMFormDataRef",
    .cpp_declaration_header = "BunIDLExternalRefs.h",
    .cpp_conversion_header = "BunIDLConvertFormData.h",
    .cpp_match = .{ .symbol = "Bun::Bindgen::ExternalRefs::matchesFormData", .header = "BunIDLConvertFormData.h" },
    .zig_type = "jsc.DOMFormData",
});

pub const url_search_params = externalRef("URLSearchParams", .{
    .cpp_type = "WebCore::URLSearchParams",
    .cpp_idl = "Bun::IDLURLSearchParamsRef",
    .cpp_declaration_header = "BunIDLExternalRefs.h",
    .cpp_conversion_header = "BunIDLConvertURLSearchParams.h",
    .cpp_match = .{ .symbol = "Bun::Bindgen::ExternalRefs::matchesURLSearchParams", .header = "BunIDLConvertURLSearchParams.h" },
    .zig_type = "jsc.URLSearchParams",
});

pub const readable_stream = brandedValueWithBrand(readable_stream_brand, .{});
pub const writable_stream = brandedValueWithBrand(writable_stream_brand, .{});
pub const transform_stream = brandedValueWithBrand(transform_stream_brand, .{});
pub const array_buffer_object = brandedValueWithBrand(array_buffer_brand, .{});

fn jscTypeBrand(comptime name: []const u8, comptime matcher: []const u8, comptime ts_type: []const u8) Brand {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return cppBrand(name, .{
        .symbol = "Bun::Bindgen::TypePredicates::is" ++ matcher,
        .header = "BindgenTypePredicates.h",
    }, ts_type);
}

fn jscTypePredicate(comptime name: []const u8, comptime matcher: []const u8, comptime ts_type: []const u8) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return brandedValueWithBrand(jscTypeBrand(name, matcher, ts_type), .{});
}

pub const js_date = jscTypePredicate("JSDate", "Date", "Date");
pub const js_arguments_object = jscTypePredicate("JSArgumentsObject", "ArgumentsObject", "IArguments");
pub const js_big_int_object = jscTypePredicate("JSBigIntObject", "BigIntObject", "BigInt");
pub const js_boolean_object = jscTypePredicate("JSBooleanObject", "BooleanObject", "Boolean");
pub const js_number_object = jscTypePredicate("JSNumberObject", "NumberObject", "Number");
pub const js_string_object = jscTypePredicate("JSStringObject", "StringObject", "String");
pub const js_symbol_object = jscTypePredicate("JSSymbolObject", "SymbolObject", "Symbol");
pub const js_reg_exp = brandedValueWithBrand(jscTypeBrand("JSRegExp", "RegExp", "RegExp"), .{
    .error_kind = .type,
    .expectation = "a RegExp",
    .node_requirement = "RegExp",
});
pub const js_async_function = jscTypePredicate(
    "JSAsyncFunction",
    "AsyncFunction",
    "((...arguments: unknown[]) => Promise<unknown>) | ((...arguments: unknown[]) => AsyncGenerator<unknown, unknown, unknown>)",
);
pub const js_generator_function = jscTypePredicate(
    "JSGeneratorFunction",
    "GeneratorFunction",
    "((...arguments: unknown[]) => Generator<unknown, unknown, unknown>) | ((...arguments: unknown[]) => AsyncGenerator<unknown, unknown, unknown>)",
);
pub const js_generator_object = jscTypePredicate(
    "JSGeneratorObject",
    "GeneratorObject",
    "Generator<unknown, unknown, unknown> | AsyncGenerator<unknown, unknown, unknown>",
);
pub const js_promise = promise(any);
pub const void_promise = promise(none);
pub const js_map = jscTypePredicate("JSMap", "Map", "Map<unknown, unknown>");
pub const js_set = jscTypePredicate("JSSet", "Set", "Set<unknown>");
pub const js_map_iterator = jscTypePredicate("JSMapIterator", "MapIterator", "IterableIterator<unknown>");
pub const js_set_iterator = jscTypePredicate("JSSetIterator", "SetIterator", "IterableIterator<unknown>");
pub const js_weak_map = jscTypePredicate("JSWeakMap", "WeakMap", "WeakMap<object, unknown>");
pub const js_weak_set = jscTypePredicate("JSWeakSet", "WeakSet", "WeakSet<object>");
pub const js_array_buffer_object = jscTypePredicate("JSArrayBufferObject", "ArrayBuffer", "ArrayBuffer");
pub const js_any_array_buffer_object = jscTypePredicate("JSAnyArrayBufferObject", "AnyArrayBuffer", "ArrayBuffer | SharedArrayBuffer");
pub const js_typed_array = brandedValueWithBrand(jscTypeBrand("JSTypedArray", "TypedArray", "Int8Array | Uint8Array | Uint8ClampedArray | Int16Array | Uint16Array | Int32Array | Uint32Array | Float16Array | Float32Array | Float64Array | BigInt64Array | BigUint64Array"), .{
    .error_kind = .type,
    .expectation = "a TypedArray",
    .node_requirement = "TypedArray",
});
pub const js_data_view = jscTypePredicate("JSDataView", "DataView", "DataView");
pub const js_shared_array_buffer = jscTypePredicate("JSSharedArrayBuffer", "SharedArrayBuffer", "SharedArrayBuffer");
pub const js_proxy = jscTypePredicate("JSProxy", "Proxy", "object");
pub const js_module_namespace_object = jscTypePredicate("JSModuleNamespaceObject", "ModuleNamespaceObject", "object");
pub const js_uint8_array = jscTypePredicate("JSUint8Array", "Uint8Array", "Uint8Array");
pub const js_uint8_clamped_array = jscTypePredicate("JSUint8ClampedArray", "Uint8ClampedArray", "Uint8ClampedArray");
pub const js_uint16_array = jscTypePredicate("JSUint16Array", "Uint16Array", "Uint16Array");
pub const js_uint32_array = jscTypePredicate("JSUint32Array", "Uint32Array", "Uint32Array");
pub const js_int8_array = jscTypePredicate("JSInt8Array", "Int8Array", "Int8Array");
pub const js_int16_array = jscTypePredicate("JSInt16Array", "Int16Array", "Int16Array");
pub const js_int32_array = jscTypePredicate("JSInt32Array", "Int32Array", "Int32Array");
pub const js_float16_array = jscTypePredicate("JSFloat16Array", "Float16Array", "Float16Array");
pub const js_float32_array = jscTypePredicate("JSFloat32Array", "Float32Array", "Float32Array");
pub const js_float64_array = jscTypePredicate("JSFloat64Array", "Float64Array", "Float64Array");
pub const js_big_int64_array = jscTypePredicate("JSBigInt64Array", "BigInt64Array", "BigInt64Array");
pub const js_big_uint64_array = jscTypePredicate("JSBigUint64Array", "BigUint64Array", "BigUint64Array");

pub const js_object = brandedValueWithBrand(jscTypeBrand("JSObject", "Object", "object"), .{
    .error_kind = .type,
    .expectation = "an object",
    .node_requirement = "object",
    .specificity = .generic,
});

pub const js_string = brandedValueWithBrand(jscTypeBrand("JSString", "String", "string"), .{
    .error_kind = .type,
    .expectation = "a string",
    .node_requirement = "string",
});

pub const js_array = brandedValueWithBrand(jscTypeBrand("JSArray", "Array", "unknown[]"), .{
    .error_kind = .type,
    .expectation = "an Array",
    .node_requirement = "Array",
});

pub const js_cell = brandedValueWithBrand(jscTypeBrand("JSCell", "Cell", "unknown"), .{
    .error_kind = .instance,
    .expectation = "a cell",
    .node_requirement = "JSCell",
    .specificity = .generic,
});

pub const js_structure = brandedValueWithBrand(jscTypeBrand("JSStructure", "Structure", "unknown"), .{
    .error_kind = .instance,
    .expectation = "a Structure",
    .node_requirement = "Structure",
});

pub const js_array_buffer_view = brandedValueWithBrand(jscTypeBrand("JSArrayBufferView", "ArrayBufferView", "ArrayBufferView"), .{
    .error_kind = .instance,
    .expectation = "an ArrayBufferView",
    .node_requirement = "ArrayBufferView",
});

pub const js_internal_field_tuple = brandedValueWithBrand(jscTypeBrand("JSInternalFieldTuple", "InternalFieldTuple", "unknown"), .{
    .error_kind = .instance,
    .expectation = "an internal field tuple",
    .node_requirement = "InternalFieldTuple",
});

pub const js_exception = brandedValueWithBrand(jscTypeBrand("JSException", "Exception", "unknown"), .{});

pub const js_error_instance = brandedValueWithBrand(jscTypeBrand("JSErrorInstance", "ErrorInstance", "Error"), .{
    .error_kind = .instance,
    .expectation = "an Error",
    .node_requirement = "Error",
});

pub const js_bound_function = brandedValueWithBrand(jscTypeBrand("JSBoundFunction", "BoundFunction", "Function"), .{
    .error_kind = .instance,
    .expectation = "a bound function",
    .node_requirement = "Function",
});

pub const js_big_int = brandedValueWithBrand(jscTypeBrand("JSBigInt", "BigInt", "bigint"), .{
    .error_kind = .type,
    .expectation = "a bigint",
    .node_requirement = "bigint",
});

pub const js_symbol = brandedValueWithBrand(jscTypeBrand("JSSymbol", "Symbol", "symbol"), .{
    .error_kind = .type,
    .expectation = "a symbol",
    .node_requirement = "symbol",
});

pub fn callback(comptime name: []const u8, comptime arguments: anytype, comptime result: Type, comptime options: CallbackOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .callback = pointerTo(Callback{
        .name = name,
        .args = sliceOf(Argument, arguments),
        .result = result,
        .options = options,
    }) };
}

fn optionalWithMode(comptime child: Type, comptime mode: OptionalMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .optional = .{ .child = pointerTo(child), .mode = mode } };
}

pub fn optional(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return optionalWithMode(child, .nullable);
}

pub fn optionalNullish(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return optionalWithMode(child, .nullish);
}

pub fn optionalUndefined(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return optionalWithMode(child, .undefined);
}

pub fn optionalFalsy(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return optionalWithMode(child, .falsy);
}

pub fn optionalMatch(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return optionalWithMode(child, .matched);
}

pub fn optionalNullishOrEmptyString(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return optionalWithMode(child, .nullish_or_empty_string);
}

pub fn enumerationValue(comptime name: []const u8, comptime value: []const u8) EnumerationValue {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return enumerationValueWithOptions(name, value, .{});
}

pub fn enumerationValueWithOptions(comptime name: []const u8, comptime value: []const u8, comptime options: EnumerationValueOptions) EnumerationValue {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .value = value, .options = options };
}

pub fn enumeration(comptime name: []const u8, comptime values: anytype) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return enumerationWithOptions(name, values, .{});
}

pub fn enumerationWithOptions(comptime name: []const u8, comptime values: anytype, comptime options: EnumerationOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .enumeration = pointerTo(Enumeration{
        .name = name,
        .values = sliceOf(EnumerationValue, values),
        .options = options,
    }) };
}

/// An error-code catalog derived from error-object domain errors with
/// explicit codes and DOMString message payloads.
pub fn errorCodeEnumeration(comptime name: []const u8, comptime errors: anytype) Type {
    @setEvalBranchQuota(2_000_000);
    const values = comptime blk: {
        var result: [errors.len]EnumerationValue = undefined;
        for (errors, 0..) |domain_error, index| {
            const options = switch (domain_error.declaration) {
                .error_object => |options| options,
                else => @compileError("an error catalog requires error-object mappings with explicit codes"),
            };
            const code = options.code orelse @compileError("an error catalog requires error-object mappings with explicit codes");
            if (!std.meta.eql(domain_error.payload, dom_string) or options.message != .payload)
                @compileError("an error catalog requires DOMString message payloads");
            result[index] = enumerationValueWithOptions(domain_error.name, domain_error.name, .{
                .native_value = @intCast(index),
                .error_code = .{ .class = options.class, .code = code, .name = options.name_override },
            });
        }
        break :blk result;
    };
    return enumerationWithOptions(name, values, .{ .tag = .u16, .error_catalog = true });
}

pub fn dictionaryField(comptime name: []const u8, comptime field_type: Type, comptime options: DictionaryFieldOptions) DictionaryField {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .type = field_type, .options = options };
}

pub fn dictionarySource(comptime name: []const u8) DictionaryField {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return dictionaryField(name, engine_value, .{ .source = .dictionary, .required = true });
}

pub fn dictionaryRetainedSource(comptime name: []const u8) DictionaryField {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return dictionaryField(name, retained_any, .{ .source = .dictionary, .required = true });
}

pub fn dictionary(comptime name: []const u8, comptime fields: anytype) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return dictionaryWithOptions(name, fields, .{});
}

pub fn dictionaryWithOptions(comptime name: []const u8, comptime fields: anytype, comptime options: DictionaryOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .dictionary = pointerTo(Dictionary{
        .name = name,
        .fields = sliceOf(DictionaryField, fields),
        .options = options,
    }) };
}

/// A dictionary result materialized as an instance of a plain class.
pub fn plainClassResult(comptime target: BoundClass) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    const properties = target.class.instance_properties;
    var fields: [properties.len]DictionaryField = undefined;
    for (properties, &fields) |property, *field| {
        field.* = dictionaryField(property.name, property.options.value, .{ .required = true });
    }
    const declared = fields;
    return dictionaryWithOptions(target.module ++ "_" ++ target.class.name ++ "Result", declared, .{ .result_class = target });
}

pub fn unionMember(comptime name: []const u8, comptime member_type: Type) UnionMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return unionMemberWithOptions(name, member_type, .{});
}

pub fn unionMemberWithOptions(comptime name: []const u8, comptime member_type: Type, comptime options: UnionMemberOptions) UnionMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .type = member_type, .options = options };
}

pub fn unionType(comptime name: []const u8, comptime members: anytype, comptime options: UnionOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .union_type = pointerTo(Union{
        .name = name,
        .members = sliceOf(UnionMember, members),
        .options = options,
    }) };
}

pub fn sequence(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return sequenceWithOptions(child, .{});
}

pub fn frozenArray(comptime child: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return sequenceWithOptions(child, .{ .flavor = .frozen_array });
}

pub fn sequenceWithOptions(comptime child: Type, comptime options: SequenceOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .sequence = pointerTo(Sequence{ .child = child, .options = options }) };
}

pub fn record(comptime key: Type, comptime value: Type) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return recordWithOptions(key, value, .{});
}

pub fn recordWithOptions(comptime key: Type, comptime value: Type, comptime options: RecordOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .record = pointerTo(Record{ .key = key, .value = value, .options = options }) };
}

pub fn customConverter(comptime name: []const u8, comptime options: CustomConverterOptions) Converter {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .kind = .custom, .name = name, .options = options };
}

pub fn converted(comptime native: Type, comptime match: Type, comptime converter: Converter, comptime options: ConvertedOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return convertedInternal(native, match, converter, options);
}

fn convertedInternal(comptime native: Type, comptime match: Type, comptime converter: Converter, comptime options: ConvertedOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .converted = pointerTo(Converted{
        .native = native,
        .match = match,
        .converter = converter,
        .options = options,
    }) };
}

pub fn brandCast(comptime match: Type, comptime options: BrandCastOptions) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    const brand_name = switch (match) {
        .branded_value => |branded| branded.brand.name,
        else => "",
    };
    const input: Type = switch (options.input) {
        .boundary => if (options.failure == .absent) any else match,
        .engine_value => engine_value,
        .optional_engine_value => optional(engine_value),
    };
    return convertedInternal(
        if (options.failure == .absent) optional(match) else match,
        input,
        .{
            .kind = .brand_cast,
            .name = "bunBindgenBrandCast" ++ brand_name ++ @tagName(options.failure) ++ @tagName(options.input),
            .options = switch (options.failure) {
                .reject => .{},
                .absent, .assert => .{ .infallible = true, .realm_free = true },
            },
            .brand_cast = .{ .match = pointerTo(match), .failure = options.failure, .input = options.input },
        },
        .{ .name = options.name },
    );
}

const json_stringified_input = unionType("JSONStringifiedInput", .{
    unionMember("text", dom_string),
    unionMember("object", js_object),
}, .{ .ordered = true, .cpp_name = "JSONStringifiedInput" });

pub const property_key = unionType("PropertyKey", .{
    unionMember("string", dom_string),
    unionMember("symbol", js_symbol),
}, .{ .cpp_name = "PropertyKey" });

pub const to_property_key = convertedInternal(property_key, engine_value, .{
    .kind = .property_key,
    .name = "bunBindgenToPropertyKey",
    .options = .{ .may_invoke_js = true },
}, .{});

pub const json_stringified_string = convertedInternal(dom_string, json_stringified_input, .{
    .kind = .json_stringify,
    .name = "bunBindgenJSONStringifiedString",
    .options = .{ .may_invoke_js = true },
}, .{});

const headers_init_value = unionType("HeadersInitValue", .{
    unionMember("headers", fetch_headers),
    unionMember("sequence", sequenceWithOptions(sequenceWithOptions(coerceString(dom_string), .{ .container = .iterable }), .{ .container = .iterable })),
    unionMember("record", record(coerceString(dom_string), coerceString(dom_string))),
}, .{ .ordered = true, .cpp_name = "HeadersInitValue", .no_match_error = .{ .kind = .type_error, .message = "Type error" } });
const headers_init_input = optionalUndefined(headers_init_value);
const headers_init_native = optional(fetch_headers);

pub fn headersInit(comptime mode: HeadersInitMode) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return convertedInternal(headers_init_native, headers_init_input, .{
        .kind = .headers_init,
        .name = if (mode == .share) "bunBindgenHeadersInit" else "bunBindgenClonedHeadersInit",
        .options = .{ .may_invoke_js = true },
    }, .{ .name = "headers" });
}

/// The reserved converted types and the schemas they must keep, which
/// normalization uses to reject reserved converters built elsewhere.
pub const reserved_conversions = struct {
    pub const property_key = to_property_key;
    pub const json_stringify = json_stringified_string;
    pub const headers_init_share = headersInit(.share);
    pub const headers_init_clone = headersInit(.clone);
};

/// The promise reaction context a reaction-context type declares.
pub fn promiseReactionOf(comptime context: Type) PromiseReactionContext {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (context) {
        .branded_value => |branded| branded.promise_reaction orelse @compileError("promiseReactionOf requires a promise reaction context type"),
        else => @compileError("promiseReactionOf requires a promise reaction context type"),
    };
}

pub fn promiseReactionContext(comptime name: []const u8, comptime tag: []const u8) Type {
    @setEvalBranchQuota(schema_eval_branch_quota);
    const owner_name = name ++ "OwnerReference";
    const owner = nominalHandle(owner_name, .{
        .cpp_type = .{ .pointer = &.{ .named = "Bun::" ++ owner_name } },
        .cpp_declarations = &.{ .{ .class = "Bun::" ++ name }, .{ .structure = "Bun::" ++ owner_name } },
        .access_thread = .vm,
    });
    return .{ .branded_value = pointerTo(BrandedValue{
        .brand = cppDynamicCastBrand(name, .{
            .type_name = "Bun::" ++ name,
            .header = "JavaScriptCore/JSDestructibleObject.h",
        }, "unknown"),
        .options = .{
            .error_kind = .instance,
            .expectation = "an internal promise reaction context",
        },
        .promise_reaction = .{ .name = name, .tag = tag, .owner_reference = owner },
    }) };
}

// ─── arguments and errors ───

pub fn argument(comptime name: []const u8, comptime argument_type: Type, comptime options: ArgumentOptions) Argument {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .type = argument_type, .options = options };
}

pub fn argumentProjection(comptime name: []const u8, comptime source: []const u8, comptime projected: Type, comptime reason: []const u8) Argument {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return argument(name, lazy(projected), .{
        .presence = .optional,
        .missing = .omitted,
        .source = .{ .argument = source },
        .deferred_reason = reason,
    });
}

pub fn rest(comptime name: []const u8, comptime element: Type) Argument {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return argument(name, element, .{ .rest = true });
}

pub fn lazyRest(comptime name: []const u8, comptime element: Type, comptime reason: []const u8) Argument {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return argument(name, lazy(element), .{ .rest = true, .deferred_reason = reason });
}

pub fn overloadCase(comptime name: []const u8, comptime arguments: anytype) OverloadCase {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return overloadCaseWithOptions(name, arguments, .{});
}

pub fn overloadCaseWithOptions(comptime name: []const u8, comptime arguments: anytype, comptime options: OverloadCaseOptions) OverloadCase {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .args = sliceOf(Argument, arguments), .options = options };
}

pub fn overloads(comptime cases: anytype, comptime options: OverloadOptions) Overloads {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .cases = sliceOf(OverloadCase, cases), .options = options };
}

fn argumentsOf(comptime arguments: anytype) Arguments {
    @setEvalBranchQuota(schema_eval_branch_quota);
    if (@TypeOf(arguments) == Overloads) return .{ .overloads = arguments };
    return .{ .list = sliceOf(Argument, arguments) };
}

pub const system_error_payload = dictionary("BindgenSystemErrorPayload", .{
    dictionaryField("error_number", int32, .{ .required = true }),
    dictionaryField("code", buffer(.copy), .{ .required = true }),
    dictionaryField("message", buffer(.copy), .{ .required = true }),
    dictionaryField("path", buffer(.copy), .{ .required = true }),
    dictionaryField("syscall", buffer(.copy), .{ .required = true }),
    dictionaryField("hostname", buffer(.copy), .{ .required = true }),
    dictionaryField("fd", int32, .{ .required = true }),
    dictionaryField("dest", buffer(.copy), .{ .required = true }),
    dictionaryField("address", buffer(.copy), .{ .required = true }),
    dictionaryField("port", optional(uint16), .{ .required = true }),
});

pub fn classError(comptime name: []const u8, comptime payload: Type) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = payload, .declaration = .class_instance };
}

pub fn aggregateError(comptime name: []const u8, comptime payload: Type, comptime options: AggregateErrorOptions) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = payload, .declaration = .{ .aggregate_error = options } };
}

pub fn domainError(comptime name: []const u8, comptime payload: Type, comptime options: DomainErrorOptions) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = payload, .declaration = .{ .error_object = options } };
}

pub fn builtinError(comptime name: []const u8, comptime payload: Type, comptime options: BuiltinErrorOptions) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = payload, .declaration = .{ .builtin_error = options } };
}

pub fn systemError(comptime name: []const u8) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return systemErrorWithOptions(name, .{});
}

pub fn systemErrorWithOptions(comptime name: []const u8, comptime options: SystemErrorOptions) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = system_error_payload, .declaration = .{ .system_error = options } };
}

pub fn systemErrorWithInfo(comptime name: []const u8) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = system_error_payload, .declaration = .system_error_with_info };
}

pub fn domException(comptime name: []const u8, comptime exception: DOMExceptionName, comptime payload: Type, comptime message: ErrorMessage) DomainError {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .payload = payload, .declaration = .{ .dom_exception = .{ .exception = exception, .message = message } } };
}

pub fn domainErrors(comptime declarations: anytype) DomainErrors {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .errors = sliceOf(DomainError, declarations) };
}

pub const no_domain_errors: DomainErrors = .{};

pub fn callbackData(comptime zig_type: []const u8) CallbackData {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .zig_type = zig_type };
}

// ─── declarations ───

pub fn function(comptime name: []const u8, comptime arguments: anytype, comptime result: Type, comptime options: FunctionOptions) Function {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .arguments = argumentsOf(arguments), .result = result, .options = options };
}

pub fn typePredicate(comptime name: []const u8, comptime target: Type) Function {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return function(name, .{argument("value", any, .{})}, boolean, .{
        .backend = .cpp,
        .length = 1,
        .profile = .exact,
        .missing_required_arguments = .convert_undefined,
        .type_predicate = target,
    });
}

pub fn engineShim(comptime name: []const u8, comptime arguments: anytype, comptime result: Type, comptime options: EngineShimOptions) EngineShim {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .args = sliceOf(Argument, arguments), .result = result, .options = options };
}

pub fn nativeExport(comptime name: []const u8, comptime arguments: anytype, comptime result: Type) NativeExport {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return nativeExportWithOptions(name, arguments, result, .{});
}

pub fn nativeExportWithOptions(comptime name: []const u8, comptime arguments: anytype, comptime result: Type, comptime options: NativeExportOptions) NativeExport {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .args = sliceOf(Argument, arguments), .result = result, .options = options };
}

pub fn instanceProperty(comptime name: []const u8, comptime options: InstancePropertyOptions) InstanceProperty {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .options = options };
}

pub fn sweep(comptime reason: []const u8) LastRelease {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .sweep = reason };
}

pub fn engineParent(comptime options: EngineParentOptions) ClassParent {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .engine = options };
}

/// Inherits from a generated class declared in this or an earlier module.
pub fn parentClass(comptime parent: Class) ClassParent {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .class = pointerTo(parent) };
}

pub fn memberAlias(comptime name: []const u8, comptime options: ClassMemberAliasOptions) ClassMemberAlias {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .key = .{ .name = name }, .options = options };
}

pub fn memberSymbolAlias(comptime symbol: PropertySymbol, comptime options: ClassMemberAliasOptions) ClassMemberAlias {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .key = .{ .symbol = symbol }, .options = options };
}

fn classMember(comptime name: []const u8, comptime kind: ClassMemberKind, comptime arguments: anytype, comptime result: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .kind = kind, .arguments = argumentsOf(arguments), .result = result, .options = options };
}

pub fn constructor(comptime arguments: anytype, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember("constructor", .constructor, arguments, native_instance, options);
}

/// The constructor object exists (name, length, prototype, statics) but both
/// calling and constructing it throw `ERR_ILLEGAL_CONSTRUCTOR`; instances are
/// created only from native code.
pub fn illegalConstructor() ClassMember {
    return classMember("constructor", .constructor, .{}, native_instance, .{ .illegal = true });
}

pub fn constructorCall(comptime arguments: anytype, comptime result: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember("call", .static_method, arguments, result, options);
}

pub fn method(comptime name: []const u8, comptime arguments: anytype, comptime result: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember(name, .method, arguments, result, options);
}

pub fn getter(comptime name: []const u8, comptime result: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember(name, .getter, .{}, result, options);
}

pub fn setter(comptime name: []const u8, comptime value: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return setterWithValueOptions(name, value, .{}, options);
}

pub fn setterWithValueOptions(comptime name: []const u8, comptime value: Type, comptime conversion: ValueConversionOptions, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember(name, .setter, .{argument("value", value, .{
        .boolean_conversion = conversion.boolean_conversion,
        .integer_conversion = conversion.integer_conversion,
        .number_conversion = conversion.number_conversion,
        .deferred_reason = options.deferred_reason,
    })}, none, options);
}

pub fn staticMethod(comptime name: []const u8, comptime arguments: anytype, comptime result: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember(name, .static_method, arguments, result, options);
}

pub fn staticGetter(comptime name: []const u8, comptime result: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember(name, .static_getter, .{}, result, options);
}

pub fn staticSetter(comptime name: []const u8, comptime value: Type, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return staticSetterWithValueOptions(name, value, .{}, options);
}

pub fn staticSetterWithValueOptions(comptime name: []const u8, comptime value: Type, comptime conversion: ValueConversionOptions, comptime options: ClassMemberOptions) ClassMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classMember(name, .static_setter, .{argument("value", value, .{
        .boolean_conversion = conversion.boolean_conversion,
        .integer_conversion = conversion.integer_conversion,
        .number_conversion = conversion.number_conversion,
        .deferred_reason = options.deferred_reason,
    })}, none, options);
}

pub fn cachedSlot(comptime name: []const u8, comptime slot_type: Type, comptime options: CachedSlotOptions) CachedSlot {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .type = slot_type, .options = options };
}

pub fn dataProperty(comptime name: []const u8, comptime value: DefaultValue, comptime options: DataPropertyOptions) DataProperty {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{
        .name = name,
        .key = if (options.symbol) |symbol| .{ .symbol = symbol } else .{ .name = name },
        .value = value,
        .options = options,
    };
}

pub fn class(comptime name: []const u8, comptime constructor_member: ClassMember, comptime members: anytype, comptime cached_slots: anytype, comptime options: ClassOptions) Class {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return classWithInstanceProperties(name, constructor_member, members, cached_slots, .{}, .{}, options);
}

pub fn classWithDataProperties(
    comptime name: []const u8,
    comptime constructor_member: ClassMember,
    comptime members: anytype,
    comptime cached_slots: anytype,
    comptime data_properties: anytype,
    comptime options: ClassOptions,
) Class {
    return classWithInstanceProperties(name, constructor_member, members, cached_slots, data_properties, .{}, options);
}

/// A `.plain` class: instances are JS objects whose own data properties come
/// from the declared instance properties, laid out on one precomputed
/// Structure.
pub fn plainClass(comptime name: []const u8, comptime constructor_member: ClassMember, comptime members: anytype, comptime instance_properties: anytype, comptime options: ClassOptions) Class {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return plainClassWithDataProperties(name, constructor_member, members, instance_properties, .{}, options);
}

pub fn plainClassWithDataProperties(
    comptime name: []const u8,
    comptime constructor_member: ClassMember,
    comptime members: anytype,
    comptime instance_properties: anytype,
    comptime data_properties: anytype,
    comptime options: ClassOptions,
) Class {
    @setEvalBranchQuota(schema_eval_branch_quota);
    if (options.representation != .plain) @compileError("plain classes must declare plain representation: " ++ name);
    return classWithInstanceProperties(name, constructor_member, members, .{}, data_properties, instance_properties, options);
}

fn classWithInstanceProperties(
    comptime name: []const u8,
    comptime constructor_member: ClassMember,
    comptime members: anytype,
    comptime cached_slots: anytype,
    comptime data_properties: anytype,
    comptime instance_properties: anytype,
    comptime options: ClassOptions,
) Class {
    return .{
        .name = name,
        .constructor = constructor_member,
        .members = sliceOf(ClassMember, members),
        .slots = sliceOf(CachedSlot, cached_slots),
        .properties = sliceOf(DataProperty, data_properties),
        .instance_properties = sliceOf(InstanceProperty, instance_properties),
        .options = options,
    };
}

// ─── surfaces ───

fn surfaceName(comptime name: []const u8) SurfacePropertyKey {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name };
}

pub fn surfaceSymbol(comptime symbol: PropertySymbol) SurfacePropertyKey {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .symbol = symbol };
}

pub fn surfaceBuiltinName(comptime accessor: []const u8) SurfacePropertyKey {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .builtin_name = accessor };
}

pub fn surfaceEngineName(comptime member: []const u8) SurfacePropertyKey {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .engine_name = member };
}

pub fn surfaceEngineBuiltinName(comptime accessor: []const u8) SurfacePropertyKey {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .engine_builtin_name = accessor };
}

pub fn surfaceAlias(comptime name: []const u8, comptime attributes: SurfacePropertyAttributes) SurfaceMemberAlias {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .key = .{ .name = name }, .attributes = attributes };
}

pub fn surfaceSymbolAlias(comptime symbol: PropertySymbol, comptime attributes: SurfacePropertyAttributes) SurfaceMemberAlias {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .key = .{ .symbol = symbol }, .attributes = attributes };
}

fn surfaceMember(comptime key: SurfacePropertyKey, comptime value: SurfaceMemberValue, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .key = key, .value = value, .options = options };
}

pub fn surfaceFunction(comptime name: []const u8, comptime declaration: BoundFunction, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceFunctionAt(surfaceName(name), declaration, options);
}

pub fn surfaceFunctionAt(comptime key: SurfacePropertyKey, comptime declaration: BoundFunction, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(key, .{ .function = declaration }, options);
}

pub fn surfaceFunctionGetter(comptime name: []const u8, comptime getter_declaration: BoundFunction, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceFunctionAccessorAt(surfaceName(name), getter_declaration, null, options);
}

pub fn surfaceFunctionAccessor(
    comptime name: []const u8,
    comptime getter_declaration: BoundFunction,
    comptime setter_declaration: ?BoundFunction,
    comptime options: SurfaceMemberOptions,
) SurfaceMember {
    return surfaceFunctionAccessorAt(surfaceName(name), getter_declaration, setter_declaration, options);
}

pub fn surfaceFunctionAccessorAt(
    comptime key: SurfacePropertyKey,
    comptime getter_declaration: BoundFunction,
    comptime setter_declaration: ?BoundFunction,
    comptime options: SurfaceMemberOptions,
) SurfaceMember {
    return surfaceMember(key, .{ .accessor = .{ .function = .{ .getter = getter_declaration, .setter = setter_declaration } } }, options);
}

fn lazyDeclarationOf(comptime declaration: anytype) LazyDeclaration {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (@TypeOf(declaration)) {
        BoundFunction => .{ .function = declaration },
        BoundNativeExport => .{ .native = declaration },
        BoundClass => .{ .class = declaration },
        else => @compileError("lazy surface properties must reference a bound function, native export, or class declaration"),
    };
}

pub fn surfaceLazyProperty(comptime name: []const u8, comptime declaration: anytype, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceLazyPropertyAt(surfaceName(name), declaration, options);
}

pub fn surfaceLazyPropertyAt(comptime key: SurfacePropertyKey, comptime declaration: anytype, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(key, .{ .lazy_declaration = lazyDeclarationOf(declaration) }, options);
}

pub fn surfaceObjectValue(comptime name: []const u8, comptime surface: ObjectSurface, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .object_value = pointerTo(surface) }, options);
}

pub fn surfaceCallableValue(comptime name: []const u8, comptime declaration: BoundFunction, comptime surface: ObjectSurface, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .callable_value = .{ .declaration = declaration, .surface = pointerTo(surface) } }, options);
}

pub fn surfaceSelf(comptime name: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .self, options);
}

pub fn surfaceBuiltinGetter(comptime name: []const u8, comptime declaration: BoundFunction, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .accessor = .{ .builtin = declaration } }, options);
}

fn surfaceConstant(comptime key: SurfacePropertyKey, comptime constant: SurfaceConstant, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(key, .{ .constant = constant }, options);
}

pub fn surfaceString(comptime name: []const u8, comptime value: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .string = value }, options);
}

pub fn surfaceExternalString(comptime name: []const u8, comptime symbol: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .external_string = symbol }, options);
}

pub fn surfaceRegisteredSymbol(comptime name: []const u8, comptime registry_key: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .registered_symbol = registry_key }, options);
}

pub fn surfaceUndefined(comptime name: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .undefined, options);
}

pub fn surfaceInteger(comptime name: []const u8, comptime value: i64, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .integer = value }, options);
}

pub fn surfaceExternalNumber(comptime name: []const u8, comptime symbol: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .external_number = symbol }, options);
}

pub fn surfaceExternalBoolean(comptime name: []const u8, comptime symbol: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .external_boolean = symbol }, options);
}

pub fn surfaceBoolean(comptime name: []const u8, comptime value: bool, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(surfaceName(name), .{ .boolean = value }, options);
}

pub fn surfaceEmptyArray(comptime name: []const u8, comptime element: Type, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .empty_collection = .{ .collection = .array, .element = element } }, options);
}

pub fn surfaceEmptySet(comptime name: []const u8, comptime element: Type, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .empty_collection = .{ .collection = .set, .element = element } }, options);
}

pub fn surfaceSymbolString(comptime symbol: PropertySymbol, comptime value: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceConstant(.{ .symbol = symbol }, .{ .string = value }, options);
}

pub fn surfaceCellProperty(comptime name: []const u8, comptime cpp_member: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .lazy_owner = .{ .owner = .cell, .member = cpp_member } }, options);
}

pub fn surfaceClassStructure(comptime name: []const u8, comptime cpp_member: []const u8, comptime options: SurfaceMemberOptions) SurfaceMember {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return surfaceMember(surfaceName(name), .{ .lazy_owner = .{ .owner = .class_structure, .member = cpp_member } }, options);
}

pub fn objectSurface(comptime name: []const u8, comptime members: anytype, comptime options: ObjectSurfaceOptions) ObjectSurface {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .members = sliceOf(SurfaceMember, members), .options = options };
}

pub fn nativeModule(comptime name: []const u8, comptime specifier: []const u8, comptime exports: anytype, comptime options: NativeModuleOptions) NativeModule {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{
        .name = name,
        .specifier = specifier,
        .exports = if (@TypeOf(exports) == ObjectSurface)
            .{ .surface = pointerTo(exports) }
        else
            .{ .members = sliceOf(SurfaceMember, exports) },
        .options = options,
    };
}

pub fn focusedEngineIntegration(comptime name: []const u8, comptime options: FocusedEngineIntegrationOptions) FocusedEngineIntegration {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return .{ .name = name, .options = options };
}

// ─── modules ───

fn surfaceOf(comptime declaration: anytype) Surface {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return switch (@TypeOf(declaration)) {
        NativeModule => .{ .native_module = declaration },
        ObjectSurface => .{ .object = declaration },
        else => @compileError("module surfaces must be created with a bindgen surface declaration"),
    };
}

fn surfacesOf(comptime declarations: anytype) []const Surface {
    @setEvalBranchQuota(schema_eval_branch_quota);
    var surfaces: [declarations.len]Surface = undefined;
    inline for (declarations, &surfaces) |declaration, *surface| surface.* = surfaceOf(declaration);
    const result = surfaces;
    return &result;
}

fn moduleWithAllDeclarations(
    comptime name: []const u8,
    comptime functions: anytype,
    comptime classes: anytype,
    comptime engine_shims: anytype,
    comptime native_exports: anytype,
    comptime surfaces: anytype,
) Module {
    const class_slice = sliceOf(Class, classes);
    return .{
        .name = name,
        .functions = sliceOf(Function, functions),
        .classes = class_slice,
        .class_values = classValues(name, class_slice),
        .engine_shims = sliceOf(EngineShim, engine_shims),
        .native_exports = sliceOf(NativeExport, native_exports),
        .surfaces = surfacesOf(surfaces),
    };
}

fn classValues(comptime module_name: []const u8, comptime classes: []const Class) []const Type {
    var values: [classes.len]Type = undefined;
    for (classes, &values) |class_value, *value| value.* = classValueNamed(.{ .module = module_name, .class = class_value.name }, .{});
    const final = values;
    return &final;
}

pub fn module(comptime name: []const u8, comptime functions: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return moduleWithAllDeclarations(name, functions, .{}, .{}, .{}, .{});
}

pub fn moduleWithClasses(comptime name: []const u8, comptime functions: anytype, comptime classes: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return moduleWithAllDeclarations(name, functions, classes, .{}, .{}, .{});
}

pub fn moduleWithEngineShims(comptime name: []const u8, comptime functions: anytype, comptime engine_shims: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return moduleWithAllDeclarations(name, functions, .{}, engine_shims, .{}, .{});
}

pub fn moduleWithNativeExports(comptime name: []const u8, comptime functions: anytype, comptime native_exports: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return moduleWithAllDeclarations(name, functions, .{}, .{}, native_exports, .{});
}

pub fn moduleWithSurfaces(comptime name: []const u8, comptime surfaces: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return moduleWithAllDeclarations(name, .{}, .{}, .{}, .{}, surfaces);
}

pub fn moduleWithFocusedEngineIntegrations(comptime name: []const u8, comptime integrations: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    var result = module(name, .{});
    result.focused_integrations = sliceOf(FocusedEngineIntegration, integrations);
    return result;
}

pub fn moduleWithClassesAndEngineShims(comptime name: []const u8, comptime functions: anytype, comptime classes: anytype, comptime engine_shims: anytype) Module {
    @setEvalBranchQuota(schema_eval_branch_quota);
    return moduleWithAllDeclarations(name, functions, classes, engine_shims, .{}, .{});
}

pub fn moduleWithDeclarations(
    comptime name: []const u8,
    comptime functions: anytype,
    comptime classes: anytype,
    comptime engine_shims: anytype,
    comptime native_exports: anytype,
) Module {
    return moduleWithAllDeclarations(name, functions, classes, engine_shims, native_exports, .{});
}

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
pub const StringEmptyRejection = vocabulary.StringEmptyRejection;
pub const StringCoercionOptions = vocabulary.StringCoercionOptions;
pub const AnyPurpose = vocabulary.AnyPurpose;
pub const DiscardedMatch = vocabulary.DiscardedMatch;
pub const DiscardPurpose = vocabulary.DiscardPurpose;
pub const NodePathOptions = vocabulary.NodePathOptions;
pub const BufferCopyFallback = vocabulary.BufferCopyFallback;
pub const BufferSourceAttachment = vocabulary.BufferSourceAttachment;
pub const BufferTypeErrorFormat = vocabulary.BufferTypeErrorFormat;
pub const BufferOptions = vocabulary.BufferOptions;
pub const CppBrandMatcher = vocabulary.CppBrandMatcher;
pub const CppRealmBrandMatcher = vocabulary.CppRealmBrandMatcher;
pub const CppDynamicCastMatcher = vocabulary.CppDynamicCastMatcher;
pub const NominalHandleOwnership = vocabulary.NominalHandleOwnership;
pub const ResourceThread = vocabulary.ResourceThread;
pub const NominalHandleOptions = vocabulary.NominalHandleOptions;
pub const CppType = vocabulary.CppType;
pub const CppDeclaration = vocabulary.CppDeclaration;
pub const BrandedValueSpecificity = vocabulary.BrandedValueSpecificity;
pub const BrandedValueError = vocabulary.BrandedValueError;
pub const BrandedValueDefaults = vocabulary.BrandedValueDefaults;
pub const ClassReferenceOptions = vocabulary.ClassReferenceOptions;
pub const ClassValueMatch = vocabulary.ClassValueMatch;
pub const ClassValueOptions = vocabulary.ClassValueOptions;
pub const CallbackOptions = struct {
    receiver: ?Type,
    profile: Profile = .webidl,
    no_match_error: ?ConversionFailure = null,
    retains_async_context: bool = false,
    schedule_next_tick: bool = false,
};
pub const OptionalMode = vocabulary.OptionalMode;
pub const EnumerationValueOptions = vocabulary.EnumerationValueOptions;
pub const InternalModuleDefault = vocabulary.InternalModuleDefault;
pub const InternalModuleSource = vocabulary.InternalModuleSource;
pub const ErrorCodeOptions = vocabulary.ErrorCodeOptions;
pub const EnumerationOptions = vocabulary.EnumerationOptions;
pub const EnumerationErrors = vocabulary.EnumerationErrors;
pub const EnumerationInvalidValueError = vocabulary.EnumerationInvalidValueError;
pub const NodeInvalidEnumerationValue = vocabulary.NodeInvalidEnumerationValue;
pub const DictionaryFieldOptions = vocabulary.DictionaryFieldOptions;
pub const LazyPropertyRead = vocabulary.LazyPropertyRead;
pub const DictionaryFieldSource = vocabulary.DictionaryFieldSource;
pub const DictionaryFieldMissing = vocabulary.DictionaryFieldMissing;
pub const ResultObjectPrototype = vocabulary.ResultObjectPrototype;
pub const DictionaryObjectError = vocabulary.DictionaryObjectError;
pub const DictionaryInputSnapshot = vocabulary.DictionaryInputSnapshot;
pub const DictionaryPropertyLookup = vocabulary.DictionaryPropertyLookup;
pub const DictionaryFieldReads = vocabulary.DictionaryFieldReads;
pub const RequiredDictionaryFieldMissing = vocabulary.RequiredDictionaryFieldMissing;
pub const UnionMemberOptions = vocabulary.UnionMemberOptions;
pub const NodeUnionError = vocabulary.NodeUnionError;
pub const NodeSequenceErrorKind = vocabulary.NodeSequenceErrorKind;
pub const NodeSequenceFailure = vocabulary.NodeSequenceFailure;
pub const NodeSequenceFailureSite = vocabulary.NodeSequenceFailureSite;
pub const NodeSequenceError = vocabulary.NodeSequenceError;
pub const SequenceElementAccess = vocabulary.SequenceElementAccess;
pub const SequenceFlavor = vocabulary.SequenceFlavor;
pub const SequenceContainer = vocabulary.SequenceContainer;
pub const SequenceOptions = vocabulary.SequenceOptions;
pub const SequenceLengthLimit = vocabulary.SequenceLengthLimit;
pub const SequenceElementPattern = vocabulary.SequenceElementPattern;
pub const RecordOptions = vocabulary.RecordOptions;
pub const Missing = vocabulary.Missing;
pub const Presence = vocabulary.Presence;
pub const DefaultValue = vocabulary.DefaultValue;
pub const IntegerRange = vocabulary.IntegerRange;
pub const IntegerRangeFailure = vocabulary.IntegerRangeFailure;
pub const SaturatedIntegerValidation = vocabulary.SaturatedIntegerValidation;
pub const ConversionFailure = vocabulary.ConversionFailure;
pub const BoundedIntegerValidation = vocabulary.BoundedIntegerValidation;
pub const TruncatedIntegerClamp = vocabulary.TruncatedIntegerClamp;
pub const CoercedIntegerDefault = vocabulary.CoercedIntegerDefault;
pub const NodeIntegerCoercion = vocabulary.NodeIntegerCoercion;
pub const NodeTruncatedIntegerValidation = vocabulary.NodeTruncatedIntegerValidation;
pub const NodeIntegerValidation = vocabulary.NodeIntegerValidation;
pub const IntegerConversion = vocabulary.IntegerConversion;
pub const NodeNumberRangeError = vocabulary.NodeNumberRangeError;
pub const NodeNumberValidation = vocabulary.NodeNumberValidation;
pub const NumberRange = vocabulary.NumberRange;
pub const NumberRangeValidation = vocabulary.NumberRangeValidation;
pub const NumberIntegerNormalization = vocabulary.NumberIntegerNormalization;
pub const NumberIntegerWrapping = vocabulary.NumberIntegerWrapping;
pub const NumberConversion = vocabulary.NumberConversion;
pub const BooleanConversion = vocabulary.BooleanConversion;
pub const ValueConversionOptions = vocabulary.ValueConversionOptions;
pub const CustomConverterOptions = vocabulary.CustomConverterOptions;
pub const ConverterKind = vocabulary.ConverterKind;
pub const BrandCastFailure = vocabulary.BrandCastFailure;
pub const BrandCastInput = vocabulary.BrandCastInput;
pub const BrandCastOptions = vocabulary.BrandCastOptions;
pub const ConvertedOptions = vocabulary.ConvertedOptions;
pub const HeadersInitMode = vocabulary.HeadersInitMode;
pub const ReceiverByteLengthConversion = vocabulary.ReceiverByteLengthConversion;
pub const ArgumentOwnership = vocabulary.ArgumentOwnership;
pub const ArgumentSelection = vocabulary.ArgumentSelection;
pub const ArgumentProjectionSource = vocabulary.ArgumentProjectionSource;
pub const ArgumentOptions = vocabulary.ArgumentOptions;
pub const OverloadCaseOptions = vocabulary.OverloadCaseOptions;
pub const OverloadOptions = vocabulary.OverloadOptions;
pub const Exposure = vocabulary.Exposure;
pub const DomainErrorMapping = vocabulary.DomainErrorMapping;
pub const ErrorClass = vocabulary.ErrorClass;
pub const ErrorMessage = vocabulary.ErrorMessage;
pub const DomainErrorOptions = vocabulary.DomainErrorOptions;
pub const BuiltinErrorOptions = vocabulary.BuiltinErrorOptions;
pub const AggregateErrorOptions = vocabulary.AggregateErrorOptions;
pub const SystemErrorOptions = vocabulary.SystemErrorOptions;
pub const DOMExceptionName = vocabulary.DOMExceptionName;
pub const CompletionRetention = vocabulary.CompletionRetention;
pub const CompletionDrop = vocabulary.CompletionDrop;
pub const CompletionDelivery = vocabulary.CompletionDelivery;
pub const CompletionSettlement = vocabulary.CompletionSettlement;
pub const MissingRequiredArguments = vocabulary.MissingRequiredArguments;
pub const RealmFunctionIdentity = vocabulary.RealmFunctionIdentity;
pub const ConversionStep = vocabulary.ConversionStep;
pub const EngineThrows = vocabulary.EngineThrows;
pub const EngineRealm = vocabulary.EngineRealm;
pub const EngineAffinity = vocabulary.EngineAffinity;
pub const EngineResultSource = vocabulary.EngineResultSource;
pub const EngineShimOptions = vocabulary.EngineShimOptions;
pub const NativeThrows = vocabulary.NativeThrows;
pub const ClassOwnership = vocabulary.ClassOwnership;
pub const ClassRepresentation = vocabulary.ClassRepresentation;
pub const MemoryUsageAffinity = vocabulary.MemoryUsageAffinity;
pub const InstancePropertyInitializer = vocabulary.InstancePropertyInitializer;
pub const InvalidThisBehavior = vocabulary.InvalidThisBehavior;
pub const GetterAssignment = vocabulary.GetterAssignment;
pub const WrapperIdentity = vocabulary.WrapperIdentity;
pub const ReferenceThread = vocabulary.ReferenceThread;
pub const LastRelease = vocabulary.LastRelease;
pub const ClassPrototypeBase = vocabulary.ClassPrototypeBase;
pub const EngineCellKind = vocabulary.EngineCellKind;
pub const EngineParentPrototype = vocabulary.EngineParentPrototype;
pub const EngineParentConstructor = vocabulary.EngineParentConstructor;
pub const EngineParentOptions = vocabulary.EngineParentOptions;
pub const EngineGlobalScopeProjection = vocabulary.EngineGlobalScopeProjection;
pub const EngineNativeOptions = vocabulary.EngineNativeOptions;
pub const ClassMemberKind = vocabulary.ClassMemberKind;
pub const PropertySymbol = vocabulary.PropertySymbol;
pub const ClassMemberAliasKey = vocabulary.ClassMemberAliasKey;
pub const ClassMemberAliasOptions = vocabulary.ClassMemberAliasOptions;
pub const ClassMemberAlias = vocabulary.ClassMemberAlias;
pub const EngineTracing = vocabulary.EngineTracing;
pub const ClassLifecycle = vocabulary.ClassLifecycle;
pub const IllegalConstructorErrors = vocabulary.IllegalConstructorErrors;
pub const CachedSlotOptions = vocabulary.CachedSlotOptions;
pub const DataPropertyStorage = vocabulary.DataPropertyStorage;
pub const DataPropertyOptions = vocabulary.DataPropertyOptions;
pub const StructuredCloneUnsupportedContext = vocabulary.StructuredCloneUnsupportedContext;
pub const StructuredCloneOptions = vocabulary.StructuredCloneOptions;
pub const SharedStructuredCloneOptions = vocabulary.SharedStructuredCloneOptions;
pub const SurfacePropertyAttributes = vocabulary.SurfacePropertyAttributes;
pub const SurfacePropertyKey = vocabulary.SurfacePropertyKey;
pub const SurfaceMemberAlias = vocabulary.SurfaceMemberAlias;
pub const SurfaceMemberKind = vocabulary.SurfaceMemberKind;
pub const SurfaceLazyDeclaration = vocabulary.SurfaceLazyDeclaration;
pub const SurfaceAccessor = vocabulary.SurfaceAccessor;
pub const SurfaceConstant = vocabulary.SurfaceConstant;
pub const SurfaceEmptyCollection = vocabulary.SurfaceEmptyCollection;
pub const SurfaceLazyOwner = vocabulary.SurfaceLazyOwner;
pub const SurfaceMemberPlacement = vocabulary.SurfaceMemberPlacement;
pub const SurfaceFunctionVisibility = vocabulary.SurfaceFunctionVisibility;
pub const SurfaceMemberOptions = vocabulary.SurfaceMemberOptions;
pub const SurfaceInstallation = vocabulary.SurfaceInstallation;
pub const ObjectSurfacePrototype = vocabulary.ObjectSurfacePrototype;
pub const ObjectSurfaceIntegrity = vocabulary.ObjectSurfaceIntegrity;
pub const ObjectSurfaceOptions = vocabulary.ObjectSurfaceOptions;
pub const NativeModuleDefaultPolicy = vocabulary.NativeModuleDefaultPolicy;
pub const NativeModuleDefaultSurface = vocabulary.NativeModuleDefaultSurface;
pub const FocusedEngineIntegrationKind = vocabulary.FocusedEngineIntegrationKind;
pub const FocusedEngineIntegrationOptions = vocabulary.FocusedEngineIntegrationOptions;
pub const StringCoercionInput = vocabulary.StringCoercionInput;
pub const StringTypeErrorFormat = vocabulary.StringTypeErrorFormat;
pub const BufferTransferPolicy = vocabulary.BufferTransferPolicy;
