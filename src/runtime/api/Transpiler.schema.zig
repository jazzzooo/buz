const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const build_types = @import("binding_schema_BuildTypes");
const diagnostics = @import("binding_schema_DiagnosticErrors");

const loader_or_context = b.unionType("TranspilerLoaderOrContext", .{
    b.unionMember("loader", build_types.module_loader),
    b.unionMember("context", b.js_object),
}, .{ .ordered = true });

const transpiler_target = b.enumeration("TranspilerTarget", .{
    b.enumerationValue("browser", "browser"),
    b.enumerationValue("bun", "bun"),
    b.enumerationValueWithOptions("bun_macro", "bun_macro", .{ .aliases = &.{"macro"} }),
    b.enumerationValue("node", "node"),
});

const source_map_option = b.enumeration("TranspilerSourceMapOption", .{
    b.enumerationValue("none", "none"),
    b.enumerationValueWithOptions("inlined", "inline", .{}),
    b.enumerationValue("external", "external"),
    b.enumerationValue("linked", "linked"),
});

const transpiler_import = b.dictionary("TranspilerImport", .{
    b.dictionaryField("path", b.dom_string, .{ .required = true }),
    b.dictionaryField("kind", build_types.import_kind, .{ .required = true }),
});

const transpiler_imports = b.sequence(transpiler_import);

const transpiler_scan_result = b.dictionary("TranspilerScanResult", .{
    b.dictionaryField("imports", transpiler_imports, .{ .required = true }),
    b.dictionaryField("exports", archetypes.dom_strings, .{ .required = true }),
});

const sourcemap_input = b.unionType("TranspilerSourceMapInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("named", source_map_option),
}, .{ .ordered = true });

const packages_option = b.enumeration("TranspilerPackagesOption", .{
    b.enumerationValue("bundle", "bundle"),
    b.enumerationValue("external", "external"),
});

const log_level_option = b.enumeration("TranspilerLogLevel", .{
    b.enumerationValue("verbose", "verbose"),
    b.enumerationValue("debug", "debug"),
    b.enumerationValue("info", "info"),
    b.enumerationValue("warn", "warn"),
    b.enumerationValueWithOptions("err", "error", .{}),
});

const minify_options = b.dictionary("TranspilerMinifyOptions", .{
    b.dictionaryField("whitespace", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("syntax", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("identifiers", b.boolean, .{ .boolean_conversion = .truthy }),
});

const minify_input = b.unionType("TranspilerMinifyInput", .{
    b.unionMember("all", b.boolean),
    b.unionMember("options", minify_options),
}, .{ .ordered = true });

const json_stringified_string = b.json_stringified_string;

const macro_input = b.unionType("TranspilerMacroInput", .{
    b.unionMember("enabled", b.boolean),
    b.unionMember("map", json_stringified_string),
}, .{ .ordered = true });

const export_replacement_primitive = b.unionType("TranspilerExportReplacementPrimitive", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("number", b.double),
    b.unionMember("flag", b.boolean),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
}, .{ .ordered = true });

const export_inject_item = b.unionType("TranspilerExportInjectItem", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("number", b.double),
    b.unionMember("flag", b.boolean),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const export_inject_input = b.sequence(export_inject_item);

const export_replacement = b.unionType("TranspilerExportReplacement", .{
    b.unionMember("value", export_replacement_primitive),
    b.unionMember("pair", export_inject_input),
}, .{ .ordered = true });

const exports_options = b.dictionary("TranspilerExportsOptions", .{
    b.dictionaryField("eliminate", archetypes.dom_strings, .{}),
    b.dictionaryField("replace", b.record(b.dom_string, export_replacement), .{}),
});

const transpiler_options = b.dictionaryWithOptions("TranspilerOptions", .{
    b.dictionaryField("define", archetypes.dom_string_record, .{}),
    b.dictionaryField("external", archetypes.dom_string_or_dom_strings, .{}),
    b.dictionaryField("loader", build_types.module_loader, .{}),
    b.dictionaryField("target", transpiler_target, .{}),
    b.dictionaryField("tsconfig", json_stringified_string, .{}),
    b.dictionaryField("macro", macro_input, .{}),
    b.dictionaryField("autoImportJSX", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("allowBunRuntime", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("inlining", b.boolean, .{ .boolean_conversion = .truthy, .js_name = "inline" }),
    b.dictionaryField("minifyWhitespace", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("deadCodeElimination", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("replMode", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("minify", minify_input, .{}),
    b.dictionaryField("sourcemap", sourcemap_input, .{}),
    b.dictionaryField("packages", packages_option, .{}),
    b.dictionaryField("treeShaking", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("trimUnusedImports", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("exports", exports_options, .{}),
    b.dictionaryField("logLevel", log_level_option, .{}),
}, .{ .user_facing_name = "transpiler options" });

const transpiler_errors = b.domainErrors(diagnostics.errors("Failed to create transpiler").errors ++ .{
    b.domainError("unsupported_loader", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "only JavaScript-like loaders supported for now" },
    }),
    b.domainError("invalid_export_identifier", b.dom_string, .{
        .class = .type_error,
        .message = .payload,
    }),
    b.domainError("invalid_export_replacement", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "exports.replace values can only be string, null, undefined, number or boolean" },
    }),
    b.domainError("create_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const scan_parse_error = b.domainError("parse_failed", b.dom_string, .{
    .class = .syntax_error,
    .message = .payload,
});

const transform_failed_error = b.domainError("transform_failed", b.thread_safe_dom_string, .{
    .class = .generic_error,
    .message = .payload,
});

fn optionalNullishArgument(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, value_type, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    });
}

const transpiler_class = b.class(
    "Transpiler",
    b.constructor(
        .{b.argument("options", transpiler_options, .{ .presence = .optional, .missing = .undefined_or_null })},
        .{ .length = 0, .errors = transpiler_errors },
    ),
    .{
        b.method(
            "scan",
            .{
                b.argument("code", archetypes.string_or_buffer, .{}),
                optionalNullishArgument("loader", build_types.module_loader),
            },
            transpiler_scan_result,
            .{ .errors = b.domainErrors(diagnostics.errors("Parse error").errors ++ .{scan_parse_error}), .length = 2 },
        ),
        b.method(
            "scanImports",
            .{
                b.argument("code", archetypes.string_or_buffer, .{}),
                optionalNullishArgument("loader", build_types.module_loader),
            },
            transpiler_imports,
            .{
                .errors = b.domainErrors(diagnostics.errors("Failed to scan imports").errors ++ .{
                    b.domainError("unsupported_loader", b.none, .{
                        .class = .type_error,
                        .code = "ERR_INVALID_ARG_TYPE",
                        .message = .{ .literal = "Only JavaScript-like files support this fast path" },
                    }),
                    scan_parse_error,
                }),
                .length = 2,
            },
        ),
        b.method(
            "transform",
            .{
                b.argument("code", archetypes.string_or_buffer, .{}),
                optionalNullishArgument("loader", build_types.module_loader),
            },
            b.dom_string,
            .{
                .errors = b.domainErrors(diagnostics.errors("Transform failed").errors ++ .{transform_failed_error}),
                .length = 2,
                .completion = .{
                    .retention = .pending_activity,
                    .sender_drop = .cancel,
                    .delivery = .vm,
                    .error_delivery = .vm,
                },
            },
        ),
        b.method(
            "transformSync",
            .{
                b.argument("code", archetypes.string_or_buffer, .{}),
                optionalNullishArgument("loaderOrContext", loader_or_context),
                optionalNullishArgument("context", b.js_object),
            },
            b.dom_string,
            .{ .errors = b.domainErrors(diagnostics.errors("Parse error").errors ++ .{transform_failed_error}), .length = 2 },
        ),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Transpiler"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
    },
);

pub const schema = b.moduleWithClasses("Transpiler", .{}, .{transpiler_class});
pub const transpiler = schema.class("Transpiler");
