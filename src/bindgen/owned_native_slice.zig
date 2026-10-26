pub fn OwnedNativeSlice(comptime T: type, comptime affinity: gc_token.Affinity) type {
    return struct {
        values: []T,

        pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), T, affinity);

        const Self = @This();
        const has_destructor = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
            else => false,
        };

        comptime {
            if (has_destructor) {
                if (@TypeOf(T.deinit) != fn (*T) void)
                    @compileError("owned native slice elements require fn deinit(*T) void");
            } else {
                @import("./class_field_validation.zig").validateNativeData(T, @typeName(T), .{});
            }
        }

        pub const empty: Self = .{ .values = &.{} };

        pub const Builder = struct {
            storage: []T = &.{},
            initialized: usize = 0,

            pub fn init(length: usize) bun.OOM!Builder {
                return .{ .storage = try bun.default_allocator.alloc(T, length) };
            }

            pub fn appendOwned(builder: *Builder, value: T) void {
                if (builder.initialized == builder.storage.len) @panic("native slice builder is full");
                builder.storage[builder.initialized] = value;
                builder.initialized += 1;
            }

            pub fn slice(builder: *Builder) []T {
                return builder.storage[0..builder.initialized];
            }

            pub fn deinit(builder: *Builder) void {
                const pending = builder.*;
                builder.* = .{};
                release(pending.storage, pending.initialized);
            }

            pub fn finish(builder: *Builder) Self {
                if (builder.initialized != builder.storage.len) @panic("native slice builder is incomplete");
                const storage = builder.storage;
                builder.* = .{};
                return .fromOwnedSlice(storage);
            }
        };

        /// Takes initialized elements allocated with bun.default_allocator.
        pub fn fromOwnedSlice(values: []T) Self {
            return .{ .values = values };
        }

        pub fn slice(self: *const Self) []const T {
            return self.values;
        }

        pub fn deinit(self: *Self) void {
            const values = self.values;
            self.* = .empty;
            release(values, values.len);
        }

        fn release(values: []T, initialized: usize) void {
            if (comptime has_destructor) {
                for (values[0..initialized]) |*value| value.deinit();
            }
            bun.default_allocator.free(values);
        }
    };
}

const bun = @import("bun");
const gc_token = @import("./gc_token.zig");
