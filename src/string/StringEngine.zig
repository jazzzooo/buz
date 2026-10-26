pub fn reportStringSliceExtraMemory(slice: *bun.SliceWithUnderlyingString, vm: *jsc.VM) void {
    if (comptime bun.Environment.isDebug) {
        bun.assert(!slice.did_report_extra_memory_debug);
        slice.did_report_extra_memory_debug = true;
    }
    if (slice.utf8.storage == .allocated) vm.reportExtraMemory(slice.utf8.length());
}

pub fn createAtomASCII(bytes: []const u8) bun.String {
    var result = Engine(BunStringCreateAtomASCIISchema).call(.{ .input = bytes }) orelse return .dead;
    return result.takeBunString();
}

pub fn tryCreateAtomASCII(bytes: []const u8) ?bun.String {
    var result = Engine(BunStringTryCreateAtomASCIISchema).call(.{ .input = bun.bindgen.BytesOperand.fromSlice(bytes) }) orelse return null;
    return result.takeBunString();
}

pub fn createAtomIfPossible(bytes: []const u8) bun.String {
    if (bytes.len == 0) return .empty;
    if (bytes.len < 64) {
        if (tryCreateAtomASCII(bytes)) |atom| return atom;
    }
    return bun.String.cloneUTF8(bytes);
}

pub const ANSISlice = struct { start: usize, length: usize, cursor: usize };

pub const ANSIIterator = struct {
    input: []const u8,
    cursor: usize = 0,

    pub fn init(input: []const u8) ANSIIterator {
        return .{ .input = input };
    }

    pub fn next(this: *ANSIIterator) ?[]const u8 {
        const slice = nextANSISlice(this.input, this.cursor) orelse {
            this.cursor = this.input.len;
            return null;
        };
        this.cursor = slice.cursor;
        return this.input[slice.start..][0..slice.length];
    }
};

pub fn nextANSISlice(input: []const u8, cursor: usize) ?ANSISlice {
    const result = Engine(ANSIIteratorNextSchema).call(.{ .input = bun.bindgen.BytesOperand.fromSlice(input), .cursor = cursor }) orelse return null;
    return .{ .start = result.start, .length = result.length, .cursor = result.cursor };
}

pub fn parseDate(value: *String, global: *jsc.JSGlobalObject) bun.JSError!f64 {
    var string = try bun.bindgen.DOMString.fromBunString(value.dupeRef());
    defer string.deinit();
    return Engine(ParseDateSchema).call(global, .{ .value = string.operand() });
}

pub fn getStringWidth(input: ?bun.bindgen.DOMStringView, count_ansi: bool, ambiguous_is_narrow: bool) usize {
    const string = input orelse return 0;
    return switch (string.unsafePtr("the generated entry frame owns the string until visible-width computation finishes reading it")) {
        .latin1 => |units| if (count_ansi)
            bun.strings.visible.width.latin1(units, !ambiguous_is_narrow)
        else
            bun.strings.visible.width.exclude_ansi_colors.latin1(units, !ambiguous_is_narrow),
        .utf16 => |units| if (count_ansi)
            bun.strings.visible.width.utf16(units, !ambiguous_is_narrow)
        else
            bun.strings.visible.width.exclude_ansi_colors.utf16(units, !ambiguous_is_narrow),
    };
}

pub fn bindGetStringWidth(
    _: bun.bindgen.CallContext(GetStringWidthSchema),
    args: bun.bindgen.Args(GetStringWidthSchema),
) bun.JSError!usize {
    if (args.options) |value| switch (value) {
        .options => |width_options| return getStringWidth(
            args.input,
            width_options.count_ansi_escape_codes,
            width_options.ambiguous_is_narrow,
        ),
        .ignored => {},
    };
    return getStringWidth(args.input, false, true);
}

pub fn jsEscapeRegExp(
    _: bun.bindgen.CallContext(EscapeRegExpSchema),
    args: bun.bindgen.Args(EscapeRegExpSchema),
) bun.JSError!bun.bindgen.DOMString {
    const input = try args.input.toUTF8(bun.default_allocator);
    defer input.deinit();

    var buffer = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer buffer.deinit();
    strings.escapeRegExp(input.slice(), &buffer.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return bun.bindgen.DOMString.fromUTF8(buffer.written());
}

pub fn jsEscapeRegExpForPackageNameMatching(
    _: bun.bindgen.CallContext(EscapeRegExpForPackageNameMatchingSchema),
    args: bun.bindgen.Args(EscapeRegExpForPackageNameMatchingSchema),
) bun.JSError!bun.bindgen.DOMString {
    const input = try args.input.toUTF8(bun.default_allocator);
    defer input.deinit();

    var buffer = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer buffer.deinit();
    strings.escapeRegExpForPackageNameMatching(input.slice(), &buffer.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return bun.bindgen.DOMString.fromUTF8(buffer.written());
}

pub const UnicodeTestingAPIs = struct {
    /// Exercises the sentinel-terminated UTF-16 path used by Windows compile metadata.
    pub fn toUTF16AllocSentinel(
        _: bun.bindgen.CallContext(ToUTF16AllocSentinelSchema),
        args: bun.bindgen.Args(ToUTF16AllocSentinelSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        const bytes = args.bytes.unsafePtr("the generated entry frame owns the copied bytes until UTF-8 decoding creates the result string");
        const result = strings.toUTF16AllocForReal(bun.default_allocator, bytes, false, true) catch return error.OutOfMemory;
        defer bun.default_allocator.free(result);
        bun.assert(result.ptr[result.len] == 0);
        return bun.bindgen.DOMString.fromUTF16(result);
    }
};

pub fn toThreadSafeRefCountDelta(
    _: bun.bindgen.CallContext(ToThreadSafeRefCountDeltaSchema),
    _: bun.bindgen.Args(ToThreadSafeRefCountDeltaSchema),
) bun.JSError!i32 {
    const original = String.cloneLatin1("thread-safe string ownership");
    if (original.tag == .Dead) return error.OutOfMemory;
    defer original.deref();

    const before: i32 = @intCast(original.value.WTFStringImpl.refCount());
    {
        var copy = original.dupeRef();
        defer copy.deref();
        try copy.toThreadSafe();
    }
    const after: i32 = @intCast(original.value.WTFStringImpl.refCount());
    return after - before;
}

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const String = bun.String;
const strings = bun.strings;
const Engine = bun.bindgen.Engine;
const JSStringBindings = bun.bindgen.Module("js_strings");
const StringWidthBindings = bun.bindgen.Module("StringWidth");
const DateTimeBindings = bun.bindgen.Module("date_time");
const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const ParseDateSchema = DateTimeBindings.engineShim("parseDate");
const BunStringCreateAtomASCIISchema = JSStringBindings.engineShim("bunStringCreateAtomASCII");
const BunStringTryCreateAtomASCIISchema = JSStringBindings.engineShim("bunStringTryCreateAtomASCII");
const ANSIIteratorNextSchema = StringWidthBindings.engineShim("ansiIteratorNext");
const GetStringWidthSchema = StringWidthBindings.function("get");
const EscapeRegExpSchema = InternalTestingBindings.function("escapeRegExp");
const EscapeRegExpForPackageNameMatchingSchema = InternalTestingBindings.function("escapeRegExpForPackageNameMatching");
const ToUTF16AllocSentinelSchema = InternalTestingBindings.function("toUTF16AllocSentinel");
const ToThreadSafeRefCountDeltaSchema = InternalTestingBindings.function("BunString_toThreadSafeRefCountDelta");

const GetStringWidthBinding = bun.bindgen.Fn(GetStringWidthSchema, bindGetStringWidth);
const EscapeRegExpBinding = bun.bindgen.Fn(EscapeRegExpSchema, jsEscapeRegExp);
const EscapeRegExpForPackageNameMatchingBinding = bun.bindgen.Fn(EscapeRegExpForPackageNameMatchingSchema, jsEscapeRegExpForPackageNameMatching);
const ToUTF16AllocSentinelBinding = bun.bindgen.Fn(ToUTF16AllocSentinelSchema, UnicodeTestingAPIs.toUTF16AllocSentinel);
const ToThreadSafeRefCountDeltaBinding = bun.bindgen.Fn(ToThreadSafeRefCountDeltaSchema, toThreadSafeRefCountDelta);

comptime {
    _ = GetStringWidthBinding;
    _ = EscapeRegExpBinding;
    _ = EscapeRegExpForPackageNameMatchingBinding;
    _ = ToUTF16AllocSentinelBinding;
    _ = ToThreadSafeRefCountDeltaBinding;
}
