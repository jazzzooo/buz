const BindingEscape = bun.bindgen.Escape(@This());
const ReplEngine = @This();

vm: *jsc.VirtualMachine,

pub const Completions = bindgen.Return(GetCompletionsSchema);
pub const Settlement = enum { fulfilled, rejected, pending, interrupted };

pub const Evaluation = struct {
    result: bindgen.EngineRoot,
    exception: ?bindgen.EngineRoot,

    pub fn deinit(this: *Evaluation) void {
        this.result.deinit();
        if (this.exception) |*exception| exception.deinit();
        this.exception = null;
    }
};

pub const Interrupt = struct {
    received: std.atomic.Value(bool) = .init(false),
    event_loop: std.atomic.Value(?*jsc.EventLoop) = .init(null),

    pub fn arm(this: *Interrupt, engine: ?ReplEngine) void {
        this.received.store(false, .release);
        this.event_loop.store(if (engine) |active| active.vm.eventLoop() else null, .release);
    }

    pub fn disarm(this: *Interrupt) void {
        this.event_loop.store(null, .release);
    }

    pub fn signal(this: *Interrupt) void {
        this.received.store(true, .release);
        if (this.event_loop.load(.acquire)) |event_loop| event_loop.wakeup();
    }
};

pub fn init(vm: *jsc.VirtualMachine) ReplEngine {
    return .{ .vm = vm };
}

pub fn transpiler(this: ReplEngine) *bun.Transpiler {
    return &this.vm.transpiler;
}

pub fn tick(this: ReplEngine) void {
    this.vm.tick();
}

pub fn drain(this: ReplEngine) void {
    this.vm.tick();
    while (this.vm.isEventLoopAlive()) {
        this.vm.tick();
        this.vm.eventLoop().autoTickActive();
    }
}

pub fn evaluate(this: ReplEngine, source: []const u8, filename: []const u8) bun.JSError!Evaluation {
    var bound_source = try bindgen.DOMString.fromUTF8(source);
    defer bound_source.deinit();
    var bound_filename = try bindgen.DOMString.fromUTF8(filename);
    defer bound_filename.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    var result = try scope.engine(EvaluateSchema).call(.{
        .source = bound_source.operand(),
        .filename = bound_filename.operand(),
    });
    defer bindgen.deinitReturn(EvaluateSchema, &result);
    var retained_result = try result.result.toRoot();
    errdefer retained_result.deinit();
    return .{
        .result = retained_result,
        .exception = if (result.exception) |exception| try exception.toRoot() else null,
    };
}

pub fn needsAwait(this: ReplEngine, evaluation: *const Evaluation) bun.JSError!bool {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    return (try scope.engineIn("promises", "jsValueAsPromise").call(.{ .value = evaluation.result.operand(&scope).asEngine() })) != null;
}

pub fn settle(this: ReplEngine, evaluation: *Evaluation, interrupt: ?*Interrupt) bun.JSError!Settlement {
    if (evaluation.exception != null) return .rejected;
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    const promise_result = (try scope.engineIn("promises", "jsValueAsPromise").call(.{ .value = evaluation.result.operand(&scope).asEngine() })) orelse return .fulfilled;
    const settlement = (try scope.waitForPromiseResult(
        promise_result.operand(&scope).asPromise(),
        if (interrupt) |cancellation| &cancellation.received else null,
    )) orelse {
        _ = interrupt.?.received.swap(false, .acq_rel);
        return .interrupted;
    };
    switch (settlement) {
        .fulfilled => |value| {
            const result = try value.toRoot();
            evaluation.result.deinit();
            evaluation.result = result;
            return .fulfilled;
        },
        .rejected => |reason| {
            evaluation.exception = try reason.toRoot();
            return .rejected;
        },
    }
}

pub fn unwrap(this: ReplEngine, evaluation: *Evaluation) bun.JSError!void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    const result = evaluation.result.operand(&scope);
    if (!result.isObject()) return;
    const value = (try result.getOwn("value")) orelse return;
    const retained = try value.toRoot();
    evaluation.result.deinit();
    evaluation.result = retained;
}

pub fn isUndefined(this: ReplEngine, value: *const bindgen.EngineRoot) bool {
    return BindingEscape.rootValue(this.vm.global, value).isUndefined();
}

pub fn setLastResult(this: ReplEngine, value: *const bindgen.EngineRoot) bun.JSError!void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    try scope.engine(SetLastResultSchema).call(.{ .value = value.operand(&scope) });
}

pub fn setLastError(this: ReplEngine, value: *const bindgen.EngineRoot) bun.JSError!void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    try scope.engine(SetLastErrorSchema).call(.{ .value = value.operand(&scope) });
}

pub fn takeException(this: ReplEngine, failure: bun.JSError) bun.JSError!bindgen.EngineRoot {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    const value = try scope.takeThrownException(failure);
    return value.toRoot();
}

pub fn formatValue(this: ReplEngine, value: *const bindgen.EngineRoot, writer: *std.Io.Writer, colors: bool) jsc.ConsoleObject.FormatError!void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    try jsc.ConsoleObject.formatScopedValue(&scope, value.operand(&scope).engineView(), .Log, writer, .{
        .enable_colors = colors,
        .add_newline = true,
        .flush = false,
        .quote_strings = true,
        .ordered_properties = false,
        .max_depth = 4,
    });
}

pub fn formatError(this: ReplEngine, value: *const bindgen.EngineRoot, writer: *std.Io.Writer, colors: bool) void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    formatErrorValue(&scope, value.operand(&scope).engineView(), writer, colors);
}

pub fn reportException(this: ReplEngine, failure: bun.JSError, writer: *std.Io.Writer, colors: bool) void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    const value = scope.takeThrownException(failure) catch return;
    formatErrorValue(&scope, value.operand(&scope).engineView(), writer, colors);
}

fn formatErrorValue(scope: *bindgen.FocusedEngineScope, value: bindgen.EngineValueView, writer: *std.Io.Writer, colors: bool) void {
    jsc.ConsoleObject.formatScopedValue(scope, value, .Error, writer, .{
        .enable_colors = colors,
        .add_newline = true,
        .flush = false,
        .quote_strings = true,
        .ordered_properties = false,
        .max_depth = 4,
    }) catch |failure| {
        const js_error = switch (failure) {
            error.WriteFailed => return,
            else => |err| err,
        };
        _ = scope.takeThrownException(js_error) catch return;
        writer.writeAll("error: [failed to format error]\n") catch {};
    };
}

pub fn clipboardText(this: ReplEngine, value: ?*const bindgen.EngineRoot, allocator: std.mem.Allocator) bun.JSError![]u8 {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    const raw = if (value) |root| root.operand(&scope) else BindingEscape.borrowEngineValue(&scope, .js_undefined);
    if (raw.isUndefined()) return allocator.dupe(u8, "undefined");
    if (raw.isNull()) return allocator.dupe(u8, "null");
    if (raw.isString()) {
        const string = try raw.toSlice(allocator);
        defer string.deinit();
        return allocator.dupe(u8, string.slice());
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    jsc.ConsoleObject.format2(.Log, this.vm.global, @ptrCast(&raw), 1, &output.writer, .{
        .enable_colors = false,
        .add_newline = false,
        .flush = false,
        .quote_strings = true,
        .ordered_properties = false,
        .max_depth = 4,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |js_error| return js_error,
    };
    return allocator.dupe(u8, output.written());
}

pub fn completions(this: ReplEngine, prefix: []const u8) bun.JSError!Completions {
    var bound_prefix = try bindgen.DOMString.fromUTF8(prefix);
    defer bound_prefix.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(this.vm.global);
    defer scope.deinit();
    return scope.engine(GetCompletionsSchema).call(.{ .prefix = bound_prefix.operand() });
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;
const ReplBindings = bindgen.Module("Repl");
const EvaluateSchema = ReplBindings.engineShim("evaluate");
const GetCompletionsSchema = ReplBindings.engineShim("getCompletions");
const SetLastResultSchema = ReplBindings.engineShim("setLastResult");
const SetLastErrorSchema = ReplBindings.engineShim("setLastError");
