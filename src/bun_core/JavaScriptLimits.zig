var synthetic_allocation_limit: std.atomic.Value(usize) = .init(std.math.maxInt(u32));
var string_allocation_limit: std.atomic.Value(usize) = .init(std.math.maxInt(u32));

pub fn syntheticAllocationLimit() usize {
    return synthetic_allocation_limit.load(.monotonic);
}

pub fn stringAllocationLimit() usize {
    return string_allocation_limit.load(.monotonic);
}

pub fn setSyntheticAllocationLimit(limit: usize) usize {
    const previous = synthetic_allocation_limit.swap(limit, .monotonic);
    string_allocation_limit.store(limit, .monotonic);
    return previous;
}

const std = @import("std");
