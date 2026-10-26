const bun = @import("bun");

pub fn increment(parent: ?*bun.jsc.Jest.bun_test.BunTest.RefData) void {
    const execution_ref = parent orelse return;
    var active_test = execution_ref.bunTest() orelse return;
    defer active_test.deinit();
    const test_state = active_test.get();
    if (execution_ref.phase.sequence(test_state)) |sequence| {
        sequence.expect_call_count +|= 1;
    } else if (test_state.reporter) |reporter| {
        reporter.summary().expectations +|= 1;
    }
}
