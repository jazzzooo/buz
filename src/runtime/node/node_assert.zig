/// Compare `actual` and `expected`, producing a diff that would turn `actual`
/// into `expected`.
///
/// Lines in the returned diff have the same encoding as `actual` and
/// `expected`. Lines borrow from these inputs, but the diff list itself must
/// be deallocated.
///
/// Use an arena allocator, otherwise this will leak memory.
///
/// ## Invariants
/// If not met, this function will panic.
/// - `actual` and `expected` are alive and have the same encoding.
pub fn myersDiff(
    allocator: Allocator,
    context: anytype,
    actual: *const BunString,
    expected: *const BunString,
    // If true, strings that have a trailing comma but are otherwise equal are
    // considered equal.
    check_comma_disparity: bool,
    // split `actual` and `expected` into lines before diffing
    lines: bool,
) bun.bindgen.CallError(@TypeOf(context))!MyersDiffReturn {
    // Short circuit on empty strings. Note that, in release builds where
    // assertions are disabled, if `actual` and `expected` are both dead, this
    // branch will be hit since dead strings have a length of 0. This should be
    // moot since BunStrings with non-zero reference counds should never be
    // dead.
    if (actual.length() == 0 and expected.length() == 0) {
        return MyersDiffReturn.fromOwnedSlice(&.{});
    }

    const actual_encoding = actual.encoding();
    const expected_encoding = expected.encoding();

    if (lines) {
        if (actual_encoding != expected_encoding) {
            const actual_utf8 = try actual.toUTF8WithoutRef(allocator);
            defer actual_utf8.deinit();
            const expected_utf8 = try expected.toUTF8WithoutRef(allocator);
            defer expected_utf8.deinit();

            return diffLines(u8, allocator, context, actual_utf8.byteSlice(), expected_utf8.byteSlice(), check_comma_disparity);
        }

        return switch (actual_encoding) {
            .latin1, .utf8 => diffLines(u8, allocator, context, actual.byteSlice(), expected.byteSlice(), check_comma_disparity),
            .utf16 => diffLines(u16, allocator, context, actual.utf16(), expected.utf16(), check_comma_disparity),
        };
    }

    if (actual_encoding != expected_encoding) {
        const actual_utf8 = try actual.toUTF8WithoutRef(allocator);
        defer actual_utf8.deinit();
        const expected_utf8 = try expected.toUTF8WithoutRef(allocator);
        defer expected_utf8.deinit();

        return diffChars(u8, allocator, context, actual_utf8.byteSlice(), expected_utf8.byteSlice());
    }

    return switch (actual_encoding) {
        .latin1, .utf8 => diffChars(u8, allocator, context, actual.byteSlice(), expected.byteSlice()),
        .utf16 => diffChars(u16, allocator, context, actual.utf16(), expected.utf16()),
    };
}

fn diffChars(
    comptime T: type,
    allocator: Allocator,
    context: anytype,
    actual: []const T,
    expected: []const T,
) bun.bindgen.CallError(@TypeOf(context))!MyersDiffReturn {
    const Differ = MyersDiff.Differ(T, .{ .check_comma_disparity = false });
    const diff: MyersDiff.DiffList(T) = Differ.diff(allocator, actual, expected) catch |err| return mapDiffError(context, err);
    return diffListToResult(T, diff);
}

fn diffLines(
    comptime T: type,
    allocator: Allocator,
    context: anytype,
    actual: []const T,
    expected: []const T,
    check_comma_disparity: bool,
) bun.bindgen.CallError(@TypeOf(context))!MyersDiffReturn {
    var a = try MyersDiff.split(T, allocator, actual);
    defer a.deinit(allocator);
    var e = try MyersDiff.split(T, allocator, expected);
    defer e.deinit(allocator);

    const diff: MyersDiff.DiffList([]const T) = blk: {
        if (check_comma_disparity) {
            const Differ = MyersDiff.Differ([]const T, .{ .check_comma_disparity = true });
            break :blk Differ.diff(allocator, a.items, e.items) catch |err| return mapDiffError(context, err);
        } else {
            const Differ = MyersDiff.Differ([]const T, .{ .check_comma_disparity = false });
            break :blk Differ.diff(allocator, a.items, e.items) catch |err| return mapDiffError(context, err);
        }
    };
    return diffListToResult([]const T, diff);
}

fn diffListToResult(comptime T: type, diff_list: MyersDiff.DiffList(T)) bun.OOM!MyersDiffReturn {
    var entries = try MyersDiffReturn.Builder.init(diff_list.items.len);
    errdefer entries.deinit();

    for (diff_list.items) |line| {
        const value: DiffValue = if (comptime T == u8 or T == u16)
            .{ .code_unit = @intCast(line.value) }
        else if (comptime T == []const u8)
            .{ .text = try bun.bindgen.DOMString.fromUTF8(line.value) }
        else if (comptime T == []const u16)
            .{ .text = try bun.bindgen.DOMString.fromUTF16(line.value) }
        else
            @compileError("unsupported Myers diff result element type");
        entries.appendOwned(.{
            .kind = @backingInt(line.kind),
            .value = value,
        });
    }
    return entries.finish();
}

fn mapDiffError(context: anytype, err: MyersDiff.Error) bun.bindgen.CallError(@TypeOf(context)) {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DiffTooLarge => context.fail(.diff_too_large, {}),
        error.InputsTooLarge => context.fail(.inputs_too_large, {}),
    };
}

const MyersDiff = @import("./assert/myers_diff.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const BunString = bun.String;
const NodeAssertBindings = bun.bindgen.Module("node_assert_binding");
const MyersDiffSchema = NodeAssertBindings.function("myersDiff");
const MyersDiffReturn = bun.bindgen.Return(MyersDiffSchema);
const DiffEntry = bun.bindgen.ResultType(MyersDiffSchema.ReturnType.child);
const DiffValue = @FieldType(DiffEntry, "value");
