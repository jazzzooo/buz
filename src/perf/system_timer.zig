fn NewTimer() type {
    if (Environment.isWasm) {
        return struct {
            pub fn start() anyerror!@This() {
                return @This(){};
            }

            pub fn read(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }

            pub fn lap(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }

            pub fn reset(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }
        };
    }

    return struct {
        started_ns: u64,

        pub fn start() !@This() {
            return .{ .started_ns = hw_timer.nowNs() };
        }

        pub fn read(self: *const @This()) u64 {
            return hw_timer.nowNs() -| self.started_ns;
        }

        pub fn lap(self: *@This()) u64 {
            const now = hw_timer.nowNs();
            const elapsed = now -| self.started_ns;
            self.started_ns = now;
            return elapsed;
        }

        pub fn reset(self: *@This()) void {
            self.started_ns = hw_timer.nowNs();
        }
    };
}
pub const Timer = NewTimer();

const Environment = @import("../bun_core/env.zig");
const hw_timer = @import("./hw_timer.zig");
const std = @import("std");
