pub const WTFStringImpl = *WTFStringImplStruct;

pub const WTFStringImplStruct = opaque {
    fn field(this: WTFStringImpl, comptime T: type, offset: usize) *const T {
        return @ptrFromInt(@intFromPtr(this) + offset);
    }

    fn rawRefCount(this: WTFStringImpl) u32 {
        return @atomicLoad(u32, this.field(u32, runtime.Layout.refCountOffset()), .monotonic);
    }

    fn flags(this: WTFStringImpl) u32 {
        return this.field(u32, runtime.Layout.flagsOffset()).*;
    }

    fn data(this: WTFStringImpl) [*]const u8 {
        return this.field([*]const u8, runtime.Layout.dataOffset()).*;
    }

    // ---------------------------------------------------------------------

    pub fn refCount(this: WTFStringImpl) u32 {
        return this.rawRefCount() / runtime.Layout.refCountIncrement();
    }

    pub fn memoryCost(this: WTFStringImpl) usize {
        return this.byteLength();
    }

    pub fn isStatic(this: WTFStringImpl) bool {
        return this.rawRefCount() & runtime.Layout.refCountStaticFlag() != 0;
    }

    pub fn byteLength(this: WTFStringImpl) usize {
        return if (this.is8Bit()) this.length() else this.length() * 2;
    }

    pub fn isThreadSafe(this: WTFStringImpl) bool {
        return this.flags() & runtime.Layout.stringKindMask() == 0;
    }

    pub fn byteSlice(this: WTFStringImpl) []const u8 {
        return this.data()[0..this.byteLength()];
    }

    pub inline fn is8Bit(self: WTFStringImpl) bool {
        return (self.flags() & runtime.Layout.flagIs8Bit()) != 0;
    }

    pub inline fn length(self: WTFStringImpl) u32 {
        return self.field(u32, runtime.Layout.lengthOffset()).*;
    }

    pub inline fn utf16Slice(self: WTFStringImpl) []const u16 {
        bun.assert(!is8Bit(self));
        const ptr: [*]const u16 = @ptrCast(@alignCast(self.data()));
        return ptr[0..length(self)];
    }

    pub inline fn latin1Slice(self: WTFStringImpl) []const u8 {
        bun.assert(is8Bit(self));
        return self.data()[0..length(self)];
    }

    /// Caller must ensure that the string is 8-bit and ASCII.
    pub inline fn utf8Slice(self: WTFStringImpl) []const u8 {
        if (comptime bun.Environment.allow_assert)
            bun.assert(canUseAsUTF8(self));
        return self.data()[0..length(self)];
    }

    pub inline fn deref(self: WTFStringImpl) void {
        bun.assert(self.hasAtLeastOneRef());
        runtime.release(@ptrCast(self));
    }

    pub inline fn ref(self: WTFStringImpl) void {
        bun.assert(self.hasAtLeastOneRef());
        runtime.retain(@ptrCast(self));
    }

    pub inline fn hasAtLeastOneRef(self: WTFStringImpl) bool {
        return self.rawRefCount() > 0;
    }

    /// Compute the hash() if necessary
    pub fn ensureHash(this: WTFStringImpl) void {
        runtime.ensureHash(@ptrCast(this));
    }

    pub fn toUTF8(this: WTFStringImpl, allocator: std.mem.Allocator) bun.OOM!bun.String.Slice {
        return (try this.toUTF8IfNeeded(allocator)) orelse bun.String.Slice.retainASCIIString(this);
    }

    pub const max = std.math.maxInt(u32);

    pub fn toUTF8WithoutRef(this: WTFStringImpl, allocator: std.mem.Allocator) bun.OOM!bun.String.Slice {
        return (try this.toUTF8IfNeeded(allocator)) orelse bun.String.Slice.fromUTF8NeverFree(this.latin1Slice());
    }

    pub fn toOwnedSliceZ(this: WTFStringImpl, allocator: std.mem.Allocator) bun.OOM![:0]u8 {
        if (this.is8Bit()) {
            if (try bun.strings.toUTF8FromLatin1Z(allocator, this.latin1Slice())) |utf8| {
                return utf8;
            }

            return allocator.dupeSentinel(u8, this.latin1Slice(), 0);
        }
        return bun.strings.toUTF8AllocZ(allocator, this.utf16Slice());
    }

    pub fn toUTF8IfNeeded(this: WTFStringImpl, allocator: std.mem.Allocator) bun.OOM!?bun.String.Slice {
        if (this.is8Bit()) {
            if (try bun.strings.toUTF8FromLatin1(allocator, this.latin1Slice())) |utf8| {
                return bun.String.Slice.init(allocator, utf8);
            }

            return null;
        }

        return bun.String.Slice.init(
            allocator,
            try bun.strings.toUTF8Alloc(allocator, this.utf16Slice()),
        );
    }

    /// Avoid using this in code paths that are about to get the string as a UTF-8
    /// In that case, use toUTF8IfNeeded instead.
    pub fn canUseAsUTF8(this: WTFStringImpl) bool {
        return this.is8Bit() and bun.strings.isAllASCII(this.latin1Slice());
    }

    pub fn utf8ByteLength(this: WTFStringImpl) usize {
        if (this.is8Bit()) {
            const input = this.latin1Slice();
            return bun.strings.elementLengthLatin1IntoUTF8(input);
        } else {
            const input = this.utf16Slice();
            return if (input.len > 0) bun.strings.elementLengthUTF16IntoUTF8(input) else 0;
        }
    }

    pub fn hasPrefix(self: WTFStringImpl, text: []const u8) bool {
        if (text.len > self.length()) return false;
        if (self.is8Bit()) return std.mem.startsWith(u8, self.latin1Slice(), text);
        for (self.utf16Slice()[0..text.len], text) |code_unit, byte| {
            if (code_unit != byte) return false;
        }
        return true;
    }

    pub const external_shared_descriptor = struct {
        pub const ref = WTFStringImplStruct.ref;
        pub const deref = WTFStringImplStruct.deref;
    };
};

/// Behaves like `WTF::Ref<WTF::StringImpl>`.
pub const WTFString = bun.ptr.ExternalShared(WTFStringImplStruct);

const bun = @import("bun");
const std = @import("std");

const runtime = @import("./StringRuntime.zig");
