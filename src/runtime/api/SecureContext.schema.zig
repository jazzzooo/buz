const b = @import("bindgen_schema");
const ssl = @import("binding_schema_SSLConfig");
const hash_types = @import("binding_schema_HashTypes");

const secure_context_errors = b.domainErrors(ssl.ssl_config_error_list ++ .{hash_types.boringssl_error});

const secure_context_class = b.class(
    "SecureContext",
    b.constructor(.{b.argument("options", ssl.ssl_config, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    })}, .{
        .errors = secure_context_errors,
    }),
    .{},
    .{},
    .{
        .backend = .zig,
        .profile = .node,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

const functions = .{
    b.function(
        "internSecureContext",
        .{b.argument("options", ssl.ssl_config, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        })},
        b.classRefByName("SecureContext", "SecureContext"),
        .{
            .backend = .zig,
            .errors = secure_context_errors,
            .profile = .node,
        },
    ),
};

const engine_shims = .{
    b.engineShim("secureContextCacheGet", .{b.argument("key", b.uint64, .{})}, b.optional(b.classRefByName("SecureContext", "SecureContext")), .current_realm_nonthrowing),
    b.engineShim("secureContextCacheSet", .{
        b.argument("key", b.uint64, .{}),
        b.argument("value", b.classRefByName("SecureContext", "SecureContext"), .{}),
    }, b.none, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("SecureContext", functions, .{secure_context_class}, engine_shims, .{});
pub const intern_secure_context = schema.function("internSecureContext");
pub const secure_context = schema.class("SecureContext");
