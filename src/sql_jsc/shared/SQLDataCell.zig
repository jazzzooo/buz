pub const SQLDataCell = struct {
    tag: Tag,

    value: Value,
    free_value: u8 = 0,

    pub const Tag = enum(u8) {
        null = 0,
        string = 1,
        float8 = 2,
        int4 = 3,
        int8 = 4,
        bool = 5,
        date = 6,
        date_with_time_zone = 7,
        bytea = 8,
        json = 9,
        array = 10,
        typed_array = 11,
        raw = 12,
        uint4 = 13,
        uint8 = 14,
    };

    pub const Value = union {
        null: u8,
        string: ?bun.WTF.StringImpl,
        float8: f64,
        int4: i32,
        int8: i64,
        bool: u8,
        date: f64,
        date_with_time_zone: f64,
        bytea: [2]usize,
        json: ?bun.WTF.StringImpl,
        array: Array,
        typed_array: TypedArray,
        raw: Raw,
        uint4: u32,
        uint8: u64,
    };

    pub const Array = struct {
        ptr: ?[*]SQLDataCell = null,
        len: u32,
        cap: u32,
        pub fn slice(this: *const Array) []const SQLDataCell {
            const ptr = this.ptr orelse return &.{};
            return ptr[0..this.len];
        }

        pub fn mutableSlice(this: *Array) []SQLDataCell {
            const ptr = this.ptr orelse return &.{};
            return ptr[0..this.len];
        }

        pub fn allocatedSlice(this: *Array) []SQLDataCell {
            const ptr = this.ptr orelse return &.{};
            return ptr[0..this.cap];
        }

        pub fn deinit(this: *Array) void {
            const allocated = this.allocatedSlice();
            this.ptr = null;
            this.len = 0;
            this.cap = 0;
            bun.default_allocator.free(allocated);
        }
    };
    pub const Raw = struct {
        ptr: ?[*]const u8 = null,
        len: u64,

        pub fn slice(this: Raw) []const u8 {
            const ptr = this.ptr orelse return &.{};
            return ptr[0..@intCast(this.len)];
        }
    };
    pub const TypedArray = struct {
        head_ptr: ?[*]u8 = null,
        ptr: ?[*]u8 = null,
        len: u32,
        byte_len: u32,
        kind: TypedArrayKind,

        pub fn elementBytes(this: *const TypedArray) []const u8 {
            const ptr = this.ptr orelse return &.{};
            return ptr[0 .. @as(usize, this.len) * this.kind.byteWidth()];
        }

        pub fn ownedAllocation(this: *const TypedArray) []u8 {
            const ptr = this.head_ptr orelse return &.{};
            return ptr[0..this.byte_len];
        }
    };

    pub const TypedArrayKind = enum {
        int32,
        float32,

        pub fn byteWidth(kind: TypedArrayKind) usize {
            return switch (kind) {
                .int32, .float32 => 4,
            };
        }
    };

    pub fn deinit(this: *SQLDataCell) void {
        if (this.free_value == 0) return;

        switch (this.tag) {
            .string => {
                if (this.value.string) |str| {
                    str.deref();
                }
            },
            .json => {
                if (this.value.json) |str| {
                    str.deref();
                }
            },
            .bytea => {
                if (this.value.bytea[1] == 0) return;
                const slice = @as([*]u8, @ptrFromInt(this.value.bytea[0]))[0..this.value.bytea[1]];
                bun.default_allocator.free(slice);
            },
            .array => {
                for (this.value.array.mutableSlice()) |*cell| {
                    cell.deinit();
                }
                this.value.array.deinit();
            },
            .typed_array => {
                bun.default_allocator.free(this.value.typed_array.ownedAllocation());
            },

            else => {},
        }
    }

    pub fn raw(optional_bytes: ?*const Data) SQLDataCell {
        if (optional_bytes) |bytes| {
            const bytes_slice = bytes.slice();
            return SQLDataCell{
                .tag = .raw,
                .value = .{ .raw = .{ .ptr = @ptrCast(bytes_slice.ptr), .len = bytes_slice.len } },
            };
        }
        // TODO: check empty and null fields
        return SQLDataCell{
            .tag = .null,
            .value = .{ .null = 0 },
        };
    }
};

const bun = @import("bun");
const Data = @import("../../sql/shared/Data.zig").Data;
