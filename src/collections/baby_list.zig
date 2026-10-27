/// This is like ArrayList except it stores the length and capacity as u32
/// In practice, it is very unusual to have lengths above 4 GiB
pub fn BabyList(comptime Type: type) type {
    const Origin = union(enum) {
        owned,
        borrowed: struct {
            trace: if (traces_enabled) StoredTrace else void,
        },
    };

    return struct {
        const Self = @This();

        // NOTE: If you add, remove, or rename any public fields, you need to update
        // `looksLikeListContainerType` in `meta.zig`.

        /// Don't access this field directly, as it's not safety-checked. Use `.slice()`, `.at()`,
        /// or `.mut()`.
        ptr: [*]Type = &.{},
        len: u32 = 0,
        cap: u32 = 0,
        origin: if (safety_checks) Origin else void = if (safety_checks) .owned,
        allocator: bun.safety.CheckedAllocator = .{},

        pub const Elem = Type;

        pub const empty: Self = .{};

        pub fn initCapacity(allocator: std.mem.Allocator, len: usize) OOM!Self {
            if (len > std.math.maxInt(u32)) return error.OutOfMemory;
            var this = initWithBuffer(try allocator.alloc(Type, len));
            this.allocator.set(allocator);
            return this;
        }

        pub fn initOne(allocator: std.mem.Allocator, value: Type) OOM!Self {
            var items = try allocator.alloc(Type, 1);
            items[0] = value;
            return .{
                .ptr = @as([*]Type, @ptrCast(items.ptr)),
                .len = 1,
                .cap = 1,
                .allocator = .init(allocator),
            };
        }

        pub fn moveFromList(list_ptr: anytype) Self {
            const ListType = std.meta.Child(@TypeOf(list_ptr));

            if (comptime ListType == Self) {
                @compileError("unnecessary call to `moveFromList`");
            }

            const unsupported_arg_msg = "unsupported argument to `moveFromList`: *" ++
                @typeName(ListType);

            const capacity = if (comptime @hasField(ListType, "capacity"))
                list_ptr.capacity
            else if (comptime @hasField(ListType, "cap"))
                list_ptr.cap
            else if (comptime std.meta.hasFn(ListType, "capacity"))
                list_ptr.capacity()
            else
                @compileError(unsupported_arg_msg);

            const items = if (comptime std.meta.hasFn(ListType, "moveToUnmanaged"))
                list_ptr.moveToUnmanaged().items
            else if (comptime @hasField(ListType, "items"))
                list_ptr.items
            else if (comptime std.meta.hasFn(ListType, "slice"))
                list_ptr.slice()
            else
                @compileError(unsupported_arg_msg);

            if (comptime Environment.allow_assert) {
                bun.assert(items.len <= capacity);
            }

            var this: Self = .{
                .ptr = items.ptr,
                .len = @intCast(items.len),
                .cap = @intCast(capacity),
            };

            const allocator = if (comptime @hasField(ListType, "allocator"))
                list_ptr.allocator
            else if (comptime std.meta.hasFn(ListType, "allocator"))
                list_ptr.allocator();

            if (comptime @TypeOf(allocator) == void) {
                list_ptr.* = .empty;
            } else {
                this.allocator.set(bun.allocators.asStd(allocator));
                // `moveToUnmanaged` already cleared the old list.
                if (comptime !std.meta.hasFn(ListType, "moveToUnmanaged")) {
                    list_ptr.* = .init(allocator);
                }
            }
            return this;
        }

        /// Requirements:
        ///
        /// * `items` must be owned memory, allocated with some allocator. That same allocator must
        ///   be passed to methods that expect it, like `append`.
        ///
        /// * `items` must be the *entire* region of allocated memory. It cannot be a subslice.
        ///   If you really need an owned subslice, use `shrinkRetainingCapacity` followed by
        ///   `toOwnedSlice` on an `ArrayList`.
        pub fn fromOwnedSlice(items: []Type) Self {
            return .{
                .ptr = items.ptr,
                .len = @intCast(items.len),
                .cap = @intCast(items.len),
            };
        }

        /// Same requirements as `fromOwnedSlice`.
        pub fn initWithBuffer(buffer: []Type) Self {
            return .{
                .ptr = buffer.ptr,
                .len = 0,
                .cap = @intCast(buffer.len),
            };
        }

        /// Copies all elements of `items` into new memory. Creates shallow copies.
        pub fn fromSlice(allocator: std.mem.Allocator, items: []const Type) OOM!Self {
            if (items.len > std.math.maxInt(u32)) return error.OutOfMemory;
            const allocated = try allocator.alloc(Type, items.len);
            bun.copy(Type, allocated, items);

            return Self{
                .ptr = allocated.ptr,
                .len = @intCast(allocated.len),
                .cap = @intCast(allocated.len),
                .allocator = .init(allocator),
            };
        }

        /// This method invalidates the `BabyList`. Use `clearAndFree` if you want to empty the
        /// list instead.
        pub fn deinit(this: *Self, allocator: std.mem.Allocator) void {
            this.assertOwned();
            this.allocator.assertEq(allocator);
            var list_ = this.list();
            list_.deinit(allocator);
            this.* = undefined;
        }

        pub fn clearAndFree(this: *Self, allocator: std.mem.Allocator) void {
            this.deinit(allocator);
            this.* = .{};
        }

        pub fn clearRetainingCapacity(this: *Self) void {
            this.len = 0;
        }

        pub fn slice(this: Self) callconv(bun.callconv_inline) []Type {
            return this.ptr[0..this.len];
        }

        /// Same as `.slice()`, with an explicit coercion to const.
        pub fn sliceConst(this: Self) callconv(bun.callconv_inline) []const Type {
            return this.slice();
        }

        pub fn at(this: Self, index: usize) callconv(bun.callconv_inline) *const Type {
            bun.assert(index < this.len);
            return &this.ptr[index];
        }

        pub fn mut(this: Self, index: usize) callconv(bun.callconv_inline) *Type {
            bun.assert(index < this.len);
            return &this.ptr[index];
        }

        pub fn first(this: Self) callconv(bun.callconv_inline) ?*Type {
            return if (this.len > 0) &this.ptr[0] else null;
        }

        pub fn last(this: Self) callconv(bun.callconv_inline) ?*Type {
            return if (this.len > 0) &this.ptr[this.len - 1] else null;
        }

        /// Empties the `BabyList`.
        pub fn toOwnedSlice(this: *Self, allocator: std.mem.Allocator) OOM![]Type {
            if ((comptime safety_checks) and this.len != this.cap) this.assertOwned();
            var list_ = this.listManaged(allocator);
            const result = try list_.toOwnedSlice();
            this.* = .empty;
            return result;
        }

        pub fn moveToList(this: *Self) std.ArrayList(Type) {
            this.assertOwned();
            defer this.* = .empty;
            return this.list();
        }

        pub fn moveToListManaged(this: *Self, allocator: std.mem.Allocator) std.array_list.Managed(Type) {
            this.assertOwned();
            defer this.* = .empty;
            return this.listManaged(allocator);
        }

        pub fn expandToCapacity(this: *Self) void {
            this.len = this.cap;
        }

        pub fn ensureTotalCapacity(
            this: *Self,
            allocator: std.mem.Allocator,
            new_capacity: usize,
        ) OOM!void {
            if (new_capacity > std.math.maxInt(u32)) return error.OutOfMemory;
            this.allocator.set(allocator);
            if (new_capacity <= this.cap) return;
            const capacity = @min(std.ArrayList(Type).growCapacity(new_capacity), std.math.maxInt(u32));
            try this.ensureTotalCapacityPrecise(allocator, capacity);
        }

        pub fn ensureTotalCapacityPrecise(
            this: *Self,
            allocator: std.mem.Allocator,
            new_capacity: usize,
        ) OOM!void {
            if (new_capacity > std.math.maxInt(u32)) return error.OutOfMemory;
            if ((comptime safety_checks) and new_capacity > this.cap) this.assertOwned();
            if (@sizeOf(Type) == 0) {
                this.allocator.set(allocator);
                this.cap = @max(this.cap, @as(u32, @intCast(new_capacity)));
                return;
            }
            var list_ = this.listManaged(allocator);
            try list_.ensureTotalCapacityPrecise(new_capacity);
            this.update(list_);
        }

        pub fn ensureUnusedCapacity(
            this: *Self,
            allocator: std.mem.Allocator,
            count: usize,
        ) OOM!void {
            if (count > std.math.maxInt(u32) - this.len) return error.OutOfMemory;
            try this.ensureTotalCapacity(allocator, @as(usize, this.len) + count);
        }

        pub fn shrinkAndFree(this: *Self, allocator: std.mem.Allocator, new_len: usize) void {
            if ((comptime safety_checks) and new_len < this.cap) this.assertOwned();
            var list_ = this.listManaged(allocator);
            list_.shrinkAndFree(new_len);
            this.update(list_);
        }

        pub fn shrinkRetainingCapacity(this: *Self, new_len: usize) void {
            bun.assertf(
                new_len <= this.len,
                "shrinkRetainingCapacity: new len ({d}) cannot exceed old ({d})",
                .{ new_len, this.len },
            );
            this.len = @intCast(new_len);
        }

        pub fn append(this: *Self, allocator: std.mem.Allocator, value: Type) OOM!void {
            try this.ensureUnusedCapacity(allocator, 1);
            this.appendAssumeCapacity(value);
        }

        pub fn appendAssumeCapacity(this: *Self, value: Type) void {
            bun.assert(this.cap > this.len);
            this.ptr[this.len] = value;
            this.len += 1;
        }

        pub fn appendSlice(this: *Self, allocator: std.mem.Allocator, vals: []const Type) OOM!void {
            try this.ensureUnusedCapacity(allocator, vals.len);
            this.appendSliceAssumeCapacity(vals);
        }

        pub fn appendSliceAssumeCapacity(this: *Self, values: []const Type) void {
            bun.assert(this.cap >= this.len + @as(u32, @intCast(values.len)));
            const tail = this.ptr[this.len .. this.len + values.len];
            bun.copy(Type, tail, values);
            this.len += @intCast(values.len);
            bun.assert(this.cap >= this.len);
        }

        pub fn pop(this: *Self) ?Type {
            if (this.len == 0) return null;
            this.len -= 1;
            return this.ptr[this.len];
        }

        pub fn orderedRemove(this: *Self, index: usize) Type {
            var l = this.list();
            defer this.update(l);
            return l.orderedRemove(index);
        }

        pub fn swapRemove(this: *Self, index: usize) Type {
            var l = this.list();
            defer this.update(l);
            return l.swapRemove(index);
        }

        pub fn insert(this: *Self, allocator: std.mem.Allocator, index: usize, val: Type) OOM!void {
            try this.ensureUnusedCapacity(allocator, 1);
            var list_ = this.listManaged(allocator);
            list_.insertAssumeCapacity(index, val);
            this.update(list_);
        }

        pub fn insertSlice(
            this: *Self,
            allocator: std.mem.Allocator,
            index: usize,
            vals: []const Type,
        ) OOM!void {
            try this.ensureUnusedCapacity(allocator, vals.len);
            var list_ = this.listManaged(allocator);
            @memcpy(list_.addManyAtAssumeCapacity(index, vals.len), vals);
            this.update(list_);
        }

        pub fn replaceRange(
            allocator: std.mem.Allocator,
            this: *Self,
            start: usize,
            len_: usize,
            new_items: []const Type,
        ) OOM!void {
            bun.assert(start <= this.len and len_ <= this.len - start);
            if (new_items.len > len_) try this.ensureUnusedCapacity(allocator, new_items.len - len_);
            var list_ = this.listManaged(allocator);
            list_.replaceRangeAssumeCapacity(start, len_, new_items);
            this.update(list_);
        }

        pub fn clone(this: Self, allocator: std.mem.Allocator) OOM!Self {
            var copy = try Self.initCapacity(allocator, this.cap);
            copy.appendSliceAssumeCapacity(this.slice());
            return copy;
        }

        pub fn unusedCapacitySlice(this: Self) []Type {
            return this.ptr[this.len..this.cap];
        }

        pub fn contains(this: Self, item: []const Type) bool {
            return this.len > 0 and
                @intFromPtr(item.ptr) >= @intFromPtr(this.ptr) and
                @intFromPtr(item.ptr) < @intFromPtr(this.ptr) + this.len;
        }

        pub fn sortAsc(this: *Self) void {
            bun.strings.sortAsc(this.slice());
        }

        pub fn sort(this: *Self, comptime Context: type, context: Context) void {
            std.sort.pdq(Type, this.slice(), context, Context.lessThan);
        }

        pub fn writableSlice(
            this: *Self,
            allocator: std.mem.Allocator,
            additional: usize,
        ) OOM![]Type {
            try this.ensureUnusedCapacity(allocator, additional);
            const previous_len = this.len;
            this.len += @intCast(additional);
            return this.ptr[previous_len..this.len];
        }

        pub fn allocatedSlice(this: Self) []Type {
            return this.ptr[0..this.cap];
        }

        pub fn memoryCost(this: Self) usize {
            return this.cap * @sizeOf(Type);
        }

        /// This method is available only for `BabyList(u8)`.
        pub fn appendFmt(
            this: *Self,
            allocator: std.mem.Allocator,
            comptime fmt: []const u8,
            args: anytype,
        ) OOM!void {
            if (comptime Type != u8) @compileError("Unsupported for type " ++ @typeName(Type));
            var writer: AppendWriter = .{ .list = this, .allocator = allocator };
            writer.interface.print(fmt, args) catch return error.OutOfMemory;
        }

        const AppendWriter = struct {
            list: *Self,
            allocator: std.mem.Allocator,
            interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

            fn drain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const writer: *@This() = @fieldParentPtr("interface", interface);
                const pattern = data[data.len - 1];
                var count = std.math.mul(usize, pattern.len, splat) catch return error.WriteFailed;
                for (data[0 .. data.len - 1]) |bytes| {
                    count = std.math.add(usize, count, bytes.len) catch return error.WriteFailed;
                }
                writer.list.ensureUnusedCapacity(writer.allocator, count) catch return error.WriteFailed;
                for (data[0 .. data.len - 1]) |bytes| writer.list.appendSliceAssumeCapacity(bytes);
                if (pattern.len > 0) for (0..splat) |_| {
                    writer.list.appendSliceAssumeCapacity(pattern);
                };
                return count;
            }
        };

        /// This method is available only for `BabyList(u8)`.
        pub fn write(this: *Self, allocator: std.mem.Allocator, str: []const u8) OOM!u32 {
            if (comptime Type != u8)
                @compileError("Unsupported for type " ++ @typeName(Type));
            const initial = this.len;
            try this.appendSlice(allocator, str);
            return this.len - initial;
        }

        /// This method is available only for `BabyList(u8)`.
        pub fn writeLatin1(this: *Self, allocator: std.mem.Allocator, str: []const u8) OOM!u32 {
            if ((comptime safety_checks) and str.len > 0) this.assertOwned();
            if (comptime Type != u8)
                @compileError("Unsupported for type " ++ @typeName(Type));
            if (str.len > std.math.maxInt(u32) - this.len) return error.OutOfMemory;
            const length = strings.elementLengthLatin1IntoUTF8(str);
            try this.ensureUnusedCapacity(allocator, length);
            const written = bun.simdutf.convert.latin1.to.utf8(str, this.unusedCapacitySlice());
            bun.assert(written == length);
            this.len += @intCast(written);
            return @intCast(written);
        }

        /// This method is available only for `BabyList(u8)`. Invalid characters are replaced with
        /// replacement character
        pub fn writeUTF16(this: *Self, allocator: std.mem.Allocator, str: []const u16) OOM!u32 {
            if ((comptime safety_checks) and str.len > 0) this.assertOwned();
            if (comptime Type != u8)
                @compileError("Unsupported for type " ++ @typeName(Type));

            if (str.len > std.math.maxInt(u32) - this.len) return error.OutOfMemory;
            const length = strings.elementLengthUTF16IntoUTF8WithReplacement(str);
            try this.ensureUnusedCapacity(allocator, length);
            const encoded = strings.copyUTF16IntoUTF8WithBufferImpl(this.unusedCapacitySlice(), str, length, false);
            bun.assert(encoded.read == str.len and encoded.written == length);
            this.len += encoded.written;
            return encoded.written;
        }

        /// This method is available only for `BabyList(u8)`.
        pub fn writeTypeAsBytesAssumeCapacity(this: *Self, comptime Int: type, int: Int) void {
            if (comptime Type != u8)
                @compileError("Unsupported for type " ++ @typeName(Type));
            bun.assert(this.cap >= this.len + @sizeOf(Int));
            @as([*]align(1) Int, @ptrCast(this.ptr[this.len .. this.len + @sizeOf(Int)]))[0] = int;
            this.len += @sizeOf(Int);
        }

        pub fn parse(input: *bun.css.Parser) bun.css.Result(Self) {
            return switch (input.parseCommaSeparated(Type, bun.css.generic.parseFor(Type))) {
                .result => |v| return .{ .result = Self{
                    .ptr = v.items.ptr,
                    .len = @intCast(v.items.len),
                    .cap = @intCast(v.capacity),
                } },
                .err => |e| return .{ .err = e },
            };
        }

        pub fn toCss(this: *const Self, dest: *bun.css.Printer) bun.css.PrintErr!void {
            return bun.css.to_css.fromBabyList(Type, this, dest);
        }

        pub fn eql(lhs: *const Self, rhs: *const Self) bool {
            if (lhs.len != rhs.len) return false;
            for (lhs.sliceConst(), rhs.sliceConst()) |*a, *b| {
                if (!bun.css.generic.eql(Type, a, b)) return false;
            }
            return true;
        }

        pub fn deepClone(this: Self, allocator: std.mem.Allocator) !Self {
            if (!@hasDecl(Type, "deepClone")) {
                @compileError("Unsupported type for BabyList.deepClone(): " ++ @typeName(Type));
            }

            var list_ = try initCapacity(allocator, this.len);
            for (this.slice()) |item| {
                const clone_result = item.deepClone(allocator);
                const cloned_item = switch (comptime @typeInfo(@TypeOf(clone_result))) {
                    .error_union => try clone_result,
                    else => clone_result,
                };
                list_.appendAssumeCapacity(cloned_item);
            }
            return list_;
        }

        /// Same as `deepClone` but calls `bun.outOfMemory` instead of returning an error.
        /// `Type.deepClone` must not return any error except `error.OutOfMemory`.
        pub fn deepCloneInfallible(this: Self, allocator: std.mem.Allocator) Self {
            return bun.handleOom(this.deepClone(allocator));
        }

        /// Avoid using this function. It creates a `BabyList` that will immediately invoke
        /// illegal behavior if you call any method that could allocate or free memory. On top of
        /// that, if `items` points to read-only memory, any attempt to modify a list element (which
        /// is very easy given how many methods return non-const pointers and slices) will also
        /// invoke illegal behavior.
        ///
        /// To find an alternative:
        ///
        /// 1. Determine how the resulting `BabyList` is being used. Is it stored in a struct field?
        ///    Is it passed to a function?
        ///
        /// 2. Determine whether that struct field or function parameter expects the list to be
        ///    mutable. Does it potentially call any methods that could allocate or free, like
        ///    `append` or `deinit`?
        ///
        /// 3. If the list is expected to be mutable, don't use this function, because the returned
        ///    list will invoke illegal behavior if mutated. Use `fromSlice` or another allocating
        ///    function instead.
        ///
        /// 4. If the list is *not* expected to be mutable, don't use a `BabyList` at all. Change
        ///    the field or parameter to be a plain slice instead.
        ///
        /// Requirements:
        ///
        /// * Methods that could potentially free, remap, or resize `items` cannot be called.
        pub fn fromBorrowedSliceDangerous(items: []const Type) Self {
            var this: Self = .fromOwnedSlice(@constCast(items));
            if (comptime safety_checks) this.origin = .{ .borrowed = .{
                .trace = if (traces_enabled) .capture(@returnAddress()),
            } };
            return this;
        }

        /// Transfers ownership of this `BabyList` to a new allocator.
        ///
        /// This method is valid only if both the old allocator and new allocator are
        /// `MimallocArena`s. See `bun.safety.CheckedAllocator.transferOwnership`.
        pub fn transferOwnership(this: *Self, new_allocator: anytype) void {
            this.allocator.transferOwnership(new_allocator);
        }

        pub fn format(
            this: Self,
            writer: *std.Io.Writer,
        ) !void {
            return writer.print(
                "BabyList({s}){{{f}}}",
                .{ @typeName(Type), this.list() },
            );
        }

        fn assertOwned(this: *Self) void {
            if ((comptime !safety_checks) or this.origin == .owned) return;
            if (comptime traces_enabled) {
                bun.Output.note("borrowed BabyList created here:", .{});
                bun.crash_handler.dumpStackTrace(
                    this.origin.borrowed.trace.trace(),
                    .{ .frame_count = 10, .stop_at_jsc_llint = true },
                );
            }
            std.debug.panic(
                "cannot perform this operation on a BabyList that doesn't own its data",
                .{},
            );
        }

        fn list(this: Self) std.ArrayList(Type) {
            return .{
                .items = this.slice(),
                .capacity = this.cap,
                .pointer_stability = .{},
            };
        }

        fn listManaged(this: *Self, allocator: std.mem.Allocator) std.array_list.Managed(Type) {
            this.allocator.set(allocator);
            var list_ = this.list();
            return list_.toManaged(allocator);
        }

        fn update(this: *Self, list_: anytype) void {
            this.ptr = list_.items.ptr;
            this.len = @intCast(list_.items.len);
            this.cap = @intCast(list_.capacity);
            if (comptime Environment.allow_assert) {
                bun.assert(this.len <= this.cap);
            }
        }

        pub const looksLikeContainerTypeBabyList = Type;
    };
}

pub const ByteList = BabyList(u8);

test "BabyList range replacement publishes storage and rejects unrepresentable growth" {
    const allocator = std.testing.allocator;
    var list = try ByteList.fromSlice(allocator, "abc");
    defer list.deinit(allocator);

    try ByteList.replaceRange(allocator, &list, 1, 1, "replacement");
    try std.testing.expectEqualStrings("areplacementc", list.slice());
    try ByteList.replaceRange(allocator, &list, 1, 11, "");
    try std.testing.expectEqualStrings("ac", list.slice());

    const pointer = list.ptr;
    const capacity = list.cap;
    try std.testing.expectError(error.OutOfMemory, list.ensureUnusedCapacity(allocator, std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfMemory, list.ensureTotalCapacity(allocator, @as(usize, std.math.maxInt(u32)) + 1));
    try std.testing.expect(list.ptr == pointer);
    try std.testing.expectEqual(capacity, list.cap);
    try std.testing.expectEqualStrings("ac", list.slice());
}

test "ByteList formatting and Unicode writes preserve prefixes and replace lone surrogates" {
    const allocator = std.testing.allocator;
    var list = try ByteList.fromSlice(allocator, "prefix:");
    defer list.deinit(allocator);
    try list.appendFmt(allocator, "{s: >5}:{d}", .{ "x", 42 });
    try std.testing.expectEqualStrings("prefix:    x:42", list.slice());
    try std.testing.expectEqual(@as(u32, 2), try list.writeLatin1(allocator, "\xe9"));
    try std.testing.expectEqualStrings("prefix:    x:42\xc3\xa9", list.slice());

    list.clearRetainingCapacity();
    const input = [_]u16{ 0xd800, 'a', 0xd83d, 0xde00, 0xdc00 };
    const expected = "\xef\xbf\xbda\xf0\x9f\x98\x80\xef\xbf\xbd";
    try std.testing.expectEqual(@as(u32, expected.len), try list.writeUTF16(allocator, &input));
    try std.testing.expectEqualStrings(expected, list.slice());
}

pub const OffsetByteList = struct {
    const Self = @This();

    head: u32 = 0,
    byte_list: ByteList = .{},

    pub fn init(head: u32, byte_list: ByteList) Self {
        return .{
            .head = head,
            .byte_list = byte_list,
        };
    }

    pub fn write(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !void {
        _ = try self.byte_list.write(allocator, bytes);
    }

    pub fn slice(self: *const Self) []u8 {
        return self.byte_list.slice()[0..self.head];
    }

    pub fn remaining(self: *const Self) []u8 {
        return self.byte_list.slice()[self.head..];
    }

    pub fn consume(self: *Self, bytes: u32) void {
        self.head +|= bytes;
        if (self.head >= self.byte_list.len) {
            self.head = 0;
            self.byte_list.len = 0;
        }
    }

    pub fn len(self: *const Self) u32 {
        return self.byte_list.len - self.head;
    }

    pub fn clear(self: *Self) void {
        self.head = 0;
        self.byte_list.len = 0;
    }

    /// This method invalidates `self`. Use `clearAndFree` to reset to empty instead.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.byte_list.deinit(allocator);
        self.* = undefined;
    }

    pub fn clearAndFree(self: *Self, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = .{};
    }
};

pub const safety_checks = Environment.ci_assert;

const std = @import("std");

const bun = @import("bun");
const OOM = bun.OOM;
const strings = bun.strings;
const StoredTrace = bun.crash_handler.StoredTrace;

const Environment = bun.Environment;
const traces_enabled = Environment.isDebug;
