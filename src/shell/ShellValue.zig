pub const Value = union(enum) {
    buffer: bindgen.OwnedMutableLease(u8),
    blob: bun.webcore.Blob,
    response: bindgen.ClassRef(ResponseSchema),
    stream: bun.webcore.ReadableStream.Owned,

    pub fn deinit(value: *Value) void {
        switch (value.*) {
            .buffer => |*buffer| buffer.deinit(),
            .blob => |*blob| blob.deinit(),
            .response => |*response| response.deinit(),
            .stream => |*stream| stream.deinit(),
        }
    }
};

pub const List = struct {
    values: std.array_list.Managed(Value),

    pub fn create(values: std.array_list.Managed(Value)) bun.OOM!*List {
        return bun.tryNew(List, .{ .values = values });
    }

    pub fn memoryCost(list: *const List) usize {
        return @sizeOf(List) + list.values.capacity * @sizeOf(Value);
    }

    pub fn destroy(list: *List) void {
        for (list.values.items) |*value| value.deinit();
        list.values.deinit();
        bun.destroy(list);
    }
};

pub const OwnedList = struct {
    list: *List,

    pub fn init(list: *List) OwnedList {
        return .{ .list = list };
    }

    pub fn get(this: OwnedList) *List {
        return this.list;
    }

    pub fn deinit(this: *OwnedList) void {
        this.list.destroy();
        this.* = undefined;
    }
};

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
const ResponseSchema = bindgen.Module("Response").class("Response");
