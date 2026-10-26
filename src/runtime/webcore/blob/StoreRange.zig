const StoreRange = @This();

store: *Store,
offset: SizeType,
size: SizeType,

pub const Owned = struct {
    store: bun.bindgen.RefNative(Store, .any),
    offset: SizeType,
    size: SizeType,

    pub fn init(range: StoreRange) Owned {
        return .{ .store = .init(range.store), .offset = range.offset, .size = range.size };
    }

    pub fn sharedView(this: *const Owned) []const u8 {
        if (this.size == 0) return "";
        const bytes = this.store.get().sharedView();
        const start = @min(@as(usize, this.offset), bytes.len);
        return bytes[start..][0..@min(bytes.len - start, @as(usize, this.size))];
    }

    pub fn storePtr(this: *const Owned) *Store {
        return this.store.get();
    }

    pub fn deinit(this: *Owned) void {
        this.store.deinit();
    }
};

const bun = @import("bun");
const Store = @import("./Store.zig");
const SizeType = @import("../BlobSize.zig").SizeType;
