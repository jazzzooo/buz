const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");

const async_call_type = b.enumeration("InspectorAsyncCallType", .{
    b.enumerationValue("DOMTimer", "dom-timer"),
    b.enumerationValue("EventListener", "event-listener"),
    b.enumerationValue("PostMessage", "post-message"),
    b.enumerationValue("RequestAnimationFrame", "request-animation-frame"),
    b.enumerationValue("Microtask", "microtask"),
});

const async_instrumentation: b.EngineShimOptions = .{
    .throws = .never,
    .realm = .current,
    .affinity = .vm,
    // Async bookkeeping also runs while a callback exception is pending.
    .check_traps = false,
};

const message_callback = b.callback(
    "BunDebuggerMessageCallback",
    .{b.rest("messages", b.dom_string)},
    b.none,
    .{ .receiver = null, .profile = .exact },
);

const inspector_connection_value = b.classRefByName("BunDebugger", "InspectorConnection");
const native_connection = b.nominalHandle("InspectorConnectionChannel", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::BunInspectorConnection" } },
    .cpp_declarations = &.{.{ .class = "Bun::BunInspectorConnection" }},
    .ownership = .owned,
    .cpp_release = "releaseInspectorConnection",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const inspector_connection = b.class("InspectorConnection", b.illegalConstructor(), .{}, .{}, .{
    .backend = .zig,
    .profile = .exact,
    .ownership = .unique,
    .identity = .fresh,
});

fn connectionMethod(comptime name: []const u8, comptime arguments: anytype, comptime length: u16) b.Function {
    return b.function(name, arguments, b.none, .{
        .backend = .zig,
        .length = length,
        .profile = .exact,
        .this_value_type = b.optionalMatch(inspector_connection_value),
    });
}

const functions = .{
    connectionMethod(
        "send",
        .{b.argument("message", archetypes.dom_string_or_dom_strings, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        })},
        1,
    ),
    connectionMethod("disconnect", .{}, 0),
    b.function(
        "createConnection",
        .{
            archetypes.coercedInteger("scriptId", b.uint32, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .unsigned = 0 },
            }),
            archetypes.truthyBoolean("shouldNotRef", .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
            b.argument("onMessage", message_callback, .{ .presence = .optional, .missing = .omitted }),
        },
        b.optionalUndefined(inspector_connection_value),
        .{ .backend = .zig, .length = 3, .profile = .exact },
    ),
};

const engine_shims = .{
    b.engineShim("createInspectorConnection", .{
        b.argument("scriptId", b.uint32, .{}),
        b.argument("shouldNotRef", b.boolean, .{}),
        b.argument("onMessage", message_callback, .{}),
    }, b.optional(native_connection), .current_realm_throwing),
    b.engineShim("sendInspectorMessages", .{
        b.argument("connection", native_connection, .{}),
        b.argument("messages", archetypes.dom_strings, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("disconnectInspectorConnection", .{
        b.argument("connection", native_connection, .{}),
    }, b.none, .current_realm_nonthrowing),
    b.engineShim("debuggerRunWithAPILock", .{
        b.argument("vm", engine_types.jsc_vm, .{}),
        b.argument("owner", engine_types.bun_vm, .{}),
    }, b.none, .vm_thread_nonthrowing),
    b.engineShim("createJSDebugger", .{b.argument("pauseOnStart", b.boolean, .{})}, b.uint32, .current_realm_throwing),
    b.engineShim("disconnectInspectorConnections", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("startJSDebuggerThread", .{
        b.argument("scriptId", b.uint32, .{}),
        b.argument("portOrPath", b.dom_string, .{}),
        b.argument("isAutomatic", b.boolean, .{}),
        b.argument("isURLServer", b.boolean, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim(
        "debuggerDidScheduleAsyncCall",
        .{
            b.argument("callType", async_call_type, .{}),
            b.argument("callbackId", b.uint64, .{}),
            b.argument("singleShot", b.boolean, .{}),
        },
        b.none,
        async_instrumentation,
    ),
    b.engineShim(
        "debuggerDidCancelAsyncCall",
        .{
            b.argument("callType", async_call_type, .{}),
            b.argument("callbackId", b.uint64, .{}),
        },
        b.none,
        async_instrumentation,
    ),
    b.engineShim(
        "debuggerDidDispatchAsyncCall",
        .{
            b.argument("callType", async_call_type, .{}),
            b.argument("callbackId", b.uint64, .{}),
        },
        b.none,
        async_instrumentation,
    ),
    b.engineShim(
        "debuggerWillDispatchAsyncCall",
        .{
            b.argument("callType", async_call_type, .{}),
            b.argument("callbackId", b.uint64, .{}),
        },
        b.none,
        async_instrumentation,
    ),
    b.engineShim("debuggerWillHotReload", .{b.argument("scriptId", b.uint32, .{})}, b.none, .realm_independent),
};

const native_exports = .{
    b.nativeExport(
        "debuggerStart",
        .{b.argument("owner", engine_types.bun_vm, .{})},
        b.none,
    ),
    b.nativeExport("debuggerDidConnect", .{}, b.none),
};

pub const schema = b.moduleWithDeclarations("BunDebugger", functions, .{inspector_connection}, engine_shims, native_exports);
