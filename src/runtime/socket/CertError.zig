const CertError = @This();

error_no: i32 = 0,
code: [:0]const u8 = "",
reason: [:0]const u8 = "",

pub fn init(error_no: i32, code: []const u8, reason: []const u8) bun.OOM!CertError {
    var result: CertError = .{ .error_no = error_no };
    errdefer result.deinit();
    if (error_no != 0) {
        if (code.len != 0) result.code = try bun.default_allocator.dupeSentinel(u8, code, 0);
        if (reason.len != 0) result.reason = try bun.default_allocator.dupeSentinel(u8, reason, 0);
    }
    return result;
}

pub fn deinit(this: *CertError) void {
    if (this.code.len > 0) {
        bun.default_allocator.free(this.code);
    }
    if (this.reason.len > 0) {
        bun.default_allocator.free(this.reason);
    }
    this.* = .{};
}

const bun = @import("bun");
