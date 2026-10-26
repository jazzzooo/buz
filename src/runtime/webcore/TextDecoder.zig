const TextDecoder = @This();

bindgen_state: bindgen.ClassState = .{},

// used for utf8 decoding
buffered: struct {
    buf: [3]u8 = @splat(0),
    len: u2 = 0,

    pub fn slice(this: *@This()) []const u8 {
        return this.buf[0..this.len];
    }
} = .{},

// used for utf16 decoding
lead_byte: ?u8 = null,
lead_surrogate: ?u16 = null,
bom_seen: bool = false,
streaming: bool = false,
codec: ?bindgen.Return(TextCodecCreateSchema) = null,
pending_input: bindgen.OwnedBytes = .empty(),

ignore_bom: bool = false,
fatal: bool = false,
encoding: EncodingLabel = EncodingLabel.@"UTF-8",

pub fn destroy(this: *TextDecoder) void {
    if (this.codec) |*codec| codec.deinit();
    this.pending_input.deinit();
    bun.destroy(this);
}

pub fn getIgnoreBOM(
    this: *TextDecoder,
    _: bindgen.CallContext(TextDecoderIgnoreBOMSchema),
    _: bindgen.Args(TextDecoderIgnoreBOMSchema),
) bun.JSError!bool {
    return this.ignore_bom;
}

pub fn getFatal(
    this: *TextDecoder,
    _: bindgen.CallContext(TextDecoderFatalSchema),
    _: bindgen.Args(TextDecoderFatalSchema),
) bun.JSError!bool {
    return this.fatal;
}

pub fn getEncoding(
    this: *TextDecoder,
    _: bindgen.CallContext(TextDecoderEncodingSchema),
    _: bindgen.Args(TextDecoderEncodingSchema),
) bun.JSError!bindgen.DOMString {
    return bindgen.DOMString.fromUTF8(EncodingLabel.getLabel(this.encoding));
}

fn codeUnitFromBytesUTF16(
    first: u16,
    second: u16,
    comptime big_endian: bool,
) u16 {
    return if (comptime big_endian)
        (first << 8) | second
    else
        first | (second << 8);
}

fn decodeUTF16(
    this: *TextDecoder,
    bytes: []const u8,
    comptime big_endian: bool,
    comptime flush: bool,
) error{OutOfMemory}!union(enum) {
    decoded: std.ArrayListUnmanaged(u16),
    invalid: []const u8,
} {
    var output: std.ArrayListUnmanaged(u16) = .empty;
    errdefer output.deinit(bun.default_allocator);
    try output.ensureTotalCapacity(bun.default_allocator, @divFloor(bytes.len, 2));

    var remain = bytes;
    while (remain.len > 0) {
        const first = this.lead_byte orelse first: {
            const byte = remain[0];
            remain = remain[1..];
            break :first byte;
        };
        this.lead_byte = null;
        if (remain.len == 0) {
            this.lead_byte = first;
            break;
        }
        const code_unit = codeUnitFromBytesUTF16(first, remain[0], big_endian);
        if (this.lead_surrogate) |lead_surrogate| {
            this.lead_surrogate = null;
            if (strings.u16IsTrail(code_unit)) {
                remain = remain[1..];
                try output.appendSlice(bun.default_allocator, &.{ lead_surrogate, code_unit });
                continue;
            }
            if (this.fatal) {
                this.lead_byte = first;
                output.deinit(bun.default_allocator);
                return .{ .invalid = remain };
            }
            try output.append(bun.default_allocator, strings.unicode_replacement);
        }
        remain = remain[1..];
        if (strings.u16IsLead(code_unit)) {
            this.lead_surrogate = code_unit;
        } else if (strings.u16IsTrail(code_unit)) {
            if (this.fatal) {
                output.deinit(bun.default_allocator);
                return .{ .invalid = remain };
            }
            try output.append(bun.default_allocator, strings.unicode_replacement);
        } else {
            try output.append(bun.default_allocator, code_unit);
        }
    }

    if (comptime flush) {
        if (this.lead_byte != null or this.lead_surrogate != null) {
            this.lead_byte = null;
            this.lead_surrogate = null;
            if (this.fatal) {
                output.deinit(bun.default_allocator);
                return .{ .invalid = "" };
            }
            try output.append(bun.default_allocator, strings.unicode_replacement);
        }
    }

    return .{ .decoded = output };
}

pub fn decode(
    this: *TextDecoder,
    context: bindgen.CallContext(TextDecoderDecodeSchema),
    args: bindgen.Args(TextDecoderDecodeSchema),
) bindgen.CallError(TextDecoderDecodeSchema)!bindgen.Return(TextDecoderDecodeSchema) {
    const stream = if (args.options) |options| options.stream else false;
    const input = if (args.input != null) try args.bytes.?.convert(context) else null;
    var input_slice = if (input) |*value|
        value.value.unsafePtr("decodeSlice consumes the entry-frame copy before the binding returns")
    else
        "";
    var joined: ?[]u8 = null;
    defer if (joined) |bytes| bun.default_allocator.free(bytes);
    if (this.streaming and !this.pending_input.isEmpty()) {
        const pending = this.pending_input.slice();
        const length = std.math.add(usize, pending.len, input_slice.len) catch return error.OutOfMemory;
        const bytes = try bun.default_allocator.alloc(u8, length);
        @memcpy(bytes[0..pending.len], pending);
        @memcpy(bytes[pending.len..], input_slice);
        joined = bytes;
        input_slice = bytes;
    }
    var pending_input = bindgen.OwnedBytes.empty();
    defer pending_input.deinit();

    const buffered = this.buffered;
    const lead_byte = this.lead_byte;
    const lead_surrogate = this.lead_surrogate;
    const bom_seen = this.bom_seen;
    const streaming = this.streaming;
    if (!streaming) {
        if (this.codec) |*codec| context.engineIn("text_codecs", "textCodecReset").call(.{ .codec = codec });
        this.buffered.len = 0;
        this.lead_byte = null;
        this.lead_surrogate = null;
        this.bom_seen = false;
    }
    this.streaming = stream;
    const result = switch (!stream) {
        inline else => |flush| this.decodeSlice(context, input_slice, flush, &pending_input),
    } catch |err| {
        if (err == error.OutOfMemory) {
            this.buffered = buffered;
            this.lead_byte = lead_byte;
            this.lead_surrogate = lead_surrogate;
            this.bom_seen = bom_seen;
            this.streaming = streaming;
        } else {
            this.pending_input.deinit();
            this.pending_input = pending_input.take();
        }
        return err;
    };
    this.pending_input.deinit();
    this.pending_input = pending_input.take();
    return switch (result) {
        .decoded => |value| value,
        .invalid => {
            const message = if (this.encoding == .@"UTF-8")
                try bindgen.DOMString.fromUTF8("Invalid byte sequence")
            else
                try bindgen.DOMString.fromBunString(try bun.String.createFormat(
                    "The encoded data was not valid {s} data",
                    .{switch (this.encoding) {
                        .@"UTF-16LE", .@"UTF-16BE" => @tagName(this.encoding),
                        else => EncodingLabel.getLabel(this.encoding),
                    }},
                ));
            return context.fail(.invalid_encoded_data, message);
        },
    };
}

fn stripInitialBOM(this: *TextDecoder, output: *std.ArrayListUnmanaged(u16)) void {
    if (this.ignore_bom or this.bom_seen or output.items.len == 0) return;
    this.bom_seen = true;
    if (output.items[0] == 0xfeff) {
        std.mem.copyForwards(u16, output.items, output.items[1..]);
        output.items.len -= 1;
    }
}

fn decodeSlice(
    this: *TextDecoder,
    context: bindgen.CallContext(TextDecoderDecodeSchema),
    buffer_slice: []const u8,
    comptime flush: bool,
    pending_input: *bindgen.OwnedBytes,
) bun.JSError!union(enum) {
    decoded: bindgen.DOMString,
    invalid,
} {
    switch (this.encoding) {
        EncodingLabel.latin1 => {
            if (strings.isAllASCII(buffer_slice)) {
                return .{ .decoded = try bindgen.DOMString.fromUTF8(buffer_slice) };
            }

            // The latin1 label denotes Windows-1252, which includes code points above U+00FF.
            const out_length = strings.elementLengthCP1252IntoUTF16(buffer_slice);
            const bytes = try bun.default_allocator.alloc(u16, out_length);

            const out = strings.copyCP1252IntoUTF16(bytes, buffer_slice);
            return .{ .decoded = try bindgen.DOMString.fromBunString(
                bun.String.createExternalGloballyAllocatedWithLength(.utf16, bytes, out.written),
            ) };
        },
        EncodingLabel.@"UTF-8" => {
            const input, const deinit = input: {
                if (this.buffered.len > 0) {
                    defer this.buffered.len = 0;
                    const length = std.math.add(usize, buffer_slice.len, this.buffered.len) catch return error.OutOfMemory;
                    const joined = try bun.default_allocator.alloc(u8, length);
                    @memcpy(joined[0..this.buffered.len], this.buffered.slice());
                    @memcpy(joined[this.buffered.len..][0..buffer_slice.len], buffer_slice);
                    break :input .{ joined, true };
                }

                break :input .{ buffer_slice, false };
            };
            defer if (deinit) bun.default_allocator.free(input);

            const decode_result = switch (this.fatal) {
                inline else => |fail_if_invalid| try strings.toUTF16AllocMaybeBuffered(bun.default_allocator, input, fail_if_invalid, flush),
            };
            switch (decode_result) {
                .invalid => |remaining| {
                    pending_input.* = try bindgen.OwnedBytes.fromSlice(remaining);
                    return .invalid;
                },
                .decoded => |value| {
                    var decoded = value.output;
                    bun.assert(this.buffered.len == 0);
                    if (comptime !flush) {
                        this.buffered.buf = value.buffered;
                        this.buffered.len = value.buffered_len;
                    }
                    this.stripInitialBOM(&decoded);
                    return .{ .decoded = try bindgen.DOMString.fromBunString(
                        bun.String.createExternalGloballyAllocatedWithLength(.utf16, decoded.allocatedSlice(), decoded.items.len),
                    ) };
                },
                .ascii => {},
            }

            bun.debugAssert(input.len == 0 or !deinit);

            if (input.len > 0) this.bom_seen = true;
            return .{ .decoded = try bindgen.DOMString.fromUTF8(input) };
        },

        inline .@"UTF-16LE", .@"UTF-16BE" => |utf16_encoding| {
            var decoded = switch (try this.decodeUTF16(buffer_slice, utf16_encoding == .@"UTF-16BE", flush)) {
                .decoded => |output| output,
                .invalid => |remaining| {
                    pending_input.* = try bindgen.OwnedBytes.fromSlice(remaining);
                    return .invalid;
                },
            };

            this.stripInitialBOM(&decoded);
            return .{ .decoded = try bindgen.DOMString.fromBunString(
                bun.String.createExternalGloballyAllocatedWithLength(.utf16, decoded.allocatedSlice(), decoded.items.len),
            ) };
        },

        // Handle all other encodings using WebKit's TextCodec
        else => {
            var decoded = try context.engineIn("text_codecs", "textCodecDecode").call(.{
                .codec = &this.codec.?,
                .data = bun.bindgen.BytesOperand.fromSlice(buffer_slice),
                .flush = flush,
                .stopOnError = this.fatal,
            });
            var result = decoded.result.takeBunString();
            if (decoded.sawError and this.fatal) {
                result.deref();
                return .invalid;
            }

            return .{ .decoded = try bindgen.DOMString.fromBunString(result) };
        },
    }
}

pub fn construct(
    context: bindgen.CallContext(TextDecoderConstructorSchema),
    args: bindgen.Args(TextDecoderConstructorSchema),
) bindgen.CallError(TextDecoderConstructorSchema)!*TextDecoder {
    var decoder = TextDecoder{};
    var encoding = try args.encoding.toUTF8(bun.default_allocator);
    defer encoding.deinit();
    if (EncodingLabel.which(encoding.slice())) |label| {
        decoder.encoding = label;
    } else {
        const message = try bun.String.createFormat(
            "Unsupported encoding label \"{s}\"",
            .{encoding.slice()},
        );
        return context.fail(
            .unsupported_encoding,
            try bindgen.DOMString.fromBunString(message),
        );
    }

    if (args.options) |options| {
        decoder.fatal = options.fatal;
        decoder.ignore_bom = options.ignore_bom;
    }

    const codec_encoding: ?bindgen.EngineArgumentType(TextCodecCreateSchema, "encoding") = switch (decoder.encoding) {
        .@"UTF-8", .@"UTF-16LE", .@"UTF-16BE", .@"windows-1252" => null,
        .IBM866 => .ibm866,
        .@"ISO-8859-3" => .iso_8859_3,
        .@"ISO-8859-6" => .iso_8859_6,
        .@"ISO-8859-7" => .iso_8859_7,
        .@"ISO-8859-8", .@"ISO-8859-8-I" => .iso_8859_8,
        .@"KOI8-U" => .koi8_u,
        .@"windows-874" => .windows_874,
        .@"windows-1253" => .windows_1253,
        .@"windows-1255" => .windows_1255,
        .@"windows-1257" => .windows_1257,
        .Big5 => .big5,
        .@"EUC-JP" => .euc_jp,
        .@"ISO-2022-JP" => .iso_2022_jp,
        .Shift_JIS => .shift_jis,
        .@"EUC-KR" => .euc_kr,
        .@"x-user-defined" => .user_defined,
        .GBK => .gbk,
        .GB18030 => .gb18030,
    };
    if (codec_encoding) |value| decoder.codec = try context.engineIn("text_codecs", "textCodecCreate").call(.{
        .encoding = value,
    });
    errdefer if (decoder.codec) |*codec| codec.deinit();
    const result = try bun.default_allocator.create(TextDecoder);
    result.* = decoder;
    return result;
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;

const bindgen = bun.bindgen;
const EncodingLabel = @import("./EncodingLabel.zig").EncodingLabel;

const TextDecoderBindingModule = bindgen.Module("TextDecoder");
const TextDecoderSchema = TextDecoderBindingModule.class("TextDecoder");
const TextDecoderConstructorSchema = TextDecoderSchema.constructor();
const TextDecoderDecodeSchema = TextDecoderSchema.member("decode");
const TextDecoderEncodingSchema = TextDecoderSchema.member("encoding");
const TextDecoderFatalSchema = TextDecoderSchema.member("fatal");
const TextDecoderIgnoreBOMSchema = TextDecoderSchema.member("ignoreBOM");
const TextDecoderClass = bindgen.Class(TextDecoderSchema, TextDecoder);
const TextCodecCreateSchema = bindgen.Module("text_codecs").engineShim("textCodecCreate");

comptime {
    _ = TextDecoderClass;
}
