pub const FetchHeaders = opaque {
    pub const Owner = bun.bindgen.Return(FetchHeadersCreateEmptySchema);

    pub fn putDefault(this: *FetchHeaders, name_: HTTPHeaderName, value: []const u8, global: *JSGlobalObject) bun.JSError!void {
        if (this.fastHas(name_)) {
            return;
        }

        try this.put(name_, value, global);
    }

    pub fn create(
        global: *JSGlobalObject,
        names: []const api.StringPointer,
        header_values: []const api.StringPointer,
        buffer: []const u8,
    ) bun.JSError!Owner {
        bun.assert(names.len == header_values.len);

        const Entry = std.meta.Elem(@FieldType(bun.bindgen.Args(FetchHeadersCreateFromEntriesSchema), "entries"));
        const native_entries = try bun.default_allocator.alloc(Entry, names.len);
        defer bun.default_allocator.free(native_entries);

        for (names, header_values, native_entries) |name, value, *entry| {
            entry.* = .{
                .name = bun.bindgen.BytesOperand.fromSlice(headerSlice(buffer, name)),
                .value = bun.bindgen.BytesOperand.fromSlice(headerSlice(buffer, value)),
            };
        }

        return bun.bindgen.Engine(FetchHeadersCreateFromEntriesSchema).call(global, .{ .entries = native_entries });
    }

    pub fn isEmpty(this: *FetchHeaders) bool {
        return bun.bindgen.Engine(FetchHeadersIsEmptySchema).call(.{ .headers = this });
    }

    pub fn createFromUWS(
        uws_request: *anyopaque,
    ) bun.OOM!Owner {
        return bun.bindgen.Engine(FetchHeadersCreateFromUWSSchema).call(.{ .request = @ptrCast(uws_request) });
    }

    pub fn createFromH3(
        h3_request: *anyopaque,
    ) bun.OOM!Owner {
        return bun.bindgen.Engine(FetchHeadersCreateFromH3Schema).call(.{ .request = @ptrCast(h3_request) });
    }

    pub const ResponseWriteOptions = struct {
        omit_framing: bool = false,
        omit_connection: bool = false,
    };

    pub fn writeToResponse(headers: *FetchHeaders, response: bun.uws.AnyResponse, options: ResponseWriteOptions) bun.uws.ResponseWriteError!void {
        var entries = try headers.snapshotForHTTP();
        defer entries.deinit();
        var iterator = entries.iterator();
        while (iterator.next()) |converted| {
            var entry = converted;
            defer entry.deinit();
            const name = entry.value.key.unsafePtr("entry owns the header name until the synchronous response write finishes copying it; entry.deinit runs afterward").latin1;
            if (options.omit_framing and
                (bun.strings.eqlCaseInsensitiveASCII(name, "content-length", true) or
                    bun.strings.eqlCaseInsensitiveASCII(name, "transfer-encoding", true))) continue;
            if (options.omit_connection and
                (bun.strings.eqlCaseInsensitiveASCII(name, "connection", true) or
                    bun.strings.eqlCaseInsensitiveASCII(name, "keep-alive", true) or
                    bun.strings.eqlCaseInsensitiveASCII(name, "proxy-connection", true) or
                    bun.strings.eqlCaseInsensitiveASCII(name, "upgrade", true))) continue;
            const value = entry.value.value.unsafePtr("entry owns the header value until the synchronous response write finishes copying it; entry.deinit runs afterward").latin1;
            try response.writeHeader(name, value);
        }
    }

    pub fn createEmpty() bun.OOM!Owner {
        return bun.bindgen.Engine(FetchHeadersCreateEmptySchema).call(.{});
    }

    pub fn appendToUpgrade(headers: *FetchHeaders, preparation: *bun.uws.UpgradePreparation) bun.OOM!void {
        var entries = try headers.snapshotForHTTP();
        defer entries.deinit();
        var iterator = entries.iterator();
        while (iterator.next()) |converted| {
            var entry = converted;
            defer entry.deinit();
            const name = entry.value.key.unsafePtr("entry owns the header name until upgrade preparation finishes copying it; entry.deinit runs afterward").latin1;
            const value = entry.value.value.unsafePtr("entry owns the header value until upgrade preparation finishes copying it; entry.deinit runs afterward").latin1;
            try preparation.addHeader(name, value);
        }
    }

    pub fn createFromPicoHeaders(
        pico_headers: anytype,
    ) bun.OOM!Owner {
        const Entry = std.meta.Elem(@FieldType(bun.bindgen.Args(FetchHeadersCreateFromPicoHeadersSchema), "headers"));
        const pico_entries = try bun.default_allocator.alloc(Entry, pico_headers.list.len);
        defer bun.default_allocator.free(pico_entries);
        for (pico_headers.list, pico_entries) |header, *entry| {
            entry.* = .{ .name = bun.bindgen.BytesOperand.fromSlice(header.name), .value = bun.bindgen.BytesOperand.fromSlice(header.value) };
        }
        return bun.bindgen.Engine(FetchHeadersCreateFromPicoHeadersSchema).call(.{ .headers = pico_entries });
    }

    pub fn put(
        this: *FetchHeaders,
        name_: HTTPHeaderName,
        value: []const u8,
        global: *JSGlobalObject,
    ) bun.JSError!void {
        try bun.bindgen.Engine(FetchHeadersPutSchema).call(global, .{
            .headers = this,
            .name = name_,
            .value = bun.bindgen.BytesOperand.fromSlice(value),
        });
    }

    pub fn get(
        this: *FetchHeaders,
        name_: []const u8,
        global: *JSGlobalObject,
    ) bun.JSError!?bun.String {
        var result = try bun.bindgen.Engine(FetchHeadersGetSchema).call(global, .{
            .headers = this,
            .name = bun.bindgen.BytesOperand.fromSlice(name_),
        });
        if (result) |*value| {
            defer value.deinit();
            return value.takeBunString();
        }
        return null;
    }

    pub fn fastHas(
        this: *FetchHeaders,
        name_: HTTPHeaderName,
    ) bool {
        return bun.bindgen.Engine(FetchHeadersFastHasSchema).call(.{
            .headers = this,
            .name = name_,
        });
    }

    pub fn fastGet(
        this: *FetchHeaders,
        name_: HTTPHeaderName,
    ) bun.OOM!?bun.bindgen.ByteString {
        return bun.bindgen.Engine(FetchHeadersFastGetSchema).call(.{
            .headers = this,
            .name = name_,
        });
    }

    pub const HTTPHeaderName = @FieldType(bun.bindgen.Args(FetchHeadersFastHasSchema), "name");

    pub fn fastRemove(
        this: *FetchHeaders,
        header: HTTPHeaderName,
    ) void {
        bun.bindgen.Engine(FetchHeadersFastRemoveSchema).call(.{
            .headers = this,
            .name = header,
        });
    }

    pub fn retain(this: *FetchHeaders) Owner {
        return bun.bindgen.Engine(FetchHeadersRetainSchema).call(.{ .headers = this });
    }

    pub fn snapshotForHTTP(
        this: *FetchHeaders,
    ) bun.OOM!bun.bindgen.Return(FetchHeadersSnapshotForHTTPSchema) {
        return bun.bindgen.Engine(FetchHeadersSnapshotForHTTPSchema).call(.{ .headers = this });
    }

    pub fn cloneThis(
        this: *FetchHeaders,
    ) bun.OOM!Owner {
        return bun.bindgen.Engine(FetchHeadersCloneNativeSchema).call(.{ .headers = this });
    }
};

fn headerSlice(buffer: []const u8, pointer: api.StringPointer) []const u8 {
    const offset: usize = pointer.offset;
    const length: usize = pointer.length;
    bun.assert(offset <= buffer.len and length <= buffer.len - offset);
    return buffer[offset..][0..length];
}

const std = @import("std");

const bun = @import("bun");

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const api = bun.schema.api;

const FetchHeadersBindings = bun.bindgen.Module("fetch_headers");
const FetchHeadersCreateEmptySchema = FetchHeadersBindings.engineShim("fetchHeadersCreateEmpty");
const FetchHeadersCreateFromEntriesSchema = FetchHeadersBindings.engineShim("fetchHeadersCreateFromEntries");
const FetchHeadersCreateFromPicoHeadersSchema = FetchHeadersBindings.engineShim("fetchHeadersCreateFromPicoHeaders");
const FetchHeadersCreateFromUWSSchema = FetchHeadersBindings.engineShim("fetchHeadersCreateFromUWS");
const FetchHeadersCreateFromH3Schema = FetchHeadersBindings.engineShim("fetchHeadersCreateFromH3");
const FetchHeadersFastHasSchema = FetchHeadersBindings.engineShim("fetchHeadersFastHas");
const FetchHeadersFastGetSchema = FetchHeadersBindings.engineShim("fetchHeadersFastGet");
const FetchHeadersFastRemoveSchema = FetchHeadersBindings.engineShim("fetchHeadersFastRemove");
const FetchHeadersIsEmptySchema = FetchHeadersBindings.engineShim("fetchHeadersIsEmpty");
const FetchHeadersGetSchema = FetchHeadersBindings.engineShim("fetchHeadersGet");
const FetchHeadersPutSchema = FetchHeadersBindings.engineShim("fetchHeadersPut");
const FetchHeadersSnapshotForHTTPSchema = FetchHeadersBindings.engineShim("fetchHeadersSnapshotForHTTP");
const FetchHeadersRetainSchema = FetchHeadersBindings.engineShim("fetchHeadersRetain");
const FetchHeadersCloneNativeSchema = FetchHeadersBindings.engineShim("fetchHeadersCloneNative");
