const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const framework_router = @import("binding_schema_FrameworkFileSystemRouter");
const build_types = @import("binding_schema_BuildTypes");

const source_map_mode = b.enumeration("BakeSourceMapMode", .{
    b.enumerationValue("inlined", "inline"),
    b.enumerationValue("external", "external"),
    b.enumerationValue("linked", "linked"),
});

const minify_options = b.dictionary("BakeMinifyOptions", .{
    b.dictionaryField("whitespace", b.boolean, .{}),
    b.dictionaryField("syntax", b.boolean, .{}),
    b.dictionaryField("identifiers", b.boolean, .{}),
});

const minify_input = b.unionType("BakeMinifyInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("options", minify_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const build_config_subset = b.dictionary("BakeBuildConfigSubset", .{
    b.dictionaryField("sourcemap", source_map_mode, .{}),
    b.dictionaryField("minify", minify_input, .{}),
});

const bundler_options = b.dictionary("BakeBundlerOptions", .{
    b.dictionaryField("client", build_config_subset, .{}),
    b.dictionaryField("server", build_config_subset, .{}),
    b.dictionaryField("ssr", build_config_subset, .{}),
});

const plugin = b.dictionaryWithOptions("BakePlugin", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("setup", build_types.plugin_setup_callback, .{ .required = true }),
}, .{ .user_facing_name = "plugin" });

const plugins = b.sequence(plugin);

const react_fast_refresh_options = b.dictionary("BakeReactFastRefreshOptions", .{
    b.dictionaryField("importSource", b.dom_string, .{ .required = true }),
});

const react_fast_refresh = b.unionType("BakeReactFastRefresh", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("options", react_fast_refresh_options),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true });

const server_components_options = b.dictionary("BakeServerComponentsOptions", .{
    b.dictionaryField("separateSSRGraph", b.boolean, .{ .required = true }),
    b.dictionaryField("serverRuntimeImportSource", b.dom_string, .{ .required = true }),
    b.dictionaryField("serverRegisterClientReferenceExport", b.dom_string, .{}),
});

const server_components = b.unionType("BakeServerComponents", .{
    b.unionMember("options", server_components_options),
    b.unionMember("flag", b.boolean),
    b.unionMember("nulled", b.null_literal),
}, .{ .ordered = true });

const built_in_module = b.dictionary("BakeBuiltInModule", .{
    b.dictionaryField("import", b.dom_string, .{ .required = true }),
    b.dictionaryField("path", b.dom_string, .{}),
    b.dictionaryField("code", b.dom_string, .{}),
});

const all_extensions = b.enumeration("BakeAllExtensions", .{
    b.enumerationValue("all", "*"),
});

const extensions = b.unionType("BakeExtensions", .{
    b.unionMember("all", all_extensions),
    b.unionMember("values", archetypes.dom_strings),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const file_system_router_type = b.dictionary("BakeFileSystemRouterType", .{
    b.dictionaryField("root", b.dom_string, .{ .required = true }),
    b.dictionaryField("prefix", b.dom_string, .{}),
    b.dictionaryField("serverEntryPoint", b.dom_string, .{ .required = true }),
    b.dictionaryField("clientEntryPoint", b.dom_string, .{}),
    b.dictionaryField("ignoreUnderscores", b.boolean, .{}),
    b.dictionaryField("ignoreDirs", archetypes.dom_strings, .{}),
    b.dictionaryField("extensions", extensions, .{}),
    b.dictionaryField("style", framework_router.route_style, .{ .required = true }),
    b.dictionaryField("layouts", b.boolean, .{}),
});

const framework_options = b.dictionary("BakeFrameworkOptions", .{
    b.dictionaryField("bundlerOptions", bundler_options, .{}),
    b.dictionaryField("fileSystemRouterTypes", b.sequence(file_system_router_type), .{ .required = true }),
    b.dictionaryField("builtInModules", b.sequence(built_in_module), .{}),
    b.dictionaryField("serverComponents", server_components, .{}),
    b.dictionaryField("reactFastRefresh", react_fast_refresh, .{}),
    b.dictionaryField("plugins", plugins, .{}),
});

const framework_preset = b.enumeration("BakeFrameworkPreset", .{
    b.enumerationValue("react", "react"),
    b.enumerationValue("react_server_components", "react-server-components"),
});

const framework = b.unionType("BakeFramework", .{
    b.unionMember("preset", framework_preset),
    b.unionMember("options", framework_options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const options = b.dictionaryWithOptions("BakeAppOptionsInput", .{
    b.dictionaryField("framework", framework, .{ .required = true }),
    b.dictionaryField("root", b.dom_string, .{}),
    b.dictionaryField("bundlerOptions", bundler_options, .{}),
    b.dictionaryField("plugins", plugins, .{}),
}, .{ .user_facing_name = "app" });

const app_preset = b.enumeration("BakeAppPreset", .{
    b.enumerationValue("react", "react"),
});

pub const app_input = b.unionType("BakeAppInput", .{
    b.unionMember("preset", app_preset),
    b.unionMember("options", options),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub const invalid_options_error = b.domainError("invalid_options", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .payload,
});

const create_errors = b.domainErrors(.{
    invalid_options_error,
});

const bake_app_options_class = b.class(
    "BakeAppOptions",
    b.constructor(.{}, .{ .exposure = .never }),
    .{},
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const functions = .{
    b.function(
        "createNative",
        .{b.argument("options", app_input, .{})},
        b.classRefByName("BakeAppOptions", "BakeAppOptions"),
        .{
            .backend = .zig,
            .errors = create_errors,
            .profile = .exact,
            .length = 1,
        },
    ),
};

const engine_shims = .{
    b.engineShim("createFromModuleDefault", .{b.argument("moduleDefault", b.engine_value, .{})}, b.classRefByName("BakeAppOptions", "BakeAppOptions"), .current_realm_throwing),
};

pub const schema = b.moduleWithClassesAndEngineShims(
    "BakeAppOptions",
    functions,
    .{bake_app_options_class},
    engine_shims,
);
pub const bake_app_options = schema.class("BakeAppOptions");
