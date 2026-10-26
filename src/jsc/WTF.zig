pub const WTF = struct {
    /// On Linux, this is min(sysconf(_SC_NPROCESSORS_ONLN), sched_getaffinity count, cgroup cpu.max quota).
    /// Result is cached after the first call.
    pub fn numberOfProcessorCores() u32 {
        return @intCast(@max(1, bun.bindgen.Engine(NumberOfProcessorCoresShim).call(.{})));
    }

    pub fn releaseFastMallocFreeMemory() void {
        bun.bindgen.Engine(ReleaseFastMallocFreeMemoryShim).call(.{});
    }

    pub fn releaseFastMallocFreeMemoryForThisThread() void {
        bun.bindgen.Engine(ReleaseFastMallocFreeMemoryForThisThreadShim).call(.{});
    }

    pub fn prepareForThreadExit() void {
        bun.bindgen.Engine(PrepareForThreadExitShim).call(.{});
    }

    pub fn parseDouble(buf: []const u8) !f64 {
        if (buf.len == 0)
            return error.InvalidCharacter;

        return bun.bindgen.Engine(ParseDoubleShim).call(.{ .bytes = bun.bindgen.BytesOperand.fromSlice(buf) }) orelse error.InvalidCharacter;
    }

    // 2000-01-01T00:00:00.000Z -> 946684800000 (ms)
    pub fn parseES5Date(buf: []const u8) !f64 {
        if (buf.len == 0)
            return error.InvalidDate;

        const ms = bun.bindgen.Engine(ParseES5DateShim).call(.{ .bytes = bun.bindgen.BytesOperand.fromSlice(buf) });
        if (std.math.isFinite(ms))
            return ms;

        return error.InvalidDate;
    }

    pub fn writeHTTPDate(buffer: *[32]u8, timestampMs: u64) []u8 {
        if (timestampMs == 0) {
            return buffer[0..0];
        }

        const res = bun.bindgen.Engine(WriteHTTPDateShim).call(.{
            .output = buffer[0..],
            .timestampMs = timestampMs,
        });
        if (res < 1) {
            return buffer[0..0];
        }

        return buffer[0..@intCast(res)];
    }
};

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const WTFThreadingBindings = bun.bindgen.Module("wtf_threading");
const NumericConversionBindings = bun.bindgen.Module("numeric_conversions");
const DateTimeBindings = bun.bindgen.Module("date_time");
const SystemResourceBindings = bun.bindgen.Module("system_resources");
const NumberOfProcessorCoresShim = SystemResourceBindings.engineShim("numberOfProcessorCores");
const ReleaseFastMallocFreeMemoryShim = WTFThreadingBindings.engineShim("releaseFastMallocFreeMemory");
const ReleaseFastMallocFreeMemoryForThisThreadShim = WTFThreadingBindings.engineShim("releaseFastMallocFreeMemoryForThisThread");
const PrepareForThreadExitShim = WTFThreadingBindings.engineShim("prepareForThreadExit");
const ParseES5DateShim = DateTimeBindings.engineShim("parseES5Date");
const ParseDoubleShim = NumericConversionBindings.engineShim("parseDouble");
const WriteHTTPDateShim = DateTimeBindings.engineShim("writeHTTPDate");
