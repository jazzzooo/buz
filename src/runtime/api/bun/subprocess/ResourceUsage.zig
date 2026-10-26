const ResourceUsage = @This();

const std = @import("std");

bindgen_state: bindgen.ClassState = .{},
rusage: Rusage,

pub fn create(rusage: *const Rusage, context: anytype) bun.JSError!ResourceUsageRef {
    const resource_usage = bun.new(ResourceUsage, .{ .rusage = rusage.* });
    return ResourceUsageClass.adoptResult(resource_usage, context);
}

pub fn getCPUTime(
    this: *ResourceUsage,
    context: bindgen.CallContext(CPUTimeSchema),
    _: bindgen.Args(CPUTimeSchema),
) bun.JSError!bindgen.Return(CPUTimeSchema) {
    _ = context;
    const rusage = this.rusage;

    const user = timevalMicroseconds(rusage.utime);
    const system = timevalMicroseconds(rusage.stime);
    const total = std.math.add(i64, user, system) catch unreachable;

    return .{ .user = user, .system = system, .total = total };
}

fn timevalMicroseconds(value: anytype) i64 {
    const seconds = std.math.mul(i64, value.sec, std.time.us_per_s) catch unreachable;
    return std.math.add(i64, seconds, value.usec) catch unreachable;
}

pub fn getMaxRSS(
    this: *ResourceUsage,
    _: bindgen.CallContext(MaxRSSSchema),
    _: bindgen.Args(MaxRSSSchema),
) bun.JSError!f64 {
    return @floatFromInt(this.rusage.maxrss);
}

pub fn getSharedMemorySize(
    this: *ResourceUsage,
    _: bindgen.CallContext(SharedMemorySizeSchema),
    _: bindgen.Args(SharedMemorySizeSchema),
) bun.JSError!f64 {
    return @floatFromInt(this.rusage.ixrss);
}

pub fn getSwapCount(
    this: *ResourceUsage,
    _: bindgen.CallContext(SwapCountSchema),
    _: bindgen.Args(SwapCountSchema),
) bun.JSError!f64 {
    return @floatFromInt(this.rusage.nswap);
}

pub fn getOps(
    this: *ResourceUsage,
    _: bindgen.CallContext(OpsSchema),
    _: bindgen.Args(OpsSchema),
) bun.JSError!bindgen.Return(OpsSchema) {
    return .{
        .input = @floatFromInt(this.rusage.inblock),
        .output = @floatFromInt(this.rusage.oublock),
    };
}

pub fn getMessages(
    this: *ResourceUsage,
    _: bindgen.CallContext(MessagesSchema),
    _: bindgen.Args(MessagesSchema),
) bun.JSError!bindgen.Return(MessagesSchema) {
    return .{
        .sent = @floatFromInt(this.rusage.msgsnd),
        .received = @floatFromInt(this.rusage.msgrcv),
    };
}

pub fn getSignalCount(
    this: *ResourceUsage,
    _: bindgen.CallContext(SignalCountSchema),
    _: bindgen.Args(SignalCountSchema),
) bun.JSError!f64 {
    return @floatFromInt(this.rusage.nsignals);
}

pub fn getContextSwitches(
    this: *ResourceUsage,
    _: bindgen.CallContext(ContextSwitchesSchema),
    _: bindgen.Args(ContextSwitchesSchema),
) bun.JSError!bindgen.Return(ContextSwitchesSchema) {
    return .{
        .voluntary = @floatFromInt(this.rusage.nvcsw),
        .involuntary = @floatFromInt(this.rusage.nivcsw),
    };
}

pub fn destroy(this: *ResourceUsage) void {
    bun.destroy(this);
}

const bun = @import("bun");
const Rusage = bun.spawn.Rusage;

const bindgen = bun.bindgen;

const BindingModule = bindgen.Module("ResourceUsage");
const ResourceUsageSchema = BindingModule.class("ResourceUsage");
const ResourceUsageRef = bindgen.ClassRef(ResourceUsageSchema);
const ContextSwitchesSchema = ResourceUsageSchema.member("contextSwitches");
const CPUTimeSchema = ResourceUsageSchema.member("cpuTime");
const MaxRSSSchema = ResourceUsageSchema.member("maxRSS");
const MessagesSchema = ResourceUsageSchema.member("messages");
const OpsSchema = ResourceUsageSchema.member("ops");
const SharedMemorySizeSchema = ResourceUsageSchema.member("shmSize");
const SignalCountSchema = ResourceUsageSchema.member("signalCount");
const SwapCountSchema = ResourceUsageSchema.member("swapCount");
const ResourceUsageClass = bindgen.Class(ResourceUsageSchema, ResourceUsage);

comptime {
    _ = ResourceUsageClass;
}
