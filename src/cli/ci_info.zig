// A modified port of ci-info@4.0.0 (https://github.com/watson/ci-info)
// Only gets the CI name, `isPR` is not implemented.
// Main implementation is in src/codegen/ci_info.ts

var detectCIOnce = bun.once(detectUncached);
var isCIOnce = bun.once(isCIUncached);

/// returns true if the current process is running in a CI environment
pub fn isCI(io: std.Io) bool {
    return isCIOnce.call(io, .{io});
}

/// returns the CI name, or null if the CI name could not be determined. note that this can be null even if `isCI` is true.
pub fn detectCIName(io: std.Io) ?[]const u8 {
    return detectCIOnce.call(io, .{});
}

fn isCIUncached(io: std.Io) bool {
    return bun.env_var.CI.get() orelse generated.isCIUncachedGenerated() or detectCIName(io) != null;
}
fn detectUncached() ?[]const u8 {
    if (bun.env_var.CI.get() == false) return null;
    return generated.detectUncachedGenerated();
}

const std = @import("std");
const bun = @import("bun");
const generated = @import("ci_info");
