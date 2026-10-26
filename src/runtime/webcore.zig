//! VM-free Web API implementations and shared types.

pub const Cookie = @import("./webcore/Cookie.zig");
pub const Headers = @import("./webcore/Headers.zig");
pub const StringPairIterator = @import("./webcore/StringPairIterator.zig");
pub const URLObject = @import("./webcore/URLObject.zig");
pub const URLPattern = @import("./webcore/URLPattern.zig");

pub const prompt = @import("./webcore/prompt.zig");

pub const ByteListPool = bun.ObjectPool(bun.ByteList, null, true, 8);

pub const Crypto = @import("./webcore/Crypto.zig");
pub const EncodingLabel = @import("./webcore/EncodingLabel.zig").EncodingLabel;
pub const TextEncoder = @import("./webcore/TextEncoder.zig");
pub const encoding = @import("./webcore/encoding.zig");
pub const EncodingBindings = @import("./webcore/EncodingBindings.zig");
pub const StreamAlgorithms = @import("./webcore/StreamAlgorithms.zig");
pub const S3StatModule = @import("./webcore/S3Stat.zig");
pub const S3Stat = S3StatModule.S3Stat;
pub const ScriptExecutionContext = @import("./webcore/ScriptExecutionContext.zig");

pub const PathOrFileDescriptor = @import("../io/PathOrFileDescriptor.zig").PathOrFileDescriptor;

pub const DrainResult = union(enum) {
    owned: struct {
        list: std.array_list.Managed(u8),
        size_hint: usize,
    },
    estimated_size: usize,
    empty: void,
    aborted: void,
};

pub const Lifetime = enum {
    clone,
    transfer,
    share,
    temporary,
};

const std = @import("std");
const bun = @import("bun");
