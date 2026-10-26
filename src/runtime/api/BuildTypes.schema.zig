const b = @import("bindgen_schema");

pub const plugin_target = b.enumerationWithOptions(
    "BunPluginTarget",
    .{
        b.enumerationValueWithOptions("bun", "bun", .{ .native_value = 0 }),
        b.enumerationValueWithOptions("browser", "browser", .{ .native_value = 1 }),
        b.enumerationValueWithOptions("node", "node", .{ .native_value = 2 }),
    },
    .{
        .cpp_name = "BunPluginTarget",
        .invalid_value_failure = .{
            .kind = .type_error,
            .message = "plugin target must be one of 'node', 'bun' or 'browser'",
        },
    },
);

const source_loader_values = .{
    b.enumerationValue("jsx", "jsx"),
    b.enumerationValue("js", "js"),
    b.enumerationValue("ts", "ts"),
    b.enumerationValue("tsx", "tsx"),
    b.enumerationValue("css", "css"),
    b.enumerationValue("file", "file"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("jsonc", "jsonc"),
    b.enumerationValue("toml", "toml"),
    b.enumerationValue("wasm", "wasm"),
    b.enumerationValue("napi", "napi"),
    b.enumerationValue("base64", "base64"),
    b.enumerationValue("dataurl", "dataurl"),
    b.enumerationValue("text", "text"),
    b.enumerationValue("bunsh", "bunsh"),
    b.enumerationValue("sqlite", "sqlite"),
    b.enumerationValue("sqlite_embedded", "sqlite_embedded"),
    b.enumerationValue("html", "html"),
    b.enumerationValue("yaml", "yaml"),
    b.enumerationValue("json5", "json5"),
    b.enumerationValue("md", "md"),
};

pub const source_loader = b.enumerationWithOptions("SourceLoader", source_loader_values, .{
    .invalid_value_error = .type,
});

pub const module_loader = b.enumerationWithOptions(
    "ModuleLoader",
    source_loader_values ++ .{
        b.enumerationValueWithOptions("_none", "none", .{ .native_value = 254 }),
    },
    .{ .cpp_name = "BunLoaderType", .invalid_value_error = .type },
);

pub const plugin_setup_callback = b.callback(
    "BuildPluginSetupCallback",
    .{b.argument("builder", b.invocation_any, .{})},
    b.any,
    .{ .receiver = null, .profile = .exact },
);

pub const import_kind = b.enumeration("BuildImportKind", .{
    b.enumerationValue("import_statement", "import-statement"),
    b.enumerationValue("require_call", "require-call"),
    b.enumerationValue("require_resolve", "require-resolve"),
    b.enumerationValue("dynamic_import", "dynamic-import"),
    b.enumerationValue("import_rule", "import-rule"),
    b.enumerationValue("url_token", "url-token"),
    b.enumerationValue("composes", "composes"),
    b.enumerationValue("internal", "internal"),
    b.enumerationValue("entry_point_run", "entry-point-run"),
    b.enumerationValue("entry_point_build", "entry-point-build"),
    b.enumerationValue("html_manifest", "html_manifest"),
});

pub const schema = b.module("BuildTypes", .{});
