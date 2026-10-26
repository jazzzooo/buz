const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const promise_status = b.enumeration("PromiseStatus", .{
    b.enumerationValue("pending", "pending"),
    b.enumerationValue("fulfilled", "fulfilled"),
    b.enumerationValue("rejected", "rejected"),
});

const functions = .{
    b.function(
        "chain",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("onFulfilled", b.optionalUndefined(archetypes.callable_value), .{}),
            b.argument("onRejected", b.optionalUndefined(archetypes.callable_value), .{}),
        },
        b.js_promise,
        .{
            .backend = .builtin,
            .builtin = "promiseChainingChainCodeGenerator",
            .length = 3,
        },
    ),
};

const engine_shims = .{
    b.engineShim(
        "queueHandledPromiseNotification",
        .{b.argument("promise", b.js_promise, .{})},
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueAsPromise",
        .{b.argument("value", b.engine_value, .{})},
        b.optional(b.js_promise),
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "promiseIsErrorLike",
        .{b.argument("reason", b.engine_value, .{})},
        b.boolean,
        .current_realm_throwing,
    ),
    b.engineShim(
        "promiseResolve",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("value", b.engine_value, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "promiseReject",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("value", b.engine_value, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "promiseRejectAsHandled",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("value", b.engine_value, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "promiseStatus",
        .{b.argument("promise", b.js_promise, .{})},
        promise_status,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "promiseSetHandled",
        .{b.argument("promise", b.js_promise, .{})},
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "promiseResult",
        .{b.argument("promise", b.js_promise, .{})},
        b.optional(b.engine_value),
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "promiseRejectionReason",
        .{b.argument("promise", b.js_promise, .{})},
        b.optionalNullish(b.engine_value),
        .current_realm_nonthrowing,
    ),
    b.engineShim("promiseCreate", .{}, b.js_promise, .current_realm_nonthrowing),
    b.engineShim("promiseCreateResolvedUndefined", .{}, b.void_promise, .current_realm_nonthrowing),
    b.engineShim(
        "promiseCreateResolved",
        .{b.argument("value", b.engine_value, .{})},
        b.js_promise,
        .current_realm_throwing,
    ),
    b.engineShim(
        "promiseCreateResolvedSize",
        .{b.argument("value", b.size, .{})},
        b.promise(b.size),
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "promiseCreateRejectedWithoutNotifying",
        .{b.argument("value", b.engine_value, .{})},
        b.js_promise,
        .current_realm_nonthrowing,
    ),
    b.engineShim("promiseWrapPendingException", .{}, b.js_promise, .current_realm_unchecked),
};

const native_exports = .{
    b.nativeExportWithOptions("handleRejectedPromise", .{b.argument("promise", b.js_promise, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("handleHandledPromise", .{b.argument("promise", b.js_promise, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("deliverHandledPromiseNotification", .{b.argument("promise", b.js_promise, .{})}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("promises", functions, .{}, engine_shims, native_exports);
