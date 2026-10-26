pub fn linearFifoOrderedRemoveProbe(
    context: bun.bindgen.CallContext(LinearFifoOrderedRemoveProbeSchema),
    args: bun.bindgen.Args(LinearFifoOrderedRemoveProbeSchema),
) bun.bindgen.CallError(LinearFifoOrderedRemoveProbeSchema)!LinearFifoOrderedRemoveProbeResult {
    const Fifo = bun.LinearFifo(u8, .{ .Static = 16 });
    var fifo = Fifo.init();

    switch (args.scenario) {
        0 => {
            fifo.writeAssumeCapacity(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
            fifo.discard(8);
            fifo.writeAssumeCapacity(&.{ 100, 101, 102, 103, 104, 105, 106, 107, 108, 109 });
            fifo.orderedRemoveItem(6);
        },
        1 => {
            fifo.writeAssumeCapacity(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
            fifo.discard(12);
            fifo.writeAssumeCapacity(&.{ 200, 201, 202, 203, 204, 205, 206, 207 });
            fifo.orderedRemoveItem(5);
        },
        else => return context.fail(.invalid_scenario, {}),
    }

    var result: [16]u8 = undefined;
    for (0..fifo.count) |i| {
        result[i] = fifo.peekItem(i);
    }
    return LinearFifoOrderedRemoveProbeResult.fromOwnedSlice(result[0..fifo.count]);
}

const bun = @import("bun");

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const LinearFifoOrderedRemoveProbeSchema = InternalTestingBindings.function("linearFifoOrderedRemoveProbe");
const LinearFifoOrderedRemoveProbeResult = bun.bindgen.ResultType(LinearFifoOrderedRemoveProbeSchema.ReturnType);
const LinearFifoOrderedRemoveProbeBinding = bun.bindgen.Fn(LinearFifoOrderedRemoveProbeSchema, linearFifoOrderedRemoveProbe);

comptime {
    _ = LinearFifoOrderedRemoveProbeBinding;
}
