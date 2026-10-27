//! Schema rules. Every declaration is checked whether or not the target
//! exposes it; each violation is a diagnostic at the declaration.
const mod_classes = @import("classes.zig");
const mod_converter_declarations = @import("converter_declarations.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const InputPlanId = plans.InputPlanId;
const schema = @import("bindgen_schema");
const normalize = @import("../normalize.zig");
const structural = @import("../structural.zig");
const plans = @import("plans.zig");
const cpp_facts = @import("cpp_facts.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;
const Type = schema.Type;

pub fn input(n: *Normalizer) Error!void {
    for (n.input.features, 0..) |feature, index| {
        if (feature.len == 0) try n.fail("", "binding feature name cannot be empty", .{});
        if (std.mem.indexOfScalar(u8, feature, 0) != null) try n.fail("", "binding feature name cannot contain a null byte", .{});
        if (index > 0 and std.mem.order(u8, n.input.features[index - 1], feature) != .lt)
            try n.fail("", "binding normalization features must be sorted and unique", .{});
    }
}

pub fn schemas(n: *Normalizer) Error!void {
    var c: Checker = .{ .n = n };
    for (n.modules, 0..) |*module, index| {
        for (n.modules[0..index]) |previous| {
            if (!eqlText(previous.name, module.name)) continue;
            c.location = module.name;
            try c.fail("duplicate binding module name in binding schema: {s}", .{module.name});
            break;
        }
        try moduleRules(&c, module);
    }
    try manifestRules(&c);
    try classReferences(&c);
}

/// Rules over normalized plans: transports, resource contracts, and
/// converter contexts that only the planned IR exposes.
pub fn normalized(n: *Normalizer) Error!void {
    var c: Checker = .{ .n = n };
    n.class_declaration_order = try classDeclarationOrder(n);
    try internalRegistryRules(&c);
    try converterSignatures(&c);
    for (n.functions.items) |*function| try functionPlanRules(&c, function);
    for (n.overload_cases.items) |*function| try functionPlanRules(&c, function);
    for (n.engine_shims.items) |*shim| try engineShimPlanRules(&c, shim);
    for (n.native_exports.items) |*native_export| try nativeExportPlanRules(&c, native_export);
    for (n.callbacks.items) |*callback| try callbackPlanRules(&c, callback);
    for (n.classes.items) |*class| try classPlanRules(&c, class);
    for (n.promise_reactions.items) |reaction| {
        const destroy = n.native_exports.items[reaction.destroy.index];
        if (destroy.exposed) continue;
        try c.at(destroy.module_name, destroy.export_name);
        try c.fail("promise reaction contexts require an exposed destroy export", .{});
    }
    for (n.types.items[0..n.binding_type_count]) |t| {
        if (t.data != .class_ref) continue;
        const class = n.classes.items[t.data.class_ref.class.index];
        if (class.representation != .engine or class.exposed) continue;
        try c.at(class.module_name, class.class_name);
        try c.fail("class references to unexposed engine classes are not supported: {s}", .{class.class_name});
    }
}

const Checker = struct {
    n: *Normalizer,
    location: []const u8 = "",
    /// Composite payloads whose context-free rules have been checked.
    checked: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn fail(c: *Checker, comptime format: []const u8, args: anytype) Error!void {
        try c.n.fail(c.location, format, args);
    }

    fn firstCheck(c: *Checker, pointer: anytype) Error!bool {
        const entry = try c.checked.getOrPut(c.n.arena, @intFromPtr(pointer));
        return !entry.found_existing;
    }

    fn at(c: *Checker, module_name: []const u8, declaration: []const u8) Error!void {
        c.location = try c.n.print("{s}.{s}", .{ module_name, declaration });
    }
};

// ─── text ───

pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or !(name[0] == '_' or std.ascii.isAlphabetic(name[0]))) return false;
    for (name[1..]) |byte| if (!(byte == '_' or std.ascii.isAlphanumeric(byte))) return false;
    return true;
}

fn identifier(c: *Checker, name: []const u8, category: []const u8) Error!void {
    if (name.len == 0) return c.fail("{s} name cannot be empty", .{category});
    if (!isIdentifier(name)) return c.fail("{s} name is not an identifier: {s}", .{ category, name });
}

const c_or_cpp_keywords = std.StaticStringMap(void).initComptime(.{
    .{"_Alignas"},       .{"_Alignof"},        .{"_Atomic"},       .{"_Bool"},
    .{"_Complex"},       .{"_Generic"},        .{"_Imaginary"},    .{"_Noreturn"},
    .{"_Static_assert"}, .{"_Thread_local"},   .{"alignas"},       .{"alignof"},
    .{"and"},            .{"and_eq"},          .{"asm"},           .{"atomic_cancel"},
    .{"atomic_commit"},  .{"atomic_noexcept"}, .{"auto"},          .{"bitand"},
    .{"bitor"},          .{"bool"},            .{"break"},         .{"case"},
    .{"catch"},          .{"char"},            .{"char8_t"},       .{"char16_t"},
    .{"char32_t"},       .{"class"},           .{"co_await"},      .{"co_return"},
    .{"co_yield"},       .{"compl"},           .{"concept"},       .{"const"},
    .{"const_cast"},     .{"consteval"},       .{"constexpr"},     .{"constinit"},
    .{"continue"},       .{"decltype"},        .{"default"},       .{"delete"},
    .{"do"},             .{"double"},          .{"dynamic_cast"},  .{"else"},
    .{"enum"},           .{"explicit"},        .{"export"},        .{"extern"},
    .{"false"},          .{"float"},           .{"for"},           .{"friend"},
    .{"goto"},           .{"if"},              .{"inline"},        .{"int"},
    .{"long"},           .{"mutable"},         .{"namespace"},     .{"new"},
    .{"noexcept"},       .{"not"},             .{"not_eq"},        .{"nullptr"},
    .{"operator"},       .{"or"},              .{"or_eq"},         .{"private"},
    .{"protected"},      .{"public"},          .{"register"},      .{"reinterpret_cast"},
    .{"requires"},       .{"return"},          .{"short"},         .{"signed"},
    .{"sizeof"},         .{"static"},          .{"static_assert"}, .{"static_cast"},
    .{"struct"},         .{"switch"},          .{"synchronized"},  .{"template"},
    .{"this"},           .{"thread_local"},    .{"throw"},         .{"true"},
    .{"try"},            .{"typedef"},         .{"typeid"},        .{"typename"},
    .{"union"},          .{"unsigned"},        .{"using"},         .{"virtual"},
    .{"void"},           .{"volatile"},        .{"wchar_t"},       .{"while"},
    .{"xor"},            .{"xor_eq"},
});

/// An identifier that names a field of a generated C or C++ wire struct.
fn wireIdentifier(c: *Checker, name: []const u8, category: []const u8) Error!void {
    if (!isIdentifier(name)) return identifier(c, name, category);
    if ((name.len >= 2 and name[0] == '_' and (name[1] == '_' or std.ascii.isUpper(name[1]))) or
        c_or_cpp_keywords.has(name) or
        std.mem.eql(u8, name, "errno") or
        std.mem.eql(u8, name, "unix") or
        std.mem.eql(u8, name, "linux"))
    {
        try c.fail("{s} name is reserved in the C/C++ wire ABI: {s}", .{ category, name });
    }
}

fn zigDeclPath(c: *Checker, path: []const u8, category: []const u8) Error!void {
    var components = std.mem.splitScalar(u8, path, '.');
    while (components.next()) |component| try identifier(c, component, category);
}

fn textAllowEmpty(c: *Checker, value: []const u8, category: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) try c.fail("{s} cannot contain a null byte", .{category});
}

fn text(c: *Checker, value: []const u8, category: []const u8) Error!void {
    if (value.len == 0) return c.fail("{s} cannot be empty", .{category});
    try textAllowEmpty(c, value, category);
}

fn asciiText(c: *Checker, value: []const u8, category: []const u8) Error!void {
    try text(c, value, category);
    for (value) |byte| if (!std.ascii.isAscii(byte)) return c.fail("{s} must be ASCII", .{category});
}

fn propertyName(c: *Checker, name: []const u8, category: []const u8) Error!void {
    try text(c, name, category);
    if (!std.unicode.utf8ValidateSlice(name)) try c.fail("{s} must be valid UTF-8", .{category});
}

fn conversionFailure(c: *Checker, failure: schema.ConversionFailure) Error!void {
    try asciiText(c, failure.message, "conversion error message");
    if (failure.kind == .code) try identifier(c, failure.kind.code, "conversion error code");
}

fn eqlText(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ─── type predicates ───

fn isInteger(t: Type) bool {
    return integerBounds(t) != null;
}

fn isString(t: Type) bool {
    return switch (t) {
        .dom_string, .usv_string, .byte_string => true,
        else => false,
    };
}

fn integerRepresentation(t: Type) ?schema.IntegerRepresentation {
    return switch (t) {
        inline .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => |integer| integer.representation,
        else => null,
    };
}

fn integerBounds(t: Type) ?schema.IntegerRange {
    return switch (t) {
        .i8 => .{ .min = std.math.minInt(i8), .max = std.math.maxInt(i8) },
        .u8 => .{ .min = 0, .max = std.math.maxInt(u8) },
        .i16 => .{ .min = std.math.minInt(i16), .max = std.math.maxInt(i16) },
        .u16 => .{ .min = 0, .max = std.math.maxInt(u16) },
        .i32 => .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
        .u32 => .{ .min = 0, .max = std.math.maxInt(u32) },
        .i64 => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
        .u64, .usize => .{ .min = 0, .max = std.math.maxInt(u64) },
        else => null,
    };
}

const effectiveArgumentType = normalize.effectiveArgumentType;
const effectiveUnionMemberType = normalize.effectiveUnionMemberType;

const TypeQuery = enum {
    contextual_discard,
    converted,
    lazy,
    owned_nominal,
    coerced_string,
    borrowed_engine_value,

    fn contains(comptime query: TypeQuery, t: Type) bool {
        const matches = switch (query) {
            .contextual_discard => t == .discarded and t.discarded.purpose == .contextual,
            .converted => t == .converted,
            .lazy => t == .lazy,
            .owned_nominal => t == .nominal_handle and t.nominal_handle.options.ownership == .owned,
            .coerced_string => isCoercingString(t),
            .borrowed_engine_value => t == .any or t == .branded_value or t == .engine_value,
        };
        if (matches) return true;
        return switch (t) {
            .optional => |optional| query.contains(optional.child.*),
            .sequence => |sequence| query.contains(sequence.child),
            .dictionary => |dictionary| for (dictionary.fields) |field| {
                if (query.contains(field.type)) break true;
            } else false,
            .union_type => |union_type| for (union_type.members) |member| {
                if (query.contains(effectiveUnionMemberType(member))) break true;
            } else false,
            .record => |record| query.contains(record.key) or query.contains(record.value),
            .lazy => |child| switch (query) {
                .owned_nominal, .borrowed_engine_value => false,
                else => query.contains(child.*),
            },
            .converted => |converted| switch (query) {
                .owned_nominal => false,
                .borrowed_engine_value => query.contains(converted.match),
                else => query.contains(converted.match) or query.contains(converted.native),
            },
            .callback => |callback| callback: {
                if (query != .converted) break :callback false;
                for (callback.args) |argument| {
                    if (query.contains(effectiveArgumentType(argument))) break :callback true;
                }
                break :callback query.contains(callback.result);
            },
            else => false,
        };
    }
};

fn containsContextualDiscard(t: Type) bool {
    return TypeQuery.contextual_discard.contains(t);
}

fn containsConverted(t: Type) bool {
    return TypeQuery.converted.contains(t);
}

pub fn typeContainsLazy(t: Type) bool {
    return TypeQuery.lazy.contains(t);
}

fn containsOwnedWireNominalHandle(t: Type) bool {
    return TypeQuery.owned_nominal.contains(t);
}

/// The operand a value conversion rule applies to.
fn conversionOperand(t: Type) Type {
    return switch (t) {
        .lazy => |child| conversionOperand(child.*),
        .optional => |optional| conversionOperand(optional.child.*),
        .converted => |converted| conversionOperand(converted.match),
        else => t,
    };
}

// ─── context-free type rules ───

/// Checks every node of a type tree against the rules its constructor
/// implies; shared subtrees are checked once.
fn typeTree(c: *Checker, t: Type) Error!void {
    switch (t) {
        .dom_string, .usv_string, .byte_string => |string| try stringRules(c, string),
        .discarded => |discarded| try typeTree(c, discarded.match_type.*),
        .lazy => |child| {
            if (!try c.firstCheck(child)) return;
            switch (child.*) {
                .void => try c.fail("a lazy binding value cannot contain void", .{}),
                .lazy => try c.fail("nested lazy binding values are redundant", .{}),
                .native_instance => try c.fail("native-instance is constructor-return-only and cannot be lazy", .{}),
                else => {},
            }
            try typeTree(c, child.*);
        },
        .converted => |converted| {
            if (!try c.firstCheck(converted)) return;
            try convertedRules(c, converted.*);
            try typeTree(c, converted.native);
            try typeTree(c, converted.match);
        },
        .buffer => |buffer| {
            if (!try c.firstCheck(buffer)) return;
            try bufferRules(c, buffer.*);
        },
        .callback => |callback| {
            if (!try c.firstCheck(callback)) return;
            try callbackRules(c, callback.*);
            if (callback.options.receiver) |receiver| try typeTree(c, receiver);
            for (callback.args) |argument| try typeTree(c, argument.type);
            try typeTree(c, callback.result);
        },
        .optional => |optional| {
            if (!try c.firstCheck(optional.child)) return;
            try optionalRules(c, optional);
            try typeTree(c, optional.child.*);
        },
        .enumeration => |enumeration| {
            if (!try c.firstCheck(enumeration)) return;
            try enumerationRules(c, enumeration.*);
        },
        .dictionary => |dictionary| {
            if (!try c.firstCheck(dictionary)) return;
            try dictionaryRules(c, dictionary.*);
            for (dictionary.fields) |field| try typeTree(c, field.type);
        },
        .union_type => |union_type| {
            if (!try c.firstCheck(union_type)) return;
            try unionRules(c, union_type.*);
            if (union_type.options.input_tag) |tag| if (tag.selector) |selector| try typeTree(c, selector);
            for (union_type.members) |member| try typeTree(c, member.type);
        },
        .sequence => |sequence| {
            if (!try c.firstCheck(sequence)) return;
            try sequenceRules(c, sequence.*);
            try typeTree(c, sequence.child);
        },
        .record => |record| {
            if (!try c.firstCheck(record)) return;
            try recordRules(c, record.*);
            try typeTree(c, record.key);
            try typeTree(c, record.value);
        },
        .nominal_handle => |handle| {
            if (!try c.firstCheck(handle)) return;
            try nominalHandleRules(c, handle.*);
        },
        .class_ref => |class_ref| try classRefRules(c, class_ref),
        .external_ref => |external| {
            if (!try c.firstCheck(external)) return;
            try externalRefRules(c, external.*);
        },
        .branded_value => |branded| {
            if (!try c.firstCheck(branded)) return;
            try brandedValueRules(c, branded.*);
            if (branded.brand.promise_value) |value| try typeTree(c, value.*);
            if (branded.promise_reaction) |reaction| try typeTree(c, reaction.owner_reference);
        },
        else => {},
    }
}

fn stringRules(c: *Checker, string: schema.String) Error!void {
    if (string.strict_failure) |failure| {
        if (string.conversion != .profile) try c.fail("a strict string cannot be changed to coercion", .{});
        if (string.coercion_input != .any)
            try c.fail("strict strings cannot declare coercion input restrictions", .{});
        if (string.nullish_failure != null or string.input_failure != null or string.type_error_format != .profile)
            try c.fail("strict strings cannot declare competing input failure policies", .{});
        try conversionFailure(c, failure);
    }
    if (string.type_error_format != .profile and string.coercion_input != .string_or_boxed)
        try c.fail("string type errors require a restricted coercion input", .{});
    if (string.input_failure) |failure| {
        if (string.coercion_input == .any or string.type_error_format != .profile)
            try c.fail("string input failures require an exclusive restricted-input diagnostic policy", .{});
        try conversionFailure(c, failure);
    }
    if (string.nullish_failure) |failure| try conversionFailure(c, failure);
    if (string.empty_rejection) |rejection| {
        try identifier(c, rejection.code, "empty string rejection error code");
        try asciiText(c, rejection.message, "empty string rejection message");
    }
}

fn bufferRules(c: *Checker, buffer: schema.Buffer) Error!void {
    const options = buffer.options;
    if (options.type_failure) |failure| {
        if (options.type_error_format != .profile)
            try c.fail("a buffer type failure cannot be combined with another type-error policy", .{});
        try conversionFailure(c, failure);
    }
    if (options.detached_failure) |failure| {
        if (options.allow_detached)
            try c.fail("a detached-buffer failure requires a buffer input that rejects detached storage", .{});
        try conversionFailure(c, failure);
    }
    if (options.transfer_policy != .reject and buffer.mode != .lease) try c.fail("transfer policy requires lease ownership", .{});
    if (options.source_attachment == .required and buffer.mode != .lease) try c.fail("source attachment requires lease ownership", .{});
    if (buffer.access == .read_write and buffer.mode != .lease) try c.fail("writable buffers require a lease", .{});
    if (buffer.mode != .lease and options.copy_fallback != .allow) try c.fail("copy fallback applies only to byte leases", .{});
}

fn brandRules(c: *Checker, brand: schema.Brand) Error!void {
    try identifier(c, brand.name, "brand");
    switch (brand.matcher) {
        .instance_class => |instance| try classNameRules(c, instance.class, "class values must name a class exported by a binding schema module"),
        .value => |matcher| {
            try text(c, matcher.symbol, "brand C++ matcher");
            try text(c, matcher.header, "brand C++ matcher header");
        },
        .realm => |matcher| {
            try text(c, matcher.symbol, "brand C++ matcher");
            try text(c, matcher.header, "brand C++ matcher header");
        },
        .dynamic_cast => |matcher| {
            try text(c, matcher.type_name, "brand C++ dynamic-cast type");
            try text(c, matcher.header, "brand C++ dynamic-cast header");
        },
    }
    try text(c, brand.typescript_type, "brand TypeScript type");
    if (brand.constructor_class) |class| try classNameRules(c, class, "class constructor values must name a class exported by a binding schema module");
}

fn classNameRules(c: *Checker, name: schema.ClassName, message: []const u8) Error!void {
    if (c.n.classId(name) == null) try c.fail("{s}", .{message});
}

fn externalRefRules(c: *Checker, external: schema.ExternalRef) Error!void {
    const options = external.options;
    try identifier(c, external.name, "external reference");
    try cppName(c, options.cpp_type);
    try cppName(c, options.cpp_idl);
    try text(c, options.cpp_declaration_header, "external reference C++ declaration header");
    try text(c, options.cpp_conversion_header, "external reference C++ conversion header");
    try cppName(c, options.cpp_match.symbol);
    try text(c, options.cpp_match.header, "external reference C++ matcher header");
    try zigDeclPath(c, options.zig_type, "external reference Zig type");
    if (options.brand) |brand| try brandRules(c, brand);
}

fn cppName(c: *Checker, name: []const u8) Error!void {
    var parts = std.mem.splitSequence(u8, name, "::");
    while (parts.next()) |part| {
        try identifier(c, part, "C++ type");
        if (c_or_cpp_keywords.has(part)) try c.fail("C++ type names cannot contain a reserved identifier: {s}", .{part});
    }
}

fn cppTypeRules(c: *Checker, value: schema.CppType) Error!void {
    switch (value) {
        .void, .int => {},
        .named => |name| try cppName(c, name),
        .pointer, .const_pointer => |child| {
            if (child.* == .function_pointer) try c.fail("function-pointer indirection requires a named alias", .{});
            try cppTypeRules(c, child.*);
        },
        .function_pointer => |function| {
            try cppTypeRules(c, function.result.*);
            for (function.parameters) |parameter| try cppTypeRules(c, parameter);
        },
        .specialization => |specialization| {
            try cppName(c, specialization.name);
            for (specialization.arguments) |argument| try cppTypeRules(c, argument);
        },
    }
}

fn isUnstructuredPointer(value: schema.CppType) bool {
    return switch (value) {
        .pointer, .const_pointer => |child| switch (child.*) {
            .void, .int, .pointer, .const_pointer => true,
            .named => |name| for ([_][]const u8{
                "char",    "char8_t",  "char16_t", "char32_t", "wchar_t",  "int8_t",    "uint8_t", "int16_t",             "uint16_t",
                "int32_t", "uint32_t", "int64_t",  "uint64_t", "intptr_t", "uintptr_t", "size_t",  "JSC::EncodedJSValue",
            }) |unstructured| {
                if (eqlText(name, unstructured)) break true;
            } else false,
            .function_pointer, .specialization => false,
        },
        .void, .int, .named, .function_pointer, .specialization => false,
    };
}

fn nominalHandleRules(c: *Checker, handle: schema.NominalHandle) Error!void {
    const name = handle.name;
    const options = handle.options;
    try identifier(c, name, "nominal handle");
    try cppTypeRules(c, options.cpp_type);
    for (options.cpp_declarations) |declaration| switch (declaration) {
        .structure, .class => |declared_name| try cppName(c, declared_name),
        .alias => |alias| {
            try cppName(c, alias.name);
            try cppTypeRules(c, alias.type);
        },
        .include => |include| try text(c, include.path, "nominal handle declaration header"),
    };
    if (options.c_struct) |tag| {
        try wireIdentifier(c, tag, "nominal handle C struct");
        const matches = switch (options.cpp_type) {
            .pointer => |child| !options.const_pointee and child.* == .named and eqlText(child.named, tag),
            .const_pointer => |child| options.const_pointee and child.* == .named and eqlText(child.named, tag),
            .void, .int, .named, .function_pointer, .specialization => false,
        };
        if (!matches) try c.fail("C nominal handles require the same global struct type in C++: {s}", .{name});
    }
    if (options.cpp_header) |header| try text(c, header, "nominal handle C++ header");
    if (options.cpp_read_bytes) |accessor| try identifier(c, accessor, "nominal handle C++ byte accessor");
    if (options.zig_type) |zig_type| {
        try zigDeclPath(c, zig_type, "nominal handle Zig type");
        if (eqlText(zig_type, "anyopaque")) try c.fail("nominal handles require a concrete Zig resource type", .{});
    }
    if (options.access_thread == null) try c.fail("nominal handles require an explicit access thread: {s}", .{name});
    if (isUnstructuredPointer(options.cpp_type)) {
        if (options.raw_pointer_escape) |reason| {
            try text(c, reason, "raw pointer escape reason");
        } else {
            try c.fail("unstructured nominal pointer handles require an explicit raw_pointer_escape reason: {s}", .{name});
        }
        if (options.cpp_read_bytes != null) try c.fail("nominal byte resources require a structured owner type: {s}", .{name});
    } else if (options.raw_pointer_escape != null) {
        try c.fail("raw_pointer_escape is only valid for unstructured pointer storage: {s}", .{name});
    }
    switch (options.ownership) {
        .borrowed => {
            if (options.cpp_read_bytes != null) try c.fail("borrowed nominal handles cannot expose owned byte storage", .{});
            if (options.cpp_release.len != 0) try c.fail("borrowed nominal handles cannot declare a C++ release implementation", .{});
            if (options.destroy_thread != null) try c.fail("borrowed nominal handles do not have a destruction contract", .{});
        },
        .owned => {
            try identifier(c, options.cpp_release, "owned nominal handle C++ release implementation");
            if (options.destroy_thread == null) try c.fail("owned nominal handles require an explicit destruction thread", .{});
        },
    }
}

fn brandedValueRules(c: *Checker, branded: schema.BrandedValue) Error!void {
    const options = branded.options;
    try brandRules(c, branded.brand);
    if (options.node_expected_types) |expected_types| {
        if (options.error_kind != .type or options.node_requirement != null or options.no_match_error != null)
            try c.fail("a branded type list requires an exclusive Node type-error policy", .{});
        if (expected_types.len < 2) try c.fail("a branded type list requires at least two types", .{});
        for (expected_types) |name| try asciiText(c, name, "Node expected type");
    }
    if (options.error_kind == .invalid_this) {
        if (options.node_requirement) |expected| {
            try asciiText(c, expected, "invalid-this receiver type name");
        } else {
            try c.fail("invalid-this brands require a receiver type name", .{});
        }
        if (options.expectation != null) try c.fail("invalid-this brands use node_requirement instead of expectation", .{});
    }
    if (options.no_match_error) |failure| {
        if (options.error_kind != .instance or options.expectation != null or options.node_requirement != null)
            try c.fail("a branded no-match error cannot be combined with another error policy", .{});
        try conversionFailure(c, failure);
    }
    if (branded.brand.promise_value) |value| {
        if (value.* == .lazy or value.* == .native_instance)
            try c.fail("a promise requires a JavaScript-visible settlement type", .{});
        try resultType(c, value.*, .zig);
    }
    if (branded.promise_reaction) |reaction| {
        try identifier(c, reaction.name, "promise reaction context");
        try identifier(c, reaction.tag, "promise reaction context tag");
    }
}

fn classRefRules(c: *Checker, class_ref: schema.ClassRef) Error!void {
    const options = class_ref.options;
    if (options.no_match_error) |failure| try conversionFailure(c, failure);
    if (options.node_expected_instances) |expected| {
        if (options.no_match_error != null)
            try c.fail("class reference diagnostics cannot combine literal and Node instance failures", .{});
        try asciiText(c, expected, "Node class-reference expected instances");
    }
    const target = class_ref.target orelse return;
    try identifier(c, target.module, "class-reference module");
    try identifier(c, target.class, "class reference");
    try classNameRules(c, target, "class references must name a class exported by a binding schema module");
}

fn callbackRules(c: *Checker, callback: schema.Callback) Error!void {
    const options = callback.options;
    try identifier(c, callback.name, "callback");
    if (options.no_match_error) |failure| try conversionFailure(c, failure);
    if (options.receiver) |receiver| {
        try anyPurpose(c, receiver, .invocation, "callback receivers");
        try resultType(c, receiver, .zig);
        if (receiver == .void) try c.fail("a callback receiver cannot have the void type", .{});
        if (receiver == .lazy or containsConverted(receiver)) try c.fail("callback receivers cannot use deferred or custom conversions", .{});
    }
    try javaScriptInputType(c, callback.result, "a callback result");
    try anyPurpose(c, callback.result, .pass_through, "callback results");
    if (options.schedule_next_tick and callback.result != .void) try c.fail("next-tick callbacks must return void", .{});
    if (callback.result == .native_instance) try c.fail("native-instance is constructor-return-only and cannot be a callback result", .{});
    if (callback.result == .lazy) try c.fail("lazy values cannot be callback results", .{});
    try argumentList(c, callback.args);
    try noCachedSlotProjections(c, callback.args);
    try receiverProjections(c, null, callback.args);
    try noArgumentTransfers(c, callback.args);
    for (callback.args) |argument| {
        const argument_type = effectiveArgumentType(argument);
        try anyPurpose(c, argument_type, .invocation, "callback parameters");
        if (argument.options.presence != .required) try c.fail("callback parameters must be required", .{});
        if (argument.options.integer_conversion != .normal)
            try c.fail("callback parameters cannot declare JavaScript-to-native integer conversion rules", .{});
        if (argument.options.boolean_conversion != .normal)
            try c.fail("callback parameters cannot declare JavaScript-to-native boolean conversion rules", .{});
        if (argument.options.number_conversion != .normal)
            try c.fail("callback parameters cannot declare JavaScript-to-native number conversion rules", .{});
        if (argument_type == .void) try c.fail("callback parameters cannot have the void type", .{});
        if (argument_type == .lazy) try c.fail("callback parameters cannot use lazy conversion", .{});
        if (containsConverted(argument_type)) try c.fail("converted semantic values cannot be callback parameters", .{});
        try resultType(c, argument_type, .zig);
    }
}

fn anyPurpose(c: *Checker, t: Type, purpose: schema.AnyPurpose, usage: []const u8) Error!void {
    switch (t) {
        .any => |declared| if (declared != purpose) try c.fail("{s} requires {t} any values", .{ usage, purpose }),
        .lazy => |child| try anyPurpose(c, child.*, purpose, usage),
        .optional => |optional| try anyPurpose(c, optional.child.*, purpose, usage),
        .sequence => |sequence| try anyPurpose(c, sequence.child, purpose, usage),
        .converted => |converted| {
            try anyPurpose(c, converted.match, purpose, usage);
            try anyPurpose(c, converted.native, purpose, usage);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try anyPurpose(c, field.type, purpose, usage),
        .union_type => |union_type| for (union_type.members) |member| try anyPurpose(c, effectiveUnionMemberType(member), purpose, usage),
        .record => |record| {
            try anyPurpose(c, record.key, purpose, usage);
            try anyPurpose(c, record.value, purpose, usage);
        },
        else => {},
    }
}

fn optionalRules(c: *Checker, optional: schema.Optional) Error!void {
    switch (optional.child.*) {
        .void => try c.fail("an optional binding value cannot contain void", .{}),
        .native_instance => try c.fail("native-instance is constructor-return-only and cannot be optional", .{}),
        .optional => try c.fail("nested optional binding values are redundant", .{}),
        .lazy => try c.fail("lazy conversion must wrap the complete argument type", .{}),
        else => {},
    }
    if (optional.mode == .matched) switch (optional.child.*) {
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .dom_string, .usv_string, .byte_string, .enumeration, .branded_value, .class_ref, .external_ref => {},
        else => try c.fail("optionalMatch requires an exactly matchable scalar or branded value type", .{}),
    };
}

fn enumerationTextEquals(options: schema.EnumerationOptions, left: []const u8, right: []const u8) bool {
    return if (options.ascii_case_insensitive) std.ascii.eqlIgnoreCase(left, right) else eqlText(left, right);
}

fn enumerationValueRules(c: *Checker, value: schema.EnumerationValue) Error!void {
    const options = value.options;
    try wireIdentifier(c, value.name, "enumeration value");
    try textAllowEmpty(c, value.value, "enumeration value");
    if (!std.unicode.utf8ValidateSlice(value.value)) try c.fail("enumeration value must be valid UTF-8", .{});
    if (options.error_code) |error_code| {
        try identifier(c, error_code.code, "error code");
        if (error_code.name) |error_name| try asciiText(c, error_name, "error name");
    }
    if (options.internal_module) |source| switch (source) {
        .javascript => |path| {
            try asciiText(c, path, "internal module source path");
            if (std.mem.indexOfAny(u8, path, "\\:") != null or
                (!std.mem.endsWith(u8, path, ".js") and !std.mem.endsWith(u8, path, ".ts")) or
                std.mem.endsWith(u8, path, ".d.ts"))
            {
                try c.fail("internal module sources must name JavaScript or TypeScript files relative to src/js", .{});
            }
            var components = std.mem.splitScalar(u8, path, '/');
            while (components.next()) |component| {
                if (component.len == 0 or eqlText(component, ".") or eqlText(component, "..")) {
                    try c.fail("internal module sources must stay within src/js", .{});
                    break;
                }
            }
        },
        .native => {},
    };
    if (options.internal_module_default != .property and
        (options.internal_module == null or options.internal_module.? != .javascript))
        try c.fail("JavaScript module default policies require a JavaScript registry entry", .{});
    for (options.aliases, 0..) |alias, index| {
        try textAllowEmpty(c, alias, "enumeration value alias");
        if (!std.unicode.utf8ValidateSlice(alias)) try c.fail("enumeration value alias must be valid UTF-8", .{});
        if (eqlText(alias, value.value)) try c.fail("enumeration value alias duplicates its primary value: {s}", .{alias});
        for (options.aliases[0..index]) |previous| {
            if (eqlText(alias, previous)) try c.fail("duplicate enumeration value alias: {s}", .{alias});
        }
    }
}

fn enumerationRules(c: *Checker, enumeration: schema.Enumeration) Error!void {
    const options = enumeration.options;
    const values = enumeration.values;
    try identifier(c, enumeration.name, "enumeration");
    if (options.cpp_name) |cpp_name| try identifier(c, cpp_name, "C++ enumeration");
    if (options.coerce and (options.accept_native_numbers or options.strict_errors != null or options.node_invalid_value != null))
        try c.fail("enumeration string coercion cannot be combined with native numeric tags or another string conversion policy", .{});
    if (options.unrecognized_value) |value_name| {
        try identifier(c, value_name, "unrecognized enumeration value");
        if (options.invalid_value_failure != null or options.strict_errors != null or
            options.node_invalid_value != null or options.invalid_value_error != .range or
            options.error_catalog or options.internal_module_registry)
            try c.fail("an unrecognized enumeration value cannot be combined with another invalid-value policy or a registry", .{});
    }
    if (options.invalid_value_failure) |failure| {
        if (options.strict_errors != null or options.node_invalid_value != null or options.invalid_value_error != .range)
            try c.fail("a literal enumeration failure cannot be combined with another invalid-value policy", .{});
        try conversionFailure(c, failure);
    }
    if (options.strict_errors) |errors| {
        if (options.node_invalid_value != null or options.invalid_value_error != .range)
            try c.fail("strict enumeration errors cannot be combined with other error policies", .{});
        try conversionFailure(c, errors.invalid_type);
        try conversionFailure(c, errors.invalid_value);
        if (errors.invalid_string_prefix) |failure| try conversionFailure(c, failure);
    }
    if (options.internal_module_registry and (options.error_catalog or options.ascii_case_insensitive))
        try c.fail("internal module IDs require an exact enumeration that is not an error catalog", .{});
    if (options.node_invalid_value) |invalid| switch (invalid) {
        .invalid_argument_value => |value| {
            if (value.non_string_name) |error_name| {
                try text(c, error_name, "Node enumeration non-string error name");
                if (value.non_string_expected_type == null)
                    try c.fail("a non-string enumeration error name requires a non-string type error", .{});
            }
            if (value.coerce and (options.accept_native_numbers or value.non_string_expected_type != null))
                try c.fail("coerced Node enumeration errors cannot accept native numeric tags or reject non-string inputs", .{});
            if (value.name) |invalid_name| try text(c, invalid_name, "Node enumeration error name");
            try text(c, value.reason, "Node enumeration error reason");
            if (value.non_string_expected_type) |expected| try asciiText(c, expected, "Node enumeration non-string expected type");
        },
        .invalid_property_value => |value| {
            if (value.non_string_name) |error_name| {
                try text(c, error_name, "Node enumeration non-string error name");
                if (value.non_string_expected_type == null)
                    try c.fail("a non-string enumeration error name requires a non-string type error", .{});
            }
            if (value.name) |invalid_name| try text(c, invalid_name, "Node enumeration property name");
            try text(c, value.expected, "Node enumeration property expectation");
            if (value.non_string_expected_type) |expected| try asciiText(c, expected, "Node enumeration non-string expected type");
        },
        .coerced_error => |value| {
            try identifier(c, value.code, "Node enumeration error code");
            try textAllowEmpty(c, value.message_prefix, "Node enumeration error message prefix");
            try textAllowEmpty(c, value.message_suffix, "Node enumeration error message suffix");
            if (value.non_string_expected_type) |expected| try asciiText(c, expected, "Node enumeration non-string expected type");
            if (value.message_prefix.len == 0 and value.message_suffix.len == 0)
                try c.fail("a coerced Node enumeration error message must frame the invalid value", .{});
        },
    };
    if (values.len == 0) return c.fail("an enumeration must contain at least one value", .{});
    const tag_max: usize = switch (options.tag) {
        .u8 => std.math.maxInt(u8),
        .u16 => std.math.maxInt(u16),
    };
    if (values.len > tag_max) try c.fail("enumeration values do not fit in the declared tag type", .{});
    var saw_native_module = false;
    for (values, 0..) |value, index| {
        try enumerationValueRules(c, value);
        const value_options = value.options;
        if (options.error_catalog != (value_options.error_code != null))
            try c.fail("error-code metadata must be declared for every member of an error catalog", .{});
        if (options.internal_module_registry != (value_options.internal_module != null))
            try c.fail("internal module metadata must be declared for every member of a module registry", .{});
        if (value_options.internal_module) |source| switch (source) {
            .javascript => |path| {
                if (saw_native_module) try c.fail("JavaScript registry modules must precede native modules", .{});
                for (values[0..index]) |previous| {
                    const previous_source = previous.options.internal_module orelse continue;
                    if (previous_source == .javascript and eqlText(previous_source.javascript, path)) {
                        try c.fail("duplicate internal module source: {s}", .{path});
                        break;
                    }
                }
            },
            .native => saw_native_module = true,
        };
        for (value_options.aliases, 0..) |alias, alias_index| {
            if (enumerationTextEquals(options, alias, value.value))
                try c.fail("enumeration value alias duplicates its primary value: {s}", .{alias});
            for (value_options.aliases[0..alias_index]) |previous| {
                if (enumerationTextEquals(options, alias, previous)) try c.fail("duplicate enumeration value alias: {s}", .{alias});
            }
        }
        for (values[0..index]) |previous| {
            if (eqlText(previous.name, value.name)) try c.fail("duplicate enumeration value name: {s}", .{value.name});
            if (enumerationTextEquals(options, previous.value, value.value))
                try c.fail("duplicate enumeration JavaScript value: {s}", .{value.value});
            for (previous.options.aliases) |previous_alias| {
                if (enumerationTextEquals(options, previous_alias, value.value))
                    try c.fail("enumeration JavaScript value duplicates an alias: {s}", .{value.value});
            }
            for (value_options.aliases) |alias| {
                if (enumerationTextEquals(options, previous.value, alias))
                    try c.fail("enumeration alias duplicates a JavaScript value: {s}", .{alias});
                for (previous.options.aliases) |previous_alias| {
                    if (enumerationTextEquals(options, previous_alias, alias)) try c.fail("duplicate enumeration alias: {s}", .{alias});
                }
            }
        }
        const native_value = enumerationNativeValue(options, value, index);
        if (native_value > tag_max) try c.fail("enumeration native value does not fit in its declared tag type", .{});
        if (options.error_catalog and native_value != index) try c.fail("error catalog tags must be contiguous and start at zero", .{});
        if (options.internal_module_registry and native_value != index)
            try c.fail("internal module IDs must be contiguous and start at zero", .{});
        for (values[0..index], 0..) |previous, previous_index| {
            if (enumerationNativeValue(options, previous, previous_index) == native_value)
                try c.fail("duplicate enumeration native value: {s}", .{value.name});
        }
    }
    if (options.unrecognized_value) |value_name| {
        for (values) |value| {
            if (eqlText(value.name, value_name)) break;
        } else try c.fail("unrecognized enumeration value must name a declared member: {s}", .{value_name});
    }
}

fn enumerationNativeValue(options: schema.EnumerationOptions, value: schema.EnumerationValue, index: usize) usize {
    return value.options.native_value orelse (index + @intFromBool(!options.internal_module_registry));
}

fn dictionaryFieldRules(c: *Checker, field: schema.DictionaryField) Error!void {
    const name = field.name;
    const field_type = field.type;
    const options = field.options;
    try wireIdentifier(c, name, "dictionary field");
    if (options.diagnostic_name) |diagnostic_name| try asciiText(c, diagnostic_name, "dictionary field diagnostic name");
    if (options.source_field) |source_field| {
        try wireIdentifier(c, source_field, "dictionary field projection source");
        if (field_type != .lazy or options.source != .property or options.js_name != null or
            options.private_symbol != null or options.aliases.len != 0 or options.lazy_property_read != .deferred)
            try c.fail("dictionary field projections require a deferred lazy view without a property name", .{});
    }
    if (options.enum_membership_after_fields) {
        if (field_type != .enumeration or options.profile != .node) {
            try c.fail("late enum membership requires an enumeration with the Node profile", .{});
        } else {
            const enumeration_options = field_type.enumeration.options;
            if (enumeration_options.unrecognized_value != null)
                try c.fail("late enum membership cannot use an unrecognized-value fallback", .{});
            const node_coerces = if (enumeration_options.node_invalid_value) |invalid| switch (invalid) {
                .invalid_argument_value => |details| details.coerce,
                .coerced_error => true,
                .invalid_property_value => false,
            } else false;
            if (enumeration_options.accept_native_numbers or enumeration_options.coerce or node_coerces)
                try c.fail("late enum membership requires a strict string enumeration", .{});
            if (options.required) try c.fail("late enum membership requires an optional or defaulted field", .{});
        }
    }
    if (field_type == .void or field_type == .native_instance) try c.fail("dictionary fields require a value type", .{});
    if (containsContextualDiscard(field_type))
        try c.fail("dictionary fields that discard a value require discardAny(.presence) or discardAny(.ignored)", .{});
    if (options.source == .dictionary) {
        if (field_type != .engine_value and !(field_type == .any and field_type.any == .retention) and !structural.eql(field_type, schema.js_object))
            try c.fail("a dictionary source field must have engine_value, retainedAny, or object type", .{});
        if (!options.required or options.missing != .undefined or options.missing_required != .reject or
            options.default_value != null or options.boolean_conversion != .normal or
            options.integer_conversion != .normal or options.number_conversion != .normal or
            options.deferred_reason != null or options.js_name != null or options.private_symbol != null or
            options.aliases.len != 0 or options.profile != null or
            options.node_unsupported != null or options.node_incompatible_with != null)
            try c.fail("a dictionary source field must use the plain required engine-value contract", .{});
    }
    if (field_type == .lazy and !options.required)
        try c.fail("lazy dictionary fields must be required; put optionality inside lazy(T)", .{});
    if (field_type == .lazy) {
        if (options.node_unsupported != null) try c.fail("lazy dictionary fields cannot be Node-unsupported: {s}", .{name});
        if (options.deferred_reason) |reason| {
            try asciiText(c, reason, "lazy dictionary field reason");
        } else {
            try c.fail("a lazy dictionary field must justify its observable conversion order: {s}", .{name});
        }
    } else if (options.deferred_reason != null) {
        try c.fail("only a lazy dictionary field can declare a deferred conversion reason", .{});
    }
    if (field_type != .lazy and options.lazy_property_read != .deferred)
        try c.fail("only a lazy dictionary field can select property-read timing", .{});
    if (options.required and options.default_value != null) try c.fail("a required dictionary field cannot declare a default value", .{});
    if (!options.required and options.missing_required != .reject) try c.fail("only a required dictionary field can convert missing values", .{});
    if (options.missing_required == .failure) try conversionFailure(c, options.missing_required.failure);
    if (options.default_value) |value| try defaultValue(c, field_type, value);
    if (options.js_name) |js_name| try propertyName(c, js_name, "dictionary field JavaScript name");
    if (options.private_symbol) |private_symbol| {
        try identifier(c, private_symbol, "dictionary field private symbol");
        if (options.missing != .undefined)
            try c.fail("private-symbol dictionary fields cannot use observable property-presence checks", .{});
        if (options.js_name != null or options.aliases.len != 0)
            try c.fail("a private-symbol dictionary field cannot declare a JavaScript name or aliases", .{});
    }
    if (options.node_unsupported) |reason| {
        if (field_type != .lazy and (options.required or options.default_value != null))
            try c.fail("an unsupported Node dictionary field must be optional and cannot have a default value", .{});
        try asciiText(c, reason, "unsupported Node dictionary field reason");
    }
    if (options.node_incompatible_with) |other| try wireIdentifier(c, other, "incompatible Node dictionary field");
    for (options.aliases, 0..) |alias, index| {
        try propertyName(c, alias, "dictionary field alias");
        if (eqlText(alias, options.js_name orelse name)) try c.fail("dictionary field alias duplicates its primary name: {s}", .{alias});
        for (options.aliases[0..index]) |previous| {
            if (eqlText(alias, previous)) try c.fail("duplicate dictionary field alias: {s}", .{alias});
        }
    }
    try valueConversion(c, field_type, options.boolean_conversion, options.integer_conversion, options.number_conversion, "dictionary field");
}

fn isIndexPropertyName(name: []const u8) bool {
    if (name.len == 0 or (name.len > 1 and name[0] == '0')) return false;
    for (name) |byte| if (!std.ascii.isDigit(byte)) return false;
    const index = std.fmt.parseInt(u32, name, 10) catch return false;
    return index != std.math.maxInt(u32);
}

fn dictionaryRules(c: *Checker, dictionary: schema.Dictionary) Error!void {
    const options = dictionary.options;
    const fields = dictionary.fields;
    try identifier(c, dictionary.name, "dictionary");
    if (options.user_facing_name) |name| try text(c, name, "dictionary user-facing name");
    if (options.cpp_name) |cpp_name| try identifier(c, cpp_name, "dictionary C++ name");
    if (options.result_to_string_tag) |tag| try text(c, tag, "dictionary result toStringTag");
    if (options.object_error) |failure| {
        if (options.object_error_profile != null or options.object_error_kind != .type)
            try c.fail("a dictionary literal object error cannot be combined with other object error policies", .{});
        try conversionFailure(c, failure);
    }
    if (options.finish_fields.len != 0 and options.field_reads != .interleaved)
        try c.fail("staged dictionary fields require interleaved field reads", .{});
    for (options.finish_fields, 0..) |name, index| {
        for (options.finish_fields[0..index]) |previous| {
            if (eqlText(name, previous)) try c.fail("duplicate staged dictionary field: {s}", .{name});
        }
        const field = for (fields) |field| {
            if (eqlText(name, field.name)) break field;
        } else {
            try c.fail("unknown staged dictionary field: {s}", .{name});
            continue;
        };
        const field_options = field.options;
        if (field_options.source != .property or field_options.default_value != null or
            field_options.missing_required != .reject or field_options.enum_membership_after_fields or
            field_options.node_unsupported != null or field_options.node_incompatible_with != null)
            try c.fail("staged dictionary fields require a plain property contract: {s}", .{name});
        switch (field.type) {
            .buffer => |buffer| if (buffer.mode != .copy or buffer.access != .read_only)
                try c.fail("staged dictionary buffers require read-only copies", .{}),
            .union_type => |union_type| if (union_type.options.input_tag == null or !union_type.options.input_tag.?.string_shorthand)
                try c.fail("dictionary field type does not support staged conversion: {s}", .{name}),
            else => try c.fail("dictionary field type does not support staged conversion: {s}", .{name}),
        }
    }
    for (fields, 0..) |field, index| {
        try dictionaryFieldRules(c, field);
        const field_options = field.options;
        if (field_options.source_field) |source_name| {
            if (for (fields[0..index]) |previous| {
                if (eqlText(source_name, previous.name)) break previous;
            } else null) |source| {
                if (source.type != .lazy or source.options.source != .property or
                    source.options.source_field != null or source.options.missing != field_options.missing)
                    try c.fail("dictionary field projection sources require an original lazy property with matching missing semantics", .{});
            } else {
                try c.fail("dictionary field projections must name an earlier lazy field: {s}", .{source_name});
            }
        }
        if (options.property_lookup == .skip_object_prototype and field_options.source == .property and field_options.private_symbol == null) {
            if (field_options.missing != .undefined)
                try c.fail("prototype-filtered dictionary lookup requires undefined-based missing values", .{});
            var index_property = isIndexPropertyName(field_options.js_name orelse field.name);
            for (field_options.aliases) |alias| index_property = index_property or isIndexPropertyName(alias);
            if (index_property) try c.fail("prototype-filtered dictionary lookup does not support index properties", .{});
        }
        if (options.field_reads == .before_conversion and field.type == .lazy)
            try c.fail("reading all dictionary fields before conversion cannot be combined with lazy fields", .{});
        if (field_options.enum_membership_after_fields and options.field_reads != .before_conversion)
            try c.fail("late enum membership requires reading all dictionary fields before conversion", .{});
        for (fields[0..index]) |previous| {
            if (eqlText(previous.name, field.name)) try c.fail("duplicate dictionary field: {s}", .{field.name});
        }
        if (field_options.source == .dictionary) {
            for (fields[0..index]) |previous| {
                if (previous.options.source == .dictionary) {
                    try c.fail("a dictionary can declare only one source field", .{});
                    break;
                }
            }
        }
        if (field_options.node_incompatible_with) |other_name| {
            for (fields[0..index]) |previous| {
                if (!eqlText(previous.name, other_name)) continue;
                if (previous.options.source == .dictionary or previous.type == .lazy)
                    try c.fail("incompatible Node dictionary field must name an earlier eager property: {s}", .{other_name});
                break;
            } else try c.fail("incompatible Node dictionary field must name an earlier field: {s}", .{other_name});
        }
    }
    if (options.result_class) |bound| try dictionaryResultClassRules(c, dictionary, bound);
}

fn dictionaryResultClassRules(c: *Checker, dictionary: schema.Dictionary, bound: schema.BoundClass) Error!void {
    const options = dictionary.options;
    const class = bound.class;
    if (c.n.classIdOf(bound) == null)
        return c.fail("a dictionary result class must name a class exported by a binding schema module", .{});
    if (class.options.representation != .plain)
        try c.fail("a dictionary result class must use the plain representation: {s}", .{class.name});
    if (options.result_prototype != .ordinary or options.result_to_string_tag != null)
        try c.fail("a plain-class dictionary result derives its prototype and tag from the class", .{});
    if (dictionary.fields.len != class.instance_properties.len)
        return c.fail("a plain-class dictionary result must contain every instance property: {s}", .{class.name});
    for (dictionary.fields, class.instance_properties) |field, property| {
        if (!eqlText(field.name, property.name) or !structural.eql(field.type, property.options.value))
            try c.fail("a plain-class dictionary result must match the declared property layout: {s}", .{class.name});
        const field_options = field.options;
        if (!field_options.required or field_options.missing != .undefined or field_options.missing_required != .reject or
            field_options.default_value != null or field_options.boolean_conversion != .normal or
            field_options.integer_conversion != .normal or field_options.number_conversion != .normal or
            field_options.js_name != null or field_options.private_symbol != null or field_options.aliases.len != 0 or
            field_options.profile != null or field_options.node_unsupported != null or field_options.node_incompatible_with != null)
            try c.fail("plain-class dictionary result fields cannot declare input conversion behavior: {s}.{s}", .{ class.name, field.name });
    }
}

fn unionMemberRules(c: *Checker, member: schema.UnionMember) Error!void {
    try wireIdentifier(c, member.name, "union member");
    if (member.type == .void or member.type == .native_instance) try c.fail("union members require a value type", .{});
    if (member.type == .lazy) {
        if (member.options.deferred_reason) |reason| {
            try text(c, reason, "lazy union member reason");
        } else {
            try c.fail("lazy union members require a deferred conversion reason", .{});
        }
    } else if (member.options.deferred_reason != null) {
        try c.fail("only lazy union members can declare a deferred conversion reason", .{});
    }
    const effective = effectiveUnionMemberType(member);
    if (containsContextualDiscard(effective)) try c.fail("nested discarded union members require an explicit discard purpose", .{});
    const options = member.options;
    try valueConversion(c, effective, options.boolean_conversion, options.integer_conversion, options.number_conversion, "union member");
}

fn unionRules(c: *Checker, union_type: schema.Union) Error!void {
    const options = union_type.options;
    const members = union_type.members;
    try identifier(c, union_type.name, "union");
    if (options.fallback_on_conversion_error and (options.input_tag == null or options.fallback_member == null))
        try c.fail("conversion-error fallbacks require an explicitly tagged fallback member", .{});
    if (options.input_tag != null and options.fallback_member != null and !options.fallback_on_conversion_error)
        try c.fail("tagged union fallbacks require fallback_on_conversion_error", .{});
    if (options.cpp_name) |cpp_name| try identifier(c, cpp_name, "union C++ name");
    if (options.input_tag) |tag| {
        try asciiText(c, tag.tag_property, "union tag property");
        if (tag.value_property) |property| {
            try asciiText(c, property, "union value property");
            if (eqlText(tag.tag_property, property)) try c.fail("union tag and value properties must be distinct", .{});
        }
        if (tag.string_shorthand and (tag.value_property != null or !tag.coerce_tag))
            try c.fail("string-shorthand unions require a same-object, DOMString discriminator", .{});
        if (tag.selector) |selector| if (selector != .enumeration) try c.fail("a tagged union selector must be an enumeration", .{});
        if (options.node_error != null) try c.fail("tagged union inputs cannot declare shape-selection errors", .{});
    }
    if (options.no_match_error) |failure| {
        if (options.node_error != null or options.fallback_member != null)
            try c.fail("a union no-match error cannot be combined with a fallback or another error policy", .{});
        try conversionFailure(c, failure);
    }
    if (options.node_error) |node_error| switch (node_error) {
        .expected_type => |expected| try asciiText(c, expected, "Node union expected type"),
        .expected_instances => |expected| try asciiText(c, expected, "Node union expected instances"),
        .type_or_instance => |expected| {
            try asciiText(c, expected.expected_type, "Node union expected type");
            try asciiText(c, expected.expected_instances, "Node union expected instances");
        },
        .invalid_value => |reason| if (reason) |value| try asciiText(c, value, "union invalid-value reason"),
        .invalid_property_value => |expected| try asciiText(c, expected, "Node union property expectation"),
        .invalid_port => {},
    };
    if (members.len < 2) try c.fail("a union must contain at least two members", .{});
    if (members.len > std.math.maxInt(u8)) try c.fail("a union may contain at most 255 members", .{});
    for (members, 0..) |member, index| {
        try unionMemberRules(c, member);
        const member_type = effectiveUnionMemberType(member);
        const is_fallback = if (options.fallback_member) |fallback| eqlText(fallback, member.name) else false;
        if (options.fallback_on_conversion_error) {
            if (typeContainsLazy(member_type)) try c.fail("conversion-error fallbacks require eager members", .{});
            try lazyType(c, member_type, false);
        }
        if (options.input_tag) |tag| {
            if (is_fallback) {
                if (tag.value_property != null or member_type != .union_type or member_type.union_type.options.input_tag == null) {
                    try c.fail("a tagged fallback must normalize the same object through another tagged union", .{});
                } else {
                    const child_tag = member_type.union_type.options.input_tag.?;
                    const same_selector = if (child_tag.selector) |child_selector|
                        if (tag.selector) |selector| structural.eql(child_selector, selector) else false
                    else
                        false;
                    if (child_tag.value_property != null or !same_selector or
                        !eqlText(child_tag.tag_property, tag.tag_property) or child_tag.string_shorthand != tag.string_shorthand or
                        child_tag.coerce_tag != tag.coerce_tag)
                        try c.fail("a tagged fallback must preserve the discriminator contract", .{});
                }
            } else {
                if (tag.selector) |selector| if (selector == .enumeration) {
                    for (selector.enumeration.values) |value| {
                        if (eqlText(member.name, value.name)) break;
                    } else try c.fail("union member is absent from its selector enumeration: {s}", .{member.name});
                };
                if (tag.value_property == null and member_type != .dictionary)
                    try c.fail("same-object tagged unions require dictionary members", .{});
            }
        }
        if (options.input_tag == null and member_type == .discarded and member_type.discarded.purpose != .classification) {
            const ignored_fallback = member_type.discarded.purpose == .ignored and is_fallback;
            if (!ignored_fallback)
                try c.fail("discarded shape-selected union members require classification; an ignored value is allowed only as the fallback", .{});
        }
        for (members[0..index]) |previous| {
            const previous_type = effectiveUnionMemberType(previous);
            if (eqlText(previous.name, member.name)) try c.fail("duplicate union member name: {s}", .{member.name});
            if (options.input_tag == null and structural.eql(previous_type, member_type) and structural.eql(previous.options, member.options))
                try c.fail("duplicate union member type and conversion: {s}", .{member.name});
            if (options.input_tag == null and !options.ordered and unionMembersOverlap(previous_type, member_type))
                try c.fail("union members '{s}' and '{s}' overlap; declare an ordered union to make precedence explicit", .{ previous.name, member.name });
        }
    }
    if (options.fallback_member) |fallback| {
        if (!options.ordered) try c.fail("a union fallback requires ordered conversion", .{});
        if (options.node_error != null) try c.fail("a union fallback cannot declare a no-match Node error", .{});
        for (members, 0..) |member, index| {
            if (!eqlText(fallback, member.name)) continue;
            if (index + 1 != members.len) try c.fail("a union fallback must be the final member", .{});
            break;
        } else try c.fail("union fallback does not name a member: {s}", .{fallback});
    }
}

fn isObjectShape(t: Type) bool {
    return switch (t) {
        .dictionary, .record => true,
        .union_type => |union_type| union_type.options.input_tag != null,
        else => false,
    };
}

fn isSpecificObject(t: Type) bool {
    return switch (t) {
        .buffer, .callback, .sequence, .external_ref, .class_ref, .branded_value => true,
        else => false,
    };
}

fn isNumberLike(t: Type) bool {
    return isInteger(t) or t == .f64 or (t == .enumeration and t.enumeration.options.accept_native_numbers);
}

fn unionMembersOverlap(left: Type, right: Type) bool {
    if (left == .any or right == .any) return true;
    if (left == .discarded) return switch (left.discarded.match) {
        .semantic_type => unionMembersOverlap(left.discarded.match_type.*, right),
        else => typeMatchesDiscardedLiteral(right, left.discarded.match),
    };
    if (right == .discarded) return switch (right.discarded.match) {
        .semantic_type => unionMembersOverlap(left, right.discarded.match_type.*),
        else => typeMatchesDiscardedLiteral(left, right.discarded.match),
    };
    if (left == .lazy) return unionMembersOverlap(left.lazy.*, right);
    if (right == .lazy) return unionMembersOverlap(left, right.lazy.*);
    if (left == .converted) return unionMembersOverlap(left.converted.match, right);
    if (right == .converted) return unionMembersOverlap(left, right.converted.match);
    if (left == .union_type and left.union_type.options.fallback_member != null) return true;
    if (right == .union_type and right.union_type.options.fallback_member != null) return true;
    if (left == .optional) {
        if (right == .optional) return true;
        return unionMembersOverlap(left.optional.child.*, right);
    }
    if (right == .optional) return unionMembersOverlap(left, right.optional.child.*);
    if (left == .union_type and left.union_type.options.input_tag == null) {
        for (left.union_type.members) |member| {
            if (unionMembersOverlap(effectiveUnionMemberType(member), right)) return true;
        }
        return false;
    }
    if (right == .union_type and right.union_type.options.input_tag == null) return unionMembersOverlap(right, left);
    const left_object = isObjectShape(left);
    const right_object = isObjectShape(right);
    const left_specific = isSpecificObject(left);
    const right_specific = isSpecificObject(right);
    if ((left_object and (right_object or right_specific)) or (right_object and (left_object or left_specific))) return true;
    if (left_specific or right_specific) return left.kind() == right.kind();
    const left_number = isNumberLike(left);
    const right_number = isNumberLike(right);
    if (left_number and right_number) return true;
    const left_string = isString(left) or left == .enumeration;
    const right_string = isString(right) or right == .enumeration;
    if (left_string or right_string) return left_string and right_string;
    if (left_number or right_number) return false;
    return left.kind() == right.kind();
}

fn typeMatchesDiscardedLiteral(t: Type, literal: schema.DiscardedMatch) bool {
    return switch (t) {
        .any, .engine_value => true,
        .discarded => |discarded| switch (discarded.match) {
            .semantic_type => typeMatchesDiscardedLiteral(discarded.match_type.*, literal),
            .number_literal => |value| switch (literal) {
                .number_literal => |other| value == other or (std.math.isNan(value) and std.math.isNan(other)),
                else => false,
            },
            else => std.meta.activeTag(discarded.match) == std.meta.activeTag(literal),
        },
        .converted => |converted| typeMatchesDiscardedLiteral(converted.match, literal),
        .optional => |optional| switch (optional.mode) {
            .nullable => literal == .null_literal,
            .undefined => literal == .undefined_literal,
            .nullish, .nullish_or_empty_string => literal == .null_literal or literal == .undefined_literal,
            .falsy, .matched => true,
        } or typeMatchesDiscardedLiteral(optional.child.*, literal),
        .boolean => literal == .false_literal,
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => literal == .number_literal and integerRepresentation(t) != .bigint,
        .f64 => literal == .number_literal,
        .enumeration => |enumeration| enumeration.options.accept_native_numbers and literal == .number_literal,
        .union_type => |union_type| if (union_type.options.input_tag != null) false else for (union_type.members) |member| {
            if (typeMatchesDiscardedLiteral(effectiveUnionMemberType(member), literal)) break true;
        } else false,
        else => false,
    };
}

fn sequenceRules(c: *Checker, sequence: schema.Sequence) Error!void {
    const options = sequence.options;
    const child = sequence.child;
    if (options.input_length_limit) |limit| {
        if (options.container == .iterable)
            try c.fail("sequence input length limits require an array or array-like container", .{});
        try conversionFailure(c, limit.failure);
    }
    if (child == .lazy) {
        if (options.element_deferred_reason) |reason| {
            try text(c, reason, "lazy sequence element reason");
        } else {
            try c.fail("lazy sequence elements require a deferred conversion reason", .{});
        }
        if (!options.container.isArray() or options.snapshot_elements or options.element_access != .property or
            options.node_error != null or options.flavor != .sequence)
            try c.fail("lazy sequence elements require deferred indexed array reads", .{});
    } else if (options.element_deferred_reason != null) {
        try c.fail("only lazy sequence elements can declare a deferred conversion reason", .{});
    }
    if (options.element_pattern) |pattern| {
        if (child != .union_type or child.union_type.options.input_tag != null or
            !options.container.isArray() or options.flavor != .sequence or
            options.snapshot_elements or options.element_access != .property or options.node_error != null)
            try c.fail("sequence element patterns require an interleaved array of untagged union values", .{});
        if (pattern.members.len < 2 or pattern.members.len > 65535)
            try c.fail("sequence element patterns require between 2 and 65535 positions", .{});
        try conversionFailure(c, pattern.incomplete_error);
        if (pattern.read_group_sizes.len != 0) {
            var total: usize = 0;
            for (pattern.read_group_sizes) |group_size| {
                if (group_size == 0) try c.fail("sequence read groups must not be empty", .{});
                total += group_size;
            }
            if (total != pattern.members.len) try c.fail("sequence read groups must cover exactly one element pattern", .{});
        }
        if (child == .union_type) for (pattern.members) |name| {
            for (child.union_type.members) |member| {
                if (eqlText(name, member.name)) break;
            } else try c.fail("sequence element pattern names an unknown union member: {s}", .{name});
        };
    }
    const conversion = options.element_conversion;
    try valueConversion(c, child, conversion.boolean_conversion, conversion.integer_conversion, conversion.number_conversion, "sequence element");
    if (options.node_error) |node_error| {
        try asciiText(c, node_error.element.expected, "Node sequence expected element");
        if (node_error.container) |container| {
            try asciiText(c, container.expected, "Node sequence expected container");
            if (container.site != .sequence) try c.fail("Node sequence container errors must identify the sequence", .{});
            if (options.container == .iterable)
                try c.fail("iterator-protocol sequences use engine container errors; declare only an element error", .{});
        }
    }
    if (options.flavor == .frozen_array and
        (options.snapshot_elements or options.node_error != null or options.element_access != .property or
            options.container != .array or !structural.eql(conversion, schema.ValueConversionOptions{})))
        try c.fail("FrozenArray cannot declare sequence input-conversion options", .{});
    if (options.container == .iterable and options.element_access != .property)
        try c.fail("iterable sequences cannot declare direct array-index access", .{});
    if (options.container == .array_like and options.element_access != .property)
        try c.fail("array-like sequences require ordinary indexed property access", .{});
    if (child == .void or child == .native_instance) try c.fail("sequence elements require a value type", .{});
}

fn recordRules(c: *Checker, record: schema.Record) Error!void {
    const options = record.options;
    if (!isString(record.key)) try c.fail("record keys must be DOMString, USVString, or ByteString", .{});
    if (record.value == .void or record.value == .native_instance) try c.fail("record entries require a value type", .{});
    if (containsBorrowedEngineValue(record.value)) try c.fail("record values cannot contain borrowed JavaScript values", .{});
    if (record.value == .lazy) {
        if (options.value_deferred_reason) |reason| {
            try text(c, reason, "lazy record value reason");
        } else {
            try c.fail("lazy record values require a deferred conversion reason", .{});
        }
    } else if (options.value_deferred_reason != null) {
        try c.fail("only lazy record values can declare a deferred conversion reason", .{});
    }
    if (options.result_to_string_tag) |tag| try text(c, tag, "record result toStringTag");
}

// ─── value conversions ───

fn valueConversion(
    c: *Checker,
    t: Type,
    boolean_conversion: schema.BooleanConversion,
    integer_conversion: schema.IntegerConversion,
    number_conversion: schema.NumberConversion,
    subject: []const u8,
) Error!void {
    const operand = conversionOperand(t);
    try booleanConversion(c, t, boolean_conversion);
    try numberConversion(c, t, number_conversion);
    switch (integer_conversion) {
        .normal => {},
        .modulo, .coerce, .coerce_saturate, .truncate_saturate, .webidl => if (!isInteger(operand))
            try c.fail("integer conversion requires an integer {s}", .{subject}),
        .to_length => if (operand != .u64 and operand != .usize)
            try c.fail("ToLength conversion requires an unsigned 64-bit {s}", .{subject}),
        .node_receiver_byte_length => |validation| {
            if (operand != .usize) try c.fail("receiver byte-length indices require size {s} storage", .{subject});
            if (validation.bound == .at_preparation and
                (!eqlText(subject, "argument") or t != .lazy or t.lazy.* != .usize))
                try c.fail("prepared receiver byte-length bounds require a lazy size argument", .{});
        },
        .node_validate_with => |validation| {
            try integerConversionRange(c, operand, validation.range, subject);
            if (validation.rejection == .safe_integer and
                (validation.range.min != -9007199254740991 or validation.range.max != 9007199254740991))
                try c.fail("safe integer diagnostics require the complete safe integer range", .{});
            if (validation.rejection == .port and (validation.range.min != 0 or validation.range.max != 65535))
                try c.fail("port diagnostics require the complete IP port range", .{});
        },
        .enforce_range, .clamp, .node_validate, .node_validate_prose, .matching => |range| try integerConversionRange(c, operand, range, subject),
        .node_coerce => |validation| try integerConversionRange(c, operand, validation.range, subject),
        .node_truncate => |validation| try integerConversionRange(c, operand, validation.range, subject),
        .saturate_validate => |validation| {
            try integerConversionRange(c, operand, validation.range, subject);
            if (validation.failure) |failure| {
                try identifier(c, failure.code, "integer range error code");
                try asciiText(c, failure.argument_suffix, "integer range error suffix");
            }
        },
        .bounded_integer => |validation| {
            try integerConversionRange(c, operand, validation.range, subject);
            if (isInteger(operand)) {
                if (integerRepresentation(operand)) |representation| if (representation != .number)
                    try c.fail("Number integer conversion accepts Number representation only", .{});
                if (validation.range.min < -9007199254740991 or validation.range.max > 9007199254740991)
                    try c.fail("Number integer conversion requires safe integer bounds", .{});
            }
            try conversionFailure(c, validation.invalid);
            try conversionFailure(c, validation.out_of_range);
        },
        .truncate_clamp => |normalization| {
            try integerConversionRange(c, operand, normalization.range, subject);
            if (integerRepresentation(operand)) |representation| if (representation != .number)
                try c.fail("Number integer conversion accepts Number representation only", .{});
            if (normalization.nan < normalization.range.min or normalization.nan > normalization.range.max)
                try c.fail("truncated integer clamp NaN value must be within its range", .{});
        },
        .coerce_truncate_or_default => |normalization| {
            try integerConversionRange(c, operand, normalization.range, subject);
            if (integerRepresentation(operand) == .bigint) try c.fail("coerced integer defaults require Number input representation", .{});
            if (normalization.range.min < -9007199254740991 or normalization.range.max > 9007199254740991)
                try c.fail("Number integer conversion requires safe integer bounds", .{});
            if (normalization.fallback < normalization.range.min or normalization.fallback > normalization.range.max)
                try c.fail("coerced integer fallback must be within its range", .{});
        },
    }
}

fn integerConversionRange(c: *Checker, t: Type, range: schema.IntegerRange, subject: []const u8) Error!void {
    const bounds = integerBounds(t) orelse return c.fail("integer conversion rules require an integer {s}", .{subject});
    if (range.min > range.max) try c.fail("integer conversion range is reversed", .{});
    if (range.min < bounds.min or range.max > bounds.max)
        try c.fail("integer conversion range exceeds the declared {s} type", .{subject});
}

fn numberConversion(c: *Checker, t: Type, conversion: schema.NumberConversion) Error!void {
    if (conversion == .normal) return;
    if (conversionOperand(t) != .f64) return c.fail("number conversion rules require a double type", .{});
    switch (conversion) {
        .normal, .coerce, .integer_or_infinity => {},
        .enforce_range => |validation| {
            if (std.math.isNan(validation.range.min) or std.math.isNan(validation.range.max) or validation.range.min > validation.range.max)
                try c.fail("number validation requires an ordered non-NaN range", .{});
            try asciiText(c, validation.error_message, "number range error message");
            if (validation.error_class != .range_error and validation.error_class != .type_error)
                try c.fail("number range validation requires RangeError or TypeError", .{});
        },
        .coerce_clamp => |range| {
            if (!std.math.isFinite(range.min) or !std.math.isFinite(range.max)) try c.fail("number clamp bounds must be finite", .{});
            if (range.min > range.max) try c.fail("number clamp range is reversed", .{});
        },
        .coerce_wrap_clamp => |normalization| {
            if (normalization.bits < 2 or normalization.bits > 53)
                return c.fail("signed Number wrapping requires a width between two and 53 bits", .{});
            const limit: f64 = @floatFromInt(@as(u64, 1) << (normalization.bits - 1));
            const range = normalization.range;
            if (!std.math.isFinite(range.min) or !std.math.isFinite(range.max) or range.min > range.max or
                @trunc(range.min) != range.min or @trunc(range.max) != range.max or range.min < -limit or range.max >= limit)
                try c.fail("wrapped Number clamp bounds must be integers within the signed width", .{});
        },
        .coerce_truncate_or_default, .coerce_truncate_clamp => |normalization| {
            const range = normalization.range;
            if (!std.math.isFinite(range.min) or !std.math.isFinite(range.max) or range.min > range.max)
                try c.fail("number normalization requires a finite ordered range", .{});
            if (!std.math.isFinite(normalization.fallback) or @trunc(normalization.fallback) != normalization.fallback)
                try c.fail("number normalization fallback must be a finite integer", .{});
            if (conversion == .coerce_truncate_clamp) {
                if (@trunc(range.min) != range.min or @trunc(range.max) != range.max)
                    try c.fail("truncated number clamp bounds must be integers", .{});
                if (normalization.fallback < range.min or normalization.fallback > range.max)
                    try c.fail("truncated number clamp fallback must be within its range", .{});
            }
        },
        .node_validate => |validation| {
            if (validation.min == null and validation.max == null) try c.fail("node number validation requires at least one bound", .{});
            if (validation.min) |min| if (!std.math.isFinite(min)) try c.fail("node number validation bounds must be finite", .{});
            if (validation.max) |max| if (!std.math.isFinite(max)) try c.fail("node number validation bounds must be finite", .{});
            if (validation.min != null and validation.max != null and validation.min.? > validation.max.?)
                try c.fail("node number validation range is reversed", .{});
        },
    }
}

fn booleanConversion(c: *Checker, t: Type, conversion: schema.BooleanConversion) Error!void {
    if (conversion == .normal) return;
    if (conversionOperand(t) != .boolean) return c.fail("boolean conversion rules require a boolean type", .{});
    switch (conversion) {
        .strict => |failure| try conversionFailure(c, failure),
        .node_property_typeof => |name| try asciiText(c, name, "boolean diagnostic property name"),
        else => {},
    }
}

// ─── defaults ───

fn defaultValue(c: *Checker, t: Type, value: schema.DefaultValue) Error!void {
    switch (t) {
        .converted => |converted| try defaultValue(c, converted.native, value),
        .boolean => if (value != .boolean) try c.fail("boolean binding default has the wrong type", .{}),
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => {
            const bounds = integerBounds(t).?;
            const number: i128 = switch (value) {
                .signed => |number| number,
                .unsigned => |number| number,
                else => return c.fail("integer binding default has the wrong type", .{}),
            };
            if (number < bounds.min or number > bounds.max) try c.fail("integer binding default is outside the declared type", .{});
        },
        .f64 => switch (value) {
            .float, .signed, .unsigned => {},
            else => try c.fail("floating-point binding default has the wrong type", .{}),
        },
        .dom_string, .usv_string, .byte_string => switch (value) {
            .string => |string| {
                if (!std.unicode.utf8ValidateSlice(string)) return c.fail("string binding default is not valid UTF-8", .{});
                if (std.mem.indexOfScalar(u8, string, 0) != null) try c.fail("string binding default contains a null byte", .{});
                if (t == .byte_string) {
                    var iterator = std.unicode.Utf8View.initUnchecked(string).iterator();
                    while (iterator.nextCodepoint()) |codepoint| {
                        if (codepoint > std.math.maxInt(u8)) {
                            try c.fail("ByteString binding default contains a non-Latin-1 code point", .{});
                            break;
                        }
                    }
                }
            },
            else => try c.fail("string binding default has the wrong type", .{}),
        },
        .enumeration => |enumeration| switch (value) {
            .string => |string| for (enumeration.values) |declared| {
                if (eqlText(string, declared.value)) break;
            } else try c.fail("enumeration binding default is not a declared value", .{}),
            else => try c.fail("enumeration binding default has the wrong type", .{}),
        },
        .any, .engine_value => switch (value) {
            .null, .undefined => {},
            else => try c.fail("opaque JavaScript value defaults must be null or undefined", .{}),
        },
        .branded_value => |branded| switch (value) {
            .null => if (!branded.options.allows_null_default) try c.fail("this branded value does not admit a null default", .{}),
            .undefined => if (!branded.options.allows_undefined_default) try c.fail("this branded value does not admit an undefined default", .{}),
            else => try c.fail("branded value defaults must be null or undefined", .{}),
        },
        .optional => |optional| if (value != .null) try defaultValue(c, optional.child.*, value),
        else => try c.fail("this binding type cannot have a default value", .{}),
    }
}

// ─── converted types ───

fn converterDeclaration(c: *Checker, converter: schema.Converter) Error!void {
    const options = converter.options;
    try identifier(c, converter.name, "custom converter");
    if (options.audit_reason) |reason| try text(c, reason, "custom converter audit reason");
    if (options.infallible and options.may_invoke_js) try c.fail("an infallible custom converter cannot invoke JavaScript", .{});
    if (options.realm_free and (!options.infallible or options.may_invoke_js))
        try c.fail("realm-free custom converters must be infallible and non-invoking", .{});
}

/// A brand cast is reserved: its native and input types, symbol, and
/// contract all derive from the cast it declares.
fn isDerivedBrandCast(c: *Checker, converted: schema.Converted) Error!bool {
    const cast = converted.converter.brand_cast orelse return false;
    const match = cast.match.*;
    if (match != .branded_value) {
        try c.fail("brand casts require a branded JavaScript type", .{});
        return true;
    }
    if (cast.failure == .reject)
        try c.fail("brand casts that raise have no engine-operand definition: {s}", .{converted.converter.name});
    if (cast.input == .optional_engine_value)
        try c.fail("absent-on-mismatch brand casts do not support optional inputs: {s}", .{converted.converter.name});
    const native_matches = if (cast.failure == .absent) switch (converted.native) {
        .optional => |optional| optional.mode == .nullable and structural.eql(optional.child.*, match),
        else => false,
    } else structural.eql(converted.native, match);
    const input_matches = switch (cast.input) {
        .boundary => if (cast.failure == .absent) structural.eql(converted.match, schema.any) else structural.eql(converted.match, match),
        .engine_value => converted.match == .engine_value,
        .optional_engine_value => switch (converted.match) {
            .optional => |optional| optional.mode == .nullable and optional.child.* == .engine_value,
            else => false,
        },
    };
    const name = try c.n.print("bunBindgenBrandCast{s}{t}{t}", .{ match.branded_value.brand.name, cast.failure, cast.input });
    const expected_options: schema.CustomConverterOptions = switch (cast.failure) {
        .reject => .{},
        .absent, .assert => .{ .infallible = true, .realm_free = true },
    };
    return native_matches and input_matches and eqlText(converted.converter.name, name) and
        structural.eql(converted.converter.options, expected_options);
}

fn isReservedConversion(converted: schema.Converted) bool {
    const reserved = schema.reserved_conversions;
    return switch (converted.converter.kind) {
        .custom, .brand_cast => false,
        .property_key => structural.eql(converted, reserved.property_key.converted.*),
        .json_stringify => structural.eql(converted, reserved.json_stringify.converted.*),
        .headers_init => structural.eql(converted, reserved.headers_init_share.converted.*) or
            structural.eql(converted, reserved.headers_init_clone.converted.*),
    };
}

fn convertedRules(c: *Checker, converted: schema.Converted) Error!void {
    const converter = converted.converter;
    if (converter.kind == .custom and converter.options.audit_reason == null)
        try c.fail("custom converters require an audit reason: {s}", .{converter.name});
    try converterDeclaration(c, converter);
    if (converted.options.name) |name| try asciiText(c, name, "converted semantic input name");
    try converterResultOwnership(c, converted.native);
    switch (converter.kind) {
        .custom => {
            if (converter.brand_cast != null) try c.fail("reserved converters must use their schema constructor", .{});
            try customConverterType(c, converted.native, true);
            try customConverterMatchType(c, converted.match);
        },
        .brand_cast => if (!try isDerivedBrandCast(c, converted)) try c.fail("reserved converters must use their schema constructor", .{}),
        .property_key, .json_stringify, .headers_init => if (!isReservedConversion(converted))
            try c.fail("reserved converters must use their schema constructor", .{}),
    }
    switch (converted.match) {
        .void, .utf8_string, .lazy, .converted, .native_instance => try c.fail("this binding type cannot select a converted semantic value", .{}),
        else => {},
    }
}

fn converterResultOwnership(c: *Checker, t: Type) Error!void {
    switch (t) {
        .nominal_handle => try c.fail("custom converters cannot produce nominal resources; use a schema-declared native operation", .{}),
        .discarded => |discarded| try converterResultOwnership(c, discarded.match_type.*),
        .lazy => |child| try converterResultOwnership(c, child.*),
        .optional => |optional| try converterResultOwnership(c, optional.child.*),
        .sequence => |sequence| try converterResultOwnership(c, sequence.child),
        .converted => |converted| try converterResultOwnership(c, converted.native),
        .record => |record| {
            try converterResultOwnership(c, record.key);
            try converterResultOwnership(c, record.value);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try converterResultOwnership(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try converterResultOwnership(c, effectiveUnionMemberType(member)),
        else => {},
    }
}

fn customConverterType(c: *Checker, t: Type, allow_sequence: bool) Error!void {
    switch (t) {
        .any, .engine_value => try c.fail("custom converters cannot produce arbitrary JavaScript values", .{}),
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .dom_string, .usv_string, .byte_string, .node_path, .enumeration => {},
        .branded_value => try c.fail("custom converters cannot produce engine objects", .{}),
        .buffer => |buffer| if (buffer.mode != .copy) try c.fail("custom buffer converters require copy ownership", .{}),
        .optional => |optional| try customConverterType(c, optional.child.*, allow_sequence),
        .sequence => |sequence| {
            if (!allow_sequence) return c.fail("nested custom-converter sequences are outside the binding contract", .{});
            try customConverterType(c, sequence.child, false);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try customConverterType(c, field.type, allow_sequence),
        .union_type => |union_type| for (union_type.members) |member| try customConverterType(c, effectiveUnionMemberType(member), allow_sequence),
        .external_ref => try c.fail("custom converters cannot produce external resources", .{}),
        else => try c.fail("this binding type cannot use a custom converter", .{}),
    }
}

fn customConverterMatchType(c: *Checker, t: Type) Error!void {
    switch (t) {
        .any, .engine_value => try c.fail("custom converters cannot consume arbitrary JavaScript values", .{}),
        .nominal_handle => try c.fail("custom converters cannot consume nominal resources; use a schema-declared native operation", .{}),
        .branded_value => |branded| if (branded.options.specificity == .generic)
            try c.fail("custom converters require a specific JavaScript brand; generic engine values cannot be converter inputs", .{}),
        .buffer => |buffer| if (buffer.mode != .copy) try c.fail("custom converters require copy-buffer match inputs", .{}),
        .optional => |optional| try customConverterMatchType(c, optional.child.*),
        .sequence => |sequence| try customConverterMatchType(c, sequence.child),
        .discarded => |discarded| if (discarded.match == .semantic_type) try customConverterMatchType(c, discarded.match_type.*),
        .dictionary => |dictionary| for (dictionary.fields) |field| try customConverterMatchType(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try customConverterMatchType(c, effectiveUnionMemberType(member)),
        .record => |record| {
            try customConverterMatchType(c, record.key);
            try customConverterMatchType(c, record.value);
        },
        else => {},
    }
}

// ─── value directions ───

fn javaScriptInputType(c: *Checker, t: Type, use: []const u8) Error!void {
    switch (t) {
        .nominal_handle => try c.fail("nominal resources cannot be {s}", .{use}),
        .utf8_string => try c.fail("UTF8String is a native-to-JavaScript type and cannot be {s}", .{use}),
        .native_slice => try c.fail("native slices cannot be {s}", .{use}),
        .discarded => |discarded| try javaScriptInputType(c, discarded.match_type.*, use),
        .lazy => |child| try javaScriptInputType(c, child.*, use),
        .optional => |optional| try javaScriptInputType(c, optional.child.*, use),
        .sequence => |sequence| {
            if (sequence.options.flavor == .frozen_array) try c.fail("FrozenArray is a native-to-JavaScript type and cannot be {s}", .{use});
            try javaScriptInputType(c, sequence.child, use);
        },
        .converted => |converted| try javaScriptInputType(c, converted.match, use),
        .dictionary => |dictionary| {
            if (dictionary.options.result_class != null) try c.fail("plain-class dictionary results cannot be {s}", .{use});
            for (dictionary.fields) |field| try javaScriptInputType(c, field.type, use);
        },
        .union_type => |union_type| for (union_type.members) |member| try javaScriptInputType(c, effectiveUnionMemberType(member), use),
        .record => |record| {
            try javaScriptInputType(c, record.key, use);
            try javaScriptInputType(c, record.value, use);
        },
        else => {},
    }
}

fn javaScriptArguments(c: *Checker, arguments: schema.Arguments) Error!void {
    switch (arguments) {
        .list => |list| for (list) |argument| try javaScriptInputType(c, effectiveArgumentType(argument), "used as a JavaScript argument"),
        .overloads => |overloads| for (overloads.cases) |case| {
            for (case.args) |argument| try javaScriptInputType(c, effectiveArgumentType(argument), "used as a JavaScript argument");
        },
    }
}

fn resultType(c: *Checker, t: Type, backend: schema.Backend) Error!void {
    switch (t) {
        .class_ref => |class_ref| if (class_ref.target == null) try c.fail("this-class references are only valid as class member results", .{}),
        .nominal_handle => try c.fail("nominal resources cannot be materialized as JavaScript results", .{}),
        .node_path => try c.fail("NodePath is an argument-only semantic type", .{}),
        .native_slice => try c.fail("native slices are argument-only engine types", .{}),
        .discarded => |discarded| if (discarded.match == .semantic_type) try c.fail("discarded semantic values are argument-only", .{}),
        .converted => try c.fail("converted semantic types are argument-only; return their native value type", .{}),
        .lazy => try c.fail("lazy semantic types are argument-only", .{}),
        .external_ref => try c.fail("external references are argument-only; return a class reference", .{}),
        .buffer => |buffer| if (buffer.access == .read_write) {
            try c.fail("writable buffers are argument-only types", .{});
        } else if (buffer.mode != .copy) {
            try c.fail("buffer results require copy ownership", .{});
        },
        .utf8_string => if (backend != .zig) try c.fail("UTF8String results require a Zig backend", .{}),
        .optional => |optional| {
            if (optional.mode == .matched) try c.fail("optionalMatch is an argument-only semantic type", .{});
            try resultType(c, optional.child.*, backend);
        },
        .sequence => |sequence| {
            if (sequence.options.element_pattern != null) try c.fail("sequence element patterns are argument-only", .{});
            try resultType(c, sequence.child, backend);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| {
            if (field.options.source == .dictionary) try c.fail("dictionary source fields are argument-only", .{});
            try resultType(c, field.type, backend);
        },
        .union_type => |union_type| {
            if (union_type.options.input_tag != null) try c.fail("tagged union inputs cannot be JavaScript results", .{});
            for (union_type.members) |member| try resultType(c, effectiveUnionMemberType(member), backend);
        },
        .record => |record| {
            try resultType(c, record.key, backend);
            try resultType(c, record.value, backend);
        },
        else => {},
    }
}

fn classMemberResultType(c: *Checker, t: Type, backend: schema.Backend) Error!void {
    if (normalize.isThisClassRef(t)) {
        if (backend != .zig) try c.fail("class reference results require a Zig backend", .{});
        return;
    }
    try resultType(c, t, backend);
}

// ─── arguments ───

fn argumentRules(c: *Checker, argument: schema.Argument) Error!void {
    const options = argument.options;
    const effective = effectiveArgumentType(argument);
    try wireIdentifier(c, argument.name, "argument");
    if (options.selection != null and (argument.type != .union_type or options.presence != .required or options.missing != .undefined or
        options.default_value != null or options.rest or options.source != null or options.ownership != .borrowed))
        try c.fail("selected arguments require a required borrowed union", .{});
    if (options.source) |source| {
        switch (source) {
            .argument => |name| try wireIdentifier(c, name, "argument projection source"),
            .cached_slot => |name| try identifier(c, name, "cached-slot projection source"),
            .this_value => {},
        }
        const lazy_projection = effective == .lazy and options.presence == .optional and options.missing == .omitted;
        const eager_projection = effective != .lazy and options.presence == .required and options.missing == .undefined;
        if ((!lazy_projection and !eager_projection) or options.default_value != null or options.rest or options.ownership != .borrowed)
            try c.fail("argument projections require optional borrowed lazy values or required borrowed conversions", .{});
    }
    if (containsContextualDiscard(effective))
        try c.fail("arguments that discard a value require discardAny(.classification), discardAny(.presence), or discardAny(.ignored)", .{});
    if (effective == .void) try c.fail("binding arguments require a value type", .{});
    if (effective == .native_instance) try c.fail("native-instance is constructor-return-only and cannot be an argument", .{});
    if (options.ownership == .transfer) {
        if (!containsOwnedWireNominalHandle(effective)) try c.fail("argument ownership transfer requires an owned nominal handle", .{});
        if (options.presence != .required or options.missing != .undefined or options.default_value != null or
            options.boolean_conversion != .normal or options.integer_conversion != .normal or
            options.number_conversion != .normal or options.rest)
            try c.fail("transferred arguments must use the plain required positional contract", .{});
    }
    if (effective == .lazy) {
        if (options.deferred_reason) |reason| {
            try asciiText(c, reason, "lazy argument reason");
        } else {
            try c.fail("a lazy argument must justify its observable conversion order: {s}", .{argument.name});
        }
        if (options.presence == .default_value or options.default_value != null) try c.fail("lazy arguments cannot declare a default value", .{});
    } else if (options.deferred_reason != null) {
        try c.fail("only a lazy argument can declare a deferred conversion reason", .{});
    }
    if (options.rest) {
        if (options.presence != .required) try c.fail("a rest argument cannot be optional or defaulted", .{});
        if (options.default_value != null) try c.fail("a rest argument cannot declare a default value", .{});
        if (options.integer_conversion != .normal) try c.fail("a rest argument cannot declare integer conversion rules", .{});
        if (options.boolean_conversion != .normal) try c.fail("a rest argument cannot declare boolean conversion rules", .{});
        if (options.number_conversion != .normal) try c.fail("a rest argument cannot declare number conversion rules", .{});
        if (effective != .lazy) try restElementType(c, effective);
    }
    if (effective == .discarded) {
        if (options.rest and effective.discarded.purpose != .count) try c.fail("discarded rest arguments require the count purpose", .{});
        if (!options.rest and effective.discarded.purpose == .count)
            try c.fail("the discarded count purpose is only valid for rest arguments", .{});
    }
    switch (options.presence) {
        .required, .optional => if (options.default_value != null) try c.fail("only a default-value argument may declare a default value", .{}),
        .default_value => if (options.default_value == null) try c.fail("a default-value argument must declare a default value", .{}),
    }
    if (options.default_value) |value| try defaultValue(c, effective, value);
    try valueConversion(c, effective, options.boolean_conversion, options.integer_conversion, options.number_conversion, "argument");
}

fn restElementType(c: *Checker, t: Type) Error!void {
    switch (t) {
        .void, .node_path, .lazy, .converted, .class_ref, .native_instance, .sequence, .record => try c.fail("this binding type cannot be used as a rest element", .{}),
        .buffer => {},
        .callback => try c.fail("typed callback rest arguments are outside the binding contract", .{}),
        .optional => |optional| try restElementType(c, optional.child.*),
        .dictionary => |dictionary| for (dictionary.fields) |field| try restElementType(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try restElementType(c, effectiveUnionMemberType(member)),
        else => {},
    }
}

fn argumentList(c: *Checker, arguments: []const schema.Argument) Error!void {
    var saw_projection = false;
    for (arguments, 0..) |argument, index| {
        try argumentRules(c, argument);
        const options = argument.options;
        for (arguments[0..index]) |previous| {
            if (eqlText(previous.name, argument.name)) {
                try c.fail("binding argument names must be unique", .{});
                break;
            }
        }
        if (options.selection) |selection| try argumentSelection(c, arguments[0..index], argument, selection);
        if (options.source) |source| {
            saw_projection = true;
            const source_name = switch (source) {
                .this_value, .cached_slot => continue,
                .argument => |name| name,
            };
            var found_source = false;
            for (arguments[0..index]) |previous| {
                if (previous.options.source != null or !eqlText(previous.name, source_name)) continue;
                if (previous.options.presence == .default_value)
                    try c.fail("argument projections cannot source default-valued arguments: {s}", .{source_name});
                if (effectiveArgumentType(argument) != .lazy and previous.options.presence != .required)
                    try c.fail("eager projections require a required positional source: {s}", .{source_name});
                found_source = true;
            }
            if (!found_source) try c.fail("argument projection source must name an earlier positional argument: {s}", .{source_name});
        } else if (saw_projection) {
            try c.fail("positional arguments must precede argument projections", .{});
        }
        if (options.rest and index + 1 != arguments.len) try c.fail("a rest argument must be the final argument", .{});
    }
    var saw_optional = false;
    for (arguments) |argument| {
        if (argument.options.source != null or argument.options.rest) continue;
        if (argument.options.presence == .required) {
            if (saw_optional) try c.fail("required arguments must precede optional and default-value arguments", .{});
        } else {
            saw_optional = true;
        }
    }
}

fn argumentSelection(c: *Checker, previous_arguments: []const schema.Argument, argument: schema.Argument, selection: schema.ArgumentSelection) Error!void {
    const selector = for (previous_arguments) |previous| {
        if (eqlText(previous.name, selection.source) and previous.options.source == null and
            previous.options.presence == .required and effectiveArgumentType(previous) == .enumeration)
            break effectiveArgumentType(previous).enumeration;
    } else return c.fail("union selection requires an earlier required enumeration argument", .{});
    if (argument.type != .union_type) return;
    const union_type = argument.type.union_type;
    if (union_type.options.input_tag != null) try c.fail("an argument selector cannot replace a union's input tag", .{});
    if (selection.cases.len != selector.values.len) try c.fail("union selection must cover every enumeration value", .{});
    for (selector.values) |value| {
        var count: usize = 0;
        for (selection.cases) |case| {
            if (eqlText(value.name, case.value)) count += 1;
        }
        if (count != 1) try c.fail("union selection requires exactly one case for each enumeration value", .{});
    }
    for (selection.cases) |case| {
        for (union_type.members) |member| {
            if (eqlText(member.name, case.member)) break;
        } else try c.fail("union selection names an unknown member", .{});
    }
    for (union_type.members) |member| {
        for (selection.cases) |case| {
            if (eqlText(member.name, case.member)) break;
        } else try c.fail("union selection must cover every union member", .{});
        switch (effectiveUnionMemberType(member)) {
            .buffer => |buffer| if (buffer.mode != .copy or buffer.access != .read_only) try c.fail("selected buffers require read-only copies", .{}),
            .dictionary => |dictionary| if (typeContainsLazy(.{ .dictionary = dictionary }) or dictionary.options.finish_fields.len != 0)
                try c.fail("selected union members must be copy buffers or eager dictionaries", .{}),
            else => try c.fail("selected union members must be copy buffers or eager dictionaries", .{}),
        }
    }
}

fn noArgumentTransfers(c: *Checker, arguments: []const schema.Argument) Error!void {
    for (arguments) |argument| {
        if (argument.options.ownership == .transfer)
            try c.fail("argument ownership transfer is restricted to engine shims and native exports", .{});
    }
}

fn noCachedSlotProjections(c: *Checker, arguments: []const schema.Argument) Error!void {
    for (arguments) |argument| {
        const source = argument.options.source orelse continue;
        if (source == .cached_slot) try c.fail("cached-slot projections require a non-overloaded native instance method", .{});
    }
}

fn receiverProjections(c: *Checker, this_type: ?Type, arguments: []const schema.Argument) Error!void {
    for (arguments) |argument| {
        const source = argument.options.source orelse continue;
        if ((source == .this_value or source == .cached_slot) and this_type == null)
            try c.fail("receiver projections require a declared typed this value", .{});
    }
}

fn argumentProfiles(c: *Checker, arguments: []const schema.Argument, profile: schema.Profile) Error!void {
    for (arguments) |argument| {
        const options = argument.options;
        const effective = effectiveArgumentType(argument);
        try booleanConversionProfile(c, options.boolean_conversion, profile);
        try integerConversionProfile(c, options.integer_conversion, profile);
        try integerRepresentationConversion(c, effective, options.integer_conversion);
        try numberConversionProfile(c, options.number_conversion, profile);
        try typeProfiles(c, effective, profile);
    }
}

fn typeProfiles(c: *Checker, t: Type, profile: schema.Profile) Error!void {
    switch (t) {
        .dom_string, .usv_string, .byte_string => |string| if (string.type_error_format == .property_typeof and profile != .node)
            try c.fail("Node string property errors require the node conversion profile", .{}),
        .node_path => if (profile != .node) try c.fail("NodePath requires the node conversion profile", .{}),
        .buffer => |buffer| if (buffer.options.result_representation != null) try c.fail("represented buffers are result-only semantic types", .{}),
        .converted => |converted| try typeProfiles(c, converted.match, profile),
        .discarded => |discarded| try typeProfiles(c, discarded.match_type.*, profile),
        .lazy => |child| try typeProfiles(c, child.*, profile),
        .optional => |optional| try typeProfiles(c, optional.child.*, profile),
        .sequence => |sequence| {
            if (sequence.options.flavor == .frozen_array) try c.fail("FrozenArray is a result-only semantic type", .{});
            const conversion = sequence.options.element_conversion;
            try booleanConversionProfile(c, conversion.boolean_conversion, profile);
            try integerConversionProfile(c, conversion.integer_conversion, profile);
            try integerRepresentationConversion(c, sequence.child, conversion.integer_conversion);
            try numberConversionProfile(c, conversion.number_conversion, profile);
            try typeProfiles(c, sequence.child, profile);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| {
            const field_profile = field.options.profile orelse profile;
            try booleanConversionProfile(c, field.options.boolean_conversion, field_profile);
            try integerConversionProfile(c, field.options.integer_conversion, field_profile);
            try integerRepresentationConversion(c, field.type, field.options.integer_conversion);
            try numberConversionProfile(c, field.options.number_conversion, field_profile);
            if (field.options.node_unsupported != null and field_profile != .node)
                try c.fail("unsupported Node dictionary fields require the node conversion profile", .{});
            if (field.options.node_incompatible_with != null and field_profile != .node)
                try c.fail("incompatible Node dictionary fields require the node conversion profile", .{});
            try typeProfiles(c, field.type, field_profile);
        },
        .union_type => |union_type| for (union_type.members) |member| {
            const member_type = effectiveUnionMemberType(member);
            try booleanConversionProfile(c, member.options.boolean_conversion, profile);
            try integerConversionProfile(c, member.options.integer_conversion, profile);
            try integerRepresentationConversion(c, member_type, member.options.integer_conversion);
            try numberConversionProfile(c, member.options.number_conversion, profile);
            try typeProfiles(c, member_type, profile);
        },
        .record => |record| {
            try typeProfiles(c, record.key, profile);
            try typeProfiles(c, record.value, profile);
        },
        .enumeration => |enumeration| if (enumeration.options.node_invalid_value != null and profile != .node)
            try c.fail("Node enumeration errors require the node conversion profile", .{}),
        else => {},
    }
}

fn integerRepresentationConversion(c: *Checker, t: Type, conversion: schema.IntegerConversion) Error!void {
    const representation: schema.IntegerRepresentation = switch (t) {
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize => integerRepresentation(t) orelse .number,
        .lazy => |child| return integerRepresentationConversion(c, child.*, conversion),
        .optional => |optional| return integerRepresentationConversion(c, optional.child.*, conversion),
        .converted => |converted| return integerRepresentationConversion(c, converted.match, conversion),
        else => return,
    };
    if (representation == .number) return;
    switch (conversion) {
        .normal, .modulo, .node_validate, .node_validate_prose => {},
        .node_coerce => if (representation != .number_or_bigint)
            try c.fail("coerced integer validation requires Number input representation", .{}),
        .coerce_truncate_or_default => if (representation != .number_or_bigint)
            try c.fail("coerced integer defaults require Number input representation", .{}),
        else => try c.fail("Integer representations accepting BigInt require normal, modulo, or Node range conversion", .{}),
    }
}

fn booleanConversionProfile(c: *Checker, conversion: schema.BooleanConversion, profile: schema.Profile) Error!void {
    if (conversion == .node_property_typeof and profile != .node)
        try c.fail("Node boolean property errors require the node conversion profile", .{});
}

fn integerConversionProfile(c: *Checker, conversion: schema.IntegerConversion, profile: schema.Profile) Error!void {
    switch (conversion) {
        .node_validate, .node_validate_with, .node_coerce, .node_validate_prose, .node_truncate, .node_receiver_byte_length => if (profile != .node)
            try c.fail("node integer validation requires the node conversion profile", .{}),
        else => {},
    }
}

fn numberConversionProfile(c: *Checker, conversion: schema.NumberConversion, profile: schema.Profile) Error!void {
    if (conversion == .enforce_range and profile == .node) try c.fail("node number ranges require node_validate error mapping", .{});
    if (conversion == .node_validate and profile != .node) try c.fail("node number validation requires the node conversion profile", .{});
}

fn typedRestBackend(c: *Checker, arguments: []const schema.Argument, backend: schema.Backend) Error!void {
    for (arguments) |argument| {
        if (argument.options.rest and effectiveArgumentType(argument) == .lazy and backend == .cpp)
            try c.fail("C++ rest arguments use eager element conversion; deferred per-element conversion requires a Zig backend", .{});
    }
}

fn lazyArguments(c: *Checker, arguments: []const schema.Argument, backend: schema.Backend) Error!void {
    for (arguments) |argument| {
        if (argument.options.selection != null and backend != .cpp) try c.fail("argument selection requires a C++ host binding", .{});
        if (argument.options.source != null and backend == .builtin) try c.fail("argument projections require a Zig or C++ backend", .{});
        const effective = effectiveArgumentType(argument);
        if (effective != .lazy) continue;
        if (typeContainsLazy(effective.lazy.*) and backend == .builtin) try c.fail("builtin lazy arguments cannot contain deferred fields", .{});
        try lazyType(c, effective.lazy.*, true);
    }
}

fn lazyType(c: *Checker, t: Type, allow_lease: bool) Error!void {
    switch (t) {
        .void, .native_instance => try c.fail("this binding type cannot be converted lazily", .{}),
        .lazy => |child| try lazyType(c, child.*, allow_lease),
        .converted => |converted| {
            try lazyType(c, converted.match, allow_lease);
            try lazyType(c, converted.native, allow_lease);
        },
        .buffer => |buffer| if (buffer.mode == .lease and !allow_lease)
            try c.fail("lazy engine shims and native exports require copy-buffer ownership", .{}),
        .optional => |optional| try lazyType(c, optional.child.*, allow_lease),
        .sequence => |sequence| try lazyType(c, sequence.child, allow_lease),
        .dictionary => |dictionary| for (dictionary.fields) |field| try lazyType(c, field.type, allow_lease),
        .union_type => |union_type| for (union_type.members) |member| try lazyType(c, effectiveUnionMemberType(member), allow_lease),
        .record => |record| {
            try lazyType(c, record.key, allow_lease);
            try lazyType(c, record.value, allow_lease);
        },
        else => {},
    }
}

// ─── overloads ───

fn overloadCase(c: *Checker, case: schema.OverloadCase) Error!void {
    try identifier(c, case.name, "overload case");
    try argumentList(c, case.args);
    try noArgumentTransfers(c, case.args);
    const indices = case.options.discriminants orelse return;
    if (indices.len == 0) try c.fail("an overload must select at least one discriminant", .{});
    for (indices, 0..) |index, position| {
        if (index >= case.args.len) {
            try c.fail("overload discriminant index is outside the argument list", .{});
            continue;
        }
        if (case.args[index].options.rest) try c.fail("an overload discriminant cannot be a rest argument", .{});
        for (indices[0..position]) |previous| {
            if (previous == index) try c.fail("duplicate overload discriminant index", .{});
        }
    }
}

fn overloadSet(c: *Checker, overloads: schema.Overloads) Error!void {
    const cases = overloads.cases;
    const options = overloads.options;
    if (cases.len < 2) try c.fail("an overload set must contain at least two cases", .{});
    if (cases.len > std.math.maxInt(u8)) try c.fail("an overload set may contain at most 255 cases", .{});
    if (options.fallback_case != null and !options.ordered) try c.fail("an overload fallback requires ordered conversion", .{});
    for (cases, 0..) |case, index| {
        try overloadCase(c, case);
        if (case.options.discriminants != null and !options.ordered)
            try c.fail("explicit overload discriminants require ordered dispatch", .{});
        for (cases[0..index]) |previous| {
            if (eqlText(previous.name, case.name)) try c.fail("duplicate overload case name: {s}", .{case.name});
            if (!options.ordered and overloadCasesOverlap(previous, case, options.accept_extra_arguments))
                try c.fail("overload cases '{s}' and '{s}' overlap; declare an ordered overload set to make precedence explicit", .{ previous.name, case.name });
        }
    }
    if (options.fallback_case) |fallback| {
        for (cases, 0..) |case, index| {
            if (!eqlText(fallback, case.name)) continue;
            if (index + 1 != cases.len) try c.fail("an overload fallback must be the final case", .{});
            break;
        } else try c.fail("overload fallback does not name a case: {s}", .{fallback});
    }
}

fn requiredArgumentCount(arguments: []const schema.Argument) usize {
    var count: usize = 0;
    for (arguments) |argument| {
        if (argument.options.rest or argument.options.presence != .required) break;
        count += 1;
    }
    return count;
}

fn maximumArgumentCount(arguments: []const schema.Argument, accept_extra_arguments: bool) usize {
    if (accept_extra_arguments or (arguments.len > 0 and arguments[arguments.len - 1].options.rest)) return std.math.maxInt(usize);
    return arguments.len;
}

fn overloadCasesOverlap(left: schema.OverloadCase, right: schema.OverloadCase, accept_extra_arguments: bool) bool {
    const minimum = @max(requiredArgumentCount(left.args), requiredArgumentCount(right.args));
    const maximum = @min(maximumArgumentCount(left.args, accept_extra_arguments), maximumArgumentCount(right.args, accept_extra_arguments));
    if (minimum > maximum) return false;
    for (0..minimum) |index| {
        if (!unionMembersOverlap(effectiveArgumentType(left.args[index]), effectiveArgumentType(right.args[index]))) return false;
    }
    return true;
}

// ─── domain errors ───

fn domainErrors(c: *Checker, errors: schema.DomainErrors, backend: ir.Backend) Error!void {
    if (errors.errors.len > std.math.maxInt(u8)) try c.fail("a function may declare at most 255 domain errors", .{});
    for (errors.errors, 0..) |domain_error, index| {
        try domainError(c, domain_error, backend);
        for (errors.errors[0..index]) |previous| {
            if (eqlText(previous.name, domain_error.name)) try c.fail("duplicate domain error name: {s}", .{domain_error.name});
        }
    }
}

fn domainError(c: *Checker, domain_error: schema.DomainError, backend: ir.Backend) Error!void {
    const payload = domain_error.payload;
    try identifier(c, domain_error.name, "domain error");
    try typeTree(c, payload);
    if (containsOwnedWireNominalHandle(payload))
        return c.fail("domain error payloads cannot contain owned nominal handles", .{});
    try resultType(c, payload, backend);
    switch (domain_error.declaration) {
        .class_instance => if (payload != .class_ref) try c.fail("class error payloads must be class references", .{}),
        .aggregate_error => |options| {
            if (payload != .sequence) try c.fail("aggregate error payloads must be sequences", .{});
            try text(c, options.message, "aggregate error message");
        },
        .error_object => |options| {
            try errorObjectMessage(c, payload, options.message);
            if (options.code) |code| try identifier(c, code, "domain error code");
        },
        .dom_exception => |exception| try errorObjectMessage(c, payload, exception.message),
        .builtin_error => |options| {
            if (payload != .dictionary) try c.fail("builtin error payloads must be dictionaries", .{});
            try identifier(c, options.group, "builtin error group");
            try identifier(c, options.function, "builtin error function");
        },
        .system_error => |options| if (options.name_override) |override| try text(c, override, "system error name override"),
        .system_error_with_info => {},
    }
}

fn errorObjectMessage(c: *Checker, payload: Type, message: schema.ErrorMessage) Error!void {
    if (payload == .lazy) try c.fail("domain error payloads cannot be lazy", .{});
    switch (message) {
        .literal => |literal| {
            if (payload != .void) try c.fail("a literal-message domain error must have a void payload", .{});
            try text(c, literal, "domain error message");
        },
        .payload => if (!isString(payload)) try c.fail("a payload-message domain error must have a string payload", .{}),
    }
}

// ─── shared callable rules ───

fn exposureRules(c: *Checker, exposure: schema.Exposure) Error!void {
    switch (exposure) {
        .never, .always => {},
        .target => |target| try text(c, target, "binding target exposure"),
        .os, .not_os => |os| try text(c, os, "binding operating-system exposure"),
        .feature => |feature| try text(c, feature, "binding feature exposure"),
    }
}

fn backendRules(c: *Checker, backend: schema.Backend, builtin: ?[]const u8, errors: schema.DomainErrors, constructor_backend: bool) Error!void {
    switch (backend) {
        .builtin => {
            if (constructor_backend) try c.fail("generated class constructors require a native backend", .{});
            if (builtin) |symbol| {
                try identifier(c, symbol, "builtin generator");
            } else {
                try c.fail("a builtin backend requires a builtin generator symbol", .{});
            }
            if (errors.errors.len != 0) try c.fail("builtin backends cannot declare native domain errors", .{});
        },
        .cpp => {
            if (constructor_backend) try c.fail("native-representation constructors create Zig state and require a Zig backend", .{});
            if (builtin != null) try c.fail("only a builtin backend may declare a builtin generator symbol", .{});
        },
        .zig => if (builtin != null) try c.fail("only a builtin backend may declare a builtin generator symbol", .{}),
    }
}

fn completionRules(c: *Checker, completion_options: ?schema.CompletionOptions, backend: schema.Backend) Error!void {
    const completion = completion_options orelse return;
    if (backend == .builtin) try c.fail("builtin backends cannot use native completion endpoints", .{});
    if (completion.error_delivery == .vm and (backend != .zig or completion.delivery != .vm))
        try c.fail("VM-materialized errors require a Zig VM-delivered completion", .{});
    if (completion.settlement == .ready_at_return and completion.delivery != .vm)
        try c.fail("ready-at-return completion settlement requires VM delivery", .{});
    if (backend == .cpp and completion.delivery != .wire) try c.fail("C++ completions require an any-thread native wire payload", .{});
    if (completion.materializer) |materializer| {
        if (backend != .cpp or completion.delivery != .wire)
            try c.fail("declarative completion materializers require a C++ wire completion", .{});
        if (c.n.engineShimIdOf(materializer) == null) {
            try c.fail("a completion materializer must reference a declared engine operation", .{});
        } else {
            const shim = materializer.shim;
            const valid_argument = shim.args.len == 1 and switch (effectiveArgumentType(shim.args[0])) {
                .nominal_handle => |handle| handle.options.ownership == .owned,
                else => false,
            } and shim.args[0].options.ownership == .borrowed and shim.args[0].options.presence == .required;
            if (!valid_argument) try c.fail("a completion materializer must borrow exactly one owned nominal resource", .{});
            if (shim.options.realm != .current or shim.options.affinity != .vm)
                try c.fail("a completion materializer must run in the completion realm on the VM thread", .{});
            if (shim.options.result_source != .native) try c.fail("a completion materializer must return its declared logical value", .{});
        }
    }
    switch (completion.sender_drop) {
        .reject => |message| try text(c, message, "completion drop rejection"),
        .cancel, .leave_pending => {},
    }
}

fn invocationOptions(c: *Checker, caller_source_location: bool, backend: schema.Backend) Error!void {
    if (caller_source_location and backend == .builtin) try c.fail("caller source locations require a Zig or C++ backend", .{});
}

const InvocationValue = struct {
    reserved_name: []const u8,
    builtin_message: []const u8,
    lazy_message: []const u8,
    use: []const u8,
    reserved_message: []const u8,
};

const this_value: InvocationValue = .{
    .reserved_name = "bindingThis",
    .builtin_message = "converted this values require a Zig or C++ backend",
    .lazy_message = "this values cannot use lazy conversion",
    .use = "used as a typed this value",
    .reserved_message = "bindingThis is reserved for a converted this value",
};

const new_target_value: InvocationValue = .{
    .reserved_name = "bindingNewTarget",
    .builtin_message = "converted new targets require a Zig or C++ backend",
    .lazy_message = "new targets cannot use lazy conversion",
    .use = "used as a typed new target",
    .reserved_message = "bindingNewTarget is reserved for a converted new target",
};

const callee_value: InvocationValue = .{
    .reserved_name = "bindingCallee",
    .builtin_message = "converted callee values require a Zig or C++ backend",
    .lazy_message = "callee values cannot use lazy conversion",
    .use = "used as a typed callee value",
    .reserved_message = "bindingCallee is reserved for a converted callee value",
};

/// A converted invocation value is converted like a synthetic argument.
fn typedInvocationValue(
    c: *Checker,
    value: InvocationValue,
    value_type: ?Type,
    backend: schema.Backend,
    profile: schema.Profile,
    arguments: schema.Arguments,
) Error!void {
    const t = value_type orelse return;
    try typeTree(c, t);
    if (backend == .builtin) try c.fail("{s}", .{value.builtin_message});
    if (t == .lazy) try c.fail("{s}", .{value.lazy_message});
    try javaScriptInputType(c, t, value.use);
    const reserved = switch (arguments) {
        .list => |list| for (list) |argument| {
            if (eqlText(argument.name, value.reserved_name)) break true;
        } else false,
        .overloads => |overloads| for (overloads.cases) |case| {
            if (for (case.args) |argument| {
                if (eqlText(argument.name, value.reserved_name)) break true;
            } else false) break true;
        } else false,
    };
    if (reserved) try c.fail("{s}", .{value.reserved_message});
    const synthetic = [_]schema.Argument{.{ .name = value.reserved_name, .type = t, .options = .{} }};
    try argumentRules(c, synthetic[0]);
    try argumentProfiles(c, &synthetic, profile);
}

fn typedThisValue(c: *Checker, this_type: ?Type, backend: schema.Backend, profile: schema.Profile, arguments: schema.Arguments) Error!void {
    switch (arguments) {
        .list => |list| try receiverProjections(c, this_type, list),
        .overloads => |overloads| for (overloads.cases) |case| try receiverProjections(c, this_type, case.args),
    }
    try typedInvocationValue(c, this_value, this_type, backend, profile, arguments);
}

/// Rules every argument list of a call shares, whether a plain list or an
/// overload case.
fn callArgumentLists(c: *Checker, arguments: schema.Arguments, backend: schema.Backend, profile: schema.Profile) Error!void {
    switch (arguments) {
        .list => |list| {
            try typedRestBackend(c, list, backend);
            try lazyArguments(c, list, backend);
            try argumentProfiles(c, list, profile);
        },
        .overloads => |overloads| for (overloads.cases) |case| {
            try noCachedSlotProjections(c, case.args);
            try typedRestBackend(c, case.args, backend);
            try lazyArguments(c, case.args, backend);
            try argumentProfiles(c, case.args, profile);
        },
    }
}

fn argumentTypeTrees(c: *Checker, arguments: schema.Arguments) Error!void {
    switch (arguments) {
        .list => |list| for (list) |argument| try typeTree(c, argument.type),
        .overloads => |overloads| for (overloads.cases) |case| {
            for (case.args) |argument| try typeTree(c, argument.type);
        },
    }
}

// ─── module functions ───

fn functionRules(c: *Checker, function: schema.Function) Error!void {
    const options = function.options;
    const arguments = function.arguments;
    const overloaded = arguments == .overloads;
    try identifier(c, function.name, "function");
    try argumentTypeTrees(c, arguments);
    try typeTree(c, function.result);
    if (options.realm_identity) |identity| {
        try textAllowEmpty(c, identity.name, "realm function name");
        if (options.backend == .builtin or options.callback_data != null or options.new_target_type != null)
            try c.fail("realm function identity requires a native non-constructor function without callback data", .{});
    }
    if (options.missing_required_arguments == .failure) try conversionFailure(c, options.missing_required_arguments.failure);
    if (options.type_predicate) |target| {
        try typeTree(c, target);
        switch (target) {
            .branded_value, .class_ref => {},
            .external_ref => |external| if (external.options.brand == null) try c.fail("type predicates require a branded external reference", .{}),
            else => try c.fail("type predicates require a branded value, class reference, or branded external reference", .{}),
        }
    }
    if (function.result == .native_instance) try c.fail("native-instance is constructor-return-only and cannot be a function result", .{});
    if (function.result == .lazy) try c.fail("lazy values cannot be function results", .{});
    try domainErrors(c, options.errors, options.backend);
    try exposureRules(c, options.exposure);
    try backendRules(c, options.backend, options.builtin, options.errors, false);
    try resultType(c, function.result, options.backend);
    try invocationOptions(c, options.caller_source_location, options.backend);
    try typedThisValue(c, options.this_value_type, options.backend, options.profile, arguments);
    try typedInvocationValue(c, new_target_value, options.new_target_type, options.backend, options.profile, arguments);
    try typedInvocationValue(c, callee_value, options.callee_value_type, options.backend, options.profile, arguments);
    if (options.callback_data) |data| {
        try zigDeclPath(c, data.zig_type, "callback data Zig type");
        if (options.backend != .zig) try c.fail("callback data requires a Zig backend", .{});
        if (options.callee_value_type != null) try c.fail("callback data cannot be combined with a callee value", .{});
        if (overloaded) try c.fail("callback data functions cannot be overloaded", .{});
    }
    try javaScriptArguments(c, arguments);
    if (options.promise_reaction_handler) {
        if (options.backend == .builtin) try c.fail("promise reaction handlers require a native host function", .{});
        if (options.callback_data != null) try c.fail("promise reaction handlers cannot carry callback data", .{});
        if (options.completion != null) try c.fail("promise reaction handlers cannot create native completion endpoints", .{});
        if (overloaded) try c.fail("promise reaction handlers cannot be overloaded", .{});
    }
    try completionRules(c, options.completion, options.backend);
    if (options.conversion_program != null and (options.backend == .builtin or overloaded or options.type_predicate != null))
        try c.fail("declared conversion programs require a non-overloaded native function", .{});
    switch (arguments) {
        .overloads => |overloads| {
            try overloadSet(c, overloads);
            if (options.type_predicate != null) try c.fail("type predicates cannot be overloaded", .{});
            if (options.completion != null) try c.fail("asynchronous overloads are outside the binding contract", .{});
            try callArgumentLists(c, arguments, options.backend, options.profile);
        },
        .list => |list| {
            try argumentList(c, list);
            try noCachedSlotProjections(c, list);
            try noArgumentTransfers(c, list);
            try callArgumentLists(c, arguments, options.backend, options.profile);
            if (options.type_predicate != null) {
                if (options.backend != .cpp or function.result != .boolean or options.profile != .exact)
                    try c.fail("type predicates require an exact-profile generated C++ boolean function", .{});
                if (options.builtin != null or options.completion != null or options.this_value_type != null or
                    options.new_target_type != null or options.callee_value_type != null or options.callback_data != null or
                    options.caller_source_location or options.errors.errors.len != 0)
                    try c.fail("type predicates cannot declare implementation-specific options", .{});
                if (list.len != 1 or !structural.eql(effectiveArgumentType(list[0]), schema.any) or
                    list[0].options.presence != .required or list[0].options.rest)
                    try c.fail("type predicates require one plain opaque value argument", .{});
            }
        },
    }
}

// ─── engine shims ───

fn engineShimRules(c: *Checker, shim: schema.EngineShim) Error!void {
    const options = shim.options;
    const result = shim.result;
    try identifier(c, shim.name, "engine shim");
    for (shim.args) |argument| try typeTree(c, argument.type);
    try typeTree(c, result);
    if (options.result_source == .native) try engineShimType(c, result, .outbound_result, true);
    try engineShimCapabilities(c, result, options);
    if (options.result_source == .javascript) {
        if (options.realm != .current or options.throws != .js_exception or !options.check_traps)
            try c.fail("JavaScript engine results require a trap-checked current realm with JavaScript exception propagation", .{});
        if (result == .void) try c.fail("JavaScript engine results require a value conversion", .{});
        try javaScriptInputType(c, result, "an engine operation's JavaScript result");
        try anyPurpose(c, result, .pass_through, "engine JavaScript results");
    }
    try argumentList(c, shim.args);
    try noCachedSlotProjections(c, shim.args);
    try receiverProjections(c, null, shim.args);
    try argumentProfiles(c, shim.args, options.profile);
    for (shim.args) |argument| {
        const argument_options = argument.options;
        const argument_type = effectiveArgumentType(argument);
        if (argument_options.presence != .required or argument_options.missing != .undefined or
            argument_options.default_value != null or argument_options.boolean_conversion != .normal or
            argument_options.integer_conversion != .normal or argument_options.number_conversion != .normal or
            argument_options.rest or argument_options.selection != null)
            try c.fail("engine shim arguments must use the plain required argument contract", .{});
        if (argument_type == .lazy) {
            if (options.realm != .current or options.throws != .js_exception or !options.check_traps)
                try c.fail("lazy engine shim arguments require a trap-checked current realm with JavaScript exception propagation", .{});
            try lazyType(c, argument_type.lazy.*, false);
        } else {
            try engineShimType(c, argument_type, .outbound_argument, true);
        }
        try engineShimConvertedArguments(c, argument_type, options);
        if (argument_options.ownership == .transfer) try engineTransferredArgumentType(c, argument_type);
        if (options.realm == .none) try realmFreeEngineArgument(c, argument_type);
        if (!options.check_traps and options.realm == .current) try trapUncheckedEngineArgument(c, argument_type);
    }
}

fn engineTransferredArgumentType(c: *Checker, t: Type) Error!void {
    switch (t) {
        .converted => try c.fail("transferred engine arguments cannot cross a conversion boundary", .{}),
        .optional => |optional| try engineTransferredArgumentType(c, optional.child.*),
        .sequence => |sequence| try engineTransferredArgumentType(c, sequence.child),
        .record => |record| {
            try engineTransferredArgumentType(c, record.key);
            try engineTransferredArgumentType(c, record.value);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try engineTransferredArgumentType(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try engineTransferredArgumentType(c, effectiveUnionMemberType(member)),
        else => {},
    }
}

fn engineShimConvertedArguments(c: *Checker, t: Type, options: schema.EngineShimOptions) Error!void {
    switch (t) {
        .converted => |converted| {
            try engineShimType(c, converted.match, .outbound_argument, false);
            const converter_options = converted.converter.options;
            if (options.realm != .current and !converter_options.realm_free)
                try c.fail("converted engine shim arguments require a current realm", .{});
            if (!converter_options.infallible and (!options.check_traps or options.throws != .js_exception))
                try c.fail("fallible engine shim converters require JavaScript exception propagation", .{});
        },
        .lazy => |child| try engineShimConvertedArguments(c, child.*, options),
        .optional => |optional| try engineShimConvertedArguments(c, optional.child.*, options),
        .sequence => |sequence| try engineShimConvertedArguments(c, sequence.child, options),
        .record => |record| {
            try engineShimConvertedArguments(c, record.key, options);
            try engineShimConvertedArguments(c, record.value, options);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try engineShimConvertedArguments(c, field.type, options),
        .union_type => |union_type| for (union_type.members) |member| try engineShimConvertedArguments(c, effectiveUnionMemberType(member), options),
        else => {},
    }
}

fn engineShimCapabilities(c: *Checker, result: Type, options: schema.EngineShimOptions) Error!void {
    switch (options.realm) {
        .current => {
            if (options.affinity != .vm) try c.fail("current-realm engine shims require VM affinity", .{});
            if (options.throws == .out_of_memory and !options.check_traps)
                try c.fail("allocating current-realm engine shims require trap checks", .{});
        },
        .none => {
            if (options.check_traps) try c.fail("realm-free engine shims cannot check JavaScript traps", .{});
            if (options.throws == .js_exception) try c.fail("realm-free engine shims cannot throw JavaScript exceptions", .{});
            try realmFreeEngineResult(c, result);
        },
    }
    if (!options.check_traps and options.throws == .js_exception)
        try c.fail("engine shims that bypass trap checks cannot throw JavaScript exceptions", .{});
}

fn trapUncheckedEngineArgument(c: *Checker, t: Type) Error!void {
    switch (t) {
        .sequence, .record => try c.fail("engine shims that bypass trap checks cannot use allocating arguments", .{}),
        .converted => |converted| {
            if (!converted.converter.options.infallible) try c.fail("engine shims that bypass trap checks require infallible converters", .{});
            try trapUncheckedEngineArgument(c, converted.match);
        },
        .optional => |optional| try trapUncheckedEngineArgument(c, optional.child.*),
        .dictionary => |dictionary| for (dictionary.fields) |field| try trapUncheckedEngineArgument(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try trapUncheckedEngineArgument(c, effectiveUnionMemberType(member)),
        else => {},
    }
}

fn realmFreeEngineArgument(c: *Checker, t: Type) Error!void {
    switch (t) {
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .dom_string, .usv_string, .byte_string, .node_path, .native_slice, .enumeration, .nominal_handle => {},
        .buffer => |buffer| if (buffer.mode != .copy) try c.fail("realm-free engine shims only support copy-buffer arguments", .{}),
        .converted => |converted| {
            if (!converted.converter.options.realm_free) try c.fail("realm-free engine shim conversions require a realm-free converter", .{});
            try realmFreeEngineArgument(c, converted.match);
        },
        .optional => |optional| try realmFreeEngineArgument(c, optional.child.*),
        .sequence => |sequence| try realmFreeEngineArgument(c, sequence.child),
        .record => |record| {
            try realmFreeEngineArgument(c, record.key);
            try realmFreeEngineArgument(c, record.value);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try realmFreeEngineArgument(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try realmFreeEngineArgument(c, effectiveUnionMemberType(member)),
        else => try c.fail("realm-free engine shim arguments cannot carry JavaScript reachability or realm-bound resources", .{}),
    }
}

fn realmFreeEngineResult(c: *Checker, t: Type) Error!void {
    switch (t) {
        .nominal_handle => {},
        .void, .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .dom_string, .usv_string, .byte_string, .enumeration => {},
        .buffer => |buffer| if (buffer.mode != .copy) try c.fail("realm-free engine shim buffer results require copy ownership", .{}),
        .optional => |optional| try realmFreeEngineResult(c, optional.child.*),
        .sequence => |sequence| try realmFreeEngineResult(c, sequence.child),
        .record => |record| {
            try realmFreeEngineResult(c, record.key);
            try realmFreeEngineResult(c, record.value);
        },
        .dictionary => |dictionary| for (dictionary.fields) |field| try realmFreeEngineResult(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try realmFreeEngineResult(c, effectiveUnionMemberType(member)),
        else => try c.fail("realm-free engine shim results cannot carry JavaScript reachability or realm-bound resources", .{}),
    }
}

fn engineShimType(c: *Checker, t: Type, role: ir.Role, direct: bool) Error!void {
    switch (t) {
        .nominal_handle => {},
        .void => if (role != .outbound_result) try c.fail("engine shim arguments cannot be void", .{}),
        .discarded => |discarded| if (role == .outbound_result) {
            if (discarded.match == .semantic_type) try c.fail("discarded semantic values are argument-only", .{});
        } else {
            try engineShimType(c, discarded.match_type.*, .outbound_argument, false);
        },
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .any, .branded_value, .engine_value, .dom_string, .usv_string, .byte_string, .callback, .enumeration, .class_ref => {},
        .node_path => if (role == .outbound_result) try c.fail("NodePath is an argument-only semantic type", .{}),
        .native_slice => if (role == .outbound_result or !direct) try c.fail("native slices are restricted to direct engine shim arguments", .{}),
        .optional => |optional| try engineShimType(c, optional.child.*, role, false),
        .dictionary => |dictionary| for (dictionary.fields) |field| try engineShimType(c, field.type, role, false),
        .union_type => |union_type| for (union_type.members) |member| try engineShimType(c, effectiveUnionMemberType(member), role, false),
        .sequence => |sequence| {
            if (role != .outbound_result and sequence.options.flavor == .frozen_array) try c.fail("engine shim arguments cannot use FrozenArray", .{});
            try engineShimType(c, sequence.child, role, false);
        },
        .record => |record| {
            try engineShimType(c, record.key, role, false);
            try engineShimType(c, record.value, role, false);
        },
        .buffer => |buffer| if (buffer.mode != .copy) {
            if (role == .outbound_result)
                try c.fail("engine shim buffer results require copy ownership", .{})
            else
                try c.fail("engine shims only support copy-buffer arguments", .{});
        },
        .external_ref => if (role == .outbound_result)
            try c.fail("engine shim results cannot transfer external references", .{})
        else
            try c.fail("engine shim arguments cannot be external references", .{}),
        .converted => |converted| if (role == .outbound_result) {
            try c.fail("engine shim results cannot use input converters", .{});
        } else {
            try engineShimType(c, converted.match, .outbound_argument, false);
        },
        .lazy => if (role == .outbound_result) try c.fail("engine shim results cannot be lazy", .{}),
        .utf8_string => try c.fail("UTF8String is a Zig-produced result transfer and not an engine logical value", .{}),
        .native_instance => try c.fail("native instances are constructor-return-only", .{}),
    }
}

// ─── native exports ───

fn isOwnedNativeTransferArgument(t: Type) bool {
    return switch (t) {
        .nominal_handle => |handle| handle.options.ownership == .owned,
        .optional => |optional| isOwnedNativeTransferArgument(optional.child.*),
        else => false,
    };
}

fn isCoercingString(t: Type) bool {
    return switch (t) {
        .dom_string, .usv_string, .byte_string => |string| string.conversion == .coerce,
        else => false,
    };
}

fn containsCoercedString(t: Type) bool {
    return TypeQuery.coerced_string.contains(t);
}

fn containsBorrowedEngineValue(t: Type) bool {
    return TypeQuery.borrowed_engine_value.contains(t);
}

fn nativeExportClassRefUnion(union_type: *const schema.Union) bool {
    if (union_type.members.len == 0) return false;
    for (union_type.members) |member| {
        if (effectiveUnionMemberType(member) != .class_ref) return false;
    }
    return true;
}

fn nativeExportRules(c: *Checker, native_export: schema.NativeExport) Error!void {
    const options = native_export.options;
    const result = native_export.result;
    try identifier(c, native_export.name, "native export");
    for (native_export.args) |argument| try typeTree(c, argument.type);
    try typeTree(c, result);
    for (native_export.args) |argument| {
        if (argument.options.selection != null) try c.fail("native exports cannot select JavaScript union arguments", .{});
    }
    if (options.non_returning and (result != .void or options.throws != .never or options.realm != .none))
        try c.fail("non-returning native exports require void, no failures, and no realm", .{});
    if (options.standalone_header) |header| {
        try identifier(c, header, "native export standalone header");
        if (options.realm != .none) try c.fail("standalone native export headers require realm-free exports", .{});
        if (options.throws == .out_of_memory) try c.fail("standalone native exports cannot report allocation failure", .{});
        if (options.errors.errors.len != 0) try c.fail("standalone native export headers do not support domain errors", .{});
        try standaloneNativeExportType(c, result);
        for (native_export.args) |argument| try standaloneNativeExportType(c, effectiveArgumentType(argument));
    }
    if (options.realm == .none and options.throws == .js_exception) try c.fail("realm-free native exports cannot throw JavaScript exceptions", .{});
    if (options.realm == .current and options.throws == .out_of_memory)
        try c.fail("current-realm native exports report allocation failures through throws = .js_exception", .{});
    try domainErrors(c, options.errors, .zig);
    if (options.errors.errors.len > 0 and options.throws != .js_exception)
        try c.fail("native exports with domain errors must declare throws = .js_exception", .{});
    try exposureRules(c, options.exposure);
    try nativeExportType(c, result, .inbound_result, options.realm, true);
    try argumentList(c, native_export.args);
    try noCachedSlotProjections(c, native_export.args);
    try receiverProjections(c, null, native_export.args);
    for (native_export.args) |argument| {
        const argument_options = argument.options;
        const argument_type = effectiveArgumentType(argument);
        if (argument_options.ownership == .transfer and !isOwnedNativeTransferArgument(argument_type))
            try c.fail("native export ownership transfer requires an owned nominal handle or its optional", .{});
        if (argument_options.presence != .required or argument_options.missing != .undefined or
            argument_options.default_value != null or argument_options.rest)
            try c.fail("native export arguments must use the plain required argument contract", .{});
        if (argument_type != .lazy and (argument_options.boolean_conversion != .normal or
            argument_options.integer_conversion != .normal or argument_options.number_conversion != .normal))
            try c.fail("native export conversion rules require a lazy argument", .{});
        const directly_coerces_string = switch (argument_type) {
            .dom_string, .usv_string, .byte_string => isCoercingString(argument_type),
            .converted => |converted| containsCoercedString(converted.match),
            else => false,
        };
        if (directly_coerces_string) {
            if (options.realm != .current) try c.fail("coercing string native export arguments require a current realm", .{});
        }
        try nativeExportType(c, argument_type, .inbound_argument, options.realm, true);
    }
}

fn standaloneNativeExportType(c: *Checker, t: Type) Error!void {
    switch (t) {
        .void, .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64, .nominal_handle, .native_slice => {},
        .optional => |optional| try standaloneNativeExportType(c, optional.child.*),
        else => try c.fail("standalone native export headers support only scalars, native slices, nominal handles, and optionals", .{}),
    }
}

fn nativeExportType(c: *Checker, t: Type, role: ir.Role, realm: schema.EngineRealm, direct: bool) Error!void {
    switch (t) {
        .nominal_handle => {},
        .void => if (role != .inbound_result) try c.fail("native export arguments cannot be void", .{}),
        .native_slice => {
            if (role == .inbound_result) try c.fail("native slices cannot be native-export results", .{});
            if (!direct) try c.fail("native slices are restricted to direct native-export arguments", .{});
        },
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64, .enumeration => {},
        .dom_string, .usv_string, .byte_string => |string| {
            if (string.conversion == .coerce and (role == .inbound_result)) try c.fail("native export results cannot use coercing string semantic types", .{});
            if (string.conversion == .coerce and realm != .current) try c.fail("coercing string native export arguments require a current realm", .{});
        },
        .any, .engine_value => if (realm != .current) try c.fail("raw JavaScript values require a current-realm native export", .{}),
        .branded_value => if (realm != .current) try c.fail("branded JavaScript values require a current-realm native export", .{}),
        .callback => if (realm != .current) try c.fail("native export callbacks require a current realm", .{}),
        .class_ref => {
            if (realm != .current) try c.fail("native export class references require a current realm", .{});
            if (role != .inbound_result and !direct) try c.fail("native export class references require a direct argument so wrapper identity is explicit", .{});
        },
        .external_ref => {
            if (role == .inbound_result) try c.fail("native export results cannot transfer external references", .{});
            if (realm != .current) try c.fail("native export external references require a current realm", .{});
        },
        .buffer => |buffer| {
            if (buffer.mode != .copy) try c.fail("native exports require copy-buffer ownership", .{});
            if (role == .inbound_result and buffer.options.result_representation != null and realm != .current)
                try c.fail("represented native export buffer results require a current realm", .{});
        },
        .optional => |optional| if (role != .inbound_result and optional.child.* == .class_ref) {
            if (!direct) try c.fail("optional native export class references require a direct argument", .{});
            try nativeExportType(c, optional.child.*, .inbound_argument, realm, true);
        } else {
            try nativeExportType(c, optional.child.*, role, realm, false);
        },
        .sequence => |sequence| {
            if (role != .inbound_result and sequence.options.flavor == .frozen_array) try c.fail("native export arguments cannot use FrozenArray", .{});
            if (role != .inbound_result and realm != .current) try c.fail("native export sequence arguments require a current realm", .{});
            if (role == .inbound_result and containsBorrowedEngineValue(sequence.child))
                try c.fail("native export result sequences cannot contain borrowed JavaScript values", .{});
            try nativeExportType(c, sequence.child, role, realm, false);
        },
        .record => |record| {
            if (role != .inbound_result and realm != .current) try c.fail("native export record arguments require a current realm", .{});
            if (role == .inbound_result and (containsBorrowedEngineValue(record.key) or containsBorrowedEngineValue(record.value)))
                try c.fail("native export result records cannot contain borrowed JavaScript values", .{});
            try nativeExportType(c, record.key, role, realm, false);
            try nativeExportType(c, record.value, role, realm, false);
        },
        .dictionary => |dictionary| {
            if (role != .inbound_result and realm != .current) try c.fail("native export dictionary arguments require a current realm", .{});
            for (dictionary.fields) |field| try nativeExportType(c, field.type, role, realm, false);
        },
        .union_type => |union_type| if (role == .inbound_result) {
            for (union_type.members) |member| try nativeExportType(c, effectiveUnionMemberType(member), .inbound_result, realm, false);
        } else if (nativeExportClassRefUnion(union_type)) {
            if (!direct) try c.fail("class-reference native export unions must be direct arguments", .{});
            for (union_type.members) |member| try nativeExportType(c, effectiveUnionMemberType(member), .inbound_argument, realm, true);
        } else {
            if (realm != .current) try c.fail("native export union arguments require a current realm", .{});
            for (union_type.members) |member| try nativeExportType(c, effectiveUnionMemberType(member), .inbound_argument, realm, false);
        },
        .converted => |converted| {
            if (role == .inbound_result) try c.fail("native export results cannot use converted semantic types", .{});
            if (realm != .current) try c.fail("converted native export arguments require a current realm", .{});
            try convertedNativeExportType(c, converted.native);
        },
        .lazy => |child| {
            if (role == .inbound_result) try c.fail("native export results cannot be lazy", .{});
            if (!direct) try c.fail("lazy native export conversion is a top-level argument contract", .{});
            if (realm != .current) try c.fail("lazy native export arguments require a current realm", .{});
            if (typeContainsLazy(child.*)) try c.fail("native export lazy arguments cannot contain deferred fields", .{});
            try lazyType(c, child.*, false);
        },
        .discarded => |discarded| if (discarded.match == .semantic_type)
            try c.fail("discarded JavaScript conversion markers do not cross native exports", .{}),
        .utf8_string => try c.fail("UTF8String is a Zig-produced JavaScript result transfer, not a native-export logical value", .{}),
        .node_path => try c.fail("NodePath is a JavaScript input conversion; native exports use a copied buffer or a typed converter result", .{}),
        .native_instance => try c.fail("native instances are constructor-return-only", .{}),
    }
}

fn convertedNativeExportType(c: *Checker, t: Type) Error!void {
    switch (t) {
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .dom_string, .usv_string, .byte_string, .node_path, .enumeration => {},
        .buffer => |buffer| if (buffer.mode != .copy) try c.fail("converted native export buffers require copy ownership", .{}),
        .optional => |optional| try convertedNativeExportType(c, optional.child.*),
        .sequence => |sequence| try convertedNativeExportType(c, sequence.child),
        .dictionary => |dictionary| for (dictionary.fields) |field| try convertedNativeExportType(c, field.type),
        .union_type => |union_type| for (union_type.members) |member| try convertedNativeExportType(c, effectiveUnionMemberType(member)),
        else => try c.fail("converted native exports require recursively owned value data and copied buffers", .{}),
    }
}

// ─── class members ───

fn formAccessorPair(a: schema.ClassMemberKind, b: schema.ClassMemberKind) bool {
    return (a.isGetter() and b.isSetter()) or (a.isSetter() and b.isGetter());
}

fn memberKeysCollide(a: schema.ClassMember, b: schema.ClassMember) bool {
    if (eqlText(a.name, b.name)) return true;
    if (a.options.symbol) |symbol| if (b.options.symbol) |other| if (symbol == other) return true;
    if (a.options.private_symbol) |symbol| if (b.options.private_symbol) |other| if (eqlText(symbol, other)) return true;
    return false;
}

fn aliasMatchesPrimary(alias: schema.ClassMemberAlias, member: schema.ClassMember) bool {
    return switch (alias.key) {
        .name => |name| member.options.symbol == null and member.options.private_symbol == null and eqlText(name, member.name),
        .symbol => |symbol| member.options.symbol == symbol,
    };
}

fn javaScriptAssignedSlotType(c: *Checker, t: Type) Error!void {
    const value = if (t == .optional) t.optional.child.* else t;
    switch (value) {
        .any, .branded_value, .engine_value, .callback, .dom_string, .usv_string, .byte_string => {},
        else => try c.fail("cached slots assigned from JavaScript only support JavaScript value, callback, string, and optional types", .{}),
    }
}

fn argumentCount(arguments: schema.Arguments) usize {
    return switch (arguments) {
        .list => |list| list.len,
        .overloads => 0,
    };
}

fn classMemberRules(c: *Checker, member: schema.ClassMember, backend: ir.Backend) Error!void {
    const options = member.options;
    const kind = member.kind;
    const overloaded = member.arguments == .overloads;
    try argumentTypeTrees(c, member.arguments);
    try typeTree(c, member.result);
    if (kind != .constructor) try identifier(c, member.name, "class member");
    if (options.invalid_this == .failure) try conversionFailure(c, options.invalid_this.failure);
    if (options.missing_required_arguments == .failure) try conversionFailure(c, options.missing_required_arguments.failure);
    if (options.native_reference and kind != .method and kind != .static_method)
        try c.fail("native function references require a class method", .{});
    if (options.deferred_reason != null and !kind.isSetter()) try c.fail("only a lazy setter can declare a deferred conversion reason", .{});
    if (options.illegal and overloaded) try c.fail("illegal constructors cannot declare overloads", .{});
    if (options.illegal and (kind != .constructor or argumentCount(member.arguments) != 0))
        try c.fail("only zero-argument constructors can be illegal", .{});
    if (overloaded and kind != .constructor and kind != .method and kind != .static_method)
        try c.fail("only class constructors and methods can declare overloads", .{});
    if (overloaded and options.completion != null and options.completion.?.delivery != .vm)
        try c.fail("asynchronous overloads require VM-materialized completions", .{});
    if (options.completion != null and kind != .method and kind != .static_method and !kind.isGetter())
        try c.fail("only class methods and getters can use native completion endpoints", .{});
    if (normalize.isThisClassRef(member.result)) {
        if (kind != .method and kind != .getter) try c.fail("this-class references are only valid as instance member results", .{});
        if (options.this_value_type == null) try c.fail("this-class reference results require a declared this value", .{});
    }
    if (member.result == .native_instance and kind != .constructor)
        try c.fail("native-instance is constructor-return-only and cannot be a class member result", .{});
    if (member.result == .lazy) try c.fail("lazy values cannot be class member results", .{});
    try domainErrors(c, options.errors, backend);
    try exposureRules(c, options.exposure);
    try javaScriptArguments(c, member.arguments);
    switch (member.arguments) {
        .list => |list| {
            try argumentList(c, list);
            try noArgumentTransfers(c, list);
        },
        .overloads => |overloads| try overloadSet(c, overloads),
    }
    if (options.new_target_type != null and kind != .constructor) try c.fail("new.target is only available to class constructors", .{});
    if (options.symbol != null and kind != .method and kind != .static_method) try c.fail("symbol-keyed class members must be methods", .{});
    if (options.private_symbol != null and kind != .method and kind != .static_method and !kind.isGetter())
        try c.fail("private-symbol class members must be methods or getters", .{});
    if (options.symbol != null and options.private_symbol != null)
        try c.fail("a class member cannot combine a property symbol with a private symbol", .{});
    if (options.aliases.len != 0) {
        if (kind != .method and kind != .static_method) try c.fail("only class methods can declare property aliases", .{});
        if (options.symbol != null or options.private_symbol != null)
            try c.fail("a class member with aliases must use an ordinary named primary property", .{});
        for (options.aliases, 0..) |alias, index| {
            switch (alias.key) {
                .name => |alias_name| {
                    try identifier(c, alias_name, "class member alias");
                    if (eqlText(alias_name, member.name)) try c.fail("class member alias duplicates its primary property: {s}", .{alias_name});
                },
                .symbol => |symbol| if (symbol == .inspect_custom) try c.fail("custom inspect must be declared as a class member, not an alias", .{}),
            }
            for (options.aliases[0..index]) |previous| {
                if (structural.eql(previous.key, alias.key)) try c.fail("duplicate class member alias", .{});
            }
        }
    }
    if (options.unforgeable) {
        if (kind != .getter and kind != .setter) try c.fail("only class accessors can be unforgeable", .{});
        if (options.symbol != null or options.private_symbol != null or options.aliases.len != 0 or options.cache != null or options.writable)
            try c.fail("unforgeable accessors must be ordinary uncached properties", .{});
        if (options.configurable) try c.fail("unforgeable accessors cannot be configurable", .{});
    }
    if (options.builtin) |builtin| try identifier(c, builtin, "builtin generator");
    if (options.implementation) |implementation| try identifier(c, implementation, "class member implementation");
    if (options.cache) |cache| try identifier(c, cache, "class member cache slot");
    if (options.cache_on_construction and (kind != .getter or options.cache == null))
        try c.fail("constructor-time caching requires a cached instance getter", .{});
    if (options.writable and (kind != .getter or options.cache == null)) try c.fail("writable class members must be cached instance getters", .{});
    if (options.getter_assignment == .ignore and (!kind.isGetter() or options.writable))
        try c.fail("ignored assignment requires a getter without a writable cache", .{});
    if (options.writable) try javaScriptAssignedSlotType(c, member.result);
    if (options.private_symbol) |private_symbol| try identifier(c, private_symbol, "private symbol");
}

/// Rules a bound callable of a class shares: its backend, invocation values,
/// and argument conversion contracts.
fn classCallableRules(
    c: *Checker,
    member: schema.ClassMember,
    backend: schema.Backend,
    profile: schema.Profile,
) Error!void {
    const options = member.options;
    try invocationOptions(c, options.caller_source_location, backend);
    try typedThisValue(c, options.this_value_type, backend, profile, member.arguments);
    try typedInvocationValue(c, new_target_value, options.new_target_type, backend, profile, member.arguments);
    try typedInvocationValue(c, callee_value, options.callee_value_type, backend, profile, member.arguments);
    try callArgumentLists(c, member.arguments, backend, profile);
    if (options.conversion_program != null and (backend == .builtin or member.arguments == .overloads))
        try c.fail("conversion programs require a non-overloaded native function", .{});
    try completionRules(c, options.completion, backend);
}

// ─── classes ───

fn instancePropertyRules(c: *Checker, property: schema.InstanceProperty) Error!void {
    const options = property.options;
    try identifier(c, property.name, "instance property");
    try typeTree(c, options.value);
    try anyPurpose(c, options.value, .retention, "plain instance properties");
    const value = if (options.value == .optional) options.value.optional.child.* else options.value;
    switch (value) {
        .callback, .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .any, .branded_value, .engine_value, .class_ref, .enumeration, .dom_string, .usv_string, .byte_string => {},
        else => try c.fail("plain instance properties require a scalar, callback, branded-value, engine-value, or class-reference semantic type, optionally wrapped in an optional", .{}),
    }
    if (options.private_symbol) |symbol| try identifier(c, symbol, "instance property private symbol");
    if (options.initializer) |initializer| switch (initializer) {
        .constant => |constant| try defaultValue(c, options.value, constant),
        .argument => |argument_name| try wireIdentifier(c, argument_name, "instance property initializer argument"),
        .argument_field => |source| {
            try wireIdentifier(c, source.argument, "instance property initializer argument");
            try wireIdentifier(c, source.field, "instance property initializer field");
        },
        .argument_bigint_quotient => |source| {
            try wireIdentifier(c, source.argument, "instance property initializer argument");
            if (source.divisor == 0) try c.fail("BigInt property initializer quotient divisor cannot be zero", .{});
            if (!isInteger(options.value) or integerRepresentation(options.value) != .bigint)
                try c.fail("BigInt property initializer quotients require a BigInt-represented integer property", .{});
        },
    };
}

fn cachedSlotRules(c: *Checker, slot: schema.CachedSlot) Error!void {
    const options = slot.options;
    try identifier(c, slot.name, "cached slot");
    try typeTree(c, slot.type);
    if (options.private_symbol) |symbol| {
        try identifier(c, symbol, "cached slot private symbol");
        if (!options.exposed) try c.fail("a private-symbol cached slot must be exposed", .{});
    }
    try anyPurpose(c, slot.type, .retention, "cached slots");
    const value = if (slot.type == .optional) slot.type.optional.child.* else slot.type;
    switch (value) {
        .void, .node_path, .converted, .native_instance => try c.fail("cached slots require a JavaScript value type", .{}),
        else => {},
    }
    try resultType(c, slot.type, .zig);
    if (options.writable) try javaScriptInputType(c, slot.type, "used by a writable cached slot");
}

fn dataPropertyRules(c: *Checker, property: schema.DataProperty) Error!void {
    if (property.options.symbol == .inspect_custom) try c.fail("custom inspect must be declared as a class member, not a constant", .{});
    if (std.mem.indexOfScalar(u8, property.name, 0) != null) try c.fail("data property name cannot contain a null byte", .{});
    if (!std.unicode.utf8ValidateSlice(property.name)) try c.fail("data property name is not valid UTF-8", .{});
    switch (property.value) {
        .string => |value| {
            if (std.mem.indexOfScalar(u8, value, 0) != null) try c.fail("data property string value cannot contain a null byte", .{});
            if (!std.unicode.utf8ValidateSlice(value)) try c.fail("data property string value is not valid UTF-8", .{});
        },
        else => {},
    }
}

fn engineClassRules(c: *Checker, class: schema.Class) Error!void {
    const name = class.name;
    const options = class.options;
    const constructor = class.constructor;
    if (options.parent) |parent| switch (parent) {
        .class => |parent_class| if (parent_class.options.representation != .engine)
            try c.fail("an engine class can only inherit from another engine class: {s}", .{name}),
        .engine => {},
    } else try c.fail("an engine class must declare an engine parent: {s}", .{name});
    if (options.upcast != null) try c.fail("engine classes inherit through C++ and cannot declare an upcast: {s}", .{name});
    if (options.engine_native == null) try c.fail("an engine class must declare its engine native type: {s}", .{name});
    if (options.engine_intrinsic) |intrinsic| {
        try asciiText(c, intrinsic, "engine class intrinsic behavior");
    } else {
        try c.fail("an engine class must name its intrinsic engine behavior: {s}", .{name});
    }
    if (options.memory_usage) |affinity| if (affinity != .vm) try c.fail("engine class memory usage requires VM affinity: {s}", .{name});
    if (options.reference_thread != .vm or !options.last_release.isDeferredVM())
        try c.fail("engine class lifetime belongs to the engine and declares no reference mobility: {s}", .{name});
    if (options.structured_clone != null or options.prototype_base != .object or
        options.has_pending_activity or options.lifecycle.wrapper_created)
        try c.fail("engine classes do not support this lifetime or identity contract: {s}", .{name});
    if (constructor.options.exposure != .never and !constructor.options.illegal) {
        if ((constructor.options.backend orelse options.backend) != .cpp) try c.fail("engine class constructors require a C++ backend: {s}", .{name});
        if (constructor.options.this_value_type != null or constructor.options.new_target_type != null or
            constructor.options.callee_value_type != null)
            try c.fail("engine class constructors receive the structure, not invocation values: {s}", .{name});
    }
}

fn plainClassRules(c: *Checker, class: schema.Class) Error!void {
    const name = class.name;
    const options = class.options;
    const constructor = class.constructor;
    if (class.instance_properties.len == 0)
        try c.fail("a plain class must declare at least one instance property: {s}", .{name});
    if (options.plain_reason) |reason| {
        try asciiText(c, reason, "plain class representation reason");
    } else {
        try c.fail("a plain class must justify its plain representation: {s}", .{name});
    }
    if (options.parent != null or options.upcast != null) try c.fail("plain class instances prototype-chain to Object: {s}", .{name});
    if (options.engine_native != null) try c.fail("plain classes have no engine native: {s}", .{name});
    if (options.identity != .fresh or options.reference_thread != .vm or !options.last_release.isDeferredVM())
        try c.fail("plain class instances have no native lifetime contract: {s}", .{name});
    if (options.structured_clone != null or options.prototype_base == .function or options.has_pending_activity or
        options.lifecycle.wrapper_created or options.memory_usage != null or options.engine_tracing != .inherited)
        try c.fail("plain classes do not support this lifetime or identity contract: {s}", .{name});
    if (constructor.options.exposure != .never) {
        if ((constructor.options.backend orelse options.backend) != .cpp) try c.fail("plain class constructors require a C++ backend: {s}", .{name});
        if (constructor.options.this_value_type != null)
            try c.fail("plain class constructors receive the structure, not invocation values: {s}", .{name});
    }
    for (class.instance_properties, 0..) |property, index| {
        try instancePropertyRules(c, property);
        for (class.instance_properties[0..index]) |previous| {
            if (eqlText(previous.name, property.name)) try c.fail("duplicate instance property name: {s}", .{property.name});
        }
    }
    try plainClassInitializers(c, class);
}

fn plainClassInitializers(c: *Checker, class: schema.Class) Error!void {
    const name = class.name;
    var initialized: usize = 0;
    for (class.instance_properties) |property| {
        if (property.options.initializer != null) initialized += 1;
    }
    if (initialized == 0) return;
    if (initialized != class.instance_properties.len)
        return c.fail("a generated plain-class constructor must initialize every instance property: {s}", .{name});
    const constructor = class.constructor;
    const arguments = switch (constructor.arguments) {
        .list => |list| list,
        .overloads => return c.fail("generated plain-class constructors cannot be overloaded: {s}", .{name}),
    };
    if (constructor.options.illegal or constructor.options.exposure == .never)
        try c.fail("generated plain-class initialization requires an exposed constructor: {s}", .{name});
    try plainInitializerArguments(c, class, arguments);
    if (class.options.constructor_call) |call| {
        const call_arguments = switch (call.arguments) {
            .list => |list| list,
            .overloads => return c.fail("generated plain-class constructor calls cannot be overloaded: {s}", .{name}),
        };
        if (call.options.completion != null) try c.fail("generated plain-class constructor calls cannot be asynchronous: {s}", .{name});
        try plainInitializerArguments(c, class, call_arguments);
    }
}

fn plainInitializerArguments(c: *Checker, class: schema.Class, arguments: []const schema.Argument) Error!void {
    for (class.instance_properties) |property| {
        const initializer = property.options.initializer.?;
        const argument_name = switch (initializer) {
            .constant => continue,
            .argument => |name| name,
            .argument_field => |source| source.argument,
            .argument_bigint_quotient => |source| source.argument,
        };
        for (arguments) |argument| {
            if (!eqlText(argument.name, argument_name)) continue;
            try plainInitializerSource(c, class.name, property.name, initializer, effectiveArgumentType(argument));
            break;
        } else try c.fail("plain-class property initializer names an absent constructor argument: {s}.{s}", .{ class.name, property.name });
    }
}

fn plainInitializerNativeType(t: Type) Type {
    return if (t == .converted) plainInitializerNativeType(t.converted.native) else t;
}

fn plainInitializerSource(
    c: *Checker,
    class_name: []const u8,
    property_name: []const u8,
    initializer: schema.InstancePropertyInitializer,
    argument_type: Type,
) Error!void {
    const native = plainInitializerNativeType(argument_type);
    switch (initializer) {
        .constant => {},
        .argument => try plainInitializerValueType(c, class_name, property_name, native),
        .argument_field => |source| {
            if (native != .dictionary)
                return c.fail("plain-class property initializer fields require a semantic dictionary: {s}.{s}", .{ class_name, property_name });
            for (native.dictionary.fields) |field| {
                if (!eqlText(field.name, source.field)) continue;
                if (!field.options.required)
                    try c.fail("plain-class property initializer dictionary fields must be required: {s}.{s}", .{ class_name, property_name });
                try plainInitializerValueType(c, class_name, property_name, field.type);
                break;
            } else try c.fail("plain-class property initializer names an absent semantic field: {s}.{s}", .{ class_name, property_name });
        },
        .argument_bigint_quotient => {
            const is_bigint = native == .branded_value and structural.eql(native.branded_value.brand, schema.brandOf(schema.js_big_int));
            if (!is_bigint)
                try c.fail("plain-class BigInt quotient initializers require a BigInt argument: {s}.{s}", .{ class_name, property_name });
        },
    }
}

fn plainInitializerValueType(c: *Checker, class_name: []const u8, property_name: []const u8, t: Type) Error!void {
    switch (t) {
        .nominal_handle => try c.fail("plain-class property initializers cannot materialize nominal handles: {s}.{s}", .{ class_name, property_name }),
        .converted => |converted| try plainInitializerValueType(c, class_name, property_name, converted.native),
        .optional => |optional| try plainInitializerValueType(c, class_name, property_name, optional.child.*),
        .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {},
        .any, .engine_value, .branded_value, .callback, .dom_string, .usv_string, .byte_string, .enumeration => {},
        else => try c.fail("plain-class property initializer type cannot be materialized as a JavaScript value: {s}.{s}", .{ class_name, property_name }),
    }
}

/// The type a cached getter stores in its slot.
fn cachedGetterValue(c: *Checker, member: schema.ClassMember) Error!Type {
    if (member.options.completion == null) return member.result;
    var brand = schema.brandOf(schema.js_promise);
    brand.promise_value = try c.n.create(member.result);
    return .{ .branded_value = try c.n.create(schema.BrandedValue{ .brand = brand, .options = .{} }) };
}

fn classRules(c: *Checker, class: schema.Class) Error!void {
    const name = class.name;
    const options = class.options;
    if (options.parent) |parent| switch (parent) {
        .engine => |engine| {
            try cppTypeRules(c, engine.cpp_class);
            try cppName(c, engine.cpp_impl);
        },
        .class => {},
    };
    const constructor = class.constructor;
    const representation = options.representation;
    try identifier(c, name, "class");
    if (options.constructor_call_error) |failure| {
        if (options.constructor_call != null or options.illegal_constructor_errors != null)
            try c.fail("constructor call errors require a non-callable constructor without illegal constructor errors", .{});
        try conversionFailure(c, failure);
    }
    if (options.illegal_constructor_errors) |errors| {
        if (!constructor.options.illegal or options.constructor_call != null)
            try c.fail("illegal constructor errors require an illegal constructor without a custom call implementation", .{});
        try conversionFailure(c, errors.call);
        try conversionFailure(c, errors.construct);
    }
    if (options.display_name) |display_name| {
        try asciiText(c, display_name, "class display name");
        for (display_name) |byte| {
            if (byte < 0x20 or byte > 0x7e or byte == '"' or byte == '\\') {
                try c.fail("class display name must be printable C++ literal text", .{});
                break;
            }
        }
    }
    if (options.brand) |brand| {
        try brandRules(c, brand);
        if (brand.matcher == .instance_class) try c.fail("class brands cannot delegate to another class's instance matcher", .{});
    }
    if (representation == .plain) {
        try plainClassRules(c, class);
    } else if (class.instance_properties.len != 0) {
        try c.fail("only plain classes declare instance properties: {s}", .{name});
    }
    try exposureRules(c, options.exposure);
    if (representation == .native and options.ownership == .unique and options.reference_thread != .vm)
        try c.fail("unique bindgen classes do not support reference mobility", .{});
    if (options.ownership == .shared and options.last_release.isSweep())
        try c.fail("inline sweep finalization requires unique ownership: {s}", .{name});
    if (representation == .native and options.ownership == .shared and options.identity == .fresh) {
        if (options.fresh_identity_reason) |reason| {
            try asciiText(c, reason, "fresh wrapper identity reason");
        } else {
            try c.fail("a shared native class with fresh wrapper identity must justify why the native object is not re-wrapped: {s}", .{name});
        }
    } else if (options.fresh_identity_reason != null) {
        try c.fail("only shared native classes with fresh wrapper identity name a fresh identity reason: {s}", .{name});
    }
    if ((options.prototype_base == .iterator or options.prototype_base == .async_iterator) and
        (representation == .engine or options.parent != null))
        try c.fail("iterator prototypes require a native or plain class with no declared parent: {s}", .{name});
    if (options.prototype_base == .function) {
        if (representation != .native) try c.fail("only native classes can use Function.prototype as their prototype base: {s}", .{name});
        if (constructor.options.exposure != .never) try c.fail("a class with Function.prototype as its prototype base cannot expose its constructor: {s}", .{name});
        if (options.parent != null) try c.fail("a class with Function.prototype as its prototype base cannot inherit: {s}", .{name});
    }
    if (options.structured_clone) |structured_clone| {
        if (structured_clone.tag < 128) try c.fail("structured clone tags must be in the generated binding range 128...255", .{});
        if (structured_clone.deserialize_thread != .vm) try c.fail("structured clone deserialization requires the VM thread", .{});
        if (structured_clone.shared) |shared| {
            try identifier(c, shared.state, "shared structured clone state type");
            try text(c, shared.reason, "shared structured clone reason");
            if (representation != .native) try c.fail("shared structured clone state requires a native class", .{});
            if (structured_clone.serialize_thread != .vm) try c.fail("shared structured clone capture requires the source VM thread", .{});
            if (structured_clone.storable or structured_clone.transferable)
                try c.fail("shared structured clone state cannot be stored or transferred across processes", .{});
        }
    }
    if (representation == .engine) {
        try engineClassRules(c, class);
    } else {
        if (options.engine_intrinsic != null) try c.fail("only engine classes name intrinsic engine behavior", .{});
        if (representation != .plain and options.plain_reason != null) try c.fail("only plain classes name a plain representation reason", .{});
        if (options.engine_native != null) try c.fail("only engine classes declare an engine native type", .{});
        if (options.engine_tracing != .inherited) try c.fail("only engine classes support additional child tracing", .{});
        if (options.parent) |parent| {
            if (parent != .class) try c.fail("a class parent must be created with bindgen_schema.class", .{});
            if (options.upcast) |upcast| {
                try identifier(c, upcast, "class upcast");
            } else {
                try c.fail("a class with a parent must declare an upcast", .{});
            }
        } else if (options.upcast != null) {
            try c.fail("a class without a parent cannot declare an upcast", .{});
        }
    }

    if (constructor.kind != .constructor) try c.fail("a class constructor must be created with bindgen_schema.constructor", .{});
    try classMemberRules(c, constructor, constructor.options.backend orelse options.backend);
    const constructor_backend = constructor.options.backend orelse options.backend;
    const constructor_profile = constructor.options.profile orelse options.profile;
    try backendRules(c, constructor_backend, constructor.options.builtin, constructor.options.errors, representation == .native);
    try resultType(c, constructor.result, constructor_backend);
    try classCallableRules(c, constructor, constructor_backend, constructor_profile);
    if (constructor.arguments == .list) try noCachedSlotProjections(c, constructor.arguments.list);

    if (options.constructor_call) |call| {
        try noCachedSlotProjections(c, call.arguments.listOrEmpty());
        if (call.kind != .static_method or !eqlText(call.name, "call"))
            try c.fail("a class constructor call must be created with bindgen_schema.constructorCall", .{});
        try classMemberRules(c, call, call.options.backend orelse options.backend);
        const call_backend = call.options.backend orelse options.backend;
        try backendRules(c, call_backend, call.options.builtin, call.options.errors, false);
        try resultType(c, call.result, call_backend);
        try classCallableRules(c, call, call_backend, call.options.profile orelse options.profile);
        if (representation == .native) {
            if (call_backend != .zig and call_backend != .builtin) try c.fail("native class constructor calls require a Zig or builtin backend", .{});
        } else if (call_backend != .cpp) {
            try c.fail("engine and plain class constructor calls require a C++ backend", .{});
        }
    }

    for (class.members, 0..) |member, index| {
        const backend = member.options.backend orelse options.backend;
        const profile = member.options.profile orelse options.profile;
        if (member.kind == .constructor) try c.fail("class members must be created with a bindgen_schema member combinator", .{});
        try classMemberRules(c, member, backend);
        if (member.options.unforgeable and representation != .engine) try c.fail("unforgeable accessors require engine representation", .{});
        if (options.prototype_base == .function and !member.kind.isStatic() and backend != .builtin)
            try c.fail("Function.prototype-based classes require builtin instance members: {s}.{s}", .{ name, member.name });
        try backendRules(c, backend, member.options.builtin, member.options.errors, false);
        if (member.options.getter_assignment == .ignore and backend == .builtin) try c.fail("ignored getter assignment requires a native accessor", .{});
        try classMemberResultType(c, member.result, backend);
        try classCallableRules(c, member, backend, profile);
        switch (member.arguments) {
            .overloads => if (backend != .zig and !(representation == .engine and backend == .cpp))
                try c.fail("overloaded class methods require a Zig backend", .{}),
            .list => |list| for (list) |argument| {
                const source = argument.options.source orelse continue;
                if (source != .cached_slot) continue;
                if (member.kind != .method or representation == .plain or backend == .builtin)
                    try c.fail("cached-slot projections require a non-overloaded native instance method", .{});
                for (class.slots) |slot| {
                    if (!eqlText(slot.name, source.cached_slot)) continue;
                    if (slot.options.storage != .instance) try c.fail("cached-slot projections require instance storage", .{});
                    break;
                } else try c.fail("cached-slot projection names an undeclared slot: {s}", .{source.cached_slot});
            },
        }
        if (member.options.private_symbol != null and member.kind.isGetter() and backend == .builtin)
            try c.fail("private-symbol getters require a native backend", .{});
        if (representation == .engine and !member.kind.isStatic() and member.options.completion != null and backend == .cpp)
            try c.fail("engine C++ instance members do not support native completion endpoints", .{});
        try memberCollisions(c, class, index);
    }
    for (class.members, 0..) |member, member_index| {
        for (member.options.aliases, 0..) |alias, alias_index| {
            for (class.members, 0..) |candidate, candidate_index| {
                if (candidate.kind.isStatic() != member.kind.isStatic()) continue;
                if (aliasMatchesPrimary(alias, candidate)) try c.fail("class member alias conflicts with a primary property", .{});
                for (candidate.options.aliases, 0..) |candidate_alias, candidate_alias_index| {
                    if (member_index == candidate_index and alias_index == candidate_alias_index) continue;
                    if (structural.eql(alias.key, candidate_alias.key)) try c.fail("duplicate class member alias", .{});
                }
            }
        }
    }
    var custom_inspect_members: usize = 0;
    for (class.members) |member| {
        if (member.options.symbol != .inspect_custom) continue;
        custom_inspect_members += 1;
        if (member.kind.isStatic()) try c.fail("custom inspect must be an instance method", .{});
    }
    if (custom_inspect_members > 1) try c.fail("a class can declare only one inspect_custom symbol method", .{});
    try slotRules(c, class);
    try dataPropertiesRules(c, class);
}

fn memberCollisions(c: *Checker, class: schema.Class, index: usize) Error!void {
    const member = class.members[index];
    const default_profile = class.options.profile;
    const default_backend = class.options.backend;
    for (class.members[0..index]) |previous| {
        if (previous.kind.isStatic() != member.kind.isStatic() or !memberKeysCollide(previous, member)) continue;
        if (!formAccessorPair(previous.kind, member.kind)) {
            try c.fail("duplicate class member name: {s}", .{member.name});
            continue;
        }
        const getter = if (previous.kind.isGetter()) previous else member;
        const setter = if (previous.kind.isSetter()) previous else member;
        if (getter.options.writable) try c.fail("writable cached getter cannot declare an explicit setter: {s}", .{member.name});
        if (getter.options.getter_assignment == .ignore) try c.fail("a getter that ignores assignment cannot declare a setter: {s}", .{member.name});
        if ((getter.options.profile orelse default_profile) != (setter.options.profile orelse default_profile))
            try c.fail("class getter and setter profiles differ for: {s}", .{member.name});
        if ((getter.options.backend orelse default_backend) != (setter.options.backend orelse default_backend))
            try c.fail("class getter and setter backends differ for: {s}", .{member.name});
        if (getter.options.enumerable != setter.options.enumerable or getter.options.configurable != setter.options.configurable)
            try c.fail("class getter and setter property attributes differ for: {s}", .{member.name});
        if (getter.options.unforgeable != setter.options.unforgeable)
            try c.fail("class getter and setter placement differs for: {s}", .{member.name});
    }
}

fn slotRules(c: *Checker, class: schema.Class) Error!void {
    for (class.slots, 0..) |slot, index| {
        const options = slot.options;
        try cachedSlotRules(c, slot);
        if (options.storage == .constructor and class.constructor.options.exposure == .never)
            try c.fail("class without an exposed constructor cannot have constructor cached slots", .{});
        for (class.slots[0..index]) |previous| {
            if (eqlText(previous.name, slot.name)) try c.fail("duplicate cached slot name: {s}", .{slot.name});
            if (options.exposed and previous.options.exposed and options.storage == previous.options.storage and
                options.private_symbol != null and previous.options.private_symbol != null and
                eqlText(options.private_symbol.?, previous.options.private_symbol.?))
                try c.fail("duplicate cached slot private symbol: {s}", .{options.private_symbol.?});
        }
        var caches_member = false;
        for (class.members) |member| {
            const member_options = member.options;
            const uses_slot_as_cache = if (member_options.cache) |cache| eqlText(cache, slot.name) else false;
            if (uses_slot_as_cache) caches_member = true;
            const same_storage = (options.storage == .constructor) == member.kind.isStatic();
            if (!options.exposed or !same_storage) continue;
            if (options.private_symbol == null and member_options.symbol == null and member_options.private_symbol == null and
                eqlText(member.name, slot.name) and !uses_slot_as_cache)
                try c.fail("cached slot conflicts with class member: {s}", .{slot.name});
            if (options.private_symbol) |symbol| if (member_options.private_symbol) |member_symbol| if (eqlText(symbol, member_symbol))
                try c.fail("cached slot conflicts with class member private symbol: {s}", .{symbol});
            if (options.private_symbol == null) for (member_options.aliases) |alias| switch (alias.key) {
                .name => |alias_name| if (eqlText(alias_name, slot.name)) try c.fail("cached slot conflicts with class member alias: {s}", .{slot.name}),
                .symbol => {},
            };
        }
        if (options.exposed and options.writable and !caches_member) try javaScriptAssignedSlotType(c, slot.type);
    }
    for (class.members) |member| {
        const cache_name = member.options.cache orelse continue;
        if (!member.kind.isGetter()) try c.fail("only getters can cache into a class slot", .{});
        for (class.slots) |slot| {
            if (!eqlText(cache_name, slot.name)) continue;
            if ((slot.options.storage == .constructor) != member.kind.isStatic())
                try c.fail("cached getter and slot storage differ for: {s}", .{member.name});
            if (!structural.eql(slot.type, try cachedGetterValue(c, member)))
                try c.fail("cached getter and slot types differ for: {s}", .{member.name});
            break;
        } else try c.fail("class getter cache names an undeclared slot: {s}", .{cache_name});
        if (member.options.cache_on_construction and (member.options.backend orelse class.options.backend) == .builtin)
            try c.fail("constructor-time caching requires a native getter backend", .{});
    }
}

fn dataPropertiesRules(c: *Checker, class: schema.Class) Error!void {
    for (class.properties, 0..) |property, index| {
        try dataPropertyRules(c, property);
        const storage = property.options.storage;
        for (class.properties[0..index]) |previous| {
            if (previous.options.storage == storage and structural.eql(previous.key, property.key))
                try c.fail("duplicate class data property name: {s}", .{property.name});
        }
        for (class.members) |member| {
            const member_storage: schema.DataPropertyStorage = if (member.kind.isStatic()) .constructor else .prototype;
            if (member_storage != storage) continue;
            const member_key: schema.ClassMemberAliasKey = if (member.options.symbol) |symbol| .{ .symbol = symbol } else .{ .name = member.name };
            if (member.options.private_symbol == null and structural.eql(member_key, property.key))
                try c.fail("data property conflicts with class member: {s}", .{property.name});
            for (member.options.aliases) |alias| {
                if (structural.eql(alias.key, property.key)) try c.fail("data property conflicts with class member alias: {s}", .{property.name});
            }
        }
        for (class.slots) |slot| {
            const slot_storage: schema.DataPropertyStorage = if (slot.options.storage == .constructor) .constructor else .prototype;
            if (slot_storage == storage and slot.options.exposed and slot.options.private_symbol == null and
                structural.eql(schema.ClassMemberAliasKey{ .name = slot.name }, property.key))
                try c.fail("data property conflicts with cached slot: {s}", .{property.name});
        }
    }
}

// ─── surfaces ───

fn surfacePropertyName(c: *Checker, name: []const u8, description: []const u8) Error!void {
    try text(c, name, description);
    for (name) |byte| if (byte > 0x7f) return c.fail("{s} must be ASCII", .{description});
}

fn surfaceMemberKey(c: *Checker, key: schema.SurfacePropertyKey, options: schema.SurfaceMemberOptions) Error!void {
    switch (key) {
        .name => |name| try surfacePropertyName(c, name, "surface property"),
        .symbol => {},
        .builtin_name => |accessor| try identifier(c, accessor, "surface builtin-name accessor"),
        .engine_name => |member| try identifier(c, member, "surface engine property-name member"),
        .engine_builtin_name => |accessor| try identifier(c, accessor, "surface engine builtin-name accessor"),
    }
    try exposureRules(c, options.exposure);
    if (options.header.len != 0) try text(c, options.header, "surface member header");
    if (options.native_accessor) |accessor| try identifier(c, accessor, "native surface accessor");
    for (options.aliases) |alias| switch (alias.key) {
        .name => |alias_name| try surfacePropertyName(c, alias_name, "surface member alias"),
        .symbol => {},
        .builtin_name, .engine_name, .engine_builtin_name => try c.fail("surface aliases must use a public name or well-known symbol", .{}),
    };
}

fn nonFunctionSurfaceOptions(c: *Checker, options: schema.SurfaceMemberOptions) Error!void {
    if (options.constructable) try c.fail("only function surface members can be constructable", .{});
    if (options.function_visibility != .public) try c.fail("only function surface members can select implementation visibility", .{});
    if (options.function_name != null) try c.fail("only function surface members can select a function name", .{});
}

fn surfaceMemberRules(c: *Checker, member: schema.SurfaceMember) Error!void {
    const options = member.options;
    const name = member.propertyName();
    try surfaceMemberKey(c, member.key, options);
    switch (member.value) {
        .function => |bound| {
            if (c.n.functionIdOf(bound) == null) return c.fail("surface functions must reference a bound function declaration", .{});
            const function_options = bound.function.options;
            if (function_options.realm_identity) |identity| {
                if (options.constructable) try c.fail("realm functions cannot be constructable surface members", .{});
                if (options.function_visibility != identity.visibility) try c.fail("surface function visibility conflicts with its realm identity", .{});
                if (options.function_name) |function_name| if (!eqlText(function_name, identity.name))
                    try c.fail("surface function name conflicts with its realm identity", .{});
            }
            if (options.constructable and function_options.backend == .builtin) try c.fail("builtin surface functions cannot be constructable", .{});
            if (options.function_name) |function_name| try textAllowEmpty(c, function_name, "surface function name");
        },
        .accessor => |accessor| {
            try nonFunctionSurfaceOptions(c, options);
            switch (accessor) {
                .function => |function_accessor| {
                    if (c.n.functionIdOf(function_accessor.getter) == null)
                        try c.fail("surface function accessors must reference a bound getter function", .{});
                    if (function_accessor.setter) |setter| if (c.n.functionIdOf(setter) == null)
                        try c.fail("surface function accessors must reference a bound setter function or void", .{});
                    const setter_realm = if (function_accessor.setter) |setter| setter.function.options.realm_identity != null else false;
                    if (function_accessor.getter.function.options.realm_identity != null or setter_realm)
                        try c.fail("realm functions cannot be surface accessor functions", .{});
                },
                .builtin => |bound| if (bound.function.options.backend != .builtin)
                    try c.fail("surface builtin getters must reference a builtin function declaration", .{}),
            }
        },
        .lazy_declaration => |declaration| {
            try nonFunctionSurfaceOptions(c, options);
            switch (declaration) {
                .function => |bound| if (bound.function.arguments.listOrEmpty().len != 0)
                    try c.fail("lazy surface functions cannot accept arguments: {s}", .{name}),
                .native => |bound| {
                    if (bound.native_export.args.len != 0) try c.fail("lazy surface native exports cannot accept arguments: {s}", .{name});
                    if (bound.native_export.result == .void) try c.fail("lazy surface native exports must return a value: {s}", .{name});
                },
                .class => {},
            }
        },
        .object_value => |surface| {
            try nonFunctionSurfaceOptions(c, options);
            if (surface.options.installation != .direct)
                try c.fail("object-valued surface members require a directly installed object surface", .{});
        },
        .callable_value => |callable| {
            if (callable.declaration.function.options.realm_identity != null)
                try c.fail("realm functions cannot have per-surface callable properties", .{});
            if (callable.surface.options.installation != .direct)
                try c.fail("callable-valued surface members require a directly installed object surface", .{});
            if (options.constructable and callable.declaration.function.options.backend == .builtin)
                try c.fail("builtin callable-valued surface members cannot be constructable", .{});
            if (options.function_name) |function_name| try textAllowEmpty(c, function_name, "surface function name");
        },
        .constant => |constant| {
            try nonFunctionSurfaceOptions(c, options);
            switch (constant) {
                .string => |value| {
                    try textAllowEmpty(c, value, "surface string constant");
                    if (!std.unicode.utf8ValidateSlice(value)) try c.fail("surface string constant must be valid UTF-8", .{});
                },
                .external_string => |symbol| try identifier(c, symbol, "surface external string constant"),
                .registered_symbol => |key| try text(c, key, "surface registered-symbol key"),
                .external_number => |symbol| try identifier(c, symbol, "surface external numeric constant"),
                .external_boolean => |symbol| try identifier(c, symbol, "surface external boolean constant"),
                .undefined, .integer, .boolean => {},
            }
        },
        .empty_collection => |collection| {
            try nonFunctionSurfaceOptions(c, options);
            try typeTree(c, collection.element);
        },
        .lazy_owner => |owner| {
            try nonFunctionSurfaceOptions(c, options);
            try identifier(c, owner.member, switch (owner.owner) {
                .cell => "surface lazy-cell member",
                .class_structure => "surface lazy-class-structure member",
            });
        },
        .self => try nonFunctionSurfaceOptions(c, options),
    }
}

fn objectSurfaceRules(c: *Checker, surface: *const schema.ObjectSurface) Error!void {
    const name = surface.name;
    const options = surface.options;
    try identifier(c, name, "object surface");
    try exposureRules(c, options.exposure);
    if (options.cpp_class) |cpp_class| try identifier(c, cpp_class, "object surface C++ class");
    for (surface.members, 0..) |member, index| {
        const member_options = member.options;
        const property = member.propertyName();
        try surfaceMemberRules(c, member);
        if (member.value == .lazy_owner and options.cpp_class == null)
            try c.fail("owner-backed surface members require a C++ owner class: {s}", .{name});
        if (options.installation == .static_lookup and member_options.aliases.len != 0)
            try c.fail("identity aliases require a reified object surface: {s}", .{name});
        if (member_options.placement == .global_static and options.cpp_class == null)
            try c.fail("global-static surface members require a C++ owner class: {s}", .{name});
        if (member_options.native_accessor) |accessor| {
            const function_accessor = member.value == .accessor and member.value.accessor == .function;
            const external_number = member.value == .constant and member.value.constant == .external_number;
            if (options.installation == .direct or member_options.placement != .inferred or member.key != .name or
                function_accessor or external_number)
                try c.fail("native surface accessors require a table-backed member: {s}.{s}", .{ name, property });
            for (surface.members[0..index]) |previous| {
                const previous_accessor = previous.options.native_accessor orelse continue;
                if (eqlText(previous_accessor, accessor)) try c.fail("duplicate native surface accessor: {s}.{s}", .{ name, accessor });
            }
        }
        for (member_options.aliases, 0..) |alias, alias_index| {
            if (structural.eql(member.key, alias.key))
                try c.fail("surface member alias duplicates its source property: {s}.{s}", .{ name, property });
            for (member_options.aliases[0..alias_index]) |previous_alias| {
                if (structural.eql(previous_alias.key, alias.key)) try c.fail("duplicate object surface member alias: {s}.{s}", .{ name, property });
            }
        }
        for (surface.members[0..index]) |previous| {
            if (structural.eql(previous.key, member.key)) try c.fail("duplicate object surface property: {s}.{s}", .{ name, property });
            for (previous.options.aliases) |previous_alias| {
                if (structural.eql(previous_alias.key, member.key))
                    try c.fail("object surface property collides with an earlier alias: {s}.{s}", .{ name, property });
            }
            for (member_options.aliases) |alias| {
                if (structural.eql(previous.key, alias.key))
                    try c.fail("object surface alias collides with an earlier property: {s}.{s}", .{ name, property });
                for (previous.options.aliases) |previous_alias| {
                    if (structural.eql(previous_alias.key, alias.key)) try c.fail("duplicate object surface alias: {s}.{s}", .{ name, property });
                }
            }
        }
    }
}

fn nativeModuleExportName(member: schema.SurfaceMember) ?[]const u8 {
    return switch (member.key) {
        .name => |name| name,
        else => null,
    };
}

fn nativeModuleRules(c: *Checker, native_module: schema.NativeModule) Error!void {
    const options = native_module.options;
    const specifier = native_module.specifier;
    try identifier(c, native_module.name, "native module");
    try text(c, specifier, "native module specifier");
    if (options.default_name) |default_name| try text(c, default_name, "native module default export name");
    try exposureRules(c, options.exposure);
    const policy = std.meta.activeTag(options.default);
    if (policy == .namespace and (options.default_surface != .none or options.attach_default_to_default))
        try c.fail("only a declaration default can describe or modify its native module surface", .{});
    if (options.attach_default_to_default and options.default_surface != .install)
        try c.fail("a native module default is attached to itself only through an installed default surface: {s}", .{specifier});
    const exports = switch (native_module.exports) {
        .members => |members| members,
        .surface => |surface| surface.members,
    };
    for (exports, 0..) |member, index| {
        if (native_module.exports == .members) try surfaceMemberRules(c, member);
        if (policy == .declaration and options.default_surface == .none)
            try c.fail("surface-member native exports require a namespace default or a declared default surface: {s}", .{specifier});
        if ((member.value == .object_value or member.value == .callable_value) and native_module.exports == .members)
            try c.fail("composed native module exports require a named object surface: {s}", .{specifier});
        const export_name = nativeModuleExportName(member) orelse {
            try c.fail("native module surface members require public string keys", .{});
            continue;
        };
        for (member.options.aliases) |alias| switch (alias.key) {
            .name => |alias_name| if (eqlText(alias_name, "default"))
                try c.fail("native module surface-member aliases cannot use the reserved default name", .{}),
            else => try c.fail("native module surface-member aliases require public string keys: {s}", .{member.propertyName()}),
        };
        if (member.options.placement == .global_static)
            try c.fail("native module surface members cannot use global-static placement: {s}", .{member.propertyName()});
        const supported = switch (member.value) {
            .accessor => |accessor| accessor != .builtin,
            .lazy_owner => false,
            else => true,
        };
        if (!supported) try c.fail("unsupported native module surface member: {s}", .{member.propertyName()});
        for (exports[0..index]) |previous| {
            if (nativeModuleExportName(previous)) |previous_name| if (eqlText(previous_name, export_name))
                try c.fail("duplicate native module export name: {s}", .{export_name});
            for (previous.options.aliases) |previous_alias| {
                if (previous_alias.key == .name and eqlText(previous_alias.key.name, export_name))
                    try c.fail("native module export name collides with an alias: {s}", .{export_name});
            }
            for (member.options.aliases) |alias| {
                if (alias.key != .name) continue;
                if (nativeModuleExportName(previous)) |previous_name| if (eqlText(previous_name, alias.key.name))
                    try c.fail("native module export name collides with an alias: {s}", .{alias.key.name});
                for (previous.options.aliases) |previous_alias| {
                    if (structural.eql(previous_alias.key, alias.key)) try c.fail("duplicate native module export alias: {s}", .{alias.key.name});
                }
            }
        }
    }
}

fn focusedIntegrationRules(c: *Checker, integration: schema.FocusedEngineIntegration) Error!void {
    const options = integration.options;
    try identifier(c, integration.name, "focused engine integration");
    switch (options.backend) {
        .cpp => if (options.header) |header| {
            try text(c, header, "focused engine integration header");
        } else {
            try c.fail("C++ engine integrations require a declaration header", .{});
        },
        .zig => if (options.header != null) try c.fail("Zig engine integrations declare their interface in the implementation module", .{}),
    }
    try text(c, options.implementation, "focused engine integration implementation");
    try asciiText(c, options.behavior, "focused engine integration behavior");
}

// ─── modules ───

fn duplicateNames(c: *Checker, comptime T: type, items: []const T, category: []const u8) Error!void {
    for (items, 0..) |item, index| {
        for (items[0..index]) |previous| {
            if (eqlText(previous.name, item.name)) {
                try c.fail("duplicate {s} name in binding schema: {s}", .{ category, item.name });
                break;
            }
        }
    }
}

fn moduleRules(c: *Checker, module: *const schema.Module) Error!void {
    c.location = module.name;
    try identifier(c, module.name, "module");
    try duplicateNames(c, schema.Function, module.functions, "function");
    try duplicateNames(c, schema.Class, module.classes, "class");
    try duplicateNames(c, schema.EngineShim, module.engine_shims, "engine shim");
    try duplicateNames(c, schema.NativeExport, module.native_exports, "native export");
    for (module.functions) |function| {
        try c.at(module.name, function.name);
        try functionRules(c, function);
    }
    for (module.classes, 0..) |class, index| {
        try c.at(module.name, class.name);
        try classRules(c, class);
        try classParentRules(c, module, class, index);
    }
    for (module.engine_shims) |shim| {
        try c.at(module.name, shim.name);
        try engineShimRules(c, shim);
    }
    for (module.native_exports) |native_export| {
        try c.at(module.name, native_export.name);
        try nativeExportRules(c, native_export);
    }
    for (module.surfaces, 0..) |surface, index| {
        switch (surface) {
            .native_module => |native_module| {
                try c.at(module.name, native_module.name);
                try nativeModuleRules(c, native_module);
            },
            .object => |object| try c.at(module.name, object.name),
        }
        for (module.surfaces[0..index]) |previous| {
            if (surface == .native_module and previous == .native_module and
                eqlText(previous.native_module.specifier, surface.native_module.specifier))
                try c.fail("duplicate native module specifier: {s}", .{surface.native_module.specifier});
            if (surface == .object and previous == .object and eqlText(previous.object.name, surface.object.name))
                try c.fail("duplicate object surface name: {s}", .{surface.object.name});
        }
    }
    for (module.focused_integrations, 0..) |integration, index| {
        try c.at(module.name, integration.name);
        try focusedIntegrationRules(c, integration);
        for (module.focused_integrations[0..index]) |previous| {
            if (eqlText(previous.name, integration.name)) try c.fail("duplicate focused engine integration: {s}", .{integration.name});
        }
    }
}

fn classParentRules(c: *Checker, module: *const schema.Module, class: schema.Class, index: usize) Error!void {
    const parent = (class.options.parent orelse return);
    const parent_class = switch (parent) {
        .class => |parent_class| parent_class,
        .engine => return,
    };
    for (module.classes, 0..) |*candidate, candidate_index| {
        if (candidate != parent_class and !structural.eql(candidate.*, parent_class.*)) continue;
        if (candidate_index >= index) try c.fail("a class parent must precede its child in the same binding module: {s}", .{class.name});
        break;
    }
    const options = class.options;
    const parent_options = parent_class.options;
    if (options.representation != parent_options.representation)
        try c.fail("class inheritance requires matching representations: {s}", .{class.name});
    if (options.representation == .native and options.ownership != parent_options.ownership)
        try c.fail("native class inheritance requires matching ownership: {s}", .{class.name});
    if (options.representation == .native and options.ownership == .shared) {
        if (options.reference_thread != parent_options.reference_thread)
            try c.fail("shared native class inheritance requires matching reference threads: {s}", .{class.name});
        if (options.identity != parent_options.identity)
            try c.fail("shared native class inheritance requires matching wrapper identity: {s}", .{class.name});
    }
}

// ─── manifest ───

fn manifestRules(c: *Checker) Error!void {
    const n = c.n;
    var structured_clone_tags: [256]bool = @splat(false);
    for (n.declared_classes.items, 0..) |declared, class_id| {
        const class = declared.class;
        try c.at(declared.module_name, class.name);
        const earlier = n.declared_classes.items[0..class_id];
        for (earlier) |previous| {
            if (previous.module != declared.module and eqlText(previous.class.name, class.name) and
                structural.eql(previous.class.*, class.*))
                try c.fail("a raw class declaration cannot belong to multiple binding modules", .{});
        }
        if (class.options.parent) |parent| if (parent == .class) {
            const parent_id = for (n.declared_classes.items, 0..) |candidate, index| {
                if (candidate.class == parent.class or structural.eql(candidate.class.*, parent.class.*)) break index;
            } else null;
            if (parent_id) |index| {
                if (index >= class_id) try c.fail("a class parent must belong to an earlier module in the binding schema DAG: {s}", .{class.name});
            } else try c.fail("class parent is absent from the binding manifest", .{});
        };
        if (class.options.structured_clone) |structured_clone| {
            if (structured_clone_tags[structured_clone.tag]) try c.fail("duplicate structured clone tag on class: {s}", .{class.name});
            structured_clone_tags[structured_clone.tag] = true;
        }
    }
    for (n.modules) |module| {
        for (module.functions) |function| {
            try c.at(module.name, function.name);
            try typePredicateTarget(c, module.name, function);
        }
    }
    for (n.declared_native_modules.items, 0..) |declared, index| {
        const native_module = declared.native_module;
        const module_name = n.modules[declared.module].name;
        try c.at(module_name, native_module.name);
        if (eqlText(native_module.specifier, "default")) try c.fail("native module specifier cannot be default", .{});
        switch (native_module.options.default) {
            .declaration => |declaration| switch (declaration) {
                .function => |bound| try functionReference(c, bound),
                .class => |bound| try classReference(c, bound),
            },
            .namespace => {},
        }
        const exports = switch (native_module.exports) {
            .members => |members| members,
            .surface => |surface| surface.members,
        };
        for (exports) |member| {
            if (nativeModuleExportName(member)) |name| if (eqlText(name, "default"))
                try c.fail("native module named exports cannot use the reserved default name", .{});
            try surfaceMemberReference(c, member);
        }
        for (n.declared_native_modules.items[0..index]) |previous| {
            if (previous.module != declared.module and eqlText(previous.native_module.specifier, native_module.specifier))
                try c.fail("duplicate native module specifier: {s}", .{native_module.specifier});
        }
    }
    for (n.declared_object_surfaces.items, 0..) |surface, index| {
        c.location = surface.name;
        try objectSurfaceRules(c, surface);
        for (surface.members) |member| {
            try surfaceMemberReference(c, member);
            const dependency = switch (member.value) {
                .object_value => |dependency| dependency,
                .callable_value => |callable| callable.surface,
                else => continue,
            };
            const dependency_index = objectSurfaceIndex(n, dependency) orelse continue;
            if (dependency_index >= index)
                try c.fail("an object surface value must reference an earlier surface in the schema DAG: {s}.{s}", .{ surface.name, member.propertyName() });
        }
        for (n.declared_object_surfaces.items[0..index]) |previous| {
            if (eqlText(previous.name, surface.name)) try c.fail("duplicate object surface name: {s}", .{surface.name});
        }
    }
}

pub fn objectSurfaceIndex(n: *const Normalizer, surface: *const schema.ObjectSurface) ?u32 {
    for (n.declared_object_surfaces.items, 0..) |candidate, index| {
        if (candidate == surface or structural.eql(candidate.*, surface.*)) return @intCast(index);
    }
    return null;
}

fn functionReference(c: *Checker, bound: schema.BoundFunction) Error!void {
    if (c.n.functionIdOf(bound) == null)
        try c.fail("native module surface references a function absent from the normalized manifest: {s}.{s}", .{ bound.module, bound.function.name });
}

fn classReference(c: *Checker, bound: schema.BoundClass) Error!void {
    if (c.n.classIdOf(bound) == null)
        try c.fail("native module surface references a class absent from the normalized manifest: {s}.{s}", .{ bound.module, bound.class.name });
}

fn objectSurfaceReference(c: *Checker, surface: *const schema.ObjectSurface) Error!void {
    if (objectSurfaceIndex(c.n, surface) == null)
        try c.fail("object surface references a surface absent from the normalized manifest: {s}", .{surface.name});
}

fn surfaceMemberReference(c: *Checker, member: schema.SurfaceMember) Error!void {
    switch (member.value) {
        .function => |bound| try functionReference(c, bound),
        .lazy_declaration => |declaration| switch (declaration) {
            .function => |bound| try functionReference(c, bound),
            .class => |bound| try classReference(c, bound),
            .native => |bound| if (c.n.nativeExportIdOf(bound) == null)
                try c.fail("object surface references a native export absent from the normalized manifest: {s}.{s}", .{ bound.module, bound.native_export.name }),
        },
        .callable_value => |callable| {
            try functionReference(c, callable.declaration);
            try objectSurfaceReference(c, callable.surface);
        },
        .object_value => |surface| try objectSurfaceReference(c, surface),
        .accessor => |accessor| switch (accessor) {
            .builtin => |bound| try functionReference(c, bound),
            .function => |function_accessor| {
                try functionReference(c, function_accessor.getter);
                if (function_accessor.setter) |setter| try functionReference(c, setter);
            },
        },
        .self, .constant, .empty_collection, .lazy_owner => {},
    }
}

fn classByName(n: *const Normalizer, name: schema.ClassName) ?*const schema.Class {
    const id = n.classId(name) orelse return null;
    return n.declared_classes.items[id].class;
}

fn typePredicateTarget(c: *Checker, module_name: []const u8, function: schema.Function) Error!void {
    const target = function.options.type_predicate orelse return;
    const reference: schema.ClassName, const initial_structure = switch (target) {
        .class_ref => |class_ref| .{ class_ref.target orelse return, false },
        .branded_value => |branded| if (branded.brand.matcher == .instance_class)
            .{ branded.brand.matcher.instance_class.class, branded.brand.matcher.instance_class.match == .initial_structure }
        else
            return,
        else => return,
    };
    const class = classByName(c.n, reference) orelse return c.fail(
        "type predicate references a class absent from the normalized binding manifest: {s}.{s}",
        .{ reference.module, reference.class },
    );
    if (initial_structure and (class.options.representation != .native or class.options.brand != null))
        try c.fail("initial-structure brands require generated native classes without a custom brand", .{});
    if (class.options.representation == .plain and class.options.brand == null)
        try c.fail(
            "type predicate {s}.{s} cannot target unbranded plain class {s}.{s}: plain instances have no generated C++ instance class; declare ClassOptions.brand",
            .{ module_name, function.name, reference.module, reference.class },
        );
}

// ─── class references visible to the target ───

const binding_class_message = "an exposed binding cannot reference a generated class excluded from the target";

fn materializedClassReferences(c: *Checker, t: Type) Error!void {
    switch (t) {
        .dictionary => |dictionary| {
            if (dictionary.options.result_class) |bound| {
                const id = c.n.classIdOf(bound) orelse return c.fail("dictionary result class is absent from the normalized binding manifest", .{});
                const class = c.n.declared_classes.items[id].class;
                if (!c.n.isExposed(class.options.exposure) or class.options.representation != .plain)
                    try c.fail("a dictionary result class must resolve to an exposed plain class", .{});
            }
            for (dictionary.fields) |field| try materializedClassReferences(c, field.type);
        },
        .optional => |optional| try materializedClassReferences(c, optional.child.*),
        .sequence => |sequence| try materializedClassReferences(c, sequence.child),
        .union_type => |members| for (members.members) |member| try materializedClassReferences(c, effectiveUnionMemberType(member)),
        .record => |record| try materializedClassReferences(c, record.value),
        .branded_value => |branded| if (branded.brand.promise_value) |value| try materializedClassReferences(c, value.*),
        else => {},
    }
}

fn classReferences(c: *Checker) Error!void {
    const n = c.n;
    for (n.declared_functions.items) |declared| {
        if (declared.member != null) continue;
        if (!n.isExposed(declared.options.exposure)) continue;
        try c.at(declared.module_name, declared.function_name);
        try callableClassReferences(c, declared, binding_class_message);
    }
    for (n.declared_classes.items) |declared| {
        const class = declared.class;
        if (!n.isExposed(class.options.exposure)) continue;
        try c.at(declared.module_name, class.name);
        var callables: [2]?u32 = .{ declared.constructor, declared.constructor_call };
        for (&callables) |maybe_id| {
            const id = maybe_id orelse continue;
            const callable = n.declared_functions.items[id];
            if (n.isExposed(callable.options.exposure)) try callableClassReferences(c, callable, binding_class_message);
        }
        for (declared.members) |id| {
            const member = n.declared_functions.items[id];
            if (n.isExposed(member.options.exposure)) try callableClassReferences(c, member, binding_class_message);
        }
        for (class.slots) |slot| {
            try semanticClassReferences(c, slot.type, binding_class_message);
            try materializedClassReferences(c, slot.type);
        }
        for (class.instance_properties) |property| {
            try semanticClassReferences(c, property.options.value, binding_class_message);
            try materializedClassReferences(c, property.options.value);
        }
    }
    for (n.declared_engine_shims.items) |declared| {
        try c.at(declared.module_name, declared.shim.name);
        try argumentClassReferences(c, declared.shim.args, "an exposed engine shim cannot reference a generated class excluded from the target");
        try semanticClassReferences(c, declared.shim.result, "an exposed engine shim cannot reference a generated class excluded from the target");
    }
    for (n.declared_native_exports.items) |declared| {
        const native_export = declared.native_export;
        if (!n.isExposed(native_export.options.exposure)) continue;
        try c.at(declared.module_name, native_export.name);
        try argumentClassReferences(c, native_export.args, binding_class_message);
        try semanticClassReferences(c, native_export.result, binding_class_message);
        for (native_export.options.errors.errors) |domain_error| try semanticClassReferences(c, domain_error.payload, binding_class_message);
    }
}

fn callableClassReferences(c: *Checker, declared: normalize.Declared, hidden_message: []const u8) Error!void {
    const options = declared.options;
    switch (declared.arguments) {
        .list => |list| try argumentClassReferences(c, list, hidden_message),
        .overloads => |overloads| for (overloads.cases) |case| try argumentClassReferences(c, case.args, hidden_message),
    }
    inline for (.{ options.this_value_type, options.new_target_type, options.callee_value_type }) |value_type| {
        if (value_type) |t| try semanticClassReferences(c, t, hidden_message);
    }
    try semanticClassReferences(c, declared.result, hidden_message);
    try materializedClassReferences(c, declared.result);
    for (options.errors.errors) |domain_error| {
        try semanticClassReferences(c, domain_error.payload, hidden_message);
        try materializedClassReferences(c, domain_error.payload);
    }
    const predicate = options.type_predicate orelse return;
    if (predicate == .class_ref) {
        const reference = predicate.class_ref.target orelse return;
        const class = classByName(c.n, reference) orelse
            return c.fail("type predicate references a class absent from the normalized binding manifest", .{});
        if (!c.n.isExposed(class.options.exposure)) try c.fail("an exposed binding cannot reference a generated class excluded from the target", .{});
    } else {
        try semanticClassReferences(c, predicate, hidden_message);
    }
}

fn argumentClassReferences(c: *Checker, arguments: []const schema.Argument, hidden_message: []const u8) Error!void {
    for (arguments) |argument| {
        try semanticClassReferences(c, effectiveArgumentType(argument), hidden_message);
        if (try normalize.argumentRestType(c.n, argument)) |rest_type| try semanticClassReferences(c, rest_type, hidden_message);
    }
}

fn semanticClassReferences(c: *Checker, t: Type, hidden_message: []const u8) Error!void {
    const n = c.n;
    switch (t) {
        .discarded => |discarded| if (discarded.match == .semantic_type) try semanticClassReferences(c, discarded.match_type.*, hidden_message),
        .lazy => |child| try semanticClassReferences(c, child.*, hidden_message),
        .optional => |optional| try semanticClassReferences(c, optional.child.*, hidden_message),
        .sequence => |sequence| try semanticClassReferences(c, sequence.child, hidden_message),
        .converted => |converted| {
            try semanticClassReferences(c, converted.native, hidden_message);
            try semanticClassReferences(c, converted.match, hidden_message);
        },
        .dictionary => |dictionary| {
            for (dictionary.fields) |field| try semanticClassReferences(c, field.type, hidden_message);
        },
        .union_type => |union_type| for (union_type.members) |member| try semanticClassReferences(c, effectiveUnionMemberType(member), hidden_message),
        .record => |record| {
            try semanticClassReferences(c, record.key, hidden_message);
            try semanticClassReferences(c, record.value, hidden_message);
        },
        .class_ref => |class_ref| {
            const reference = class_ref.target orelse return;
            const class = classByName(n, reference) orelse return c.fail(
                "class reference is absent from the normalized binding manifest: {s}.{s}",
                .{ reference.module, reference.class },
            );
            if (!n.isExposed(class.options.exposure)) try c.fail("{s}", .{hidden_message});
            if (class.options.representation == .plain) try c.fail("plain classes do not have native class references; use a branded value", .{});
        },
        .branded_value => |branded| {
            const brand = branded.brand;
            if (brand.promise_value) |value| try semanticClassReferences(c, value.*, hidden_message);
            const reference = if (brand.matcher == .instance_class) brand.matcher.instance_class.class else brand.constructor_class orelse return;
            const class = classByName(n, reference) orelse return c.fail("branded class reference is absent from the normalized binding manifest", .{});
            if (!n.isExposed(class.options.exposure)) try c.fail("{s}", .{hidden_message});
            if (brand.matcher == .instance_class) {
                const instance = brand.matcher.instance_class;
                if (instance.match == .initial_structure and (class.options.representation != .native or class.options.brand != null))
                    try c.fail("initial-structure brands require generated native classes without a custom brand", .{});
                if (class.options.representation == .plain and class.options.brand == null)
                    try c.fail("plain class values require a declared class brand", .{});
            }
        },
        .callback => |callback| {
            if (callback.options.receiver) |receiver| try materializedClassReferences(c, receiver);
            try argumentClassReferences(c, callback.args, "an exposed callback cannot reference a generated class excluded from the target");
            for (callback.args) |argument| try materializedClassReferences(c, effectiveArgumentType(argument));
            try semanticClassReferences(c, callback.result, "an exposed callback cannot reference a generated class excluded from the target");
        },
        else => {},
    }
}

// ─── normalized plans ───

fn resultCollection(c: *Checker, label: []const u8, kind: []const u8, child: anytype) Error!void {
    const rooted = switch (@TypeOf(child).role) {
        .inbound_result => !c.n.get(child).requires_scope,
        .outbound_result => rootedResultStorage(c.n, child),
        .inbound_argument, .outbound_argument => @compileError("result validation requires a result plan"),
    };
    if (!rooted) try c.fail("{s} transfers a {s} of borrowed engine values through unscanned memory; root them behind a class or return them individually", .{ label, kind });
    try resultTree(c, label, child);
}

fn resultTree(c: *Checker, label: []const u8, id: anytype) Error!void {
    const position = c.n.get(id).*;
    switch (position.representation) {
        .converted => |conversion| try resultTree(c, label, conversion.apiValue()),
        .optional => |child| try resultTree(c, label, child),
        .dictionary => |fields| for (fields) |field| try resultTree(c, label, field.value),
        .union_type => |members| for (members) |member| try resultTree(c, label, member.value),
        inline .sequence, .rest => |child| try resultCollection(c, label, "sequence", child),
        .record => |entry| try resultCollection(c, label, "record", entry),
        .record_entry => |entry| {
            try resultTree(c, label, entry.key);
            try resultTree(c, label, entry.value);
        },
        .leaf => |leaf| switch (@TypeOf(id).role) {
            .inbound_result => switch (leaf) {
                .void, .scalar, .enumeration, .js_value_result, .string_owned, .utf8_owned, .bytes_owned, .lease_owned, .callback_owned, .class_owned, .external_owned, .nominal_borrow, .nominal_owned, .native_instance => {},
            },
            .outbound_result => switch (leaf) {
                .void, .scalar, .enumeration, .js_value_result, .string_owned, .bytes_owned, .callback_result, .class_result, .nominal_borrow, .nominal_owned => {},
            },
            .inbound_argument, .outbound_argument => @compileError("result validation requires a result plan"),
        },
    }
}

fn rootedResultStorage(n: *const Normalizer, id: ir.OutboundResultPlanId) bool {
    return switch (n.get(id).representation) {
        .converted => |conversion| rootedResultStorage(n, conversion.value),
        inline .optional, .sequence, .record, .rest => |child| rootedResultStorage(n, child),
        .dictionary => |fields| for (fields) |field| {
            if (!rootedResultStorage(n, field.value)) break false;
        } else true,
        .union_type => |members| for (members) |member| {
            if (!rootedResultStorage(n, member.value)) break false;
        } else true,
        .record_entry => |entry| rootedResultStorage(n, entry.key) and rootedResultStorage(n, entry.value),
        .leaf => |leaf| switch (leaf) {
            .js_value_result => false,
            .void, .scalar, .enumeration, .string_owned, .bytes_owned, .callback_result, .class_result, .nominal_borrow, .nominal_owned => true,
        },
    };
}

fn classPlanRules(c: *Checker, class: *const ir.Class) Error!void {
    if (!class.exposed) return;
    for (class.declarations) |id| {
        const member = c.n.functions.items[id.index];
        if (!member.exposed) continue;
        try c.at(member.module_name, member.function_name);
        const facts = member.class_member.?;
        const options = c.n.declaration(member.id).member.?.raw.options;
        if (options.unforgeable and options.invalid_this != .throw)
            try c.fail("unforgeable accessors must throw on an invalid receiver: {s}", .{member.js_name});
        if (options.symbol == null and options.private_symbol == null and facts.member_kind == .static_getter and member.backend == .builtin)
            try c.fail("static builtin getters are not supported: {s}", .{member.js_name});
        if (options.private_symbol) |symbol| if (!facts.member_kind.isGetter() and member.backend == .builtin)
            try c.fail("private-symbol members cannot be builtins: {s}", .{symbol});
        for (options.aliases) |alias| if (!alias.options.writable or !alias.options.configurable)
            try c.fail("class member aliases must stay writable and configurable", .{});
    }
    try c.at(class.module_name, class.class_name);
    for (class.slots, c.n.declared_classes.items[class.id.index].class.slots) |slot, raw| {
        if (slot.storage == .constructor and raw.options.exposed and !mod_classes.slotCachesMember(c.n, class, slot) and raw.options.private_symbol == null)
            try c.fail("constructor cached slots must be private or cache a member: {s}", .{slot.slot_name});
    }
}

fn completionPayload(c: *Checker, label: []const u8, id: ir.TypeId) Error!void {
    const resources = c.n.projection(id).resources;
    if (resources.encode != .any or resources.destroy != .any)
        try c.fail("{s} must be encodable and destructible on any thread", .{label});
}

fn functionPlanRules(c: *Checker, function: *const ir.Function) Error!void {
    const n = c.n;
    const qualified = if ((function.id == .overload))
        try n.print("{s}_{s}_overload_{s}", .{ function.module_name, function.function_name, function.case_name })
    else
        try n.print("{s}_{s}", .{ function.module_name, function.function_name });
    c.location = try n.print("{s}.{s}", .{ function.module_name, function.function_name });
    if (function.backend == .zig) try resultTree(c, try n.print("{s} result", .{qualified}), function.result_position);
    if (function.backend != .cpp or function.completion != null) for (function.domain_errors) |id| {
        const domain_error = n.get(id);
        try resultTree(c, try n.print("{s} domain error {s}", .{ qualified, domain_error.error_name }), domain_error.position);
    };
    if (function.completion) |completion_id| {
        const completion = n.get(completion_id);
        if (completion.delivery != .vm) try completionPayload(c, try n.print("{s} result", .{qualified}), n.get(completion.payload).type);
        if (completion.error_delivery == .wire) for (function.domain_errors) |id| {
            const domain_error = n.get(id);
            try completionPayload(c, try n.print("{s} domain error {s}", .{ qualified, domain_error.error_name }), n.get(domain_error.position).type);
        };
        if (n.completion_inputs.items[completion_id.index].materializer) |materializer| {
            if (n.get(n.get(materializer).outbound.result_position).type.index != n.get(function.result_position).type.index)
                try c.fail("completion materializer result must match the declared function result", .{});
        }
    }
    for (function.args) |argument| {
        const input_plan = n.get(argument.position).input;
        const raw = n.declaration(function.id).inputs.arguments;
        for (raw) |declared| if (eqlText(declared.name, argument.argument_name) and declared.options.selection != null and plans.inputFacts(n, input_plan).effective_buffer_mode_mask & 2 != 0)
            try c.fail("selected arguments require copy ownership for buffers", .{});
        if (argument.conversion.rest and plans.inputFacts(n, input_plan).effective_buffer_mode_mask & 2 != 0)
            try c.fail("rest arguments require copy ownership for buffers", .{});
        try functionInputPlan(c, function.backend, argument.position);
    }
    inline for (.{ function.this_argument, function.new_target_argument, function.callee_argument }) |maybe_argument| {
        if (maybe_argument) |argument| try functionInputPlan(c, function.backend, argument.position);
    }
}

fn functionInputPlan(c: *Checker, backend: ir.Backend, position: ir.InboundArgumentPlanId) Error!void {
    const id = c.n.get(position).input;
    switch (backend) {
        .zig => try wireInputPlan(c, id),
        .cpp => try cppLazyDictionaryInputPlan(c, id),
        .builtin => {},
    }
}

fn wireInputPlan(c: *Checker, id: InputPlanId) Error!void {
    switch (plans.plan(c.n, id).codec) {
        .converted => |converted| try wireInputPlan(c, converted.match),
        .discarded => |discarded| try wireInputPlan(c, discarded.match),
        .lazy => |child| try wireInputPlan(c, child),
        .optional => |optional| try wireInputPlan(c, optional.child),
        .sequence => |sequence| try wireInputPlan(c, sequence.child),
        .dictionary => |fields| for (fields, c.n.rawType(plans.plan(c.n, id).type).dictionary.fields) |field, raw| {
            if (raw.options.private_symbol != null) try c.fail("private-symbol dictionary fields are restricted to C++ binding implementations", .{});
            try wireInputPlan(c, field);
        },
        .union_type => |members| for (members) |member| try wireInputPlan(c, member),
        .record => |record| {
            try wireInputPlan(c, record.key);
            try wireInputPlan(c, record.value);
        },
        else => {},
    }
}

fn cppLazyDictionaryInputPlan(c: *Checker, id: InputPlanId) Error!void {
    switch (plans.plan(c.n, id).codec) {
        .converted => |converted| try cppLazyDictionaryInputPlan(c, converted.match),
        .discarded => |discarded| try cppLazyDictionaryInputPlan(c, discarded.match),
        .lazy => |child| try cppLazyDictionaryInputPlan(c, child),
        .optional => |optional| try cppLazyDictionaryInputPlan(c, optional.child),
        .sequence => |sequence| try cppLazyDictionaryInputPlan(c, sequence.child),
        .dictionary => |fields| for (fields, c.n.rawType(plans.plan(c.n, id).type).dictionary.fields) |field, raw| {
            if (plans.codecOf(c.n, field) == .lazy and raw.options.node_incompatible_with != null)
                try c.fail("lazy dictionary fields cannot use node_incompatible_with", .{});
            try cppLazyDictionaryInputPlan(c, field);
        },
        .union_type => |members| for (members) |member| try cppLazyDictionaryInputPlan(c, member),
        .record => |record| {
            try cppLazyDictionaryInputPlan(c, record.key);
            try cppLazyDictionaryInputPlan(c, record.value);
        },
        else => {},
    }
}

fn supportsAnyAffinity(thread: ir.ResourceThread) bool {
    return thread == .any or thread == .current;
}

fn engineShimPlanRules(c: *Checker, shim: *const ir.EngineShim) Error!void {
    const n = c.n;
    const options = n.rawEngineShim(shim.id).options;
    const qualified = try n.print("{s}_{s}", .{ shim.module_name, shim.shim_name });
    c.location = try n.print("{s}.{s}", .{ shim.module_name, shim.shim_name });
    try resultTree(c, try n.print("{s} result", .{qualified}), shim.outbound.result_position);
    if (options.affinity == .any) {
        for (shim.outbound.args) |argument| {
            const resources = n.projection(n.get(argument.position).type).resources;
            if (!supportsAnyAffinity(resources.access) or !supportsAnyAffinity(resources.encode) or !supportsAnyAffinity(resources.destroy)) {
                try c.fail("any-thread engine shim arguments require any-thread resource contracts: {s}", .{qualified});
                break;
            }
        }
        const resources = n.projection(n.get(shim.outbound.result_position).type).resources;
        if (!supportsAnyAffinity(resources.clone) or !supportsAnyAffinity(resources.decode) or !supportsAnyAffinity(resources.destroy))
            try c.fail("any-thread engine shim results require any-thread resource contracts: {s}", .{qualified});
    }
    var has_lazy_conversion = false;
    for (shim.outbound.args) |argument| {
        if (plans.inputFacts(n, n.get(argument.position).input).contains_receiver_conversion)
            try c.fail("engine shim converters cannot depend on an object receiver: {s}", .{qualified});
        has_lazy_conversion = has_lazy_conversion or plans.inputFacts(n, n.get(argument.position).input).contains_lazy_conversion;
    }
    if (has_lazy_conversion and (shim.outbound.call_plan.realm != .current or shim.outbound.call_plan.throws != .js_exception or !shim.outbound.call_plan.checks_traps))
        try c.fail("lazy engine arguments require a trap-checked current realm with JavaScript exception propagation", .{});
    const result_source = options.result_source;
    const adapter_allocates = result_source == .javascript or cpp_facts.get(n, shim.outbound.result_position).result_encoding_allocates or for (shim.outbound.args) |argument| {
        if (n.get(argument.valuePosition()).zig.encode_allocates) break true;
    } else false;
    if (!shim.outbound.call_plan.checks_traps and shim.outbound.call_plan.throws == .never and adapter_allocates)
        try c.fail("engine shim {s} requires error propagation for allocating adapters", .{qualified});
    if (result_source == .javascript) {
        const value = n.get(shim.outbound.result_position).input;
        if (plans.inputFacts(n, value).contains_receiver_conversion)
            try c.fail("engine JavaScript result converters cannot depend on an object receiver: {s}", .{qualified});
        try callbackResultRules(c, value);
        try wireInputPlan(c, value);
    }
}

fn nativeExportPlanRules(c: *Checker, native_export: *const ir.NativeExport) Error!void {
    const n = c.n;
    const qualified = try n.print("{s}_{s}", .{ native_export.module_name, native_export.export_name });
    c.location = try n.print("{s}.{s}", .{ native_export.module_name, native_export.export_name });
    try resultTree(c, try n.print("{s} result", .{qualified}), native_export.result_position);
    const result_facts = cpp_facts.get(n, native_export.result_position);
    const adapter_allocates = result_facts.result_encoding_allocates or result_facts.decode_allocates or for (native_export.args) |argument| {
        if (cpp_facts.get(n, argument.position).argument_allocates) break true;
    } else false;
    if (native_export.call_plan.throws == .never and adapter_allocates)
        try c.fail("native export requires error propagation for allocating C++ adapters", .{});
    for (native_export.domain_errors) |id| {
        const domain_error = n.get(id);
        try resultTree(c, try n.print("{s} domain error {s}", .{ qualified, domain_error.error_name }), domain_error.position);
    }
    for (native_export.args) |argument| {
        if (plans.inputFacts(n, n.get(argument.position).input).contains_receiver_conversion)
            try c.fail("native export converters cannot depend on an object receiver: {s}", .{qualified});
        if (native_export.call_plan.throws != .js_exception) try nonThrowingNativeParameter(c, argument.position);
    }
}

fn callbackPlanRules(c: *Checker, callback: *const ir.Callback) Error!void {
    const n = c.n;
    const call = &n.callback_calls[callback.id.index];
    c.location = callback.callback_name;
    try resultTree(c, try n.print("{s} callback result", .{callback.callback_name}), call.result_position);
    const result_value = n.get(call.result_position).input;
    if (plans.inputFacts(n, result_value).contains_receiver_conversion)
        try c.fail("typed callback result converters cannot depend on an object receiver: {s}", .{callback.callback_name});
    for (call.args) |argument| {
        if (argument.conversion.rest and n.irType(n.get(argument.position).type).kind() == .discarded) try c.fail("discarded rest arguments cannot be callback parameters", .{});
        try callbackValueRules(c, n.get(argument.position).input, .outbound_argument);
    }
    if (call.call_plan.receiver) |receiver| try callbackValueRules(c, n.get(receiver).input, .outbound_argument);
    try callbackResultRules(c, result_value);
    try wireInputPlan(c, result_value);
}

/// The schema rules for a typed callback value. Whether it can be materialized
/// or converted is decided when its codecs are planned.
fn callbackValueRules(c: *Checker, id: InputPlanId, role: ir.Role) Error!void {
    const n = c.n;
    const plan = plans.plan(n, id);
    switch (plan.codec) {
        .none => if (role != .outbound_result) try c.fail("callback parameters cannot have the void type", .{}),
        .converted => |converted| {
            if (role != .outbound_result) return c.fail("converted semantic values cannot be callback parameters", .{});
            const native = plans.plan(n, converted.converted_value);
            const converter = n.rawType(plan.type).converted.converter;
            const is_optional_brand_cast = converter.kind == .brand_cast and native.codec == .optional and
                plans.codecOf(n, native.codec.optional.child) == .branded_value;
            if (native.codec != .boolean and !is_optional_brand_cast)
                try c.fail("converted callback results require a boolean or an absent-on-mismatch brand cast", .{});
        },
        .optional => |optional| try callbackValueRules(c, optional.child, role),
        .dictionary => |fields| if (role != .outbound_result) for (fields) |field| try callbackValueRules(c, field, .outbound_argument),
        .union_type => |members| for (members) |member| try callbackValueRules(c, member, role),
        .sequence => |sequence| if (role != .outbound_result) try callbackValueRules(c, sequence.child, .outbound_argument),
        .record => |record| if (role != .outbound_result) {
            try callbackValueRules(c, record.key, .outbound_argument);
            try callbackValueRules(c, record.value, .outbound_argument);
        },
        .boolean, .discarded, .integer, .number, .js_value, .string, .callback, .enumeration, .utf8_string, .node_path, .buffer, .native_slice, .lazy, .external_ref, .class_ref, .branded_value, .native_instance, .nominal_handle => {},
    }
}

fn callbackResultRules(c: *Checker, id: InputPlanId) Error!void {
    switch (plans.plan(c.n, id).codec) {
        .optional => |optional| try callbackResultRules(c, optional.child),
        else => try callbackValueRules(c, id, .outbound_result),
    }
}

fn converterSignatures(c: *Checker) Error!void {
    var signatures: std.ArrayList(ir.CppConverterDeclaration) = .empty;
    inline for (std.enums.values(ir.Role)) |role| {
        for (c.n.rolePlans(role), 0..) |position, index| {
            if (position.representation != .converted) continue;
            const signature = mod_converter_declarations.signature(c.n, @as(role.PlanId(), .of(index))) orelse {
                c.location = c.n.projection(position.type).semantic;
                try c.fail("the custom converter requires C++ input and result types", .{});
                continue;
            };
            for (signatures.items) |previous| {
                if (structural.eql(signature, previous)) break;
                if (previous.input.index == signature.input.index and previous.realm_free == signature.realm_free and eqlText(previous.symbol, signature.symbol)) {
                    c.location = c.n.projection(position.type).semantic;
                    try c.fail("custom converter has conflicting declarations: {s}", .{signature.symbol});
                    break;
                }
            } else try signatures.append(c.n.arena, signature);
        }
    }
}

const ClassVisit = enum { pending, active, complete };

fn classDeclarationOrder(n: *Normalizer) Error![]const ir.ClassId {
    const visits = try n.arena.alloc(ClassVisit, n.classes.items.len);
    @memset(visits, .pending);
    var order: std.ArrayList(ir.ClassId) = .empty;
    for (n.classes.items) |class| try appendClassDeclaration(n, class.id, visits, &order);
    return order.items;
}

fn appendClassDeclaration(n: *Normalizer, id: ir.ClassId, visits: []ClassVisit, order: *std.ArrayList(ir.ClassId)) Error!void {
    const class = n.get(id);
    switch (visits[id.index]) {
        .complete => return,
        .active => return n.reject(try n.print("{s}.{s}", .{ class.module_name, class.class_name }), "class inheritance contains a cycle", .{}),
        .pending => {},
    }
    visits[id.index] = .active;
    if (class.parent) |parent| try appendClassDeclaration(n, parent, visits, order);
    visits[id.index] = .complete;
    try order.append(n.arena, id);
}

fn internalRegistryRules(c: *Checker) Error!void {
    const n = c.n;
    for (n.types.items[0..n.binding_type_count]) |t| {
        if (t.data != .enumeration or n.get(t.data.enumeration).header != .internal_modules) continue;
        const raw = n.rawType(t.id).enumeration;
        c.location = raw.name;
        for (raw.values, 0..) |value, index| switch (value.options.internal_module.?) {
            .javascript => |path| for (raw.values[0..index]) |previous| switch (previous.options.internal_module.?) {
                .javascript => |other| if (eqlText(path[0 .. path.len - 3], other[0 .. other.len - 3]))
                    try c.fail("internal module sources share a bundle output: {s}.js", .{path[0 .. path.len - 3]}),
                .native => {},
            },
            .native => {
                for (n.native_module_surfaces.items) |surface| {
                    if (surface.exposed and eqlText(surface.specifier, value.value)) break;
                } else try c.fail("internal registry entry has no exposed native module surface: {s}", .{value.value});
            },
        };
        for (n.native_module_surfaces.items) |surface| {
            if (!surface.exposed) continue;
            for (raw.values) |value| {
                if (value.options.internal_module.? == .native and eqlText(value.value, surface.specifier)) break;
            } else try c.fail("native module surface is absent from the internal registry: {s}", .{surface.specifier});
        }
    }
}

fn nonThrowingNativeParameter(c: *Checker, id: ir.InboundArgumentPlanId) Error!void {
    switch (cpp_facts.nativeParameter(c.n, id)) {
        .javascript => switch (plans.plan(c.n, c.n.get(id).input).codec) {
            .converted => try c.fail("converted native export arguments require JavaScript exception propagation", .{}),
            .string => try c.fail("coercing string native export arguments require JavaScript exception propagation", .{}),
            else => {},
        },
        .optional => |child| try nonThrowingNativeParameter(c, child),
        .lazy => try c.fail("lazy native export arguments require JavaScript exception propagation", .{}),
        .encode => {},
    }
}
