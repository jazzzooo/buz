const SharedBytes = @This();

store: ?bun.bindgen.RefNative(Store, .any),
offset: BlobSize.SizeType,
size: BlobSize.SizeType,

pub fn slice(this: *const SharedBytes) []const u8 {
    if (this.size == 0) return "";
    const store = if (this.store) |value| value.get() else return "";
    var bytes = store.sharedView();
    bytes = bytes[@min(@as(usize, this.offset), bytes.len)..];
    return bytes[0..@min(bytes.len, @as(usize, this.size))];
}

pub fn isBunFile(this: *const SharedBytes) bool {
    return if (this.store) |store| store.get().data == .file else false;
}

pub fn deinit(this: *SharedBytes) void {
    if (this.store) |*store| store.deinit();
    this.store = null;
}

const bun = @import("bun");
const BlobSize = @import("../BlobSize.zig");
const Store = @import("./Store.zig");
