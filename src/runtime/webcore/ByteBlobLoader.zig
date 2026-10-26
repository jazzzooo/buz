pub fn New(comptime Blob: type, comptime Streams: type) type {
    return struct {
        const ByteBlobLoader = @This();

        offset: Blob.SizeType = 0,
        store: ?bun.bindgen.RefNative(Blob.Store, .any) = null,
        chunk_size: Blob.SizeType = 1024 * 1024 * 2,
        remain: Blob.SizeType = 1024 * 1024 * 2,
        done: bool = false,

        /// https://github.com/oven-sh/bun/issues/14988
        /// Necessary for converting a ByteBlobLoader from a Blob -> back into a Blob
        /// Especially for DOMFormData, where the specific content-type might've been serialized into the data.
        content_type: bun.bindgen.OwnedBytes = .empty(),
        content_type_was_set: bool = false,

        pub fn setup(
            this: *ByteBlobLoader,
            blob: *const Blob,
            user_chunk_size: Blob.SizeType,
        ) bun.OOM!void {
            const content_type = if (blob.content_type_was_set)
                try blob.content_type.clone()
            else
                bun.bindgen.OwnedBytes.empty();
            var blobe: Blob = .{
                .offset = blob.offset,
                .size = blob.size,
                .store = blob.store.?.clone(),
            };
            blobe.resolveSize();
            const store = blobe.store.?;
            blobe.store = null;
            this.* = ByteBlobLoader{
                .offset = blobe.offset,
                .store = store,
                .chunk_size = @min(
                    if (user_chunk_size > 0) @min(user_chunk_size, blobe.size) else blobe.size,
                    1024 * 1024 * 2,
                ),
                .remain = blobe.size,
                .done = false,
                .content_type = content_type,
                .content_type_was_set = blob.content_type_was_set,
            };
        }

        pub fn onStart(this: *ByteBlobLoader) Streams.ReadableStart {
            return .{ .chunk_size = this.chunk_size };
        }

        pub fn onPull(this: *ByteBlobLoader, buffer: []u8) Streams.Result {
            const store = (this.store orelse return .{ .done = {} }).get();
            if (this.done) {
                return .{ .done = {} };
            }

            var temporary = store.sharedView();
            temporary = temporary[@min(this.offset, temporary.len)..];

            temporary = temporary[0..@min(buffer.len, @min(temporary.len, this.remain))];
            if (temporary.len == 0) {
                this.clearData();
                this.done = true;
                return .{ .done = {} };
            }

            const copied = @as(Blob.SizeType, @intCast(temporary.len));

            this.remain -|= copied;
            this.offset +|= copied;
            bun.assert(buffer.ptr != temporary.ptr);
            @memcpy(buffer[0..temporary.len], temporary);
            if (this.remain == 0) {
                return .{ .into_array_and_done = .{ .len = copied } };
            }

            return .{ .into_array = .{ .len = copied } };
        }

        pub fn detachStore(this: *ByteBlobLoader) ?*Blob.Store {
            if (this.store) |*store| {
                const pointer = store.take();
                this.store = null;
                this.done = true;
                return pointer;
            }
            return null;
        }

        pub fn onCancel(this: *ByteBlobLoader) void {
            this.clearData();
        }

        pub fn deinit(this: *ByteBlobLoader) void {
            this.clearData();
        }

        pub fn clearData(this: *ByteBlobLoader) void {
            this.content_type.deinit();
            this.content_type_was_set = false;

            if (this.store) |*store| {
                store.deinit();
                this.store = null;
            }
        }

        pub fn drain(this: *ByteBlobLoader) bun.OOM!bun.bindgen.OwnedBytes {
            const store = (this.store orelse return .empty()).get();
            var temporary = store.sharedView();
            temporary = temporary[@min(this.offset, temporary.len)..];
            temporary = temporary[0..@min(16384, @min(temporary.len, this.remain))];

            const bytes = try bun.bindgen.OwnedBytes.fromSlice(temporary);
            this.offset +|= @as(Blob.SizeType, @intCast(temporary.len));
            this.remain -|= @as(Blob.SizeType, @intCast(temporary.len));

            return bytes;
        }

        pub fn memoryCost(this: *const ByteBlobLoader) usize {
            if (this.store) |store| {
                return store.get().memoryCost();
            }
            return 0;
        }
    };
}

const bun = @import("bun");
