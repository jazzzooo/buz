//! Semantic type normalization and conversion metadata.
const mod_wire = @import("wire.zig");
const mod_cpp_facts = @import("cpp_facts.zig");
const mod_typescript = @import("typescript.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const plans = @import("plans.zig");
const structural = @import("../structural.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;
const vocabulary = ir.vocabulary;

pub const StringProjection = projection: {
    const info = @typeInfo(schema.String).@"struct";
    const names = info.field_names ++ [_][]const u8{"kind"};
    const fields = info.field_types ++ [_]type{ir.StringKind};
    break :projection @Struct(.auto, null, names, fields, &@splat(.{}));
};

pub const BufferProjection = struct {
    effective_mode: ir.BufferMode,
    source: ir.BufferSource,
    access: ir.BufferAccess,
    allow_detached: bool,
    allow_shared: bool,
    copy_fallback: vocabulary.BufferCopyFallback = .allow,
    source_attachment: vocabulary.BufferSourceAttachment = .optional,
    snapshot_resizable_on_retention: bool = false,
    transfer_policy: ir.BufferTransferPolicy = .reject,
    result_representation: ir.BufferResultRepresentation,
    result_representation_explicit: bool,

    pub fn allowsArrayBuffer(buffer: BufferProjection) bool {
        return buffer.source == .array_buffer_or_view;
    }

    pub fn requiresIntegerTypedArray(buffer: BufferProjection) bool {
        return buffer.source.isIntegerTypedArray();
    }

    pub fn requiresUint8Array(buffer: BufferProjection) bool {
        return buffer.source == .uint8_array;
    }

    pub fn requiresUint32Array(buffer: BufferProjection) bool {
        return buffer.source == .uint32_array;
    }

    pub fn isWritable(buffer: BufferProjection) bool {
        return buffer.access == .read_write;
    }
};

pub const Metadata = struct {
    name_hash: u64,
    cpp_name: ?[]const u8,
    is_system_error_payload: bool,
    sequence_container_match: ?ir.CppBrandMatchId,
};

pub const Projection = struct {
    semantic: []const u8,
    conversion_codec: std.meta.Tag(plans.InputCodec) = .none,
    scalar_kind: ?ir.ScalarKind = null,
    integer_representation: ?ir.IntegerRepresentation = null,
    js_value_kind: ?ir.JSValueKind = null,
    string: ?StringProjection = null,
    buffer: ?BufferProjection = null,
    typescript: []const u8,
    input_typescript: ?[]const u8 = null,
    resources: ResourceThreads = .{},

    pub fn inputTypeScript(value: *const Projection) []const u8 {
        return value.input_typescript orelse value.typescript;
    }
};

/// Normalizes every collected type, interning the types metadata reaches.
pub fn normalizeAll(n: *Normalizer, wires: *mod_wire.Builder) Error!void {
    var index: usize = 0;
    while (index < n.raw_types.items.len) : (index += 1) {
        const normalized = try normalizeType(n, wires, .of(index), n.raw_types.items[index]);
        try n.types.append(n.arena, normalized.value);
        try n.type_metadata.append(n.arena, normalized.metadata);
    }
    n.projection_ready = try n.arena.alloc(bool, n.types.items.len);
    n.type_projections = try n.arena.alloc(Projection, n.types.items.len);
    @memset(n.projection_ready, false);
    for (0..n.types.items.len) |id| _ = try projection(n, .of(id));
    try plans.planAll(n);
}

/// Interns a type reached after collection, with its children.
pub fn ensure(n: *Normalizer, t: schema.Type) Error!ir.TypeId {
    try normalize.appendTypeTree(n, t);
    return n.typeId(t);
}

pub fn normalizeBrandMatch(n: *Normalizer, brand: schema.Brand) Error!ir.CppBrandMatchId {
    const cpp_match: ir.CppBrandMatch = switch (brand.matcher) {
        .instance_class => |instance| .{ .class_instance = .{
            .class = .of(n.classId(instance.class) orelse return n.reject(brand.name, "class brand refers to a class absent from the normalized binding manifest", .{})),
            .match = switch (instance.match) {
                .instance => .instance,
                .initial_structure => .initial_structure,
            },
        } },
        .realm => |matcher| .{ .realm = .{ .symbol = matcher.symbol, .header = matcher.header } },
        .value => |matcher| .{ .value = .{ .symbol = matcher.symbol, .header = matcher.header } },
        .dynamic_cast => |matcher| .{ .dynamic_cast = .{ .type_name = matcher.type_name, .header = matcher.header } },
    };
    return .of((try n.cpp_brand_matches.getOrPut(n.arena, cpp_match)).index);
}

pub fn normalizeBrandValue(n: *Normalizer, brand: schema.Brand) Error!ir.Brand {
    const cpp_match = try normalizeBrandMatch(n, brand);
    const named = try n.brand_matches_by_name.getOrPut(n.arena, brand.name);
    if (!named.found_existing) {
        named.value_ptr.* = cpp_match;
    } else if (named.value_ptr.index != cpp_match.index) {
        return n.reject(brand.name, "brands sharing this name use different matchers", .{});
    }
    return .{
        .brand_name = brand.name,
        .cpp_match = cpp_match,
        .promise_value_type = if (brand.promise_value) |value| try ensure(n, value.*) else null,
        .constructor_class = if (brand.constructor_class) |class| .of(n.classId(class) orelse return n.reject(brand.name, "constructor brand refers to a class absent from the normalized binding manifest", .{})) else null,
    };
}

fn normalizeType(n: *Normalizer, wires: *mod_wire.Builder, id: ir.TypeId, t: schema.Type) Error!struct { value: ir.Type, metadata: Metadata } {
    const name_hash = structural.hash(t);
    const data: ir.TypeData = switch (t) {
        .void => .void,
        .boolean => .boolean,
        .f64 => .f64,
        .utf8_string => .utf8_string,
        .native_instance => .native_instance,
        .engine_value => .engine_value,
        .node_path => .node_path,
        .any => |purpose| .{ .any = purpose },
        inline .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => |_, tag| @unionInit(ir.TypeData, @tagName(tag), {}),
        .discarded => .discarded,
        inline .dom_string, .usv_string, .byte_string => |string, tag| @unionInit(ir.TypeData, @tagName(tag), .{
            .string_thread_safe = string.thread_safe,
        }),
        .buffer => |buffer| .{ .buffer = .{
            .buffer_access = buffer.access,
            .buffer_result_representation = buffer.options.resultRepresentation(),
        } },
        .native_slice => |slice| .{ .native_slice = .{
            .native_slice_element = slice.element,
            .native_slice_access = slice.access,
        } },
        .lazy => |child| .{ .lazy = n.typeId(child.*) },
        .converted => |converted| value: {
            if (converted.converter.brand_cast) |cast| _ = try ensure(n, cast.match.*);
            break :value .{ .converted = .{ .native_type = n.typeId(converted.native) } };
        },
        .branded_value => |branded| .{ .branded_value = .{
            .brand = try normalizeBrandValue(n, branded.brand),
            .promise_reaction = if (branded.promise_reaction) |reaction| try promiseReaction(n, reaction) else null,
        } },
        .nominal_handle => |handle| blk: {
            const options = handle.options;
            const ownership: @FieldType(ir.NominalHandleType, "ownership") = switch (options.ownership) {
                .borrowed => .borrowed,
                .owned => owned: {
                    const owner: ir.NominalOwnershipId = .of(n.nominal_ownerships.items.len);
                    try n.nominal_ownerships.append(n.arena, .{
                        .destroy_thread = options.destroy_thread.?,
                        .release_symbol = try n.print("bun_bindgen_nominal_handle_release_{x:0>16}", .{name_hash}),
                        .cpp_release = options.cpp_release,
                        .byte_access = if (options.cpp_read_bytes) |read| .{
                            .symbol = try n.print("bun_bindgen_nominal_handle_read_bytes_{x:0>16}", .{name_hash}),
                            .cpp_read = read,
                        } else null,
                    });
                    break :owned .{ .owned = owner };
                },
            };
            break :blk .{ .nominal_handle = .{
                .nominal_handle_name = handle.name,
                .wire = try wires.handle(try n.print("BunBind_Nominal_{x:0>16}", .{name_hash})),
                .cpp_type = try mod_cpp_facts.Types.fromSchema(n, options.cpp_type),
                .const_pointee = options.const_pointee,
                .ownership = ownership,
                .zig_type = options.zig_type,
            } };
        },
        .external_ref => |external| value: {
            const reference: ir.ExternalRefId = .of(n.external_refs.items.len);
            try n.external_refs.append(n.arena, .{
                .external_name = external.name,
                .cpp_type = try mod_cpp_facts.Types.fromSchema(n, .{ .named = external.options.cpp_type }),
                .cpp_idl = try mod_cpp_facts.Types.fromSchema(n, .{ .named = external.options.cpp_idl }),
                .zig_type = external.options.zig_type,
                .brand = if (external.options.brand) |brand| try normalizeBrandValue(n, brand) else null,
                .wire = try wires.handle(try n.print("BunBind_External_{x:0>16}", .{name_hash})),
                .clone_symbol = try n.print("bun_bindgen_external_clone_{x:0>16}", .{name_hash}),
                .release_symbol = try n.print("bun_bindgen_external_release_{x:0>16}", .{name_hash}),
            });
            break :value .{ .external_ref = reference };
        },
        .class_ref => |class_ref| .{ .class_ref = .{
            .class = .of(n.classId(class_ref.target.?).?),
        } },
        .optional => |optional| .{ .optional = .{
            .child = n.typeId(optional.child.*),
            .optional_mode = optional.mode,
        } },
        .enumeration => |enumeration| .{ .enumeration = try normalizeEnumeration(n, enumeration, name_hash) },
        .dictionary => |dictionary| .{ .dictionary = try normalizeDictionary(n, dictionary) },
        .union_type => |union_type| .{ .union_type = try normalizeUnion(n, union_type) },
        .sequence => |sequence| .{ .sequence = .{ .child = n.typeId(sequence.child) } },
        .record => |record| .{ .record = .{
            .key_type = n.typeId(record.key),
            .value_type = n.typeId(record.value),
        } },
        .callback => |callback| value: {
            const callback_id: ir.CallbackId = .of(n.callbacks.items.len);
            try n.callbacks.append(n.arena, .{ .id = callback_id, .type = id, .callback_name = callback.name });
            break :value .{ .callback = callback_id };
        },
    };
    return .{
        .value = .{ .id = id, .data = data },
        .metadata = .{
            .name_hash = name_hash,
            .cpp_name = switch (t) {
                .dictionary => |dictionary| dictionary.options.cpp_name orelse try n.print("BunBindgenDictionary_{x:0>16}", .{name_hash}),
                .union_type => |union_type| union_type.options.cpp_name orelse try n.print("BunBindgenUnion_{x:0>16}", .{name_hash}),
                else => null,
            },
            .is_system_error_payload = structural.eql(t, schema.system_error_payload),
            .sequence_container_match = if (t == .sequence and t.sequence.options.container == .concrete_array)
                try normalizeBrandMatch(n, schema.brandOf(schema.js_array))
            else
                null,
        },
    };
}

fn reactionDeclaration(n: *Normalizer, comptime Id: type, name: []const u8, location: []const u8) Error!Id {
    const declarations = if (Id == ir.EngineShimId) n.declared_engine_shims.items else n.declared_native_exports.items;
    for (declarations, 0..) |declaration, index| {
        const declaration_name = if (Id == ir.EngineShimId) declaration.shim.name else declaration.native_export.name;
        if (std.mem.eql(u8, declaration.module_name, "promise_reactions") and std.mem.eql(u8, declaration_name, name)) return .of(index);
    }
    return n.reject(location, "promise reaction context requires promise_reactions.{s}", .{name});
}

fn promiseReaction(n: *Normalizer, reaction: schema.PromiseReactionContext) Error!ir.PromiseReactionId {
    const location = try n.print("promise_reactions.{s}", .{reaction.name});
    const cpp_types = mod_cpp_facts.Types;
    const owner_type = switch (reaction.owner_reference) {
        .nominal_handle => |handle| try cpp_types.fromSchema(n, handle.options.cpp_type),
        .external_ref => |external| try cpp_types.fromSchema(n, .{ .named = external.options.cpp_type }),
        else => return n.reject(location, "promise reaction owners require a nominal handle or external reference", .{}),
    };
    const value: ir.PromiseReactionContext = .{
        .context_name = reaction.name,
        .owner_type = owner_type,
        .create = try reactionDeclaration(n, ir.EngineShimId, try n.print("{s}Create", .{reaction.name}), location),
        .adopt = try reactionDeclaration(n, ir.EngineShimId, try n.print("{s}Adopt", .{reaction.name}), location),
        .attach = try reactionDeclaration(n, ir.EngineShimId, try n.print("{s}Attach", .{reaction.name}), location),
        .take = try reactionDeclaration(n, ir.EngineShimId, try n.print("{s}Take", .{reaction.name}), location),
        .destroy = try reactionDeclaration(n, ir.NativeExportId, try n.print("{s}Destroy", .{reaction.name}), location),
    };
    const id: ir.PromiseReactionId = .of(n.promise_reactions.items.len);
    try n.promise_reactions.append(n.arena, value);
    return id;
}

fn normalizeEnumeration(n: *Normalizer, enumeration: *const schema.Enumeration, name_hash: u64) Error!ir.EnumerationId {
    const options = enumeration.options;
    const values = try n.arena.alloc(ir.EnumerationValue, enumeration.values.len);
    for (enumeration.values, values, 0..) |value, *normalized, index| {
        const native: u16 = @intCast(value.options.native_value orelse index + @intFromBool(!options.internal_module_registry));
        normalized.* = .{
            .value_name = value.name,
            .js_value = value.value,
            .native_value = native,
        };
    }
    const id: ir.EnumerationId = .of(n.enumerations.items.len);
    try n.enumerations.append(n.arena, .{
        .enumeration_name = enumeration.name,
        .enumeration_values = values,
        .header = if (options.error_catalog) .error_codes else if (options.internal_module_registry) .internal_modules else .shared,
        .tag = switch (options.tag) {
            .u8 => .u8,
            .u16 => .u16,
        },
        .cpp_name = options.cpp_name orelse try n.print("BunBindgenEnumeration_{x:0>16}", .{name_hash}),
    });
    return id;
}

pub fn dictionaryFieldPresence(options: schema.DictionaryFieldOptions) ir.DictionaryFieldPresence {
    return if (options.required) switch (options.missing_required) {
        .reject, .failure => .required_reject,
        .convert_undefined => .required_convert_undefined,
    } else if (options.default_value != null) .default_value else .optional;
}

fn normalizeDictionary(n: *Normalizer, dictionary: *const schema.Dictionary) Error!ir.DictionaryType {
    const fields = try n.arena.alloc(ir.DictionaryField, dictionary.fields.len);
    for (dictionary.fields, fields) |field, *normalized| {
        const field_options = field.options;
        normalized.* = .{
            .field_name = field.name,
            .field_type = n.typeId(field.type),
            .storage = if (dictionaryFieldPresence(field_options) == .optional) .optional else .direct,
        };
    }
    return .{
        .dictionary_name = dictionary.name,
        .dictionary_fields = fields,
    };
}

fn normalizeUnion(n: *Normalizer, union_type: *const schema.Union) Error!ir.UnionType {
    const members = try n.arena.alloc(ir.UnionMember, union_type.members.len);
    for (union_type.members, members) |member, *normalized| {
        normalized.* = .{
            .member_name = member.name,
            .member_type = n.typeId(normalize.effectiveUnionMemberType(member)),
        };
    }
    return .{
        .union_name = union_type.name,
        .union_members = members,
    };
}

pub const UnionSelectorValue = struct { value_name: []const u8, js_value: []const u8, aliases: []const []const u8 };

pub fn selectorValue(member_name: []const u8, selector: ?*const schema.Enumeration) UnionSelectorValue {
    if (selector) |enumeration| {
        for (enumeration.values) |value| {
            if (std.mem.eql(u8, member_name, value.name)) return .{
                .value_name = value.name,
                .js_value = value.value,
                .aliases = value.options.aliases,
            };
        }
        unreachable;
    }
    return .{ .value_name = member_name, .js_value = member_name, .aliases = &.{} };
}

fn projection(n: *Normalizer, id: ir.TypeId) Error!Projection {
    const ready = &n.projection_ready[id.index];
    const value = &n.type_projections[id.index];
    if (!ready.*) {
        value.* = try project(n, id);
        ready.* = true;
    }
    return value.*;
}

const ResourceThreads = struct {
    clone: ir.ResourceThread = .any,
    access: ir.ResourceThread = .any,
    encode: ir.ResourceThread = .any,
    decode: ir.ResourceThread = .any,
    destroy: ir.ResourceThread = .any,
};

const vm_resources: ResourceThreads = .{ .clone = .vm, .access = .vm, .encode = .vm, .decode = .vm, .destroy = .vm };
const lease_resources: ResourceThreads = .{ .clone = .vm, .encode = .vm, .destroy = .vm };

fn mergeResources(left: ResourceThreads, right: ResourceThreads) ResourceThreads {
    var result: ResourceThreads = undefined;
    inline for (@typeInfo(ResourceThreads).@"struct".field_names) |name| {
        @field(result, name) = mergeThread(@field(left, name), @field(right, name));
    }
    return result;
}

fn mergeThread(left: ir.ResourceThread, right: ir.ResourceThread) ir.ResourceThread {
    return if (left == .vm or right == .vm) .vm else if (left == .current or right == .current) .current else .any;
}

fn conversionCodec(kind: ir.TypeKind) std.meta.Tag(plans.InputCodec) {
    return switch (kind) {
        .void => .none,
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => .integer,
        .f64 => .number,
        .any, .engine_value => .js_value,
        .dom_string, .usv_string, .byte_string => .string,
        inline .boolean, .discarded, .branded_value, .lazy, .converted, .utf8_string, .node_path, .buffer, .native_slice, .callback, .optional, .enumeration, .dictionary, .union_type, .sequence, .record, .nominal_handle, .class_ref, .external_ref, .native_instance => |tag| @field(std.meta.Tag(plans.InputCodec), @tagName(tag)),
    };
}

fn integerProjection(
    n: *Normalizer,
    scalar_kind: ir.ScalarKind,
    representation: ir.IntegerRepresentation,
) Error!Projection {
    return .{
        .semantic = try n.print("{s}{s}", .{ @tagName(scalar_kind), switch (representation) {
            .number => "",
            .bigint => " represented as bigint",
            .number_or_bigint => " represented as number or bigint",
        } }),
        .scalar_kind = scalar_kind,
        .integer_representation = representation,
        .typescript = switch (representation) {
            .number => "number",
            .bigint => "bigint",
            .number_or_bigint => "number | bigint",
        },
    };
}

fn brandedSemantic(n: *Normalizer, branded: ir.BrandedValueType) Error![]const u8 {
    if (branded.brand.promise_value_type) |value| {
        return n.print("promise({s})", .{(try projection(n, value)).typescript});
    }
    return n.print("branded({s})", .{branded.brand.brand_name});
}

fn brandedTypeScript(n: *Normalizer, id: ir.TypeId, branded: ir.BrandedValueType) Error![]const u8 {
    if (branded.brand.promise_value_type) |value| {
        return n.print("Promise<{s}>", .{(try projection(n, value)).typescript});
    }
    return n.rawType(id).branded_value.brand.typescript_type;
}

fn callbackTypeScript(n: *Normalizer, id: ir.TypeId) Error![]const u8 {
    const raw = n.rawType(id).callback;
    var text: std.Io.Writer.Allocating = .init(n.arena);
    const writer = &text.writer;
    writer.writeAll("((") catch return error.OutOfMemory;
    if (raw.options.receiver) |receiver| {
        writer.print("this: {s}", .{(try projection(n, n.typeId(receiver))).typescript}) catch return error.OutOfMemory;
    }
    for (raw.args, 0..) |argument, index| {
        if (index != 0 or raw.options.receiver != null) writer.writeAll(", ") catch return error.OutOfMemory;
        const argument_type = (try projection(n, n.typeId(normalize.effectiveArgumentType(argument)))).typescript;
        if (argument.options.rest)
            writer.print("...{s}: {s}[]", .{ argument.name, argument_type }) catch return error.OutOfMemory
        else
            writer.print("{s}: {s}", .{ argument.name, argument_type }) catch return error.OutOfMemory;
    }
    const return_type = (try projection(n, n.typeId(raw.result))).typescript;
    // Parenthesized so the arrow type composes into union projections.
    writer.print(") => {s})", .{return_type}) catch return error.OutOfMemory;
    return text.written();
}

fn bufferTypeScript(source: ir.BufferSource) []const u8 {
    return switch (source) {
        .array_buffer_or_view => "ArrayBuffer | ArrayBufferView",
        .view => "ArrayBufferView",
        .integer_typed_array => "Int8Array | Uint8Array | Uint8ClampedArray | Int16Array | Uint16Array | Int32Array | Uint32Array | BigInt64Array | BigUint64Array",
        .uint8_array => "Uint8Array",
        .uint32_array => "Uint32Array",
    };
}

fn bufferProjection(n: *Normalizer, buffer: schema.Buffer) Error!Projection {
    const options = buffer.options;
    const source = buffer.source;
    const access = buffer.access;
    const result_representation = options.resultRepresentation();
    const effective = buffer.mode;
    const source_name: []const u8 = switch (source) {
        .array_buffer_or_view => "buffer",
        .view => "buffer_view",
        .integer_typed_array => "writable_integer_typed_array",
        .uint8_array => "uint8_array",
        .uint32_array => "uint32_array",
    };
    const semantic = if (access == .read_write and source != .integer_typed_array)
        try n.print("writable_{s}", .{source_name})
    else
        source_name;
    return .{
        .semantic = switch (result_representation) {
            .array_buffer => "array_buffer",
            .node_buffer => "node_buffer",
            .uint8_array => if (options.allow_detached) semantic else try n.print("non_detached_{s}", .{semantic}),
            else => @tagName(result_representation),
        },
        .typescript = switch (result_representation) {
            .array_buffer => "ArrayBuffer",
            .uint8_array => bufferTypeScript(source),
            .node_buffer => "Buffer",
            else => result_representation.jsClassName(),
        },
        .buffer = .{
            .effective_mode = effective,
            .source = source,
            .access = access,
            .allow_detached = options.allow_detached,
            .allow_shared = options.allow_shared,
            .copy_fallback = options.copy_fallback,
            .source_attachment = options.source_attachment,
            .snapshot_resizable_on_retention = effective == .lease and access == .read_only and options.copy_fallback == .allow and options.source_attachment == .optional,
            .transfer_policy = options.transfer_policy,
            .result_representation = result_representation,
            .result_representation_explicit = options.result_representation != null,
        },
        .resources = switch (effective) {
            .copy => .{},
            .lease => lease_resources,
        },
    };
}

fn nativeSliceProjection(n: *Normalizer, slice: ir.NativeSliceType) Error!Projection {
    const element: []const u8 = switch (slice.native_slice_element) {
        .uint8 => "u8",
        .uint16 => "u16",
        .uint32 => "u32",
        .uint64 => "u64",
    };
    const mutable = slice.native_slice_access == .read_write;
    return .{
        .semantic = if (mutable) try n.print("native_mutable_slice({s})", .{element}) else try n.print("native_slice({s})", .{element}),
        .typescript = "never",
        .resources = .{},
    };
}

fn project(n: *Normalizer, id: ir.TypeId) Error!Projection {
    const t = n.irType(id).*;
    var result: Projection = switch (t.data) {
        .void => .{
            .semantic = "void",
            .typescript = "void",
        },
        .boolean => .{
            .semantic = "boolean",
            .scalar_kind = .boolean,
            .typescript = "boolean",
        },
        inline .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => |_, kind| try integerProjection(n, @field(ir.ScalarKind, @tagName(kind)), @field(n.rawType(id), @tagName(kind)).representation orelse .number),
        .f64 => .{
            .semantic = "f64",
            .scalar_kind = .f64,
            .typescript = "number",
        },
        .any => |purpose| .{
            .semantic = try n.print("any({t})", .{purpose}),
            .js_value_kind = .any,
            .typescript = "unknown",
            .resources = vm_resources,
        },
        .discarded => discarded_value: {
            const discarded = n.rawType(id).discarded;
            break :discarded_value .{
                .semantic = switch (discarded.match) {
                    .semantic_type => "discarded",
                    .null_literal => "null literal",
                    .undefined_literal => "undefined literal",
                    .false_literal => "false literal",
                    .number_literal => |number| try n.print("number literal(0x{x:0>16})", .{@as(u64, @bitCast(number))}),
                },
                .scalar_kind = .discarded,
                .typescript = switch (discarded.match) {
                    .semantic_type => (try projection(n, n.typeId(discarded.match_type.*))).typescript,
                    .null_literal => "null",
                    .undefined_literal => "undefined",
                    .false_literal => "false",
                    .number_literal => "number",
                },
                .input_typescript = if (discarded.match == .semantic_type) (try projection(n, n.typeId(discarded.match_type.*))).input_typescript else null,
            };
        },
        .branded_value => |branded| .{
            .semantic = if (branded.promise_reaction) |reaction|
                try n.print("promise_reaction_context({s})", .{n.get(reaction).context_name})
            else
                try brandedSemantic(n, branded),
            .js_value_kind = .branded,
            .typescript = try brandedTypeScript(n, id, branded),
            .resources = vm_resources,
        },
        .engine_value => .{
            .semantic = "engine_value",
            .js_value_kind = .engine_value,
            .typescript = "unknown",
            .resources = vm_resources,
        },
        .lazy => |child_id| blk: {
            const child = try projection(n, child_id);
            break :blk .{
                .semantic = try n.print("lazy({s})", .{child.semantic}),
                .typescript = child.typescript,
                .input_typescript = child.input_typescript,
                .buffer = child.buffer,
                .resources = mergeResources(vm_resources, child.resources),
            };
        },
        .converted => |converted| blk: {
            const native = try projection(n, converted.native_type);
            const raw = n.rawType(id).converted;
            const match = try projection(n, n.typeId(raw.match));
            const converter = raw.converter;
            break :blk .{
                .semantic = switch (converter.kind) {
                    .brand_cast => try n.print("brand_cast({s}, failure={t}, input={t})", .{
                        native.semantic,
                        converter.brand_cast.?.failure,
                        converter.brand_cast.?.input,
                    }),
                    .json_stringify => "json_stringified_string",
                    .headers_init => try n.print("headers_init({s})", .{converter.name}),
                    .property_key => "property_key",
                    .custom => try n.print("converted({s}, {s})", .{ native.semantic, converter.name }),
                },
                .typescript = match.typescript,
                .input_typescript = match.input_typescript,
                .scalar_kind = native.scalar_kind,
                .integer_representation = native.integer_representation,
                .js_value_kind = native.js_value_kind,
                .string = native.string,
                .buffer = native.buffer,
                .resources = native.resources,
            };
        },
        inline .dom_string, .usv_string, .byte_string => |_, kind| try stringProjection(n, @field(n.rawType(id), @tagName(kind)), @field(ir.StringKind, @tagName(kind))),
        .utf8_string => .{
            .semantic = "utf8_string",
            .typescript = "string",
            .resources = .{},
        },
        .node_path => .{
            .semantic = "node_path",
            .typescript = if (n.rawType(id).node_path.boxed_strings) "string | Uint8Array | URL | String" else "string | Uint8Array | URL",
            .resources = .{},
        },
        .buffer => try bufferProjection(n, n.rawType(id).buffer.*),
        .native_slice => |slice| try nativeSliceProjection(n, slice),
        .callback => |callback| .{
            .semantic = n.get(callback).callback_name,
            .typescript = try callbackTypeScript(n, id),
            .resources = vm_resources,
        },
        .optional => |optional| blk: {
            const child = try projection(n, optional.child);
            break :blk .{
                .semantic = try n.print("{s}optional({s})", .{ switch (optional.optional_mode) {
                    .nullable => "",
                    .nullish => "nullish-",
                    .undefined => "undefined-",
                    .falsy => "falsy-",
                    .matched => "matched-",
                    .nullish_or_empty_string => "nullish-or-empty-string-",
                }, child.semantic }),
                .typescript = try mod_typescript.optional(n, optional, child.typescript, false),
                .input_typescript = try mod_typescript.optional(n, optional, child.inputTypeScript(), true),
                .buffer = child.buffer,
                .resources = child.resources,
            };
        },
        .enumeration => |enumeration| .{
            .semantic = n.get(enumeration).enumeration_name,
            .typescript = n.get(enumeration).enumeration_name,
        },
        .dictionary => |dictionary| blk: {
            var resources: ResourceThreads = .{};
            for (dictionary.dictionary_fields) |field| resources = mergeResources(resources, (try projection(n, field.field_type)).resources);
            break :blk .{
                .semantic = dictionary.dictionary_name,
                .typescript = if (n.rawType(id).dictionary.options.result_class) |class| class.class.name else dictionary.dictionary_name,
                .resources = resources,
            };
        },
        .union_type => |union_type| blk: {
            var resources: ResourceThreads = .{};
            for (union_type.union_members) |member| resources = mergeResources(resources, (try projection(n, member.member_type)).resources);
            break :blk .{
                .semantic = union_type.union_name,
                .typescript = union_type.union_name,
                .resources = resources,
            };
        },
        .sequence => |sequence| blk: {
            const child = try projection(n, sequence.child);
            const options = n.rawType(id).sequence.options;
            const kind_name: []const u8 = if (options.flavor == .frozen_array)
                "frozen_array"
            else switch (options.container) {
                .iterable => if (options.snapshot_elements) "snapshot_iterable_sequence" else "iterable_sequence",
                .array_like => if (options.snapshot_elements) "snapshot_array_like_sequence" else "array_like_sequence",
                .array, .concrete_array => if (options.element_access == .direct_index) "direct_index_sequence" else if (options.snapshot_elements) "snapshot_sequence" else "sequence",
            };
            break :blk .{
                .semantic = try n.print("{s}({s})", .{ kind_name, child.semantic }),
                .typescript = try mod_typescript.sequence(n, options.container, child.typescript),
                .input_typescript = if (child.input_typescript) |input| try mod_typescript.sequence(n, options.container, input) else null,
                .resources = child.resources,
            };
        },
        .record => |record| blk: {
            const key = try projection(n, record.key_type);
            const value = try projection(n, record.value_type);
            break :blk .{
                .semantic = try n.print("record({s}, {s})", .{ key.semantic, value.semantic }),
                .typescript = try mod_typescript.record(n, value.typescript),
                .input_typescript = if (value.input_typescript) |input| try mod_typescript.record(n, input) else null,
                .resources = mergeResources(key.resources, value.resources),
            };
        },
        .class_ref => reference: {
            const class = n.rawType(id).class_ref.target.?;
            break :reference .{
                .semantic = try n.print("class_ref({s}.{s})", .{ class.module, class.class }),
                .typescript = class.class,
                .resources = vm_resources,
            };
        },
        .external_ref => |external| .{
            .semantic = n.get(external).external_name,
            .typescript = n.get(external).external_name,
            .resources = vm_resources,
        },
        .native_instance => .{
            .semantic = "native_instance",
            .typescript = "never",
            .resources = vm_resources,
        },
        .nominal_handle => |handle| .{
            .semantic = handle.nominal_handle_name,
            .conversion_codec = .nominal_handle,
            .typescript = "never",
            .resources = .{
                .access = n.rawType(id).nominal_handle.options.access_thread.?,
                .destroy = switch (handle.ownership) {
                    .borrowed => .any,
                    .owned => |owner| n.get(owner).destroy_thread,
                },
            },
        },
    };
    result.conversion_codec = conversionCodec(t.kind());
    return result;
}

fn stringProjection(n: *Normalizer, string: schema.String, comptime kind: ir.StringKind) Error!Projection {
    const kind_name = @tagName(kind);
    const semantic = try n.print("{s}{s}{s}{s}{s}{s}{s}{s}", .{
        if (string.thread_safe) "thread_safe_" else "",
        if (string.strict_failure != null) "strict_" else "",
        if (string.input_failure != null) "input_checked_" else "",
        if (string.conversion == .coerce) "coerced_" else "",
        switch (string.coercion_input) {
            .any => "",
            .string_or_boxed => "string_or_boxed_",
            .object_only => "object_",
        },
        if (string.nullish_failure != null) "non_nullish_" else "",
        if (string.empty_rejection != null) "non_empty_" else "",
        kind_name,
    });
    var projected: StringProjection = undefined;
    inline for (@typeInfo(StringProjection).@"struct".field_names) |name| {
        @field(projected, name) = if (comptime std.mem.eql(u8, name, "kind")) kind else @field(string, name);
    }
    return .{
        .semantic = semantic,
        .string = projected,
        .typescript = "string",
        .input_typescript = if (string.coercion_input == .object_only) "object" else null,
        .resources = if (string.thread_safe) .{} else vm_resources,
    };
}
