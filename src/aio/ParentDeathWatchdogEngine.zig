pub fn install() void {
    if (comptime !bun.Environment.isMac) return;
    ParentDeathWatchdog.registerTrackedProcessBackend(.{
        .begin = beginTracking,
        .release_kqueue = releaseTrackingKqueue,
        .scan = scanTrackedProcesses,
        .remove_exited = removeTrackedProcess,
        .kill = killTrackedProcesses,
    });
}

pub fn beginTracking(kqueue_fd: c_int, root_pid: std.c.pid_t) void {
    Engine(BeginSchema).call(.{
        .kqueueFd = kqueue_fd,
        .rootPid = root_pid,
    });
}

pub fn releaseTrackingKqueue() void {
    Engine(ReleaseKqueueSchema).call(.{});
}

pub fn scanTrackedProcesses() void {
    Engine(ScanSchema).call(.{});
}

pub fn removeTrackedProcess(pid: std.c.pid_t) void {
    Engine(RemoveExitedSchema).call(.{ .pid = pid });
}

pub fn killTrackedProcesses() void {
    Engine(KillSchema).call(.{});
}

const std = @import("std");

const bun = @import("bun");
const ParentDeathWatchdog = @import("./ParentDeathWatchdog.zig");
const Engine = bun.bindgen.Engine;
const Bindings = bun.bindgen.Module("no_orphans_tracker");
const BeginSchema = Bindings.engineShim("noOrphansTrackerBegin");
const ReleaseKqueueSchema = Bindings.engineShim("noOrphansTrackerReleaseKqueue");
const ScanSchema = Bindings.engineShim("noOrphansTrackerScan");
const RemoveExitedSchema = Bindings.engineShim("noOrphansTrackerRemoveExited");
const KillSchema = Bindings.engineShim("noOrphansTrackerKill");
