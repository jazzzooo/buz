pub fn linearFifoOrderedRemoveProbe(globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const arguments = callframe.arguments();
    if (arguments.len < 1) {
        return globalThis.throw("linearFifoOrderedRemoveProbe: expected 1 argument", .{});
    }

    const Fifo = bun.LinearFifo(u8, .{ .Static = 16 });
    var fifo = Fifo.init();

    switch (arguments[0].toInt32()) {
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
        else => return globalThis.throw("linearFifoOrderedRemoveProbe: invalid scenario", .{}),
    }

    const result = try jsc.JSArray.createEmpty(globalThis, fifo.count);
    for (0..fifo.count) |i| {
        try result.putDirectIndex(globalThis, @intCast(i), .jsNumber(fifo.peekItem(i)));
    }
    return result.toJS();
}

const bun = @import("bun");
const jsc = bun.jsc;
