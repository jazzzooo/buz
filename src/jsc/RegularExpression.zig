pub const RegularExpression = opaque {
    pub const Flags = enum(u16) {
        none = 0,

        hasIndices = 1 << 0,
        global = 1 << 1,
        ignoreCase = 1 << 2,
        multiline = 1 << 3,
        dotAll = 1 << 4,
        unicode = 1 << 5,
        unicodeSets = 1 << 6,
        sticky = 1 << 7,
    };

    pub inline fn init(pattern: bun.String, flags: Flags) error{InvalidRegExp}!*RegularExpression {
        var bound_pattern = bun.bindgen.ThreadSafeDOMString.fromBunString(pattern.dupeRef()) catch bun.outOfMemory();
        defer bound_pattern.deinit();
        const regex: *RegularExpression = @ptrCast(bun.bindgen.Engine(RegularExpressionCreateSchema).call(.{
            .pattern = bound_pattern.operand(),
            .flags = @backingInt(flags),
        }));
        if (!regex.isValid()) {
            regex.deinit();
            return error.InvalidRegExp;
        }
        return regex;
    }

    pub inline fn isValid(this: *RegularExpression) bool {
        return bun.bindgen.Engine(RegularExpressionIsValidSchema).call(.{ .expression = @ptrCast(this) });
    }

    pub inline fn matches(this: *RegularExpression, str: bun.String) bool {
        var string = bun.bindgen.ThreadSafeDOMString.fromBunString(str.dupeRef()) catch bun.outOfMemory();
        defer string.deinit();
        return bun.bindgen.Engine(RegularExpressionMatchesSchema).call(.{
            .expression = @ptrCast(this),
            .string = string.operand(),
        }) >= 0;
    }

    pub inline fn searchRev(this: *RegularExpression, str: bun.String) i32 {
        var string = bun.bindgen.ThreadSafeDOMString.fromBunString(str.dupeRef()) catch bun.outOfMemory();
        defer string.deinit();
        return bun.bindgen.Engine(RegularExpressionSearchRevSchema).call(.{
            .expression = @ptrCast(this),
            .string = string.operand(),
        });
    }

    pub inline fn matchedLength(this: *RegularExpression) i32 {
        return bun.bindgen.Engine(RegularExpressionMatchedLengthSchema).call(.{ .expression = @ptrCast(this) });
    }

    pub inline fn deinit(this: *RegularExpression) void {
        bun.bindgen.Engine(RegularExpressionDestroySchema).call(.{ .expression = @ptrCast(this) });
    }
};

const bun = @import("bun");

const RegularExpressionBindings = bun.bindgen.Module("regular_expressions");
const RegularExpressionCreateSchema = RegularExpressionBindings.engineShim("regularExpressionCreate");
const RegularExpressionDestroySchema = RegularExpressionBindings.engineShim("regularExpressionDestroy");
const RegularExpressionIsValidSchema = RegularExpressionBindings.engineShim("regularExpressionIsValid");
const RegularExpressionMatchedLengthSchema = RegularExpressionBindings.engineShim("regularExpressionMatchedLength");
const RegularExpressionMatchesSchema = RegularExpressionBindings.engineShim("regularExpressionMatches");
const RegularExpressionSearchRevSchema = RegularExpressionBindings.engineShim("regularExpressionSearchRev");
