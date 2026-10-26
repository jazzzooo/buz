const b = @import("bindgen_schema");
const deferred_terminal_flags = "terminal availability and closed state are checked before coercing flag values";
const archetypes = @import("binding_schema_archetypes");

const terminal_ref = b.classRefByName("Terminal", "Terminal");

const data_callback = b.callback("TerminalDataCallback", .{
    b.argument("terminal", terminal_ref, .{}),
    b.argument("data", b.node_buffer, .{}),
}, b.none, .{ .receiver = terminal_ref, .profile = .exact, .retains_async_context = true });

const drain_callback = b.callback("TerminalDrainCallback", .{
    b.argument("terminal", terminal_ref, .{}),
}, b.none, .{ .receiver = terminal_ref, .profile = .exact, .retains_async_context = true });

const exit_callback = b.callback("TerminalExitCallback", .{
    b.argument("terminal", terminal_ref, .{}),
    b.argument("exit_code", b.int32, .{}),
    b.argument("signal", archetypes.nullable_dom_string, .{}),
}, b.none, .{ .receiver = terminal_ref, .profile = .exact, .retains_async_context = true });

fn callbackField(comptime name: []const u8, comptime callback: b.Type) b.DictionaryField {
    return b.dictionaryField(name, b.optionalNullish(callback), .{ .default_value = .null });
}

const dimension = b.integerRepresentation(b.uint16, .number_or_bigint);
pub const terminal_options = b.dictionaryWithOptions("TerminalOptions", .{
    archetypes.coercedIntegerOrDefaultField("cols", dimension, .{ .min = 1, .max = 65535 }, 80),
    archetypes.coercedIntegerOrDefaultField("rows", dimension, .{ .min = 1, .max = 65535 }, 24),
    b.dictionaryField("name", b.coerceStringWithOptions(b.dom_string, .{
        .input = .string_or_boxed,
        .type_error_format = .property_typeof,
    }), .{
        .default_value = .{ .string = "xterm-256color" },
        .missing = .undefined_or_null,
        .diagnostic_name = "name",
        .profile = .node,
    }),
    callbackField("data", data_callback),
    callbackField("exit", exit_callback),
    callbackField("drain", drain_callback),
}, .{ .user_facing_name = "TerminalOptions" });

const terminal_constructor_errors = b.domainErrors(.{
    b.domainError("missing_options", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Terminal constructor requires an options object" },
    }),
    b.domainError("name_too_long", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Terminal name too long (max 128 characters)" },
    }),
    b.domainError("open_pty_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to open PTY" },
    }),
    b.domainError("dup_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to duplicate PTY file descriptor" },
    }),
    b.domainError("not_supported", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "PTY not supported on this platform" },
    }),
    b.domainError("writer_start_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to start terminal writer" },
    }),
    b.domainError("reader_start_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to start terminal reader" },
    }),
});

const terminal_closed_error = b.domainError("terminal_closed", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Terminal is closed" },
});
const terminal_resize_errors = b.domainErrors(.{
    terminal_closed_error,
    b.domainError("resize_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to resize terminal" },
    }),
});
const terminal_raw_mode_errors = b.domainErrors(.{
    terminal_closed_error,
    b.domainError("raw_mode_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to set raw mode" },
    }),
});
const terminal_write_errors = b.domainErrors(.{
    terminal_closed_error,
    b.systemError("system"),
});

const functions = .{};

fn flagSetter(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return b.setterWithValueOptions(name, b.lazy(b.uint32), .{
        .integer_conversion = .{ .truncate_clamp = .{
            .range = .{ .min = 0, .max = 4294967295 },
            .nan = 4294967295,
            .coerce = true,
        } },
    }, .{ .implementation = implementation, .profile = .webidl, .deferred_reason = deferred_terminal_flags });
}

const terminal_class = b.class(
    "Terminal",
    b.constructor(
        .{b.argument("options", terminal_options, .{ .presence = .optional, .missing = .omitted })},
        .{
            .errors = terminal_constructor_errors,
            .length = 0,
        },
    ),
    .{
        b.method("__asyncDispose", .{}, b.none, .{
            .implementation = "bindAsyncDisposeNative",
            .private_symbol = "asyncDisposeNative",
            .length = 0,
        }),
        b.method("asyncDispose", .{}, b.promise(b.none), .{
            .backend = .builtin,
            .builtin = "terminalAsyncDisposeCodeGenerator",
            .symbol = .async_dispose,
            .length = 0,
        }),
        b.method("close", .{}, b.none, .{ .implementation = "bindClose", .length = 0 }),
        b.getter("closed", b.boolean, .{ .implementation = "bindGetClosed" }),
        b.getter("controlFlags", b.uint32, .{ .implementation = "bindGetControlFlags", .profile = .webidl }),
        flagSetter("controlFlags", "bindSetControlFlags"),
        b.getter("inputFlags", b.uint32, .{ .implementation = "bindGetInputFlags", .profile = .webidl }),
        flagSetter("inputFlags", "bindSetInputFlags"),
        b.getter("localFlags", b.uint32, .{ .implementation = "bindGetLocalFlags", .profile = .webidl }),
        flagSetter("localFlags", "bindSetLocalFlags"),
        b.getter("outputFlags", b.uint32, .{ .implementation = "bindGetOutputFlags", .profile = .webidl }),
        flagSetter("outputFlags", "bindSetOutputFlags"),
        b.method("ref", .{}, b.none, .{ .implementation = "bindRef", .length = 0 }),
        b.method(
            "resize",
            .{
                b.argument("cols", b.uint16, .{ .integer_conversion = .{ .enforce_range = .{ .min = 1, .max = 65535 } } }),
                b.argument("rows", b.uint16, .{ .integer_conversion = .{ .enforce_range = .{ .min = 1, .max = 65535 } } }),
            },
            b.none,
            .{ .implementation = "bindResize", .length = 2, .errors = terminal_resize_errors },
        ),
        b.method(
            "setRawMode",
            .{b.argument("enabled", b.boolean, .{ .presence = .optional, .missing = .omitted })},
            b.none,
            .{ .implementation = "bindSetRawMode", .length = 1, .profile = .webidl, .errors = terminal_raw_mode_errors },
        ),
        b.method("unref", .{}, b.none, .{ .implementation = "bindUnref", .length = 0 }),
        b.method("write", .{b.argument("data", archetypes.string_or_buffer, .{})}, archetypes.byte_count, .{
            .implementation = "bindWrite",
            .length = 1,
            .errors = terminal_write_errors,
        }),
    },
    .{
        b.cachedSlot("dataCallback", data_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("drainCallback", drain_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("exitCallback", exit_callback, .{ .writable = true, .exposed = false }),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("Terminal"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .per_realm,
        .reference_thread = .vm,
        .has_pending_activity = true,
        .lifecycle = .{ .wrapper_created = true },
    },
);

pub const schema = b.moduleWithClasses("Terminal", functions, .{terminal_class});
pub const terminal = schema.class("Terminal");
