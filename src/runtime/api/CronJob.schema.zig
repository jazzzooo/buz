const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const time_types = @import("binding_schema_TimeTypes");

const cron_expression_input = b.unionType("CronExpressionInput", .{
    b.unionMember("expression", archetypes.string_like_dom_string),
    b.unionMember("invalid", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "invalid" });

const cron_callback_result = b.unionType("CronCallbackResult", .{
    b.unionMember("promise", b.js_promise),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const cron_callback = b.callback(
    "CronCallback",
    .{},
    cron_callback_result,
    .{
        .receiver = b.classRefByName("CronJob", "CronJob"),
        .profile = .exact,
        .retains_async_context = true,
    },
);

const cron_register_result = b.unionType("CronRegisterResult", .{
    b.unionMember("job", b.classRefByName("CronJob", "CronJob")),
    b.unionMember("promise", b.js_promise),
}, .{ .ordered = true });

const invalid_title_error = b.domainError("invalid_title", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "Cron title must contain only alphanumeric characters, hyphens, and underscores" },
});
const operation_failed_error = b.domainError("operation_failed", b.thread_safe_dom_string, .{
    .class = .generic_error,
    .message = .payload,
});
const invalid_expression_error = b.domainError("invalid_expression", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .payload,
});
const async_invalid_expression_error = b.domainError("invalid_expression", b.thread_safe_dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .payload,
});
const executable_path_failed_error = b.domainError("executable_path_failed", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Failed to get bun executable path" },
});

const remove_errors = b.domainErrors(.{
    invalid_title_error,
    operation_failed_error,
});

const parse_errors = b.domainErrors(.{
    invalid_expression_error,
    b.domainError("invalid_date", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Invalid date value" },
    }),
});

const register_in_process_errors = b.domainErrors(.{
    invalid_expression_error,
    b.domainError("no_future_occurrences", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
});

const register_system_errors = b.domainErrors(.{
    invalid_title_error,
    async_invalid_expression_error,
    b.domainError("path_resolve_failed", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Failed to resolve path" },
    }),
    b.domainError("path_has_single_quote", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Path must not contain single quotes" },
    }),
    b.domainError("path_has_percent", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Path must not contain percent signs (cron interprets % as newline)" },
    }),
    b.domainError("unsafe_executable_path", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    executable_path_failed_error,
    operation_failed_error,
});

pub const cron_job_promise_reaction_context = b.promiseReactionContext(
    "CronJobPromiseReactionContext",
    "cron_job",
);

const functions = .{
    b.function(
        "register",
        b.overloads(.{
            b.overloadCase("in_process", .{
                b.argument("expression", b.dom_string, .{}),
                b.argument("handler", cron_callback, .{}),
            }),
            b.overloadCase("system", .{
                b.argument("path", b.dom_string, .{}),
                b.argument("schedule", b.dom_string, .{}),
                b.argument("title", b.dom_string, .{}),
            }),
        }, .{ .ordered = true }),
        cron_register_result,
        .{
            .backend = .builtin,
            .builtin = "bunObjectCronCodeGenerator",
            .length = 3,
            .profile = .exact,
        },
    ),
    b.function(
        "registerInProcess",
        .{
            b.argument("expression", cron_expression_input, .{}),
            b.argument("handler", cron_callback, .{}),
        },
        b.classRefByName("CronJob", "CronJob"),
        .{
            .backend = .zig,
            .errors = register_in_process_errors,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "registerSystem",
        .{
            b.argument("path", b.dom_string, .{}),
            b.argument("schedule", b.dom_string, .{}),
            b.argument("title", b.dom_string, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .caller_source_location = true,
            .errors = register_system_errors,
            .length = 3,
            .profile = .exact,
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
        },
    ),
    b.function(
        "remove",
        .{b.argument("title", b.dom_string, .{})},
        b.none,
        .{
            .backend = .zig,
            .errors = remove_errors,
            .length = 1,
            .profile = .exact,
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
        },
    ),
    b.function(
        "parse",
        .{
            b.argument("expression", b.dom_string, .{}),
            b.argument("from", time_types.date_or_milliseconds, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
        },
        b.optional(b.js_date),
        .{
            .backend = .zig,
            .errors = parse_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "onPromiseResolve",
        .{
            b.argument("result", b.discardAny(.ignored), .{}),
            b.argument("context", cron_job_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
    b.function(
        "onPromiseReject",
        .{
            b.argument("errorValue", b.engine_value, .{}),
            b.argument("context", cron_job_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
};

const cron_job_class = b.class(
    "CronJob",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("dispose", .{}, archetypes.self_ref, .{
            .symbol = .dispose,
            .length = 0,
            .this_value_type = b.this_class_ref,
        }),
        b.getter("cron", b.dom_string, .{ .implementation = "getCron" }),
        b.method("ref", .{}, archetypes.self_ref, .{
            .implementation = "doRef",
            .length = 0,
            .this_value_type = b.this_class_ref,
        }),
        b.method("stop", .{}, archetypes.self_ref, .{
            .length = 0,
            .this_value_type = b.this_class_ref,
        }),
        b.method("unref", .{}, archetypes.self_ref, .{
            .implementation = "doUnref",
            .length = 0,
            .this_value_type = b.this_class_ref,
        }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "each scheduled job is returned through its single construction wrapper",
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("CronJob", functions, .{cron_job_class});
pub const cron_job = schema.class("CronJob");
