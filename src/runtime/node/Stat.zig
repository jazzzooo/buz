/// Stats and BigIntStats classes from node:fs
pub fn StatType(comptime big: bool) type {
    return struct {
        pub const new = bun.TrivialNew(@This());
        pub const deinit = bun.TrivialDeinit(@This());

        value: Syscall.PosixStat,

        const StatTimespec = bun.timespec;
        const Float = if (big) i64 else f64;
        pub inline fn init(stat_: *const Syscall.PosixStat) @This() {
            return .{ .value = stat_.* };
        }

        inline fn toNanoseconds(ts: StatTimespec) u64 {
            if (ts.sec < 0) {
                return @intCast(@max(bun.timespec.nsSigned(&bun.timespec{
                    .sec = @intCast(ts.sec),
                    .nsec = @intCast(ts.nsec),
                }), 0));
            }

            return bun.timespec.ns(&bun.timespec{
                .sec = @intCast(ts.sec),
                .nsec = @intCast(ts.nsec),
            });
        }

        inline fn toSignedBigInt(value: anytype) i64 {
            const integer = @typeInfo(@TypeOf(value)).int;
            return if (integer.signedness == .signed)
                @intCast(value)
            else
                @bitCast(@as(u64, @intCast(value)));
        }

        fn toTimeMS(ts: StatTimespec) Float {
            // On windows, Node.js purposefully misinterprets time values
            // > On win32, time is stored in uint64_t and starts from 1601-01-01.
            // > libuv calculates tv_sec and tv_nsec from it and converts to signed long,
            // > which causes Y2038 overflow. On the other platforms it is safe to treat
            // > negative values as pre-epoch time.
            const tv_sec = if (Environment.isWindows) @as(u32, @bitCast(@as(i32, @truncate(ts.sec)))) else ts.sec;
            const tv_nsec = if (Environment.isWindows) @as(u32, @bitCast(@as(i32, @truncate(ts.nsec)))) else ts.nsec;
            if (big) {
                const sec: i64 = tv_sec;
                const nsec: i64 = tv_nsec;
                return @as(i64, sec * std.time.ms_per_s) +|
                    @as(i64, @divTrunc(nsec, std.time.ns_per_ms));
            } else {
                // Use floating-point arithmetic to preserve sub-millisecond precision.
                // Node.js returns fractional milliseconds (e.g. 1773248895434.0544).
                const sec_ms: f64 = @as(f64, @floatFromInt(tv_sec)) * 1000.0;
                const nsec_ms: f64 = @as(f64, @floatFromInt(tv_nsec)) / 1_000_000.0;
                return sec_ms + nsec_ms;
            }
        }

        fn getBirthtime(stat_: *const Syscall.PosixStat) StatTimespec {
            return stat_.birthtim;
        }

        pub fn toResult(this: *const @This(), comptime Result: type) Result {
            return statResult(&this.value, Result);
        }

        fn statResult(stat_: *const Syscall.PosixStat, comptime Result: type) Result {
            const aTime = stat_.atime();
            const mTime = stat_.mtime();
            const cTime = stat_.ctime();
            const bTime = getBirthtime(stat_);
            const atime_ms: Float = toTimeMS(aTime);
            const mtime_ms: Float = toTimeMS(mTime);
            const ctime_ms: Float = toTimeMS(cTime);
            const birthtime_ms: Float = toTimeMS(bTime);

            if (big) {
                return .{
                    .brand = true,
                    .dev = toSignedBigInt(stat_.dev),
                    .ino = toSignedBigInt(stat_.ino),
                    .mode = toSignedBigInt(stat_.mode),
                    .nlink = toSignedBigInt(stat_.nlink),
                    .uid = toSignedBigInt(stat_.uid),
                    .gid = toSignedBigInt(stat_.gid),
                    .rdev = toSignedBigInt(stat_.rdev),
                    .size = toSignedBigInt(stat_.size),
                    .blksize = toSignedBigInt(stat_.blksize),
                    .blocks = toSignedBigInt(stat_.blocks),
                    .atimeMs = atime_ms,
                    .mtimeMs = mtime_ms,
                    .ctimeMs = ctime_ms,
                    .birthtimeMs = birthtime_ms,
                    .atimeNs = toNanoseconds(aTime),
                    .mtimeNs = toNanoseconds(mTime),
                    .ctimeNs = toNanoseconds(cTime),
                    .birthtimeNs = toNanoseconds(bTime),
                };
            }

            return .{
                .brand = true,
                .dev = stat_.dev,
                .ino = stat_.ino,
                .mode = stat_.mode,
                .nlink = stat_.nlink,
                .uid = stat_.uid,
                .gid = stat_.gid,
                .rdev = stat_.rdev,
                .size = @bitCast(stat_.size),
                .blksize = @bitCast(stat_.blksize),
                .blocks = @bitCast(stat_.blocks),
                .atimeMs = atime_ms,
                .mtimeMs = mtime_ms,
                .ctimeMs = ctime_ms,
                .birthtimeMs = birthtime_ms,
            };
        }
    };
}
pub const StatsSmall = StatType(false);
pub const StatsBig = StatType(true);

pub fn createStatsForIno(
    _: bun.bindgen.CallContext(CreateStatsForInoSchema),
    args: bun.bindgen.Args(CreateStatsForInoSchema),
) bun.JSError!bun.bindgen.Return(CreateStatsForInoSchema) {
    const Result = bun.bindgen.Return(CreateStatsForInoSchema);
    var stat_ = std.mem.zeroes(Syscall.PosixStat);
    stat_.ino = args.ino;
    return if (args.bigint)
        .{ .bigint_stats = StatsBig.init(&stat_).toResult(@FieldType(Result, "bigint_stats")) }
    else
        .{ .stats = StatsSmall.init(&stat_).toResult(@FieldType(Result, "stats")) };
}

/// Union between `Stats` and `BigIntStats` where the type can be decided at runtime
pub const Stats = union(enum) {
    big: StatsBig,
    small: StatsSmall,

    pub inline fn init(stat_: *const Syscall.PosixStat, big: bool) Stats {
        if (big) {
            return .{ .big = StatsBig.init(stat_) };
        } else {
            return .{ .small = StatsSmall.init(stat_) };
        }
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Syscall = bun.sys;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const CreateStatsForInoSchema = InternalTestingBindings.function("createStatsForIno");
const CreateStatsForInoBinding = bun.bindgen.Fn(CreateStatsForInoSchema, createStatsForIno);

comptime {
    _ = CreateStatsForInoBinding;
}
