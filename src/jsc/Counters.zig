const Counters = @This();

spawnSync_blocking: i32 = 0,
spawn_memfd: i32 = 0,

pub fn mark(this: *Counters, comptime tag: Field) void {
    @field(this, @tagName(tag)) +|= 1;
}

pub fn createCountersObject(
    _: bun.bindgen.CallContext(CreateCountersObjectSchema),
    _: bun.bindgen.Args(CreateCountersObjectSchema),
) bun.JSError!bun.bindgen.Return(CreateCountersObjectSchema) {
    const counters = bun.jsc.VirtualMachine.get().counters;
    return .{
        .spawnSync_blocking = counters.spawnSync_blocking,
        .spawn_memfd = counters.spawn_memfd,
    };
}

const Field = std.meta.FieldEnum(Counters);

const std = @import("std");

const bun = @import("bun");

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const CreateCountersObjectSchema = InternalTestingBindings.function("createCountersObject");
const CreateCountersObjectBinding = bun.bindgen.Fn(CreateCountersObjectSchema, createCountersObject);

comptime {
    _ = CreateCountersObjectBinding;
}
