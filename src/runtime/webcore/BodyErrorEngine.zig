pub fn retainStreamError(value: *const streams.Result.StreamError, global: *jsc.JSGlobalObject) bun.JSError!bindgen.Root {
    if (value.* == .JSValue) return value.JSValue.cloneRoot() orelse @panic("stored stream error has no value");
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    return materializeStreamError(value, &scope) catch |failure| rootFromFailure(&scope, failure);
}

fn materializeStreamError(value: *const streams.Result.StreamError, scope: *bindgen.FocusedEngineScope) bun.JSError!bindgen.Root {
    switch (value.*) {
        .OutOfMemory => return error.OutOfMemory,
        .Error => |*err| return rootFromSystemError(scope, err),
        .AbortReason => |reason| return rootFromAbortReason(scope, reason),
        .JSValue => unreachable,
        .consumed => @panic("consumed stream error cannot be materialized"),
    }
}

fn rootFromFailure(scope: *bindgen.FocusedEngineScope, failure: bun.JSError) bun.JSError!bindgen.Root {
    var thrown = try scope.takeThrownValue(failure);
    defer thrown.deinit();
    return thrown.toRoot();
}

fn rootFromSystemError(scope: *bindgen.FocusedEngineScope, err: *const bindgen.SystemError) bun.JSError!bindgen.Root {
    var value = try err.toErrorInstance(scope);
    defer value.deinit();
    return value.toRoot();
}

fn rootFromAbortReason(scope: *bindgen.FocusedEngineScope, reason: jsc.CommonAbortReason) bun.JSError!bindgen.Root {
    const operation = scope.engineIn("abort_signals", "commonAbortReasonToJS");
    var value = try operation.call(.{ .value = reason.toBinding(@FieldType(@TypeOf(operation).Args, "value")) });
    defer value.deinit();
    return value.toRoot();
}

pub const ValueError = union(enum) {
    OutOfMemory: void,
    AbortReason: jsc.CommonAbortReason,
    SystemError: bindgen.RefNative(SystemErrorBox, .any),
    Message: bindgen.OwnedBunString,
    /// Fetch maps network errors to `TypeError`, which callers can observe with `instanceof`.
    TypeError: bindgen.OwnedBunString,
    JSValue: bindgen.Root.Optional,

    pub const SystemErrorBox = struct {
        const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", destroy, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        ref_count: RefCount = .init(),
        value: bindgen.SystemError,

        pub fn borrow(box: *const SystemErrorBox) *const bindgen.SystemError {
            return &box.value;
        }

        fn destroy(box: *SystemErrorBox) void {
            box.value.deinit();
            bun.destroy(box);
        }
    };

    pub fn fromSystemError(value: bun.sys.SystemError) @This() {
        defer value.deref();
        return fromSystemErrorPayload(bindgen.SystemError.fromSystemError(&value) catch return .OutOfMemory);
    }

    pub fn fromFailure(failure: bun.JSError, global: *jsc.JSGlobalObject) bun.JSError!@This() {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        if (failure == error.OutOfMemory) {
            switch (scope.engineIn("errors", "globalObjectPendingExceptionKind").call(.{})) {
                .none => return .OutOfMemory,
                .termination => return error.JSTerminated,
                .other => {},
            }
        }
        var root = try rootFromFailure(&scope, failure);
        return .{ .JSValue = root.takeOptional() };
    }

    pub fn fromSystemErrorPayload(payload: bindgen.SystemError) @This() {
        var owned = payload;
        const box = bun.default_allocator.create(SystemErrorBox) catch {
            owned.deinit();
            return .OutOfMemory;
        };
        box.* = .{ .value = owned };
        return .{ .SystemError = .adopt(box) };
    }

    pub fn toStreamError(this: *@This(), global: *jsc.JSGlobalObject) bun.JSError!streams.Result.StreamError {
        if (this.* == .OutOfMemory) return .OutOfMemory;
        if (this.* == .AbortReason) return .{ .AbortReason = this.AbortReason };
        if (this.* == .SystemError) return .{ .Error = try this.SystemError.get().value.clone() };
        var root = try this.toRoot(global);
        return .{ .JSValue = root.takeOptional() };
    }

    pub fn toRoot(this: *@This(), global: *jsc.JSGlobalObject) bun.JSError!bindgen.Root {
        if (this.* == .JSValue) return this.JSValue.cloneRoot() orelse @panic("body error was already consumed");
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        var root = this.materialize(&scope) catch |failure| try rootFromFailure(&scope, failure);
        this.deinit();
        this.* = .{ .JSValue = root.takeOptional() };
        return this.JSValue.cloneRoot().?;
    }

    fn materialize(this: *const @This(), scope: *bindgen.FocusedEngineScope) bun.JSError!bindgen.Root {
        switch (this.*) {
            .OutOfMemory => return error.OutOfMemory,
            .AbortReason => |reason| return rootFromAbortReason(scope, reason),
            .SystemError => |*system_error| return rootFromSystemError(scope, &system_error.get().value),
            inline .Message, .TypeError => |*message, tag| {
                var text = try bindgen.DOMString.fromBunString(message.get().dupeRef());
                defer text.deinit();
                var value = try scope.engineIn("errors", if (tag == .Message) "createError" else "createTypeError").call(.{ .message = text.operand() });
                defer value.deinit();
                return value.toRoot();
            },
            .JSValue => unreachable,
        }
    }

    pub fn dupe(this: *const @This()) @This() {
        return switch (this.*) {
            inline .SystemError, .Message, .TypeError, .JSValue => |*value, tag| @unionInit(@This(), @tagName(tag), value.clone()),
            .OutOfMemory, .AbortReason => this.*,
        };
    }

    pub fn deinit(this: *@This()) void {
        var pending = this.*;
        this.* = .{ .JSValue = .empty };
        switch (pending) {
            inline .SystemError, .Message, .TypeError, .JSValue => |*value| value.deinit(),
            .OutOfMemory, .AbortReason => {},
        }
    }
};

const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;
const streams = @import("./streams.zig");
