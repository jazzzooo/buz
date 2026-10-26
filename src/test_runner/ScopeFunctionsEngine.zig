pub fn deriveOnly(
    context: bindgen.CallContext(DeriveOnlySchema),
    args: bindgen.Args(DeriveOnlySchema),
) bindgen.CallError(DeriveOnlySchema)!bindgen.Return(DeriveOnlySchema) {
    if (bun.ci.isCI(jsc.VirtualMachine.get().io)) return context.fail(.only_in_ci, {});
    return ScopeFunctions.extendScope(args.state.get(ScopeFunctions), context, .{ .self_only = true }, "get .only");
}

pub fn call(
    context: bindgen.CallContext(ScopeFunctionsCallSchema),
    args: bindgen.Args(ScopeFunctionsCallSchema),
) bindgen.CallError(ScopeFunctionsCallSchema)!void {
    const global = context.viewToken().globalObject();
    var engine = Engine{ .globalThis = global };
    return callFromBinding(context, args, &engine);
}

const DeclarationArguments = struct {
    description: ?bindgen.DOMStringView = null,
    callback: ?bun_test.StoredTestCallback = null,
    callback_length: usize = 0,
    timeout: ?f64 = null,
    options: ParseArgumentsOptions = .{},

    fn setDescription(this: *@This(), context: anytype, state: *const ScopeFunctions, description: anytype) bindgen.CallError(@TypeOf(context))!void {
        switch (description) {
            .value => |value| if (value) |text| {
                this.description = text;
                return;
            },
            .null, .undefined => return,
            .invalid => {},
        }
        const message = try std.fmt.allocPrint(bun.default_allocator, "{f}() expects first argument to be a named class, named function, number, or string", .{state.*});
        defer bun.default_allocator.free(message);
        return context.fail(.invalid_description, try bindgen.DOMString.fromUTF8(message));
    }

    fn setCallback(this: *@This(), context: anytype, callback: bindgen.CallbackView(bun_test.TestCallbackSchema)) bun.JSError!void {
        var owned = try bun_test.StoredTestCallback.fromArgument(callback);
        errdefer owned.deinit();
        this.callback_length = try bun_test.callbackLength(context, callback);
        this.callback = owned.take();
    }

    fn setOptions(this: *@This(), input: anytype) void {
        switch (input orelse return) {
            .milliseconds => |milliseconds| this.timeout = milliseconds,
            .options => |options| {
                this.timeout = options.timeout;
                this.options.retry = options.retry;
                this.options.repeats = options.repeats;
            },
        }
    }

    fn init(context: anytype, state: *const ScopeFunctions, args: anytype) bindgen.CallError(@TypeOf(context))!@This() {
        var result: @This() = .{};
        errdefer result.deinit();
        switch (args) {
            .description_callback_options => |values| {
                try result.setDescription(context, state, values.description);
                try result.setCallback(context, values.callback);
                result.setOptions(values.options);
            },
            .description_options_callback => |values| {
                try result.setDescription(context, state, values.description);
                try result.setCallback(context, values.callback);
                result.setOptions(values.options);
            },
            .description_callback => |values| {
                try result.setDescription(context, state, values.description);
                try result.setCallback(context, values.callback);
            },
            .callback_options => |values| {
                try result.setCallback(context, values.callback);
                result.setOptions(values.options);
            },
            .callback => |values| try result.setCallback(context, values.callback),
            .description => |values| try result.setDescription(context, state, values.description),
            .empty => {},
        }
        return result;
    }

    fn deinit(this: *@This()) void {
        if (this.callback) |*callback| callback.deinit();
        this.callback = null;
    }
};

fn callFromBinding(
    context: anytype,
    binding_args: bindgen.Args(ScopeFunctionsCallSchema),
    engine: *const Engine,
) bindgen.CallError(@TypeOf(context))!void {
    const globalThis = context.viewToken().globalObject();
    groupLog.begin(@src());
    defer groupLog.end();

    const state = switch (binding_args) {
        inline else => |values| values.bindingThis.get(ScopeFunctions),
    };
    const caller_source_location = context.callerSourceLocation();
    const line_no = try jsc.Jest.captureTestLineNumber(caller_source_location);

    var buntest_strong = try bun_test.js_fns.cloneActiveStrong(globalThis, .{
        .signature = .{ .scope_functions = state },
        .allow_in_preload = false,
    });
    defer buntest_strong.deinit();
    const bunTest = buntest_strong.get();

    const callback_mode: CallbackMode = switch (state.cfg.self_mode) {
        .skip, .todo => .allow,
        else => .require,
    };

    var args = try DeclarationArguments.init(context, state, binding_args);
    defer args.deinit();
    if (callback_mode == .require and args.callback == null) {
        const message = try std.fmt.allocPrint(bun.default_allocator, "{f} expects a function as the second argument", .{state.*});
        defer bun.default_allocator.free(message);
        return context.fail(.callback_required, try bindgen.DOMString.fromUTF8(message));
    }
    if (args.options.retry == null) {
        if (bun.jsc.Jest.Jest.runner) |runner| {
            args.options.retry = runner.test_options.retry;
        }
    }
    if ((args.options.retry orelse 0) != 0 and args.options.repeats != 0) {
        return context.fail(.retry_repeats, {});
    }
    args.options.timeout = resolveTimeout(args.timeout);

    const description: ?[]const u8 = if (args.description) |description| blk: {
        var utf8 = try description.toUTF8(bunTest.gpa);
        break :blk try utf8.intoOwnedSlice(bunTest.gpa);
    } else null;
    defer if (description) |value| bunTest.gpa.free(value);

    if (state.each) |*each| {
        var rows = try engine.collectEachRows(each, bunTest.gpa);
        defer rows.deinit();
        for (rows.rows, 0..) |*row, test_idx| {
            const argument_count = row.arguments.values().len;
            const formatted_label: ?[]const u8 = if (description) |label|
                try engine.formatEachLabel(label, &row.arguments, test_idx, bunTest.gpa)
            else
                null;
            defer if (formatted_label) |label| bunTest.gpa.free(label);

            var bound: ?bun_test.StoredTestCallback = if (args.callback) |*callback| blk: {
                var owned_arguments = row.takeArguments();
                break :blk callback.cloneWithBinding(
                    &row.receiver,
                    &owned_arguments,
                );
            } else null;
            defer if (bound) |*callback| callback.deinit();
            try enqueueDescribeOrTestCallback(
                state,
                bunTest,
                globalThis,
                caller_source_location,
                if (bound) |*callback| callback else null,
                formatted_label,
                args.options,
                args.callback_length -| argument_count,
                line_no,
            );
        }
    } else {
        try enqueueDescribeOrTestCallback(
            state,
            bunTest,
            globalThis,
            caller_source_location,
            if (args.callback) |*callback| callback else null,
            description,
            args.options,
            args.callback_length,
            line_no,
        );
    }
}

const Measure = struct {
    len: usize,

    fn writeEnd(this: *Measure, write: []const u8) void {
        this.len += write.len;
    }
};

const Write = struct {
    buf: []u8,

    fn writeEnd(this: *Write, write: []const u8) void {
        if (this.buf.len < write.len) {
            bun.debugAssert(false);
            return;
        }
        @memcpy(this.buf[this.buf.len - write.len ..], write);
        this.buf = this.buf[0 .. this.buf.len - write.len];
    }
};

fn filterNames(comptime Rem: type, rem: *Rem, description: ?[]const u8, parent_in: ?*bun_test.DescribeScope) void {
    rem.writeEnd(description orelse "");
    var parent = parent_in;
    while (parent) |scope| : (parent = scope.base.parent) {
        if (scope.base.name == null) continue;
        rem.writeEnd(" ");
        rem.writeEnd(scope.base.name.?);
    }
}

fn enqueueDescribeOrTestCallback(
    state: *ScopeFunctions,
    bunTest: *bun_test.BunTest,
    globalThis: *jsc.JSGlobalObject,
    caller_source_location: bindgen.CallerSourceLocationView,
    callback: ?*bun_test.StoredTestCallback,
    description: ?[]const u8,
    options: ParseArgumentsOptions,
    callback_length: usize,
    line_no: u32,
) bun.JSError!void {
    groupLog.begin(@src());
    defer groupLog.end();

    switch (bunTest.phase) {
        .collection => {},
        .execution => return globalThis.throw("Cannot call {f}() inside a test. Call it inside describe() instead.", .{state}),
        .done => return globalThis.throw("Cannot call {f}() after the test run has completed", .{state}),
    }

    var test_id_for_debugger: i32 = 0;
    if (globalThis.bunVM().debugger) |*debugger| {
        if (debugger.test_reporter_agent.isEnabled()) {
            const counter = struct {
                var next: i32 = 0;
            };
            counter.next += 1;
            var name = bun.String.cloneUTF8(description orelse "(unnamed)");
            defer name.deref();
            const parent = bunTest.collection.active_scope;
            const parent_id = if (parent.base.test_id_for_debugger != 0) parent.base.test_id_for_debugger else -1;
            debugger.test_reporter_agent.reportTestFound(
                caller_source_location,
                counter.next,
                &name,
                switch (state.mode) {
                    .describe => .describe,
                    .@"test" => .@"test",
                },
                parent_id,
            );
            test_id_for_debugger = counter.next;
        }
    }

    var base = state.cfg;
    base.line_no = line_no;
    base.test_id_for_debugger = test_id_for_debugger;
    if (bunTest.default_concurrent or (bun.jsc.Jest.Jest.runner != null and bun.jsc.Jest.Jest.runner.?.concurrent)) {
        if (base.self_concurrent == .inherit) base.self_concurrent = .yes;
    }

    switch (state.mode) {
        .describe => {
            const new_scope = try bunTest.collection.active_scope.appendDescribe(bunTest.gpa, description, base);
            try bunTest.collection.enqueueDescribeCallback(new_scope, callback);
        },
        .@"test" => {
            var matches_filter = true;
            if (bunTest.reporter) |reporter| if (reporter.jest.filter_regex) |filter_regex| {
                groupLog.log("matches_filter begin", .{});
                bun.assert(bunTest.collection.filter_buffer.items.len == 0);
                defer bunTest.collection.filter_buffer.clearRetainingCapacity();

                var len: Measure = .{ .len = 0 };
                filterNames(Measure, &len, description, bunTest.collection.active_scope);
                const slice = try bunTest.collection.filter_buffer.addManyAsSlice(len.len);
                var rem: Write = .{ .buf = slice };
                filterNames(Write, &rem, description, bunTest.collection.active_scope);
                bun.debugAssert(rem.buf.len == 0);

                const name = bun.String.cloneUTF8(bunTest.collection.filter_buffer.items);
                defer name.deref();
                groupLog.log("matches_filter \"{f}\"", .{std.zig.fmtString(bunTest.collection.filter_buffer.items)});
                matches_filter = filter_regex.matches(name);
            };

            if (!matches_filter) base.self_mode = .filtered_out;

            bun.assert(!bunTest.collection.locked);
            groupLog.log("enqueueTestCallback / {s} / in scope: {s}", .{
                description orelse "(unnamed)",
                bunTest.collection.active_scope.base.name orelse "(unnamed)",
            });

            _ = try bunTest.collection.active_scope.appendTest(
                bunTest.gpa,
                description,
                if (matches_filter) callback else null,
                .{
                    .has_done_parameter = callback != null and callback_length >= 1,
                    .timeout = options.timeout,
                    .retry_count = options.retry orelse 0,
                    .repeat_count = options.repeats,
                },
                base,
                .collection,
            );
        },
    }
}

pub fn resolveTimeout(timeout_option: ?f64) u32 {
    const runner = bun.jsc.Jest.Jest.runner orelse return if (timeout_option) |timeout| std.math.lossyCast(u32, timeout) else 0;
    const default_timeout_ms: ?u32 = if (runner.default_timeout_ms != 0) runner.default_timeout_ms else null;
    const override_timeout_ms: ?u32 = if (runner.default_timeout_override != std.math.maxInt(u32)) runner.default_timeout_override else null;
    const timeout_option_ms: ?u32 = if (timeout_option) |timeout| std.math.lossyCast(u32, timeout) else null;
    return timeout_option_ms orelse override_timeout_ms orelse default_timeout_ms orelse 0;
}

const Engine = struct {
    globalThis: *jsc.JSGlobalObject,

    fn collectEachRows(engine: *const Engine, each: *const EachArray, allocator: std.mem.Allocator) bun.JSError!TestEachRows {
        var rows: std.array_list.Managed(TestEachRow) = .init(allocator);
        errdefer {
            for (rows.items) |*row| row.deinit();
            rows.deinit();
        }
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(engine.globalThis);
        defer scope.deinit();
        const array = try each.view(&scope);
        const length = try scope.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = array.operand(&scope).asEngine() });
        for (0..length) |index| {
            const item = try scope.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = array.operand(&scope).asEngine(), .index = index });
            var row = try collectEachRow(&scope, item, allocator);
            rows.append(row) catch |err| {
                row.deinit();
                return err;
            };
        }
        const owned_rows = try rows.toOwnedSlice();
        return .{
            .rows = owned_rows,
            .allocator = if (owned_rows.len > 0) allocator else null,
        };
    }

    fn formatEachLabel(
        engine: *const Engine,
        label: []const u8,
        arguments: *const bindgen.RetainedArguments,
        test_index: usize,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        return jsc.Jest.formatLabel(engine.globalThis, label, arguments.values(), test_index, allocator);
    }
};

const TestEachRow = struct {
    receiver: bindgen.Root,
    arguments: bindgen.RetainedArguments,

    fn takeArguments(row: *TestEachRow) bindgen.RetainedArguments {
        return row.arguments.take();
    }

    fn deinit(row: *TestEachRow) void {
        row.receiver.deinit();
        row.arguments.deinit();
    }
};

const TestEachRows = struct {
    rows: []TestEachRow,
    allocator: ?std.mem.Allocator,

    fn deinit(result: *TestEachRows) void {
        for (result.rows) |*row| row.deinit();
        if (result.allocator) |allocator| allocator.free(result.rows);
        result.rows = &.{};
        result.allocator = null;
    }
};

fn collectEachRow(scope: *bindgen.FocusedEngineScope, item: bindgen.EngineValueResult, allocator: std.mem.Allocator) bun.JSError!TestEachRow {
    var receiver_value = item.asAny(scope);
    defer receiver_value.deinit();
    var receiver = try receiver_value.toRoot();
    errdefer receiver.deinit();
    const array = scope.engineIn("js_arrays", "tryCastArrayValue").call(.{ .value = item.operand(scope).asEngine() });
    const length = if (array) |value|
        try scope.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = value.operand(scope).asEngine() })
    else
        1;
    var builder = try bindgen.RetainedArguments.Builder.init(allocator, length);
    defer builder.deinit();
    if (array) |value| {
        for (0..length) |index| {
            const argument = try scope.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = value.operand(scope).asEngine(), .index = index });
            var argument_value = argument.asAny(scope);
            defer argument_value.deinit();
            builder.appendOwned(try argument_value.toRoot());
        }
    } else builder.appendOwned(receiver.clone());
    return .{ .receiver = receiver, .arguments = builder.finish() };
}

const ParseArgumentsOptions = struct {
    timeout: u32 = 0,
    retry: ?u32 = null,
    repeats: u32 = 0,
};

const CallbackMode = enum { require, allow };

const bun = @import("bun");
const std = @import("std");
const bindgen = bun.bindgen;
const jsc = bun.jsc;
const bun_test = jsc.Jest.bun_test;
const ScopeFunctions = bun_test.ScopeFunctions;
const EachArray = ScopeFunctions.EachArray;
const groupLog = bun_test.debug.group;
const BindingModule = bindgen.Module("ScopeFunctions");
const DeriveOnlySchema = BindingModule.function("deriveOnly");
const ScopeFunctionsCallSchema = BindingModule.function("call");
