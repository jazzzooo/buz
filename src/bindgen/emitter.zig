//! Renders every binding artifact from the normalized IR. Rendering happens
//! entirely in memory so a failure leaves no artifact behind.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ir = @import("bindgen_ir");
const structural = @import("structural.zig");
const value_encoding = @import("value_encoding.zig");

pub const Error = Writer.Error || Allocator.Error;

fn indented(writer: *Writer, indentation: usize) IndentedWriter {
    return .{ .writer = writer, .indentation = indentation };
}

const IndentedWriter = struct {
    writer: *Writer,
    indentation: usize,

    fn print(w: IndentedWriter, comptime format: []const u8, args: anytype) Writer.Error!void {
        try w.writer.splatByteAll(' ', w.indentation);
        try w.writer.print(format, args);
    }

    fn writeAll(w: IndentedWriter, text: []const u8) Writer.Error!void {
        try w.writer.splatByteAll(' ', w.indentation);
        try w.writer.writeAll(text);
    }
};

pub const Group = enum { headers, wire, typescript, cpp };

pub const File = struct {
    group: Group,
    name: []const u8,
    data: []const u8,
};

pub const Emitter = struct {
    ir: *const ir.Ir,
    arena: Allocator,
    fingerprint: u64,
    cpp_shard_count: u32,
    fingerprint_symbol: []const u8 = "",
    cpp_shards: []const u32 = &.{},
    property_key_indexes: std.StringHashMapUnmanaged(u32) = .empty,
    enumeration_string_indexes: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn print(e: *Emitter, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(e.arena, format, args);
    }

    fn codecIds(e: *const Emitter, comptime Id: type) Allocator.Error![]const Id {
        var result: std.ArrayList(Id) = .empty;
        for (e.ir.rolePlans(Id.role), 0..) |plan, position| {
            for (@field(plan.cpp, Id.cpp_field), 0..) |_, index| try result.append(e.arena, .{ .position = .of(position), .index = @intCast(index) });
        }
        return result.items;
    }

    fn function(e: *const Emitter, id: ir.FunctionId) *const ir.Function {
        return &e.ir.functions[id.index];
    }

    fn class(e: *const Emitter, id: ir.ClassId) *const ir.Class {
        return &e.ir.classes[id.index];
    }

    fn engineShim(e: *const Emitter, id: ir.EngineShimId) *const ir.EngineShim {
        return &e.ir.engine_shims[id.index];
    }

    fn nativeExport(e: *const Emitter, id: ir.NativeExportId) *const ir.NativeExport {
        return &e.ir.native_exports[id.index];
    }

    fn objectSurface(e: *const Emitter, id: ir.ObjectSurfaceId) *const ir.ObjectSurface {
        return &e.ir.object_surfaces[id.index];
    }

    fn wireSpelling(e: *const Emitter, id: ir.WireTypeId) Allocator.Error![]const u8 {
        return renderWireType(e.ir, e.arena, id);
    }

    fn cppType(e: *Emitter, id: ir.CppTypeId) Allocator.Error![]const u8 {
        return switch (e.ir.get(id).*) {
            .builtin => |builtin| switch (builtin) {
                .strict_boolean => "Bun::IDLStrictBoolean",
                .unrestricted_double => "WebCore::IDLUnrestrictedDouble",
                .strict_double => "Bun::IDLStrictDouble",
                .to_length => "Bun::BindgenToLength",
                .integer_or_infinity => "Bun::IDLIntegerOrInfinity",
                .webidl_i8 => "WebCore::IDLByte",
                .webidl_u8 => "WebCore::IDLOctet",
                .webidl_i16 => "WebCore::IDLShort",
                .webidl_u16 => "WebCore::IDLUnsignedShort",
                .webidl_i32 => "WebCore::IDLLong",
                .webidl_u32 => "WebCore::IDLUnsignedLong",
                .webidl_i64 => "WebCore::IDLLongLong",
                .webidl_u64 => "WebCore::IDLUnsignedLongLong",
                .webidl_dom_string => "WebCore::IDLDOMString",
                .webidl_usv_string => "WebCore::IDLUSVString",
                .webidl_byte_string => "WebCore::IDLByteString",
                .strict_dom_string => "Bun::IDLStrictString",
                .strict_usv_string => "Bun::IDLStrictUSVString",
                .strict_byte_string => "Bun::IDLStrictByteString",
            },
            .template => |template| e.print("{s}<{s}>", .{ switch (template.name) {
                .strict_boolean => "Bun::BindgenStrictBoolean",
                .node_property_boolean => "Bun::BindgenNodePropertyBoolean",
                .number_integer_range => "Bun::BindgenNumberIntegerRange",
                .coerced_integer_default => "Bun::BindgenCoercedIntegerDefault",
                .modulo_integer => "Bun::BindgenModuloInteger",
                .strict_integer => "Bun::IDLStrictInteger",
                .number_or_bigint_range => "Bun::BindgenNumberOrBigIntIntegerRange",
                .bigint_integer => "Bun::IDLBigIntInteger",
                .bigint_range => "Bun::BindgenBigIntIntegerRange",
                .number_integer => "Bun::BindgenNumberInteger",
                .loose_integer => "Bun::IDLLooseInteger",
                .coerced_saturated_integer => "Bun::IDLToInt32Saturated",
                .saturated_integer => "Bun::BindgenSaturatedInteger",
                .truncated_integer_clamp => "Bun::BindgenTruncatedIntegerClamp",
                .saturated_integer_range => "Bun::BindgenSaturatedIntegerRange",
                .bounded_integer => "Bun::BindgenBoundedInteger",
                .integer_enforce_range => "Bun::BindgenIntegerEnforceRange",
                .webidl_clamp => "WebCore::IDLClampAdaptor",
                .node_integer_diagnostic => "Bun::BindgenNodeIntegerDiagnostic",
                .matching_integer => "Bun::BindgenMatchingInteger",
                .clamped_number => "Bun::BindgenClampedNumber",
                .number_enforce_range => "Bun::BindgenNumberEnforceRange",
                .normalized_integer => "Bun::BindgenNormalizedInteger",
                .truncated_clamped_number => "Bun::BindgenTruncatedClampedNumber",
                .wrapped_clamped_number => "Bun::BindgenWrappedClampedNumber",
                .number_range => "Bun::BindgenNumberRange",
            }, try e.cppTemplateArguments(template.arguments) }),
            .conversion_failure => |failure| cppConversionFailure(e, failure),
            .void => "void",
            .int => "int",
            .scalar => |kind| switch (kind) {
                .boolean, .discarded => "bool",
                .i8 => "int8_t",
                .u8 => "uint8_t",
                .i16 => "int16_t",
                .u16 => "uint16_t",
                .i32 => "int32_t",
                .u32 => "uint32_t",
                .i64 => "int64_t",
                .u64, .usize => "uint64_t",
                .f64 => "double",
            },
            .any => "Bun::Bindgen::CppAny",
            .js_value => "JSC::JSValue",
            .encoded_js_value => "JSC::EncodedJSValue",
            .js_object => "JSC::JSObject",
            .size => "size_t",
            .monostate => "std::monostate",
            .any_sequence => "Bun::Bindgen::CppAnySequenceView",
            .wire => |wire| e.wireSpelling(wire),
            .wrapper_class => |class_id| e.print("Bun::{s}", .{e.class(class_id).cpp_class_name}),
            .string => "WTF::String",
            .bytes => "Bun::Bindgen::CppBytes",
            .scoped_bytes => |access| switch (access) {
                .read_only => "Bun::Bindgen::CppScopedBytes",
                .read_write => "Bun::Bindgen::CppScopedMutableBytes",
            },
            .named => |name| switch (name.namespace) {
                .global => name.name,
                .binding => e.print("Bun::Bindgen::{s}", .{name.name}),
                .engine => e.print("Bun::Bindgen::Engine::{s}", .{name.name}),
            },
            .external_implementation => |idl| e.print("typename {s}::ImplementationType", .{try e.cppType(idl)}),
            .native_class => |class_id| e.print("{s}_Native", .{e.class(class_id).cpp_class_name}),
            inline .pointer, .const_pointer, .const_reference, .const_span, .span, .optional, .allocation_result, .vector, .lazy_argument, .result_sequence => |child, tag| e.print(switch (tag) {
                .pointer => "{s}*",
                .const_pointer => "{s} const*",
                .const_reference => "{s} const&",
                .const_span => "std::span<{s} const>",
                .span => "std::span<{s}>",
                .optional => "std::optional<{s}>",
                .allocation_result => "Bun::Bindgen::NativeAllocationResult<{s}>",
                .vector => "WTF::Vector<{s}>",
                .lazy_argument => "Bun::Bindgen::CppLazyArgument<{s}>",
                .result_sequence => "CppResultSequence<{s}>",
                else => unreachable,
            }, .{try e.cppType(child)}),
            .pair => |pair| e.print("std::pair<{s}, {s}>", .{ try e.cppType(pair.key), try e.cppType(pair.value) }),
            .function_pointer => |signature| e.print("{s}{s} (*)({s})", .{ if (signature.convention == .host) "SYSV_ABI " else "", try e.cppType(signature.result), try e.cppTypeList(signature.parameters) }),
            .specialization => |specialization| e.print("{s}<{s}>", .{ specialization.name, try e.cppTypeList(specialization.arguments) }),
        };
    }

    fn cppTemplateArguments(e: *Emitter, values: []const ir.CppTemplateArgument) Allocator.Error![]const u8 {
        const arguments = try e.arena.alloc([]const u8, values.len);
        for (values, arguments) |value, *argument| argument.* = switch (value) {
            .type => |id| try e.cppType(id),
            .wire => |id| try e.wireSpelling(id),
            .boolean => |flag| cppBoolean(flag),
            .integer => |integer| try cppIntegerLiteral(e, integer),
            .double_bits => |number| try e.print("0x{x:0>16}ULL", .{cppDoubleBits(number)}),
            .string => |text| try cppByteStringLiteral(e, text),
            .error_code => |name| try e.print("Bun::ErrorCode::{s}", .{name}),
            .integer_rejection => |rejection| switch (rejection) {
                .safe_integer => "Bun::BindgenIntegerRejection::SafeInteger",
                .property_value => "Bun::BindgenIntegerRejection::PropertyValue",
                .port => "Bun::BindgenIntegerRejection::Port",
            },
            .number_range_error => |kind| switch (kind) {
                .out_of_range => "Bun::BindgenNumberRangeError::OutOfRange",
                .invalid_value => "Bun::BindgenNumberRangeError::InvalidValue",
            },
        };
        return std.mem.join(e.arena, ", ", arguments);
    }

    fn cppTypeList(e: *Emitter, ids: []const ir.CppTypeId) Allocator.Error![]const u8 {
        const types = try e.arena.alloc([]const u8, ids.len);
        for (ids, types) |id, *value| value.* = try e.cppType(id);
        return std.mem.join(e.arena, ", ", types);
    }
};

pub fn renderWireType(binding: *const ir.Ir, arena: Allocator, id: ir.WireTypeId) Allocator.Error![]const u8 {
    return switch (binding.get(id).*) {
        .scalar => |scalar| @tagName(scalar),
        .pointer => |pointer| blk: {
            const child = try renderWireType(binding, arena, pointer.child);
            break :blk if (pointer.is_const and binding.get(pointer.child).* != .pointer)
                try std.fmt.allocPrint(arena, "const {s}*", .{child})
            else
                try std.fmt.allocPrint(arena, "{s}{s}*", .{ child, if (pointer.is_const) " const" else "" });
        },
        .opaque_handle, .forward_structure => |name| name.alloc(arena),
        inline .alias, .structure, .@"union", .function_pointer, .function => |declaration| declaration.name.alloc(arena),
    };
}

/// Renders every artifact for one target.
pub fn emitAll(e: *Emitter) Error![]const File {
    const symbol = ir.fingerprintSymbol(e.fingerprint);
    e.fingerprint_symbol = try e.arena.dupe(u8, &symbol);
    e.cpp_shards = try assignCppShards(e);
    for (e.ir.interned_property_keys, 0..) |key, index| try e.property_key_indexes.put(e.arena, key, @intCast(index));
    for (e.ir.enumeration_strings, 0..) |value, index| try e.enumeration_string_indexes.put(e.arena, value, @intCast(index));
    var files: std.ArrayList(File) = .empty;
    const headers = [_]struct { []const u8, *const fn (*Emitter, *Writer) Error!void }{
        .{ "SchemaBindings.h", emitCppHeader },
        .{ "SchemaBindingsEnumerations.h", emitCppEnumerationsHeader },
        .{ "SchemaBindingsConverters.h", emitCppConvertersHeader },
        .{ "SchemaBindingsPromiseReactionHandlers.inc", emitPromiseReactionHandlers },
    };
    for (headers) |entry| try files.append(e.arena, try render(e, .headers, entry[0], entry[1]));
    for (e.ir.standalone_native_export_header_plans) |*header_plan| {
        var contents: Writer.Allocating = .init(e.arena);
        try emitStandaloneNativeExportHeader(e, &contents.writer, header_plan);
        try files.append(e.arena, .{
            .group = .headers,
            .name = try e.print("SchemaBindings+{s}.h", .{header_plan.header}),
            .data = contents.written(),
        });
    }
    const late_headers = [_]struct { []const u8, *const fn (*Emitter, *Writer) Error!void }{
        .{ "SchemaBindingsEngineClasses.h", emitCppEngineClassesHeader },
        .{ "ObjectSurfaces.h", emitObjectSurfacesHeader },
        .{ "SchemaBindings+lazyStructureHeader.h", emitLazyStructureHeader },
        .{ "SchemaBindings+lazyStructureImpl.h", emitLazyStructureImpl },
        .{ "SchemaBindings+DOMClientIsoSubspaces.h", emitClientIsoSubspaces },
        .{ "SchemaBindings+DOMIsoSubspaces.h", emitIsoSubspaces },
    };
    for (late_headers) |entry| try files.append(e.arena, try render(e, .headers, entry[0], entry[1]));
    const wire = [_]struct { []const u8, *const fn (*Emitter, *Writer) Error!void }{
        .{ "SchemaBindingsWire.h", emitWireHeader },
        .{ "SchemaWireLayout.cpp", emitWireLayoutTable },
        .{ "SchemaBindingsLinkMetadata.json", emitLinkMetadata },
        .{ "SchemaBindingsErrorCodes.h", emitErrorCodeCatalog },
        .{ "NativeModuleRegistry.h", emitNativeModuleRegistryHeader },
        .{ "NativeModuleRegistry.cpp", emitNativeModuleRegistrySource },
        .{ "SchemaBindingsModuleRegistry.h", emitInternalModuleRegistryHeader },
        .{ "InternalModuleRegistry+createInternalModuleById.h", emitInternalModuleRegistryCreation },
        .{ "SchemaBindingsIdentifiers.cpp", emitIdentifierTableSource },
        .{ "NativeModuleManifest.json", emitNativeModuleManifest },
        .{ "SchemaBindingsWireTypes.h", emitWireTypes },
    };
    for (wire) |entry| try files.append(e.arena, try render(e, .wire, entry[0], entry[1]));
    try files.append(e.arena, try render(e, .typescript, "SchemaBindings.d.ts", emitTypeScript));
    for (0..e.cpp_shard_count) |shard| {
        var contents: Writer.Allocating = .init(e.arena);
        try emitCppSource(e, &contents.writer, @intCast(shard));
        try files.append(e.arena, .{
            .group = .cpp,
            .name = try e.print("SchemaBindings{d}.cpp", .{shard}),
            .data = contents.written(),
        });
    }
    return files.items;
}

fn render(e: *Emitter, group: Group, name: []const u8, emit: *const fn (*Emitter, *Writer) Error!void) Error!File {
    var contents: Writer.Allocating = .init(e.arena);
    try emit(e, &contents.writer);
    return .{ .group = group, .name = name, .data = contents.written() };
}

fn emitCppExternC(writer: *Writer, comptime signature: []const u8, comptime body: []const u8, args: anytype) Error!void {
    try writer.print("extern \"C\" " ++ signature ++ " noexcept\n" ++ body, args);
}

fn emitCppResultCommit(writer: *Writer, release_wire: bool, statement: []const u8, indent: usize) Error!void {
    if (release_wire) {
        try indented(writer, indent).writeAll("resultGuard.release();\n");
    }
    try indented(writer, indent).writeAll(statement);
    try writer.writeByte('\n');
}

// ─── literals and paths ───

fn emitCppRawStringLiteral(writer: *Writer, value: []const u8) Error!void {
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte >= 0x20 and byte <= 0x7e and byte != '\\' and byte != '"') {
            try writer.writeByte(byte);
        } else {
            try writer.print("\\{o:0>3}", .{byte});
        }
    }
    try writer.writeByte('"');
}

const CppRelativePath = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

/// A fixed diagnostic path or a path relative to its semantic converter.
const CppPath = union(enum) {
    literal: []const u8,
    template_path: struct { owner: *CppConverterPaths, relative: CppRelativePath },
};

const CppIndexedStringPath = struct {
    root: []const u8,
    index: []const u8,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

const CppConverterPaths = struct {
    const Child = struct { converter: ir.CppInputAggregateId, path: CppRelativePath };
    errors: structural.OrderedMap(CppRelativePath, void) = .empty,
    children: structural.OrderedMap(Child, void) = .empty,

    fn errorIndex(paths: *CppConverterPaths, arena: Allocator, path: CppRelativePath) Allocator.Error!usize {
        return (try paths.errors.getOrPut(arena, path)).index;
    }

    fn childIndex(paths: *CppConverterPaths, arena: Allocator, converter: ir.CppInputAggregateId, path: CppRelativePath) Allocator.Error!usize {
        return (try paths.children.getOrPut(arena, .{ .converter = converter, .path = path })).index;
    }

    fn emit(paths: *const CppConverterPaths, e: *Emitter, writer: *Writer) Error!void {
        try writer.writeAll("    struct Paths : BindingConversionPaths {\n");
        for (paths.errors.keys(), 0..) |_, index| {
            try writer.print("        WTF::ASCIILiteral error_{d};\n", .{index});
        }
        for (paths.children.keys(), 0..) |child, index| {
            try writer.print("        const {s}::Paths* child_{d};\n", .{ try cppSemanticConverterName(e, child.converter), index });
        }
        try writer.writeAll(
            \\    };
            \\    template<BindingFixedString RootPath, BindingFixedString PathPrefix = "", BindingFixedString PathLeading = "">
            \\    struct PathConstants {
            \\        inline static constexpr Paths value {
            \\
        );
        for (paths.errors.keys(), 0..) |path, index| {
            try writer.print("            .error_{d} = bindingPath<", .{index});
            try emitCppRawStringLiteral(writer, path.prefix);
            try writer.writeAll(", PathLeading, RootPath, PathPrefix, ");
            try emitCppRawStringLiteral(writer, path.suffix);
            try writer.writeAll(">(),\n");
        }
        for (paths.children.keys(), 0..) |child, index| {
            try writer.print("            .child_{d} = &{s}::PathConstants<RootPath, concatenateBindingStrings<PathPrefix, ", .{ index, try cppSemanticConverterName(e, child.converter) });
            try emitCppRawStringLiteral(writer, child.path.suffix);
            try writer.writeAll(">(), concatenateBindingStrings<");
            try emitCppRawStringLiteral(writer, child.path.prefix);
            try writer.writeAll(", PathLeading>()>::value,\n");
        }
        try writer.writeAll("        };\n    };\n\n");
    }
};

fn cppPath(value: []const u8) CppPath {
    return .{ .literal = value };
}

fn CppPathAffix(comptime prepend: bool) type {
    return struct {
        fn apply(e: *Emitter, value: anytype, affix: []const u8) Allocator.Error!@TypeOf(value) {
            var result = value;
            const component = comptime if (prepend) "prefix" else "suffix";
            const text = if (@TypeOf(value) == CppIndexedStringPath)
                &@field(result, component)
            else switch (result) {
                .literal => |*literal| literal,
                .template_path => |*path| &@field(path.relative, component),
            };
            text.* = try e.print("{s}{s}", if (prepend) .{ affix, text.* } else .{ text.*, affix });
            return result;
        }
    };
}

const cppPathAppend = CppPathAffix(false).apply;
const cppPathPrepend = CppPathAffix(true).apply;

fn cppDictionaryFieldPath(e: *Emitter, root: CppPath, path: ir.CppFieldPath) Allocator.Error!CppPath {
    return switch (path) {
        .absolute => |absolute| cppPath(absolute),
        .suffix => |suffix| cppPathAppend(e, root, suffix),
    };
}

fn emitCppPath(e: *Emitter, writer: *Writer, value: anytype) Error!void {
    if (@TypeOf(value) == CppIndexedStringPath) {
        try writer.writeAll("WTF::makeString(");
        try emitCppAsciiLiteral(writer, try e.print("{s}{s}[", .{ value.prefix, value.root }));
        try writer.print(", {s}, ", .{value.index});
        try emitCppAsciiLiteral(writer, try e.print("]{s}", .{value.suffix}));
        try writer.writeByte(')');
        return;
    }
    switch (value) {
        .literal => |literal| try emitCppAsciiLiteral(writer, literal),
        .template_path => |path| try writer.print("m_paths->error_{d}", .{try path.owner.errorIndex(e.arena, path.relative)}),
    }
}

fn emitCppConverterPaths(e: *Emitter, writer: *Writer, id: ir.CppInputAggregateId, value: CppPath) Error!void {
    switch (value) {
        .literal => |literal| {
            try writer.print("Bun::Bindgen::{s}::PathConstants<", .{try cppSemanticConverterName(e, id)});
            try emitCppRawStringLiteral(writer, literal);
            try writer.writeAll(">::value");
        },
        .template_path => |path| {
            const index = try path.owner.childIndex(e.arena, id, path.relative);
            try writer.print("*m_paths->child_{d}", .{index});
        },
    }
}

// ─── registries ───

fn emitPromiseReactionHandlers(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.functions) |*function| {
        if (!function.exposed or !function.is_promise_reaction_handler) continue;
        try writer.print("BUN_BINDGEN_PROMISE_REACTION_HANDLER({s})\n", .{function.host_symbol});
    }
}

fn emitNativeModuleRegistryHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#include <JavaScriptCore/Identifier.h>
        \\#include <JavaScriptCore/JSGlobalObject.h>
        \\#include <JavaScriptCore/ArgList.h>
        \\#include <wtf/Vector.h>
        \\#include <wtf/text/WTFString.h>
        \\
        \\namespace Bun::Bindgen {
        \\using NativeModuleGenerator = void (*)(JSC::JSGlobalObject*, JSC::Identifier, WTF::Vector<JSC::Identifier, 4>&, JSC::MarkedArgumentBuffer&);
        \\NativeModuleGenerator findNativeModuleGenerator(const WTF::String&) noexcept;
        \\
    );
    for (e.ir.native_module_surfaces) |surface| {
        if (!surface.exposed) continue;
        try writer.print("void generateNativeModule_{s}(JSC::JSGlobalObject*, JSC::Identifier, WTF::Vector<JSC::Identifier, 4>&, JSC::MarkedArgumentBuffer&);\n", .{surface.surface_name});
    }
    try writer.writeAll("}\n");
}

fn emitInternalModuleRegistryHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll("#pragma once\n#include <cstddef>\n#include <cstdint>\nnamespace Bun::Bindgen {\n");
    if (e.ir.internal_module_registry) |registry| {
        const enumeration = e.ir.get(registry.enumeration);
        try emitCppEnumerationDeclaration(e, writer, registry.enumeration);
        try writer.print("inline constexpr size_t internalModuleCount = {d};\n", .{registry.modules.len});
        try writer.print("inline constexpr bool internalModuleUsesObjectDefault({s} id) noexcept {{\n    switch (id) {{\n", .{enumeration.cpp_name});
        for (registry.modules) |entry| {
            if (entry.default_export == .module_object) try writer.print("    case {s}::{s}: return true;\n", .{ enumeration.cpp_name, entry.name });
        }
        try writer.writeAll("    default: return false;\n    }\n}\n");
    }
    try writer.writeAll("}\n");
}

fn emitInternalModuleRegistryCreation(e: *Emitter, writer: *Writer) Error!void {
    const registry = e.ir.internal_module_registry orelse return;
    try writer.writeAll("JSC::JSValue InternalModuleRegistry::createInternalModuleById(JSC::JSGlobalObject* globalObject, JSC::VM& vm, Field id)\n{\n    switch (id) {\n");
    for (registry.modules) |entry| {
        try writer.print("    case Field::{s}:\n", .{entry.name});
        switch (entry.source) {
            .native => |surface| try writer.print("        return generateNativeModule(globalObject, vm, Bindgen::generateNativeModule_{s});\n", .{e.ir.get(surface).surface_name}),
            .javascript => |javascript| {
                try writer.writeAll("        INTERNAL_MODULE_REGISTRY_GENERATE(globalObject, vm, ");
                try emitCppUtf8String(writer, entry.specifier);
                try writer.writeAll(", ");
                try emitCppUtf8String(writer, javascript.bundle_path);
                try writer.print(", InternalModuleRegistryConstants::{s}Code, ", .{entry.name});
                try emitCppUtf8String(writer, javascript.url);
                try writer.writeAll(");\n");
            },
        }
    }
    try writer.writeAll("    }\n    RELEASE_ASSERT_NOT_REACHED();\n}\n");
}

fn emitIdentifierTableSource(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#include "root.h"
        \\#include "SchemaBindings.h"
        \\
        \\namespace Bun::Bindgen {
        \\
        \\IdentifierTable::IdentifierTable(JSC::VM& vm)
        \\    : m_values {
        \\
    );
    for (e.ir.interned_property_keys) |key| {
        try writer.writeAll("        JSC::Identifier::fromString(vm, ");
        try emitCppUtf8String(writer, key);
        try writer.writeAll("),\n");
    }
    try writer.writeAll(
        \\    }
        \\{
        \\}
        \\
        \\JSC::JSString* IdentifierTable::enumerationString(JSC::VM& vm, size_t index)
        \\{
        \\    RELEASE_ASSERT(index < m_enumerationStrings.size());
        \\    auto& value = m_enumerationStrings[index];
        \\    if (value)
        \\        return value.get();
        \\    switch (index) {
        \\
    );
    for (e.ir.enumeration_strings, 0..) |value, index| {
        try writer.print("    case {d}: value.set(vm, JSC::jsString(vm, ", .{index});
        try emitCppUtf8String(writer, value);
        try writer.writeAll(")); break;\n");
    }
    try writer.writeAll(
        \\    default: RELEASE_ASSERT_NOT_REACHED();
        \\    }
        \\    return value.get();
        \\}
        \\
        \\}
        \\
    );
}

fn emitNativeModuleRegistrySource(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#include "root.h"
        \\#include "NativeModuleRegistry.h"
        \\#include "SchemaBindings.h"
        \\#include "ZigGlobalObject.h"
        \\#include <JavaScriptCore/CustomGetterSetter.h>
        \\#include <JavaScriptCore/JSCInlines.h>
        \\#include <JavaScriptCore/ObjectConstructor.h>
        \\
    );
    for (e.ir.native_module_headers) |header| try writer.print("#include \"{s}\"\n", .{header});
    try writer.writeAll(
        \\
        \\namespace Bun::Bindgen {
        \\using namespace JSC;
        \\using namespace WTF;
        \\
    );
    for (e.ir.object_surfaces) |surface| {
        if (!e.ir.object_surface_plans[surface.id.index].owned_by_native_modules) continue;
        try writer.print(
            "#define BUN_BINDGEN_OBJECT_SURFACE_{s}\n#include \"ObjectSurfaces.h\"\n#undef BUN_BINDGEN_OBJECT_SURFACE_{s}\n\n",
            .{ surface.surface_name, surface.surface_name },
        );
    }
    for (e.ir.native_module_surfaces) |*surface| {
        if (!surface.exposed) continue;
        try emitNativeModuleGenerator(e, writer, surface);
    }
    try writer.writeAll(
        \\NativeModuleGenerator findNativeModuleGenerator(const WTF::String& specifier) noexcept
        \\{
        \\
    );
    for (e.ir.native_module_surfaces) |surface| {
        if (!surface.exposed) continue;
        try writer.writeAll("    if (specifier == ");
        try emitCppAsciiLiteral(writer, surface.specifier);
        try writer.print(") return generateNativeModule_{s};\n", .{surface.surface_name});
    }
    try writer.writeAll(
        \\    return nullptr;
        \\}
        \\
        \\}
        \\
    );
}

// ─── native modules ───

fn emitNativeModuleGenerator(e: *Emitter, writer: *Writer, surface: *const ir.NativeModuleSurface) Error!void {
    const name = surface.surface_name;
    try writer.print("static constexpr unsigned nativeModuleNamedExportCount_{s} = {d};\n\n", .{ name, surface.named_export_count });
    try writer.print(
        \\void generateNativeModule_{s}(
        \\    JSC::JSGlobalObject* lexicalGlobalObject,
        \\    JSC::Identifier moduleKey,
        \\    WTF::Vector<JSC::Identifier, 4>& exportNames,
        \\    JSC::MarkedArgumentBuffer& exportValues)
        \\{{
        \\    (void)moduleKey;
        \\    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
        \\    auto& vm = globalObject->vm();
        \\    auto scope = DECLARE_THROW_SCOPE(vm);
        \\    exportNames.reserveCapacity(nativeModuleNamedExportCount_{s} + 1);
        \\    exportValues.ensureCapacity(nativeModuleNamedExportCount_{s} + 1);
        \\    JSC::JSValue defaultValue;
        \\
    , .{ name, name, name });
    switch (surface.default) {
        .namespace => {
            try writer.print(
                "    auto* defaultObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), nativeModuleNamedExportCount_{s} < JSC::JSFinalObject::maxInlineCapacity ? nativeModuleNamedExportCount_{s} : JSC::JSFinalObject::maxInlineCapacity);\n" ++
                    "    defaultValue = defaultObject;\n",
                .{ name, name },
            );
        },
        .declaration => |declaration| {
            try writer.writeAll("    defaultValue = ");
            try emitCppSurfaceValue(e, writer, declaration.value, "defaultObject", "globalObject");
            try writer.writeAll(";\n");
            if (declaration.installation) |installation| {
                try writer.writeAll(
                    "    auto* defaultObject = defaultValue.getObject();\n" ++
                        "    RELEASE_ASSERT(defaultObject);\n",
                );
                if (installation.self_property) |attributes| {
                    try writer.writeAll("    defaultObject->putDirect(vm, vm.propertyNames->defaultKeyword, defaultValue, ");
                    try emitSurfaceAttributes(writer, attributes, false);
                    try writer.writeAll(");\n");
                }
            }
        },
    }
    try writer.writeAll(
        "    exportNames.append(vm.propertyNames->defaultKeyword);\n" ++
            "    exportValues.append(defaultValue);\n",
    );
    for (surface.exports, 0..) |*module_export, export_index| {
        if (!module_export.exposed) continue;
        try emitNativeModuleNamedExport(e, writer, module_export, export_index);
    }
    try writer.writeAll("}\n\n");
}

fn emitNativeModuleNamedExport(
    e: *Emitter,
    writer: *Writer,
    module_export: *const ir.NativeModuleExport,
    export_index: usize,
) Error!void {
    try writer.writeAll("    {\n        auto name = ");
    try emitCppInternedPropertyKey(e, writer, module_export.export_name, "vm");
    try writer.writeAll(";\n        JSC::JSValue value;\n");
    try emitNativeModuleSurfaceMemberValue(e, writer, module_export.operation, export_index, "value", 8);
    try emitNativeModuleDefaultProperty(writer, module_export, export_index, "name", "value", module_export.attributes);
    try writer.writeAll(
        "        exportNames.append(name);\n" ++
            "        exportValues.append(value);\n",
    );
    for (module_export.aliases) |alias| {
        try writer.writeAll("        {\n            auto aliasName = ");
        try emitCppInternedPropertyKey(e, writer, alias.name, "vm");
        try writer.writeAll(";\n");
        try emitNativeModuleDefaultProperty(writer, module_export, export_index, "aliasName", "value", alias.attributes);
        try writer.writeAll(
            "            exportNames.append(aliasName);\n" ++
                "            exportValues.append(value);\n" ++
                "        }\n",
        );
    }
    try writer.writeAll("    }\n");
}

fn emitNativeModuleDefaultProperty(
    writer: *Writer,
    module_export: *const ir.NativeModuleExport,
    export_index: usize,
    name_variable: []const u8,
    value_variable: []const u8,
    attributes: ir.SurfacePropertyAttributes,
) Error!void {
    switch (module_export.operation) {
        .accessor => |accessor| {
            try writer.print("        defaultObject->putDirectAccessor(globalObject, {s}, JSC::GetterSetter::create(vm, globalObject, nativeModuleGetter_{d}, ", .{ name_variable, export_index });
            switch (accessor.setter) {
                .none => try writer.writeAll("nullptr"),
                .getter => try writer.print("nativeModuleGetter_{d}", .{export_index}),
                .function => try writer.print("nativeModuleSetter_{d}", .{export_index}),
            }
            try writer.writeAll("), ");
            try emitSurfaceAttributes(writer, attributes, true);
        },
        .value => {
            try writer.print("        defaultObject->putDirect(vm, {s}, {s}, ", .{ name_variable, value_variable });
            try emitSurfaceAttributes(writer, attributes, false);
        },
    }
    try writer.writeAll(");\n");
}

fn emitNativeModuleSurfaceMemberValue(e: *Emitter, writer: *Writer, operation: ir.CppNativeModuleValue, export_index: usize, target: []const u8, indent: usize) Error!void {
    switch (operation) {
        .value => |value| {
            try indented(writer, indent).print("{s} = ", .{target});
            try emitCppSurfaceValue(e, writer, value, "defaultObject", "globalObject");
            try writer.writeAll(";\n");
        },
        .accessor => |accessor| {
            try emitSurfaceAccessorDeclarations(e, writer, accessor, "nativeModule", export_index, "globalObject", indent);
            try indented(writer, indent).print("JSC::MarkedArgumentBuffer nativeModuleAccessorArguments_{d};\n", .{export_index});
            try indented(writer, indent).print("{s} = JSC::profiledCall(globalObject, JSC::ProfilingReason::API, nativeModuleGetter_{d}, JSC::getCallData(nativeModuleGetter_{d}), defaultObject, nativeModuleAccessorArguments_{d});\n", .{ target, export_index, export_index, export_index });
        },
    }
    try indented(writer, indent).writeAll("RETURN_IF_EXCEPTION(scope, void());\n");
}

fn objectSurfaceTableName(e: *Emitter, surface: *const ir.ObjectSurface) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}TableValues", .{surface.surface_name});
}

fn objectSurfaceHashTableName(e: *Emitter, surface: *const ir.ObjectSurface) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}Table", .{surface.surface_name});
}

fn objectSurfaceHashIndexName(e: *Emitter, surface: *const ir.ObjectSurface) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}TableIndex", .{surface.surface_name});
}

fn objectSurfaceCallbackName(e: *Emitter, surface: *const ir.ObjectSurface, member_index: usize) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}_member_{d}", .{ surface.surface_name, member_index });
}

fn objectSurfaceCallbackBodyName(e: *Emitter, surface: *const ir.ObjectSurface, member_index: usize) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}_member_{d}_body", .{ surface.surface_name, member_index });
}

fn objectSurfaceInstallName(e: *Emitter, surface: *const ir.ObjectSurface) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}_install", .{surface.surface_name});
}

fn objectSurfaceCreateName(e: *Emitter, surface: *const ir.ObjectSurface) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}_create", .{surface.surface_name});
}

fn objectSurfaceNativeAccessorName(e: *Emitter, surface: *const ir.ObjectSurface, accessor: []const u8) Allocator.Error![]const u8 {
    return e.print("bunBindgenObjectSurface_{s}_{s}", .{ surface.surface_name, accessor });
}

fn emitCppPropertyAttributes(writer: *Writer, attributes: anytype, base: ?[]const u8) Error!void {
    var wrote = false;
    if (base) |flag| {
        try writer.print("JSC::PropertyAttribute::{s}", .{flag});
        wrote = true;
    }
    inline for (.{
        .{ if (@hasField(@TypeOf(attributes), "read_only")) attributes.read_only else !attributes.writable, "ReadOnly" },
        .{ if (@hasField(@TypeOf(attributes), "dom_attribute")) attributes.dom_attribute else false, "DOMAttribute" },
        .{ !attributes.enumerable, "DontEnum" },
        .{ !attributes.configurable, "DontDelete" },
    }) |attribute| {
        if (attribute[0]) {
            if (wrote) try writer.writeAll(" | ");
            try writer.print("JSC::PropertyAttribute::{s}", .{attribute[1]});
            wrote = true;
        }
    }
    if (!wrote) try writer.writeByte('0');
}

fn emitObjectSurfaceHeaderMemberCallbacks(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface, member: *const ir.ObjectSurfaceMember, member_index: usize) Error!void {
    if (!member.exposed) return;
    const initializer = member.initializer orelse return;
    try writer.print("static JSC::JSValue {s}([[maybe_unused]] JSC::VM& vm, JSC::JSObject* object)\n{{\n", .{try objectSurfaceCallbackBodyName(e, surface, member_index)});
    switch (initializer) {
        .value => |value| {
            try writer.writeAll("    return ");
            try emitCppSurfaceValue(e, writer, value, "object", "object->globalObject()");
            try writer.writeAll(";\n");
        },
        .callable => |callable| {
            try writer.writeAll("    auto* value = ");
            try emitCppSurfaceFunction(e, writer, callable.function, "object->globalObject()");
            try writer.print(";\n    {s}(vm, value->classInfo(), *value);\n    return value;\n", .{try objectSurfaceInstallName(e, e.objectSurface(callable.surface))});
        },
    }
    try writer.writeAll("}\n\n");
    try writer.print(
        \\static JSC::JSValue {s}(JSC::VM& vm, JSC::JSObject* object)
        \\{{
        \\    return Bun::Bindgen::invokePropertyInitializer(vm, object, {s});
        \\}}
        \\
    , .{ try objectSurfaceCallbackName(e, surface, member_index), try objectSurfaceCallbackBodyName(e, surface, member_index) });
}

fn emitObjectSurfaceTableMember(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface, member: *const ir.ObjectSurfaceMember, member_index: usize) Error!void {
    if (!member.exposed) return;
    const table = switch (member.installation) {
        .table => |value| value,
        .direct, .global => return,
    };
    try writer.writeAll("    { ");
    try emitCppAsciiLiteral(writer, member.property_name);
    try writer.writeAll(", static_cast<unsigned>(");
    switch (table) {
        .function => |function| {
            try emitCppPropertyAttributes(writer, member.attributes, switch (function.symbol) {
                .native => "Function",
                .builtin => "Builtin",
            });
            if (function.constructable) try writer.writeAll(" | JSC::PropertyAttribute::Constructable");
            switch (function.symbol) {
                .native => |symbol| try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::NativeFunctionType, {s}, {d} }} }},\n", .{ symbol, function.length }),
                .builtin => |symbol| try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::BuiltinGeneratorType, WebCore::{s}, {d} }} }},\n", .{ symbol, function.length }),
            }
        },
        .property_callback => {
            try emitCppPropertyAttributes(writer, member.attributes, "PropertyCallback");
            try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::LazyPropertyType, {s} }} }},\n", .{try objectSurfaceCallbackName(e, surface, member_index)});
        },
        .builtin_accessor => |symbol| {
            try emitCppPropertyAttributes(writer, member.attributes, "Builtin | JSC::PropertyAttribute::Accessor");
            try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::BuiltinAccessorType, WebCore::{s}, nullptr }} }},\n", .{symbol});
        },
        .integer => |integer| {
            try emitCppPropertyAttributes(writer, member.attributes, "ConstantInteger");
            try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::ConstantType, {d} }} }},\n", .{integer});
        },
        .owner => |owner| {
            try emitCppPropertyAttributes(writer, member.attributes, switch (owner.kind) {
                .cell => "CellProperty",
                .class_structure => "ClassStructure",
            });
            try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::{s}, OBJECT_OFFSETOF({s}, {s}) }} }},\n", .{
                switch (owner.kind) {
                    .cell => "LazyCellPropertyType",
                    .class_structure => "LazyClassStructureType",
                },
                owner.class,
                owner.member,
            });
        },
    }
}

fn emitObjectSurfaceStaticHashTable(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface, table: ir.CppSurfaceHashTable) Error!void {
    try writer.print("static constinit const JSC::CompactHashIndex {s}[{d}] = {{\n", .{ try objectSurfaceHashIndexName(e, surface), table.index.len });
    for (table.index) |entry| {
        try writer.print("    {{ {d}, {d} }},\n", .{ entry.value, entry.next });
    }
    try writer.print(
        \\}};
        \\
        \\static constinit const JSC::HashTable {s} = {{
        \\    {d}, {d}, false, nullptr, {s}, {s}
        \\}};
        \\
    , .{
        try objectSurfaceHashTableName(e, surface),
        table.value_count,
        table.mask,
        try objectSurfaceTableName(e, surface),
        try objectSurfaceHashIndexName(e, surface),
    });
}

fn emitSurfaceAttributes(writer: *Writer, attributes: anytype, accessor: bool) Error!void {
    try writer.writeAll("static_cast<unsigned>(");
    try emitCppPropertyAttributes(writer, attributes, if (accessor) "Accessor" else null);
    try writer.writeByte(')');
}

fn emitObjectSurfacePropertyKey(e: *Emitter, writer: *Writer, key: ir.SurfacePropertyKey) Error!void {
    switch (key) {
        .name => |name| try emitCppInternedPropertyKey(e, writer, name, "vm"),
        .symbol => |symbol| try writer.writeAll(classSymbolCppName(symbol)),
        .builtin_name => |accessor| try writer.print("WebCore::builtinNames(vm).{s}()", .{accessor}),
        .engine_name => |member| try writer.print("vm.propertyNames->{s}", .{member}),
        .engine_builtin_name => |accessor| try writer.print("vm.propertyNames->builtinNames().{s}()", .{accessor}),
    }
}

fn emitCppSurfaceValue(e: *Emitter, writer: *Writer, value: ir.CppSurfaceValue, owner: []const u8, global: []const u8) Error!void {
    switch (value) {
        .function => |function| try emitCppSurfaceFunction(e, writer, function, global),
        .callback => |reference| try writer.print("{s}(vm, {s})", .{ try objectSurfaceCallbackName(e, e.objectSurface(reference.surface), reference.index), owner }),
        .function_factory => |symbol| try writer.print("{s}({s}, {s})", .{ symbol, global, owner }),
        .native_factory => |symbol| try writer.print("JSC::JSValue::decode(Bun::Bindgen::ZigExports::{s}({s}))", .{ symbol, global }),
        .constructor => |id| try writer.print("{s}_value({s})", .{ e.class(id).get_constructor_symbol, global }),
        .object => |id| try writer.print("{s}({s})", .{ try objectSurfaceCreateName(e, e.objectSurface(id)), global }),
        .self => try writer.writeAll(owner),
        .constant => |constant| switch (constant) {
            .string => |text| {
                try writer.writeAll("JSC::jsString(vm, ");
                try emitCppUtf8String(writer, text);
                try writer.writeByte(')');
            },
            .external_string => |symbol| try writer.print("JSC::jsString(vm, WTF::String({s}))", .{symbol}),
            .registered_symbol => |key| {
                try writer.writeAll("JSC::Symbol::create(vm, vm.symbolRegistry().symbolForKey(");
                try emitCppUtf8String(writer, key);
                try writer.writeAll("))");
            },
            .undefined => try writer.writeAll("JSC::jsUndefined()"),
            .integer => |integer| try writer.print("JSC::jsNumber({d})", .{integer}),
            .external_number => |symbol| try writer.print("JSC::jsNumber({s})", .{symbol}),
            .external_boolean => |symbol| try writer.print("JSC::jsBoolean({s})", .{symbol}),
            .boolean => |boolean| try writer.writeAll(if (boolean) "JSC::jsBoolean(true)" else "JSC::jsBoolean(false)"),
        },
        .empty_collection => |collection| switch (collection) {
            .array => try writer.print("JSC::constructEmptyArray({s}, nullptr)", .{global}),
            .set => try writer.print("JSC::JSSet::create(vm, {s}->setStructure())", .{global}),
        },
    }
}

fn emitCppSurfaceFunction(e: *Emitter, writer: *Writer, function: ir.CppSurfaceFunction, global: []const u8) Error!void {
    switch (function) {
        .realm => |id| try writer.print("static_cast<Zig::GlobalObject*>({s})->{s}()", .{ global, e.ir.get(id).symbol }),
        .builtin => |symbol| try writer.print("JSC::JSFunction::create(vm, {s}, WebCore::{s}(vm), {s})", .{ global, symbol, global }),
        .native => |native| {
            try writer.print("JSC::JSFunction::create(vm, {s}, {d}, ", .{ global, native.length });
            switch (native.name) {
                .none => try writer.writeAll("WTF::String()"),
                .named => |name| try emitCppUtf8String(writer, name),
                .getter => |name| try emitCppUtf8String(writer, try e.print("get {s}", .{name})),
                .setter => |name| try emitCppUtf8String(writer, try e.print("set {s}", .{name})),
            }
            try writer.print(", {s}, JSC::ImplementationVisibility::{s}", .{ native.symbol, if (native.visibility == .public) "Public" else "Private" });
            if (native.constructable) try writer.print(", JSC::NoIntrinsic, {s}", .{native.symbol});
            try writer.writeByte(')');
        },
    }
}

fn emitSurfaceAccessorDeclarations(e: *Emitter, writer: *Writer, accessor: ir.CppSurfaceAccessor, prefix: []const u8, index: usize, global: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("auto* {s}Getter_{d} = ", .{ prefix, index });
    try emitCppSurfaceFunction(e, writer, accessor.getter, global);
    try writer.writeAll(";\n");
    switch (accessor.setter) {
        .none, .getter => {},
        .function => |function| {
            try indented(writer, indent).print("auto* {s}Setter_{d} = ", .{ prefix, index });
            try emitCppSurfaceFunction(e, writer, function, global);
            try writer.writeAll(";\n");
        },
    }
}

fn emitObjectSurfaceDirect(e: *Emitter, writer: *Writer, member: *const ir.ObjectSurfaceMember, index: usize, operation: ir.CppSurfaceInstallation) Error!void {
    switch (operation) {
        .value => |value| {
            try writer.writeAll("    putSurfaceValue(");
            try emitObjectSurfacePropertyKey(e, writer, member.property_key);
            try writer.writeAll(", ");
            try emitCppSurfaceValue(e, writer, value, "&object", "object.globalObject()");
            try writer.writeAll(", ");
            try emitSurfaceAttributes(writer, member.attributes, false);
        },
        .builtin => |symbol| {
            try writer.writeAll("    object.putDirectBuiltinFunction(vm, object.globalObject(), ");
            try emitObjectSurfacePropertyKey(e, writer, member.property_key);
            try writer.print(", WebCore::{s}(vm), ", .{symbol});
            try emitSurfaceAttributes(writer, member.attributes, false);
        },
        .native => |function| {
            try writer.writeAll("    object.putDirectNativeFunction(vm, object.globalObject(), ");
            try emitObjectSurfacePropertyKey(e, writer, member.property_key);
            try writer.print(", {d}, {s}, JSC::ImplementationVisibility::{s}, JSC::NoIntrinsic, ", .{ function.length, function.symbol, if (function.visibility == .public) "Public" else "Private" });
            try emitSurfaceAttributes(writer, member.attributes, false);
        },
        .accessor => |accessor| {
            try emitSurfaceAccessorDeclarations(e, writer, accessor, "surface", index, "object.globalObject()", 4);
            try writer.writeAll("    object.putDirectAccessor(object.globalObject(), ");
            try emitObjectSurfacePropertyKey(e, writer, member.property_key);
            try writer.print(", JSC::GetterSetter::create(vm, object.globalObject(), surfaceGetter_{d}, ", .{index});
            switch (accessor.setter) {
                .none => try writer.writeAll("JSC::jsUndefined()"),
                .getter => try writer.print("surfaceGetter_{d}", .{index}),
                .function => try writer.print("surfaceSetter_{d}", .{index}),
            }
            try writer.writeAll("), ");
            try emitSurfaceAttributes(writer, member.attributes, true);
        },
    }
    try writer.writeAll(");\n");
}

fn emitObjectSurfaceGlobalStatics(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface) Error!void {
    const cpp_class = surface.global_class orelse return;
    try writer.print("    {s}::BindingGlobalPropertyInfo surfaceGlobals[] = {{\n", .{cpp_class});
    for (surface.members) |*member| {
        if (!member.exposed) continue;
        const value = switch (member.installation) {
            .global => |global_value| global_value,
            .direct, .table => continue,
        };
        try writer.print("        {s}::BindingGlobalPropertyInfo(", .{cpp_class});
        try emitObjectSurfacePropertyKey(e, writer, member.property_key);
        try writer.writeAll(", ");
        try emitCppSurfaceValue(e, writer, value, "&object", "object.globalObject()");
        try writer.writeAll(", ");
        try emitSurfaceAttributes(writer, member.attributes, false);
        try writer.writeAll("),\n");
    }
    try writer.writeAll("    };\n");
    try writer.print("    static_cast<{s}&>(object).addBindingStaticGlobals(surfaceGlobals);\n", .{cpp_class});
}

fn emitObjectSurfaceInstaller(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface) Error!void {
    switch (surface.installation) {
        .static_lookup => |lookup| if (!lookup.install) return,
        .reified, .direct => {},
    }
    try writer.print(
        \\static void {s}(JSC::VM& vm, const JSC::ClassInfo* classInfo, JSC::JSObject& object)
        \\{{
        \\
    , .{try objectSurfaceInstallName(e, surface)});
    try writer.writeAll(
        \\    [[maybe_unused]] auto putSurfaceValue = [&](auto name, auto value, unsigned attributes) {
        \\        object.putDirect(vm, name, value, attributes);
        \\    };
        \\
    );
    if (surface.installation == .reified) {
        try writer.print("    JSC::reifyStaticProperties(vm, classInfo, {s}, object);\n", .{try objectSurfaceTableName(e, surface)});
    } else {
        try writer.writeAll("    UNUSED_PARAM(classInfo);\n");
    }
    try emitObjectSurfaceGlobalStatics(e, writer, surface);
    for (surface.members, 0..) |*member, member_index| {
        if (!member.exposed) continue;
        switch (member.installation) {
            .direct => |operation| try emitObjectSurfaceDirect(e, writer, member, member_index, operation),
            .table, .global => {},
        }
        if (member.aliases.len != 0) {
            try writer.print("    JSC::JSValue aliasValue_{d} = object.getDirect(vm, ", .{member_index});
            try emitObjectSurfacePropertyKey(e, writer, member.property_key);
            try writer.writeAll(");\n");
            try writer.print("    RELEASE_ASSERT(aliasValue_{d});\n", .{member_index});
            for (member.aliases) |alias| {
                try writer.writeAll("    putSurfaceValue(");
                try emitObjectSurfacePropertyKey(e, writer, alias.key);
                try writer.print(", aliasValue_{d}, ", .{member_index});
                try emitSurfaceAttributes(writer, alias.attributes, false);
                try writer.writeAll(");\n");
            }
        }
    }
    try writer.writeAll("}\n\n");
}

fn emitObjectSurfaceCreator(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface) Error!void {
    if (!e.ir.object_surface_plans[surface.id.index].used_as_object_value) return;
    try writer.print(
        \\static JSC::JSObject* {s}(JSC::JSGlobalObject* globalObject)
        \\{{
        \\    auto& vm = globalObject->vm();
        \\    auto* value =
    , .{try objectSurfaceCreateName(e, surface)});
    switch (surface.prototype) {
        .ordinary => try writer.writeAll(" JSC::constructEmptyObject(globalObject);\n"),
        .null => try writer.writeAll(" JSC::constructEmptyObject(vm, globalObject->nullPrototypeObjectStructure());\n"),
    }
    try writer.print("    {s}(vm, value->classInfo(), *value);", .{try objectSurfaceInstallName(e, surface)});
    switch (surface.integrity) {
        .extensible => {},
        .frozen => try writer.writeAll("    value->freeze(vm);\n"),
    }
    try writer.writeAll("    return value;\n}\n\n");
}

fn emitObjectSurfaceNativeAccessor(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface, member: *const ir.ObjectSurfaceMember) Error!void {
    if (!member.exposed) return;
    const accessor = member.native_accessor orelse return;
    try writer.print(
        \\static JSC::JSValue {s}(JSC::VM& vm, JSC::JSObject* object)
        \\{{
        \\    RELEASE_ASSERT(object);
        \\    auto propertyName =
    , .{try objectSurfaceNativeAccessorName(e, surface, accessor.name)});
    try writer.writeByte(' ');
    try emitObjectSurfacePropertyKey(e, writer, member.property_key);
    try writer.writeAll(
        \\;
        \\    unsigned attributes = 0;
        \\    auto offset = object->getDirectOffset(vm, propertyName, attributes);
        \\    if (!JSC::isValidOffset(offset)) {
        \\        RELEASE_ASSERT(!object->staticPropertiesReified());
        \\        {
        \\            JSC::DeferTerminationForAWhile deferScope(vm);
        \\            JSC::reifyStaticProperty(vm, object->classInfo(), propertyName,
    );
    try writer.print("{s}[{d}], *object);\n", .{ try objectSurfaceTableName(e, surface), accessor.table_index });
    try writer.writeAll(
        \\        }
        \\        if (vm.exceptionForInspection())
        \\            return {};
        \\        offset = object->getDirectOffset(vm, propertyName, attributes);
        \\        RELEASE_ASSERT(JSC::isValidOffset(offset));
        \\    }
        \\    return object->getDirect(offset);
        \\}
        \\
    );
}

fn emitObjectSurfaceGuard(e: *Emitter, writer: *Writer, surface: *const ir.ObjectSurface) Error!void {
    try writer.writeAll("#if ");
    for (e.ir.object_surface_plans[surface.id.index].header_roots, 0..) |root, index| {
        if (index != 0) try writer.writeAll(" || ");
        try writer.print("defined(BUN_BINDGEN_OBJECT_SURFACE_{s})", .{e.objectSurface(root).surface_name});
    }
    try writer.writeByte('\n');
    try writer.print(
        "#ifndef BUN_BINDGEN_OBJECT_SURFACE_EMITTED_{s}\n#define BUN_BINDGEN_OBJECT_SURFACE_EMITTED_{s}\n\n",
        .{ surface.surface_name, surface.surface_name },
    );
}

fn emitObjectSurfacesHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll("#include <JavaScriptCore/JSSet.h>\n\n");
    for (e.ir.object_surfaces) |*surface| {
        if (!surface.exposed) continue;
        try emitObjectSurfaceGuard(e, writer, surface);
        for (surface.members) |member| {
            if (!member.exposed) continue;
            if (member.initializer) |initializer| switch (initializer) {
                .value => |value| switch (value) {
                    .object => |id| try writer.print("static JSC::JSObject* {s}(JSC::JSGlobalObject*);\n", .{try objectSurfaceCreateName(e, e.objectSurface(id))}),
                    .function, .callback, .function_factory, .native_factory, .constructor, .constant, .empty_collection, .self => {},
                },
                .callable => |callable| try writer.print("static void {s}(JSC::VM&, const JSC::ClassInfo*, JSC::JSObject&);\n", .{try objectSurfaceInstallName(e, e.objectSurface(callable.surface))}),
            };
        }
        try writer.writeByte('\n');
        for (surface.members, 0..) |*member, member_index| try emitObjectSurfaceHeaderMemberCallbacks(e, writer, surface, member, member_index);
        if (surface.installation != .direct) {
            try writer.print("static constinit const JSC::HashTableValue {s}[] = {{\n", .{try objectSurfaceTableName(e, surface)});
            for (surface.members, 0..) |*member, member_index| try emitObjectSurfaceTableMember(e, writer, surface, member, member_index);
            try writer.writeAll("};\n\n");
            switch (surface.installation) {
                .static_lookup => |lookup| try emitObjectSurfaceStaticHashTable(e, writer, surface, lookup.table),
                .reified, .direct => {},
            }
        }
        for (surface.members) |*member| try emitObjectSurfaceNativeAccessor(e, writer, surface, member);
        try emitObjectSurfaceInstaller(e, writer, surface);
        try emitObjectSurfaceCreator(e, writer, surface);
        try writer.writeAll("#endif\n#endif\n\n");
    }
}

// ─── manifests and catalogs ───

fn emitNativeModuleManifest(e: *Emitter, writer: *Writer) Error!void {
    const registry = e.ir.internal_module_registry;
    const Module = struct {
        id: u16,
        name: []const u8,
        specifier: []const u8,
        source: ?[]const u8,
        bundlePath: ?[]const u8,
        aliases: []const []const u8,
    };
    const entries = if (registry) |value| value.modules else &.{};
    const modules = try e.arena.alloc(Module, entries.len);
    for (entries, modules) |entry, *module| module.* = .{
        .id = entry.id,
        .name = entry.name,
        .specifier = entry.specifier,
        .source = switch (entry.source) {
            .javascript => |javascript| javascript.path,
            .native => null,
        },
        .bundlePath = switch (entry.source) {
            .javascript => |javascript| javascript.bundle_path,
            .native => null,
        },
        .aliases = entry.aliases,
    };
    try std.json.Stringify.value(.{
        .version = 4,
        .fingerprint = e.fingerprint_symbol,
        .privateSymbols = e.ir.private_symbols,
        .registry = .{ .javascriptCount = if (registry) |value| value.javascript_count else @as(u16, 0), .modules = modules },
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn emitLinkMetadata(e: *Emitter, writer: *Writer) Error!void {
    const Entry = struct {
        kind: enum { function, class },
        source: []const u8,
        name: []const u8,
        symbol: []const u8,
    };
    var entries: std.ArrayList(Entry) = .empty;
    for (e.ir.modules) |*module| {
        const source = try e.print("{s}.schema.zig", .{module.source_stem});
        for (module.declarations) |function_id| {
            const factory = e.ir.cpp_function_factories[function_id.index] orelse continue;
            const function = e.function(function_id);
            try entries.append(e.arena, .{
                .kind = .function,
                .source = source,
                .name = function.function_name,
                .symbol = factory.symbol,
            });
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            const constructor = e.ir.cpp_class_constructors[class_id.index] orelse continue;
            try entries.append(e.arena, .{
                .kind = .class,
                .source = source,
                .name = class.class_name,
                .symbol = constructor.factory_symbol,
            });
        }
    }
    const ErrorCode = struct {
        tag: []const u8,
        value: u16,
        code: []const u8,
        name: []const u8,
        constructor: []const u8,
    };
    const codes = if (e.ir.error_catalog) |catalog| catalog.codes else &.{};
    const error_codes = try e.arena.alloc(ErrorCode, codes.len);
    for (codes, error_codes) |code, *output| output.* = .{
        .tag = code.tag,
        .value = code.value,
        .code = code.code,
        .name = code.name_override orelse errorClassName(code.class),
        .constructor = errorClassName(code.class),
    };
    try std.json.Stringify.value(.{
        .version = 2,
        .fingerprint = e.fingerprint_symbol,
        .entries = entries.items,
        .errorCodes = error_codes,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn errorClassName(class: ir.ErrorClass) []const u8 {
    return switch (class) {
        .generic_error => "Error",
        .type_error => "TypeError",
        .range_error => "RangeError",
        .syntax_error => "SyntaxError",
        .uri_error => "URIError",
    };
}

fn emitErrorCodeCatalog(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "Bindgen/ErrorCodeInfo.h"
        \\namespace Bun::Bindgen {
        \\
    );
    const catalog = e.ir.error_catalog;
    if (catalog) |value| {
        try emitCppEnumerationDeclaration(e, writer, value.enumeration);
        try writer.writeAll(
            \\inline constexpr ErrorCodeInfo nodeErrorCodes[] = {
            \\
        );
        for (value.codes) |code| {
            try writer.print("    {{ JSC::ErrorType::{s}, WTF::ASCIILiteral::fromLiteralUnsafe(", .{errorClassName(code.class)});
            try emitCppRawStringLiteral(writer, code.name_override orelse errorClassName(code.class));
            try writer.writeAll("), WTF::ASCIILiteral::fromLiteralUnsafe(");
            try emitCppRawStringLiteral(writer, code.code);
            try writer.writeAll(") },\n");
        }
        try writer.writeAll("};\n");
    }
    try writer.writeAll("}\n");
    if (catalog) |value| {
        const enumeration = e.ir.get(value.enumeration);
        try writer.print(
            \\namespace Bun {{
            \\using ErrorCode = Bindgen::{s};
            \\inline constexpr size_t NODE_ERROR_COUNT = {d};
            \\inline constexpr auto& errors = Bindgen::nodeErrorCodes;
            \\}}
            \\
        , .{ enumeration.cpp_name, value.codes.len });
    }
}

// ─── wire header ───

fn emitWireHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#ifndef BUN_SCHEMA_BINDINGS_WIRE_H
        \\#define BUN_SCHEMA_BINDINGS_WIRE_H
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#define BUN_BINDGEN_NOEXCEPT noexcept
        \\#define BUN_BINDGEN_NORETURN [[noreturn]]
        \\#else
        \\#define BUN_BINDGEN_NOEXCEPT
        \\#define BUN_BINDGEN_NORETURN _Noreturn
        \\#endif
        \\#include "SchemaBindingsWireTypes.h"
        \\
    );
    try emitWireDeclarations(e, writer);
    try writer.writeAll(
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\#endif
        \\
    );
}

// ─── wire names ───

fn lazyConvertSymbol(e: *Emitter, symbol: []const u8) Allocator.Error![]const u8 {
    return e.print(ir.symbol_formats.lazy_convert, .{symbol});
}

fn lazyDiscardSymbol(e: *Emitter, symbol: []const u8) Allocator.Error![]const u8 {
    return e.print(ir.symbol_formats.lazy_discard, .{symbol});
}

fn lazyFieldConvertSymbol(e: *Emitter, symbol: []const u8) Allocator.Error![]const u8 {
    return e.print(ir.symbol_formats.lazy_field_convert, .{symbol});
}

fn lazyFieldDiscardSymbol(e: *Emitter, symbol: []const u8) Allocator.Error![]const u8 {
    return e.print(ir.symbol_formats.lazy_field_discard, .{symbol});
}

// ─── wire layout ───

fn emitWireLayoutTable(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\// Wire layout metadata compiled by the C++ target compiler. Checked builds
        \\// compare it against every aggregate in Zig's translated wire header.
        \\#include "SchemaBindingsWire.h"
        \\
        \\extern "C" const uint64_t bun_bindgen_wire_layout_values[] = {
        \\    0x42554e4c41594f55ULL,
        \\    1,
    );
    try emitWireLayoutEntries(e, writer);
    try writer.writeAll(
        \\};
        \\extern "C" const uint64_t bun_bindgen_wire_layout_count =
        \\    sizeof(bun_bindgen_wire_layout_values) / sizeof(uint64_t);
        \\
    );
}

fn emitWireLayoutEntries(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.wire_types) |wire_type| switch (wire_type) {
        .structure, .@"union" => |aggregate| try emitWireLayoutEntry(writer, try aggregate.name.alloc(e.arena), aggregate.fields),
        .scalar, .opaque_handle, .forward_structure, .pointer, .alias, .function_pointer, .function => {},
    };
}

fn emitWireLayoutEntry(writer: *Writer, name: []const u8, fields: []const ir.WireField) Error!void {
    try emitWireLayoutPackedName(writer, name);
    try writer.print("    sizeof({s}), _Alignof({s}), {d},\n", .{ name, name, fields.len });
    for (fields) |field| {
        try emitWireLayoutPackedName(writer, field.name);
        try writer.print("    offsetof({s}, {s}),\n", .{ name, field.name });
    }
}

fn emitWireLayoutPackedName(writer: *Writer, name: []const u8) Error!void {
    try writer.print("    {d},\n", .{name.len});
    for (0..(name.len + 7) / 8) |word_index| {
        var word: u64 = 0;
        for (0..8) |byte_index| {
            const index = word_index * 8 + byte_index;
            if (index == name.len) break;
            word |= @as(u64, name[index]) << @intCast(byte_index * 8);
        }
        try writer.print("    0x{x}ULL,\n", .{word});
    }
}

fn emitWireTypes(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.wire_types) |wire_type| switch (wire_type) {
        .scalar, .pointer, .function => {},
        .opaque_handle => |name| try writer.print("typedef struct {f} {f};\n", .{ name, name }),
        .forward_structure => |name| try writer.print("#ifndef __cplusplus\ntypedef struct {f} {f};\n#endif\n", .{ name, name }),
        .alias => |alias| {
            try writer.writeAll("typedef ");
            try emitWireTypeReference(e, writer, alias.child);
            try writer.print(" {f};\n", .{alias.name});
            for (alias.constants) |constant| try writer.print("#define {s} (({f}){d})\n", .{ constant.name, alias.name, constant.value });
        },
        .structure, .@"union" => |aggregate| {
            const keyword = if (wire_type == .structure) "struct" else "union";
            try writer.print("typedef {s} {f} {{\n", .{ keyword, aggregate.name });
            for (aggregate.fields) |field| {
                try writer.writeAll("    ");
                try emitWireTypeReference(e, writer, field.type);
                try writer.print(" {s};\n", .{field.name});
            }
            try writer.print("}} {f};\n", .{aggregate.name});
        },
        .function_pointer => |function| {
            try writer.writeAll("typedef ");
            try emitWireTypeReference(e, writer, function.result);
            try writer.print(" (*{f})(", .{function.name});
            for (function.parameters, 0..) |parameter, index| {
                if (index != 0) try writer.writeAll(", ");
                try emitWireTypeReference(e, writer, parameter);
            }
            if (function.parameters.len == 0) try writer.writeAll("void");
            try writer.writeAll(");\n");
        },
    };
}

fn emitWireTypeReference(e: *const Emitter, writer: *Writer, id: ir.WireTypeId) Error!void {
    try writer.writeAll(try e.wireSpelling(id));
}

fn emitWireAdapter(e: *Emitter, writer: *Writer, function: ir.WireFunction, adapter: ir.WireAdapter) Error!void {
    try writer.print("\n{{\n    {s} wireArgs = {{0}};\n", .{try e.wireSpelling(adapter.arguments)});
    for (adapter.inputs) |input| {
        const source = function.parameters[input.parameter].name;
        switch (input.operation) {
            .copy, .boolean => try writer.print("    wireArgs.{s} = {s}{s};\n", .{ input.field, source, if (input.operation == .boolean) " != 0" else "" }),
            .nonnull_pointer => |target| {
                try writer.print("    if (!{s}) abort();\n", .{source});
                try writer.print("    wireArgs.{s} = ({s}){s};\n", .{ input.field, try e.wireSpelling(target), source });
            },
            .slice => |length_parameter| {
                const length = function.parameters[length_parameter].name;
                try writer.print("    if ({0s} && (!{1s} || {0s} > SIZE_MAX / sizeof(*{1s}))) abort();\n", .{ length, source });
                try writer.print("    wireArgs.{s}.ptr = {s} ? {s} : NULL;\n", .{ input.field, length, source });
                try writer.print("    wireArgs.{s}.len = {s};\n", .{ input.field, length });
            },
        }
    }
    try writer.print("    {s} wireResult = {{0}};\n    {s} context = {{0}};\n    context.call_id = {s}();\n", .{
        try e.wireSpelling(adapter.result), try e.wireSpelling(adapter.context), try e.wireSpelling(adapter.call_id),
    });
    try writer.writeAll("    ");
    if (!function.non_returning) try writer.print("{s} status = ", .{try e.wireSpelling(adapter.status)});
    try writer.print("{s}(&context, &wireArgs, &wireResult);\n", .{try e.wireSpelling(adapter.callee)});
    if (!function.non_returning) {
        try writer.writeAll("    if (status != BIND_STATUS_OK) abort();\n");
        if (adapter.result_field) |field| try writer.print("    return wireResult.{s};\n", .{field});
    }
    try writer.writeAll("}\n#endif\n");
}

fn emitWireDeclarations(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.wire_types) |wire_type| switch (wire_type) {
        .function => |function| {
            if (function.body == .adapter) try writer.writeAll("#ifndef __cplusplus\n#include <stdlib.h>\n");
            if (function.non_returning) try writer.writeAll("BUN_BINDGEN_NORETURN ");
            if (function.body != .declaration) try writer.writeAll("static inline ");
            try emitWireTypeReference(e, writer, function.result);
            try writer.print(" {f}(", .{function.name});
            for (function.parameters, 0..) |parameter, index| {
                if (index != 0) try writer.writeAll(", ");
                try emitWireTypeReference(e, writer, parameter.type);
                try writer.print(" {s}", .{parameter.name});
            }
            if (function.parameters.len == 0) try writer.writeAll("void");
            try writer.writeAll(") BUN_BINDGEN_NOEXCEPT");
            switch (function.body) {
                .adapter => |adapter| try emitWireAdapter(e, writer, function, adapter),
                .declaration => try writer.writeAll(";\n"),
            }
        },
        .scalar, .pointer, .opaque_handle, .forward_structure, .alias, .structure, .@"union", .function_pointer => {},
    };
}

// ─── C++ declarations ───

fn emitCppDomainError(e: *Emitter, writer: *Writer, failure: ir.CppDomainError) Error!void {
    try writer.print("        struct {s} {{", .{failure.name});
    if (failure.payload) |type_| try writer.print(" {s} value; ", .{try e.cppType(type_)});
    try writer.writeAll(" };\n");
}

fn emitCppCompletionDeclaration(e: *Emitter, writer: *Writer, id: ir.CppCompletionEncoderId) Error!void {
    const codec = e.ir.get(id);
    const api = e.ir.get(codec.api);
    try writer.print(
        \\struct {s} {{
        \\    using Handle = {s};
        \\    using Wire = {s};
        \\
    , .{ api.codec, try e.wireSpelling(api.handle), try e.wireSpelling(codec.wire) });
    switch (codec.value) {
        .owned_handle => |type_| {
            try writer.print("    using NativeValue = {s};\n", .{try e.cppType(type_)});
            try writer.writeAll("    struct Deleter { void operator()(NativeValue) const noexcept; };\n    using Value = std::unique_ptr<std::remove_pointer_t<NativeValue>, Deleter>;\n");
            if (e.ir.cpp_completion_deliveries[codec.completion.index].materializer == .engine) try writer.writeAll("    static JSC::JSValue materialize(Bun::Bindgen::EngineCallContext&, NativeValue);\n");
        },
        .value => |type_| try writer.print("    using Value = {s};\n", .{try e.cppType(type_)}),
    }
    try writer.writeAll("    struct Errors {\n");
    for (codec.entries) |entry| switch (entry.output) {
        .value => {},
        .domain_error => |failure| try emitCppDomainError(e, writer, failure.declaration),
    };
    try writer.writeAll("    };\n");
    for (codec.entries) |entry| switch (entry.output) {
        .value => try writer.writeAll("    static void resolve(Handle*, Value);\n"),
        .domain_error => |failure| {
            const declaration = failure.declaration;
            try writer.print("    static void fail(Handle*, Errors::{s});\n", .{declaration.name});
            try writer.print("    static void raise(Bun::Bindgen::EngineCallContext& context, Errors::{s}{s}) {{ {s}(context", .{
                declaration.name, if (declaration.payload != null) " failure" else "", declaration.raise_symbol,
            });
            if (declaration.payload != null) try writer.writeAll(", WTF::move(failure.value)");
            try writer.writeAll("); }\n");
        },
    };
    try writer.print("    static void clone(Handle* handle) {{ {s}(handle); }}\n", .{api.clone});
    try writer.print("    static void release(Handle* handle) {{ {s}(handle); }}\n", .{api.release});
    try writer.print("    static void finish(Handle* handle, bool success) {{ {s}(handle, success); }}\n", .{api.finish});
    try writer.print("    static void outOfMemory(Handle* handle) {{ Wire result {{}}; {s}(handle, BIND_COMPLETION_OUT_OF_MEMORY, &result); }}\n", .{api.settle});
    try writer.writeAll("};\n");
}

fn emitCppCompletionEncoder(e: *Emitter, writer: *Writer, codec: *const ir.CppCompletionEncoder, value_plan: ir.CppCompletionValue) Error!void {
    const api = e.ir.get(codec.api);
    const operation = e.ir.get(value_plan.encoder).operation;
    const has_value = operation != .leaf or operation.leaf != .void;
    const owned_handle = value_plan.output == .value and codec.value == .owned_handle;
    const value = if (owned_handle) "nativeValue" else "value";
    const target = switch (value_plan.output) {
        .value => |layout| switch (layout) {
            .direct => "result.value",
            .tagged => "result.payload.value",
        },
        .domain_error => |failure| try e.print("result.payload.error_{s}", .{failure.declaration.name}),
    };
    try writer.writeAll("    Wire result {};\n");
    switch (value_plan.output) {
        .value => |layout| switch (layout) {
            .direct => {},
            .tagged => try writer.writeAll("    result.tag = 0;\n"),
        },
        .domain_error => |failure| try writer.print("    result.tag = {d};\n", .{failure.tag}),
    }
    if (owned_handle) try writer.writeAll("    auto* nativeValue = value.get();\n");
    try writer.writeAll("    auto encode = [&]() -> BindStatus {\n");
    if (has_value) try emitCppResultValue(e, writer, value_plan.encoder, value, target, 8, .{}, "nullptr");
    try writer.writeAll("        return BIND_STATUS_OK;\n    };\n    auto status = encode();\n    if (status != BIND_STATUS_OK) {\n        RELEASE_ASSERT(status == BIND_STATUS_OUT_OF_MEMORY);\n");
    if (value_plan.cleanup) |cleanup| try emitCppDestroyPendingResultValue(e, writer, cleanup, target, 8);
    try writer.writeAll("        outOfMemory(handle);\n        return;\n    }\n");
    if (owned_handle) {
        try writer.writeAll("    value.release();\n");
    }
    try writer.print("    {s}(handle, {s}, &result);\n}}\n\n", .{ api.settle, if (value_plan.output == .value) "BIND_COMPLETION_VALUE" else "BIND_COMPLETION_DOMAIN_ERROR" });
}

fn emitCppCompletionCodec(e: *Emitter, writer: *Writer, id: ir.CppCompletionEncoderId) Error!void {
    const codec = e.ir.get(id);
    const completion = e.ir.get(codec.completion);
    const name = try e.print("Bun::Bindgen::Cpp::{s}", .{e.ir.get(codec.api).codec});
    if (codec.value == .owned_handle) {
        try writer.print("void {s}::Deleter::operator()(NativeValue value) const noexcept\n{{\n", .{name});
        try emitCppOwnedNominalHandleReleasePlan(e, writer, completion.payload, "value", 4);
        try writer.writeAll("}\n\n");
    }
    for (codec.entries) |entry| {
        switch (entry.output) {
            .value => {
                try writer.print("void {s}::resolve(Handle* handle, Value value)\n{{\n", .{name});
                const operation = e.ir.get(entry.encoder).operation;
                if (operation == .leaf and operation.leaf == .void) try writer.writeAll("    static_cast<void>(value);\n");
            },
            .domain_error => |failure| {
                try writer.print("void {s}::fail(Handle* handle, Errors::{s} failure)\n{{\n", .{ name, failure.declaration.name });
                try writer.writeAll(if (failure.declaration.payload != null) "    auto& value = failure.value;\n" else "    static_cast<void>(failure);\n");
            },
        }
        try emitCppCompletionEncoder(e, writer, codec, entry);
    }
}

fn emitCppFunctionCompletions(e: *Emitter, writer: *Writer, function: *const ir.Function) Error!void {
    if (function.exposed) switch (e.ir.functionCpp(function).*) {
        .builtin => {},
        .overload => |dispatch| {
            for (dispatch.cases) |case| try emitCppFunctionCompletions(e, writer, e.ir.get(case.declaration));
        },
        .call => |body| switch (body.entry.callee) {
            .cpp => |id| switch (e.ir.get(id).result) {
                .completion => |codec| try emitCppCompletionCodec(e, writer, codec),
                .sync => {},
            },
            .wire, .builtin_constructor, .predicate, .reject, .load_cache, .store_cache => {},
        },
    };
    if (function.completion) |id| try emitCompletionDelivery(e, writer, id);
}

fn cppImplementationReturnType(e: *Emitter, implementation: *const ir.CppImplementation) Allocator.Error![]const u8 {
    return switch (implementation.result) {
        .completion => "void",
        .sync => |result| if (result.outcome) |outcome| e.print("Bun::Bindgen::Cpp::{s}::Type", .{outcome.name}) else e.cppType(result.type),
    };
}

fn emitCppImplementationDeclaration(e: *Emitter, writer: *Writer, function: *const ir.CppFunction) Error!void {
    const callee = switch (function.*) {
        .builtin => return,
        .overload => |dispatch| {
            for (dispatch.cases) |case| try emitCppImplementationDeclaration(e, writer, &e.ir.cpp_overload_cases[case.declaration.index].?);
            return;
        },
        .call => |body| switch (body.entry.callee) {
            .cpp => |id| e.ir.get(id),
            .wire, .builtin_constructor, .predicate, .reject, .load_cache, .store_cache => return,
        },
    };
    const context_type = switch (callee.context) {
        .call => "Bun::Bindgen::CppCallContext",
        .engine_call => |id| try e.print("Bun::Bindgen::CppEngineCallContext<{s}>", .{e.class(id).cpp_class_name}),
        .engine_construct => |id| try e.print("Bun::Bindgen::CppEngineConstructContext<{s}>", .{e.class(id).cpp_class_name}),
        .plain_construct => "Bun::Bindgen::CppPlainConstructContext",
    };
    switch (callee.result) {
        .completion => |id| try emitCppCompletionDeclaration(e, writer, id),
        .sync => |result| if (result.outcome) |outcome| {
            try writer.print("struct {s} {{\n    struct Errors {{\n", .{outcome.name});
            for (outcome.errors) |failure| try emitCppDomainError(e, writer, failure);
            try writer.writeAll("    };\n");
            try writer.print("    using Type = Bun::Bindgen::CppResult<{s}", .{try e.cppType(result.type)});
            for (outcome.errors) |failure| try writer.print(", Errors::{s}", .{failure.name});
            try writer.writeAll(">;\n};\n");
        },
    }
    try writer.print("struct {s} {{\n", .{callee.arguments});
    for (callee.fields) |field| try writer.print("    {s} {s};\n", .{ try e.cppType(field.type), field.name });
    try writer.writeAll("};\n");
    switch (callee.result) {
        .completion => |id| try writer.print("void {s}({s}&, const {s}&, Bun::Bindgen::CppCompletion<{s}>&);\n\n", .{ callee.symbol, context_type, callee.arguments, e.ir.get(e.ir.get(id).api).codec }),
        .sync => try writer.print("{s} {s}({s}&, const {s}&);\n\n", .{ try cppImplementationReturnType(e, callee), callee.symbol, context_type, callee.arguments }),
    }
}

fn emitEngineImplementationDeclaration(e: *Emitter, writer: *Writer, id: ir.EngineShimId) Error!void {
    const implementation = e.ir.cpp_engine_implementations[id.index];
    try writer.print("struct {s} {{\n", .{implementation.arguments.name});
    for (implementation.arguments.fields) |field| {
        try writer.print("    {s} {s};\n", .{ try e.cppType(field.type), field.name });
    }
    try writer.writeAll("};\n");
    try writer.print("using {s} = {s};\n", .{ implementation.result_alias.name, try e.cppType(implementation.result_alias.type) });
    try emitCppNativeSignature(e, writer, implementation.signature);
    try writer.writeAll(";\n\n");
    if (e.ir.cpp_engine_entries[id.index]) |entry| {
        try emitCppNativeSignature(e, writer, entry.signature);
        try writer.writeAll(";\n");
    }
}

fn emitCppDictionaryDefinition(e: *Emitter, writer: *Writer, definition: ir.CppTypeDefinition, fields: []const ir.CppTypeField) Error!void {
    try writer.print("struct {s} {{\n", .{definition.name});
    for (fields) |field| try writer.print("    {s} {s};\n", .{ try e.cppType(field.type), field.name });
    if (definition.protects_sources) try emitCppResultDictionaryProtection(writer, fields);
    if (definition.transferred_roots) try writer.writeAll("    bool tryAdoptRoot(Bun::StrongRef root) { return bindingRoots.tryAdopt(WTF::move(root)); }\n    CppTransferredRoots bindingRoots;\n");
    try writer.writeAll("};\n\n");
}

fn emitCppUnionDefinition(e: *Emitter, writer: *Writer, definition: ir.CppTypeDefinition, union_: ir.CppUnionDefinition) Error!void {
    const name = definition.name;
    const members = union_.members;
    try writer.print("class {s} {{\npublic:\n", .{name});
    try writer.writeAll("    enum class Tag : uint8_t { none");
    for (members) |member| try writer.print(", {s}", .{member.name});
    try writer.writeAll(" };\n\n");
    try writer.writeAll("    Tag tag() const { return static_cast<Tag>(m_value.index()); }\n");
    if (union_.visit) {
        try writer.writeAll("    template<typename Visitor> decltype(auto) visit(Visitor&& visitor) const\n    {\n        switch (tag()) {\n");
        for (members) |member| try writer.print("        case Tag::{0s}: return std::forward<Visitor>(visitor)({0s}());\n", .{member.name});
        try writer.writeAll("        case Tag::none: RELEASE_ASSERT_NOT_REACHED();\n        }\n        RELEASE_ASSERT_NOT_REACHED();\n    }\n");
    }
    if (union_.selector) |selector| {
        const selector_name = try e.cppType(selector.type);
        try writer.print("    {s} selector() const\n    {{\n        switch (tag()) {{\n", .{selector_name});
        for (members, selector.values) |member, value| switch (value) {
            .forward => try writer.print("        case Tag::{0s}: return {0s}().selector();\n", .{member.name}),
            .constant => |tag| try writer.print("        case Tag::{s}: return {s}::{s};\n", .{ member.name, selector_name, tag }),
        };
        try writer.writeAll("        case Tag::none: RELEASE_ASSERT_NOT_REACHED();\n        }\n        RELEASE_ASSERT_NOT_REACHED();\n    }\n");
    }
    for (members, 1..) |member, index| {
        try writer.print(
            \\    bool is_{0s}() const {{ return m_value.index() == {1d}; }}
            \\    {2s}& {0s}() {{ RELEASE_ASSERT(is_{0s}()); return std::get<{1d}>(m_value); }}
            \\    {2s} const& {0s}() const {{ RELEASE_ASSERT(is_{0s}()); return std::get<{1d}>(m_value); }}
            \\    void set_{0s}({2s} value) {{ m_value.emplace<{1d}>(std::move(value)); }}
            \\
        , .{ member.name, index, try e.cppType(member.type) });
    }
    if (definition.protects_sources) try emitCppResultUnionProtection(writer, members);
    if (definition.transferred_roots) try writer.writeAll("    bool tryAdoptRoot(Bun::StrongRef root) { return m_bindingRoots.tryAdopt(WTF::move(root)); }\n");
    try writer.writeAll("private:\n    std::variant<std::monostate");
    for (members) |member| try writer.print(", {s}", .{try e.cppType(member.type)});
    try writer.writeAll("> m_value;\n");
    if (definition.transferred_roots) try writer.writeAll("    CppTransferredRoots m_bindingRoots;\n");
    try writer.writeAll("};\n\n");
}

fn emitCppResultDictionaryProtection(writer: *Writer, fields: []const ir.CppTypeField) Error!void {
    try writer.writeAll("    bool protectResult(CppResultContext& context) const\n    {\n");
    for (fields) |field| if (field.protects_sources) try writer.print("        if (!protectCppResult(context, {s})) return false;\n", .{field.name});
    try writer.writeAll("        return true;\n    }\n");
}

fn emitCppResultUnionProtection(writer: *Writer, members: []const ir.CppTypeField) Error!void {
    try writer.writeAll("    bool protectResult(CppResultContext& context) const\n    {\n        switch (tag()) {\n");
    for (members) |member| {
        const name = member.name;
        try writer.print("        case Tag::{s}:\n", .{name});
        if (member.protects_sources) {
            try writer.print("            return protectCppResult(context, {s}());\n", .{name});
        } else {
            try writer.writeAll("            return true;\n");
        }
    }
    try writer.writeAll("        case Tag::none:\n            RELEASE_ASSERT_NOT_REACHED();\n        }\n        RELEASE_ASSERT_NOT_REACHED();\n    }\n");
}

fn nativeHandleToWireExpression(e: *Emitter, handle: ir.CppHandle, expression: []const u8) Allocator.Error![]const u8 {
    const wire_type = try e.wireSpelling(handle.wire);
    if (handle.const_pointee) {
        return e.print("const_cast<{s}*>(reinterpret_cast<const {s}*>({s}))", .{ wire_type, wire_type, expression });
    }
    return e.print("reinterpret_cast<{s}*>({s})", .{ wire_type, expression });
}

fn emitCppNativeSignature(e: *Emitter, writer: *Writer, signature: ir.CppNativeSignature) Error!void {
    if (signature.nodiscard) try writer.writeAll("[[nodiscard]] ");
    if (signature.non_returning) try writer.writeAll("[[noreturn]] ");
    try writer.writeAll(try e.cppType(signature.result));
    try writer.print(" {s}(", .{signature.symbol});
    switch (signature.context) {
        .none => {},
        .global => try writer.writeAll("JSC::JSGlobalObject* global"),
        .engine => try writer.writeAll("Bun::Bindgen::EngineCallContext& context"),
    }
    for (signature.parameters, 0..) |parameter, index| {
        if (index > 0 or signature.context != .none) try writer.writeAll(", ");
        const type_id = switch (parameter.type) {
            .native => |id| e.ir.get(id).type,
            .direct => |id| id,
        };
        try writer.print("{s} {s}", .{ try e.cppType(type_id), parameter.name });
    }
    try writer.writeByte(')');
}

fn emitNativeExportDeclaration(e: *Emitter, writer: *Writer, native_export: ir.CppNativeExport) Error!void {
    for (native_export.element_aliases) |alias| try writer.print("using {s} = {s};\n", .{ alias.name, try e.cppType(alias.type) });
    try emitCppNativeSignature(e, writer, native_export.entry.signature);
    try writer.writeAll(";\n");
}

fn cppDiscardedJSValue(e: *Emitter, match: ir.DiscardedMatch) Allocator.Error![]const u8 {
    return switch (match) {
        .semantic_type => "JSC::jsBoolean(false)",
        .null_literal => "JSC::jsNull()",
        .undefined_literal => "JSC::jsUndefined()",
        .false_literal => "JSC::jsBoolean(false)",
        .number_literal => |number| e.print("JSC::jsNumber(std::bit_cast<double>(uint64_t {{ 0x{x:0>16}ULL }}))", .{@as(u64, @bitCast(number))}),
    };
}

fn cppAnyFromJSExpression(e: *Emitter, expression: []const u8) Allocator.Error![]const u8 {
    return e.print("Bun::Bindgen::Detail::CppAnyAccess::fromJS({s})", .{expression});
}

fn cppAnyToJSExpression(e: *Emitter, expression: []const u8) Allocator.Error![]const u8 {
    return e.print("Bun::Bindgen::Detail::CppAnyAccess::toJS({s})", .{expression});
}

fn cppNativeClassOpaqueType(e: *Emitter, class: *const ir.Class) Allocator.Error![]const u8 {
    return e.print("{s}_Native", .{class.cpp_class_name});
}

fn cppNativeClassPointerType(e: *Emitter, class: *const ir.Class) Allocator.Error![]const u8 {
    return e.print("{s}_Native*", .{class.cpp_class_name});
}

fn cppSemanticConverterName(e: *Emitter, id: ir.CppInputAggregateId) Allocator.Error![]const u8 {
    return e.print("CppSemanticConverter_{d}_{d}", .{ id.position.index, id.index });
}

fn cppResultEncoderName(e: *Emitter, id: ir.CppResultEncoderId(.inbound_result)) Allocator.Error![]const u8 {
    return e.print("encodeBindingResult_{d}_{d}", .{ id.position.index, id.index });
}

fn cppResultDecoderName(e: *Emitter, position: ir.InboundResultPlanId) Allocator.Error![]const u8 {
    return e.print("decodeBindingResult_{d}", .{position.index});
}

// ─── conversion contexts ───

const CppConversionBindings = struct {
    receiver: []const u8 = "JSC::JSValue(global)",
    deferred: []const u8 = "nullptr",
};

const CppInputValue = struct {
    value: []const u8,
    prepared: ?[]const u8 = null,
    selected_member: ?[]const u8 = null,

    fn source(input: CppInputValue) []const u8 {
        return input.prepared orelse input.value;
    }
};

const CppCodecBindings = struct {
    global: []const u8 = "global",
    root_target: ?[]const u8 = null,
    wire_storage: []const u8 = "wireStorage",
    native_roots: []const u8 = "nullptr",

    fn withRoots(bindings: CppCodecBindings, target: ?[]const u8) CppCodecBindings {
        return .{ .global = bindings.global, .root_target = target, .wire_storage = bindings.wire_storage, .native_roots = bindings.native_roots };
    }
};

fn emitCppCodecException(e: *Emitter, writer: *Writer, id: ir.CppCodecFailureId, indent: usize) Error!void {
    switch (e.ir.get(id).exception) {
        .none => {},
        .status => {
            try indented(writer, indent).writeAll("if (materializeBindingException(throwScope)) return BIND_STATUS_PENDING_EXCEPTION;\n");
        },
        inline .materialize, .termination => |value, tag| {
            try indented(writer, indent).print("if ({s}(throwScope)) {s}\n", .{ if (tag == .materialize) "materializeBindingException" else "bindingTerminationAfterNonThrowingCall", cppReturn(value) });
        },
    }
}

fn emitCppCodecAllocationFailure(e: *Emitter, writer: *Writer, id: ir.CppCodecFailureId, indent: usize) Error!void {
    try writer.splatByteAll(' ', indent);
    switch (e.ir.get(id).allocation) {
        .infallible => try writer.writeAll("RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"an infallible binding adapter failed to allocate\");\n"),
        .status => try writer.writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n"),
        .return_value => |value| try writer.print("{s}\n", .{cppReturn(value)}),
        .throw_value => |failure| {
            if (failure.if_clear) {
                try writer.writeAll("if (!materializeBindingException(throwScope))\n");
                try writer.splatByteAll(' ', indent + 4);
            }
            try writer.writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
            try indented(writer, indent).print("{s}\n", .{cppReturn(failure.value)});
        },
    }
}

fn cppDecodedValueType(e: *Emitter, decode: anytype) Error![]const u8 {
    return e.cppType(e.ir.get(decode.position).cpp.decode.?.value_type);
}

fn emitCppDecodeAllocationCheck(e: *Emitter, writer: *Writer, failure: ir.CppCodecFailureId, failed: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if ({s}) {{\n", .{failed});
    try emitCppCodecAllocationFailure(e, writer, failure, indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppWireDecodePresent(
    e: *Emitter,
    writer: *Writer,
    decode: anytype,
    environment: CppCodecBindings,
    present: []const u8,
    source: []const u8,
    target: []const u8,
    suffix: []const u8,
    path: []const u8,
    indent: usize,
) Error!void {
    const value = try e.print("present_{s}", .{suffix});
    try indented(writer, indent).print("if (decodeBindingPresence({s})) {{\n", .{present});
    try indented(writer, indent + 4).print("{s} {s} {{}};\n", .{ try cppDecodedValueType(e, decode), value });
    try emitCppWireDecode(e, writer, decode, environment, source, value, suffix, path, indent + 4);
    try indented(writer, indent + 4).print("{s} = WTF::move({s});\n", .{ target, value });
    try indented(writer, indent).writeAll("} else\n");
    try indented(writer, indent + 4).print("{s} = std::nullopt;\n", .{target});
}

fn emitCppWireDecode(
    e: *Emitter,
    writer: *Writer,
    decode: anytype,
    environment: CppCodecBindings,
    source: []const u8,
    target: []const u8,
    suffix: []const u8,
    path: []const u8,
    indent: usize,
) Error!void {
    const plan = &e.ir.get(decode.position).cpp.decode.?;
    switch (plan.operation) {
        .body => |*body| try emitCppDecodeBody(e, writer, decode, body, environment, source, target, suffix, path, indent),
        .helper => |helper| {
            const call = try e.print("Bun::Bindgen::{s}({s}, {s}, {s})", .{ try cppResultDecoderName(e, helper), environment.global, source, target });
            if (e.ir.get(helper).cpp.decoder_helper.?.allocates) return emitCppDecodeAllocationCheck(e, writer, decode.failure, try e.print("!{s}", .{call}), indent);
            try indented(writer, indent).print("{s};\n", .{call});
        },
    }
}

fn emitCppDecodeBody(
    e: *Emitter,
    writer: *Writer,
    decode: anytype,
    body: *const ir.CppDecodeBody(@TypeOf(decode.position).role),
    environment: CppCodecBindings,
    source: []const u8,
    target: []const u8,
    suffix: []const u8,
    path: []const u8,
    indent: usize,
) Error!void {
    if (body.cleanup) {
        try indented(writer, indent).print("auto nativeOwner_{s} = WTF::makeScopeExit([&] {{\n", .{suffix});
        try emitCppOwnedNominalHandleReleasePlan(e, writer, decode.position, target, indent + 4);
        try indented(writer, indent).writeAll("});\n");
    }
    const renderer: CppDecodeEmission(@TypeOf(decode.position).role) = .{
        .e = e,
        .writer = writer,
        .decode = decode,
        .body = body,
        .environment = environment.withRoots(switch (body.roots) {
            .none => null,
            .enclosing => environment.root_target,
            .target => target,
        }),
        .source = source,
        .target = target,
        .suffix = suffix,
        .path = path,
        .indent = indent,
    };
    switch (e.ir.get(decode.position).representation) {
        .converted => |conversion| try renderer.converted(conversion.apiValue()),
        .record_entry => |pair| try renderer.entry(pair),
        .optional => |child| try renderer.optional(child),
        .dictionary => |fields| try renderer.dictionary(fields),
        .union_type => |members| try renderer.union_type(members),
        inline .sequence, .record, .rest => |child| try renderer.collection(child),
        .leaf => if (comptime @TypeOf(decode.position).role == .outbound_argument) switch (body.leaf.?) {
            inline .scalar, .enumeration, .encoded_value, .slice_borrow, .lazy => |value, tag| try @field(@TypeOf(renderer), @tagName(tag))(renderer, value),
            .callback_borrow => try renderer.callback({}),
            .class_borrow => |reference| try renderer.class_reference(reference),
            .string_borrow => try renderer.string({}),
            .handle_borrow => try renderer.handle({}),
        } else switch (body.leaf.?) {
            .void => {},
            inline .scalar, .enumeration, .encoded_value, .bytes_take, .buffer_materialize => |value, tag| try @field(@TypeOf(renderer), @tagName(tag))(renderer, value),
            .callback_root => try renderer.callback({}),
            .class_root => |reference| try renderer.class_reference(reference),
            .string_take => try renderer.string({}),
            .handle_borrow, .handle_take => try renderer.handle({}),
        },
    }
    if (body.cleanup) {
        try indented(writer, indent).print("nativeOwner_{s}.release();\n", .{suffix});
    }
}

fn CppDecodeEmission(comptime role: ir.Role) type {
    return struct {
        const Self = @This();
        const Decode = ir.CppDecode(role);

        e: *Emitter,
        writer: *Writer,
        decode: Decode,
        body: *const ir.CppDecodeBody(role),
        environment: CppCodecBindings,
        source: []const u8,
        target: []const u8,
        suffix: []const u8,
        path: []const u8,
        indent: usize,

        fn child(s: Self, position: role.PlanId()) Decode {
            return .{ .position = position, .failure = s.decode.failure };
        }

        fn converted(s: Self, match: role.PlanId()) Error!void {
            if (comptime role == .outbound_argument) if (s.body.converter) |converter|
                return emitCppEngineConvertedArgument(s.e, s.writer, s.environment, s.child(match), converter, s.decode.failure, s.source, s.target, s.suffix, s.path, s.indent);
            try emitCppWireDecode(s.e, s.writer, s.child(match), s.environment, s.source, s.target, s.suffix, s.path, s.indent);
        }

        fn lazy(s: Self, conversion: ir.CppLazyDecode) Error!void {
            try indented(s.writer, s.indent).print("{s} = Bun::Bindgen::Detail::CppArgumentAccess::lazyArgument<{s}>(global, {s}, bindingDeferredConversionsPointer, ", .{ s.target, try s.e.cppType(conversion.value_type), s.source });
            try s.writer.print("{d});\n", .{ir.lazyFieldKey(conversion.protocol)});
        }

        fn handle(s: Self, _: void) Error!void {
            const take = if (comptime role == .outbound_argument) false else s.body.leaf.? == .handle_take;
            try indented(s.writer, s.indent).print("{s} = reinterpret_cast<{s}>({s}({s}));\n", .{
                s.target,
                try cppDecodedValueType(s.e, s.decode),
                if (take) "takeBindingHandle" else "requireBindingHandle",
                s.source,
            });
        }

        fn scalar(s: Self, kind: ir.ScalarKind) Error!void {
            try s.writer.splatByteAll(' ', s.indent);
            switch (kind) {
                .boolean => try s.writer.print("{s} = decodeBindingBoolean({s});\n", .{ s.target, s.source }),
                .discarded => try s.writer.print("{s} = decodeBindingDiscarded({s});\n", .{ s.target, s.source }),
                .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => try s.writer.print("{s} = {s};\n", .{ s.target, s.source }),
            }
        }

        fn encoded_value(s: Self, value: ir.CppJavaScriptValue) Error!void {
            const decoded = try s.e.print("decodeBindingValue({s})", .{s.source});
            try s.writer.splatByteAll(' ', s.indent);
            switch (value) {
                .any => try s.writer.print("{s} = {s};\n", .{ s.target, try cppAnyFromJSExpression(s.e, decoded) }),
                .engine_value => try s.writer.print("{s} = {s};\n", .{ s.target, decoded }),
                .branded => |brand| {
                    try s.writer.print("{s} = {s};\n", .{ s.target, decoded });
                    try emitCppBrandAssertion(s.e, s.writer, brand, s.target, s.indent);
                },
            }
        }

        fn callback(s: Self, _: void) Error!void {
            if (comptime role == .outbound_argument) {
                try indented(s.writer, s.indent).print("{s} = borrowBindingValue({s});\n", .{ s.target, s.source });
            } else {
                const root = try s.e.print("callbackRoot_{s}", .{s.suffix});
                const owned_root = try s.e.print("callbackRooted_{s}", .{s.suffix});
                try indented(s.writer, s.indent).print("auto* {s} = takeBindingHandle({s});\n", .{ root, s.source });
                try indented(s.writer, s.indent).print("Bun::StrongRef {s} {{ reinterpret_cast<Bun::StrongRefStorage*>({s}) }};\n", .{ owned_root, root });
                try indented(s.writer, s.indent).print("{s} = readBindingRootValue(global, {s});\n", .{ s.target, root });
                try indented(s.writer, s.indent).print("(void)bindingCallbackFunction({s});\n", .{s.target});
                if (s.environment.root_target) |owner| try emitCppDecodeAllocationCheck(s.e, s.writer, s.decode.failure, try s.e.print("!{s}.tryAdoptRoot(WTF::move({s}))", .{ owner, owned_root }), s.indent);
            }
        }

        fn class_reference(s: Self, reference: ir.CppClassReference) Error!void {
            const class = switch (reference) {
                .native, .engine => |class_id| s.e.class(class_id),
            };
            const value = try s.e.print("classValue_{s}", .{s.suffix});
            const object = try s.e.print("classObject_{s}", .{s.suffix});
            const rooted = try s.e.print("classRooted_{s}", .{s.suffix});
            const native = switch (reference) {
                .engine => try s.e.print("&{s}->wrapped()", .{object}),
                .native => try s.e.print("{s}->native()", .{object}),
            };
            try s.writer.splatByteAll(' ', s.indent);
            if (comptime role == .outbound_argument) {
                try s.writer.print("JSC::JSValue {s} = borrowBindingValue({s}.wrapper);\n", .{ value, s.source });
            } else {
                const root = try s.e.print("classRoot_{s}", .{s.suffix});
                try s.writer.print("auto* {s} = takeBindingHandle({s}.wrapper);\n", .{ root, s.source });
                try indented(s.writer, s.indent).print("Bun::StrongRef {s} {{ reinterpret_cast<Bun::StrongRefStorage*>({s}) }};\n", .{ rooted, root });
                try indented(s.writer, s.indent).print("JSC::JSValue {s} = readBindingRootValue(global, {s});\n", .{ value, root });
            }
            try indented(s.writer, s.indent).print("auto* {s} = dynamicDowncast<Bun::{s}>({s});\n", .{ object, class.cpp_class_name, value });
            try indented(s.writer, s.indent).print("RELEASE_ASSERT({s} && reinterpret_cast<BindNativeHandle*>({s}) == requireBindingHandle({s}.native));\n", .{ object, native, s.source });
            try s.writer.splatByteAll(' ', s.indent);
            if (comptime role == .outbound_argument) {
                if (reference == .engine) {
                    try s.writer.print("{s} = {s};\n", .{ s.target, native });
                } else {
                    try s.writer.print("{s} = engineContext.borrowNative<{s}>(*{s}, {s});\n", .{ s.target, try cppNativeClassOpaqueType(s.e, class), object, value });
                    try emitCppDecodeAllocationCheck(s.e, s.writer, s.decode.failure, try s.e.print("!{s}", .{s.target}), s.indent);
                }
            } else {
                try s.writer.print("{s} = {s};\n", .{ s.target, value });
                if (s.environment.root_target) |owner| try emitCppDecodeAllocationCheck(s.e, s.writer, s.decode.failure, try s.e.print("!{s}.tryAdoptRoot(WTF::move({s}))", .{ owner, rooted }), s.indent);
            }
        }

        fn string(s: Self, _: void) Error!void {
            try indented(s.writer, s.indent).print("{s} = {s}({s});\n", .{ s.target, if (comptime role == .outbound_argument) "decodeBindingString" else "takeBindingString", s.source });
        }

        fn buffer_materialize(s: Self, representation: ir.BufferResultRepresentation) Error!void {
            try emitCppBufferToJS(s.e, s.writer, representation, s.decode.failure, s.source, s.target, try s.e.print("nativeBuffer_{s}", .{s.suffix}), s.indent);
        }

        fn bytes_take(s: Self, _: void) Error!void {
            try indented(s.writer, s.indent).print("(void)decodeBindingSlice({s});\n", .{s.source});
            try indented(s.writer, s.indent).print("{s} = Bun::Bindgen::Detail::CppNativeResultAccess::adoptBytes({s});\n", .{ s.target, s.source });
        }

        fn slice_borrow(s: Self, _: void) Error!void {
            try indented(s.writer, s.indent).print("{s} = decodeBindingSlice({s});\n", .{ s.target, s.source });
        }

        fn enumeration(s: Self, tags: []const u16) Error!void {
            try indented(s.writer, s.indent).writeAll("RELEASE_ASSERT(");
            try emitCppEnumerationValidityExpression(s.writer, tags, s.source);
            try s.writer.writeAll(");\n");
            try indented(s.writer, s.indent).print("{s} = static_cast<{s}>({s});\n", .{ s.target, try cppDecodedValueType(s.e, s.decode), s.source });
        }

        fn entry(s: Self, pair: @FieldType(ir.Representation(role), "record_entry")) Error!void {
            try emitCppWireDecode(s.e, s.writer, s.child(pair.key), s.environment, try s.e.print("{s}.key", .{s.source}), try s.e.print("{s}.first", .{s.target}), try s.e.print("{s}_key", .{s.suffix}), try s.e.print("{s}.<key>", .{s.path}), s.indent);
            try emitCppWireDecode(s.e, s.writer, s.child(pair.value), s.environment, try s.e.print("{s}.value", .{s.source}), try s.e.print("{s}.second", .{s.target}), try s.e.print("{s}_value", .{s.suffix}), s.path, s.indent);
        }

        fn optional(s: Self, value: role.PlanId()) Error!void {
            try emitCppWireDecodePresent(
                s.e,
                s.writer,
                s.child(value),
                s.environment,
                try s.e.print("{s}.present", .{s.source}),
                try s.e.print("{s}.value", .{s.source}),
                s.target,
                try s.e.print("{s}_optional", .{s.suffix}),
                s.path,
                s.indent,
            );
        }

        fn dictionary(s: Self, fields: []const ir.PositionField(role)) Error!void {
            for (fields) |field| {
                const name = field.name;
                const field_source = try s.e.print("{s}.{s}", .{ s.source, name });
                const field_target = try s.e.print("{s}.{s}", .{ s.target, name });
                const field_suffix = try s.e.print("{s}_{s}", .{ s.suffix, name });
                const field_path = try s.e.print("{s}.{s}", .{ s.path, name });
                const value_decode = s.child(field.value);
                if (role == .outbound_argument and field.dictionary_source) {
                    const value = try s.e.print("dictionarySource_{s}", .{field_suffix});
                    try indented(s.writer, s.indent).print("{s} {s} {{}};\n", .{ try cppDecodedValueType(s.e, value_decode), value });
                    try emitCppWireDecode(s.e, s.writer, value_decode, s.environment, field_source, value, field_suffix, field_path, s.indent);
                    try indented(s.writer, s.indent).print("{s} = Bun::Bindgen::CppDictionarySource {{ *{s}, Bun::Bindgen::Detail::CppAnyAccess::toJS({s}) }};\n", .{ field_target, s.environment.global, value });
                    continue;
                }
                if (field.optional) {
                    try emitCppWireDecodePresent(s.e, s.writer, value_decode, s.environment, try s.e.print("{s}_present", .{field_source}), field_source, field_target, field_suffix, field_path, s.indent);
                } else {
                    try emitCppWireDecode(s.e, s.writer, value_decode, s.environment, field_source, field_target, field_suffix, field_path, s.indent);
                }
            }
        }

        fn union_type(s: Self, members: []const ir.PositionMember(role)) Error!void {
            try indented(s.writer, s.indent).print("switch ({s}.tag) {{\n", .{s.source});
            for (members, 0..) |member_plan, index| {
                const name = member_plan.name;
                const member_suffix = try s.e.print("{s}_{s}", .{ s.suffix, name });
                const value = try s.e.print("member_{s}", .{member_suffix});
                const member = s.child(member_plan.value);
                try indented(s.writer, s.indent).print("case {d}: {{\n", .{index + 1});
                try indented(s.writer, s.indent + 4).print("{s} {s} {{}};\n", .{ try cppDecodedValueType(s.e, member), value });
                try emitCppWireDecode(s.e, s.writer, member, s.environment, try s.e.print("{s}.payload.{s}", .{ s.source, name }), value, member_suffix, try s.e.print("{s}.{s}", .{ s.path, name }), s.indent + 4);
                try indented(s.writer, s.indent + 4).print("{s}.set_{s}(WTF::move({s}));\n", .{ s.target, name, value });
                try indented(s.writer, s.indent + 4).writeAll("break;\n");
                try indented(s.writer, s.indent).writeAll("}\n");
            }
            try indented(s.writer, s.indent).writeAll("default:\n");
            try indented(s.writer, s.indent + 4).writeAll("RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding wire union has an invalid tag\");\n");
            try indented(s.writer, s.indent).writeAll("}\n");
        }

        fn collection(s: Self, element_position: role.PlanId()) Error!void {
            const element_plan = s.child(element_position);
            const element_type = try cppDecodedValueType(s.e, element_plan);
            const items = try s.e.print("items_{s}", .{s.suffix});
            const index = try s.e.print("index_{s}", .{s.suffix});
            const element = try s.e.print("element_{s}", .{s.suffix});
            const span = s.body.span;
            const storage = if (span) try s.e.print("storage_{s}", .{s.suffix}) else s.target;
            try indented(s.writer, s.indent).print("auto {s} = decodeBindingSlice({s});\n", .{ items, s.source });
            if (span) {
                try indented(s.writer, s.indent).print("auto* {s}Owner = engineArgumentStorage.create<WTF::Vector<{s}>>();\n", .{ storage, element_type });
                try emitCppDecodeAllocationCheck(s.e, s.writer, s.decode.failure, try s.e.print("!{s}Owner", .{storage}), s.indent);
                try indented(s.writer, s.indent).print("auto& {s} = *{s}Owner;\n", .{ storage, storage });
            }
            try emitCppDecodeAllocationCheck(s.e, s.writer, s.decode.failure, try s.e.print("!{s}.tryReserveCapacity({s}.size())", .{ storage, items }), s.indent);
            try indented(s.writer, s.indent).print("for (size_t {s} = 0; {s} < {s}.size(); ++{s}) {{\n", .{ index, index, items, index });
            try indented(s.writer, s.indent + 4).print("{s} {s} {{}};\n", .{ element_type, element });
            try emitCppWireDecode(s.e, s.writer, element_plan, s.environment, try s.e.print("{s}[{s}]", .{ items, index }), element, try s.e.print("{s}_element", .{s.suffix}), try s.e.print("{s}[]", .{s.path}), s.indent + 4);
            try indented(s.writer, s.indent + 4).print("Bun::Bindgen::Detail::CppNativeResultAccess::append({s}, WTF::move({s}));\n", .{ storage, element });
            try indented(s.writer, s.indent).writeAll("}\n");
            if (span) {
                try indented(s.writer, s.indent).print("{s} = std::span<{s} const> {{ {s}.span().data(), {s}.size() }};\n", .{ s.target, element_type, storage, storage });
            }
        }
    };
}

// ─── result converters ───

fn emitCppResultEncoderSignature(e: *Emitter, writer: *Writer, id: ir.CppResultEncoderId(.inbound_result)) Error!void {
    const encoder = e.ir.get(id);
    try writer.print("inline BindStatus {s}(JSC::JSGlobalObject* global, {s}& value, {s}& output)", .{
        try cppResultEncoderName(e, id), try e.cppType(encoder.value_type), try e.wireSpelling(encoder.wire),
    });
}

fn emitCppResultEncoder(e: *Emitter, writer: *Writer, id: ir.CppResultEncoderId(.inbound_result)) Error!void {
    const encoder = e.ir.get(id);
    try emitCppResultEncoderSignature(e, writer, id);
    try writer.writeAll("\n{\n");
    if (encoder.requires_global) try writer.writeAll(
        \\    return invokeBindingStatusEntry(global, [&]() -> BindStatus {
        \\    auto throwScope = DECLARE_THROW_SCOPE(global->vm());
        \\
    );
    try emitCppResultValue(e, writer, id, "value", "output", 4, .{}, "global");
    try writer.writeAll("    return BIND_STATUS_OK;\n");
    if (encoder.requires_global) try writer.writeAll("    });\n");
    try writer.writeAll("}\n\n");
}

fn emitCppResultDecoderSignature(e: *Emitter, writer: *Writer, position: ir.InboundResultPlanId) Error!void {
    const decoder = &e.ir.get(position).cpp.decoder_helper.?;
    try writer.print("inline {s} {s}(JSC::JSGlobalObject* global, {s}& source, {s}& target)", .{
        if (decoder.allocates) "bool" else "void", try cppResultDecoderName(e, position), try e.wireSpelling(decoder.wire), try e.cppType(decoder.value_type),
    });
}

fn emitCppResultDecoder(e: *Emitter, writer: *Writer, position: ir.InboundResultPlanId) Error!void {
    const decoder = &e.ir.get(position).cpp.decoder_helper.?;
    try emitCppResultDecoderSignature(e, writer, position);
    try writer.writeAll("\n{\n");
    try emitCppDecodeBody(e, writer, ir.CppDecode(.inbound_result){ .position = position, .failure = decoder.failure }, &decoder.body, .{}, "source", "target", "native", "native", 4);
    if (decoder.allocates) try writer.writeAll("    return true;\n");
    try writer.writeAll("}\n\n");
}

fn emitCppConvertersHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll("#pragma once\n\nnamespace Bun::Bindgen {\n\n");
    try emitCppAggregateDeclarations(e, writer, .converter_header);
    var result_encoders: std.AutoArrayHashMapUnmanaged(ir.CppResultEncoderId(.inbound_result), void) = .empty;
    inline for (.{ ir.Role.inbound_result, ir.Role.outbound_result }) |role| {
        for (try e.codecIds(ir.CppResultEncoderId(role))) |id| {
            const operation = e.ir.get(id).operation;
            if (operation == .leaf and operation.leaf == .helper) try result_encoders.put(e.arena, operation.leaf.helper, {});
        }
    }
    for (result_encoders.keys()) |id| {
        try emitCppResultEncoderSignature(e, writer, id);
        try writer.writeAll(";\n");
    }
    var decoders: std.ArrayList(ir.InboundResultPlanId) = .empty;
    for (e.ir.inbound_result_plans, 0..) |plan, index| if (plan.cpp.decoder_helper != null) try decoders.append(e.arena, .of(index));
    for (decoders.items) |id| {
        try emitCppResultDecoderSignature(e, writer, id);
        try writer.writeAll(";\n");
    }
    inline for (std.enums.values(ir.Role)) |role| {
        for (try e.codecIds(ir.CppMaterializerId(role))) |id| {
            try emitCppMaterializerSignature(e, writer, id);
            try writer.writeAll(";\n");
        }
    }
    inline for (std.enums.values(ir.Role)) |role| {
        for (try e.codecIds(ir.CppMaterializerId(role))) |id| try emitCppMaterializer(e, writer, id);
    }
    for (e.ir.cpp_input_declarations) |id| try emitCppSemanticConverter(e, writer, id);
    for (result_encoders.keys()) |id| try emitCppResultEncoder(e, writer, id);
    for (decoders.items) |id| try emitCppResultDecoder(e, writer, id);
    var completion_decoders: std.AutoHashMapUnmanaged(ir.CppMaterializerId(.inbound_result), void) = .empty;
    for (e.ir.cpp_completion_deliveries) |delivery| switch (delivery.materializer) {
        .wire => |materializer| {
            if ((try completion_decoders.getOrPut(e.arena, materializer)).found_existing) continue;
            try emitCppCompletionValueDecoder(e, writer, materializer);
        },
        .engine => {},
    };
    for (e.ir.domain_error_factories) |*domain_error| try emitCppDomainErrorFactory(e, writer, domain_error);
    try writer.writeAll("}\n");
}

fn cppCompletionValueDecoder(e: *Emitter, id: ir.CppMaterializerId(.inbound_result)) Allocator.Error![]const u8 {
    return e.print("decodeBindingCompletionValue_{d}_{d}", .{ id.position.index, id.index });
}

fn emitCppCompletionValueDecoder(e: *Emitter, writer: *Writer, id: ir.CppMaterializerId(.inbound_result)) Error!void {
    try writer.print("inline JSC::JSValue {s}(JSC::JSGlobalObject* global, void* payload)\n{{\n", .{try cppCompletionValueDecoder(e, id)});
    if (e.ir.get(id).isVoid()) {
        try writer.writeAll("    return JSC::jsUndefined();\n}\n\n");
        return;
    }
    try writer.writeAll("    auto& vm = global->vm();\n    auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
    try writer.print("    auto& value = *static_cast<{s}*>(payload);\n", .{try e.wireSpelling(e.ir.get(id).source.wire.type)});
    try writer.writeAll("    JSC::JSValue jsResult;\n");
    try emitCppMaterializedValue(e, writer, id, "value", "jsResult", 4);
    try emitCppExceptionReturn(writer, 4, "return {};");
    try writer.writeAll("    return jsResult;\n}\n\n");
}

fn emitCppDomainErrorRaiser(e: *Emitter, writer: *Writer, factory: *const ir.DomainErrorFactory) Error!void {
    try writer.print("void Bun::Bindgen::Cpp::{s}(Bun::Bindgen::EngineCallContext& context", .{factory.symbol});
    if (factory.value_type) |value_type| try writer.print(", {s} value", .{try e.cppType(value_type)});
    try writer.writeAll(
        \\)
        \\{
        \\    auto* global = &context.globalObject;
        \\    auto& vm = global->vm();
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\
    );
    try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, void());\n    auto materialize = [&]() -> JSC::JSObject* {\n");
    try emitCppDomainErrorObjectBody(e, writer, factory, 8, "value");
    try writer.writeAll("        return jsError;\n    };\n    auto* exception = materialize();\n    BINDGEN_RETURN_IF_EXCEPTION(throwScope, void());\n    RELEASE_ASSERT(exception);\n    throwScope.throwException(global, exception);\n}\n\n");
}

fn emitCppDomainErrorFactory(e: *Emitter, writer: *Writer, factory: *const ir.DomainErrorFactory) Error!void {
    try writer.print("inline JSC::JSObject* {s}(JSC::JSGlobalObject* global, void* input)\n{{\n", .{factory.symbol});
    try writer.writeAll("    auto& vm = global->vm();\n    auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
    if (factory.value_type) |value_type| {
        try writer.print("    auto& payload = *static_cast<{s}*>(input);\n", .{try e.cppType(value_type)});
    }
    try emitCppDomainErrorObjectBody(e, writer, factory, 4, "payload");
    try writer.writeAll("    return jsError;\n}\n\n");
}

fn emitCppSemanticConverter(e: *Emitter, output: *Writer, id: ir.CppInputAggregateId) Error!void {
    const aggregate = e.ir.get(id);
    var paths: CppConverterPaths = .{};
    const root_path: CppPath = .{ .template_path = .{ .owner = &paths, .relative = .{} } };
    var body: Writer.Allocating = .init(e.arena);
    const writer = &body.writer;
    try emitCppAggregateConverterPreamble(e, writer, aggregate);
    const context = cppAggregateConversionBindings(aggregate);
    switch (aggregate.operation) {
        .dictionary => |fields| try emitCppDictionaryInputPlan(e, writer, context, aggregate, fields, root_path, "input", "output", "semantic", 8),
        .union_type => |input| try emitCppUnionConverter(e, writer, aggregate, input, root_path),
        .sequence => |sequence| {
            try emitCppSequenceConversion(e, writer, context, aggregate, sequence, .{ .value = "input", .prepared = "source" }, root_path, "semantic", "converted", 8);
            try writer.writeAll("        output = WTF::move(converted);\n");
        },
        .record => |entry| {
            try emitCppBackendRecordPlanToCpp(e, writer, context, aggregate, entry, "input", root_path, "semantic", "converted", 8);
            try writer.writeAll("        output = WTF::move(converted);\n");
        },
    }
    if (aggregate.holds_byte_lease) try writer.writeAll("        bindingConverted_semantic = true;\n");
    try emitCppAggregateConverterEpilogue(e, writer, aggregate);
    try output.print("class {s} final {{\npublic:\n", .{try cppSemanticConverterName(e, id)});
    try paths.emit(e, output);
    try output.writeAll(body.written());
    try output.writeAll("};\n\n");
}

// ─── aggregate semantic converters ───

fn emitCppAggregateConverterPreamble(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    try writer.print(
        \\    class Cpp final {{
        \\        const Paths* m_paths {{ nullptr }};
        \\    public:
        \\    bool convert(const Paths& paths, JSC::JSGlobalObject* global, const BindingConversionInput& source, {s}& output, [[maybe_unused]] BindingDeferredConversions* bindingDeferredConversionsPointer{s}{s})
        \\    {{
        \\        RELEASE_ASSERT(global);
        \\        m_paths = &paths;
        \\        auto& vm = JSC::getVM(global);
        \\        auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\        [[maybe_unused]] JSC::JSValue input = source.value();
        \\
    , .{
        try e.cppType(aggregate.value_type),
        if (aggregate.receiver) ", JSC::JSValue bindingConverterReceiver" else "",
        if (cppAggregateAcceptsSelection(aggregate)) ", [[maybe_unused]] uint16_t bindingUnionSelection = 0" else "",
    });
}

fn cppAggregateAcceptsSelection(aggregate: *const ir.CppInputAggregate) bool {
    return switch (aggregate.operation) {
        .union_type => |input| switch (input.operation) {
            .matching => true,
            .tagged => false,
        },
        .dictionary, .sequence, .record => false,
    };
}

fn cppAggregateConversionBindings(aggregate: *const ir.CppInputAggregate) CppConversionBindings {
    return .{
        .deferred = "bindingDeferredConversionsPointer",
        .receiver = if (aggregate.receiver) "bindingConverterReceiver" else "JSC::JSValue(global)",
    };
}

fn emitCppAggregateConverterEpilogue(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    try writer.writeAll("        throwScope.release();\n        return true;\n    }\n");
    try emitCppSemanticConverterMethods(e, writer, aggregate);
    try writer.writeAll("\nprivate:\n");
    try emitCppSemanticConverterStorage(e, writer, aggregate);
    try writer.writeAll("    };\n");
}

fn emitCppUnionConverter(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate, input: ir.CppUnionInput, path: CppPath) Error!void {
    const fallback = input.fallback;
    if (fallback != null) try writer.writeAll(
        \\        auto primary = [&]() -> bool {
        \\            auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\
    );
    const context = cppAggregateConversionBindings(aggregate);
    try emitCppUnionConversion(e, writer, context, aggregate, input, .{
        .value = "input",
        .prepared = "source",
        .selected_member = if (cppAggregateAcceptsSelection(aggregate)) "bindingUnionSelection" else null,
    }, "output", path, "semantic", 8);
    if (fallback) |index| {
        try writer.writeAll(
            \\            throwScope.release();
            \\            return true;
            \\        };
            \\        bool converted = primary();
            \\        if (materializeBindingException(throwScope)) {
            \\            auto* exception = throwScope.exception();
            \\            if (vm.isTerminationException(exception)) return false;
            \\            if (auto* error = dynamicDowncast<JSC::ErrorInstance>(exception->value()); error && error->isOutOfMemoryError()) return false;
            \\            if (!throwScope.tryClearException()) return false;
            \\            converted = false;
            \\        }
            \\        if (!converted) {
            \\
        );
        try emitCppTaggedUnionFallback(e, writer, context, input.members[index], .{ .value = "input", .prepared = "source" }, "output", path, "semantic", 12);
        try writer.writeAll("        }\n");
    }
}

fn emitCppSemanticConverterMethods(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    try emitCppSemanticConverterArgumentMethod(e, writer, aggregate);
    try emitCppSemanticConverterResultMethod(e, writer, aggregate);
    if (!aggregate.holds_byte_lease) return;
    try writer.writeAll("    bool registerDeferred(JSC::JSGlobalObject* global, BindingDeferredConversions& bindingDeferredConversions)\n    {\n        if (!bindingConverted_semantic) return true;\n        auto throwScope = DECLARE_THROW_SCOPE(global->vm());\n");
    try emitCppSemanticConverterRootLeaseRegistration(e, writer, aggregate);
    try writer.writeAll("        throwScope.release();\n        return true;\n    }\n");
}

/// Registers every lease held by the storage that
/// `emitCppConverterValueStorage` declared for a plan under `suffix`.
fn emitCppSemanticConverterValueLeaseRegistration(e: *Emitter, writer: *Writer, id: ir.CppInputId, suffix: []const u8) Error!void {
    const input = e.ir.get(id);
    const failure = cppInputFailureReturn(input.failure);
    if (!input.holds_byte_lease) return;
    switch (input.operation) {
        .aggregate => try emitCppSemanticConverterLeaseRegistration(writer, suffix, failure),
        .optional => |optional| {
            try writer.print("    if (bindingLeasePresent_{s}) {{\n", .{suffix});
            try emitCppSemanticConverterValueLeaseRegistration(e, writer, optional.value, try e.print("{s}_optional", .{suffix}));
            try writer.writeAll("    }\n");
        },
        .buffer => |buffer| if (buffer == .lease) try emitCppLeaseStorageRegistration(writer, try e.print("bindingStorage_{s}", .{suffix}), failure, 4),
        .void, .discarded, .scalar, .converted, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .lazy => {},
    }
}

fn emitCppSemanticConverterRootLeaseRegistration(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    switch (aggregate.operation) {
        .dictionary => |dictionary| for (dictionary.fields) |entry| switch (entry) {
            .source => {},
            .value => |id| {
                const field = e.ir.get(id);
                if (!e.ir.get(field.input).holds_byte_lease) continue;
                if (field.tracks_lease_presence) try writer.print("    if (bindingFieldPresent_semantic_{s}) {{\n", .{field.name});
                try emitCppSemanticConverterValueLeaseRegistration(e, writer, field.input, try e.print("semantic_{s}", .{field.name}));
                if (field.tracks_lease_presence) try writer.writeAll("    }\n");
            },
        },
        .union_type => |union_input| for (union_input.members) |member| {
            if (!e.ir.get(member.value).holds_byte_lease) continue;
            try writer.print("    if (bindingSelectedMember_semantic == {d}) {{\n", .{member.tag});
            try emitCppSemanticConverterValueLeaseRegistration(e, writer, member.value, try e.print("semantic_{s}", .{member.name}));
            try writer.writeAll("    }\n");
        },
        .sequence => |sequence| try emitCppCollectionLeaseRegistration(e, writer, sequence.value, "bindingSequenceConverters_semantic"),
        .record => |entry| try emitCppCollectionLeaseRegistration(e, writer, entry.value, "bindingRecordConverters_semantic"),
    }
}

fn emitCppCollectionLeaseRegistration(e: *Emitter, writer: *Writer, value: ir.CppInputId, storage: []const u8) Error!void {
    const failure = cppInputFailureReturn(e.ir.get(value).failure);
    if (!e.ir.get(value).holds_byte_lease) return;
    try writer.print("    for (auto& bindingSemanticConverterItem : {s}) {{\n", .{storage});
    try writer.print("        if (!checkBindingConversionResult(throwScope, bindingSemanticConverterItem->registerDeferred(global, bindingDeferredConversions))) return {s};\n", .{failure});
    try writer.writeAll("    }\n");
}

fn emitCppSemanticConverterDeclaration(e: *Emitter, writer: *Writer, id: ir.CppInputAggregateId, suffix: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("Bun::Bindgen::{s}::Cpp bindingSemanticConverter_{s};\n", .{ try cppSemanticConverterName(e, id), suffix });
}

const CppStorageEmission = struct {
    e: *Emitter,
    writer: *Writer,
    indent: usize,
    source: ?[]const u8 = null,

    fn field(emission: CppStorageEmission, prefix: []const u8, suffix: []const u8, type_name: []const u8, initializer: []const u8) Error!void {
        const output = indented(emission.writer, emission.indent);
        if (emission.source) |source| {
            try output.print("auto& {0s}_{1s} = {2s}.{0s}_{1s};\n", .{ prefix, suffix, source });
        } else {
            try output.print("{s} {s}_{s}{s};\n", .{ type_name, prefix, suffix, initializer });
        }
    }

    fn emit(emission: CppStorageEmission, id: ir.CppInputId, suffix: []const u8) Error!void {
        const e = emission.e;
        const input = e.ir.get(id);
        switch (input.operation) {
            .aggregate => |aggregate| try emission.field("bindingSemanticConverter", suffix, try e.print("Bun::Bindgen::{s}::Cpp", .{try cppSemanticConverterName(e, aggregate)}), ""),
            .lazy => |lazy| try emission.field("bindingLazyState", suffix, try e.print("std::unique_ptr<Bun::Bindgen::Detail::CppLazyArgumentState<{s}>>", .{try e.cppType(e.ir.get(lazy.conversion.value).value_type)}), ""),
            .optional => |optional| {
                if (optional.tracks_lease_presence) try emission.field("bindingLeasePresent", suffix, "[[maybe_unused]] bool", " { false }");
                try emission.emit(optional.value, try e.print("{s}_optional", .{suffix}));
            },
            .converted => |converted| {
                const match_suffix = try e.print("{s}_match", .{suffix});
                try emission.emit(converted.match, match_suffix);
                try emission.field("bindingConverterInput", match_suffix, try e.cppType(e.ir.get(converted.match).value_type), " {}");
            },
            .value, .branded_value, .callback => try emission.field("bindingStorage", suffix, if (input.rooted) "BindingRootedValue" else "JSC::JSValue", ""),
            .node_path => try emission.field("bindingStorage", suffix, "WTF::Vector<uint8_t>", ""),
            .class_ref => |reference| {
                try emission.field("bindingWrapper", suffix, if (input.rooted) "BindingRootedValue" else "JSC::JSValue", "");
                switch (reference.reference) {
                    .engine => try emission.field("bindingStorage", suffix, try e.cppType(input.value_type), " = nullptr"),
                    .native => |class_id| try emission.field("bindingStorage", suffix, try e.print("std::optional<Bun::{s}::NativeBorrow>", .{e.class(class_id).cpp_class_name}), ""),
                }
            },
            .buffer => |buffer| switch (buffer) {
                .copy => try emission.field("bindingStorage", suffix, "WTF::Vector<uint8_t>", ""),
                .lease => {
                    try emission.field("bindingSource", suffix, "BindingBufferSource", "");
                    try emission.field("bindingStorage", suffix, "BindingByteLease", "");
                },
            },
            .void, .discarded, .scalar, .enumeration, .string, .external_ref => {},
        }
    }
};

fn emitCppConverterValueStorage(e: *Emitter, writer: *Writer, id: ir.CppInputId, suffix: []const u8, indent: usize) Error!void {
    const emission: CppStorageEmission = .{ .e = e, .writer = writer, .indent = indent };
    try emission.emit(id, suffix);
}

fn emitCppConverterValueAliases(e: *Emitter, writer: *Writer, id: ir.CppInputId, suffix: []const u8, storage: []const u8, indent: usize) Error!void {
    const emission: CppStorageEmission = .{ .e = e, .writer = writer, .indent = indent, .source = storage };
    try emission.emit(id, suffix);
}

fn emitCppStorageAllocationCheck(writer: *Writer, storage: []const u8, indent: usize, failure: ir.CppInputFailure) Error!void {
    try indented(writer, indent).print("if (!{s}) {{\n", .{storage});
    try emitCppOutOfMemoryReturn(writer, failure, indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppConverterStorageBundle(e: *Emitter, writer: *Writer, id: ir.CppInputId, suffix: []const u8, name: []const u8) Error!void {
    try writer.print("    struct {s} {{\n", .{name});
    try emitCppConverterValueStorage(e, writer, id, suffix, 8);
    if (e.ir.get(id).holds_byte_lease) {
        try writer.writeAll("        bool registerDeferred(JSC::JSGlobalObject* global, BindingDeferredConversions& bindingDeferredConversions)\n        {\n            auto throwScope = DECLARE_THROW_SCOPE(global->vm());\n");
        try emitCppSemanticConverterValueLeaseRegistration(e, writer, id, suffix);
        try writer.writeAll("            throwScope.release();\n            return true;\n        }\n");
    }
    try writer.writeAll("    };\n");
}

fn emitCppSemanticConverterStorage(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    if (aggregate.holds_byte_lease) try writer.writeAll("    bool bindingConverted_semantic { false };\n");
    switch (aggregate.operation) {
        .dictionary => |dictionary| for (dictionary.fields) |entry| switch (entry) {
            .source => {},
            .value => |id| {
                const field = e.ir.get(id);
                if (field.tracks_lease_presence) try writer.print("    bool bindingFieldPresent_semantic_{s} {{ false }};\n", .{field.name});
                try emitCppConverterValueStorage(e, writer, field.input, try e.print("semantic_{s}", .{field.name}), 4);
            },
        },
        .union_type => |union_input| {
            try writer.writeAll("    uint8_t bindingSelectedMember_semantic { 0 };\n");
            for (union_input.members) |member| try emitCppConverterValueStorage(e, writer, member.value, try e.print("semantic_{s}", .{member.name}), 4);
        },
        .sequence => |sequence| if (e.ir.get(sequence.value).collection_storage) {
            try emitCppConverterStorageBundle(e, writer, sequence.value, "semantic_element", "SemanticElementStorage");
            try writer.writeAll("    WTF::Vector<std::unique_ptr<SemanticElementStorage>> bindingSequenceConverters_semantic;\n");
        },
        .record => |entry| if (e.ir.get(entry.value).collection_storage) {
            try emitCppConverterStorageBundle(e, writer, entry.value, "semantic_record_value", "SemanticRecordValueStorage");
            try writer.writeAll("    WTF::Vector<std::unique_ptr<SemanticRecordValueStorage>> bindingRecordConverters_semantic;\n");
        },
    }
}

fn cppRecordArgumentEntryPlanValueType(e: *Emitter, entry: ir.CppRecordInput) Error![]const u8 {
    return e.print("std::pair<{s}, {s}>", .{ try e.cppType(e.ir.get(entry.key).value_type), try e.cppType(e.ir.get(entry.value).value_type) });
}

// ─── custom converters ───

fn emitCppConverterDefinitions(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.cpp_converter_declarations) |declaration| switch (declaration.body) {
        .external => {},
        .brand_cast => |cast| {
            try writer.print("namespace Bun::Bindgen::Custom {{\n\n{s} {s}({s}{s} value, WTF::ASCIILiteral)\n{{\n", .{
                try e.cppType(declaration.result),                                         declaration.symbol,
                if (declaration.realm_free) "" else "JSC::JSGlobalObject& globalObject, ", try e.cppType(declaration.input),
            });
            if (!declaration.realm_free) try writer.writeAll("    auto* global = &globalObject;\n");
            try writer.writeAll("    if (");
            const value = switch (cast.value) {
                .javascript => "value",
                .opaque_value => "Bun::Bindgen::Detail::CppAnyAccess::toJS(value)",
            };
            try emitCppBrandMatchExpression(e, writer, cast.brand, value);
            try writer.print(") {{\n        return {s};\n    }}\n    {s}\n}}\n\n}}\n\n", .{ value, switch (cast.mismatch) {
                .absent => "return std::nullopt;",
                .assert => "RELEASE_ASSERT_NOT_REACHED();",
            } });
        },
    };
}

fn emitCppEngineClassesHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#ifndef BUN_SCHEMA_BINDINGS_ENGINE_CLASSES_H
        \\#define BUN_SCHEMA_BINDINGS_ENGINE_CLASSES_H
        \\#include "root.h"
        \\#include "SchemaBindings.h"
        \\#include "ZigGlobalObject.h"
        \\
    );
    try emitEngineClassIncludes(e, writer);
    try writer.writeAll("namespace Bun {\n\nusing namespace JSC;\nusing namespace WebCore;\n\n");
    for (e.ir.engine_classes) |class_id| try emitCppClassDeclaration(e, writer, e.class(class_id));
    try writer.writeAll("namespace Bindgen {\nnamespace Cpp {\n\n");
    for (e.ir.engine_classes) |class_id| {
        const class = e.class(class_id);
        const constructor = e.function(class.constructor);
        if (constructor.exposed) try emitCppImplementationDeclaration(e, writer, e.ir.functionCpp(constructor));
        for (class.declarations) |member_id| {
            const member = e.function(member_id);
            if (!member.exposed or member.backend != .cpp) continue;
            try emitCppImplementationDeclaration(e, writer, e.ir.functionCpp(member));
        }
    }
    try writer.writeAll(
        \\}
        \\}
        \\}
        \\
    );
    for (e.ir.classes, e.ir.class_relations) |class, relations| {
        if (!class.exposed) continue;
        const dispatch = relations.engine_wrapper_dispatch orelse continue;
        // toJS lives in the impl's namespace so unqualified calls in
        // native code resolve through argument-dependent lookup.
        const impl_type = try e.cppType(dispatch.native_type);
        try writer.print("namespace {s} {{\n", .{cppTypeNamespace(impl_type)});
        try writer.print(
            \\JSC::JSValue toJS(JSC::JSGlobalObject*, WebCore::JSDOMGlobalObject*, {s}&);
            \\inline JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, WebCore::JSDOMGlobalObject* globalObject, {s}* impl)
            \\{{
            \\    return impl ? toJS(lexicalGlobalObject, globalObject, *impl) : JSC::jsNull();
            \\}}
            \\JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject*, WebCore::JSDOMGlobalObject*, Ref<{s}>&&);
            \\inline JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject* lexicalGlobalObject, WebCore::JSDOMGlobalObject* globalObject, RefPtr<{s}>&& impl)
            \\{{
            \\    return impl ? toJSNewlyCreated(lexicalGlobalObject, globalObject, impl.releaseNonNull()) : JSC::jsNull();
            \\}}
            \\}}
            \\
        , .{ impl_type, impl_type, impl_type, impl_type });
    }
    try writer.writeAll("#endif\n");
}

fn cppTypeNamespace(cpp_type: []const u8) []const u8 {
    return cpp_type[0..std.mem.lastIndexOf(u8, cpp_type, "::").?];
}

fn emitCppEngineNativeForwardDeclaration(writer: *Writer, cpp_type: []const u8) Error!void {
    const separator = std.mem.lastIndexOf(u8, cpp_type, "::").?;
    try writer.print("namespace {s} {{ class {s}; }}\n", .{ cpp_type[0..separator], cpp_type[separator + 2 ..] });
}

fn emitEngineClassIncludes(e: *Emitter, writer: *Writer) Error!void {
    try emitCppHeaderIncludes(writer, e.ir.engine_class_headers);
}

fn emitCppHeaderIncludes(writer: *Writer, headers: []const []const u8) Error!void {
    for (headers) |header| try writer.print("#include \"{s}\"\n", .{header});
    if (headers.len != 0) try writer.writeByte('\n');
}

fn emitStandaloneNativeExportHeader(e: *Emitter, writer: *Writer, header_plan: *const ir.StandaloneNativeExportHeaderPlan) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#include "SchemaBindingsWire.h"
        \\#ifdef __cplusplus
        \\#include <optional>
        \\#include <span>
        \\
    );
    for (header_plan.nominal_handle_declarations) |declaration| try emitCppDeclaration(e, writer, e.ir.get(declaration).*);
    try writer.writeAll("\nnamespace Bun::Bindgen::ZigExports {\n\n");
    for (header_plan.exports) |export_id| try emitNativeExportDeclaration(e, writer, e.ir.cpp_native_exports[export_id.index].?);
    try writer.writeAll("\n}\n#endif\n");
}

fn emitCppAggregateDeclarations(e: *Emitter, writer: *Writer, location: ir.CppAggregateLocation) Error!void {
    for (e.ir.cpp_type_definitions) |definition| {
        if (definition.location != location) continue;
        switch (definition.body) {
            .dictionary => |fields| try emitCppDictionaryDefinition(e, writer, definition, fields),
            .union_type => |members| try emitCppUnionDefinition(e, writer, definition, members),
        }
    }
}

fn emitCppDeclaration(e: *Emitter, writer: *Writer, declaration: ir.CppDeclaration) Error!void {
    const name = switch (declaration) {
        .structure, .class => |name| name,
        .alias => |alias| alias.name,
        .include => |include| {
            try writer.print("#include {s}{s}{s}\n", .{ if (include.system) "<" else "\"", include.path, if (include.system) ">" else "\"" });
            return;
        },
    };
    const separator = std.mem.lastIndexOf(u8, name, "::");
    if (separator) |index| try writer.print("namespace {s} {{ ", .{name[0..index]});
    const local = if (separator) |index| name[index + 2 ..] else name;
    switch (declaration) {
        .structure => try writer.print("struct {s};", .{local}),
        .class => try writer.print("class {s};", .{local}),
        .alias => |alias| try writer.print("using {s} = {s};", .{ local, try e.cppType(alias.type) }),
        .include => {},
    }
    if (separator != null) try writer.writeAll(" }");
    try writer.writeByte('\n');
}

fn emitCppHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#ifndef BUN_SCHEMA_BINDINGS_H
        \\#define BUN_SCHEMA_BINDINGS_H
        \\#include "root.h"
        \\#include "SchemaBindingsWire.h"
        \\#include "SchemaBindingsErrorCodes.h"
        \\#include "SchemaBindingsModuleRegistry.h"
        \\#include "SchemaBindingsEnumerations.h"
        \\#include "BunClientData.h"
        \\#include "StrongRef.h"
        \\#include <JavaScriptCore/Identifier.h>
        \\#include <JavaScriptCore/CallFrame.h>
        \\#include <JavaScriptCore/GetterSetter.h>
        \\#include <JavaScriptCore/JSCJSValue.h>
        \\#include <JavaScriptCore/IteratorOperations.h>
        \\#include <JavaScriptCore/JSDestructibleObject.h>
        \\#include <JavaScriptCore/LazyClassStructure.h>
        \\#include <JavaScriptCore/MarkedVector.h>
        \\#include <JavaScriptCore/SourceOrigin.h>
        \\#include <JavaScriptCore/StrongInlines.h>
        \\#include <JavaScriptCore/JSString.h>
        \\#include <array>
        \\#include <memory>
        \\#include <new>
        \\#include <optional>
        \\#include <span>
        \\#include <type_traits>
        \\#include <utility>
        \\#include <variant>
        \\#include <wtf/FixedVector.h>
        \\#include <wtf/NeverDestroyed.h>
        \\#include <wtf/RefPtr.h>
        \\#include <wtf/Vector.h>
        \\#include <wtf/text/ASCIILiteral.h>
        \\#include <wtf/text/WTFString.h>
        \\
        \\namespace JSC {
        \\class ArrayBuffer;
        \\class CallFrame;
        \\class JSGlobalObject;
        \\class JSObject;
        \\class VM;
        \\}
        \\namespace WebCore {
        \\class EventListener;
        \\}
        \\
    );
    try emitCppHeaderIncludes(writer, e.ir.external_ref_declaration_headers);
    for (e.ir.cpp_header_declarations) |id| try emitCppDeclaration(e, writer, e.ir.get(id).*);
    for (e.ir.modules) |module| {
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (class.exposed and class.representation == .native) try writer.print("struct {s};\n", .{try cppNativeClassOpaqueType(e, class)});
        }
    }
    for (e.ir.classes) |class| {
        if (!class.exposed) continue;
        switch (class.representation) {
            .engine => |engine| try emitCppEngineNativeForwardDeclaration(writer, try e.cppType(engine.native_type)),
            .native, .plain => {},
        }
    }
    try writer.writeAll(
        \\#include "Bindgen/BindingRuntimeDeclarations.h"
        \\#include "Bindgen/Completion.h"
        \\#include "Bindgen/NativeCell.h"
        \\#include "Bindgen/NativeResult.h"
        \\
        \\namespace Bun {
        \\namespace Bindgen {
        \\
    );
    try writer.print(
        \\class IdentifierTable final {{
        \\public:
        \\    explicit IdentifierTable(JSC::VM&);
        \\    const JSC::Identifier& at(size_t index) const
        \\    {{
        \\        RELEASE_ASSERT(index < m_values.size());
        \\        return m_values[index];
        \\    }}
        \\    JSC::JSString* enumerationString(JSC::VM&, size_t index);
        \\
        \\private:
        \\    std::array<JSC::Identifier, {d}> m_values;
        \\    std::array<JSC::Strong<JSC::JSString>, {d}> m_enumerationStrings;
        \\}};
        \\
        \\inline const JSC::Identifier& internedPropertyKey(JSC::VM& vm, size_t index)
        \\{{
        \\    return WebCore::clientData(vm)->bindgenIdentifiers().at(index);
        \\}}
        \\
        \\inline JSC::JSString* enumerationString(JSC::VM& vm, size_t index)
        \\{{
        \\    return WebCore::clientData(vm)->bindgenIdentifiers().enumerationString(vm, index);
        \\}}
        \\
    , .{ e.ir.interned_property_keys.len, e.ir.enumeration_strings.len });
    try emitCppAggregateDeclarations(e, writer, .public_header);
    try writer.writeAll("namespace Custom {\n\n");
    for (e.ir.cpp_converter_declarations) |declaration| {
        try writer.print("{s} {s}({s}{s}, WTF::ASCIILiteral);\n", .{
            try e.cppType(declaration.result),                            declaration.symbol,
            if (declaration.realm_free) "" else "JSC::JSGlobalObject&, ", try e.cppType(declaration.input),
        });
    }
    try writer.writeAll("}\n\nnamespace Cpp {\n\n");
    for (e.ir.cpp_domain_error_factories) |factory| {
        try writer.print("void {s}(Bun::Bindgen::EngineCallContext&", .{factory.symbol});
        if (factory.value_type) |value_type| try writer.print(", {s}", .{try e.cppType(value_type)});
        try writer.writeAll(");\n");
    }
    for (e.ir.modules) |module| {
        for (module.declarations) |function_id| {
            const function = e.function(function_id);
            if (!function.exposed or function.backend != .cpp) continue;
            try emitCppImplementationDeclaration(e, writer, e.ir.functionCpp(function));
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed) continue;
            if (e.ir.cpp_class_constructors[class.id.index]) |constructor_plan| switch (constructor_plan.call) {
                .function => |id| try emitCppImplementationDeclaration(e, writer, &e.ir.cpp_functions[id.index].?),
                .host => {},
            };
            if (class.representation == .engine) continue;
            if (class.representation == .plain) {
                const constructor = e.function(class.constructor);
                if (constructor.exposed) try emitCppImplementationDeclaration(e, writer, e.ir.functionCpp(constructor));
            }
            for (class.declarations) |member_id| {
                const member = e.function(member_id);
                if (member.exposed and member.backend == .cpp) try emitCppImplementationDeclaration(e, writer, e.ir.functionCpp(member));
            }
        }
    }
    try writer.writeAll("}\n\n");
    for (e.ir.modules) |module| {
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed or class.representation != .plain) continue;
            for (class.instance_properties, 0..) |property, property_index| {
                try writer.print("constexpr unsigned {s}_offset_{s} = {d};\n", .{ class.cpp_class_name, property.property_name, property_index });
            }
        }
    }
    try writer.writeAll("\nnamespace Engine {\n\n");
    for (e.ir.cpp_resources) |resource| switch (resource) {
        .nominal => |handle| {
            const owner = e.ir.get(handle.ownership);
            try writer.print("void {s}({s});\n", .{ owner.cpp_release, try e.cppType(handle.native_type) });
            if (owner.byte_access) |access| {
                try writer.print("std::span<const uint8_t> {s}({s});\n", .{ access.cpp_read, try e.cppType(handle.native_type) });
            }
        },
        .external => {},
    };
    try writer.writeByte('\n');
    for (e.ir.modules) |module| {
        for (module.engine_declarations) |shim_id| try emitEngineImplementationDeclaration(e, writer, shim_id);
    }
    try writer.writeAll("}\n\nnamespace ZigExports {\n\n");
    for (e.ir.modules) |module| {
        for (module.native_declarations) |export_id| {
            const native_export = e.nativeExport(export_id);
            if (native_export.exposed) {
                const cpp = e.ir.cpp_native_exports[export_id.index].?;
                try emitNativeExportDeclaration(e, writer, cpp);
                if (cpp.surface) |surface| {
                    try emitCppNativeSignature(e, writer, surface.signature);
                    try writer.writeAll(";\n");
                }
            }
        }
    }
    try writer.writeAll(
        \\}
        \\}
        \\
    );
    try writer.writeAll("using namespace JSC;\nusing namespace WebCore;\n\n");
    for (e.ir.cpp_header_classes) |class_id| try emitCppClassDeclaration(e, writer, e.class(class_id));
    for (e.ir.promise_reaction_contexts) |context| try emitCppPromiseReactionContextDeclaration(e, writer, context);
    for (e.ir.modules) |module| {
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (class.exposed) try writer.print("void {s}(JSC::LazyClassStructure::Initializer&);\n", .{class.initialize_symbol});
        }
    }
    try writer.writeAll("}\n\n");
    try writer.writeAll(
        \\namespace WebCore {
        \\class CloneSerializer;
        \\class CloneDeserializer;
        \\using StructuredCloneableSerializeFunction = void (*)(void*, JSC::JSGlobalObject*, CloneSerializer*);
        \\
        \\class StructuredCloneableSerialize {
        \\public:
        \\    enum class UnsupportedContext : uint8_t {
        \\        Reject,
        \\        EmptyObject,
        \\    };
        \\
        \\    StructuredCloneableSerializeFunction function;
        \\    uint8_t tag { 0 };
        \\    void* impl { nullptr };
        \\    bool isForTransfer { false };
        \\    bool isForStorage { false };
        \\    UnsupportedContext unsupportedContext { UnsupportedContext::Reject };
        \\
        \\    void write(CloneSerializer* serializer, JSC::JSGlobalObject* global)
        \\    {
        \\        function(impl, global, serializer);
        \\    }
        \\};
        \\}
        \\
        \\namespace Bun {
        \\bool bindgenStructuredCloneSerialize(JSC::JSValue, WebCore::StructuredCloneableSerialize&);
        \\bool bindgenStructuredCloneDeserialize(uint8_t, JSC::JSGlobalObject*, const uint8_t*&, const uint8_t*, JSC::EncodedJSValue&, WebCore::CloneDeserializer*);
        \\
    );
    for (e.ir.structured_clone_modules) |module| {
        try writer.print("bool bunBindgenStructuredCloneSerializeModule{d}(JSC::JSValue, WebCore::StructuredCloneableSerialize&);\n", .{module.index});
        try writer.print("bool bunBindgenStructuredCloneDeserializeModule{d}(uint8_t, JSC::JSGlobalObject*, const uint8_t*&, const uint8_t*, JSC::EncodedJSValue&, WebCore::CloneDeserializer*);\n", .{module.index});
    }
    try writer.writeAll("}\n\n");
    for (e.ir.modules) |*module| {
        for (module.declarations) |function_id| {
            const function = e.function(function_id);
            if (!function.exposed) continue;
            if (e.ir.cpp_function_factories[function_id.index]) |factory| switch (factory.abi) {
                .value => try writer.print("JSC::JSValue {s}(Zig::GlobalObject*) noexcept;\n", .{factory.symbol}),
                .reference => {},
            };
            switch (e.ir.functionCpp(function).*) {
                .call => |body| {
                    if (body.surface) |surface| try writer.print("JSC::JSValue {s}(JSC::JSGlobalObject*, JSC::JSValue) noexcept;\n", .{surface.symbol});
                    try emitCppHostDeclaration(writer, body.host);
                },
                .overload => |dispatch| try emitCppHostDeclaration(writer, dispatch.host),
                .builtin => {},
            }
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed) continue;
            if (e.ir.cpp_class_constructors[class_id.index]) |constructor| {
                try writer.print(
                    \\inline JSC::JSValue {s}_value(JSC::JSGlobalObject* global)
                    \\{{
                    \\    BindEncodedJSValue encoded;
                    \\    {s}(reinterpret_cast<BindGlobalObjectHandle*>(global), &encoded);
                    \\    return decodeBindingValue(encoded);
                    \\}}
                    \\
                , .{ class.get_constructor_symbol, class.get_constructor_symbol });
                try writer.print(
                    \\inline JSC::JSValue {s}(JSC::JSGlobalObject* global)
                    \\{{
                    \\    return {s}_value(global);
                    \\}}
                    \\
                , .{ constructor.factory_symbol, class.get_constructor_symbol });
            }
            const native_pointer_type = switch (class.representation) {
                .plain => continue,
                .engine => |engine| try e.print("{s}*", .{try e.cppType(engine.native_type)}),
                .native => try cppNativeClassPointerType(e, class),
            };
            for ([_][]const u8{ class.try_cast_symbol, class.try_cast_direct_symbol }) |symbol| {
                try writer.print(
                    \\inline {s} {s}_value(JSC::JSValue value)
                    \\{{
                    \\    return reinterpret_cast<{s}>({s}(encodeBindingValue(value)));
                    \\}}
                    \\
                , .{ native_pointer_type, symbol, native_pointer_type, symbol });
            }
            if (class.representation != .engine) {
                try writer.print(
                    \\inline JSC::JSValue {s}_value(JSC::JSGlobalObject* global, BindNativeHandle* native)
                    \\{{
                    \\    return Bun::Bindgen::bindingClassWrapValue(global, native, {s});
                    \\}}
                    \\
                , .{ class.wrap_native_symbol, class.wrap_native_symbol });
            }
            for (class.slots) |slot| {
                try writer.print(
                    \\inline JSC::JSValue {s}_value(JSC::JSValue wrapper)
                    \\{{
                    \\    auto* value = {s}(encodeBindingValue(wrapper));
                    \\    RELEASE_ASSERT(value);
                    \\    return *reinterpret_cast<const JSC::JSValue*>(value);
                    \\}}
                    \\
                , .{ slot.get_symbol, slot.get_symbol });
                if (slot.write) |write| {
                    try writer.print(
                        \\inline void {s}_value(JSC::JSGlobalObject* global, JSC::JSValue wrapper, JSC::JSValue value)
                        \\{{
                        \\    {s}(
                        \\        reinterpret_cast<BindGlobalObjectHandle*>(global),
                        \\        encodeBindingValue(wrapper),
                        \\        static_cast<BindEncodedJSValue>(JSC::JSValue::encode(value)));
                        \\}}
                        \\
                    , .{ write.set, write.set });
                }
            }
        }
    }
    try writer.writeAll("#endif\n");
}

fn emitCppEnumerationsHeader(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\#pragma once
        \\#include "Bindgen/Enumeration.h"
        \\namespace Bun::Bindgen {
        \\
    );
    for (e.ir.enumerations, 0..) |enumeration, index| {
        if (enumeration.header != .shared) continue;
        try emitCppEnumerationDeclaration(e, writer, .of(index));
        const name = enumeration.cpp_name;
        try writer.print("template<> struct EnumerationTraits<{s}> {{\n", .{name});
        try writer.print("    static constexpr std::array<EnumerationEntry<{s}>, {d}> entries {{{{\n", .{ name, enumeration.enumeration_values.len });
        for (enumeration.enumeration_values) |value| {
            try writer.print("        {{ {s}::{s}, std::string_view {{ ", .{ name, value.value_name });
            try emitCppRawStringLiteral(writer, value.js_value);
            try writer.print(", {d} }} }},\n", .{value.js_value.len});
        }
        try writer.writeAll("    }};\n};\n\n");
    }
    try writer.writeAll("}\n");
}

fn emitCppEnumerationDeclaration(e: *Emitter, writer: *Writer, id: ir.EnumerationId) Error!void {
    const enumeration = e.ir.get(id);
    try writer.print("enum class {s} : {s} {{\n", .{ enumeration.cpp_name, switch (enumeration.tag) {
        .u8 => "uint8_t",
        .u16 => "uint16_t",
    } });
    for (enumeration.enumeration_values) |value| try writer.print("    {s} = {d},\n", .{ value.value_name, value.native_value });
    try writer.writeAll("};\n\n");
}

fn emitCppEnumerationValidityExpression(writer: *Writer, tags: []const u16, expression: []const u8) Error!void {
    try writer.writeByte('(');
    for (tags, 0..) |value, index| {
        if (index != 0) try writer.writeAll(" || ");
        try writer.print("{s} == {d}", .{ expression, value });
    }
    try writer.writeByte(')');
}

// ─── shards ───

fn cppModuleWeight(e: *const Emitter, module: ir.Module) usize {
    var weight = 1 + module.declarations.len * 16 + module.engine_declarations.len * 8 + module.native_declarations.len * 8;
    for (module.class_declarations) |class_id| weight += 64 + e.class(class_id).declarations.len * 16;
    return weight;
}

/// Balances modules across C++ shards, heaviest first.
fn assignCppShards(e: *Emitter) Allocator.Error![]const u32 {
    const count = e.ir.modules.len;
    const weights = try e.arena.alloc(usize, count);
    for (e.ir.modules, weights) |module, *weight| weight.* = cppModuleWeight(e, module);
    const result = try e.arena.alloc(u32, count);
    const assigned = try e.arena.alloc(bool, count);
    @memset(assigned, false);
    const shard_weights = try e.arena.alloc(usize, e.cpp_shard_count);
    @memset(shard_weights, 0);
    for (0..count) |_| {
        var module_index: ?usize = null;
        for (weights, 0..) |weight, candidate| {
            if (!assigned[candidate] and (module_index == null or weight > weights[module_index.?])) module_index = candidate;
        }
        var shard: usize = 0;
        for (shard_weights[1..], 1..) |weight, candidate| {
            if (weight < shard_weights[shard]) shard = candidate;
        }
        result[module_index.?] = @intCast(shard);
        assigned[module_index.?] = true;
        shard_weights[shard] += weights[module_index.?];
    }
    return result;
}

fn emitCppShardBegin(writer: *Writer, shard: u32) Error!void {
    try writer.print("#if BUN_BINDGEN_SHARD == {d}\n", .{shard});
}

fn emitCppShardEnd(writer: *Writer) Error!void {
    try writer.writeAll("#endif\n\n");
}

/// Strings already emitted into one translation unit.
const CppStringSet = struct {
    values: std.StringHashMapUnmanaged(void) = .empty,

    fn insert(set: *CppStringSet, arena: Allocator, value: []const u8) Allocator.Error!bool {
        const entry = try set.values.getOrPut(arena, value);
        return !entry.found_existing;
    }
};

fn emitCppSourceHeader(e: *Emitter, writer: *Writer, headers: *CppStringSet, header: []const u8, system: bool) Error!void {
    if (!try headers.insert(e.arena, header)) return;
    if (system) {
        try writer.print("#include <{s}>\n", .{header});
    } else {
        try writer.print("#include \"{s}\"\n", .{header});
    }
}

// ─── C++ sources ───

fn emitCppSource(e: *Emitter, writer: *Writer, selected_shard: u32) Error!void {
    try writer.print(
        \\#ifndef BUN_BINDGEN_SHARD
        \\#define BUN_BINDGEN_SHARD {d}
        \\#endif
        \\#if BUN_BINDGEN_SHARD < 0 || BUN_BINDGEN_SHARD >= {d}
        \\#error "invalid binding C++ shard"
        \\#endif
        \\
    , .{ selected_shard, e.cpp_shard_count });
    var source_headers: CppStringSet = .{};
    for ([_][]const u8{
        "root.h",
        "SchemaBindings.h",
        "AsyncContextFrame.h",
        "BunBuiltinNames.h",
        "WebCoreJSBuiltins.h",
        "BunIDLConvert.h",
        "Bindgen/IDLConvertBase.h",
        "Bindgen/NumericConversion.h",
        "Bindgen/BooleanConversion.h",
        "JSDOMBinding.h",
        "JSDOMConvertBoolean.h",
        "JSDOMConvertNumbers.h",
        "JSDOMConvertStrings.h",
        "JSDOMExceptionHandling.h",
        "JSDOMException.h",
        "JSDOMURL.h",
        "ErrorCode.h",
        "ErrorBindings.h",
        "ObjectBindings.h",
        "BunClientData.h",
        "JSFFIFunction.h",
        "StrongRef.h",
        "ZigGlobalObject.h",
        "SchemaBindingsEngineClasses.h",
        "SerializedScriptValue.h",
    }) |header| try emitCppSourceHeader(e, writer, &source_headers, header, false);
    for ([_][]const u8{
        "JavaScriptCore/ArrayBuffer.h",
        "JavaScriptCore/JSCInlines.h",
        "JavaScriptCore/PureNaN.h",
        "JavaScriptCore/FunctionPrototype.h",
        "JavaScriptCore/JSIteratorPrototype.h",
        "JavaScriptCore/AsyncIteratorPrototype.h",
        "JavaScriptCore/HeapAnalyzer.h",
        "JavaScriptCore/JSArrayBuffer.h",
        "JavaScriptCore/JSArrayBufferView.h",
        "JavaScriptCore/JSBoundFunction.h",
        "JavaScriptCore/JSDestructibleObject.h",
        "JavaScriptCore/JSGenericTypedArrayViewInlines.h",
        "JavaScriptCore/InternalFunction.h",
        "JavaScriptCore/ObjectInitializationScope.h",
        "JavaScriptCore/ObjectConstructor.h",
        "JavaScriptCore/PropertyNameArray.h",
        "JavaScriptCore/JSPromise.h",
        "JavaScriptCore/MarkedVector.h",
        "JavaScriptCore/StrongInlines.h",
        "JavaScriptCore/WeakGCMapInlines.h",
        "JavaScriptCore/WeakInlines.h",
        "algorithm",
        "atomic",
        "bit",
        "cstring",
        "limits",
        "new",
        "span",
        "type_traits",
        "utility",
        "wtf/FastMalloc.h",
        "wtf/Threading.h",
        "wtf/Vector.h",
        "wtf/text/ExternalStringImpl.h",
        "wtf/text/StringImpl.h",
    }) |header| try emitCppSourceHeader(e, writer, &source_headers, header, true);
    try emitCppValueEncodingContract(writer);
    for (e.ir.cpp_source_dependencies) |dependency| {
        const header = switch (dependency) {
            .header => |header| header,
            .type_predicates => "BindgenTypePredicates.h",
            .brand_match => |id| switch (e.ir.get(id).*) {
                .value, .realm => |matcher| matcher.header,
                .dynamic_cast => |matcher| matcher.header,
                .class_instance => "SchemaBindings.h",
            },
        };
        try emitCppSourceHeader(e, writer, &source_headers, header, false);
    }
    try writer.writeByte('\n');
    for (e.ir.cpp_source_dependencies) |dependency| switch (dependency) {
        .header, .type_predicates => {},
        .brand_match => |id| try emitCppBrandContract(e, writer, id),
    };
    try writer.writeAll("\n#include \"Bindgen/BindingRuntime.h\"\n#include \"SchemaBindingsConverters.h\"\n\n");
    if (selected_shard == 0) {
        try emitCppShardBegin(writer, 0);
        try emitCppLazyFieldProtocols(e, writer);
        for (e.ir.cpp_resources) |resource| switch (resource) {
            .external => |external| try emitCppExternalRef(e, writer, e.ir.get(external).*),
            .nominal => |handle| try emitCppNominalHandle(e, writer, handle),
        };
        try emitCppConverterDefinitions(e, writer);
        try writer.print(
            \\extern "C" __attribute__((used, retain, visibility("default"))) const uint8_t {s} = 0;
            \\extern "C" void bun_bindgen_zig_fingerprint_anchor() noexcept;
            \\extern "C" __attribute__((used, retain, visibility("default"))) void (*const bun_bindgen_zig_fingerprint_anchor_reference)() = bun_bindgen_zig_fingerprint_anchor;
            \\
        , .{e.fingerprint_symbol});
        try writer.writeAll("#include \"Bindgen/WrapperRegistry.h\"\n#include \"Bindgen/PlainClassDiagnostics.h\"\n\n");
        for (e.ir.cpp_callback_calls) |*maybe| if (maybe.*) |*call| try emitCppOutboundCall(e, writer, call);
        try writer.writeAll("#include \"Bindgen/PromiseReactions.h\"\n\n");
        for (e.ir.promise_reaction_contexts) |context| try emitCppPromiseReactionContextDefinition(e, writer, context);
        try emitCppShardEnd(writer);
    }
    for (e.ir.modules, 0..) |module, module_index| {
        if (e.cpp_shards[module_index] != selected_shard) continue;
        try emitCppShardBegin(writer, selected_shard);
        for (module.engine_declarations) |shim_id| {
            try emitCppOutboundCall(e, writer, &e.ir.cpp_engine_calls[shim_id.index]);
            if (e.ir.cpp_engine_entries[shim_id.index]) |entry| try emitCppNativeEntry(e, writer, entry);
        }
        try emitCppShardEnd(writer);
    }
    for (e.ir.modules, 0..) |module, module_index| {
        if (e.cpp_shards[module_index] != selected_shard) continue;
        try emitCppShardBegin(writer, selected_shard);
        for (module.native_declarations) |export_id| {
            const native_export = e.nativeExport(export_id);
            if (!native_export.exposed) continue;
            const cpp = e.ir.cpp_native_exports[export_id.index].?;
            try emitCppLazyConverters(e, writer, cpp.entry.call);
            try emitCppNativeEntry(e, writer, cpp.entry);
            if (cpp.surface) |surface| try emitCppNativeEntry(e, writer, surface);
        }
        try emitCppShardEnd(writer);
    }
    for (e.ir.modules, 0..) |*module, module_index| {
        if (e.cpp_shards[module_index] != selected_shard) continue;
        try emitCppShardBegin(writer, selected_shard);
        for (module.declarations) |function_id| {
            const function = e.function(function_id);
            try emitCppFunctionCompletions(e, writer, function);
            if (!function.exposed) continue;
            try emitCppFunctionLazyConverters(e, writer, e.ir.functionCpp(function));
            try emitCppHostFunction(e, writer, e.ir.functionCpp(function));
            switch (e.ir.functionCpp(function).*) {
                .builtin, .overload => {},
                .call => |body| if (body.surface) |surface| try emitSurfaceFunctionEvaluator(e, writer, surface),
            }
            if (e.ir.cpp_function_factories[function_id.index]) |factory| try emitFunctionFactory(e, writer, factory);
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (class.exposed) try emitCppClass(e, writer, class);
        }
        try emitCppStructuredCloneModule(e, writer, module_index);
        try emitCppShardEnd(writer);
    }
    if (selected_shard == 0) {
        try emitCppShardBegin(writer, 0);
        try emitCppStructuredCloneRegistry(e, writer);
        for (e.ir.cpp_domain_error_factories) |*domain_error| try emitCppDomainErrorRaiser(e, writer, domain_error);
        try emitCppShardEnd(writer);
    }
}

fn emitCppExternalRef(e: *Emitter, writer: *Writer, external: ir.ExternalRef) Error!void {
    const handle = try e.wireSpelling(external.wire);
    const cpp_type = try e.cppType(external.cpp_type);
    const cpp_idl = try e.cppType(external.cpp_idl);
    try emitCppExternC(writer, "{s}* {s}(const {s}* handle)",
        \\{{
        \\    RELEASE_ASSERT(handle);
        \\    using Implementation = typename {s}::ImplementationType;
        \\    auto* value = const_cast<{s}*>(reinterpret_cast<const {s}*>(handle));
        \\    return reinterpret_cast<{s}*>(Implementation::RefDerefTraits::refIfNotNull(value));
        \\}}
        \\
    , .{ handle, external.clone_symbol, handle, cpp_idl, cpp_type, cpp_type, handle });
    try emitCppExternC(writer, "void {s}({s}* handle)",
        \\{{
        \\    RELEASE_ASSERT(handle);
        \\    using Implementation = typename {s}::ImplementationType;
        \\    Implementation::RefDerefTraits::derefIfNotNull(reinterpret_cast<{s}*>(handle));
        \\}}
        \\
    , .{ external.release_symbol, handle, cpp_idl, cpp_type });
}

fn emitCppNominalHandle(e: *Emitter, writer: *Writer, handle: ir.CppNominalHandle) Error!void {
    const ownership = e.ir.get(handle.ownership);
    try emitCppExternC(writer, "void {s}({s}* handle)",
        \\{{
        \\    RELEASE_ASSERT(handle);
        \\    Bun::Bindgen::Engine::{s}(reinterpret_cast<{s}>(handle));
        \\}}
        \\
    , .{ ownership.release_symbol, try e.wireSpelling(handle.wire), ownership.cpp_release, try e.cppType(handle.native_type) });
    const access = ownership.byte_access orelse return;
    try emitCppExternC(writer, "void {s}({s}* handle, BindConstByteSlice* out)",
        \\{{
        \\    RELEASE_ASSERT(handle && out);
        \\    encodeBindingSlice(Bun::Bindgen::Engine::{s}(reinterpret_cast<{s}>(handle)), *out);
        \\}}
        \\
    , .{ access.symbol, try e.wireSpelling(handle.wire), access.cpp_read, try e.cppType(handle.native_type) });
}

fn emitCppLazyFieldProtocols(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.rolePlans(.inbound_argument), 0..) |position, index| {
        const lazy = position.cpp.lazy_field orelse continue;
        const input = e.ir.get(lazy.input);
        const protocol: ir.InboundArgumentPlanId = .of(index);
        const child = e.ir.get(lazy.input.position);
        const key = ir.lazyFieldKey(protocol);
        for ([_]bool{ false, true }) |discard| {
            const symbol = if (discard) try lazyFieldDiscardSymbol(e, lazy.symbol) else try lazyFieldConvertSymbol(e, lazy.symbol);
            try emitCppExternC(writer, "BindStatus {s}(BindGlobalObjectHandle* globalHandle, BindLazyArgumentHandle* valueHandle, BindDeferredConversionsHandle* deferredHandle, uint8_t last, BindDeferredConversionsHandle** proof{s})", "{{\n    RELEASE_ASSERT(globalHandle && valueHandle && last <= 1);\n    RELEASE_ASSERT(!last || (deferredHandle && proof));\n    if (proof) *proof = nullptr;\n", .{ symbol, if (discard) "" else try e.print(", {s}* out", .{try e.wireSpelling(child.wire)}) });
            if (!discard) try writer.writeAll("    RELEASE_ASSERT(out);\n    *out = {};\n");
            try writer.writeAll("    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);\n    return invokeBindingStatusEntry(global, [&]() -> BindStatus {\n    auto scope = DECLARE_THROW_SCOPE(global->vm());\n");
            try writer.writeAll("    auto& base = *reinterpret_cast<Bun::Bindgen::Detail::CppLazyArgumentStateBase*>(valueHandle);\n    base.requireContext(global, reinterpret_cast<Bun::Bindgen::BindingDeferredConversions*>(deferredHandle));\n");
            try writer.print("    base.requireWireKey({d});\n", .{key});
            try writer.print("    auto& state = static_cast<Bun::Bindgen::Detail::CppLazyArgumentState<{s}>&>(base);\n", .{try e.cppType(input.value_type)});
            try writer.writeAll("    Bun::Bindgen::CppDeferredLeaseProof cppProof;\n");
            if (discard) {
                try writer.writeAll("    if (last) state.discardLast(cppProof);\n    else state.discard();\n");
            } else {
                try writer.writeAll("    if (!(last ? state.convertLast(cppProof) : state.convert())) return BIND_STATUS_PENDING_EXCEPTION;\n");
            }
            try writer.writeAll("    if (bindingExceptionAfterDispatch(scope, BIND_STATUS_OK)) return BIND_STATUS_PENDING_EXCEPTION;\n");
            if (!discard) try writer.print("    state.copyWire({d}, *out);\n", .{key});
            try writer.writeAll("    if (last) *proof = deferredHandle;\n    return BIND_STATUS_OK;\n    });\n}\n\n");
        }
    }
}

fn emitCppLazyConverters(e: *Emitter, writer: *Writer, call: *const ir.CppInboundCall(.inbound_argument)) Error!void {
    const storage = switch (call.callee) {
        .wire => |callee| callee.lazy_storage orelse return,
        .builtin_constructor, .predicate, .reject, .load_cache, .store_cache, .cpp => return,
    };
    for (storage.converters) |converter| try emitCppLazyConverter(e, writer, converter);
    try writer.print("struct {s} {{\n", .{storage.symbol});
    if (storage.receiver) try writer.writeAll("    BindingRootedValue receiver;\n");
    for (storage.converters) |converter| {
        const index = converter.index;
        try writer.print("    {s}<{s}_Storage{s}> argument_{d};\n", .{
            if (converter.rest) "WTF::Vector<std::unique_ptr" else "std::optional",
            try lazyConvertSymbol(e, converter.symbol),
            if (converter.rest) ">" else "",
            index,
        });
    }
    try writer.writeAll("};\n\n");
    for (storage.converters) |converter| {
        try emitCppLazyConverterEntry(e, writer, converter, storage.symbol);
        if (converter.discard) try emitCppLazyDiscardEntry(e, writer, converter, storage.symbol);
    }
}

fn emitCppLazyDiscardEntry(e: *Emitter, writer: *Writer, converter: ir.CppLazyConversion, storage_name: []const u8) Error!void {
    const index = converter.index;
    const rest = converter.rest;
    try emitCppExternC(writer, "BindStatus {s}(BindGlobalObjectHandle* globalHandle, BindLazyStorageHandle* storageHandle, BindDeferredConversionsHandle* deferredHandle, uint8_t last, {s} valueHandle{s}, BindDeferredConversionsHandle** proof)",
        \\{{
        \\    RELEASE_ASSERT(globalHandle && storageHandle && deferredHandle && valueHandle && proof && last <= 1);
        \\    *proof = nullptr;
        \\    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
        \\    return invokeBindingStatusEntry(global, [&]() -> BindStatus {{
        \\    auto& vm = global->vm();
        \\    auto scope = DECLARE_THROW_SCOPE(vm);
        \\    auto& storage = *reinterpret_cast<{s}*>(storageHandle);
        \\
    , .{ try lazyDiscardSymbol(e, converter.symbol), if (rest) "const BindJSValueHandle*" else "BindLazyArgumentHandle*", if (rest) ", size_t elementIndex" else "", storage_name });
    if (rest) try writer.print("    RELEASE_ASSERT(elementIndex < storage.argument_{0d}.size());\n", .{index});
    try writer.print("    auto& slot = storage.argument_{d}{s};\n    RELEASE_ASSERT(slot);\n", .{ index, if (rest) "[elementIndex]" else "" });
    try writer.writeAll(if (rest)
        "    RELEASE_ASSERT(JSC::JSValue::encode(slot->value()) == JSC::JSValue::encode(borrowBindingValue(valueHandle)));\n"
    else
        "    RELEASE_ASSERT(valueHandle == Bun::Bindgen::Detail::CppArgumentAccess::lazyHandle(slot->view()));\n");
    try writer.writeAll(
        \\    slot->requireContext(global, reinterpret_cast<Bun::Bindgen::BindingDeferredConversions*>(deferredHandle));
        \\    Bun::Bindgen::CppDeferredLeaseProof cppProof;
        \\    if (last) slot->discardLast(cppProof);
        \\    else slot->discard();
        \\    if (bindingExceptionAfterDispatch(scope, BIND_STATUS_OK)) return BIND_STATUS_PENDING_EXCEPTION;
        \\    if (last) *proof = deferredHandle;
        \\    return BIND_STATUS_OK;
        \\    });
        \\}
        \\
    );
}

fn emitCppLazyConverterEntry(e: *Emitter, writer: *Writer, converter: ir.CppLazyConversion, storage_name: []const u8) Error!void {
    const index = converter.index;
    const rest = converter.rest;
    const convert_symbol = try lazyConvertSymbol(e, converter.symbol);
    try emitCppExternC(writer, "BindStatus {s}(BindGlobalObjectHandle* globalHandle, BindLazyStorageHandle* storageHandle, BindDeferredConversionsHandle* deferredHandle, uint8_t last, {s} valueHandle{s}, BindDeferredConversionsHandle** proof, {s}* out)",
        \\{{
        \\    RELEASE_ASSERT(globalHandle && storageHandle && valueHandle && out && last <= 1);
        \\    RELEASE_ASSERT(!last || (deferredHandle && proof));
        \\    if (proof) *proof = nullptr;
        \\    *out = {{}};
        \\    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
        \\    return invokeBindingStatusEntry(global, [&]() -> BindStatus {{
        \\    auto& storage = *reinterpret_cast<{s}*>(storageHandle);
        \\
    , .{
        convert_symbol,
        if (rest) "const BindJSValueHandle*" else "BindLazyArgumentHandle*",
        if (rest) ", size_t elementIndex" else "",
        try e.wireSpelling(converter.result_wire),
        storage_name,
    });
    const slot = try e.print("storage.argument_{d}", .{index});
    if (rest) {
        try writer.writeAll("    JSC::JSValue input = borrowBindingValue(valueHandle);\n");
        try writer.print("    RELEASE_ASSERT(elementIndex < {0s}.size() && {0s}[elementIndex]);\n", .{slot});
    } else {
        try writer.print("    RELEASE_ASSERT({s} && valueHandle == Bun::Bindgen::Detail::CppArgumentAccess::lazyHandle({s}->view()));\n", .{ slot, slot });
    }
    try writer.print(
        \\    auto& state = *{s}{s};
        \\    {s}
        \\    state.requireContext(global, reinterpret_cast<Bun::Bindgen::BindingDeferredConversions*>(deferredHandle));
        \\    Bun::Bindgen::CppDeferredLeaseProof cppProof;
        \\    if (!(last ? state.convertLast(cppProof) : state.convert())) return BIND_STATUS_PENDING_EXCEPTION;
        \\    if (last) *proof = deferredHandle;
        \\    out->value = state.convertedValue;
        \\    return BIND_STATUS_OK;
        \\}});
        \\}}
        \\
    , .{
        slot,
        if (rest) "[elementIndex]" else "",
        if (rest) "RELEASE_ASSERT(JSC::JSValue::encode(state.value()) == JSC::JSValue::encode(input));" else "",
    });
}

fn emitCppLazyConverter(e: *Emitter, writer: *Writer, conversion: ir.CppLazyConversion) Error!void {
    const index = conversion.index;
    const input = e.ir.get(conversion.conversion.value);
    const prepare_receiver_bound = receiverByteLengthBoundAtPreparation(input.*);
    const suffix = try e.print("lazy_argument_{d}", .{index});
    const forwards_receiver = input.call_receiver;
    const converter_context: CppConversionBindings = .{
        .deferred = "bindingDeferredConversionsPointer",
        .receiver = if (forwards_receiver) "bindingConverterReceiver" else "JSC::JSValue(global)",
    };
    const selects_iterator = conversion.prepared_input;
    const value_type = try e.cppType(input.value_type);
    try writer.print(
        \\struct {0s}_Storage final : Bun::Bindgen::Detail::CppLazyArgumentState<{1s}> {{
        \\    using Base = Bun::Bindgen::Detail::CppLazyArgumentState<{1s}>;
        \\    {0s}_Storage(JSC::JSGlobalObject& global, JSC::JSValue value, const BindingConversionInput* prepared, Bun::Bindgen::BindingDeferredConversions* deferred, size_t index{3s})
        \\        : Base(global, *this, deferred, {2d}), global(&global), rootedInput(global.vm(), value), preparedInput(prepared), bindingDeferredConversionsPointer(deferred), elementIndex(index){4s}{5s} {{}}
        \\    JSC::JSGlobalObject* global;
        \\    BindingRootedValue rootedInput;
        \\    const BindingConversionInput* preparedInput;
        \\    Bun::Bindgen::BindingDeferredConversions* bindingDeferredConversionsPointer;
        \\    size_t elementIndex;
        \\{6s}{7s}
        \\    JSC::JSValue value() const {{ return rootedInput.get(); }}
        \\
    , .{
        try lazyConvertSymbol(e, conversion.symbol),
        value_type,
        ir.lazyFieldKey(conversion.conversion.protocol),
        if (forwards_receiver) ", JSC::JSValue receiver" else "",
        if (forwards_receiver) ", bindingConverterReceiver(receiver)" else "",
        if (prepare_receiver_bound) ", bindingPreparedReceiverByteLength(WTF::uncheckedDowncast<JSC::JSArrayBufferView>(receiver)->byteLength())" else "",
        if (forwards_receiver) "    JSC::JSValue bindingConverterReceiver;" else "",
        if (prepare_receiver_bound) "\n    uint64_t bindingPreparedReceiverByteLength;" else "",
    });
    try emitCppConverterValueStorage(e, writer, conversion.conversion.value, suffix, 4);
    const wire_type = try e.wireSpelling(e.ir.get(conversion.conversion.value.position).wire);
    try writer.print("    {s} logicalValue {{}};\n", .{value_type});
    try writer.print("    {s} convertedValue {{}};\n", .{wire_type});
    try writer.writeAll("    BindingTemporaryWireStorage wireStorage;\n");
    try writer.print("    void copyWire(void* output) const noexcept {{ *static_cast<{s}*>(output) = convertedValue; }}\n", .{wire_type});
    try writer.print("    const {s}* operator()() noexcept {{ return convertValue() ? &logicalValue : nullptr; }}\n", .{value_type});
    try writer.writeAll(
        \\    bool convertValue()
        \\    {
        \\    auto& vm = JSC::getVM(global);
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\    const auto& input = *this;
        \\    static_cast<void>(elementIndex);
        \\
    );
    if (selects_iterator) try writer.writeAll(
        \\    BindingConversionInput unselectedInput(input.value());
        \\    const auto& source = preparedInput ? *preparedInput : unselectedInput;
        \\
    );
    switch (conversion.path) {
        .value => |root| try emitCppInputPlanValue(e, writer, converter_context, conversion.conversion.value, .{ .value = "input.value()", .prepared = if (selects_iterator) "source" else null }, "logicalValue", cppPath(root), suffix, 4),
        .element => |element| try emitCppStringConversionTo(e, writer, element.conversion, "input.value()", "logicalValue", CppIndexedStringPath{ .root = element.name, .index = "elementIndex" }, try e.print("conversionContext_{s}", .{suffix}), 4),
    }
    try emitCppInputEncode(e, writer, input.encoder, "logicalValue", "convertedValue", .{ .suffix = suffix }, 4);
    if (input.holds_byte_lease) {
        try writer.writeAll("    RELEASE_ASSERT(bindingDeferredConversionsPointer);\n    {\n        auto& bindingDeferredConversions = *bindingDeferredConversionsPointer;\n");
        try emitCppSemanticConverterValueLeaseRegistration(e, writer, conversion.conversion.value, suffix);
        try writer.writeAll("    }\n");
    }
    try writer.writeAll(
        \\    if (materializeBindingException(throwScope)) return false;
        \\    throwScope.release();
        \\    return true;
        \\    }
        \\};
        \\
    );
}

// ─── engine shims and native exports ───

fn cppOutboundInvokeContext(invoke: ir.CppOutboundInvoke) ir.CppOutboundContext {
    return switch (invoke.callee) {
        .native => |native| native.context,
        .callback => .{ .current = .exception },
    };
}

fn cppOutboundChecks(context: ir.CppOutboundContext) bool {
    return switch (context) {
        .none => false,
        .current => |scope| scope != .unchecked,
    };
}

fn emitCppOutboundNativeArguments(e: *Emitter, writer: *Writer, native: ir.CppOutboundNativeCall) Error!void {
    if (native.context != .none) try writer.writeAll(
        \\    auto* bindingDeferredConversionsPointer = reinterpret_cast<Bun::Bindgen::BindingDeferredConversions*>(context->deferred_conversions);
        \\    Bun::Bindgen::EngineCallContext engineContext { *global, bindingDeferredConversionsPointer };
        \\
    );
    try writer.print("    {s} engineArgs {{}};\n", .{try e.cppType(native.arguments_type)});
    if (native.argument_storage) try writer.writeAll("    BindingTemporaryWireStorage engineArgumentStorage;\n");
    const environment: CppCodecBindings = .{ .global = if (native.context == .none) "nullptr" else "global" };
    for (native.arguments, 0..) |argument, index| try emitCppWireDecode(
        e,
        writer,
        argument.decoder,
        environment,
        try e.print("args->{s}", .{argument.name}),
        try e.print("engineArgs.{s}", .{argument.name}),
        try e.print("argument_{d}", .{index}),
        argument.path,
        4,
    );
}

fn emitCppOutboundCallbackArguments(e: *Emitter, writer: *Writer, callback: ir.CppOutboundCallbackArguments) Error!void {
    try writer.writeAll("    RELEASE_ASSERT(args->bindingCallee);\n    JSC::JSValue callbackValue;\n");
    try emitCppWireDecode(e, writer, callback.callee, .{}, "args->bindingCallee", "callbackValue", "callback_callee", "callback", 4);
    try writer.writeAll(
        \\    JSC::CallData callData = JSC::getCallData(callbackValue);
        \\    if (callData.type == JSC::CallData::Type::None && !dynamicDowncast<AsyncContextFrame>(callbackValue)) {
        \\        JSC::throwTypeError(global, throwScope, "Typed callback is no longer callable"_s);
        \\        return BIND_STATUS_PENDING_EXCEPTION;
        \\    }
        \\    JSC::MarkedArgumentBuffer callbackArguments;
        \\
    );
    try writer.print("    JSC::JSValue callbackThisValue = {s};\n", .{if (callback.receiver) |receiver| try cppMaterializedValue(e, receiver, "args->bindingThis") else "JSC::jsUndefined()"});
    try emitCppExceptionReturn(writer, 4, "return BIND_STATUS_PENDING_EXCEPTION;");
    switch (callback.capacity) {
        .fixed => |count| try writer.print("    callbackArguments.ensureCapacity({d});\n", .{count}),
        .rest => |rest| try writer.print(
            \\    RELEASE_ASSERT(args->{0s}.ptr || args->{0s}.len == 0);
            \\    if (args->{0s}.len > std::numeric_limits<size_t>::max() - {1d})
            \\        return BIND_STATUS_OUT_OF_MEMORY;
            \\    callbackArguments.ensureCapacity({1d} + args->{0s}.len);
            \\
        , .{ rest.name, rest.fixed }),
    }
    try writer.writeAll("    if (callbackArguments.hasOverflowed())\n        return BIND_STATUS_OUT_OF_MEMORY;\n");
    for (callback.arguments, 0..) |argument, index| try emitCppJavaScriptArgument(e, writer, argument, index);
    try writer.writeAll("    if (callbackArguments.hasOverflowed())\n        return BIND_STATUS_OUT_OF_MEMORY;\n");
}

fn emitCppOutboundInvoke(e: *Emitter, writer: *Writer, wire_result: ir.WireTypeId, invoke: ir.CppOutboundInvoke) Error!void {
    const context = cppOutboundInvokeContext(invoke);
    switch (invoke.callee) {
        .native => |native| {
            try writer.writeAll(if (native.allocation) "    auto engineAllocationResult = " else if (invoke.result != null) "    auto engineResult = " else "    ");
            try writer.print("Bun::Bindgen::Engine::{s}({s}engineArgs);\n", .{ native.symbol, if (native.context != .none) "engineContext, " else "" });
            if (native.allocation) {
                try writer.writeAll("    if (!engineAllocationResult) {\n");
                if (cppOutboundChecks(context)) try writer.writeAll("        if (bindingTerminationAfterNonThrowingCall(throwScope))\n            return BIND_STATUS_PENDING_EXCEPTION;\n");
                try writer.writeAll("        return BIND_STATUS_OUT_OF_MEMORY;\n    }\n");
                if (invoke.result != null) try writer.writeAll("    auto engineResult = WTF::move(engineAllocationResult).value();\n");
            }
        },
        .callback => {
            try writer.writeAll("    auto engineResult = AsyncContextFrame::call(global, callbackValue, callbackThisValue, callbackArguments);\n");
            if (invoke.result == null) try writer.writeAll("    UNUSED_PARAM(engineResult);\n");
        },
    }
    const owned = if (invoke.result) |result| switch (result.conversion) {
        .native => |native| native.owned,
        .javascript => null,
    } else null;
    if (owned) |position| {
        try writer.writeAll("    auto engineResultOwner = WTF::makeScopeExit([&] {\n");
        try emitCppOwnedNominalHandleReleasePlan(e, writer, position, "engineResult", 8);
        try writer.writeAll("    });\n");
    }
    switch (context) {
        .none => {},
        .current => |scope| switch (scope) {
            .unchecked => {},
            .exception => try writer.writeAll("    if (materializeBindingException(throwScope))\n        return BIND_STATUS_PENDING_EXCEPTION;\n"),
            .termination => try writer.writeAll("    if (bindingTerminationAfterNonThrowingCall(throwScope))\n        return BIND_STATUS_PENDING_EXCEPTION;\n"),
        },
    }
    if (invoke.result) |result| {
        try writer.print(
            \\    {0s} pendingResult {{}};
            \\    BindingResultGuard<{0s}, {1s}> resultGuard {{ pendingResult, true }};
            \\
        , .{ try e.wireSpelling(wire_result), result.destroy });
        switch (result.conversion) {
            .javascript => |javascript| {
                try writer.writeAll("    RELEASE_ASSERT(!engineResult.isEmpty());\n");
                try emitCppCallbackResultValue(e, writer, javascript.decoder, "engineResult", "pendingResult.value", "outbound_result", cppPath(javascript.path), 4);
                try writer.writeAll("    if (materializeBindingException(throwScope))\n        return BIND_STATUS_PENDING_EXCEPTION;\n");
            },
            .native => |native| try emitCppResultValue(e, writer, native.encoder, "engineResult", "pendingResult.value", 4, .{}, if (context == .none) "nullptr" else "global"),
        }
        if (owned != null) try writer.writeAll("    engineResultOwner.release();\n");
        try writer.writeAll("    *result = pendingResult;\n");
    } else try writer.writeAll("    result->_reserved = 0;\n");
    try emitCppResultCommit(writer, invoke.result != null, "return BIND_STATUS_OK;", 4);
}

fn emitCppOutboundCall(e: *Emitter, writer: *Writer, program: *const ir.CppOutboundCall) Error!void {
    for (program.entries) |entry| {
        const context: ir.CppOutboundContext = switch (entry.operation) {
            .invoke => |invoke| cppOutboundInvokeContext(invoke),
            .schedule => .{ .current = .exception },
        };
        const transferred: []const ir.CppOutboundNativeCall.Transfer = switch (entry.operation) {
            .invoke => |invoke| switch (invoke.callee) {
                .native => |native| native.transferred,
                .callback => &.{},
            },
            .schedule => &.{},
        };
        const current_realm = context != .none;
        const checks_traps = cppOutboundChecks(context);
        switch (entry.operation) {
            .invoke => |invoke| if (invoke.result) |result| {
                try writer.print("static void {s}({s}* result)\n{{\n", .{ result.destroy, try e.wireSpelling(program.wire_result) });
                try emitCppDestroyPendingResultValue(e, writer, result.position, "result->value", 4);
                try writer.writeAll("    *result = {};\n}\n\n");
            },
            .schedule => {},
        }
        try emitCppExternC(writer, "BindStatus {s}(BindCallContext*{s}, const {s}* args, {s}* result)", "{{\n", .{
            entry.symbol, if (current_realm) " context" else "", try e.wireSpelling(program.wire_args), try e.wireSpelling(program.wire_result),
        });
        if (current_realm) try writer.writeAll("    RELEASE_ASSERT(context);\n    RELEASE_ASSERT(context->global_object);\n");
        try writer.writeAll("    RELEASE_ASSERT(args);\n    RELEASE_ASSERT(result);\n    *result = {};\n");
        if (current_realm) try writer.writeAll("    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(context->global_object);\n");
        if (checks_traps) try writer.writeAll(
            \\    return invokeBindingStatusEntry(global, [&]() -> BindStatus {
            \\    auto& vm = JSC::getVM(global);
            \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
            \\
        );
        if (transferred.len != 0) {
            try writer.writeAll("    auto engineArgumentOwner = WTF::makeScopeExit([&] {\n");
            for (transferred) |argument| try emitCppEngineWireOwnedNominalHandleReleasePlan(e, writer, argument.position, try e.print("args->{s}", .{argument.name}), 8);
            try writer.writeAll("    });\n");
        }
        if (checks_traps) try writer.writeAll("    if (materializeBindingException(throwScope))\n        return BIND_STATUS_PENDING_EXCEPTION;\n");
        switch (entry.operation) {
            .invoke => |invoke| {
                switch (invoke.callee) {
                    .native => |native| try emitCppOutboundNativeArguments(e, writer, native),
                    .callback => |callback| try emitCppOutboundCallbackArguments(e, writer, callback),
                }
                if (transferred.len != 0) try writer.writeAll("    engineArgumentOwner.release();\n");
                try emitCppOutboundInvoke(e, writer, program.wire_result, invoke);
            },
            .schedule => |callback| {
                try emitCppOutboundCallbackArguments(e, writer, callback);
                try writer.writeAll("    RELEASE_AND_RETURN(throwScope, scheduleBindingCallbackNextTick(global, callbackValue, callbackThisValue, callbackArguments));\n");
            },
        }
        if (checks_traps) try writer.writeAll("    });\n");
        try writer.writeAll("}\n\n");
    }
}

fn emitCppNativeEntry(e: *Emitter, writer: *Writer, entry: anytype) Error!void {
    try writer.writeAll(switch (entry.namespace) {
        .engine => "namespace Bun::Bindgen::Engine {\n\n",
        .zig_exports => "namespace Bun::Bindgen::ZigExports {\n\n",
    });
    const signature = entry.signature;
    try emitCppNativeSignature(e, writer, signature);
    try writer.writeAll("\n{\n");
    const scope: ?ir.CppNativeSignature.GlobalScope = switch (signature.context) {
        .none => null,
        .global => |global| value: {
            try writer.writeAll("    RELEASE_ASSERT(global);\n");
            break :value global;
        },
        .engine => value: {
            try writer.writeAll("    auto* global = &context.globalObject;\n");
            break :value .exception;
        },
    };
    if (scope) |value| {
        try writer.writeAll("    auto& vm = JSC::getVM(global);\n");
        try writer.print("    auto throwScope = {s}(vm);\n", .{if (value == .termination) "DECLARE_TOP_EXCEPTION_SCOPE" else "DECLARE_THROW_SCOPE"});
        if (value == .checked_exception) try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, {});\n");
    }
    try emitCppInboundCall(e, writer, entry.call);
    try writer.writeAll("}\n\n");
}

fn emitCppEngineConvertedArgument(
    e: *Emitter,
    writer: *Writer,
    environment: CppCodecBindings,
    match: ir.CppDecode(.outbound_argument),
    converter: ir.CppDecodeConverter,
    failure: ir.CppCodecFailureId,
    source: []const u8,
    target: []const u8,
    suffix: []const u8,
    path: []const u8,
    indent: usize,
) Error!void {
    const declaration = e.ir.get(converter.declaration);
    const converted_input = try e.print("engineConvertedInput_{s}", .{suffix});
    const converted = try e.print("engineConverted_{s}", .{suffix});
    try indented(writer, indent).print("{s} {s} {{}};\n", .{ try cppDecodedValueType(e, match), converted_input });
    try emitCppWireDecode(e, writer, match, environment, source, converted_input, try e.print("{s}_match", .{suffix}), path, indent);
    try indented(writer, indent).print("auto {s} = Bun::Bindgen::Custom::{s}(", .{ converted, declaration.symbol });
    if (!declaration.realm_free) try writer.print("*{s}, ", .{environment.global});
    try writer.print("{s}, ", .{converted_input});
    try emitCppAsciiLiteral(writer, converter.path_override orelse path);
    try writer.writeAll(");\n");
    if (!converter.infallible) try emitCppCodecException(e, writer, failure, indent);
    try indented(writer, indent).print("{s} = WTF::move({s});\n", .{ target, converted });
}

fn emitCppNativeParameterStorage(e: *Emitter, writer: *Writer, id: ir.CppNativeParameterId, suffix: []const u8) Error!void {
    const parameter = e.ir.get(id);
    switch (parameter.operation) {
        .javascript => |input| {
            try writer.print("    {s} convertedNativeArgument_{s} {{}};\n", .{ try e.cppType(e.ir.get(input).value_type), suffix });
            try emitCppConverterValueStorage(e, writer, input, suffix, 4);
        },
        .optional => |child| try emitCppNativeParameterStorage(e, writer, child, try e.print("{s}_optional", .{suffix})),
        .encode, .lazy => {},
    }
}

fn emitCppNativeParameter(e: *Emitter, writer: *Writer, environment: CppCodecBindings, converter_context: CppConversionBindings, id: ir.CppNativeParameterId, source: []const u8, target: []const u8, path: []const u8, suffix: []const u8, index: usize, indent: usize) Error!void {
    const parameter = e.ir.get(id);
    switch (parameter.operation) {
        .javascript => |input| {
            const value = try e.print("convertedNativeArgument_{s}", .{suffix});
            try indented(writer, indent).print("bool converted_{s} = [&]() -> bool {{\n", .{suffix});
            try indented(writer, indent + 4).writeAll("auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
            try emitCppInputPlanValue(e, writer, converter_context, input, .{ .value = source }, value, cppPath(path), suffix, indent + 4);
            try emitCppInputEncode(e, writer, e.ir.get(input).encoder, value, target, .{ .suffix = suffix }, indent + 4);
            try indented(writer, indent + 4).writeAll("throwScope.release();\n");
            try indented(writer, indent + 4).writeAll("return true;\n");
            try indented(writer, indent).writeAll("}();\n");
            try emitCppCodecException(e, writer, parameter.failure, indent);
            try indented(writer, indent).print("RELEASE_ASSERT(converted_{s});\n", .{suffix});
        },
        .optional => |child| {
            try emitCppOptionalProjectionStart(writer, source, try e.print("{s}.present", .{target}), indent);
            try emitCppNativeParameter(e, writer, environment, converter_context, child, try e.print("{s}.value()", .{source}), try e.print("{s}.value", .{target}), path, try e.print("{s}_optional", .{suffix}), index, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .encode => |encoder| try emitCppNativeEncodeValue(e, writer, encoder, source, target, environment, indent),
        .lazy => |input| try emitCppLazyInput(e, writer, converter_context, input, index, .{ .value = source }, target, indent),
    }
}

// ─── projections ───

fn cppInputFailureReturn(failure: ir.CppInputFailure) []const u8 {
    return switch (failure) {
        .empty => "{}",
        .false_value => "false",
        .status => "BIND_STATUS_PENDING_EXCEPTION",
    };
}

fn emitCppConversionExceptionReturn(writer: *Writer, failure: ir.CppInputFailure, indent: usize) Error!void {
    try indented(writer, indent).writeAll("if (materializeBindingException(throwScope)) [[unlikely]]\n");
    try indented(writer, indent + 4).print("return {s};\n", .{cppInputFailureReturn(failure)});
}

fn emitCppOutOfMemoryReturn(writer: *Writer, failure: ir.CppInputFailure, indent: usize) Error!void {
    switch (failure) {
        .empty, .false_value => {
            try indented(writer, indent).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
            try indented(writer, indent).print("return {s};\n", .{cppInputFailureReturn(failure)});
        },
        .status => {
            try emitCppConversionExceptionReturn(writer, .status, indent);
            try indented(writer, indent).writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n");
        },
    }
}

fn emitCppNativeRootCheck(writer: *Writer, roots: []const u8, value: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if (!{s}.tryProtect({s})) return false;\n", .{ roots, value });
}

fn emitCppNativeRootsBody(e: *Emitter, writer: *Writer, id: anytype, source: []const u8, roots: []const u8, indent: usize) Error!void {
    const plan = e.ir.get(id);
    if (!plan.protects_sources) return;
    switch (plan.operation) {
        .leaf => |leaf| switch (leaf) {
            .value => |representation| try emitCppNativeRootCheck(writer, roots, if (representation == .any) try cppAnyToJSExpression(e, source) else source, indent),
            .callback => try emitCppNativeRootCheck(writer, roots, source, indent),
            .scalar, .enumeration, .string, .bytes, .native_slice, .handle, .lazy_handle => {},
        },
        .converted => |child| try emitCppNativeRootsBody(e, writer, child, source, roots, indent),
        .optional => |child| {
            try indented(writer, indent).print("if ({s}.has_value()) {{\n", .{source});
            try emitCppNativeRootsBody(e, writer, child, try e.print("{s}.value()", .{source}), roots, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .dictionary => |fields| for (fields) |field| {
            const child = field.value;
            if (!e.ir.get(child).protects_sources) continue;
            const value = try e.print("{s}.{s}", .{ source, field.name });
            if (field.dictionary_source) {
                try emitCppNativeRootCheck(writer, roots, try e.print("Bun::Bindgen::Detail::CppArgumentAccess::dictionarySource({s})", .{value}), indent);
            } else if (field.optional) {
                try indented(writer, indent).print("if ({s}.has_value()) {{\n", .{value});
                try emitCppNativeRootsBody(e, writer, child, try e.print("{s}.value()", .{value}), roots, indent + 4);
                try indented(writer, indent).writeAll("}\n");
            } else try emitCppNativeRootsBody(e, writer, child, value, roots, indent);
        },
        .union_type => |members| for (members) |member| {
            if (!e.ir.get(member.value).protects_sources) continue;
            try indented(writer, indent).print("if ({s}.is_{s}()) {{\n", .{ source, member.name });
            try emitCppNativeRootsBody(e, writer, member.value, try e.print("{s}.{s}()", .{ source, member.name }), roots, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .collection => |child| {
            const element = try e.print("nativeRootElement_{d}", .{indent});
            try indented(writer, indent).print("for (const auto& {s} : {s}) {{\n", .{ element, source });
            try emitCppNativeRootsBody(e, writer, child, element, roots, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .entry => |entry| {
            try emitCppNativeRootsBody(e, writer, entry.key, try e.print("{s}.first", .{source}), roots, indent);
            try emitCppNativeRootsBody(e, writer, entry.value, try e.print("{s}.second", .{source}), roots, indent);
        },
    }
}

fn emitCppNativeSourceRoots(e: *Emitter, writer: *Writer, id: anytype, source: []const u8, environment: CppCodecBindings, indent: usize) Error!void {
    const plan = e.ir.get(id);
    if (!plan.protects_sources) return;
    try indented(writer, indent).writeAll("if (!([&]() -> bool {\n");
    try emitCppNativeRootsBody(e, writer, id, source, try e.print("(*({s}))", .{environment.native_roots}), indent + 4);
    try indented(writer, indent + 4).writeAll("return true;\n");
    try indented(writer, indent).writeAll("})()) {\n");
    try emitCppCodecAllocationFailure(e, writer, plan.failure, indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppNativeParameterRoots(e: *Emitter, writer: *Writer, id: ir.CppNativeParameterId, source: []const u8, environment: CppCodecBindings, indent: usize) Error!void {
    switch (e.ir.get(id).operation) {
        .javascript, .lazy => {},
        .optional => |child| {
            try indented(writer, indent).print("if ({s}.has_value()) {{\n", .{source});
            try emitCppNativeParameterRoots(e, writer, child, try e.print("{s}.value()", .{source}), environment, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .encode => |encoder| try emitCppNativeSourceRoots(e, writer, encoder, source, environment, indent),
    }
}

const CppInputStorage = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",

    fn child(storage: CppInputStorage, e: *Emitter, suffix: []const u8) Allocator.Error!CppInputStorage {
        return .{ .prefix = storage.prefix, .suffix = try e.print("{s}{s}", .{ storage.suffix, suffix }) };
    }
};

fn emitCppSemanticConverterArgumentMethod(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    try writer.print(
        \\    bool borrowArgument(JSC::JSGlobalObject* global, const {s}& value, {s}& output, BindingTemporaryWireStorage& wireStorage)
        \\    {{
        \\        auto throwScope = DECLARE_THROW_SCOPE(global->vm());
        \\
    , .{ try e.cppType(aggregate.value_type), try e.wireSpelling(aggregate.wire) });
    try emitCppInputEncode(e, writer, aggregate.encoder, "value", "output", .{ .suffix = "semantic" }, 8);
    try writer.writeAll("        throwScope.release();\n        return true;\n    }\n");
}

fn emitCppOptionalProjectionStart(writer: *Writer, source: []const u8, presence: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("{s} = static_cast<uint8_t>({s}.has_value());\n", .{ presence, source });
    try indented(writer, indent).print("if ({s}) {{\n", .{presence});
}

fn emitCppInputEncode(e: *Emitter, writer: *Writer, id: ir.CppInputEncodeId, source: []const u8, target: []const u8, storage: CppInputStorage, indent: usize) Error!void {
    const encoder = e.ir.get(id);
    switch (encoder.operation) {
        .void => {},
        .native => |native| try emitCppNativeEncodeValue(e, writer, native, source, target, .{}, indent),
        .helper => {
            try indented(writer, indent).print("if (!checkBindingConversionResult(throwScope, {s}bindingSemanticConverter_{s}.borrowArgument(global, {s}, {s}, wireStorage)))\n", .{ storage.prefix, storage.suffix, source, target });
            try indented(writer, indent + 4).print("return {s};\n", .{cppInputFailureReturn(encoder.failure)});
        },
        .rest => {
            try indented(writer, indent).print("{0s} = {{ {1s}.isEmpty() ? nullptr : reinterpret_cast<const BindJSValueSliceHandle*>(&{1s}), {1s}.size() }};\n", .{ target, source });
        },
        .byte_lease => {
            try indented(writer, indent).print("{s} = Bun::Bindgen::Detail::CppArgumentAccess::handle({s});\n", .{ target, source });
        },
        .value => |kind| {
            const value = switch (kind) {
                .any => try cppAnyToJSExpression(e, source),
                .engine_value, .branded => source,
            };
            try indented(writer, indent).print("{s} = bindingValueHandle({s});\n", .{ target, value });
        },
        .callback => {
            try indented(writer, indent).print("{s} = bindingValueHandle({s});\n", .{ target, source });
        },
        .class_ref => {
            try indented(writer, indent).print("{s}.native = reinterpret_cast<const BindNativeHandle*>({s});\n", .{ target, source });
            try indented(writer, indent).print("{s}.wrapper = bindingValueHandle({s}bindingWrapper_{s});\n", .{ target, storage.prefix, storage.suffix });
        },
        .optional => |child| {
            try emitCppOptionalProjectionStart(writer, source, try e.print("{s}.present", .{target}), indent);
            try emitCppInputEncode(e, writer, child, try e.print("{s}.value()", .{source}), try e.print("{s}.value", .{target}), try storage.child(e, "_optional"), indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .dictionary => |fields| for (fields) |field| {
            const field_source = try e.print("{s}.{s}", .{ source, field.name });
            const field_target = try e.print("{s}.{s}", .{ target, field.name });
            switch (field.operation) {
                .source => {
                    try indented(writer, indent).writeAll("{\n");
                    try indented(writer, indent + 4).print("auto* sourceValue = wireStorage.copy(Bun::Bindgen::Detail::CppArgumentAccess::dictionarySource({s}));\n", .{field_source});
                    try indented(writer, indent + 4).writeAll("if (!sourceValue) {\n");
                    try emitCppOutOfMemoryReturn(writer, encoder.failure, indent + 8);
                    try indented(writer, indent + 4).writeAll("}\n");
                    try indented(writer, indent + 4).print("{s} = reinterpret_cast<const BindJSValueHandle*>(sourceValue);\n", .{field_target});
                    try indented(writer, indent).writeAll("}\n");
                },
                .value => |field_value| {
                    if (field_value.optional) try emitCppOptionalProjectionStart(writer, field_source, try e.print("{s}_present", .{field_target}), indent);
                    try emitCppInputEncode(e, writer, field_value.encoder, if (field_value.optional) try e.print("{s}.value()", .{field_source}) else field_source, field_target, try storage.child(e, try e.print("_{s}", .{field.name})), indent + @as(usize, if (field_value.optional) 4 else 0));
                    if (field_value.optional) {
                        try indented(writer, indent).writeAll("}\n");
                    }
                },
            }
        },
        .union_type => |members| try emitCppEncodingUnion(e, writer, members, true, source, target, storage, .{}, indent),
        .entry => |entry| {
            try emitCppNativeEncodeValue(e, writer, entry.key, try e.print("{s}.first", .{source}), try e.print("{s}.key", .{target}), .{}, indent);
            try emitCppInputEncode(e, writer, entry.value, try e.print("{s}.second", .{source}), try e.print("{s}.value", .{target}), storage, indent);
        },
        .collection => |collection| {
            const items = try e.print("projectionItems_{d}", .{indent});
            const index = try e.print("projectionIndex_{d}", .{indent});
            try indented(writer, indent).writeAll("{\n");
            try indented(writer, indent + 4).print("auto* {s} = wireStorage.allocateZeroed<{s}>({s}.size());\n", .{ items, try e.wireSpelling(collection.wire), source });
            try indented(writer, indent + 4).print("if ({s}.size() && !{s}) {{\n", .{ source, items });
            try emitCppOutOfMemoryReturn(writer, encoder.failure, indent + 8);
            try indented(writer, indent + 4).writeAll("}\n");
            try indented(writer, indent + 4).print("{s} = {{ {s}, {s}.size() }};\n", .{ target, items, source });
            try indented(writer, indent + 4).print("for (size_t {0s} = 0; {0s} < {1s}.size(); ++{0s}) {{\n", .{ index, source });
            const item_source = try e.print("({s})[{s}]", .{ source, index });
            const item_target = try e.print("{s}[{s}]", .{ items, index });
            switch (collection.element) {
                .native => |native| try emitCppNativeEncodeValue(e, writer, native, item_source, item_target, .{}, indent + 8),
                .sequence, .record => |converted| try emitCppInputEncode(e, writer, converted, item_source, item_target, .{
                    .prefix = try e.print("{s}{s}{s}[{s}]->", .{ storage.prefix, if (collection.element == .record) "bindingRecordConverters_" else "bindingSequenceConverters_", storage.suffix, index }),
                    .suffix = try e.print("{s}{s}", .{ storage.suffix, if (collection.element == .record) "_record_value" else "_element" }),
                }, indent + 8),
            }
            try indented(writer, indent + 4).writeAll("}\n");
            try indented(writer, indent).writeAll("}\n");
        },
    }
}

fn emitCppSemanticConverterResultMethod(e: *Emitter, writer: *Writer, aggregate: *const ir.CppInputAggregate) Error!void {
    const encoder = aggregate.result_encoder orelse return;
    try writer.print("    BindStatus encodeResult(JSC::JSGlobalObject* global, {s}& value, {s}& output)\n    {{\n", .{
        try e.cppType(e.ir.get(encoder).value_type),
        try e.wireSpelling(e.ir.get(encoder).wire),
    });
    const requires_realm = e.ir.get(encoder).requires_global;
    if (requires_realm) try writer.writeAll(
        \\        return invokeBindingStatusEntry(global, [&]() -> BindStatus {
        \\        auto throwScope = DECLARE_THROW_SCOPE(global->vm());
        \\
    );
    try emitCppResultValue(e, writer, encoder, "value", "output", 8, .{ .suffix = "semantic" }, "global");
    try writer.writeAll("        return BIND_STATUS_OK;\n");
    if (requires_realm) try writer.writeAll("        });\n");
    try writer.writeAll("    }\n");
}

fn emitCppConvertedResultCall(writer: *Writer, converter: []const u8, source: []const u8, target: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if (auto status = {s}.encodeResult(global, {s}, {s}); status != BIND_STATUS_OK)\n", .{ converter, source, target });
    try indented(writer, indent + 4).writeAll("return status;\n");
}

// ─── result values ───

fn emitCppNativeEncodeValue(e: *Emitter, writer: *Writer, id: anytype, source: []const u8, target: []const u8, environment: CppCodecBindings, indent: usize) Error!void {
    return emitCppEncodedValue(e, writer, id, source, target, indent, .{}, environment);
}

fn emitCppResultValue(e: *Emitter, writer: *Writer, id: anytype, source: []const u8, target: []const u8, indent: usize, storage: CppInputStorage, global: []const u8) Error!void {
    return emitCppEncodedValue(e, writer, id, source, target, indent, storage, .{ .global = global });
}

fn emitCppEncodedValue(
    e: *Emitter,
    writer: *Writer,
    id: anytype,
    expression: []const u8,
    target: []const u8,
    indent: usize,
    storage: CppInputStorage,
    environment: CppCodecBindings,
) Error!void {
    const encoder = e.ir.get(id);
    const native = comptime std.mem.eql(u8, @TypeOf(id).cpp_field, "native_encoders");
    switch (encoder.operation) {
        .converted => |child| try emitCppEncodedValue(e, writer, child, expression, target, indent, .{}, environment),
        .optional => |child| {
            try emitCppOptionalProjectionStart(writer, expression, try e.print("{s}.present", .{target}), indent);
            try emitCppEncodedValue(e, writer, child, try e.print("{s}.value()", .{expression}), try e.print("{s}.value", .{target}), indent + 4, try storage.child(e, "_optional"), environment);
            try indented(writer, indent).writeAll("}\n");
        },
        .entry => |entry| {
            try emitCppEncodedValue(e, writer, entry.key, try e.print("{s}.first", .{expression}), try e.print("{s}.key", .{target}), indent, .{}, environment);
            try emitCppEncodedValue(e, writer, entry.value, try e.print("{s}.second", .{expression}), try e.print("{s}.value", .{target}), indent, storage, environment);
        },
        .collection => |collection| try emitCppEncodingCollection(e, writer, id, collection, expression, target, indent, storage, environment),
        .dictionary => |fields| for (fields) |field| {
            const name = field.name;
            const field_expression = try e.print("{s}.{s}", .{ expression, name });
            const field_target = try e.print("{s}.{s}", .{ target, name });
            const field_storage = try storage.child(e, try e.print("_{s}", .{name}));
            if (comptime native) if (field.dictionary_source) {
                try emitCppNativeDictionarySource(e, writer, id, field_expression, field_target, environment, indent);
                continue;
            };
            if (field.optional) {
                try emitCppOptionalProjectionStart(writer, field_expression, try e.print("{s}_present", .{field_target}), indent);
                try emitCppEncodedValue(e, writer, field.value, try e.print("{s}.value()", .{field_expression}), field_target, indent + 4, field_storage, environment);
                try indented(writer, indent).writeAll("}\n");
            } else {
                try emitCppEncodedValue(e, writer, field.value, field_expression, field_target, indent, field_storage, environment);
            }
        },
        .union_type => |members| try emitCppEncodingUnion(e, writer, members, false, expression, target, storage, environment, indent),
        .leaf => |leaf| if (comptime native)
            try emitCppNativeEncodingLeaf(e, writer, id, leaf, expression, target, environment, indent)
        else
            try emitCppResultEncodingLeaf(e, writer, id, leaf, expression, target, indent, storage, environment.global),
    }
}

fn emitCppEncodingUnion(e: *Emitter, writer: *Writer, members: anytype, comptime input: bool, source: []const u8, target: []const u8, storage: CppInputStorage, environment: CppCodecBindings, indent: usize) Error!void {
    try indented(writer, indent).print("switch ({s}.tag()) {{\n", .{source});
    for (members, 0..) |member, index| {
        try indented(writer, indent).print("case std::remove_cvref_t<decltype({s})>::Tag::{s}: {{\n", .{ source, member.name });
        try indented(writer, indent + 4).print("{s}.tag = {d};\n", .{ target, if (input) member.tag else index + 1 });
        const member_source = try e.print("{s}.{s}()", .{ source, member.name });
        const member_target = try e.print("{s}.payload.{s}", .{ target, member.name });
        const member_storage = try storage.child(e, try e.print("_{s}", .{member.name}));
        if (input)
            try emitCppInputEncode(e, writer, member.encoder, member_source, member_target, member_storage, indent + 4)
        else
            try emitCppEncodedValue(e, writer, member.value, member_source, member_target, indent + 4, member_storage, environment);
        try indented(writer, indent + 4).writeAll("break;\n");
        try indented(writer, indent).writeAll("}\n");
    }
    try indented(writer, indent).print("case std::remove_cvref_t<decltype({s})>::Tag::none:\n", .{source});
    try indented(writer, indent + 4).writeAll("RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding encoded an uninitialized union\");\n");
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppNativeEncodingLeaf(e: *Emitter, writer: *Writer, id: anytype, leaf: ir.CppNativeEncodingLeaf(@TypeOf(id).role), source: []const u8, target: []const u8, environment: CppCodecBindings, indent: usize) Error!void {
    const plan = e.ir.get(id);
    switch (leaf) {
        .scalar => |kind| {
            if (kind == .discarded) {
                try indented(writer, indent).print("(void)({s});\n", .{source});
                try indented(writer, indent).print("{s} = 0;\n", .{target});
            } else {
                try indented(writer, indent).print("{s} = static_cast<{s}>({s});\n", .{ target, try e.wireSpelling(plan.wire), source });
            }
        },
        .enumeration => {
            try indented(writer, indent).print("{s} = static_cast<{s}>({s});\n", .{ target, try e.wireSpelling(plan.wire), source });
        },
        .string => {
            try indented(writer, indent).print("{s} = reinterpret_cast<const BindStringHandle*>({s}.impl());\n", .{ target, source });
        },
        .bytes, .native_slice => {
            try indented(writer, indent).print("encodeBindingSlice({s}, {s});\n", .{ if (leaf == .bytes) try e.print("bindingByteSpan({s})", .{source}) else source, target });
        },
        .value => |representation| {
            const value = switch (representation) {
                .any => try cppAnyToJSExpression(e, source),
                .engine_value, .branded => source,
            };
            try indented(writer, indent).print("{s} = {s}({s});\n", .{ target, if (@TypeOf(id).role == .inbound_argument) "bindingValueHandle" else "encodeBindingValue", value });
            switch (representation) {
                .branded => |brand| try emitCppBrandAssertion(e, writer, brand, value, indent),
                .any, .engine_value => {},
            }
        },
        .callback => |retains_async_context| {
            try indented(writer, indent).print("(void)bindingCallbackFunction({s});\n", .{source});
            if (retains_async_context) {
                const local = try e.print("nativeCallback_{d}", .{indent});
                try indented(writer, indent).writeAll("{\n");
                try indented(writer, indent + 4).print("auto {s} = AsyncContextFrame::withAsyncContextIfNeeded({s}, {s});\n", .{ local, environment.global, source });
                try emitCppCodecException(e, writer, plan.failure, indent + 4);
                try indented(writer, indent + 4).print("auto* stored = {s}.copy({s});\n", .{ environment.wire_storage, local });
                try emitCppDecodeAllocationCheck(e, writer, plan.failure, "!stored", indent + 4);
                try indented(writer, indent + 4).print("RELEASE_ASSERT({s});\n", .{environment.native_roots});
                try emitCppDecodeAllocationCheck(e, writer, plan.failure, try e.print("!({s})->tryProtect(*stored)", .{environment.native_roots}), indent + 4);
                try indented(writer, indent + 4).print("{s} = bindingValueHandle(*stored);\n", .{target});
                try indented(writer, indent).writeAll("}\n");
            } else {
                try indented(writer, indent).print("{s} = bindingValueHandle({s});\n", .{ target, source });
            }
        },
        .handle => |handle| {
            const value = if (@TypeOf(id).role == .inbound_argument) switch (handle) {
                .external => try e.print("reinterpret_cast<{s}>(requireBindingHandle({s}.get()))", .{ try e.wireSpelling(plan.wire), source }),
                .nominal => |nominal| try nativeHandleToWireExpression(e, nominal, try e.print("requireBindingHandle({s})", .{source})),
            } else try nativeHandleToWireExpression(e, handle, try e.print("requireBindingHandle({s})", .{source}));
            try indented(writer, indent).print("{s} = {s};\n", .{ target, value });
        },
        .lazy_handle => {
            try indented(writer, indent).print("{s} = Bun::Bindgen::Detail::CppArgumentAccess::lazyHandle({s});\n", .{ target, source });
        },
    }
}

fn emitCppResultEncodingLeaf(e: *Emitter, writer: *Writer, id: anytype, leaf: @FieldType(@FieldType(ir.CppResultEncoder(@TypeOf(id).role), "operation"), "leaf"), expression: []const u8, target: []const u8, indent: usize, storage: CppInputStorage, global: []const u8) Error!void {
    switch (leaf) {
        .void => {},
        .helper => |helper| if (@TypeOf(id).role == .inbound_argument) {
            try emitCppConvertedResultCall(writer, try e.print("{s}bindingSemanticConverter_{s}", .{ storage.prefix, storage.suffix }), expression, target, indent);
        } else {
            try indented(writer, indent).print("if (auto status = Bun::Bindgen::{s}({s}, {s}, {s}); status != BIND_STATUS_OK)\n", .{ try cppResultEncoderName(e, helper), global, expression, target });
            try indented(writer, indent + 4).writeAll("return status;\n");
        },
        .nominal_handle => |handle| {
            try indented(writer, indent).print("{s} = {s};\n", .{ target, try nativeHandleToWireExpression(e, handle, try e.print("requireBindingHandle({s})", .{expression})) });
        },
        .scalar => |kind| switch (kind) {
            .discarded => {
                try indented(writer, indent).print("{s} = 0;\n", .{target});
            },
            .boolean => {
                try indented(writer, indent).print("{s} = static_cast<uint8_t>({s});\n", .{ target, expression });
            },
            .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64 => {
                try indented(writer, indent).print("{s} = {s};\n", .{ target, expression });
            },
        },
        .value => |representation| {
            const value = switch (representation) {
                .any => try cppAnyToJSExpression(e, expression),
                .engine_value, .branded => expression,
            };
            try indented(writer, indent).print("{s} = encodeBindingValue({s});\n", .{ target, value });
            switch (representation) {
                .branded => |brand| try emitCppBrandAssertion(e, writer, brand, value, indent),
                .any, .engine_value => {},
            }
        },
        .callback => |retains_async_context| {
            try indented(writer, indent).writeAll("{\n");
            try indented(writer, indent + 4).print("(void)bindingCallbackFunction({s});\n", .{expression});
            try indented(writer, indent + 4).print("JSC::JSValue capturedCallback = {s};\n", .{if (retains_async_context) try e.print("AsyncContextFrame::withAsyncContextIfNeeded({s}, {s})", .{ global, expression }) else expression});
            if (retains_async_context) try emitCppConversionExceptionReturn(writer, .status, indent + 4);
            try indented(writer, indent + 4).print("{s} = reinterpret_cast<BindRootHandle*>(Bun::createStrongRef(global, capturedCallback));\n", .{target});
            try emitCppConversionExceptionReturn(writer, .status, indent + 4);
            try indented(writer, indent + 4).print("RELEASE_ASSERT({s});\n", .{target});
            try indented(writer, indent).writeAll("}\n");
        },
        .class_ref => |reference| if (@TypeOf(id).role == .inbound_argument) {
            const wrapper = try e.print("{s}bindingWrapper_{s}", .{ storage.prefix, storage.suffix });
            try indented(writer, indent).print("{s}.native = reinterpret_cast<BindNativeHandle*>({s});\n", .{ target, expression });
            try indented(writer, indent).print("{s}.wrapper = reinterpret_cast<BindRootHandle*>(Bun::createStrongRef(global, bindingValue({s})));\n", .{ target, wrapper });
            try emitCppConversionExceptionReturn(writer, .status, indent);
            try indented(writer, indent).print("RELEASE_ASSERT({s}.wrapper);\n", .{target});
        } else {
            const class_id = switch (reference) {
                .native, .engine => |class| class,
            };
            const class = e.class(class_id);
            try indented(writer, indent).writeAll("{\n");
            try indented(writer, indent + 4).print("auto* engineClassResult = dynamicDowncast<Bun::{s}>({s});\n", .{ class.cpp_class_name, expression });
            switch (reference) {
                .engine => {
                    try indented(writer, indent + 4).writeAll("RELEASE_ASSERT(engineClassResult);\n");
                    try indented(writer, indent + 4).print("{s}.native = reinterpret_cast<BindNativeHandle*>(&engineClassResult->wrapped());\n", .{target});
                },
                .native => {
                    try indented(writer, indent + 4).writeAll("RELEASE_ASSERT(engineClassResult && engineClassResult->native());\n");
                    try indented(writer, indent + 4).print("{s}.native = reinterpret_cast<BindNativeHandle*>(engineClassResult->native());\n", .{target});
                },
            }
            try indented(writer, indent + 4).print("{s}.wrapper = reinterpret_cast<BindRootHandle*>(Bun::createStrongRef(global, {s}));\n", .{ target, expression });
            try emitCppConversionExceptionReturn(writer, .status, indent + 4);
            try indented(writer, indent + 4).print("RELEASE_ASSERT({s}.wrapper);\n", .{target});
            try indented(writer, indent).writeAll("}\n");
        },
        .string => |string| {
            try indented(writer, indent).print("if (!encodeBindingString({s}, {s}, {s}))\n", .{ expression, cppBoolean(string.thread_safe), target });
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n");
        },
        .bytes => {
            try writer.splatByteAll(' ', indent);
            if (@TypeOf(id).role == .inbound_argument)
                try writer.print("if (!encodeBindingBytes(std::span<const uint8_t> {{ {0s}.data(), {0s}.size() }}, {1s}))\n", .{ expression, target })
            else
                try writer.print("if (!Bun::Bindgen::Detail::CppNativeResultAccess::takeBytes({s}, {s}))\n", .{ expression, target });
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n");
        },
        .enumeration => |scalar| {
            try indented(writer, indent).print("{s} = static_cast<{s}>({s});\n", .{ target, @tagName(scalar), expression });
        },
    }
}

fn emitCppEncodingCollection(e: *Emitter, writer: *Writer, id: anytype, collection: anytype, expression: []const u8, target: []const u8, indent: usize, storage: CppInputStorage, environment: CppCodecBindings) Error!void {
    const native = comptime std.mem.eql(u8, @TypeOf(id).cpp_field, "native_encoders");
    const item_wire = try e.wireSpelling(if (native) e.ir.get(collection).wire else collection.wire);
    const items = try e.print("encodedItems_{d}", .{indent});
    const length = try e.print("encodedLength_{d}", .{indent});
    const index = try e.print("encodedIndex_{d}", .{indent});
    try indented(writer, indent).writeAll("{\n");
    try indented(writer, indent + 4).print("const size_t {s} = {s}.size();\n", .{ length, expression });
    if (native) {
        try indented(writer, indent + 4).print("auto* {s} = {s}.allocateZeroed<{s}>({s});\n", .{ items, environment.wire_storage, item_wire, length });
        try emitCppDecodeAllocationCheck(e, writer, e.ir.get(id).failure, try e.print("{s} && !{s}", .{ length, items }), indent + 4);
    } else {
        try indented(writer, indent + 4).print("auto* {s} = allocateBindingTransferItems<{s}>({s});\n", .{ items, item_wire, length });
        try indented(writer, indent + 4).print("if ({s} && !{s})\n", .{ length, items });
        try indented(writer, indent + 8).writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n");
    }
    try indented(writer, indent + 4).print("{s} = {{ {s}, {s} }};\n", .{ target, items, length });
    const item: struct { id: @TypeOf(id), storage: CppInputStorage } = if (native)
        .{ .id = collection, .storage = .{} }
    else switch (collection.element) {
        .direct => |child| .{ .id = child, .storage = .{} },
        .sequence, .record => |child| .{ .id = child, .storage = .{
            .prefix = try e.print("{s}{s}{s}[{s}]->", .{ storage.prefix, if (collection.element == .record) "bindingRecordConverters_" else "bindingSequenceConverters_", storage.suffix, index }),
            .suffix = try e.print("{s}{s}", .{ storage.suffix, if (collection.element == .record) "_record_value" else "_element" }),
        } },
    };
    try indented(writer, indent + 4).print("for (size_t {0s} = 0; {0s} < {1s}; ++{0s}) {{\n", .{ index, length });
    const source = if (native)
        try e.print("({s})[{s}]", .{ expression, index })
    else
        try e.print("Bun::Bindgen::Detail::CppNativeResultAccess::element({s}, {s})", .{ expression, index });
    try emitCppEncodedValue(e, writer, item.id, source, try e.print("{s}[{s}]", .{ items, index }), indent + 8, item.storage, environment);
    try indented(writer, indent + 4).writeAll("}\n");
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppNativeDictionarySource(e: *Emitter, writer: *Writer, id: anytype, source: []const u8, target: []const u8, environment: CppCodecBindings, indent: usize) Error!void {
    const plan = e.ir.get(id);

    if (@TypeOf(id).role == .outbound_argument) {
        try indented(writer, indent).print("{s} = encodeBindingValue(Bun::Bindgen::Detail::CppArgumentAccess::dictionarySource({s}));\n", .{ target, source });
        return;
    }
    try indented(writer, indent).writeAll("{\n");
    try indented(writer, indent + 4).print("auto* sourceValue = {s}.copy(Bun::Bindgen::Detail::CppArgumentAccess::dictionarySource({s}));\n", .{ environment.wire_storage, source });
    try emitCppDecodeAllocationCheck(e, writer, plan.failure, "!sourceValue", indent + 4);
    try indented(writer, indent + 4).print("{s} = bindingValueHandle(*sourceValue);\n", .{target});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppValueEncodingContract(writer: *Writer) Error!void {
    try writer.writeAll("static_assert(sizeof(JSC::JSValue) == sizeof(uint64_t));\n");
    const Constant = struct { name: []const u8, value: u64 };
    for ([_]Constant{
        .{ .name = "NumberTag", .value = value_encoding.number_tag },
        .{ .name = "DoubleEncodeOffset", .value = value_encoding.double_offset },
        .{ .name = "NotCellMask", .value = value_encoding.not_cell_mask },
        .{ .name = "ValueEmpty", .value = value_encoding.empty_value },
        .{ .name = "ValueDeleted", .value = value_encoding.deleted_value },
        .{ .name = "ValueUndefined", .value = value_encoding.undefined_value },
        .{ .name = "ValueNull", .value = value_encoding.null_value },
        .{ .name = "ValueFalse", .value = value_encoding.false_value },
        .{ .name = "ValueTrue", .value = value_encoding.true_value },
    }) |constant| {
        try writer.print("static_assert(static_cast<uint64_t>(JSC::JSValue::{s}) == UINT64_C({d}));\n", .{ constant.name, constant.value });
    }
}

fn emitCppHostSignature(writer: *Writer, linkage: @FieldType(ir.CppHost.Frame, "linkage"), symbol: []const u8, overload_inputs: bool) Error!void {
    const signature = "SYSV_ABI JSC::EncodedJSValue {s}(JSC::JSGlobalObject* global, JSC::CallFrame* callFrame{s})";
    const extra = if (overload_inputs) ", std::span<const BindingConversionInput> bindingOverloadInputs" else "";
    switch (linkage) {
        .external_noexcept => try emitCppExternC(writer, signature, "", .{ symbol, extra }),
        .internal_noexcept => try writer.print("static " ++ signature ++ " noexcept\n", .{ symbol, extra }),
        .internal => try writer.print("static " ++ signature ++ "\n", .{ symbol, extra }),
    }
}

fn emitCppHostPreamble(writer: *Writer, host: ir.CppHost) Error!void {
    switch (host.signature) {
        .frame => |frame| {
            if (frame.promise_body) |body| {
                try writer.print("static JSC::EncodedJSValue SYSV_ABI {s}(JSC::JSGlobalObject*, JSC::CallFrame*){s};\n", .{ body, if (frame.linkage == .internal) "" else " noexcept" });
                try emitCppHostSignature(writer, frame.linkage, host.symbol, false);
                try writer.print("{{\n    return invokeBindingPromiseEntry(global, [&] {{ return {s}(global, callFrame); }});\n}}\n\n", .{body});
            }
            try emitCppHostSignature(writer, if (frame.promise_body != null and frame.linkage == .external_noexcept) .internal_noexcept else frame.linkage, frame.promise_body orelse host.symbol, frame.overload_inputs);
        },
        .getter => |promise_body| {
            if (promise_body) |body| {
                try writer.print("static JSC_DECLARE_CUSTOM_GETTER({s});\n", .{body});
                try writer.print("JSC_DEFINE_CUSTOM_GETTER({s}, (JSC::JSGlobalObject* global, JSC::EncodedJSValue encodedThis, JSC::PropertyName propertyName))\n{{\n    return invokeBindingPromiseEntry(global, [&] {{ return {s}(global, encodedThis, propertyName); }});\n}}\n\n", .{ host.symbol, body });
            }
            try writer.print("JSC_DEFINE_CUSTOM_GETTER({s}, (JSC::JSGlobalObject* global, JSC::EncodedJSValue encodedThis, JSC::PropertyName))\n", .{promise_body orelse host.symbol});
        },
        .setter => try writer.print("JSC_DEFINE_CUSTOM_SETTER({s}, (JSC::JSGlobalObject* global, JSC::EncodedJSValue encodedThis, JSC::EncodedJSValue encodedValue, JSC::PropertyName))\n", .{host.symbol}),
    }
    try writer.writeAll("{\n    auto& vm = JSC::getVM(global);\n    auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
    switch (host.signature) {
        .frame => |frame| if (frame.callback_data) try writer.writeAll("    auto* callbackFunction = dynamicDowncast<Zig::JSFFIFunction>(JSC::JSValue(callFrame->jsCallee()));\n    RELEASE_ASSERT(callbackFunction);\n"),
        .getter, .setter => {},
    }
}

fn emitCppHostCall(e: *Emitter, writer: *Writer, call: ir.CppHostCall) Error!void {
    try emitCppHostPreamble(writer, call.host);
    try emitCppInboundCall(e, writer, call.entry);
}

fn emitSurfaceFunctionEvaluator(e: *Emitter, writer: *Writer, surface: ir.CppSurfaceEvaluator) Error!void {
    try writer.print(
        \\static JSC::EncodedJSValue {s}_body(JSC::JSGlobalObject* global, JSC::JSValue bindingSurfaceReceiver) noexcept
        \\{{
        \\    auto& vm = global->vm();
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\
    , .{surface.symbol});
    try emitCppInboundCall(e, writer, surface.entry);
    try writer.print(
        \\JSC::JSValue {s}(JSC::JSGlobalObject* global, JSC::JSValue bindingSurfaceReceiver) noexcept
        \\{{
        \\    return JSC::JSValue::decode(
    , .{surface.symbol});
    if (surface.promise) try writer.writeAll("invokeBindingPromiseEntry(global, [&] { return ");
    try writer.print("{s}_body(global, bindingSurfaceReceiver)", .{surface.symbol});
    if (surface.promise) try writer.writeAll("; })");
    try writer.writeAll(");\n}\n\n");
}

fn emitFunctionFactory(e: *Emitter, writer: *Writer, factory: ir.CppFunctionFactory) Error!void {
    switch (factory.abi) {
        .value => try writer.print(
            \\JSC::JSValue {s}(Zig::GlobalObject* global) noexcept
            \\{{
            \\
        , .{factory.symbol}),
        .reference => try emitCppExternC(writer, "BindStatus {s}(BindGlobalObjectHandle* globalHandle, BindEncodedJSValue* outValue)",
            \\{{
            \\    RELEASE_ASSERT(globalHandle);
            \\    RELEASE_ASSERT(outValue);
            \\    *outValue = 0;
            \\    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
            \\    return invokeBindingStatusEntry(global, [&]() -> BindStatus {{
            \\
        , .{factory.symbol}),
    }
    const failure: []const u8 = switch (factory.abi) {
        .value => "{}",
        .reference => "BIND_STATUS_PENDING_EXCEPTION",
    };
    try writer.print(
        \\    auto& vm = JSC::getVM(global);
        \\    auto scope = DECLARE_THROW_SCOPE(vm);
        \\    if (materializeBindingException(scope)) return {s};
        \\
    , .{failure});
    switch (factory.value) {
        .builtin => |symbol| try writer.print(
            \\    auto* executable = WebCore::{s}(vm);
            \\    if (materializeBindingException(scope)) return {s};
            \\    auto* function = JSC::JSFunction::create(vm, global, executable, global);
            \\
        , .{ symbol, failure }),
        .realm, .native => {
            try writer.writeAll("    auto* function = ");
            try emitCppSurfaceFunction(e, writer, factory.value, "global");
            try writer.writeAll(";\n");
        },
    }
    try writer.print("    if (materializeBindingException(scope)) return {s};\n", .{failure});
    switch (factory.abi) {
        .value => try writer.writeAll("    return function;\n"),
        .reference => try writer.writeAll(
            \\    *outValue = encodeBindingValue(function);
            \\    return BIND_STATUS_OK;
            \\    });
            \\
        ),
    }
    try writer.writeAll("}\n\n");
}

// ─── typed callbacks ───

fn emitCppJavaScriptArgument(e: *Emitter, writer: *Writer, argument: ir.CppOutboundCallbackArguments.Argument, index: usize) Error!void {
    const materializer = argument.materializer;
    const field = try e.print("args->{s}", .{argument.name});
    if (argument.rest) {
        const suffix = try e.print("callback_rest_{d}", .{index});
        const items = try e.print("callbackRest_{d}", .{index});
        const item = try e.print("{s}[callbackRestIndex_{d}]", .{ items, index });
        try writer.print("    auto {s} = decodeBindingSlice({s});\n", .{ items, field });
        try writer.print("    for (size_t callbackRestIndex_{0d} = 0; callbackRestIndex_{0d} < {1s}.size(); ++callbackRestIndex_{0d}) {{\n", .{ index, items });
        try writer.print("        JSC::JSValue callbackArgument_{s};\n", .{suffix});
        try emitCppMaterializedValue(e, writer, materializer, item, try e.print("callbackArgument_{s}", .{suffix}), 8);
        try emitCppExceptionReturn(writer, 8, "return BIND_STATUS_PENDING_EXCEPTION;");
        try writer.print("        callbackArguments.append(callbackArgument_{s});\n", .{suffix});
        try writer.writeAll("    }\n\n");
        return;
    }
    try writer.print("    JSC::JSValue callbackArgument_{d};\n", .{index});
    try emitCppMaterializedValue(e, writer, materializer, field, try e.print("callbackArgument_{d}", .{index}), 4);
    try emitCppExceptionReturn(writer, 4, "return BIND_STATUS_PENDING_EXCEPTION;");
    try writer.print("    callbackArguments.append(callbackArgument_{d});\n", .{index});
}

const WireReleaseKind = enum { pending, owned_handles };

fn emitCppDestroyPendingResultValue(e: *Emitter, writer: *Writer, id: anytype, value: []const u8, indent: usize) Error!void {
    try emitCppWireRelease(e, writer, id, value, indent, .pending);
}

fn emitCppWireRelease(e: *Emitter, writer: *Writer, position_id: anytype, value: []const u8, indent: usize, comptime kind: WireReleaseKind) Error!void {
    const position = e.ir.get(position_id);
    if (!@field(position.cpp.release, @tagName(kind))) return;
    switch (position.representation) {
        .leaf => if (kind == .owned_handles) {
            try indented(writer, indent).print("if ({s})\n", .{value});
            try indented(writer, indent + 4).print("{s}({s});\n", .{ e.ir.get(position.representation.leaf.nominal_owned).release_symbol, value });
        } else switch (position.cpp.release.pending_leaf.?) {
            .root => try emitCppPendingHandleRelease(writer, value, try e.print("reinterpret_cast<Bun::StrongRefStorage*>({s})->deref();", .{value}), indent),
            .class_ref => {
                const handle = try e.print("{s}.wrapper", .{value});
                try emitCppPendingHandleRelease(writer, handle, try e.print("reinterpret_cast<Bun::StrongRefStorage*>({s})->deref();", .{handle}), indent);
            },
            .string => try emitCppPendingHandleRelease(writer, value, try e.print("bun_bindgen_string_release({s});", .{value}), indent),
            .release_handle => |symbol| try emitCppPendingHandleRelease(writer, value, try e.print("{s}({s});", .{ symbol, value }), indent),
            .bytes => {
                try indented(writer, indent).print("releaseBindingBytes({s});\n", .{value});
            },
        },
        .converted => |conversion| try emitCppWireRelease(e, writer, conversion.apiValue(), value, indent, kind),
        .optional => |child| {
            try indented(writer, indent).print("if (decodeBindingPresence({s}.present)) {{\n", .{value});
            try emitCppWireRelease(e, writer, child, try e.print("{s}.value", .{value}), indent + 4, kind);
            try indented(writer, indent).writeAll("}\n");
        },
        .dictionary => |fields| for (fields) |field| {
            if (!@field(e.ir.get(field.value).cpp.release, @tagName(kind))) continue;
            const field_value = try e.print("{s}.{s}", .{ value, field.name });
            if (field.optional) {
                try indented(writer, indent).print("if (decodeBindingPresence({s}_present)) {{\n", .{field_value});
                try emitCppWireRelease(e, writer, field.value, field_value, indent + 4, kind);
                try indented(writer, indent).writeAll("}\n");
            } else try emitCppWireRelease(e, writer, field.value, field_value, indent, kind);
        },
        .union_type => |members| {
            try indented(writer, indent).print("switch ({s}.tag) {{\n", .{value});
            if (kind == .pending) try indented(writer, indent).writeAll("case 0: break;\n");
            for (members, 1..) |member, tag| {
                try indented(writer, indent).print("case {d}: {{\n", .{tag});
                try emitCppWireRelease(e, writer, member.value, try e.print("{s}.payload.{s}", .{ value, member.name }), indent + 4, kind);
                try indented(writer, indent + 4).writeAll("break;\n");
                try indented(writer, indent).writeAll("}\n");
            }
            try indented(writer, indent).writeAll("default: RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding union has an invalid tag\");\n");
            try indented(writer, indent).writeAll("}\n");
        },
        inline .sequence, .record, .rest => |child| {
            try indented(writer, indent).writeAll("{\n");
            try indented(writer, indent + 4).print("auto releaseItems = decodeBindingSlice({s});\n", .{value});
            if (@field(e.ir.get(child).cpp.release, @tagName(kind))) {
                const item = try e.print("releaseItem_{d}_{d}", .{ position_id.index, indent });
                try indented(writer, indent + 4).print("for (auto& {s} : releaseItems) {{\n", .{item});
                try emitCppWireRelease(e, writer, child, item, indent + 8, kind);
                try indented(writer, indent + 4).writeAll("}\n");
            }
            if (kind == .pending and @TypeOf(position_id).role != .outbound_argument) {
                const element_wire = try e.wireSpelling(e.ir.get(child).wire);
                try indented(writer, indent + 4).print("if (!releaseItems.empty()) bun_bindgen_transfer_free_aligned(reinterpret_cast<uint8_t*>(releaseItems.data()), releaseItems.size_bytes(), alignof({s}));\n", .{element_wire});
            }
            try indented(writer, indent).writeAll("}\n");
        },
        .record_entry => |entry| {
            try emitCppWireRelease(e, writer, entry.key, try e.print("{s}.key", .{value}), indent, kind);
            try emitCppWireRelease(e, writer, entry.value, try e.print("{s}.value", .{value}), indent, kind);
        },
    }
}

fn emitCppPendingHandleRelease(writer: *Writer, handle: []const u8, release: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if ({s})\n", .{handle});
    try indented(writer, indent + 4).print("{s}\n", .{release});
}

fn emitCppCallbackResultValue(
    e: *Emitter,
    writer: *Writer,
    id: ir.CppJavaScriptDecodeId,
    value: []const u8,
    target: []const u8,
    suffix: []const u8,
    path: CppPath,
    indent: usize,
) Error!void {
    const decoder = e.ir.get(id);
    switch (decoder.operation) {
        .void => {},
        .scalar => |scalar| try emitCppScalarConversionTo(
            e,
            writer,
            .{},
            scalar,
            value,
            target,
            path,
            try e.print("callbackConversionContext_{s}", .{suffix}),
            indent,
        ),
        .value => try emitCppAssignment(writer, target, try e.print("encodeBindingValue({s})", .{value}), indent),
        .branded => |branded| {
            try indented(writer, indent).writeAll("if (!( ");
            try emitCppBrandMatchExpression(e, writer, branded.brand, value);
            try writer.writeAll(")) {\n");
            try emitCppValueInputError(e, writer, branded.failure, path, value, indent + 4);
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_PENDING_EXCEPTION;\n");
            try indented(writer, indent).writeAll("}\n");
            try emitCppAssignment(writer, target, try e.print("encodeBindingValue({s})", .{value}), indent);
        },
        .callback => |callback| {
            try indented(writer, indent).print("if (JSC::getCallData({s}).type == JSC::CallData::Type::None) {{\n", .{value});
            try emitCppValueInputError(e, writer, callback.failure, path, value, indent + 4);
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_PENDING_EXCEPTION;\n");
            try indented(writer, indent).writeAll("}\n");
            try indented(writer, indent).print("JSC::JSValue callbackFunction_{s} = {s};\n", .{ suffix, if (callback.captures_context) try e.print("AsyncContextFrame::withAsyncContextIfNeeded(global, {s})", .{value}) else value });
            if (callback.captures_context) try emitCppConversionExceptionReturn(writer, decoder.failure, indent);
            try indented(writer, indent).print("{s} = reinterpret_cast<BindRootHandle*>(Bun::createStrongRef(global, callbackFunction_{s}));\n", .{ target, suffix });
            try emitCppConversionExceptionReturn(writer, decoder.failure, indent);
            try indented(writer, indent).print("RELEASE_ASSERT({s});\n", .{target});
        },
        .string => |string| {
            const converted = try e.print("callbackString_{s}", .{suffix});
            try indented(writer, indent).print("WTF::String {s};\n", .{converted});
            try emitCppStringConversionTo(e, writer, string, value, converted, path, try e.print("callbackConversionContext_{s}", .{suffix}), indent);
            try indented(writer, indent).print("if (!encodeBindingString(callbackString_{s}, {s}, {s}))\n", .{ suffix, cppBoolean(string.thread_safe), target });
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n");
        },
        .bytes => |buffer| {
            try indented(writer, indent).print("BindingBufferSource callbackBuffer_{s};\n", .{suffix});
            try emitCppBufferCheckStart(writer, buffer, try e.print("callbackBuffer_{s}", .{suffix}), value, indent);
            try emitCppBufferConversionError(e, writer, buffer, path, value, indent + 4);
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_PENDING_EXCEPTION;\n");
            try indented(writer, indent).writeAll("}\n");
            try indented(writer, indent).print("if (!encodeBindingBytes(callbackBuffer_{s}, {s}))\n", .{ suffix, target });
            try indented(writer, indent + 4).writeAll("return BIND_STATUS_OUT_OF_MEMORY;\n");
        },
        .aggregate => |conversion| try emitCppCallbackAggregateResult(e, writer, conversion, value, target, suffix, path, indent),
        .optional => |optional| {
            try indented(writer, indent).print("{s}.present = 0;\n", .{target});
            try indented(writer, indent).writeAll("if (");
            try emitCppValueTest(e, writer, optional.presence, value, value);
            try writer.writeAll(") {\n");
            try indented(writer, indent + 4).print("{s}.present = 1;\n", .{target});
            try emitCppCallbackResultValue(e, writer, optional.value, value, try e.print("{s}.value", .{target}), try e.print("{s}_value", .{suffix}), path, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
    }
}

fn emitCppCallbackAggregateResult(
    e: *Emitter,
    writer: *Writer,
    id: ir.CppInputAggregateId,
    value: []const u8,
    target: []const u8,
    suffix: []const u8,
    path: CppPath,
    indent: usize,
) Error!void {
    const conversion = e.ir.get(id);
    const converter_suffix = try e.print("callback_{s}", .{suffix});
    const native_result = try e.print("callbackAggregate_{s}", .{suffix});
    try emitCppSemanticConverterDeclaration(e, writer, id, converter_suffix, indent);
    try indented(writer, indent).print("{s} {s} {{}};\n", .{ try e.cppType(conversion.value_type), native_result });
    try indented(writer, indent).print("if (!checkBindingConversionResult(throwScope, bindingSemanticConverter_{s}.convert(", .{converter_suffix});
    try emitCppConverterPaths(e, writer, id, path);
    try writer.print(", global, {s}, {s}, nullptr", .{ value, native_result });
    try writer.writeAll(")))\n");
    try indented(writer, indent + 4).writeAll("return BIND_STATUS_PENDING_EXCEPTION;\n");
    try emitCppConvertedResultCall(writer, try e.print("bindingSemanticConverter_{s}", .{converter_suffix}), native_result, target, indent);
}

// ─── host functions and overloads ───

fn emitCppHostFunction(e: *Emitter, writer: *Writer, function: *const ir.CppFunction) Error!void {
    switch (function.*) {
        .builtin => {},
        .call => |body| {
            try emitCppHostCall(e, writer, .{ .host = body.host, .entry = body.entry });
            if (body.writable) |setter| try emitCppHostCall(e, writer, setter);
        },
        .overload => |dispatch| {
            for (dispatch.cases) |case| try emitCppHostFunction(e, writer, &e.ir.cpp_overload_cases[case.declaration.index].?);
            try emitCppHostPreamble(writer, dispatch.host);
            if (dispatch.prepare_receiver) |source| try emitCppReceiverPreparation(writer, source);
            if (dispatch.receiver) |check| try emitCppReceiverCheck(e, writer, check);
            try emitCppOverloadArgumentCountDeclaration(writer, dispatch);
            try emitCppOverloadUnderflow(e, writer, dispatch);
            for (dispatch.cases, 0..) |case, case_index| {
                try writer.print("    bool overloadMatches_{d} = ", .{case_index});
                try emitCppOverloadMatch(e, writer, dispatch, case);
                try writer.writeAll(";\n    BINDGEN_RETURN_IF_EXCEPTION(throwScope, {});\n");
                try writer.print("    if (overloadMatches_{d})\n        RELEASE_AND_RETURN(throwScope, {s}(global, callFrame, bindingOverloadInputs));\n", .{ case_index, case.symbol });
            }
            try writer.writeAll("    JSC::throwTypeError(global, throwScope, ");
            try emitCppUtf8String(writer, try e.print("No overload of {s} matches the provided arguments", .{dispatch.name}));
            try writer.writeAll(");\n    return {};\n}\n\n");
        },
    }
}

fn emitCppOverloadUnderflow(e: *Emitter, writer: *Writer, dispatch: ir.CppOverloadDispatch) Error!void {
    switch (dispatch.underflow) {
        .none => {},
        .reject => |check| try emitCppRequiredArgumentCheck(e, writer, check),
        .dispatch => |index| {
            const case = dispatch.cases[index];
            try writer.print("    if (callFrame->argumentCount() < {d})\n        RELEASE_AND_RETURN(throwScope, {s}(global, callFrame, bindingOverloadInputs));\n", .{ case.minimum_argument_count, case.symbol });
        },
    }
}

fn emitCppOverloadArgumentCountDeclaration(writer: *Writer, dispatch: ir.CppOverloadDispatch) Error!void {
    try writer.print("    std::array<BindingConversionInput, {d}> bindingOverloadInputs {{\n", .{dispatch.input_slot_count});
    for (0..dispatch.input_slot_count) |index| try writer.print("        callFrame->argument({d}),\n", .{index});
    try writer.writeAll("    };\n");
    switch (dispatch.argument_count) {
        .call_frame => {},
        .clamped => |maximum| try writer.print("    size_t overloadArgumentCount = std::min<size_t>({d}, callFrame->argumentCount());\n", .{maximum}),
    }
}

fn overloadArgumentCountExpression(dispatch: ir.CppOverloadDispatch) []const u8 {
    return switch (dispatch.argument_count) {
        .call_frame => "callFrame->argumentCount()",
        .clamped => "overloadArgumentCount",
    };
}

fn emitCppOverloadMatch(e: *Emitter, writer: *Writer, dispatch: ir.CppOverloadDispatch, case: ir.CppOverloadCase) Error!void {
    const argument_count = overloadArgumentCountExpression(dispatch);
    try writer.print("{s} >= {d}", .{ argument_count, case.minimum_argument_count });
    if (case.maximum_argument_count) |maximum| try writer.print(" && {s} <= {d}", .{ argument_count, maximum });

    for (case.comparisons) |comparison| {
        try writer.print(" && ({s} < {d}", .{ argument_count, comparison.overlap_minimum });
        if (comparison.overlap_maximum) |overlap_maximum| try writer.print(" || {s} > {d}", .{ argument_count, overlap_maximum });
        try writer.writeAll(" || (");
        for (comparison.arguments, 0..) |argument, position| {
            const index = argument.index;
            if (position > 0) try writer.writeAll(" && ");
            const source = try e.print("bindingOverloadInputs[{d}]", .{index});
            const value = try e.print("{s}.value()", .{source});
            try writer.print("({s} <= {d} || (", .{ argument_count, index });
            try emitCppInputSelectionExpression(e, writer, argument.selection, value, source);
            try writer.writeAll("))");
        }
        try writer.writeAll("))");
    }
}

fn emitCppReceiverPreparation(writer: *Writer, source: ir.CppReceiverSource) Error!void {
    const value = switch (source) {
        .frame => "callFrame->thisValue().toThis(global, JSC::ECMAMode::strict())",
        .encoded => "JSC::JSValue::decode(encodedThis).toThis(global, JSC::ECMAMode::strict())",
        .surface => "bindingSurfaceReceiver",
    };
    try writer.print("    JSC::EnsureStillAliveScope bindingThisValue = {s};\n", .{value});
}

fn cppReceiverValue(value: ir.CppReceiverValue) []const u8 {
    return switch (value) {
        .frame, .encoded, .surface => "bindingThisValue.value()",
        .cpp => "cppArgs.bindingThis",
        .object => "JSC::JSValue(thisObject)",
    };
}

fn cppArgumentRead(e: *Emitter, read: ir.CppArgumentRead) Allocator.Error![]const u8 {
    return switch (read) {
        .receiver => |receiver| cppReceiverValue(receiver),
        .new_target => "callFrame->newTarget()",
        .callee => "JSC::JSValue(callFrame->jsCallee())",
        .setter_value => "JSC::JSValue::decode(encodedValue)",
        .argument => |argument| e.print("callFrame->{s}({d})", .{ if (argument.unchecked) "uncheckedArgument" else "argument", argument.index }),
        .slot => |slot| e.print("thisObject->slot_{s}()", .{slot}),
        .prepared => |index| e.print("bindingPreparedInput_{d}.value()", .{index}),
    };
}

fn cppArgumentDestination(e: *Emitter, target: ir.CppArgumentDestination) Allocator.Error![]const u8 {
    return switch (target) {
        .cpp => |field| e.print("cppArgs.{s}", .{field}),
        .wire => |field| e.print("args.{s}", .{field}),
    };
}

fn cppReturn(value: ir.CppReturn) []const u8 {
    return switch (value) {
        .empty => "return {};",
        .void => "return;",
        .true_value => "return true;",
        .false_value => "return false;",
        .undefined_value => "return JSC::JSValue::encode(JSC::jsUndefined());",
        .allocation_failure => "return Bun::Bindgen::nativeAllocationFailure();",
        .monostate => "return std::monostate {};",
    };
}

fn cppReceiverHandle(receiver: ir.CppReceiverHandle) []const u8 {
    return switch (receiver) {
        .none => "nullptr",
        .native => "reinterpret_cast<BindNativeHandle*>(nativeBorrow.get())",
        .engine => "reinterpret_cast<BindNativeHandle*>(&thisObject->wrapped())",
        .callback_data => "callbackFunction->dataPtr",
    };
}

fn cppDeferredConversions(value: @FieldType(@FieldType(ir.CppWireCallee, "context"), "deferred")) []const u8 {
    return switch (value) {
        .none => "nullptr",
        .local => "reinterpret_cast<BindDeferredConversionsHandle*>(&bindingDeferredConversions)",
        .engine_context => "Bun::Bindgen::Detail::CppArgumentAccess::deferredHandle(context)",
    };
}

fn cppInboundFrame(e: *const Emitter, call: anytype) ?*const ir.CppArgumentFrame {
    const id = if (comptime @TypeOf(call.*).argument_role == .inbound_argument) call.frame orelse return null else call.frame;
    return e.ir.get(id);
}

fn cppInboundConversionBindings(e: *const Emitter, call: *const ir.CppInboundCall(.inbound_argument)) CppConversionBindings {
    const frame = cppInboundFrame(e, call) orelse return .{};
    return .{
        .receiver = if (frame.converter_receiver) |receiver| cppReceiverValue(receiver) else "JSC::JSValue(global)",
        .deferred = if (frame.deferred_conversions) "&bindingDeferredConversions" else "nullptr",
    };
}

fn cppInboundCodecBindings(e: *const Emitter, call: anytype) CppCodecBindings {
    const frame = cppInboundFrame(e, call);
    return .{
        .global = if (call.status.realm == .current) "global" else "nullptr",
        .native_roots = if (if (frame) |value| value.argument_roots else false) "&argumentRoots" else "nullptr",
    };
}

fn emitCppReceiverCheck(e: *Emitter, writer: *Writer, check: ir.CppReceiverCheck) Error!void {
    const class = e.class(switch (check.class) {
        .native, .engine, .constructor => |id| id,
    });
    try writer.print("    auto* thisObject = dynamicDowncast<{s}>(bindingThisValue.value());\n", .{switch (check.class) {
        .native, .engine => class.cpp_class_name,
        .constructor => class.cpp_constructor_name,
    }});
    if (check.brand) |brand| {
        try writer.writeAll("    if (!(");
        try emitCppBrandMatchExpression(e, writer, brand, "bindingThisValue.value()");
        try writer.writeAll(")) thisObject = nullptr;\n");
        try emitCppExceptionReturn(writer, 4, cppReturn(check.failure_return));
    }
    try writer.writeAll("    if (!thisObject) [[unlikely]] {\n");
    switch (check.invalid_this) {
        .no_op => |value| try writer.print("        {s}\n", .{cppReturn(value)}),
        .throw => {
            try writer.writeAll("        auto* error = Bun::createInvalidThisError(global, bindingThisValue.value(), ");
            try emitCppAsciiLiteral(writer, class.display_name);
            try writer.writeAll(");\n");
            try emitCppExceptionReturn(writer, 8, cppReturn(check.failure_return));
            try writer.print("        throwScope.throwException(global, error);\n        {s}\n", .{cppReturn(check.failure_return)});
        },
        .failure => |failure| try writer.print("        {s}::raise(*global, throwScope);\n        {s}\n", .{ try cppConversionFailure(e, failure), cppReturn(check.failure_return) }),
    }
    try writer.writeAll("    }\n");
    if (check.class == .native) try writer.print(
        \\    if (!thisObject->native()) {{
        \\        JSC::throwTypeError(global, throwScope, "{s} is detached"_s);
        \\        {s}
        \\    }}
        \\
    , .{ class.class_name, cppReturn(check.failure_return) });
}

fn cppCachedSlotReadExpression(e: *Emitter, read: ir.CppCachedSlotRead, value: []const u8) Allocator.Error![]const u8 {
    return switch (read) {
        .value => value,
        .callback => e.print("({0s}.isUndefined() ? {0s} : bindingCallbackFunction({0s}))", .{value}),
        .optional_callback => e.print("({0s}.isUndefinedOrNull() ? {0s} : bindingCallbackFunction({0s}))", .{value}),
    };
}

fn emitCppCacheRead(e: *Emitter, writer: *Writer, cache: ir.CppCacheAccess) Error!void {
    const class = e.class(cache.owner);
    const slot = class.slots[cache.slot];
    if (cache.nullable_receiver) try writer.print("    auto* thisObject = dynamicDowncast<{s}>(bindingThisValue.value());\n    if (thisObject) {{\n", .{class.cpp_constructor_name});
    try writer.print("    if (auto cached = thisObject->raw_slot_{s}()) return JSC::JSValue::encode({s});\n", .{ slot.slot_name, try cppCachedSlotReadExpression(e, cache.read, "cached") });
    if (cache.nullable_receiver) try writer.writeAll("    }\n");
}

fn emitCppInboundStructure(e: *Emitter, writer: *Writer, call: *const ir.CppInboundCall(.inbound_argument), construction: @FieldType(ir.CppInboundInput(.inbound_argument), "construct_structure")) Error!void {
    const class = e.class(construction.class);
    const failure_return = cppReturn(call.failure_return);
    try writer.print(
        \\    auto* zigGlobal = defaultGlobalObject(global);
        \\    auto* structure = zigGlobal->{0s}Structure();
        \\    JSC::JSValue newTarget = callFrame->newTarget();
        \\    if (zigGlobal->{0s}Constructor() != newTarget) [[unlikely]] {{
        \\        if (!newTarget) {{
        \\            {1s}::raise(*global, throwScope);
        \\            {2s}
        \\        }}
        \\        auto* functionGlobal = defaultGlobalObject(JSC::getFunctionRealm(global, newTarget.getObject()));
        \\
    , .{ class.cpp_class_name, try cppConversionFailure(e, construction.missing_new), failure_return });
    try emitCppExceptionReturn(writer, 8, failure_return);
    try writer.print("        structure = JSC::InternalFunction::createSubclassStructure(global, newTarget.getObject(), functionGlobal->{s}Structure());\n", .{class.cpp_class_name});
    try emitCppExceptionReturn(writer, 8, failure_return);
    try writer.writeAll("    }\n");
}

fn emitCppInboundArgumentFrame(e: *Emitter, writer: *Writer, call: anytype, id: ir.CppArgumentFrameId) Error!void {
    const frame = e.ir.get(id);
    if (frame.deferred_conversions) try writer.writeAll("    Bun::Bindgen::BindingDeferredConversions bindingDeferredConversions { *global };\n");
    if (frame.wire_storage) try writer.writeAll("    BindingTemporaryWireStorage wireStorage;\n");
    if (frame.argument_roots) try writer.writeAll("    Bun::Bindgen::CppResultContext argumentRoots { *global };\n");
    if (comptime @TypeOf(call.*).argument_role == .inbound_argument) {
        switch (call.callee) {
            .wire => |callee| {
                if (callee.lazy_storage) |storage| {
                    try writer.print("    {s} lazyStorage {{}};\n", .{storage.symbol});
                }
                try writer.print("    {s} args {{}};\n", .{try e.wireSpelling(callee.arguments)});
            },
            .cpp => |implementation| {
                const callee = e.ir.get(implementation);
                switch (callee.context) {
                    .call => |context| if (context.caller_source_origin) try writer.writeAll("    JSC::SourceOrigin bindingCallerSourceOrigin = callFrame->callerSourceOrigin(vm);\n"),
                    .engine_call, .engine_construct, .plain_construct => {},
                }
                try writer.print("    Bun::Bindgen::Cpp::{s} cppArgs {{}};\n", .{callee.arguments});
            },
            .builtin_constructor, .predicate, .reject, .load_cache, .store_cache => {},
        }
    } else {
        try writer.print("    {s} args {{}};\n", .{try e.wireSpelling(call.callee.arguments)});
    }
    if (frame.transferred.len != 0) {
        try writer.writeAll("    auto argumentOwner = WTF::makeScopeExit([&] {\n");
        for (frame.transferred) |argument| try emitCppOwnedNominalHandleReleasePlan(e, writer, argument.position, try e.print("nativeArgument_{s}", .{argument.name}), 8);
        try writer.writeAll("    });\n");
    }
}

fn emitCppInboundCall(e: *Emitter, writer: *Writer, call: anytype) Error!void {
    const frame = cppInboundFrame(e, call);
    const deferred_conversions = if (frame) |value| value.deferred_conversions else false;
    const environment = cppInboundCodecBindings(e, call);
    if (comptime @TypeOf(call.*).argument_role == .inbound_argument) {
        if (call.prepare_receiver) |source| try emitCppReceiverPreparation(writer, source);
        for (call.inputs) |*step| switch (step.*) {
            .prepare_arguments => |id| try emitCppInboundArgumentFrame(e, writer, call, id),
            .retain_lazy_receiver => |receiver| try writer.print("    lazyStorage.receiver.set(vm, {s});\n", .{cppReceiverValue(receiver)}),
            .check_receiver => |check| try emitCppReceiverCheck(e, writer, check),
            .read_cache => |cache| try emitCppCacheRead(e, writer, cache),
            .borrow_receiver => |class| try writer.print("    {s}::NativeBorrow nativeBorrow(*thisObject);\n", .{e.class(class).cpp_class_name}),
            .construct_structure => |construction| try emitCppInboundStructure(e, writer, call, construction),
            .javascript => |*input| try emitCppInboundArgument(e, writer, call, input),
            .required_count => |check| try emitCppRequiredArgumentCheck(e, writer, check),
            .native => |arguments| {
                for (arguments) |argument| try emitCppNativeParameterRoots(e, writer, argument.parameter, try e.print("nativeArgument_{s}", .{argument.name}), environment, 4);
                for (arguments) |argument| try emitCppNativeParameterStorage(e, writer, argument.parameter, argument.name);
                for (arguments, 0..) |argument, index| try emitCppNativeParameter(e, writer, environment, cppInboundConversionBindings(e, call), argument.parameter, try e.print("nativeArgument_{s}", .{argument.name}), try e.print("args.{s}", .{argument.name}), argument.path, argument.name, index, 4);
            },
        };
    } else {
        for (call.inputs) |*step| switch (step.*) {
            .prepare_arguments => |id| try emitCppInboundArgumentFrame(e, writer, call, id),
            .native => |arguments| {
                for (arguments) |argument| try emitCppNativeSourceRoots(e, writer, argument.encoder, try e.print("nativeArgs.{s}", .{argument.name}), environment, 4);
                for (arguments) |argument| try emitCppNativeEncodeValue(e, writer, argument.encoder, try e.print("nativeArgs.{s}", .{argument.name}), try e.print("args.{s}", .{argument.name}), environment, 4);
            },
        };
    }
    if (deferred_conversions) {
        if (comptime @TypeOf(call.*).argument_role == .inbound_argument) for (call.inputs) |*step| switch (step.*) {
            .javascript => |*input| switch (input.conversion) {
                .value => |value| try emitCppArgumentLeaseRegistration(e, writer, value.input, input.index),
                .lazy, .rest, .prepare, .selected => {},
            },
            .prepare_arguments, .retain_lazy_receiver, .check_receiver, .read_cache, .borrow_receiver, .construct_structure, .required_count, .native => {},
        };
        try writer.print("    if (!checkBindingConversionResult(throwScope, bindingDeferredConversions.seal())) {s}\n", .{cppReturn(call.failure_return)});
    }
    if (comptime @TypeOf(call.*).argument_role == .inbound_argument) {
        if (call.output == .promise) {
            try writer.writeAll("    auto* promise = JSC::JSPromise::create(vm, global->promiseStructure());\n");
            try emitCppCodecException(e, writer, call.codec_failure, 4);
        }
        switch (call.callee) {
            .wire => |callee| try emitCppInboundWireCall(e, writer, call, callee),
            .builtin_constructor => |class| {
                try emitCppCodecException(e, writer, call.codec_failure, 4);
                try writer.print("    auto* constructor = uncheckedDowncast<{s}>(callFrame->jsCallee());\n", .{e.class(class).cpp_constructor_name});
                try writer.writeAll("    auto cppResult = JSC::JSValue::decode(invokeBindingBuiltinConstructor(global, callFrame, constructor->builtinConstructorCall()));\n");
                try emitCppCodecException(e, writer, call.codec_failure, 4);
                try emitCppInboundFinish(e, writer, call, 4);
            },
            .reject => |failure| {
                try writer.print("    {s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, failure)});
                try emitCppInboundFinish(e, writer, call, 4);
            },
            .load_cache => |cache| {
                try writer.print("    auto cached = thisObject->slot_{s}();\n    auto cppResult = {s};\n", .{ cache.name, try cppCachedSlotReadExpression(e, cache.read, "cached") });
                try emitCppInboundFinish(e, writer, call, 4);
            },
            .store_cache => |conversion| {
                try emitCppCachedSlotSetterConversion(e, writer, conversion);
                try emitCppInboundFinish(e, writer, call, 4);
            },
            .predicate => |predicate| {
                try writer.writeAll("    bool cppResult = ");
                try emitCppValueTest(e, writer, predicate, "callFrame->argument(0)", "callFrame->argument(0)");
                try writer.writeAll(";\n");
                try emitCppCodecException(e, writer, call.codec_failure, 4);
                try emitCppInboundFinish(e, writer, call, 4);
            },
            .cpp => |callee_id| {
                const callee = e.ir.get(callee_id);
                const result_context = switch (callee.result) {
                    .completion => "nullptr",
                    .sync => |result| if (result.requires_context) context: {
                        try writer.writeAll("    Bun::Bindgen::CppResultContext cppResultContext { *global };\n");
                        break :context "&cppResultContext";
                    } else "nullptr",
                };
                const deferred = if (deferred_conversions) "&bindingDeferredConversions" else "nullptr";
                const common_context = try e.print("{{ *global, {s}, {s} }}", .{ result_context, deferred });
                switch (callee.context) {
                    .call => |context| try writer.print("    Bun::Bindgen::CppCallContext cppContext {{ {s}, {s}, {s} }};\n", .{ common_context, cppReceiverHandle(context.receiver), if (context.caller_source_origin) "bindingCallerSourceOrigin" else "std::nullopt" }),
                    .engine_call => |id| try writer.print("    Bun::Bindgen::CppEngineCallContext<{s}> cppContext {{ {s}, *thisObject }};\n", .{ e.class(id).cpp_class_name, common_context }),
                    .engine_construct => |id| try writer.print("    Bun::Bindgen::CppEngineConstructContext<{s}> cppContext {{ {s}, structure }};\n", .{ e.class(id).cpp_class_name, common_context }),
                    .plain_construct => |id| try writer.print("    Bun::Bindgen::CppPlainConstructContext cppContext {{ {s}, structure, {s}_createForInitialization }};\n", .{ common_context, e.class(id).cpp_class_name }),
                }
                switch (callee.result) {
                    .completion => |id| {
                        const api = e.ir.get(e.ir.get(id).api);
                        try writer.print("    {s}* completionHandle = nullptr;\n    auto completionStatus = {s}(reinterpret_cast<BindGlobalObjectHandle*>(global), reinterpret_cast<BindPromiseHandle*>(promise), &completionHandle);\n", .{ try e.wireSpelling(api.handle), api.create });
                        try writer.print("    if (bindingExceptionAfterDispatch(throwScope, completionStatus)) {s}\n", .{cppReturn(call.failure_return)});
                        try emitCppDecodeAllocationCheck(e, writer, call.codec_failure, "completionStatus == BIND_STATUS_OUT_OF_MEMORY", 4);
                        try writer.writeAll("    RELEASE_ASSERT(completionStatus == BIND_STATUS_OK && completionHandle);\n");
                        try writer.print("    Bun::Bindgen::Detail::CppCompletionEntry<Bun::Bindgen::Cpp::{s}> completion {{ completionHandle }};\n", .{api.codec});
                        try writer.print("    Bun::Bindgen::Cpp::{s}(cppContext, cppArgs, completion.sender());\n", .{callee.symbol});
                    },
                    .sync => |result| try writer.print("    {s}Bun::Bindgen::Cpp::{s}(cppContext, cppArgs);\n", .{ if (result.outcome != null) "auto cppOutcome = " else if (result.returns_value) "auto cppResult = " else "", callee.symbol }),
                }
                try emitCppCodecException(e, writer, call.codec_failure, 4);
                switch (callee.result) {
                    .completion => {},
                    .sync => |result| if (result.outcome) |outcome| {
                        try writer.writeAll(
                            \\    if (!cppOutcome) {
                            \\        Bun::Bindgen::EngineCallContext errorContext { *global, nullptr };
                            \\        std::visit([&](auto&& failure) {
                            \\            using Failure = std::remove_cvref_t<decltype(failure)>;
                            \\            if constexpr (std::is_same_v<Failure, Bun::Bindgen::NativeAllocationError>)
                            \\                Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
                            \\
                        );
                        for (outcome.errors) |failure| {
                            try writer.print("            else if constexpr (std::is_same_v<Failure, Bun::Bindgen::Cpp::{s}::Errors::{s}>)\n                Bun::Bindgen::Cpp::{s}(errorContext", .{ outcome.name, failure.name, failure.raise_symbol });
                            if (failure.payload != null) try writer.writeAll(", WTF::move(failure.value)");
                            try writer.writeAll(");\n");
                        }
                        try writer.writeAll("        }, cppOutcome.error());\n");
                        try emitCppCodecException(e, writer, call.codec_failure, 8);
                        try writer.writeAll("        RELEASE_ASSERT_NOT_REACHED();\n    }\n");
                        if (result.returns_value) try writer.writeAll("    auto cppResult = WTF::move(*cppOutcome);\n");
                    },
                }
                try emitCppInboundFinish(e, writer, call, 4);
            },
        }
    } else {
        try emitCppInboundWireCall(e, writer, call, call.callee);
    }
    try writer.writeAll("}\n\n");
}

fn emitCppInboundWireCall(e: *Emitter, writer: *Writer, call: anytype, callee: ir.CppWireCallee) Error!void {
    const plan = &call.status;
    const result = e.ir.get(callee.result);
    const wire_name = try e.wireSpelling(result.wire);
    const failure_return = call.failure_return;
    try writer.print(
        \\    BindCallContext wireContext {{
        \\        .global_object = {s},
        \\        .promise = {s},
        \\        .native_receiver = {s},
        \\        .caller_frame = {s},
        \\        .deferred_conversions = {s},
        \\        .lazy_storage = {s},
        \\        .call_id = takeBindingCallId(),
        \\    }};
        \\    {s} result {{}};
        \\
    , .{
        if (callee.realm == .current) "reinterpret_cast<BindGlobalObjectHandle*>(global)" else "nullptr",
        if (callee.context.promise) "reinterpret_cast<BindPromiseHandle*>(promise)" else "nullptr",
        cppReceiverHandle(callee.context.receiver),
        if (callee.context.caller_frame) "reinterpret_cast<const BindCallFrameHandle*>(callFrame)" else "nullptr",
        cppDeferredConversions(callee.context.deferred),
        if (callee.lazy_storage != null) "reinterpret_cast<BindLazyStorageHandle*>(&lazyStorage)" else "nullptr",
        wire_name,
    });
    if (cppInboundFrame(e, call)) |frame| if (frame.transferred.len != 0) try writer.writeAll("    argumentOwner.release();\n");
    try writer.print("    {s}{s}(&wireContext, &args, &result);\n", .{ if (plan.non_returning) "" else "BindStatus status = ", callee.symbol });
    if (plan.non_returning) return;
    try writer.print("    BindingResultGuard<{s}, {s}> resultGuard {{ result, {s} }};\n", .{ wire_name, result.destroy orelse "nullptr", switch (result.layout) {
        .void, .value => "status == BIND_STATUS_OK",
        .errors => "status == BIND_STATUS_OK || status == BIND_STATUS_FAILED",
    } });
    if (plan.realm == .current) try writer.print("    if ({s}(throwScope, status)) {s}\n", .{ if (plan.throws == .js_exception) "bindingExceptionAfterDispatch" else "bindingExceptionAfterNonThrowingDispatch", cppReturn(failure_return) });
    switch (result.layout) {
        .void, .value => {},
        .errors => |errors| try writer.print(
            \\    if (status == BIND_STATUS_OK)
            \\        RELEASE_ASSERT(result.tag == {0s}_TAG_VALUE);
            \\    else if (status == BIND_STATUS_FAILED)
            \\        RELEASE_ASSERT(result.tag > {0s}_TAG_VALUE && result.tag <= {1d});
            \\    else
            \\        RELEASE_ASSERT(result.tag == {0s}_TAG_VALUE);
            \\
        , .{ wire_name, errors.len }),
    }
    try writer.writeAll("    switch (status) {\n    case BIND_STATUS_OK: {\n");
    try emitCppInboundFinish(e, writer, call, 8);
    try writer.writeAll("    }\n    case BIND_STATUS_PENDING_EXCEPTION:\n        RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding returned pending_exception without a pending exception\");\n    case BIND_STATUS_OUT_OF_MEMORY:\n");
    try emitCppCodecAllocationFailure(e, writer, call.codec_failure, 8);
    try writer.writeAll("    case BIND_STATUS_FAILED: {\n");
    switch (result.layout) {
        .void, .value => try writer.writeAll("        RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding returned an undeclared domain error\");\n"),
        .errors => |errors| try emitCppDomainFailure(e, writer, errors, result.wire, failure_return),
    }
    try writer.writeAll("    }\n    default:\n        RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding returned an unknown status\");\n    }\n");
}

fn emitCppInboundCache(e: *Emitter, writer: *Writer, call: *const ir.CppInboundCall(.inbound_argument), value: []const u8, indent: usize) Error!void {
    const cache = call.cache orelse return;
    try writer.splatByteAll(' ', indent);
    if (cache.nullable_receiver) try writer.writeAll("if (thisObject) ");
    try writer.print("thisObject->set_slot_{s}(vm, {s});\n", .{ e.class(cache.owner).slots[cache.slot].slot_name, value });
}

fn cppWireResultValue(e: *const Emitter, id: ir.CppWireResultId) []const u8 {
    return switch (e.ir.get(id).layout) {
        .void => "result._reserved",
        .value => "result.value",
        .errors => "result.payload.value",
    };
}

fn emitCppInboundDecodedResult(e: *Emitter, writer: *Writer, call: anytype, result: ir.CppDecodedResult(@TypeOf(call.*).argument_role.result()), indent: usize) Error!void {
    const environment = cppInboundCodecBindings(e, call);
    try indented(writer, indent).print("{s} nativeResult {{}};\n", .{try cppDecodedValueType(e, result.decoder)});
    try emitCppWireDecode(e, writer, result.decoder, environment, cppWireResultValue(e, result.result), "nativeResult", "result", "result", indent);
    try emitCppResultCommit(writer, result.release_wire, "return WTF::move(nativeResult);", indent);
}

fn emitCppInboundFinish(e: *Emitter, writer: *Writer, call: anytype, indent: usize) Error!void {
    if (comptime @TypeOf(call.*).argument_role == .outbound_argument) {
        switch (call.output) {
            .void => try emitCppResultCommit(writer, true, "return std::monostate {};", indent),
            .decode_value => |result| try emitCppInboundDecodedResult(e, writer, call, result, indent),
        }
    } else {
        switch (call.output) {
            .promise => |owner| {
                if (owner == .cpp) {
                    try indented(writer, indent).writeAll("completion.commit();\n");
                }
                try emitCppInboundCache(e, writer, call, "promise", indent);
                try emitCppResultCommit(writer, owner == .wire, "return JSC::JSValue::encode(promise);", indent);
            },
            .constant => |result| try emitCppResultCommit(writer, result.release_wire, cppReturn(result.value), indent),
            .javascript => |value| {
                switch (value) {
                    .object => {
                        try indented(writer, indent).writeAll("RELEASE_ASSERT(cppResult);\n");
                    },
                    .value => {},
                }
                try emitCppResultCommit(writer, false, "return JSC::JSValue::encode(cppResult);", indent);
            },
            .attach_native => |attachment| {
                const construction = e.ir.get(attachment.construction);
                const class = e.class(construction.class);
                try indented(writer, indent).writeAll("auto* clientData = WebCore::clientData(vm);\n");
                try indented(writer, indent).print("auto* nativeResult = takeBindingHandle({s});\n", .{cppWireResultValue(e, attachment.result)});
                try indented(writer, indent).writeAll("RELEASE_ASSERT(nativeResult);\n");
                try indented(writer, indent).print("Bun::Bindgen::BindingNativeOwner nativeOwner(reinterpret_cast<BindVirtualMachineHandle*>(clientData->bunVM), nativeResult, {s});\n", .{class.release_native_on_vm_symbol});
                try indented(writer, indent).print("auto* jsResult = {s}::createForNative(vm, structure, nativeResult, clientData, structure->globalObject());\n", .{class.cpp_class_name});
                try indented(writer, indent).writeAll("nativeOwner.attachWrapper(jsResult);\n");
                try emitCppCodecException(e, writer, call.codec_failure, indent);
                for (construction.cached_getters) |member_id| {
                    const member = e.function(member_id);
                    try indented(writer, indent).print("(void){s}(global, JSC::JSValue::encode(jsResult), ", .{member.host_symbol});
                    try emitCppInternedPropertyKey(e, writer, member.js_name, "vm");
                    try writer.writeAll(");\n");
                    try emitCppCodecException(e, writer, call.codec_failure, indent);
                }
                try indented(writer, indent).writeAll("nativeOwner.commit();\n");
                try indented(writer, indent).writeAll("jsResult->reportNativeMemoryAllocated(vm);\n");
                try emitCppCodecException(e, writer, call.codec_failure, indent);
                try emitCppResultCommit(writer, true, "return JSC::JSValue::encode(jsResult);", indent);
            },
            .decode_value => |result| try emitCppInboundDecodedResult(e, writer, call, result, indent),
            .encode_value => |result| {
                try indented(writer, indent).writeAll("JSC::JSValue jsResult;\n");
                switch (result) {
                    .wire => |value| try emitCppMaterializedValue(e, writer, value.materializer, cppWireResultValue(e, value.result), "jsResult", indent),
                    .cpp => |value| {
                        const aliases = value.string_inputs;
                        if (aliases.len > 0) {
                            try indented(writer, indent).writeAll("if (!cppResult.isNull()) {\n");
                            for (aliases) |index| {
                                try indented(writer, indent + 4).print("if (jsResult.isEmpty() && input_{0d}.value().isString() && JSC::asString(input_{0d}.value())->tryGetValueImpl() == cppResult.impl()) jsResult = input_{0d}.value();\n", .{index});
                            }
                            try indented(writer, indent).writeAll("}\n");
                            try indented(writer, indent).writeAll("if (jsResult.isEmpty()) {\n");
                        }
                        try emitCppMaterializedValue(e, writer, value.materializer, "cppResult", "jsResult", indent + @as(usize, if (aliases.len > 0) 4 else 0));
                        if (aliases.len > 0) {
                            try indented(writer, indent).writeAll("}\n");
                        }
                    },
                }
                try emitCppCodecException(e, writer, call.codec_failure, indent);
                try emitCppInboundCache(e, writer, call, "jsResult", indent);
                try emitCppResultCommit(writer, switch (result) {
                    .wire => |value| value.release_wire,
                    .cpp => false,
                }, "return JSC::JSValue::encode(jsResult);", indent);
            },
        }
    }
}

fn emitCppPreparedValue(e: *Emitter, writer: *Writer, preparation: ir.CppInputPreparation, value: []const u8, path: CppPath, indent: usize) Error!void {
    const failure_policy = preparation.failure;
    switch (preparation.operation) {
        .object_or_string => {
            try indented(writer, indent).print("if (!{0s}.isObject()) {{\n", .{value});
            try indented(writer, indent + 4).print("{0s} = {0s}.toString(global);\n", .{value});
            try emitCppConversionExceptionReturn(writer, failure_policy, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
        .buffer => |buffer| {
            try indented(writer, indent).writeAll("{\n");
            try indented(writer, indent + 4).writeAll("BindingBufferSource buffer;\n");
            try emitCppBufferCheckStart(writer, buffer, "buffer", value, indent + 4);
            try emitCppBufferConversionError(e, writer, buffer, path, value, indent + 8);
            try indented(writer, indent + 8).print("return {s};\n", .{cppInputFailureReturn(failure_policy)});
            try indented(writer, indent + 4).writeAll("}\n");
            try indented(writer, indent).writeAll("}\n");
        },
    }
}

fn emitCppSelectedArgument(e: *Emitter, writer: *Writer, call: *const ir.CppInboundCall(.inbound_argument), input: *const ir.CppInboundArgument, selection: ir.CppArgumentSelection) Error!void {
    const index = input.index;
    const suffix = try e.print("selected_{d}", .{index});
    const context = cppInboundConversionBindings(e, call);
    const operand = try cppInboundInputValue(e, input, try e.print("bindingSelectedInput_{s}.value()", .{suffix}));
    if (selection.frame) |frame| {
        try writer.print("    JSC::EnsureStillAliveScope bindingSelectedInput_{s} = {s};\n", .{ suffix, try cppArgumentRead(e, frame.read) });
        for (frame.storage) |member| {
            try emitCppConverterValueStorage(e, writer, member.input, try e.print("{s}_{s}", .{ suffix, member.name }), 4);
        }
        if (frame.retain) |source_index| try writer.print("    JSC::EnsureStillAliveScope bindingPreparedInput_{d} = bindingSelectedInput_{s}.value();\n", .{ source_index, suffix });
    }
    try writer.print("    switch (cppArgs.{s}) {{\n", .{selection.source_name});
    for (selection.members) |selected| {
        for (selected.values) |name| {
            try writer.print("    case {s}::{s}:\n", .{ try e.cppType(selection.selector), name });
        }
        try writer.writeAll("    {\n");
        const member_suffix = try e.print("{s}_{s}", .{ suffix, selected.name });
        switch (selected.operation) {
            .none => {},
            .prepare => |preparation| {
                try writer.print("        auto selectedValue = bindingSelectedInput_{s}.value();\n", .{suffix});
                try emitCppPreparedValue(e, writer, preparation, "selectedValue", cppPath(selection.path), 8);
            },
            .convert => |conversion| {
                try writer.print("        {s} selectedValue {{}};\n", .{try e.cppType(e.ir.get(conversion).value_type)});
                try emitCppInputPlanValue(e, writer, context, conversion, operand, "selectedValue", cppPath(selection.path), member_suffix, 8);
                try writer.print("        cppArgs.{s}.set_{s}(WTF::move(selectedValue));\n", .{ selection.target, selected.name });
            },
        }
        try writer.writeAll("        break;\n    }\n");
    }
    try writer.writeAll("    }\n");
}

fn receiverByteLengthBoundAtPreparation(conversion: ir.CppInput) bool {
    return switch (conversion.operation) {
        .scalar => |scalar| switch (scalar.operation) {
            .receiver_byte_length => |receiver| receiver.bound == .at_preparation,
            .boolean, .idl, .clamp => false,
        },
        .void, .discarded, .converted, .optional, .enumeration, .string, .node_path, .external_ref, .value, .branded_value, .callback, .class_ref, .buffer, .aggregate, .lazy => false,
    };
}

fn emitCppBackendLazyArgument(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    conversion: ir.CppArgumentLazy,
    site: *const ir.CppInboundArgument,
) Error!void {
    const index = site.index;
    const lazy = conversion.input;
    const input = e.ir.get(lazy.value);
    const suffix = try cppArgumentSuffix(e, index);
    const prepare_receiver_bound = receiverByteLengthBoundAtPreparation(input.*);
    const value_type = try e.cppType(input.value_type);
    try emitCppConverterValueStorage(e, writer, lazy.value, suffix, 4);
    if (prepare_receiver_bound) {
        try writer.print("    const uint64_t bindingPreparedReceiverByteLength_{d} = WTF::uncheckedDowncast<JSC::JSArrayBufferView>({s})->byteLength();\n", .{ index, converter_context.receiver });
    }
    try writer.print("    {s} lazyValue_{d} {{}};\n", .{ value_type, index });
    try writer.print("    auto lazyConverter_{d} = [&", .{index});
    if (prepare_receiver_bound) try writer.print(", bindingPreparedReceiverByteLength = bindingPreparedReceiverByteLength_{d}", .{index});
    try writer.print(
        \\]() noexcept -> {s} const* {{
        \\        auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\
    , .{value_type});
    try emitCppInputPlanValue(
        e,
        writer,
        converter_context,
        lazy.value,
        try cppInboundInputValue(e, site, try e.print("input_{d}.value()", .{index})),
        try e.print("lazyValue_{d}", .{index}),
        cppPath(conversion.path),
        suffix,
        8,
    );
    try emitCppArgumentLeaseRegistration(e, writer, lazy.value, index);
    try writer.print(
        \\        return &lazyValue_{0d};
        \\    }};
        \\
    , .{index});
    const target = try cppArgumentDestination(e, conversion.target);
    try writer.print("    std::optional<Bun::Bindgen::Detail::CppLazyArgumentState<{s}>> lazyState_{d};\n", .{ value_type, index });
    const optional = conversion.missing != null;
    const indent: usize = if (optional) 8 else 4;
    if (conversion.missing) |missing| try writer.print("    if (!{s}) {{\n", .{try cppArgumentMissing(e, missing, index)});
    try indented(writer, indent).print("lazyState_{0d}.emplace(*global, lazyConverter_{0d}, {1s}, {2d});\n", .{
        index,
        converter_context.deferred,
        ir.lazyFieldKey(lazy.protocol),
    });
    try writer.splatByteAll(' ', indent);
    if (optional)
        try writer.print("{s}.emplace(lazyState_{d}->view());\n", .{ target, index })
    else
        try writer.print("{s} = lazyState_{d}->view();\n", .{ target, index });
    if (optional) try writer.writeAll("    }\n");
}

fn emitCppBackendRecordPlanToCpp(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    aggregate: *const ir.CppInputAggregate,
    entry: ir.CppRecordInput,
    value: []const u8,
    path: CppPath,
    suffix: []const u8,
    native_record: []const u8,
    indent: usize,
) Error!void {
    const failure_policy = aggregate.failure;
    const failure = cppInputFailureReturn(failure_policy);
    const value_input = e.ir.get(entry.value);
    const centralized_value = value_input.collection_storage;
    try indented(writer, indent).print("JSC::JSObject* recordObject_{s} = nullptr;\n", .{suffix});
    switch (entry.object) {
        .nullable => {
            try indented(writer, indent).print("if (!{s}.isUndefinedOrNull())\n", .{value});
            try indented(writer, indent + 4).print("recordObject_{s} = {s}.getObject();\n", .{ suffix, value });
            try indented(writer, indent).print("if (!{s}.isUndefinedOrNull() && !recordObject_{s}) {{\n", .{ value, suffix });
        },
        .required => {
            try indented(writer, indent).print("recordObject_{s} = {s}.getObject();\n", .{ suffix, value });
            try indented(writer, indent).print("if (!recordObject_{s}) {{\n", .{suffix});
        },
    }
    try emitCppValueInputError(e, writer, entry.object_error, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("JSC::PropertyNameArrayBuilder recordKeys_{s}(vm, JSC::PropertyNameMode::StringsAndSymbols, JSC::PrivateSymbolMode::Exclude);\n", .{suffix});
    try indented(writer, indent).print("if (recordObject_{s}) {{\n", .{suffix});
    try indented(writer, indent + 4).print("recordObject_{0s}->methodTable()->getOwnPropertyNames(recordObject_{0s}, global, recordKeys_{0s}, JSC::DontEnumPropertiesMode::Include);\n", .{suffix});
    try emitCppConversionExceptionReturn(writer, failure_policy, indent + 4);
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("{s} {s};\n", .{ try e.cppType(aggregate.value_type), native_record });
    const key_count = try e.print("recordKeys_{s}.size()", .{suffix});
    try emitCppSequenceReserve(writer, native_record, key_count, indent, failure_policy);
    if (centralized_value) {
        try emitCppSequenceReserve(writer, try e.print("bindingRecordConverters_{s}", .{suffix}), key_count, indent, failure_policy);
    }
    try indented(writer, indent).print("for (auto& recordKey_{0s} : recordKeys_{0s}) {{\n", .{suffix});
    try indented(writer, indent + 4).print("JSC::PropertySlot recordSlot_{0s}(recordObject_{0s}, JSC::PropertySlot::InternalMethodType::GetOwnProperty);\n", .{suffix});
    try indented(writer, indent + 4).print("bool recordHasProperty_{0s} = recordObject_{0s}->methodTable()->getOwnPropertySlot(recordObject_{0s}, global, recordKey_{0s}, recordSlot_{0s});\n", .{suffix});
    try emitCppConversionExceptionReturn(writer, failure_policy, indent + 4);
    try indented(writer, indent + 4).print("if (!recordHasProperty_{0s} || (recordSlot_{0s}.attributes() & JSC::PropertyAttribute::DontEnum))\n", .{suffix});
    try indented(writer, indent + 8).writeAll("continue;\n");
    try indented(writer, indent + 4).print("JSC::JSValue recordValue_{s};\n", .{suffix});
    try indented(writer, indent + 4).print("if (!recordSlot_{s}.isTaintedByOpaqueObject())\n", .{suffix});
    try indented(writer, indent + 8).print("recordValue_{0s} = recordSlot_{0s}.getValue(global, recordKey_{0s});\n", .{suffix});
    try indented(writer, indent + 4).writeAll("else\n");
    try indented(writer, indent + 8).print("recordValue_{0s} = recordObject_{0s}->get(global, recordKey_{0s});\n", .{suffix});
    try emitCppConversionExceptionReturn(writer, failure_policy, indent + 4);
    try indented(writer, indent + 4).print("WTF::String recordKeyValue_{0s} = WebCore::{1s}(*global, recordKey_{0s});\n", .{
        suffix,
        switch (entry.key_conversion) {
            .dom_string => "identifierToString",
            .usv_string => "identifierToUSVString",
            .byte_string => "identifierToByteString",
        },
    });
    try emitCppConversionExceptionReturn(writer, failure_policy, indent + 4);
    const value_suffix = try e.print("{s}_record_value", .{suffix});
    if (centralized_value) {
        try indented(writer, indent + 4).writeAll("auto bindingRecordValueStorage = std::unique_ptr<SemanticRecordValueStorage>(new (std::nothrow) SemanticRecordValueStorage);\n");
        try emitCppStorageAllocationCheck(writer, "bindingRecordValueStorage", indent + 4, failure_policy);
        try emitCppConverterValueAliases(e, writer, entry.value, value_suffix, "(*bindingRecordValueStorage)", indent + 4);
    }
    try indented(writer, indent + 4).print("{s} bindingNativeRecordValue_{s} {{}};\n", .{ try e.cppType(value_input.value_type), suffix });
    try emitCppInputPlanValue(
        e,
        writer,
        converter_context,
        entry.value,
        .{ .value = try e.print("recordValue_{s}", .{suffix}) },
        try e.print("bindingNativeRecordValue_{s}", .{suffix}),
        try cppPathPrepend(e, path, "value of "),
        value_suffix,
        indent + 4,
    );
    if (centralized_value) {
        try indented(writer, indent + 4).print("bindingRecordConverters_{s}.append(WTF::move(bindingRecordValueStorage));\n", .{suffix});
    }
    try indented(writer, indent + 4).print("{s}.append({s} {{ std::move(recordKeyValue_{s}), std::move(bindingNativeRecordValue_{s}) }});\n", .{ native_record, try cppRecordArgumentEntryPlanValueType(e, entry), suffix, suffix });
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppDictionaryInputPlan(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    aggregate: *const ir.CppInputAggregate,
    input: ir.CppDictionaryInput,
    root_path: CppPath,
    value: []const u8,
    target: []const u8,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const failure = cppInputFailureReturn(aggregate.failure);
    const path = if (input.path) |override| cppPath(override) else root_path;
    const object = try e.print("dictionaryObject_{s}", .{suffix});
    try indented(writer, indent).print("JSC::JSObject* {s} = nullptr;\n", .{object});
    switch (input.object) {
        .webidl_nullable => {
            try indented(writer, indent).print("if (!{s}.isUndefinedOrNull())\n", .{value});
            try indented(writer, indent + 4).print("{s} = {s}.getObject();\n", .{ object, value });
            try indented(writer, indent).print("if (!{s}.isUndefinedOrNull() && !{s}) {{\n", .{ value, object });
        },
        .node_object => |node| {
            try indented(writer, indent).print("{s} = {s}.getObject();\n", .{ object, value });
            try indented(writer, indent).print("bool dictionaryInvalid_{s} = !{s}", .{ suffix, object });
            if (node.reject_array) try writer.print(" || JSC::isArray(global, {s})", .{value});
            if (node.reject_callable) try writer.print(" || JSC::getCallData({s}).type != JSC::CallData::Type::None", .{value});
            try writer.writeAll(";\n");
            try emitCppConversionExceptionReturn(writer, aggregate.failure, indent);
            try indented(writer, indent).print("if (dictionaryInvalid_{s}) {{\n", .{suffix});
        },
        .exact_object => {
            try indented(writer, indent).print("{s} = {s}.getObject();\n", .{ object, value });
            try indented(writer, indent).print("if (!{s}) {{\n", .{object});
        },
    }
    try emitCppValueInputError(e, writer, input.object_error, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
    if (input.snapshot) {
        try indented(writer, indent).print("{0s} = bindingSnapshotOwnEnumerableProperties(global, {0s});\n", .{object});
        try emitCppConversionExceptionReturn(writer, aggregate.failure, indent);
    }
    for (input.steps) |step| switch (step) {
        .read => |read| {
            const field = e.ir.get(read.field);
            try emitCppDictionaryFieldLookup(e, writer, read.reader, object, try e.print("dictionaryValue_{s}_{s}", .{ suffix, field.name }), indent);
        },
        .source => |name| {
            try indented(writer, indent).print("{s}.{s} = Bun::Bindgen::CppDictionarySource {{ *global, {s} }};\n", .{ target, name, value });
        },
        .validate_string => |validation| {
            const field = e.ir.get(validation.field);
            const field_value = try e.print("dictionaryValue_{s}_{s}", .{ suffix, field.name });
            const field_path = try cppDictionaryFieldPath(e, path, field.path);
            try indented(writer, indent).print("if (!{s} && !{s}.isString()) {{\n", .{ try cppDictionaryFieldMissing(e, field.missing, field_value), field_value });
            try emitCppValueInputError(e, writer, validation.error_value, field_path, field_value, indent + 4);
            try indented(writer, indent + 4).print("return {s};\n", .{failure});
            try indented(writer, indent).writeAll("}\n");
        },
        .lazy => |lazy| {
            const field = e.ir.get(lazy.field);
            try emitCppBackendLazyConversion(e, writer, converter_context, lazy.input, .{ .value = object, .scope_suffix = suffix }, try e.print("{s}.{s}", .{ target, field.name }), try cppDictionaryFieldPath(e, path, field.path), try e.print("{s}_{s}", .{ suffix, field.name }), indent);
        },
        .value => |conversion| try emitCppDictionaryValueStep(e, writer, converter_context, conversion, object, target, path, suffix, indent),
    };
}

fn emitCppDictionaryValueStep(e: *Emitter, writer: *Writer, context: CppConversionBindings, step: ir.CppDictionaryValueStep, object: []const u8, target: []const u8, path: CppPath, suffix: []const u8, indent: usize) Error!void {
    const field = e.ir.get(step.field);
    const input = e.ir.get(field.input);
    const failure = cppInputFailureReturn(input.failure);
    const field_suffix = try e.print("{s}_{s}", .{ suffix, field.name });
    const field_value = try e.print("dictionaryValue_{s}", .{field_suffix});
    const field_target = try e.print("{s}.{s}", .{ target, field.name });
    const field_path = try cppDictionaryFieldPath(e, path, field.path);
    if (step.read) |read| try emitCppDictionaryFieldLookup(e, writer, read, object, field_value, indent);
    if (input.operation == .discarded) {
        try indented(writer, indent).print("static_cast<void>({s});\n", .{field_value});
    }
    if (field.incompatible) |incompatible| {
        const other = e.ir.get(incompatible.other);
        const other_value = try e.print("dictionaryValue_{s}_{s}", .{ suffix, other.name });
        try indented(writer, indent).print("if (!{s} && !{s}) {{\n", .{ try cppDictionaryFieldMissing(e, field.missing, field_value), try cppDictionaryFieldMissing(e, other.missing, other_value) });
        try indented(writer, indent + 4).writeAll("Bun::ERR::INCOMPATIBLE_OPTION_PAIR(throwScope, global, ");
        try emitCppUtf8String(writer, incompatible.primary);
        try writer.writeAll(", ");
        try emitCppUtf8String(writer, incompatible.current);
        try writer.writeAll(");\n");
        try indented(writer, indent + 4).print("return {s};\n", .{failure});
        try indented(writer, indent).writeAll("}\n");
    }
    if (field.unsupported) |reason| {
        try indented(writer, indent).print("if (!{s}) {{\n", .{try cppDictionaryFieldMissing(e, field.missing, field_value)});
        try indented(writer, indent + 4).writeAll("Bun::ERR::INVALID_ARG_VALUE(throwScope, global, ");
        try emitCppPath(e, writer, field_path);
        try writer.print(", {s}, ", .{field_value});
        try emitCppUtf8String(writer, reason);
        try writer.writeAll(");\n");
        try indented(writer, indent + 4).print("return {s};\n", .{failure});
        try indented(writer, indent).writeAll("}\n");
        return;
    }
    switch (field.presence) {
        .required_reject => |required| try emitCppRequiredInputCheck(e, writer, required, field_value, field_path, indent),
        .required_convert_undefined => {},
        .default_value => |default| {
            try indented(writer, indent).print("if ({s}) {{\n", .{try cppDictionaryFieldMissing(e, field.missing, field_value)});
            try emitCppBackendDefault(e, writer, default, field_target, indent + 4);
            try indented(writer, indent).writeAll("} else {\n");
        },
        .optional => {
            try indented(writer, indent).print("if (!{s}) {{\n", .{try cppDictionaryFieldMissing(e, field.missing, field_value)});
            if (field.tracks_lease_presence) {
                try indented(writer, indent + 4).print("bindingFieldPresent_{s} = true;\n", .{field_suffix});
            }
        },
    }
    const conditional = field.presence == .default_value or field.presence == .optional;
    try emitCppBackendDictionaryFieldValue(e, writer, context, step.operation, field_value, field_target, field_path, field_suffix, indent + @as(usize, if (conditional) 4 else 0));
    if (conditional) try indented(writer, indent).writeAll("}\n");
    if (step.retain) {
        try indented(writer, indent).print("JSC::EnsureStillAliveScope dictionaryPrepared_{s} = {s};\n", .{ field_suffix, field_value });
    }
}

fn cppDictionaryFieldMissing(e: *Emitter, missing: ir.DictionaryFieldMissingPlan, value: []const u8) Allocator.Error![]const u8 {
    return e.print("{s}{s}", .{ value, switch (missing) {
        .undefined => ".isUndefined()",
        .undefined_or_null => ".isUndefinedOrNull()",
        .absent => ".isEmpty()",
    } });
}

fn emitCppRequiredInputCheck(e: *Emitter, writer: *Writer, required: ir.CppRequiredInput, value: []const u8, path: CppPath, indent: usize) Error!void {
    try indented(writer, indent).print("if ({s}) {{\n", .{try cppDictionaryFieldMissing(e, required.missing, value)});
    try emitCppValueInputError(e, writer, required.error_value, path, "JSC::jsUndefined()", indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{cppInputFailureReturn(required.failure)});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppDictionaryPropertyGet(e: *Emitter, writer: *Writer, read: ir.CppPropertyLookup, object: []const u8, key: []const u8) Error!void {
    switch (read.method) {
        .get => try writer.print("{s}->get(global, ", .{object}),
        .get_if_exists => try writer.print("{s}->getIfPropertyExists(global, ", .{object}),
        .skip_object_prototype => try writer.print("Bun::getIfPropertyExistsPrototypePollutionMitigation(global, {s}, ", .{object}),
    }
    try emitCppInternedPropertyKey(e, writer, key, "vm");
    try writer.writeByte(')');
}

fn emitCppDictionaryFieldLookup(e: *Emitter, writer: *Writer, read: ir.CppPropertyRead, object: []const u8, value: []const u8, indent: usize) Error!void {
    try writer.splatByteAll(' ', indent);
    switch (read.operation) {
        .private_symbol => |symbol| {
            try writer.print("JSC::JSValue {0s} = {1s} ? {1s}->getDirect(vm, WebCore::builtinNames(vm).{2s}PrivateName()) : JSC::jsUndefined();\n", .{ value, object, symbol });
            try indented(writer, indent).print("if ({0s}.isEmpty()) {0s} = JSC::jsUndefined();\n", .{value});
            try emitCppConversionExceptionReturn(writer, read.failure, indent);
        },
        .property => |property| {
            try writer.print("JSC::JSValue {s} = {s} ? ", .{ value, object });
            try emitCppDictionaryPropertyGet(e, writer, property, object, property.first);
            try writer.writeAll(if (property.missing == .absent) " : JSC::JSValue();\n" else " : JSC::jsUndefined();\n");
            try emitCppConversionExceptionReturn(writer, read.failure, indent);
            for (property.aliases) |alias| {
                try indented(writer, indent).print("if ({s} && {s})\n", .{ try cppDictionaryFieldMissing(e, property.missing, value), object });
                try indented(writer, indent + 4).print("{s} = ", .{value});
                try emitCppDictionaryPropertyGet(e, writer, property, object, alias);
                try writer.writeAll(";\n");
                try emitCppConversionExceptionReturn(writer, read.failure, indent);
            }
        },
    }
}

const CppLazyBindings = struct { value: []const u8, index: []const u8 = "", scope_suffix: []const u8 = "" };

fn emitCppBackendLazyConversion(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    deferred: ir.CppDeferredInput,
    bindings: CppLazyBindings,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const conversion = deferred.conversion;
    const input = e.ir.get(conversion.value);
    const child = e.ir.get(conversion.value.position);
    const value_type = try e.cppType(input.value_type);
    const field_value = try e.print("lazyDictionaryValue_{s}", .{suffix});
    const field_output = try e.print("lazyDictionaryOutput_{s}", .{suffix});
    const failure = e.ir.get(conversion.value).failure;
    const has_paths = path == .template_path;
    const lazy_suffix = try e.print("{s}_lazy", .{suffix});
    const deferred_context: CppConversionBindings = .{ .receiver = "bindingConverterReceiver", .deferred = "bindingDeferredConversionsPointer" };

    try indented(writer, indent).print("bindingLazyState_{s}.reset(new (std::nothrow) Bun::Bindgen::Detail::CppLazyArgumentState<{s}> {{ *global, {s}, {d}, {s},\n", .{
        suffix,
        value_type,
        switch (deferred.source) {
            .value, .property => bindings.value,
            .element => try e.print("{s}, {s}", .{ bindings.value, bindings.index }),
            .projected => |name| try e.print("*bindingLazyState_{s}_{s}", .{ bindings.scope_suffix, name }),
        },
        ir.lazyFieldKey(conversion.protocol),
        if (has_paths) "m_paths" else "nullptr",
    });
    switch (deferred.source) {
        .value, .projected, .element => {},
        .property => |reader| {
            try indented(writer, indent + 4).writeAll("+[](JSC::JSGlobalObject& lazyGlobal, JSC::JSObject* lazyObject, JSC::JSValue& lazyValue) noexcept -> bool {\n");
            try indented(writer, indent + 8).writeAll("auto* global = &lazyGlobal;\n");
            try indented(writer, indent + 8).writeAll("auto& vm = global->vm();\n");
            try indented(writer, indent + 8).writeAll("auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
            try emitCppDictionaryFieldLookup(e, writer, reader, "lazyObject", "propertyValue", indent + 8);
            try indented(writer, indent + 8).writeAll("lazyValue = propertyValue;\n");
            try indented(writer, indent + 8).writeAll("throwScope.release();\n");
            try indented(writer, indent + 8).writeAll("return true;\n");
            try indented(writer, indent + 4).writeAll("},\n");
            try writer.splatByteAll(' ', indent + 4);
        },
    }
    try writer.print(
        "+[](const Bun::Bindgen::BindingConversionPaths* rawPaths, JSC::JSGlobalObject& lazyGlobal, JSC::JSValue lazyValue, JSC::JSValue bindingConverterReceiver, {s}& {s}, Bun::Bindgen::CppLazyPropertyStorage& lazyStorage, Bun::Bindgen::BindingDeferredConversions* lazyDeferred) noexcept -> bool {{\n",
        .{ value_type, field_output },
    );
    try indented(writer, indent + 8).writeAll("struct LazyPropertyStorage {\n");
    try emitCppConverterValueStorage(e, writer, conversion.value, lazy_suffix, indent + 8);
    try indented(writer, indent + 8).print("using Wire = {s};\n", .{try e.wireSpelling(child.wire)});
    try indented(writer, indent + 8).writeAll("Wire wireValue {};\n");
    try indented(writer, indent + 8).writeAll("BindingTemporaryWireStorage wireStorage;\n");
    try indented(writer, indent + 8).print("bool convert(const Bun::Bindgen::BindingConversionPaths* rawPaths, JSC::JSGlobalObject& lazyGlobal, JSC::JSValue {s}, [[maybe_unused]] JSC::JSValue bindingConverterReceiver, {s}& {s}, Bun::Bindgen::BindingDeferredConversions* lazyDeferred) noexcept\n", .{ field_value, value_type, field_output });
    try indented(writer, indent + 8).writeAll("{\n");
    try indented(writer, indent + 12).writeAll(if (has_paths)
        "[[maybe_unused]] auto* m_paths = static_cast<const Paths*>(rawPaths);\n"
    else
        "static_cast<void>(rawPaths);\n");
    try indented(writer, indent + 12).writeAll("auto* global = &lazyGlobal;\n");
    try indented(writer, indent + 12).writeAll("auto& vm = global->vm();\n");
    try indented(writer, indent + 12).writeAll("auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
    try indented(writer, indent + 12).writeAll("[[maybe_unused]] auto* bindingDeferredConversionsPointer = lazyDeferred;\n");
    if (deferred.required) |required| try emitCppRequiredInputCheck(e, writer, required, field_value, path, indent + 12);
    try emitCppInputPlanValue(e, writer, deferred_context, conversion.value, .{ .value = field_value }, field_output, path, lazy_suffix, indent + 12);
    try emitCppInputEncode(e, writer, e.ir.get(conversion.value).encoder, field_output, "wireValue", .{ .suffix = lazy_suffix }, indent + 12);
    if (input.holds_byte_lease) {
        try indented(writer, indent + 12).writeAll("RELEASE_ASSERT(bindingDeferredConversionsPointer);\n");
        try indented(writer, indent + 12).writeAll("{\n");
        try indented(writer, indent + 16).writeAll("auto& bindingDeferredConversions = *bindingDeferredConversionsPointer;\n");
        try emitCppSemanticConverterValueLeaseRegistration(e, writer, conversion.value, lazy_suffix);
        try indented(writer, indent + 12).writeAll("}\n");
    }
    try indented(writer, indent + 12).writeAll("throwScope.release();\n");
    try indented(writer, indent + 12).writeAll("return true;\n");
    try indented(writer, indent + 8).writeAll("}\n");
    try indented(writer, indent + 4).writeAll("};\n");
    try indented(writer, indent + 4).writeAll("auto* propertyStorage = lazyStorage.create<LazyPropertyStorage>();\n");
    try indented(writer, indent + 4).writeAll("if (!propertyStorage) {\n");
    try indented(writer, indent + 8).writeAll("auto throwScope = DECLARE_THROW_SCOPE(lazyGlobal.vm());\n");
    try indented(writer, indent + 8).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(&lazyGlobal, throwScope);\n");
    try indented(writer, indent + 8).writeAll("return false;\n");
    try indented(writer, indent + 4).writeAll("}\n");
    try indented(writer, indent + 4).print("return propertyStorage->convert(rawPaths, lazyGlobal, lazyValue, bindingConverterReceiver, {s}, lazyDeferred);\n", .{field_output});
    try indented(writer, indent).print("}}, {s}", .{converter_context.deferred});
    if (input.call_receiver) try writer.print(", {s}", .{converter_context.receiver});
    try writer.writeAll(" });\n");
    try indented(writer, indent).print("if (!bindingLazyState_{s}) {{\n", .{suffix});
    try emitCppOutOfMemoryReturn(writer, failure, indent + 4);
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("{s} = bindingLazyState_{s}->view();\n", .{ target, suffix });
    if (deferred.prefetch) {
        try indented(writer, indent).print("if (!checkBindingConversionResult(throwScope, bindingLazyState_{s}->prefetch())) return {s};\n", .{ suffix, cppInputFailureReturn(failure) });
    }
}

fn emitCppBackendDictionaryFieldValue(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    operation: ir.CppDictionaryFieldValue,
    value: []const u8,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    switch (operation) {
        .prepare => |preparation| try emitCppPreparedValue(e, writer, preparation, value, path, indent),
        .convert => |conversion| {
            const value_target = if (conversion.optional) try e.print("convertedDictionaryField_{s}", .{suffix}) else target;
            if (conversion.optional) {
                try indented(writer, indent).print("decltype({s})::value_type {s} {{}};\n", .{ target, value_target });
            }
            try emitCppInputPlanValue(e, writer, converter_context, conversion.input, .{ .value = value }, value_target, path, suffix, indent);
            if (conversion.optional) {
                try indented(writer, indent).print("{s} = std::move({s});\n", .{ target, value_target });
            }
        },
    }
}

// ─── input plan values ───

fn emitCppInputPlanValue(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    id: ir.CppInputId,
    operand: CppInputValue,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const value = operand.value;
    const conversion = e.ir.get(id);
    const failure_policy = conversion.failure;
    const failure = cppInputFailureReturn(failure_policy);
    switch (conversion.operation) {
        .void => {},
        .discarded => {
            try indented(writer, indent).print("static_cast<void>({s});\n", .{value});
            try indented(writer, indent).print("{s} = false;\n", .{target});
        },
        .scalar => |scalar| try emitCppScalarConversionTo(
            e,
            writer,
            converter_context,
            scalar,
            value,
            target,
            path,
            try e.print("conversionContext_{s}", .{suffix}),
            indent,
        ),
        .converted => |converted| {
            const converter = e.ir.get(converted.declaration);
            const match_suffix = try e.print("{s}_match", .{suffix});
            const match_input = try e.print("bindingConverterInput_{s}", .{match_suffix});
            const conversion_path = if (converted.path) |override| cppPath(override) else path;
            try emitCppInputPlanValue(e, writer, converter_context, converted.match, operand, match_input, conversion_path, match_suffix, indent);
            try writer.splatByteAll(' ', indent);
            if (converter.realm_free) {
                try writer.print("{s} = Bun::Bindgen::Custom::{s}({s}, ", .{ target, converter.symbol, match_input });
            } else {
                try writer.print("{s} = Bun::Bindgen::Custom::{s}(*global, {s}, ", .{ target, converter.symbol, match_input });
            }
            try emitCppPath(e, writer, conversion_path);
            try writer.writeAll(");\n");
            try emitCppConversionExceptionReturn(writer, failure_policy, indent);
        },
        .optional => |optional| {
            try indented(writer, indent).writeAll("if (!( ");
            try emitCppValueTest(e, writer, optional.presence, value, value);
            try writer.writeAll(")) {\n");
            try indented(writer, indent + 4).print("{s} = std::nullopt;\n", .{target});
            try indented(writer, indent).writeAll("} else {\n");
            if (optional.tracks_lease_presence) {
                try indented(writer, indent + 4).print("bindingLeasePresent_{s} = true;\n", .{suffix});
            }
            const child = e.ir.get(optional.value);
            const present = try e.print("bindingOptional_{s}", .{suffix});
            try indented(writer, indent + 4).print("{s} {s} {{}};\n", .{ try e.cppType(child.value_type), present });
            try emitCppInputPlanValue(e, writer, converter_context, optional.value, operand, present, path, try e.print("{s}_optional", .{suffix}), indent + 4);
            try indented(writer, indent + 4).print("{s}.emplace(WTF::move({s}));\n", .{ target, present });
            try indented(writer, indent).writeAll("}\n");
        },
        .enumeration => |enumeration| try emitCppEnumerationConversion(e, writer, enumeration, value, path, target, suffix, indent),
        .string => |string| try emitCppStringConversionTo(e, writer, string, value, target, path, try e.print("conversionContext_{s}", .{suffix}), indent),
        .node_path => |node_path| {
            try indented(writer, indent).print("bindingStorage_{s} = Bun::Bindgen::convertNodePath(*global, {s}, ", .{ suffix, value });
            try emitCppPath(e, writer, path);
            try writer.print(", {s}, {s});\n", .{ cppBoolean(node_path.file_url_strings), cppBoolean(node_path.boxed_strings) });
            try emitCppConversionExceptionReturn(writer, failure_policy, indent);
            try writer.splatByteAll(' ', indent);

            try writer.print("{s} = bindingStorage_{s}.span();\n", .{ target, suffix });
        },
        .external_ref => |conversion_| try emitCppIdlConversionTo(e, writer, conversion_, value, target, path, try e.print("conversionContext_{s}", .{suffix}), indent),
        inline .value, .branded_value, .callback => |input, kind| {
            const storage = try e.print("bindingStorage_{s}", .{suffix});
            const stored_value = try e.print("bindingValue({s})", .{storage});
            if (comptime kind == .branded_value) {
                try indented(writer, indent).writeAll("if (!( ");
                try emitCppBrandMatchExpression(e, writer, input.brand, value);
                try writer.writeAll(")) {\n");
                try emitCppValueInputError(e, writer, input.failure, path, value, indent + 4);
                try indented(writer, indent + 4).print("return {s};\n", .{failure});
                try indented(writer, indent).writeAll("}\n");
            }
            try indented(writer, indent).print("setBindingValue(vm, {s}, {s});\n", .{ storage, value });
            if (comptime kind == .callback) {
                try indented(writer, indent).print("if (JSC::getCallData({s}).type == JSC::CallData::Type::None) {{\n", .{stored_value});
                try emitCppValueInputError(e, writer, input.failure, path, value, indent + 4);
                try indented(writer, indent + 4).print("return {s};\n", .{failure});
                try indented(writer, indent).writeAll("}\n");
                if (input.captures_context) {
                    try indented(writer, indent).print("setBindingValue(vm, {s}, AsyncContextFrame::withAsyncContextIfNeeded(global, {s}));\n", .{ storage, stored_value });
                    try emitCppConversionExceptionReturn(writer, failure_policy, indent);
                }
            }
            const result_value = if (comptime kind == .value)
                if (input == .any) try cppAnyFromJSExpression(e, stored_value) else stored_value
            else
                stored_value;
            try indented(writer, indent).print("{s} = {s};\n", .{ target, result_value });
        },
        .class_ref => |reference_input| {
            const reference = reference_input.reference;
            const class = switch (reference) {
                .native, .engine => |class_id| e.class(class_id),
            };
            try indented(writer, indent).print("setBindingValue(vm, bindingWrapper_{0s}, {1s});\nauto* bindingObject_{0s} = dynamicDowncast<Bun::{2s}>(bindingValue(bindingWrapper_{0s}));\n", .{ suffix, value, class.cpp_class_name });
            try indented(writer, indent).writeAll("if (!( ");
            try emitCppClassBrandMatchExpression(e, writer, class, try e.print("bindingValue(bindingWrapper_{s})", .{suffix}));
            try writer.print(") || !bindingObject_{0s}{1s}) {{\n", .{ suffix, if (reference == .native) try e.print(" || !bindingObject_{s}->native()", .{suffix}) else "" });
            try emitCppValueInputError(e, writer, reference_input.failure, path, value, indent + 4);
            try indented(writer, indent + 4).print("return {s};\n", .{failure});
            try indented(writer, indent).writeAll("}\n");
            switch (reference) {
                .engine => {
                    try indented(writer, indent).print("bindingStorage_{0s} = &bindingObject_{0s}->wrapped();\n", .{suffix});
                },
                .native => {
                    try indented(writer, indent).print("bindingStorage_{0s}.emplace(*bindingObject_{0s});\n", .{suffix});
                },
            }
            try writer.splatByteAll(' ', indent);

            const expression = switch (reference) {
                .engine => try e.print("bindingStorage_{s}", .{suffix}),
                .native => try e.print("static_cast<{s}>(bindingStorage_{s}->get())", .{ try e.cppType(conversion.value_type), suffix }),
            };
            try writer.print("{s} = {s};\n", .{ target, expression });
        },
        .buffer => |buffer| switch (buffer) {
            .copy => |copy| try emitCppNestedBufferCopy(e, writer, copy, value, target, path, suffix, indent),
            .lease => |lease| try emitCppNestedLeasePreparation(e, writer, lease, value, target, path, suffix, indent),
        },
        .aggregate => |aggregate| {
            const converted = try e.print("bindingConvertedAggregate_{s}", .{suffix});
            try indented(writer, indent).print("{s} {s} {{}};\n", .{ try e.cppType(conversion.value_type), converted });
            const helper = e.ir.get(aggregate);
            try indented(writer, indent).print("if (!checkBindingConversionResult(throwScope, bindingSemanticConverter_{s}.convert(", .{suffix});
            try emitCppConverterPaths(e, writer, aggregate, path);
            try writer.print(", global, {s}, {s}, {s}", .{
                operand.source(),
                converted,
                converter_context.deferred,
            });
            if (helper.receiver) try writer.print(", {s}", .{converter_context.receiver});
            if (cppAggregateAcceptsSelection(helper)) {
                if (operand.selected_member) |selection| try writer.print(", {s}", .{selection});
            }
            try writer.writeAll(")))\n");
            try indented(writer, indent + 4).print("return {s};\n", .{cppInputFailureReturn(failure_policy)});
            try indented(writer, indent).print("{s} = WTF::move({s});\n", .{ target, converted });
        },
        .lazy => |lazy| {
            try emitCppBackendLazyConversion(e, writer, converter_context, lazy, .{ .value = value }, target, path, suffix, indent);
        },
    }
}

fn emitCppBackendDefault(e: *Emitter, writer: *Writer, value: anytype, target: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("{s} = ", .{target});
    try emitCppDefault(e, writer, value);
    try writer.writeAll(";\n");
}

fn emitCppDefault(e: *Emitter, writer: *Writer, value: anytype) Error!void {
    for (value.wrappers) |value_type| try writer.print("{s} {{ std::in_place, ", .{try e.cppType(value_type)});
    switch (value.operation) {
        .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |literal| try writer.writeAll(try cppIntegerLiteral(e, literal)),
        .number => |number| try emitCppNumberLiteral(writer, number),
        .string => |text| try emitCppUtf8String(writer, text),
        .null_value => try writer.writeAll("JSC::jsNull()"),
        .undefined_value => try writer.writeAll("JSC::jsUndefined()"),
        .any_null => try writer.writeAll("Bun::Bindgen::Detail::CppAnyAccess::fromJS(JSC::jsNull())"),
        .any_undefined => try writer.writeAll("Bun::Bindgen::Detail::CppAnyAccess::fromJS(JSC::jsUndefined())"),
        .enumeration => |tag| try writer.print("static_cast<{s}>({d})", .{ try e.cppType(tag.type), tag.value }),
        .empty_optional => try writer.writeAll("std::nullopt"),
    }
    for (value.wrappers) |_| try writer.writeAll(" }");
}

fn emitCppResultObjectCreation(e: *Emitter, writer: *Writer, variable: []const u8, object: ir.CppObjectCreation, indent: usize, failure_return: []const u8) Error!void {
    try writer.splatByteAll(' ', indent);
    const result_to_string_tag = switch (object) {
        .ordinary => |tag| ordinary: {
            try writer.print("auto* {s} = JSC::constructEmptyObject(global);\n", .{variable});
            break :ordinary tag;
        },
        .null_prototype => |tag| null_prototype: {
            try writer.print("auto* {s} = JSC::constructEmptyObject(vm, global->nullPrototypeObjectStructure());\n", .{variable});
            break :null_prototype tag;
        },
        .class => |class| instance: {
            try writer.print("auto* {s} = JSC::JSFinalObject::create(vm, defaultGlobalObject(global)->{s}Structure());\n", .{ variable, e.class(class).cpp_class_name });
            break :instance null;
        },
    };
    try emitCppAllocationCheck(writer, variable, indent, failure_return);
    if (result_to_string_tag) |tag| {
        try indented(writer, indent).print("{s}->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, ", .{variable});
        try emitCppUtf8String(writer, tag);
        try writer.writeAll("), JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly);\n");
        try emitCppExceptionReturn(writer, indent, failure_return);
    }
}

fn emitCppAssignment(writer: *Writer, target: []const u8, source: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("{s} = {s};\n", .{ target, source });
}

// ─── completions ───

fn emitCppCompletionMaterializer(e: *Emitter, writer: *Writer, completion: *const ir.CompletionPlan, program: @FieldType(ir.CppCompletionMaterializer, "engine")) Error!void {
    const codec = try e.print("Bun::Bindgen::Cpp::{s}", .{e.ir.get(program.api).codec});
    try writer.print("JSC::JSValue {s}::materialize(Bun::Bindgen::EngineCallContext& context, NativeValue value)\n{{\n", .{codec});
    try writer.writeAll("    auto* global = &context.globalObject;\n    auto& vm = global->vm();\n    auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
    try writer.print("    Bun::Bindgen::Engine::{s} args {{ .{s} = value }};\n", .{ program.arguments, program.argument });
    try writer.print("    {s}Bun::Bindgen::Engine::{s}(context, args);\n", .{ if (program.result == .void) "" else "auto nativeResult = ", program.callee });
    switch (program.exception_check) {
        .exception => try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, {});\n"),
        .termination => try writer.writeAll("    if (bindingTerminationAfterNonThrowingCall(throwScope)) return {};\n"),
    }
    if (program.result == .allocation) try writer.writeAll(
        \\    if (!nativeResult) {
        \\        Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
        \\        return {};
        \\    }
        \\
    );
    try writer.writeAll("    JSC::JSValue jsResult;\n");
    switch (program.result) {
        .void => try writer.writeAll("    jsResult = JSC::jsUndefined();\n"),
        .value => |result| try emitCppMaterializedValue(e, writer, result, "nativeResult", "jsResult", 4),
        .allocation => |result| try emitCppMaterializedValue(e, writer, result, "nativeResult.value()", "jsResult", 4),
    }
    try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, {});\n    return jsResult;\n}\n\n");
    try writer.print("static JSC::JSValue materializeBindingCompletion_{d}(JSC::JSGlobalObject* global, void* payload)\n{{\n", .{program.api.index});
    try writer.writeAll("    Bun::Bindgen::EngineCallContext context { *global, nullptr };\n");
    try writer.print("    return {0s}::materialize(context, reinterpret_cast<{0s}::NativeValue>(*static_cast<{1s}*>(payload)));\n}}\n\n", .{ codec, try e.wireSpelling(e.ir.get(completion.payload).wire) });
}

fn emitCompletionDelivery(e: *Emitter, writer: *Writer, completion_id: ir.CompletionId) Error!void {
    const completion = e.ir.get(completion_id);
    const program = e.ir.cpp_completion_deliveries[completion_id.index];
    const wire = try e.wireSpelling(program.wire);
    switch (program.materializer) {
        .wire => {},
        .engine => |materializer| try emitCppCompletionMaterializer(e, writer, completion, materializer),
    }
    try emitCppExternC(writer, "void {s}(BindGlobalObjectHandle* globalHandle, BindPromiseHandle* promiseHandle, BindCompletionDisposition disposition, {s}* result)",
        \\{{
        \\
    , .{ e.ir.get(program.completion).deliver_symbol, wire });
    switch (program.layout) {
        .void, .value => {},
        .errors => |errors| {
            try writer.writeAll("    static constexpr BindingDomainErrorFactory errors[] {\n");
            for (errors) |failure| try writer.print("        {{ offsetof({s}, payload.error_{s}), Bun::Bindgen::{s} }},\n", .{ wire, failure.name, failure.factory });
            try writer.writeAll("    };\n");
        },
    }
    try writer.writeAll("    static constexpr BindingCompletionCodec codec {\n");
    try writer.print("        sizeof({s}),\n", .{wire});
    if (program.destroy) |destroy|
        try writer.print("        [](void* value) {{ {s}(static_cast<{s}*>(value)); }},\n", .{ destroy, wire })
    else
        try writer.writeAll("        [](void*) {},\n");
    switch (program.materializer) {
        .engine => |materializer| try writer.print("        materializeBindingCompletion_{d},\n", .{materializer.api.index}),
        .wire => |materializer| try writer.print("        Bun::Bindgen::{s},\n", .{try cppCompletionValueDecoder(e, materializer)}),
    }
    try writer.print("        offsetof({s}, {s}),\n", .{
        wire,
        switch (program.layout) {
            .void => "_reserved",
            .value => "value",
            .errors => "payload.value",
        },
    });
    switch (program.layout) {
        .errors => try writer.print("        offsetof({s}, tag),\n        errors,\n", .{wire}),
        .void, .value => try writer.writeAll("        0, {},\n"),
    }
    try writer.writeAll("        []() { return ");
    switch (completion.sender_drop) {
        .reject => |message| try emitCppUtf8String(writer, message),
        .cancel, .leave_pending => try emitCppUtf8String(writer, "binding completion dropped"),
    }
    try writer.writeAll(
        \\; },
        \\    };
        \\    deliverBindingCompletion(reinterpret_cast<JSC::JSGlobalObject*>(globalHandle), reinterpret_cast<JSC::JSPromise*>(promiseHandle), disposition, result, codec);
        \\}
        \\
    );
}

// ─── domain errors ───

fn emitCppDomainFailure(
    e: *Emitter,
    writer: *Writer,
    errors: []const ir.CppWireErrorFactory,
    result_wire: ir.WireTypeId,
    failure_return: ir.CppReturn,
) Error!void {
    const return_value = cppReturn(failure_return);
    try writer.writeAll("        switch (result.tag) {\n");
    for (errors) |failure| {
        try writer.print("        case {s}_TAG_ERROR_{s}: {{\n", .{ try e.wireSpelling(result_wire), failure.name });
        try writer.print("            auto* jsError = Bun::Bindgen::{s}(global, &result.payload.error_{s});\n", .{ failure.factory, failure.name });
        try emitCppExceptionReturn(writer, 12, return_value);
        try writer.print(
            \\            RELEASE_ASSERT(jsError);
            \\            throwScope.throwException(global, jsError);
            \\            {s}
            \\        }}
            \\
        , .{return_value});
    }
    try writer.writeAll(
        \\        default:
        \\            RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("binding returned an unknown domain-error tag");
        \\        }
        \\
    );
}

fn emitCppErrorPayload(e: *Emitter, writer: *Writer, callee: ir.CppMaterializerId(.inbound_result), source: []const u8, target: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("JSC::JSValue {s} = Bun::Bindgen::{s}(global", .{ target, try materializerName(e, callee) });
    if (!e.ir.get(callee).isVoid()) try writer.print(", {s}", .{source});
    try writer.writeAll(");\n");
    try emitCppExceptionReturn(writer, indent, "return {};");
}

fn emitCppErrorMessage(writer: *Writer, message: ir.CppErrorMessage, payload: []const u8, indent: usize) Error!void {
    try indented(writer, indent).writeAll("WTF::String errorMessage = ");
    switch (message) {
        .literal => |literal| try emitCppUtf8String(writer, literal),
        .payload => |read| switch (read) {
            .string => try writer.writeAll(payload),
            .string_handle => try writer.print("decodeBindingString({s})", .{payload}),
        },
    }
    try writer.writeAll(";\n");
    if (message == .payload) {
        try indented(writer, indent).writeAll("if (errorMessage.isNull()) errorMessage = WTF::emptyString();\n");
    }
}

fn emitCppDomainErrorObjectBody(
    e: *Emitter,
    writer: *Writer,
    factory: *const ir.DomainErrorFactory,
    indent: usize,
    payload: []const u8,
) Error!void {
    switch (factory.operation) {
        .error_object => |error_object| {
            try emitCppErrorMessage(writer, error_object.message, payload, indent);
            try emitCppErrorObject(writer, error_object.class, error_object.code, indent);
        },
        .dom_exception => |exception| {
            try emitCppErrorMessage(writer, exception.message, payload, indent);
            try emitCppDOMException(writer, exception.name, indent);
        },
        .builtin_error => |builtin| try emitCppBuiltinErrorObject(e, writer, builtin, indent, payload),
        .class_instance => |materializer| {
            try emitCppErrorPayload(e, writer, materializer, payload, "jsResult", indent);
            try indented(writer, indent).writeAll("auto* jsError = JSC::asObject(jsResult);\n");
        },
        .aggregate_error => |aggregate| {
            try emitCppErrorPayload(e, writer, aggregate.materializer, payload, "jsResult", indent);
            try indented(writer, indent).writeAll("auto* jsError = createBindingAggregateError(global, jsResult, ");
            try emitCppUtf8String(writer, aggregate.message);
            try writer.writeAll(");\n");
            try emitCppAllocationCheck(writer, "jsError", indent, "return {};");
        },
        .system_error => |system_error| try emitCppSystemErrorObject(e, writer, system_error, indent, payload),
    }
    try emitCppExceptionReturn(writer, indent, "return {};");
    if (factory.name_override) |name_override| {
        try indented(writer, indent).writeAll("auto bindingErrorName = ");
        try emitCppUtf8String(writer, name_override.name);
        try writer.writeAll(";\n");
        try indented(writer, indent).writeAll("if (bindingErrorName.isNull()) {\n");
        try indented(writer, indent + 4).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
        try emitCppPendingExceptionReturn(writer, indent + 4, "return {};");
        try indented(writer, indent).writeAll("}\n");
        try indented(writer, indent).print("jsError->putDirect(vm, vm.propertyNames->name, JSC::jsString(vm, bindingErrorName), {s});\n", .{
            if (name_override.enumerable) "0" else "static_cast<unsigned>(JSC::PropertyAttribute::DontEnum)",
        });
        try emitCppExceptionReturn(writer, indent, "return {};");
    }
}

fn emitCppDOMException(writer: *Writer, exception_name: ir.DOMExceptionName, indent: usize) Error!void {
    try indented(writer, indent).print("auto exception = WebCore::DOMException::create(WebCore::ExceptionCode::{t}, errorMessage);\n", .{exception_name});
    try indented(writer, indent).writeAll("auto errorValue = WebCore::toJS(global, static_cast<WebCore::JSDOMGlobalObject*>(global), exception.get());\n");
    try emitCppExceptionReturn(writer, indent, "return {};");
    try indented(writer, indent).writeAll("auto* jsError = JSC::asObject(errorValue);\n");
}

fn emitCppBuiltinErrorObject(
    e: *Emitter,
    writer: *Writer,
    builtin: @FieldType(@FieldType(ir.DomainErrorFactory, "operation"), "builtin_error"),
    indent: usize,
    payload_source: []const u8,
) Error!void {
    try emitCppErrorPayload(e, writer, builtin.materializer, payload_source, "bindingErrorPayload", indent);
    try indented(writer, indent).print("auto* bindingErrorFactory = static_cast<Zig::GlobalObject*>(global)->builtinInternalFunctions().{s}().m_{s}Function.get();\n", .{ builtin.group, builtin.function });
    try indented(writer, indent).writeAll("JSC::MarkedArgumentBuffer bindingErrorArguments;\n");
    try indented(writer, indent).writeAll("bindingErrorArguments.append(bindingErrorPayload);\n");
    try indented(writer, indent).writeAll("if (bindingErrorArguments.hasOverflowed()) {\n");
    try indented(writer, indent + 4).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
    try emitCppPendingExceptionReturn(writer, indent + 4, "return {};");
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).writeAll("auto bindingErrorResult = JSC::profiledCall(global, JSC::ProfilingReason::API, bindingErrorFactory, JSC::getCallData(bindingErrorFactory), JSC::jsUndefined(), bindingErrorArguments);\n");
    try emitCppExceptionReturn(writer, indent, "return {};");
    try indented(writer, indent).writeAll("auto* jsError = dynamicDowncast<JSC::ErrorInstance>(bindingErrorResult);\n");
    try indented(writer, indent).writeAll("RELEASE_ASSERT_WITH_MESSAGE(jsError, \"binding error factory did not return an Error instance\");\n");
}

fn emitCppErrorObject(writer: *Writer, error_class: ir.ErrorClass, error_code: ?[]const u8, indent: usize) Error!void {
    const class_name = errorClassName(error_class);
    try writer.splatByteAll(' ', indent);
    if (error_code) |code| {
        try writer.print("auto* jsError = Bun::createErrorWithCode(global, JSC::ErrorType::{0s}, \"{0s}\"_s, \"{1s}\"_s, errorMessage);\n", .{ class_name, code });
    } else {
        try writer.print("auto* jsError = createBindingError(global, JSC::ErrorType::{s}, errorMessage);\n", .{class_name});
    }
    try emitCppAllocationCheck(writer, "jsError", indent, "return {};");
}

fn emitCppSystemErrorObject(e: *Emitter, writer: *Writer, plan: ir.CppSystemError, indent: usize, payload: []const u8) Error!void {
    try indented(writer, indent).print("const auto& systemError = {s};\n", .{payload});
    const fields: []const []const u8 = switch (plan.detail) {
        .info => &.{ "code", "message", "syscall" },
        .standard => &.{ "code", "message", "path", "syscall", "hostname", "dest", "address" },
    };
    for (fields) |field| {
        try writer.splatByteAll(' ', indent);
        switch (plan.payload) {
            .wire => try writer.print("auto systemError_{0s} = decodeBindingUTF8Bytes(systemError.{0s});\n", .{field}),
            .native => try writer.print("auto systemError_{0s} = Bun::decodeUTF8ReplacingInvalidSequences(systemError.{0s}.span());\n", .{field}),
        }
        try emitCppAllocationCheck(writer, try e.print("systemError_{s}", .{field}), indent, "return {};");
    }
    switch (plan.detail) {
        .info => {
            try indented(writer, indent).writeAll("auto* jsError = createBindingSystemErrorWithInfoObject(global, systemError.error_number, systemError_code.value(), systemError_message.value(), systemError_syscall.value(), ");
            try emitCppInternedPropertyKey(e, writer, "info", "vm");
            try writer.writeAll(");\n");
        },
        .standard => |standard| {
            try indented(writer, indent).writeAll(switch (plan.payload) {
                .wire => "const std::optional<uint16_t> systemErrorPort = decodeBindingPresence(systemError.port.present) ? std::optional<uint16_t> { systemError.port.value } : std::nullopt;\n",
                .native => "const std::optional<uint16_t> systemErrorPort = systemError.port.has_value() ? std::optional<uint16_t> { systemError.port.value() } : std::nullopt;\n",
            });
            try indented(writer, indent).writeAll("auto* jsError = createBindingSystemError(global, systemError.error_number, systemError_code.value(), systemError_message.value(), systemError_path.value(), systemError_syscall.value(), systemError_hostname.value(), systemError.fd, systemError_dest.value(), systemError_address.value(), systemErrorPort, ");
            try emitCppInternedPropertyKey(e, writer, "address", "vm");
            try writer.writeAll(", ");
            try emitCppInternedPropertyKey(e, writer, "port", "vm");
            try writer.print(", {s});\n", .{
                if (standard.metadata_configurable) "0" else "static_cast<unsigned>(JSC::PropertyAttribute::DontDelete)",
            });
        },
    }
    try emitCppAllocationCheck(writer, "jsError", indent, "return {};");
}

fn emitCppUtf8String(writer: *Writer, value: []const u8) Error!void {
    for (value) |byte| {
        if (!std.ascii.isAscii(byte)) break;
    } else {
        try writer.writeAll("WTF::String { ");
        try emitCppAsciiLiteral(writer, value);
        return writer.writeAll(" }");
    }
    try writer.writeAll("WTF::String::fromUTF8(");
    try emitCppRawStringLiteral(writer, value);
    try writer.writeByte(')');
}

fn emitCppInternedPropertyKey(e: *Emitter, writer: *Writer, key: []const u8, vm_expression: []const u8) Error!void {
    const index = e.property_key_indexes.get(key).?;
    try writer.print("Bun::Bindgen::internedPropertyKey({s}, {d})", .{ vm_expression, index });
}

fn emitCppAsciiLiteral(writer: *Writer, value: []const u8) Error!void {
    try emitCppRawStringLiteral(writer, value);
    try writer.writeAll("_s");
}

// ─── enumerations ───

fn emitCppEnumerationConversion(
    e: *Emitter,
    writer: *Writer,
    conversion: ir.CppEnumerationInput,
    value: []const u8,
    path: CppPath,
    target: []const u8,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const failure = conversion.failure;
    const numbers = conversion.numbers orelse return emitCppEnumerationStringConversion(e, writer, conversion, value, path, target, suffix, indent);
    try indented(writer, indent).print("if ({s}.isNumber()) {{\n", .{value});
    for (conversion.values, 0..) |tag, index| {
        try indented(writer, indent + 4).print("{s}if ({s}.asNumber() == {d})\n", .{ if (index == 0) "" else "else ", value, tag.tag });
        try emitCppEnumerationAssignment(e, writer, conversion.type, target, tag.tag, indent + 8);
    }
    try indented(writer, indent + 4).writeAll("else {\n");
    try emitCppEnumerationUnmatched(e, writer, numbers, conversion.type, value, path, target, suffix, indent + 8, failure);
    try indented(writer, indent + 4).writeAll("}\n");
    try indented(writer, indent).writeAll("} else {\n");
    try emitCppEnumerationStringConversion(e, writer, conversion, value, path, target, suffix, indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppEnumerationAssignment(e: *Emitter, writer: *Writer, type_id: ir.CppTypeId, target: []const u8, tag: u16, indent: usize) Error!void {
    try indented(writer, indent).print("{s} = static_cast<{s}>({d});\n", .{ target, try e.cppType(type_id), tag });
}

fn emitCppEnumerationStringConversion(
    e: *Emitter,
    writer: *Writer,
    conversion: ir.CppEnumerationInput,
    value: []const u8,
    path: CppPath,
    target: []const u8,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const failure = conversion.failure;
    const context = try e.print("enumerationContext_{s}", .{suffix});
    switch (conversion.string) {
        .idl => |idl| try emitCppNamedConversionContext(e, writer, idl.context, path, context, indent),
        .coerced => {},
        .reject_non_string => |invalid| {
            try indented(writer, indent).print("if (!{s}.isString()) {{\n", .{value});
            try emitCppEnumerationFailure(e, writer, invalid, value, path, suffix, indent + 4, failure);
            try indented(writer, indent).writeAll("}\n");
        },
    }
    try indented(writer, indent).print("WTF::String enumerationText_{s} = ", .{suffix});
    switch (conversion.string) {
        .idl => |idl| try emitCppIdlValue(e, writer, idl, value, context),
        .coerced, .reject_non_string => try writer.print("{s}.toWTFString(global)", .{value}),
    }
    try writer.writeAll(";\n");
    try emitCppConversionExceptionReturn(writer, failure, indent);
    for (conversion.values, 0..) |tag, index| {
        try indented(writer, indent).print("{s}if (", .{if (index == 0) "" else "else "});
        try emitCppEnumerationTextComparison(writer, conversion.ascii_case_insensitive, suffix, tag.text);
        for (tag.aliases) |alias| {
            try writer.writeAll(" || ");
            try emitCppEnumerationTextComparison(writer, conversion.ascii_case_insensitive, suffix, alias);
        }
        try writer.writeAll(") {\n");
        try emitCppEnumerationAssignment(e, writer, conversion.type, target, tag.tag, indent + 4);
        try indented(writer, indent).writeAll("}\n");
    }
    try indented(writer, indent).writeAll(if (conversion.values.len == 0) "{\n" else "else {\n");
    try emitCppEnumerationUnmatched(e, writer, conversion.unmatched, conversion.type, value, path, target, suffix, indent + 4, failure);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppEnumerationUnmatched(e: *Emitter, writer: *Writer, unmatched: ir.CppEnumerationUnmatched, type_id: ir.CppTypeId, value: []const u8, path: CppPath, target: []const u8, suffix: []const u8, indent: usize, failure: ir.CppInputFailure) Error!void {
    switch (unmatched) {
        .value => |tag| try emitCppEnumerationAssignment(e, writer, type_id, target, tag, indent),
        .failure => |invalid| try emitCppEnumerationFailure(e, writer, invalid, value, path, suffix, indent, failure),
    }
}

fn emitCppEnumerationFailure(e: *Emitter, writer: *Writer, invalid: ir.CppEnumerationFailure, value: []const u8, path: CppPath, suffix: []const u8, indent: usize, failure: ir.CppInputFailure) Error!void {
    switch (invalid) {
        .prefix => |prefix| {
            try indented(writer, indent).print("auto invalidEnumerationMessage_{0s} = WTF::tryMakeString(Bun::Bindgen::bindingLiteral<{1s}>(), enumerationText_{0s});\n", .{ suffix, try cppByteStringLiteral(e, prefix.message) });
            try indented(writer, indent).print("if (invalidEnumerationMessage_{s}.isNull()) {{\n", .{suffix});
            try indented(writer, indent + 4).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
            try indented(writer, indent).writeAll("} else {\n");
            try indented(writer, indent + 4).print("{s}::raise(*global, throwScope, invalidEnumerationMessage_{s});\n", .{ try cppConversionFailure(e, prefix), suffix });
            try indented(writer, indent).writeAll("}\n");
        },
        .value => |invalid_value| try emitCppValueInputError(e, writer, invalid_value.error_value, if (invalid_value.name) |name| cppPath(name) else path, value, indent),
        .node_coerced => |details| {
            if (details.text == .input) {
                try indented(writer, indent).print("WTF::String enumerationText_{s} = {s}.toWTFString(global);\n", .{ suffix, value });
                try emitCppConversionExceptionReturn(writer, failure, indent);
            }
            const message_indent = if (details.non_string_error != null) indent + 4 else indent;
            if (details.non_string_error) |expected| {
                try indented(writer, indent).print("if (!{s}.isString()) {{\n", .{value});
                try emitCppValueInputError(e, writer, expected, path, value, message_indent);
                try indented(writer, indent).writeAll("} else {\n");
            }
            try indented(writer, message_indent).print("Bun::throwError(global, throwScope, Bun::ErrorCode::{s}, WTF::makeString(", .{details.code});
            try emitCppUtf8String(writer, details.prefix);
            try writer.print(", enumerationText_{s}, ", .{suffix});
            try emitCppUtf8String(writer, details.suffix);
            try writer.writeAll("));\n");
            if (details.non_string_error != null) {
                try indented(writer, indent).writeAll("}\n");
            }
        },
    }
    try indented(writer, indent).print("return {s};\n", .{cppInputFailureReturn(failure)});
}

fn emitCppEnumerationTextComparison(writer: *Writer, ascii_case_insensitive: bool, suffix: []const u8, expected: []const u8) Error!void {
    if (ascii_case_insensitive) {
        try writer.print("WTF::equalIgnoringASCIICase(enumerationText_{s}, ", .{suffix});
        try emitCppUtf8String(writer, expected);
        try writer.writeByte(')');
    } else {
        try writer.print("enumerationText_{s} == ", .{suffix});
        try emitCppUtf8String(writer, expected);
    }
}

fn emitCppEnumerationToJS(e: *Emitter, writer: *Writer, id: ir.EnumerationId, source: []const u8, target: []const u8, indent: usize) Error!void {
    const enumeration = e.ir.get(id);
    try indented(writer, indent).print("switch (static_cast<{s}>({s})) {{\n", .{ switch (enumeration.tag) {
        .u8 => "uint8_t",
        .u16 => "uint16_t",
    }, source });
    for (enumeration.enumeration_values) |enumeration_value| {
        try indented(writer, indent).print("case {d}: {{\n", .{enumeration_value.native_value});
        try indented(writer, indent + 4).print("{s} = Bun::Bindgen::enumerationString(vm, {d});\n", .{ target, e.enumeration_string_indexes.get(enumeration_value.js_value).? });
        try indented(writer, indent + 4).writeAll("break;\n");
        try indented(writer, indent).writeAll("}\n");
    }
    try indented(writer, indent).writeAll("default:\n");
    try indented(writer, indent + 4).writeAll("RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding enumeration tag is invalid\");\n");
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppValueInputError(e: *Emitter, writer: *Writer, failure: ir.CppValueInputError, path: anytype, value: []const u8, indent: usize) Error!void {
    switch (failure) {
        .custom => |custom| {
            try indented(writer, indent).print("{s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, custom)});
        },
        .node_port => {
            try indented(writer, indent).writeAll("Bun::ERR::SOCKET_BAD_PORT(throwScope, global, JSC::jsString(vm, WTF::String(");
            try emitCppPath(e, writer, path);
            try writer.print(")), {s}, true);\n", .{value});
        },
        .node_property_value => |expected| {
            try indented(writer, indent).writeAll("Bun::ERR::INVALID_ARG_PROPERTY_VALUE(throwScope, global, ");
            try emitCppPath(e, writer, path);
            try writer.print(", {s}, ", .{value});
            try emitCppUtf8String(writer, expected);
            try writer.writeAll(");\n");
        },
        .node_type_or_instance => |expected| {
            try indented(writer, indent).writeAll("Bun::ERR::INVALID_ARG_TYPE_INSTANCE(throwScope, global, ");
            try emitCppPath(e, writer, path);
            try writer.writeAll(", ");
            try emitCppAsciiLiteral(writer, expected.expected_type);
            try writer.writeAll(", ");
            try emitCppAsciiLiteral(writer, expected.expected_instances);
            try writer.print(", {s});\n", .{value});
        },
        .node_string_property_type => {
            try indented(writer, indent).print("WTF::String bindingInputType = JSC::jsTypeStringForValue(global, {s})->value(global);\n", .{value});
            try indented(writer, indent).writeAll("Bun::throwError(global, throwScope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, WTF::makeString(\"The \\\"\"_s, ");
            try emitCppPath(e, writer, path);
            try writer.writeAll(", \"\\\" property must be of type string, got \"_s, bindingInputType));\n");
        },
        .webidl_integer_array => {
            try indented(writer, indent).writeAll("WebCore::propagateException(*global, throwScope, WebCore::Exception { WebCore::ExceptionCode::TypeMismatchError, ");
            try emitCppPath(e, writer, try cppPathPrepend(e, try cppPathAppend(e, path, " argument must be an integer-type TypedArray"), "The "));
            try writer.writeAll(" });\n");
        },
        .node_expected => |expected| {
            try indented(writer, indent).print("Bun::ERR::{s}(throwScope, global, ", .{switch (expected.kind) {
                .type, .multiple_types => "INVALID_ARG_TYPE",
                .instance => "INVALID_ARG_INSTANCE",
                .range => "OUT_OF_RANGE",
            }});
            try emitCppPath(e, writer, if (expected.source_suffix) |suffix| try cppPathAppend(e, path, suffix) else path);
            try writer.writeAll(", ");
            try emitCppAsciiLiteral(writer, expected.requirement);
            try writer.print(", {s}{s});\n", .{ value, if (expected.kind == .multiple_types) ", true" else "" });
        },
        .node_value => |invalid| {
            try indented(writer, indent).writeAll("Bun::ERR::INVALID_ARG_VALUE(throwScope, global, ");
            try emitCppPath(e, writer, if (invalid.source_suffix) |suffix| try cppPathAppend(e, path, suffix) else path);
            try writer.print(", {s}", .{value});
            if (invalid.reason) |reason| {
                try writer.writeAll(", ");
                try emitCppUtf8String(writer, reason);
            }
            try writer.writeAll(");\n");
        },
        .javascript => |invalid| {
            try indented(writer, indent).print("JSC::throw{s}Error(global, throwScope, ", .{switch (invalid.kind) {
                .type => "Type",
                .range => "Range",
            }});
            switch (invalid.message) {
                .literal => |message| try emitCppPath(e, writer, cppPath(message)),
                .suffix => |suffix| try emitCppPath(e, writer, try cppPathAppend(e, path, suffix)),
            }
            try writer.writeAll(");\n");
        },
        .invalid_this => |expected| {
            try indented(writer, indent).writeAll("{\n");
            try indented(writer, indent + 4).print("auto* invalidThisError = Bun::createInvalidThisError(global, {s}, ", .{value});
            try emitCppAsciiLiteral(writer, expected);
            try writer.writeAll(");\n");
            try indented(writer, indent + 4).writeAll("if (!throwScope.exception())\n");
            try indented(writer, indent + 8).writeAll("throwScope.throwException(global, invalidThisError);\n");
            try indented(writer, indent).writeAll("}\n");
        },
        .node_invalid_this => |expected| {
            try indented(writer, indent).writeAll("Bun::ERR::INVALID_THIS(throwScope, global, ");
            try emitCppAsciiLiteral(writer, expected);
            try writer.writeAll(");\n");
        },
    }
}

fn cppBoolean(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn bufferTypedArrayRequirement(source: ir.BufferSource) []const u8 {
    return switch (source) {
        .uint32_array => "1",
        .uint8_array => "2",
        .array_buffer_or_view, .view, .integer_typed_array => "0",
    };
}

// ─── strings and scalars ───

fn emitCppStringNullishRejection(e: *Emitter, writer: *Writer, conversion: ir.CppStringInput, value: []const u8, indent: usize) Error!void {
    const failure = cppInputFailureReturn(conversion.conversion.failure);
    const type_failure = conversion.nullish_failure orelse return;
    try indented(writer, indent).print("if ({s}.isUndefinedOrNull()) {{\n", .{value});
    try indented(writer, indent + 4).print("{s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, type_failure)});
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppStringEmptyRejection(writer: *Writer, conversion: ir.CppStringInput, value: []const u8, indent: usize) Error!void {
    const failure = cppInputFailureReturn(conversion.conversion.failure);
    const rejection = conversion.empty_rejection orelse return;
    try indented(writer, indent).print("if ({s}.isEmpty()) {{\n", .{value});
    try indented(writer, indent + 4).print("Bun::throwError(global, throwScope, Bun::ErrorCode::{s}, ", .{rejection.code});
    try emitCppAsciiLiteral(writer, rejection.message);
    try writer.writeAll(");\n");
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppNamedConversionContext(e: *Emitter, writer: *Writer, context: ir.ConversionContext, path: anytype, name: []const u8, indent: usize) Error!void {
    const names: struct { []const u8, []const u8 } = switch (context) {
        .none => return,
        .node_literal => .{ "LiteralConversionContext", "StringConversionContext" },
        .node_prose_literal => .{ "ProseLiteralConversionContext", "ProseStringConversionContext" },
        .node_predicate_literal => .{ "PredicateLiteralConversionContext", "PredicateStringConversionContext" },
        .exact_literal => .{ "ExactLiteralConversionContext", "ExactStringConversionContext" },
    };
    try indented(writer, indent).print("Bun::Bindgen::{s} {s} {{ ", .{ if (@TypeOf(path) == CppIndexedStringPath) names[1] else names[0], name });
    try emitCppPath(e, writer, path);
    try writer.writeAll(" };\n");
}

fn emitCppScalarConversionTo(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    conversion: ir.CppScalarConversion,
    value: []const u8,
    target: []const u8,
    path: CppPath,
    context_name: []const u8,
    indent: usize,
) Error!void {
    const failure = conversion.failure;
    try emitCppNamedConversionContext(e, writer, conversion.context, path, context_name, indent);
    try indented(writer, indent).print("{s} = ", .{target});
    try emitCppScalarValue(e, writer, converter_context, conversion, value, context_name);
    try writer.writeAll(";\n");
    try emitCppConversionExceptionReturn(writer, failure, indent);
}

fn emitCppIdlConversionTo(
    e: *Emitter,
    writer: *Writer,
    conversion: ir.CppIdlInput,
    value: []const u8,
    target: []const u8,
    path: anytype,
    context_name: []const u8,
    indent: usize,
) Error!void {
    const failure = conversion.failure;
    try emitCppNamedConversionContext(e, writer, conversion.context, path, context_name, indent);
    try indented(writer, indent).print("{s} = ", .{target});
    try emitCppIdlValue(e, writer, conversion, value, context_name);
    try writer.writeAll(";\n");
    try emitCppConversionExceptionReturn(writer, failure, indent);
}

fn emitCppIdlValue(e: *Emitter, writer: *Writer, conversion: ir.CppIdlInput, value: []const u8, context_name: []const u8) Error!void {
    if (conversion.context != .none) {
        try writer.print("Bun::convertIDL<{s}>(*global, {s}, {s})", .{ try e.cppType(conversion.type), value, context_name });
    } else {
        try writer.print("WebCore::convert<{s}>(*global, {s})", .{ try e.cppType(conversion.type), value });
    }
}

fn emitCppStringConversionTo(
    e: *Emitter,
    writer: *Writer,
    conversion: ir.CppStringInput,
    value: []const u8,
    target: []const u8,
    path: anytype,
    context_name: []const u8,
    indent: usize,
) Error!void {
    try emitCppStringNullishRejection(e, writer, conversion, value, indent);
    try emitCppStringInputRejection(e, writer, conversion, value, path, indent);
    try emitCppIdlConversionTo(e, writer, conversion.conversion, value, target, path, context_name, indent);
    try emitCppStringEmptyRejection(writer, conversion, target, indent);
}

fn emitCppStringInputRejection(e: *Emitter, writer: *Writer, conversion: ir.CppStringInput, value: []const u8, path: anytype, indent: usize) Error!void {
    const failure = cppInputFailureReturn(conversion.conversion.failure);
    if (conversion.strict_failure) |type_failure| {
        try indented(writer, indent).print("if (!{s}.isString()) {{\n", .{value});
        try indented(writer, indent + 4).print("{s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, type_failure)});
        try indented(writer, indent + 4).print("return {s};\n", .{failure});
        try indented(writer, indent).writeAll("}\n");
    }
    const error_value = switch (conversion.input) {
        .any => return,
        .object => |invalid| object: {
            try indented(writer, indent).print("if (!{s}.isObject()) {{\n", .{value});
            break :object invalid;
        },
        .string_or_boxed => |invalid| boxed: {
            try indented(writer, indent).print("if (!{0s}.isString() && !Bun::Bindgen::TypePredicates::isStringObject({0s})) {{\n", .{value});
            break :boxed invalid;
        },
    };
    try emitCppValueInputError(e, writer, error_value, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppBufferCheckStart(writer: *Writer, check: ir.CppBufferCheck, storage: []const u8, value: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if (!{s}.initialize({s}, {s}, {s}, {s}, {s}, {s})) {{\n", .{
        storage,
        value,
        cppBoolean(check.allow_detached),
        cppBoolean(check.source == .array_buffer_or_view),
        cppBoolean(check.source.isIntegerTypedArray()),
        bufferTypedArrayRequirement(check.source),
        cppBoolean(check.allow_shared),
    });
}

fn emitCppBufferConversionError(e: *Emitter, writer: *Writer, check: ir.CppBufferCheck, path: CppPath, value: []const u8, indent: usize) Error!void {
    const failure = check.detached_failure orelse return emitCppValueInputError(e, writer, check.invalid, path, value, indent);
    try indented(writer, indent).print("if (BindingBufferSource::isDetachedOrOutOfBoundsSource({s}, {s}, {s}, {s})) {{\n", .{
        value,
        cppBoolean(check.source == .array_buffer_or_view),
        cppBoolean(check.source.isIntegerTypedArray()),
        bufferTypedArrayRequirement(check.source),
    });
    try indented(writer, indent + 4).print("{s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, failure)});
    try indented(writer, indent).writeAll("} else {\n");
    try emitCppValueInputError(e, writer, check.invalid, path, value, indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppLazyInput(e: *Emitter, writer: *Writer, context: CppConversionBindings, id: ir.CppInputId, index: usize, operand: CppInputValue, target: []const u8, indent: usize) Error!void {
    const value = operand.value;
    try indented(writer, indent).print("RELEASE_ASSERT(!{s}.isEmpty());\n", .{value});
    try indented(writer, indent).print("lazyStorage.argument_{d}.emplace(*global, {s}, {s}, {s}, 0{s});\n", .{
        index,
        value,
        if (operand.prepared) |prepared| try e.print("&{s}", .{prepared}) else "nullptr",
        context.deferred,
        if (e.ir.get(id).call_receiver) ", lazyStorage.receiver.get()" else "",
    });
    try indented(writer, indent).print("{s} = Bun::Bindgen::Detail::CppArgumentAccess::lazyHandle(lazyStorage.argument_{d}->view());\n", .{ target, index });
}

// ─── call inputs ───

fn cppInboundInputValue(e: *Emitter, input: *const ir.CppInboundArgument, value: []const u8) Allocator.Error!CppInputValue {
    return .{ .value = value, .prepared = if (input.prepared_input) |prepared| try e.print("bindingOverloadInputs[{d}]", .{prepared}) else null };
}

fn emitCppInboundArgument(e: *Emitter, writer: *Writer, call: *const ir.CppInboundCall(.inbound_argument), input: *const ir.CppInboundArgument) Error!void {
    const index = input.index;
    const converter_context = cppInboundConversionBindings(e, call);
    switch (input.conversion) {
        .selected => |selection| try emitCppSelectedArgument(e, writer, call, input, selection),
        .prepare => |preparation| {
            const value = try e.print("bindingPreparedValue_{d}", .{preparation.source_index});
            try writer.print("    JSC::JSValue {s} = {s};\n", .{ value, try cppArgumentRead(e, preparation.read) });
            try emitCppPreparedValue(e, writer, preparation.value, value, cppPath(preparation.path), 4);
            try writer.print("    JSC::EnsureStillAliveScope bindingPreparedInput_{d} = {s};\n", .{ preparation.source_index, value });
        },
        .rest => |rest| try emitCppRestArgument(e, writer, converter_context, rest, index),
        .value => |value| {
            try writer.print("    JSC::EnsureStillAliveScope input_{d} = {s};\n", .{ index, try cppArgumentRead(e, value.read) });
            try emitCppArgumentValue(e, writer, converter_context, value, input);
        },
        .lazy => |deferred| {
            const lazy = deferred.input;
            try writer.print("    JSC::EnsureStillAliveScope input_{d} = {s};\n", .{ index, try cppArgumentRead(e, deferred.read) });
            switch (deferred.target) {
                .cpp => try emitCppBackendLazyArgument(e, writer, converter_context, deferred, input),
                .wire => |field| {
                    if (deferred.missing) |missing| {
                        try writer.print("    if (!{s}) {{\n", .{try cppArgumentMissing(e, missing, index)});
                        try writer.print("        args.{s}_present = 1;\n", .{field});
                    }
                    try emitCppLazyInput(e, writer, converter_context, lazy.value, index, try cppInboundInputValue(e, input, try e.print("input_{d}.value()", .{index})), try e.print("args.{s}", .{field}), if (deferred.missing != null) 8 else 4);
                    if (deferred.missing != null) try writer.writeAll("    }\n");
                },
            }
        },
    }
}

fn emitCppRequiredArgumentCheck(e: *Emitter, writer: *Writer, check: ir.CppRequiredArgumentCheck) Error!void {
    try writer.print("    if (callFrame->argumentCount() < {d}) {{\n", .{check.minimum});
    switch (check.failure) {
        .custom => |failure| try writer.print("        {s}::raise(*global, throwScope);\n        {s}\n", .{ try cppConversionFailure(e, failure.value), cppReturn(failure.return_value) }),
        .arity => try writer.writeAll("        return JSC::throwVMError(global, throwScope, createNotEnoughArgumentsError(global));\n"),
    }
    try writer.writeAll("    }\n");
}

fn cppArgumentSuffix(e: *Emitter, index: usize) Allocator.Error![]const u8 {
    return e.print("argument_{d}", .{index});
}

/// Converts one eager argument into storage owned by the entry frame and
/// assigns the implementation's view of it. Lease registration and detach
/// validation find that storage under the same suffix.
fn emitCppArgumentValue(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    conversion: ir.CppArgumentValue,
    site: *const ir.CppInboundArgument,
) Error!void {
    const index = site.index;
    const id = conversion.input;
    const value_input = e.ir.get(id);
    const path = cppPath(conversion.path);
    const suffix = try cppArgumentSuffix(e, index);
    const value = try cppInboundInputValue(e, site, try e.print("input_{d}.value()", .{index}));
    const target = switch (conversion.target) {
        .cpp => |field| try e.print("cppArgs.{s}", .{field}),
        .wire => try e.print("bindingArgument_{d}", .{index}),
    };
    switch (conversion.target) {
        .wire => |wire| try writer.print("    {s} {s} {{}};\n", .{ try e.cppType(wire.local_type), target }),
        .cpp => {},
    }
    try emitCppConverterValueStorage(e, writer, id, suffix, 4);
    switch (conversion.presence) {
        .required => try emitCppInputPlanValue(e, writer, converter_context, id, value, target, path, suffix, 4),
        .optional => |missing| {
            try writer.print("    if (!{s}) {{\n", .{try cppArgumentMissing(e, missing, index)});
            const present = try e.print("bindingPresentArgument_{d}", .{index});
            try writer.print("        {s} {s} {{}};\n", .{ try e.cppType(value_input.value_type), present });
            try emitCppInputPlanValue(e, writer, converter_context, id, value, present, path, suffix, 8);
            try writer.print("        {s}.emplace(WTF::move({s}));\n", .{ target, present });
            try writer.writeAll("    }\n");
        },
        .default_value => |default| {
            try writer.print("    if (!{s}) {{\n", .{try cppArgumentMissing(e, default.missing, index)});
            try emitCppInputPlanValue(e, writer, converter_context, id, value, target, path, suffix, 8);
            try writer.writeAll("    } else {\n");
            try emitCppBackendDefault(e, writer, default.value, target, 8);
            try writer.writeAll("    }\n");
        },
    }
    switch (conversion.target) {
        .cpp => {},
        .wire => |wire| {
            const wire_target = try e.print("args.{s}", .{wire.field});
            const optional = conversion.presence == .optional;
            if (optional) try emitCppOptionalProjectionStart(writer, target, try e.print("{s}_present", .{wire_target}), 4);
            try emitCppInputEncode(e, writer, value_input.encoder, if (optional) try e.print("{s}.value()", .{target}) else target, wire_target, .{ .suffix = suffix }, if (optional) 8 else 4);
            if (optional) try writer.writeAll("    }\n");
        },
    }
}

// ─── owned nominal handles ───

fn emitCppEngineWireOwnedNominalHandleReleasePlan(e: *Emitter, writer: *Writer, id: ir.OutboundArgumentPlanId, expression: []const u8, indent: usize) Error!void {
    try emitCppWireRelease(e, writer, id, expression, indent, .owned_handles);
}

fn emitCppOwnedNominalHandleReleasePlan(e: *Emitter, writer: *Writer, id: anytype, expression: []const u8, indent: usize) Error!void {
    if (!e.ir.get(id).cpp.release.owned_handles) return;
    // Nested rollback guards may refer to the same logical value.
    try emitCppOwnedNominalHandleReleaseBody(e, writer, id, expression, indent);
    try indented(writer, indent).print("{s} = {{}};\n", .{expression});
}

fn emitCppOwnedNominalHandleReleaseBody(e: *Emitter, writer: *Writer, id: anytype, expression: []const u8, indent: usize) Error!void {
    const position = e.ir.get(id);
    if (!position.cpp.release.owned_handles) return;
    switch (position.representation) {
        .leaf => |leaf| try emitCppNativeHandleRelease(e, writer, leaf.nominal_owned, expression, indent),
        .converted => |conversion| try emitCppOwnedNominalHandleReleaseBody(e, writer, conversion.apiValue(), expression, indent),
        .optional => |child| try emitCppNativeHandleOptional(e, writer, child, expression, indent),
        inline .sequence, .record, .rest => |child| try emitCppNativeHandleCollection(e, writer, child, expression, indent),
        .record_entry => |entry| try emitCppNativeHandleEntry(e, writer, entry, expression, indent),
        .dictionary => |fields| try emitCppNativeHandleFields(e, writer, fields, expression, indent),
        .union_type => |members| try emitCppNativeHandleMembers(e, writer, members, expression, indent),
    }
}

fn emitCppNativeHandleRelease(e: *Emitter, writer: *Writer, owner: ir.NominalOwnershipId, expression: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if ({s})\n", .{expression});
    try indented(writer, indent + 4).print("Bun::Bindgen::Engine::{s}({s});\n", .{ e.ir.get(owner).cpp_release, expression });
}

fn emitCppNativeHandleOptional(e: *Emitter, writer: *Writer, child: anytype, expression: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if ({s}.has_value()) {{\n", .{expression});
    try emitCppOwnedNominalHandleReleaseBody(e, writer, child, try e.print("{s}.value()", .{expression}), indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppNativeHandleCollection(e: *Emitter, writer: *Writer, child: anytype, expression: []const u8, indent: usize) Error!void {
    const index = try e.print("ownedIndex_{d}_{d}", .{ child.index, indent });
    try indented(writer, indent).print("for (size_t {0s} = 0; {0s} < {1s}.size(); ++{0s}) {{\n", .{ index, expression });
    try emitCppOwnedNominalHandleReleaseBody(e, writer, child, try e.print("Bun::Bindgen::Detail::CppNativeResultAccess::element({s}, {s})", .{ expression, index }), indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppNativeHandleEntry(e: *Emitter, writer: *Writer, entry: anytype, expression: []const u8, indent: usize) Error!void {
    try emitCppOwnedNominalHandleReleaseBody(e, writer, entry.key, try e.print("{s}.first", .{expression}), indent);
    try emitCppOwnedNominalHandleReleaseBody(e, writer, entry.value, try e.print("{s}.second", .{expression}), indent);
}

fn emitCppNativeHandleFields(e: *Emitter, writer: *Writer, fields: anytype, expression: []const u8, indent: usize) Error!void {
    for (fields) |field| {
        if (!e.ir.get(field.value).cpp.release.owned_handles) continue;
        const value = try e.print("{s}.{s}", .{ expression, field.name });
        if (field.optional) {
            try indented(writer, indent).print("if ({s}.has_value()) {{\n", .{value});
            try emitCppOwnedNominalHandleReleaseBody(e, writer, field.value, try e.print("{s}.value()", .{value}), indent + 4);
            try indented(writer, indent).writeAll("}\n");
        } else try emitCppOwnedNominalHandleReleaseBody(e, writer, field.value, value, indent);
    }
}

fn emitCppNativeHandleMembers(e: *Emitter, writer: *Writer, members: anytype, expression: []const u8, indent: usize) Error!void {
    for (members) |member| {
        if (!e.ir.get(member.value).cpp.release.owned_handles) continue;
        try indented(writer, indent).print("if ({s}.is_{s}()) {{\n", .{ expression, member.name });
        try emitCppOwnedNominalHandleReleaseBody(e, writer, member.value, try e.print("{s}.{s}()", .{ expression, member.name }), indent + 4);
        try indented(writer, indent).writeAll("}\n");
    }
}

// ─── input storage ───

fn emitCppUnionConversion(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    aggregate: *const ir.CppInputAggregate,
    input: ir.CppUnionInput,
    operand: CppInputValue,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const value = operand.value;
    const matching = switch (input.operation) {
        .matching => |program| program,
        .tagged => |tagged| return emitCppTaggedUnionInput(e, writer, converter_context, aggregate, input.members, tagged, value, target, path, suffix, indent),
    };
    const failure = cppInputFailureReturn(aggregate.failure);
    try indented(writer, indent).print("bool unionMatched_{s} = false;\n", .{suffix});
    const selection = operand.selected_member;
    for (input.members, matching.tests) |member, test_| {
        try indented(writer, indent).print("if (!unionMatched_{s}) {{\n", .{suffix});
        try indented(writer, indent + 4).writeAll("bool matches = ");
        if (selection) |selected| try writer.print("{0s} ? ({0s} == {1d}) : (", .{ selected, member.tag });
        try emitCppInputSelectionExpression(e, writer, test_, value, operand.source());
        if (selection != null) try writer.writeByte(')');
        try writer.writeAll(";\n");
        try emitCppConversionExceptionReturn(writer, aggregate.failure, indent + 4);
        try indented(writer, indent + 4).writeAll("if (matches) {\n");
        const member_suffix = try e.print("{s}_{s}", .{ suffix, member.name });
        const member_value = try e.print("bindingUnionValue_{s}", .{member_suffix});
        try indented(writer, indent + 8).print("{s} {s} {{}};\n", .{ try e.cppType(e.ir.get(member.value).value_type), member_value });
        try emitCppInputPlanValue(e, writer, converter_context, member.value, .{ .value = value, .prepared = operand.prepared }, member_value, path, member_suffix, indent + 8);
        try indented(writer, indent + 8).print("{s}.set_{s}(WTF::move({s}));\n", .{ target, member.name, member_value });
        try indented(writer, indent + 8).print("bindingSelectedMember_{s} = {d};\n", .{ suffix, member.tag });
        try indented(writer, indent + 8).print("unionMatched_{s} = true;\n", .{suffix});
        try indented(writer, indent + 4).writeAll("}\n");
        try indented(writer, indent).writeAll("}\n");
    }
    try indented(writer, indent).print("if (!unionMatched_{s}) {{\n", .{suffix});
    try emitCppValueInputError(e, writer, matching.error_value, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppTaggedUnionInput(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    aggregate: *const ir.CppInputAggregate,
    members: []const ir.CppInputUnionMember,
    tag: ir.CppTaggedUnionInput,
    value: []const u8,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const failure = cppInputFailureReturn(aggregate.failure);
    const object = try e.print("bindingTaggedObject_{s}", .{suffix});
    const tag_value = try e.print("bindingTagValue_{s}", .{suffix});
    const tag_string = try e.print("enumerationText_{s}", .{suffix});
    const tag_path = try cppPathAppend(e, path, try e.print(".{s}", .{tag.property}));
    try indented(writer, indent).print("auto* {s} = {s}.getObject();\n", .{ object, value });
    try indented(writer, indent).print("JSC::JSValue {s};\n", .{tag_value});
    try indented(writer, indent).print("if ({s}) {{\n", .{object});
    try indented(writer, indent + 4).print("{s} = {s}->get(global, ", .{ tag_value, object });
    try emitCppInternedPropertyKey(e, writer, tag.property, "vm");
    try writer.writeAll(");\n");
    try emitCppConversionExceptionReturn(writer, aggregate.failure, indent + 4);
    switch (tag.tag_read) {
        .coerced => |required| {
            try indented(writer, indent + 4).print("if ({s}.isUndefined()) {{\n", .{tag_value});
            try emitCppValueInputError(e, writer, required, tag_path, tag_value, indent + 8);
            try indented(writer, indent + 8).print("return {s};\n", .{failure});
            try indented(writer, indent + 4).writeAll("}\n");
        },
        .strict => {},
    }
    try indented(writer, indent).writeAll("} else {\n");
    switch (tag.object) {
        .shorthand => {
            try indented(writer, indent + 4).print("{s} = {s};\n", .{ tag_value, value });
        },
        .required => |required| {
            try emitCppValueInputError(e, writer, required, path, value, indent + 4);
            try indented(writer, indent + 4).print("return {s};\n", .{failure});
        },
    }
    try indented(writer, indent).writeAll("}\n");
    switch (tag.tag_read) {
        .coerced => {},
        .strict => |invalid_type| {
            try indented(writer, indent).print("if (!{s}.isString()) {{\n", .{tag_value});
            try emitCppValueInputError(e, writer, invalid_type, tag_path, tag_value, indent + 4);
            try indented(writer, indent + 4).print("return {s};\n", .{failure});
            try indented(writer, indent).writeAll("}\n");
        },
    }
    try indented(writer, indent).print("WTF::String {s} = {s}.toWTFString(global);\n", .{ tag_string, tag_value });
    try emitCppConversionExceptionReturn(writer, aggregate.failure, indent);
    for (tag.cases, 0..) |case, case_index| {
        const member = members[case.member];
        try indented(writer, indent).print("{s}if (", .{if (case_index == 0) "" else "else "});
        try emitCppEnumerationTextComparison(writer, tag.case_insensitive, suffix, case.value);
        for (case.aliases) |alias| {
            try writer.writeAll(" || ");
            try emitCppEnumerationTextComparison(writer, tag.case_insensitive, suffix, alias);
        }
        try writer.writeAll(") {\n");
        const member_suffix = try e.print("{s}_{s}", .{ suffix, member.name });
        const payload = try e.print("bindingUnionPayload_{s}", .{member_suffix});
        const member_value = try e.print("bindingUnionValue_{s}", .{member_suffix});
        try indented(writer, indent + 4).print("{s} {s} {{}};\n", .{ try e.cppType(e.ir.get(member.value).value_type), member_value });
        switch (case.shorthand) {
            .none => {},
            .field => |field| {
                try indented(writer, indent + 4).print("if (!{s}) {{ {s}.{s} = {s}; }} else {{\n", .{ object, member_value, e.ir.get(field).name, tag_string });
            },
            .object => {
                try indented(writer, indent + 4).print("if (!{s}) {{\n", .{object});
                try indented(writer, indent + 8).print("{s} = JSC::constructEmptyObject(vm, global->nullPrototypeObjectStructure());\n", .{object});
                try emitCppConversionExceptionReturn(writer, aggregate.failure, indent + 8);
                try indented(writer, indent + 8).print("{s}->putDirect(vm, ", .{object});
                try emitCppInternedPropertyKey(e, writer, tag.property, "vm");
                try writer.print(", JSC::jsString(vm, {s}));\n", .{tag_string});
                try emitCppConversionExceptionReturn(writer, aggregate.failure, indent + 8);
                try indented(writer, indent + 4).writeAll("}\n");
            },
        }
        try writer.splatByteAll(' ', indent + 4);
        const member_path = switch (tag.payload) {
            .property => |property| selected_path: {
                try writer.print("JSC::JSValue {s} = {s}->get(global, ", .{ payload, object });
                try emitCppInternedPropertyKey(e, writer, property, "vm");
                try writer.writeAll(");\n");
                try emitCppConversionExceptionReturn(writer, aggregate.failure, indent + 4);
                break :selected_path try cppPathAppend(e, path, try e.print(".{s}", .{property}));
            },
            .object => selected_path: {
                try writer.print("JSC::JSValue {s} = {s};\n", .{ payload, object });
                break :selected_path path;
            },
        };
        try emitCppInputPlanValue(e, writer, converter_context, member.value, .{ .value = payload }, member_value, member_path, member_suffix, indent + 4);
        if (case.shorthand == .field) {
            try indented(writer, indent + 4).writeAll("}\n");
        }
        try indented(writer, indent + 4).print("{s}.set_{s}(WTF::move({s}));\n", .{ target, member.name, member_value });
        try indented(writer, indent + 4).print("bindingSelectedMember_{s} = {d};\n", .{ suffix, member.tag });
        try indented(writer, indent).writeAll("}\n");
    }
    try indented(writer, indent).writeAll(if (tag.cases.len == 0) "{\n" else "else {\n");
    switch (tag.unmatched) {
        .failure => {},
        .raise => |invalid| try emitCppValueInputError(e, writer, invalid, path, tag_value, indent + 4),
    }
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppTaggedUnionFallback(
    e: *Emitter,
    writer: *Writer,
    context: CppConversionBindings,
    member: ir.CppInputUnionMember,
    value: CppInputValue,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    try indented(writer, indent).print("{s} fallbackValue {{}};\n", .{try e.cppType(e.ir.get(member.value).value_type)});
    try emitCppInputPlanValue(e, writer, context, member.value, value, "fallbackValue", path, try e.print("{s}_{s}", .{ suffix, member.name }), indent);
    try indented(writer, indent).print("{s}.set_{s}(WTF::move(fallbackValue));\n", .{ target, member.name });
    try indented(writer, indent).print("bindingSelectedMember_{s} = {d};\n", .{ suffix, member.tag });
}

// ─── brands ───

fn emitCppBrandContract(e: *Emitter, writer: *Writer, id: ir.CppBrandMatchId) Error!void {
    switch (e.ir.get(id).*) {
        .realm => |matcher| try writer.print("static_assert(std::is_same_v<decltype(&{s}), bool (*)(JSC::JSGlobalObject&, JSC::JSValue) noexcept>);\n", .{matcher.symbol}),
        .value => |matcher| try writer.print("static_assert(std::is_same_v<decltype(&{s}), bool (*)(JSC::JSValue) noexcept>);\n", .{matcher.symbol}),
        .dynamic_cast => |matcher| try writer.print("static_assert(std::is_base_of_v<JSC::JSCell, {s}>);\n", .{matcher.type_name}),
        .class_instance => {},
    }
}

fn emitCppBrandMatchExpression(e: *Emitter, writer: *Writer, id: ir.CppBrandMatchId, value: []const u8) Error!void {
    switch (e.ir.get(id).*) {
        .class_instance => |reference| {
            const class = e.class(reference.class);
            if (reference.match == .initial_structure) {
                try writer.print("([&] {{ auto* object = dynamicDowncast<Bun::{0s}>({1s}); if (!object || !object->native()) return false; auto* realm = dynamicDowncast<Zig::GlobalObject>(object->globalObject()); return realm && object->structure() == realm->{0s}Structure(); }})()", .{ class.cpp_class_name, value });
            } else {
                try emitCppClassBrandMatchExpression(e, writer, class, value);
            }
        },
        .realm => |matcher| try writer.print("{s}(*global, {s})", .{ matcher.symbol, value }),
        .value => |matcher| try writer.print("{s}({s})", .{ matcher.symbol, value }),
        .dynamic_cast => |matcher| try writer.print("!!dynamicDowncast<{s}>({s})", .{ matcher.type_name, value }),
    }
}

fn emitCppBrandAssertion(e: *Emitter, writer: *Writer, id: ir.CppBrandMatchId, value: []const u8, indent: usize) Error!void {
    try indented(writer, indent).writeAll("RELEASE_ASSERT_WITH_MESSAGE(");
    try emitCppBrandMatchExpression(e, writer, id, value);
    try writer.writeAll(", \"binding value has the wrong brand\");\n");
}

fn emitCppClassBrandAssertion(e: *Emitter, writer: *Writer, class: *const ir.Class, value: []const u8, indent: usize) Error!void {
    try indented(writer, indent).writeAll("RELEASE_ASSERT_WITH_MESSAGE(");
    try emitCppClassBrandMatchExpression(e, writer, class, value);
    try writer.writeAll(", \"binding value has the wrong class\");\n");
}

fn emitCppClassBrandMatchExpression(e: *Emitter, writer: *Writer, class: *const ir.Class, value: []const u8) Error!void {
    if (class.brand) |brand| {
        try emitCppBrandMatchExpression(e, writer, brand.cpp_match, value);
    } else if (class.representation != .native) {
        try writer.print("dynamicDowncast<Bun::{s}>({s})", .{ class.cpp_class_name, value });
    } else {
        try writer.print("([&] {{ auto* object = dynamicDowncast<Bun::{s}>({s}); return object && object->native(); }})()", .{ class.cpp_class_name, value });
    }
}

fn emitCppValueTest(e: *Emitter, writer: *Writer, test_: ir.CppValueTest, value: []const u8, source: []const u8) Error!void {
    switch (test_) {
        .always => try writer.writeAll("true"),
        .null_value => try writer.print("{s}.isNull()", .{value}),
        .undefined_value => try writer.print("{s}.isUndefined()", .{value}),
        .nullish => try writer.print("{s}.isUndefinedOrNull()", .{value}),
        .boolean => try writer.print("{s}.isBoolean()", .{value}),
        .number => try writer.print("{s}.isNumber()", .{value}),
        .big_int => try writer.print("{s}.isBigInt()", .{value}),
        .int32 => try writer.print("{s}.isInt32AsAnyInt()", .{value}),
        .uint32 => try writer.print("{s}.isUInt32()", .{value}),
        .string => try writer.print("{s}.isString()", .{value}),
        .object => try writer.print("{s}.isObject()", .{value}),
        .truthy => try writer.print("{s}.toBoolean(global)", .{value}),
        .string_object => try writer.print("Bun::Bindgen::TypePredicates::isStringObject({s})", .{value}),
        .url => try writer.print("Bun::Bindgen::TypePredicates::isDOMURL({s})", .{value}),
        .callback => try writer.print("JSC::getCallData({s}).type != JSC::CallData::Type::None", .{value}),
        .array => try writer.print("JSC::isArray(global, {s})", .{value}),
        .iterable => try writer.print("{s}.selectIterable(global)", .{source}),
        .uint8_array, .uint32_array => try writer.print("({0s}.isCell() && {0s}.asCell()->type() == JSC::JSType::{1s})", .{ value, if (test_ == .uint8_array) "Uint8ArrayType" else "Uint32ArrayType" }),
        .uint8_view => try writer.print("dynamicDowncast<JSC::JSUint8Array>({s})", .{value}),
        .integer_array => try writer.print("BindingBufferSource::isIntegerTypedArray({s})", .{value}),
        .buffer_view => try writer.print("dynamicDowncast<JSC::JSArrayBufferView>({s})", .{value}),
        .array_buffer => try writer.print("dynamicDowncast<JSC::JSArrayBuffer>({s})", .{value}),
        .number_literal => |number| if (std.math.isNan(number)) {
            try writer.print("({0s}.isNumber() && std::isnan({0s}.asNumber()))", .{value});
        } else {
            try writer.print("({0s}.isNumber() && {0s}.asNumber() == std::bit_cast<double>(uint64_t {{ 0x{1x:0>16}ULL }}))", .{ value, @as(u64, @bitCast(number)) });
        },
        .integer => |matching| try emitCppMatchingIntegerExpression(e, writer, matching, value),
        .brand => |brand| try emitCppBrandMatchExpression(e, writer, brand, value),
        .class => |class| try emitCppClassBrandMatchExpression(e, writer, e.class(class), value),
        .external => |symbol| try writer.print("{s}(*global, {s})", .{ symbol, value }),
        .negate => |child| {
            try writer.writeAll("!(");
            try emitCppValueTest(e, writer, e.ir.get(child).*, value, source);
            try writer.writeByte(')');
        },
        .any_of, .all_of => |children| {
            try writer.writeByte('(');
            for (children, 0..) |child, index| {
                if (index != 0) try writer.writeAll(if (test_ == .any_of) " || " else " && ");
                try writer.writeAll("(!throwScope.exception() && (");
                try emitCppValueTest(e, writer, e.ir.get(child).*, value, source);
                try writer.writeAll("))");
            }
            try writer.writeByte(')');
        },
    }
}

fn emitCppInputSelectionExpression(e: *Emitter, writer: *Writer, test_: ir.CppValueTest, value: []const u8, source: []const u8) Error!void {
    try writer.writeAll("(!throwScope.exception() && (");
    try emitCppValueTest(e, writer, test_, value, source);
    try writer.writeAll("))");
}

// ─── sequences ───

fn emitCppBackendSequenceNativeElementDeclaration(e: *Emitter, writer: *Writer, element: ir.CppInputId, suffix: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("{s} bindingNativeSequenceElement_{s} {{}};\n", .{ try e.cppType(e.ir.get(element).value_type), suffix });
}

fn emitCppBackendSequenceNativeElementValue(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    element: ir.CppInputId,
    value: CppInputValue,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    try emitCppInputPlanValue(e, writer, converter_context, element, value, try e.print("bindingNativeSequenceElement_{s}", .{suffix}), path, try e.print("{s}_element", .{suffix}), indent);
}

fn emitCppSequenceElementRead(writer: *Writer, read: ir.CppSequenceRead, suffix: []const u8, indent: usize) Error!void {
    const direct_index = read.method == .direct_index;
    try indented(writer, indent).print("JSC::JSValue sequenceValue_{0s} = sequenceObject_{0s}->{1s}(global, sequenceIndex_{0s});\n", .{ suffix, if (direct_index) "getDirectIndex" else "get" });
    try emitCppConversionExceptionReturn(writer, read.failure, indent);
    if (direct_index) {
        try indented(writer, indent).print("if (sequenceValue_{0s}.isEmpty()) sequenceValue_{0s} = JSC::jsUndefined();\n", .{suffix});
    }
}

fn emitCppSequenceConversion(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    aggregate: *const ir.CppInputAggregate,
    conversion: ir.CppSequenceInput,
    operand: CppInputValue,
    path: CppPath,
    suffix: []const u8,
    native_sequence: []const u8,
    indent: usize,
) Error!void {
    const value = operand.value;
    const failure_policy = aggregate.failure;
    const element_id = conversion.value;
    const indexed = switch (conversion.operation) {
        .indexed => |program| program,
        .iterable => |iterable| return emitCppIterableSequenceConversion(e, writer, converter_context, aggregate, conversion, iterable, operand, path, suffix, native_sequence, indent),
    };
    const failure = cppInputFailureReturn(failure_policy);
    const element_input = e.ir.get(element_id);
    const centralized_element = element_input.collection_storage;
    const pattern = indexed.pattern;
    const length = try e.print("sequenceLength_{s}", .{suffix});
    try indented(writer, indent).print("bool sequenceIsArray_{s} = ", .{suffix});
    try emitCppInputSelectionExpression(e, writer, indexed.selection, value, operand.source());
    try writer.writeAll(";\n");
    try indented(writer, indent).writeAll("if (materializeBindingException(throwScope))\n");
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).print("if (!sequenceIsArray_{s}) {{\n", .{suffix});
    try emitCppValueInputError(e, writer, indexed.object_error, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("auto* sequenceObject_{s} = {s}.getObject();\n", .{ suffix, value });
    try indented(writer, indent).print("JSC::JSValue sequenceLengthValue_{0s} = sequenceObject_{0s}->get(global, vm.propertyNames->length);\n", .{suffix});
    try indented(writer, indent).writeAll("if (materializeBindingException(throwScope))\n");
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).print("size_t sequenceLength_{0s} = sequenceLengthValue_{0s}.toLength(global);\n", .{suffix});
    try indented(writer, indent).writeAll("if (materializeBindingException(throwScope))\n");
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    if (indexed.length_limit) |limit| {
        try indented(writer, indent).print("if (sequenceLength_{s} > {d}) {{\n", .{ suffix, limit.max });
        try indented(writer, indent + 4).print("{s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, limit.failure)});
        try indented(writer, indent + 4).print("return {s};\n", .{failure});
        try indented(writer, indent).writeAll("}\n");
    }
    try indented(writer, indent).print("if (sequenceLength_{s} > std::numeric_limits<uint32_t>::max()) {{\n", .{suffix});
    try emitCppValueInputError(e, writer, conversion.too_long, path, try e.print("sequenceLengthValue_{s}", .{suffix}), indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
    if (pattern) |sequence_pattern| {
        try indented(writer, indent).print("static constexpr uint16_t sequencePattern_{s}[] = {{", .{suffix});
        for (sequence_pattern.member_tags, 0..) |tag, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("{d}", .{tag});
        }
        try writer.writeAll("};\n");
        try indented(writer, indent).print("if (sequenceLength_{s} % {d}) {{\n", .{ suffix, sequence_pattern.member_tags.len });
        try indented(writer, indent + 4).print("{s}::raise(*global, throwScope);\n", .{try cppConversionFailure(e, sequence_pattern.incomplete_error)});
        try indented(writer, indent + 4).print("return {s};\n", .{failure});
        try indented(writer, indent).writeAll("}\n");
    }
    switch (indexed.read) {
        .interleaved, .snapshot, .lazy => {},
        .grouped => |group| {
            for ([_]struct { []const u8, []const u16 }{ .{ "Sizes", group.sizes }, .{ "Offsets", group.offsets } }) |entry| {
                try indented(writer, indent).print("static constexpr uint16_t sequenceReadGroup{s}_{s}[] = {{", .{ entry[0], suffix });
                for (entry[1], 0..) |number, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{number});
                }
                try writer.writeAll("};\n");
            }
            try indented(writer, indent).print("JSC::MarkedArgumentBuffer sequenceReadGroup_{s};\n", .{suffix});
            try indented(writer, indent).print("sequenceReadGroup_{s}.ensureCapacity({d});\n", .{ suffix, group.sizes.len });
            try indented(writer, indent).print("if (sequenceReadGroup_{s}.hasOverflowed()) {{\n", .{suffix});
            try emitCppOutOfMemoryReturn(writer, failure_policy, indent + 4);
            try indented(writer, indent).writeAll("}\n");
        },
    }
    try indented(writer, indent).print("WTF::Vector<{s}> {s};\n", .{ try e.cppType(element_input.value_type), native_sequence });
    try emitCppSequenceReserve(writer, native_sequence, length, indent, failure_policy);
    if (centralized_element) {
        try emitCppSequenceReserve(writer, try e.print("bindingSequenceConverters_{s}", .{suffix}), length, indent, failure_policy);
    }
    switch (indexed.read) {
        .interleaved, .grouped, .lazy => {},
        .snapshot => |read| {
            try indented(writer, indent).print("JSC::MarkedArgumentBuffer sequenceValues_{s};\n", .{suffix});
            try indented(writer, indent).print("sequenceValues_{0s}.ensureCapacity(sequenceLength_{0s});\n", .{suffix});
            try indented(writer, indent).print("if (sequenceValues_{s}.hasOverflowed()) {{\n", .{suffix});
            try emitCppOutOfMemoryReturn(writer, failure_policy, indent + 4);
            try indented(writer, indent).writeAll("}\n");
            try indented(writer, indent).print("for (uint32_t sequenceIndex_{0s} = 0; sequenceIndex_{0s} < sequenceLength_{0s}; ++sequenceIndex_{0s}) {{\n", .{suffix});
            try emitCppSequenceElementRead(writer, read, suffix, indent + 4);
            try emitCppSequenceElementPlanValidation(e, writer, conversion.validation, value, path, suffix, indent + 4);
            try indented(writer, indent + 4).print("sequenceValues_{0s}.append(sequenceValue_{0s});\n", .{suffix});
            try indented(writer, indent).writeAll("}\n");
        },
    }
    try indented(writer, indent).print("for (uint32_t sequenceIndex_{0s} = 0; sequenceIndex_{0s} < sequenceLength_{0s}; ++sequenceIndex_{0s}) {{\n", .{suffix});
    const element_suffix = try e.print("{s}_element", .{suffix});
    if (centralized_element) {
        try indented(writer, indent + 4).writeAll("auto bindingElementStorage = std::unique_ptr<SemanticElementStorage>(new (std::nothrow) SemanticElementStorage);\n");
        try emitCppStorageAllocationCheck(writer, "bindingElementStorage", indent + 4, failure_policy);
        try emitCppConverterValueAliases(e, writer, element_id, element_suffix, "(*bindingElementStorage)", indent + 4);
    }
    try emitCppBackendSequenceNativeElementDeclaration(e, writer, element_id, suffix, indent + 4);
    const element_path = try cppPathPrepend(e, path, "element of ");
    switch (indexed.read) {
        .lazy => |lazy| {
            try emitCppBackendLazyConversion(e, writer, converter_context, lazy, .{
                .value = try e.print("sequenceObject_{s}", .{suffix}),
                .index = try e.print("sequenceIndex_{s}", .{suffix}),
            }, try e.print("bindingNativeSequenceElement_{s}", .{suffix}), element_path, element_suffix, indent + 4);
        },
        .snapshot => {
            try indented(writer, indent + 4).print("[[maybe_unused]] JSC::JSValue sequenceValue_{0s} = sequenceValues_{0s}[sequenceIndex_{0s}];\n", .{suffix});
        },
        .grouped => |group| {
            try indented(writer, indent + 4).print("uint32_t sequencePatternIndex_{0s} = sequenceIndex_{0s} % {1d};\n", .{ suffix, group.sizes.len });
            try indented(writer, indent + 4).print("uint16_t sequenceReadCount_{0s} = sequenceReadGroupSizes_{0s}[sequencePatternIndex_{0s}];\n", .{suffix});
            try indented(writer, indent + 4).print("if (sequenceReadCount_{0s}) {{\n", .{suffix});
            try indented(writer, indent + 8).print("sequenceReadGroup_{s}.clear();\n", .{suffix});
            try indented(writer, indent + 8).print("for (uint16_t readIndex = 0; readIndex < sequenceReadCount_{s}; ++readIndex) {{\n", .{suffix});
            try indented(writer, indent + 12).print("auto readValue = sequenceObject_{0s}->get(global, sequenceIndex_{0s} + readIndex);\n", .{suffix});
            try emitCppConversionExceptionReturn(writer, failure_policy, indent + 12);
            try indented(writer, indent + 12).print("sequenceReadGroup_{s}.append(readValue);\n", .{suffix});
            try indented(writer, indent + 8).writeAll("}\n");
            try indented(writer, indent + 4).writeAll("}\n");
            try indented(writer, indent + 4).print("JSC::JSValue sequenceValue_{0s} = sequenceReadGroup_{0s}[sequenceReadGroupOffsets_{0s}[sequencePatternIndex_{0s}]];\n", .{suffix});
        },
        .interleaved => |read| try emitCppSequenceElementRead(writer, read, suffix, indent + 4),
    }
    if (indexed.read != .lazy) {
        if (indexed.read != .snapshot) {
            try emitCppSequenceElementPlanValidation(e, writer, conversion.validation, value, path, suffix, indent + 4);
        }
        try emitCppBackendSequenceNativeElementValue(e, writer, converter_context, element_id, .{
            .value = try e.print("sequenceValue_{s}", .{suffix}),
            .selected_member = if (pattern) |sequence_pattern| try e.print("sequencePattern_{0s}[sequenceIndex_{0s} % {1d}]", .{ suffix, sequence_pattern.member_tags.len }) else null,
        }, element_path, suffix, indent + 4);
    }
    if (centralized_element) {
        try indented(writer, indent + 4).print("bindingSequenceConverters_{s}.append(WTF::move(bindingElementStorage));\n", .{suffix});
    }
    try indented(writer, indent + 4).print("{s}.append(WTF::move(bindingNativeSequenceElement_{s}));\n", .{ native_sequence, suffix });
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppIterableSequenceConversion(
    e: *Emitter,
    writer: *Writer,
    converter_context: CppConversionBindings,
    aggregate: *const ir.CppInputAggregate,
    conversion: ir.CppSequenceInput,
    iterable: @FieldType(@FieldType(ir.CppSequenceInput, "operation"), "iterable"),
    operand: CppInputValue,
    path: CppPath,
    suffix: []const u8,
    native_sequence: []const u8,
    indent: usize,
) Error!void {
    const value = operand.value;
    const failure_policy = aggregate.failure;
    const element_id = conversion.value;
    const failure = cppInputFailureReturn(failure_policy);
    const element_failure = e.ir.get(conversion.value).failure;
    if (iterable.object_error) |failure_value| {
        try indented(writer, indent).print("if (!{s}.isObject()) {{\n", .{value});
        try emitCppValueInputError(e, writer, failure_value, path, value, indent + 4);
        try indented(writer, indent + 4).print("return {s};\n", .{failure});
        try indented(writer, indent).writeAll("}\n");
    }
    const element_input = e.ir.get(element_id);
    const centralized_element = element_input.collection_storage;
    const element_type = try e.cppType(element_input.value_type);
    const element_suffix = try e.print("{s}_element", .{suffix});
    const snapshot = iterable.snapshot;
    if (snapshot) {
        try indented(writer, indent).print("JSC::MarkedArgumentBuffer sequenceSnapshot_{s};\n", .{suffix});
        try indented(writer, indent).print("{s}.forEachInIterable(global, [&](JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue item) {{\n", .{operand.source()});
        try indented(writer, indent + 4).print("sequenceSnapshot_{s}.append(item);\n", .{suffix});
        try indented(writer, indent + 4).print("if (sequenceSnapshot_{s}.hasOverflowed()) Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n", .{suffix});
        try indented(writer, indent).writeAll("});\n");
        try emitCppConversionExceptionReturn(writer, failure_policy, indent);
    }
    try indented(writer, indent).print("WTF::Vector<{s}> {s};\n", .{ element_type, native_sequence });
    if (snapshot) {
        const snapshot_length = try e.print("sequenceSnapshot_{s}.size()", .{suffix});
        try emitCppSequenceReserve(writer, native_sequence, snapshot_length, indent, failure_policy);
        if (centralized_element) try emitCppSequenceReserve(writer, try e.print("bindingSequenceConverters_{s}", .{suffix}), snapshot_length, indent, failure_policy);
    }
    try indented(writer, indent).print("size_t sequenceIndex_{s} = 0;\n", .{suffix});
    try indented(writer, indent).print("bool sequenceConversionSucceeded_{s} = true;\n", .{suffix});
    try writer.splatByteAll(' ', indent);
    if (snapshot) {
        try writer.print("auto convertSequenceElement_{0s} = [&](JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue sequenceValue_{0s}) {{\n", .{suffix});
    } else {
        try writer.print("{s}.forEachInIterable(global, [&](JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue sequenceValue_{s}) {{\n", .{ operand.source(), suffix });
    }
    try indented(writer, indent + 4).print("if (!sequenceConversionSucceeded_{s})\n", .{suffix});
    try indented(writer, indent + 8).writeAll("return;\n");
    try indented(writer, indent + 4).print("sequenceConversionSucceeded_{s} = [&]() -> bool {{\n", .{suffix});
    try indented(writer, indent + 8).print("if (sequenceIndex_{s} == std::numeric_limits<uint32_t>::max()) {{\n", .{suffix});
    try emitCppValueInputError(e, writer, conversion.too_long, path, value, indent + 12);
    try indented(writer, indent + 12).writeAll("return false;\n");
    try indented(writer, indent + 8).writeAll("}\n");
    if (!snapshot) {
        const next_length = try e.print("sequenceIndex_{s} + 1", .{suffix});
        try emitCppSequenceReserve(writer, native_sequence, next_length, indent + 8, element_failure);
        if (centralized_element) {
            try emitCppSequenceReserve(writer, try e.print("bindingSequenceConverters_{s}", .{suffix}), next_length, indent + 8, element_failure);
        }
    }
    if (centralized_element) {
        try indented(writer, indent + 8).writeAll("auto bindingElementStorage = std::unique_ptr<SemanticElementStorage>(new (std::nothrow) SemanticElementStorage);\n");
        try emitCppStorageAllocationCheck(writer, "bindingElementStorage", indent + 8, element_failure);
        try emitCppConverterValueAliases(e, writer, element_id, element_suffix, "(*bindingElementStorage)", indent + 8);
    }
    try emitCppBackendSequenceNativeElementDeclaration(e, writer, element_id, suffix, indent + 8);
    try emitCppSequenceElementPlanValidation(e, writer, conversion.validation, value, path, suffix, indent + 8);
    try emitCppBackendSequenceNativeElementValue(e, writer, converter_context, element_id, .{ .value = try e.print("sequenceValue_{s}", .{suffix}) }, try cppPathPrepend(e, path, "element of "), suffix, indent + 8);
    if (centralized_element) {
        try indented(writer, indent + 8).print("bindingSequenceConverters_{s}.append(WTF::move(bindingElementStorage));\n", .{suffix});
    }
    try indented(writer, indent + 8).print("{s}.append(WTF::move(bindingNativeSequenceElement_{s}));\n", .{ native_sequence, suffix });
    try indented(writer, indent + 8).print("++sequenceIndex_{s};\n", .{suffix});
    try indented(writer, indent + 8).writeAll("return true;\n");
    try indented(writer, indent + 4).writeAll("}();\n");
    try writer.splatByteAll(' ', indent);
    if (snapshot) {
        try writer.writeAll("};\n");
        try indented(writer, indent).print("for (unsigned index = 0; index < sequenceSnapshot_{0s}.size() && sequenceConversionSucceeded_{0s}; ++index)\n", .{suffix});
        try indented(writer, indent + 4).print("convertSequenceElement_{0s}(vm, global, sequenceSnapshot_{0s}.at(index));\n", .{suffix});
    } else {
        try writer.writeAll("});\n");
    }
    try indented(writer, indent).writeAll("if (materializeBindingException(throwScope))\n");
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).print("RELEASE_ASSERT(sequenceConversionSucceeded_{s});\n", .{suffix});
}

fn emitCppSequenceElementPlanValidation(
    e: *Emitter,
    writer: *Writer,
    validation: ?ir.CppSequenceValidation,
    value: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const policy = validation orelse return;
    const failure_policy = policy.failure_return;
    const failure = cppInputFailureReturn(failure_policy);
    const element_value = try e.print("sequenceValue_{s}", .{suffix});
    try indented(writer, indent).print("bool sequenceElementSelected_{s} = ", .{suffix});
    try emitCppInputSelectionExpression(e, writer, policy.selection, element_value, try e.print("sequenceInput_{s}", .{suffix}));
    try writer.writeAll(";\n");
    try emitCppConversionExceptionReturn(writer, failure_policy, indent);
    try indented(writer, indent).print("if (!sequenceElementSelected_{s}) {{\n", .{suffix});
    switch (policy.failure) {
        .sequence => |failure_value| try emitCppValueInputError(e, writer, failure_value, path, value, indent + 4),
        .element => |failure_value| {
            try indented(writer, indent + 4).print("Bun::ERR::{s}(throwScope, global, WTF::makeString(", .{switch (failure_value.kind) {
                .type => "INVALID_ARG_TYPE",
                .instance => "INVALID_ARG_INSTANCE",
            }});
            try emitCppPath(e, writer, try cppPathAppend(e, path, "["));
            try writer.print(", sequenceIndex_{s}, ", .{suffix});
            try emitCppAsciiLiteral(writer, "]");
            try writer.writeAll("), ");
            try emitCppAsciiLiteral(writer, failure_value.expected);
            try writer.print(", {s});\n", .{element_value});
        },
    }
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppSequenceReserve(writer: *Writer, vector: []const u8, length: []const u8, indent: usize, failure_policy: ir.CppInputFailure) Error!void {
    try indented(writer, indent).print("if (!Bun::Bindgen::tryEnsureBindingCapacity({s}, {s})) {{\n", .{ vector, length });
    try emitCppOutOfMemoryReturn(writer, failure_policy, indent + 4);
    try indented(writer, indent).writeAll("}\n");
}

// ─── byte leases and buffer copies ───

fn emitCppNestedLeasePreparation(
    e: *Emitter,
    writer: *Writer,
    input: ir.CppBufferLease,
    value: []const u8,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const failure = cppInputFailureReturn(input.failure);
    try emitCppBufferCheckStart(writer, input.check, try e.print("bindingSource_{s}", .{suffix}), value, indent);
    try emitCppBufferConversionError(e, writer, input.check, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("switch ({s}.prepare({s}, JSC::getVM(global), {{ .writable = {s}, .allowCopy = {s}, .requireSourceAttachment = {s}, .copyTransfers = {s}, .snapshotResizableOnRetention = {s} }})) {{\n", .{
        try e.print("bindingStorage_{s}", .{suffix}),
        try e.print("bindingSource_{s}", .{suffix}),
        cppBoolean(input.writable),
        cppBoolean(input.allow_copy),
        cppBoolean(input.require_source_attachment),
        cppBoolean(input.copy_transfers),
        cppBoolean(input.snapshot_resizable),
    });
    try indented(writer, indent).writeAll("case BindingByteLease::PrepareResult::ready:\n");
    try indented(writer, indent + 4).writeAll("break;\n");
    try indented(writer, indent).writeAll("case BindingByteLease::PrepareResult::outOfMemory:\n");
    try emitCppOutOfMemoryReturn(writer, input.failure, indent + 4);
    try indented(writer, indent).writeAll("case BindingByteLease::PrepareResult::copyRequired:\n");
    try emitCppValueInputError(e, writer, input.copy_required, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{cppInputFailureReturn(input.failure)});
    try indented(writer, indent).writeAll("case BindingByteLease::PrepareResult::attachmentUnavailable:\n");
    try emitCppValueInputError(e, writer, input.attachment_unavailable, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{cppInputFailureReturn(input.failure)});
    try indented(writer, indent).writeAll("}\n");
    try writer.splatByteAll(' ', indent);
    if (input.writable) {
        try writer.print("{s} = Bun::Bindgen::CppScopedMutableBytes {{ reinterpret_cast<BindByteLeaseHandle*>(&bindingStorage_{s}) }};\n", .{ target, suffix });
    } else {
        try writer.print("{s} = Bun::Bindgen::CppScopedBytes {{ reinterpret_cast<const BindByteLeaseHandle*>(&bindingStorage_{s}) }};\n", .{ target, suffix });
    }
}

fn emitCppNestedBufferCopy(
    e: *Emitter,
    writer: *Writer,
    input: ir.CppBufferCopy,
    value: []const u8,
    target: []const u8,
    path: CppPath,
    suffix: []const u8,
    indent: usize,
) Error!void {
    const failure = cppInputFailureReturn(input.failure);
    try indented(writer, indent).print("BindingBufferSource buffer_{s};\n", .{suffix});
    try emitCppBufferCheckStart(writer, input.check, try e.print("buffer_{s}", .{suffix}), value, indent);
    try emitCppBufferConversionError(e, writer, input.check, path, value, indent + 4);
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("size_t bufferLength_{0s} = buffer_{0s}.byteLength();\n", .{suffix});
    try indented(writer, indent).print("if (!bindingStorage_{0s}.tryGrow(bufferLength_{0s})) {{\n", .{suffix});
    try emitCppOutOfMemoryReturn(writer, input.failure, indent + 4);
    try indented(writer, indent).writeAll("}\n");
    try indented(writer, indent).print("auto* bufferBytes_{0s} = buffer_{0s}.data();\n", .{suffix});
    try indented(writer, indent).print("if (buffer_{s}.isShared()) {{\n", .{suffix});
    try indented(writer, indent + 4).print("for (size_t byteIndex_{0s} = 0; byteIndex_{0s} < bufferLength_{0s}; ++byteIndex_{0s})\n", .{suffix});
    try indented(writer, indent + 8).print("bindingStorage_{0s}[byteIndex_{0s}] = std::atomic_ref<uint8_t>(bufferBytes_{0s}[byteIndex_{0s}]).load(std::memory_order_relaxed);\n", .{suffix});
    try indented(writer, indent).print("}} else if (bufferLength_{s})\n", .{suffix});
    try indented(writer, indent + 4).print("memcpy(bindingStorage_{0s}.mutableSpan().data(), bufferBytes_{0s}, bufferLength_{0s});\n", .{suffix});
    try indented(writer, indent).print("{0s} = {1s}{{ bindingStorage_{2s}.isEmpty() ? nullptr : bindingStorage_{2s}.span().data(), bindingStorage_{2s}.size() }};\n", .{
        target,
        try e.print("std::remove_cvref_t<decltype({s})> ", .{target}),
        suffix,
    });
}

fn emitCppRestArgument(e: *Emitter, writer: *Writer, converter_context: CppConversionBindings, conversion: ir.CppRestInput, index: usize) Error!void {
    const values = switch (conversion) {
        .borrowed_values => |field| {
            try writer.print("    auto bindingArguments_{0d} = callFrame->argumentsSpan();\n    cppArgs.{1s} = Bun::Bindgen::Detail::CppAnyAccess::fromSpan(bindingArguments_{0d}.subspan(std::min<size_t>({0d}, bindingArguments_{0d}.size())));\n", .{ index, field });
            return;
        },
        .count => |count| {
            const length = try e.print("(callFrame->argumentCount() > {0d} ? callFrame->argumentCount() - {0d} : 0)", .{index});
            return emitCppInputEncode(e, writer, count.encoder, length, try cppArgumentDestination(e, count.target), .{}, 4);
        },
        .element => |element| return emitCppTypedRestArgument(e, writer, converter_context, element, index),
        .values => |values| values,
    };
    const deferred = converter_context.deferred;
    const failure = e.ir.get(values.encoder).failure;
    try writer.print("    WTF::Vector<JSC::JSValue> converted_{0d};\n    size_t restLength_{0d} = callFrame->argumentCount() > {0d} ? callFrame->argumentCount() - {0d} : 0;\n", .{index});
    try emitCppSequenceReserve(writer, try e.print("converted_{d}", .{index}), try e.print("restLength_{d}", .{index}), 4, failure);
    if (values.lazy != null) {
        try emitCppSequenceReserve(writer, try e.print("lazyStorage.argument_{d}", .{index}), try e.print("restLength_{d}", .{index}), 4, failure);
        try writer.print("    using LazyRestStorage_{0d} = std::remove_pointer_t<decltype(lazyStorage.argument_{0d}[0].get())>;\n", .{index});
    }
    try writer.print("    for (size_t restIndex = 0; restIndex < restLength_{0d}; ++restIndex) {{\n", .{index});
    switch (values.read) {
        .overload_inputs => try writer.print("        const BindingConversionInput* preparedInput = {0d} + restIndex < bindingOverloadInputs.size() ? &bindingOverloadInputs[{0d} + restIndex] : nullptr;\n", .{index}),
        .call_frame => try writer.writeAll("        const BindingConversionInput* preparedInput = nullptr;\n"),
    }
    try writer.print("        JSC::JSValue restValue = preparedInput ? preparedInput->value() : callFrame->uncheckedArgument({d} + restIndex);\n", .{index});
    if (values.lazy) |deferred_input| {
        try writer.print("        auto state = std::unique_ptr<LazyRestStorage_{0d}>(new (std::nothrow) LazyRestStorage_{0d}(*global, restValue, preparedInput, {1s}, restIndex{2s}));\n", .{
            index,
            deferred,
            if (e.ir.get(deferred_input.value).call_receiver) ", lazyStorage.receiver.get()" else "",
        });
        try emitCppStorageAllocationCheck(writer, "state", 8, failure);
        try writer.print("        lazyStorage.argument_{d}.append(WTF::move(state));\n", .{index});
    }
    try writer.print("        converted_{d}.append(restValue);\n    }}\n", .{index});
    try emitCppInputEncode(e, writer, values.encoder, try e.print("converted_{d}", .{index}), try e.print("args.{s}", .{values.target}), .{}, 4);
}

fn emitCppTypedRestArgument(e: *Emitter, writer: *Writer, converter_context: CppConversionBindings, conversion: ir.CppRestElement, index: usize) Error!void {
    const destination = conversion.target;
    const value_input = e.ir.get(conversion.value);
    const suffix = try e.print("rest_argument_{d}", .{index});
    const element_suffix = try e.print("{s}_element", .{suffix});
    const length = try e.print("restLength_{d}", .{index});
    const values = try e.print("restValues_{d}", .{index});
    const element = try e.print("restElement_{d}", .{index});
    const element_type = switch (destination) {
        .wire => try e.wireSpelling(e.ir.get(conversion.value.position).wire),
        .cpp => try e.cppType(value_input.value_type),
    };
    const storage_type = try e.print("BindingRestElement_{d}", .{index});
    const receiver = value_input.call_receiver;
    const context: CppConversionBindings = .{
        .receiver = "bindingConverterReceiver",
        .deferred = "bindingDeferredConversionsPointer",
    };
    try writer.print("    struct {s} {{\n        {s} value {{}};\n", .{ storage_type, try e.cppType(value_input.value_type) });
    try emitCppConverterValueStorage(e, writer, conversion.value, element_suffix, 8);
    try writer.print("        bool convert(JSC::JSGlobalObject* global, const BindingConversionInput& source, [[maybe_unused]] size_t elementIndex, {s}Bun::Bindgen::BindingDeferredConversions* bindingDeferredConversionsPointer, {s}& output{s})\n        {{\n", .{ if (destination == .wire) "BindingTemporaryWireStorage& wireStorage, " else "", element_type, if (receiver) ", JSC::JSValue bindingConverterReceiver" else "" });
    try writer.writeAll("            auto& vm = global->vm();\n            auto throwScope = DECLARE_THROW_SCOPE(vm);\n");
    switch (conversion.path) {
        .value => |root| try emitCppInputPlanValue(e, writer, context, conversion.value, .{ .value = "source.value()", .prepared = "source" }, "value", cppPath(root), element_suffix, 12),
        .element => |indexed| try emitCppStringConversionTo(e, writer, indexed.conversion, "source.value()", "value", CppIndexedStringPath{ .root = indexed.name, .index = "elementIndex" }, try e.print("conversionContext_{s}", .{element_suffix}), 12),
    }
    switch (destination) {
        .wire => try emitCppInputEncode(e, writer, value_input.encoder, "value", "output", .{ .suffix = element_suffix }, 12),
        .cpp => try writer.writeAll("            output = WTF::move(value);\n"),
    }
    try writer.writeAll("            if (materializeBindingException(throwScope)) return false;\n            throwScope.release();\n            return true;\n        }\n    };\n");
    try writer.print("    size_t restLength_{0d} = callFrame->argumentCount() > {0d} ? callFrame->argumentCount() - {0d} : 0;\n", .{index});
    try writer.print("    WTF::Vector<{s}> {s};\n", .{ element_type, values });
    try emitCppSequenceReserve(writer, values, length, 4, conversion.failure);
    try writer.print("    WTF::Vector<std::unique_ptr<{s}>> bindingRestConverters_{s};\n", .{ storage_type, suffix });
    try emitCppSequenceReserve(writer, try e.print("bindingRestConverters_{s}", .{suffix}), length, 4, conversion.failure);
    try writer.print("    for (size_t restIndex_{0d} = 0; restIndex_{0d} < restLength_{0d}; ++restIndex_{0d}) {{\n", .{index});
    try writer.print("        {s} {s} {{}};\n", .{ element_type, element });
    try writer.print("        auto storage = std::unique_ptr<{0s}>(new (std::nothrow) {0s});\n", .{storage_type});
    try emitCppStorageAllocationCheck(writer, "storage", 8, conversion.failure);
    try writer.print("        bindingRestConverters_{s}.append(WTF::move(storage));\n", .{suffix});
    try writer.print("        BindingConversionInput restInput(callFrame->uncheckedArgument({0d} + restIndex_{0d}));\n", .{index});
    const source = switch (conversion.read) {
        .overload_inputs => try e.print("({0d} + restIndex_{0d} < bindingOverloadInputs.size() ? bindingOverloadInputs[{0d} + restIndex_{0d}] : restInput)", .{index}),
        .call_frame => "restInput",
    };
    try writer.print("        if (!checkBindingConversionResult(throwScope, bindingRestConverters_{s}.last()->convert(global, {s}, restIndex_{d}, {s}{s}, {s}", .{
        suffix,                                            source,                     index,
        if (destination == .wire) "wireStorage, " else "", converter_context.deferred, element,
    });
    if (receiver) try writer.print(", {s}", .{converter_context.receiver});
    try writer.print("))) return {s};\n", .{cppInputFailureReturn(conversion.failure)});
    try writer.print("        {s}.append(WTF::move({s}));\n", .{ values, element });
    try writer.writeAll("    }\n");
    switch (destination) {
        .wire => |field| try writer.print("    encodeBindingSlice({s}.span(), args.{s});\n\n", .{ values, field }),
        .cpp => |field| try writer.print("    cppArgs.{s} = std::span<{s} const> {{ {s}.span().data(), {s}.size() }};\n\n", .{ field, element_type, values, values }),
    }
}

/// Registers the leases `emitCppArgumentValue` stored for one argument. A lazy
/// argument registers its leases when it is forced.
fn emitCppArgumentLeaseRegistration(e: *Emitter, writer: *Writer, id: ir.CppInputId, index: usize) Error!void {
    try emitCppSemanticConverterValueLeaseRegistration(e, writer, id, try cppArgumentSuffix(e, index));
}

fn emitCppSemanticConverterLeaseRegistration(writer: *Writer, suffix: []const u8, failure: []const u8) Error!void {
    try writer.print("    if (!checkBindingConversionResult(throwScope, bindingSemanticConverter_{s}.registerDeferred(global, bindingDeferredConversions)))\n", .{suffix});
    try writer.print("        return {s};\n", .{failure});
}

fn emitCppLeaseStorageRegistration(writer: *Writer, storage: []const u8, failure: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("if (!{s}.defer(bindingDeferredConversions)) {{\n", .{storage});
    try indented(writer, indent + 4).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
    try indented(writer, indent + 4).print("return {s};\n", .{failure});
    try indented(writer, indent).writeAll("}\n");
}

fn cppArgumentMissing(e: *Emitter, missing: ir.CppArgumentMissing, index: usize) Allocator.Error![]const u8 {
    return switch (missing) {
        .never => "false",
        .undefined => e.print("input_{d}.value().isUndefined()", .{index}),
        .nullish => e.print("input_{d}.value().isUndefinedOrNull()", .{index}),
        .omitted => |source_index| e.print("(callFrame->argumentCount() <= {d})", .{source_index}),
    };
}

// ─── scalar conversions ───

fn emitCppScalarValue(e: *Emitter, writer: *Writer, context: CppConversionBindings, conversion: ir.CppScalarConversion, value: []const u8, context_name: []const u8) Error!void {
    switch (conversion.operation) {
        .boolean => |operation| switch (operation) {
            .webidl => try writer.print("static_cast<uint8_t>(WebCore::convert<WebCore::IDLBoolean>(*global, {s}))", .{value}),
            .truthy => try writer.print("static_cast<uint8_t>({s}.toBoolean(global))", .{value}),
            .strict_true => try writer.print("static_cast<uint8_t>({s}.isTrue())", .{value}),
            .not_strict_false => try writer.print("static_cast<uint8_t>(!{s}.isFalse())", .{value}),
        },
        .idl => |type_id| if (conversion.context == .none)
            try writer.print("WebCore::convert<{s}>(*global, {s})", .{ try e.cppType(type_id), value })
        else
            try writer.print("Bun::convertIDL<{s}>(*global, {s}, {s})", .{ try e.cppType(type_id), value, context_name }),
        .clamp => |clamp| {
            const wire = try e.wireSpelling(clamp.wire);
            try writer.print("std::clamp(WebCore::convert<{s}>(*global, {s}), static_cast<{s}>({s}), static_cast<{s}>({s}))", .{
                try e.cppType(clamp.idl), value, wire, try cppIntegerLiteral(e, clamp.range.min), wire, try cppIntegerLiteral(e, clamp.range.max),
            });
        },
        .receiver_byte_length => |receiver| {
            const bound = if (receiver.bound == .at_preparation) "bindingPreparedReceiverByteLength" else context.receiver;
            try writer.print("Bun::Bindgen::{s}<{s}>(*global, {s}, {s}, {s})", .{
                if (receiver.bound == .at_preparation) "byteLengthIndex" else "receiverByteLengthIndex",
                cppBoolean(receiver.mode == .to_length),
                value,
                context_name,
                bound,
            });
        },
    }
}

fn cppConversionFailure(e: *Emitter, failure: ir.ConversionFailure) Allocator.Error![]const u8 {
    const message = try cppByteStringLiteral(e, failure.message);
    const names: struct { []const u8, []const u8 } = switch (failure.kind) {
        .dom_exception => |name| return e.print("Bun::BindgenDOMConversionFailure<WebCore::ExceptionCode::{t}, {s}>", .{ name, message }),
        .generic_error => .{ "Error", "ERR_OUT_OF_RANGE" },
        .type_error => .{ "TypeError", "ERR_OUT_OF_RANGE" },
        .range_error => .{ "RangeError", "ERR_OUT_OF_RANGE" },
        .code => |name| .{ "Code", name },
    };
    return e.print("Bun::BindgenConversionFailure<Bun::BindgenConversionErrorKind::{s}, Bun::ErrorCode::{s}, {s}>", .{ names[0], names[1], message });
}

fn cppByteStringLiteral(e: *Emitter, value: []const u8) Allocator.Error![]const u8 {
    var text: Writer.Allocating = .init(e.arena);
    emitCppRawStringLiteral(&text.writer, value) catch return error.OutOfMemory;
    return text.written();
}

fn emitCppMatchingIntegerExpression(e: *Emitter, writer: *Writer, matching: @FieldType(ir.CppValueTest, "integer"), value: []const u8) Error!void {
    try writer.print("Bun::Bindgen::matchingInteger<{s}, {s}, {s}>({s}).has_value()", .{
        try e.wireSpelling(matching.wire),
        try cppIntegerLiteral(e, matching.range.min),
        try cppIntegerLiteral(e, matching.range.max),
        value,
    });
}

fn cppDoubleBits(value: f64) u64 {
    return @bitCast(value);
}

fn cppScalarToJSExpression(e: *Emitter, scalar: ir.CppScalarMaterialization, expression: []const u8) Allocator.Error![]const u8 {
    return switch (scalar) {
        .boolean => e.print("JSC::jsBoolean({s})", .{expression}),
        .number => e.print("JSC::jsNumber(JSC::purifyNaN({s}))", .{expression}),
        .integer_number => e.print("JSC::jsNumber({s})", .{expression}),
        .integer_number_or_bigint => e.print("Bun::Bindgen::integerNumberOrBigIntToJS(global, {s})", .{expression}),
        .signed_bigint => e.print("JSC::JSBigInt::createFrom(global, static_cast<int64_t>({s}))", .{expression}),
        .unsigned_bigint => e.print("JSC::JSBigInt::createFrom(global, static_cast<uint64_t>({s}))", .{expression}),
        .discarded => |match| cppDiscardedJSValue(e, match),
    };
}

fn cppIntegerLiteral(e: *Emitter, literal: ir.CppIntegerLiteral) Allocator.Error![]const u8 {
    return switch (literal) {
        .signed => |number| e.print("{d}", .{number}),
        .unsigned => |number| e.print("{d}U", .{number}),
        .signed_long => |number| if (number == std.math.minInt(i64)) "(-9223372036854775807LL - 1)" else e.print("{d}LL", .{number}),
        .unsigned_long => |number| e.print("{d}ULL", .{number}),
    };
}

fn emitCppNumberLiteral(writer: *Writer, value: f64) Error!void {
    try writer.print("std::bit_cast<double>(uint64_t {{ 0x{x:0>16}ULL }})", .{cppDoubleBits(value)});
}

// ─── wire values to JavaScript ───

fn cppBufferTemplateArguments(e: *Emitter, representation: ir.BufferResultRepresentation) Allocator.Error![]const u8 {
    return if (representation == .node_buffer)
        "JSC::JSUint8Array, true"
    else
        e.print("JSC::JS{s}", .{representation.jsClassName()});
}

fn emitCppBufferToJS(
    e: *Emitter,
    writer: *Writer,
    representation: ir.BufferResultRepresentation,
    failure: ir.CppCodecFailureId,
    source: []const u8,
    target: []const u8,
    native_name: []const u8,
    indent: usize,
) Error!void {
    try writer.splatByteAll(' ', indent);
    try writer.print("auto* {s} = takeBindingBuffer<{s}>(global, {s});\n", .{ native_name, try cppBufferTemplateArguments(e, representation), source });
    try emitCppCodecException(e, writer, failure, indent);
    try emitCppDecodeAllocationCheck(e, writer, failure, try e.print("!{s}", .{native_name}), indent);
    try indented(writer, indent).print("{s} = {s};\n", .{ target, native_name });
}

fn emitCppPropertyWrite(
    e: *Emitter,
    writer: *Writer,
    property: ir.CppPropertyWrite,
    object: []const u8,
    value: []const u8,
    indent: usize,
    failure_return: []const u8,
) Error!void {
    try writer.splatByteAll(' ', indent);
    switch (property) {
        .offset => |offset| try writer.print("{s}->putDirectOffset(vm, {d}, {s});\n", .{ object, offset, value }),
        .name => |name| {
            try writer.print("{s}->putDirect(vm, ", .{object});
            try emitCppInternedPropertyKey(e, writer, name, "vm");
            try writer.print(", {s});\n", .{value});
            try emitCppExceptionReturn(writer, indent, failure_return);
        },
    }
}

fn materializerName(e: *Emitter, id: anytype) Allocator.Error![]const u8 {
    return e.print("materializeBinding_{t}_{d}_{d}", .{ @TypeOf(id).role, id.position.index, id.index });
}

fn emitCppMaterializerSignature(e: *Emitter, writer: *Writer, id: anytype) Error!void {
    const materializer = e.ir.get(id);
    try writer.print("inline JSC::JSValue {s}(JSC::JSGlobalObject* global", .{try materializerName(e, id)});
    if (!materializer.isVoid()) switch (materializer.source) {
        .wire => |wire| try writer.print(", {s}std::type_identity_t<{s}>& value", .{ if (wire.transfer) "" else "const ", try e.wireSpelling(wire.type) }),
        .native => |value_type| try writer.print(", const {s}& value", .{try e.cppType(value_type)}),
    };
    try writer.writeByte(')');
}

fn cppMaterializedValue(e: *Emitter, id: anytype, source: []const u8) Allocator.Error![]const u8 {
    return if (e.ir.get(id).isVoid())
        e.print("Bun::Bindgen::{s}(global)", .{try materializerName(e, id)})
    else
        e.print("Bun::Bindgen::{s}(global, {s})", .{ try materializerName(e, id), source });
}

fn emitCppMaterializedValue(e: *Emitter, writer: *Writer, id: anytype, source: []const u8, target: []const u8, indent: usize) Error!void {
    try indented(writer, indent).print("{s} = {s};\n", .{ target, try cppMaterializedValue(e, id, source) });
}

const MaterializationAccess = struct {
    e: *Emitter,
    source: ir.CppMaterializationSource,

    fn present(a: MaterializationAccess, value: []const u8) Allocator.Error![]const u8 {
        return if (a.source == .wire) a.e.print("decodeBindingPresence({s}.present)", .{value}) else a.e.print("{s}.has_value()", .{value});
    }

    fn optional(a: MaterializationAccess, value: []const u8) Allocator.Error![]const u8 {
        return if (a.source == .wire) a.e.print("{s}.value", .{value}) else a.e.print("{s}.value()", .{value});
    }

    fn fieldPresent(a: MaterializationAccess, name: []const u8) Allocator.Error![]const u8 {
        return if (a.source == .wire) a.e.print("decodeBindingPresence(value.{s}_present)", .{name}) else a.e.print("value.{s}.has_value()", .{name});
    }

    fn field(a: MaterializationAccess, name: []const u8, is_optional: bool) Allocator.Error![]const u8 {
        return if (a.source == .native and is_optional) a.e.print("value.{s}.value()", .{name}) else a.e.print("value.{s}", .{name});
    }

    fn member(a: MaterializationAccess, name: []const u8) Allocator.Error![]const u8 {
        return if (a.source == .wire) a.e.print("value.payload.{s}", .{name}) else a.e.print("value.{s}()", .{name});
    }

    fn values(a: MaterializationAccess) []const u8 {
        return if (a.source == .wire) "decodeBindingSlice(value)" else "value";
    }

    fn recordKey(a: MaterializationAccess) []const u8 {
        return if (a.source == .wire) "decodeBindingString(values[index].key)" else "values[index].first";
    }

    fn recordValue(a: MaterializationAccess) []const u8 {
        return if (a.source == .wire) "values[index].value" else "values[index].second";
    }
};

fn materializedJSValue(e: *Emitter, read: ir.CppMaterializedValue, source: []const u8) Allocator.Error![]const u8 {
    return switch (read) {
        .encoded => e.print("decodeBindingValue({s})", .{source}),
        .handle => e.print("readBindingJSValue({s})", .{source}),
        .root => e.print("readBindingRootValue(global, {s})", .{source}),
        .any => cppAnyToJSExpression(e, source),
        .native => source,
    };
}

fn emitCppMaterializationLeaf(e: *Emitter, writer: *Writer, materializer: anytype, leaf: ir.CppMaterializationLeaf) Error!void {
    const wire = materializer.source == .wire;
    switch (leaf) {
        .void => try writer.writeAll("    jsResult = JSC::jsUndefined();\n"),
        .scalar => |scalar| {
            if (wire and scalar == .discarded) try writer.writeAll("    decodeBindingDiscarded(value);\n");
            try writer.print("    jsResult = {s};\n", .{try cppScalarToJSExpression(e, scalar, if (wire and scalar == .boolean) "decodeBindingBoolean(value)" else "value")});
        },
        .value => |value| {
            try writer.print("    jsResult = {s};\n", .{try materializedJSValue(e, value.read, "value")});
            if (value.brand) |brand| {
                try writer.writeAll("    RELEASE_ASSERT_WITH_MESSAGE(!jsResult.isEmpty(), \"binding returned an empty JS value without an exception\");\n");
                try emitCppBrandAssertion(e, writer, brand, "jsResult", 4);
            }
        },
        .callback => |read| try writer.print("    jsResult = bindingCallbackFunction({s});\n", .{try materializedJSValue(e, read, "value")}),
        .class => |class| {
            if (wire) try writer.writeAll("    RELEASE_ASSERT(value.native);\n");
            try writer.print("    jsResult = {s};\n", .{try materializedJSValue(e, class.read, if (wire) "value.wrapper" else "value")});
            try writer.writeAll("    RELEASE_ASSERT_WITH_MESSAGE(!jsResult.isEmpty(), \"binding returned an empty JS value without an exception\");\n");
            try emitCppClassBrandAssertion(e, writer, e.class(class.id), "jsResult", 4);
        },
        .string => try writer.print("    jsResult = JSC::jsStringWithCache(vm, {s});\n", .{if (wire) "decodeBindingString(value)" else "value"}),
        .utf8 => {
            try writer.writeAll("    auto text = decodeBindingUTF8Bytes(value);\n");
            try emitCppAllocationCheck(writer, "text", 4, "return {};");
            try writer.writeAll("    jsResult = JSC::jsStringWithCache(vm, text.value());\n");
        },
        .buffer => |buffer| {
            const transfer = wire and materializer.source.wire.transfer;
            const source = if (transfer) "value" else if (wire) "decodeBindingSlice(value)" else "bindingByteSpan(value)";
            const verb = if (transfer) "take" else "copy";
            try writer.print("    auto* result = {s}BindingBuffer<{s}>(global, {s});\n", .{ verb, try cppBufferTemplateArguments(e, buffer), source });
            try emitCppAllocationCheck(writer, "result", 4, "return {};");
            try writer.writeAll("    jsResult = result;\n");
        },
        .enumeration => |enumeration| try emitCppEnumerationToJS(e, writer, enumeration, "value", "jsResult", 4),
    }
}

fn emitCppMaterializer(e: *Emitter, writer: *Writer, id: anytype) Error!void {
    const materializer = e.ir.get(id);
    const access: MaterializationAccess = .{ .e = e, .source = std.meta.activeTag(materializer.source) };
    try emitCppMaterializerSignature(e, writer, id);
    try writer.writeAll("\n{\n    auto& vm = global->vm();\n    auto throwScope = DECLARE_THROW_SCOPE(vm);\n    BINDGEN_RETURN_IF_EXCEPTION(throwScope, {});\n    JSC::JSValue jsResult;\n");
    switch (materializer.operation) {
        .leaf => |leaf| try emitCppMaterializationLeaf(e, writer, materializer, leaf),
        .optional => |optional| {
            try writer.print("    if ({s}) {{\n", .{try access.present("value")});
            try emitCppMaterializedValue(e, writer, optional.value, try access.optional("value"), "jsResult", 8);
            try writer.print("    }} else {{\n        jsResult = JSC::{s}();\n    }}\n", .{switch (optional.absence) {
                .undefined_value => "jsUndefined",
                .null_value => "jsNull",
            }});
        },
        .dictionary => |dictionary| {
            try emitCppResultObjectCreation(e, writer, "result", dictionary.object, 4, "return {};");
            for (dictionary.fields, 0..) |field, index| {
                if (field.optional) try writer.print("    if ({s}) {{\n", .{try access.fieldPresent(field.name)});
                const indent: usize = if (field.optional) 8 else 4;
                const target = try e.print("field_{d}", .{index});
                try indented(writer, indent).print("JSC::JSValue {s};\n", .{target});
                try emitCppMaterializedValue(e, writer, field.value, try access.field(field.name, field.optional), target, indent);
                try emitCppExceptionReturn(writer, indent, "return {};");
                try emitCppPropertyWrite(e, writer, field.property, "result", target, indent, "return {};");
                if (field.optional) try writer.writeAll("    }\n");
            }
            try writer.writeAll("    jsResult = result;\n");
        },
        .union_type => |members| {
            try writer.print("    switch ({s}) {{\n", .{if (access.source == .wire) "value.tag" else "static_cast<unsigned>(value.tag())"});
            for (members, 1..) |member, tag| {
                try writer.print("    case {d}: {{\n", .{tag});
                try emitCppMaterializedValue(e, writer, member.value, try access.member(member.name), "jsResult", 8);
                try writer.writeAll("        break;\n    }\n");
            }
            try writer.writeAll("    default: RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(\"binding union has an invalid tag\");\n    }\n");
        },
        .sequence => |sequence| {
            try writer.print("    auto&& values = {s};\n", .{access.values()});
            try writer.writeAll(
                \\    if (values.size() > std::numeric_limits<uint32_t>::max()) {
                \\        JSC::throwRangeError(global, throwScope, "binding sequence is too large"_s);
                \\        return {};
                \\    }
                \\    auto* result = JSC::constructEmptyArray(global, nullptr, static_cast<uint32_t>(values.size()));
                \\
            );
            try emitCppAllocationCheck(writer, "result", 4, "return {};");
            try writer.writeAll("    for (uint32_t index = 0; index < values.size(); ++index) {\n        JSC::JSValue element;\n");
            try emitCppMaterializedValue(e, writer, sequence.value, "values[index]", "element", 8);
            try emitCppExceptionReturn(writer, 8, "return {};");
            try writer.writeAll("        result->putDirectIndex(global, index, element);\n");
            try emitCppExceptionReturn(writer, 8, "return {};");
            try writer.writeAll("    }\n");
            if (sequence.frozen) {
                try writer.writeAll("    auto* frozen = JSC::objectConstructorFreeze(global, result);\n");
                try emitCppAllocationCheck(writer, "frozen", 4, "return {};");
                try writer.writeAll("    jsResult = frozen;\n");
            } else try writer.writeAll("    jsResult = result;\n");
        },
        .record => |record| {
            try writer.print("    auto&& values = {s};\n", .{access.values()});
            try emitCppResultObjectCreation(e, writer, "result", record.object, 4, "return {};");
            try writer.writeAll("    for (size_t index = 0; index < values.size(); ++index) {\n        JSC::JSValue element;\n");
            try emitCppMaterializedValue(e, writer, record.value, access.recordValue(), "element", 8);
            try emitCppExceptionReturn(writer, 8, "return {};");
            try writer.print("        result->createDataProperty(global, JSC::Identifier::fromString(vm, {s}), element, false);\n", .{access.recordKey()});
            try emitCppExceptionReturn(writer, 8, "return {};");
            try writer.writeAll("    }\n    jsResult = result;\n");
        },
    }
    try emitCppExceptionReturn(writer, 4, "return {};");
    try writer.writeAll("    return jsResult;\n}\n\n");
}

fn emitCppAllocationCheck(writer: *Writer, value: []const u8, indent: usize, failure_return: []const u8) Error!void {
    try emitCppExceptionReturn(writer, indent, failure_return);
    try indented(writer, indent).print("if (!{s}) {{\n", .{value});
    try indented(writer, indent + 4).writeAll("if (!materializeBindingException(throwScope))\n");
    try indented(writer, indent + 8).writeAll("Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);\n");
    try emitCppPendingExceptionReturn(writer, indent + 4, failure_return);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppExceptionReturn(writer: *Writer, indent: usize, failure_return: []const u8) Error!void {
    try indented(writer, indent).writeAll("if (materializeBindingException(throwScope)) {\n");
    try emitCppPendingExceptionReturn(writer, indent + 4, failure_return);
    try indented(writer, indent).writeAll("}\n");
}

fn emitCppPendingExceptionReturn(writer: *Writer, indent: usize, failure_return: []const u8) Error!void {
    try indented(writer, indent).writeAll(failure_return);
    try writer.writeByte('\n');
}

// ─── TypeScript ───

fn typeScriptReservedWord(name: []const u8) bool {
    const reserved = [_][]const u8{ "delete", "new", "typeof", "in", "of", "function", "var", "class", "return", "import", "export", "default", "void", "switch", "case", "if", "else", "for", "while", "do", "break", "continue", "catch", "finally", "try", "throw", "with", "instanceof", "this", "super", "extends", "yield", "enum", "null", "true", "false", "let", "const" };
    for (reserved) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

/// Namespace functions with reserved names are declared under a trailing
/// underscore and export-renamed by the caller.
fn emitTypeScriptFunctionHead(writer: *Writer, name: []const u8) Error!void {
    if (typeScriptReservedWord(name)) {
        try writer.print("        function {s}_(", .{name});
    } else {
        try writer.print("        function {s}(", .{name});
    }
}

fn emitTypeScript(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll("declare namespace BunNativeBindings {\n");
    for (e.ir.typescript_declarations) |declaration| {
        switch (declaration) {
            .enumeration => |enumeration| {
                try writer.print("    type {s} = ", .{enumeration.name});
                for (enumeration.values, 0..) |value, index| {
                    if (index != 0) try writer.writeAll(" | ");
                    switch (value) {
                        .string => |string| try emitTypeScriptString(writer, string),
                        .number => |number| try writer.print("{d}", .{number}),
                    }
                }
                try writer.writeAll(";\n");
            },
            .dictionary => |dictionary| {
                try writer.print("    type {s} = {{\n", .{dictionary.name});
                for (dictionary.fields) |typescript| {
                    try writer.writeAll("        ");
                    try emitTypeScriptString(writer, typescript.name);
                    try writer.print("{s}: {s};\n", .{ if (typescript.optional) "?" else "", typescript.value });
                }
                try writer.writeAll("    };\n");
            },
            .union_type => |union_plan| {
                try writer.print("    type {s} = ", .{union_plan.name});
                for (union_plan.members, 0..) |member, index| {
                    if (index != 0) try writer.writeAll(" | ");
                    const member_typescript = member.value;
                    if (union_plan.tag) |tag| if (member.tag) |selector| {
                        try writer.writeAll("{ ");
                        try emitTypeScriptString(writer, tag.property);
                        try writer.writeAll(": ");
                        try emitTypeScriptString(writer, selector);
                        if (tag.value_property) |property| {
                            try writer.writeAll("; ");
                            try emitTypeScriptString(writer, property);
                            try writer.print(": {s} }}", .{member_typescript});
                        } else {
                            try writer.print(" }} & {s}", .{member_typescript});
                        }
                        if (tag.shorthand) {
                            try writer.writeAll(" | ");
                            try emitTypeScriptString(writer, selector);
                        }
                        continue;
                    };
                    try writer.writeAll(member_typescript);
                }
                try writer.writeAll(";\n");
            },
        }
    }
    if (e.ir.typescript_declarations.len > 0) try writer.writeByte('\n');
    for (e.ir.modules) |module| {
        try writer.print("    namespace {s} {{\n", .{module.module_name});
        for (module.declarations) |function_id| {
            const function = e.function(function_id);
            if (function.isOverloaded()) {
                for (function.overload_cases) |case_id| {
                    const case = e.ir.get(case_id);
                    try emitTypeScriptFunctionHead(writer, function.function_name);
                    try emitTypeScriptArguments(e, writer, case);
                    try writer.writeAll("): ");
                    try emitTypeScriptReturn(e, writer, case);
                    try writer.writeAll(";\n");
                }
            } else {
                try emitTypeScriptFunctionHead(writer, function.function_name);
                try emitTypeScriptArguments(e, writer, function);
                try writer.writeAll("): ");
                try emitTypeScriptReturn(e, writer, function);
                try writer.writeAll(";\n");
            }
            if (typeScriptReservedWord(function.function_name)) {
                try writer.print("        export {{ {0s}_ as {0s} }};\n", .{function.function_name});
            }
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            const parent_name = if (class.parent) |parent| e.class(parent).class_name else "";
            const extends = if (class.parent != null) " extends " else "";
            const plan = e.ir.class_relations[class.id.index].typescript;
            switch (plan.declaration) {
                .callable => |callable| {
                    try writer.print("        interface {s}{s}{s} {{\n", .{ class.class_name, extends, parent_name });
                    try emitTypeScriptClassMembers(e, writer, plan.members);
                    try writer.writeAll("        }\n");
                    try writer.print("        interface {s}Constructor {{\n", .{class.class_name});
                    for (callable.constructors) |id| {
                        try writer.writeAll("            new (");
                        try emitTypeScriptArguments(e, writer, e.ir.functionById(id));
                        try writer.print("): {s};\n", .{class.class_name});
                    }
                    for (callable.calls) |id| {
                        const function = e.ir.functionById(id);
                        try writer.writeAll("            (");
                        try emitTypeScriptArguments(e, writer, function);
                        try writer.writeAll("): ");
                        try emitTypeScriptReturn(e, writer, function);
                        try writer.writeAll(";\n");
                    }
                    try writer.print("            readonly prototype: {s};\n", .{class.class_name});
                    try emitTypeScriptClassMembers(e, writer, callable.members);
                    try writer.writeAll("        }\n");
                    try writer.print("        const {0s}: {0s}Constructor", .{class.class_name});
                    if (class.parent != null) try writer.print(" & typeof {s}", .{parent_name});
                    try writer.writeAll(";\n");
                },
                .class => |constructors| {
                    try writer.print("        class {s}{s}{s} {{\n", .{ class.class_name, extends, parent_name });
                    if (constructors.len == 0) try writer.writeAll("            private constructor();\n");
                    for (constructors) |id| {
                        try writer.writeAll("            constructor(");
                        try emitTypeScriptArguments(e, writer, e.ir.functionById(id));
                        try writer.writeAll(");\n");
                    }
                    try emitTypeScriptClassMembers(e, writer, plan.members);
                    try writer.writeAll("        }\n");
                },
            }
        }
        try writer.writeAll("    }\n");
    }
    if (e.ir.typescript_object_surfaces.len != 0) {
        try writer.writeAll("    namespace ObjectSurfaces {\n");
        for (e.ir.typescript_object_surfaces) |id| {
            const surface = e.objectSurface(id);
            try writer.print("        type {s} = {{\n", .{surface.surface_name});
            for (surface.typescript_members) |member| try emitTypeScriptObjectSurfaceMember(e, writer, member);
            try writer.writeAll("        };\n");
        }
        try writer.writeAll("    }\n");
    }
    try writer.writeAll("}\n");
    for (e.ir.native_module_surfaces) |*surface| {
        if (!surface.typescript_exposed) continue;
        try emitTypeScriptNativeModule(e, writer, surface);
    }
}

fn emitTypeScriptNativeModule(e: *Emitter, writer: *Writer, surface: *const ir.NativeModuleSurface) Error!void {
    try writer.writeAll("declare module ");
    try emitTypeScriptString(writer, surface.specifier);
    try writer.writeAll(" {\n    const defaultExport: ");
    switch (surface.default) {
        .namespace => try emitTypeScriptNativeModuleProperties(e, writer, surface),
        .declaration => |declaration| {
            try emitTypeScriptNativeModuleDeclaration(e, writer, declaration.target);
            if (declaration.installation != null) {
                try writer.writeAll(" & ");
                try emitTypeScriptNativeModuleProperties(e, writer, surface);
            }
        },
    }
    try writer.writeAll(";\n    export default defaultExport;\n");
    for (surface.exports) |*module_export| {
        if (!module_export.typescript_exposed) continue;
        try writer.print("    const {s}: ", .{module_export.export_name});
        try emitTypeScriptSurfaceMemberType(e, writer, module_export.type);
        try writer.print(";\n    export {{ {s} }};\n", .{module_export.export_name});
        for (module_export.aliases) |alias| {
            try writer.print("    const {s}: ", .{alias.name});
            try emitTypeScriptSurfaceMemberType(e, writer, module_export.type);
            try writer.print(";\n    export {{ {s} }};\n", .{alias.name});
        }
    }
    try writer.writeAll("}\n");
}

fn emitTypeScriptNativeModuleProperties(e: *Emitter, writer: *Writer, surface: *const ir.NativeModuleSurface) Error!void {
    try writer.writeAll("{\n");
    for (surface.exports) |*module_export| {
        if (!module_export.typescript_exposed) continue;
        try writer.writeAll("        ");
        if (!module_export.attributes.writable) try writer.writeAll("readonly ");
        try emitTypeScriptString(writer, module_export.export_name);
        try writer.writeAll(": ");
        try emitTypeScriptSurfaceMemberType(e, writer, module_export.type);
        try writer.writeAll(";\n");
        for (module_export.aliases) |alias| {
            try writer.writeAll("        ");
            if (!alias.attributes.writable) try writer.writeAll("readonly ");
            try emitTypeScriptString(writer, alias.name);
            try writer.writeAll(": ");
            try emitTypeScriptSurfaceMemberType(e, writer, module_export.type);
            try writer.writeAll(";\n");
        }
    }
    try writer.writeAll("    }");
}

fn emitTypeScriptNativeModuleDeclaration(e: *Emitter, writer: *Writer, declaration: ir.JavaScriptDeclarationRef) Error!void {
    switch (declaration) {
        .function => |id| try writer.print("typeof BunNativeBindings.{s}.{s}", .{ e.function(id).module_name, e.function(id).function_name }),
        .class => |id| try writer.print("typeof BunNativeBindings.{s}.{s}", .{ e.class(id).module_name, e.class(id).class_name }),
    }
}

fn emitTypeScriptObjectSurfaceMember(e: *Emitter, writer: *Writer, member: ir.SurfaceTypeScriptMember) Error!void {
    try writer.writeAll("            ");
    if (member.read_only) try writer.writeAll("readonly ");
    try emitTypeScriptPropertyKey(writer, member.key);
    try writer.writeAll(": ");
    try emitTypeScriptSurfaceMemberType(e, writer, member.type);
    try writer.writeAll(";\n");
}

fn emitTypeScriptSurfaceMemberType(e: *Emitter, writer: *Writer, value: ir.SurfaceType) Error!void {
    switch (value) {
        .declaration => |declaration| try emitTypeScriptNativeModuleDeclaration(e, writer, declaration),
        .value => |id| try writer.writeAll(e.ir.typeScript(id)),
        .object, .self_object => |id| try writer.print("BunNativeBindings.ObjectSurfaces.{s}", .{e.objectSurface(id).surface_name}),
        .namespace => try writer.writeAll("typeof defaultExport"),
        .callable => |callable| {
            try emitTypeScriptNativeModuleDeclaration(e, writer, .{ .function = callable.declaration });
            try writer.print(" & BunNativeBindings.ObjectSurfaces.{s}", .{e.objectSurface(callable.surface).surface_name});
        },
        .constant => |constant| switch (constant) {
            .string => |text| try emitTypeScriptString(writer, text),
            .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
            .string_type => try writer.writeAll("string"),
            .boolean_type => try writer.writeAll("boolean"),
            .number => try writer.writeAll("number"),
            .symbol => try writer.writeAll("symbol"),
            .undefined => try writer.writeAll("undefined"),
        },
        .collection => |collection| {
            try writer.writeAll(switch (collection.kind) {
                .array => "Array<",
                .set => "Set<",
            });
            try writer.writeAll(e.ir.typeScript(collection.element));
            try writer.writeByte('>');
        },
    }
}

fn emitTypeScriptClassMembers(e: *Emitter, writer: *Writer, members: []const ir.TypeScriptClassMember) Error!void {
    for (members) |member| {
        try writer.writeAll("            ");
        if (member.is_static) try writer.writeAll("static ");
        switch (member.operation) {
            .iterator => |iterator| try writer.writeAll(switch (iterator) {
                .synchronous => "[Symbol.iterator](): this;\n",
                .asynchronous => "[Symbol.asyncIterator](): this;\n",
            }),
            .method => |method| {
                const function = e.ir.functionById(method.declaration);
                try emitTypeScriptPropertyKey(writer, method.key);
                try writer.writeByte('(');
                try emitTypeScriptArguments(e, writer, function);
                try writer.writeAll("): ");
                try emitTypeScriptReturn(e, writer, function);
                try writer.writeAll(";\n");
            },
            .getter => |getter| {
                if (!getter.writable) try writer.writeAll("get ");
                try writer.writeAll(getter.name);
                try writer.writeAll(if (getter.writable) ": " else "(): ");
                try emitTypeScriptReturn(e, writer, e.ir.functionById(getter.declaration));
                try writer.writeAll(";\n");
            },
            .setter => |setter| try writer.print("set {s}(value: {s});\n", .{ setter.name, e.ir.get(setter.argument).typescript }),
            .property => |property| {
                if (property.read_only) try writer.writeAll("readonly ");
                try emitTypeScriptPropertyKey(writer, property.key);
                try writer.writeAll(": ");
                try writer.writeAll(switch (property.value) {
                    .type => |id| e.ir.typeScript(id),
                    .primitive => |primitive| switch (primitive) {
                        .boolean => "boolean",
                        .number => "number",
                        .string => "string",
                        .null_value => "null",
                        .undefined_value => "undefined",
                    },
                });
                try writer.writeAll(";\n");
            },
        }
    }
}

fn emitTypeScriptPropertyKey(writer: *Writer, key: ir.TypeScriptPropertyKey) Error!void {
    switch (key) {
        .name => |name| try emitTypeScriptString(writer, name),
        .symbol => |symbol| try writer.writeAll(propertySymbolTypeScriptName(symbol)),
    }
}

fn emitTypeScriptString(writer: *Writer, value: []const u8) Error!void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn emitTypeScriptArguments(e: *Emitter, writer: *Writer, function: *const ir.Function) Error!void {
    var needs_separator = false;
    if (function.this_argument) |this_argument| {
        if (function.class_member == null) {
            try writer.print("this: {s}", .{e.ir.get(this_argument.position).typescript});
            needs_separator = true;
        }
    }
    for (function.args) |argument| {
        if (argument.is_projection) continue;
        if (needs_separator) try writer.writeAll(", ");
        const typescript = e.ir.get(argument.position).typescript;
        if (argument.conversion.rest) {
            try writer.print("...{s}: Array<{s}>", .{ argument.argument_name, typescript });
        } else {
            try writer.print("{s}{s}: {s}", .{ argument.argument_name, if (argument.conversion.presence == .required) "" else "?", typescript });
        }
        needs_separator = true;
    }
}

fn typeScriptAsync(function: *const ir.Function) bool {
    if (function.isAsync()) return true;
    return if (function.class_member) |member| member.typescript_async else false;
}

fn emitTypeScriptReturn(e: *Emitter, writer: *Writer, function: *const ir.Function) Error!void {
    if (function.predicate) |predicate| {
        try writer.print("value is {s}", .{e.ir.typeScript(e.ir.get(predicate).type)});
        return;
    }
    const promise = typeScriptAsync(function);
    try writer.print("{s}{s}{s}", .{
        if (promise) "Promise<" else "",
        e.ir.typeScript(e.ir.get(function.result_position).type),
        if (promise) ">" else "",
    });
}

// ─── global object structures and subspaces ───

fn cppRealmFunction(e: *const Emitter, declaration: ir.FunctionId) ?*const ir.CppRealmFunction {
    const factory = e.ir.cpp_function_factories[declaration.index] orelse return null;
    return switch (factory.value) {
        .realm => |id| e.ir.get(id),
        .builtin, .native => null,
    };
}

fn emitLazyStructureHeader(e: *Emitter, writer: *Writer) Error!void {
    for (e.ir.modules) |module| {
        for (module.declarations) |function_id| {
            const function = cppRealmFunction(e, function_id) orelse continue;
            try writer.print(
                \\JSC::JSFunction* {0s}() const {{ return m_{0s}.getInitializedOnMainThread(this); }}
                \\LazyPropertyOfGlobalObject<JSC::JSFunction> m_{0s};
                \\
            , .{function.symbol});
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed) continue;
            const name = class.cpp_class_name;
            const constructor_accessor = if (e.function(class.constructor).exposed)
                try e.print("JSC::JSObject* {0s}Constructor() const {{ return m_{0s}.constructorInitializedOnMainThread(this); }}", .{name})
            else
                "";
            try writer.print(
                \\JSC::Structure* {0s}Structure() const {{ return m_{0s}.getInitializedOnMainThread(this); }}
                \\{1s}
                \\JSC::JSObject* {0s}Prototype() const {{ return m_{0s}.prototypeInitializedOnMainThread(this); }}
                \\JSC::LazyClassStructure m_{0s};
                \\
            , .{ name, constructor_accessor });
        }
    }
    for (e.ir.promise_reaction_contexts) |context| {
        try writer.print(
            \\JSC::Structure* {0s}Structure() const {{ return m_{0s}Structure.getInitializedOnMainThread(this); }}
            \\LazyPropertyOfGlobalObject<JSC::Structure> m_{0s}Structure;
            \\
        , .{e.ir.get(context).context_name});
    }
    try writer.writeAll(
        \\ALWAYS_INLINE void initSchemaBindingClasses();
        \\template<typename Visitor> void visitSchemaBindingClasses(GlobalObject*, Visitor&);
        \\
    );
}

fn emitLazyStructureImpl(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll("ALWAYS_INLINE void GlobalObject::initSchemaBindingClasses()\n{\n");
    for (e.ir.modules) |module| {
        for (module.declarations) |function_id| {
            const function = cppRealmFunction(e, function_id) orelse continue;
            try writer.print(
                \\    m_{s}.initLater([](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSFunction>::Initializer& init) {{
                \\
            , .{function.symbol});
            try writer.print("        init.set(JSC::JSFunction::create(init.vm, init.owner, {d}, ", .{function.length});
            try emitCppUtf8String(writer, function.name);
            try writer.print(", ::{s}, JSC::ImplementationVisibility::{s}));\n    }});\n", .{
                function.host,
                if (function.visibility == .public) "Public" else "Private",
            });
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed) continue;
            try writer.print(
                \\    m_{s}.initLater([](JSC::LazyClassStructure::Initializer& init) {{
                \\        Bun::{s}(init);
                \\    }});
                \\
            , .{ class.cpp_class_name, class.initialize_symbol });
        }
    }
    for (e.ir.promise_reaction_contexts) |context| {
        try writer.print(
            \\    m_{0s}Structure.initLater([](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {{
            \\        init.set(Bun::{0s}::createStructure(init.vm, init.owner));
            \\    }});
            \\
        , .{e.ir.get(context).context_name});
    }
    try writer.writeAll("}\n\ntemplate<typename Visitor>\nvoid GlobalObject::visitSchemaBindingClasses(GlobalObject* thisObject, Visitor& visitor)\n{\n");
    for (e.ir.modules) |module| {
        for (module.declarations) |function_id| {
            const function = cppRealmFunction(e, function_id) orelse continue;
            try writer.print("    thisObject->m_{s}.visit(visitor);\n", .{function.symbol});
        }
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed) continue;
            try writer.print("    thisObject->m_{s}.visit(visitor);\n", .{class.cpp_class_name});
        }
    }
    for (e.ir.promise_reaction_contexts) |context| {
        try writer.print("    thisObject->m_{s}Structure.visit(visitor);\n", .{e.ir.get(context).context_name});
    }
    try writer.writeAll("}\n");
}

fn emitIsoSubspaceDeclarations(e: *Emitter, writer: *Writer, comptime declaration: []const u8) Error!void {
    for (e.ir.modules) |module| {
        for (module.class_declarations) |class_id| {
            const class = e.class(class_id);
            if (!class.exposed) continue;
            try writer.print(declaration, .{class.cpp_class_name});
            if (e.ir.cpp_class_constructors[class.id.index]) |constructor| if (constructor.hasTracedState()) try writer.print(declaration, .{class.cpp_constructor_name});
        }
    }
    for (e.ir.promise_reaction_contexts) |context| try writer.print(declaration, .{e.ir.get(context).context_name});
}

fn emitClientIsoSubspaces(e: *Emitter, writer: *Writer) Error!void {
    try emitIsoSubspaceDeclarations(e, writer, "std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceFor{s};\n");
}

fn emitIsoSubspaces(e: *Emitter, writer: *Writer) Error!void {
    try emitIsoSubspaceDeclarations(e, writer, "std::unique_ptr<IsoSubspace> m_subspaceFor{s};\n");
}

// ─── classes ───

fn engineClassJSType(kind: @FieldType(ir.CppEngineClass, "cell_kind")) []const u8 {
    return switch (kind) {
        .object => "JSC::ObjectType",
        .event => "JSC::JSType(WebCore::JSEventType)",
        .dom_wrapper => "JSC::JSType(WebCore::JSDOMWrapperType)",
        .as_json => "JSC::JSType(WebCore::JSAsJSONType)",
    };
}

fn emitCppSlotAccessors(writer: *Writer, slot_name: []const u8) Error!void {
    try writer.print("    JSC::JSValue slot_{0s}() const {{ auto value = m_{0s}.get(); return value.isEmpty() ? JSC::jsUndefined() : value; }}", .{slot_name});
    try writer.print("    JSC::JSValue raw_slot_{0s}() const {{ return m_{0s}.get(); }}\n    const JSC::JSValue* raw_slot_{0s}_handle() const {{ return m_{0s}.slot(); }}\n", .{slot_name});
    try writer.print("    void set_slot_{0s}(JSC::VM& vm, JSC::JSValue value) {{ m_{0s}.set(vm, this, value); }}\n    void clear_slot_{0s}() {{ m_{0s}.clear(); }}\n\n", .{slot_name});
}

fn emitCppSubspaceFor(writer: *Writer, name: []const u8) Error!void {
    try writer.print(
        \\    template<typename, JSC::SubspaceAccess mode>
        \\    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
        \\    {{
        \\        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
        \\            return nullptr;
        \\        return WebCore::subspaceForImpl<{0s}, WebCore::UseCustomHeapCellType::No>(
        \\            vm,
        \\            [](auto& spaces) {{ return spaces.m_clientSubspaceFor{0s}.get(); }},
        \\            [](auto& spaces, auto&& space) {{ spaces.m_clientSubspaceFor{0s} = std::forward<decltype(space)>(space); }},
        \\            [](auto& spaces) {{ return spaces.m_subspaceFor{0s}.get(); }},
        \\            [](auto& spaces, auto&& space) {{ spaces.m_subspaceFor{0s} = std::forward<decltype(space)>(space); }});
        \\    }}
        \\
    , .{name});
}

fn emitCppEngineClassDeclaration(e: *Emitter, writer: *Writer, class: *const ir.Class, engine: ir.CppEngineClass) Error!void {
    const base_name = try e.cppType(engine.base_type);
    const impl_type = try e.cppType(engine.native_type);
    const name = class.cpp_class_name;
    try writer.print(
        \\class {0s}{1s} : public {2s} {{
        \\public:
        \\    using Base = {2s};
        \\    using DOMWrapped = {3s};
        \\    static constexpr unsigned StructureFlags = {4s};
        \\    DECLARE_INFO;
        \\    DECLARE_VISIT_CHILDREN;
        \\
        \\
    , .{
        name,
        if (e.ir.class_relations[class.id.index].emission.has_children) "" else " final",
        base_name,
        impl_type,
        if (class.immutable_prototype) "Base::StructureFlags | JSC::IsImmutablePrototypeExoticObject" else "Base::StructureFlags",
    });
    try emitCppSubspaceFor(writer, name);
    try writer.print(
        \\
        \\    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue);
        \\    static {0s}* create(JSC::Structure*, WebCore::JSDOMGlobalObject*, Ref<{1s}>&&);
        \\    static void destroy(JSC::JSCell*);
        \\    static void analyzeHeap(JSC::JSCell*, JSC::HeapAnalyzer&);
        \\    {1s}& wrapped() const {{ return static_cast<{1s}&>(Base::wrapped()); }}
        \\    static {1s}* toWrapped(JSC::VM&, JSC::JSValue);
        \\
    , .{ name, impl_type });
    if (class.runtime_plan.tracing.mode == .engine_slots_and_additional_children) {
        try writer.writeAll(
            \\    DECLARE_VISIT_OUTPUT_CONSTRAINTS;
            \\    template<typename Visitor> void visitAdditionalChildren(Visitor&);
            \\
        );
    }
    if (engine.estimated_size) try writer.writeAll("    static size_t estimatedSize(JSC::JSCell*, JSC::VM&);\n");
    for (class.slots) |slot| {
        if (slot.storage == .instance) try emitCppSlotAccessors(writer, slot.slot_name);
    }
    try writer.print(
        \\protected:
        \\    {s}(JSC::Structure*, WebCore::JSDOMGlobalObject&, Ref<{s}>&&);
        \\    void finishCreation(JSC::VM&);
        \\
    , .{ name, impl_type });
    for (class.slots) |slot| {
        if (slot.storage == .instance) try writer.print("    JSC::WriteBarrier<JSC::Unknown> m_{s};\n", .{slot.slot_name});
    }
    try writer.writeAll("};\n\n");
}

fn emitCppUnforgeableAccessorInitializer(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    const properties = e.ir.class_relations[class.id.index].properties.unforgeable;
    if (properties.len == 0) return;
    try writer.print("static void {0s}_initializeUnforgeableAccessors({0s}& object, JSC::VM& vm)\n{{\n", .{class.cpp_class_name});
    for (properties) |property| {
        try writer.writeAll("    object.putDirectCustomAccessor(vm, ");
        try emitCppInternedPropertyKey(e, writer, property.name, "vm");
        try writer.writeAll(", WebCore::DOMAttributeGetterSetter::create(vm, ");
        switch (property.accessor) {
            .getter => |getter| try writer.print("{s}, {s}", .{
                try cppClassMemberSymbol(e, getter.implementation),
                if (getter.setter) |setter| try cppClassMemberSymbol(e, setter) else "nullptr",
            }),
            .setter => |setter| try writer.print("nullptr, {s}", .{try cppClassMemberSymbol(e, setter)}),
        }
        try writer.print(", WebCore::DOMAttributeAnnotation {{ {s}::info(), nullptr }}), static_cast<unsigned>(", .{class.cpp_class_name});
        try emitCppPropertyAttributes(writer, property.attributes, "CustomAccessor");
        try writer.writeAll("));\n");
    }
    try writer.writeAll("}\n\n");
}

fn emitCppEngineClassDefinitions(e: *Emitter, writer: *Writer, class: *const ir.Class, engine: ir.CppEngineClass) Error!void {
    const impl_type = try e.cppType(engine.native_type);
    const name = class.cpp_class_name;
    try writer.print("const JSC::ClassInfo {0s}::s_info = {{ \"{1s}\"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE({0s}) }};\n", .{ class.cpp_prototype_name, class.display_name });
    if (e.function(class.constructor).exposed) {
        try writer.print("const JSC::ClassInfo {0s}::s_info = {{ \"{1s}\"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE({0s}) }};\n", .{ class.cpp_constructor_name, class.display_name });
    }
    try emitCppUnforgeableAccessorInitializer(e, writer, class);
    try writer.print(
        \\const JSC::ClassInfo {0s}::s_info = {{ "{1s}"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE({0s}) }};
        \\
        \\{0s}::{0s}(JSC::Structure* structure, WebCore::JSDOMGlobalObject& globalObject, Ref<{2s}>&& impl)
        \\    : Base(structure, globalObject, WTF::move(impl))
        \\{{
        \\}}
        \\
        \\JSC::Structure* {0s}::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global, JSC::JSValue prototype)
        \\{{
        \\    return JSC::Structure::create(vm, global, prototype, JSC::TypeInfo({3s}, StructureFlags), info());
        \\}}
        \\
        \\{0s}* {0s}::create(JSC::Structure* structure, WebCore::JSDOMGlobalObject* globalObject, Ref<{2s}>&& impl)
        \\{{
        \\    auto& vm = globalObject->vm();
        \\    auto* object = new (NotNull, JSC::allocateCell<{0s}>(vm)) {0s}(structure, *globalObject, WTF::move(impl));
        \\    object->finishCreation(vm);
        \\    return object;
        \\}}
        \\
        \\void {0s}::finishCreation(JSC::VM& vm)
        \\{{
        \\    Base::finishCreation(vm);
        \\    {4s}
        \\    ASSERT(inherits(info()));
        \\}}
        \\
        \\void {0s}::destroy(JSC::JSCell* cell)
        \\{{
        \\    static_cast<{0s}*>(cell)->~{0s}();
        \\}}
        \\
        \\void {0s}::analyzeHeap(JSC::JSCell* cell, JSC::HeapAnalyzer& analyzer)
        \\{{
        \\    auto* object = uncheckedDowncast<{0s}>(cell);
        \\    analyzer.setWrappedObjectForCell(cell, &object->wrapped());
        \\    Base::analyzeHeap(cell, analyzer);
        \\}}
        \\
        \\{2s}* {0s}::toWrapped(JSC::VM&, JSC::JSValue value)
        \\{{
        \\    if (auto* wrapper = WTF::dynamicDowncast<{0s}>(value))
        \\        return &wrapper->wrapped();
        \\    return nullptr;
        \\}}
        \\
    , .{
        name,
        class.display_name,
        impl_type,
        engineClassJSType(engine.cell_kind),
        if (e.ir.class_relations[class.id.index].properties.unforgeable.len != 0) try e.print("{s}_initializeUnforgeableAccessors(*this, vm);", .{name}) else "",
    });
    if (engine.estimated_size) {
        try writer.print(
            \\size_t {0s}::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
            \\{{
            \\    auto* object = uncheckedDowncast<{0s}>(cell);
            \\    return Base::estimatedSize(cell, vm) + object->wrapped().memoryCost();
            \\}}
            \\
        , .{name});
    }
    if (class.runtime_plan.tracing.mode == .engine_slots_and_additional_children) {
        try writer.print(
            \\template<typename Visitor>
            \\void {0s}::visitOutputConstraintsImpl(JSCell* cell, Visitor& visitor)
            \\{{
            \\    auto* object = uncheckedDowncast<{0s}>(cell);
            \\    ASSERT_GC_OBJECT_INHERITS(object, info());
            \\    Base::visitOutputConstraints(object, visitor);
            \\    object->visitAdditionalChildren(visitor);
            \\}}
            \\DEFINE_VISIT_OUTPUT_CONSTRAINTS({0s});
            \\
        , .{name});
    }
}

// ─── plain classes ───

fn emitCppPlainClassCreator(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    try writer.print(
        \\static JSC::JSObject* {0s}_createForInitialization(JSC::JSGlobalObject* global, JSC::Structure* requestedStructure)
        \\{{
        \\    auto& vm = JSC::getVM(global);
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\    auto* structure = defaultGlobalObject(requestedStructure->realm())->{0s}Structure();
        \\    BINDGEN_RETURN_IF_EXCEPTION(throwScope, nullptr);
        \\    auto* object = JSC::JSFinalObject::create(vm, structure);
        \\
    , .{class.cpp_class_name});
    for (class.instance_properties, 0..) |_, index| try writer.print("    object->putDirectOffset(vm, {d}, JSC::jsUndefined());\n", .{index});
    try writer.writeAll(
        \\    if (requestedStructure != structure)
        \\        object->setPrototypeDirect(vm, requestedStructure->storedPrototype());
        \\    return object;
        \\}
        \\
    );
    try emitCppExternC(writer, "BindStatus {0s}(BindGlobalObjectHandle* globalHandle, const ::{0s}_Fields* fields, BindEncodedJSValue* outValue)",
        \\{{
        \\    RELEASE_ASSERT(globalHandle);
        \\    RELEASE_ASSERT(fields);
        \\    RELEASE_ASSERT(outValue);
        \\    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
        \\    return invokeBindingStatusEntry(global, [&]() -> BindStatus {{
        \\    auto& vm = JSC::getVM(global);
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\    *outValue = 0;
        \\    BINDGEN_RETURN_IF_EXCEPTION(throwScope, BIND_STATUS_PENDING_EXCEPTION);
        \\    auto* structure = defaultGlobalObject(global)->{1s}Structure();
        \\    BINDGEN_RETURN_IF_EXCEPTION(throwScope, BIND_STATUS_PENDING_EXCEPTION);
        \\
    , .{ class.create_symbol, class.cpp_class_name });
    for (class.instance_properties, e.ir.cpp_class_property_materializers[class.id.index], 0..) |property, materializer, index| {
        try writer.print("    JSC::JSValue value_{d};\n", .{index});
        try emitCppMaterializedValue(e, writer, materializer, try e.print("fields->{s}", .{property.property_name}), try e.print("value_{d}", .{index}), 4);
        try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, BIND_STATUS_PENDING_EXCEPTION);\n");
    }
    try writer.print("    auto* object = {s}_createForInitialization(global, structure);\n", .{class.cpp_class_name});
    try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, BIND_STATUS_PENDING_EXCEPTION);\n");
    for (class.instance_properties, 0..) |_, index| try writer.print("    object->putDirectOffset(vm, {0d}, value_{0d});\n", .{index});
    try writer.writeAll(
        \\    BINDGEN_RETURN_IF_EXCEPTION(throwScope, BIND_STATUS_PENDING_EXCEPTION);
        \\    *outValue = encodeBindingValue(object);
        \\    return BIND_STATUS_OK;
        \\});
        \\}
        \\
        \\
    );
    if (e.ir.class_initializers[class.id.index]) |initializers| try emitCppPlainClassConstructorDefinitions(e, writer, class, initializers);
}

fn emitCppPlainClassConstructorDefinitions(e: *Emitter, writer: *Writer, class: *const ir.Class, initializers: ir.ClassInitializers) Error!void {
    const constructor = e.ir.get(initializers.constructor.implementation);
    const construct_helper_name = try e.print("{s}_createForConstruct", .{class.cpp_class_name});
    try emitCppPlainClassCreateHelper(e, writer, class, initializers.constructor, construct_helper_name);
    try writer.print(
        \\{s} Bindgen::Cpp::{s}(
        \\    Bun::Bindgen::CppPlainConstructContext& context,
        \\    const Bun::Bindgen::Cpp::{s}& args)
        \\{{
        \\    return {s}(&context.globalObject, context.structure, args);
        \\}}
        \\
    , .{ try cppImplementationReturnType(e, constructor), constructor.symbol, constructor.arguments, construct_helper_name });
    if (initializers.call) |call| {
        const constructor_call = e.ir.get(call.implementation);
        const call_helper_name = try e.print("{s}_createForCall", .{class.cpp_class_name});
        try emitCppPlainClassCreateHelper(e, writer, class, call, call_helper_name);
        try writer.print(
            \\{s} Bindgen::Cpp::{s}(
            \\    Bun::Bindgen::CppCallContext& context,
            \\    const Bun::Bindgen::Cpp::{s}& args)
            \\{{
            \\    auto* global = &context.globalObject;
            \\    return {s}(global, defaultGlobalObject(global)->{s}Structure(), args);
            \\}}
            \\
        , .{ try cppImplementationReturnType(e, constructor_call), constructor_call.symbol, constructor_call.arguments, call_helper_name, class.cpp_class_name });
    }
}

fn emitCppPlainClassCreateHelper(
    e: *Emitter,
    writer: *Writer,
    class: *const ir.Class,
    initializers: ir.ClassInitializers.Entry,
    helper_name: []const u8,
) Error!void {
    try writer.print(
        \\static JSC::JSObject* {s}(
        \\    JSC::JSGlobalObject* global,
        \\    JSC::Structure* requestedStructure,
        \\    const Bun::Bindgen::Cpp::{s}& args)
        \\{{
        \\    auto& vm = JSC::getVM(global);
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\    auto* structureGlobal = defaultGlobalObject(requestedStructure->realm());
        \\    auto* structure = structureGlobal->{s}Structure();
        \\
    , .{ helper_name, e.ir.get(initializers.implementation).arguments, class.cpp_class_name });
    for (initializers.values, 0..) |*initializer, index| {
        try writer.print("    JSC::JSValue value_{d};\n", .{index});
        try emitCppPlainInitializerValue(e, writer, initializer, index);
        try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, nullptr);\n");
    }
    try writer.writeAll("    auto* object = JSC::JSFinalObject::create(vm, structure);\n");
    try writer.writeAll("    BINDGEN_RETURN_IF_EXCEPTION(throwScope, nullptr);\n");
    for (class.instance_properties, 0..) |_, index| try writer.print("    object->putDirectOffset(vm, {0d}, value_{0d});\n", .{index});
    try writer.writeAll(
        \\    if (requestedStructure != structure)
        \\        object->setPrototypeDirect(vm, requestedStructure->storedPrototype());
        \\    return object;
        \\}
        \\
    );
}

fn emitCppPlainInitializerValue(e: *Emitter, writer: *Writer, initializer: *const ir.PlainInitializer, index: usize) Error!void {
    switch (initializer.value) {
        .constant => |constant| switch (constant.value.operation) {
            .null_value, .any_null => try writer.print("    value_{d} = JSC::jsNull();\n", .{index}),
            .undefined_value, .any_undefined => try writer.print("    value_{d} = JSC::jsUndefined();\n", .{index}),
            .boolean, .integer, .number, .string, .enumeration, .empty_optional => {
                const source = try e.print("nativeConstant_{d}", .{index});
                try writer.print("    {s} {s} = ", .{ try e.cppType(e.ir.get(constant.materializer).source.native), source });
                try emitCppDefault(e, writer, constant.value);
                try writer.writeAll(";\n");
                try emitCppMaterializedValue(e, writer, constant.materializer, source, try e.print("value_{d}", .{index}), 4);
            },
        },
        .source => |source| if (source.access.optional) {
            try writer.print("    if (args.{s}.has_value()) {{\n", .{source.access.argument_name});
            try emitCppPlainInitializerSource(e, writer, source, index, 8);
            try writer.print("    }} else {{\n        value_{d} = JSC::jsUndefined();\n    }}\n", .{index});
        } else try emitCppPlainInitializerSource(e, writer, source, index, 4),
    }
}

fn emitCppPlainInitializerSource(e: *Emitter, writer: *Writer, source: ir.PlainInitializer.Source, index: usize, indent: usize) Error!void {
    const access = source.access;
    const expression = try e.print("args.{s}{s}{s}{s}", .{
        access.argument_name,
        if (access.optional) ".value()" else "",
        if (access.field_name != null) "." else "",
        access.field_name orelse "",
    });
    const target = try e.print("value_{d}", .{index});
    switch (source.conversion) {
        .bigint_quotient => |divisor| {
            try indented(writer, indent).print("{s} = bindingBigIntQuotient(global, {s}, uint64_t {{ {d}ULL }});\n", .{ target, expression, divisor });
        },
        .materialize => |materializer| try emitCppMaterializedValue(e, writer, materializer, expression, target, indent),
    }
}

// ─── engine wrappers ───

fn emitCppEngineWrapperBase(owned: *Writer, borrowed: *Writer, class_name: []const u8, native_type: []const u8) Error!void {
    try owned.print(
        \\    ASSERT(!WebCore::getCachedWrapper(globalObject->world(), impl.get()));
        \\    auto* implPtr = impl.ptr();
        \\    auto* wrapper = Bun::{0s}::create(globalObject->{0s}Structure(), globalObject, WTF::move(impl));
        \\    WebCore::cacheWrapper(globalObject->world(), implPtr, wrapper);
        \\    return wrapper;
        \\
    , .{class_name});
    try borrowed.print(
        \\    if (auto* wrapper = WebCore::getCachedWrapper(globalObject->world(), impl))
        \\        return wrapper;
        \\    return toJSNewlyCreated(lexicalGlobalObject, globalObject, Ref<{s}> {{ impl }});
        \\
    , .{native_type});
}

fn emitCppEngineToJSDefinitions(e: *Emitter, writer: *Writer, class: *const ir.Class, dispatch: ir.EngineWrapperDispatch) Error!void {
    const impl_type = try e.cppType(dispatch.native_type);
    var borrowed: Writer.Allocating = .init(e.arena);
    const borrowed_writer = &borrowed.writer;
    try writer.print("namespace {s} {{\n", .{cppTypeNamespace(impl_type)});
    try writer.print(
        \\JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject* lexicalGlobalObject, WebCore::JSDOMGlobalObject* globalObject, Ref<{s}>&& impl)
        \\{{
        \\
    , .{impl_type});
    switch (dispatch.operation) {
        .direct => try emitCppEngineWrapperBase(writer, borrowed_writer, class.cpp_class_name, impl_type),
        .tagged => |tagged| {
            try writer.print("    switch (impl->{s}()) {{\n", .{tagged.discriminator});
            try borrowed_writer.print("    switch (impl.{s}()) {{\n", .{tagged.discriminator});
            for (tagged.cases) |case| {
                for ([_]*Writer{ writer, borrowed_writer }) |body| try body.print("    case {s}: {{\n", .{case.tag});
                switch (case.operation) {
                    .derived => |native_type| {
                        const name = try e.cppType(native_type);
                        try writer.print("        return toJSNewlyCreated(lexicalGlobalObject, globalObject, unsafeRefDowncast<{s}>(WTF::move(impl)));\n", .{name});
                        try borrowed_writer.print("        return toJS(lexicalGlobalObject, globalObject, static_cast<{s}&>(impl));\n", .{name});
                    },
                    .global_scope => |native_type| {
                        const name = try e.cppType(native_type);
                        try writer.print("        JSC::JSGlobalObject* targetGlobal = static_cast<{s}&>(impl.get()).globalObject();\n", .{name});
                        try borrowed_writer.print("        JSC::JSGlobalObject* targetGlobal = static_cast<{s}&>(impl).globalObject();\n", .{name});
                        for ([_]*Writer{ writer, borrowed_writer }) |body| try body.writeAll("        return targetGlobal ? JSC::JSValue(targetGlobal) : JSC::jsNull();\n");
                    },
                    .base => try emitCppEngineWrapperBase(writer, borrowed_writer, class.cpp_class_name, impl_type),
                }
                for ([_]*Writer{ writer, borrowed_writer }) |body| try body.writeAll("    }\n");
            }
            for ([_]*Writer{ writer, borrowed_writer }) |body| try body.writeAll("    default:\n        RELEASE_ASSERT_NOT_REACHED();\n    }\n");
        },
    }
    try writer.print(
        \\}}
        \\
        \\JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, WebCore::JSDOMGlobalObject* globalObject, {s}& impl)
        \\{{
        \\
    , .{impl_type});
    try writer.writeAll(borrowed.written());
    try writer.writeAll("}\n}\n");
}

// ─── promise reaction contexts ───

fn emitCppPromiseReactionContextDeclaration(e: *Emitter, writer: *Writer, context: ir.PromiseReactionId) Error!void {
    const reaction = e.ir.get(context);
    const name = reaction.context_name;
    const owner_type = try e.cppType(reaction.owner_type);
    try writer.print(
        \\class {0s} final : public JSC::JSDestructibleObject {{
        \\public:
        \\    using Base = JSC::JSDestructibleObject;
        \\    static constexpr unsigned StructureFlags = Base::StructureFlags;
        \\    DECLARE_INFO;
        \\
        \\    static {0s}* create(JSC::VM&, JSC::Structure*);
        \\    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
        \\    {{
        \\        return JSC::Structure::create(vm, globalObject, JSC::jsNull(), JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        \\    }}
        \\    static void destroy(JSC::JSCell*);
        \\
        \\
    , .{name});
    try emitCppSubspaceFor(writer, name);
    try writer.print(
        \\
        \\    void adopt({1s} owner) {{ RELEASE_ASSERT(owner && !m_owner); m_owner = owner; }}
        \\    {1s} take() {{ return std::exchange(m_owner, nullptr); }}
        \\
        \\private:
        \\    {0s}(JSC::VM& vm, JSC::Structure* structure)
        \\        : Base(vm, structure)
        \\    {{
        \\    }}
        \\    ~{0s}();
        \\
        \\    {1s} m_owner {{ nullptr }};
        \\}};
        \\
    , .{ name, owner_type });
}

fn emitCppPromiseReactionContextDefinition(e: *Emitter, writer: *Writer, context: ir.PromiseReactionId) Error!void {
    const reaction = e.ir.get(context);
    const name = reaction.context_name;
    const owner_type = try e.cppType(reaction.owner_type);
    const create = e.ir.cpp_engine_implementations[reaction.create.index];
    const adopt = e.ir.cpp_engine_implementations[reaction.adopt.index];
    const attach = e.ir.cpp_engine_implementations[reaction.attach.index];
    const take = e.ir.cpp_engine_implementations[reaction.take.index];
    const destroy = e.ir.cpp_native_exports[reaction.destroy.index].?.entry.signature;
    try writer.print(
        \\namespace Bun {{
        \\
        \\const JSC::ClassInfo {0s}::s_info = {{ "{0s}"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE({0s}) }};
        \\
        \\{0s}* {0s}::create(JSC::VM& vm, JSC::Structure* structure)
        \\{{
        \\    auto* context = new (NotNull, JSC::allocateCell<{0s}>(vm)) {0s}(vm, structure);
        \\    context->finishCreation(vm);
        \\    return context;
        \\}}
        \\
        \\{0s}::~{0s}()
        \\{{
        \\    if (m_owner)
        \\        Bindgen::ZigExports::{2s}(m_owner);
        \\}}
        \\
        \\void {0s}::destroy(JSC::JSCell* cell)
        \\{{
        \\    static_cast<{0s}*>(cell)->~{0s}();
        \\}}
        \\
        \\}}
        \\
        \\namespace Bun::Bindgen::Engine {{
        \\
        \\JSC::JSValue {3s}(EngineCallContext& context, const {4s}&)
        \\{{
        \\    auto* globalObject = defaultGlobalObject(&context.globalObject);
        \\    auto& vm = JSC::getVM(globalObject);
        \\    return Bun::{0s}::create(vm, globalObject->{0s}Structure());
        \\}}
        \\
        \\std::optional<{1s}> {5s}(EngineCallContext&, const {6s}& args)
        \\{{
        \\    auto* reactionContext = dynamicDowncast<Bun::{0s}>(args.context);
        \\    RELEASE_ASSERT(reactionContext);
        \\    if (auto* owner = reactionContext->take())
        \\        return owner;
        \\    return std::nullopt;
        \\}}
        \\
        \\}}
        \\
    , .{
        name,
        owner_type,
        destroy.symbol,
        create.signature.symbol,
        create.arguments.name,
        take.signature.symbol,
        take.arguments.name,
    });
    try writer.print(
        \\namespace Bun::Bindgen::Engine {{
        \\
        \\void {0s}(EngineCallContext&, const {1s}& args)
        \\{{
        \\    auto* reactionContext = dynamicDowncast<Bun::{2s}>(args.context);
        \\    RELEASE_ASSERT(reactionContext);
        \\    reactionContext->adopt(args.owner);
        \\}}
        \\
        \\}}
        \\
    , .{ adopt.signature.symbol, adopt.arguments.name, name });
    try writer.print(
        \\namespace Bun::Bindgen::Engine {{
        \\
        \\void {0s}(EngineCallContext& context, const {1s}& args)
        \\{{
        \\    auto* globalObject = defaultGlobalObject(&context.globalObject);
        \\    auto* promise = dynamicDowncast<JSC::JSPromise>(args.promise);
        \\    auto* reactionContext = dynamicDowncast<Bun::{2s}>(args.context);
        \\    RELEASE_ASSERT(promise);
        \\    RELEASE_ASSERT(reactionContext);
        \\    attachPromiseReaction(promise, globalObject, reactionContext, args.resolve, args.reject);
        \\}}
        \\
        \\}}
        \\
    , .{ attach.signature.symbol, attach.arguments.name, name });
}

// ─── native cells ───

fn cppNativeCellTraits(e: *Emitter, class: *const ir.Class) Allocator.Error![]const u8 {
    return e.print("{s}_Traits", .{class.cpp_class_name});
}

fn cppNativeCellBase(e: *Emitter, class: *const ir.Class) Allocator.Error![]const u8 {
    return e.print("Bun::Bindgen::NativeCell<{s}, {s}{s}{s}>", .{
        class.cpp_class_name,
        try cppNativeCellTraits(e, class),
        if (class.parent != null) ", " else "",
        if (class.parent) |parent| e.class(parent).cpp_class_name else "",
    });
}

fn emitCppNativeCellTraits(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    try writer.print(
        \\struct {s} : Bun::Bindgen::NativeCellTraits {{
        \\    using Native = {s};
        \\    static constexpr auto destroyNative = &{s};
        \\    static constexpr auto releaseNativeOnVM = &{s};
        \\
    , .{
        try cppNativeCellTraits(e, class),
        try cppNativeClassOpaqueType(e, class),
        class.destroy_native_symbol,
        class.release_native_on_vm_symbol,
    });
    switch (class.runtime_plan.identity) {
        .per_realm_registry => |symbol| try writer.print(
            \\    static constexpr auto identity = Bun::Bindgen::NativeCellIdentity::{s};
            \\    static constexpr auto nativeGeneration = &{s};
            \\
        , .{
            if (class.runtime_plan.ownership.isNativeShared()) "PerRealmShared" else "PerRealmUnique",
            symbol,
        }),
        .plain_value, .fresh_wrapper, .engine_constructor_only, .engine_wrapper_cache => {},
    }
    if (class.upcast) |upcast| try writer.print("    static constexpr auto upcast = &{s};\n", .{upcast.symbol});
    if (class.memory_usage) |memory| {
        try writer.print(
            \\    static constexpr auto memoryUsage = &{s};
            \\    static constexpr auto memoryAffinity = Bun::Bindgen::NativeMemoryAffinity::{s};
            \\
        , .{
            memory.symbol,
            switch (memory.affinity) {
                .any => "Any",
                .vm => "VM",
            },
        });
    }
    if (class.pending_activity) |symbol| try writer.print("    static constexpr auto pendingActivity = &{s};\n", .{symbol});
    if (class.runtime_plan.construction.wrapper_created) |symbol| try writer.print("    static constexpr auto wrapperCreated = &{s};\n", .{symbol});
    switch (class.runtime_plan.construction.external_initialization) {
        .native_subclass, .root_native_subclass => |symbol| try writer.print("    static constexpr auto initializeExternalNative = &{s};\n", .{symbol}),
        .none => {},
    }
    try writer.print(
        \\    static auto& clientSubspace(auto& spaces) {{ return spaces.m_clientSubspaceFor{0s}; }}
        \\    static auto& subspace(auto& spaces) {{ return spaces.m_subspaceFor{0s}; }}
        \\}};
        \\
        \\
    , .{class.cpp_class_name});
}

fn cppConstructorCallSymbol(e: *const Emitter, call: @FieldType(ir.CppClassConstructor, "call")) []const u8 {
    return switch (call) {
        .function => |id| e.function(id).host_symbol,
        .host => |host| host.host.symbol,
    };
}

fn emitCppHostDeclaration(writer: *Writer, host: ir.CppHost) Error!void {
    switch (host.signature) {
        .frame => |frame| try writer.print("{s}JSC::EncodedJSValue SYSV_ABI {s}(JSC::JSGlobalObject*, JSC::CallFrame*{s}){s};\n", .{
            if (frame.linkage == .external_noexcept) "extern \"C\" " else "static ", host.symbol, if (frame.overload_inputs) ", std::span<const BindingConversionInput>" else "", if (frame.linkage == .internal) "" else " noexcept",
        }),
        .getter => try writer.print("static JSC_DECLARE_CUSTOM_GETTER({s});\n", .{host.symbol}),
        .setter => try writer.print("static JSC_DECLARE_CUSTOM_SETTER({s});\n", .{host.symbol}),
    }
}

fn emitCppHostDeclarations(e: *Emitter, writer: *Writer, function: *const ir.CppFunction) Error!void {
    switch (function.*) {
        .builtin => {},
        .overload => |dispatch| {
            try emitCppHostDeclaration(writer, dispatch.host);
            for (dispatch.cases) |case| try emitCppHostDeclarations(e, writer, &e.ir.cpp_overload_cases[case.declaration.index].?);
        },
        .call => |body| {
            try emitCppHostDeclaration(writer, body.host);
            if (body.writable) |setter| try emitCppHostDeclaration(writer, setter.host);
        },
    }
}

fn emitCppClassDeclaration(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    switch (class.representation) {
        .engine => |engine| try emitCppEngineClassDeclaration(e, writer, class, engine),
        .native => {
            const base = try cppNativeCellBase(e, class);
            try emitCppNativeCellTraits(e, writer, class);
            try writer.print(
                \\class {0s}{1s} : public {2s} {{
                \\public:
                \\    using Base = {2s};
                \\    DECLARE_INFO;
                \\    DECLARE_VISIT_CHILDREN;
                \\
                \\
            , .{ class.cpp_class_name, if (e.ir.class_relations[class.id.index].emission.has_children) "" else " final", base });
            for (class.slots) |slot| {
                if (slot.storage == .instance) try emitCppSlotAccessors(writer, slot.slot_name);
            }
            try writer.writeAll(
                \\protected:
                \\    friend Base;
                \\    using Base::Base;
                \\
            );
            if (class.runtime_plan.construction.external_initialization == .root_native_subclass) {
                try writer.print("    void moveInstanceSlotsFrom({s}&, JSC::VM&);\n", .{class.cpp_class_name});
            }
            for (class.slots) |slot| {
                if (slot.storage == .instance) try writer.print("    JSC::WriteBarrier<JSC::Unknown> m_{s};\n", .{slot.slot_name});
            }
            try writer.writeAll("};\n\n");
        },
        .plain => {},
    }
}

fn emitCppClass(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    const plain = class.representation == .plain;
    const constructor = e.function(class.constructor);
    const constructor_plan = e.ir.cpp_class_constructors[class.id.index];
    const prototype_table = try e.print("{s}TableValues", .{class.cpp_prototype_name});
    const constructor_table = try e.print("{s}TableValues", .{class.cpp_constructor_name});

    try writer.writeAll("namespace Bun {\n\nusing namespace JSC;\nusing namespace WebCore;\n\n");
    if (constructor_plan) |plan| {
        switch (plan.call) {
            .function => |id| try emitCppHostDeclarations(e, writer, &e.ir.cpp_functions[id.index].?),
            .host => |host| try emitCppHostDeclaration(writer, host.host),
        }
        try emitCppHostDeclarations(e, writer, e.ir.functionCpp(constructor));
    }
    for (class.declarations) |member_id| {
        const member = e.function(member_id);
        if (member.exposed) try emitCppHostDeclarations(e, writer, e.ir.functionCpp(member));
    }
    for (e.ir.cpp_class_slot_accessors[class.id.index]) |maybe| {
        const accessors = maybe orelse continue;
        try emitCppHostDeclaration(writer, accessors.getter.host);
        if (accessors.setter) |setter| try emitCppHostDeclaration(writer, setter.host);
    }
    try writer.writeByte('\n');
    switch (e.ir.class_relations[class.id.index].emission.declaration) {
        .source => try emitCppClassDeclaration(e, writer, class),
        .none, .bindings_header, .engine_header => {},
    }

    const prototype_base = if (plain) "Bun::Bindgen::PlainClassPrototype" else "JSC::JSNonFinalObject";
    try writer.print(
        \\class {0s} final : public {1s} {{
        \\public:
        \\    using Base = {1s};
        \\    static constexpr unsigned StructureFlags = {2s};
        \\    DECLARE_INFO;
        \\    template<typename, JSC::SubspaceAccess> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm) {{ return &vm.plainObjectSpace(); }}
        \\    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue);
        \\    static {0s}* create(JSC::VM&, JSC::Structure*, JSC::JSGlobalObject*);
        \\
        \\private:
        \\    {0s}(JSC::VM& vm, JSC::Structure* structure) : Base(vm, structure) {{ }}
        \\    void finishCreation(JSC::VM&, JSC::JSGlobalObject*);
        \\}};
        \\
    , .{
        class.cpp_prototype_name,
        prototype_base,
        if (class.immutable_prototype) "Base::StructureFlags | JSC::IsImmutablePrototypeExoticObject" else "Base::StructureFlags",
    });

    if (constructor_plan) |plan| {
        try writer.print(
            \\class {0s} final : public JSC::InternalFunction {{
            \\public:
            \\    using Base = JSC::InternalFunction;
            \\    static constexpr unsigned StructureFlags = Base::StructureFlags;
            \\    DECLARE_INFO;
            \\    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue);
            \\    static {0s}* create(JSC::VM&, JSC::Structure*, JSC::JSObject*, JSC::JSGlobalObject*);
            \\
        , .{class.cpp_constructor_name});
        if (plan.hasTracedState()) {
            try emitCppSubspaceFor(writer, class.cpp_constructor_name);
        } else {
            try writer.writeAll("    template<typename, JSC::SubspaceAccess> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm) { return &vm.internalFunctionSpace(); }\n");
        }
        if (plan.hasTracedState()) try writer.writeAll("    DECLARE_VISIT_CHILDREN;\n");
        if (plan.builtin != null) {
            try writer.writeAll("    JSC::JSFunction* builtinConstructorCall() const { return bindingBuiltinCall_.get(); }\n");
        }
        for (plan.slots) |index| try emitCppSlotAccessors(writer, class.slots[index].slot_name);
        try writer.print(
            \\private:
            \\    {s}(JSC::VM& vm, JSC::Structure* structure) : Base(vm, structure, {s}, {s}) {{ }}
            \\    void finishCreation(JSC::VM&, JSC::JSObject*, JSC::JSGlobalObject*);
            \\
        , .{ class.cpp_constructor_name, cppConstructorCallSymbol(e, plan.call), constructor.host_symbol });
        if (plan.builtin != null) try writer.writeAll("    JSC::WriteBarrier<JSC::JSFunction> bindingBuiltinCall_;\n");
        for (plan.slots) |index| try writer.print("    JSC::WriteBarrier<JSC::Unknown> m_{s};\n", .{class.slots[index].slot_name});
        try writer.writeAll("};\n\n");
    }

    try emitCppClassDefinitions(e, writer, class, prototype_table, constructor_table);
    for (class.declarations) |member_id| {
        if (e.ir.cpp_function_factories[member_id.index]) |factory| try emitFunctionFactory(e, writer, factory);
    }
    if (class.structured_clone) |clone| try emitCppStructuredCloneSerializeAdapter(e, writer, class, e.ir.get(clone).*);
    try writer.writeAll("} // namespace Bun\n\n");
    if (e.ir.class_relations[class.id.index].engine_wrapper_dispatch) |dispatch| try emitCppEngineToJSDefinitions(e, writer, class, dispatch);
}

fn structuredCloneSerializeAdapterName(e: *Emitter, class: *const ir.Class) Allocator.Error![]const u8 {
    return e.print("{s}_structuredCloneSerialize", .{class.cpp_class_name});
}

// ─── structured clone ───

fn emitCppStructuredCloneSerializeAdapter(e: *Emitter, writer: *Writer, class: *const ir.Class, clone: ir.StructuredClonePlan) Error!void {
    try writer.print(
        \\static void {0s}(void* implementation, JSC::JSGlobalObject* global, WebCore::CloneSerializer* serializer)
        \\{{
        \\    RELEASE_ASSERT(implementation);
        \\    RELEASE_ASSERT(global);
        \\    RELEASE_ASSERT(serializer);
        \\    auto* object = static_cast<{1s}*>(implementation);
        \\    auto& vm = JSC::getVM(global);
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\    if (!object->native()) {{
        \\        JSC::throwTypeError(global, throwScope, "{2s} is detached"_s);
        \\        return;
        \\    }}
        \\    {1s}::NativeBorrow nativeBorrow(*object);
        \\    BindCallContext context {{
        \\        .global_object = reinterpret_cast<BindGlobalObjectHandle*>(global),
        \\        .promise = nullptr,
        \\        .native_receiver = reinterpret_cast<BindNativeHandle*>(nativeBorrow.get()),
        \\        .caller_frame = nullptr,
        \\        .deferred_conversions = nullptr,
        \\        .call_id = takeBindingCallId(),
        \\    }};
        \\
    , .{ try structuredCloneSerializeAdapterName(e, class), class.cpp_class_name, class.class_name });
    switch (clone.serialization) {
        .bytes => try writer.print(
            \\    auto status = {s}(&context, reinterpret_cast<BindNativeHandle*>(nativeBorrow.get()), reinterpret_cast<BindCloneSerializerHandle*>(serializer));
            \\    RELEASE_ASSERT(status == BIND_STATUS_OK || status == BIND_STATUS_PENDING_EXCEPTION || status == BIND_STATUS_OUT_OF_MEMORY);
            \\    if (bindingExceptionAfterDispatch(throwScope, status))
            \\        return;
            \\    if (status == BIND_STATUS_OUT_OF_MEMORY)
            \\        Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
            \\
        , .{clone.serialize_symbol}),
        .shared => |shared| {
            const handle = try e.wireSpelling(shared.handle);
            try writer.print(
                \\    {s}* shared = nullptr;
                \\    auto status = {s}(&context, reinterpret_cast<BindNativeHandle*>(nativeBorrow.get()), &shared);
                \\    RELEASE_ASSERT(status == BIND_STATUS_OK || status == BIND_STATUS_PENDING_EXCEPTION || status == BIND_STATUS_OUT_OF_MEMORY);
                \\    if (bindingExceptionAfterDispatch(throwScope, status)) {{
                \\        if (shared)
                \\            {s}(shared);
                \\        return;
                \\    }}
                \\    if (status == BIND_STATUS_OUT_OF_MEMORY) {{
                \\        RELEASE_ASSERT(!shared);
                \\        Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
                \\        return;
                \\    }}
                \\    RELEASE_ASSERT(status == BIND_STATUS_OK && shared);
                \\    Bun::Bindgen::SharedCloneResource resource({d}, shared, +[](void* value) noexcept {{
                \\        {s}(static_cast<{s}*>(value));
                \\    }});
                \\    if (!WebCore::SerializedScriptValue::writeSharedResourceForBindgen(serializer, WTF::move(resource)))
                \\        Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
                \\
            , .{ handle, clone.serialize_symbol, shared.release_symbol, clone.tag, shared.release_symbol, handle });
        },
    }
    try writer.writeAll("}\n");
}

fn emitCppStructuredCloneRegistry(e: *Emitter, writer: *Writer) Error!void {
    try writer.writeAll(
        \\bool Bun::bindgenStructuredCloneSerialize(JSC::JSValue value, WebCore::StructuredCloneableSerialize& result)
        \\{
        \\
    );
    for (e.ir.structured_clone_modules) |module| {
        try writer.print("    if (Bun::bunBindgenStructuredCloneSerializeModule{d}(value, result))\n        return true;\n", .{module.index});
    }
    try writer.writeAll(
        \\    return false;
        \\}
        \\
        \\bool Bun::bindgenStructuredCloneDeserialize(uint8_t tag, JSC::JSGlobalObject* global, const uint8_t*& ptr, const uint8_t* end, JSC::EncodedJSValue& result, WebCore::CloneDeserializer* deserializer)
        \\{
        \\    switch (tag) {
        \\
    );
    for (e.ir.structured_clone_modules) |module| {
        for (e.ir.get(module).structured_clones) |id| try writer.print("    case {d}:\n", .{e.ir.get(id).tag});
        try writer.print(
            \\    {{
            \\        result = {{}};
            \\        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
            \\        RETURN_IF_EXCEPTION(scope, true);
            \\        const bool handled = Bun::bunBindgenStructuredCloneDeserializeModule{d}(tag, global, ptr, end, result, deserializer);
            \\        if (scope.exception()) {{
            \\            result = {{}};
            \\            return true;
            \\        }}
            \\        RELEASE_ASSERT(handled);
            \\        return true;
            \\    }}
            \\
        , .{module.index});
    }
    try writer.writeAll(
        \\    default:
        \\        return false;
        \\    }
        \\}
        \\
    );
}

fn emitCppStructuredCloneModule(e: *Emitter, writer: *Writer, module_index: usize) Error!void {
    const module = e.ir.modules[module_index];
    if (module.structured_clones.len == 0) return;
    try writer.print(
        \\bool Bun::bunBindgenStructuredCloneSerializeModule{d}(JSC::JSValue value, WebCore::StructuredCloneableSerialize& result)
        \\{{
        \\
    , .{module_index});
    for (module.structured_clones) |id| {
        const clone = e.ir.get(id);
        const class = e.class(clone.class);
        try writer.print(
            \\    if (auto* object = dynamicDowncast<Bun::{s}>(value)) {{
            \\        result = {{
            \\            .function = Bun::{s},
            \\            .tag = {d},
            \\            .impl = object,
            \\            .isForTransfer = {s},
            \\            .isForStorage = {s},
            \\            .unsupportedContext = WebCore::StructuredCloneableSerialize::UnsupportedContext::{s},
            \\        }};
            \\        return true;
            \\    }}
            \\
        , .{
            class.cpp_class_name,
            try structuredCloneSerializeAdapterName(e, class),
            clone.tag,
            cppBoolean(clone.transferable),
            cppBoolean(clone.storable),
            switch (clone.unsupported_context) {
                .reject => "Reject",
                .empty_object => "EmptyObject",
            },
        });
    }
    try writer.writeAll(
        \\    return false;
        \\}
        \\
    );
    try writer.print(
        \\bool Bun::bunBindgenStructuredCloneDeserializeModule{d}(uint8_t tag, JSC::JSGlobalObject* global, const uint8_t*& ptr, const uint8_t* end, JSC::EncodedJSValue& result, WebCore::CloneDeserializer* deserializer)
        \\{{
        \\    RELEASE_ASSERT(global);
        \\    RELEASE_ASSERT(ptr);
        \\    RELEASE_ASSERT(end);
        \\    auto& vm = JSC::getVM(global);
        \\    auto throwScope = DECLARE_THROW_SCOPE(vm);
        \\
    , .{module_index});
    for (module.structured_clones) |id| {
        const clone = e.ir.get(id);
        const class = e.class(clone.class);
        try emitCppCloneDeserialize(e, writer, class, clone.*);
    }
    try writer.writeAll(
        \\    return false;
        \\}
        \\
    );
}

fn emitCppCloneDeserialize(e: *Emitter, writer: *Writer, class: *const ir.Class, clone: ir.StructuredClonePlan) Error!void {
    try writer.print(
        \\    if (tag == {d}) {{
        \\        result = {{}};
        \\
    , .{clone.tag});
    switch (clone.serialization) {
        .bytes => try writer.writeAll("        BindCloneReader reader { ptr, end };\n"),
        .shared => try writer.writeAll(
            \\        auto* shared = WebCore::SerializedScriptValue::sharedResourceForBindgen(deserializer, tag, ptr, end);
            \\        if (!shared)
            \\            return true;
            \\
        ),
    }
    try writer.writeAll(
        \\        BindCallContext context {
        \\            .global_object = reinterpret_cast<BindGlobalObjectHandle*>(global),
        \\            .promise = nullptr,
        \\            .native_receiver = nullptr,
        \\            .caller_frame = nullptr,
        \\            .deferred_conversions = nullptr,
        \\            .call_id = takeBindingCallId(),
        \\        };
        \\        BindNativeHandle* native = nullptr;
        \\
    );
    const input = switch (clone.serialization) {
        .bytes => "&reader",
        .shared => |shared| try e.print("static_cast<{s}*>(shared)", .{try e.wireSpelling(shared.handle)}),
    };
    try writer.print("        auto status = {s}(&context, {s}, &native);\n", .{ clone.deserialize_symbol, input });
    if (clone.serialization == .shared) try writer.writeAll("        RELEASE_ASSERT(status == BIND_STATUS_OK || status == BIND_STATUS_PENDING_EXCEPTION || status == BIND_STATUS_OUT_OF_MEMORY);\n");
    try writer.print(
        \\        if (bindingExceptionAfterDispatch(throwScope, status)) {{
        \\            if (native)
        \\                {s}(reinterpret_cast<BindVirtualMachineHandle*>(WebCore::clientData(vm)->bunVM), native);
        \\            return true;
        \\        }}
        \\        switch (status) {{
        \\        case BIND_STATUS_OK: {{
        \\            RELEASE_ASSERT(native);
        \\
    , .{class.release_native_on_vm_symbol});
    if (clone.serialization == .bytes) try writer.writeAll("            RELEASE_ASSERT(reader.ptr >= ptr && reader.ptr <= end);\n");
    try writer.print(
        \\            auto wrapped = {s}_value(global, native);
        \\            RETURN_IF_EXCEPTION(throwScope, true);
        \\            RELEASE_ASSERT(wrapped);
        \\
    , .{class.wrap_native_symbol});
    if (clone.serialization == .bytes) try writer.writeAll("            ptr = reader.ptr;\n");
    try writer.writeAll(
        \\            result = JSC::JSValue::encode(wrapped);
        \\            return true;
        \\        }
        \\        case BIND_STATUS_PENDING_EXCEPTION:
        \\            RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("structured clone binding returned pending_exception without a pending exception");
        \\        case BIND_STATUS_OUT_OF_MEMORY:
        \\            RELEASE_ASSERT(!native);
        \\            Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
        \\            return true;
        \\
    );
    if (clone.serialization == .bytes) try writer.writeAll(
        \\        case BIND_STATUS_FAILED:
        \\            RELEASE_ASSERT(!native);
        \\            return true;
        \\
    );
    try writer.writeAll(
        \\        default:
        \\            RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("structured clone binding returned an invalid status");
        \\        }
        \\    }
        \\
    );
}

// ─── class definitions ───

fn emitCppClassDefinitions(e: *Emitter, writer: *Writer, class: *const ir.Class, prototype_table: []const u8, constructor_table: []const u8) Error!void {
    switch (class.representation) {
        .engine => |engine| {
            try emitCppEngineClassDefinitions(e, writer, class, engine);
            try emitCppClassVisitChildren(writer, class);
            return emitCppSharedClassDefinitions(e, writer, class, prototype_table, constructor_table);
        },
        .native => try emitCppClassInfo(writer, class.cpp_class_name, class.display_name),
        .plain => {},
    }
    try emitCppClassInfo(writer, class.cpp_prototype_name, class.display_name);
    if (e.function(class.constructor).exposed) try emitCppClassInfo(writer, class.cpp_constructor_name, class.display_name);
    try writer.writeByte('\n');
    if (class.representation == .plain) {
        try emitCppPlainClassCreator(e, writer, class);
    } else {
        if (class.runtime_plan.construction.external_initialization == .root_native_subclass) try emitCppClassSlotTransfer(writer, class);
        try emitCppClassVisitChildren(writer, class);
    }
    try emitCppSharedClassDefinitions(e, writer, class, prototype_table, constructor_table);
}

fn emitCppClassInfo(writer: *Writer, cpp_name: []const u8, display_name: []const u8) Error!void {
    try writer.print("const JSC::ClassInfo {0s}::s_info = {{ \"{1s}\"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE({0s}) }};\n", .{ cpp_name, display_name });
}

fn emitCppClassSlotTransfer(writer: *Writer, class: *const ir.Class) Error!void {
    try writer.print(
        \\void {0s}::moveInstanceSlotsFrom({0s}& source, JSC::VM& vm)
        \\{{
        \\    UNUSED_PARAM(source);
        \\    UNUSED_PARAM(vm);
        \\
    , .{class.cpp_class_name});
    for (class.slots) |slot| {
        if (slot.storage != .instance) continue;
        try writer.print(
            \\    if (auto value = source.raw_slot_{0s}(); !value.isEmpty()) {{
            \\        set_slot_{0s}(vm, value);
            \\        source.clear_slot_{0s}();
            \\    }}
            \\
        , .{slot.slot_name});
    }
    try writer.writeAll("}\n\n");
}

fn emitCppClassVisitChildren(writer: *Writer, class: *const ir.Class) Error!void {
    try writer.print(
        \\template<typename Visitor>
        \\void {0s}::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
        \\{{
        \\    auto* object = uncheckedDowncast<{0s}>(cell);
        \\    ASSERT_GC_OBJECT_INHERITS(object, info());
        \\    Base::visitChildren(object, visitor);
        \\
    , .{class.cpp_class_name});
    if (class.runtime_plan.tracing.reports_any_thread_native_memory) try writer.writeAll("    object->visitNativeMemory(visitor);\n");
    if (class.runtime_plan.tracing.mode == .engine_slots_and_additional_children) try writer.writeAll("    object->visitAdditionalChildren(visitor);\n");
    for (class.slots) |slot| {
        if (slot.storage == .instance) try writer.print("    visitor.append(object->m_{s});\n", .{slot.slot_name});
    }
    try writer.print(
        \\}}
        \\DEFINE_VISIT_CHILDREN({s});
        \\
    , .{class.cpp_class_name});
}

fn emitCppSharedClassDefinitions(e: *Emitter, writer: *Writer, class: *const ir.Class, prototype_table: []const u8, constructor_table: []const u8) Error!void {
    const constructor = e.function(class.constructor);
    const constructor_plan = e.ir.cpp_class_constructors[class.id.index];
    if (constructor_plan) |plan| {
        if (plan.hasTracedState()) {
            try writer.print(
                \\template<typename Visitor>
                \\void {0s}::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
                \\{{
                \\    auto* object = uncheckedDowncast<{0s}>(cell);
                \\    ASSERT_GC_OBJECT_INHERITS(object, info());
                \\    Base::visitChildren(object, visitor);
                \\
            , .{class.cpp_constructor_name});
            if (plan.builtin != null) try writer.writeAll("    visitor.append(object->bindingBuiltinCall_);\n");
            for (plan.slots) |index| try writer.print("    visitor.append(object->m_{s});\n", .{class.slots[index].slot_name});
            try writer.print(
                \\}}
                \\DEFINE_VISIT_CHILDREN({s});
                \\
            , .{class.cpp_constructor_name});
        }
    }

    try emitCppClassHosts(e, writer, class);
    const properties = e.ir.class_relations[class.id.index].properties;
    try emitCppClassTable(e, writer, prototype_table, properties.prototype.table);
    try emitCppClassTable(e, writer, constructor_table, properties.constructor.table);

    try writer.print(
        \\JSC::Structure* {0s}::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global, JSC::JSValue prototype)
        \\{{
        \\    auto* structure = JSC::Structure::create(vm, global, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        \\    structure->setMayBePrototype(true);
        \\    return structure;
        \\}}
        \\
        \\{0s}* {0s}::create(JSC::VM& vm, JSC::Structure* structure, JSC::JSGlobalObject* global)
        \\{{
        \\    auto* object = new (NotNull, JSC::allocateCell<{0s}>(vm)) {0s}(vm, structure);
        \\    object->finishCreation(vm, global);
        \\    return object;
        \\}}
        \\
        \\void {0s}::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* global)
        \\{{
        \\    Base::finishCreation(vm);
        \\    RELEASE_ASSERT(global);
        \\
    , .{class.cpp_prototype_name});
    if (properties.prototype.table.len != 0) {
        try writer.print("    reifyStaticProperties(vm, {s}::info(), {s}, *this);\n", .{
            if (class.representation == .plain) class.cpp_prototype_name else class.cpp_class_name,
            prototype_table,
        });
    }
    try emitCppClassInstallations(e, writer, properties.prototype.installations);
    try writer.writeAll("    ASSERT(inherits(info()));\n}\n\n");

    if (constructor_plan) |plan| {
        try writer.print(
            \\JSC::Structure* {0s}::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global, JSC::JSValue prototype)
            \\{{
            \\    return JSC::Structure::create(vm, global, prototype, JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
            \\}}
            \\
            \\{0s}* {0s}::create(JSC::VM& vm, JSC::Structure* structure, JSC::JSObject* prototype, JSC::JSGlobalObject* global)
            \\{{
            \\    auto* object = new (NotNull, JSC::allocateCell<{0s}>(vm)) {0s}(vm, structure);
            \\    object->finishCreation(vm, prototype, global);
            \\    return object;
            \\}}
            \\
            \\void {0s}::finishCreation(JSC::VM& vm, JSC::JSObject* prototype, JSC::JSGlobalObject* global)
            \\{{
            \\    Base::finishCreation(vm, {1d}, "{2s}"_s, PropertyAdditionMode::WithoutStructureTransition);
            \\    RELEASE_ASSERT(global);
            \\    putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly);
            \\
        , .{ class.cpp_constructor_name, constructor.js_length, class.display_name });
        if (plan.builtin) |builtin| try writer.print("    bindingBuiltinCall_.set(vm, this, JSC::JSFunction::create(vm, global, WebCore::{s}(vm), global));\n", .{builtin});
        if (properties.constructor.table.len != 0) try writer.print("    reifyStaticProperties(vm, {s}::info(), {s}, *this);\n", .{ class.cpp_constructor_name, constructor_table });
        try emitCppClassInstallations(e, writer, properties.constructor.installations);
        try writer.writeAll("    ASSERT(inherits(info()));\n}\n\n");
    }

    try emitCppClassInitialization(e, writer, class);
}

fn emitCppFunctionLazyConverters(e: *Emitter, writer: *Writer, function: *const ir.CppFunction) Error!void {
    switch (function.*) {
        .builtin => {},
        .overload => |dispatch| for (dispatch.cases) |case| try emitCppFunctionLazyConverters(e, writer, &e.ir.cpp_overload_cases[case.declaration.index].?),
        .call => |body| try emitCppLazyConverters(e, writer, body.entry),
    }
}

fn emitCppClassHosts(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    const constructor = e.function(class.constructor);
    const constructor_plan = e.ir.cpp_class_constructors[class.id.index];
    if (constructor_plan) |plan| {
        try emitCppFunctionLazyConverters(e, writer, e.ir.functionCpp(constructor));
        switch (plan.call) {
            .function => |id| try emitCppFunctionLazyConverters(e, writer, &e.ir.cpp_functions[id.index].?),
            .host => {},
        }
    }
    for (class.declarations) |member_id| {
        const member = e.function(member_id);
        if (member.exposed) try emitCppFunctionLazyConverters(e, writer, e.ir.functionCpp(member));
    }
    if (constructor_plan) |plan| {
        try emitCppFunctionCompletions(e, writer, constructor);
        switch (plan.call) {
            .function => |id| {
                const constructor_call = e.function(id);
                try emitCppFunctionCompletions(e, writer, constructor_call);
                try emitCppHostFunction(e, writer, &e.ir.cpp_functions[id.index].?);
            },
            .host => |host| try emitCppHostCall(e, writer, host),
        }
        try emitCppHostFunction(e, writer, e.ir.functionCpp(constructor));
    }

    for (class.declarations) |member_id| {
        const member = e.function(member_id);
        if (!member.exposed or member.backend == .builtin) continue;
        try emitCppFunctionCompletions(e, writer, member);
        try emitCppHostFunction(e, writer, e.ir.functionCpp(member));
    }

    for (e.ir.cpp_class_slot_accessors[class.id.index]) |maybe| {
        const accessors = maybe orelse continue;
        try emitCppHostCall(e, writer, accessors.getter);
        if (accessors.setter) |setter| try emitCppHostCall(e, writer, setter);
    }
}

fn emitCppCachedSlotSetterConversion(e: *Emitter, writer: *Writer, conversion: ir.CppCachedSlotWrite) Error!void {
    const input = e.ir.get(conversion.input);
    try writer.writeAll("    JSC::EnsureStillAliveScope input_0(JSC::JSValue::decode(encodedValue));\n");
    try writer.print("    {s} converted_0 {{}};\n", .{try e.cppType(input.value_type)});
    try emitCppConverterValueStorage(e, writer, conversion.input, "cached_slot", 4);
    try writer.writeAll("    JSC::JSValue slotValue;\n");
    if (conversion.nullable) {
        try writer.writeAll("    if (input_0.value().isNull())\n        slotValue = JSC::jsNull();\n    else {\n");
        try emitCppCachedSlotValueConversion(e, writer, conversion, 8);
        try writer.writeAll("    }\n");
    } else try emitCppCachedSlotValueConversion(e, writer, conversion, 4);
    try writer.print("    thisObject->set_slot_{s}(vm, slotValue);\n", .{conversion.name});
}

fn emitCppCachedSlotValueConversion(e: *Emitter, writer: *Writer, conversion: ir.CppCachedSlotWrite, indent: usize) Error!void {
    try emitCppInputPlanValue(e, writer, .{}, conversion.input, .{ .value = "input_0.value()" }, "converted_0", cppPath(conversion.name), "cached_slot", indent);
    try emitCppAssignment(writer, "slotValue", switch (conversion.output) {
        .any => try cppAnyToJSExpression(e, "converted_0"),
        .value => "converted_0",
        .string => "JSC::jsStringWithCache(vm, converted_0)",
    }, indent);
    try emitCppConversionExceptionReturn(writer, e.ir.get(conversion.input).failure, indent);
}

fn cppClassMemberSymbol(e: *Emitter, symbol: ir.CppClassMemberSymbol) Allocator.Error![]const u8 {
    return switch (symbol) {
        .native => |name| name,
        .builtin => |name| e.print("WebCore::{s}", .{name}),
    };
}

// ─── class tables and properties ───

fn emitCppClassTable(e: *Emitter, writer: *Writer, name: []const u8, entries: []const ir.CppClassTableEntry) Error!void {
    if (entries.len == 0) return;
    try writer.print("static const JSC::HashTableValue {s}[] = {{\n", .{name});
    for (entries) |entry| {
        try writer.print("    {{ \"{s}\"_s, static_cast<unsigned>(", .{entry.name});
        switch (entry.value) {
            .function => |function| {
                try emitCppPropertyAttributes(writer, entry.attributes, switch (function.implementation) {
                    .native => "Function",
                    .builtin => "Builtin",
                });
                try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::{s}, {s}, {d} }} }},\n", .{
                    switch (function.implementation) {
                        .native => "NativeFunctionType",
                        .builtin => "BuiltinGeneratorType",
                    },
                    try cppClassMemberSymbol(e, function.implementation),
                    function.length,
                });
            },
            .accessor => |getter| {
                try emitCppPropertyAttributes(writer, entry.attributes, switch (getter.implementation) {
                    .native => "CustomAccessor",
                    .builtin => "Builtin | JSC::PropertyAttribute::Accessor",
                });
                try writer.print("), JSC::NoIntrinsic, {{ JSC::HashTableValue::{s}, {s}, {s} }} }},\n", .{
                    switch (getter.implementation) {
                        .native => "GetterSetterType",
                        .builtin => "BuiltinAccessorType",
                    },
                    try cppClassMemberSymbol(e, getter.implementation),
                    if (getter.setter) |setter| try cppClassMemberSymbol(e, setter) else "nullptr",
                });
            },
        }
    }
    try writer.writeAll("};\n\n");
}

fn emitCppClassPropertyKey(e: *Emitter, writer: *Writer, key: ir.CppClassPropertyKey) Error!void {
    switch (key) {
        .name => |name| try emitCppInternedPropertyKey(e, writer, name, "vm"),
        .symbol => |symbol| try writer.writeAll(classSymbolCppName(symbol)),
        .private_symbol => |symbol| try writer.print("WebCore::clientData(vm)->builtinNames().{s}PrivateName()", .{symbol}),
    }
}

fn emitCppClassInstallations(e: *Emitter, writer: *Writer, installations: []const ir.CppClassInstallation) Error!void {
    for (installations, 0..) |installation, index| switch (installation) {
        .property => |property| {
            try writer.writeAll(switch (property.value) {
                .accessor => "    putDirectCustomAccessor(vm, ",
                .builtin => "    putDirectBuiltinFunction(vm, global, ",
                .native, .constant => "    putDirect(vm, ",
            });
            try emitCppClassPropertyKey(e, writer, property.key);
            try writer.writeAll(", ");
            switch (property.value) {
                .native => |function| {
                    try writer.print("JSC::JSFunction::create(vm, global, {d}, ", .{function.length});
                    try emitCppUtf8String(writer, function.name);
                    try writer.print(", {s}, JSC::ImplementationVisibility::{s})", .{
                        function.symbol,
                        switch (function.visibility) {
                            .public => "Public",
                            .internal => "Private",
                        },
                    });
                },
                .builtin => |symbol| try writer.print("WebCore::{s}(vm)", .{symbol}),
                .accessor => |getter| try writer.print("JSC::CustomGetterSetter::create(vm, {s}, {s})", .{
                    try cppClassMemberSymbol(e, getter.implementation),
                    if (getter.setter) |setter| try cppClassMemberSymbol(e, setter) else "nullptr",
                }),
                .constant => |value| try emitCppDataPropertyValue(writer, value),
            }
            try writer.writeAll(", static_cast<unsigned>(");
            try emitCppPropertyAttributes(writer, property.attributes, switch (property.value) {
                .accessor => "CustomAccessor",
                .native, .builtin, .constant => null,
            });
            try writer.writeAll("));\n");
        },
        .aliases => |aliases| {
            try writer.print("    JSC::JSValue aliasValue_{d} = getDirect(vm, ", .{index});
            try emitCppInternedPropertyKey(e, writer, aliases.source, "vm");
            try writer.writeAll(");\n");
            for (aliases.targets) |alias| {
                try writer.writeAll("    putDirectWithoutTransition(vm, ");
                switch (alias.key) {
                    .name => |name| try emitCppInternedPropertyKey(e, writer, name, "vm"),
                    .symbol => |symbol| try writer.writeAll(classSymbolCppName(symbol)),
                }
                try writer.print(", aliasValue_{d}, {s});\n", .{ index, if (alias.enumerable) "0" else "static_cast<unsigned>(JSC::PropertyAttribute::DontEnum)" });
            }
        },
        .to_string_tag => try writer.writeAll("    JSC_TO_STRING_TAG_WITHOUT_TRANSITION();\n"),
    };
}

fn emitCppDataPropertyValue(writer: *Writer, value: ir.DefaultValue) Error!void {
    switch (value) {
        .boolean => |boolean| try writer.writeAll(if (boolean) "JSC::jsBoolean(true)" else "JSC::jsBoolean(false)"),
        inline .signed, .unsigned => |number| {
            try writer.writeAll("JSC::jsNumber(");
            try emitCppNumberLiteral(writer, @floatFromInt(number));
            try writer.writeByte(')');
        },
        .float => |number| {
            try writer.writeAll("JSC::jsNumber(");
            try emitCppNumberLiteral(writer, number);
            try writer.writeByte(')');
        },
        .string => |string| {
            try writer.writeAll("JSC::jsString(vm, ");
            try emitCppUtf8String(writer, string);
            try writer.writeByte(')');
        },
        .null => try writer.writeAll("JSC::jsNull()"),
        .undefined => try writer.writeAll("JSC::jsUndefined()"),
    }
}

// ─── class initialization ───

fn emitCppClassInitialization(e: *Emitter, writer: *Writer, class: *const ir.Class) Error!void {
    const initialization = e.ir.class_relations[class.id.index].initialization;
    const constructor_exposed = initialization.constructor != null;
    try writer.print("void {s}(JSC::LazyClassStructure::Initializer& init)\n{{\n    auto* parentPrototype = ", .{class.initialize_symbol});
    switch (initialization.prototype) {
        .object => try writer.writeAll("init.global->objectPrototype()"),
        .function => try writer.writeAll("init.global->functionPrototype()"),
        .iterator => try writer.writeAll("init.global->iteratorPrototype()"),
        .async_iterator => try writer.writeAll("init.global->asyncIteratorPrototype()"),
        .error_object => try writer.writeAll("init.global->errorPrototype()"),
        .class => |parent| try writer.print("defaultGlobalObject(init.global)->{s}Prototype()", .{e.class(parent).cpp_class_name}),
    }
    try writer.print(
        \\;
        \\    auto* prototypeStructure = {0s}::createStructure(init.vm, init.global, parentPrototype);
        \\    auto* prototype = {0s}::create(init.vm, prototypeStructure, init.global);
        \\
    , .{class.cpp_prototype_name});
    switch (initialization.structure) {
        .class => try writer.print("    auto* structure = {s}::createStructure(init.vm, init.global, prototype);\n", .{class.cpp_class_name}),
        .plain => |properties| {
            try writer.print("    auto* structure = JSC::Structure::create(init.vm, init.global, prototype, JSC::TypeInfo(JSC::FinalObjectType, 0), JSC::JSFinalObject::info(), JSC::NonArray, {d});\n", .{properties.len});
            if (properties.len != 0) try writer.writeAll("    JSC::PropertyOffset propertyOffset = 0;\n");
            for (properties) |property| {
                try writer.writeAll("    structure = structure->addPropertyTransition(init.vm, structure, ");
                switch (property) {
                    .name => |name| try emitCppInternedPropertyKey(e, writer, name, "init.vm"),
                    .private_symbol => |symbol| try writer.print("WebCore::builtinNames(init.vm).{s}PrivateName()", .{symbol}),
                }
                try writer.writeAll(", 0, propertyOffset);\n");
            }
        },
    }
    if (initialization.constructor) |parent| {
        try writer.writeAll("    auto* parentConstructor = ");
        switch (parent) {
            .function => try writer.writeAll("init.global->functionPrototype()"),
            .class => |id| try writer.print("defaultGlobalObject(init.global)->{s}Constructor()", .{e.class(id).cpp_class_name}),
        }
        try writer.print(";\n    auto* constructor = {0s}::create(init.vm, {0s}::createStructure(init.vm, init.global, parentConstructor), prototype, init.global);\n", .{class.cpp_constructor_name});
    }
    try writer.writeAll("    init.setPrototype(prototype);\n    init.setStructure(structure);\n");
    if (constructor_exposed) try writer.writeAll("    init.setConstructor(constructor);\n");
    try writer.writeAll("}\n\n");
    if (constructor_exposed) {
        try emitCppExternC(writer, "void {s}(BindGlobalObjectHandle* globalHandle, BindEncodedJSValue* outValue)",
            \\{{
            \\    RELEASE_ASSERT(globalHandle);
            \\    RELEASE_ASSERT(outValue);
            \\    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
            \\    *outValue = encodeBindingValue(defaultGlobalObject(global)->{s}Constructor());
            \\}}
            \\
        , .{ class.get_constructor_symbol, class.cpp_class_name });
    }
    if (class.representation == .plain) return;
    const engine = class.representation == .engine;
    const native_access = if (engine) "&object->wrapped()" else "object->native()";
    try emitCppExternC(writer, "BindNativeHandle* {s}(BindEncodedJSValue encodedValue)",
        \\{{
        \\    auto value = decodeBindingValue(encodedValue);
        \\
    , .{class.try_cast_symbol});
    if (class.brand != null) {
        try writer.writeAll("    if (!(");
        try emitCppClassBrandMatchExpression(e, writer, class, "value");
        try writer.writeAll(
            \\))
            \\        return nullptr;
            \\
        );
    }
    try writer.print(
        \\    auto* object = dynamicDowncast<{s}>(value);
        \\    return reinterpret_cast<BindNativeHandle*>(object ? {s} : nullptr);
        \\}}
        \\
    , .{ class.cpp_class_name, native_access });
    try emitCppExternC(writer, "BindNativeHandle* {0s}(BindEncodedJSValue encodedValue)",
        \\{{
        \\    auto value = decodeBindingValue(encodedValue);
        \\    if (!value.isCell())
        \\        return nullptr;
        \\    auto* object = dynamicDowncast<{1s}>(value);
        \\    if (!object)
        \\        return nullptr;
        \\    auto* global = {2s};
        \\    if (!global || object->structureID() != global->{1s}Structure()->id())
        \\        return nullptr;
        \\    return reinterpret_cast<BindNativeHandle*>({3s});
        \\}}
        \\
    , .{
        class.try_cast_direct_symbol,
        class.cpp_class_name,
        // A JSDOMWrapper-derived cell's globalObject() is already the typed
        // JSDOMGlobalObject, which dynamicDowncast rejects as a self-cast.
        if (engine) "object->globalObject()" else "dynamicDowncast<Zig::GlobalObject>(object->globalObject())",
        native_access,
    });
    if (!engine) {
        try emitCppExternC(writer, "BindStatus {0s}(BindGlobalObjectHandle* globalHandle, BindNativeHandle* nativeHandle, BindEncodedJSValue* outValue)",
            \\{{
            \\    return {1s}::wrapNative(globalHandle, nativeHandle, outValue, [](JSC::JSGlobalObject* global) {{ return defaultGlobalObject(global)->{1s}Structure(); }});
            \\}}
            \\
        , .{ class.wrap_native_symbol, class.cpp_class_name });
    }
    try emitCppClassSlotWireAccessors(writer, class);
}

fn emitCppClassSlotWireAccessors(writer: *Writer, class: *const ir.Class) Error!void {
    for (class.slots) |slot| {
        const cpp_owner = if (slot.storage == .constructor) class.cpp_constructor_name else class.cpp_class_name;
        try emitCppExternC(writer, "const BindJSValueHandle* {s}(BindEncodedJSValue encodedWrapper)",
            \\{{
            \\    auto wrapperValue = decodeBindingValue(encodedWrapper);
            \\    auto* wrapper = dynamicDowncast<{s}>(wrapperValue);
            \\    RELEASE_ASSERT(wrapper);
            \\    return reinterpret_cast<const BindJSValueHandle*>(wrapper->raw_slot_{s}_handle());
            \\}}
            \\
        , .{ slot.get_symbol, cpp_owner, slot.slot_name });
        const write = slot.write orelse continue;
        try emitCppExternC(writer, "void {s}(BindGlobalObjectHandle* globalHandle, BindEncodedJSValue encodedWrapper, BindEncodedJSValue encodedValue)",
            \\{{
            \\    RELEASE_ASSERT(globalHandle);
            \\    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
            \\    auto wrapperValue = decodeBindingValue(encodedWrapper);
            \\    auto value = JSC::JSValue::decode(static_cast<JSC::EncodedJSValue>(encodedValue));
            \\    auto* wrapper = dynamicDowncast<{s}>(wrapperValue);
            \\    RELEASE_ASSERT(wrapper);
            \\    wrapper->set_slot_{s}(JSC::getVM(global), value);
            \\}}
            \\
        , .{ write.set, cpp_owner, slot.slot_name });
        try emitCppExternC(writer, "void {s}(const BindWeakRefHandle* weakWrapper)",
            \\{{
            \\    auto* object = bindingWeakRefObject(weakWrapper);
            \\    if (!object)
            \\        return;
            \\    auto* wrapper = dynamicDowncast<{s}>(object);
            \\    RELEASE_ASSERT(wrapper);
            \\    wrapper->set_slot_{s}(wrapper->vm(), JSC::JSValue());
            \\}}
            \\
        , .{ write.clear_weak, cpp_owner, slot.slot_name });
    }
}

fn propertySymbolTypeScriptName(symbol: ir.TypeScriptPropertySymbol) []const u8 {
    return switch (symbol) {
        .async_dispose => "[Symbol.asyncDispose]",
        .async_iterator => "[Symbol.asyncIterator]",
        .dispose => "[Symbol.dispose]",
        .has_instance => "[Symbol.hasInstance]",
        .iterator => "[Symbol.iterator]",
        .match => "[Symbol.match]",
        .match_all => "[Symbol.matchAll]",
        .replace => "[Symbol.replace]",
        .search => "[Symbol.search]",
        .split => "[Symbol.split]",
        .species => "[Symbol.species]",
        .to_primitive => "[Symbol.toPrimitive]",
        .to_string_tag => "[Symbol.toStringTag]",
    };
}

fn classSymbolCppName(symbol: ir.PropertySymbol) []const u8 {
    return switch (symbol) {
        .async_dispose => "vm.propertyNames->asyncDisposeSymbol",
        .async_iterator => "vm.propertyNames->asyncIteratorSymbol",
        .dispose => "vm.propertyNames->disposeSymbol",
        .has_instance => "vm.propertyNames->hasInstanceSymbol",
        .iterator => "vm.propertyNames->iteratorSymbol",
        .match => "vm.propertyNames->matchSymbol",
        .match_all => "vm.propertyNames->matchAllSymbol",
        .replace => "vm.propertyNames->replaceSymbol",
        .search => "vm.propertyNames->searchSymbol",
        .split => "vm.propertyNames->splitSymbol",
        .species => "vm.propertyNames->speciesSymbol",
        .to_primitive => "vm.propertyNames->toPrimitiveSymbol",
        .to_string_tag => "vm.propertyNames->toStringTagSymbol",
        .inspect_custom => "WebCore::clientData(vm)->builtinNames().inspectCustomPublicName()",
    };
}
