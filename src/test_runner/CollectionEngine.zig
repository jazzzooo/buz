pub fn step(buntest_strong: bun_test.BunTestPtr, globalThis: *jsc.JSGlobalObject, data: bun_test.BunTest.RefDataValue) bun.JSError!bun_test.StepResult {
    group.begin(@src());
    defer group.end();
    const buntest = buntest_strong.get();
    const this = &buntest.collection;

    if (data != .start) this.completeStep(data);
    this.promoteCallbacks();

    while (this.describe_callback_queue.items.len > 0) {
        group.log("runOne -> call next", .{});
        var first = this.describe_callback_queue.pop().?;
        defer first.deinit();

        if (first.active_scope.failed) continue;

        const callback = &first.callback;
        const active_scope = first.active_scope;
        const new_scope = first.new_scope;

        const previous_scope = active_scope;

        group.log("collection:runOne set scope from {s}", .{this.active_scope.base.name orelse "undefined"});
        this.active_scope = new_scope;
        group.log("collection:runOne set scope to {s}", .{this.active_scope.base.name orelse "undefined"});

        if (BunTest.runTestCallback(buntest_strong, globalThis, callback, false, .{
            .collection = .{ .active_scope = previous_scope },
        }, &.epoch)) |cfg_data| {
            buntest.addResult(cfg_data);
        }

        return .{ .waiting = .{} };
    }
    return .complete;
}

const bun = @import("bun");
const jsc = bun.jsc;

const bun_test = jsc.Jest.bun_test;
const BunTest = bun_test.BunTest;
const group = bun_test.debug.group;
