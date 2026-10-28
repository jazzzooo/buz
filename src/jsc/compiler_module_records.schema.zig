const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");

const module_identifier = b.nominalHandle("ModuleIdentifier", .{
    .cpp_type = .{ .const_pointer = &.{ .named = "JSC::Identifier" } },
    .cpp_declarations = &.{.{ .class = "JSC::Identifier" }},
    .const_pointee = true,
    .access_thread = .vm,
});

const source_code = b.nominalHandle("SourceCode", .{
    .cpp_type = .{ .const_pointer = &.{ .named = "JSC::SourceCode" } },
    .cpp_declarations = &.{.{ .class = "JSC::SourceCode" }},
    .const_pointee = true,
    .access_thread = .vm,
});

const module_record = b.brandedValueWithBrand(b.cppDynamicCastBrand("JSModuleRecordValue", .{
    .type_name = "JSC::JSModuleRecord",
    .header = "JavaScriptCore/JSModuleRecord.h",
}, "object"), .{});

const module_type = b.enumeration("CompilerModuleType", .{
    b.enumerationValue("JavaScript", "javascript"),
    b.enumerationValue("WebAssembly", "webassembly"),
    b.enumerationValue("JSON", "json"),
    b.enumerationValue("HostDefined", "hostDefined"),
});

const requested_module_kind = b.enumeration("CompilerRequestedModuleKind", .{
    b.enumerationValue("None", "none"),
    b.enumerationValue("JavaScript", "javascript"),
    b.enumerationValue("WebAssembly", "webassembly"),
    b.enumerationValue("JSON", "json"),
    b.enumerationValue("HostDefined", "hostDefined"),
});

const import_kind = b.enumeration("CompilerImportKind", .{
    b.enumerationValue("Single", "single"),
    b.enumerationValue("SingleTypeScript", "singleTypeScript"),
    b.enumerationValue("Namespace", "namespace"),
});

const export_kind = b.enumeration("CompilerExportKind", .{
    b.enumerationValue("Indirect", "indirect"),
    b.enumerationValue("Local", "local"),
    b.enumerationValue("Namespace", "namespace"),
    b.enumerationValue("Star", "star"),
});

const compiler_requested_module = b.dictionary("CompilerRequestedModule", .{
    b.dictionaryField("kind", requested_module_kind, .{ .required = true }),
    b.dictionaryField("moduleName", b.uint32, .{ .required = true }),
    b.dictionaryField("hostDefinedImportType", b.uint32, .{ .required = true }),
});

const compiler_import = b.dictionary("CompilerImport", .{
    b.dictionaryField("kind", import_kind, .{ .required = true }),
    b.dictionaryField("moduleType", module_type, .{ .required = true }),
    b.dictionaryField("moduleName", b.uint32, .{ .required = true }),
    b.dictionaryField("importName", b.uint32, .{ .required = true }),
    b.dictionaryField("localName", b.uint32, .{ .required = true }),
});

const compiler_export = b.dictionary("CompilerExport", .{
    b.dictionaryField("kind", export_kind, .{ .required = true }),
    b.dictionaryField("moduleType", module_type, .{ .required = true }),
    b.dictionaryField("exportName", b.uint32, .{ .required = true }),
    b.dictionaryField("importName", b.uint32, .{ .required = true }),
    b.dictionaryField("localName", b.uint32, .{ .required = true }),
    b.dictionaryField("moduleName", b.uint32, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("compilerModuleRecordCreate", .{
        b.argument("moduleKey", module_identifier, .{}),
        b.argument("sourceCode", source_code, .{}),
        b.argument("identifiers", archetypes.dom_strings, .{}),
        b.argument("requestedModules", b.sequence(compiler_requested_module), .{}),
        b.argument("imports", b.sequence(compiler_import), .{}),
        b.argument("exports", b.sequence(compiler_export), .{}),
        b.argument("hasImportMeta", b.boolean, .{}),
        b.argument("isTypeScript", b.boolean, .{}),
        b.argument("hasTLA", b.boolean, .{}),
    }, module_record, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExport("compilerArtifactDestroy", .{b.argument("moduleInfo", engine_types.borrowed_module_info_deserialized, .{})}, b.none),
    b.nativeExportWithOptions("compilerArtifactToModuleRecord", .{
        b.argument("moduleKey", module_identifier, .{}),
        b.argument("sourceCode", source_code, .{}),
        b.argument("moduleInfo", engine_types.borrowed_module_info_deserialized, .{}),
    }, b.optional(module_record), .current_realm_throwing),
    b.nativeExportWithOptions("compilerRenderDiff", .{
        b.argument("expected", b.dom_string, .{}),
        b.argument("received", b.dom_string, .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("compiler_module_records", .{}, .{}, engine_shims, native_exports);
