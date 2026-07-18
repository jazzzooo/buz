pub const SQLDataCell = extern struct {
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

    pub const Value = extern union {
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

    pub const Array = extern struct {
        ptr: ?[*]SQLDataCell = null,
        len: u32,
        cap: u32,
        pub fn slice(this: *Array) []SQLDataCell {
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
    pub const Raw = extern struct {
        ptr: ?[*]const u8 = null,
        len: u64,
    };
    pub const TypedArray = extern struct {
        head_ptr: ?[*]u8 = null,
        ptr: ?[*]u8 = null,
        len: u32,
        byte_len: u32,
        type: JSValue.JSType,

        pub fn slice(this: *TypedArray) []u8 {
            const ptr = this.ptr orelse return &.{};
            return ptr[0..this.len];
        }

        pub fn byteSlice(this: *TypedArray) []u8 {
            const ptr = this.head_ptr orelse return &.{};
            return ptr[0..this.len];
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
                for (this.value.array.slice()) |*cell| {
                    cell.deinit();
                }
                this.value.array.deinit();
            },
            .typed_array => {
                bun.default_allocator.free(this.value.typed_array.byteSlice());
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

    // TODO: cppbind isn't yet able to detect slice parameters when the next is uint32_t
    pub fn constructObjectFromDataCell(
        globalObject: *jsc.JSGlobalObject,
        encodedArrayValue: jsc.JSValue,
        cells: [*]SQLDataCell,
        count: u32,
        result_mode: u8,
        layout: ?*const ResultLayout,
    ) !jsc.JSValue {
        const slots = if (layout) |value| value.slots else &.{};
        const flags: u32 = if (layout) |value| @bitCast(value.flags) else 0;
        const structure = if (layout) |value| value.jsValue() orelse .js_undefined else .js_undefined;
        const slots_ptr: ?[*]const ResultLayout.Slot = if (slots.len > 0) slots.ptr else null;

        if (comptime bun.Environment.ci_assert) {
            var scope: jsc.ExceptionValidationScope = undefined;
            scope.init(globalObject, @src());
            defer scope.deinit();
            const value = JSC__constructObjectFromDataCell(globalObject, encodedArrayValue, structure, cells, count, flags, result_mode, slots_ptr, @intCast(slots.len));
            scope.assertExceptionPresenceMatches(value == .zero);
            return if (value == .zero) error.JSError else value;
        } else {
            const value = JSC__constructObjectFromDataCell(globalObject, encodedArrayValue, structure, cells, count, flags, result_mode, slots_ptr, @intCast(slots.len));
            if (value == .zero) return error.JSError;
            return value;
        }
    }

    pub extern fn JSC__constructObjectFromDataCell(
        *jsc.JSGlobalObject,
        JSValue,
        JSValue,
        [*]SQLDataCell,
        u32,
        u32, // layout flags
        u8, // result_mode
        ?[*]const ResultLayout.Slot,
        u32,
    ) JSValue;
};

const bun = @import("bun");
const Data = @import("../../sql/shared/Data.zig").Data;
const ResultLayout = @import("./ResultLayout.zig");

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
