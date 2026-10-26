pub fn freeMemory() u64 {
    return switch (Environment.os) {
        .mac => freeMemoryDarwin(),
        .linux => freeMemoryLinux(),
        .freebsd => freeMemoryFreeBSD(),
        .windows => bun.windows.libuv.uv_get_available_memory(),
        .wasm => @compileError("unsupported os"),
    };
}

fn freeMemoryDarwin() u64 {
    var info: Darwin.VmStatistics = undefined;
    var count: std.c.mach_msg_type_number_t = @intCast(@sizeOf(Darwin.VmStatistics) / @sizeOf(std.c.integer_t));
    if (Darwin.host_statistics(std.c.mach_host_self(), Darwin.host_vm_info, @ptrCast(&info), &count) != 0) return 0;

    const page_size = c.sysconf(c._SC_PAGESIZE);
    if (page_size <= 0) return 0;
    return std.math.mul(u64, info.counts[0], @intCast(page_size)) catch 0;
}

fn freeMemoryLinux() u64 {
    var buffer: [4096]u8 = undefined;
    const file = switch (bun.sys.File.open("/proc/meminfo", bun.O.RDONLY | bun.O.CLOEXEC, 0)) {
        .result => |value| value,
        .err => return freeMemoryLinuxFallback(),
    };
    defer file.close();

    const length = switch (file.readAll(&buffer)) {
        .result => |value| value,
        .err => return freeMemoryLinuxFallback(),
    };
    const available = parseMemAvailable(buffer[0..length]);
    return if (available != 0) available else freeMemoryLinuxFallback();
}

fn parseMemAvailable(contents: []const u8) u64 {
    const field = "MemAvailable:";
    const field_start = std.mem.indexOf(u8, contents, field) orelse return 0;
    const value_start = field_start + field.len;
    const value = std.mem.trimStart(u8, contents[value_start..], " \t");

    var digit_count: usize = 0;
    while (digit_count < value.len and std.ascii.isDigit(value[digit_count])) : (digit_count += 1) {}
    if (digit_count == 0) return 0;

    const suffix = std.mem.trimStart(u8, value[digit_count..], " \t");
    if (!std.mem.startsWith(u8, suffix, "kB")) return 0;

    const kibibytes = std.fmt.parseInt(u64, value[0..digit_count], 10) catch return 0;
    return std.math.mul(u64, kibibytes, 1024) catch 0;
}

fn freeMemoryLinuxFallback() u64 {
    var info: c.struct_sysinfo = undefined;
    if (c.sysinfo(&info) != 0) return 0;
    return @as(u64, @bitCast(info.freeram)) *% @as(c_ulong, @bitCast(@as(c_ulong, info.mem_unit)));
}

fn freeMemoryFreeBSD() u64 {
    var free_pages: c_int = 0;
    var length: usize = @sizeOf(c_int);
    if (std.c.sysctlbyname("vm.stats.vm.v_free_count", &free_pages, &length, null, 0) != 0) return 0;

    const page_size = c.sysconf(c._SC_PAGESIZE);
    if (free_pages <= 0 or page_size <= 0) return 0;
    return std.math.mul(u64, @intCast(free_pages), @intCast(page_size)) catch 0;
}

const Darwin = if (Environment.isMac) struct {
    const host_vm_info = 2;
    const VmStatistics = extern struct {
        counts: [15]std.c.natural_t,
    };

    extern "c" fn host_statistics(
        host_priv: std.c.mach_port_t,
        flavor: std.c.integer_t,
        host_info_out: [*]std.c.integer_t,
        host_info_out_count: *std.c.mach_msg_type_number_t,
    ) std.c.kern_return_t;
} else struct {};

const std = @import("std");

const bun = @import("bun");
const c = bun.c;
const Environment = bun.Environment;
