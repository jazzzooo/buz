pub fn compileTargetFromSlice(global: *jsc.JSGlobalObject, slice_with_bun_prefix: []const u8) bun.JSError!CompileTarget {
    const slice = slice_with_bun_prefix["bun-".len..];
    const target_parsed = CompileTarget.tryFrom(slice) catch {
        return global.throwInvalidArguments("Unknown compile target: {s}", .{slice_with_bun_prefix});
    };
    if (!target_parsed.isSupported()) {
        return global.throwInvalidArguments("Unsupported compile target: {s}", .{slice_with_bun_prefix});
    }

    return target_parsed;
}

const CompileTarget = @import("../options_types/CompileTarget.zig");

const bun = @import("bun");
const jsc = bun.jsc;
