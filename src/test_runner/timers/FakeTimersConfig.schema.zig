const b = @import("bindgen_schema");
const time_types = @import("binding_schema_TimeTypes");

pub const fake_timers_config = b.dictionaryWithOptions("FakeTimersConfig", .{
    b.dictionaryField("now", b.optionalUndefined(time_types.date_or_milliseconds), .{ .default_value = .null }),
}, .{ .user_facing_name = "FakeTimersOptions" });

const inactive_error = b.domainError("inactive", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Fake timers are not active. Call useFakeTimers() first." },
});
const active_errors = b.domainErrors(.{inactive_error});
const advance_errors = b.domainErrors(.{
    inactive_error,
    b.domainError("missing_milliseconds", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "advanceTimersByTime() expects a number of milliseconds" },
    }),
    b.domainError("not_initialized", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Fake timers not initialized. Initialize with useFakeTimers() first." },
    }),
});

const functions = .{
    b.function(
        "useFakeTimers",
        .{b.argument("options", fake_timers_config, .{ .presence = .optional, .missing = .undefined })},
        b.none,
        .{ .backend = .zig, .length = 0, .profile = .node },
    ),
    b.function(
        "useRealTimers",
        .{},
        b.none,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "advanceTimersToNextTimer",
        .{},
        b.none,
        .{ .backend = .zig, .errors = active_errors, .length = 0, .profile = .exact },
    ),
    b.function(
        "advanceTimersByTime",
        .{b.argument("milliseconds", b.lazy(b.double), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "fake-timer activation and clock availability are checked before millisecond conversion",
            .number_conversion = .{ .enforce_range = .{
                .range = .{ .min = 0, .max = 4294967295 },
                .error_class = .type_error,
                .error_message = "advanceTimersByTime() ms is out of range. It must be >= 0 and <= 4294967295.",
            } },
        })},
        b.none,
        .{ .backend = .zig, .errors = advance_errors, .length = 1, .profile = .exact },
    ),
    b.function(
        "runOnlyPendingTimers",
        .{},
        b.none,
        .{ .backend = .zig, .errors = active_errors, .length = 0, .profile = .exact },
    ),
    b.function(
        "runAllTimers",
        .{},
        b.none,
        .{ .backend = .zig, .errors = active_errors, .length = 0, .profile = .exact },
    ),
    b.function(
        "getTimerCount",
        .{},
        b.size,
        .{ .backend = .zig, .errors = active_errors, .length = 0, .profile = .exact },
    ),
    b.function(
        "clearAllTimers",
        .{},
        b.none,
        .{ .backend = .zig, .errors = active_errors, .length = 0, .profile = .exact },
    ),
    b.function(
        "isFakeTimers",
        .{},
        b.boolean,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
};

pub const schema = b.module("fake_timers_config", functions);
