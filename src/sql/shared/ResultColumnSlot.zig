const ResultColumnSlot = @This();

pub const Value = union(enum) {
    duplicate,
    indexed: u32,
    named: bun.String,
    named_offset: u32,
};

value: Value = .duplicate,

pub fn deinit(this: *ResultColumnSlot) void {
    switch (this.value) {
        .named => |name| name.deref(),
        else => {},
    }
}

const bun = @import("bun");
