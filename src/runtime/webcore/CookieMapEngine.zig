pub const CookieMap = @import("./CookieMap.zig").CookieMap;

pub const PreparedHeaders = bun.bindgen.Return(CookieMapPrepareHeadersSchema);

pub fn prepare(cookie_map: *CookieMap, global: *bun.jsc.JSGlobalObject) bun.JSError!PreparedHeaders {
    return bun.bindgen.Engine(CookieMapPrepareHeadersSchema).call(global, .{
        .cookieMap = cookie_map,
    });
}

pub fn write(prepared: *PreparedHeaders, response: bun.uws.AnyResponse) bun.uws.ResponseWriteError!void {
    var iterator = prepared.iterator();
    while (iterator.next()) |value| {
        var header = value;
        defer header.deinit();
        const bytes = header.value.unsafePtr("the prepared cookie header owns these bytes until the synchronous socket write returns").latin1;
        try response.writeHeader("Set-Cookie", bytes);
    }
}

pub fn appendToUpgrade(prepared: *PreparedHeaders, preparation: *bun.uws.UpgradePreparation) bun.OOM!void {
    var iterator = prepared.iterator();
    while (iterator.next()) |value| {
        var header = value;
        defer header.deinit();
        const bytes = header.value.unsafePtr("header owns the cookie bytes until upgrade preparation finishes copying them; header.deinit runs afterward").latin1;
        try preparation.addHeader("Set-Cookie", bytes);
    }
}

const bun = @import("bun");
const CookieMapBindings = bun.bindgen.Module("cookie_map");
const CookieMapPrepareHeadersSchema = CookieMapBindings.engineShim("cookieMapPrepareHeaders");
