const ResultLayout = @This();

structure: ?SQLTypes.ObjectStructure = null,
slots: []Slot = &.{},
engine_slots: []SQLTypes.ResultColumnSlot = &.{},
flags: Flags = .{
    .has_indexed_columns = false,
    .has_named_columns = false,
    .has_duplicate_columns = false,
},
initialized: bool = false,

pub const Slot = @import("../../sql/shared/ResultColumnSlot.zig");
pub const Flags = SQLResultMaterializer.LayoutFlags;

pub fn init(this: *ResultLayout, columns: anytype, values: *const SQLTypes.BindingValues) bun.JSError!void {
    bun.debugAssert(!this.initialized);

    const slots = bun.handleOom(bun.default_allocator.alloc(Slot, columns.len));
    @memset(slots, .{});
    errdefer {
        for (slots) |*slot| slot.deinit();
        if (slots.len > 0) bun.default_allocator.free(slots);
    }

    var seen_names = bun.StringHashMap(void).init(bun.default_allocator);
    defer seen_names.deinit();
    bun.handleOom(seen_names.ensureUnusedCapacity(@intCast(columns.len)));

    var seen_indices: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen_indices.deinit(bun.default_allocator);
    bun.handleOom(seen_indices.ensureTotalCapacity(bun.default_allocator, @intCast(columns.len)));

    var flags: Flags = .{
        .has_indexed_columns = false,
        .has_named_columns = false,
        .has_duplicate_columns = false,
    };
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
                    break :slot .{};
                }

                flags.has_named_columns = true;
                break :slot .{ .value = .{ .named = bun.String.cloneUTF8(name.slice()) } };
            },
            .index => |index| slot: {
                const entry = bun.handleOom(seen_indices.getOrPut(bun.default_allocator, index));
                if (entry.found_existing) {
                    flags.has_duplicate_columns = true;
                    break :slot .{};
                }

                flags.has_indexed_columns = true;
                break :slot .{ .value = .{ .indexed = index } };
            },
            .duplicate => slot: {
                flags.has_duplicate_columns = true;
                break :slot .{};
            },
        };
    }

    const engine_slots = bun.handleOom(bun.default_allocator.alloc(SQLTypes.ResultColumnSlot, slots.len));
    errdefer if (engine_slots.len > 0) bun.default_allocator.free(engine_slots);
    SQLResultMaterializer.encodeColumnSlots(engine_slots, slots);

    if (names_are_valid_utf8) {
        this.structure = try SQLResultMaterializer.createObjectStructure(values, engine_slots);

        if (this.structure != null) {
            var offset: u32 = 0;
            for (slots, engine_slots) |*slot, *engine_slot| {
                switch (slot.value) {
                    .named => |name| {
                        name.deref();
                        slot.* = .{ .value = .{ .named_offset = offset } };
                        engine_slot.* = .{ .named_offset = .{ .value = offset } };
                        offset += 1;
                    },
                    else => {},
                }
            }
        }
    }

    this.slots = slots;
    this.engine_slots = engine_slots;
    this.flags = flags;
    this.initialized = true;
}

pub fn deinit(this: *ResultLayout) void {
    if (this.structure) |*structure| structure.deinit();
    for (this.slots) |*slot| slot.deinit();
    if (this.slots.len > 0) bun.default_allocator.free(this.slots);
    if (this.engine_slots.len > 0) bun.default_allocator.free(this.engine_slots);
    this.* = .{};
}

pub fn materializerLayout(this: *const ResultLayout) SQLResultMaterializer.Layout {
    return .{
        .structure = if (this.structure) |*structure| structure else null,
        .slots = this.engine_slots,
        .flags = this.flags,
    };
}

const std = @import("std");
const bun = @import("bun");
const SQLTypes = @import("./SQLTypes.zig");
const SQLResultMaterializer = @import("./SQLResultMaterializer.zig");
