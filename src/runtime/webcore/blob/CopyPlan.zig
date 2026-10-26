const CopyPlan = @This();

source_offset: u64,
destination_offset: u64,
limit: u64,
written: u64 = 0,
backward: bool = false,
in_place: bool = false,

pub const Chunk = struct {
    source_offset: u64,
    destination_offset: u64,
    length: usize,
};

pub fn init(source: StoreRange, destination: StoreRange) CopyPlan {
    return .{
        .source_offset = source.offset,
        .destination_offset = destination.offset,
        .limit = @min(source.size, destination.size),
    };
}

pub fn setSameFile(this: *CopyPlan, file_size: u64) void {
    this.in_place = true;
    this.limit = @min(this.limit, file_size -| this.source_offset);
    if (this.source_offset == this.destination_offset) {
        this.written = this.limit;
        return;
    }
    this.backward = this.destination_offset > this.source_offset and
        this.destination_offset - this.source_offset < this.limit;
}

pub fn next(this: *const CopyPlan, capacity: usize) ?Chunk {
    if (this.written == this.limit) return null;
    const length: usize = @intCast(@min(this.limit - this.written, capacity));
    const offset = if (this.backward) this.limit - this.written - length else this.written;
    return .{
        .source_offset = this.source_offset + offset,
        .destination_offset = this.destination_offset + offset,
        .length = length,
    };
}

pub fn advance(this: *CopyPlan, amount: usize) void {
    bun.assert(amount <= this.limit - this.written);
    this.written += amount;
}

const bun = @import("bun");
const StoreRange = @import("./StoreRange.zig");
