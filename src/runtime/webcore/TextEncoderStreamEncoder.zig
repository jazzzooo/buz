const TextEncoderStreamEncoder = @This();

bindgen_state: bindgen.ClassState = .{},
pending_lead_surrogate: ?u16 = null,

const log = Output.scoped(.TextEncoderStreamEncoder, .visible);

pub const new = bun.TrivialNew(TextEncoderStreamEncoder);

pub fn destroy(this: *TextEncoderStreamEncoder) void {
    bun.destroy(this);
}

pub fn construct(
    _: bindgen.CallContext(TextEncoderStreamEncoderConstructorSchema),
    _: bindgen.Args(TextEncoderStreamEncoderConstructorSchema),
) bun.JSError!*TextEncoderStreamEncoder {
    return TextEncoderStreamEncoder.new(.{});
}

pub fn encode(
    this: *TextEncoderStreamEncoder,
    _: bindgen.CallContext(TextEncoderStreamEncoderEncodeSchema),
    args: bindgen.Args(TextEncoderStreamEncoderEncodeSchema),
) bun.JSError!bindgen.OwnedBytes {
    const bytes = switch (args.input.unsafePtr("the generated entry frame owns the string until the encoder finishes copying its code units")) {
        .latin1 => |input| try this.encodeLatin1(input),
        .utf16 => |input| try this.encodeUTF16(input),
    };
    return bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
}

fn encodeLatin1(this: *TextEncoderStreamEncoder, input: []const u8) bun.OOM![]u8 {
    log("encodeLatin1: \"{s}\"", .{input});

    if (input.len == 0) return @constCast(&.{});

    const prepend_replacement_len: usize = prepend_replacement: {
        if (this.pending_lead_surrogate != null) {
            this.pending_lead_surrogate = null;
            // no latin1 surrogate pairs
            break :prepend_replacement 3;
        }

        break :prepend_replacement 0;
    };
    var buffer = try std.array_list.Managed(u8).initCapacity(bun.default_allocator, input.len + prepend_replacement_len);
    errdefer buffer.deinit();
    if (prepend_replacement_len > 0) {
        buffer.appendSliceAssumeCapacity(&[3]u8{ 0xef, 0xbf, 0xbd });
    }

    var remain = input;
    while (remain.len > 0) {
        const result = strings.copyLatin1IntoUTF8(buffer.unusedCapacitySlice(), remain);

        buffer.items.len += result.written;
        remain = remain[result.read..];

        if (result.written == 0 and result.read == 0) {
            try buffer.ensureUnusedCapacity(2);
        } else if (buffer.items.len == buffer.capacity and remain.len > 0) {
            try buffer.ensureTotalCapacity(buffer.items.len + remain.len + 1);
        }
    }

    if (comptime Environment.isDebug) {
        // wrap in comptime if so simdutf isn't called in a release build here.
        bun.debugAssert(buffer.items.len == (bun.simdutf.length.utf8.from.latin1(input) + prepend_replacement_len));
    }

    return buffer.toOwnedSlice();
}

fn encodeUTF16(this: *TextEncoderStreamEncoder, input: []const u16) bun.OOM![]u8 {
    log("encodeUTF16: \"{f}\"", .{bun.fmt.utf16(input)});

    if (input.len == 0) return @constCast(&.{});

    const Prepend = struct {
        bytes: [4]u8,
        len: u8,

        pub const replacement: @This() = .{ .bytes = .{ 0xef, 0xbf, 0xbd, 0 }, .len = 3 };

        pub fn fromSequence(seq: [4]u8, length: u8) @This() {
            return .{ .bytes = seq, .len = length };
        }
    };

    var remain = input;

    const prepend: ?Prepend = prepend: {
        if (this.pending_lead_surrogate) |lead| {
            this.pending_lead_surrogate = null;
            const maybe_trail = remain[0];
            if (strings.u16IsTrail(maybe_trail)) {
                const converted = strings.utf16CodepointWithFFFD(&.{ lead, maybe_trail });
                // shouldn't fail because `u16IsTrail` is true and `pending_lead_surrogate` is always
                // a valid lead.
                bun.debugAssert(!converted.fail);

                const sequence = strings.wtf8Sequence(converted.code_point);

                remain = remain[1..];
                if (remain.len == 0) {
                    return bun.default_allocator.dupe(u8, sequence[0..converted.utf8Width()]);
                }

                break :prepend Prepend.fromSequence(sequence, converted.utf8Width());
            }

            break :prepend Prepend.replacement;
        }
        break :prepend null;
    };

    const length = bun.simdutf.length.utf8.from.utf16.le(remain);

    var buf = try std.array_list.Managed(u8).initCapacity(
        bun.default_allocator,
        length + @as(usize, if (prepend) |pre| pre.len else 0),
    );
    errdefer buf.deinit();

    if (prepend) |*pre| {
        buf.appendSliceAssumeCapacity(pre.bytes[0..pre.len]);
    }

    const result = bun.simdutf.convert.utf16.to.utf8.with_errors.le(remain, buf.unusedCapacitySlice());

    switch (result.status) {
        else => {
            const lead_surrogate = try strings.toUTF8ListWithTypeBun(&buf, remain, true);

            if (lead_surrogate) |pending_lead| {
                this.pending_lead_surrogate = pending_lead;
            }

            return buf.toOwnedSlice();
        },
        .success => {
            buf.items.len += result.count;
            return buf.toOwnedSlice();
        },
    }
}

pub fn flush(
    this: *TextEncoderStreamEncoder,
    _: bindgen.CallContext(TextEncoderStreamEncoderFlushSchema),
    _: bindgen.Args(TextEncoderStreamEncoderFlushSchema),
) bun.JSError!bindgen.OwnedBytes {
    const bytes = try flushBytes(this);
    return bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
}

fn flushBytes(this: *TextEncoderStreamEncoder) bun.OOM![]u8 {
    if (this.pending_lead_surrogate == null) return @constCast(&.{});
    this.pending_lead_surrogate = null;
    return bun.default_allocator.dupe(u8, &.{ 0xef, 0xbf, 0xbd });
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const strings = bun.strings;

const bindgen = bun.bindgen;

const TextEncoderStreamEncoderBindingModule = bindgen.Module("TextEncoderStreamEncoder");
const TextEncoderStreamEncoderSchema = TextEncoderStreamEncoderBindingModule.class("TextEncoderStreamEncoder");
const TextEncoderStreamEncoderConstructorSchema = TextEncoderStreamEncoderSchema.constructor();
const TextEncoderStreamEncoderEncodeSchema = TextEncoderStreamEncoderSchema.member("encode");
const TextEncoderStreamEncoderFlushSchema = TextEncoderStreamEncoderSchema.member("flush");
const TextEncoderStreamEncoderClass = bindgen.Class(TextEncoderStreamEncoderSchema, TextEncoderStreamEncoder);

comptime {
    _ = TextEncoderStreamEncoderClass;
}
