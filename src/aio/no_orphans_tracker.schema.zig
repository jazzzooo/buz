const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim(
        "noOrphansTrackerBegin",
        .{
            b.argument("kqueueFd", b.int32, .{}),
            b.argument("rootPid", b.int32, .{}),
        },
        b.none,
        .realm_independent,
    ),
    b.engineShim("noOrphansTrackerReleaseKqueue", .{}, b.none, .realm_independent),
    b.engineShim("noOrphansTrackerScan", .{}, b.none, .realm_independent),
    b.engineShim("noOrphansTrackerRemoveExited", .{b.argument("pid", b.int32, .{})}, b.none, .realm_independent),
    b.engineShim("noOrphansTrackerKill", .{}, b.none, .realm_independent),
};

pub const schema = b.moduleWithEngineShims("no_orphans_tracker", .{}, engine_shims);
