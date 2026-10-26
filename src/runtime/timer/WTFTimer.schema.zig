const b = @import("bindgen_schema");

const run_loop_timer = b.nominalHandle("WTFRunLoopTimer", .{
    .cpp_type = .{ .pointer = &.{ .named = "WTF::RunLoop::TimerBase" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "wtf/RunLoop.h", .system = true } }},
    .zig_type = "api.Timer.WTFTimer.RunLoopTimer",
    .access_thread = .current,
});

const timer_state = b.nominalHandle("WTFTimerState", .{
    .cpp_type = .{ .pointer = &.{ .named = "WTF::RunLoop::TimerBase::Bun__WTFTimer" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "wtf/RunLoop.h", .system = true } }},
    .zig_type = "api.Timer.WTFTimer",
    .access_thread = .current,
});

const uws_loop = b.nominalHandle("UWSLoop", .{
    .cpp_type = .{ .pointer = &.{ .named = "us_loop_t" } },
    .c_struct = "us_loop_t",
    .cpp_declarations = &.{.{ .structure = "us_loop_t" }},
    .zig_type = "uws.Loop",
    .access_thread = .current,
});

fn nativeExport(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type) b.NativeExport {
    return b.nativeExportWithOptions(name, arguments, result, .{
        .throws = .never,
        .realm = .none,
        .standalone_header = "WTFTimer",
    });
}

const engine_shims = .{
    b.engineShim(
        "wtfTimerFire",
        .{b.argument("timer", run_loop_timer, .{})},
        b.none,
        .realm_independent,
    ),
};

const native_exports = .{
    nativeExport(
        "wtfTimerCreate",
        .{b.argument("timer", run_loop_timer, .{})},
        b.optional(timer_state),
    ),
    nativeExport(
        "wtfTimerUpdate",
        .{
            b.argument("timer", timer_state, .{}),
            b.argument("seconds", b.double, .{}),
            b.argument("repeat", b.boolean, .{}),
        },
        b.none,
    ),
    nativeExport(
        "wtfTimerDestroy",
        .{b.argument("timer", timer_state, .{})},
        b.none,
    ),
    nativeExport(
        "wtfTimerIsActive",
        .{b.argument("timer", timer_state, .{})},
        b.boolean,
    ),
    nativeExport(
        "wtfTimerCancel",
        .{b.argument("timer", timer_state, .{})},
        b.none,
    ),
    nativeExport(
        "wtfTimerSecondsUntilFire",
        .{b.argument("timer", timer_state, .{})},
        b.double,
    ),
    nativeExport("wtfTimerThisThreadHasVM", .{}, b.boolean),
    b.nativeExportWithOptions(
        "ensureDateHeaderTimerIsEnabled",
        .{b.argument("loop", uws_loop, .{})},
        b.none,
        .{ .throws = .never, .realm = .none, .standalone_header = "UWSRuntime" },
    ),
};

pub const schema = b.moduleWithDeclarations("WTFTimer", .{}, .{}, engine_shims, native_exports);
