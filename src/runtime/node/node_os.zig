fn onlineProcessorCount() i32 {
    return @intCast(c.sysconf(c._SC_NPROCESSORS_ONLN));
}

const CPUTimes = struct {
    user: u64 = 0,
    nice: u64 = 0,
    sys: u64 = 0,
    idle: u64 = 0,
    irq: u64 = 0,
};

fn appendCPU(values: *CPUInfoList, model: []const u8, speed: u64, times: CPUTimes) bun.OOM!void {
    var owned_model = try bun.bindgen.DOMString.fromUTF8(model);
    errdefer owned_model.deinit();
    try values.append(.{
        .model = owned_model,
        .speed = speed,
        .times = .{
            .user = times.user,
            .nice = times.nice,
            .sys = times.sys,
            .idle = times.idle,
            .irq = times.irq,
        },
    });
}

fn deinitCPUInfos(values: []CPUInfo) void {
    for (values) |*value| value.model.deinit();
}

pub fn cpus(io: std.Io) !CpusResult {
    const cpusImpl = switch (Environment.os) {
        .linux => cpusImplLinux,
        .mac => cpusImplLibuv,
        .freebsd => cpusImplFreeBSD,
        .windows => cpusImplLibuv,
        .wasm => @compileError("Unsupported OS"),
    };

    return cpusImpl(io);
}

fn cpusImplLinux(io: std.Io) !CpusResult {
    var values = CPUInfoList.init(bun.default_allocator);
    defer values.deinit();
    errdefer deinitCPUInfos(values.items);
    var num_cpus: u32 = 0;

    var stack_fallback_buffer: [1024 * 8]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var file_buf = std.array_list.Managed(u8).init(stack_fallback.allocator());
    defer file_buf.deinit();

    // Read /proc/stat to get number of CPUs and times
    {
        const file = std.Io.Dir.cwd().openFile(io, "/proc/stat", .{}) catch {
            const count: u32 = @intCast(@max(1, onlineProcessorCount()));
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try appendCPU(&values, "unknown", 0, .{});
            }
            return CpusResult.fromOwnedSlice(values.items);
        };
        defer file.close(io);

        const read = try bun.sys.File.from(file).readToEndWithArrayList(&file_buf, .probably_small).unwrap();
        defer file_buf.clearRetainingCapacity();
        const contents = file_buf.items[0..read];

        var line_iter = std.mem.tokenizeScalar(u8, contents, '\n');

        // Skip the first line (aggregate of all CPUs)
        _ = line_iter.next();

        // Read each CPU line
        while (line_iter.next()) |line| {
            // CPU lines are formatted as `cpu0 user nice sys idle iowait irq softirq`
            var toks = std.mem.tokenizeAny(u8, line, " \t");
            const cpu_name = toks.next();
            if (cpu_name == null or !std.mem.startsWith(u8, cpu_name.?, "cpu")) break; // done with CPUs

            //NOTE: libuv assumes this is fixed on Linux, not sure that's actually the case
            const scale = 10;

            var times = CPUTimes{};
            times.user = scale * try std.fmt.parseInt(u64, toks.next() orelse return error.eol, 10);
            times.nice = scale * try std.fmt.parseInt(u64, toks.next() orelse return error.eol, 10);
            times.sys = scale * try std.fmt.parseInt(u64, toks.next() orelse return error.eol, 10);
            times.idle = scale * try std.fmt.parseInt(u64, toks.next() orelse return error.eol, 10);
            _ = try (toks.next() orelse error.eol); // skip iowait
            times.irq = scale * try std.fmt.parseInt(u64, toks.next() orelse return error.eol, 10);

            try appendCPU(&values, "unknown", 0, times);

            num_cpus += 1;
        }
    }

    // Read /proc/cpuinfo to get model information (optional)
    if (std.Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{})) |file| {
        defer file.close(io);

        const read = try bun.sys.File.from(file).readToEndWithArrayList(&file_buf, .probably_small).unwrap();
        defer file_buf.clearRetainingCapacity();
        const contents = file_buf.items[0..read];

        var line_iter = std.mem.tokenizeScalar(u8, contents, '\n');

        const key_processor = "processor\t: ";
        const key_model_name = "model name\t: ";

        var cpu_index: u32 = 0;
        while (line_iter.next()) |line| {
            if (strings.hasPrefixComptime(line, key_processor)) {
                const digits = std.mem.trim(u8, line[key_processor.len..], " \t\n");
                cpu_index = try std.fmt.parseInt(u32, digits, 10);
                if (cpu_index >= num_cpus) return error.TooManyCPUs;
            } else if (strings.hasPrefixComptime(line, key_model_name)) {
                if (cpu_index >= values.items.len) return error.TooManyCPUs;
                const model_name = line[key_model_name.len..];
                const model = try bun.bindgen.DOMString.fromUTF8(model_name);
                values.items[cpu_index].model.deinit();
                values.items[cpu_index].model = model;
            }
        }
    } else |_| {}

    for (0..num_cpus) |cpu_index| {
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{}/cpufreq/scaling_cur_freq", .{cpu_index});
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            defer file.close(io);

            const read = try bun.sys.File.from(file).readToEndWithArrayList(&file_buf, .probably_small).unwrap();
            defer file_buf.clearRetainingCapacity();
            const contents = file_buf.items[0..read];

            const digits = std.mem.trim(u8, contents, " \n");
            const speed = (std.fmt.parseInt(u64, digits, 10) catch 0) / 1000;

            values.items[cpu_index].speed = speed;
        } else |_| {}
    }

    return CpusResult.fromOwnedSlice(values.items);
}

fn cpusImplFreeBSD(_: std.Io) !CpusResult {
    var ncpu: c_uint = 0;
    var ncpu_len: usize = @sizeOf(c_uint);
    try sysctlByName("hw.ncpu", &ncpu, &ncpu_len);
    if (ncpu == 0) return error.no_processor_info;

    var model_buf: [512]u8 = undefined;
    var model_len: usize = model_buf.len;
    const model = if (sysctlByName("hw.model", &model_buf, &model_len)) |_|
        std.mem.sliceTo(&model_buf, 0)
    else |_|
        "unknown";

    var speed_mhz: c_uint = 0;
    var speed_len: usize = @sizeOf(c_uint);
    sysctlByName("hw.clockrate", &speed_mhz, &speed_len) catch {};

    const cpu_states = 5; // user, nice, sys, intr, idle
    const times_buf = try bun.default_allocator.alloc(c_long, @as(usize, ncpu) * cpu_states);
    defer bun.default_allocator.free(times_buf);
    var times_len: usize = times_buf.len * @sizeOf(c_long);
    try sysctlByName("kern.cp_times", times_buf.ptr, &times_len);

    const ticks = c.sysconf(c._SC_CLK_TCK);
    const mult: u64 = if (ticks > 0) 1000 / @as(u64, @intCast(ticks)) else 1;

    var values = try CPUInfoList.initCapacity(bun.default_allocator, @intCast(ncpu));
    defer values.deinit();
    errdefer deinitCPUInfos(values.items);
    var i: u32 = 0;
    while (i < ncpu) : (i += 1) {
        const off = @as(usize, i) * cpu_states;
        const times = CPUTimes{
            .user = @as(u64, @intCast(@max(times_buf[off + 0], 0))) * mult,
            .nice = @as(u64, @intCast(@max(times_buf[off + 1], 0))) * mult,
            .sys = @as(u64, @intCast(@max(times_buf[off + 2], 0))) * mult,
            .irq = @as(u64, @intCast(@max(times_buf[off + 3], 0))) * mult,
            .idle = @as(u64, @intCast(@max(times_buf[off + 4], 0))) * mult,
        };
        try appendCPU(&values, model, @intCast(speed_mhz), times);
    }
    return CpusResult.fromOwnedSlice(values.items);
}

pub fn cpusImplLibuv(_: std.Io) !CpusResult {
    var cpu_infos: [*]libuv.uv_cpu_info_t = undefined;
    var count: c_int = undefined;
    const err = libuv.uv_cpu_info(&cpu_infos, &count);
    if (err != 0) {
        return error.NoProcessorInfo;
    }
    defer libuv.uv_free_cpu_info(cpu_infos, count);

    var values = try CPUInfoList.initCapacity(bun.default_allocator, @intCast(count));
    defer values.deinit();
    errdefer deinitCPUInfos(values.items);

    for (cpu_infos[0..@intCast(count)]) |cpu_info| {
        const times = CPUTimes{
            .user = cpu_info.cpu_times.user,
            .nice = cpu_info.cpu_times.nice,
            .sys = cpu_info.cpu_times.sys,
            .idle = cpu_info.cpu_times.idle,
            .irq = cpu_info.cpu_times.irq,
        };

        try appendCPU(&values, bun.span(cpu_info.model), @intCast(@max(cpu_info.speed, 0)), times);
    }

    return CpusResult.fromOwnedSlice(values.items);
}

pub fn freemem() u64 {
    return bun.sys.SystemResources.freeMemory();
}

fn noSuchProcessError(syscall: sys.Tag) bun.sys.Error {
    if (comptime Environment.isWindows) {
        return .{
            .errno = @intCast(-libuv.UV_ESRCH),
            .from_libuv = true,
            .syscall = syscall,
        };
    }
    return bun.sys.Error.fromCode(.SRCH, syscall);
}

fn systemErrorFromUV(code: c_int, syscall: sys.Tag) bun.sys.Error {
    if (comptime Environment.isWindows) {
        bun.assert(code < 0);
        return .{
            .errno = @intCast(-code),
            .from_libuv = true,
            .syscall = syscall,
        };
    }
    unreachable;
}

pub fn getPriority(pid: i32) bun.sys.Maybe(i32) {
    if (pid < 0) return .{ .err = noSuchProcessError(.uv_os_getpriority) };
    if (comptime Environment.isWindows) {
        var priority: c_int = undefined;
        const status = libuv.uv_os_getpriority(pid, &priority);
        if (status != 0) return .{ .err = systemErrorFromUV(status, .uv_os_getpriority) };
        return .{ .result = priority };
    }
    std.c._errno().* = 0;
    const result = c.getpriority(c.PRIO_PROCESS, @intCast(pid));
    if (result == -1 and std.c._errno().* != 0)
        return .{ .err = bun.sys.Error.fromCode(bun.sys.getErrno(result), .uv_os_getpriority) };
    return .{ .result = result };
}

fn homedirBytes() bun.OOM!bun.sys.Maybe(bun.bindgen.OwnedBytes) {
    // In Node.js, this is a wrapper around uv_os_homedir.
    if (Environment.isWindows) {
        var out: bun.PathBuffer = undefined;
        var size: usize = out.len;
        const code = libuv.uv_os_homedir(&out, &size).int();
        if (code != 0) {
            return .{ .err = systemErrorFromUV(code, .uv_os_homedir) };
        }
        return .{ .result = try bun.bindgen.OwnedBytes.fromSlice(out[0..size]) };
    } else {

        // The posix implementation of uv_os_homedir first checks the HOME
        // environment variable, then falls back to reading the passwd entry.
        if (bun.env_var.HOME.get()) |home| {
            if (home.len > 0)
                return .{ .result = try bun.bindgen.OwnedBytes.fromSlice(home) };
        }

        // From libuv:
        // > Calling sysconf(_SC_GETPW_R_SIZE_MAX) would get the suggested size, but it
        // > is frequently 1024 or 4096, so we can just use that directly. The pwent
        // > will not usually be large.
        // Instead of always using an allocation, first try a stack allocation
        // of 4096, then fallback to heap.
        var stack_string_bytes: [4096]u8 = undefined;
        var string_bytes: []u8 = &stack_string_bytes;
        defer if (string_bytes.ptr != &stack_string_bytes)
            bun.default_allocator.free(string_bytes);

        var pw: bun.c.passwd = undefined;
        var result: ?*bun.c.passwd = null;

        const ret = while (true) {
            const ret = bun.c.getpwuid_r(
                bun.c.geteuid(),
                &pw,
                string_bytes.ptr,
                string_bytes.len,
                &result,
            );

            if (ret == @backingInt(bun.sys.E.INTR))
                continue;

            // If the system call wants more memory, double it.
            if (ret == @backingInt(bun.sys.E.RANGE)) {
                const len = string_bytes.len;
                if (string_bytes.ptr != &stack_string_bytes) bun.default_allocator.free(string_bytes);
                string_bytes = "";
                string_bytes = try bun.default_allocator.alloc(u8, len * 2);
                continue;
            }

            break ret;
        };

        if (ret != 0) {
            return .{ .err = bun.sys.Error.fromCode(
                @fromBackingInt(@intCast(ret)),
                .uv_os_homedir,
            ) };
        }

        if (result == null) {
            // bionic has no passwd entries for app uids; with HOME also unset
            // (zygote/run-as), return a usable default rather than throwing.
            if (comptime Environment.isAndroid) {
                return .{ .result = try bun.bindgen.OwnedBytes.fromSlice("/data/local/tmp") };
            }
            // in uv__getpwuid_r, null result throws UV_ENOENT.
            return .{ .err = bun.sys.Error.fromCode(
                .NOENT,
                .uv_os_homedir,
            ) };
        }

        return .{ .result = if (pw.pw_dir) |dir|
            try bun.bindgen.OwnedBytes.fromSlice(bun.span(dir))
        else
            bun.bindgen.OwnedBytes.empty() };
    }
}

pub fn homedir() bun.OOM!bun.sys.Maybe(bun.bindgen.DOMString) {
    var bytes = switch (try homedirBytes()) {
        .result => |value| value,
        .err => |err| return .{ .err = err },
    };
    defer bytes.deinit();
    return .{ .result = try bun.bindgen.DOMString.fromUTF8(bytes.slice()) };
}

pub fn hostname() bun.OOM!bun.bindgen.DOMString {
    if (Environment.isWindows) {
        var name_buffer: [129:0]u16 = undefined;
        if (bun.windows.GetHostNameW(&name_buffer, name_buffer.len).toBool()) {
            return bun.bindgen.DOMString.fromUTF16(std.mem.sliceTo(&name_buffer, 0));
        }
        return bun.bindgen.DOMString.fromUTF8("unknown");
    } else {
        var name_buffer: [bun.HOST_NAME_MAX]u8 = undefined;
        return bun.bindgen.DOMString.fromUTF8(std.posix.gethostname(&name_buffer) catch "unknown");
    }
}

pub fn loadavg() [3]f64 {
    const result = switch (bun.Environment.os) {
        .mac => loadavg: {
            var avg: c.struct_loadavg = undefined;
            var size: usize = @sizeOf(@TypeOf(avg));

            sysctlByName("vm.loadavg", &avg, &size) catch break :loadavg [3]f64{ 0, 0, 0 };

            const scale: f64 = @floatFromInt(avg.fscale);
            break :loadavg .{
                if (scale == 0.0) 0 else @as(f64, @floatFromInt(avg.ldavg[0])) / scale,
                if (scale == 0.0) 0 else @as(f64, @floatFromInt(avg.ldavg[1])) / scale,
                if (scale == 0.0) 0 else @as(f64, @floatFromInt(avg.ldavg[2])) / scale,
            };
        },
        .linux => loadavg: {
            var info: c.struct_sysinfo = undefined;
            if (c.sysinfo(&info) == @as(c_int, 0)) {
                break :loadavg [3]f64{
                    std.math.ceil((@as(f64, @floatFromInt(info.loads[0])) / 65536.0) * 100.0) / 100.0,
                    std.math.ceil((@as(f64, @floatFromInt(info.loads[1])) / 65536.0) * 100.0) / 100.0,
                    std.math.ceil((@as(f64, @floatFromInt(info.loads[2])) / 65536.0) * 100.0) / 100.0,
                };
            }
            break :loadavg [3]f64{ 0, 0, 0 };
        },
        .freebsd => loadavg: {
            var avg: [3]f64 = .{ 0, 0, 0 };
            if (c.getloadavg(&avg, 3) != 3) break :loadavg [3]f64{ 0, 0, 0 };
            break :loadavg avg;
        },
        .windows => .{ 0, 0, 0 },
        .wasm => @compileError("TODO"),
    };

    return result;
}

pub const networkInterfaces = switch (Environment.os) {
    .linux, .mac, .freebsd => networkInterfacesPosix,
    .windows => networkInterfacesWindows,
    .wasm => @compileError("Unsupported OS"),
};

const NetworkInterfaceGroup = struct {
    name: []const u8,
    values: std.ArrayListUnmanaged(NetworkInterface) = .empty,
};

const NetworkInterfaceGroups = std.ArrayListUnmanaged(NetworkInterfaceGroup);

fn deinitNetworkInterface(value: *NetworkInterface) void {
    value.address.deinit();
    value.netmask.deinit();
    value.mac.deinit();
    if (value.cidr) |*cidr| cidr.deinit();
}

fn deinitNetworkInterfaceGroups(groups: *NetworkInterfaceGroups) void {
    for (groups.items) |*group| {
        for (group.values.items) |*value| deinitNetworkInterface(value);
        group.values.deinit(bun.default_allocator);
    }
    groups.deinit(bun.default_allocator);
}

fn appendNetworkInterfaceValue(
    groups: *NetworkInterfaceGroups,
    name: []const u8,
    address: []const u8,
    netmask: []const u8,
    family: NetworkInterfaceFamily,
    mac: []const u8,
    internal: bool,
    cidr: ?[]const u8,
    scopeid: ?u32,
) bun.OOM!void {
    var owned_address = try bun.bindgen.DOMString.fromUTF8(address);
    errdefer owned_address.deinit();
    var owned_netmask = try bun.bindgen.DOMString.fromUTF8(netmask);
    errdefer owned_netmask.deinit();
    var owned_mac = try bun.bindgen.DOMString.fromUTF8(mac);
    errdefer owned_mac.deinit();
    var owned_cidr: ?bun.bindgen.DOMString = if (cidr) |value|
        try bun.bindgen.DOMString.fromUTF8(value)
    else
        null;
    errdefer if (owned_cidr) |*value| value.deinit();

    const group: *NetworkInterfaceGroup = for (groups.items) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) break candidate;
    } else group: {
        try groups.append(bun.default_allocator, .{ .name = name });
        break :group &groups.items[groups.items.len - 1];
    };

    try group.values.append(bun.default_allocator, .{
        .address = owned_address,
        .netmask = owned_netmask,
        .family = family,
        .mac = owned_mac,
        .internal = internal,
        .cidr = owned_cidr,
        .scopeid = scopeid,
    });
}

fn appendNetworkInterface(
    groups: *NetworkInterfaceGroups,
    name: []const u8,
    address: SocketAddress,
    netmask: SocketAddress,
    mac: []const u8,
    internal: bool,
) bun.OOM!void {
    var address_buffer: [65]u8 = undefined;
    const address_string = address.formatIp(&address_buffer);
    var netmask_buffer: [65]u8 = undefined;
    const netmask_string = netmask.formatIp(&netmask_buffer);

    const family: NetworkInterfaceFamily = switch (address.family()) {
        .INET => .ipv4,
        .INET6 => .ipv6,
    };
    const suffix: ?u8 = switch (address.family()) {
        .INET => netmaskToCIDRSuffix(netmask.address4()),
        .INET6 => netmaskToCIDRSuffix(@as(u128, @bitCast(netmask.address6()))),
    };
    var cidr_buffer: [72]u8 = undefined;
    const cidr: ?[]const u8 = if (suffix) |value|
        std.fmt.bufPrint(&cidr_buffer, "{s}/{d}", .{ address_string, value }) catch unreachable
    else
        null;

    try appendNetworkInterfaceValue(
        groups,
        name,
        address_string,
        netmask_string,
        family,
        mac,
        internal,
        cidr,
        if (address.family() == .INET6) @intCast(address.scopeId()) else null,
    );
}

fn finishNetworkInterfaces(groups: *NetworkInterfaceGroups) bun.OOM!NetworkInterfacesResult {
    var entries = try NetworkInterfacesResult.Builder.init(groups.items.len);
    errdefer entries.deinit();
    for (groups.items) |*group| {
        var key = try bun.bindgen.DOMString.fromUTF8(group.name);
        errdefer key.deinit();
        const value = try NetworkInterfaceList.fromOwnedSlice(group.values.items);
        group.values.items.len = 0;
        entries.appendOwned(.{ .key = key, .value = value });
    }
    return entries.finish();
}

fn networkInterfacesPosix() !NetworkInterfacesResult {
    var interface_start: ?*c.ifaddrs = null;
    const rc = c.getifaddrs(&interface_start);
    if (rc != 0) {
        const errno = std.posix.errno(rc);
        if (comptime Environment.isAndroid) {
            if (errno == .ACCES or errno == .PERM) {
                var groups: NetworkInterfaceGroups = .empty;
                defer deinitNetworkInterfaceGroups(&groups);
                return finishNetworkInterfaces(&groups);
            }
        }
        return error.NetworkInterfacesQueryFailed;
    }
    defer c.freeifaddrs(interface_start);

    const helpers = struct {
        pub fn skip(iface: *c.ifaddrs) bool {
            if (iface.ifa_flags & c.IFF_RUNNING == 0) return true;
            if (iface.ifa_flags & c.IFF_UP == 0) return true;
            return iface.ifa_addr == null;
        }

        pub fn isLinkLayer(iface: *c.ifaddrs) bool {
            if (iface.ifa_addr == null) return false;
            return if (comptime Environment.isLinux)
                iface.ifa_addr.*.sa_family == std.posix.AF.PACKET
            else if (comptime Environment.isMac or Environment.isFreeBSD)
                iface.ifa_addr.?.*.sa_family == std.posix.AF.LINK
            else
                @compileError("unreachable");
        }

        pub fn isLoopback(iface: *c.ifaddrs) bool {
            return iface.ifa_flags & c.IFF_LOOPBACK == c.IFF_LOOPBACK;
        }
    };

    var groups: NetworkInterfaceGroups = .empty;
    defer deinitNetworkInterfaceGroups(&groups);

    var it = interface_start;
    while (it) |iface| : (it = iface.ifa_next) {
        if (helpers.skip(iface) or helpers.isLinkLayer(iface)) continue;

        const address_pointer = iface.ifa_addr orelse continue;
        const netmask_pointer = iface.ifa_netmask orelse continue;
        const address = SocketAddress.fromPosix(@alignCast(@as(*std.posix.sockaddr, @ptrCast(address_pointer)))) orelse continue;
        const netmask = SocketAddress.fromPosix(@alignCast(@as(*std.posix.sockaddr, @ptrCast(netmask_pointer)))) orelse continue;
        const interface_name = std.mem.sliceTo(iface.ifa_name, 0);

        var mac_buffer: [17]u8 = undefined;
        var mac: []const u8 = "00:00:00:00:00:00";
        var link_it = interface_start;
        const link_address = while (link_it) |link_iface| : (link_it = link_iface.ifa_next) {
            if (helpers.skip(link_iface) or !helpers.isLinkLayer(link_iface)) continue;

            const link_name = std.mem.sliceTo(link_iface.ifa_name, 0);
            if (!strings.hasPrefix(link_name, interface_name)) continue;
            if (link_name.len > interface_name.len and link_name[interface_name.len] != ':') continue;

            if (comptime Environment.isLinux) {
                break @as(?*std.posix.sockaddr.ll, @ptrCast(@alignCast(link_iface.ifa_addr)));
            } else if (comptime Environment.isMac or Environment.isFreeBSD) {
                break @as(?*c.sockaddr_dl, @ptrCast(@alignCast(link_iface.ifa_addr)));
            } else {
                @compileError("unreachable");
            }
        } else null;

        if (link_address) |value| {
            const bytes = if (comptime Environment.isLinux)
                value.addr
            else if (comptime Environment.isMac or Environment.isFreeBSD)
                value.sdl_data[value.sdl_nlen..]
            else
                @compileError("unreachable");
            if (bytes.len >= 6) {
                mac = std.fmt.bufPrint(&mac_buffer, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                }) catch unreachable;
            }
        }

        try appendNetworkInterface(
            &groups,
            interface_name,
            address,
            netmask,
            mac,
            helpers.isLoopback(iface),
        );
    }

    return finishNetworkInterfaces(&groups);
}

fn networkInterfacesWindows() !NetworkInterfacesResult {
    var ifaces: [*]libuv.uv_interface_address_t = undefined;
    var count: c_int = undefined;
    if (libuv.uv_interface_addresses(&ifaces, &count) != 0) {
        return error.NetworkInterfacesQueryFailed;
    }
    defer libuv.uv_free_interface_addresses(ifaces, count);

    var groups: NetworkInterfaceGroups = .empty;
    defer deinitNetworkInterfaceGroups(&groups);

    for (ifaces[0..@intCast(count)]) |iface| {
        const address = SocketAddress.fromPosix(@ptrCast(&iface.address.address4)) orelse continue;
        const netmask = SocketAddress.fromPosix(@ptrCast(&iface.netmask.netmask4)) orelse continue;
        var mac_buffer: [17]u8 = undefined;
        const physical_address = iface.phys_addr;
        const mac = std.fmt.bufPrint(&mac_buffer, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            physical_address[0],
            physical_address[1],
            physical_address[2],
            physical_address[3],
            physical_address[4],
            physical_address[5],
        }) catch unreachable;

        try appendNetworkInterface(
            &groups,
            bun.span(iface.name),
            address,
            netmask,
            mac,
            iface.is_internal != 0,
        );
    }

    return finishNetworkInterfaces(&groups);
}

pub fn release(
    context: bun.bindgen.CallContext(ReleaseSchema),
    args: bun.bindgen.Args(ReleaseSchema),
) bun.JSError!bun.bindgen.DOMString {
    _ = context;
    _ = args;

    var name_buffer: [bun.HOST_NAME_MAX]u8 = undefined;

    const value = switch (Environment.os) {
        .linux => slice: {
            const uts = std.posix.uname();
            const result = std.mem.sliceTo(&uts.release, 0);
            bun.copy(u8, &name_buffer, result);

            break :slice name_buffer[0..result.len];
        },
        .mac, .freebsd => slice: {
            @memset(&name_buffer, 0);

            var size: usize = name_buffer.len;

            if (std.c.sysctlbyname(
                "kern.osrelease",
                &name_buffer,
                &size,
                null,
                0,
            ) == -1) break :slice "unknown";

            break :slice std.mem.sliceTo(&name_buffer, 0);
        },
        .windows => slice: {
            var info: bun.windows.libuv.uv_utsname_s = undefined;
            const err = bun.windows.libuv.uv_os_uname(&info);
            if (err != 0) {
                break :slice "unknown";
            }
            const value = std.mem.sliceTo(&info.release, 0);
            @memcpy(name_buffer[0..value.len], value);
            break :slice name_buffer[0..value.len];
        },
        .wasm => @compileError("unsupported os"),
    };

    return bun.bindgen.DOMString.fromUTF8(value);
}

pub fn setProcessPriority(pid: i32, priority: i32) ?bun.sys.Error {
    if (pid < 0) return noSuchProcessError(.uv_os_setpriority);
    if (comptime bun.Environment.isWindows) {
        const code = libuv.uv_os_setpriority(pid, priority);
        if (code == 0) return null;
        return systemErrorFromUV(code, .uv_os_setpriority);
    }
    const code = c.setpriority(c.PRIO_PROCESS, @intCast(pid), priority);
    if (code == 0) return null;
    return bun.sys.Error.fromCode(bun.sys.getErrno(code), .uv_os_setpriority);
}

pub fn totalmem() u64 {
    switch (bun.Environment.os) {
        .mac => {
            var memory: u64 = 0;
            var size: usize = @sizeOf(@TypeOf(memory));
            sysctlByName("hw.memsize", &memory, &size) catch return 0;
            return memory;
        },
        .linux => {
            var info: c.struct_sysinfo = undefined;
            if (c.sysinfo(&info) == @as(c_int, 0)) return @as(u64, @bitCast(info.totalram)) *% @as(c_ulong, @bitCast(@as(c_ulong, info.mem_unit)));
            return 0;
        },
        .freebsd => {
            var physmem: u64 = 0;
            var size: usize = @sizeOf(u64);
            sysctlByName("hw.physmem", &physmem, &size) catch return 0;
            return physmem;
        },
        .windows => {
            return libuv.uv_get_total_memory();
        },
        .wasm => @compileError("unsupported os"),
    }
}

fn uptimeError(system_error: bun.sys.Error) bun.sys.Error {
    var result = system_error;
    result.node_code = .ERR_SYSTEM_ERROR;
    result.node_message = "failed to get system uptime";
    return result;
}

pub fn uptime(io: std.Io) bun.sys.Maybe(f64) {
    switch (Environment.os) {
        .windows => {
            var uptime_value: f64 = undefined;
            const err = libuv.uv_uptime(&uptime_value);
            if (err != 0) {
                return .{ .err = uptimeError(systemErrorFromUV(err, .uv_uptime)) };
            }
            return .{ .result = uptime_value };
        },
        .mac, .freebsd => {
            var boot_time: std.c.timeval = undefined;
            var size: usize = @sizeOf(@TypeOf(boot_time));
            if (std.c.sysctlbyname("kern.boottime", &boot_time, &size, null, 0) != 0) {
                return .{ .err = uptimeError(bun.sys.Error.fromCode(bun.sys.getErrno(@as(c_int, -1)), .uv_uptime)) };
            }
            return .{ .result = @floatFromInt(bun.realSeconds(io) - boot_time.sec) };
        },
        .linux => {
            var info: c.struct_sysinfo = undefined;
            if (c.sysinfo(&info) == 0)
                return .{ .result = @floatFromInt(info.uptime) };
            return .{ .err = uptimeError(bun.sys.Error.fromCode(bun.sys.getErrno(@as(c_int, -1)), .uv_uptime)) };
        },
        .wasm => @compileError("unsupported os"),
    }
}

fn sysctlByName(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize) error{SysctlFailed}!void {
    if (std.c.sysctlbyname(name, oldp, oldlenp, null, 0) != 0) return error.SysctlFailed;
}

pub fn userInfo(buffer_output: bool) bun.OOM!bun.sys.Maybe(bun.bindgen.Return(UserInfoSchema)) {
    var home_bytes = switch (try homedirBytes()) {
        .result => |value| value,
        .err => |err| return .{ .err = err },
    };
    defer home_bytes.deinit();
    var username_bytes = try bun.bindgen.OwnedBytes.fromSlice(bun.env_var.USER.get() orelse "unknown");
    defer username_bytes.deinit();

    if (comptime Environment.isWindows) {
        if (buffer_output) return .{ .result = .{ .buffer = .{
            .username = username_bytes.take(),
            .uid = -1,
            .gid = -1,
            .shell = null,
            .homedir = home_bytes.take(),
        } } };

        var username = try bun.bindgen.DOMString.fromUTF8(username_bytes.slice());
        errdefer username.deinit();
        var home = try bun.bindgen.DOMString.fromUTF8(home_bytes.slice());
        errdefer home.deinit();
        return .{ .result = .{ .text = .{
            .username = username,
            .uid = -1,
            .gid = -1,
            .shell = null,
            .homedir = home,
        } } };
    }

    var shell_bytes = try bun.bindgen.OwnedBytes.fromSlice(bun.env_var.SHELL.get() orelse "unknown");
    defer shell_bytes.deinit();
    if (buffer_output) return .{ .result = .{ .buffer = .{
        .username = username_bytes.take(),
        .uid = @floatFromInt(c.getuid()),
        .gid = @floatFromInt(c.getgid()),
        .shell = shell_bytes.take(),
        .homedir = home_bytes.take(),
    } } };

    var username = try bun.bindgen.DOMString.fromUTF8(username_bytes.slice());
    errdefer username.deinit();
    var shell = try bun.bindgen.DOMString.fromUTF8(shell_bytes.slice());
    errdefer shell.deinit();
    var home = try bun.bindgen.DOMString.fromUTF8(home_bytes.slice());
    errdefer home.deinit();
    return .{ .result = .{ .text = .{
        .username = username,
        .uid = @floatFromInt(c.getuid()),
        .gid = @floatFromInt(c.getgid()),
        .shell = shell,
        .homedir = home,
    } } };
}

pub fn version() bun.JSError!bun.String {
    var name_buffer: [bun.HOST_NAME_MAX]u8 = undefined;

    const slice: []const u8 = switch (Environment.os) {
        .mac, .freebsd => slice: {
            @memset(&name_buffer, 0);

            var size: usize = name_buffer.len;

            if (std.c.sysctlbyname(
                "kern.version",
                &name_buffer,
                &size,
                null,
                0,
            ) == -1) break :slice "unknown";

            break :slice std.mem.sliceTo(&name_buffer, 0);
        },
        .linux => slice: {
            const uts = std.posix.uname();
            const result = std.mem.sliceTo(&uts.version, 0);
            bun.copy(u8, &name_buffer, result);

            break :slice name_buffer[0..result.len];
        },
        .windows => slice: {
            var info: bun.windows.libuv.uv_utsname_s = undefined;
            const err = bun.windows.libuv.uv_os_uname(&info);
            if (err != 0) {
                break :slice "unknown";
            }
            const slice = std.mem.sliceTo(&info.version, 0);
            @memcpy(name_buffer[0..slice.len], slice);
            break :slice name_buffer[0..slice.len];
        },
        .wasm => @compileError("unsupported os"),
    };

    return bun.String.cloneUTF8(slice);
}

/// Given a netmask returns a CIDR suffix.  Returns null if the mask is not valid.
/// `@TypeOf(mask)` must be one of u32 (IPv4) or u128 (IPv6)
fn netmaskToCIDRSuffix(mask: anytype) ?u8 {
    const T = @TypeOf(mask);
    comptime bun.assert(T == u32 or T == u128);

    const mask_bits = @byteSwap(mask);

    // Validity check: set bits should be left-contiguous
    const first_zero = @clz(~mask_bits);
    const last_one = @bitSizeOf(T) - @ctz(mask_bits);
    if (first_zero < @bitSizeOf(T) and first_zero < last_one) return null;
    return first_zero;
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const c = bun.c;
const strings = bun.strings;
const sys = bun.sys;

const NodeOsBindings = bun.bindgen.Module("node_os");
const ProcessHostBindings = bun.bindgen.Module("ProcessHost");
const CpusSchema = NodeOsBindings.function("cpus");
const CpusResult = bun.bindgen.Return(CpusSchema);
const CPUInfo = bun.bindgen.ResultType(CpusSchema.ReturnType.child);
const CPUInfoList = std.array_list.Managed(CPUInfo);
const FreememSchema = NodeOsBindings.function("freemem");
const AvailableMemorySchema = ProcessHostBindings.function("availableMemory");
const GetPrioritySchema = NodeOsBindings.function("getPriority");
const HomedirSchema = NodeOsBindings.function("homedir");
const HostnameSchema = NodeOsBindings.function("hostname");
const LoadavgSchema = NodeOsBindings.function("loadavg");
const NetworkInterfacesSchema = NodeOsBindings.function("networkInterfaces");
const NetworkInterfacesResult = bun.bindgen.Return(NetworkInterfacesSchema);
const NetworkInterfaceList = bun.bindgen.ResultType(NetworkInterfacesSchema.ReturnType.ValueType);
const NetworkInterface = bun.bindgen.ResultType(NetworkInterfacesSchema.ReturnType.ValueType.child);
const NetworkInterfaceFamily = @FieldType(NetworkInterface, "family");
const ReleaseSchema = NodeOsBindings.function("release");
const TotalmemSchema = NodeOsBindings.function("totalmem");
const UptimeSchema = NodeOsBindings.function("uptime");
const UserInfoSchema = NodeOsBindings.function("userInfo");
const VersionSchema = NodeOsBindings.function("version");
const SetPrioritySchema = NodeOsBindings.function("setPriority");

fn cpusBinding(
    context: bun.bindgen.CallContext(CpusSchema),
    _: bun.bindgen.Args(CpusSchema),
) bun.bindgen.CallError(CpusSchema)!CpusResult {
    return cpus(bun.current_runtime.io()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => context.fail(.query_failed, {}),
    };
}

fn freememBinding(context: bun.bindgen.CallContext(FreememSchema), args: bun.bindgen.Args(FreememSchema)) bun.JSError!u64 {
    _ = context;
    _ = args;
    return freemem();
}

fn availableMemoryBinding(context: bun.bindgen.CallContext(AvailableMemorySchema), args: bun.bindgen.Args(AvailableMemorySchema)) bun.JSError!u64 {
    _ = context;
    _ = args;
    return freemem();
}

fn getPriorityBinding(
    context: bun.bindgen.CallContext(GetPrioritySchema),
    args: bun.bindgen.Args(GetPrioritySchema),
) bun.bindgen.CallError(GetPrioritySchema)!i32 {
    return switch (getPriority(args.pid)) {
        .result => |value| value,
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysErrorWithInfo(err)),
    };
}

fn homedirBinding(
    context: bun.bindgen.CallContext(HomedirSchema),
    _: bun.bindgen.Args(HomedirSchema),
) bun.bindgen.CallError(HomedirSchema)!bun.bindgen.DOMString {
    return switch (try homedir()) {
        .result => |value| value,
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

fn hostnameBinding(_: bun.bindgen.CallContext(HostnameSchema), _: bun.bindgen.Args(HostnameSchema)) bun.JSError!bun.bindgen.DOMString {
    return hostname();
}

fn loadavgBinding(_: bun.bindgen.CallContext(LoadavgSchema), _: bun.bindgen.Args(LoadavgSchema)) bun.JSError!bun.bindgen.Return(LoadavgSchema) {
    const values = loadavg();
    return try bun.bindgen.Return(LoadavgSchema).fromOwnedSlice(&values);
}

fn networkInterfacesBinding(
    context: bun.bindgen.CallContext(NetworkInterfacesSchema),
    _: bun.bindgen.Args(NetworkInterfacesSchema),
) bun.bindgen.CallError(NetworkInterfacesSchema)!NetworkInterfacesResult {
    return networkInterfaces() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => context.fail(.query_failed, {}),
    };
}

fn totalmemBinding(context: bun.bindgen.CallContext(TotalmemSchema), args: bun.bindgen.Args(TotalmemSchema)) bun.JSError!u64 {
    _ = context;
    _ = args;
    return totalmem();
}

fn uptimeBinding(
    context: bun.bindgen.CallContext(UptimeSchema),
    _: bun.bindgen.Args(UptimeSchema),
) bun.bindgen.CallError(UptimeSchema)!f64 {
    return switch (uptime(bun.current_runtime.io())) {
        .result => |value| value,
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

fn stringViewEquals(value: anytype, comptime expected: []const u8) bool {
    if (value.length() != expected.len) return false;
    inline for (expected, 0..) |code_unit, index| {
        if (value.codeUnitAt(index) != code_unit) return false;
    }
    return true;
}

fn userInfoBinding(
    context: bun.bindgen.CallContext(UserInfoSchema),
    args: bun.bindgen.Args(UserInfoSchema),
) bun.bindgen.CallError(UserInfoSchema)!bun.bindgen.Return(UserInfoSchema) {
    const buffer_output = if (args.options) |options| stringViewEquals(options.encoding, "buffer") else false;
    return switch (try userInfo(buffer_output)) {
        .result => |value| value,
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

fn versionBinding(context: bun.bindgen.CallContext(VersionSchema), args: bun.bindgen.Args(VersionSchema)) bun.JSError!bun.bindgen.DOMString {
    _ = context;
    _ = args;
    var value = try version();
    defer value.deref();
    const utf8 = try value.toUTF8(bun.default_allocator);
    defer utf8.deinit();
    return bun.bindgen.DOMString.fromUTF8(utf8.slice());
}

fn setPriorityBinding(
    context: bun.bindgen.CallContext(SetPrioritySchema),
    args: bun.bindgen.Args(SetPrioritySchema),
) bun.bindgen.CallError(SetPrioritySchema)!void {
    const failure = switch (args) {
        .with_pid => |values| setProcessPriority(values.pid, values.priority),
        .current => |values| setProcessPriority(0, values.priority),
    };
    if (failure) |err| {
        return context.fail(.system, try bun.bindgen.SystemError.fromSysErrorWithInfo(err));
    }
}

const CpusBinding = bun.bindgen.Fn(CpusSchema, cpusBinding);
const FreememBinding = bun.bindgen.Fn(FreememSchema, freememBinding);
const AvailableMemoryBinding = bun.bindgen.Fn(AvailableMemorySchema, availableMemoryBinding);
const GetPriorityBinding = bun.bindgen.Fn(GetPrioritySchema, getPriorityBinding);
const HomedirBinding = bun.bindgen.Fn(HomedirSchema, homedirBinding);
const HostnameBinding = bun.bindgen.Fn(HostnameSchema, hostnameBinding);
const LoadavgBinding = bun.bindgen.Fn(LoadavgSchema, loadavgBinding);
const NetworkInterfacesBinding = bun.bindgen.Fn(NetworkInterfacesSchema, networkInterfacesBinding);
const ReleaseBinding = bun.bindgen.Fn(ReleaseSchema, release);
const TotalmemBinding = bun.bindgen.Fn(TotalmemSchema, totalmemBinding);
const UptimeBinding = bun.bindgen.Fn(UptimeSchema, uptimeBinding);
const UserInfoBinding = bun.bindgen.Fn(UserInfoSchema, userInfoBinding);
const VersionBinding = bun.bindgen.Fn(VersionSchema, versionBinding);
const SetPriorityBinding = bun.bindgen.Fn(SetPrioritySchema, setPriorityBinding);

comptime {
    _ = CpusBinding;
    _ = FreememBinding;
    _ = AvailableMemoryBinding;
    _ = GetPriorityBinding;
    _ = HomedirBinding;
    _ = HostnameBinding;
    _ = LoadavgBinding;
    _ = NetworkInterfacesBinding;
    _ = ReleaseBinding;
    _ = TotalmemBinding;
    _ = UptimeBinding;
    _ = UserInfoBinding;
    _ = VersionBinding;
    _ = SetPriorityBinding;
}

const libuv = bun.windows.libuv;
const SocketAddress = @import("../socket/SocketAddressValue.zig");
