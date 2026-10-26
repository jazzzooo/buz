pub const JSArrayIterator = struct {
    i: u64 = 0,
    len: u64,
    array: bun.bindgen.EngineRoot,

    pub fn init(context: anytype, input: *bun.bindgen.EngineRoot) bun.JSError!JSArrayIterator {
        const length = try context.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = input.operand(context) });
        return .{
            .array = input.take(),
            .len = length,
        };
    }

    pub fn deinit(this: *JSArrayIterator) void {
        this.array.deinit();
    }

    pub fn next(this: *JSArrayIterator, context: anytype) bun.JSError!?bun.bindgen.EngineValueResult {
        if (this.i >= this.len) {
            return null;
        }
        const i = this.i;
        this.i += 1;
        return try context.engineIn("property_accessors", "jsValueGetIndex").call(.{
            .value = this.array.operand(context),
            .index = i,
        });
    }
};

const bun = @import("bun");
