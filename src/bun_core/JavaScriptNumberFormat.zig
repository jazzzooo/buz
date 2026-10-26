const std = @import("std");

pub const buffer_size = 124;

pub fn format(buf: *[buffer_size]u8, number: f64) []const u8 {
    if (std.math.isNan(number)) return copy(buf, "NaN");
    if (number == 0) return copy(buf, "0");
    if (std.math.isInf(number)) return copy(buf, if (number < 0) "-Infinity" else "Infinity");

    var rendered_buf: [std.fmt.float.min_buffer_size]u8 = undefined;
    const rendered = std.fmt.float.render(&rendered_buf, number, .{ .mode = .scientific }) catch unreachable;
    const negative = rendered[0] == '-';
    const unsigned = rendered[@intFromBool(negative)..];
    const exponent_marker = std.mem.indexOfScalar(u8, unsigned, 'e').?;
    const exponent = std.fmt.parseInt(i32, unsigned[exponent_marker + 1 ..], 10) catch unreachable;

    var digits_buf: [24]u8 = undefined;
    var digits_len: usize = 0;
    for (unsigned[0..exponent_marker]) |byte| {
        if (byte == '.') continue;
        digits_buf[digits_len] = byte;
        digits_len += 1;
    }
    const digits = digits_buf[0..digits_len];

    var index: usize = 0;
    if (negative) {
        buf[index] = '-';
        index += 1;
    }

    const decimal_point = exponent + 1;
    if (decimal_point <= -6 or decimal_point > 21) {
        buf[index] = digits[0];
        index += 1;
        if (digits.len > 1) {
            buf[index] = '.';
            index += 1;
            @memcpy(buf[index..][0 .. digits.len - 1], digits[1..]);
            index += digits.len - 1;
        }
        buf[index] = 'e';
        index += 1;
        if (exponent >= 0) {
            buf[index] = '+';
            index += 1;
        }
        const exponent_text = std.fmt.bufPrint(buf[index..], "{d}", .{exponent}) catch unreachable;
        return buf[0 .. index + exponent_text.len];
    }

    if (decimal_point <= 0) {
        @memcpy(buf[index..][0..2], "0.");
        index += 2;
        const zeros: usize = @intCast(-decimal_point);
        @memset(buf[index..][0..zeros], '0');
        index += zeros;
        @memcpy(buf[index..][0..digits.len], digits);
        return buf[0 .. index + digits.len];
    }

    const integer_digits: usize = @intCast(decimal_point);
    if (integer_digits >= digits.len) {
        @memcpy(buf[index..][0..digits.len], digits);
        index += digits.len;
        @memset(buf[index..][0 .. integer_digits - digits.len], '0');
        return buf[0 .. integer_digits + @intFromBool(negative)];
    }

    @memcpy(buf[index..][0..integer_digits], digits[0..integer_digits]);
    index += integer_digits;
    buf[index] = '.';
    index += 1;
    @memcpy(buf[index..][0 .. digits.len - integer_digits], digits[integer_digits..]);
    return buf[0 .. index + digits.len - integer_digits];
}

fn copy(buf: *[buffer_size]u8, value: []const u8) []const u8 {
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

test format {
    const Case = struct { number: f64, expected: []const u8 };
    for ([_]Case{
        .{ .number = 0, .expected = "0" },
        .{ .number = -0.0, .expected = "0" },
        .{ .number = 1, .expected = "1" },
        .{ .number = -1.25, .expected = "-1.25" },
        .{ .number = 0.000001, .expected = "0.000001" },
        .{ .number = 0.0000001, .expected = "1e-7" },
        .{ .number = 1e20, .expected = "100000000000000000000" },
        .{ .number = 1e21, .expected = "1e+21" },
        .{ .number = std.math.inf(f64), .expected = "Infinity" },
        .{ .number = -std.math.inf(f64), .expected = "-Infinity" },
        .{ .number = std.math.nan(f64), .expected = "NaN" },
        .{ .number = 5e-324, .expected = "5e-324" },
        .{ .number = 1.7976931348623157e308, .expected = "1.7976931348623157e+308" },
    }) |case| {
        var buf: [buffer_size]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, format(&buf, case.number));
    }
}
