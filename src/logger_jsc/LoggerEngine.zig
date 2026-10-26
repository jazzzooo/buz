pub fn msgToRoot(this: Msg, globalObject: *jsc.JSGlobalObject) bun.JSError!bindgen.EngineRoot {
    return msgToRootWithReferrer(this, globalObject, "");
}

pub fn msgToRootWithReferrer(this: Msg, globalObject: *jsc.JSGlobalObject, referrer: []const u8) bun.JSError!bindgen.EngineRoot {
    return switch (this.metadata) {
        .build => blk: {
            var message = try bun.api.BuildMessage.createRef(globalObject, this);
            break :blk message.takeEngineRoot();
        },
        .resolve => blk: {
            var message = try bun.api.ResolveMessage.createRef(globalObject, this, referrer);
            break :blk message.takeEngineRoot();
        },
    };
}

pub fn logToRoot(this: *const Log, global: *jsc.JSGlobalObject, message: []const u8) bun.JSError!bindgen.EngineRoot {
    switch (this.msgs.items.len) {
        0 => {
            var scope: bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            return bindgen.EngineRoot.initUndefined(&scope);
        },
        1 => return msgToRoot(this.msgs.items[0], global),
        else => return logToAggregateErrorRoot(this, global, .fromBytes(message), ""),
    }
}

pub fn failDiagnostics(this: *const Log, context: anytype) (bun.JSError || bindgen.DomainFailure) {
    const messages = errorMessages(this);
    bun.assert(messages.len > 0);
    if (messages.len == 1) {
        const message = messages[0];
        return switch (message.metadata) {
            .build => context.fail(.build_message, try bun.api.BuildMessage.adoptResult(
                try bun.api.BuildMessage.createNative(message),
                context.errorContext(.build_message),
            )),
            .resolve => context.fail(.resolve_message, try bun.api.ResolveMessage.adoptResult(
                try bun.api.ResolveMessage.createNative(message, ""),
                context.errorContext(.resolve_message),
            )),
        };
    }

    const error_context = context.errorContext(.diagnostics);
    return context.fail(.diagnostics, try diagnosticSequence(messages, error_context));
}

fn diagnosticSequence(messages: []const Msg, context: anytype) bun.JSError!@TypeOf(context).Result {
    const Sequence = @TypeOf(context).Result;
    var result = try Sequence.Builder.init(messages.len);
    errdefer result.deinit();
    for (messages) |message| {
        result.appendOwned(switch (message.metadata) {
            .build => .{ .build = try bun.api.BuildMessage.adoptResult(
                try bun.api.BuildMessage.createNative(message),
                context,
            ) },
            .resolve => .{ .resolve = try bun.api.ResolveMessage.adoptResult(
                try bun.api.ResolveMessage.createNative(message, ""),
                context,
            ) },
        });
    }
    return result.finish();
}

pub fn throwLog(this: *const Log, global: *jsc.JSGlobalObject, message: []const u8) bun.JSError {
    var error_value = try logToRoot(this, global, message);
    var root = error_value.takeAnyRoot();
    defer root.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    return root.throwException(&scope);
}

pub fn throwAggregateError(this: *const Log, global: *jsc.JSGlobalObject, message: bun.TextView) bun.JSError {
    var error_value = try logToAggregateErrorRoot(this, global, message, "");
    var root = error_value.takeAnyRoot();
    defer root.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    return root.throwException(&scope);
}

pub fn logToAggregateErrorRoot(this: *const Log, global: *jsc.JSGlobalObject, message: bun.TextView, referrer: []const u8) bun.JSError!bun.bindgen.EngineRoot {
    var bound_message = try bun.bindgen.DOMString.fromTextView(message);
    defer bound_message.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const result = try createAggregateError(this, global, &scope, bound_message, referrer);
    return result.eraseBrandToEngineRoot();
}

fn createAggregateError(this: *const Log, global: *jsc.JSGlobalObject, scope: *bun.bindgen.FocusedEngineScope, message_text: bun.bindgen.DOMString, referrer: []const u8) @TypeOf(scope.engine(CreateAggregateErrorSchema)).Return {
    const msgs = errorMessages(this);
    const array = try scope.engine(CreateMessageArraySchema).call(.{ .length = msgs.len });
    for (msgs, 0..) |msg, i| {
        switch (msg.metadata) {
            .build => {
                var message = try bun.api.BuildMessage.createRef(global, msg);
                defer message.deinit();
                try scope.engine(AppendBuildMessageSchema).call(.{
                    .array = array.operand(scope),
                    .index = @as(u32, @intCast(i)),
                    .message = message.operand(scope),
                });
            },
            .resolve => {
                var message = try bun.api.ResolveMessage.createRef(global, msg, referrer);
                defer message.deinit();
                try scope.engine(AppendResolveMessageSchema).call(.{
                    .array = array.operand(scope),
                    .index = @as(u32, @intCast(i)),
                    .message = message.operand(scope),
                });
            },
        }
    }

    return scope.engine(CreateAggregateErrorSchema).call(.{
        .errors = array.operand(scope),
        .message = message_text.operand(),
    });
}

fn errorMessages(log: *const Log) []const Msg {
    // Bound exception aggregation without truncating the native log or build results.
    return log.msgs.items[0..@min(log.msgs.items.len, 256)];
}

const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;

const logger = bun.logger;
const Log = logger.Log;
const Msg = logger.Msg;

const LoggerJSCBindings = bun.bindgen.Module("LoggerJSC");
const CreateMessageArraySchema = LoggerJSCBindings.engineShim("createMessageArray");
const AppendBuildMessageSchema = LoggerJSCBindings.engineShim("appendBuildMessage");
const AppendResolveMessageSchema = LoggerJSCBindings.engineShim("appendResolveMessage");
const CreateAggregateErrorSchema = LoggerJSCBindings.engineShim("createAggregateError");
