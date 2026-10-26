pub fn order(
    context: bun.bindgen.CallContext(OrderSchema),
    args: bun.bindgen.Args(OrderSchema),
) bun.bindgen.CallError(OrderSchema)!i32 {
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, arena.allocator());
    const allocator = stack_fallback.allocator();

    var left = try args.left.toUTF8(allocator);
    defer left.deinit();
    var right = try args.right.toUTF8(allocator);
    defer right.deinit();

    if (!strings.isAllASCII(left.slice())) return 0;
    if (!strings.isAllASCII(right.slice())) return 0;

    const left_result = Version.parse(SlicedString.init(left.slice(), left.slice()));
    const right_result = Version.parse(SlicedString.init(right.slice(), right.slice()));

    if (!left_result.valid) {
        return invalidSemver(context, left.slice());
    }

    if (!right_result.valid) {
        return invalidSemver(context, right.slice());
    }

    const left_version = left_result.version.max();
    const right_version = right_result.version.max();

    return switch (left_version.orderWithoutBuild(right_version, left.slice(), right.slice())) {
        .eq => 0,
        .gt => 1,
        .lt => -1,
    };
}

pub fn satisfies(
    context: bun.bindgen.CallContext(SatisfiesSchema),
    args: bun.bindgen.Args(SatisfiesSchema),
) bun.JSError!bool {
    _ = context;
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, arena.allocator());
    const allocator = stack_fallback.allocator();

    var left = try args.left.toUTF8(allocator);
    defer left.deinit();
    var right = try args.right.toUTF8(allocator);
    defer right.deinit();

    if (!strings.isAllASCII(left.slice())) return false;
    if (!strings.isAllASCII(right.slice())) return false;

    const left_result = Version.parse(SlicedString.init(left.slice(), left.slice()));
    if (left_result.wildcard != .none) {
        return false;
    }

    const left_version = left_result.version.min();

    const right_group = try Query.parse(
        allocator,
        right.slice(),
        SlicedString.init(right.slice(), right.slice()),
    );
    defer right_group.deinit();

    const right_version = right_group.getExactVersion();

    if (right_version != null) {
        return left_version.eql(right_version.?);
    }

    return right_group.satisfies(left_version, right.slice(), left.slice());
}

fn invalidSemver(context: bun.bindgen.CallContext(OrderSchema), input: []const u8) bun.bindgen.CallError(OrderSchema) {
    const message = try bun.String.createFormat("Invalid SemVer: {s}\n", .{input});
    return context.fail(.invalid_semver, try bun.bindgen.DOMString.fromBunString(message));
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;

const Query = bun.Semver.Query;
const SlicedString = bun.Semver.SlicedString;
const Version = bun.Semver.Version;
const SemverObjectBindings = bun.bindgen.Module("SemverObject");
const SatisfiesSchema = SemverObjectBindings.function("satisfies");
const OrderSchema = SemverObjectBindings.function("order");
const SatisfiesBinding = bun.bindgen.Fn(SatisfiesSchema, satisfies);
const OrderBinding = bun.bindgen.Fn(OrderSchema, order);

comptime {
    _ = SatisfiesBinding;
    _ = OrderBinding;
}
