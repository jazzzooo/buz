pub fn handleErrors(load_lockfile: Lockfile.LoadResult, pm: *PackageManager) void {
    if (load_lockfile == .not_found) {
        if (pm.options.log_level != .silent) {
            Output.errGeneric("Lockfile not found", .{});
        }
        Global.exit(1);
    }

    if (load_lockfile == .err) {
        if (pm.options.log_level != .silent) {
            Output.errGeneric("Error loading lockfile: {s}", .{@errorName(load_lockfile.err.value)});
        }
        Global.exit(1);
    }
}

const Lockfile = @import("../install/lockfile.zig");

const bun = @import("bun");
const Global = bun.Global;
const Output = bun.Output;
const PackageManager = bun.install.PackageManager;
