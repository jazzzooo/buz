pub const JSPropertyIteratorOptions = struct {
    skip_empty_name: bool,
    own_properties_only: bool = true,
    observable: bool = true,
    only_non_index_properties: bool = false,
};

pub fn JSPropertyIterator(comptime options: JSPropertyIteratorOptions) type {
    return struct {
        len: usize,
        i: usize = 0,
        iter_i: usize = 0,
        impl: @FieldType(Creation, "iterator"),
        object: bun.bindgen.EngineRoot,

        pub const Entry = struct {
            name: bun.bindgen.DOMString,
            value: bun.bindgen.EngineValueResult,

            pub fn deinit(entry: *Entry) void {
                entry.name.deinit();
            }
        };

        pub fn getLongestPropertyName(this: *@This(), context: anytype) usize {
            return if (this.impl) |*iter|
                context.engineIn("property_iterators", "propertyIteratorGetLongestPropertyName").call(.{ .iterator = iter })
            else
                0;
        }

        pub fn deinit(this: *@This()) void {
            if (this.impl) |*impl| impl.deinit();
            this.object.deinit();
            this.* = undefined;
        }

        pub fn init(context: anytype, object: *bun.bindgen.EngineRoot) bun.JSError!@This() {
            const result = try context.engineIn("property_iterators", "propertyIteratorCreate").call(.{
                .value = object.operand(context).asEngine(),
                .ownPropertiesOnly = options.own_properties_only,
                .onlyNonIndexProperties = options.only_non_index_properties,
            });
            return .{
                .object = object.take(),
                .impl = result.iterator,
                .len = result.count,
            };
        }

        pub fn reset(this: *@This()) void {
            this.iter_i = 0;
            this.i = 0;
        }

        pub fn next(this: *@This(), context: anytype) bun.JSError!?Entry {
            while (this.iter_i < this.len) {
                this.i = this.iter_i;
                this.iter_i += 1;
                var entry = (try context.engineIn("property_iterators", if (options.observable)
                    "propertyIteratorGetNameAndValue"
                else
                    "propertyIteratorGetNameAndValueNonObservable").call(.{
                    .iterator = &this.impl.?,
                    .object = this.object.operand(context).asEngine(),
                    .index = this.i,
                })) orelse continue;

                if (options.skip_empty_name and entry.name.isEmpty()) {
                    entry.name.deinit();
                    continue;
                }
                return .{ .name = entry.name, .value = entry.value };
            }
            this.i = this.iter_i;
            return null;
        }
    };
}

const bun = @import("bun");
const Creation = bun.bindgen.Return(bun.bindgen.Module("property_iterators").engineShim("propertyIteratorCreate"));
