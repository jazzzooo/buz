const std = @import("std");

/// Max int of double precision
/// ~4.5 petabytes is probably enough for awhile
/// We want to avoid coercing to a BigInt because that's a heap allocation
/// and it's generally just harder to use
pub const SizeType = u52;
pub const max_size = std.math.maxInt(SizeType);
