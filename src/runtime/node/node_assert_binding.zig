/// ```ts
/// const enum DiffType {
///     Insert = 0,
///     Delete = 1,
///     Equal  = 2,
/// }
/// type Diff = { kind: DiffType, value: string | number };
/// declare function myersDiff(actual: string, expected: string): Diff[];
/// ```
pub fn myersDiff(
    context: bun.bindgen.CallContext(MyersDiffSchema),
    args: bun.bindgen.Args(MyersDiffSchema),
) bun.bindgen.CallError(MyersDiffSchema)!bun.bindgen.Return(MyersDiffSchema) {
    var stack_fallback_buffer: [1024 * 2]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var arena = std.heap.ArenaAllocator.init(stack_fallback.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const check_comma_disparity = args.checkCommaDisparity orelse false;
    const lines = args.lines orelse false;

    var actual = args.actual.toOwned();
    var actual_str = actual.takeBunString();
    defer actual_str.deref();
    var expected = args.expected.toOwned();
    var expected_str = expected.takeBunString();
    defer expected_str.deref();

    bun.assertWithLocation(actual_str.tag != .Dead, @src());
    bun.assertWithLocation(expected_str.tag != .Dead, @src());

    return assert.myersDiff(
        allocator,
        context,
        &actual_str,
        &expected_str,
        check_comma_disparity,
        lines,
    );
}

const assert = @import("./node_assert.zig");
const bun = @import("bun");
const std = @import("std");
const NodeAssertBindings = bun.bindgen.Module("node_assert_binding");
const MyersDiffSchema = NodeAssertBindings.function("myersDiff");
const MyersDiffBinding = bun.bindgen.Fn(MyersDiffSchema, myersDiff);

comptime {
    _ = MyersDiffBinding;
}
