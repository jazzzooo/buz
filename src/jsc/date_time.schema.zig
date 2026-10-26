const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("currentUnixTimeMilliseconds", .{}, b.double, .realm_independent),
    b.engineShim("currentDateMilliseconds", .{}, b.double, .current_realm_unchecked),
    b.engineShim(
        "parseES5Date",
        .{b.argument("bytes", b.buffer(.copy), .{})},
        b.double,
        .realm_independent,
    ),
    b.engineShim(
        "writeHTTPDate",
        .{
            b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
            b.argument("timestampMs", b.uint64, .{}),
        },
        b.int32,
        .realm_independent,
    ),
    b.engineShim(
        "postgresFormatTime",
        .{
            b.argument("microseconds", b.int64, .{}),
            b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
        },
        b.size,
        .realm_independent,
    ),
    b.engineShim(
        "postgresFormatTimeTz",
        .{
            b.argument("microseconds", b.int64, .{}),
            b.argument("tzOffsetSeconds", b.int32, .{}),
            b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
        },
        b.size,
        .realm_independent,
    ),
    b.engineShim(
        "jsValueDateMilliseconds",
        .{b.argument("value", b.engine_value, .{})},
        b.double,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "dateInstanceFromNumber",
        .{b.argument("value", b.double, .{})},
        b.js_date,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "dateToISOString",
        .{b.argument("value", b.brandCast(b.js_date, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.byte_string,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "parseDate",
        .{b.argument("value", b.dom_string, .{})},
        b.double,
        .current_realm_throwing,
    ),
    b.engineShim(
        "setOverriddenDateNow",
        .{b.argument("milliseconds", b.double, .{})},
        b.none,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "gregorianDateTimeToMS",
        .{
            b.argument("year", b.int32, .{}),
            b.argument("month", b.int32, .{}),
            b.argument("day", b.int32, .{}),
            b.argument("hour", b.int32, .{}),
            b.argument("minute", b.int32, .{}),
            b.argument("second", b.int32, .{}),
            b.argument("millisecond", b.int32, .{}),
            b.argument("localTime", b.boolean, .{}),
        },
        b.double,
        .current_realm_throwing,
    ),
    b.engineShim(
        "setTimeZone",
        .{b.argument("timeZone", b.dom_string, .{})},
        b.boolean,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("date_time", .{}, .{}, engine_shims, .{});
