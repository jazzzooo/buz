pub const immutable = @import("./immutable.zig");

pub const MutableString = @import("./MutableString.zig");
pub const PathString = @import("./PathString.zig").PathString;
pub const SmolStr = @import("./SmolStr.zig").SmolStr;
pub const StringBuilder = @import("./StringBuilder.zig");
pub const StringJoiner = @import("./StringJoiner.zig");
pub const UTF16Builder = @import("./UTF16Builder.zig");
pub const wtf = @import("./wtf.zig");
pub const WTFString = wtf.WTFString;
pub const WTFStringImpl = wtf.WTFStringImpl;
pub const WTFStringImplStruct = wtf.WTFStringImplStruct;

pub const Tag = enum(u8) {
    /// String is not valid. Observed on some failed operations.
    /// To prevent crashes, this value acts similarly to .Empty (such as length = 0)
    Dead = 0,
    /// String is backed by a WTF::StringImpl from JavaScriptCore.
    /// Can be in either `latin1` or `utf16le` encodings.
    WTFStringImpl = 1,
    /// String is ""
    Empty = 4,
};

pub const StringImpl = extern union {
    WTFStringImpl: WTFStringImpl,
    Dead: void,
    Empty: void,
};

pub const String = extern struct {
    pub const name = "BunString";

    tag: Tag,
    value: StringImpl,

    pub const empty = String{ .tag = .Empty, .value = .{ .Empty = {} } };

    pub const dead = String{ .tag = .Dead, .value = .{ .Dead = {} } };

    pub fn ensureHash(this: String) void {
        if (this.tag == .WTFStringImpl) this.value.WTFStringImpl.ensureHash();
    }

    pub fn toOwnedSlice(this: String, allocator: std.mem.Allocator) OOM![]u8 {
        const bytes, _ = try this.toOwnedSliceImpl(allocator);
        return bytes;
    }

    /// Returns `.{ utf8_bytes, is_all_ascii }`.
    ///
    /// `false` means the string contains at least one non-ASCII character.
    pub fn toOwnedSliceReturningAllASCII(this: String, allocator: std.mem.Allocator) OOM!struct { []u8, bool } {
        const bytes, const ascii_status = try this.toOwnedSliceImpl(allocator);
        const is_ascii = switch (ascii_status) {
            .all_ascii => true,
            .non_ascii => false,
            .unknown => bun.strings.isAllASCII(bytes),
        };
        return .{ bytes, is_ascii };
    }

    fn toOwnedSliceImpl(this: String, allocator: std.mem.Allocator) !struct { []u8, AsciiStatus } {
        return switch (this.tag) {
            .WTFStringImpl => blk: {
                const utf8_slice = try this.value.WTFStringImpl.toUTF8WithoutRef(allocator);
                errdefer utf8_slice.deinit();

                const ascii_status: AsciiStatus = if (utf8_slice.storage == .borrowed)
                    .all_ascii
                else if (this.value.WTFStringImpl.is8Bit())
                    .non_ascii
                else
                    .unknown;

                const bytes = switch (utf8_slice.storage) {
                    .borrowed => |bytes| try allocator.dupe(u8, bytes),
                    .allocated => |allocation| allocation.bytes,
                    .string => unreachable,
                };
                break :blk .{ bytes, ascii_status };
            },
            else => return .{ &.{}, .all_ascii }, // trivially all ascii
        };
    }

    pub fn createIfDifferent(other: String, utf8_slice: []const u8) String {
        if (other.tag == .WTFStringImpl) {
            if (other.eqlUTF8(utf8_slice)) {
                return other.dupeRef();
            }
        }

        return cloneUTF8(utf8_slice);
    }

    fn createUninitializedLatin1(len: usize) struct { String, []u8 } {
        bun.assert(len > 0);
        const result = runtime.createUninitialized(len, .latin1) orelse return .{ .dead, &.{} };
        const string = validateRefCount(.{
            .tag = .WTFStringImpl,
            .value = .{ .WTFStringImpl = @ptrCast(@alignCast(result.handle)) },
        });
        return .{ string, result.data[0..len] };
    }

    fn createUninitializedUTF16(len: usize) struct { String, []u16 } {
        bun.assert(len > 0);
        const result = runtime.createUninitialized(len, .utf16) orelse return .{ .dead, &.{} };
        const string = validateRefCount(.{
            .tag = .WTFStringImpl,
            .value = .{ .WTFStringImpl = @ptrCast(@alignCast(result.handle)) },
        });
        return .{ string, @as([*]u16, @ptrCast(@alignCast(result.data)))[0..len] };
    }

    pub const WTFEncoding = enum {
        latin1,
        utf16,

        pub fn Byte(comptime this: WTFEncoding) type {
            return switch (this) {
                .latin1 => u8,
                .utf16 => u16,
            };
        }
    };

    /// Allocate memory for a WTF::String of a given length and encoding, and
    /// return the string and a mutable slice for that string.
    ///
    /// This is not allowed on zero-length strings, in this case you should
    /// check earlier and use String.empty in that case.
    ///
    /// If the length is too large, this will return a dead string.
    pub fn createUninitialized(
        comptime kind: WTFEncoding,
        len: usize,
    ) struct { String, [](kind.Byte()) } {
        bun.assert(len > 0);
        return switch (comptime kind) {
            .latin1 => createUninitializedLatin1(len),
            .utf16 => createUninitializedUTF16(len),
        };
    }

    pub fn cloneLatin1(bytes: []const u8) String {
        if (bytes.len == 0) return String.empty;
        const string, const destination = createUninitialized(.latin1, bytes.len);
        if (string.tag != .Dead) @memcpy(destination, bytes);
        return string;
    }

    pub inline fn validateRefCount(this: String) String {
        if (comptime bun.Environment.isDebug) {
            // Newly created strings should have a ref count of 1
            if (!this.isEmpty()) {
                const ref_count = this.value.WTFStringImpl.refCount();
                bun.assert(ref_count == 1);
            }
        }

        return this;
    }

    pub fn cloneUTF8(bytes: []const u8) String {
        if (bytes.len == 0) return .empty;
        const converted = bun.strings.toUTF16Alloc(bun.default_allocator, bytes, false, false) catch return .dead;
        if (converted) |utf16_units| {
            defer bun.default_allocator.free(utf16_units);
            return cloneUTF16(utf16_units);
        }
        return cloneLatin1(bytes);
    }

    pub fn cloneUTF16(bytes: []const u16) String {
        if (bytes.len == 0) return String.empty;
        if (bun.strings.firstNonASCII16(bytes) == null) {
            const string, const destination = createUninitialized(.latin1, bytes.len);
            if (string.tag != .Dead) bun.strings.copyU16IntoU8(destination, bytes);
            return string;
        }
        const string, const destination = createUninitialized(.utf16, bytes.len);
        if (string.tag != .Dead) @memcpy(destination, bytes);
        return string;
    }

    pub fn createFormat(comptime fmt: [:0]const u8, args: anytype) OOM!String {
        if (comptime std.meta.fieldNames(@TypeOf(args)).len == 0) {
            return String.static(fmt);
        }

        var sba_buffer: [512]u8 = undefined;
        var sba: std.heap.BufferFirstAllocator = .init(&sba_buffer, bun.default_allocator);
        const alloc = sba.allocator();
        const buf = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(buf);
        const result = cloneUTF8(buf);
        if (result.tag == .Dead) return error.OutOfMemory;
        return result;
    }

    pub fn createFromOSPath(os_path: bun.OSPathSlice) String {
        return switch (@TypeOf(os_path)) {
            []const u8 => cloneUTF8(os_path),
            []const u16 => cloneUTF16(os_path),
            else => @compileError("unreachable"),
        };
    }

    pub fn isEmpty(this: String) bool {
        return this.tag == .Empty or this.length() == 0;
    }

    pub fn dupeRef(this: String) String {
        this.ref();
        return this;
    }

    pub fn clone(this: String) String {
        if (this.tag == .WTFStringImpl) {
            return this.dupeRef();
        }

        if (this.isEmpty()) {
            return String.empty;
        }

        if (this.isUTF16()) {
            const new, const bytes = createUninitialized(.utf16, this.length());
            if (new.tag != .Dead) {
                @memcpy(bytes, this.value.WTFStringImpl.utf16Slice());
            }
            return new;
        }

        return cloneUTF8(this.byteSlice());
    }

    pub fn utf8ByteLength(this: String) usize {
        return switch (this.tag) {
            .WTFStringImpl => this.value.WTFStringImpl.utf8ByteLength(),
            .Dead, .Empty => 0,
        };
    }

    /// View of the first `len` code units.
    pub fn trunc(this: *const String, len: usize) bun.TextView {
        const view = this.textView();
        return view.substringWithLen(0, @min(len, view.len()));
    }

    pub fn toOwnedSliceZ(this: String, allocator: std.mem.Allocator) OOM![:0]u8 {
        return this.textView().toOwnedSliceZ(allocator);
    }

    /// Wrap an existing StringImpl without taking a reference; the caller
    /// guarantees the impl outlives this value.
    pub fn init(impl: WTFStringImpl) String {
        return .{ .tag = .WTFStringImpl, .value = .{ .WTFStringImpl = impl } };
    }

    pub fn static(comptime input: []const u8) String {
        if (comptime input.len == 0) return .empty;
        const Holder = struct {
            fn create() String {
                return createStaticExternal(.latin1, input);
            }

            var once = bun.threadedOnce(create);
        };
        return Holder.once.call(.{});
    }

    /// Static string for a runtime enum or tagged-union value's tag name:
    /// one immortal impl per variant.
    pub fn staticTagName(value: anytype) String {
        const tag_value = if (@typeInfo(@TypeOf(value)) == .@"union") std.meta.activeTag(value) else value;
        return switch (tag_value) {
            inline else => |tag| static(@tagName(tag)),
        };
    }

    /// ctx is the pointer passed into `createExternal`
    /// buffer is the pointer to the buffer, either [*]u8 or [*]u16
    /// byte_len is the size of that buffer in bytes.
    pub fn ExternalStringImplFreeFunction(comptime Ctx: type) type {
        return fn (ctx: Ctx, buffer: *u8, byte_len: usize) void;
    }

    pub const ExternalStringOwner = struct {
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque, ?*u8, usize) void,
        allocation_byte_length: ?usize = null,

        fn create(
            comptime Ctx: type,
            context: Ctx,
            comptime callback: *const ExternalStringImplFreeFunction(Ctx),
        ) bun.OOM!*ExternalStringOwner {
            const callback_fn = callback;
            const Wrapper = struct {
                fn finalize(raw_context: ?*anyopaque, data: ?*u8, byte_len: usize) void {
                    callback_fn(
                        @ptrCast(@alignCast(raw_context.?)),
                        data orelse @panic("external string finalized without its buffer"),
                        byte_len,
                    );
                }
            };
            return createRaw(@ptrCast(context), Wrapper.finalize);
        }

        pub fn createRaw(
            context: ?*anyopaque,
            callback: *const fn (?*anyopaque, ?*u8, usize) void,
        ) bun.OOM!*ExternalStringOwner {
            const owner = try bun.default_allocator.create(ExternalStringOwner);
            owner.* = .{
                .context = context,
                .callback = callback,
            };
            return owner;
        }

        fn finalize(this: *ExternalStringOwner, data: ?*u8, byte_len: usize) void {
            const context = this.context;
            const callback = this.callback;
            const allocation_byte_length = this.allocation_byte_length orelse byte_len;
            bun.destroy(this);
            callback(context, data, allocation_byte_length);
        }

        fn finalizeFromRuntime(context: ?*anyopaque, data: ?*u8, byte_len: usize) callconv(.c) void {
            const this: *ExternalStringOwner = @ptrCast(@alignCast(context.?));
            this.finalize(data, byte_len);
        }

        pub fn finalizeFromByteOwner(context: ?*anyopaque, data: [*c]u8, byte_len: usize) callconv(.c) void {
            const this: *ExternalStringOwner = @ptrCast(@alignCast(context.?));
            this.finalize(if (data == null) null else @ptrCast(data), byte_len);
        }
    };

    /// Creates a `String` backed by a `WTF::ExternalStringImpl`.
    ///
    /// External strings are WTF strings with bytes allocated somewhere else.
    /// When destroyed, they call `callback`, which should free the allocation
    /// as needed.
    ///
    ///
    /// If `bytes` is too long (longer than `max_length()`), `callback` gets
    /// called and a `dead` string is returned. `bytes` cannot be empty. Passing
    /// an empty slice is safety-checked Illegal Behavior.
    ///
    /// ### Memory Characteristics
    /// - Allocates memory for the backing `WTF::ExternalStringImpl` and its
    ///   Zig owner record. Does not allocate the actual string bytes.
    /// - The returned string retains `bytes` without copying and calls
    ///   `callback` when it no longer needs them.
    pub fn createExternal(
        comptime kind: WTFEncoding,
        comptime Ctx: type,
        bytes: []const kind.Byte(),
        ctx: Ctx,
        comptime callback: *const ExternalStringImplFreeFunction(Ctx),
    ) String {
        comptime if (@typeInfo(Ctx) != .pointer) @compileError("context must be a pointer");
        bun.assert(bytes.len > 0);
        if (bytes.len >= max_length()) {
            callback(ctx, @ptrCast(@constCast(bytes.ptr)), bytes.len * @sizeOf(kind.Byte()));
            return dead;
        }

        const owner = ExternalStringOwner.create(Ctx, ctx, callback) catch {
            callback(ctx, @ptrCast(@constCast(bytes.ptr)), bytes.len * @sizeOf(kind.Byte()));
            return .dead;
        };
        const handle = runtime.createExternal(
            @ptrCast(bytes.ptr),
            bytes.len,
            switch (kind) {
                .latin1 => .latin1,
                .utf16 => .utf16,
            },
            owner,
            ExternalStringOwner.finalizeFromRuntime,
        ) orelse {
            owner.finalize(@ptrCast(@constCast(bytes.ptr)), bytes.len * @sizeOf(kind.Byte()));
            return .dead;
        };
        return validateRefCount(.{
            .tag = .WTFStringImpl,
            .value = .{ .WTFStringImpl = @ptrCast(@alignCast(handle)) },
        });
    }

    /// This should rarely be used. The WTF::StringImpl* will never be freed.
    ///
    /// So this really only makes sense when you need to dynamically allocate a
    /// string that will never be freed.
    pub fn createStaticExternal(comptime kind: WTFEncoding, bytes: []const kind.Byte()) String {
        bun.assert(bytes.len > 0);
        if (bytes.len >= max_length()) return dead;

        const handle = runtime.createStaticExternal(
            @ptrCast(bytes.ptr),
            bytes.len,
            switch (kind) {
                .latin1 => .latin1,
                .utf16 => .utf16,
            },
        ) orelse return .dead;
        return validateRefCount(.{
            .tag = .WTFStringImpl,
            .value = .{ .WTFStringImpl = @ptrCast(@alignCast(handle)) },
        });
    }

    /// Max WTFStringImpl length.
    /// **Not** in bytes. In characters.
    pub inline fn max_length() usize {
        return bun.JavaScriptLimits.stringAllocationLimit();
    }

    /// If the allocation fails, this will free the bytes and return a dead string.
    pub fn createExternalGloballyAllocated(comptime kind: WTFEncoding, bytes: []kind.Byte()) String {
        bun.assert(bytes.len > 0);
        return createExternalGloballyAllocatedWithLength(kind, bytes, bytes.len);
    }

    pub fn createExternalGloballyAllocatedWithLength(comptime kind: WTFEncoding, allocation: []kind.Byte(), code_unit_length: usize) String {
        return createExternalGloballyAllocatedImpl(kind, std.mem.sliceAsBytes(allocation), code_unit_length, switch (kind) {
            .latin1 => freeGloballyAllocatedLatin1,
            .utf16 => freeGloballyAllocatedUTF16,
        });
    }

    pub fn createExternalGloballyAllocatedBytes(comptime kind: WTFEncoding, allocation: []u8, code_unit_length: usize) String {
        return createExternalGloballyAllocatedImpl(kind, allocation, code_unit_length, freeGloballyAllocatedLatin1);
    }

    fn createExternalGloballyAllocatedImpl(
        comptime kind: WTFEncoding,
        allocation: []u8,
        code_unit_length: usize,
        comptime deallocator: *const fn (?*anyopaque, ?*u8, usize) void,
    ) String {
        bun.assert(code_unit_length <= allocation.len / @sizeOf(kind.Byte()));
        if (code_unit_length == 0) {
            deallocator(null, @ptrCast(allocation.ptr), allocation.len);
            return .empty;
        }
        bun.assert(std.mem.isAligned(@intFromPtr(allocation.ptr), @alignOf(kind.Byte())));
        if (code_unit_length >= max_length()) {
            deallocator(null, @ptrCast(allocation.ptr), allocation.len);
            return dead;
        }

        const owner = ExternalStringOwner.createRaw(null, deallocator) catch {
            deallocator(null, @ptrCast(allocation.ptr), allocation.len);
            return .dead;
        };
        owner.allocation_byte_length = allocation.len;
        const handle = runtime.createExternal(
            allocation.ptr,
            code_unit_length,
            switch (kind) {
                .latin1 => .latin1,
                .utf16 => .utf16,
            },
            owner,
            ExternalStringOwner.finalizeFromRuntime,
        ) orelse {
            owner.finalize(@ptrCast(allocation.ptr), allocation.len);
            return .dead;
        };
        return validateRefCount(.{
            .tag = .WTFStringImpl,
            .value = .{ .WTFStringImpl = @ptrCast(@alignCast(handle)) },
        });
    }

    fn freeGloballyAllocatedLatin1(_: ?*anyopaque, buffer: ?*u8, byte_len: usize) void {
        bun.default_allocator.free(@as([*]u8, @ptrCast(buffer.?))[0..byte_len]);
    }

    fn freeGloballyAllocatedUTF16(_: ?*anyopaque, buffer: ?*u8, byte_len: usize) void {
        bun.assert(byte_len % @sizeOf(u16) == 0);
        bun.default_allocator.free(@as([*]u16, @ptrCast(@alignCast(buffer.?)))[0 .. byte_len / @sizeOf(u16)]);
    }

    pub fn format(self: String, writer: *std.Io.Writer) !void {
        try self.textView().format(writer);
    }

    /// Borrowed view of the string's contents; valid only while this string
    /// is alive.
    pub fn textView(this: *const String) bun.TextView {
        switch (this.tag) {
            .WTFStringImpl => {
                const impl = this.value.WTFStringImpl;
                return if (impl.is8Bit())
                    .{ .latin1 = impl.latin1Slice() }
                else
                    .{ .utf16 = impl.utf16Slice() };
            },
            .Dead, .Empty => return .empty,
        }
    }

    pub inline fn length(this: String) usize {
        return if (this.tag == .WTFStringImpl)
            this.value.WTFStringImpl.length()
        else
            0;
    }

    pub inline fn utf16(self: String) []const u16 {
        if (self.tag == .WTFStringImpl) {
            return self.value.WTFStringImpl.utf16Slice();
        }
        return &[_]u16{};
    }

    pub inline fn latin1(self: String) []const u8 {
        if (self.tag == .WTFStringImpl) {
            return self.value.WTFStringImpl.latin1Slice();
        }
        return &[_]u8{};
    }

    pub inline fn asUTF8(self: String) ?[]const u8 {
        if (self.tag == .WTFStringImpl) {
            if (self.value.WTFStringImpl.is8Bit() and bun.strings.isAllASCII(self.value.WTFStringImpl.latin1Slice())) {
                return self.value.WTFStringImpl.latin1Slice();
            }

            return null;
        }

        return "";
    }

    pub fn encoding(self: String) bun.strings.EncodingNonAscii {
        if (self.isUTF16()) {
            return .utf16;
        }

        return .latin1;
    }

    pub const GithubActionFormatter = struct {
        text: String,

        pub fn format(this: GithubActionFormatter, writer: *std.Io.Writer) !void {
            var slice = this.text.toUTF8(bun.default_allocator) catch return error.WriteFailed;
            defer slice.deinit();
            try bun.fmt.githubActionWriter(writer, slice.slice());
        }
    };

    pub fn githubAction(self: String) GithubActionFormatter {
        return .{ .text = self };
    }

    pub fn byteSlice(this: String) []const u8 {
        return switch (this.tag) {
            .WTFStringImpl => this.value.WTFStringImpl.byteSlice(),
            else => &[_]u8{},
        };
    }

    pub fn isUTF16(self: String) bool {
        if (self.tag == .WTFStringImpl)
            return !self.value.WTFStringImpl.is8Bit();

        return false;
    }

    pub const encodeInto = webcore_encoding.encodeStringInto;
    pub const encode = webcore_encoding.encodeString;

    pub fn canBeUTF8(self: String) bool {
        if (self.tag == .WTFStringImpl)
            return self.value.WTFStringImpl.is8Bit() and bun.strings.isAllASCII(self.value.WTFStringImpl.latin1Slice());

        return self.tag == .Empty;
    }

    /// View of the code units from `start_index` to the end; valid only
    /// while this string is alive.
    pub fn substring(this: *const String, start_index: usize) bun.TextView {
        const view = this.textView();
        return view.substring(start_index);
    }

    /// View of the code-unit range; valid only while this string is alive.
    pub fn substringWithLen(this: *const String, start_index: usize, end_index: usize) bun.TextView {
        return this.textView().substringWithLen(start_index, end_index);
    }

    pub fn toUTF8(this: String, allocator: std.mem.Allocator) OOM!Slice {
        if (this.tag == .WTFStringImpl) {
            return this.value.WTFStringImpl.toUTF8(allocator);
        }

        return Slice.empty;
    }

    /// This is the same as toUTF8, but it doesn't increment the reference count for latin1 strings
    pub fn toUTF8WithoutRef(this: String, allocator: std.mem.Allocator) OOM!Slice {
        if (this.tag == .WTFStringImpl) {
            return this.value.WTFStringImpl.toUTF8WithoutRef(allocator);
        }

        return Slice.empty;
    }

    /// Equivalent to calling `toUTF8WithoutRef` followed by `cloneIfBorrowed`.
    pub fn toUTF8Owned(this: String, allocator: std.mem.Allocator) OOM!Slice {
        const utf8 = try this.toUTF8WithoutRef(allocator);
        errdefer utf8.deinit();
        return utf8.cloneIfBorrowed(allocator);
    }

    /// The returned slice is always allocated by `allocator`.
    pub fn toUTF8Bytes(this: String, allocator: std.mem.Allocator) OOM![]u8 {
        return this.toOwnedSlice(allocator);
    }

    /// use `byteSlice` to get a `[]const u8`.
    pub fn toSlice(this: *String, allocator: std.mem.Allocator) OOM!SliceWithUnderlyingString {
        const result = SliceWithUnderlyingString{
            .utf8 = try this.toUTF8(allocator),
            .underlying = this.*,
        };
        this.* = .empty;
        return result;
    }

    pub fn toThreadSafeSlice(this: *String, allocator: std.mem.Allocator) bun.OOM!SliceWithUnderlyingString {
        if (this.tag == .WTFStringImpl) {
            const impl = this.value.WTFStringImpl;
            if (impl.isThreadSafe() and impl.canUseAsUTF8()) {
                return .{
                    .utf8 = Slice.retainASCIIString(impl),
                    .underlying = this.dupeRef(),
                };
            }
            return .{ .utf8 = try this.toUTF8Owned(allocator) };
        }

        return this.toSlice(allocator);
    }

    pub fn ref(this: String) void {
        switch (this.tag) {
            .WTFStringImpl => this.value.WTFStringImpl.ref(),
            else => {},
        }
    }

    pub fn deref(this: String) void {
        switch (this.tag) {
            .WTFStringImpl => this.value.WTFStringImpl.deref(),
            else => {},
        }
    }

    pub fn eqlComptime(this: String, comptime value: []const u8) bool {
        return this.textView().eqlBytes(value);
    }

    pub fn is8Bit(this: String) bool {
        return switch (this.tag) {
            .WTFStringImpl => this.value.WTFStringImpl.is8Bit(),
            else => true,
        };
    }

    pub fn charAt(this: String, index: usize) u16 {
        if (comptime bun.Environment.allow_assert) {
            bun.assert(index < this.length());
        }
        return switch (this.tag) {
            .WTFStringImpl => if (this.value.WTFStringImpl.is8Bit()) this.value.WTFStringImpl.latin1Slice()[index] else this.value.WTFStringImpl.utf16Slice()[index],
            else => 0,
        };
    }

    pub fn indexOfAsciiChar(this: String, chr: u8) ?usize {
        bun.assert(chr < 128);
        return switch (this.isUTF16()) {
            true => std.mem.indexOfScalar(u16, this.utf16(), @intCast(chr)),
            false => bun.strings.indexOfCharUsize(this.byteSlice(), chr),
        };
    }

    pub fn visibleWidth(this: *const String, ambiguousAsWide: bool) usize {
        if (this.isUTF16()) {
            return bun.strings.visible.width.utf16(this.utf16(), ambiguousAsWide);
        }
        return bun.strings.visible.width.latin1(this.latin1(), ambiguousAsWide);
    }

    pub fn visibleWidthExcludeANSIColors(this: *const String, ambiguousAsWide: bool) usize {
        if (this.isUTF16()) {
            return bun.strings.visible.width.exclude_ansi_colors.utf16(this.utf16(), ambiguousAsWide);
        }
        return bun.strings.visible.width.exclude_ansi_colors.latin1(this.latin1(), ambiguousAsWide);
    }

    pub fn indexOfComptimeArrayAssumeSameLength(this: String, comptime values: []const []const u8) ?usize {
        if (this.is8Bit()) {
            const bytes = this.byteSlice();

            inline for (0..values.len) |i| {
                bun.assert(bytes.len == values[i].len);
                if (bun.strings.eqlComptimeCheckLenWithType(u8, bytes, values[i], false)) {
                    return i;
                }
            }

            return null;
        }

        const u16_bytes = this.utf16();
        var buffer: [values[0].len]u8 = undefined;
        inline for (0..values[0].len) |i| {
            const uchar = u16_bytes[i];
            if (uchar > 255)
                return null;

            buffer[i] = @as(u8, @intCast(uchar));
        }

        inline for (0..values.len) |i| {
            if (bun.strings.eqlComptimeCheckLenWithType(u8, &buffer, values[i], false)) {
                return i;
            }
        }

        return null;
    }

    pub fn inMap(this: String, comptime ComptimeStringMap: anytype) ?ComptimeStringMap.Value {
        return ComptimeStringMap.getWithEqlList(this, indexOfComptimeArrayAssumeSameLength);
    }

    pub fn inMapCaseInsensitive(this: String, comptime ComptimeStringMap: anytype) ?ComptimeStringMap.Value {
        return ComptimeStringMap.getWithEqlList(this, indexOfComptimeArrayCaseInsensitiveSameLength);
    }

    pub fn indexOfComptimeArrayCaseInsensitiveSameLength(this: String, comptime values: []const []const u8) ?usize {
        if (this.is8Bit()) {
            const bytes = this.byteSlice();

            inline for (0..values.len) |i| {
                bun.assert(bytes.len == values[i].len);
                if (bun.strings.eqlCaseInsensitiveASCIIIgnoreLength(bytes, values[i])) {
                    return i;
                }
            }

            return null;
        }

        const u16_bytes = this.utf16();
        const buffer: [values[0].len]u8 = brk: {
            var bytes: [values[0].len]u8 = undefined;
            for (&bytes, u16_bytes) |*byte, uchar| {
                if (uchar > 255)
                    return null;

                byte.* = @as(u8, @intCast(uchar));
            }
            break :brk bytes;
        };

        inline for (0..values.len) |i| {
            if (bun.strings.eqlCaseInsensitiveASCIIIgnoreLength(&buffer, values[i])) {
                return i;
            }
        }

        return null;
    }

    pub fn hasPrefixComptime(this: String, comptime value: []const u8) bool {
        if (this.tag == .WTFStringImpl) {
            return this.value.WTFStringImpl.hasPrefix(value);
        }

        return value.len == 0;
    }

    pub fn isolatedCopy(this: String) OOM!String {
        const copy = switch (this.tag) {
            .WTFStringImpl => if (this.value.WTFStringImpl.is8Bit())
                cloneLatin1(this.value.WTFStringImpl.latin1Slice())
            else
                cloneUTF16(this.value.WTFStringImpl.utf16Slice()),
            .Empty => return .empty,
            .Dead => return error.OutOfMemory,
        };
        if (copy.tag == .Dead) return error.OutOfMemory;
        return copy;
    }

    pub fn toThreadSafe(this: *String) OOM!void {
        const copy = try this.isolatedCopy();
        const previous = this.*;
        this.* = copy;
        previous.deref();
    }

    pub fn eqlUTF8(this: String, other: []const u8) bool {
        return this.textView().eqlUTF8View(.fromBytes(other));
    }

    pub fn eql(this: String, other: String) bool {
        return this.textView().eqlUTF8View(other.textView());
    }

    /// Reports owned allocation size, not the actual size of the string.
    pub fn estimatedSize(this: *const String) usize {
        return switch (this.tag) {
            .Dead, .Empty => 0,
            .WTFStringImpl => this.value.WTFStringImpl.byteLength(),
        };
    }

    /// UTF-8 bytes with borrowed, allocated, or StringImpl ownership.
    /// Must call `.deinit` to release memory.
    pub const Slice = struct {
        storage: union(enum) {
            borrowed: []const u8,
            allocated: struct { allocator: std.mem.Allocator, bytes: []u8 },
            string: WTFStringImpl,
        } = .{ .borrowed = "" },

        pub fn init(allocator: std.mem.Allocator, input: []const u8) Slice {
            return .{ .storage = .{ .allocated = .{ .allocator = allocator, .bytes = @constCast(input) } } };
        }

        pub fn retainASCIIString(impl: WTFStringImpl) Slice {
            bun.assert(impl.canUseAsUTF8());
            impl.ref();
            return .{ .storage = .{ .string = impl } };
        }

        pub fn initDupe(allocator: std.mem.Allocator, input: []const u8) OOM!Slice {
            return .init(allocator, try allocator.dupe(u8, input));
        }

        pub fn byteLength(this: *const Slice) usize {
            return this.slice().len;
        }

        pub inline fn length(this: Slice) usize {
            return this.slice().len;
        }

        pub const byteSlice = Slice.slice;

        pub fn fromUTF8NeverFree(input: []const u8) Slice {
            return .{ .storage = .{ .borrowed = input } };
        }

        pub const empty: Slice = .{};

        pub fn toOwned(this: Slice, allocator: std.mem.Allocator) OOM!Slice {
            return .init(allocator, try allocator.dupe(u8, this.slice()));
        }

        /// Converts this `Slice` into a `[]const u8`, guaranteed to be allocated by
        /// `allocator`.
        ///
        /// This method sets `this` to an empty string. If you don't need the original string,
        /// this method may be more efficient than `toOwned`, which always allocates memory.
        pub fn intoOwnedSlice(this: *Slice, allocator: std.mem.Allocator) OOM![]const u8 {
            defer this.* = .{};
            if (this.storage == .allocated) {
                const allocation = this.storage.allocated;
                if (allocator.vtable == bun.default_allocator.vtable and allocation.allocator.vtable == allocator.vtable)
                    return allocation.bytes;
            }
            defer this.deinit();
            return (try this.toOwned(allocator)).slice();
        }

        /// Same as `intoOwnedSlice`, but creates `[:0]const u8`
        pub fn intoOwnedSliceZ(this: *Slice, allocator: std.mem.Allocator) OOM![:0]const u8 {
            defer {
                this.deinit();
                this.* = .{};
            }
            // always clones
            return allocator.dupeSentinel(u8, this.slice(), 0);
        }

        /// Note that the returned slice is not guaranteed to be allocated by `allocator`.
        pub fn cloneIfBorrowed(this: Slice, allocator: std.mem.Allocator) bun.OOM!Slice {
            if (this.storage != .borrowed) {
                return this;
            }

            return this.toOwned(allocator);
        }

        pub fn cloneWithTrailingSlash(this: Slice, allocator: std.mem.Allocator) !Slice {
            const buf = try strings.cloneNormalizingSeparators(allocator, this.slice());
            return Slice.init(allocator, buf);
        }

        pub fn slice(this: *const Slice) []const u8 {
            return switch (this.storage) {
                .borrowed => |bytes| bytes,
                .allocated => |allocation| allocation.bytes,
                .string => |impl| impl.latin1Slice(),
            };
        }

        /// Releases the allocation or string reference; borrowed bytes are unchanged.
        pub fn deinit(this: *const Slice) void {
            switch (this.storage) {
                .borrowed => {},
                .allocated => |allocation| allocation.allocator.free(allocation.bytes),
                .string => |impl| impl.deref(),
            }
        }
    };
};

pub const SliceWithUnderlyingString = struct {
    utf8: String.Slice = String.Slice.empty,
    underlying: String = String.dead,

    did_report_extra_memory_debug: bun.DebugOnly(bool) = if (bun.Environment.isDebug) false,

    pub fn dupeRef(this: SliceWithUnderlyingString) SliceWithUnderlyingString {
        return .{
            .utf8 = String.Slice.empty,
            .underlying = this.underlying.dupeRef(),
        };
    }

    /// Transcode a byte array to an encoded String, avoiding unnecessary copies.
    ///
    /// owned_input_bytes ownership is transferred to this function
    pub const transcodeFromOwnedSlice = webcore_encoding.transcodeOwnedStringSlice;

    /// Assumes default allocator in use
    pub fn fromUTF8(utf8: []const u8) SliceWithUnderlyingString {
        return .{
            .utf8 = String.Slice.init(bun.default_allocator, utf8),
            .underlying = String.dead,
        };
    }

    pub fn toThreadSafe(this: *SliceWithUnderlyingString) bun.OOM!void {
        if (this.underlying.tag == .WTFStringImpl) {
            try this.underlying.toThreadSafe();
            if (this.utf8.storage == .string) {
                this.utf8.deinit();
                this.utf8 = if (this.underlying.tag == .WTFStringImpl)
                    String.Slice.retainASCIIString(this.underlying.value.WTFStringImpl)
                else
                    .empty;
            }
        }
    }

    pub fn deinit(this: SliceWithUnderlyingString) void {
        this.utf8.deinit();
        this.underlying.deref();
    }

    pub fn slice(this: SliceWithUnderlyingString) []const u8 {
        return this.utf8.slice();
    }

    pub fn format(self: SliceWithUnderlyingString, writer: *std.Io.Writer) !void {
        if (self.utf8.length() == 0) {
            try self.underlying.format(writer);
            return;
        }

        try writer.writeAll(self.utf8.slice());
    }
};

comptime {
    if (bun.Environment.isNative) {
        bun.assert_eql(@sizeOf(bun.String), 16);
        bun.assert_eql(@alignOf(bun.String), 8);
    }
}

const std = @import("std");
const bun = @import("bun");
const OOM = bun.OOM;
const strings = bun.strings;
const AsciiStatus = bun.strings.AsciiStatus;

const runtime = @import("./StringRuntime.zig");
const webcore_encoding = @import("../runtime/webcore/encoding.zig");
