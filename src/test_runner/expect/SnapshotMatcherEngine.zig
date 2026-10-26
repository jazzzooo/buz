const bun = @import("bun");
const Core = @import("./Matcher.zig");
const DiffFormatter = @import("../DiffFormatEngine.zig").DiffFormatter;
const Snapshot = @import("./Snapshot.zig");
const ThrownValueEngine = @import("./ThrownValueEngine.zig");
const capturedValue = @import("./MatcherEngine.zig").capturedValue;
const std = @import("std");

const bindgen = bun.bindgen;
const Expect = bun.jsc.Expect.Expect;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const JSValue = bindgen.EngineOperand;
const Jest = bun.jsc.Jest.Jest;

pub fn run(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    args: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    try rejectNegatedSnapshot(global, expect, @tagName(matcher));
    if (Jest.runner) |runner| runner.snapshots.total += 1;
    return switch (matcher) {
        .toMatchSnapshot => runExternal(global, context, expect, args),
        .toMatchInlineSnapshot => runInline(global, context, expect, args),
        .toThrowErrorMatchingSnapshot => runThrownExternal(global, context, expect, args),
        .toThrowErrorMatchingInlineSnapshot => runThrownInline(global, context, expect, args),
        else => @compileError("non-snapshot matcher passed to snapshot matcher engine"),
    };
}

fn runExternal(global: *JSGlobalObject, context: anytype, expect: *Expect, args: anytype) bun.JSError!void {
    try requireSnapshotContext(global, expect, "toMatchSnapshot", true);
    const value = try capturedValue(expect, context, "toMatchSnapshot", "<green>properties<r><d>, <r>hint");

    return switch (args) {
        .properties_hint => |values| result: {
            const hint = try values.hint.toUTF8(bun.default_allocator);
            defer hint.deinit();
            break :result try snapshot(expect, global, value, values.properties.operand(context).asEngine(), hint.slice(), "toMatchSnapshot");
        },
        .hint => |values| result: {
            const hint = try values.hint.toUTF8(bun.default_allocator);
            defer hint.deinit();
            break :result try snapshot(expect, global, value, null, hint.slice(), "toMatchSnapshot");
        },
        .properties => |values| try snapshot(expect, global, value, values.properties.operand(context).asEngine(), "", "toMatchSnapshot"),
        .empty => try snapshot(expect, global, value, null, "", "toMatchSnapshot"),
    };
}

fn runInline(global: *JSGlobalObject, context: anytype, expect: *Expect, args: anytype) bun.JSError!void {
    const value = try capturedValue(expect, context, "toMatchInlineSnapshot", "<green>properties<r><d>, <r>hint");
    const caller = context.callerSourceLocation();

    return switch (args) {
        .properties_snapshot => |values| result: {
            const snapshot_text = switch (values.snapshot) {
                .text => |text| try text.toUTF8(bun.default_allocator),
                .absent => null,
            };
            defer if (snapshot_text) |text| text.deinit();
            break :result try inlineSnapshot(expect, global, caller, value, values.properties.operand(context).asEngine(), if (snapshot_text) |text| text.slice() else null, "toMatchInlineSnapshot");
        },
        .snapshot => |values| result: {
            const snapshot_text = try values.snapshot.toUTF8(bun.default_allocator);
            defer snapshot_text.deinit();
            break :result try inlineSnapshot(expect, global, caller, value, null, snapshot_text.slice(), "toMatchInlineSnapshot");
        },
        .properties => |values| try inlineSnapshot(expect, global, caller, value, values.properties.operand(context).asEngine(), null, "toMatchInlineSnapshot"),
        .empty => try inlineSnapshot(expect, global, caller, value, null, null, "toMatchInlineSnapshot"),
    };
}

fn runThrownExternal(global: *JSGlobalObject, context: anytype, expect: *Expect, args: anytype) bun.JSError!void {
    try requireSnapshotContext(global, expect, "toThrowErrorMatchingSnapshot", true);
    const value = try thrownMessage(global, context, expect, "toThrowErrorMatchingSnapshot");

    return switch (args) {
        .snapshot => |values| result: {
            const hint = try values.snapshot.toUTF8(bun.default_allocator);
            defer hint.deinit();
            break :result try snapshot(expect, global, value, null, hint.slice(), "toThrowErrorMatchingSnapshot");
        },
        .empty => try snapshot(expect, global, value, null, "", "toThrowErrorMatchingSnapshot"),
    };
}

fn runThrownInline(global: *JSGlobalObject, context: anytype, expect: *Expect, args: anytype) bun.JSError!void {
    const value = try thrownMessage(global, context, expect, "toThrowErrorMatchingInlineSnapshot");
    const caller = context.callerSourceLocation();

    return switch (args) {
        .snapshot => |values| result: {
            const snapshot_text = try values.snapshot.toUTF8(bun.default_allocator);
            defer snapshot_text.deinit();
            break :result try inlineSnapshot(expect, global, caller, value, null, snapshot_text.slice(), "toThrowErrorMatchingInlineSnapshot");
        },
        .empty => try inlineSnapshot(expect, global, caller, value, null, null, "toThrowErrorMatchingInlineSnapshot"),
    };
}

fn requireSnapshotContext(global: *JSGlobalObject, expect: *Expect, comptime matcher: []const u8, comptime require_test: bool) bun.JSError!void {
    if (comptime require_test) {
        var active_test = expect.bunTest() orelse {
            const signature = comptime Expect.getSignature(matcher, "", true);
            return expect.throw(global, signature, "\n\n<b>Matcher error<r>: Snapshot matchers cannot be used outside of a test\n", .{});
        };
        active_test.deinit();
    }
}

fn rejectNegatedSnapshot(global: *JSGlobalObject, expect: *Expect, comptime matcher: []const u8) bun.JSError!void {
    if (!expect.flags.not) return;
    const signature = comptime Expect.getSignature(matcher, "", true);
    return expect.throw(global, signature, "\n\n<b>Matcher error<r>: Snapshot matchers cannot be used with <b>not<r>\n", .{});
}

fn thrownMessage(global: *JSGlobalObject, context: anytype, expect: *Expect, comptime matcher: []const u8) bun.JSError!JSValue {
    const received_result = try expect.getScopedValue(context, matcher, "<green>properties<r><d>, <r>hint");
    const message = (try ThrownValueEngine.messageOrUndefined(context, try received_result.view(context), expect.flags.promise != .none)) orelse {
        const signature = comptime Expect.getSignature(matcher, "", false);
        return expect.throw(global, signature, "\n\n<b>Matcher error<r>: Received function did not throw\n", .{});
    };
    return message.operand(context).asEngine();
}

fn inlineSnapshot(
    expect: *Expect,
    global: *JSGlobalObject,
    caller: bindgen.CallerSourceLocationView,
    value: JSValue,
    property_matchers: ?JSValue,
    saved: ?[]const u8,
    comptime matcher: []const u8,
) bun.JSError!void {
    const runner = Jest.runner orelse {
        const signature = comptime Expect.getSignature(matcher, "", false);
        return expect.throw(global, signature, "\n\n<b>Matcher error<r>: Snapshot matchers cannot be used outside of a test\n", .{});
    };
    if (expect.getSnapshotName(runner.snapshots.allocator, "")) |snapshot_name| {
        defer runner.snapshots.allocator.free(snapshot_name);
        _ = runner.snapshots.nextSnapshotIndex(snapshot_name) catch return error.OutOfMemory;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoTest, error.SnapshotInConcurrentGroup, error.TestNotActive => {},
    }

    const update = runner.snapshots.update_snapshots;
    var needs_write = false;
    var pretty_value = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer pretty_value.deinit();
    try matchAndFormat(expect, global, value, property_matchers, &pretty_value.writer, matcher);

    var start_indent: ?[]const u8 = null;
    var end_indent: ?[]const u8 = null;
    if (saved) |saved_value| {
        const buffer = try runner.snapshots.allocator.alloc(u8, saved_value.len);
        defer runner.snapshots.allocator.free(buffer);
        const trimmed = Snapshot.trimLeadingWhitespaceForInlineSnapshot(saved_value, buffer);

        if (bun.strings.eqlLong(pretty_value.written(), trimmed.trimmed, true)) {
            runner.snapshots.passed += 1;
            return;
        }
        if (update) {
            runner.snapshots.passed += 1;
            needs_write = true;
            start_indent = trimmed.start_indent;
            end_indent = trimmed.end_indent;
        } else {
            runner.snapshots.failed += 1;
            const signature = comptime Expect.getSignature(matcher, "<green>expected<r>", false);
            const diff = DiffFormatter{
                .received_string = pretty_value.written(),
                .expected_string = trimmed.trimmed,
                .globalThis = global,
            };
            return global.throwPretty(signature ++ "\n\n{f}\n", .{diff});
        }
    } else {
        needs_write = true;
    }

    if (!needs_write) return;
    if (bun.ci.isCI(runner.snapshots.io) and !update) {
        const signature = comptime Expect.getSignature(matcher, "", false);
        return expect.throw(global, signature, "\n\n<b>Matcher error<r>: Inline snapshot creation is disabled in CI environments unless --update-snapshots is used.\nTo override, set the environment variable CI=false.\n\nReceived: {s}", .{pretty_value.written()});
    }

    var active_test = expect.bunTest() orelse {
        const signature = comptime Expect.getSignature(matcher, "", false);
        return expect.throw(global, signature, "\n\n<b>Matcher error<r>: Snapshot matchers cannot be used outside of a test\n", .{});
    };
    defer active_test.deinit();
    const test_state = active_test.get();

    var source_location = try caller.sourceLocation();
    defer source_location.deinit();
    var source_url = try source_location.source_url.toUTF8(runner.snapshots.allocator);
    defer source_url.deinit();
    const file_id = test_state.file_id;
    const file = runner.files.get(file_id);

    if (!bun.strings.eql(source_url.slice(), file.source.path.text)) {
        const signature = comptime Expect.getSignature(matcher, "", false);
        return expect.throw(global, signature,
            \\
            \\
            \\<b>Matcher error<r>: Inline snapshot matchers must be called from the test file:
            \\  Expected to be called from file: <green>"{f}"<r>
            \\  {s} called from file: <red>"{f}"<r>
            \\
        , .{
            std.zig.fmtString(file.source.path.text),
            matcher,
            std.zig.fmtString(source_url.slice()),
        });
    }

    try runner.snapshots.addInlineSnapshotToWrite(file_id, .{
        .line = source_location.line,
        .col = source_location.column,
        .value = try pretty_value.toOwnedSlice(),
        .has_matchers = property_matchers != null,
        .is_added = saved == null,
        .kind = matcher,
        .start_indent = if (start_indent) |indent| try runner.snapshots.allocator.dupe(u8, indent) else null,
        .end_indent = if (end_indent) |indent| try runner.snapshots.allocator.dupe(u8, indent) else null,
    });
    return;
}

fn matchAndFormat(
    expect: *Expect,
    global: *JSGlobalObject,
    value: JSValue,
    property_matchers: ?JSValue,
    pretty_value: *std.Io.Writer,
    comptime matcher: []const u8,
) bun.JSError!void {
    if (property_matchers) |matchers| {
        if (!value.isObject()) {
            const signature = comptime Expect.getSignature(matcher, "<green>properties<r><d>, <r>hint", false);
            return expect.throw(global, signature, "\n\n<b>Matcher error: <red>received<r> values must be an object when the matcher has <green>properties<r>\n", .{});
        }
        if (!try value.jestDeepMatch(matchers, true)) {
            const signature = comptime Expect.getSignature(matcher, "<green>propertyMatchers<r>", false);
            var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global };
            defer formatter.deinit();
            return global.throwPretty(signature ++ "\n\nExpected <green>propertyMatchers<r> to match properties from received object\n\nReceived: {f}\n", .{value.toFmt(&formatter)});
        }
    }

    value.jestSnapshotPrettyFormat(pretty_value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |js_error| return js_error,
    };
}

fn snapshot(
    expect: *Expect,
    global: *JSGlobalObject,
    value: JSValue,
    property_matchers: ?JSValue,
    hint: []const u8,
    comptime matcher: []const u8,
) bun.JSError!void {
    var pretty_value = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer pretty_value.deinit();
    try matchAndFormat(expect, global, value, property_matchers, &pretty_value.writer, matcher);

    const runner = Jest.runner.?;
    var active_test = expect.bunTest() orelse return global.throw("Snapshot matchers cannot be used outside of a test", .{});
    defer active_test.deinit();
    const test_state = active_test.get();
    const test_file_path = runner.files.get(test_state.file_id).source.path.text;
    const snapshot_name = expect.getSnapshotName(runner.snapshots.allocator, hint) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoTest => global.throw("Snapshot matchers cannot be used outside of a test", .{}),
        error.SnapshotInConcurrentGroup => global.throw("Snapshot matchers are not supported in concurrent tests", .{}),
        error.TestNotActive => global.throw("Snapshot matchers are not supported after the test has finished executing", .{}),
    };
    defer runner.snapshots.allocator.free(snapshot_name);

    const existing = runner.snapshots.getOrPut(test_state.file_id, snapshot_name, pretty_value.written()) catch |err| return switch (err) {
        error.FailedToOpenSnapshotFile => global.throw("Failed to open snapshot file for test file: {s}", .{test_file_path}),
        error.FailedToMakeSnapshotDirectory => global.throw("Failed to make snapshot directory for test file: {s}", .{test_file_path}),
        error.FailedToWriteSnapshotFile => global.throw("Failed write to snapshot file: {s}", .{test_file_path}),
        error.SyntaxError, error.ParseError => global.throw("Failed to parse snapshot file for: {s}", .{test_file_path}),
        error.SnapshotCreationNotAllowedInCI => creation_error: {
            const rejected_name = runner.snapshots.last_error_snapshot_name;
            defer if (rejected_name) |name| {
                runner.snapshots.allocator.free(name);
                runner.snapshots.last_error_snapshot_name = null;
            };
            if (rejected_name) |name| {
                break :creation_error global.throw("Snapshot creation is disabled in CI environments unless --update-snapshots is used\nTo override, set the environment variable CI=false.\n\nSnapshot name: \"{s}\"\nReceived: {s}", .{ name, pretty_value.written() });
            }
            break :creation_error global.throw("Snapshot creation is disabled in CI environments unless --update-snapshots is used\nTo override, set the environment variable CI=false.\n\nReceived: {s}", .{pretty_value.written()});
        },
        else => failure: {
            var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global };
            defer formatter.deinit();
            break :failure global.throw("Failed to snapshot value: {f}", .{value.toFmt(&formatter)});
        },
    };

    if (existing) |saved_value| {
        if (bun.strings.eqlLong(pretty_value.written(), saved_value, true)) {
            runner.snapshots.passed += 1;
            return;
        }

        runner.snapshots.failed += 1;
        const signature = comptime Expect.getSignature(matcher, "<green>expected<r>", false);
        const diff = DiffFormatter{
            .received_string = pretty_value.written(),
            .expected_string = saved_value,
            .globalThis = global,
        };
        return global.throwPretty(signature ++ "\n\n{f}\n", .{diff});
    }

    return;
}
