pub const css = @import("../css_parser.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Calc = css.css_values.calc.Calc;

pub const CSSNumber = f32;
pub const CSSNumberFns = struct {
    pub fn parse(input: *css.Parser) Result(CSSNumber) {
        if (input.tryParse(Calc(f32).parse, .{}).asValue()) |calc_value| {
            switch (calc_value) {
                .value => |v| return .{ .result = v.* },
                .number => |n| return .{ .result = n },
                // Numbers are always compatible, so they will always compute to a value.
                else => return .{ .err = input.newCustomError(css.ParserError.invalid_value) },
            }
        }

        return input.expectNumber();
    }

    pub fn toCss(this: *const CSSNumber, dest: *Printer) PrintErr!void {
        return css.serializer.serializeNumericValue(this.*, "", dest);
    }

    pub fn tryFromAngle(_: css.css_values.angle.Angle) ?CSSNumber {
        return null;
    }

    pub fn sign(this: *const CSSNumber) f32 {
        if (this.* == 0.0) return if (css.signfns.isSignPositive(this.*)) 0.0 else 0.0;
        return css.signfns.signum(this.*);
    }
};

/// A CSS [`<integer>`](https://www.w3.org/TR/css-values-4/#integers) value.
pub const CSSInteger = i32;
pub const CSSIntegerFns = struct {
    pub fn parse(input: *css.Parser) Result(CSSInteger) {
        // TODO: calc??
        return input.expectInteger();
    }
    pub inline fn toCss(this: *const CSSInteger, dest: *Printer) PrintErr!void {
        try css.to_css.integer(i32, this.*, dest);
    }
};
