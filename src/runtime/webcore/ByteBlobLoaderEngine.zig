pub const Loader = @import("./ByteBlobLoader.zig").New(Blob, streams);

pub const tag = ReadableStream.Tag.Blob;
pub const Source = ReadableStream.NewSource(
    Loader,
    "Blob",
    Loader.onStart,
    Loader.onPull,
    Loader.onCancel,
    Loader.deinit,
    null,
    Loader.drain,
    Loader.memoryCost,
    toBufferedValue,
);

pub fn toAnyBlob(this: *Loader) bun.OOM!?Blob.Any {
    const blob = (try takeAnyBlob(this)) orelse return null;
    parent(this).is_closed = true;
    return blob;
}

fn takeAnyBlob(this: *Loader) bun.OOM!?Blob.Any {
    const store_ref = this.store orelse return null;
    const store = store_ref.get();
    if (this.offset == 0 and this.remain == store.size() and !this.content_type_was_set) {
        if (StoreEngine.toAnyBlob(Blob, store)) |blob| {
            _ = this.detachStore();
            defer store.deref();
            return blob;
        }
    }

    store.ref();
    var blob = try Blob.initWithStore(store);
    _ = this.detachStore();
    store.deref();
    blob.offset = this.offset;
    blob.size = this.remain;

    if (this.content_type_was_set) {
        blob.content_type.deinit();
        blob.content_type = this.content_type.take();
        blob.content_type_was_set = true;
        this.content_type_was_set = false;
    }

    return .{ .Blob = blob };
}

pub fn cancel(this: *Loader) void {
    parent(this).cancel();
}

fn toBufferedValue(this: *Loader, action: *BufferAction) void {
    const value = toAnyBlob(this) catch {
        action.outOfMemory();
        return;
    };
    if (value) |blob_value| {
        var blob = blob_value;
        action.fulfill(&blob);
        return;
    }

    action.failBodyAlreadyUsed();
}

fn parent(this: *Loader) *Source {
    return @fieldParentPtr("context", this);
}

const bun = @import("bun");

const Blob = bun.webcore.Blob;
const BufferAction = ReadableStream.BufferAction;
const ReadableStream = bun.webcore.ReadableStream;
const streams = bun.webcore.streams;
const StoreEngine = @import("./blob/StoreEngine.zig");
