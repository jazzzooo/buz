const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const utf8_strings = b.sequence(b.utf8_string);

const scan_error_list = .{
    b.systemError("system"),
    b.domainError("invalid_cwd", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
};

const scan_errors = b.domainErrors(scan_error_list ++ .{
    b.domainError("concurrency_unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "ConcurrencyUnavailable" },
    }),
});

const scan_sync_errors = b.domainErrors(scan_error_list);

const scan_options_dictionary = b.dictionaryWithOptions("GlobScanOptions", .{
    b.dictionaryField("only_files", b.boolean, .{
        .boolean_conversion = .strict_true,
        .default_value = .{ .boolean = true },
        .js_name = "onlyFiles",
    }),
    b.dictionaryField("error_on_broken_symlinks", b.boolean, .{
        .boolean_conversion = .strict_true,
        .default_value = .{ .boolean = false },
        .js_name = "throwErrorOnBrokenSymlink",
    }),
    b.dictionaryField("follow_symlinks", b.boolean, .{
        .boolean_conversion = .strict_true,
        .default_value = .{ .boolean = false },
        .js_name = "followSymlinks",
    }),
    b.dictionaryField("absolute", b.boolean, .{
        .boolean_conversion = .strict_true,
        .default_value = .{ .boolean = false },
    }),
    b.dictionaryField("cwd", b.dom_string, .{}),
    b.dictionaryField("dot", b.boolean, .{
        .boolean_conversion = .strict_true,
        .default_value = .{ .boolean = false },
    }),
}, .{ .user_facing_name = "GlobScanOptions", .property_lookup = .skip_object_prototype });

const scan_options = b.unionType("GlobScanOptionsInput", .{
    b.unionMember("cwd", b.dom_string),
    b.unionMember("options", scan_options_dictionary),
}, .{ .ordered = true });

fn scanOptionsArgument() b.Argument {
    return b.argument("options", scan_options, .{ .presence = .optional, .missing = .undefined_or_null });
}

const glob_class = b.class(
    "Glob",
    b.constructor(
        .{b.argument("pattern", b.dom_string, .{})},
        .{ .length = 1 },
    ),
    .{
        b.method(
            "__scan",
            .{scanOptionsArgument()},
            utf8_strings,
            .{
                .private_symbol = "pull",
                .length = 1,
                .errors = scan_errors,
                .completion = .{
                    .retention = .pending_activity,
                    .sender_drop = .cancel,
                },
            },
        ),
        b.method(
            "__scanSync",
            .{scanOptionsArgument()},
            b.optionalUndefined(utf8_strings),
            .{ .private_symbol = "resolveSync", .length = 1, .errors = scan_sync_errors },
        ),
        b.method("match", .{b.argument("value", b.dom_string, .{})}, b.boolean, .{ .length = 1 }),
        b.method(
            "scan",
            .{scanOptionsArgument()},
            b.js_generator_object,
            .{ .backend = .builtin, .builtin = "globScanCodeGenerator", .length = 1 },
        ),
        b.method(
            "scanSync",
            .{scanOptionsArgument()},
            b.js_generator_object,
            .{ .backend = .builtin, .builtin = "globScanSyncCodeGenerator", .length = 1 },
        ),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Glob"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("Glob", .{}, .{glob_class});
pub const glob = schema.class("Glob");
