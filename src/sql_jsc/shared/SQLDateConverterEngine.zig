const SQLDateConverterEngine = @This();

global_object: *jsc.JSGlobalObject,

pub const Parts = struct {
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
    millisecond: i32,
};

pub fn init(global_object: *jsc.JSGlobalObject) SQLDateConverterEngine {
    return .{
        .global_object = global_object,
    };
}

pub fn fromParts(this: SQLDateConverterEngine, parts: Parts) bun.JSError!f64 {
    return this.global_object.gregorianDateTimeToMS(
        parts.year,
        parts.month,
        parts.day,
        parts.hour,
        parts.minute,
        parts.second,
        parts.millisecond,
    );
}

pub fn parseDate(this: SQLDateConverterEngine, value: *bun.String) bun.JSError!f64 {
    return bun.api.StringEngine.parseDate(value, this.global_object);
}

pub fn formatTime(_: SQLDateConverterEngine, microseconds: i64, output: []u8) usize {
    return bun.bindgen.Engine(PostgresFormatTimeSchema).call(.{
        .microseconds = microseconds,
        .output = output,
    });
}

pub fn formatTimeTz(_: SQLDateConverterEngine, microseconds: i64, tz_offset_seconds: i32, output: []u8) usize {
    return bun.bindgen.Engine(PostgresFormatTimeTzSchema).call(.{
        .microseconds = microseconds,
        .tzOffsetSeconds = tz_offset_seconds,
        .output = output,
    });
}

const bun = @import("bun");
const jsc = bun.jsc;

const DateTimeBindings = bun.bindgen.Module("date_time");
const PostgresFormatTimeSchema = DateTimeBindings.engineShim("postgresFormatTime");
const PostgresFormatTimeTzSchema = DateTimeBindings.engineShim("postgresFormatTimeTz");
