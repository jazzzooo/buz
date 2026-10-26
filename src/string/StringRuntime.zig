pub const Encoding = enum(u8) {
    latin1,
    utf16,
};

pub const Layout = struct {
    pub fn refCountOffset() usize {
        return Bun__WTFStringImpl__refCountOffset;
    }

    pub fn lengthOffset() usize {
        return Bun__WTFStringImpl__lengthOffset;
    }

    pub fn dataOffset() usize {
        return Bun__WTFStringImpl__dataOffset;
    }

    pub fn flagsOffset() usize {
        return Bun__WTFStringImpl__flagsOffset;
    }

    pub fn flagIs8Bit() u32 {
        return Bun__WTFStringImpl__flagIs8Bit;
    }

    pub fn stringKindMask() u32 {
        return Bun__WTFStringImpl__stringKindMask;
    }

    pub fn refCountStaticFlag() u32 {
        return Bun__WTFStringImpl__refCountStaticFlag;
    }

    pub fn refCountIncrement() u32 {
        return Bun__WTFStringImpl__refCountIncrement;
    }
};

pub const Uninitialized = struct {
    handle: *wire.BindStringHandle,
    data: [*]u8,
};

pub const ExternalRelease = *const fn (?*anyopaque, ?*u8, usize) callconv(.c) void;

pub fn createUninitialized(length: usize, encoding: Encoding) ?Uninitialized {
    var handle: ?*wire.BindStringHandle = null;
    var data: ?[*]u8 = null;
    if (wire.bun_bindgen_string_create_uninitialized(
        length,
        @backingInt(encoding),
        &handle,
        &data,
    ) != 0) return null;
    return .{
        .handle = handle.?,
        .data = data.?,
    };
}

pub fn createExternal(
    data: [*]const u8,
    length: usize,
    encoding: Encoding,
    context: ?*anyopaque,
    release_callback: ExternalRelease,
) ?*wire.BindStringHandle {
    var handle: ?*wire.BindStringHandle = null;
    if (wire.bun_bindgen_string_create_external(
        data,
        length,
        @backingInt(encoding),
        context,
        @ptrCast(release_callback),
        &handle,
    ) != 0) return null;
    return handle.?;
}

pub fn createStaticExternal(data: [*]const u8, length: usize, encoding: Encoding) ?*wire.BindStringHandle {
    var handle: ?*wire.BindStringHandle = null;
    if (wire.bun_bindgen_string_create_static_external(
        data,
        length,
        @backingInt(encoding),
        &handle,
    ) != 0) return null;
    return handle.?;
}

pub fn retain(impl: *anyopaque) void {
    wire.bun_bindgen_string_retain(@ptrCast(impl));
}

pub fn release(impl: *anyopaque) void {
    wire.bun_bindgen_string_release(@ptrCast(impl));
}

pub fn ensureHash(impl: *anyopaque) void {
    wire.bun_bindgen_string_ensure_hash(@ptrCast(impl));
}

const wire = @import("binding_wire");

extern const Bun__WTFStringImpl__refCountOffset: u32;
extern const Bun__WTFStringImpl__lengthOffset: u32;
extern const Bun__WTFStringImpl__dataOffset: u32;
extern const Bun__WTFStringImpl__flagsOffset: u32;
extern const Bun__WTFStringImpl__flagIs8Bit: u32;
extern const Bun__WTFStringImpl__stringKindMask: u32;
extern const Bun__WTFStringImpl__refCountStaticFlag: u32;
extern const Bun__WTFStringImpl__refCountIncrement: u32;
