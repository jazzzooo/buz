//! macOS ImageIO/CoreGraphics backend.

pub const BackendError = codecs.Error || error{BackendUnavailable};

fn check(status: c.BunImageStatus) BackendError!void {
    return switch (status) {
        c.BUN_IMAGE_OK => {},
        c.BUN_IMAGE_UNAVAILABLE => error.BackendUnavailable,
        c.BUN_IMAGE_INVALID_INPUT => error.InvalidDimensions,
        c.BUN_IMAGE_DECODE_FAILED => error.DecodeFailed,
        c.BUN_IMAGE_ENCODE_FAILED => error.EncodeFailed,
        c.BUN_IMAGE_TOO_MANY_PIXELS => error.TooManyPixels,
        c.BUN_IMAGE_OUT_OF_MEMORY => error.OutOfMemory,
        else => @panic("CoreGraphics backend returned an unknown status"),
    };
}

pub fn decode(bytes: []const u8, max_pixels: u64) BackendError!codecs.Decoded {
    var width: u32 = undefined;
    var height: u32 = undefined;
    var image: ?*c.BunCGImage = null;
    try check(c.bun_coregraphics_open(bytes.ptr, bytes.len, max_pixels, &image, &width, &height));
    defer c.bun_coregraphics_image_release(image.?);
    const out = try bun.default_allocator.alloc(u8, try codecs.rgbaByteLength(width, height));
    errdefer bun.default_allocator.free(out);
    try check(c.bun_coregraphics_render(image.?, out.ptr, out.len));
    return .{ .rgba = out, .width = width, .height = height };
}

pub fn encode(rgba: []const u8, width: u32, height: u32, opts: codecs.EncodeOptions) BackendError![]u8 {
    const format: c.BunImageFormat = switch (opts.format) {
        .heic => c.BUN_IMAGE_FORMAT_HEIC,
        .avif => c.BUN_IMAGE_FORMAT_AVIF,
        else => return error.BackendUnavailable,
    };
    var data: ?*const c.BunCGData = null;
    try check(c.bun_coregraphics_encode(rgba.ptr, rgba.len, width, height, format, opts.quality, &data));
    defer c.bun_coregraphics_data_release(data.?);
    return copyData(data.?);
}

fn copyData(data: *const c.BunCGData) bun.OOM![]u8 {
    var len: usize = undefined;
    const bytes = c.bun_coregraphics_data_bytes(data, &len);
    return bun.default_allocator.dupe(u8, bytes[0..len]);
}

/// vImage's default resampler is Lanczos-3; explicit filters use the native kernels.
pub fn scale(src: []const u8, sw: u32, sh: u32, dw: u32, dh: u32, filter: codecs.Filter) BackendError![]u8 {
    if (filter != .lanczos3) return error.BackendUnavailable;
    const out = try bun.default_allocator.alloc(u8, try codecs.rgbaByteLength(dw, dh));
    errdefer bun.default_allocator.free(out);
    try check(c.bun_coregraphics_scale(src.ptr, src.len, sw, sh, out.ptr, out.len, dw, dh));
    return out;
}

pub fn rotate(src: []const u8, width: u32, height: u32, quarters: u32) BackendError![]u8 {
    if (quarters > 3) return error.InvalidDimensions;
    const out = try bun.default_allocator.alloc(u8, try codecs.rgbaByteLength(width, height));
    errdefer bun.default_allocator.free(out);
    try check(c.bun_coregraphics_rotate90(src.ptr, src.len, width, height, out.ptr, out.len, @intCast(quarters)));
    return out;
}

pub fn flip(src: []const u8, width: u32, height: u32, horizontal: bool) BackendError![]u8 {
    const out = try bun.default_allocator.alloc(u8, try codecs.rgbaByteLength(width, height));
    errdefer bun.default_allocator.free(out);
    try check(c.bun_coregraphics_reflect(src.ptr, src.len, width, height, out.ptr, out.len, @intFromBool(horizontal)));
    return out;
}

/// Returns an encoded image container, or null when the pasteboard has no image.
pub fn clipboard() error{ BackendUnavailable, OutOfMemory }!?[]u8 {
    var data: ?*const c.BunCGData = null;
    switch (c.bun_coregraphics_clipboard(&data)) {
        c.BUN_IMAGE_OK => {},
        c.BUN_IMAGE_UNAVAILABLE => return error.BackendUnavailable,
        c.BUN_IMAGE_OUT_OF_MEMORY => return error.OutOfMemory,
        else => @panic("CoreGraphics clipboard returned an unknown status"),
    }
    const owned = data orelse return null;
    defer c.bun_coregraphics_data_release(owned);
    return try copyData(owned);
}

pub fn hasClipboardImage() bool {
    var data: ?*const c.BunCGData = null;
    if (c.bun_coregraphics_clipboard(&data) != c.BUN_IMAGE_OK) return false;
    const owned = data orelse return false;
    c.bun_coregraphics_data_release(owned);
    return true;
}

pub fn clipboardChangeCount() i64 {
    var count: i64 = undefined;
    return if (c.bun_coregraphics_clipboard_change_count(&count) == c.BUN_IMAGE_OK) count else -1;
}

const bun = @import("bun");
const codecs = @import("./codecs.zig");
const c = @import("image-ffi");
