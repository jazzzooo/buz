const ResultLayout = @This();

structure: jsc.Strong.Optional = .empty,
slots: []Slot = &.{},
flags: Flags = .{},
initialized: bool = false,

pub const Slot = jsc.JSObject.ExternColumnSlot;

pub const Flags = packed struct(u32) {
    has_indexed_columns: bool = false,
    has_named_columns: bool = false,
    has_duplicate_columns: bool = false,
    _: u29 = 0,
};

pub fn init(this: *ResultLayout, columns: anytype, owner: ?jsc.JSValue, globalObject: *jsc.JSGlobalObject) void {
    bun.debugAssert(!this.initialized);

    const slots = bun.handleOom(bun.default_allocator.alloc(Slot, columns.len));
    @memset(slots, .{ .tag = .duplicate, .value = .{ .index = 0 } });

    var seen_names = bun.StringHashMap(void).init(bun.default_allocator);
    defer seen_names.deinit();
    bun.handleOom(seen_names.ensureUnusedCapacity(@intCast(columns.len)));

    var seen_indices: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen_indices.deinit(bun.default_allocator);
    bun.handleOom(seen_indices.ensureTotalCapacity(bun.default_allocator, @intCast(columns.len)));

    var flags: Flags = .{};
    var named_count: usize = 0;
    var names_are_valid_utf8 = true;
    var remaining = columns.len;
    while (remaining > 0) {
        remaining -= 1;
        const identifier = columns[remaining].name_or_index;
        slots[remaining] = switch (identifier) {
            .name => |name| slot: {
                names_are_valid_utf8 = names_are_valid_utf8 and std.unicode.utf8ValidateSlice(name.slice());
                const entry = bun.handleOom(seen_names.getOrPut(name.slice()));
                if (entry.found_existing) {
                    flags.has_duplicate_columns = true;
                    break :slot .{ .tag = .duplicate, .value = .{ .index = 0 } };
                }

                flags.has_named_columns = true;
                named_count += 1;
                break :slot .{ .tag = .named, .value = .{ .name = bun.String.createAtomIfPossible(name.slice()) } };
            },
            .index => |index| slot: {
                const entry = bun.handleOom(seen_indices.getOrPut(bun.default_allocator, index));
                if (entry.found_existing) {
                    flags.has_duplicate_columns = true;
                    break :slot .{ .tag = .duplicate, .value = .{ .index = 0 } };
                }

                flags.has_indexed_columns = true;
                break :slot .{ .tag = .indexed, .value = .{ .index = index } };
            },
            .duplicate => slot: {
                flags.has_duplicate_columns = true;
                break :slot .{ .tag = .duplicate, .value = .{ .index = 0 } };
            },
        };
    }

    if (owner != null and names_are_valid_utf8 and named_count <= jsc.JSObject.maxInlineCapacity()) {
        this.structure.set(globalObject, jsc.JSObject.createStructure(globalObject, owner, slots));

        var offset: u32 = 0;
        for (slots) |*slot| {
            if (slot.tag == .named) {
                slot.value.name.deref();
                slot.* = .{ .tag = .named_offset, .value = .{ .index = offset } };
                offset += 1;
            }
        }
    }

    this.slots = slots;
    this.flags = flags;
    this.initialized = true;
}

pub fn deinit(this: *ResultLayout) void {
    this.structure.deinit();
    for (this.slots) |*slot| slot.deinit();
    if (this.slots.len > 0) bun.default_allocator.free(this.slots);
    this.* = .{};
}

pub fn jsValue(this: *const ResultLayout) ?jsc.JSValue {
    return this.structure.get();
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
