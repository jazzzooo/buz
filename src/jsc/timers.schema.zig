const b = @import("bindgen_schema");
const immediate = @import("binding_schema_Immediate");
const timeout = @import("binding_schema_Timeout");

const post_dispatch = b.dictionary("TimerPostDispatch", .{
    b.dictionaryField("shouldReschedule", b.boolean, .{ .required = true }),
    b.dictionaryField("convertToInterval", b.boolean, .{ .required = true }),
    b.dictionaryField("repeatInterval", b.uint32, .{ .required = true }),
});

const warning_kind = b.enumerationWithOptions("TimerWarningKind", .{
    b.enumerationValue("overflow", "TimeoutOverflowWarning"),
    b.enumerationValue("negative", "TimeoutNegativeWarning"),
    b.enumerationValue("nan", "TimeoutNaNWarning"),
}, .{ .cpp_name = "TimerWarningKind" });

const engine_shims = .{
    b.engineShim("emitCountdownWarning", .{
        b.argument("countdown", b.double, .{}),
        b.argument("kind", warning_kind, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("timerInitializeTimeout", .{
        b.argument("timer", b.classRef(timeout.timeout), .{}),
        b.argument("interval", b.uint32, .{}),
        b.argument("repeats", b.boolean, .{}),
        b.argument("arguments", b.sequence(b.invocation_any), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("timerInitializeImmediate", .{
        b.argument("timer", b.classRef(immediate.immediate), .{}),
        b.argument("arguments", b.sequence(b.invocation_any), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim(
        "timerPrepareReschedule",
        .{
            b.argument("timer", b.classRef(timeout.timeout), .{}),
            b.argument("isInterval", b.boolean, .{}),
            b.argument("idleStart", b.uint64, .{}),
        },
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim("timerTimeoutCallbackPresent", .{b.argument("timer", b.classRef(timeout.timeout), .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("timerImmediateCallbackPresent", .{b.argument("timer", b.classRef(immediate.immediate), .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim(
        "timerInvokeTimeoutCallback",
        .{
            b.argument("timer", b.classRef(timeout.timeout), .{}),
        },
        b.boolean,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "timerTimeoutPostDispatch",
        .{
            b.argument("timer", b.classRef(timeout.timeout), .{}),
            b.argument("isInterval", b.boolean, .{}),
        },
        post_dispatch,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "timerInvokeImmediateCallback",
        .{
            b.argument("timer", b.classRef(immediate.immediate), .{}),
        },
        b.boolean,
        .current_realm_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("timers", .{}, .{}, engine_shims, .{});
