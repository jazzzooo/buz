//! The host operating system, architecture, and OS version, detected once at runtime.

os: OperatingSystem,
arch: Architecture,
version: []const u8,

const Platform = @This();

pub const OperatingSystem = enum(u8) { _none, linux, macos, windows, wsl, android, freebsd, _ };
pub const Architecture = enum(u8) { _none, x64, arm, _ };
const platform_arch: Architecture = if (Environment.isAarch64) .arm else .x64;

var osversion_name: [32]u8 = undefined;
fn forMac() Platform {
    @memset(&osversion_name, 0);

    var platform: Platform = .{ .os = .macos, .version = &.{}, .arch = platform_arch };
    var len = osversion_name.len - 1;
    if (std.c.sysctlbyname("kern.osproductversion", &osversion_name, &len, null, 0) == -1) return platform;

    platform.version = std.mem.sliceTo(&osversion_name, 0);
    return platform;
}

var linux_os_name: std.c.utsname = undefined;
var platform_: Platform = undefined;
var linux_kernel_version: Semver.Version = undefined;
const InitState = enum(u8) { uninitialized, initializing, initialized };
var init_state = std.atomic.Value(InitState).init(.uninitialized);

fn initialize() void {
    if (comptime Environment.isMac) {
        platform_ = forMac();
    } else if (comptime Environment.isLinux) {
        platform_ = forLinux();

        const release = std.mem.sliceTo(&linux_os_name.release, 0);
        const sliced_string = Semver.SlicedString.init(release, release);
        const result = Semver.Version.parse(sliced_string);
        linux_kernel_version = result.version.min();
    } else if (comptime Environment.isFreeBSD) {
        platform_ = forFreeBSD();
    } else if (Environment.isWindows) {
        platform_ = .{ .os = .windows, .version = &.{}, .arch = platform_arch };
    }
}

fn fallbackPlatform() Platform {
    return .{
        .os = switch (Environment.os) {
            .mac => .macos,
            .linux => if (Environment.isAndroid) .android else .linux,
            .windows => .windows,
            .freebsd => .freebsd,
            .wasm => ._none,
        },
        .version = &.{},
        .arch = platform_arch,
    };
}

fn ensureInitialized() bool {
    switch (init_state.load(.acquire)) {
        .initialized => return true,
        .initializing => return false,
        .uninitialized => {},
    }

    if (init_state.cmpxchgStrong(.uninitialized, .initializing, .acq_rel, .acquire) != null)
        return init_state.load(.acquire) == .initialized;

    initialize();
    init_state.store(.initialized, .release);
    return true;
}

pub fn forOS() Platform {
    return if (ensureInitialized()) platform_ else fallbackPlatform();
}

pub fn kernelVersion() Semver.Version {
    if (comptime !Environment.isLinux) {
        @compileError("kernelVersion() is only available on Linux");
    }
    return if (ensureInitialized()) linux_kernel_version else .{};
}

fn forLinux() Platform {
    linux_os_name = std.mem.zeroes(@TypeOf(linux_os_name));
    _ = std.c.uname(&linux_os_name);

    // uname's release field contains the kernel version.
    const release = std.mem.sliceTo(&linux_os_name.release, 0);
    return .{
        .os = if (Environment.isAndroid) .android else if (std.mem.indexOf(u8, release, "microsoft") != null) .wsl else .linux,
        .version = release,
        .arch = platform_arch,
    };
}

// Zig std's `std.c.utsname` has no FreeBSD branch; use translate-c's.
var freebsd_os_name: if (Environment.isFreeBSD) bun.c.struct_utsname else void = undefined;
fn forFreeBSD() Platform {
    freebsd_os_name = std.mem.zeroes(@TypeOf(freebsd_os_name));
    _ = bun.c.uname(&freebsd_os_name);
    return .{
        .os = .freebsd,
        .version = std.mem.sliceTo(&freebsd_os_name.release, 0),
        .arch = platform_arch,
    };
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Semver = bun.Semver;
