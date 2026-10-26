pub const JSValue = enum(i64) {
    js_undefined = value_encoding.undefined_value,
    null = value_encoding.null_value,
    true = value_encoding.true_value,
    false = value_encoding.false_value,

    /// Typically means an exception was thrown.
    zero = value_encoding.empty_value,

    _,

    pub const is_pointer = false;
    pub const JSType = @import("./JSType.zig").JSType;

    pub fn format(_: JSValue, _: *std.Io.Writer) !void {
        @compileError("Formatting a JSValue directly is not allowed. Use jsc.ConsoleObject.Formatter");
    }

    pub fn jsNumberWithType(comptime Number: type, number: Number) JSValue {
        if (@typeInfo(Number) == .@"enum") {
            return jsNumberWithType(@typeInfo(Number).@"enum".tag_type, @backingInt(number));
        }
        return switch (comptime Number) {
            JSValue => number,
            u0 => jsNumberFromInt32(0),
            f32, f64 => {
                if (tryConvertToStrictInt32(number)) |int| {
                    return jsNumberFromInt32(int);
                }
                return jsDoubleNumber(number);
            },
            u31, c_ushort, u8, i16, i32, c_int, i8, u16 => jsNumberFromInt32(@as(i32, @intCast(number))),
            c_long, u32, u52, c_uint, i64, isize => jsNumberFromInt64(@as(i64, @intCast(number))),
            usize, u64 => jsNumberFromUint64(@as(u64, @intCast(number))),
            comptime_int => switch (number) {
                0...std.math.maxInt(i32) => jsNumberFromInt32(@as(i32, @intCast(number))),
                else => jsNumberFromInt64(@as(i64, @intCast(number))),
            },
            else => {
                @compileError("Type transformation missing for number of type: " ++ @typeName(Number));
            },
        };
    }

    pub inline fn jsBoolean(i: bool) JSValue {
        return switch (i) {
            false => .false,
            true => .true,
        };
    }

    pub inline fn jsNull() JSValue {
        return JSValue.null;
    }

    pub fn jsNumber(number: anytype) JSValue {
        return jsNumberWithType(@TypeOf(number), number);
    }

    pub fn jsDoubleNumber(i: f64) JSValue {
        return @fromBackingInt(value_encoding.fromDouble(i));
    }
    pub fn jsNumberFromInt32(i: i32) JSValue {
        return @fromBackingInt(value_encoding.fromInt32(i));
    }

    pub fn jsNumberFromInt64(i: i64) JSValue {
        if (i <= std.math.maxInt(i32) and i >= std.math.minInt(i32)) {
            return jsNumberFromInt32(@as(i32, @intCast(i)));
        }

        return jsDoubleNumber(@floatFromInt(i));
    }

    pub fn jsNumberFromUint64(i: u64) JSValue {
        if (i <= std.math.maxInt(i32)) {
            return jsNumberFromInt32(@as(i32, @intCast(i)));
        }

        return jsDoubleNumber(@floatFromInt(i));
    }

    // Mirrors WTF::tryConvertToStrictInt32 (wtf/MathExtras.h). Returns the int32
    // when `value` is exactly representable as i32 (rejects -0.0, NaN, ±Inf,
    // non-integers, out-of-range).
    pub fn tryConvertToStrictInt32(value: f64) ?i32 {
        // Range gate also rejects NaN/±Inf via unordered compare.
        if (!(value >= -2147483648.0 and value < 2147483648.0)) {
            return null;
        }
        const int: i32 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(int)) != value or (int == 0 and std.math.signbit(value))) {
            return null;
        }
        return int;
    }

    pub fn coerceDoubleTruncatingIntoInt64(this: JSValue) i64 {
        return std.math.lossyCast(i64, this.asNumber());
    }

    pub inline fn isUndefined(this: JSValue) bool {
        return this == .js_undefined;
    }
    pub inline fn isNull(this: JSValue) bool {
        return this == .null;
    }
    pub inline fn isEmptyOrUndefinedOrNull(this: JSValue) bool {
        return switch (this) {
            .zero, .js_undefined, .null => true,
            else => false,
        };
    }
    pub fn isUndefinedOrNull(this: JSValue) bool {
        return switch (this) {
            .js_undefined, .null => true,
            else => false,
        };
    }
    pub fn isBoolean(this: JSValue) bool {
        return this == .true or this == .false;
    }

    pub fn isInt32(this: JSValue) bool {
        return value_encoding.isInt32(@backingInt(this));
    }

    pub fn isNumber(this: JSValue) bool {
        return value_encoding.isNumber(@backingInt(this));
    }

    pub fn isDouble(this: JSValue) bool {
        return this.isNumber() and !this.isInt32();
    }

    /// [21.1.2.2 Number.isFinite](https://tc39.es/ecma262/#sec-number.isfinite)
    ///
    /// Returns `false` for non-numbers, `NaN`, `Infinity`, and `-Infinity`
    pub fn isFinite(this: JSValue) bool {
        if (!this.isNumber()) return false;
        return std.math.isFinite(this.asNumber());
    }

    pub inline fn isCell(this: JSValue) bool {
        return value_encoding.isCell(@backingInt(this));
    }

    /// Check if the JSValue is either a signed 32-bit integer or a double and
    /// return the value as a f64
    ///
    /// This does not call `valueOf` on the JSValue
    pub fn getNumber(this: JSValue) ?f64 {
        if (this.isInt32()) {
            return @as(f64, @floatFromInt(this.asInt32()));
        }

        if (isNumber(this)) {
            // Don't need to check for !isInt32() because above
            return asDouble(this);
        }

        return null;
    }

    /// Asserts this is a number, undefined, null, or a boolean
    pub fn asNumber(this: JSValue) f64 {
        bun.assert(this.isNumber() or this.isUndefinedOrNull() or this.isBoolean());
        if (this.isInt32()) {
            return @floatFromInt(this.asInt32());
        } else if (isNumber(this)) {
            // Don't need to check for !isInt32() because above
            return this.asDouble();
        } else if (this.isUndefinedOrNull()) {
            return 0.0;
        } else if (this.isBoolean()) {
            return @floatFromInt(@intFromBool(this.asBoolean()));
        }
        return std.math.nan(f64); // unreachable in assertion builds
    }

    pub fn asDouble(this: JSValue) f64 {
        bun.assert(this.isDouble());
        return value_encoding.asDouble(@backingInt(this));
    }

    pub fn asBoolean(this: JSValue) bool {
        bun.assert(this.isBoolean());
        return this == .true;
    }

    pub fn asInt32(this: JSValue) i32 {
        bun.assert(this.isInt32());
        return value_encoding.asInt32(@backingInt(this));
    }

    pub inline fn ensureStillAlive(this: JSValue) void {
        if (!this.isCell()) return;
        std.mem.doNotOptimizeAway(@backingInt(this));
    }

    pub const backing_int = @typeInfo(JSValue).@"enum".tag_type;
};

const value_encoding = @import("../bindgen/value_encoding.zig");
const std = @import("std");
const bun = @import("bun");
