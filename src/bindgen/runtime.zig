const std = @import("std");
const builtin = @import("builtin");
const bun = @import("bun");
const jsc = bun.jsc;
const ir = @import("bindgen_ir");
const wire = @import("binding_wire");
const class_field_validation = @import("./class_field_validation.zig");
const gc_token = @import("./gc_token.zig");
const value_encoding = @import("./value_encoding.zig");
const Manifest = @import("./manifest.zig");

pub const Status = enum(wire.BindStatus) {
    ok = wire.BIND_STATUS_OK,
    pending_exception = wire.BIND_STATUS_PENDING_EXCEPTION,
    out_of_memory = wire.BIND_STATUS_OUT_OF_MEMORY,
    failed = wire.BIND_STATUS_FAILED,

    fn fromWire(value: wire.BindStatus) Status {
        return std.enums.fromInt(Status, value) orelse @panic("binding operation returned an unknown status");
    }
};

const JSHostFn = fn (*jsc.JSGlobalObject, *jsc.CallFrame) callconv(jsc.conv) jsc.JSValue;
const retained_any_value_proof: u8 = 0;

pub fn voidFromJSError(err: bun.JSError, global: *jsc.JSGlobalObject) void {
    switch (err) {
        error.JSError => {},
        error.OutOfMemory => global.throwOutOfMemory() catch {},
        error.JSTerminated => {},
    }
}

fn createEngineFunctionValue(
    context: anytype,
    function_name: []const u8,
    argument_count: u32,
    function: *const JSHostFn,
) @TypeOf(context.engineIn("js_functions", "bindingFunctionCreate")).Return {
    var name = try DOMString.fromLatin1(function_name);
    defer name.deinit();
    return context.engineIn("js_functions", "bindingFunctionCreate").call(.{
        .symbolName = name.operand(),
        .argumentCount = argument_count,
        .function = @as(EngineArgumentType(BindingFunctionCreateSchema, "function"), @ptrCast(@constCast(function))),
    });
}

const CallFrameBindings = Module("call_frames");
const PromiseBindings = Module("promises");
const StrongReferenceBindings = Module("strong_references");
const JSFunctionBindings = Module("js_functions");
const AsyncHooksBindings = Module("AsyncHooks");
const BindingFunctionCreateSchema = JSFunctionBindings.engineShim("bindingFunctionCreate");
const BindingFunctionCreateWithDataSchema = JSFunctionBindings.engineShim("bindingFunctionCreateWithData");
const BindingFunctionClearDataSchema = JSFunctionBindings.engineShim("bindingFunctionClearData");
const CallFrameGetCallerSourceLocationSchema = CallFrameBindings.engineShim("callFrameGetCallerSourceLocation");
const CallFrameGetLineNumberSchema = CallFrameBindings.engineShim("callFrameGetLineNumber");
const PromiseCreateSchema = PromiseBindings.engineShim("promiseCreate");
const PromiseSemanticType = Manifest.EngineShimAt(Manifest.EngineShimId(PromiseCreateSchema)).ReturnType;

fn checkedStatus(global: *jsc.JSGlobalObject, status: Status) wire.BindStatus {
    return wire.bun_bindgen_check_traps(@ptrCast(global), @backingInt(status));
}

fn checkedNativeStatus(global: *jsc.JSGlobalObject, status: Status, inherited_exception: ?*const wire.BindExceptionHandle) wire.BindStatus {
    return wire.bun_bindgen_check_traps_inheriting(@ptrCast(global), @backingInt(status), inherited_exception);
}

fn commitCheckedResult(
    comptime Function: type,
    global: *jsc.JSGlobalObject,
    output: *wireType(Function.wire_result),
    staged: wireType(Function.wire_result),
    status: Status,
    inherited_exception: ?*const wire.BindExceptionHandle,
) wire.BindStatus {
    const checked = checkedNativeStatus(global, status, inherited_exception);
    if (checked != @backingInt(status)) {
        if (comptime Function.destroy_result_symbol != null) {
            var discarded = staged;
            destroyResultPayload(Function, &discarded);
        }
        return checked;
    }
    output.* = staged;
    return checked;
}

fn statusAfterCheckedCall(global: *jsc.JSGlobalObject, status: wire.BindStatus) Status {
    return Status.fromWire(wire.bun_bindgen_check_post_call_traps(@ptrCast(global), status));
}

fn requireCheckedSuccess(global: *jsc.JSGlobalObject, status: wire.BindStatus) bun.JSError!void {
    return switch (statusAfterCheckedCall(global, status)) {
        .ok => {},
        .pending_exception => error.JSError,
        .out_of_memory => error.OutOfMemory,
        .failed => @panic("binding operation without domain errors returned a domain failure"),
    };
}

fn decodeCreatedObject(global: *jsc.JSGlobalObject, raw_status: wire.BindStatus, encoded: wire.BindEncodedJSValue) bun.JSError!jsc.JSValue {
    if (raw_status != @backingInt(Status.ok) and
        raw_status != @backingInt(Status.pending_exception) and
        raw_status != @backingInt(Status.out_of_memory))
    {
        @panic("binding object creation returned an invalid status");
    }
    if ((raw_status == @backingInt(Status.ok)) != (encoded != 0)) {
        @panic("binding object creation returned a result inconsistent with its status");
    }
    try requireCheckedSuccess(global, raw_status);
    return @fromBackingInt(encoded);
}

fn FunctionMetadata(comptime function_id: usize, comptime overload_index: ?usize) type {
    const ParentMetadata = Manifest.FunctionAt(function_id);
    const Metadata = if (overload_index) |index|
        ParentMetadata.overload_cases[index]
    else
        ParentMetadata;
    const Result_ = struct {
        pub const Parent = if (overload_index != null) FunctionMetadata(function_id, null) else @This();
        pub const Context = FunctionCallContext(function_id);
        pub const overload_tag: ?[]const u8 = if (overload_index != null) Metadata.case_name else null;
        pub const id = function_id;
        pub const overload_id = overload_index;
        pub const module_name = Metadata.module_name;
        pub const function_name = Metadata.function_name;
        pub const args = Metadata.args;
        pub const is_overloaded = Metadata.is_overloaded;

        pub const overload_cases = Metadata.overload_cases;

        pub const ReturnType = Metadata.ReturnType;
        pub const backend = Metadata.backend;
        pub const domain_errors = Metadata.domain_errors;
        pub const completion = Metadata.completion;
        pub const is_async = Metadata.is_async;
        pub const completion_payload = if (Metadata.is_async and Metadata.backend == .cpp) Metadata.completion_payload else void;

        pub const result_position = Metadata.result_position;
        pub const call_plan = Metadata.call_plan;

        pub const invocation_args = Metadata.invocation_args;
        pub const has_callback_data = Metadata.has_callback_data;
        pub const CallbackData = if (Metadata.callback_data_type) |data_type|
            resolveZigDeclPath(bun, data_type)
        else
            anyopaque;
        pub const has_caller_source_location = Metadata.has_caller_source_location;
        pub const is_promise_reaction_handler = Metadata.is_promise_reaction_handler;
        pub const is_class_member = Metadata.is_class_member;
        pub const member_kind = Metadata.member_kind;
        pub const dispatch_symbol = Metadata.dispatch_symbol;
        pub const host_symbol = Metadata.host_symbol;
        pub const wire_args = Metadata.wire_args;
        pub const wire_result = Metadata.wire_result;
        pub const destroy_result_symbol = Metadata.destroy_result_symbol;
        pub const js_length = Metadata.js_length;
        pub const exposed = Metadata.exposed;
        pub const is_illegal = Metadata.is_illegal;
        pub const implementation = if (Metadata.is_class_member) Metadata.implementation_name else null;

        pub fn OverloadAt(comptime index: usize) type {
            if (!ParentMetadata.is_overloaded) @compileError("binding function does not declare overloads");
            if (index >= ParentMetadata.overload_cases.len) @compileError("binding overload index is out of bounds");
            return FunctionMetadata(function_id, index);
        }
    };
    return Result_;
}

fn EngineOperationId(
    comptime module_name: []const u8,
    comptime operation_name: []const u8,
) usize {
    return Manifest.EngineShimIdByName(module_name, operation_name);
}

fn BoundEngineOperation(comptime shim_id: usize) type {
    const Protocol = Outbound(Manifest.EngineShimAt(shim_id));
    return struct {
        token: ViewToken,

        pub const Args = Protocol.Args;
        pub const CallArgs = Protocol.CallArgs;
        pub const Return = Protocol.Return;

        pub fn call(operation: @This(), args: CallArgs) Protocol.Return {
            operation.token.requireActive();
            return Protocol.enter(if (Manifest.EngineShimAt(shim_id).call_plan.realm == .current) operation.token.globalObject() else null, operation.token, args, {});
        }

        /// Forwards named views from source; overrides are already-typed operands.
        pub fn callForwarded(operation: @This(), source: anytype, overrides: anytype) bun.JSError!Protocol.Value {
            const Declaration = Manifest.EngineShimAt(shim_id);
            if (Declaration.call_plan.transfers_argument_ownership)
                @compileError("forwarded calls cannot transfer argument ownership");
            operation.token.requireActive();
            inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| {
                if (!@hasField(Protocol.Args, name)) @compileError("binding call has no argument named '" ++ name ++ "'");
            }
            var prepared: Protocol.Args = undefined;
            inline for (@typeInfo(Protocol.Args).@"struct".field_names) |name| {
                if (comptime @hasField(@TypeOf(overrides), name)) {
                    @field(prepared, name) = @field(overrides, name);
                } else {
                    const forwarded = operation.argument(name, @field(source, name));
                    @field(prepared, name) = if (@typeInfo(@TypeOf(forwarded)) == .error_union) try forwarded else forwarded;
                }
            }
            return operation.call(prepared);
        }

        pub fn argument(operation: @This(), comptime name: []const u8, source: anytype) ForwardedArgument(Manifest.EngineShimAt(shim_id), name) {
            return forwardArgument(Manifest.EngineShimAt(shim_id), name, operation.token, source);
        }
    };
}

pub fn isCallScopedJSValueView(comptime Value: type) bool {
    if (Value == AnyView or Value == EngineValueView) return true;
    return switch (@typeInfo(Value)) {
        .@"struct" => @hasDecl(Value, "bindgen_class_ref_view") or
            @hasDecl(Value, "bindgen_branded_value_view") or
            (@hasDecl(Value, "bindgen_callback_handle") and Value.bindgen_callback_storage == .view),
        else => false,
    };
}

fn readCallScopedJSValue(global: *jsc.JSGlobalObject, token: ViewToken, value: anytype) jsc.JSValue {
    const Value = @TypeOf(value);
    if (comptime !isCallScopedJSValueView(Value)) {
        @compileError("expected a call-scoped JS value view");
    }
    if (comptime @hasDecl(Value, "bindgen_class_ref_view")) {
        return @fromBackingInt(value.wrapper.encodedForEngine(global, token));
    }
    if (comptime @hasDecl(Value, "bindgen_callback_handle")) {
        return readJSValue(value.borrowWireForEngine(global, token));
    }
    return @fromBackingInt(value.encodedForEngine(global, token));
}

fn NativeExportMetadata(comptime export_id: usize) type {
    const Metadata = Manifest.NativeExportAt(export_id);
    const Result_ = struct {
        pub const Parent = @This();
        pub const Context = if (Metadata.realm == .current) NativeCallContextFor(export_id) else void;
        pub const overload_tag: ?[]const u8 = null;
        pub const is_async = false;
        pub const completion: ?ir.CompletionPlan = null;
        pub const is_overloaded = false;
        pub const has_callback_data = false;
        pub const has_caller_source_location = false;
        pub const invocation_args: []const type = &.{};

        pub const id = export_id;
        pub const module_name = Metadata.module_name;
        pub const export_name = Metadata.export_name;
        pub const function_name = Metadata.export_name;
        pub const non_returning = Metadata.non_returning;
        pub const args = Metadata.args;
        pub const ReturnType = Metadata.ReturnType;
        pub const throws = Metadata.throws;
        pub const realm = Metadata.realm;
        pub const exposed = Metadata.exposed;

        pub const result_position = Metadata.result_position;
        pub const call_plan = Metadata.call_plan;
        pub const domain_errors = Metadata.domain_errors;
        pub const wire_args = Metadata.wire_args;
        pub const wire_result = Metadata.wire_result;
        pub const dispatch_symbol = Metadata.dispatch_symbol;
        pub const destroy_result_symbol = Metadata.destroy_result_symbol;
    };
    return Result_;
}

const schema_fingerprint = @extern(*const u8, .{
    .name = &ir.fingerprintSymbol(@import("binding_fingerprint")),
});

pub export fn bun_bindgen_zig_fingerprint_anchor() callconv(.c) void {
    comptime {
        if (Manifest.binding().target != currentTarget())
            @compileError("the binding IR was normalized for " ++ Manifest.binding().target.name() ++ ", not for the compilation target");
        @setEvalBranchQuota(10_000_000);
        for (0..Manifest.function_count) |id| {
            const Function = Manifest.FunctionAt(id);
            if (Function.is_async and Function.exposed) {
                _ = CppCompletionBinding(FunctionMetadata(id, null));
                if (Function.is_overloaded) for (0..Function.overload_cases.len) |index| {
                    _ = CppCompletionBinding(FunctionMetadata(id, index));
                };
            }
        }
        for (0..Manifest.engine_shim_count) |id| {
            _ = ResultBinding(Manifest.EngineShimAt(id));
        }
    }
    std.mem.doNotOptimizeAway(schema_fingerprint);
}

pub const DomainFailure = error{BindgenDomainFailure};
const CompletionRejection = error{BindgenCompletionRejection};

fn ContextMetadata(comptime Context: type) type {
    const Metadata = switch (@typeInfo(Context)) {
        .pointer => |pointer| pointer.child,
        else => Context,
    };
    if (!@hasDecl(Metadata, "bindgen_function_call_context") and
        !@hasDecl(Metadata, "bindgen_native_call_context"))
    {
        @compileError("expected a bindgen call context");
    }
    return Metadata;
}

pub fn ContextImplementationName(comptime Context: type) []const u8 {
    const Metadata = ContextMetadata(Context);
    if (!@hasDecl(Metadata, "bindgen_function_id")) {
        @compileError("binding implementation names require a function call context");
    }
    const Function = FunctionMetadata(Metadata.bindgen_function_id, null);
    if (!Function.is_class_member) {
        @compileError("binding implementation names require a class member context");
    }
    return Function.implementation;
}

pub fn requireFunctionContext(comptime Context: type, comptime FunctionSchema: type) void {
    const Metadata = ContextMetadata(Context);
    if (!@hasDecl(Metadata, "bindgen_function_id")) {
        @compileError("expected a bindgen function call context");
    }
    if (Metadata.bindgen_function_id != Manifest.FunctionId(FunctionSchema)) {
        @compileError("runtime operation requires its exact binding function context");
    }
}

pub fn MaterializationError(comptime FunctionSchema: type) type {
    return CallError(FunctionSchema) || CompletionRejection;
}

fn FunctionCallError(comptime Function: type) type {
    return if (Function.domain_errors.len == 0) bun.JSError else bun.JSError || DomainFailure;
}

const SweepCapability = opaque {};
const sweep_capability: u8 = 0;

pub const FinalizerNode = struct {
    node: jsc.NativeFinalizerQueue.Node = .{},

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);
};

pub const SweepContext = struct {
    _capability: *const SweepCapability,
};

fn sweepContext() SweepContext {
    return .{ ._capability = @ptrCast(&sweep_capability) };
}

pub const CallerFrameHandle = wire.BindCallFrameHandle;
const StoredRealmHandle = opaque {
    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
};
const StoredVMHandle = opaque {};

fn storedRealmGlobal(realm: *StoredRealmHandle) *jsc.JSGlobalObject {
    return @ptrCast(@alignCast(realm));
}

pub const VMIdentity = struct {
    handle: *StoredVMHandle,

    pub fn eql(left: VMIdentity, right: VMIdentity) bool {
        return left.handle == right.handle;
    }
};

pub const VMTaskActivity = struct {
    vm: ?*StoredVMHandle = null,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

    const Self = @This();

    pub fn isActive(activity: Self) bool {
        return activity.vm != null;
    }

    pub fn acquire(activity: *Self, identity: VMIdentity) void {
        const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(identity.handle));
        if (activity.vm) |owner| {
            if (owner != @as(*StoredVMHandle, @ptrCast(vm))) {
                @panic("VM task activity acquired by a different VM");
            }
            return;
        }
        activity.vm = @ptrCast(vm);
        vm.active_tasks += 1;
    }

    pub fn releaseForVM(activity: *Self, identity: VMIdentity) void {
        const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(identity.handle));
        const owner = activity.vm orelse return;
        if (owner != @as(*StoredVMHandle, @ptrCast(vm))) {
            @panic("VM task activity released by a different VM");
        }
        activity.release();
    }

    pub fn release(activity: *Self) void {
        const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(activity.vm orelse return));
        activity.vm = null;
        vm.active_tasks -= 1;
    }
};

pub const CallerSourceLocation = struct {
    source_url: DOMString,
    line: u32,
    column: u32,

    pub fn deinit(location: *CallerSourceLocation) void {
        location.source_url.deinit();
    }
};

pub const CallerSourceLocationView = struct {
    frame: *const CallerFrameHandle,
    token: ViewToken,

    pub fn sourceLocation(view: CallerSourceLocationView) bun.JSError!CallerSourceLocation {
        view.token.requireActive();
        var result = try Engine(CallFrameGetCallerSourceLocationSchema).call(view.engineGlobal(), .{
            .callFrame = @ptrCast(@constCast(view.frame)),
        });
        return .{
            .source_url = result.sourceURL.take(),
            .line = result.line,
            .column = result.column,
        };
    }

    pub fn lineNumber(view: CallerSourceLocationView) bun.JSError!u32 {
        view.token.requireActive();
        return try Engine(CallFrameGetLineNumberSchema).call(view.engineGlobal(), .{
            .callFrame = @ptrCast(@constCast(view.frame)),
        });
    }

    pub fn frameHandle(view: CallerSourceLocationView) *CallerFrameHandle {
        view.token.requireActive();
        return @constCast(view.frame);
    }

    fn engineGlobal(view: CallerSourceLocationView) *jsc.JSGlobalObject {
        return view.token.globalObject();
    }
};

fn CallContextState(comptime Function: type) type {
    return struct {
        call: *CallRecord,
        failure: *DomainFailureStorage(Function),
        completion_control: ?*anyopaque = null,
        completion_taken: ?*bool = null,
        native_receiver: ?*anyopaque = null,
        caller_frame: ?*const wire.BindCallFrameHandle = null,
    };
}

fn CallContextAccess(comptime Context: type, comptime Function: type) type {
    const State = CallContextState(Function);
    return struct {
        fn uncheckedState(context: Context) *const State {
            return @ptrCast(@alignCast(context));
        }

        fn viewToken(context: Context) ViewToken {
            return ViewToken.init(uncheckedState(context).call);
        }

        fn requireActive(context: Context) void {
            _ = viewToken(context);
        }

        fn state(context: Context) *const State {
            requireActive(context);
            return uncheckedState(context);
        }

        fn activeCall(context: Context) *CallRecord {
            return state(context).call;
        }

        fn globalObject(context: Context) *jsc.JSGlobalObject {
            return viewToken(context).globalObject();
        }

        fn fail(context: Context, comptime tag: FailureTagType(Function), payload: FailurePayloadApiType(Function, tag)) DomainFailure {
            return state(context).failure.commit(tag, payload);
        }
    };
}

fn requirePromiseReturn(comptime Function: type) void {
    if (comptime Function.ReturnType.kind != .branded_value or
        Function.ReturnType.PromiseValueType == void)
    {
        @compileError("typed promise construction requires a declared promise return type");
    }
}

fn resultClassMismatchDescription(comptime Type: type, comptime class_id: usize) []const u8 {
    if (Type.kind == .class_ref) return std.fmt.comptimePrint(
        "declared {s}.{s} (class ID {d}), attempted class ID {d}",
        .{
            Type.ReferencedClass.module_name,
            Type.ReferencedClass.class_name,
            Manifest.ClassId(Type.ReferencedClass),
            class_id,
        },
    );
    return "declared result kind " ++ @tagName(Type.kind);
}

fn ContextOperations(comptime Context: type) type {
    return struct {
        const ExceptionResult = @typeInfo(Return(Module("errors").engineShim("globalObjectTryTakeException"))).optional.child;

        pub fn vmIdentity(context: Context) VMIdentity {
            _ = context.viewToken();
            return .{ .handle = @ptrCast(context.viewToken().globalObject().bunVM()) };
        }

        pub fn tryTakeException(context: Context) ?ExceptionResult {
            _ = context.viewToken();
            return engineIn(context, "errors", "globalObjectTryTakeException").call(.{});
        }

        pub fn takeException(context: Context, failure: bun.JSError) ExceptionResult {
            switch (failure) {
                error.JSError, error.JSTerminated => {},
                error.OutOfMemory => context.viewToken().globalObject().throwOutOfMemory() catch {},
            }
            return tryTakeException(context) orelse @panic("a JavaScript exception was cleared before it could be read");
        }

        pub fn takeThrownException(context: Context, failure: bun.JSError) bun.JSTerminated!EngineValueResult {
            const exception = takeException(context, failure);
            if (engineIn(context, "errors", "jsValueIsTerminationException").call(.{ .value = exception.operand(context).asEngine() })) return error.JSTerminated;
            return engineIn(context, "errors", "exceptionThrownValue").call(.{ .exception = exception.operand(context).asEngine() });
        }

        pub fn takeThrownValue(context: Context, failure: bun.JSError) bun.JSTerminated!AnyResult {
            const value = try takeThrownException(context, failure);
            return value.asAny(context);
        }

        pub fn engineIn(
            context: Context,
            comptime module_name: []const u8,
            comptime operation_name: []const u8,
        ) BoundEngineOperation(EngineOperationId(module_name, operation_name)) {
            return .{ .token = context.viewToken() };
        }

        pub fn engine(context: Context, comptime Shim: type) BoundEngineOperation(Manifest.EngineShimId(Shim)) {
            return .{ .token = context.viewToken() };
        }

        pub fn reportUncaughtException(context: Context, exception: AnyOperand, is_rejection: bool) bool {
            const token = context.viewToken();
            const global = context.viewToken().globalObject();
            return global.bunVM().uncaughtException(
                global,
                exception.rawValueForEngine(global, token),
                is_rejection,
            );
        }

        pub fn reportUnhandledException(context: Context, exception: AnyOperand) void {
            const token = context.viewToken();
            const global = context.viewToken().globalObject();
            const vm = global.bunVM();
            vm.onUnhandledRejection(vm, global, exception.rawValueForEngine(global, token));
        }

        pub fn runErrorHandler(context: Context, exception: AnyOperand) void {
            const token = context.viewToken();
            const global = context.viewToken().globalObject();
            global.bunVM().runErrorHandler(exception.rawValueForEngine(global, token), null);
        }

        pub fn collectUnhandledException(context: Context, exception: AnyOperand, exception_list: *jsc.VirtualMachine.ExceptionList) void {
            const token = context.viewToken();
            const global = context.viewToken().globalObject();
            const vm = global.bunVM();
            const previous = vm.onUnhandledRejectionExceptionList;
            vm.onUnhandledRejectionExceptionList = exception_list;
            defer vm.onUnhandledRejectionExceptionList = previous;
            vm.onUnhandledRejection(vm, global, exception.rawValueForEngine(global, token));
        }

        pub fn reportUnhandledRejection(context: Context, reason: AnyOperand, promise: PromiseOperand) void {
            _ = context.viewToken();
            reportDeclaredUnhandledRejection(context, reason, promise);
        }

        pub fn waitForPromiseRejection(context: Context, promise: PromiseOperand) bun.JSError!?EngineValueResult {
            const global = context.viewToken().globalObject();
            var root = try PromiseRoot.create(promise.rawValueForEngine(global, context.viewToken()), global);
            defer root.deinit();
            return waitForDeclaredPromise(context, &root);
        }

        pub fn waitForPromiseResult(
            context: Context,
            promise: PromiseOperand,
            cancelled: ?*const std.atomic.Value(bool),
        ) bun.JSError!?PromiseSettlement {
            const global = context.viewToken().globalObject();
            var root = try PromiseRoot.create(promise.rawValueForEngine(global, context.viewToken()), global);
            defer root.deinit();
            if (!try waitForDeclaredPromiseSettlement(context, &root, cancelled)) return null;
            const operand = root.operand(context).asPromise();
            const result = (try context.engineIn("promises", "promiseResult").call(.{ .promise = operand })) orelse
                @panic("settled promise has no result");
            return switch (context.engineIn("promises", "promiseStatus").call(.{ .promise = operand })) {
                .fulfilled => .{ .fulfilled = result },
                .rejected => .{ .rejected = result },
                .pending => @panic("promise wait returned before settlement"),
            };
        }
    };
}

fn FunctionCallContext(comptime function_id: usize) type {
    const Function = FunctionMetadata(function_id, null);
    const Result_ = opaque {
        pub const bindgen_function_id = function_id;
        pub const bindgen_function_call_context = {};
        pub const bindgen_result_context = {};
        pub const bindgen_result_type = Function.ReturnType;

        pub const Result = Api(Function.result_position);

        const Self = @This();
        const Operations = ContextOperations(*const Self);

        pub const vmIdentity = Operations.vmIdentity;
        pub const takeThrownException = Operations.takeThrownException;
        pub const takeThrownValue = Operations.takeThrownValue;
        pub const engineIn = Operations.engineIn;
        pub const engine = Operations.engine;
        pub const reportUncaughtException = Operations.reportUncaughtException;
        pub const reportUnhandledException = Operations.reportUnhandledException;
        pub const runErrorHandler = Operations.runErrorHandler;
        pub const collectUnhandledException = Operations.collectUnhandledException;
        pub const waitForPromiseRejection = Operations.waitForPromiseRejection;
        pub const waitForPromiseResult = Operations.waitForPromiseResult;

        const Access = CallContextAccess(*const Self, Function);
        const state = Access.state;
        const activeCall = Access.activeCall;
        const globalObject = Access.globalObject;
        const requireActive = Access.requireActive;
        pub const viewToken = Access.viewToken;
        pub const fail = Access.fail;

        pub fn lease(context: *const Self, proof: DeferredLeaseProof) bun.JSError!void {
            const call = context.activeCall();
            proof.token.requireSameCall(context.viewToken(), context.globalObject(), "deferred lease proof used by an unrelated binding call");
            const deferred = call.deferred_conversions orelse @panic("binding call has no deferred leases");
            if (proof.handle != deferred) @panic("binding lease proof belongs to another deferred conversion set");
            const raw_status = wire.bun_bindgen_deferred_leases_acquire(@ptrCast(context.globalObject()), deferred);
            return requireCheckedSuccess(context.globalObject(), raw_status);
        }

        pub fn reportStoredUnhandledRejection(
            context: *const Self,
            reason: AnyOperand,
            promise: *PromiseRoot.Optional,
        ) void {
            const global = context.globalObject();
            global.bunVM().unhandledRejection(
                context,
                EngineValueResult.initInline(
                    reason.rawValueForEngine(global, context.viewToken()),
                    global,
                    context.viewToken(),
                    .engine,
                ),
                if (promise.trySwap()) |value|
                    PromiseResult.initInline(value, global, context.viewToken(), .branded)
                else
                    null,
            );
        }

        pub fn promiseResolved(context: *const Self, value: ResultType(declaredPromiseSemanticType(Self.Result).PromiseValueType)) bun.JSError!Self.Result {
            comptime requirePromiseReturn(Function);
            return context.promiseResolvedAs(Self.Result, value);
        }

        pub fn promiseResolvedAs(
            context: *const Self,
            comptime DeclaredResult: type,
            value: ResultType(declaredPromiseSemanticType(DeclaredResult).PromiseValueType),
        ) bun.JSError!DeclaredResult {
            const SemanticType = comptime declaredPromiseSemanticType(DeclaredResult);
            const PromiseValueType = SemanticType.PromiseValueType;
            if (comptime PromiseValueType.kind == .usize) {
                const resolved = try context.engineIn("promises", "promiseCreateResolvedSize").call(.{ .value = value });
                if (@TypeOf(resolved) != DeclaredResult) {
                    @compileError("resolved-size promise result does not match the declared promise type");
                }
                return resolved;
            } else {
                var promise = try context.engineIn("promises", "promiseCreateResolved").call(.{ .value = value.operand(context).asEngine() });
                defer promise.deinit();
                return DeclaredResult.initInline(
                    promise.rawValue(),
                    context.globalObject(),
                    context.viewToken(),
                    .branded,
                );
            }
        }

        pub fn promiseRejectedWithoutNotifying(context: *const Self, value: EngineOperand) bun.JSError!Self.Result {
            comptime requirePromiseReturn(Function);
            var promise = try context.engineIn("promises", "promiseCreateRejectedWithoutNotifying").call(.{ .value = value });
            defer promise.deinit();
            return Self.Result.initInline(
                promise.rawValue(),
                context.globalObject(),
                context.viewToken(),
                .branded,
            );
        }

        pub fn promiseFromPendingException(context: *const Self) Self.Result {
            comptime requirePromiseReturn(Function);
            var promise = context.engineIn("promises", "promiseWrapPendingException").call(.{});
            defer promise.deinit();
            return Self.Result.initInline(
                promise.rawValue(),
                context.globalObject(),
                context.viewToken(),
                .branded,
            );
        }

        pub fn callbackData(context: *const Self) ?*Function.CallbackData {
            context.requireActive();
            if (!Function.has_callback_data) @compileError("callback data was not declared for this binding");
            return if (context.state().native_receiver) |data| @ptrCast(@alignCast(data)) else null;
        }

        pub fn callerSourceLocation(context: *const Self) CallerSourceLocationView {
            context.requireActive();
            if (!Function.has_caller_source_location) @compileError("caller source location was not declared for this binding");
            return .{
                .frame = context.state().caller_frame.?,
                .token = context.viewToken(),
            };
        }

        pub fn completion(context: *const Self) CompletionTypes(Function).View {
            context.requireActive();
            if (!Function.is_async) @compileError("synchronous bindings do not have a completion");
            return .{
                .control = @ptrCast(@alignCast(context.state().completion_control.?)),
                .token = context.viewToken(),
                .taken = context.state().completion_taken.?,
            };
        }

        pub fn errorContext(context: *const Self, comptime tag: FailureTagType(Function)) DomainErrorContext(Function, tag) {
            return .{ .token = context.viewToken() };
        }
    };
    return *const Result_;
}

pub fn MemoryUsageContext(comptime affinity: ir.MemoryUsageAffinity) type {
    return struct {
        identity: if (affinity == .vm) VMIdentity else void,

        const Self = @This();
    };
}

pub const StructuredCloneError = bun.JSError || error{InvalidData};

pub fn StructuredCloneContext(comptime ClassSchema: type) type {
    return StructuredCloneContextById(Manifest.ClassId(ClassSchema));
}

fn StructuredCloneContextById(comptime class_id: usize) type {
    const ClassMeta = Manifest.ClassAt(class_id);
    if (!ClassMeta.has_structured_clone) @compileError("structured clone contexts require a structured-clone class");
    return struct {
        token: ViewToken,

        pub const bindgen_structured_clone_context = {};
        pub const bindgen_class_id = class_id;

        const Self = @This();

        fn init(global: *jsc.JSGlobalObject, token: ViewToken) Self {
            if (token.globalObject() != global) @panic("structured clone context has the wrong call realm");
            return .{ .token = token };
        }

        pub fn viewToken(context: *const Self) ViewToken {
            context.requireActive();
            return context.token;
        }

        fn requireActive(context: *const Self) void {
            context.token.requireActive();
        }

        pub const engineIn = ContextOperations(*const Self).engineIn;
        pub const engine = ContextOperations(*const Self).engine;
    };
}

pub const StructuredCloneWriter = struct {
    serializer: *wire.BindCloneSerializerHandle,
    token: ViewToken,

    pub fn writeAll(writer: StructuredCloneWriter, bytes: []const u8) bun.OOM!void {
        writer.token.requireActive();
        var remaining = bytes;
        while (remaining.len > 0) {
            const chunk_len = @min(remaining.len, std.math.maxInt(u32));
            switch (wire.bun_bindgen_clone_write(writer.serializer, remaining.ptr, @intCast(chunk_len))) {
                @backingInt(Status.ok) => {},
                @backingInt(Status.out_of_memory) => return error.OutOfMemory,
                else => @panic("structured clone writer returned an invalid status"),
            }
            remaining = remaining[chunk_len..];
        }
    }

    pub fn writeInt(
        writer: StructuredCloneWriter,
        comptime T: type,
        value: T,
        endian: std.lang.Endian,
    ) bun.OOM!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, endian);
        try writer.writeAll(&bytes);
    }
};

pub const StructuredCloneReader = struct {
    ptr: [*]const u8,
    end: [*]const u8,
    token: ViewToken,

    pub const Error = error{EndOfStream};

    pub fn remaining(reader: *const StructuredCloneReader) usize {
        reader.token.requireActive();
        const start = @intFromPtr(reader.ptr);
        const finish = @intFromPtr(reader.end);
        if (finish < start) @panic("structured clone reader bounds are reversed");
        return finish - start;
    }

    pub fn readAll(reader: *StructuredCloneReader, out: []u8) Error!void {
        if (out.len > reader.remaining()) return error.EndOfStream;
        @memcpy(out, reader.ptr[0..out.len]);
        reader.ptr += out.len;
    }

    pub fn readInt(
        reader: *StructuredCloneReader,
        comptime T: type,
        endian: std.lang.Endian,
    ) Error!T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try reader.readAll(&bytes);
        return std.mem.readInt(T, &bytes, endian);
    }
};

pub const ViewToken = struct {
    call: *CallRecord,
    generation: if (bun.Environment.allow_assert) u64 else void,

    fn init(call: *CallRecord) ViewToken {
        if (comptime bun.Environment.allow_assert) {
            var current = CheckedActiveCalls.top;
            while (current) |active| : (current = active.parent) {
                if (active == call) return .{ .call = call, .generation = active.id };
            }
            @panic("binding view created outside its call");
        }
        return .{ .call = call, .generation = {} };
    }

    pub fn requireActive(token: ViewToken) void {
        if (comptime bun.Environment.allow_assert) {
            var current = CheckedActiveCalls.top;
            while (current) |call| : (current = call.parent) {
                // A later invocation can reuse the same call-record address.
                if (call == token.call and call.id == token.generation) return;
            }
            @panic("binding view used outside its call");
        }
    }

    fn sameCall(token: ViewToken, other: ViewToken) bool {
        token.requireActive();
        other.requireActive();
        return token.call == other.call;
    }

    fn requireSameCall(
        token: ViewToken,
        operation_token: ViewToken,
        global: *jsc.JSGlobalObject,
        comptime message: []const u8,
    ) void {
        if (!token.sameCall(operation_token) or token.globalObject() != global) {
            @panic(message);
        }
    }

    pub fn globalObject(token: ViewToken) *jsc.JSGlobalObject {
        token.requireActive();
        return token.call.global_object orelse @panic("realm-free binding call has no global object");
    }
};

pub const DeferredLeaseProof = struct {
    handle: *wire.BindDeferredConversionsHandle,
    token: ViewToken,

    fn init(handle: ?*wire.BindDeferredConversionsHandle, token: ViewToken) DeferredLeaseProof {
        token.requireActive();
        return .{
            .handle = handle orelse @panic("last deferred conversion did not return a lease proof"),
            .token = token,
        };
    }
};

const StringEncoding = enum(wire.BindStringEncoding) {
    latin1 = wire.BIND_STRING_LATIN1,
    utf16 = wire.BIND_STRING_UTF16,
};

pub const UnsafeStringCodeUnits = union(enum) {
    latin1: []const u8,
    utf16: []const u16,

    pub fn textView(self: @This()) bun.TextView {
        return switch (self) {
            .latin1 => |units| .{ .latin1 = units },
            .utf16 => |units| .{ .utf16 = units },
        };
    }
};

pub const DOMStringView = BoundStringView(.dom_string, false);
pub const USVStringView = BoundStringView(.usv_string, false);
pub const ByteStringView = BoundStringView(.byte_string, false);
pub const ThreadSafeDOMStringView = BoundStringView(.dom_string, true);
pub const ThreadSafeUSVStringView = BoundStringView(.usv_string, true);
pub const ThreadSafeByteStringView = BoundStringView(.byte_string, true);
pub const DOMString = BoundString(.dom_string, false);
pub const USVString = BoundString(.usv_string, false);
pub const ByteString = BoundString(.byte_string, false);
pub const ThreadSafeDOMString = BoundString(.dom_string, true);
pub const ThreadSafeUSVString = BoundString(.usv_string, true);
pub const ThreadSafeByteString = BoundString(.byte_string, true);

const api_eval_branch_quota = 10_000_000;

fn decodeBoundStringView(
    comptime kind: ir.StringKind,
    handle: ?*const wire.BindStringHandle,
) wire.BindStringView {
    var view: wire.BindStringView = std.mem.zeroes(wire.BindStringView);
    wire.bun_bindgen_string_view(handle, &view);
    _ = boundStringCodeUnits(kind, view);
    return view;
}

fn boundStringCodeUnits(
    comptime kind: ir.StringKind,
    view: wire.BindStringView,
) UnsafeStringCodeUnits {
    if (view.len == 0) {
        if (view.ptr != null) @panic("binding string view is not in canonical empty form");
        if (view.encoding != @backingInt(StringEncoding.latin1)) {
            @panic("binding empty string view has a non-canonical encoding");
        }
        return .{ .latin1 = &.{} };
    }
    return switch (view.encoding) {
        @backingInt(StringEncoding.latin1) => .{ .latin1 = wireSlice([]const u8, view) },
        @backingInt(StringEncoding.utf16) => blk: {
            if (kind == .byte_string) @panic("ByteString was not stored as Latin-1");
            break :blk .{ .utf16 = wireSlice([]const u16, view) };
        },
        else => @panic("binding string view has an unknown encoding"),
    };
}

fn ExternalRefNativeType(comptime Type: type) type {
    if (comptime Type.kind != .external_ref) @compileError("external native types require an external reference schema type");
    return resolveZigDeclPath(bun, Type.zig_type);
}

fn ExternalRefView(comptime Type: type) type {
    if (comptime Type.kind != .external_ref) @compileError("ExternalRefView requires an external reference schema type");
    const Handle = wireType(Type.external_handle_wire);
    const Result_ = struct {
        handle: *const Handle,
        token: ViewToken,

        const Self = @This();
        pub const Native = ExternalRefNativeType(Type);

        fn init(handle: ?*const Handle, token: ViewToken) Self {
            return .{
                .handle = handle orelse @panic("binding external reference view is null"),
                .token = token,
            };
        }

        pub fn get(self: Self) *Native {
            self.token.requireActive();
            return @ptrCast(@alignCast(@constCast(self.handle)));
        }

        pub fn toOwned(self: Self) ExternalRef(Type) {
            self.token.requireActive();
            const handle = @field(wire, Type.external_clone_symbol)(self.handle) orelse
                @panic("binding external reference clone returned null");
            return ExternalRef(Type).adoptWire(handle);
        }
    };
    return Result_;
}

fn ExternalRef(comptime Type: type) type {
    if (comptime Type.kind != .external_ref) @compileError("ExternalRef requires an external reference schema type");
    const Handle = wireType(Type.external_handle_wire);
    const Result_ = struct {
        handle: ?*Handle,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(
            @This(),
            .vm,
        );

        const Self = @This();
        pub const Native = ExternalRefNativeType(Type);

        pub fn get(self: *const Self) *Native {
            return @ptrCast(@alignCast(self.requireHandle()));
        }

        pub fn deinit(self: *Self) void {
            const handle = self.handle orelse return;
            self.handle = null;
            @field(wire, Type.external_release_symbol)(handle);
        }

        fn adoptWire(handle: ?*Handle) Self {
            return .{ .handle = handle orelse @panic("binding external reference transfer is null") };
        }

        fn takeWire(self: *Self) *Handle {
            const handle = self.requireHandle();
            self.handle = null;
            return handle;
        }

        pub fn takeNative(self: *Self) *Native {
            return @ptrCast(@alignCast(self.takeWire()));
        }

        fn borrowWire(self: *const Self) *Handle {
            return self.requireHandle();
        }

        fn requireHandle(self: *const Self) *Handle {
            return self.handle orelse @panic("binding external reference was moved or released");
        }
    };
    return Result_;
}

fn OwnedNominalHandle(comptime Type: type, comptime ownership: @import("document.zig").NominalOwnership) type {
    const Result_ = struct {
        handle: ?NominalHandlePointer(Type),

        pub const bindgen_gc_token = gc_token.markerWithAffinity(
            @This(),
            if (ownership.destroy_thread == .any) .any else .vm,
        );
        pub const Native = NominalHandleNativeType(Type);

        const Self = @This();

        pub const ByteResource = struct {
            owner: Self,

            pub const bindgen_gc_token = gc_token.markerWithAffinity(
                @This(),
                if (ownership.destroy_thread == .any) .any else .vm,
            );

            pub fn slice(resource: *const ByteResource) []const u8 {
                return resource.owner.readableBytes();
            }

            pub fn length(resource: *const ByteResource) usize {
                return resource.slice().len;
            }

            pub fn take(resource: *ByteResource) ByteResource {
                return .{ .owner = resource.owner.take() };
            }

            pub fn deinit(resource: *ByteResource) void {
                resource.owner.deinit();
            }
        };

        pub fn get(self: *const Self) NominalHandlePointer(Type) {
            if (comptime Type.zig_type == null) {
                @compileError("opaque owned nominal handles can only be passed to schema-declared operations");
            }
            return self.requireHandle();
        }

        pub fn initNative(handle: NominalHandlePointer(Type)) Self {
            if (Type.zig_type == null) {
                @compileError("only nominal handles with a declared Zig type can be constructed in Zig");
            }
            return .{ .handle = handle };
        }

        pub fn takeNative(self: *Self) NominalHandlePointer(Type) {
            if (Type.zig_type == null) {
                @compileError("opaque owned nominal handles can only be transferred to schema-declared operations");
            }
            return self.takeHandle();
        }

        fn requireHandle(self: *const Self) NominalHandlePointer(Type) {
            return self.handle orelse @panic("owned nominal handle was moved or released");
        }

        fn takeHandle(self: *Self) NominalHandlePointer(Type) {
            return bun.take(&self.handle) orelse @panic("owned nominal handle was moved or released");
        }

        pub fn deinit(self: *Self) void {
            const handle = bun.take(&self.handle) orelse return;
            @field(wire, ownership.release_symbol)(nominalHandleToWire(Type, handle));
        }

        pub fn take(self: *Self) Self {
            return .{ .handle = self.takeHandle() };
        }

        pub fn takeByteResource(self: *Self) ByteResource {
            if (comptime ownership.byte_access == null) {
                @compileError("only readable owned nominal handles can transfer their byte resource");
            }
            return .{ .owner = self.take() };
        }

        fn readableBytes(self: *const Self) []const u8 {
            var view: wire.BindConstByteSlice = undefined;
            if (comptime ownership.byte_access) |access| {
                @field(wire, access.symbol)(self.borrowWire(), &view);
            } else {
                @compileError("this owned nominal handle does not expose immutable bytes");
            }
            return wireSlice([]const u8, view);
        }

        fn borrowWire(self: *const Self) NominalHandleWirePointer(Type) {
            return nominalHandleToWire(Type, self.requireHandle());
        }

        fn takeWire(self: *Self) NominalHandleWirePointer(Type) {
            return nominalHandleToWire(Type, self.takeHandle());
        }

        fn commitTransfer(self: *Self) void {
            _ = self.takeHandle();
        }

        fn adoptWire(handle: ?NominalHandleWirePointer(Type)) Self {
            return .{ .handle = @ptrCast(@alignCast(handle orelse @panic("binding received a null owned nominal handle"))) };
        }
    };
    return Result_;
}

fn NominalHandleNativeType(comptime Type: type) type {
    const path = Type.zig_type orelse return Type.Native;
    if (std.mem.eql(u8, path, "u8")) return u8;
    return resolveZigDeclPath(bun, path);
}

fn resolveZigDeclPath(comptime Namespace: type, comptime path: []const u8) type {
    const separator = std.mem.indexOfScalar(u8, path, '.');
    const name = if (separator) |index| path[0..index] else path;
    if (!@hasDecl(Namespace, name)) {
        @compileError("binding Zig type does not resolve: " ++ path);
    }
    const Declaration = @field(Namespace, name);
    if (@TypeOf(Declaration) != type) {
        @compileError("binding Zig type path names a non-type declaration: " ++ path);
    }
    return if (separator) |index|
        resolveZigDeclPath(Declaration, path[index + 1 ..])
    else
        Declaration;
}

fn NominalHandlePointer(comptime Type: type) type {
    const Native = NominalHandleNativeType(Type);
    return if (comptime Type.const_pointee) *const Native else *Native;
}

fn NominalHandleWireType(comptime Type: type) type {
    return wireType(Type.nominal_handle_wire);
}

fn NominalHandleWirePointer(comptime Type: type) type {
    return *NominalHandleWireType(Type);
}

fn nominalHandleToWire(comptime Type: type, handle: NominalHandlePointer(Type)) NominalHandleWirePointer(Type) {
    return if (comptime Type.const_pointee)
        @ptrCast(@constCast(handle))
    else
        @ptrCast(handle);
}

fn ByteReads(comptime Receiver: type) type {
    return struct {
        fn read(self: Receiver, offset: usize, destination: []u8) bool {
            const bytes = self.raw();
            if (offset > bytes.len or destination.len > bytes.len - offset) return false;
            @memmove(destination, bytes[offset..][0..destination.len]);
            return true;
        }

        fn copy(self: Receiver) bun.OOM!OwnedBytes {
            return OwnedBytes.fromSlice(self.raw());
        }

        fn unsafePtr(self: Receiver, comptime reason: []const u8) []const u8 {
            if (reason.len == 0) @compileError("unsafePtr requires a non-empty lifetime reason");
            return self.raw();
        }
    };
}

pub const BytesView = struct {
    ptr: ?[*]const u8,
    len: usize,
    token: ViewToken,

    const Self = @This();

    fn init(value: anytype, token: ViewToken) Self {
        const bytes = wireSlice([]const u8, value);
        return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len, .token = token };
    }

    pub fn length(self: Self) usize {
        self.token.requireActive();
        return self.len;
    }

    pub fn operand(self: Self) BytesOperand {
        self.token.requireActive();
        return .{ .pointer = @ptrCast(self.ptr), .len = self.len, .token = self.token };
    }

    pub const read = ByteReads(Self).read;

    pub const copy = ByteReads(Self).copy;

    pub const toOwned = copy;

    pub fn dupe(self: Self, allocator: std.mem.Allocator) bun.OOM![]u8 {
        return allocator.dupe(u8, self.raw());
    }

    pub const unsafePtr = ByteReads(Self).unsafePtr;

    fn raw(self: Self) []const u8 {
        self.token.requireActive();
        if (self.len == 0) return &.{};
        return self.ptr.?[0..self.len];
    }
};

pub const BytesOperand = struct {
    pointer: ?*const Data,
    len: usize,
    token: ?ViewToken,

    const Data = opaque {};

    pub fn fromSlice(bytes: []const u8) BytesOperand {
        return .{ .pointer = if (bytes.len == 0) null else @ptrCast(bytes.ptr), .len = bytes.len, .token = null };
    }

    fn borrowWire(self: BytesOperand) wire.BindConstByteSlice {
        if (self.token) |token| token.requireActive();
        return .{ .ptr = if (self.len == 0) null else @as([*]const u8, @ptrCast(self.pointer.?)), .len = self.len };
    }
};

pub const ExternalBytesOwnerHandle = wire.BindByteOwnerHandle;
pub const ExternalBytesDeallocator = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const ExternalBytesDeallocatorWithLength = *const fn (?*anyopaque, [*c]u8, usize) callconv(.c) void;
pub const OwnedByteResource = ResultType(Manifest.semanticTypeNamed(.nominal_handle, "ExternalBytesOwner")).ByteResource;

pub const OwnedBunString = struct {
    value: bun.String,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

    const Self = @This();

    pub fn adopt(value: bun.String) Self {
        return .{ .value = value };
    }

    pub fn retain(value: bun.String) Self {
        return adopt(value.dupeRef());
    }

    pub fn get(self: *const Self) *const bun.String {
        return &self.value;
    }

    pub fn clone(self: *const Self) Self {
        return retain(self.value);
    }

    pub fn take(self: *Self) bun.String {
        const value = self.value;
        self.value = .empty;
        return value;
    }

    pub fn deinit(self: *Self) void {
        self.take().deref();
    }
};

pub fn adoptExternalBytesOwner(
    data: ?*anyopaque,
    len: usize,
    context: ?*anyopaque,
    deallocator: ExternalBytesDeallocator,
) bun.OOM!*ExternalBytesOwnerHandle {
    if (data == null and len != 0) @panic("external byte owner received a null non-empty allocation");
    return wire.bun_bindgen_external_byte_owner_adopt(
        @ptrCast(data),
        len,
        context,
        @ptrCast(deallocator),
    ) orelse {
        deallocator(data, context);
        return error.OutOfMemory;
    };
}

pub fn adoptExternalBytesOwnerWithLength(
    data: ?*anyopaque,
    len: usize,
    context: ?*anyopaque,
    deallocator: ExternalBytesDeallocatorWithLength,
) bun.OOM!*ExternalBytesOwnerHandle {
    if (data == null and len != 0) @panic("external byte owner received a null non-empty allocation");
    return wire.bun_bindgen_byte_owner_create(
        @ptrCast(data),
        len,
        context,
        @ptrCast(deallocator),
    ) orelse {
        deallocator(context, @ptrCast(data), len);
        return error.OutOfMemory;
    };
}

pub const OwnedByteList = struct {
    list: std.array_list.Managed(u8),

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

    const Self = @This();

    pub fn init(list_allocator: std.mem.Allocator) Self {
        return .{ .list = .init(list_allocator) };
    }

    pub fn fromManaged(list: std.array_list.Managed(u8)) Self {
        return .{ .list = list };
    }

    pub fn fromOwnedSlice(list_allocator: std.mem.Allocator, bytes: []u8) Self {
        return .{ .list = .fromOwnedSlice(list_allocator, bytes) };
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.list.items;
    }

    pub fn length(self: *const Self) usize {
        return self.list.items.len;
    }

    pub fn capacity(self: *const Self) usize {
        return self.list.capacity;
    }

    pub fn ensureTotalCapacityPrecise(self: *Self, size: usize) bun.OOM!void {
        try self.list.ensureTotalCapacityPrecise(size);
    }

    pub fn clearRetainingCapacity(self: *Self) void {
        self.list.clearRetainingCapacity();
    }

    pub fn write(self: *Self, bytes: []const u8) bun.OOM!usize {
        try self.list.appendSlice(bytes);
        return bytes.len;
    }

    pub fn writeLatin1(self: *Self, bytes: []const u8) bun.OOM!usize {
        const encoded_length = bun.strings.elementLengthLatin1IntoUTF8(bytes);
        try self.list.ensureUnusedCapacity(encoded_length);
        const written = bun.simdutf.convert.latin1.to.utf8(bytes, self.list.unusedCapacitySlice());
        bun.assert(written == encoded_length);
        self.list.items.len += written;
        return written;
    }

    pub fn writeUTF16(self: *Self, units: []const u16) bun.OOM!usize {
        const encoded_length = bun.strings.elementLengthUTF16IntoUTF8WithReplacement(units);
        try self.list.ensureUnusedCapacity(encoded_length);
        const encoded = bun.strings.copyUTF16IntoUTF8WithBufferImpl(self.list.unusedCapacitySlice(), units, encoded_length, false);
        bun.assert(encoded.read == units.len and encoded.written == encoded_length);
        self.list.items.len += encoded.written;
        return encoded.written;
    }

    pub fn takeManaged(self: *Self) std.array_list.Managed(u8) {
        const list_allocator = self.list.allocator;
        const list = self.list;
        self.list = .init(list_allocator);
        return list;
    }

    pub fn tryToDefaultOwnedSlice(self: *Self) bun.OOM![]u8 {
        const list_allocator = self.list.allocator;
        if (bun.allocators.isDefault(list_allocator)) {
            return try self.list.toOwnedSlice();
        }
        const bytes = try bun.default_allocator.dupe(u8, self.list.items);
        self.deinit();
        return bytes;
    }

    pub fn deinit(self: *Self) void {
        self.takeManaged().deinit();
    }
};

pub const OwnedBytes = struct {
    bytes: []u8,
    owner: ?*wire.BindByteOwnerHandle,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

    const Self = @This();

    pub fn fromSlice(value: []const u8) bun.OOM!Self {
        return .{ .bytes = try copyTransferBytes(value), .owner = null };
    }

    pub fn fromDefaultAllocatedSlice(value: []u8) Self {
        if (value.len == 0) return empty();
        return .{ .bytes = value, .owner = null };
    }

    pub fn initUninitialized(len: usize) bun.OOM!Self {
        if (len == 0) return empty();
        return .{ .bytes = try transferAlloc(u8, len), .owner = null };
    }

    pub fn mutableSlice(self: *Self) []u8 {
        return self.bytes;
    }

    pub fn fromMappedSlice(value: []align(std.heap.page_size_min) u8) bun.OOM!Self {
        if (comptime bun.Environment.isPosix) {
            if (value.len == 0) return empty();
            const owner = wire.bun_bindgen_byte_owner_create(
                value.ptr,
                value.len,
                null,
                releaseMappedBytes,
            ) orelse return error.OutOfMemory;
            return .{ .bytes = value, .owner = owner };
        } else {
            unreachable;
        }
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.bytes;
    }

    pub fn operand(self: *const Self) BytesOperand {
        return .fromSlice(self.bytes);
    }

    pub fn length(self: *const Self) usize {
        return self.bytes.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.bytes.len == 0;
    }

    pub fn clone(self: *const Self) bun.OOM!Self {
        return fromSlice(self.bytes);
    }

    pub fn deinit(self: *Self) void {
        const pending = self.take();
        if (pending.owner) |owner|
            wire.bun_bindgen_byte_owner_release(owner)
        else
            freeTransferBytes(pending.bytes);
    }

    pub fn take(self: *Self) Self {
        const value = self.*;
        self.* = empty();
        return value;
    }

    fn takeWire(self: *Self) wire.BindByteSlice {
        const owned = self.take();
        return .{
            .ptr = if (owned.bytes.len == 0) null else owned.bytes.ptr,
            .len = owned.bytes.len,
            .owner = owned.owner,
        };
    }

    fn borrowWire(self: *const Self) wire.BindByteSlice {
        return .{
            .ptr = if (self.bytes.len == 0) null else self.bytes.ptr,
            .len = self.bytes.len,
            .owner = null,
        };
    }

    fn adoptWire(value: wire.BindByteSlice) Self {
        return .{ .bytes = wireSlice([]u8, value), .owner = value.owner };
    }

    pub fn empty() Self {
        return .{ .bytes = &.{}, .owner = null };
    }

    fn releaseMappedBytes(_: ?*anyopaque, ptr: [*c]u8, len: usize) callconv(.c) void {
        bun.assert(ptr != null and len > 0);
        const mapping = @as(
            [*]align(std.heap.page_size_min) const u8,
            @ptrCast(@alignCast(ptr)),
        )[0..len];
        _ = bun.sys.munmap(mapping);
    }
};

pub const UTF8String = struct {
    bytes: OwnedBytes,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

    const Self = @This();

    pub fn fromSlice(value: []const u8) bun.OOM!Self {
        return .{ .bytes = try OwnedBytes.fromSlice(value) };
    }

    pub fn deinit(self: *Self) void {
        self.bytes.deinit();
    }

    fn takeWire(self: *Self) wire.BindByteSlice {
        return self.bytes.takeWire();
    }
};

pub const SystemError = struct {
    error_number: i32,
    code: OwnedBytes = OwnedBytes.empty(),
    message: OwnedBytes = OwnedBytes.empty(),
    path: OwnedBytes = OwnedBytes.empty(),
    syscall: OwnedBytes = OwnedBytes.empty(),
    hostname: OwnedBytes = OwnedBytes.empty(),
    fd: i32,
    dest: OwnedBytes = OwnedBytes.empty(),
    address: OwnedBytes = OwnedBytes.empty(),
    port: ?u16,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

    pub const Init = struct {
        errno: i32,
        code: []const u8 = "",
        message: []const u8,
        path: []const u8 = "",
        syscall: []const u8 = "",
        hostname: []const u8 = "",
        fd: i32 = std.math.minInt(i32),
        dest: []const u8 = "",
        address: []const u8 = "",
        port: ?u16 = null,
    };

    const Self = @This();

    const byte_fields = fields: {
        const info = @typeInfo(Self).@"struct";
        var names: []const []const u8 = &.{};
        for (info.field_names, info.field_types) |name, T| {
            if (T == OwnedBytes) names = names ++ .{name};
        }
        break :fields names;
    };

    pub fn init(input: Init) bun.OOM!Self {
        var result: Self = .{ .error_number = input.errno, .fd = input.fd, .port = input.port };
        errdefer result.deinit();
        inline for (byte_fields) |name| @field(result, name) = try OwnedBytes.fromSlice(@field(input, name));
        return result;
    }

    pub fn fromSysError(value: bun.sys.Error) bun.OOM!Self {
        var message_buffer: [bun.sys.Error.system_error_message_capacity]u8 = undefined;
        return init(sysErrorInput(value, &message_buffer));
    }

    pub fn createSysErrorInstance(context: anytype, value: bun.sys.Error) @TypeOf(context.engineIn("errors", "systemErrorToErrorInstance")).Return {
        var message_buffer: [bun.sys.Error.system_error_message_capacity]u8 = undefined;
        return createErrorInstance(context, sysErrorInput(value, &message_buffer));
    }

    fn sysErrorInput(value: bun.sys.Error, message_buffer: *[bun.sys.Error.system_error_message_capacity]u8) Init {
        const data = value.toSystemErrorData(message_buffer);
        return .{
            .errno = data.errno,
            .code = data.code orelse "",
            .message = data.message,
            .path = data.path,
            .syscall = data.syscall,
            .fd = data.fd,
            .dest = data.dest,
        };
    }

    pub fn fromSysErrorWithInfo(value: bun.sys.Error) bun.OOM!Self {
        const resolved = value.getErrorCodeTagName();
        return init(.{
            .errno = -%@as(i32, value.errno),
            .code = if (resolved) |entry| entry[0] else "UNKNOWN",
            .message = if (resolved) |entry| bun.sys.libuv_error_map.get(entry[1]).? else "unknown error",
            .syscall = @tagName(value.syscall),
        });
    }

    pub fn fromDNSError(value: bun.c_ares.Error, syscall: []const u8, hostname: ?[]const u8) bun.OOM!Self {
        const code = value.code()["DNS_".len..];
        var result = try init(.{
            .errno = @backingInt(value),
            .code = code,
            .message = "",
            .syscall = syscall,
            .hostname = hostname orelse "",
        });
        errdefer result.deinit();
        result.message = .fromDefaultAllocatedSlice(if (hostname) |host|
            try std.fmt.allocPrint(bun.default_allocator, "{s} {s} {s}", .{ syscall, code, host })
        else
            try std.fmt.allocPrint(bun.default_allocator, "{s} {s}", .{ syscall, code }));
        return result;
    }

    pub fn fromSystemError(value: *const bun.sys.SystemError) bun.OOM!Self {
        var result: Self = .{ .error_number = value.errno, .fd = value.fd, .port = null };
        errdefer result.deinit();
        inline for (byte_fields) |name| {
            if (comptime !std.mem.eql(u8, name, "address")) {
                @field(result, name) = .fromDefaultAllocatedSlice(try @field(value, name).toOwnedSlice(bun.default_allocator));
            }
        }
        return result;
    }

    pub fn toErrorInstance(
        self: *const Self,
        context: anytype,
    ) @TypeOf(context.engineIn("errors", "systemErrorToErrorInstance")).Return {
        return createErrorInstance(context, self.borrowedInput());
    }

    fn borrowedInput(self: *const Self) Init {
        var input: Init = .{ .errno = self.error_number, .message = "", .fd = self.fd, .port = self.port };
        inline for (byte_fields) |name| @field(input, name) = @field(self, name).slice();
        return input;
    }

    pub fn createErrorInstance(context: anytype, input: Init) @TypeOf(context.engineIn("errors", "systemErrorToErrorInstance")).Return {
        const operation = context.engineIn("errors", "systemErrorToErrorInstance");
        var strings: [byte_fields.len]DOMString = @splat(DOMString.empty());
        defer for (&strings) |*text| text.deinit();
        var args: @TypeOf(operation).Args = undefined;
        inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "errorNumber")) {
                @field(args, name) = input.errno;
            } else if (comptime std.mem.eql(u8, name, "fd") or std.mem.eql(u8, name, "port")) {
                @field(args, name) = @field(input, name);
            } else {
                const index = comptime for (byte_fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field, name)) break i;
                } else @compileError("system error engine argument has no owned text field");
                strings[index] = try DOMString.fromUTF8(@field(input, name));
                @field(args, name) = strings[index].operand();
            }
        }
        return operation.call(args);
    }

    pub fn clone(self: *const Self) bun.OOM!Self {
        return init(self.borrowedInput());
    }

    pub fn deinit(self: *Self) void {
        inline for (byte_fields) |name| @field(self, name).deinit();
    }
};

pub fn ScopedLease(comptime Element: type) type {
    return ScopedLeaseType(Element, false);
}

pub fn ScopedMutableLease(comptime Element: type) type {
    return ScopedLeaseType(Element, true);
}

fn ScopedLeaseType(comptime Element: type, comptime mutable: bool) type {
    if (Element != u8) @compileError("binding byte leases require u8 elements");
    const Result_ = struct {
        handle: *const wire.BindByteLeaseHandle,
        token: ViewToken,

        const Self = @This();

        fn init(
            handle: ?*const wire.BindByteLeaseHandle,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            if (token.globalObject() != global) @panic("binding byte lease has the wrong call realm");
            return .{
                .handle = handle orelse @panic("binding scoped byte lease is null"),
                .token = token,
            };
        }

        pub fn length(self: Self) usize {
            return self.raw().len;
        }

        pub fn at(self: Self, index: usize) ?u8 {
            const bytes = self.raw();
            return if (index < bytes.len) bytes[index] else null;
        }

        pub const read = ByteReads(Self).read;

        pub const copy = ByteReads(Self).copy;

        pub fn toOwned(self: Self) bun.OOM!OwnedLeaseType(Element, mutable) {
            self.token.requireActive();
            const cloned = wire.bun_bindgen_byte_lease_clone(self.handle);
            return OwnedLeaseType(Element, mutable).adoptWire(cloned orelse
                return error.OutOfMemory);
        }

        pub fn source(self: Self) AnyResult {
            return AnyResult.initInline(
                self.rawSource(),
                self.token.globalObject(),
                self.token,
                .any,
            );
        }

        fn rawSource(self: Self) jsc.JSValue {
            self.token.requireActive();
            var encoded: i64 = undefined;
            wire.bun_bindgen_byte_lease_source(self.handle, &encoded);
            return @fromBackingInt(encoded);
        }

        pub fn elementSize(self: Self) usize {
            self.token.requireActive();
            return wire.bun_bindgen_byte_lease_element_size(self.handle);
        }

        pub const unsafePtr = ByteReads(Self).unsafePtr;

        pub fn unsafeMutPtr(self: Self, comptime reason: []const u8) []u8 {
            if (!mutable) @compileError("a read-only byte lease cannot expose mutable bytes");
            if (reason.len == 0) @compileError("unsafeMutPtr requires a non-empty lifetime reason");
            self.token.requireActive();
            return mutableByteLeaseSlice(@constCast(self.handle));
        }

        fn raw(self: Self) []const u8 {
            self.token.requireActive();
            return byteLeaseSlice(self.handle);
        }
    };
    return Result_;
}

pub fn OwnedLease(comptime Element: type) type {
    return OwnedLeaseType(Element, false);
}

pub fn OwnedMutableLease(comptime Element: type) type {
    return OwnedLeaseType(Element, true);
}

fn OwnedLeaseType(comptime Element: type, comptime mutable: bool) type {
    if (Element != u8) @compileError("binding byte leases require u8 elements");
    const Result_ = struct {
        handle: ?*wire.BindByteLeaseHandle,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();

        pub fn clone(self: *const Self) bun.OOM!Self {
            return adoptWire(wire.bun_bindgen_byte_lease_clone(self.requireHandle()) orelse
                return error.OutOfMemory);
        }

        pub fn take(self: *Self) Self {
            return .{ .handle = self.takeWire() };
        }

        pub fn length(self: *const Self) usize {
            return self.raw().len;
        }

        pub const read = ByteReads(*const Self).read;

        pub fn write(self: *const Self, offset: usize, source: []const u8) bool {
            if (!mutable) @compileError("a read-only byte lease cannot be mutated");
            const bytes = mutableByteLeaseSlice(self.requireHandle());
            if (offset > bytes.len or source.len > bytes.len - offset) return false;
            @memmove(bytes[offset..][0..source.len], source);
            return true;
        }

        pub fn release(self: *Self) void {
            wire.bun_bindgen_byte_lease_release(self.takeWire());
        }

        pub const deinit = release;

        pub const unsafePtr = ByteReads(*const Self).unsafePtr;

        pub fn unsafeMutPtr(self: *const Self, comptime reason: []const u8) []u8 {
            if (!mutable) @compileError("a read-only byte lease cannot expose mutable bytes");
            if (reason.len == 0) @compileError("unsafeMutPtr requires a non-empty lifetime reason");
            return mutableByteLeaseSlice(self.requireHandle());
        }

        fn adoptWire(handle: ?*wire.BindByteLeaseHandle) Self {
            return .{ .handle = handle orelse @panic("binding owned byte lease transfer is null") };
        }

        fn takeWire(self: *Self) *wire.BindByteLeaseHandle {
            const handle = self.requireHandle();
            self.handle = null;
            return handle;
        }

        fn raw(self: *const Self) []const u8 {
            return byteLeaseSlice(self.requireHandle());
        }

        fn requireHandle(self: *const Self) *wire.BindByteLeaseHandle {
            return self.handle orelse @panic("binding owned byte lease was moved or released");
        }
    };
    return Result_;
}

fn byteLeaseSlice(handle: *const wire.BindByteLeaseHandle) []const u8 {
    var length: usize = 0;
    const ptr = wire.bun_bindgen_byte_lease_data(handle, &length);
    if (length == 0) return &.{};
    if (ptr == null) @panic("binding byte lease has a null data pointer");
    return @as([*]const u8, @ptrCast(ptr))[0..length];
}

fn mutableByteLeaseSlice(handle: *wire.BindByteLeaseHandle) []u8 {
    var length: usize = 0;
    const ptr = wire.bun_bindgen_byte_lease_mutable_data(handle, &length);
    if (length == 0) return &.{};
    if (ptr == null) @panic("binding mutable byte lease has a null data pointer");
    return @as([*]u8, @ptrCast(ptr))[0..length];
}

fn readJSValue(handle: *const wire.BindJSValueHandle) jsc.JSValue {
    var encoded: i64 = undefined;
    wire.bun_bindgen_js_value_read(handle, &encoded);
    return @fromBackingInt(encoded);
}

const AnyViewHandle = opaque {};

pub const AnyView = struct {
    handle: *const AnyViewHandle,
    token: ViewToken,

    const Self = @This();

    fn init(
        handle: ?*const wire.BindJSValueHandle,
        global: *jsc.JSGlobalObject,
        token: ViewToken,
    ) Self {
        if (token.globalObject() != global) @panic("binding JS value view has the wrong call realm");
        return .{
            .handle = @ptrCast(handle orelse @panic("binding JS value view is null")),
            .token = token,
        };
    }

    fn rawValue(self: Self) jsc.JSValue {
        self.token.requireActive();
        return readJSValue(@ptrCast(self.handle));
    }

    pub fn operand(self: Self, context: anytype) AnyOperand {
        self.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "binding any operand has an unrelated scope");
        return AnyOperand.init(self.rawValue(), self.token);
    }

    pub fn toRoot(self: Self) bun.JSError!Root {
        return Root.create(self.rawValue(), self.engineGlobal());
    }

    pub fn toResult(self: Self) AnyResult {
        self.token.requireActive();
        return AnyResult.initBorrowed(@ptrCast(self.handle), self.engineGlobal(), self.token, .any);
    }

    fn encodedForEngine(self: Self, global: *jsc.JSGlobalObject, token: ViewToken) i64 {
        self.token.requireSameCall(token, global, "binding JS value used by an unrelated engine operation");
        return @backingInt(readJSValue(@ptrCast(self.handle)));
    }

    fn engineGlobal(self: Self) *jsc.JSGlobalObject {
        return self.token.globalObject();
    }
};

pub fn BrandedValueView(comptime ValueSchema: type) type {
    return BrandedValueViewType(ValueSchema);
}

pub fn BrandedValueResult(comptime ValueSchema: type) type {
    return BrandedValueResultType(ValueSchema);
}

fn BrandedValueViewType(comptime Type: type) type {
    if (comptime Type.kind != .branded_value) @compileError("branded value views require a branded value schema");
    if (Type.is_promise_reaction_context) return PromiseReactionContextViewType(Type);
    const Handle = opaque {};
    return struct {
        handle: *const Handle,
        token: ViewToken,

        pub const SemanticType = Type;
        pub const bindgen_branded_value_view = {};

        const Self = @This();

        fn init(
            handle: ?*const wire.BindJSValueHandle,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            if (token.globalObject() != global) @panic("binding branded value view has the wrong call realm");
            return .{
                .handle = @ptrCast(handle orelse @panic("binding branded value view is null")),
                .token = token,
            };
        }

        fn rawValue(self: Self) jsc.JSValue {
            self.token.requireActive();
            return readJSValue(@ptrCast(self.handle));
        }

        pub fn operand(self: Self, context: anytype) ValueOperand(.branded, Type.Brand) {
            self.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "binding branded operand has an unrelated scope");
            return ValueOperand(.branded, Type.Brand).init(self.rawValue(), self.token);
        }

        pub fn toRoot(self: Self) bun.JSError!Root {
            return Root.create(self.rawValue(), self.engineGlobal());
        }

        pub fn toOwned(self: Self) bun.JSError!OwnedBrandedValueType(Type) {
            return .{
                .root = try BrandedRoot(Type).create(self.rawValue(), self.engineGlobal()),
            };
        }

        pub fn toWeak(self: Self) bun.JSError!WeakValueHandle(Type) {
            return WeakValueHandle(Type).init(self.rawValue(), self.engineGlobal());
        }

        pub fn toResult(self: Self) BrandedValueResultType(Type) {
            self.token.requireActive();
            return BrandedValueResultType(Type).initBorrowed(
                @ptrCast(self.handle),
                self.engineGlobal(),
                self.token,
                .branded,
            );
        }

        fn encodedForEngine(self: Self, global: *jsc.JSGlobalObject, token: ViewToken) i64 {
            self.token.requireSameCall(token, global, "binding branded value used by an unrelated engine operation");
            return @backingInt(readJSValue(@ptrCast(self.handle)));
        }

        fn engineGlobal(self: Self) *jsc.JSGlobalObject {
            return self.token.globalObject();
        }
    };
}

fn PromiseReactionContextViewType(comptime Type: type) type {
    const Handle = opaque {};
    return struct {
        handle: *const Handle,
        token: ViewToken,

        pub const SemanticType = Type;
        pub const bindgen_branded_value_view = {};

        const Self = @This();

        fn init(
            handle: ?*const wire.BindJSValueHandle,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            if (token.globalObject() != global) @panic("promise reaction context has the wrong call realm");
            return .{
                .handle = @ptrCast(handle orelse @panic("promise reaction context is null")),
                .token = token,
            };
        }

        pub fn operand(self: Self, context: anytype) ValueOperand(.branded, Type.Brand) {
            const token = context.viewToken();
            return ValueOperand(.branded, Type.Brand).init(@fromBackingInt(self.encodedForEngine(context.viewToken().globalObject(), token)), token);
        }

        fn encodedForEngine(self: Self, global: *jsc.JSGlobalObject, token: ViewToken) i64 {
            self.token.requireSameCall(token, global, "promise reaction context used by an unrelated engine operation");
            return @backingInt(readJSValue(@ptrCast(self.handle)));
        }

        fn engineGlobal(self: Self) *jsc.JSGlobalObject {
            return self.token.globalObject();
        }
    };
}

pub const EngineValueView = struct {
    value: OperandValue,
    token: ViewToken,

    const Self = @This();

    fn init(
        handle: ?*const wire.BindJSValueHandle,
        global: *jsc.JSGlobalObject,
        token: ViewToken,
    ) Self {
        return initInline(readJSValue(handle orelse @panic("binding engine value view is null")), global, token);
    }

    fn initInline(value: jsc.JSValue, global: *jsc.JSGlobalObject, token: ViewToken) Self {
        token.requireActive();
        if (token.globalObject() != global) @panic("binding engine value view has the wrong call realm");
        if (value == .zero) @panic("binding engine view cannot contain an empty value");
        return .{ .value = @fromBackingInt(@backingInt(value)), .token = token };
    }

    fn rawValue(self: Self) jsc.JSValue {
        self.token.requireActive();
        return @fromBackingInt(@backingInt(self.value));
    }

    pub fn operand(self: Self, context: anytype) EngineOperand {
        self.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "binding engine operand has an unrelated scope");
        return EngineOperand.init(self.rawValue(), self.token);
    }

    pub fn toRoot(self: Self) bun.JSError!EngineRoot {
        return EngineRoot.create(self.rawValue(), self.engineGlobal());
    }

    pub fn toResult(self: Self) EngineValueResult {
        self.token.requireActive();
        return EngineValueResult.initInline(self.rawValue(), self.engineGlobal(), self.token, .engine);
    }

    fn encodedForEngine(self: Self, global: *jsc.JSGlobalObject, token: ViewToken) i64 {
        self.token.requireSameCall(token, global, "binding engine value used by an unrelated engine operation");
        return @backingInt(self.value);
    }

    fn engineGlobal(self: Self) *jsc.JSGlobalObject {
        return self.token.globalObject();
    }
};

pub inline fn keepAlive(value: anytype) void {
    const T = @TypeOf(value);
    if (comptime T == jsc.JSValue) {
        value.ensureStillAlive();
        return;
    }
    if (comptime T == AnyView) {
        value.rawValue().ensureStillAlive();
        return;
    }
    if (comptime T == *Root or T == *const Root or T == *EngineRoot or T == *const EngineRoot) {
        value.get().ensureStillAlive();
        return;
    }
    @compileError("keepAlive requires a JSValue, AnyView, Root, or EngineRoot pointer");
}

pub const AnyRestView = struct {
    handle: ?*const wire.BindJSValueSliceHandle,
    len: usize,
    token: ViewToken,

    const Self = @This();

    fn init(slice: wire.BindJSValueSlice, global: *jsc.JSGlobalObject, token: ViewToken) Self {
        if (slice.len == 0) {
            if (slice.handle != null) @panic("binding JS rest view is not in canonical empty form");
        } else if (slice.handle == null) {
            @panic("binding JS rest view has a null handle");
        }
        if (token.globalObject() != global) @panic("binding JS rest view has the wrong call realm");
        return .{ .handle = slice.handle, .len = slice.len, .token = token };
    }

    pub fn length(self: Self) usize {
        self.token.requireActive();
        return self.len;
    }

    pub fn at(self: Self, index: usize) ?AnyView {
        self.token.requireActive();
        if (index >= self.len) return null;
        return AnyView.init(
            wire.bun_bindgen_js_value_slice_at(self.handle.?, index),
            self.engineGlobal(),
            self.token,
        );
    }

    fn engineGlobal(self: Self) *jsc.JSGlobalObject {
        return self.token.globalObject();
    }
};

/// A strong reference that keeps an opaque JavaScript value alive until
/// released. Curated engine access requires the distinct `EngineRoot` type.
const RootAccess = enum {
    any,
    engine,
    branded,
};

pub const Root = ValueRoot(.any);
pub const EngineRoot = ValueRoot(.engine);

fn RootOperations(comptime Owner: type) type {
    return struct {
        fn create(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!Owner {
            if (value == .zero) @panic("binding root cannot hold an empty JS value");
            return .{ .impl = try .init(global, value) };
        }

        fn requireHandle(self: *const Owner) RootHandle {
            return self.impl orelse @panic("binding root was moved or released");
        }

        fn takeHandle(self: *Owner) RootHandle {
            const impl = requireHandle(self);
            self.impl = null;
            return impl;
        }

        fn clone(self: *const Owner) Owner {
            return .{ .impl = requireHandle(self).clone() };
        }

        const get = rawValue;

        fn rawValue(self: *const Owner) jsc.JSValue {
            const impl = requireHandle(self);
            return impl.get(impl.globalObject());
        }

        fn globalObject(self: *const Owner) *jsc.JSGlobalObject {
            return requireHandle(self).globalObject();
        }

        fn requireCurrentVM(self: *const Owner, global: *jsc.JSGlobalObject) void {
            if (!requireHandle(self).belongsToCurrentVM(global)) @panic("binding root used from a different VM");
        }

        fn deinit(self: *Owner) void {
            const impl = bun.take(&self.impl) orelse return;
            impl.deinit();
        }

        fn take(self: *Owner) Owner {
            return .{ .impl = takeHandle(self) };
        }

        fn takeAnyRoot(self: *Owner) Root {
            return .{ .impl = takeHandle(self) };
        }

        fn view(self: *const Owner, context: anytype, comptime View: type) bun.OOM!View {
            context.requireActive();
            const token = context.viewToken();
            const global = token.globalObject();
            return View.init(try viewWire(self, global, token), global, token);
        }

        fn operand(self: *const Owner, context: anytype, comptime Operand: type) Operand {
            const token = context.viewToken();
            requireCurrentVM(self, token.globalObject());
            return Operand.init(rawValue(self), token);
        }

        fn viewWire(self: *const Owner, global: *jsc.JSGlobalObject, token: ViewToken) bun.OOM!*const wire.BindJSValueHandle {
            requireCurrentVM(self, global);
            return retainCallScopedValue(requireHandle(self), global, token);
        }

        fn borrowRootWire(self: *const Owner) *wire.BindRootHandle {
            return requireHandle(self).borrowWire();
        }

        fn borrowWire(self: *const Owner) *const wire.BindJSValueHandle {
            return requireHandle(self).borrowValue();
        }

        fn takeWire(self: *Owner) *wire.BindRootHandle {
            return takeHandle(self).takeWire();
        }
    };
}

fn RootedOperations(comptime Owner: type) type {
    return struct {
        fn clone(owner: *const Owner) Owner {
            return .{ .root = owner.root.clone() };
        }

        fn take(owner: *Owner) Owner {
            return .{ .root = owner.root.take() };
        }

        fn deinit(owner: *Owner) void {
            owner.root.deinit();
        }

        fn takeAnyRoot(owner: *Owner) Root {
            return owner.root.takeAnyRoot();
        }
    };
}

fn OptionalRootOperations(comptime Owner: type) type {
    return struct {
        fn take(self: *Owner) Owner {
            const result = self.*;
            self.* = .empty;
            return result;
        }

        const deinit = RootOperations(Owner).deinit;

        fn get(self: *const Owner) ?jsc.JSValue {
            const impl = self.impl orelse return null;
            return impl.get(impl.globalObject());
        }

        fn has(self: *const Owner) bool {
            return get(self) != null;
        }

        fn view(self: *const Owner, context: anytype, comptime View: type) bun.OOM!?View {
            if (self.impl == null) return null;
            return try RootOperations(Owner).view(self, context, View);
        }

        fn operand(self: *const Owner, context: anytype, comptime Operand: type) ?Operand {
            const impl = self.impl orelse return null;
            const token = context.viewToken();
            const global = token.globalObject();
            if (!impl.belongsToCurrentVM(global)) @panic("binding optional root operand has a different VM");
            return Operand.init(impl.get(global), token);
        }
    };
}

fn ValueRoot(comptime access: RootAccess) type {
    return struct {
        impl: ?RootHandle,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();
        const Operand = ValueOperand(access, void);
        const Result = ValueResultType(access, void);

        const create = RootOperations(Self).create;

        pub fn initUndefined(context: anytype) bun.JSError!Self {
            context.requireActive();
            return create(.js_undefined, context.viewToken().globalObject());
        }

        pub fn initNull(context: anytype) bun.JSError!Self {
            context.requireActive();
            return create(.null, context.viewToken().globalObject());
        }

        pub fn throwException(self: *const Self, context: anytype) bun.JSError {
            context.requireActive();
            const global = context.viewToken().globalObject();
            self.requireCurrentVM(global);
            return global.throwValue(self.rawValue());
        }

        pub const clone = RootOperations(Self).clone;

        const get = RootOperations(Self).get;

        const globalObject = RootOperations(Self).globalObject;

        const rawValue = RootOperations(Self).rawValue;

        pub fn operand(self: *const Self, context: anytype) Operand {
            return RootOperations(Self).operand(self, context, Operand);
        }

        pub fn view(self: *const Self, context: anytype) bun.OOM!AnyView {
            return RootOperations(Self).view(self, context, AnyView);
        }

        pub fn engineView(self: *const Self, context: anytype) bun.OOM!EngineValueView {
            if (access != .engine) @compileError("opaque roots do not grant engine access");
            return RootOperations(Self).view(self, context, EngineValueView);
        }

        pub fn toAnyRoot(self: *const Self) Root {
            const global = self.globalObject();
            self.requireCurrentVM(global);
            return .{ .impl = self.impl.?.clone() };
        }

        pub const takeAnyRoot = RootOperations(Self).takeAnyRoot;

        pub const deinit = RootOperations(Self).deinit;

        /// Transfers ownership, leaving the source empty.
        pub const take = RootOperations(Self).take;

        const requireCurrentVM = RootOperations(Self).requireCurrentVM;

        pub fn takeOptional(self: *Self) Optional {
            const result = self.take();
            return .{ .impl = result.impl };
        }

        pub const Optional = struct {
            impl: ?RootHandle,

            pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
            pub const empty: Optional = .{ .impl = null };

            fn create(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!Optional {
                return if (value != .zero)
                    .{ .impl = try .init(global, value) }
                else
                    .empty;
            }

            pub const deinit = OptionalRootOperations(Optional).deinit;

            pub const take = OptionalRootOperations(Optional).take;

            pub fn clone(self: *const Optional) Optional {
                return .{
                    .impl = if (self.impl) |impl| impl.clone() else null,
                };
            }

            pub fn cloneRoot(self: *const Optional) ?Self {
                const impl = self.impl orelse return null;
                return .{
                    .impl = impl.clone(),
                };
            }

            pub const clear = Optional.deinit;

            fn requireCurrentVM(self: *const Optional, global: *jsc.JSGlobalObject) void {
                const impl = self.impl orelse return;
                if (!impl.belongsToCurrentVM(global)) {
                    @panic("binding optional root used from a different VM");
                }
            }

            const get = OptionalRootOperations(Optional).get;

            pub const has = OptionalRootOperations(Optional).has;

            pub fn operand(self: *const Optional, context: anytype) ?Operand {
                return OptionalRootOperations(Optional).operand(self, context, Operand);
            }

            pub fn view(self: *const Optional, context: anytype) bun.OOM!?AnyView {
                return OptionalRootOperations(Optional).view(self, context, AnyView);
            }

            pub fn engineView(self: *const Optional, context: anytype) bun.OOM!?EngineValueView {
                if (access != .engine) @compileError("opaque roots do not grant engine access");
                return OptionalRootOperations(Optional).view(self, context, EngineValueView);
            }

            pub fn toResult(self: *const Optional, context: anytype) ?Result {
                const impl = self.impl orelse return null;
                context.requireActive();
                const global = context.viewToken().globalObject();
                if (!impl.belongsToCurrentVM(global)) {
                    @panic("binding optional root returned from a different VM");
                }
                return Result.initInline(impl.get(impl.globalObject()), global, context.viewToken(), access);
            }

            pub fn takeRoot(self: *Optional) ?Self {
                const impl = self.impl orelse return null;
                self.* = .empty;
                return .{
                    .impl = impl,
                };
            }

            fn setValue(
                self: *Optional,
                global: *jsc.JSGlobalObject,
                value: jsc.JSValue,
            ) bun.JSError!void {
                try RootHandle.replaceValue(&self.impl, global, value);
            }

            pub fn set(self: *Optional, value: Operand) bun.JSError!void {
                value.token.requireActive();
                const global = value.token.globalObject();
                try self.setValue(global, value.rawValueForEngine(global, value.token));
            }

            pub fn setRoot(self: *Optional, value: *const Self) void {
                const source = value.impl orelse @panic("binding root was already consumed");
                RootHandle.replaceRoot(&self.impl, source);
            }
        };
    };
}

pub const RetainedArguments = struct {
    roots: []Root = &.{},
    allocator: std.mem.Allocator = bun.default_allocator,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
    pub const empty: RetainedArguments = .{};

    const Self = @This();

    pub const Builder = struct {
        owner: Self = .empty,
        initialized: usize = 0,

        pub fn init(allocator: std.mem.Allocator, length: usize) bun.OOM!Builder {
            return .{ .owner = .adoptOwnedSlice(try allocator.alloc(Root, length), allocator) };
        }

        pub fn appendOwned(builder: *Builder, root: Root) void {
            if (builder.initialized == builder.owner.roots.len) @panic("retained arguments builder is full");
            builder.owner.roots[builder.initialized] = root;
            builder.initialized += 1;
        }

        pub fn finish(builder: *Builder) Self {
            if (builder.initialized != builder.owner.roots.len) @panic("retained arguments builder is incomplete");
            builder.initialized = 0;
            return builder.owner.take();
        }

        pub fn deinit(builder: *Builder) void {
            const pending = builder.*;
            builder.* = .{};
            pending.owner.release(pending.initialized);
        }
    };

    pub fn adoptOwnedSlice(roots: []Root, allocator: std.mem.Allocator) Self {
        return .{ .roots = roots, .allocator = allocator };
    }

    pub fn values(self: *const Self) []const Root {
        return self.roots;
    }

    pub fn take(self: *Self) Self {
        const result = self.*;
        self.* = .empty;
        return result;
    }

    pub fn deinit(self: *Self) void {
        const pending = self.take();
        pending.release(pending.roots.len);
    }

    fn release(self: Self, initialized: usize) void {
        for (self.roots[0..initialized]) |*root| root.deinit();
        self.allocator.free(self.roots);
    }
};

fn RetainedValueRoot(comptime Identity: type) type {
    return struct {
        impl: ?RootHandle,

        pub const bindgen_typed_root = Identity;
        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();

        const create = RootOperations(Self).create;

        pub const clone = RootOperations(Self).clone;

        const get = RootOperations(Self).get;

        const globalObject = RootOperations(Self).globalObject;

        const rawValue = RootOperations(Self).rawValue;

        const viewWire = RootOperations(Self).viewWire;

        pub const deinit = RootOperations(Self).deinit;

        const requireHandle = RootOperations(Self).requireHandle;

        const takeHandle = RootOperations(Self).takeHandle;

        pub const take = RootOperations(Self).take;

        const takeAnyRoot = RootOperations(Self).takeAnyRoot;

        const borrowRootWire = RootOperations(Self).borrowRootWire;

        const borrowWire = RootOperations(Self).borrowWire;

        const takeWire = RootOperations(Self).takeWire;

        const requireCurrentVM = RootOperations(Self).requireCurrentVM;

        fn adoptWire(handle: ?*wire.BindRootHandle, global: *jsc.JSGlobalObject) bun.JSError!Self {
            var result: Self = .{
                .impl = RootHandle.adoptWire(handle),
            };
            errdefer result.deinit();
            result.requireCurrentVM(global);
            const impl = result.impl.?;
            try RootHandle.replaceValue(&result.impl, global, impl.get(impl.globalObject()));
            return result;
        }
    };
}

fn BrandedRoot(comptime Type: type) type {
    return RetainedValueRoot(Type);
}

fn CallbackRoot(comptime Type: type) type {
    return RetainedValueRoot(Type);
}

fn ClassRootIdentity(comptime class_id: usize) type {
    return struct {
        pub const bindgen_class_root_id = class_id;
    };
}

fn ClassRootById(comptime class_id: usize) type {
    return RetainedValueRoot(ClassRootIdentity(class_id));
}

fn ClassSetRootIdentity(comptime class_ids: anytype) type {
    return struct {
        pub const bindgen_class_root_ids = class_ids;
    };
}

fn ClassSetRoot(comptime class_ids: anytype) type {
    return RetainedValueRoot(ClassSetRootIdentity(class_ids));
}

fn ValueResultType(comptime expected_access: RootAccess, comptime SemanticType: type) type {
    if ((expected_access == .branded) != (SemanticType != void))
        @compileError("only branded JS value results carry a semantic type");
    if (comptime SemanticType != void) {
        if (SemanticType.kind != .branded_value)
            @compileError("branded JS value results require a branded semantic type");
    }
    const StoredRoot = switch (expected_access) {
        .any => Root,
        .engine => EngineRoot,
        .branded => BrandedRoot(SemanticType),
    };
    return struct {
        value: OperandValue,
        token: ViewToken,

        pub const bindgen_value_result = {};
        pub const bindgen_value_access = expected_access;
        pub const bindgen_semantic_type = SemanticType;

        const Self = @This();

        fn initBorrowed(handle: *const wire.BindJSValueHandle, global: *jsc.JSGlobalObject, token: ViewToken, access: RootAccess) Self {
            token.requireActive();
            return initInline(readJSValue(handle), global, token, access);
        }

        fn initInline(value: jsc.JSValue, global: *jsc.JSGlobalObject, token: ViewToken, access: RootAccess) Self {
            if (value == .zero) @panic("binding value result cannot hold an empty JS value");
            if (expected_access != .any and access != expected_access)
                @panic("binding value result has incompatible access provenance");
            if (token.globalObject() != global) @panic("binding value result has the wrong call realm");
            return .{ .value = @fromBackingInt(@backingInt(value)), .token = token };
        }

        pub fn fromRoot(root: *const StoredRoot, context: anytype) Self {
            if (comptime expected_access == .branded)
                @compileError("a generic root does not preserve a branded value's semantic identity");
            const token = context.viewToken();
            const global = token.globalObject();
            root.requireCurrentVM(global);
            return initInline(root.rawValue(), global, token, expected_access);
        }

        pub fn fromOwnedRoot(root: *StoredRoot, context: anytype) Self {
            const result = fromRoot(root, context);
            root.deinit();
            return result;
        }

        pub fn initUndefined(context: anytype) Self {
            if (expected_access == .branded) @compileError("a branded result cannot be undefined");
            const token = context.viewToken();
            return initInline(.js_undefined, token.globalObject(), token, expected_access);
        }

        pub fn initNull(context: anytype) Self {
            if (expected_access == .branded) @compileError("a branded result cannot be null");
            const token = context.viewToken();
            return initInline(.null, token.globalObject(), token, expected_access);
        }

        fn toStoredRoot(result: *const Self) bun.JSError!StoredRoot {
            return StoredRoot.create(result.rawValue(), result.token.globalObject());
        }

        pub fn toRoot(result: *const Self) bun.JSError!(if (expected_access == .engine) EngineRoot else Root) {
            if (comptime expected_access == .branded)
                return Root.create(result.rawValue(), result.token.globalObject());
            return result.toStoredRoot();
        }

        pub fn throwException(result: *const Self, context: anytype) bun.JSError {
            const token = context.viewToken();
            const global = token.globalObject();
            return global.throwValue(result.rawValueForEngine(global, token));
        }

        pub fn asAny(result: *const Self, context: anytype) AnyResult {
            const token = context.viewToken();
            const global = token.globalObject();
            return AnyResult.initInline(result.rawValueForEngine(global, token), global, token, .any);
        }

        pub fn eraseBrandToEngineRoot(result: *const Self) bun.JSError!EngineRoot {
            if (comptime expected_access != .branded)
                @compileError("only a branded binding result can erase its brand into an engine root");
            return EngineRoot.create(result.rawValue(), result.token.globalObject());
        }

        pub fn toOwned(result: *const Self) if (expected_access == .branded) bun.JSError!OwnedBrandedValueType(SemanticType) else void {
            if (comptime expected_access != .branded)
                @compileError("only branded values retain semantic identity when owned");
            return .{ .root = try result.toStoredRoot() };
        }

        pub fn operand(result: *const Self, context: anytype) ValueOperand(expected_access, if (expected_access == .branded) SemanticType.Brand else void) {
            const token = context.viewToken();
            return .init(result.rawValueForEngine(token.globalObject(), token), token);
        }

        pub fn view(result: *const Self, context: anytype) bun.JSError!switch (expected_access) {
            .any => AnyView,
            .engine => EngineValueView,
            .branded => BrandedValueViewType(SemanticType),
        } {
            const token = context.viewToken();
            const global = token.globalObject();
            const handle = try retainCallScopedValue(result.rawValueForEngine(global, token), global, token);
            return switch (expected_access) {
                .any => AnyView.init(handle, global, token),
                .engine => EngineValueView.init(handle, global, token),
                .branded => BrandedValueViewType(SemanticType).init(handle, global, token),
            };
        }

        fn encodedForEngine(result: *const Self, global: *jsc.JSGlobalObject, token: ViewToken) i64 {
            return @backingInt(result.rawValueForEngine(global, token));
        }

        fn rawValue(result: *const Self) jsc.JSValue {
            result.token.requireActive();
            if (@backingInt(result.value) == 0) @panic("binding value result was already consumed");
            return @fromBackingInt(@backingInt(result.value));
        }

        fn takeEncoded(result: *Self) i64 {
            const value = result.rawValue();
            result.deinit();
            return @backingInt(value);
        }

        pub fn deinit(result: *Self) void {
            result.value = @fromBackingInt(0);
        }

        fn rawValueForEngine(result: *const Self, global: *jsc.JSGlobalObject, token: ViewToken) jsc.JSValue {
            result.token.requireSameCall(token, global, "binding value result used by an unrelated engine operation");
            return result.rawValue();
        }
    };
}

pub const AnyResult = ValueResultType(.any, void);
pub const EngineValueResult = ValueResultType(.engine, void);
pub const PromiseResult = ValueResultType(.branded, PromiseSemanticType);

fn requirePromiseValue(value: jsc.JSValue, global: *jsc.JSGlobalObject) void {
    if (value == .zero) @panic("binding promise root requires a promise");
    var scope: FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    if (scope.borrowEngineValue(value).jsType() != .JSPromise) @panic("binding promise root requires a promise");
}

pub const PromiseRoot = struct {
    impl: ?RootHandle,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

    const Self = @This();

    fn create(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!Self {
        requirePromiseValue(value, global);
        return .{ .impl = try .init(global, value) };
    }

    const get = RootOperations(Self).get;

    const globalObject = RootOperations(Self).globalObject;

    pub fn operand(self: *const Self, context: anytype) ValueOperand(.branded, PromiseSemanticType.Brand) {
        return RootOperations(Self).operand(self, context, ValueOperand(.branded, PromiseSemanticType.Brand));
    }

    pub fn view(self: *const Self, context: anytype) bun.OOM!BrandedValueViewType(PromiseSemanticType) {
        return RootOperations(Self).view(self, context, BrandedValueViewType(PromiseSemanticType));
    }

    pub const deinit = RootOperations(Self).deinit;

    const requireCurrentVM = RootOperations(Self).requireCurrentVM;

    pub const Optional = struct {
        impl: ?RootHandle = null,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const empty: @This() = .{};

        const OptionalSelf = @This();

        fn create(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!OptionalSelf {
            if (value == .zero) return .empty;
            requirePromiseValue(value, global);
            return .{ .impl = try .init(global, value) };
        }

        pub const has = OptionalRootOperations(OptionalSelf).has;

        pub const take = OptionalRootOperations(OptionalSelf).take;

        pub const clear = OptionalSelf.deinit;

        pub const deinit = OptionalRootOperations(OptionalSelf).deinit;

        const get = OptionalRootOperations(OptionalSelf).get;

        fn trySwap(self: *OptionalSelf) ?jsc.JSValue {
            const impl = self.impl orelse return null;
            const value = impl.get(impl.globalObject());
            self.clear();
            return value;
        }

        fn setValue(self: *OptionalSelf, global: *jsc.JSGlobalObject, value: jsc.JSValue) bun.JSError!void {
            if (value != .zero) requirePromiseValue(value, global);
            try RootHandle.replaceValue(&self.impl, global, value);
        }

        pub fn set(self: *OptionalSelf, value: PromiseOperand) bun.JSError!void {
            value.token.requireActive();
            const global = value.token.globalObject();
            try self.setValue(global, value.rawValueForEngine(global, value.token));
        }

        pub fn operand(self: *const OptionalSelf, context: anytype) ?ValueOperand(.branded, PromiseSemanticType.Brand) {
            return OptionalRootOperations(OptionalSelf).operand(self, context, ValueOperand(.branded, PromiseSemanticType.Brand));
        }

        pub fn view(
            self: *const OptionalSelf,
            context: anytype,
        ) bun.OOM!?BrandedValueViewType(PromiseSemanticType) {
            return OptionalRootOperations(OptionalSelf).view(self, context, BrandedValueViewType(PromiseSemanticType));
        }

        pub fn toPromiseResult(self: *const OptionalSelf, context: anytype) bun.JSError!?PromiseResult {
            return self.toPromiseResultAs(context, PromiseResult);
        }

        fn toPromiseResultAs(
            self: *const OptionalSelf,
            context: anytype,
            comptime Result: type,
        ) bun.JSError!?Result {
            if (!@hasDecl(Result, "bindgen_value_result") or
                !@hasDecl(Result, "bindgen_value_access") or
                !@hasDecl(Result, "bindgen_semantic_type") or
                Result.bindgen_value_access != .branded)
            {
                @compileError("promise roots require a branded binding value result");
            }
            const SemanticType = Result.bindgen_semantic_type;
            if (comptime SemanticType.PromiseValueType == void) {
                @compileError("promise roots can only produce declared promise results");
            }
            context.requireActive();
            const global = context.viewToken().globalObject();
            const impl = self.impl orelse return null;
            if (!impl.belongsToCurrentVM(global)) {
                @panic("binding promise root returned from a different VM");
            }
            const value = self.get() orelse return null;
            return Result.initInline(value, global, context.viewToken(), .branded);
        }
    };
};

fn declaredPromiseSemanticType(comptime Result: type) type {
    if (!@hasDecl(Result, "bindgen_semantic_type")) @compileError("a declared promise result requires a generated result type");
    const SemanticType = Result.bindgen_semantic_type;
    if (SemanticType.PromiseValueType == void or Result != ResultType(SemanticType))
        @compileError("a declared promise result requires the exact generated promise API type");
    return SemanticType;
}

fn continuePromiseWait(global: *jsc.JSGlobalObject, cancelled: ?*const std.atomic.Value(bool)) bun.JSError!bool {
    if (global.vm().executionForbidden()) return error.JSTerminated;
    switch (global.pendingExceptionKind()) {
        .none => {},
        .other => return error.JSError,
        .termination => return error.JSTerminated,
    }
    return if (cancelled) |flag| !flag.load(.acquire) else true;
}

pub const PromiseSettlement = union(enum) {
    fulfilled: EngineValueResult,
    rejected: EngineValueResult,
};

fn waitForDeclaredPromiseSettlement(
    context: anytype,
    owned_promise: *const PromiseRoot,
    cancelled: ?*const std.atomic.Value(bool),
) bun.JSError!bool {
    const global = context.viewToken().globalObject();
    owned_promise.requireCurrentVM(global);
    context.engineIn("promises", "promiseSetHandled").call(.{ .promise = owned_promise.operand(context).asPromise() });
    const event_loop = global.bunVM().eventLoop();
    while (true) {
        if (!try continuePromiseWait(global, cancelled)) return false;
        if (context.engineIn("promises", "promiseStatus").call(.{ .promise = owned_promise.operand(context).asPromise() }) != .pending)
            return true;
        event_loop.tick();
        if (!try continuePromiseWait(global, cancelled)) return false;
        if (context.engineIn("promises", "promiseStatus").call(.{ .promise = owned_promise.operand(context).asPromise() }) == .pending)
            event_loop.autoTick();
    }
}

fn waitForDeclaredPromise(context: anytype, owned_promise: *const PromiseRoot) bun.JSError!?EngineValueResult {
    _ = try waitForDeclaredPromiseSettlement(context, owned_promise, null);
    return switch (context.engineIn("promises", "promiseStatus").call(.{ .promise = owned_promise.operand(context).asPromise() })) {
        .fulfilled => null,
        .rejected => rejected: {
            const result = (try context.engineIn("promises", "promiseResult").call(.{ .promise = owned_promise.operand(context).asPromise() })) orelse
                @panic("settled promise has no rejection reason");
            break :rejected result;
        },
        .pending => @panic("promise wait returned before settlement"),
    };
}

pub fn StrongPromise(comptime Result: type) type {
    const SemanticType = declaredPromiseSemanticType(Result);
    const Owned = OwnedBrandedValueType(SemanticType);
    return struct {
        value: ?Owned = null,

        pub const bindgen_strong_promise = SemanticType;
        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const empty: @This() = .{};

        const Self = @This();

        pub fn initFromResult(result: *const Result) bun.JSError!Self {
            return .{ .value = .{ .root = try result.toStoredRoot() } };
        }

        pub fn initFromOwned(value: *const Owned) Self {
            return .{ .value = value.clone() };
        }

        pub fn has(promise: *const Self) bool {
            return promise.value != null;
        }

        pub fn clone(promise: *const Self) Self {
            return .{ .value = if (promise.value) |*value| value.clone() else null };
        }

        fn requireValue(promise: *const Self, comptime operation: []const u8) *const Owned {
            return if (promise.value) |*value| value else @panic("empty promise handle cannot be " ++ operation);
        }

        pub fn toResult(promise: *const Self, context: anytype) Result {
            return promise.requireValue("returned").toResult(context);
        }

        pub fn operand(promise: *const Self, context: anytype) ValueOperand(.branded, SemanticType.Brand) {
            return promise.requireValue("borrowed").operand(context);
        }

        pub fn toOwned(promise: *const Self) Owned {
            const value = promise.requireValue("retained");
            value.root.requireCurrentVM(value.root.globalObject());
            return value.clone();
        }

        pub fn deinit(promise: *Self) void {
            var value = bun.take(&promise.value) orelse return;
            value.deinit();
        }
    };
}

fn BrandedValueResultType(comptime Type: type) type {
    return ValueResultType(.branded, Type);
}

pub fn OwnedBrandedValue(comptime ValueSchema: type) type {
    return OwnedBrandedValueType(ValueSchema);
}

fn OwnedBrandedValueType(comptime Type: type) type {
    if (comptime Type.kind != .branded_value or Type.is_promise_reaction_context) {
        @compileError("owned branded values require a retainable branded schema type");
    }
    return struct {
        root: BrandedRoot(Type),

        pub const SemanticType = Type;
        pub const Result = BrandedValueResultType(Type);
        pub const bindgen_owned_branded_value = {};
        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();

        pub const clone = RootedOperations(Self).clone;

        pub const take = RootedOperations(Self).take;

        pub const takeAnyRoot = RootedOperations(Self).takeAnyRoot;

        pub const deinit = RootedOperations(Self).deinit;

        pub fn storedRealm(value: *const Self) *StoredRealmHandle {
            return @ptrCast(value.root.globalObject());
        }

        pub fn initScope(value: *const Self, scope: *FocusedEngineScope) void {
            const global = value.root.globalObject();
            value.root.requireCurrentVM(global);
            scope.init(global);
        }

        pub fn operand(value: *const Self, context: anytype) ValueOperand(.branded, Type.Brand) {
            const token = context.viewToken();
            return ValueOperand(.branded, Type.Brand).init(value.rawValueForEngine(context.viewToken().globalObject(), token), token);
        }

        pub fn view(value: *const Self, context: anytype) bun.OOM!BrandedValueViewType(Type) {
            context.requireActive();
            const global = context.viewToken().globalObject();
            if (value.root.globalObject() != global) {
                @panic("owned branded value used in a different realm");
            }
            return BrandedValueViewType(Type).init(try value.root.viewWire(global, context.viewToken()), global, context.viewToken());
        }

        pub fn toResult(value: *const Self, context: anytype) Result {
            context.requireActive();
            const global = context.viewToken().globalObject();
            if (value.root.globalObject() != global) {
                @panic("owned branded value returned in a different realm");
            }
            value.root.requireCurrentVM(global);
            return Result.initInline(value.root.rawValue(), global, context.viewToken(), .branded);
        }

        pub fn takeResult(value: *Self, context: anytype) Result {
            const result = value.toResult(context);
            value.deinit();
            return result;
        }

        fn rawValueForEngine(
            value: *const Self,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) jsc.JSValue {
            token.requireActive();
            if (value.root.globalObject() != global) {
                @panic("owned branded value used in a different realm");
            }
            value.root.requireCurrentVM(global);
            return value.root.get();
        }
    };
}

const RootHandle = struct {
    resource: Resource,

    const Self = @This();
    const Resource = Return(StrongRefCreateSchema);

    fn init(global: *jsc.JSGlobalObject, value: jsc.JSValue) bun.JSError!Self {
        var scope: FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        return .{ .resource = try scope.engine(StrongRefCreateSchema).call(.{ .value = scope.borrowEngineValue(value) }) };
    }

    fn get(this: Self, global: *jsc.JSGlobalObject) jsc.JSValue {
        var scope: FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        const result = scope.engine(StrongRefGetSchema).call(.{ .reference = &this.resource });
        return result.rawValue();
    }

    fn globalObject(this: Self) *jsc.JSGlobalObject {
        return @ptrCast(@alignCast(wire.bun_bindgen_root_global(this.borrowWire()) orelse
            @panic("binding root has no realm")));
    }

    fn borrowWire(this: Self) *wire.BindRootHandle {
        return @ptrCast(this.resource.borrowWire());
    }

    fn takeWire(this: Self) *wire.BindRootHandle {
        var resource = this.resource;
        return @ptrCast(resource.takeWire());
    }

    fn adoptWire(handle: ?*wire.BindRootHandle) Self {
        return .{ .resource = .adoptWire(@ptrCast(handle)) };
    }

    fn borrowValue(this: Self) *const wire.BindJSValueHandle {
        return wire.bun_bindgen_root_borrow(this.borrowWire()) orelse
            @panic("binding root has no value slot");
    }

    fn clone(this: Self) Self {
        return .{ .resource = Engine(StrongRefCloneSchema).call(this.globalObject(), .{ .reference = &this.resource }) };
    }

    fn belongsToCurrentVM(this: Self, global: *jsc.JSGlobalObject) bool {
        return Engine(StrongRefBelongsToCurrentVMSchema).call(global, .{
            .reference = &this.resource,
        });
    }

    fn sharesVM(this: Self, other: Self) bool {
        return Engine(StrongRefsShareVMSchema).call(this.globalObject(), .{
            .left = &this.resource,
            .right = &other.resource,
        });
    }

    fn replaceValue(slot: *?Self, global: *jsc.JSGlobalObject, value: jsc.JSValue) bun.JSError!void {
        if (slot.*) |current| {
            if (!current.belongsToCurrentVM(global)) @panic("binding root cannot change VMs");
            if (value != .zero and current.globalObject() == global and current.get(global) == value) return;
        }
        const replacement: ?Self = if (value == .zero) null else try .init(global, value);
        const previous = slot.*;
        slot.* = replacement;
        if (previous) |owner| owner.deinit();
    }

    fn replaceRoot(slot: *?Self, source: Self) void {
        if (slot.*) |current| {
            if (!current.sharesVM(source)) @panic("binding root cannot change VMs");
        }
        const replacement = source.clone();
        const previous = slot.*;
        slot.* = replacement;
        if (previous) |owner| owner.deinit();
    }

    fn deinit(this: Self) void {
        var resource = this.resource;
        resource.deinit();
    }
};

const StrongRefCreateSchema = StrongReferenceBindings.engineShim("strongRefCreate");
const StrongRefGetSchema = StrongReferenceBindings.engineShim("strongRefGet");
const StrongRefCloneSchema = StrongReferenceBindings.engineShim("strongRefClone");
const StrongRefBelongsToCurrentVMSchema = StrongReferenceBindings.engineShim("strongRefBelongsToCurrentVM");
const StrongRefsShareVMSchema = StrongReferenceBindings.engineShim("strongRefsShareVM");
const CreateAsyncContextFrameSchema = AsyncHooksBindings.engineShim("createAsyncContextFrame");
const CallbackIdentityEqualsSchema = AsyncHooksBindings.engineShim("callbackIdentityEquals");

const CallbackStorage = enum {
    view,
    owned,
};

pub fn CallbackSchema(comptime callback_name: []const u8) type {
    return Manifest.CallbackSchema(callback_name);
}

pub fn CallbackView(comptime CallbackType: type) type {
    const NormalizedCallback = Manifest.callbackOf(CallbackType);
    const Handle = opaque {};
    const Result_ = struct {
        handle: *const Handle,
        token: ViewToken,

        const Self = @This();

        pub const bindgen_callback_handle = {};
        pub const bindgen_callback_storage: CallbackStorage = .view;
        pub const SemanticType = CallbackType;

        fn init(
            handle: ?*const wire.BindJSValueHandle,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            if (token.globalObject() != global) @panic("binding callback view has the wrong call realm");
            return .{
                .handle = @ptrCast(handle orelse @panic("binding callback view is null")),
                .token = token,
            };
        }

        fn wireHandle(self: Self) *const wire.BindJSValueHandle {
            return @ptrCast(self.handle);
        }

        fn globalObject(self: Self) *jsc.JSGlobalObject {
            return self.token.globalObject();
        }

        fn get(self: Self) jsc.JSValue {
            self.token.requireActive();
            return readJSValue(self.wireHandle());
        }

        pub fn operand(view: Self, context: anytype) Self {
            view.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "binding callback operand has an unrelated scope");
            return view;
        }

        pub fn asEngine(view: Self) EngineOperand {
            return EngineOperand.init(view.get(), view.token);
        }

        pub fn asAny(view: Self) AnyOperand {
            return view.asEngine().asAny();
        }

        pub fn call(self: Self, args: Args(CallbackType)) Outbound(NormalizedCallback).Return {
            self.token.requireActive();
            return Outbound(NormalizedCallback).enter(self.globalObject(), self.token, args, self);
        }

        pub fn dispatch(self: Self, args: Args(CallbackType)) void {
            self.token.requireActive();
            Outbound(NormalizedCallback).dispatch(self.globalObject(), self.token, args, self);
        }

        pub fn schedule(self: Self, args: Args(CallbackType)) Outbound(NormalizedCallback.Scheduled).Return {
            self.token.requireActive();
            return Outbound(NormalizedCallback.Scheduled).enter(self.globalObject(), self.token, args, self);
        }

        pub fn toOwned(self: Self) bun.JSError!Callback(CallbackType) {
            const global = self.globalObject();
            return .{ .root = try CallbackRoot(CallbackType).create(self.get(), global) };
        }

        pub fn toOwnedWithExplicitAsyncContext(
            self: Self,
            context: AnyView,
        ) bun.JSError!Callback(CallbackType) {
            const global = self.globalObject();
            self.token.requireSameCall(context.token, global, "binding callback and async context belong to unrelated calls");
            const Function = Manifest.EngineShimAt(Manifest.EngineShimId(CreateAsyncContextFrameSchema));
            const callback = ValueOperand(.branded, Function.args[0].ArgumentType.Brand).init(self.get(), self.token);
            const value = try (BoundEngineOperation(Manifest.EngineShimId(CreateAsyncContextFrameSchema)){ .token = self.token }).call(.{
                .callback = callback,
                .context = EngineOperand.init(context.rawValue(), context.token),
            });
            return .{ .root = try CallbackRoot(CallbackType).create(value.rawValue(), global) };
        }

        fn borrowWireForEngine(
            self: Self,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) *const wire.BindJSValueHandle {
            self.token.requireSameCall(token, global, "binding callback used by an unrelated engine operation");
            return self.wireHandle();
        }
    };
    return Result_;
}

pub fn Callback(comptime CallbackType: type) type {
    const NormalizedCallback = Manifest.callbackOf(CallbackType);
    const Result_ = struct {
        root: CallbackRoot(CallbackType),

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();

        pub const SemanticType = CallbackType;
        pub const bindgen_callback_handle = {};
        pub const bindgen_callback_storage: CallbackStorage = .owned;

        fn globalObject(self: *const Self) *jsc.JSGlobalObject {
            return self.root.globalObject();
        }

        fn adoptWire(handle: ?*wire.BindRootHandle, global: *jsc.JSGlobalObject) bun.JSError!Self {
            return .{ .root = try CallbackRoot(CallbackType).adoptWire(handle, global) };
        }

        pub const clone = RootedOperations(Self).clone;

        pub fn operand(self: *const Self, context: anytype) CallbackView(CallbackType) {
            const global = context.viewToken().globalObject();
            if (self.globalObject() != global) @panic("binding callback operand has a different realm");
            return .init(self.root.borrowWire(), global, context.viewToken());
        }

        pub fn view(self: *const Self, context: anytype) bun.OOM!CallbackView(CallbackType) {
            context.requireActive();
            const global = context.viewToken().globalObject();
            if (self.globalObject() != global) {
                @panic("owned callback viewed from a different realm");
            }
            return CallbackView(CallbackType).init(try self.root.viewWire(global, context.viewToken()), global, context.viewToken());
        }

        pub fn call(self: *const Self, context: anytype, args: Args(CallbackType)) Outbound(NormalizedCallback).Return {
            return self.operand(context).call(args);
        }

        pub fn dispatch(self: *const Self, context: anytype, args: Args(CallbackType)) void {
            self.operand(context).dispatch(args);
        }

        pub fn schedule(self: *const Self, context: anytype, args: Args(CallbackType)) Outbound(NormalizedCallback.Scheduled).Return {
            return self.operand(context).schedule(args);
        }

        pub const Invocation = struct {
            // Re-entrant calls may replace or destroy the original callback storage.
            callback: Self,
            active_call_scope: ActiveCallScope,
            token: ViewToken,
            active: bool,

            pub const bindgen_callback_invocation_context = {};
            pub const bindgen_callback_type_id = Manifest.TypeId(CallbackType);

            const Operations = ContextOperations(*@This());
            pub const vmIdentity = Operations.vmIdentity;
            pub const engineIn = Operations.engineIn;
            pub const engine = Operations.engine;
            pub const takeThrownException = Operations.takeThrownException;
            pub const takeThrownValue = Operations.takeThrownValue;
            pub const reportUnhandledRejection = Operations.reportUnhandledRejection;
            pub const reportUncaughtException = Operations.reportUncaughtException;
            pub const reportUnhandledException = Operations.reportUnhandledException;
            pub const runErrorHandler = Operations.runErrorHandler;
            pub const collectUnhandledException = Operations.collectUnhandledException;
            pub const waitForPromiseRejection = Operations.waitForPromiseRejection;

            pub fn viewToken(invocation: *@This()) ViewToken {
                invocation.requireActive();
                return invocation.token;
            }

            pub fn reportActiveException(invocation: *@This(), err: bun.JSError) void {
                invocation.requireActive();
                invocation.globalObject().reportActiveExceptionAsUnhandled(err);
            }

            pub fn call(invocation: *@This(), args: Args(CallbackType)) Outbound(NormalizedCallback).Return {
                return invocation.callback.call(invocation, args);
            }

            pub fn argument(invocation: *@This(), comptime name: []const u8, source: anytype) ForwardedArgument(NormalizedCallback, name) {
                return forwardArgument(NormalizedCallback, name, invocation.viewToken(), source);
            }

            pub fn dispatch(invocation: *@This(), args: Args(CallbackType)) void {
                invocation.callback.dispatch(invocation, args);
            }

            pub fn schedule(invocation: *@This(), args: Args(CallbackType)) Outbound(NormalizedCallback.Scheduled).Return {
                return invocation.callback.schedule(invocation, args);
            }

            pub fn takeExceptionRoot(invocation: *@This(), err: bun.JSError) bun.JSError!EngineRoot {
                const exception = ContextOperations(*@This()).takeException(invocation, err);
                return exception.eraseBrandToEngineRoot();
            }

            fn globalObject(invocation: *@This()) *jsc.JSGlobalObject {
                return invocation.viewToken().globalObject();
            }

            fn requireActive(invocation: *const @This()) void {
                if (!invocation.active) @panic("binding callback invocation scope is inactive");
                invocation.token.requireActive();
            }

            pub fn deinit(invocation: *@This()) void {
                if (!invocation.active) return;
                invocation.active = false;
                invocation.active_call_scope.deinit();
                invocation.callback.deinit();
            }
        };

        pub fn beginInvocation(self: *const Self, invocation: *Invocation) void {
            var callback = self.clone();
            callback.moveIntoInvocation(invocation);
        }

        pub fn moveIntoInvocation(self: *Self, invocation: *Invocation) void {
            invocation.* = .{
                .callback = self.take(),
                .active_call_scope = undefined,
                .token = undefined,
                .active = true,
            };
            invocation.active_call_scope.init(nextCallbackInvocationCallId(), invocation.callback.globalObject());
            invocation.token = invocation.active_call_scope.token();
        }

        pub fn sameViewIdentity(self: *const Self, other: CallbackView(CallbackType)) bool {
            if (self.globalObject() != other.globalObject()) return false;
            var engine_scope: FocusedEngineScope = undefined;
            engine_scope.init(self.globalObject());
            defer engine_scope.deinit();
            return engine_scope.engine(CallbackIdentityEqualsSchema).call(.{
                .left = engine_scope.borrowEngineValue(self.root.get()),
                .right = engine_scope.borrowEngineValue(other.get()),
            });
        }

        pub const take = RootedOperations(Self).take;

        pub fn deinit(self: *Self) void {
            self.root.deinit();
        }

        fn takeWire(self: *Self) *wire.BindRootHandle {
            return self.root.takeWire();
        }

        fn borrowWire(self: *const Self) *wire.BindRootHandle {
            return self.root.borrowRootWire();
        }
    };
    return Result_;
}

pub fn StringCallbackRegistry(comptime CallbackType: type) type {
    const StoredCallback = Callback(CallbackType);
    const CallbackList = std.ArrayList(StoredCallback);
    return struct {
        callbacks: bun.StringHashMapUnmanaged(CallbackList) = .empty,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();
        const allocator = bun.default_allocator;

        fn cloneCallbacks(callbacks: []const StoredCallback) bun.OOM!CallbackList {
            var result = try CallbackList.initCapacity(allocator, callbacks.len);
            for (callbacks) |*callback| result.appendAssumeCapacity(callback.clone());
            return result;
        }

        fn deinitCallbacks(callbacks: *CallbackList) void {
            var pending = callbacks.*;
            callbacks.* = .empty;
            for (pending.items) |*callback| callback.deinit();
            pending.deinit(allocator);
        }

        pub fn count(self: *const Self) usize {
            return self.callbacks.count();
        }

        pub fn clone(self: *const Self) bun.OOM!Self {
            var result: Self = .{};
            errdefer result.deinit();
            try result.callbacks.ensureTotalCapacity(allocator, self.callbacks.count());

            var iterator = self.callbacks.iterator();
            while (iterator.next()) |entry| {
                const channel = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(channel);
                result.callbacks.putAssumeCapacityNoClobber(channel, try cloneCallbacks(entry.value_ptr.items));
            }
            return result;
        }

        pub fn add(self: *Self, channel: []const u8, callback: CallbackView(CallbackType)) bun.JSError!void {
            var owned_callback = try callback.toOwned();
            errdefer owned_callback.deinit();
            const entry = try self.callbacks.getOrPut(allocator, channel);
            if (entry.found_existing) {
                try entry.value_ptr.append(allocator, owned_callback);
                return;
            }
            errdefer _ = self.callbacks.remove(channel);
            const owned_channel = try allocator.dupe(u8, channel);
            errdefer allocator.free(owned_channel);
            var callbacks: CallbackList = .empty;
            errdefer callbacks.deinit(allocator);
            try callbacks.append(allocator, owned_callback);
            entry.key_ptr.* = owned_channel;
            entry.value_ptr.* = callbacks;
        }

        pub fn remove(
            self: *Self,
            channel: []const u8,
            callback: CallbackView(CallbackType),
        ) ?usize {
            const list = self.callbacks.getPtr(channel) orelse return null;
            var removed_any = false;
            var index = list.items.len;
            while (index > 0) {
                index -= 1;
                if (!list.items[index].sameViewIdentity(callback)) continue;
                var removed = list.orderedRemove(index);
                removed.deinit();
                removed_any = true;
            }
            if (!removed_any) return list.items.len;
            if (list.items.len != 0) return list.items.len;

            if (!self.removeAll(channel)) @panic("empty callback registry entry disappeared");
            return 0;
        }

        pub fn removeAll(self: *Self, channel: []const u8) bool {
            var removed = self.callbacks.fetchRemove(channel) orelse return false;
            deinitCallbacks(&removed.value);
            allocator.free(removed.key);
            return true;
        }

        pub fn clear(self: *Self) void {
            var iterator = self.callbacks.iterator();
            while (iterator.next()) |entry| {
                deinitCallbacks(entry.value_ptr);
                allocator.free(entry.key_ptr.*);
            }
            self.callbacks.clearRetainingCapacity();
        }

        pub fn dispatch(
            self: *const Self,
            context: anytype,
            channel: []const u8,
            args: Args(CallbackType),
        ) bun.OOM!bool {
            const callbacks = self.callbacks.get(channel) orelse return false;
            var snapshot = try cloneCallbacks(callbacks.items);
            defer deinitCallbacks(&snapshot);
            for (snapshot.items) |*callback| callback.dispatch(context, args);
            return true;
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.callbacks.deinit(allocator);
            self.callbacks = .empty;
        }
    };
}

const SharedClassOps = struct {
    retain: *const fn (*anyopaque) void,
    release_deferred: *const fn (*anyopaque) bool,
    destroy_deferred: *const fn (*anyopaque) void,
    wrap: *const fn (*jsc.JSGlobalObject, *anyopaque) bun.JSError!jsc.JSValue,
};

const SharedClassOwner = struct {
    native: *anyopaque,
    ops: *const SharedClassOps,
};

pub const ClassState = struct {
    generation: std.atomic.Value(u64) = .init(0),
    finalizer_queue: std.atomic.Value(?*jsc.NativeFinalizerQueue) = .init(null),
    finalizer_node: FinalizerNode = .{},
    shared_owner: ?SharedClassOwner = null,

    pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

    fn isPristine(state: *const ClassState) bool {
        return state.generation.load(.acquire) == 0 and
            state.finalizer_queue.load(.acquire) == null and
            state.finalizer_node.node.isUnused() and
            state.shared_owner == null;
    }

    fn initializeFresh(
        state: *ClassState,
        finalizer_queue: *jsc.NativeFinalizerQueue,
        shared_owner: ?SharedClassOwner,
    ) void {
        if (!state.isPristine()) @panic("class constructor returned invalid bindgen state");
        state.finalizer_queue.store(finalizer_queue, .release);
        if (shared_owner) |owner| state.bindSharedOwner(owner);
        state.generation.store(takeClassGeneration(), .release);
    }

    fn bindFinalizerQueue(state: *ClassState, queue: *jsc.NativeFinalizerQueue) void {
        if (state.finalizer_queue.cmpxchgStrong(null, queue, .release, .acquire)) |existing| {
            if (existing != queue) @panic("class native used by multiple VMs");
        }
    }

    fn requireFinalizerQueue(state: *const ClassState) *jsc.NativeFinalizerQueue {
        return state.finalizer_queue.load(.acquire) orelse
            @panic("deferred class native has no finalizer queue");
    }

    fn requireFinalizerQueueForVM(
        state: *const ClassState,
        queue: *jsc.NativeFinalizerQueue,
    ) void {
        if (state.requireFinalizerQueue() != queue) @panic("class native finalized by the wrong VM");
    }

    fn ensureGeneration(state: *ClassState) u64 {
        const existing = state.generation.load(.acquire);
        if (existing != 0) return existing;
        if (!state.finalizer_node.node.isUnused()) @panic("class finalizer state has no generation");
        const generation = takeClassGeneration();
        return state.generation.cmpxchgStrong(0, generation, .release, .acquire) orelse generation;
    }

    fn getGeneration(state: *const ClassState) u64 {
        const generation = state.generation.load(.acquire);
        if (generation == 0) @panic("class native has no generation");
        return generation;
    }

    fn bindSharedOwner(state: *ClassState, owner: SharedClassOwner) void {
        if (state.shared_owner == null) state.shared_owner = owner;
    }

    fn sharedOwner(state: *const ClassState) SharedClassOwner {
        return state.shared_owner orelse @panic("shared class state has no reference owner");
    }

    fn retainShared(state: *const ClassState) void {
        const owner = state.sharedOwner();
        owner.ops.retain(owner.native);
    }

    fn wrapShared(state: *const ClassState, global: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
        const owner = state.sharedOwner();
        return owner.ops.wrap(global, owner.native);
    }
};

fn finalizeDeferredShared(state: *ClassState) void {
    const owner = state.sharedOwner();
    owner.ops.destroy_deferred(owner.native);
}

var next_class_generation: std.atomic.Value(u64) = .init(1);

fn takeClassGeneration() u64 {
    const generation = next_class_generation.fetchAdd(1, .monotonic);
    if (generation == 0 or generation == std.math.maxInt(u64)) {
        @panic("bindgen class generation counter exhausted");
    }
    return generation;
}

pub const NativeAffinity = gc_token.Affinity;

pub fn NativeCallbackContext(comptime affinity: NativeAffinity) type {
    const Policy = struct {
        pub fn validate(comptime T: type, comptime reference_affinity: NativeAffinity) void {
            class_field_validation.validateNative(
                T,
                @typeName(T),
                .{jsc.JSValue},
                .{ViewToken},
                .{ jsc.JSGlobalObject, jsc.VirtualMachine, jsc.VM },
                reference_affinity == .vm,
            );
        }
    };
    return @import("./native_context.zig").NativeContext(affinity, Policy);
}

pub fn OwnedNativeWithDestructor(
    comptime T: type,
    comptime destroy_fn: *const fn (*T) void,
    comptime affinity: NativeAffinity,
) type {
    return NativeOwner(T, destroy_fn, affinity, false);
}

pub fn OwnedNative(comptime T: type, comptime affinity: NativeAffinity) type {
    const Release = struct {
        fn destroy(pointer: *T) void {
            T.destroy(pointer);
        }
    };
    return OwnedNativeWithDestructor(T, Release.destroy, affinity);
}

pub const OwnedNativeSlice = @import("./owned_native_slice.zig").OwnedNativeSlice;

pub fn RefNative(comptime T: type, comptime affinity: NativeAffinity) type {
    const Release = struct {
        fn deref(pointer: *T) void {
            T.deref(pointer);
        }
    };
    return NativeOwner(T, Release.deref, affinity, true);
}

fn NativeOwner(comptime T: type, comptime release: *const fn (*T) void, comptime affinity: NativeAffinity, comptime shared: bool) type {
    return struct {
        pointer: ?*T,

        pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), T, affinity);

        const Self = @This();
        pub const empty: Self = .{ .pointer = null };

        pub fn init(pointer: *T) Self {
            if (shared) _ = T.ref(pointer);
            return adopt(pointer);
        }

        pub fn adopt(pointer: *T) Self {
            if (@typeInfo(T) == .pointer) @compileError("native owners require the pointee type");
            return .{ .pointer = pointer };
        }

        pub fn get(self: Self) *T {
            return self.pointer orelse @panic("native owner was moved or released");
        }

        pub fn getOptional(self: Self) ?*T {
            return self.pointer;
        }

        pub fn clone(self: Self) Self {
            if (!shared) @compileError("unique native owners cannot be cloned");
            return init(self.get());
        }

        pub fn take(self: *Self) *T {
            return self.takeOptional() orelse @panic("native owner was moved or released");
        }

        pub fn takeOptional(self: *Self) ?*T {
            const pointer = self.pointer;
            self.pointer = null;
            return pointer;
        }

        pub fn deinit(self: *Self) void {
            if (self.takeOptional()) |pointer| release(pointer);
        }
    };
}

fn RootedNative(comptime class_id: usize, comptime T: type) type {
    if (@typeInfo(T) == .pointer) @compileError("RootedNative expects the pointee type");
    const Result_ = struct {
        root: ClassRootById(class_id),

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

        const Self = @This();

        fn init(root: ClassRootById(class_id)) Self {
            return .{ .root = root };
        }

        pub fn get(self: *const Self) *T {
            return @ptrCast(@alignCast(requireClassNative(class_id, self.root.get())));
        }

        pub fn toRef(self: *const Self) ClassRefById(class_id) {
            return .{ .root = self.root.clone() };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit();
        }
    };
    return Result_;
}

pub fn ClassRefView(comptime ClassSchema: type) type {
    return ClassRefViewById(Manifest.ClassId(ClassSchema));
}

fn validateClassReferenceTarget(comptime class_id: usize) void {
    if (Manifest.ClassAt(class_id).representation == .plain) {
        @compileError("plain classes do not have native class references; use a branded value");
    }
}

fn ClassRefViewById(comptime class_id: usize) type {
    validateClassReferenceTarget(class_id);
    const Result_ = struct {
        wrapper: AnyView,

        pub const bindgen_class_ref_view = {};

        const Self = @This();

        fn init(
            reference: wire.BindClassRefView,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            const native = reference.native orelse @panic("binding class reference native pointer is null");
            const wrapper = AnyView.init(reference.wrapper, global, token);
            requireClassReferenceNative(class_id, wrapper.rawValue(), native);
            return .{
                .wrapper = wrapper,
            };
        }

        pub fn operand(view: Self, context: anytype) Self {
            view.wrapper.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "binding class operand has an unrelated scope");
            return view;
        }

        pub fn asEngine(view: Self) EngineOperand {
            return EngineOperand.init(view.wrapper.rawValue(), view.wrapper.token);
        }

        pub fn asAny(view: Self) AnyOperand {
            return view.asEngine().asAny();
        }

        pub fn get(view: Self, comptime Impl: type) *Impl {
            if (comptime Manifest.ClassAt(class_id).representation == .engine) {
                @compileError("engine class references are opaque outside generated adapters");
            }
            view.wrapper.token.requireActive();
            _ = ClassBinding(class_id, Impl);
            return @ptrCast(@alignCast(requireClassNative(class_id, view.wrapper.rawValue())));
        }

        pub fn value(view: Self) BrandedValueView(Manifest.ClassAt(class_id).ValueType) {
            view.wrapper.token.requireActive();
            return BrandedValueView(Manifest.ClassAt(class_id).ValueType).init(
                @ptrCast(view.wrapper.handle),
                view.wrapper.engineGlobal(),
                view.wrapper.token,
            );
        }

        fn borrowWireForEngine(
            view: Self,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) wire.BindClassRefView {
            view.wrapper.token.requireSameCall(token, global, "binding class reference used by an unrelated engine operation");
            return .{
                .native = @ptrCast(requireClassNative(class_id, view.wrapper.rawValue())),
                .wrapper = @ptrCast(view.wrapper.handle),
            };
        }

        pub fn toOwned(view: Self) bun.JSError!ClassRefById(class_id) {
            view.wrapper.token.requireActive();
            return .{
                .root = try ClassRootById(class_id).create(
                    view.wrapper.rawValue(),
                    view.wrapper.engineGlobal(),
                ),
            };
        }
    };
    return Result_;
}

pub fn ClassRef(comptime ClassSchema: type) type {
    return ClassRefById(Manifest.ClassId(ClassSchema));
}

fn ClassRefById(comptime class_id: usize) type {
    validateClassReferenceTarget(class_id);
    const Result_ = struct {
        root: ClassRootById(class_id),

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const bindgen_class_ref = {};
        pub const bindgen_class_id = class_id;

        const Self = @This();

        pub fn get(ref: *const Self, comptime Impl: type) *Impl {
            if (comptime Manifest.ClassAt(class_id).representation == .engine) {
                @compileError("engine class references are opaque outside generated adapters");
            }
            _ = ClassBinding(class_id, Impl);
            return @ptrCast(@alignCast(requireClassNative(class_id, ref.root.get())));
        }

        pub const clone = RootedOperations(Self).clone;

        pub const deinit = RootedOperations(Self).deinit;

        pub const take = RootedOperations(Self).take;

        pub fn takeUpcast(ref: *Self, comptime AncestorSchema: type) ClassRef(AncestorSchema) {
            const ConcreteClass = Manifest.ClassAt(class_id);
            const Ancestor = Manifest.ClassAt(Manifest.ClassId(AncestorSchema));
            if (comptime ConcreteClass.representation != .native or Ancestor.representation != .native or
                !Manifest.classIsOrInherits(ConcreteClass, Ancestor))
            {
                @compileError("class references may only be upcast along declared native inheritance");
            }
            const root = ref.root.take();
            return .{
                .root = .{ .impl = root.impl },
            };
        }

        pub const takeAnyRoot = RootedOperations(Self).takeAnyRoot;

        pub fn takeEngineRoot(ref: *Self) EngineRoot {
            ref.root.requireCurrentVM(ref.globalObject());
            const root = ref.root.take();
            return .{ .impl = root.impl };
        }

        fn adoptWire(value: wire.BindClassRef, global: *jsc.JSGlobalObject) bun.JSError!Self {
            const native = value.native orelse @panic("binding class reference transfer has a null native pointer");
            const result: Self = .{
                .root = try ClassRootById(class_id).adoptWire(value.wrapper, global),
            };
            requireClassReferenceNative(class_id, result.root.get(), native);
            return result;
        }

        fn globalObject(ref: *const Self) *jsc.JSGlobalObject {
            return ref.root.globalObject();
        }

        fn takeWire(ref: *Self) wire.BindClassRef {
            const native = requireClassNative(class_id, ref.root.get());
            return .{
                .native = @ptrCast(native),
                .wrapper = ref.root.takeWire(),
            };
        }

        fn borrowWire(ref: *const Self) wire.BindClassRef {
            return .{
                .native = @ptrCast(requireClassNative(class_id, ref.root.get())),
                .wrapper = ref.root.borrowRootWire(),
            };
        }

        fn borrowWireForEngine(ref: *const Self) wire.BindClassRefView {
            return .{
                .native = @ptrCast(requireClassNative(class_id, ref.root.get())),
                .wrapper = ref.root.borrowWire(),
            };
        }

        pub fn operand(ref: *const Self, context: anytype) ClassRefViewById(class_id) {
            const global = context.viewToken().globalObject();
            ref.root.requireCurrentVM(global);
            return .init(ref.borrowWireForEngine(), global, context.viewToken());
        }

        pub fn view(ref: *const Self, context: anytype) bun.OOM!ClassRefViewById(class_id) {
            context.requireActive();
            const global = context.viewToken().globalObject();
            if (ref.globalObject() != global) {
                @panic("binding class reference viewed from a different realm");
            }
            return .{
                .wrapper = AnyView.init(try ref.root.viewWire(global, context.viewToken()), global, context.viewToken()),
            };
        }
    };
    return Result_;
}

/// Plain native data stored inline in a bound class.
pub fn NativeData(comptime T: type) type {
    comptime class_field_validation.validateNativeData(T, @typeName(T), .{jsc.JSValue});
    const Result_ = struct {
        value: T,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .any);

        const Self = @This();
    };
    return Result_;
}

/// A typed native pointer whose allocation is owned and freed elsewhere; the
/// owner guarantees it outlives this wrapper.
pub fn BorrowedNative(comptime T: type, comptime affinity: NativeAffinity) type {
    const Result_ = struct {
        value: *T,

        pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), T, affinity);

        const Self = @This();

        pub fn init(value: *T) Self {
            return .{ .value = value };
        }

        pub fn get(self: Self) *T {
            return self.value;
        }
    };
    return Result_;
}

/// A native pointer lent to a wrapper for the duration of one library
/// callback. The dispatcher arms it before the callback and clears it after;
/// uses outside that window observe null.
pub fn CallbackBorrow(comptime T: type, comptime affinity: NativeAffinity) type {
    const Result_ = struct {
        value: ?*T = null,

        pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), T, affinity);

        const Self = @This();

        pub const empty: Self = .{};

        pub fn init(value: *T) Self {
            return .{ .value = value };
        }

        pub fn clear(self: *Self) void {
            self.value = null;
        }
    };
    return Result_;
}

fn StringOperand(comptime kind: ir.StringKind, comptime thread_safe: bool) type {
    return struct {
        handle: ?*const wire.BindStringHandle,
        token: ?ViewToken,

        const Self = @This();
        pub const string_kind = kind;
        pub const is_thread_safe = thread_safe;

        fn borrowWire(self: Self) ?*const wire.BindStringHandle {
            if (self.token) |token| token.requireActive();
            return self.handle;
        }
    };
}

fn StringConversions(comptime Receiver: type) type {
    return struct {
        pub fn hasPrefixComptime(self: Receiver, comptime prefix: []const u8) bool {
            return self.raw().textView().hasPrefixComptime(prefix);
        }

        pub fn toUTF8(self: Receiver, allocator: std.mem.Allocator) bun.OOM!bun.String.Slice {
            return if (self.stringImpl()) |impl| impl.toUTF8(allocator) else bun.String.Slice.empty;
        }

        pub fn toOwnedSlice(self: Receiver, allocator: std.mem.Allocator) bun.OOM![]u8 {
            return if (self.stringImpl()) |impl| bun.String.init(impl).toOwnedSlice(allocator) else allocator.dupe(u8, &.{});
        }

        pub fn toOwnedSliceZ(self: Receiver, allocator: std.mem.Allocator) bun.OOM![:0]u8 {
            return if (self.stringImpl()) |impl| impl.toOwnedSliceZ(allocator) else allocator.dupeSentinel(u8, &.{}, 0);
        }
    };
}

fn BoundStringView(comptime kind: ir.StringKind, comptime thread_safe: bool) type {
    const Result_ = struct {
        handle: ?*const wire.BindStringHandle,
        view: wire.BindStringView,
        token: ViewToken,

        const Self = @This();

        fn init(handle: anytype, token: ViewToken) Self {
            const string_handle: ?*const wire.BindStringHandle = if (handle == null) null else @ptrCast(handle);
            return .{
                .handle = string_handle,
                .view = decodeBoundStringView(kind, string_handle),
                .token = token,
            };
        }

        pub fn operand(self: Self) StringOperand(kind, thread_safe) {
            self.token.requireActive();
            return .{ .handle = self.handle, .token = self.token };
        }

        fn borrowWire(self: Self) ?*const wire.BindStringHandle {
            self.token.requireActive();
            return self.handle;
        }

        pub fn asDOMString(self: Self) BoundStringView(.dom_string, thread_safe) {
            self.token.requireActive();
            return .{ .handle = self.handle, .view = self.view, .token = self.token };
        }

        pub fn length(self: Self) usize {
            return switch (self.raw()) {
                inline else => |units| units.len,
            };
        }

        pub fn codeUnitAt(self: Self, index: usize) ?u16 {
            return switch (self.raw()) {
                .latin1 => |units| if (index < units.len) units[index] else null,
                .utf16 => |units| if (index < units.len) units[index] else null,
            };
        }

        pub fn toOwned(self: Self) if (thread_safe) bun.OOM!BoundString(kind, thread_safe) else BoundString(kind, thread_safe) {
            self.token.requireActive();
            if (self.length() == 0) return BoundString(kind, thread_safe).empty();
            return retainBoundString(kind, thread_safe, self.handle.?);
        }

        pub fn hashUTF8(self: Self) u64 {
            return self.raw().textView().hashUTF8();
        }

        pub fn eqlUTF8(self: Self, expected: []const u8) bool {
            return self.raw().textView().eqlUTF8View(.{ .utf8 = expected });
        }

        pub fn eqlIgnoringASCIICase(self: Self, expected: []const u8) bool {
            if (self.length() != expected.len) return false;
            for (expected, 0..) |unit, index| {
                const actual = self.codeUnitAt(index).?;
                if (actual > 255 or std.ascii.toLower(@intCast(actual)) != std.ascii.toLower(unit)) return false;
            }
            return true;
        }

        const Conversions = StringConversions(Self);
        pub const hasPrefixComptime = Conversions.hasPrefixComptime;
        pub const toUTF8 = Conversions.toUTF8;
        pub const toOwnedSlice = Conversions.toOwnedSlice;
        pub const toOwnedSliceZ = Conversions.toOwnedSliceZ;

        fn stringImpl(self: Self) ?bun.string.WTFStringImpl {
            self.token.requireActive();
            return if (self.handle) |handle| @ptrCast(@alignCast(@constCast(handle))) else null;
        }

        pub fn unsafePtr(self: Self, comptime reason: []const u8) UnsafeStringCodeUnits {
            if (reason.len == 0) @compileError("unsafePtr requires a non-empty lifetime reason");
            return self.raw();
        }

        fn raw(self: Self) UnsafeStringCodeUnits {
            self.token.requireActive();
            return boundStringCodeUnits(kind, self.view);
        }
    };
    return Result_;
}

fn BoundString(comptime kind: ir.StringKind, comptime thread_safe: bool) type {
    const Result_ = struct {
        impl: ?bun.string.WTFStringImpl,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), if (thread_safe) .any else .vm);

        const Self = @This();

        pub fn fromLatin1(value: []const u8) bun.OOM!Self {
            return adoptFreshBunString(bun.String.cloneLatin1(value));
        }

        pub fn fromUTF8(value: []const u8) bun.OOM!Self {
            if (kind == .byte_string) @compileError("ByteString must be constructed from Latin-1 code units");
            return adoptFreshBunString(bun.String.cloneUTF8(value));
        }

        pub fn fromOptionalUTF8(value: ?[]const u8) bun.OOM!?Self {
            return if (value) |bytes| try fromUTF8(bytes) else null;
        }

        pub fn fromUTF16(value: []const u16) bun.OOM!Self {
            if (kind != .dom_string) @compileError("only DOMString accepts unnormalized UTF-16 code units");
            return adoptFreshBunString(bun.String.cloneUTF16(value));
        }

        pub fn fromTextView(value: bun.TextView) bun.OOM!Self {
            if (kind != .dom_string) @compileError("only DOMString accepts unnormalized text views");
            return switch (value) {
                .latin1 => |bytes| fromLatin1(bytes),
                .utf8 => |bytes| fromUTF8(bytes),
                .utf16 => |units| fromUTF16(units),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.take().impl) |impl| wire.bun_bindgen_string_release(@ptrCast(impl));
        }

        pub fn clone(self: *const Self) Self {
            const impl = self.impl orelse return empty();
            impl.ref();
            return .{ .impl = impl };
        }

        pub fn take(self: *Self) Self {
            const value = self.*;
            self.* = empty();
            return value;
        }

        pub const toOwned = Self.clone;

        pub fn length(self: *const Self) usize {
            return if (self.impl) |impl| impl.length() else 0;
        }

        pub fn utf8ByteLength(self: *const Self) usize {
            return if (self.impl) |impl| impl.utf8ByteLength() else 0;
        }

        pub fn byteLength(self: *const Self) usize {
            return if (self.impl) |impl| impl.byteLength() else 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.length() == 0;
        }

        pub fn eqlUTF8(self: *const Self, expected: []const u8) bool {
            return self.raw().textView().eqlUTF8View(.{ .utf8 = expected });
        }

        const Conversions = StringConversions(*const Self);
        pub const hasPrefixComptime = Conversions.hasPrefixComptime;
        pub const toUTF8 = Conversions.toUTF8;
        pub const toOwnedSlice = Conversions.toOwnedSlice;
        pub const toOwnedSliceZ = Conversions.toOwnedSliceZ;

        fn stringImpl(self: *const Self) ?bun.string.WTFStringImpl {
            return self.impl;
        }

        fn raw(self: *const Self) UnsafeStringCodeUnits {
            const impl = self.impl orelse return .{ .latin1 = &.{} };
            return if (impl.is8Bit())
                .{ .latin1 = impl.latin1Slice() }
            else
                .{ .utf16 = impl.utf16Slice() };
        }

        pub fn format(self: Self, writer: *std.Io.Writer) !void {
            try self.raw().textView().format(writer);
        }

        pub fn unsafePtr(self: *const Self, comptime reason: []const u8) UnsafeStringCodeUnits {
            if (reason.len == 0) @compileError("unsafePtr requires a non-empty lifetime reason");
            return self.raw();
        }

        fn takeWire(self: *Self) ?*wire.BindStringHandle {
            const owned = self.take();
            return owned.borrowWire();
        }

        fn borrowWire(self: *const Self) ?*wire.BindStringHandle {
            return if (self.impl) |value| @ptrCast(value) else null;
        }

        fn adoptWire(value: ?*wire.BindStringHandle) Self {
            return .{ .impl = if (value) |handle| @ptrCast(@alignCast(handle)) else null };
        }

        pub fn fromBunString(value: bun.String) bun.OOM!Self {
            if (kind != .dom_string) @compileError("only DOMString accepts an unnormalized native string");
            var owned = value;
            errdefer owned.deref();
            if (thread_safe) try owned.toThreadSafe();
            return adoptFreshBunString(owned);
        }

        pub fn operand(self: *const Self) StringOperand(kind, thread_safe) {
            return .{ .handle = self.borrowWire(), .token = null };
        }

        pub fn view(self: *const Self, context: anytype) BoundStringView(kind, thread_safe) {
            context.requireActive();
            return BoundStringView(kind, thread_safe).init(self.borrowWire(), context.viewToken());
        }

        pub fn toThreadSafe(self: *Self) bun.OOM!BoundString(kind, true) {
            if (thread_safe) @compileError("binding string is already thread-safe");
            const impl = self.impl orelse return BoundString(kind, true).empty();
            const isolated = try bun.String.init(impl).isolatedCopy();
            const result = try BoundString(kind, true).adoptFreshBunString(isolated);
            self.deinit();
            return result;
        }

        pub fn takeBunString(self: *Self) bun.String {
            const impl = self.take().impl orelse return .empty;
            return .{ .tag = .WTFStringImpl, .value = .{ .WTFStringImpl = impl } };
        }

        pub fn empty() Self {
            return .{ .impl = null };
        }

        fn adoptFreshBunString(value: bun.String) bun.OOM!Self {
            return switch (value.tag) {
                .WTFStringImpl => .{ .impl = value.value.WTFStringImpl },
                .Empty => empty(),
                .Dead => error.OutOfMemory,
            };
        }
    };
    return Result_;
}

fn retainBoundString(
    comptime kind: ir.StringKind,
    comptime thread_safe: bool,
    handle: *const wire.BindStringHandle,
) if (thread_safe) bun.OOM!BoundString(kind, thread_safe) else BoundString(kind, thread_safe) {
    const impl: bun.string.WTFStringImpl = @ptrCast(@alignCast(@constCast(handle)));
    impl.ref();
    if (!thread_safe) return .{ .impl = impl };
    var owned: BoundString(kind, false) = .{ .impl = impl };
    defer owned.deinit();
    return owned.toThreadSafe();
}

const transfer_allocator = bun.default_allocator;
const AllocationFailureCountdown = struct {
    remaining: ?usize = null,

    fn shouldFail(this: *@This()) bool {
        const remaining = this.remaining orelse return false;
        if (remaining == 0) {
            this.remaining = null;
            return true;
        }
        this.remaining = remaining - 1;
        return false;
    }
};
threadlocal var transfer_allocation_failure: AllocationFailureCountdown = .{};
threadlocal var snapshot_allocation_failure: AllocationFailureCountdown = .{};
threadlocal var weak_allocation_failure: AllocationFailureCountdown = .{};

pub const testing = struct {
    pub fn setTransferAllocationFailureCountdown(countdown: ?usize) void {
        transfer_allocation_failure.remaining = countdown;
    }

    pub fn setSnapshotAllocationFailureCountdown(countdown: ?usize) void {
        snapshot_allocation_failure.remaining = countdown;
    }

    pub fn setWeakAllocationFailureCountdown(countdown: ?usize) void {
        weak_allocation_failure.remaining = countdown;
    }

    pub fn failWeakAllocation() bool {
        return weak_allocation_failure.shouldFail();
    }
};

fn transferAlloc(comptime T: type, len: usize) bun.OOM![]T {
    if (transfer_allocation_failure.shouldFail()) return error.OutOfMemory;
    return transfer_allocator.alloc(T, len);
}

pub export fn bun_bindgen_transfer_alloc(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    return (transferAlloc(u8, len) catch return null).ptr;
}

pub export fn bun_bindgen_transfer_alloc_aligned(len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    if (transfer_allocation_failure.shouldFail()) return null;
    return transfer_allocator.rawAlloc(len, .fromByteUnits(alignment), @returnAddress());
}

pub export fn bun_bindgen_transfer_free_aligned(ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    const bytes = wireSlice([]u8, .{ .ptr = ptr, .len = len });
    if (bytes.len > 0) transfer_allocator.rawFree(bytes, .fromByteUnits(alignment), @returnAddress());
}

pub export fn bun_bindgen_transfer_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    freeTransferBytes(wireSlice([]u8, .{ .ptr = ptr, .len = len }));
}

fn copyTransferBytes(value: []const u8) bun.OOM![]u8 {
    if (value.len == 0) return &.{};
    const result = try transferAlloc(u8, value.len);
    @memcpy(result, value);
    return result;
}

fn freeTransferBytes(value: []u8) void {
    if (value.len > 0) transfer_allocator.free(value);
}

const CallRecord = struct {
    id: u64,
    global_object: ?*jsc.JSGlobalObject,
    resources: ?*CallScopedResource,
    deferred_conversions: ?*wire.BindDeferredConversionsHandle,
    lazy_storage: ?*wire.BindLazyStorageHandle,
    parent: if (bun.Environment.allow_assert) ?*CallRecord else void,
};

const CheckedActiveCalls = if (bun.Environment.allow_assert) struct {
    threadlocal var top: ?*CallRecord = null;
} else struct {};

const CallScopedResource = struct {
    next: ?*CallScopedResource,
    release: *const fn (*CallScopedResource) void,
};

fn adoptCallScopedOwner(value: anytype, token: ViewToken) bun.OOM!*@TypeOf(value) {
    const Owner = @TypeOf(value);
    var pending = value;
    errdefer pending.deinit();
    token.requireActive();
    const Node = struct {
        resource: CallScopedResource,
        value: Owner,

        fn release(resource: *CallScopedResource) void {
            const node: *@This() = @fieldParentPtr("resource", resource);
            node.value.deinit();
            bun.destroy(node);
        }
    };
    if (snapshot_allocation_failure.shouldFail()) return error.OutOfMemory;
    const node = try bun.default_allocator.create(Node);
    node.* = .{
        .resource = .{ .next = token.call.resources, .release = Node.release },
        .value = pending,
    };
    token.call.resources = &node.resource;
    return &node.value;
}

/// Snapshots and transferred roots share the call lifetime without exposing ownership through a view.
fn adoptCallScopedRoot(root: RootHandle, global: *jsc.JSGlobalObject, token: ViewToken) bun.OOM!*const wire.BindJSValueHandle {
    token.requireActive();
    if (token.call.global_object != global) @panic("binding stored value has the wrong call realm");
    if (!root.belongsToCurrentVM(global)) @panic("binding stored value belongs to a different VM");
    const owner = try adoptCallScopedOwner(root, token);
    return owner.borrowValue();
}

fn retainCallScopedValue(
    value: anytype,
    global: *jsc.JSGlobalObject,
    token: ViewToken,
) (if (@TypeOf(value) == RootHandle) bun.OOM else bun.JSError)!*const wire.BindJSValueHandle {
    token.requireActive();
    if (token.call.global_object != global) @panic("binding stored value has the wrong call realm");
    if (comptime @TypeOf(value) == RootHandle) {
        if (!value.belongsToCurrentVM(global)) @panic("binding stored value belongs to a different VM");
    }
    const root = if (comptime @TypeOf(value) == RootHandle)
        value.clone()
    else if (comptime @TypeOf(value) == jsc.JSValue)
        try RootHandle.init(global, value)
    else
        @compileError("call snapshots require a JS value or an owned root handle");
    return adoptCallScopedRoot(root, global, token);
}

const ActiveCallScope = struct {
    call: CallRecord,

    fn init(scope: *ActiveCallScope, id: u64, global: *jsc.JSGlobalObject) void {
        scope.initRecord(id, global, null, null);
    }

    fn initWithDeferred(scope: *ActiveCallScope, id: u64, global: *jsc.JSGlobalObject, deferred: ?*wire.BindDeferredConversionsHandle, lazy_storage: ?*wire.BindLazyStorageHandle) void {
        scope.initRecord(id, global, deferred, lazy_storage);
    }

    fn initRealmFree(scope: *ActiveCallScope, id: u64) void {
        scope.initRecord(id, null, null, null);
    }

    fn initRecord(scope: *ActiveCallScope, id: u64, global: ?*jsc.JSGlobalObject, deferred: ?*wire.BindDeferredConversionsHandle, lazy_storage: ?*wire.BindLazyStorageHandle) void {
        if (id == 0) @panic("binding call received call ID zero");
        scope.call = .{
            .id = id,
            .global_object = global,
            .resources = null,
            .deferred_conversions = deferred,
            .lazy_storage = lazy_storage,
            .parent = if (bun.Environment.allow_assert) CheckedActiveCalls.top else {},
        };
        if (comptime bun.Environment.allow_assert) CheckedActiveCalls.top = &scope.call;
    }

    fn token(scope: *ActiveCallScope) ViewToken {
        return ViewToken.init(&scope.call);
    }

    fn deinit(scope: *ActiveCallScope) void {
        if (comptime bun.Environment.allow_assert) {
            if (CheckedActiveCalls.top != &scope.call) @panic("binding call stack was corrupted");
            CheckedActiveCalls.top = scope.call.parent;
        }
        var resource = scope.call.resources;
        while (resource) |node| {
            resource = node.next;
            node.release(node);
        }
    }
};

const OperandContext = struct {
    token: ViewToken,

    pub fn viewToken(context: *const @This()) ViewToken {
        return context.token;
    }
    pub fn requireActive(context: *const @This()) void {
        context.token.requireActive();
    }
    pub const engineIn = ContextOperations(*const @This()).engineIn;
    pub const engine = ContextOperations(*const @This()).engine;
    pub const takeThrownException = ContextOperations(*const @This()).takeThrownException;
};

const OperandValue = enum(i64) { _ };

fn ValueOperand(comptime access: RootAccess, comptime Brand: type) type {
    return struct {
        value: OperandValue,
        token: ViewToken,

        const Self = @This();

        fn init(value: jsc.JSValue, token: ViewToken) Self {
            if (value == .zero) @panic("focused engine values cannot hold an empty JS value");
            token.requireActive();
            return .{ .value = @fromBackingInt(@backingInt(value)), .token = token };
        }

        fn rawValueForEngine(
            local: *const Self,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) jsc.JSValue {
            local.token.requireSameCall(token, global, "focused engine value used by an unrelated engine operation");
            return @fromBackingInt(@backingInt(local.value));
        }

        pub fn operand(local: Self, context: anytype) Self {
            local.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "binding operand has an unrelated scope");
            return local;
        }

        fn encodedForEngine(local: Self, global: *jsc.JSGlobalObject, token: ViewToken) i64 {
            return @backingInt(local.rawValueForEngine(global, token));
        }

        pub fn engineView(local: Self) EngineValueView {
            if (access == .any) @compileError("opaque any operands do not grant engine access");
            local.token.requireActive();
            return EngineValueView.initInline(@fromBackingInt(@backingInt(local.value)), local.token.globalObject(), local.token);
        }

        pub fn toRoot(local: Self) bun.JSError!(if (access == .engine) EngineRoot else Root) {
            local.token.requireActive();
            const value: jsc.JSValue = @fromBackingInt(@backingInt(local.value));
            return if (access == .engine)
                EngineRoot.create(value, local.token.globalObject())
            else
                Root.create(value, local.token.globalObject());
        }

        pub fn asAny(local: Self) AnyOperand {
            local.token.requireActive();
            return .{ .value = local.value, .token = local.token };
        }

        pub fn asPromise(local: Self) ValueOperand(.branded, PromiseSemanticType.Brand) {
            if (access != .branded or !Brand.is_promise) @compileError("only promises can erase their settled-value type");
            local.token.requireActive();
            return .{ .value = local.value, .token = local.token };
        }

        pub fn asEngine(local: Self) EngineOperand {
            if (access == .any) @compileError("opaque any operands do not grant engine access");
            local.token.requireActive();
            return .{ .value = local.value, .token = local.token };
        }

        pub fn viewToken(local: Self) ViewToken {
            local.token.requireActive();
            return local.token;
        }

        pub fn requireActive(local: Self) void {
            local.token.requireActive();
        }

        pub fn engineIn(local: Self, comptime module_name: []const u8, comptime operation_name: []const u8) BoundEngineOperation(EngineOperationId(module_name, operation_name)) {
            return local.operationContext().engineIn(module_name, operation_name);
        }

        pub fn engine(local: Self, comptime Shim: type) BoundEngineOperation(Manifest.EngineShimId(Shim)) {
            return local.operationContext().engine(Shim);
        }

        fn raw(local: Self) jsc.JSValue {
            if (access == .any) @compileError("opaque any operands do not grant value inspection");
            local.token.requireActive();
            return @fromBackingInt(@backingInt(local.value));
        }

        fn operationContext(local: Self) OperandContext {
            if (access == .any) @compileError("opaque any operands only support retention, forwarding and invocation");
            local.token.requireActive();
            return .{ .token = local.token };
        }

        fn UnaryOperation(comptime Shim: type) type {
            return struct {
                fn call(value: Self) BoundEngineOperation(Manifest.EngineShimId(Shim)).Return {
                    const context = value.operationContext();
                    return context.engine(Shim).call(.{ .value = value.asEngine() });
                }
            };
        }

        fn BinaryOperation(comptime Shim: type, comptime field: enum { input, operands }) type {
            return struct {
                fn call(left: Self, right: EngineOperand) BoundEngineOperation(Manifest.EngineShimId(Shim)).Return {
                    const context = left.operationContext();
                    const operands: @FieldType(BoundEngineOperation(Manifest.EngineShimId(Shim)).Args, @tagName(field)) = .{ .left = left.asEngine(), .right = right.asEngine() };
                    return context.engine(Shim).call(switch (field) {
                        .input => .{ .input = operands },
                        .operands => .{ .operands = operands },
                    });
                }
            };
        }

        fn StringOperation(comptime Shim: type) type {
            return struct {
                fn call(value: Self) bun.JSError!bun.String {
                    var result = try UnaryOperation(Shim).call(value);
                    defer result.deinit();
                    return result.takeBunString();
                }
            };
        }

        pub const isTruthy = toBoolean;
        const PropertyIterationMode = enum { all, non_indexed, ordered };
        pub const ComparisonResult = enum(u8) {
            equal,
            undefined_result,
            greater_than,
            less_than,
            invalid_comparison,
        };
        pub const BuiltinName = bun.bindgen.EngineArgumentType(JSValueFastGetSchema, "builtinId");
        pub const getIfPropertyExists = get;
        const ProxyInternalField = enum(u32) {
            target = 0,
            handler = 1,
        };

        const coerceToInt32 = UnaryOperation(JSValueCoerceToInt32Shim).call;

        const coerceToInt64 = UnaryOperation(JSValueCoerceToInt64Shim).call;

        pub fn getIndex(this: Self, i: u64) bun.JSError!EngineOperand {
            const scope = this.operationContext();
            const result = try scope.engine(JSValueGetIndexSchema).call(.{
                .value = this.asEngine(),
                .index = i,
            });
            return result.operand(&scope).asEngine();
        }

        fn forEachPropertyImpl(
            comptime mode: PropertyIterationMode,
            this: Self,
            ctx: anytype,
            comptime callback: anytype,
        ) bun.JSError!void {
            const globalThis = this.token.globalObject();
            const engine_scope = this.operationContext();
            const input_value = this.asEngine();
            const creation = try engine_scope.engine(ConsolePropertyIteratorCreateSchema).call(.{
                .value = input_value.operand(&engine_scope).asEngine(),
                .mode = switch (mode) {
                    .all => .all,
                    .non_indexed => .nonIndexed,
                    .ordered => .ordered,
                },
            });
            const iterator = creation.iterator orelse return;
            defer bun.bindgen.Engine(ConsolePropertyIteratorDestroySchema).call(.{ .iterator = iterator });

            for (0..creation.count) |index| {
                var entry = try engine_scope.engine(ConsolePropertyIteratorGetEntrySchema).call(.{
                    .iterator = iterator,
                    .value = input_value.operand(&engine_scope).asEngine(),
                    .index = index,
                }) orelse continue;
                defer entry.name.deinit();

                const value = entry.value.operand(&engine_scope).asEngine();
                callback(
                    globalThis,
                    ctx,
                    entry.name.unsafePtr("entry owns the name until the property callback returns").textView(),
                    value,
                    entry.isSymbol,
                    entry.isPrivateSymbol,
                );
                value.ensureStillAlive();
                if (globalThis.hasException()) return error.JSError;
            }
        }

        pub fn forEachPropertyNonIndexed(
            this: Self,
            ctx: anytype,
            comptime callback: anytype,
        ) bun.JSError!void {
            return forEachPropertyImpl(.non_indexed, this, ctx, callback);
        }

        pub fn forEachProperty(
            this: Self,
            ctx: anytype,
            comptime callback: anytype,
        ) bun.JSError!void {
            return forEachPropertyImpl(.all, this, ctx, callback);
        }

        pub fn forEachPropertyOrdered(
            this: Self,
            ctx: anytype,
            comptime callback: anytype,
        ) bun.JSError!void {
            return forEachPropertyImpl(.ordered, this, ctx, callback);
        }

        /// Perform the ToNumber abstract operation, coercing a value to a number.
        /// Equivalent to `+value`
        /// https://tc39.es/ecma262/#sec-tonumber
        pub const toNumber = UnaryOperation(JSValueToNumberSchema).call;

        pub fn coerce(
            this: Self,
            comptime T: type,
        ) bun.JSError!T {
            return switch (T) {
                f64 => {
                    if (this.isDouble()) {
                        return this.asDouble();
                    }
                    return this.toNumber();
                },
                i64 => {
                    return this.coerceToInt64();
                },
                i32 => {
                    if (this.isInt32()) {
                        return this.asInt32();
                    }
                    if (this.getNumber()) |num| {
                        return std.math.lossyCast(i32, num);
                    }
                    return this.coerceToInt32();
                },
                else => @compileError("Unsupported coercion type"),
            };
        }

        pub fn isInstanceOf(this: Self, constructor: EngineOperand) bun.JSError!bool {
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueIsInstanceOfSchema).call(.{
                .input = .{
                    .value = this.asEngine(),
                    .constructor = constructor.asEngine(),
                },
            });
        }

        pub fn call(function: Self, this_value: AnyOperand, arguments: []const AnyOperand) bun.JSError!(if (access == .any) AnyOperand else EngineOperand) {
            const context: OperandContext = .{ .token = function.token };
            if (comptime bun.Environment.isDebug) {
                const loop = function.token.globalObject().bunVM().eventLoop();
                loop.debug.js_call_count_outside_tick_queue += @as(usize, @intFromBool(!loop.debug.is_inside_tick_queue));
                if (loop.debug.track_last_fn_name and !loop.debug.is_inside_tick_queue) {
                    loop.debug.last_fn_name.deref();
                    var name = try context.engine(JSValueGetNameSchema).call(.{ .value = .{ .value = function.value, .token = function.token } });
                    loop.debug.last_fn_name = name.takeBunString();
                }
            }
            const result = try context.engine(JSValueCallSchema).call(.{
                .function = .{ .value = function.value, .token = function.token },
                .this_value = .{ .value = this_value.value, .token = this_value.token },
                .arguments = arguments,
            });
            return if (access == .any) result.operand(&context).asAny() else result.operand(&context).asEngine();
        }

        pub fn jsType(
            this: Self,
        ) JSType {
            const engine_scope = this.operationContext();
            return @fromBackingInt(engine_scope.engine(JSValueTypeSchema).call(.{ .value = this.asEngine() }));
        }

        pub fn proxyTarget(
            this: Self,
        ) bun.JSError!?EngineOperand {
            const scope = this.operationContext();
            const result = (try scope.engine(JSValueProxyTargetSchema).call(.{ .value = this.asEngine() })) orelse return null;
            return result.operand(&scope).asEngine();
        }

        pub fn jsTypeLoose(
            this: Self,
        ) JSType {
            if (this.isNumber()) {
                return JSType.NumberObject;
            }

            return this.jsType();
        }

        pub const isBuffer = UnaryOperation(JSValueIsBufferShim).call;

        pub fn isRegExp(this: Self) bool {
            return this.jsType() == .RegExpObject;
        }

        pub fn isDate(this: Self) bool {
            return this.jsType() == .JSDate;
        }

        pub fn jestSnapshotPrettyFormat(this: Self, out: *std.Io.Writer) !void {
            const value = this.asEngine();
            try JestPrettyFormat.format(.Debug, this.token.globalObject(), @ptrCast(&value), 1, out, .{
                .enable_colors = false,
                .add_newline = false,
                .flush = false,
                .quote_strings = true,
            });
            try out.flush();
        }

        pub fn className(
            this: Self,
        ) bun.JSError!bun.String {
            if (!this.isCell())
                return bun.String.static("[not a class]");
            const engine_scope = this.operationContext();
            var result = try engine_scope.engine(JSValueClassNameSchema).call(.{ .value = this.asEngine() });
            defer result.deinit();
            return result.takeBunString();
        }

        pub fn print(this: Self, message_type: jsc.ConsoleObject.MessageType, message_level: jsc.ConsoleObject.MessageLevel) void {
            jsc.ConsoleObject.messageWithTypeAndLevel(message_type, message_level, this.token.globalObject(), &.{this.asEngine()});
        }

        /// Calls `Object.hasOwnProperty(value)`.
        /// Returns true if the object has the property, false otherwise
        ///
        /// If the object is not an object, it will crash. **You must check if the object is an object before calling this function.**
        pub fn hasOwnPropertyValue(this: Self, key: EngineOperand) bun.JSError!bool {
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueHasOwnPropertySchema).call(.{
                .object = this.asEngine(),
                .key = key.asEngine(),
            });
        }

        pub fn arrayIterator(this: Self) bun.JSError!jsc.JSArrayIterator {
            const context = this.operationContext();
            return .{
                .len = try context.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = this.asEngine() }),
                .array = try this.asEngine().toRoot(),
            };
        }

        /// Decimal values are truncated without rounding.
        /// `NaN` coerces to 0. `-Infinity` coerces to minInt(i64).
        /// `Infinity` coerces to maxInt(i64).
        pub fn toInt64(this: Self) i64 {
            if (this.isInt32()) {
                return this.asInt32();
            }

            if (this.isNumber()) {
                return this.coerceDoubleTruncatingIntoInt64();
            }

            const value = this.raw();
            if (value.isBoolean()) return @intFromBool(value.asBoolean());
            if (value.isUndefinedOrNull()) return 0;
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueToInt64Schema).call(.{ .value = this.asEngine() });
        }

        pub fn asBigIntCompare(this: Self, other: EngineOperand) ComparisonResult {
            if (!this.isBigInt() or (!other.isBigInt() and !other.isNumber())) {
                return .invalid_comparison;
            }
            const engine_scope = this.operationContext();
            return @fromBackingInt(engine_scope.engine(JSValueCompareBigIntSchema).call(.{
                .left = this.asEngine(),
                .right = other.asEngine(),
            }));
        }

        pub const isAnyInt = UnaryOperation(JSValueIsAnyIntShim).call;

        pub fn isError(this: Self) bool {
            if (!this.isCell())
                return false;

            return this.jsType() == JSType.ErrorInstance;
        }

        pub fn isAnyError(this: Self) bool {
            if (!this.isCell())
                return false;
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueIsAnyErrorSchema).call(.{ .value = this.asEngine() });
        }

        /// Returns true if
        /// - `" string literal"`
        /// - `new String("123")`
        /// - `class DerivedString extends String; new DerivedString("123")`
        pub inline fn isString(this: Self) bool {
            if (!this.isCell())
                return false;

            return jsType(this).isStringLike();
        }

        /// Returns true only for string literals
        /// - `" string literal"`
        pub inline fn isStringLiteral(this: Self) bool {
            if (!this.isCell()) {
                return false;
            }

            return jsType(this).isString();
        }

        pub const isBigInt = UnaryOperation(JSValueIsBigIntShim).call;

        pub const isBigInt32 = UnaryOperation(JSValueIsBigInt32Shim).call;

        pub const isSymbol = UnaryOperation(JSValueIsSymbolShim).call;

        pub const isPrimitive = UnaryOperation(JSValueIsPrimitiveShim).call;

        pub inline fn isObject(this: Self) bool {
            return this.isCell() and this.jsType().isObject();
        }

        pub inline fn isArray(this: Self) bool {
            return this.isCell() and this.jsType().isArray();
        }

        pub fn isObjectEmpty(
            this: Self,
        ) bun.JSError!bool {
            const type_of_value = this.jsType();
            // https://github.com/jestjs/jest/blob/main/packages/jest-get-type/src/index.ts#L26
            // Map and Set are not considered as object in jest-extended
            if (type_of_value.isMap() or type_of_value.isSet() or this.isRegExp() or this.isDate()) {
                return false;
            }

            if (!this.isObject()) return false;
            const scope = this.operationContext();
            const keys = try scope.engine(JSValueKeysSchema).call(.{ .value = this.asEngine() });
            return try scope.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = keys.operand(&scope).asEngine() }) == 0;
        }

        pub const isClass = UnaryOperation(JSValueIsClassSchema).call;

        pub const getName = StringOperation(JSValueGetNameSchema).call;

        pub const getDeclaredName = StringOperation(JSValueGetDeclaredNameSchema).call;

        pub const isConstructorPrototype = UnaryOperation(JSValueIsConstructorPrototypeSchema).call;

        pub const isCallable = UnaryOperation(JSValueIsCallableShim).call;

        pub const isException = UnaryOperation(JSValueIsExceptionSchema).call;

        pub const isTerminationException = UnaryOperation(JSValueIsTerminationExceptionSchema).call;

        /// Increments the reference count, you must call `.deref()` or it will leak memory.
        pub const toBunString = StringOperation(JSValueToBunStringSchema).call;

        /// this: RegExp value
        /// other: string value
        pub fn toMatch(this: Self, other: EngineOperand) !bool {
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueToMatchShim).call(.{
                .regex = this.asEngine(),
                .value = other.asEngine(),
            });
        }

        pub const copyArrayBufferView = UnaryOperation(JSValueCopyArrayBufferViewSchema).call;

        pub const arrayBufferIsShared = UnaryOperation(JSValueArrayBufferIsSharedSchema).call;

        /// Convert a JSValue to a string, potentially calling `toString` on the
        /// JSValue in JavaScript. Can throw an error.
        ///
        /// This keeps the WTF::StringImpl alive if it was originally a latin1
        /// ASCII-only string.
        ///
        /// Otherwise, it will be cloned using the allocator.
        pub fn toSlice(this: Self, allocator: std.mem.Allocator) bun.JSError!bun.String.Slice {
            const str = try this.toBunString();
            defer str.deref();
            return str.toUTF8(allocator);
        }

        pub fn jsonStringify(this: Self, indent: u32) bun.JSError!?bun.bindgen.DOMString {
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSONStringifySchema).call(.{
                .input = .{ .value = this.asEngine(), .indent = indent },
            });
        }

        /// Omitting space allows the engine's fast JSON serialization path.
        pub const jsonStringifyFast = UnaryOperation(JSONStringifyFastSchema).call;

        /// Call `toString()` on the JSValue and clone the result.
        pub fn toSliceOrNull(
            this: Self,
        ) bun.JSError!bun.String.Slice {
            const str = try this.toBunString();
            defer str.deref();
            return str.toUTF8(bun.default_allocator);
        }

        pub fn getPrototype(
            this: Self,
        ) bun.JSError!EngineOperand {
            const scope = this.operationContext();
            const result = try scope.engine(JSValueGetPrototypeSchema).call(.{ .value = this.asEngine() });
            return result.operand(&scope).asEngine();
        }

        pub const eqlValue = BinaryOperation(JSValueEqualSchema, .operands).call;

        fn builtinName(property: []const u8) ?BuiltinName {
            const Schema = JSValueFastGetSchema.args[1].ArgumentType;
            inline for (Schema.enumeration_values) |Value| {
                if (std.mem.eql(u8, property, Value.js_value))
                    return @field(BuiltinName, Value.value_name);
            }
            return null;
        }

        // `this` must be known to be an object
        pub fn fastGet(this: Self, builtin_name: BuiltinName) bun.JSError!?EngineOperand {
            if (bun.Environment.isDebug)
                bun.assert(this.isObject());

            const scope = this.operationContext();
            const result = (try scope.engine(JSValueFastGetSchema).call(.{
                .value = this.asEngine(),
                .builtinId = builtin_name,
            })) orelse return null;
            return result.operand(&scope).asEngine();
        }

        pub fn isSymbolFor(value: Self, name: []const u8) bun.JSError!bool {
            var key = try bun.bindgen.DOMString.fromLatin1(name);
            defer key.deinit();
            const scope = value.operationContext();
            const symbol = try scope.engine(SymbolForSchema).call(.{ .key = key.operand() });
            return scope.engine(JSValueSameValueShim).call(.{ .operands = .{
                .left = value.asEngine(),
                .right = symbol.operand(&scope).asEngine(),
            } });
        }

        pub const getDescription = StringOperation(JSValueSymbolDescriptionSchema).call;

        /// Equivalent to `target[property]`. Calls userland getters/proxies.  Can
        /// throw. Zig null indicates the property does not exist OR its value is
        /// JS undefined (the two are not distinguished). JS null passes through
        /// as a value.
        ///
        /// `property` must be `[]const u8`. A comptime slice may defer to
        /// calling `fastGet`, which use a more optimal code path. This function is
        /// marked `inline` to allow Zig to determine if `fastGet` should be used
        /// per invocation.
        ///
        /// Cannot handle property names that are numeric indexes. (For this use `getPropertyValue` instead.)
        ///
        pub inline fn get(target: Self, property_slice: []const u8) bun.JSError!?EngineOperand {
            bun.debugAssert(target.isObject());

            // This call requires `get` to be `inline`
            if (bun.isComptimeKnown(property_slice)) {
                if (comptime builtinName(property_slice)) |builtin_name| {
                    return target.fastGet(builtin_name);
                }
            }

            var property = bun.bindgen.DOMString.fromUTF8(property_slice) catch return error.OutOfMemory;
            defer property.deinit();
            const scope = target.operationContext();
            const result = (try scope.engine(JSValueGetIfPropertyExistsSchema).call(.{
                .target = target.asEngine(),
                .property = property.operand(),
            })) orelse return null;
            return result.operand(&scope).asEngine();
        }

        /// Get *own* property value (i.e. does not resolve property in the prototype chain)
        pub fn getOwn(this: Self, property_name: anytype) bun.JSError!?EngineOperand {
            var bound_name = switch (@TypeOf(property_name)) {
                bun.String => try bun.bindgen.DOMString.fromBunString(property_name.dupeRef()),
                else => try bun.bindgen.DOMString.fromUTF8(property_name),
            };
            defer bound_name.deinit();
            const scope = this.operationContext();
            const result = (try scope.engine(JSValueGetOwnStringSchema).call(.{
                .value = this.asEngine(),
                .key = bound_name.operand(),
            })) orelse return null;
            return result.operand(&scope).asEngine();
        }

        pub const isStrictEqual = BinaryOperation(JSValueStrictEqualShim, .operands).call;

        /// Object.is()
        ///
        /// This algorithm differs from the IsStrictlyEqual Algorithm by treating all NaN values as equivalent and by differentiating +0𝔽 from -0𝔽.
        /// https://tc39.es/ecma262/#sec-samevalue
        ///
        /// This can throw because it resolves rope strings
        pub fn isSameValue(this: Self, other: EngineOperand) bun.JSError!bool {
            this.token.requireSameCall(other.token, this.token.globalObject(), "binding comparison has unrelated operands");
            if (@backingInt(this.value) == @backingInt(other.value)) return true;
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueSameValueShim).call(.{
                .operands = .{ .left = this.asEngine(), .right = other.asEngine() },
            });
        }

        pub const deepEquals = BinaryOperation(JSValueDeepEqualsSchema, .input).call;

        /// Deep equality with Jest asymmetric matchers.
        pub const jestDeepEquals = BinaryOperation(JSValueJestDeepEqualsSchema, .input).call;

        pub const strictDeepEquals = BinaryOperation(JSValueStrictDeepEqualsSchema, .input).call;

        /// Strict deep equality with Jest asymmetric matchers.
        pub const jestStrictDeepEquals = BinaryOperation(JSValueJestStrictDeepEqualsSchema, .input).call;

        /// Matches a subset with Jest asymmetric matchers.
        pub fn jestDeepMatch(this: Self, subset: EngineOperand, replace_props_with_asymmetric_matchers: bool) bun.JSError!bool {
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueJestDeepMatchSchema).call(.{
                .input = .{
                    .value = this.asEngine(),
                    .subset = subset.asEngine(),
                    .replaceProperties = replace_props_with_asymmetric_matchers,
                },
            });
        }

        /// Get the internal number of the `JSC::DateInstance` object
        /// Returns NaN if the value is not a `JSC::DateInstance` (`Date` in JS)
        pub const getUnixTimestamp = UnaryOperation(JSValueDateMillisecondsSchema).call;

        pub fn toFmt(this: Self, formatter: *jsc.ConsoleObject.Formatter) jsc.ConsoleObject.Formatter.ZigFormatter {
            return formatter.toFmt(this.asEngine());
        }

        /// Equivalent to the `!!` operator
        pub const toBoolean = UnaryOperation(JSValuePureToBooleanSchema).call;

        pub fn toInt32(this: Self) i32 {
            if (this.isInt32()) {
                return asInt32(this);
            }

            if (this.getNumber()) |num| {
                return std.math.lossyCast(i32, num);
            }

            const value = this.raw();
            if (value.isBoolean()) return @intFromBool(value.asBoolean());
            if (value.isUndefinedOrNull()) return 0;
            @panic("toInt32 requires a number, boolean, null, or undefined; coerce other values");
        }

        pub inline fn toU16(this: Self) u16 {
            return @intCast(@min(@max(this.toInt64(), 0), std.math.maxInt(u16)));
        }

        pub inline fn toU32(this: Self) u32 {
            return @as(u32, @intCast(@min(@max(this.toInt64(), 0), std.math.maxInt(u32))));
        }

        /// This function supports:
        /// - Array, DerivedArray & friends
        /// - String, DerivedString & friends
        /// - TypedArray
        /// - Map (size)
        /// - WeakMap (size)
        /// - Set (size)
        /// - ArrayBuffer (byteLength)
        /// - anything with a .length property returning a number
        ///
        /// If the "length" property does not exist, this function will return 0.
        pub fn getLength(
            this: Self,
        ) bun.JSError!u64 {
            const len = (try this.getLengthIfPropertyExists()) orelse return 0;
            if (!(len > 0)) return 0;
            return @intFromFloat(@min(len, std.math.maxInt(u53)));
        }

        pub const getLengthIfPropertyExists = UnaryOperation(JSValueLengthIfPropertyExistsSchema).call;

        pub const isAggregateError = UnaryOperation(JSValueIsAggregateErrorSchema).call;

        pub fn forEach(
            this: Self,
            ctx: anytype,
            comptime callback: *const fn (vm: *jsc.VM, globalObject: *jsc.JSGlobalObject, ctx: @TypeOf(ctx), nextValue: EngineOperand) void,
        ) bun.JSError!void {
            const globalObject = this.token.globalObject();
            const engine_scope = this.operationContext();
            const input = this.asEngine();
            const iterator = try engine_scope.engine(IterableIteratorCreateSchema).call(.{ .value = input.operand(&engine_scope).asEngine() }) orelse return;
            defer bun.bindgen.Engine(IterableIteratorDestroySchema).call(.{ .iterator = iterator });

            while (true) {
                const next = try engine_scope.engine(IterableIteratorNextSchema).call(.{ .iterator = iterator }) orelse break;
                const value = next.operand(&engine_scope).asEngine();
                callback(globalObject.vm(), globalObject, ctx, value);
                value.ensureStillAlive();
                if (globalObject.hasException()) {
                    var original = try engine_scope.takeThrownException(error.JSError);
                    defer original.deinit();
                    engine_scope.engine(IterableIteratorCloseSchema).call(.{ .iterator = iterator }) catch |failure| {
                        var closing = try engine_scope.takeThrownException(failure);
                        closing.deinit();
                    };
                    return original.throwException(&engine_scope);
                }
            }
        }

        pub const isIterable = UnaryOperation(JSValueIsIterableSchema).call;

        pub fn stringIncludes(this: Self, other: EngineOperand) bun.JSError!bool {
            const engine_scope = this.operationContext();
            return engine_scope.engine(JSValueStringIncludesSchema).call(.{
                .value = this.asEngine(),
                .search = other.asEngine(),
            });
        }

        pub const isAsyncContextFrame = UnaryOperation(JSValueIsAsyncContextFrameShim).call;

        /// Asserts `this` is a proxy
        pub fn getProxyInternalField(this: Self, field: ProxyInternalField) bun.JSError!?EngineOperand {
            const scope = this.operationContext();
            const result = (try scope.engine(ProxyObjectGetInternalFieldSchema).call(.{
                .value = this.asEngine(),
                .field = @backingInt(field),
            })) orelse return null;
            return result.operand(&scope).asEngine();
        }

        /// For native C++ classes extending JSCell, this retrieves s_info's name
        /// This is a readonly ASCII string.
        pub fn getClassInfoName(
            this: Self,
        ) bun.JSError!?bun.String {
            if (!this.isCell()) return null;
            const engine_scope = this.operationContext();
            if (try engine_scope.engine(JSValueClassInfoNameSchema).call(.{ .value = this.asEngine() })) |name| {
                var result = name;
                defer result.deinit();
                return result.takeBunString();
            }
            return null;
        }

        pub fn isInt32(this: Self) bool {
            return this.raw().isInt32();
        }
        pub fn asBoolean(this: Self) bool {
            return this.raw().asBoolean();
        }
        pub fn isCell(this: Self) bool {
            return this.raw().isCell();
        }
        pub fn getNumber(this: Self) ?f64 {
            return this.raw().getNumber();
        }
        pub fn asNumber(this: Self) f64 {
            return this.raw().asNumber();
        }
        pub fn isUndefined(this: Self) bool {
            return this.raw().isUndefined();
        }
        pub fn isUndefinedOrNull(this: Self) bool {
            return this.raw().isUndefinedOrNull();
        }
        pub fn isDouble(this: Self) bool {
            return this.raw().isDouble();
        }
        pub fn isEmptyOrUndefinedOrNull(this: Self) bool {
            return this.raw().isEmptyOrUndefinedOrNull();
        }
        pub fn isNull(this: Self) bool {
            return this.raw().isNull();
        }
        pub fn isNumber(this: Self) bool {
            return this.raw().isNumber();
        }
        pub fn asDouble(this: Self) f64 {
            return this.raw().asDouble();
        }
        pub fn asInt32(this: Self) i32 {
            return this.raw().asInt32();
        }
        pub fn coerceDoubleTruncatingIntoInt64(this: Self) i64 {
            return this.raw().coerceDoubleTruncatingIntoInt64();
        }

        pub fn isBoolean(this: Self) bool {
            return this.raw().isBoolean();
        }

        pub const JSType = jsc.JSValue.JSType;
        const JestPrettyFormat = @import("../test_runner/PrettyFormatEngine.zig").JestPrettyFormat;
        const JSStringBindings = bun.bindgen.Module("js_strings");
        const ErrorBindings = bun.bindgen.Module("errors");
        const JSValueInspectionBindings = bun.bindgen.Module("js_value_inspection");
        const BigIntBindings = bun.bindgen.Module("bigints");
        const ArrayBufferBindings = bun.bindgen.Module("array_buffers");
        const PropertyAccessorBindings = bun.bindgen.Module("property_accessors");
        const SymbolBindings = bun.bindgen.Module("symbols");
        const JSONSerializationBindings = bun.bindgen.Module("json_serialization");
        const DateTimeBindings = bun.bindgen.Module("date_time");
        const JSValueConversionBindings = bun.bindgen.Module("js_value_conversions");
        const RegularExpressionBindings = bun.bindgen.Module("regular_expressions");
        const PropertyIteratorBindings = bun.bindgen.Module("property_iterators");
        const IterableIteratorBindings = bun.bindgen.Module("iterable_iterators");
        const JSValueIsAnyIntShim = JSValueInspectionBindings.engineShim("jsValueIsAnyInt");
        const JSValueIsBigIntShim = BigIntBindings.engineShim("jsValueIsBigInt");
        const JSValueIsBigInt32Shim = BigIntBindings.engineShim("jsValueIsBigInt32");
        const JSValueIsCallableShim = JSValueInspectionBindings.engineShim("jsValueIsCallable");
        const JSValueIsPrimitiveShim = JSValueInspectionBindings.engineShim("jsValueIsPrimitive");
        const JSValueIsBufferShim = ArrayBufferBindings.engineShim("jsValueIsBuffer");
        const JSValueIsAsyncContextFrameShim = AsyncHooksBindings.engineShim("jsValueIsAsyncContextFrame");
        const JSValueIsSymbolShim = JSValueInspectionBindings.engineShim("jsValueIsSymbol");
        const JSValueStrictEqualShim = JSValueInspectionBindings.engineShim("jsValueStrictEqual");
        const JSValueSameValueShim = JSValueInspectionBindings.engineShim("jsValueSameValue");
        const JSValueCoerceToInt32Shim = JSValueConversionBindings.engineShim("jsValueCoerceToInt32");
        const JSValueCoerceToInt64Shim = JSValueConversionBindings.engineShim("jsValueCoerceToInt64");
        const JSValueToNumberSchema = JSValueConversionBindings.engineShim("jsValueToNumber");
        const JSValueToMatchShim = RegularExpressionBindings.engineShim("jsValueToMatch");
        const JSValueToBunStringSchema = JSStringBindings.engineShim("stringFromJS");
        const ConsolePropertyIteratorCreateSchema = PropertyIteratorBindings.engineShim("consolePropertyIteratorCreate");
        const ConsolePropertyIteratorGetEntrySchema = PropertyIteratorBindings.engineShim("consolePropertyIteratorGetEntry");
        const ConsolePropertyIteratorDestroySchema = PropertyIteratorBindings.engineShim("consolePropertyIteratorDestroy");
        const IterableIteratorCreateSchema = IterableIteratorBindings.engineShim("iterableIteratorCreate");
        const IterableIteratorNextSchema = IterableIteratorBindings.engineShim("iterableIteratorNext");
        const IterableIteratorCloseSchema = IterableIteratorBindings.engineShim("iterableIteratorClose");
        const IterableIteratorDestroySchema = IterableIteratorBindings.engineShim("iterableIteratorDestroy");
        const JSValueToInt64Schema = JSValueConversionBindings.engineShim("jsValueToInt64");
        const JSValueTypeSchema = JSValueInspectionBindings.engineShim("jsValueType");
        const JSValueProxyTargetSchema = JSValueInspectionBindings.engineShim("jsValueProxyTarget");
        const JSValueIsAnyErrorSchema = ErrorBindings.engineShim("jsValueIsAnyError");
        const JSValueIsTerminationExceptionSchema = ErrorBindings.engineShim("jsValueIsTerminationException");
        const JSValueEqualSchema = JSValueInspectionBindings.engineShim("jsValueEqual");
        const JSValueDateMillisecondsSchema = DateTimeBindings.engineShim("jsValueDateMilliseconds");
        const JSValuePureToBooleanSchema = JSValueConversionBindings.engineShim("jsValuePureToBoolean");
        const JSValueIsClassSchema = JSValueInspectionBindings.engineShim("jsValueIsClass");
        const JSValueIsAggregateErrorSchema = ErrorBindings.engineShim("jsValueIsAggregateError");
        const JSValueGetPrototypeSchema = JSValueInspectionBindings.engineShim("jsValueGetPrototype");
        const JSValueFastGetSchema = PropertyAccessorBindings.engineShim("jsValueFastGet");
        const JSONStringifySchema = JSONSerializationBindings.engineShim("jsonStringify");
        const JSONStringifyFastSchema = JSONSerializationBindings.engineShim("jsonStringifyFast");
        const SymbolForSchema = SymbolBindings.engineShim("symbolFor");
        const JSValueSymbolDescriptionSchema = SymbolBindings.engineShim("jsValueSymbolDescription");
        const JSValueIsInstanceOfSchema = JSValueInspectionBindings.engineShim("jsValueIsInstanceOf");
        const JSValueIsIterableSchema = JSValueInspectionBindings.engineShim("jsValueIsIterable");
        const JSValueStringIncludesSchema = JSStringBindings.engineShim("jsValueStringIncludes");
        const JSValueDeepEqualsSchema = JSValueInspectionBindings.engineShim("jsValueDeepEquals");
        const JSValueJestDeepEqualsSchema = JSValueInspectionBindings.engineShim("jsValueJestDeepEquals");
        const JSValueStrictDeepEqualsSchema = JSValueInspectionBindings.engineShim("jsValueStrictDeepEquals");
        const JSValueJestStrictDeepEqualsSchema = JSValueInspectionBindings.engineShim("jsValueJestStrictDeepEquals");
        const JSValueJestDeepMatchSchema = JSValueInspectionBindings.engineShim("jsValueJestDeepMatch");
        const JSValueLengthIfPropertyExistsSchema = JSValueInspectionBindings.engineShim("jsValueLengthIfPropertyExists");
        const JSValueHasOwnPropertySchema = PropertyAccessorBindings.engineShim("jsValueHasOwnProperty");
        const JSValueGetOwnStringSchema = PropertyAccessorBindings.engineShim("jsValueGetOwnString");
        const JSValueGetNameSchema = JSValueInspectionBindings.engineShim("jsValueGetName");
        const JSValueGetDeclaredNameSchema = JSValueInspectionBindings.engineShim("jsValueGetDeclaredName");
        const JSValueIsConstructorPrototypeSchema = JSValueInspectionBindings.engineShim("jsValueIsConstructorPrototype");
        const JSValueClassNameSchema = JSValueInspectionBindings.engineShim("jsValueClassName");
        const JSValueClassInfoNameSchema = JSValueInspectionBindings.engineShim("jsValueClassInfoName");
        const ProxyObjectGetInternalFieldSchema = JSValueInspectionBindings.engineShim("proxyObjectGetInternalField");
        const JSValueIsExceptionSchema = ErrorBindings.engineShim("jsValueIsException");
        const JSValueCompareBigIntSchema = BigIntBindings.engineShim("jsValueCompareBigInt");
        const JSValueGetIfPropertyExistsSchema = PropertyAccessorBindings.engineShim("getIfPropertyExists");
        const JSValueGetIndexSchema = PropertyAccessorBindings.engineShim("jsValueGetIndex");
        const JSValueKeysSchema = PropertyAccessorBindings.engineShim("jsValueKeys");
        const JSValueCallSchema = JSFunctionBindings.engineShim("jsValueCall");
        const JSValueCopyArrayBufferViewSchema = ArrayBufferBindings.engineShim("jsValueCopyArrayBufferView");
        const JSValueArrayBufferIsSharedSchema = ArrayBufferBindings.engineShim("jsValueArrayBufferIsShared");

        pub fn ensureStillAlive(this: Self) void {
            this.token.requireActive();
            std.mem.doNotOptimizeAway(this.value);
        }

        pub const brand = Brand;
        pub const bindgen_focused_value_access = access;
    };
}

pub const AnyOperand = ValueOperand(.any, void);
pub const EngineOperand = ValueOperand(.engine, void);
const PromiseOperand = ValueOperand(.branded, PromiseSemanticType.Brand);

pub const FocusedEngineScope = struct {
    active_call_scope: ActiveCallScope,
    token: ViewToken,
    active: bool,

    pub const bindgen_focused_engine_scope = {};

    const Self = @This();
    const Operations = ContextOperations(*Self);

    pub const engineIn = Operations.engineIn;
    pub const engine = Operations.engine;
    pub const tryTakeException = Operations.tryTakeException;
    pub const takeException = Operations.takeException;
    pub const takeThrownException = Operations.takeThrownException;
    pub const takeThrownValue = Operations.takeThrownValue;
    pub const reportUncaughtException = Operations.reportUncaughtException;
    pub const reportUnhandledRejection = Operations.reportUnhandledRejection;
    pub const runErrorHandler = Operations.runErrorHandler;
    pub const waitForPromiseRejection = Operations.waitForPromiseRejection;
    pub const waitForPromiseResult = Operations.waitForPromiseResult;
    pub const reportUnhandledException = Operations.reportUnhandledException;
    pub const collectUnhandledException = Operations.collectUnhandledException;

    pub fn init(scope: *Self, global: *jsc.JSGlobalObject) void {
        scope.initStoredRealm(@ptrCast(global));
    }

    fn initStoredRealm(scope: *Self, realm: *StoredRealmHandle) void {
        const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(realm));
        const call_id = nextCallbackInvocationCallId();
        scope.* = .{
            .active_call_scope = undefined,
            .token = undefined,
            .active = true,
        };
        scope.active_call_scope.init(call_id, global);
        scope.token = scope.active_call_scope.token();
    }

    pub fn deinit(scope: *Self) void {
        scope.requireActive();
        scope.active = false;
        scope.active_call_scope.deinit();
    }

    fn borrowEngineValue(scope: *Self, value: jsc.JSValue) EngineOperand {
        scope.requireActive();
        return EngineOperand.init(value, scope.token);
    }

    pub fn viewToken(scope: *Self) ViewToken {
        scope.requireActive();
        return scope.token;
    }

    pub fn reportPendingException(scope: *Self, failure: bun.JSError) bun.JSTerminated!bool {
        scope.requireActive();
        if (failure == error.JSTerminated) return error.JSTerminated;
        const exception = scope.takeException(failure);
        if (scope.engineIn("errors", "jsValueIsTerminationException").call(.{ .value = exception.operand(scope).asEngine() })) return error.JSTerminated;
        return scope.reportUncaughtException(exception.operand(scope).asAny(), false);
    }

    pub fn runPendingErrorHandler(scope: *Self) bool {
        scope.requireActive();
        const exception = scope.tryTakeException() orelse return false;
        scope.runErrorHandler(exception.operand(scope).asAny());
        return true;
    }

    fn requireActive(scope: *const Self) void {
        if (!scope.active) @panic("focused engine scope is inactive");
        scope.token.requireActive();
    }
};

pub fn Escape(comptime File: type) type {
    const files = @import("binding_implementations").source_files;
    for (Manifest.binding().focused_integrations) |path| {
        if (@hasDecl(files, path) and File == @field(files, path)) return EngineEscapes;
    }
    @compileError(@typeName(File) ++ " is not listed in FocusedEngineIntegrations.schema.zig");
}

const EngineEscapes = struct {
    pub fn borrowEngineValue(context: anytype, value: jsc.JSValue) EngineOperand {
        return EngineOperand.init(value, context.viewToken());
    }

    pub fn rawCallScopedValue(context: anytype, value: anytype) jsc.JSValue {
        const token = context.viewToken();
        return readCallScopedJSValue(token.globalObject(), token, value);
    }

    pub fn borrowResultValue(realm: anytype, result: anytype) jsc.JSValue {
        return bindingResultRawValue(escapeRealm(realm), result);
    }

    pub fn rootValue(realm: anytype, root: anytype) jsc.JSValue {
        const RootType = switch (@typeInfo(@TypeOf(root))) {
            .pointer => |pointer| pointer.child,
            else => @compileError("focused root access requires a root pointer"),
        };
        if (comptime RootType != Root and RootType != EngineRoot) {
            @compileError("focused root access requires Root or EngineRoot");
        }
        root.requireCurrentVM(escapeRealm(realm));
        return root.rawValue();
    }

    pub fn optionalRootValue(realm: anytype, root: anytype) ?jsc.JSValue {
        const OptionalType = switch (@typeInfo(@TypeOf(root))) {
            .pointer => |pointer| pointer.child,
            else => @compileError("focused optional-root access requires a pointer"),
        };
        if (comptime OptionalType != Root.Optional and
            OptionalType != EngineRoot.Optional and
            OptionalType != PromiseRoot.Optional)
        {
            @compileError("focused optional-root access requires a bindgen optional root");
        }
        const impl = root.impl orelse return null;
        if (!impl.belongsToCurrentVM(escapeRealm(realm))) {
            @panic("binding optional root read from a different VM");
        }
        return impl.get(impl.globalObject());
    }

    pub fn brandedValue(realm: anytype, value: anytype) jsc.JSValue {
        const Value = switch (@typeInfo(@TypeOf(value))) {
            .pointer => |pointer| pointer.child,
            else => @TypeOf(value),
        };
        if (comptime !@hasDecl(Value, "bindgen_owned_branded_value")) {
            @compileError("focused branded access requires an owned branded value");
        }
        const global = escapeRealm(realm);
        if (value.root.globalObject() != global) {
            @panic("owned branded value used in a different realm");
        }
        value.root.requireCurrentVM(global);
        return value.root.rawValue();
    }

    pub fn setOptionalEngineValue(realm: anytype, slot: *EngineRoot.Optional, value: jsc.JSValue) bun.JSError!void {
        try slot.setValue(escapeRealm(realm), value);
    }
};

fn escapeRealm(realm: anytype) *jsc.JSGlobalObject {
    return if (@TypeOf(realm) == *jsc.JSGlobalObject) realm else realm.viewToken().globalObject();
}

fn bindingResultRawValue(global: *jsc.JSGlobalObject, result: anytype) jsc.JSValue {
    const Result = switch (@typeInfo(@TypeOf(result))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("focused result access requires a result pointer"),
    };
    if (comptime !@hasDecl(Result, "bindgen_value_result")) {
        @compileError("focused result access requires a generated JavaScript-value result");
    }
    if (result.token.globalObject() != global) {
        @panic("binding result used in a different realm");
    }
    return result.rawValue();
}

fn reportDeclaredUnhandledRejection(context: anytype, reason: AnyOperand, promise: PromiseOperand) void {
    const global = context.viewToken().globalObject();
    const token = context.viewToken();
    const value = promise.rawValueForEngine(global, token);
    if (promise.asEngine().jsType() != .JSPromise) @panic("unhandled rejection requires a promise");
    global.bunVM().unhandledRejection(
        context,
        EngineValueResult.initInline(reason.rawValueForEngine(global, token), global, token, .engine),
        PromiseResult.initInline(value, global, token, .branded),
    );
}

threadlocal var next_callback_invocation_call_id: u64 = 1 << 63;

fn nextCallbackInvocationCallId() u64 {
    const id = next_callback_invocation_call_id;
    if (id == 0 or id == std.math.maxInt(u64)) {
        @panic("binding callback invocation call ID space was exhausted");
    }
    next_callback_invocation_call_id += 1;
    return id;
}

const CompletionDisposition = enum(wire.BindCompletionDisposition) {
    value = wire.BIND_COMPLETION_VALUE,
    domain_error = wire.BIND_COMPLETION_DOMAIN_ERROR,
    drop_reject = wire.BIND_COMPLETION_DROP_REJECT,
    cancel = wire.BIND_COMPLETION_CANCEL,
    leave_pending = wire.BIND_COMPLETION_LEAVE_PENDING,
    out_of_memory = wire.BIND_COMPLETION_OUT_OF_MEMORY,
    pending_exception = wire.BIND_COMPLETION_PENDING_EXCEPTION,
    materialized = 7,
    retained_rejection = 8,
    adopted_promise = 9,
};

fn completionDispositionOwnsPayload(disposition: CompletionDisposition) bool {
    return disposition == .value or
        disposition == .domain_error or
        disposition == .materialized;
}

const completion_allocator = bun.default_allocator;

const ReadyCompletionDeliveryScope = struct {
    context: ?NativeCallbackContext(.vm),
    finish: *const fn (NativeCallbackContext(.vm)) void,
    vm: *jsc.VirtualMachine,

    pub fn deinit(scope: *@This()) void {
        const context = bun.take(&scope.context) orelse return;
        if (scope.vm != jsc.VirtualMachine.getOrNull())
            @panic("binding completion delivery requires its VM thread");
        scope.finish(context);
    }
};

fn CompletionTypes(comptime Function: type) type {
    if (!Function.is_async) @compileError("completion types require an asynchronous binding");
    const WireResult = wireType(Function.wire_result);
    const Result_ = struct {
        const Namespace = @This();
        pub const AdoptedPromise = OwnedBrandedValueType(Manifest.SemanticType(Manifest.get(Function.completion.promise).type));

        const State = enum(u8) {
            open,
            writing,
            queued,
            delivered,
            detached,
            detached_completed,
        };

        const MaterializedAttachment = struct {
            context: NativeCallbackContext(.vm),
            destroy: *const fn (NativeCallbackContext(.vm)) void,
        };

        const MaterializedOps = struct {
            deliver: *const fn (*jsc.JSGlobalObject, PromiseResult, ?NativeCallbackContext(.vm), NativeCallbackContext(.vm)) bun.JSError!void,
            destroy_payload: *const fn (NativeCallbackContext(.vm)) void,
        };

        const Control = struct {
            state: std.atomic.Value(State) = .init(.open),
            references: std.atomic.Value(usize) = .init(2),
            senders: std.atomic.Value(usize) = .init(1),
            disposition: CompletionDisposition = undefined,
            result: WireResult = std.mem.zeroes(WireResult),
            materialized_payload: ?NativeCallbackContext(.vm) = null,
            materialized_ops: ?*const MaterializedOps = null,
            registry: *jsc.NativeCompletionRegistry,
            entry: jsc.NativeCompletionRegistry.Entry = undefined,
            invocation_active: bool = false,

            fn retain(control: *Control) void {
                const references = control.references.fetchAdd(1, .monotonic);
                if (references == 0 or references == std.math.maxInt(usize))
                    @panic("binding completion retained an invalid control block");
            }

            fn addSender(control: *Control) void {
                control.retain();
                _ = control.senders.fetchAdd(1, .monotonic);
                const state = control.state.load(.acquire);
                if (state != .open and state != .detached) {
                    _ = control.senders.fetchSub(1, .monotonic);
                    control.dropReference();
                    @panic("binding completion was cloned after completion");
                }
            }

            fn claim(control: *Control) ?State {
                const state = control.state.cmpxchgStrong(.open, .writing, .acq_rel, .acquire) orelse return null;
                if (state == .detached) {
                    return control.state.cmpxchgStrong(.detached, .detached_completed, .acq_rel, .acquire) orelse .detached;
                }
                return state;
            }

            fn enqueue(control: *Control, disposition: CompletionDisposition) void {
                if (Function.completion.error_delivery == .vm and disposition == .domain_error)
                    @panic("VM-materialized error payload entered a completion sender");
                control.disposition = disposition;
                if (control.state.cmpxchgStrong(.writing, .queued, .acq_rel, .acquire)) |state| {
                    if (state != .detached_completed) @panic("binding completion entered an invalid state while completing");
                    if (completionDispositionOwnsPayload(disposition)) control.destroyPayload();
                    return;
                }
                _ = control.registry.submit(&control.entry);
            }

            fn releaseSender(control: *Control, force_cancel: bool) void {
                const senders = control.senders.fetchSub(1, .acq_rel);
                if (senders == 0) @panic("binding completion sender was released twice");
                if (senders == 1 and control.claim() == null) {
                    control.result = std.mem.zeroes(WireResult);
                    control.enqueue(if (force_cancel) .cancel else configuredDropDisposition(Function));
                }
                control.dropReference();
            }

            fn destroyPayload(control: *Control) void {
                switch (control.disposition) {
                    .value, .domain_error => destroyResultPayload(Function, &control.result),
                    .materialized => {
                        const payload = control.materialized_payload orelse
                            @panic("binding materialized completion payload is null");
                        control.materialized_payload = null;
                        control.materialized_ops.?.destroy_payload(payload);
                    },
                    .drop_reject, .cancel, .leave_pending, .out_of_memory, .pending_exception, .adopted_promise, .retained_rejection => @panic("binding completion disposition does not own a payload"),
                }
            }

            fn configureMaterialized(
                control: *Control,
                ops: *const MaterializedOps,
                attachment: ?MaterializedAttachment,
            ) void {
                const state = control.state.load(.acquire);
                if (state != .open and state != .detached) {
                    @panic("binding completion materializer was configured after completion");
                }
                if (control.materialized_ops != null) {
                    @panic("binding completion materializer was configured twice");
                }
                control.materialized_ops = ops;
                if (state == .detached) {
                    if (attachment) |owned| owned.destroy(owned.context);
                    return;
                }
                const endpoint = control.entry.context.get(*Endpoint);
                if (endpoint.materialized_attachment != null) {
                    @panic("binding completion attachment was configured twice");
                }
                endpoint.materialized_attachment = attachment;
            }

            fn dropReference(control: *Control) void {
                const references = control.references.fetchSub(1, .acq_rel);
                if (references == 0) @panic("binding completion reference count underflowed");
                if (references == 1) {
                    const registry = control.registry;
                    completion_allocator.destroy(control);
                    registry.release();
                }
            }
        };

        const Endpoint = struct {
            const PromiseStorage = if (Function.completion.retention == .weak) WeakStorage else PromiseRoot.Optional;
            const Retained = union(enum) { none, promise: Root, rejection: MaterializedRejection };

            global: *jsc.JSGlobalObject,
            async_task: jsc.Debugger.AsyncTaskTracker,
            async_task_state: enum { unscheduled, scheduled, settled } = .unscheduled,
            promise: PromiseStorage = .{},
            activity_loop: ?*jsc.EventLoop = null,
            materialized_attachment: ?MaterializedAttachment = null,
            retained: Retained = .none,
            control: *Control,

            fn deliverOpaque(context: NativeCallbackContext(.vm)) void {
                const endpoint = context.get(*Endpoint);
                endpoint.run();
            }

            fn detachOpaque(context: NativeCallbackContext(.vm)) void {
                const endpoint = context.get(*Endpoint);
                endpoint.detach();
            }

            fn run(endpoint: *Endpoint) void {
                const control = endpoint.control;
                if (control.state.load(.acquire) != .queued) {
                    @panic("binding completion delivery ran in an invalid state");
                }
                const promise_value = (endpoint.promiseValue() catch |err| {
                    const global = endpoint.global;
                    endpoint.discardDelivery();
                    global.reportActiveExceptionAsUnhandled(err);
                    return;
                }) orelse {
                    endpoint.discardDelivery();
                    return;
                };
                defer promise_value.ensureStillAlive();
                var settlement_scope: FocusedEngineScope = undefined;
                settlement_scope.init(endpoint.global);
                defer settlement_scope.deinit();
                const promise_result = PromiseResult.initInline(promise_value, endpoint.global, settlement_scope.token, .branded);
                const dispatches = control.disposition != .cancel and control.disposition != .leave_pending;
                if (dispatches)
                    endpoint.async_task.willDispatch(endpoint.global)
                else
                    endpoint.settleAsyncTask(false);
                if (control.disposition == .materialized) {
                    const payload = control.materialized_payload orelse
                        @panic("binding materialized completion payload is null");
                    const attachment = if (endpoint.materialized_attachment) |owned| owned.context else null;
                    control.materialized_ops.?.deliver(endpoint.global, promise_result, attachment, payload) catch |err|
                        Namespace.deliverFailure(endpoint.global, promise_value, err);
                    control.destroyPayload();
                } else if (control.disposition == .retained_rejection) {
                    var rejection = endpoint.takeRetained(.rejection);
                    defer rejection.value.deinit();
                    rejection.deliver(&settlement_scope, promise_result) catch |err|
                        Namespace.deliverFailure(endpoint.global, promise_value, err);
                } else if (control.disposition == .adopted_promise) {
                    var adopted = endpoint.takeRetained(.promise);
                    defer adopted.deinit();
                    adopted.requireCurrentVM(endpoint.global);
                    settlement_scope.engineIn("promises", "promiseResolve").call(.{
                        .promise = promise_result.operand(&settlement_scope),
                        .value = settlement_scope.borrowEngineValue(adopted.rawValue()),
                    }) catch |err| Namespace.deliverFailure(endpoint.global, promise_value, err);
                } else {
                    Namespace.deliverWire(endpoint.global, promise_value, control.disposition, &control.result);
                }
                if (dispatches) endpoint.settleAsyncTask(true);
                control.state.store(.delivered, .release);
                endpoint.finish();
            }

            fn detach(endpoint: *Endpoint) void {
                const control = endpoint.control;
                var previous = control.state.load(.acquire);
                while (true) {
                    const detached: State = switch (previous) {
                        .open => .detached,
                        .writing, .queued => .detached_completed,
                        .delivered, .detached, .detached_completed => @panic("binding completion endpoint detached twice"),
                    };
                    previous = control.state.cmpxchgStrong(previous, detached, .acq_rel, .acquire) orelse break;
                }
                switch (previous) {
                    .open, .writing => {},
                    .queued => if (completionDispositionOwnsPayload(control.disposition)) control.destroyPayload(),
                    .delivered, .detached, .detached_completed => unreachable,
                }
                endpoint.settleAsyncTask(false);
                endpoint.finish();
            }

            fn settleAsyncTask(endpoint: *Endpoint, comptime dispatched: bool) void {
                if (endpoint.async_task_state == .settled) @panic("binding completion async task settled twice");
                if (dispatched) {
                    if (endpoint.async_task_state != .scheduled) @panic("binding completion dispatched an unscheduled async task");
                    endpoint.async_task.didDispatch(endpoint.global);
                } else if (endpoint.async_task_state == .scheduled) {
                    endpoint.async_task.didCancel(endpoint.global);
                }
                endpoint.async_task_state = .settled;
            }

            fn discardDelivery(endpoint: *Endpoint) void {
                const control = endpoint.control;
                endpoint.settleAsyncTask(false);
                if (completionDispositionOwnsPayload(control.disposition)) control.destroyPayload();
                control.state.store(.delivered, .release);
                endpoint.finish();
            }

            fn promiseValue(endpoint: *Endpoint) bun.JSError!?jsc.JSValue {
                return endpoint.promise.get();
            }

            fn takeRetained(endpoint: *Endpoint, comptime tag: std.meta.Tag(Retained)) @FieldType(Retained, @tagName(tag)) {
                if (std.meta.activeTag(endpoint.retained) != tag) @panic("binding completion has the wrong retained value");
                const value = @field(endpoint.retained, @tagName(tag));
                endpoint.retained = .none;
                return value;
            }

            fn finish(endpoint: *Endpoint) void {
                if (endpoint.async_task_state != .settled) @panic("binding completion destroyed with an unsettled async task");
                const control = endpoint.control;
                endpoint.promise.deinit();
                var retained = endpoint.retained;
                endpoint.retained = .none;
                switch (retained) {
                    .none => {},
                    .promise => |*promise| promise.deinit(),
                    .rejection => |*rejection| rejection.value.deinit(),
                }
                if (bun.take(&endpoint.materialized_attachment)) |attachment| attachment.destroy(attachment.context);
                if (endpoint.activity_loop) |event_loop| {
                    endpoint.activity_loop = null;
                    event_loop.unrefConcurrently();
                }
                completion_allocator.destroy(endpoint);
                control.dropReference();
            }
        };

        pub const View = struct {
            control: *Control,
            token: ViewToken,
            taken: *bool,

            const Self = @This();

            fn requireAvailable(view: *Self) void {
                view.token.requireActive();
                if (view.taken.*) @panic("binding completion view was taken twice");
            }

            pub fn take(view: *Self) Owned {
                view.requireAvailable();
                view.taken.* = true;
                return .{ .control = view.control };
            }

            pub fn resolve(view: *Self, value: Api(Function.result_position)) void {
                if (Function.completion.delivery == .vm) {
                    @compileError("VM-materialized completions must use MaterializedCompletion");
                }
                var owned = view.take();
                owned.resolve(value);
            }

            pub fn fail(
                view: *Self,
                comptime tag: FailureTagType(Function),
                payload: FailurePayloadApiType(Function, tag),
            ) void {
                var owned = view.take();
                owned.fail(tag, payload);
            }

            pub fn outOfMemory(view: *Self) void {
                var owned = view.take();
                owned.outOfMemory();
            }

            pub fn reject(
                view: *Self,
                value: *Root,
                rejection_options: CompletionRejectionOptions,
            ) void {
                var owned = view.take();
                owned.reject(value, rejection_options);
            }

            pub fn adoptPromise(view: *Self, promise: *AdoptedPromise) void {
                var owned = view.take();
                owned.adoptPromise(promise);
            }
        };

        pub const Owned = struct {
            control: ?*Control,

            pub const bindgen_gc_token = gc_token.markerWithAffinity(
                @This(),
                if (Function.completion.delivery == .vm) .vm else .any,
            );

            const Self = @This();

            pub fn clone(owned: *const Self) Self {
                const control = owned.requireControl();
                control.addSender();
                return .{ .control = control };
            }

            fn readyDeliveryScope(owned: *const Self, global: *jsc.JSGlobalObject) ReadyCompletionDeliveryScope {
                if (comptime Function.completion.settlement != .ready_at_return)
                    @compileError("ready completion delivery requires ready-at-return settlement");
                const vm = global.bunVM();
                if (vm != jsc.VirtualMachine.getOrNull())
                    @panic("binding completion delivery requires its VM thread");
                const control = owned.requireControl();
                const state = control.state.load(.acquire);
                if (state != .open and state != .detached)
                    @panic("binding completion delivery scope started after completion");
                if (state == .open) {
                    const endpoint = control.entry.context.get(*Endpoint);
                    if (endpoint.global.bunVM() != vm)
                        @panic("binding completion delivered from a different VM");
                }
                control.retain();
                return .{ .context = NativeCallbackContext(.vm).init(control), .finish = finishReadyDelivery, .vm = vm };
            }

            fn finishReadyDelivery(context: NativeCallbackContext(.vm)) void {
                const control = context.get(*Control);
                defer control.dropReference();
                // The originating binding must validate its return status before settlement.
                if (control.invocation_active) return;
                _ = control.registry.deliverReady(&control.entry);
            }

            pub fn resolve(owned: *Self, value: Api(Function.result_position)) void {
                if (Function.completion.delivery == .vm) {
                    @compileError("VM-materialized completions must use MaterializedCompletion");
                }
                owned.completeWire(null, value);
            }

            pub fn fail(
                owned: *Self,
                comptime tag: FailureTagType(Function),
                payload: FailurePayloadApiType(Function, tag),
            ) void {
                comptime Manifest.validateCompletionSenderFailure(Function.completion);
                owned.completeWire(tag, payload);
            }

            fn completeWire(owned: *Self, comptime failure: ?FailureTagType(Function), payload: anytype) void {
                const control = owned.consume();
                const state = control.claim();
                if (state != null and state != .detached) {
                    control.releaseSender(false);
                    @panic("binding completion was completed twice");
                }
                defer control.releaseSender(false);
                var result = if (failure) |tag| encodeFailure(Function, tag, payload) else encodeResult(Function, payload);
                if (state == .detached) {
                    destroyResultPayload(Function, &result);
                    return;
                }
                control.result = result;
                control.enqueue(if (failure == null) .value else .domain_error);
            }

            fn resolveMaterialized(
                owned: *Self,
                payload: NativeCallbackContext(.vm),
                ops: *const MaterializedOps,
            ) void {
                const control = owned.consume();
                defer control.releaseSender(false);
                if (control.materialized_ops != ops) {
                    ops.destroy_payload(payload);
                    control.releaseSender(false);
                    @panic("binding completion used the wrong materializer");
                }
                if (control.claim()) |state| {
                    if (state == .detached) {
                        ops.destroy_payload(payload);
                        return;
                    }
                    control.releaseSender(false);
                    @panic("binding completion was completed twice");
                }
                control.materialized_payload = payload;
                control.enqueue(.materialized);
            }

            pub fn outOfMemory(owned: *Self) void {
                const control = owned.consume();
                defer control.releaseSender(false);
                if (control.claim()) |state| {
                    if (state == .detached) {
                        return;
                    }
                    control.releaseSender(false);
                    @panic("binding completion was completed twice");
                }
                control.result = std.mem.zeroes(WireResult);
                control.enqueue(.out_of_memory);
            }

            pub fn reject(
                owned: *Self,
                value: *Root,
                rejection_options: CompletionRejectionOptions,
            ) void {
                value.requireCurrentVM(value.globalObject());
                const control = owned.consume();
                defer control.releaseSender(false);
                var rejection: MaterializedRejection = .{
                    .value = value.take(),
                    .attach_async_stack = rejection_options.attach_async_stack,
                    .handled = rejection_options.handled,
                };
                if (control.claim()) |state| {
                    rejection.value.deinit();
                    if (state == .detached) {
                        return;
                    }
                    control.releaseSender(false);
                    @panic("binding completion was completed twice");
                }
                const endpoint = control.entry.context.get(*Endpoint);
                rejection.value.requireCurrentVM(endpoint.global);
                endpoint.retained = .{ .rejection = rejection };
                control.enqueue(.retained_rejection);
            }

            pub fn adoptPromise(owned: *Self, promise: *AdoptedPromise) void {
                if (Function.completion.delivery != .vm) {
                    @compileError("promise adoption requires completion.delivery = .vm");
                }
                promise.root.requireCurrentVM(promise.root.globalObject());
                const control = owned.consume();
                if (control.claim()) |state| {
                    promise.deinit();
                    if (state == .detached) {
                        control.releaseSender(false);
                        return;
                    }
                    control.releaseSender(false);
                    @panic("binding completion was completed twice");
                }
                const endpoint = control.entry.context.get(*Endpoint);
                if (promise.root.globalObject() != endpoint.global) {
                    promise.deinit();
                    control.releaseSender(false);
                    @panic("binding completion adopted a promise from a different realm");
                }
                var engine_scope: FocusedEngineScope = undefined;
                engine_scope.init(endpoint.global);
                defer engine_scope.deinit();
                engine_scope.engine(PromiseBindings.engineShim("promiseSetHandled")).call(.{
                    .promise = promise.operand(&engine_scope).asPromise(),
                });
                endpoint.retained = .{ .promise = promise.root.takeAnyRoot() };
                control.enqueue(.adopted_promise);
                control.releaseSender(false);
            }

            pub fn release(owned: *Self) void {
                owned.consume().releaseSender(false);
            }

            fn consume(owned: *Self) *Control {
                const control = owned.requireControl();
                owned.control = null;
                return control;
            }

            fn requireControl(owned: *const Self) *Control {
                return owned.control orelse @panic("binding completion handle was already consumed");
            }
        };

        const CreateError = bun.JSError;

        fn deliverFailure(global: *jsc.JSGlobalObject, promise: jsc.JSValue, failure: bun.JSError) void {
            if (failure == error.JSTerminated) return;
            var result = std.mem.zeroes(WireResult);
            deliverWire(global, promise, if (failure == error.OutOfMemory) .out_of_memory else .pending_exception, &result);
        }

        fn deliverWire(global: *jsc.JSGlobalObject, promise: jsc.JSValue, disposition: CompletionDisposition, result: *WireResult) void {
            defer promise.ensureStillAlive();
            @field(wire, Function.completion.deliver_symbol)(
                @ptrCast(global),
                value_encoding.cellPointer(*wire.BindPromiseHandle, @backingInt(promise)),
                @backingInt(disposition),
                result,
            );
        }

        fn Created(comptime Result: type, comptime Completion: type) type {
            const PromiseType = declaredPromiseSemanticType(Result);
            if (PromiseType.Brand.PromiseValueType != Function.ReturnType)
                @compileError("completion promise resolution type does not match the completion result");
            return struct {
                promise: StrongPromise(Result),
                completion: Completion,
            };
        }

        fn createPromise(comptime Result: type, context: anytype) CreateError!Created(Result, Owned) {
            context.requireActive();
            _ = ResultBinding(Function);
            const token = context.viewToken();
            const global = token.globalObject();
            const operation: BoundEngineOperation(Manifest.EngineShimId(PromiseCreateSchema)) = .{ .token = token };
            const promise = (try operation.call(.{})).rawValue();
            const result = Result.initInline(promise, global, token, .branded);
            var retained = try StrongPromise(Result).initFromResult(&result);
            errdefer retained.deinit();
            const control = try create(global, promise);
            return .{ .promise = retained, .completion = .{ .control = control } };
        }

        fn create(global: *jsc.JSGlobalObject, promise: jsc.JSValue) CreateError!*Control {
            if (promise == .zero) @panic("binding completion promise is empty");
            const vm = global.bunVM();
            const registry = try (try vm.tryRareData()).nativeCompletionRegistry(vm);
            const endpoint = try completion_allocator.create(Endpoint);
            errdefer completion_allocator.destroy(endpoint);
            const control = try completion_allocator.create(Control);
            errdefer completion_allocator.destroy(control);
            registry.retain();
            errdefer registry.release();
            control.* = .{
                .registry = registry,
            };
            endpoint.* = .{
                .global = global,
                .async_task = jsc.Debugger.AsyncTaskTracker.init(vm),
                .control = control,
            };
            endpoint.promise = if (Function.completion.retention == .weak)
                try WeakStorage.create(void, promise, global, null, null)
            else
                try PromiseRoot.Optional.create(promise, global);
            if (Function.completion.retention == .pending_activity) {
                endpoint.activity_loop = vm.eventLoop();
                endpoint.activity_loop.?.refConcurrently();
            }
            control.entry = .{
                .context = .init(endpoint),
                .deliver = Endpoint.deliverOpaque,
                .detach = Endpoint.detachOpaque,
            };
            if (!registry.register(&control.entry)) {
                endpoint.detach();
                return control;
            }
            endpoint.async_task_state = .scheduled;
            endpoint.async_task.didSchedule(global);
            return control;
        }

        // The entry frame outlives a sender that settles during re-entry.
        fn finishInvocation(control: *Control, taken: bool, succeeded: bool) void {
            if (!succeeded)
                control.registry.detach(&control.entry);
            if (!taken)
                control.releaseSender(!succeeded);
            control.invocation_active = false;
            control.dropReference();
        }
    };
    return Result_;
}

fn ResultBinding(comptime Function: type) type {
    const symbol = Function.destroy_result_symbol orelse return struct {};
    const WireResult = wireType(Function.wire_result);
    return struct {
        fn destroyResult(wire_result: ?*WireResult) callconv(.c) void {
            const result = wire_result orelse @panic("binding result destructor received null");
            destroyResultPayload(Function, result);
        }

        comptime {
            @export(&destroyResult, .{ .name = symbol });
        }
    };
}

fn CppCompletionBinding(comptime Function: type) type {
    const api = Manifest.get(Function.completion.cpp_api orelse return struct {});
    const Payload = Function.completion_payload;
    const Types = CompletionTypes(Payload);
    const Handle = wireType(api.handle);
    const WireResult = wireType(Function.wire_result);
    return struct {
        fn control(handle: ?*Handle) *Types.Control {
            return @ptrCast(@alignCast(handle orelse @panic("null C++ binding completion")));
        }

        fn create(global_handle: ?*wire.BindGlobalObjectHandle, promise_handle: ?*wire.BindPromiseHandle, output: ?*?*Handle) callconv(.c) wire.BindStatus {
            const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(global_handle orelse @panic("null completion realm")));
            const promise: jsc.JSValue = @fromBackingInt(value_encoding.fromCell(promise_handle orelse @panic("null completion promise")));
            const result = output orelse @panic("null completion output");
            result.* = null;
            const value = Types.create(global, promise) catch |err|
                return checkedStatus(global, if (err == error.OutOfMemory) .out_of_memory else .pending_exception);
            value.retain();
            const status = checkedStatus(global, .ok);
            if (status != @backingInt(Status.ok)) {
                Types.finishInvocation(value, false, false);
                return status;
            }
            result.* = @ptrCast(value);
            return status;
        }

        fn cloneHandle(handle: ?*Handle) callconv(.c) void {
            control(handle).addSender();
        }

        fn release(handle: ?*Handle) callconv(.c) void {
            control(handle).releaseSender(false);
        }

        fn finish(handle: ?*Handle, succeeded: u8) callconv(.c) void {
            if (succeeded > 1) @panic("invalid completion invocation status");
            Types.finishInvocation(control(handle), true, succeeded != 0);
        }

        fn settle(handle: ?*Handle, raw_disposition: wire.BindCompletionDisposition, output: ?*WireResult) callconv(.c) void {
            const disposition: CompletionDisposition = switch (raw_disposition) {
                @backingInt(CompletionDisposition.value) => .value,
                @backingInt(CompletionDisposition.domain_error) => .domain_error,
                @backingInt(CompletionDisposition.out_of_memory) => .out_of_memory,
                else => @panic("invalid C++ completion disposition"),
            };
            const result = output orelse @panic("null C++ completion result");
            if (comptime Function.domain_errors.len > 0) {
                if (disposition == .domain_error) {
                    if (result.tag == 0 or result.tag > Function.domain_errors.len)
                        @panic("invalid C++ completion domain error");
                } else if (result.tag != 0) @panic("invalid C++ completion value tag");
            } else if (disposition == .domain_error) @panic("undeclared C++ completion domain error");
            const value = control(handle);
            defer value.releaseSender(false);
            if (value.claim()) |state| {
                if (completionDispositionOwnsPayload(disposition)) destroyResultPayload(Payload, result);
                if (state != .detached) @panic("binding completion was completed twice");
                return;
            }
            value.result = result.*;
            result.* = std.mem.zeroes(WireResult);
            value.enqueue(disposition);
        }

        comptime {
            @export(&create, .{ .name = api.create });
            @export(&cloneHandle, .{ .name = api.clone });
            @export(&release, .{ .name = api.release });
            @export(&finish, .{ .name = api.finish });
            @export(&settle, .{ .name = api.settle });
            _ = ResultBinding(Payload);
        }
    };
}

fn configuredDropDisposition(comptime Function: type) CompletionDisposition {
    return switch (Function.completion.sender_drop) {
        .cancel => .cancel,
        .reject => .drop_reject,
        .leave_pending => .leave_pending,
    };
}

pub fn PromiseReaction(comptime ContextSchema: type, comptime Owner: type) type {
    const Context = ContextSchema;
    if (comptime Context.promise_reaction) |reaction| {
        if (!@hasDecl(Owner, "releasePromiseReactionRef")) {
            @compileError("promise reaction owner is missing releasePromiseReactionRef: " ++ @typeName(Owner));
        }
        if (@TypeOf(Owner.releasePromiseReactionRef) != fn (*Owner) void) {
            @compileError("promise reaction owner has an incompatible releasePromiseReactionRef: " ++ @typeName(Owner));
        }
        const CreateSchema = Manifest.EngineShim(reaction.create);
        const AdoptSchema = Manifest.EngineShim(reaction.adopt);
        const AttachSchema = Manifest.EngineShim(reaction.attach);
        const TakeSchema = Manifest.EngineShim(reaction.take);
        const DestroySchema = Manifest.NativeExport(reaction.destroy);
        const ContextView = BrandedValueViewType(Context);

        const Result_ = struct {
            fn callbackHost(comptime Binding: type, comptime role: []const u8) *const JSHostFn {
                if (Binding != FunctionBinding(Binding.bindgen_function_id, Binding.bound_implementation, Binding.bindgen_overload_index))
                    @compileError("promise reaction " ++ role ++ " requires an exact generated function binding");
                const CallbackFunction = FunctionMetadata(Binding.bindgen_function_id, Binding.bindgen_overload_index);
                if (!CallbackFunction.is_promise_reaction_handler)
                    @compileError("promise reaction " ++ role ++ " is not declared as a promise reaction handler");
                if (CallbackFunction.backend != .zig)
                    @compileError("promise reaction " ++ role ++ " must use a Zig callback");
                if (comptime CallbackFunction.ReturnType.kind != .void)
                    @compileError("promise reaction " ++ role ++ " must return none");
                if (CallbackFunction.is_overloaded or CallbackFunction.args.len != 2)
                    @compileError("promise reaction " ++ role ++ " must have exactly a result and context argument");
                const CallbackContext = CallbackFunction.args[1].ArgumentType;
                if (comptime CallbackContext != Context)
                    @compileError("promise reaction " ++ role ++ " has the wrong context type");
                if (CallbackFunction.has_callback_data)
                    @compileError("promise reaction " ++ role ++ " cannot carry callback data");
                return Binding.host;
            }

            const Reference = struct {
                node: jsc.NativeFinalizerQueue.Node = .{},
                queue: *jsc.NativeFinalizerQueue,
                owner: *Owner,

                fn take(reference: *@This()) *Owner {
                    const owner = reference.owner;
                    bun.destroy(reference);
                    return owner;
                }

                fn finalize(reference: *@This()) void {
                    reference.owner.releasePromiseReactionRef();
                    bun.destroy(reference);
                }
            };

            fn create(context: anytype) bun.JSError!BrandedValueResultType(Context) {
                const operation: BoundEngineOperation(Manifest.EngineShimId(CreateSchema)) = .{ .token = context.viewToken() };
                return operation.call(.{});
            }

            pub fn attach(
                context: anytype,
                promise: @FieldType(Args(AttachSchema), "promise"),
                owner: *Owner,
                comptime ResolveBinding: type,
                comptime RejectBinding: type,
            ) bun.JSError!void {
                var transferred = false;
                errdefer if (!transferred) owner.releasePromiseReactionRef();
                var cell = try create(context);
                defer cell.deinit();
                const cell_view = try cell.view(context);
                const global = context.viewToken().globalObject();
                const queue = (try global.bunVM().tryRareData()).nativeFinalizerQueue();
                const reference = try bun.default_allocator.create(Reference);
                reference.* = .{ .queue = queue, .owner = owner };
                (BoundEngineOperation(Manifest.EngineShimId(AdoptSchema)){ .token = cell_view.token }).call(
                    .{ .context = cell_view.operand(context), .owner = @ptrCast(reference) },
                );
                transferred = true;
                errdefer if (take(cell_view)) |retained_owner| retained_owner.releasePromiseReactionRef();
                const attach_reaction: BoundEngineOperation(Manifest.EngineShimId(AttachSchema)) = .{ .token = context.viewToken() };
                const AttachArgs = @TypeOf(attach_reaction).Args;
                try attach_reaction.call(.{
                    .promise = promise,
                    .context = cell_view.operand(context),
                    .resolve = @as(
                        @FieldType(AttachArgs, "resolve"),
                        @ptrCast(@constCast(callbackHost(ResolveBinding, "resolve callback"))),
                    ),
                    .reject = @as(
                        @FieldType(AttachArgs, "reject"),
                        @ptrCast(@constCast(callbackHost(RejectBinding, "reject callback"))),
                    ),
                });
            }

            pub fn take(context: ContextView) ?*Owner {
                const reference_handle = (BoundEngineOperation(Manifest.EngineShimId(TakeSchema)){ .token = context.token }).call(
                    .{ .context = .init(@fromBackingInt(context.encodedForEngine(context.engineGlobal(), context.token)), context.token) },
                ) orelse return null;
                const reference: *Reference = @ptrCast(@alignCast(reference_handle));
                return reference.take();
            }

            fn destroyContext(args: Args(DestroySchema)) Return(DestroySchema) {
                const reference: *Reference = @ptrCast(@alignCast(args.owner));
                reference.queue.enqueue(
                    &reference.node,
                    reference,
                    Reference.finalize,
                );
            }

            const DestroyBinding = Fn(DestroySchema, destroyContext);

            comptime {
                _ = DestroyBinding;
            }
        };
        return Result_;
    } else {
        @compileError("promise reactions require a schema-declared reaction context");
    }
}

const DeclarationKind = enum { function, native_export, engine_shim, callback };

/// The kind of declaration a schema handle, callback type, or call context names.
fn declarationKind(comptime Handle: type) DeclarationKind {
    const T = HandleTarget(Handle);
    if (@hasDecl(T, "bindgen_bound_function") or @hasDecl(T, "bindgen_function_call_context")) return .function;
    if (@hasDecl(T, "bindgen_bound_native_export") or @hasDecl(T, "bindgen_native_call_context")) return .native_export;
    if (@hasDecl(T, "bindgen_bound_engine_shim")) return .engine_shim;
    if (Manifest.isSemanticType(T)) {
        if (T.kind == .callback) return .callback;
    }
    @compileError("expected a bindgen function, native export, engine shim, callback type, or call context");
}

fn HandleTarget(comptime Handle: type) type {
    return switch (@typeInfo(Handle)) {
        .pointer => |pointer| pointer.child,
        else => Handle,
    };
}

fn DeclarationOf(comptime Handle: type) type {
    const T = HandleTarget(Handle);
    return switch (declarationKind(Handle)) {
        .function => FunctionMetadata(if (@hasDecl(T, "bindgen_function_id")) T.bindgen_function_id else Manifest.FunctionId(T), null),
        .native_export => NativeExportMetadata(if (@hasDecl(T, "bindgen_native_export_id")) T.bindgen_native_export_id else Manifest.NativeExportId(T)),
        .engine_shim => Manifest.EngineShimAt(Manifest.EngineShimId(T)),
        .callback => Manifest.callbackOf(T),
    };
}

/// The context a function or native export implementation receives.
pub fn CallContext(comptime Handle: type) type {
    return switch (declarationKind(Handle)) {
        .function => FunctionCallContext(Manifest.FunctionId(Handle)),
        .native_export => NativeCallContextFor(Manifest.NativeExportId(Handle)),
        .engine_shim, .callback => @compileError("only function and native export implementations receive a call context"),
    };
}

/// The arguments an implementation receives, or that a caller of an engine shim or callback passes.
pub fn Args(comptime Handle: type) type {
    const Declaration = DeclarationOf(Handle);
    return switch (declarationKind(Handle)) {
        .function => if (Declaration.is_overloaded) OverloadArgsType(Declaration) else ArgsType(Declaration),
        .native_export => ArgsType(Declaration),
        .engine_shim, .callback => Outbound(Declaration).Args,
    };
}

pub fn Return(comptime Handle: type) type {
    const Declaration = DeclarationOf(Handle);
    if (comptime declarationKind(Handle) == .native_export) {
        if (Declaration.non_returning) return noreturn;
    }
    return Api(Declaration.result_position);
}

pub fn deinitReturn(comptime Handle: type, value: *Return(Handle)) void {
    destroy(DeclarationOf(Handle).result_position).api(value);
}

pub fn CallError(comptime Handle: type) type {
    return switch (declarationKind(Handle)) {
        .function, .native_export => FunctionCallError(DeclarationOf(Handle)),
        .engine_shim, .callback => @compileError("only function and native export implementations have a call error set"),
    };
}

pub fn Module(comptime name: []const u8) type {
    return Manifest.moduleNamed(name);
}

pub fn enumConstant(comptime Type: type, comptime text: []const u8) Type.Native {
    return EnumConstant(Type, text).value;
}

fn EnumConstant(comptime Type: type, comptime text: []const u8) type {
    Manifest.requireSemanticType(Type);
    if (Type.kind != .enumeration) @compileError("enumeration constants require an enumeration schema");
    return struct {
        const value: Type.Native = lookup: {
            @setEvalBranchQuota(api_eval_branch_quota);
            for (Type.enumeration_values) |Value| {
                if (std.mem.eql(u8, text, Value.js_value)) break :lookup @field(Type.Native, Value.value_name);
            }
            @compileError("no declared enumeration value in " ++ Type.enumeration_name ++ ": " ++ text);
        };
    };
}

pub fn ArgumentType(comptime Type: type) type {
    if (Manifest.argumentPosition(Type)) |position| return Api(position);
    @compileError("binding type has no argument API");
}

pub fn ResultType(comptime Type: type) type {
    if (Manifest.resultPosition(Type)) |position| return Api(position);
    @compileError("binding type has no result API");
}

fn DeclaredDomainError(comptime FunctionSchema: type, comptime tag: @EnumLiteral()) type {
    const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
    inline for (Function.domain_errors) |DomainError| {
        if (std.mem.eql(u8, @tagName(tag), DomainError.error_name)) return DomainError;
    }
    @compileError("binding function has no domain error named '" ++ @tagName(tag) ++ "'");
}

pub fn DomainErrorPayload(comptime FunctionSchema: type, comptime tag: @EnumLiteral()) type {
    return Api(DeclaredDomainError(FunctionSchema, tag).position);
}

pub fn deinitDomainErrorPayload(comptime FunctionSchema: type, comptime tag: @EnumLiteral(), value: *DomainErrorPayload(FunctionSchema, tag)) void {
    destroy(DeclaredDomainError(FunctionSchema, tag).position).api(value);
}

pub fn deinitResult(comptime Type: type, value: *ResultType(Type)) void {
    if (Manifest.resultPosition(Type)) |position| return destroy(position).api(value);
    @compileError("binding type has no result API");
}

pub fn DictionaryFieldType(comptime DictionaryType: type, comptime field_name: []const u8) type {
    if (comptime DictionaryType.kind != .dictionary) @compileError("DictionaryFieldType requires a dictionary type");
    inline for (DictionaryType.dictionary_fields) |Field| {
        if (std.mem.eql(u8, Field.field_name, field_name)) return Field.FieldType;
    }
    @compileError("binding dictionary has no field named '" ++ field_name ++ "'");
}

pub fn UnionMemberType(comptime UnionType: type, comptime member_name: []const u8) type {
    if (comptime UnionType.kind != .union_type) @compileError("UnionMemberType requires a union type");
    inline for (UnionType.union_members) |Member| {
        if (std.mem.eql(u8, Member.member_name, member_name)) return Member.MemberType;
    }
    @compileError("binding union has no member named '" ++ member_name ++ "'");
}

pub fn EngineArgumentType(comptime EngineShimSchema: type, comptime argument_name: []const u8) type {
    const Arguments = Args(EngineShimSchema);
    if (!@hasField(Arguments, argument_name)) @compileError("engine operation has no argument named '" ++ argument_name ++ "'");
    return @FieldType(Arguments, argument_name);
}

pub fn EngineTransferredArgumentType(comptime EngineShimSchema: type, comptime argument_name: []const u8) type {
    const EngineShim = Manifest.EngineShimAt(Manifest.EngineShimId(EngineShimSchema));
    inline for (EngineShim.args) |Argument| {
        if (std.mem.eql(u8, Argument.argument_name, argument_name)) {
            if (!Manifest.get(Argument.value_position).transfer) {
                @compileError("engine operation argument '" ++ argument_name ++ "' does not transfer ownership");
            }
            return EngineArgumentType(EngineShimSchema, argument_name);
        }
    }
    @compileError("engine operation has no argument named '" ++ argument_name ++ "'");
}

pub fn Engine(comptime EngineShimSchema: type) type {
    const Declaration = Manifest.EngineShimAt(Manifest.EngineShimId(EngineShimSchema));
    const Protocol = Outbound(Declaration);
    return struct {
        pub const Args = Protocol.Args;
        pub const Return = Protocol.Return;
        pub const call = if (Declaration.call_plan.realm == .current) invoke else invokePure;

        fn invoke(global: *jsc.JSGlobalObject, args: Protocol.CallArgs) Protocol.Return {
            if (Declaration.call_plan.requires_scope) @compileError(Declaration.module_name ++ "." ++ Declaration.shim_name ++ " requires an active call scope");
            return Protocol.enter(global, null, args, {});
        }

        fn invokePure(args: Protocol.CallArgs) Protocol.Return {
            if (Declaration.call_plan.requires_scope) @compileError(Declaration.module_name ++ "." ++ Declaration.shim_name ++ " requires an active call scope");
            return Protocol.enter(null, null, args, {});
        }
    };
}

fn Outbound(comptime Declaration: type) type {
    return struct {
        const Self = @This();
        pub const Args = OutboundArgsType(Declaration);
        pub const CallArgs = if (Declaration.call_plan.transfers_argument_ownership) *Self.Args else Self.Args;
        pub const Value = Api(Declaration.result_position);
        const checks_traps = Declaration.call_plan.realm == .current and Declaration.call_plan.checks_traps;
        pub const Return = if (checks_traps or Manifest.get(Declaration.result_position).zig.decode_allocates)
            bun.JSError!Value
        else if (Declaration.call_plan.throws == .out_of_memory)
            bun.OOM!Value
        else
            Value;

        const needs_arena = blk: {
            for (Declaration.args) |Argument| {
                if (Manifest.get(Argument.value_position).zig.encode_allocates) break :blk true;
            }
            for ([_]?ir.OutboundArgumentPlanId{ Declaration.call_plan.callee, Declaration.call_plan.receiver }) |maybe_id| {
                if (maybe_id) |id| if (Manifest.get(id).zig.encode_allocates) break :blk true;
            }
            break :blk false;
        };

        const Callee = if (Declaration.call_plan.callee) |id| Api(id) else void;

        fn dispatch(global: *jsc.JSGlobalObject, token: ViewToken, args: CallArgs, callee: Callee) void {
            if (Value != void) @compileError("callback dispatch requires a void result");
            const event_loop = global.bunVM().eventLoop();
            event_loop.enter();
            defer event_loop.exit();
            enter(global, token, args, callee) catch |err| global.reportActiveExceptionAsUnhandled(err);
        }

        fn enter(
            global: if (Declaration.call_plan.realm == .current) *jsc.JSGlobalObject else @TypeOf(null),
            token: if (Declaration.call_plan.requires_scope) ViewToken else ?ViewToken,
            args: CallArgs,
            callee: Callee,
        ) Self.Return {
            var copied_args: Self.Args = undefined;
            const prepared: *Self.Args = if (Declaration.call_plan.transfers_argument_ownership) args else copied: {
                copied_args = args;
                break :copied &copied_args;
            };
            defer destroyArguments(Declaration, prepared);
            var arena: if (needs_arena) std.heap.ArenaAllocator else void = if (needs_arena)
                std.heap.ArenaAllocator.init(bun.default_allocator)
            else {};
            defer if (needs_arena) arena.deinit();
            const encoded = encodeOutboundArgs(Declaration, prepared, callee, .{ .global = global, .token = token, .allocator = if (needs_arena) arena.allocator() else bun.default_allocator });
            var wire_args = if (comptime checks_traps or Declaration.call_plan.throws == .out_of_memory)
                try encoded
            else
                encoded catch @panic("infallible outbound argument encoding allocated");
            commitEngineCallArgumentTransfers(Declaration, prepared);
            var result: wireType(Declaration.wire_result) = std.mem.zeroes(wireType(Declaration.wire_result));
            var call_context: wire.BindCallContext = std.mem.zeroes(wire.BindCallContext);
            call_context.global_object = if (Declaration.call_plan.realm == .current) @ptrCast(global) else null;
            const active_token: ?ViewToken = token;
            if (active_token) |active| {
                call_context.call_id = active.call.id;
                call_context.deferred_conversions = active.call.deferred_conversions;
            }
            const raw_status = @field(wire, Declaration.thunk_symbol)(&call_context, &wire_args, &result);
            const status: Status = if (checks_traps)
                statusAfterCheckedCall(global, raw_status)
            else
                Status.fromWire(raw_status);
            if (raw_status == @backingInt(Status.ok) and status != .ok) {
                if (comptime Api(Declaration.result_position) != void) destroy(Declaration.result_position).transfer(&result.value);
            }
            switch (status) {
                .ok => {},
                .pending_exception => if (checks_traps) return error.JSError else @panic("infallible outbound call returned a pending exception"),
                .out_of_memory => if (checks_traps or Declaration.call_plan.throws == .out_of_memory) return error.OutOfMemory else @panic("infallible outbound call returned out of memory"),
                .failed => @panic("outbound call returned a domain failure"),
            }
            defer poisonMovedWire(&result);
            if (comptime Api(Declaration.result_position) == void) return {};
            const decoded = decode(Declaration.result_position).wire(result.value, .{ .global = global, .token = token });
            return try decoded;
        }
    };
}

fn commitEngineCallArgumentTransfers(comptime EngineShim: type, args: *OutboundArgsType(EngineShim)) void {
    if (comptime !EngineShim.call_plan.transfers_argument_ownership) return;
    inline for (EngineShim.args) |Argument| {
        const position = comptime Argument.value_position;
        if (Manifest.get(position).transfer) {
            encode(position).commit(&@field(args.*, Argument.argument_name));
        }
    }
}

fn NativeCallContextFor(comptime export_id: usize) type {
    const Export = NativeExportMetadata(export_id);
    if (Export.realm != .current) {
        @compileError("realm-free native exports do not have a call context");
    }
    const Result_ = opaque {
        pub const bindgen_native_export_id = export_id;
        pub const bindgen_result_type = Export.ReturnType;

        pub const bindgen_native_call_context = {};
        pub const Result = Api(Export.result_position);

        const Self = @This();
        const Operations = ContextOperations(*const Self);

        pub const engineIn = Operations.engineIn;
        pub const engine = Operations.engine;
        pub const runErrorHandler = Operations.runErrorHandler;
        pub const reportUnhandledRejection = Operations.reportUnhandledRejection;
        pub const waitForPromiseResult = Operations.waitForPromiseResult;

        const Access = CallContextAccess(*const Self, Export);
        const state = Access.state;
        const activeCall = Access.activeCall;
        const globalObject = Access.globalObject;
        const requireActive = Access.requireActive;
        pub const viewToken = Access.viewToken;
        pub const fail = Access.fail;

        pub fn reportUnhandledError(context: *const Self, value: AnyOperand) void {
            const global = context.globalObject();
            const raw = value.rawValueForEngine(global, context.viewToken());
            if (EngineOperand.init(raw, context.viewToken()).isTerminationException()) return;
            _ = global.bunVM().uncaughtException(global, raw, false);
        }
    };
    return *const Result_;
}

fn NativeExportBinding(comptime export_id: usize, comptime implementation: anytype) type {
    const Export = NativeExportMetadata(export_id);
    if (!Export.exposed) @compileError("bindgen.Fn cannot bind a native export excluded from the current target");
    const NativeArguments = ArgsType(Export);
    const ImplementationArgs = if (Export.call_plan.transfers_argument_ownership) *NativeArguments else NativeArguments;
    const Result = if (Export.call_plan.non_returning) noreturn else switch (Export.call_plan.throws) {
        .never => Api(Export.result_position),
        .out_of_memory => error{OutOfMemory}!Api(Export.result_position),
        .js_exception => FunctionCallError(Export)!Api(Export.result_position),
    };
    const Expected = switch (Export.call_plan.realm) {
        .none => fn (ImplementationArgs) Result,
        .current => fn (NativeCallContextFor(export_id), ImplementationArgs) Result,
    };
    if (@TypeOf(implementation) != Expected) {
        @compileError("native export implementation '" ++ Export.module_name ++ "." ++ Export.export_name ++ "' has an incompatible signature: expected " ++ @typeName(Expected) ++ ", found " ++ @typeName(@TypeOf(implementation)));
    }

    return Inbound(Export, implementation);
}

pub fn CompletionView(comptime FunctionSchema: type) type {
    const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
    if (!Function.is_async) @compileError("synchronous bindings do not have a completion view");
    return CompletionTypes(Function).View;
}

pub fn OwnedCompletion(comptime FunctionSchema: type) type {
    const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
    if (!Function.is_async) @compileError("synchronous bindings do not have an owned completion");
    return CompletionTypes(Function).Owned;
}

pub fn StandaloneCompletion(comptime FunctionSchema: type) type {
    const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
    if (!Function.is_async or Function.exposed) {
        @compileError("standalone completions require an unexposed asynchronous function");
    }
    if (Function.completion.delivery != .wire) {
        @compileError("VM-materialized completions require MaterializedCompletion");
    }
    const Types = CompletionTypes(Function);
    return struct {
        pub const Owned = Types.Owned;

        pub fn Created(comptime Result: type) type {
            return Types.Created(Result, Owned);
        }

        pub fn create(comptime Result: type, context: anytype) Types.CreateError!Created(Result) {
            return Types.createPromise(Result, context);
        }
    };
}

fn DomainErrorContext(comptime Function: type, comptime tag: FailureTagType(Function)) type {
    const DomainError = domainErrorForTag(Function, tag);
    return struct {
        pub const bindgen_result_construction_context = {};
        pub const bindgen_result_context = {};
        pub const bindgen_result_type = DomainError.PayloadType;

        pub const Result = Api(DomainError.position);

        token: ViewToken,

        fn requireActive(context: @This()) void {
            context.token.requireActive();
        }

        pub fn viewToken(context: @This()) ViewToken {
            context.requireActive();
            return context.token;
        }
    };
}

pub fn MaterializationContext(comptime FunctionSchema: type) type {
    const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
    const Result_ = struct {
        pub const bindgen_materialization_context = {};
        pub const bindgen_result_context = {};
        pub const bindgen_result_type = Function.ReturnType;

        token: ViewToken,
        failure: *DomainFailureStorage(Function),
        rejection: *?MaterializedRejection,

        const Self = @This();

        fn requireActive(context: Self) void {
            context.token.requireActive();
        }

        pub fn viewToken(context: Self) ViewToken {
            context.token.requireActive();
            return context.token;
        }

        pub const engineIn = ContextOperations(Self).engineIn;
        pub const engine = ContextOperations(Self).engine;

        pub fn errorContext(context: Self, comptime tag: FailureTagType(Function)) DomainErrorContext(Function, tag) {
            return .{ .token = context.viewToken() };
        }

        pub fn fail(
            context: Self,
            comptime tag: FailureTagType(Function),
            payload: FailurePayloadApiType(Function, tag),
        ) DomainFailure {
            context.token.requireActive();
            return context.failure.commit(tag, payload);
        }

        pub fn reject(
            context: Self,
            value: *Root,
            rejection_options: CompletionRejectionOptions,
        ) CompletionRejection {
            context.token.requireActive();
            if (context.rejection.* != null) @panic("binding materializer rejected twice");
            value.requireCurrentVM(context.token.globalObject());
            context.rejection.* = .{
                .value = value.take(),
                .attach_async_stack = rejection_options.attach_async_stack,
                .handled = rejection_options.handled,
            };
            return error.BindgenCompletionRejection;
        }
    };
    return Result_;
}

pub const CompletionRejectionOptions = struct {
    attach_async_stack: bool = false,
    handled: bool = false,
};

const MaterializedRejection = struct {
    value: Root,
    attach_async_stack: bool,
    handled: bool,

    fn deliver(rejection: *const @This(), context: anytype, promise: PromiseResult) bun.JSError!void {
        const token = context.viewToken();
        rejection.value.requireCurrentVM(token.globalObject());
        const value = EngineOperand.init(rejection.value.rawValue(), token);
        if (rejection.attach_async_stack) try context.engineIn("errors", "attachAsyncStackFromPromise").call(.{
            .@"error" = value,
            .promise = promise.operand(context),
        });
        switch (rejection.handled) {
            inline else => |handled| try context.engineIn("promises", if (handled) "promiseRejectAsHandled" else "promiseReject").call(.{
                .promise = promise.operand(context),
                .value = value,
            }),
        }
    }
};

pub fn MaterializedCompletion(
    comptime FunctionSchema: type,
    comptime Payload: type,
    comptime Attachment: type,
    comptime Ops: type,
) type {
    const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
    if (!Function.is_async) @compileError("synchronous bindings do not have materialized completions");
    if (Function.completion.delivery != .vm) {
        @compileError("MaterializedCompletion requires completion.delivery = .vm");
    }
    const Types = CompletionTypes(Function);
    const Context = MaterializationContext(FunctionSchema);
    const MaterializerError = FunctionCallError(Function) || CompletionRejection;
    const Materializer = struct {
        fn materialize(
            context: Context,
            attachment: if (Attachment == void) void else *Attachment,
            payload: *Payload,
        ) MaterializerError!Api(Function.result_position) {
            return if (Attachment == void)
                Ops.materialize(FunctionSchema, context, payload)
            else
                Ops.materialize(FunctionSchema, context, attachment, payload);
        }
    };
    const materialize_fn: *const fn (
        Context,
        if (Attachment == void) void else *Attachment,
        *Payload,
    ) MaterializerError!Api(Function.result_position) = &Materializer.materialize;
    const destroy_payload_fn: *const fn (*Payload) void = &Ops.destroyPayload;
    _ = materialize_fn;
    _ = destroy_payload_fn;
    if (Attachment != void) {
        const destroy_attachment_fn: *const fn (*Attachment) void = &Ops.destroyAttachment;
        _ = destroy_attachment_fn;
    }

    const Result_ = struct {
        const materialized_ops: Types.MaterializedOps = .{
            .deliver = deliverOpaque,
            .destroy_payload = destroyPayloadOpaque,
        };

        pub fn TypedCreated(comptime DeclaredPromiseResult: type) type {
            return Types.Created(DeclaredPromiseResult, Owned);
        }

        fn deliverOpaque(
            global: *jsc.JSGlobalObject,
            promise: PromiseResult,
            attachment: ?NativeCallbackContext(.vm),
            payload: NativeCallbackContext(.vm),
        ) bun.JSError!void {
            const call_id = nextCallbackInvocationCallId();
            var active: ActiveCallScope = undefined;
            active.init(call_id, global);
            defer active.deinit();
            var failure: DomainFailureStorage(Function) = .{};
            var rejection: ?MaterializedRejection = null;
            defer if (rejection) |*rejected| rejected.value.deinit();
            const context: Context = .{
                .token = active.token(),
                .failure = &failure,
                .rejection = &rejection,
            };
            const promise_result = PromiseResult.initInline(promise.rawValue(), global, active.token(), .branded);
            defer promise.rawValue().ensureStillAlive();
            const value = Materializer.materialize(
                context,
                if (Attachment == void) {} else (attachment orelse
                    @panic("binding materializer requires an attachment")).get(*Attachment),
                payload.get(*Payload),
            ) catch |err| {
                switch (@as(bun.JSError || DomainFailure || CompletionRejection, err)) {
                    error.BindgenCompletionRejection => {
                        if (failure.payload != null) @panic("binding materializer rejected after committing a domain failure");
                        if (rejection) |*rejected| {
                            try rejected.deliver(context, promise_result);
                            return;
                        }
                        @panic("binding materializer rejected without a value");
                    },
                    error.BindgenDomainFailure => {
                        if (failure.payload == null) @panic("binding materializer returned a domain failure without a payload");
                        var result = commitDomainFailure(Function, failure);
                        Types.deliverWire(global, promise.rawValue(), .domain_error, &result);
                        return;
                    },
                    error.OutOfMemory, error.JSError, error.JSTerminated => |failure_error| {
                        if (failure.payload != null) @panic("binding materializer returned an exception after committing a domain failure");
                        Types.deliverFailure(global, promise.rawValue(), failure_error);
                        return;
                    },
                }
            };
            if (failure.payload != null) @panic("binding materializer returned success after committing a domain failure");
            if (rejection != null) @panic("binding materializer returned success after rejecting");
            var result = encodeResult(Function, value);
            Types.deliverWire(global, promise.rawValue(), .value, &result);
        }

        fn destroyPayloadOpaque(payload: NativeCallbackContext(.vm)) void {
            Ops.destroyPayload(payload.get(*Payload));
        }

        fn destroyAttachmentOpaque(attachment_opaque: NativeCallbackContext(.vm)) void {
            if (Attachment == void) return;
            const attachment = attachment_opaque.get(*Attachment);
            Ops.destroyAttachment(attachment);
            completion_allocator.destroy(attachment);
        }

        pub const Owned = struct {
            inner: Types.Owned,

            pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

            pub fn readyDeliveryScope(owned: *const @This(), global: *jsc.JSGlobalObject) ReadyCompletionDeliveryScope {
                return owned.inner.readyDeliveryScope(global);
            }

            pub fn complete(owned: *@This(), payload: *Payload) void {
                owned.inner.resolveMaterialized(.init(payload), &materialized_ops);
            }

            pub fn outOfMemory(owned: *@This()) void {
                owned.inner.outOfMemory();
            }

            pub fn fail(
                owned: *@This(),
                comptime tag: FailureTagType(Function),
                payload: FailurePayloadApiType(Function, tag),
            ) void {
                owned.inner.fail(tag, payload);
            }

            pub fn reject(
                owned: *@This(),
                value: *Root,
                rejection_options: CompletionRejectionOptions,
            ) void {
                owned.inner.reject(value, rejection_options);
            }

            pub fn adoptPromise(owned: *@This(), promise: *Types.AdoptedPromise) void {
                owned.inner.adoptPromise(promise);
            }

            pub fn release(owned: *@This()) void {
                owned.inner.release();
            }
        };

        pub fn take(view: *Types.View, attachment_value: Attachment) bun.OOM!Owned {
            if (Attachment == void) return takeWithoutAttachment(view);
            view.requireAvailable();
            var attachment = attachment_value;
            const boxed = completion_allocator.create(Attachment) catch |err| {
                Ops.destroyAttachment(&attachment);
                return err;
            };
            boxed.* = attachment;
            view.control.configureMaterialized(
                &materialized_ops,
                .{ .context = .init(boxed), .destroy = destroyAttachmentOpaque },
            );
            return .{ .inner = view.take() };
        }

        pub fn createTypedWithoutAttachment(
            comptime DeclaredPromiseResult: type,
            context: anytype,
        ) Types.CreateError!TypedCreated(DeclaredPromiseResult) {
            context.requireActive();
            return createTypedWithoutAttachmentInRealm(
                DeclaredPromiseResult,
                context.viewToken().globalObject(),
            );
        }

        pub fn createTypedWithoutAttachmentInRealm(
            comptime DeclaredPromiseResult: type,
            global: *jsc.JSGlobalObject,
        ) Types.CreateError!TypedCreated(DeclaredPromiseResult) {
            if (Attachment != void) {
                @compileError("createTypedWithoutAttachment requires a void materialization attachment");
            }
            if (Function.exposed) {
                @compileError("standalone materialized completions require an unexposed binding function");
            }
            var scope: FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const created = try Types.createPromise(DeclaredPromiseResult, &scope);
            created.completion.requireControl().configureMaterialized(
                &materialized_ops,
                null,
            );
            return .{
                .promise = created.promise,
                .completion = .{ .inner = created.completion },
            };
        }

        pub fn takeWithoutAttachment(view: *Types.View) Owned {
            if (Attachment != void) {
                @compileError("takeWithoutAttachment requires a void materialization attachment");
            }
            view.requireAvailable();
            view.control.configureMaterialized(
                &materialized_ops,
                null,
            );
            return .{ .inner = view.take() };
        }
    };
    return Result_;
}

pub fn PendingMaterializedCompletion(
    comptime FunctionSchema: type,
    comptime PromiseResultType: type,
    comptime Payload: type,
    comptime Ops: type,
) type {
    const Completion = MaterializedCompletion(FunctionSchema, Payload, void, Ops);
    return struct {
        delivery: ?Delivery = null,

        const Self = @This();
        const Delivery = struct {
            promise: StrongPromise(PromiseResultType),
            completion: Completion.Owned,
            payload: OwnedNativeWithDestructor(Payload, Ops.destroyPayload, .vm),
        };
        pub const bindgen_gc_token = gc_token.markerWithAffinity(Self, .vm);

        pub fn has(self: *const Self) bool {
            return self.delivery != null;
        }

        pub fn existingPromise(self: *const Self) *const StrongPromise(PromiseResultType) {
            const delivery = if (self.delivery) |*value| value else @panic("pending completion does not exist");
            return &delivery.promise;
        }

        pub fn promiseResult(self: *Self, context: anytype) bun.JSError!PromiseResultType {
            if (!self.has()) {
                const payload = try bun.default_allocator.create(Payload);
                payload.* = Ops.empty_payload;
                errdefer Ops.destroyPayload(payload);
                const created = try Completion.createTypedWithoutAttachment(PromiseResultType, context);
                self.delivery = .{ .promise = created.promise, .completion = created.completion, .payload = .init(payload) };
            }
            return self.existingPromise().toResult(context);
        }

        pub fn complete(self: *Self, payload_value: Payload) void {
            var payload = payload_value;
            var delivery = self.takeDelivery() orelse {
                Ops.deinitPayload(&payload);
                return;
            };
            Ops.deinitPayload(delivery.payload.get());
            delivery.payload.get().* = payload;
            delivery.completion.complete(delivery.payload.take());
        }

        pub fn outOfMemory(self: *Self) void {
            var delivery = self.takeDelivery() orelse return;
            delivery.payload.deinit();
            delivery.completion.outOfMemory();
        }

        pub fn deinit(self: *Self) void {
            var delivery = self.takeDelivery() orelse return;
            delivery.payload.deinit();
            delivery.completion.release();
        }

        fn takeDelivery(self: *Self) ?Delivery {
            var delivery = bun.take(&self.delivery) orelse return null;
            delivery.promise.deinit();
            return delivery;
        }
    };
}

/// A type-erased materialized completion over a fixed set of async function
/// schemas that share one payload type and delivery ops. Shared async
/// machinery can then serve several schema functions with a single carrier
/// type instead of a completion type per call site.
pub fn MaterializedCompletionSet(
    comptime function_schemas: anytype,
    comptime Payload: type,
    comptime Ops: type,
) type {
    @setEvalBranchQuota(10_000_000);
    if (function_schemas.len == 0) @compileError("materialized completion sets require at least one function schema");
    comptime var field_names: [function_schemas.len][:0]const u8 = undefined;
    comptime var field_types: [function_schemas.len]type = undefined;
    inline for (function_schemas, 0..) |FunctionSchema, index| {
        // Positional names: distinct schemas may share a function name.
        field_names[index] = std.fmt.comptimePrint("f{d}", .{index});
        field_types[index] = MaterializedCompletion(FunctionSchema, Payload, void, Ops).Owned;
    }
    const frozen_names = field_names;
    const Tag = @Enum(u8, .exhaustive, &frozen_names, &std.simd.iota(u8, frozen_names.len));
    const Inner = @Union(.auto, Tag, &frozen_names, &field_types, &@splat(.{}));

    const Result_ = struct {
        const FirstFunction = FunctionMetadata(Manifest.FunctionId(function_schemas[0]), null);
        const member_function_ids = ids: {
            var ids: [function_schemas.len]usize = undefined;
            for (&ids, 0..) |*id, index| id.* = Manifest.FunctionId(function_schemas[index]);
            break :ids ids;
        };

        fn memberIndex(comptime function_id: usize) usize {
            return std.mem.indexOfScalar(usize, &member_function_ids, function_id) orelse
                @compileError("function is not part of this completion set");
        }

        pub fn TypedCreated(comptime DeclaredPromiseResult: type) type {
            return struct {
                promise: StrongPromise(DeclaredPromiseResult),
                completion: Owned,
            };
        }

        pub const Owned = struct {
            inner: Inner,

            pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);

            pub fn readyDeliveryScope(owned: *const Owned, global: *jsc.JSGlobalObject) ReadyCompletionDeliveryScope {
                return switch (owned.inner) {
                    inline else => |*variant| variant.readyDeliveryScope(global),
                };
            }

            pub fn complete(owned: *Owned, payload: *Payload) void {
                switch (owned.inner) {
                    inline else => |*variant| variant.complete(payload),
                }
            }

            pub fn outOfMemory(owned: *Owned) void {
                switch (owned.inner) {
                    inline else => |*variant| variant.outOfMemory(),
                }
            }

            pub fn fail(
                owned: *Owned,
                comptime tag: FailureTagType(FirstFunction),
                payload: FailurePayloadApiType(FirstFunction, tag),
            ) void {
                @setEvalBranchQuota(10_000_000);
                switch (owned.inner) {
                    inline else => |*variant, variant_tag| {
                        const FunctionSchema = function_schemas[@backingInt(variant_tag)];
                        const Function = FunctionMetadata(Manifest.FunctionId(FunctionSchema), null);
                        const candidate_tag = @field(FailureTagType(Function), @tagName(tag));
                        if (FailurePayloadApiType(Function, candidate_tag) != @TypeOf(payload)) {
                            @compileError("materialized completion set failure payloads disagree");
                        }
                        variant.fail(candidate_tag, payload);
                    },
                }
            }

            pub fn reject(
                owned: *Owned,
                value: *Root,
                rejection_options: CompletionRejectionOptions,
            ) void {
                switch (owned.inner) {
                    inline else => |*variant| variant.reject(value, rejection_options),
                }
            }

            pub fn adoptPromise(owned: *Owned, promise: *CompletionTypes(FirstFunction).AdoptedPromise) void {
                switch (owned.inner) {
                    inline else => |*variant| variant.adoptPromise(promise),
                }
            }

            pub fn release(owned: *Owned) void {
                switch (owned.inner) {
                    inline else => |*variant| variant.release(),
                }
            }
        };

        pub fn take(comptime FunctionSchema: type, view: *CompletionTypes(FunctionMetadata(Manifest.FunctionId(FunctionSchema), null)).View) Owned {
            const index = comptime memberIndex(Manifest.FunctionId(FunctionSchema));
            const owned = MaterializedCompletion(FunctionSchema, Payload, void, Ops).takeWithoutAttachment(view);
            return .{ .inner = @unionInit(Inner, frozen_names[index], owned) };
        }

        pub fn createTyped(
            comptime FunctionSchema: type,
            comptime DeclaredPromiseResult: type,
            context: anytype,
        ) bun.JSError!TypedCreated(DeclaredPromiseResult) {
            context.requireActive();
            return createTypedInRealm(FunctionSchema, DeclaredPromiseResult, context.viewToken().globalObject());
        }

        pub fn createTypedInRealm(
            comptime FunctionSchema: type,
            comptime DeclaredPromiseResult: type,
            global: *jsc.JSGlobalObject,
        ) bun.JSError!TypedCreated(DeclaredPromiseResult) {
            const index = comptime memberIndex(Manifest.FunctionId(FunctionSchema));
            const created = try MaterializedCompletion(FunctionSchema, Payload, void, Ops)
                .createTypedWithoutAttachmentInRealm(DeclaredPromiseResult, global);
            return .{
                .promise = created.promise,
                .completion = .{ .inner = @unionInit(Inner, frozen_names[index], created.completion) },
            };
        }

        /// Takes the completion for whichever set member is being called,
        /// matched through the call context, so shared funnels do not need the
        /// schema threaded explicitly.
        pub fn takeForContext(context: anytype, view: *CompletionTypes(FunctionMetadata(ContextMetadata(@TypeOf(context)).bindgen_function_id, null)).View) Owned {
            const index = comptime memberIndex(ContextMetadata(@TypeOf(context)).bindgen_function_id);
            return take(function_schemas[index], view);
        }
    };
    return Result_;
}

pub fn Fn(comptime Handle: type, comptime implementation: anytype) type {
    return switch (declarationKind(Handle)) {
        .function => ImplementationBinding(.function, Manifest.FunctionId(Handle), implementation).binding,
        .native_export => ImplementationBinding(.native_export, Manifest.NativeExportId(Handle), implementation).binding,
        .engine_shim, .callback => @compileError("bindgen.Fn binds function and native export implementations"),
    };
}

const ImplementationKind = enum { function, native_export };

/// An implementation's binding, built once in a declaration of a type keyed by
/// the declaration and the implementation, so a `comptime` block binding many
/// implementations is charged only for selecting each binding.
fn ImplementationBinding(comptime kind: ImplementationKind, comptime id: usize, comptime implementation: anytype) type {
    const Bound = struct {
        pub const binding = binding: {
            @setEvalBranchQuota(api_eval_branch_quota);
            break :binding switch (kind) {
                .function => FnBinding(id, implementation),
                .native_export => NativeExportBinding(id, implementation),
            };
        };
    };
    return Bound;
}

fn FnBinding(comptime function_id: usize, comptime implementation: anytype) type {
    const Function = FunctionMetadata(function_id, null);
    if (Function.backend != .zig) @compileError("bindgen.Fn requires a .zig schema backend");
    const ImplementationResult = if (Function.is_async) void else Api(Function.result_position);
    const ImplementationArgs = if (Function.is_overloaded) OverloadArgsType(Function) else ArgsType(Function);
    const Expected = fn (FunctionCallContext(function_id), ImplementationArgs) FunctionCallError(Function)!ImplementationResult;
    if (@TypeOf(implementation) != Expected) {
        @compileError(std.fmt.comptimePrint(
            "binding implementation '{s}.{s}' has an incompatible signature\nexpected: {s}\nactual:   {s}",
            .{ Function.module_name, Function.function_name, @typeName(Expected), @typeName(@TypeOf(implementation)) },
        ));
    }

    return CallableBinding(function_id, implementation);
}

fn CallableBinding(comptime function_id: usize, comptime implementation: anytype) type {
    if (FunctionMetadata(function_id, null).is_overloaded) return OverloadedFunctionBinding(function_id, implementation);
    return FunctionBinding(function_id, implementation, null);
}

fn validateClassImplementation(comptime Impl: type, comptime NormalizedClass: type) void {
    const info = @typeInfo(Impl).@"struct";
    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        if (comptime NormalizedClass.runtime_plan.ownership.isNativeShared() and std.mem.eql(u8, field_name, "ref_count")) continue;
        if (comptime NormalizedClass.has_parent) {
            if (FieldType == Impl.Parent) {
                validateClassImplementation(Impl.Parent, NormalizedClass.Parent);
                continue;
            }
        }
        validateClassFieldType(
            FieldType,
            @typeName(Impl) ++ "." ++ field_name,
            !NormalizedClass.runtime_plan.ownership.canReferenceOffThread(),
        );
    }
}

fn validateClassFunction(comptime Impl: type, comptime name: []const u8, comptime Expected: type, comptime category: []const u8) void {
    if (!@hasDecl(Impl, name))
        @compileError(category ++ " '" ++ @typeName(Impl) ++ "' is missing " ++ name);
    if (@TypeOf(@field(Impl, name)) != Expected)
        @compileError(category ++ " '" ++ @typeName(Impl) ++ "." ++ name ++ "' has an incompatible signature");
}

fn validateSharedClassImplementation(comptime Impl: type, comptime NormalizedClass: type) void {
    if (!@hasField(Impl, "ref_count")) {
        @compileError("shared class implementation '" ++ @typeName(Impl) ++ "' is missing ref_count");
    }
    const RefCount = @FieldType(Impl, "ref_count");
    if (!@hasDecl(RefCount, "ref_count_target") or RefCount.ref_count_target != Impl) {
        @compileError("shared class ref_count must be bun.ptr.RefCount or bun.ptr.ThreadSafeRefCount for the implementation type");
    }
    if (comptime NormalizedClass.runtime_plan.ownership.canReferenceOffThread() and !RefCount.thread_safe) {
        @compileError("an any-thread shared class requires bun.ptr.ThreadSafeRefCount");
    }
    inline for (.{
        .{ "ref", fn (*Impl) void },
        .{ "deref", fn (*Impl) void },
        .{ "derefDeferred", fn (*Impl) bool },
        .{ "destroyAfterDeferred", fn (*Impl) void },
    }) |contract| {
        const name, const Expected = contract;
        validateClassFunction(Impl, name, Expected, "shared class implementation");
    }
}

fn validateClassState(comptime Impl: type, comptime NormalizedClass: type) void {
    if (@hasDecl(Impl, "bindgenState")) {
        if (comptime !NormalizedClass.has_parent or !NormalizedClass.runtime_plan.ownership.isNativeShared()) {
            @compileError("bindgenState is reserved for inherited shared class implementations: " ++ @typeName(Impl));
        }
        validateClassFunction(Impl, "bindgenState", fn (*Impl) *ClassState, "bound class implementation");
        return;
    }
    if (!@hasField(Impl, "bindgen_state")) {
        @compileError("bound class implementation '" ++ @typeName(Impl) ++ "' is missing bindgen_state: bindgen.ClassState or bindgenState");
    }
    if (@FieldType(Impl, "bindgen_state") != ClassState) {
        @compileError("bound class implementation '" ++ @typeName(Impl) ++ "' has an invalid bindgen_state field");
    }
}

fn classState(comptime Impl: type, native: *Impl) *ClassState {
    if (comptime @hasDecl(Impl, "bindgenState")) return Impl.bindgenState(native);
    return &native.bindgen_state;
}

fn ClassWireAdapter(comptime NormalizedClass: type) type {
    const Result_ = struct {
        fn constructor(global: *jsc.JSGlobalObject) jsc.JSValue {
            var encoded: i64 = undefined;
            @field(wire, NormalizedClass.get_constructor_symbol)(@ptrCast(global), &encoded);
            return @fromBackingInt(encoded);
        }

        fn wrap(global: *jsc.JSGlobalObject, native: *wire.BindNativeHandle) bun.JSError!jsc.JSValue {
            var encoded: i64 = 0;
            const raw_status = @field(wire, NormalizedClass.wrap_native_symbol)(@ptrCast(global), native, &encoded);
            return decodeCreatedObject(global, raw_status, encoded);
        }
    };
    return Result_;
}

fn SharedClassOperations(comptime class_id: usize, comptime Impl: type) type {
    const NormalizedClass = Manifest.ClassAt(class_id);
    if (comptime !NormalizedClass.runtime_plan.ownership.isNativeShared()) {
        @compileError("shared class operations require shared ownership");
    }
    const Result_ = struct {
        const value: SharedClassOps = .{
            .retain = retain,
            .release_deferred = releaseDeferred,
            .destroy_deferred = destroyDeferred,
            .wrap = wrap,
        };

        fn retain(native: *anyopaque) void {
            Impl.ref(@ptrCast(@alignCast(native)));
        }

        fn releaseDeferred(native: *anyopaque) bool {
            return Impl.derefDeferred(@ptrCast(@alignCast(native)));
        }

        fn destroyDeferred(native: *anyopaque) void {
            Impl.destroyAfterDeferred(@ptrCast(@alignCast(native)));
        }

        fn wrap(global: *jsc.JSGlobalObject, native: *anyopaque) bun.JSError!jsc.JSValue {
            return ClassWireAdapter(NormalizedClass).wrap(global, @ptrCast(native));
        }
    };
    return Result_;
}

fn sharedClassOps(comptime class_id: usize, comptime Impl: type) *const SharedClassOps {
    return &SharedClassOperations(class_id, Impl).value;
}

fn initializeClassState(
    comptime class_id: usize,
    comptime Impl: type,
    native: *Impl,
    finalizer_queue: *jsc.NativeFinalizerQueue,
) void {
    const NormalizedClass = Manifest.ClassAt(class_id);
    const state = classState(Impl, native);
    const shared_owner: ?SharedClassOwner = if (comptime NormalizedClass.runtime_plan.ownership.isNativeShared())
        .{ .native = native, .ops = sharedClassOps(class_id, Impl) }
    else
        null;
    state.initializeFresh(finalizer_queue, shared_owner);
}

fn initializeStructuredCloneClassState(
    comptime class_id: usize,
    comptime Impl: type,
    native: *Impl,
    finalizer_queue: *jsc.NativeFinalizerQueue,
) void {
    const NormalizedClass = Manifest.ClassAt(class_id);
    if (comptime NormalizedClass.runtime_plan.ownership.isNativeShared()) {
        const state = classState(Impl, native);
        if (!state.isPristine()) {
            state.requireFinalizerQueueForVM(finalizer_queue);
            const owner = state.sharedOwner();
            if (owner.native != @as(*anyopaque, @ptrCast(native)) or
                owner.ops != sharedClassOps(class_id, Impl))
            {
                @panic("structured clone returned a shared native with incompatible bindgen state");
            }
            return;
        }
    }
    initializeClassState(class_id, Impl, native, finalizer_queue);
}

fn validateClassFieldType(
    comptime T: type,
    comptime path: []const u8,
    comptime allow_vm_affine: bool,
) void {
    class_field_validation.validate(
        T,
        path,
        .{ Root, Root.Optional, EngineRoot, EngineRoot.Optional },
        .{jsc.JSValue},
        .{ViewToken},
        .{ jsc.JSGlobalObject, jsc.VirtualMachine, jsc.VM },
        allow_vm_affine,
    );
}

const EntryScope = struct {
    active: ActiveCallScope,
    global: ?*jsc.JSGlobalObject,
    inherited_exception: ?*const wire.BindExceptionHandle,

    fn init(entry: *EntryScope, context: *const wire.BindCallContext, global: ?*jsc.JSGlobalObject) void {
        entry.global = global;
        entry.inherited_exception = if (global) |realm| wire.bun_bindgen_current_exception(@ptrCast(realm)) else null;
        if (global) |realm|
            entry.active.initWithDeferred(context.call_id, realm, context.deferred_conversions, context.lazy_storage)
        else
            entry.active.initRealmFree(context.call_id);
    }

    fn deinit(entry: *EntryScope) void {
        entry.active.deinit();
    }

    fn failure(entry: *const EntryScope, err: bun.JSError) wire.BindStatus {
        return entry.status(switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.JSError, error.JSTerminated => .pending_exception,
        });
    }

    fn status(entry: *const EntryScope, result: Status) wire.BindStatus {
        return if (entry.global) |global| checkedNativeStatus(global, result, entry.inherited_exception) else @backingInt(result);
    }
};

fn Inbound(comptime Function: type, comptime implementation: anytype) type {
    const Parent = Function.Parent;
    const call = Function.call_plan;
    const WireArgs = wireType(Function.wire_args);
    const WireResult = wireType(Function.wire_result);
    return struct {
        fn enter(
            raw_context: ?*wire.BindCallContext,
            raw_args: ?*const WireArgs,
            raw_result: ?*WireResult,
        ) callconv(.c) wire.BindStatus {
            const context_ptr = raw_context orelse @panic("binding received a null call context");
            const args_ptr = raw_args orelse @panic("binding received null arguments");
            const result = raw_result orelse @panic("binding received a null result");
            result.* = std.mem.zeroes(WireResult);
            if (context_ptr.call_id == 0) @panic("binding received call ID zero");
            const global: if (call.realm == .current) *jsc.JSGlobalObject else @TypeOf(null) = if (comptime call.realm == .current)
                @ptrCast(@alignCast(context_ptr.global_object orelse @panic("binding received no declared realm")))
            else no_realm: {
                if (context_ptr.global_object != null) @panic("realm-free binding received a realm");
                break :no_realm null;
            };
            var entry: EntryScope = undefined;
            entry.init(context_ptr, global);
            defer entry.deinit();
            const inherited_exception = entry.inherited_exception;
            if (comptime call.receiver != null) {
                if (context_ptr.native_receiver == null) @panic("binding received no declared receiver");
            } else if (!Function.has_callback_data and context_ptr.native_receiver != null) {
                @panic("binding received an undeclared receiver");
            }
            if (Function.has_caller_source_location != (context_ptr.caller_frame != null))
                @panic("binding received an invalid caller frame");
            if (call.acquires_byte_lease != (context_ptr.deferred_conversions != null))
                @panic("binding received an invalid deferred-lease state");
            if (call.has_lazy_arguments != (context_ptr.lazy_storage != null))
                @panic("binding received invalid deferred conversion storage");

            var completion_taken = false;
            var invocation_succeeded = false;
            const completion_control: if (Parent.is_async) *anyopaque else @TypeOf(null) = if (comptime Parent.is_async) control: {
                const promise_handle = context_ptr.promise orelse @panic("asynchronous binding received no promise");
                const promise: jsc.JSValue = @fromBackingInt(value_encoding.fromCell(promise_handle));
                const completion = CompletionTypes(Parent).create(global, promise) catch |err| {
                    return entry.failure(err);
                };
                completion.retain();
                completion.invocation_active = true;
                break :control @ptrCast(completion);
            } else no_completion: {
                if (context_ptr.promise != null) @panic("synchronous binding received a promise");
                break :no_completion null;
            };
            defer if (comptime Parent.is_async) {
                CompletionTypes(Parent).finishInvocation(@ptrCast(@alignCast(completion_control)), completion_taken, invocation_succeeded);
            };

            var failure: DomainFailureStorage(Parent) = .{};
            var context_state: CallContextState(Parent) = .{
                .call = &entry.active.call,
                .failure = &failure,
                .completion_control = completion_control,
                .completion_taken = &completion_taken,
                .native_receiver = if (context_ptr.native_receiver) |native| @ptrCast(native) else null,
                .caller_frame = context_ptr.caller_frame,
            };
            const context: Function.Context = if (comptime call.realm == .current) @ptrCast(&context_state) else {};
            const decoded = decodeArgs(Function, args_ptr, global, entry.active.token());
            const InvocationArgs = if (Parent.is_overloaded) OverloadArgsType(Parent) else ArgsType(Function);
            var args: InvocationArgs = if (comptime Function.overload_tag) |tag| @unionInit(InvocationArgs, tag, decoded) else decoded;
            defer if (comptime call.transfers_argument_ownership) destroyArguments(Function, &args);
            const operand = if (comptime call.transfers_argument_ownership) &args else args;
            const operands = if (comptime call.realm == .current) .{ context, operand } else .{operand};
            if (comptime call.non_returning) return @call(.auto, implementation, operands);
            const value = if (comptime call.throws == .never)
                @call(.auto, implementation, operands)
            else
                @call(.auto, implementation, operands) catch |err| {
                    if (err == error.BindgenDomainFailure) {
                        if (Function.domain_errors.len == 0 or failure.payload == null) @panic("binding returned a domain failure without a declared payload");
                        return commitCheckedResult(Function, global, result, commitDomainFailure(Function, failure), .failed, inherited_exception);
                    }
                    if (failure.payload != null) @panic("binding returned an exception after committing a domain failure");
                    return entry.failure(@errorCast(err));
                };
            if (failure.payload != null) @panic("binding returned success after committing a domain failure");
            if (comptime !Parent.is_async) {
                const encoded = encodeResult(Function, value);
                if (comptime call.realm == .current) return commitCheckedResult(Function, global, result, encoded, .ok, inherited_exception);
                result.* = encoded;
                return @backingInt(Status.ok);
            }
            var status = entry.status(.ok);
            if (comptime Parent.completion.settlement == .ready_at_return) {
                if (status == @backingInt(Status.ok)) {
                    const control: *CompletionTypes(Parent).Control = @ptrCast(@alignCast(completion_control));
                    _ = control.registry.deliverReady(&control.entry);
                    status = entry.status(.ok);
                }
            }
            invocation_succeeded = status == @backingInt(Status.ok);
            return status;
        }

        comptime {
            @export(&enter, .{ .name = Function.dispatch_symbol });
            _ = ResultBinding(Function);
        }
    };
}

fn FunctionBinding(
    comptime function_id: usize,
    comptime implementation: anytype,
    comptime overload_index: ?usize,
) type {
    const Function = FunctionMetadata(function_id, overload_index);

    const Binding = struct {
        pub const bindgen_function_id = function_id;
        pub const bindgen_overload_index = overload_index;

        const bound_implementation = implementation;

        const CallbackWithDataIdentity = struct {
            pub const bindgen_function_id = function_id;
        };

        const host = @extern(*const JSHostFn, .{ .name = Function.host_symbol });

        pub const CallbackWithData = struct {
            root: RetainedValueRoot(CallbackWithDataIdentity),

            pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
            pub const bindgen_retained_any_value = &retained_any_value_proof;

            const Self = @This();

            pub fn operand(callback: *const Self, context: anytype) AnyOperand {
                callback.root.requireCurrentVM(context.viewToken().globalObject());
                return AnyOperand.init(callback.root.get(), context.viewToken());
            }

            pub fn clearData(callback: *const Self) void {
                const global = callback.root.globalObject();
                callback.root.requireCurrentVM(global);
                var scope: FocusedEngineScope = undefined;
                scope.init(global);
                defer scope.deinit();
                const FunctionType = Manifest.EngineShimAt(Manifest.EngineShimId(BindingFunctionClearDataSchema)).args[0].ArgumentType;
                scope.engine(BindingFunctionClearDataSchema).call(.{
                    .function = ValueOperand(.branded, FunctionType.Brand).init(callback.root.get(), scope.viewToken()),
                });
            }

            pub fn deinit(callback: *Self) void {
                callback.root.deinit();
            }
        };

        pub fn createCallbackValue(context: anytype) @TypeOf(context.engineIn("js_functions", "bindingFunctionCreate")).Return {
            if (comptime Function.is_class_member) @compileError("class members are created with their owning class");
            if (comptime Function.has_callback_data) {
                @compileError("callback-data functions require createCallbackWithData");
            }
            return createEngineFunctionValue(context, Function.function_name, Function.js_length, host);
        }

        pub fn createCallbackWithData(global: *jsc.JSGlobalObject, data: *Function.CallbackData) bun.JSError!CallbackWithData {
            if (comptime !Function.has_callback_data) {
                @compileError("callback data was not declared for this binding");
            }
            var name = try DOMString.fromLatin1(Function.function_name);
            defer name.deinit();
            var scope: FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const callback = try scope.engine(BindingFunctionCreateWithDataSchema).call(.{
                .symbolName = name.operand(),
                .argumentCount = Function.js_length,
                .function = @ptrCast(@constCast(host)),
                .data = @ptrCast(data),
            });
            return .{ .root = try .create(callback.rawValue(), global) };
        }

        comptime {
            _ = Inbound(Function, implementation);
        }
    };
    return Binding;
}

fn OverloadedFunctionBinding(comptime function_id: usize, comptime implementation: anytype) type {
    const Function = FunctionMetadata(function_id, null);
    const Result_ = struct {
        const host = @extern(*const JSHostFn, .{ .name = Function.host_symbol });

        comptime {
            for (0..Function.overload_cases.len) |overload_index| {
                _ = FunctionBinding(function_id, implementation, overload_index);
            }
            _ = ResultBinding(Function);
        }
    };
    return Result_;
}

fn classNativeTypeSymbol(comptime NormalizedClass: type, comptime Impl: type) []const u8 {
    const hash = std.hash.Fnv1a_64.hash(@typeName(Impl));
    return std.fmt.comptimePrint("{s}_{x}", .{ NormalizedClass.native_type_symbol_prefix, hash });
}

fn validateClassInheritance(comptime Impl: type, comptime NormalizedClass: type) void {
    const upcast = NormalizedClass.upcast orelse return;
    if (!@hasDecl(Impl, "Parent")) {
        @compileError("inherited class implementation '" ++ @typeName(Impl) ++ "' is missing Parent");
    }
    if (@TypeOf(Impl.Parent) != type) {
        @compileError("inherited class implementation '" ++ @typeName(Impl) ++ ".Parent' must be a type");
    }
    validateClassFunction(Impl, upcast.implementation, fn (*Impl) *Impl.Parent, "inherited class implementation");
}

fn validateOptionalClassContracts(comptime Impl: type, comptime NormalizedClass: type) void {
    if (NormalizedClass.memory_usage) |memory|
        validateClassFunction(Impl, "memoryUsage", fn (*const Impl, MemoryUsageContext(memory.affinity)) usize, "class implementation");
    if (NormalizedClass.pending_activity != null)
        validateClassFunction(Impl, "hasPendingActivity", fn (*const Impl) bool, "class implementation");
    if (NormalizedClass.runtime_plan.construction.wrapper_created != null)
        validateClassFunction(Impl, "wrapperCreated", fn (*Impl, ClassRefViewById(NormalizedClass.id)) bun.JSError!void, "class implementation");
    if (NormalizedClass.structured_clone) |structured_clone| {
        const CloneContext = StructuredCloneContextById(NormalizedClass.id);
        const ExpectedSerialize = switch (structured_clone.serialization) {
            .shared => |shared| {
                if (!@hasDecl(Impl, shared.state))
                    @compileError("shared structured clone is missing native state type " ++ shared.state);
                const State = @field(Impl, shared.state);
                class_field_validation.validateNative(State, @typeName(State), .{jsc.JSValue}, .{ViewToken}, .{ jsc.JSGlobalObject, jsc.VirtualMachine, jsc.VM }, false);
                if (!@hasField(State, "ref_count"))
                    @compileError("shared structured clone state requires a thread-safe ref_count");
                const Counter = @FieldType(State, "ref_count");
                if (!@hasDecl(Counter, "ref_count_target") or Counter.ref_count_target != State or !Counter.thread_safe)
                    @compileError("shared structured clone state requires bun.ptr.ThreadSafeRefCount");
                inline for (.{
                    .{ "ref", fn (*State) void },
                    .{ "deref", fn (*State) void },
                }) |contract| {
                    const name, const Expected = contract;
                    validateClassFunction(State, name, Expected, "shared structured clone state");
                }
                inline for (.{
                    .{ "structuredCloneShare", fn (*const Impl, CloneContext) bun.JSError!RefNative(State, .any) },
                    .{ "structuredCloneFromShared", fn (CloneContext, BorrowedNative(State, .any)) bun.JSError!*Impl },
                }) |contract| {
                    const name, const Expected = contract;
                    validateClassFunction(Impl, name, Expected, "class implementation");
                }
                return;
            },
            .bytes => |thread| switch (thread) {
                .any => fn (*const Impl, StructuredCloneWriter) bun.OOM!void,
                .vm => fn (*const Impl, CloneContext, StructuredCloneWriter) bun.JSError!void,
            },
        };
        inline for (.{
            .{ "structuredCloneSerialize", ExpectedSerialize },
            .{ "structuredCloneDeserialize", fn (CloneContext, *StructuredCloneReader) StructuredCloneError!*Impl },
        }) |contract| {
            const name, const Expected = contract;
            validateClassFunction(Impl, name, Expected, "class implementation");
        }
    }
}

const WeakRefCreateSchema = Module("weak_references").engineShim("weakRefCreate");
const WeakRefGetSchema = Module("weak_references").engineShim("weakRefGet");
const WeakRefFinalizerRunSchema = Module("weak_references").nativeExport("weakRefFinalizerRun");
const WeakFinalizerHandle = EngineArgumentType(WeakRefCreateSchema, "finalizer");

const WeakFinalizer = struct {
    references: std.atomic.Value(u32) = .init(1),
    cancelled: std.atomic.Value(bool) = .init(false),
    enqueued: std.atomic.Value(bool) = .init(false),
    node: jsc.NativeFinalizerQueue.Node = .{},
    queue: *jsc.NativeFinalizerQueue,
    context: NativeCallbackContext(.vm),
    callback: *const fn (NativeCallbackContext(.vm)) void,

    fn create(
        comptime T: type,
        global: *jsc.JSGlobalObject,
        context: *T,
        comptime callback: *const fn (*T) void,
    ) bun.OOM!*WeakFinalizer {
        const Wrapper = struct {
            fn run(raw_context: NativeCallbackContext(.vm)) void {
                callback(raw_context.get(*T));
            }
        };
        const queue = (try global.bunVM().tryRareData()).nativeFinalizerQueue();
        const result = try bun.default_allocator.create(WeakFinalizer);
        result.* = .{
            .queue = queue,
            .context = .init(context),
            .callback = Wrapper.run,
        };
        return result;
    }

    fn enqueue(this: *WeakFinalizer) void {
        if (this.enqueued.swap(true, .acq_rel)) @panic("weak finalizer queued twice");
        const previous = this.references.fetchAdd(1, .monotonic);
        bun.assert(previous == 1);
        this.queue.enqueue(&this.node, this, finalize);
    }

    fn cancel(this: *WeakFinalizer) void {
        this.cancelled.store(true, .release);
        this.release();
    }

    fn release(this: *WeakFinalizer) void {
        const previous = this.references.fetchSub(1, .acq_rel);
        bun.assert(previous > 0);
        if (previous == 1) bun.destroy(this);
    }

    fn finalize(this: *WeakFinalizer) void {
        defer this.release();
        if (!this.cancelled.load(.acquire)) this.callback(this.context);
    }

    fn bindRun(args: Args(WeakRefFinalizerRunSchema)) Return(WeakRefFinalizerRunSchema) {
        const this: *WeakFinalizer = @ptrCast(@alignCast(args.finalizer));
        this.enqueue();
    }
};

const WeakStorage = struct {
    state: ?State = null,

    const State = struct {
        reference: Return(WeakRefCreateSchema),
        global: *jsc.JSGlobalObject,
        finalizer: ?*WeakFinalizer,
    };

    const Self = @This();

    fn create(
        comptime T: type,
        value: jsc.JSValue,
        global: *jsc.JSGlobalObject,
        context: ?*T,
        comptime finalizer: ?*const fn (*T) void,
    ) bun.JSError!Self {
        switch (global.pendingExceptionKind()) {
            .none => {},
            .other => return error.JSError,
            .termination => return error.JSTerminated,
        }
        const owner: ?*WeakFinalizer = if (finalizer) |callback|
            try WeakFinalizer.create(T, global, context orelse @panic("weak finalizer requires a context"), callback)
        else
            null;
        errdefer if (owner) |record| record.cancel();
        if (bun.bindgen.testing.failWeakAllocation()) return error.OutOfMemory;
        var engine_scope: FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        return .{ .state = .{
            .reference = try engine_scope.engine(WeakRefCreateSchema).call(.{
                .value = engine_scope.borrowEngineValue(value),
                .finalizer = @as(WeakFinalizerHandle, if (owner) |record| @ptrCast(record) else null),
            }),
            .global = global,
            .finalizer = owner,
        } };
    }

    fn globalObject(this: *const Self) ?*jsc.JSGlobalObject {
        return if (this.state) |*state| state.global else null;
    }

    fn get(this: *const Self) bun.JSError!?jsc.JSValue {
        const state = if (this.state) |*owned| owned else return null;
        var scope: FocusedEngineScope = undefined;
        scope.init(state.global);
        defer scope.deinit();
        const result = (try scope.engine(WeakRefGetSchema).call(.{ .reference = &state.reference })) orelse return null;
        return result.rawValue();
    }

    fn deinit(this: *Self) void {
        var pending = bun.take(&this.state) orelse return;
        pending.reference.deinit();
        if (pending.finalizer) |owner| owner.cancel();
    }
};

comptime {
    _ = Fn(WeakRefFinalizerRunSchema, WeakFinalizer.bindRun);
}

pub const WrapperHandleKind = enum {
    strong,
    weak,
    activity,
};

pub fn WeakValueHandle(comptime ValueSchema: type) type {
    return WeakValueHandleType(ValueSchema);
}

fn WeakValueHandleType(comptime Type: type) type {
    if (comptime Type.kind != .branded_value) {
        @compileError("weak value handles require a branded value schema");
    }
    return struct {
        storage: WeakStorage = .{},

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const SemanticType = Type;
        pub const empty: @This() = .{};

        const Self = @This();

        fn init(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!Self {
            return .{ .storage = try WeakStorage.create(void, value, global, null, null) };
        }

        fn rawValue(handle: *const Self) bun.JSError!?jsc.JSValue {
            return handle.storage.get();
        }

        pub fn toOwned(handle: *const Self) bun.JSError!?OwnedBrandedValueType(Type) {
            const value = (try handle.rawValue()) orelse return null;
            const global = handle.storage.globalObject().?;
            return .{ .root = try BrandedRoot(Type).create(value, global) };
        }

        pub fn take(handle: *Self) Self {
            const result = handle.*;
            handle.* = .empty;
            return result;
        }

        pub fn deinit(handle: *Self) void {
            handle.storage.deinit();
        }
    };
}

fn tryCastClassNative(comptime class_id: usize, value: jsc.JSValue) ?*anyopaque {
    const NormalizedClass = Manifest.ClassAt(class_id);
    return @ptrCast(@field(wire, NormalizedClass.try_cast_symbol)(@backingInt(value)) orelse return null);
}

fn tryCastClassRef(comptime class_id: usize, value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!?ClassRefById(class_id) {
    if (tryCastClassNative(class_id, value) == null) return null;
    return .{ .root = try ClassRootById(class_id).create(value, global) };
}

fn requireClassNative(comptime class_id: usize, value: jsc.JSValue) *anyopaque {
    return tryCastClassNative(class_id, value) orelse @panic("binding class reference lost its class identity");
}

fn requireClassReferenceNative(comptime class_id: usize, value: jsc.JSValue, native: *const wire.BindNativeHandle) void {
    if (@intFromPtr(requireClassNative(class_id, value)) != @intFromPtr(native))
        @panic("binding class reference native pointer does not match its wrapper");
}

fn cachedSlotValueHandle(
    comptime Slot: type,
    wrapper: jsc.JSValue,
) *const wire.BindJSValueHandle {
    return @field(wire, Slot.get_symbol)(@backingInt(wrapper)) orelse @panic("binding cached slot returned a null handle");
}

fn setCachedSlotValue(
    comptime Slot: type,
    global: *jsc.JSGlobalObject,
    wrapper: jsc.JSValue,
    value: jsc.JSValue,
) void {
    const write = if (Slot.write) |operation| operation else @compileError("cached slot is read-only");
    @field(wire, write.set)(@ptrCast(global), @backingInt(wrapper), @backingInt(value));
}

fn setCachedSlotRoot(comptime Slot: type, global: *jsc.JSGlobalObject, wrapper: jsc.JSValue, root: anytype) void {
    root.requireCurrentVM(global);
    if (root.globalObject() != global)
        @panic("binding cached slot and owned value belong to different realms");
    setCachedSlotValue(Slot, global, wrapper, root.get());
}

/// A typed handle to a bound class's own wrapper. Parameterized by the class
/// schema alone so implementations can store their own handle as a field
/// without a dependency cycle through `bindgen.Class`.
pub fn ClassWrapperHandle(comptime ClassSchema: type, comptime kind: WrapperHandleKind) type {
    return ClassWrapperHandleById(Manifest.ClassId(ClassSchema), kind);
}

fn ClassWrapperHandleById(comptime class_id: usize, comptime kind: WrapperHandleKind) type {
    const NormalizedClass = Manifest.ClassAt(class_id);
    const Storage = if (kind == .strong)
        ClassRootById(class_id)
    else
        WeakStorage;
    return struct {
        storage: Storage,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const bindgen_class_wrapper_handle = class_id;

        const Self = @This();
        const ReadError = if (kind == .strong) error{} else bun.JSError;

        fn ReadResult(comptime Value: type) type {
            return if (kind == .strong) Value else bun.JSError!Value;
        }

        pub const empty: Self = if (kind == .strong)
            @compileError("strong wrapper handles have no empty state")
        else
            .{ .storage = .{} };

        pub fn initView(view: ClassRefViewById(class_id)) bun.JSError!Self {
            if (comptime kind == .activity and NormalizedClass.pending_activity == null) {
                @compileError("activity wrapper handles require has_pending_activity");
            }
            view.wrapper.token.requireActive();
            const global = view.wrapper.engineGlobal();
            const value = view.wrapper.rawValue();
            return .{
                .storage = if (comptime kind == .strong)
                    try ClassRootById(class_id).create(value, global)
                else
                    try WeakStorage.create(void, value, global, null, null),
            };
        }

        pub fn initRef(ref: *const ClassRefById(class_id)) ReadResult(Self) {
            if (comptime kind == .activity and NormalizedClass.pending_activity == null) {
                @compileError("activity wrapper handles require has_pending_activity");
            }
            const value = ref.root.get();
            return .{
                .storage = if (comptime kind == .strong)
                    ref.root.clone()
                else
                    try WeakStorage.create(void, value, ref.globalObject(), null, null),
            };
        }

        fn globalObject(handle: *const Self) ?*jsc.JSGlobalObject {
            if (comptime kind != .strong) return handle.storage.globalObject();
            if (handle.storage.impl == null) return null;
            return handle.storage.globalObject();
        }

        fn rawValue(handle: *const Self) ReadError!?jsc.JSValue {
            const value = if (comptime kind == .strong)
                handle.storage.get()
            else
                (try handle.storage.get()) orelse return null;
            if (tryCastClassNative(class_id, value) == null) return null;
            return value;
        }

        pub fn isAlive(handle: *const Self) ReadResult(bool) {
            return (try handle.rawValue()) != null;
        }

        pub fn matchesView(handle: *const Self, view: ClassRefViewById(class_id)) ReadResult(bool) {
            view.wrapper.token.requireActive();
            if (handle.globalObject() != view.wrapper.engineGlobal()) return false;
            const value = (try handle.rawValue()) orelse return false;
            return value == view.wrapper.rawValue();
        }

        pub fn toOwned(handle: *const Self) ReadResult(?ClassRefById(class_id)) {
            const global = handle.globalObject() orelse return null;
            const value = (try handle.rawValue()) orelse return null;
            return .{
                .root = if (comptime kind == .strong) handle.storage.clone() else try ClassRootById(class_id).create(value, global),
            };
        }

        pub fn deinit(handle: *Self) void {
            handle.storage.deinit();
        }
    };
}

pub fn ClassWeakHandle(comptime ClassSchema: type, comptime Context: type) type {
    return ClassWeakHandleById(Manifest.ClassId(ClassSchema), Context);
}

fn ClassWeakHandleById(comptime class_id: usize, comptime Context: type) type {
    return struct {
        storage: WeakStorage = .{},

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const empty: @This() = .{};

        const Self = @This();

        pub fn initRef(
            ref: *const ClassRefById(class_id),
            context: *Context,
            comptime finalizer: *const fn (*Context) void,
        ) bun.JSError!Self {
            return .{
                .storage = try WeakStorage.create(
                    Context,
                    ref.root.get(),
                    ref.globalObject(),
                    context,
                    finalizer,
                ),
            };
        }

        pub fn toOwned(handle: *const Self) bun.JSError!?ClassRefById(class_id) {
            const global = handle.storage.globalObject() orelse return null;
            const value = (try handle.storage.get()) orelse return null;
            return tryCastClassRef(class_id, value, global);
        }

        pub fn deinit(handle: *Self) void {
            handle.storage.deinit();
        }
    };
}

pub fn WrapperReference(comptime ClassSchemas: anytype) type {
    if (ClassSchemas.len == 0) @compileError("WrapperReference requires at least one class schema");
    var class_ids: [ClassSchemas.len]usize = undefined;
    inline for (ClassSchemas, 0..) |ClassSchema, index| {
        class_ids[index] = Manifest.ClassId(ClassSchema);
    }
    return WrapperReferenceByIds(class_ids);
}

fn WrapperReferenceByIds(comptime class_ids: anytype) type {
    const Result_ = struct {
        state: State = .empty,

        pub const bindgen_gc_token = gc_token.markerWithAffinity(@This(), .vm);
        pub const wrapper_class_ids = class_ids;

        const Self = @This();
        const State = union(enum) {
            empty,
            live: struct {
                weak: WeakStorage,
                strong: ?ClassSetRoot(class_ids),
            },
            finalized,
        };

        pub fn empty() Self {
            return .{};
        }

        pub const initWeakRef = Retention(false).initRef;
        pub const initStrongRef = Retention(true).initRef;
        pub const setWeakClassView = Retention(false).setView;
        pub const setStrongClassView = Retention(true).setView;

        fn Retention(comptime strong: bool) type {
            return struct {
                fn initRef(ref: anytype) bun.JSError!Self {
                    comptime requireAcceptedReference(@TypeOf(ref));
                    return .{
                        .state = try createState(ref.root.get(), ref.globalObject(), strong),
                    };
                }

                fn setView(reference: *Self, comptime ClassSchema: type, view: ClassRefView(ClassSchema)) bun.JSError!void {
                    comptime requireAcceptedClass(ClassSchema);
                    if (reference.state == .finalized) return;
                    view.wrapper.token.requireActive();
                    try reference.replaceValue(view.wrapper.rawValue(), view.wrapper.engineGlobal(), strong);
                }
            };
        }

        fn rawValue(reference: *const Self) bun.JSError!?jsc.JSValue {
            const value = (try reference.readValue()) orelse return null;
            return if (accepts(value)) value else null;
        }

        fn readValue(reference: *const Self) bun.JSError!?jsc.JSValue {
            return switch (reference.state) {
                .empty, .finalized => null,
                .live => |*live| if (live.strong) |*strong| strong.get() else try live.weak.get(),
            };
        }

        fn createState(value: jsc.JSValue, global: *jsc.JSGlobalObject, comptime strong: bool) bun.JSError!State {
            var weak = try WeakStorage.create(void, value, global, null, null);
            errdefer weak.deinit();
            return .{ .live = .{
                .weak = weak,
                .strong = if (strong) try ClassSetRoot(class_ids).create(value, global) else null,
            } };
        }

        fn replaceValue(reference: *Self, value: jsc.JSValue, global: *jsc.JSGlobalObject, comptime strong: bool) bun.JSError!void {
            if (reference.state == .live and reference.globalObject() == global) {
                if ((try reference.readValue()) == value) {
                    if (strong) {
                        if (reference.state.live.strong == null)
                            reference.state.live.strong = try ClassSetRoot(class_ids).create(value, global);
                    } else reference.downgrade();
                    return;
                }
            }
            reference.replaceState(try createState(value, global, strong));
        }

        pub fn toOwnedClassRef(reference: *const Self, comptime ClassSchema: type) bun.JSError!?ClassRef(ClassSchema) {
            comptime requireAcceptedClass(ClassSchema);
            const value = (try reference.rawValue()) orelse return null;
            const global = reference.globalObject();
            const requested_id = comptime Manifest.ClassId(ClassSchema);
            if (tryCastClassNative(requested_id, value) == null) return null;
            return .{
                .root = if (reference.state.live.strong) |*strong|
                    .{ .impl = strong.impl.?.clone() }
                else
                    try ClassRootById(requested_id).create(value, global),
            };
        }

        pub fn setStrongRef(reference: *Self, ref: anytype) bun.JSError!void {
            comptime requireAcceptedReference(@TypeOf(ref));
            if (reference.state == .finalized) return;
            try reference.replaceValue(ref.root.get(), ref.globalObject(), true);
        }

        pub fn upgrade(reference: *Self) bun.JSError!void {
            switch (reference.state) {
                .live => |*live| {
                    if (live.strong != null) return;
                    const value = (try live.weak.get()) orelse @panic("binding wrapper receiver was collected");
                    requireAccepted(value);
                    const global = reference.globalObject();
                    live.strong = try ClassSetRoot(class_ids).create(value, global);
                },
                .empty, .finalized => @panic("binding wrapper receiver is unavailable"),
            }
        }

        pub fn downgrade(reference: *Self) void {
            switch (reference.state) {
                .live => |*live| if (bun.take(&live.strong)) |strong| {
                    var owned = strong;
                    owned.deinit();
                },
                .empty, .finalized => {},
            }
        }

        pub fn isEmpty(reference: *const Self) bun.JSError!bool {
            return (try reference.rawValue()) == null;
        }

        pub fn isStrong(reference: *const Self) bool {
            return reference.state == .live and reference.state.live.strong != null;
        }

        pub fn isFinalized(reference: *const Self) bool {
            return reference.state == .finalized;
        }

        pub fn deinit(reference: *Self) void {
            if (reference.state == .finalized) return;
            reference.replaceState(.empty);
        }

        pub fn finalize(reference: *Self) void {
            reference.replaceState(.finalized);
        }

        fn globalObject(reference: *const Self) *jsc.JSGlobalObject {
            return switch (reference.state) {
                .live => |*live| live.weak.globalObject() orelse @panic("wrapper reference has no stored realm"),
                .empty, .finalized => @panic("binding wrapper receiver is unavailable"),
            };
        }

        fn accepts(value: jsc.JSValue) bool {
            inline for (class_ids) |class_id| {
                if (tryCastClassNative(class_id, value) != null) return true;
            }
            return false;
        }

        fn requireAcceptedReference(comptime Pointer: type) void {
            const Ref = @typeInfo(Pointer).pointer.child;
            const class_id = Ref.bindgen_class_id;
            if (Pointer != *ClassRefById(class_id) and Pointer != *const ClassRefById(class_id))
                @compileError("wrapper reference requires a pointer to an owned class reference");
            requireAcceptedClass(Manifest.ClassAt(class_id));
        }

        fn requireAcceptedClass(comptime ClassSchema: type) void {
            const requested_id = Manifest.ClassId(ClassSchema);
            inline for (class_ids) |candidate_id| {
                if (candidate_id == requested_id) return;
            }
            @compileError("wrapper reference does not accept class '" ++
                Manifest.ClassAt(requested_id).class_name ++ "'");
        }

        // Cannot type-check via `accepts` here: inside `construct` the wrapper's
        // impl pointer is not attached yet, so fromJS would reject the value.
        fn requireAccepted(value: jsc.JSValue) void {
            bun.assert(!value.isEmptyOrUndefinedOrNull());
            bun.assert(value.isCell());
        }

        fn replaceState(reference: *Self, replacement: State) void {
            var previous = reference.state;
            reference.state = replacement;
            switch (previous) {
                .live => |*live| {
                    live.weak.deinit();
                    if (live.strong) |*strong| strong.deinit();
                },
                .empty, .finalized => {},
            }
        }
    };
    return Result_;
}

pub fn Class(comptime ClassSchema: type, comptime Impl: type) type {
    const class_id = Manifest.ClassId(ClassSchema);
    if (Manifest.ClassAt(class_id).representation == .engine) {
        @compileError("engine-representation classes bind through EngineClassBackend");
    }
    return ClassBinding(class_id, Impl);
}

pub fn EngineClassBackend(comptime ClassSchema: type, comptime Impl: type) type {
    const class_id = Manifest.ClassId(ClassSchema);
    if (Manifest.ClassAt(class_id).representation != .engine) {
        @compileError("EngineClassBackend requires an engine-representation class");
    }
    const Binding = ClassBinding(class_id, Impl);
    return struct {
        comptime {
            if (Binding.bound_class_id != class_id) @compileError("engine class binding identity mismatch");
        }
    };
}

pub fn PlainObject(comptime ClassSchema: type) type {
    const class_id = Manifest.ClassId(ClassSchema);
    const NormalizedClass = Manifest.ClassAt(class_id);
    if (NormalizedClass.representation != .plain) @compileError("bindgen.PlainObject requires a plain class");
    if (!NormalizedClass.exposed) @compileError("bindgen.PlainObject cannot bind a class excluded from this target");
    const WireFields = @field(wire, NormalizedClass.create_symbol ++ "_Fields");
    const Result_ = struct {
        pub const Fields = PlainObjectFields(NormalizedClass);
        pub const ConstructorResult = ClassConstructorResultType(NormalizedClass.id);
        pub const InstanceValue = if (NormalizedClass.has_brand)
            Manifest.ClassInstanceValueType(class_id)
        else
            void;
        pub const OwnedInstance = if (NormalizedClass.has_brand)
            OwnedBrandedValueType(InstanceValue)
        else
            void;

        pub fn create(context: anytype, fields: *const Fields) bun.JSError!jsc.JSValue {
            const token = context.viewToken();
            token.requireActive();
            const global = token.globalObject();
            var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
            defer arena.deinit();
            var wire_fields: WireFields = undefined;
            if (NormalizedClass.instance_properties.len == 0) wire_fields._reserved = 0;
            inline for (NormalizedClass.instance_properties) |Property| {
                @field(wire_fields, Property.property_name) = try encode(Property.position).wire(&@field(fields.*, Property.property_name), .{ .global = global, .token = token, .allocator = arena.allocator() });
            }
            var encoded: wire.BindEncodedJSValue = 0;
            const status = @field(wire, NormalizedClass.create_symbol)(@ptrCast(global), &wire_fields, &encoded);
            return decodeCreatedObject(global, status, encoded);
        }

        pub fn createOwned(context: anytype, fields: *const Fields) bun.JSError!OwnedInstance {
            if (!NormalizedClass.has_brand) @compileError("bindgen.PlainObject.createOwned requires a branded plain class");
            const value = try create(context, fields);
            const global = context.viewToken().globalObject();
            return .{
                .root = try BrandedRoot(InstanceValue).create(value, global),
            };
        }

        pub fn constructorResult(context: anytype) ConstructorResult {
            context.requireActive();
            const global = context.viewToken().globalObject();
            return ConstructorResult.initInline(
                ClassWireAdapter(NormalizedClass).constructor(global),
                global,
                context.viewToken(),
                .branded,
            );
        }
    };
    return Result_;
}

fn ClassConstructorResultType(comptime class_id: usize) type {
    return BrandedValueResultType(Manifest.ClassConstructorValueType(class_id));
}

fn PlainObjectFields(comptime NormalizedClass: type) type {
    var names: [NormalizedClass.instance_properties.len][]const u8 = undefined;
    var types: [names.len]type = undefined;
    inline for (NormalizedClass.instance_properties, 0..) |Property, index| {
        names[index] = Property.property_name;
        types[index] = Api(Property.position);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn validateClassBinding(comptime class_id: usize, comptime Impl: type) void {
    const NormalizedClass = Manifest.ClassAt(class_id);
    if (!NormalizedClass.exposed) @compileError("bindgen.Class cannot bind a class excluded from this target");
    if (NormalizedClass.representation == .native) {
        if (@typeInfo(Impl) != .@"struct") @compileError("a bindgen class implementation must be a struct");
        validateClassState(Impl, NormalizedClass);
        validateClassInheritance(Impl, NormalizedClass);
        validateOptionalClassContracts(Impl, NormalizedClass);
        validateClassImplementation(Impl, NormalizedClass);
    }
    switch (NormalizedClass.runtime_plan.ownership) {
        .native_shared => validateSharedClassImplementation(Impl, NormalizedClass),
        .native_unique => {
            if (!@hasDecl(Impl, "destroy")) {
                @compileError("class implementation '" ++ @typeName(Impl) ++ "' is missing destroy");
            }
            const ExpectedDestroy = if (comptime NormalizedClass.runtime_plan.finalization.isInlineSweep())
                fn (*Impl, SweepContext) void
            else
                fn (*Impl) void;
            if (@TypeOf(Impl.destroy) != ExpectedDestroy) {
                @compileError("class implementation '" ++ @typeName(Impl) ++ ".destroy' has an incompatible signature");
            }
        },
        .none, .engine => {},
    }
    if (NormalizedClass.representation == .plain) @compileError("plain classes bind through bindgen.PlainObject");
    if (NormalizedClass.representation == .engine) {
        switch (@typeInfo(Impl)) {
            .@"opaque" => {},
            .@"struct" => |info| inline for (info.field_names, info.field_types) |field_name, FieldType| {
                validateClassFieldType(FieldType, @typeName(Impl) ++ "." ++ field_name, false);
            },
            else => @compileError("an engine class implementation must be an opaque or extern-struct mirror"),
        }
    }
    if (NormalizedClass.Constructor.exposed and !NormalizedClass.Constructor.is_illegal and NormalizedClass.representation == .native) {
        validateClassMemberImplementation(NormalizedClass.Constructor.id, Impl);
    }
    if (NormalizedClass.callable) {
        if (NormalizedClass.ConstructorCall.backend == .zig) {
            validateClassMemberImplementation(NormalizedClass.ConstructorCall.id, Impl);
        }
    }
    inline for (NormalizedClass.declarations) |Member| {
        if (Member.backend == .zig) {
            validateClassMemberImplementation(Member.id, Impl);
        }
    }
}

fn ClassBinding(comptime class_id: usize, comptime Impl: type) type {
    const NormalizedClass = Manifest.ClassAt(class_id);
    const Result_ = struct {
        pub const bound_class_id = class_id;
        pub const module_name = NormalizedClass.module_name;
        pub const class_name = NormalizedClass.class_name;
        pub const Native = Impl;

        fn tryCastNative(value: jsc.JSValue) ?*anyopaque {
            return tryCastClassNative(class_id, value);
        }

        fn tryCastNativeDirect(value: jsc.JSValue) ?*anyopaque {
            const native = @field(wire, NormalizedClass.try_cast_direct_symbol)(@backingInt(value)) orelse return null;
            return @ptrCast(native);
        }

        pub fn methodFunction(comptime name: []const u8, global: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
            const Member = NormalizedClass.member(name);
            if (comptime Member.exposed) {
                if (comptime Member.native_reference_symbol) |symbol| {
                    var encoded: wire.BindEncodedJSValue = 0;
                    const status = @field(wire, symbol)(@ptrCast(global), &encoded);
                    return decodeCreatedObject(global, status, encoded);
                }
            }
            @compileError("method function access requires an exposed method with native_reference enabled");
        }

        const SharedHandle = struct {
            pointer: ?*Impl,

            pub const bindgen_gc_token = gc_token.markerWithAffinity(
                @This(),
                if (!NormalizedClass.runtime_plan.ownership.canReferenceOffThread()) .vm else .any,
            );

            const Self = @This();

            pub fn initView(view: ClassRefViewById(class_id)) Self {
                view.wrapper.token.requireActive();
                const pointer = view.get(Impl);
                classState(Impl, pointer).retainShared();
                return .{ .pointer = pointer };
            }

            /// Consumes the native reference on both success and failure.
            pub fn adopt(pointer: *Impl, global: *jsc.JSGlobalObject) bun.OOM!Self {
                const rare = global.bunVM().tryRareData() catch |err| {
                    NativeLifetime.destroyUnbound(pointer);
                    return err;
                };
                const state = classState(Impl, pointer);
                state.bindFinalizerQueue(rare.nativeFinalizerQueue());
                state.bindSharedOwner(.{ .native = pointer, .ops = sharedClassOps(class_id, Impl) });
                return .{ .pointer = pointer };
            }

            pub fn get(handle: Self) *Impl {
                return handle.pointer orelse @panic("class native reference was already consumed");
            }

            pub fn clone(handle: Self) Self {
                const pointer = handle.get();
                classState(Impl, pointer).retainShared();
                return .{ .pointer = pointer };
            }

            pub fn take(handle: *Self) *Impl {
                const pointer = handle.get();
                handle.pointer = null;
                return pointer;
            }

            pub fn deinit(handle: *Self) void {
                const pointer = handle.pointer orelse return;
                handle.pointer = null;
                NativeLifetime.finalize(pointer);
            }
        };

        pub const Handle = if (NormalizedClass.runtime_plan.ownership.isNativeShared())
            SharedHandle
        else
            RootedNative(class_id, Impl);

        pub const StrongWrapper = ClassWrapperHandleById(class_id, .strong);
        pub const WeakWrapper = ClassWrapperHandleById(class_id, .weak);
        pub const ActivityWrapper = ClassWrapperHandleById(class_id, .activity);
        pub const WrapperRef = WrapperReferenceByIds(.{class_id});

        pub fn tryCast(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!?Handle {
            if (comptime NormalizedClass.runtime_plan.ownership.isNativeShared()) {
                @compileError("shared classes are cast with tryCastRef");
            }
            if (tryCastNative(value) == null) return null;
            return RootedNative(class_id, Impl).init(try ClassRootById(class_id).create(value, global));
        }

        pub fn tryCastRef(value: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!?ClassRefById(class_id) {
            return tryCastClassRef(class_id, value, global);
        }

        pub fn isDirectInstance(value: jsc.JSValue) bool {
            return tryCastNativeDirect(value) != null;
        }

        pub fn isInstance(value: jsc.JSValue) bool {
            return tryCastNative(value) != null;
        }

        pub fn toJS(handle: *Handle, global: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
            if (comptime !NormalizedClass.runtime_plan.ownership.isNativeShared()) {
                @compileError("unique class handles cannot be independently wrapped");
            }
            const native = handle.take();
            requireNativeGlobal(native, global);
            const state = classState(Impl, native);
            state.bindSharedOwner(.{ .native = native, .ops = sharedClassOps(class_id, Impl) });
            _ = state.ensureGeneration();
            return state.wrapShared(global);
        }

        pub fn toRef(handle: *Handle, context: anytype) bun.JSError!ClassRefById(class_id) {
            if (comptime !NormalizedClass.runtime_plan.ownership.isNativeShared()) {
                @compileError("unique class handles cannot be independently wrapped");
            }
            context.requireActive();
            const global = context.viewToken().globalObject();
            const wrapper = try toJS(handle, global);
            return (try tryCastRef(wrapper, global)) orelse
                @panic("newly wrapped binding class failed its own brand check");
        }

        /// Consumes the native ownership on both success and failure.
        pub fn adoptNative(native: *Impl, global: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
            if (comptime NormalizedClass.runtime_plan.ownership.isNativeShared()) {
                var handle = try Handle.adopt(native, global);
                return toJS(&handle, global);
            }
            if (comptime !NormalizedClass.runtime_plan.ownership.isNativeUnique()) {
                @compileError("adoptNative is available only for native classes");
            }
            const rare = global.bunVM().tryRareData() catch |err| {
                NativeLifetime.destroyUnbound(native);
                return err;
            };
            const finalizer_queue = rare.nativeFinalizerQueue();
            initializeClassState(class_id, Impl, native, finalizer_queue);
            return ClassWireAdapter(NormalizedClass).wrap(global, @ptrCast(native));
        }

        pub fn adoptNativeRef(native: *Impl, global: *jsc.JSGlobalObject) bun.JSError!ClassRefById(class_id) {
            return (try tryCastRef(try adoptNative(native, global), global)) orelse
                @panic("newly wrapped binding class failed its own brand check");
        }

        pub fn adoptResult(native: *Impl, context: anytype) bun.JSError!ClassRefById(class_id) {
            const Context = switch (@typeInfo(@TypeOf(context))) {
                .pointer => |pointer| pointer.child,
                else => @TypeOf(context),
            };
            if (!@hasDecl(Context, "bindgen_result_type")) {
                @compileError("class results require a binding result context");
            }
            if (comptime !Manifest.typeContainsClass(Context.bindgen_result_type, NormalizedClass)) {
                @compileError("binding result does not declare class " ++ NormalizedClass.module_name ++ "." ++ NormalizedClass.class_name ++
                    ": " ++ resultClassMismatchDescription(Context.bindgen_result_type, class_id));
            }
            context.requireActive();
            return adoptNativeRef(native, context.viewToken().globalObject());
        }

        pub fn adoptResultAs(comptime AncestorSchema: type, native: *Impl, context: anytype) bun.JSError!ClassRef(AncestorSchema) {
            const Ancestor = Manifest.ClassAt(Manifest.ClassId(AncestorSchema));
            if (comptime NormalizedClass.representation != .native or Ancestor.representation != .native or
                !Manifest.classIsOrInherits(NormalizedClass, Ancestor))
            {
                @compileError("native class results may only be projected to a declared ancestor");
            }
            const Context = switch (@typeInfo(@TypeOf(context))) {
                .pointer => |pointer| pointer.child,
                else => @TypeOf(context),
            };
            if (comptime !@hasDecl(Context, "bindgen_result_type") or
                !Manifest.typeContainsClass(Context.bindgen_result_type, Ancestor))
            {
                @compileError("binding result does not declare the requested ancestor class");
            }
            context.requireActive();
            var reference = try adoptNativeRef(native, context.viewToken().globalObject());
            defer reference.deinit();
            return reference.takeUpcast(AncestorSchema);
        }

        pub fn CachedSlot(comptime slot_name: []const u8) type {
            const Slot = findCachedSlot(slot_name);
            const ValueType = Slot.ValueType;
            const value_kind: ?ir.JSValueKind = switch (Slot.access) {
                .callback => null,
                .js_value => |kind| kind,
                .class_ref, .union_type, .storage_only => @compileError("cached-slot engine identity access requires any, engine_value, branded-value, or callback semantics"),
            };
            const IsCallback = Slot.access == .callback;
            const IsAny = value_kind == .any;
            const IsBranded = value_kind == .branded;
            const OwnedBranded = if (comptime IsBranded)
                OwnedBrandedValueType(ValueType)
            else
                void;
            const OwnedCallback = if (IsCallback) Callback(ValueType) else void;
            const View = if (value_kind) |kind| switch (kind) {
                .any => AnyView,
                .engine_value => EngineValueView,
                .branded => BrandedValueViewType(ValueType),
            } else CallbackView(ValueType);
            return struct {
                pub const SemanticType = ValueType;
                pub const OwnedValue = OwnedBranded;
                pub fn view(wrapper: ClassRefViewById(class_id)) bun.JSError!?View {
                    wrapper.wrapper.token.requireActive();
                    const cached = readJSValue(cachedSlotValueHandle(Slot, wrapper.wrapper.rawValue()));
                    if (cached == .zero) return null;
                    const global = wrapper.wrapper.engineGlobal();
                    return View.init(try retainCallScopedValue(cached, global, wrapper.wrapper.token), global, wrapper.wrapper.token);
                }

                pub fn setView(
                    wrapper: ClassRefViewById(class_id),
                    value: Api(Slot.assigned_position),
                ) void {
                    wrapper.wrapper.token.requireActive();
                    const global = wrapper.wrapper.engineGlobal();
                    value.token.requireSameCall(wrapper.wrapper.token, global, "binding cached slot and value belong to unrelated calls");
                    const raw_value = if (comptime IsCallback) value.get() else value.rawValue();
                    setCachedSlotValue(Slot, global, wrapper.wrapper.rawValue(), raw_value);
                }

                pub fn setOwnedCallbackOnOwned(
                    wrapper: *const ClassRefById(class_id),
                    value: if (IsCallback) *const OwnedCallback else void,
                ) void {
                    if (comptime !IsCallback) {
                        @compileError("only callback cached slots accept typed callbacks");
                    }
                    setCachedSlotRoot(Slot, wrapper.globalObject(), wrapper.root.get(), &value.root);
                }

                pub fn setCallbackViewOnOwned(
                    wrapper: *const ClassRefById(class_id),
                    comptime CallbackType: type,
                    value: CallbackView(CallbackType),
                ) void {
                    const NormalizedCallbackType = CallbackType;
                    if (comptime !IsAny and ValueType != NormalizedCallbackType) {
                        @compileError("typed callback does not match the cached slot's semantic type");
                    }
                    const global = wrapper.globalObject();
                    if (value.globalObject() != global) {
                        @panic("binding callback and cached-slot owner belong to different realms");
                    }
                    setCachedSlotValue(Slot, global, wrapper.root.get(), value.get());
                }

                pub const setEngineRootOnOwned = RootSetter(EngineRoot, .engine_value).set;
                pub const setRootOnOwned = RootSetter(Root, .any).set;
                pub const setOptionalRootOnOwned = RootSetter(Root.Optional, .any).set;

                fn RootSetter(comptime RootType: type, comptime kind: ir.JSValueKind) type {
                    return struct {
                        fn set(wrapper: *const ClassRefById(class_id), value: *const RootType) void {
                            if (comptime value_kind != kind) @compileError("root type does not match the cached slot's semantic type");
                            const global = wrapper.globalObject();
                            value.requireCurrentVM(global);
                            const raw = value.get();
                            setCachedSlotValue(Slot, global, wrapper.root.get(), if (RootType == Root.Optional) raw orelse .zero else raw);
                        }
                    };
                }

                pub fn rootFromOwned(wrapper: *const ClassRefById(class_id)) bun.JSError!?Root {
                    if (comptime !IsAny) {
                        @compileError("generic root retrieval requires an any cached slot");
                    }
                    const value = readJSValue(cachedSlotValueHandle(
                        Slot,
                        wrapper.root.get(),
                    ));
                    if (value == .zero) return null;
                    return try Root.create(value, wrapper.globalObject());
                }

                pub const ownedBranded = OwnedGetter(false).fromOwned;
                pub const ownedBrandedFromReference = OwnedGetter(false).fromReference;
                pub const ownedCallback = OwnedGetter(true).fromOwned;
                pub const ownedCallbackFromReference = OwnedGetter(true).fromReference;
                pub const ownedCallbackFromView = OwnedGetter(true).fromView;

                fn OwnedGetter(comptime callback: bool) type {
                    const Owner = if (callback) OwnedCallback else OwnedBranded;
                    return struct {
                        fn fromOwned(wrapper: *const ClassRefById(class_id)) bun.JSError!?Owner {
                            return read(wrapper.root.get(), wrapper.globalObject());
                        }

                        fn fromReference(reference: anytype) bun.JSError!?Owner {
                            const wrapper = (try referencedWrapper(reference)) orelse return null;
                            return read(wrapper, reference.globalObject());
                        }

                        fn fromView(wrapper: ClassRefViewById(class_id)) bun.JSError!?Owner {
                            wrapper.wrapper.token.requireActive();
                            return read(wrapper.wrapper.rawValue(), wrapper.wrapper.engineGlobal());
                        }

                        fn read(wrapper: jsc.JSValue, global: *jsc.JSGlobalObject) bun.JSError!?Owner {
                            if (comptime !(if (callback) IsCallback else IsBranded))
                                @compileError("owned cached-slot retrieval must match the slot's semantic type");
                            const value = readJSValue(cachedSlotValueHandle(Slot, wrapper));
                            if (value == .zero) return null;
                            const RootType = if (callback) CallbackRoot(ValueType) else BrandedRoot(ValueType);
                            return .{ .root = try RootType.create(value, global) };
                        }
                    };
                }

                pub fn setOwnedBrandedOnOwned(
                    wrapper: *const ClassRefById(class_id),
                    value: *const OwnedBranded,
                ) void {
                    setOwnedBrandedOn(wrapper.root.get(), wrapper.globalObject(), value);
                }

                pub fn setOwnedBrandedOnReference(reference: anytype, value: *const OwnedBranded) bun.JSError!void {
                    const wrapper = (try referencedWrapper(reference)) orelse @panic("binding wrapper reference is unavailable");
                    setOwnedBrandedOn(wrapper, reference.globalObject(), value);
                }

                fn setOwnedBrandedOn(wrapper: jsc.JSValue, global: *jsc.JSGlobalObject, value: *const OwnedBranded) void {
                    if (comptime !IsBranded) {
                        @compileError("only branded-value cached slots accept owned branded values");
                    }
                    setCachedSlotRoot(Slot, global, wrapper, &value.root);
                }

                pub fn setOwnedBranded(
                    wrapper: ClassRefViewById(class_id),
                    value: *const OwnedBranded,
                ) void {
                    wrapper.wrapper.token.requireActive();
                    setOwnedBrandedOn(wrapper.wrapper.rawValue(), wrapper.wrapper.engineGlobal(), value);
                }

                pub fn setViewOnOwned(
                    wrapper: *const ClassRefById(class_id),
                    value: Api(Slot.assigned_position),
                ) void {
                    const global = wrapper.globalObject();
                    wrapper.root.requireCurrentVM(value.token.globalObject());
                    const raw_value = if (comptime IsCallback) value.get() else value.rawValue();
                    setCachedSlotValue(Slot, global, wrapper.root.get(), raw_value);
                }

                pub fn isSetOwned(wrapper: *const ClassRefById(class_id)) bool {
                    return readJSValue(cachedSlotValueHandle(
                        Slot,
                        wrapper.root.get(),
                    )) != .zero;
                }

                pub fn isSetView(wrapper: ClassRefViewById(class_id)) bool {
                    wrapper.wrapper.token.requireActive();
                    return readJSValue(cachedSlotValueHandle(
                        Slot,
                        wrapper.wrapper.rawValue(),
                    )) != .zero;
                }

                pub const clearOwned = CachedSlotInvalidator(slot_name).clearOwned;

                pub fn clearOnReference(reference: anytype) bun.JSError!void {
                    const wrapper = (try referencedWrapper(reference)) orelse return;
                    setCachedSlotValue(Slot, reference.globalObject(), wrapper, .zero);
                }

                /// The wrapper a stored reference currently holds. Slot accesses run no JavaScript
                /// and the conservatively scanned stack keeps the wrapper alive, so it needs no root.
                fn referencedWrapper(reference: anytype) bun.JSError!?jsc.JSValue {
                    const Reference = @TypeOf(reference.*);
                    if (comptime Reference != WrapperReferenceByIds(Reference.wrapper_class_ids))
                        @compileError("cached-slot references require a bindgen.WrapperReference");
                    const wrapper = (try reference.rawValue()) orelse return null;
                    return if (tryCastClassNative(class_id, wrapper) != null) wrapper else null;
                }

                pub fn takeOwnedCallback(
                    wrapper: *const ClassRefById(class_id),
                ) bun.JSError!?OwnedCallback {
                    if (comptime !IsCallback) {
                        @compileError("only callback cached slots can produce typed callbacks");
                    }
                    const callback = (try ownedCallback(wrapper)) orelse return null;
                    clearOwned(wrapper);
                    return callback;
                }

                pub const clearView = CachedSlotInvalidator(slot_name).clearView;
            };
        }

        pub fn CachedSlotInvalidator(comptime slot_name: []const u8) type {
            const Slot = findCachedSlot(slot_name);
            const write = if (Slot.write) |operation| operation else @compileError("cached slot is read-only");
            return struct {
                pub fn clearWrapper(comptime kind: WrapperHandleKind, wrapper: *const ClassWrapperHandleById(class_id, kind)) void {
                    if (comptime kind == .strong) {
                        const global = wrapper.globalObject() orelse return;
                        setCachedSlotValue(Slot, global, wrapper.storage.get(), .zero);
                    } else {
                        const state = if (wrapper.storage.state) |*owned| owned else return;
                        @field(wire, write.clear_weak)(@ptrCast(state.reference.borrowWire()));
                    }
                }

                pub fn clearOwned(wrapper: *const ClassRefById(class_id)) void {
                    setCachedSlotValue(Slot, wrapper.globalObject(), wrapper.root.get(), .zero);
                }

                pub fn clearView(wrapper: ClassRefViewById(class_id)) void {
                    wrapper.wrapper.token.requireActive();
                    const global = wrapper.wrapper.engineGlobal();
                    setCachedSlotValue(Slot, global, wrapper.wrapper.rawValue(), .zero);
                }
            };
        }

        pub fn copyCachedSlot(
            comptime source_name: []const u8,
            comptime destination_name: []const u8,
            wrapper: ClassRefViewById(class_id),
        ) void {
            wrapper.wrapper.token.requireActive();
            copyCachedSlotValue(source_name, destination_name, wrapper.wrapper.rawValue(), wrapper.wrapper.engineGlobal());
        }

        pub fn copyCachedSlotOwned(
            comptime source_name: []const u8,
            comptime destination_name: []const u8,
            wrapper: *const ClassRefById(class_id),
        ) void {
            copyCachedSlotValue(source_name, destination_name, wrapper.root.get(), wrapper.globalObject());
        }

        fn copyCachedSlotValue(
            comptime source_name: []const u8,
            comptime destination_name: []const u8,
            wrapper: jsc.JSValue,
            global: *jsc.JSGlobalObject,
        ) void {
            const Source = findCachedSlot(source_name);
            const Destination = findCachedSlot(destination_name);
            if (Destination.write == null) @compileError("destination cached slot is read-only");
            if (comptime Source.ValueType != Destination.ValueType) {
                @compileError("cached-slot copies require the same semantic value type");
            }
            const value = readJSValue(cachedSlotValueHandle(Source, wrapper));
            setCachedSlotValue(Destination, global, wrapper, value);
        }

        pub fn CachedClassRefSlot(comptime slot_name: []const u8) type {
            const Slot = findCachedSlot(slot_name);
            switch (Slot.access) {
                .class_ref => {},
                .callback, .js_value, .union_type, .storage_only => @compileError("cached class-reference slot must contain a class reference"),
            }
            const ReferenceType = Slot.ValueType;
            return struct {
                pub fn getOwned(
                    wrapper: *const ClassRefById(class_id),
                ) bun.JSError!?ClassRef(ReferenceType.ReferencedClass) {
                    const value = readJSValue(cachedSlotValueHandle(
                        Slot,
                        wrapper.root.get(),
                    ));
                    if (value == .zero) return null;
                    if (comptime Slot.optional) {
                        var scope: FocusedEngineScope = undefined;
                        scope.init(wrapper.globalObject());
                        defer scope.deinit();
                        const operand = scope.borrowEngineValue(value);
                        const absent = switch (Slot.SlotType.optional_mode) {
                            .nullable => value.isNull(),
                            .nullish => value.isUndefinedOrNull(),
                            .undefined => value.isUndefined(),
                            .falsy => !operand.toBoolean(),
                            .matched => false,
                            .nullish_or_empty_string => value.isUndefinedOrNull() or (operand.isString() and !operand.toBoolean()),
                        };
                        if (absent) return null;
                    }
                    const reference = try tryCastClassRef(ReferenceType.ReferencedClass.id, value, wrapper.globalObject());
                    if (comptime Slot.optional and Slot.SlotType.optional_mode == .matched) return reference;
                    return reference orelse
                        @panic("cached class-reference slot contains a value with the wrong class");
                }

                pub fn setOnOwned(
                    wrapper: *const ClassRefById(class_id),
                    reference: *const ClassRef(ReferenceType.ReferencedClass),
                ) void {
                    setCachedSlotRoot(Slot, wrapper.globalObject(), wrapper.root.get(), &reference.root);
                }
            };
        }

        pub fn CachedUnionSlot(comptime slot_name: []const u8) type {
            const Slot = findCachedSlot(slot_name);
            switch (Slot.access) {
                .union_type => {},
                .callback, .js_value, .class_ref, .storage_only => @compileError("cached union-slot access requires a union slot"),
            }
            return struct {
                fn Member(comptime member_name: []const u8) type {
                    inline for (Slot.ValueType.union_members) |UnionMember| {
                        if (std.mem.eql(u8, UnionMember.member_name, member_name)) return UnionMember;
                    }
                    @compileError("cached union slot has no member named '" ++ member_name ++ "'");
                }

                pub fn setOwnedBrandedMemberOnOwned(
                    comptime member_name: []const u8,
                    wrapper: *const ClassRefById(class_id),
                    value: *const OwnedBrandedValueType(Member(member_name).MemberType),
                ) void {
                    setCachedSlotRoot(Slot, wrapper.globalObject(), wrapper.root.get(), &value.root);
                }
            };
        }

        fn findCachedSlot(comptime slot_name: []const u8) type {
            inline for (NormalizedClass.slots) |Slot| {
                if (std.mem.eql(u8, Slot.slot_name, slot_name)) return Slot;
            }
            @compileError("binding class has no cached slot named " ++ slot_name);
        }

        fn requireNativeGlobal(native: *Impl, global: *jsc.JSGlobalObject) void {
            const rare = global.bunVM().rare_data orelse
                @panic("bound class native has no finalizer queue");
            classState(Impl, native).requireFinalizerQueueForVM(rare.nativeFinalizerQueue());
        }

        const NativeLifetime = switch (NormalizedClass.runtime_plan.ownership) {
            .native_shared => struct {
                const destroyUnbound = Impl.deref;

                fn releaseOnVM(native: *Impl) void {
                    const owner = classState(Impl, native).sharedOwner();
                    if (owner.ops.release_deferred(owner.native)) owner.ops.destroy_deferred(owner.native);
                }

                fn finalize(native: *Impl) void {
                    const state = classState(Impl, native);
                    const owner = state.sharedOwner();
                    if (owner.ops.release_deferred(owner.native)) {
                        state.requireFinalizerQueue().enqueue(&state.finalizer_node.node, state, finalizeDeferredShared);
                    }
                }
            },
            .native_unique => if (NormalizedClass.runtime_plan.finalization.isInlineSweep()) struct {
                fn destroyUnbound(native: *Impl) void {
                    Impl.destroy(native, sweepContext());
                }

                const releaseOnVM = destroyUnbound;
                const finalize = destroyUnbound;
            } else struct {
                const destroyUnbound = Impl.destroy;
                const releaseOnVM = Impl.destroy;

                fn finalize(native: *Impl) void {
                    const state = classState(Impl, native);
                    state.requireFinalizerQueue().enqueue(&state.finalizer_node.node, native, Impl.destroy);
                }
            },
            .none, .engine => void,
        };

        fn destroyPendingNative(native_handle: ?*wire.BindNativeHandle) callconv(.c) void {
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse @panic("pending native instance is null")));
            _ = classState(Impl, native).requireFinalizerQueue();
            NativeLifetime.destroyUnbound(native);
        }

        fn releaseNativeOnVM(
            vm_handle: ?*wire.BindVirtualMachineHandle,
            native_handle: ?*wire.BindNativeHandle,
        ) callconv(.c) void {
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("class native release received null")));
            const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(vm_handle orelse
                @panic("class native release received null VM")));
            if (jsc.VirtualMachine.get() != vm) @panic("class native release ran outside its VM thread");
            const queue = (vm.rare_data orelse
                @panic("class native release has no finalizer queue")).nativeFinalizerQueue();
            classState(Impl, native).requireFinalizerQueueForVM(queue);
            NativeLifetime.releaseOnVM(native);
        }

        fn destroyNative(
            vm_handle: ?*wire.BindVirtualMachineHandle,
            native_handle: ?*wire.BindNativeHandle,
        ) callconv(.c) void {
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("class native destructor received null")));
            const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(vm_handle orelse
                @panic("class destructor received null VM")));
            const queue = (vm.rare_data orelse
                @panic("class native destructor has no finalizer queue")).nativeFinalizerQueue();
            const state = classState(Impl, native);
            state.requireFinalizerQueueForVM(queue);
            NativeLifetime.finalize(native);
        }

        fn initializeExternalNative(
            global_handle: ?*wire.BindGlobalObjectHandle,
            native_handle: ?*wire.BindNativeHandle,
        ) callconv(.c) wire.BindStatus {
            const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(global_handle orelse
                @panic("external class native initializer received null global object")));
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("external class native initializer received null native pointer")));
            const rare = global.bunVM().tryRareData() catch {
                NativeLifetime.destroyUnbound(native);
                return checkedStatus(global, .out_of_memory);
            };
            const finalizer_queue = rare.nativeFinalizerQueue();
            initializeClassState(class_id, Impl, native, finalizer_queue);
            const status = checkedStatus(global, .ok);
            if (status != @backingInt(Status.ok)) NativeLifetime.destroyUnbound(native);
            return status;
        }

        fn nativeGeneration(native_handle: ?*wire.BindNativeHandle) callconv(.c) u64 {
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("class generation lookup received null")));
            return classState(Impl, native).getGeneration();
        }

        fn nativeTypeIdentity() callconv(.c) void {}

        fn memoryUsageAnyThread(native_handle: ?*wire.BindNativeHandle) callconv(.c) usize {
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("class memoryUsage received null native pointer")));
            return Impl.memoryUsage(native, .{ .identity = {} });
        }

        fn memoryUsageVM(
            vm_handle: ?*wire.BindVirtualMachineHandle,
            native_handle: ?*wire.BindNativeHandle,
        ) callconv(.c) usize {
            const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(vm_handle orelse
                @panic("class memoryUsage received null VM")));
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("class memoryUsage received null native pointer")));
            return Impl.memoryUsage(native, .{ .identity = .{ .handle = @ptrCast(vm) } });
        }

        fn hasPendingActivityNative(native_handle: ?*wire.BindNativeHandle) callconv(.c) u8 {
            const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                @panic("class hasPendingActivity received null native pointer")));
            return @intFromBool(Impl.hasPendingActivity(native));
        }

        const WrapperCreation = if (NormalizedClass.runtime_plan.construction.wrapper_created != null) struct {
            fn dispatch(
                wire_context: ?*wire.BindCallContext,
                wire_wrapper: ?*const wire.BindClassRefView,
            ) callconv(.c) wire.BindStatus {
                const context = wire_context orelse @panic("class wrapper creation received null context");
                const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(context.global_object orelse
                    @panic("class wrapper creation received null global object")));
                const native: *Impl = @ptrCast(@alignCast(context.native_receiver orelse
                    @panic("class wrapper creation received null native pointer")));
                const wrapper = wire_wrapper orelse @panic("class wrapper creation received null wrapper");
                if (wrapper.native != context.native_receiver) @panic("class wrapper creation received mismatched native pointers");
                if (wrapper.wrapper == null) @panic("class wrapper creation received null wrapper value");
                if (context.call_id == 0) @panic("class wrapper creation received call ID zero");
                var entry: EntryScope = undefined;
                entry.init(context, global);
                defer entry.deinit();
                const token = entry.active.token();
                const view = ClassRefViewById(class_id).init(wrapper.*, global, token);
                Impl.wrapperCreated(native, view) catch |err|
                    return entry.failure(err);
                return entry.status(.ok);
            }
        } else void;

        const StructuredClone = if (NormalizedClass.structured_clone) |clone_plan| switch (clone_plan.serialization) {
            .shared => |shared_plan| struct {
                const SharedCloneState = @field(Impl, shared_plan.state);
                const SharedCloneHandle = wireType(shared_plan.handle);

                fn serialize(
                    wire_context: ?*wire.BindCallContext,
                    native_handle: ?*wire.BindNativeHandle,
                    out_shared: *?*SharedCloneHandle,
                ) callconv(.c) wire.BindStatus {
                    out_shared.* = null;
                    const context = wire_context orelse @panic("shared clone capture received null context");
                    const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(context.global_object orelse
                        @panic("shared clone capture received null global")));
                    const native: *const Impl = @ptrCast(@alignCast(native_handle orelse
                        @panic("shared clone capture received null native")));
                    var entry: EntryScope = undefined;
                    entry.init(context, global);
                    defer entry.deinit();
                    var shared = Impl.structuredCloneShare(native, StructuredCloneContextById(class_id).init(global, entry.active.token())) catch |err|
                        return entry.failure(err);
                    const status = entry.status(.ok);
                    if (status != @backingInt(Status.ok)) {
                        shared.deinit();
                        return status;
                    }
                    out_shared.* = @ptrCast(shared.take());
                    return status;
                }

                fn release(shared_handle: ?*SharedCloneHandle) callconv(.c) void {
                    const shared: *SharedCloneState = @ptrCast(@alignCast(shared_handle orelse
                        @panic("shared clone release received null state")));
                    SharedCloneState.deref(shared);
                }

                fn deserialize(
                    wire_context: ?*wire.BindCallContext,
                    shared_handle: ?*SharedCloneHandle,
                    out_native: *?*wire.BindNativeHandle,
                ) callconv(.c) wire.BindStatus {
                    out_native.* = null;
                    const context = wire_context orelse @panic("shared clone restore received null context");
                    const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(context.global_object orelse
                        @panic("shared clone restore received null global")));
                    const shared: *SharedCloneState = @ptrCast(@alignCast(shared_handle orelse
                        @panic("shared clone restore received null state")));
                    var entry: EntryScope = undefined;
                    entry.init(context, global);
                    defer entry.deinit();
                    const rare = global.bunVM().tryRareData() catch return entry.status(.out_of_memory);
                    const native = Impl.structuredCloneFromShared(
                        StructuredCloneContextById(class_id).init(global, entry.active.token()),
                        BorrowedNative(SharedCloneState, .any).init(shared),
                    ) catch |err| return entry.failure(err);
                    initializeStructuredCloneClassState(class_id, Impl, native, rare.nativeFinalizerQueue());
                    const status = entry.status(.ok);
                    if (status != @backingInt(Status.ok)) {
                        destroyNative(@ptrCast(global.bunVM()), @ptrCast(native));
                        return status;
                    }
                    out_native.* = @ptrCast(native);
                    return status;
                }
            },
            .bytes => |serialize_thread| struct {
                fn serialize(
                    wire_context: ?*wire.BindCallContext,
                    native_handle: ?*wire.BindNativeHandle,
                    serializer_handle: ?*wire.BindCloneSerializerHandle,
                ) callconv(.c) wire.BindStatus {
                    const context_ptr = wire_context orelse @panic("structured clone serialize received null context");
                    const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(context_ptr.global_object orelse
                        @panic("structured clone serialize received null global object")));
                    const native: *const Impl = @ptrCast(@alignCast(native_handle orelse
                        @panic("structured clone serialize received null native pointer")));
                    const serializer = serializer_handle orelse @panic("structured clone serialize received null writer");
                    if (context_ptr.call_id == 0) @panic("structured clone serialize received call ID zero");
                    var entry: EntryScope = undefined;
                    entry.init(context_ptr, global);
                    defer entry.deinit();
                    const token = entry.active.token();
                    const writer: StructuredCloneWriter = .{ .serializer = serializer, .token = token };
                    const result: bun.JSError!void = switch (comptime serialize_thread) {
                        .any => Impl.structuredCloneSerialize(native, writer),
                        .vm => Impl.structuredCloneSerialize(native, StructuredCloneContextById(class_id).init(global, token), writer),
                    };
                    result catch |err| return entry.failure(err);
                    return entry.status(.ok);
                }

                fn deserialize(
                    wire_context: ?*wire.BindCallContext,
                    wire_reader: ?*wire.BindCloneReader,
                    out_native: *?*wire.BindNativeHandle,
                ) callconv(.c) wire.BindStatus {
                    out_native.* = null;
                    const context_ptr = wire_context orelse @panic("structured clone deserialize received null context");
                    const global: *jsc.JSGlobalObject = @ptrCast(@alignCast(context_ptr.global_object orelse
                        @panic("structured clone deserialize received null global object")));
                    const reader_ptr = wire_reader orelse @panic("structured clone deserialize received null reader");
                    if (reader_ptr.ptr == null or reader_ptr.end == null) @panic("structured clone deserialize received null bounds");
                    if (context_ptr.call_id == 0) @panic("structured clone deserialize received call ID zero");
                    var entry: EntryScope = undefined;
                    entry.init(context_ptr, global);
                    defer entry.deinit();
                    const token = entry.active.token();
                    var reader: StructuredCloneReader = .{
                        .ptr = @ptrCast(reader_ptr.ptr),
                        .end = @ptrCast(reader_ptr.end),
                        .token = token,
                    };
                    _ = reader.remaining();
                    const context = StructuredCloneContextById(class_id).init(global, token);
                    const rare = global.bunVM().tryRareData() catch
                        return entry.status(.out_of_memory);
                    const finalizer_queue = rare.nativeFinalizerQueue();
                    const native = Impl.structuredCloneDeserialize(context, &reader) catch |err| {
                        return switch (err) {
                            error.InvalidData => entry.status(.failed),
                            else => |exception| entry.failure(exception),
                        };
                    };
                    initializeStructuredCloneClassState(class_id, Impl, native, finalizer_queue);
                    const status = entry.status(.ok);
                    if (status != @backingInt(Status.ok)) {
                        destroyNative(@ptrCast(global.bunVM()), @ptrCast(native));
                        return status;
                    }
                    reader_ptr.ptr = @ptrCast(reader.ptr);
                    out_native.* = @ptrCast(native);
                    return status;
                }
            },
        } else void;

        const Inheritance = if (NormalizedClass.upcast) |upcast_plan| struct {
            fn upcast(native_handle: ?*wire.BindNativeHandle) callconv(.c) ?*wire.BindNativeHandle {
                const ParentImpl = Impl.Parent;
                const verify_parent_native_type = @extern(
                    *const fn () callconv(.c) void,
                    .{ .name = classNativeTypeSymbol(NormalizedClass.Parent, ParentImpl) },
                );
                verify_parent_native_type.*();
                const native: *Impl = @ptrCast(@alignCast(native_handle orelse
                    @panic("class upcast received null native pointer")));
                const parent = @field(Impl, upcast_plan.implementation)(native);
                if (comptime NormalizedClass.runtime_plan.ownership.isNativeShared()) {
                    if (classState(Impl, native) != classState(ParentImpl, parent)) {
                        @panic("shared class upcast returned native state with a different ownership identity");
                    }
                }
                return @ptrCast(parent);
            }
        } else void;

        comptime {
            @setEvalBranchQuota(10_000_000);
            validateClassBinding(class_id, Impl);
            if (NormalizedClass.Constructor.exposed and !NormalizedClass.Constructor.is_illegal and NormalizedClass.representation == .native) {
                _ = CallableBinding(NormalizedClass.Constructor.id, ClassMemberAdapter(NormalizedClass.Constructor.id, Impl).invoke);
            }
            if (NormalizedClass.callable) {
                const ConstructorCall = NormalizedClass.ConstructorCall;
                if (ConstructorCall.backend == .zig) {
                    _ = CallableBinding(ConstructorCall.id, ClassMemberAdapter(ConstructorCall.id, Impl).invoke);
                }
            }
            for (NormalizedClass.declarations) |Member| {
                if (Member.backend == .zig) {
                    _ = CallableBinding(Member.id, ClassMemberAdapter(Member.id, Impl).invoke);
                }
            }
            if (NormalizedClass.representation == .native) {
                @export(&destroyNative, .{ .name = NormalizedClass.destroy_native_symbol });
                @export(&destroyPendingNative, .{ .name = NormalizedClass.destroy_pending_native_symbol });
                @export(&releaseNativeOnVM, .{ .name = NormalizedClass.release_native_on_vm_symbol });
                if (NormalizedClass.runtime_plan.construction.initialize_external_native) |symbol| {
                    @export(&initializeExternalNative, .{ .name = symbol });
                }
                @export(&nativeTypeIdentity, .{ .name = classNativeTypeSymbol(NormalizedClass, Impl) });
                if (NormalizedClass.runtime_plan.native_generation) |symbol| {
                    @export(&nativeGeneration, .{ .name = symbol });
                }
                if (NormalizedClass.upcast) |upcast| {
                    @export(&Inheritance.upcast, .{ .name = upcast.symbol });
                }
                if (NormalizedClass.memory_usage) |memory| {
                    @export(
                        if (memory.affinity == .any) &memoryUsageAnyThread else &memoryUsageVM,
                        .{ .name = memory.symbol },
                    );
                }
                if (NormalizedClass.pending_activity) |symbol| {
                    @export(&hasPendingActivityNative, .{ .name = symbol });
                }
                if (NormalizedClass.runtime_plan.construction.wrapper_created) |symbol| {
                    @export(&WrapperCreation.dispatch, .{ .name = symbol });
                }
                if (NormalizedClass.structured_clone) |clone_plan| {
                    @export(&StructuredClone.serialize, .{ .name = clone_plan.serialize_symbol });
                    @export(&StructuredClone.deserialize, .{ .name = clone_plan.deserialize_symbol });
                    switch (clone_plan.serialization) {
                        .shared => |shared_plan| @export(&StructuredClone.release, .{ .name = shared_plan.release_symbol }),
                        .bytes => {},
                    }
                }
            }
        }
    };
    return Result_;
}

fn validateClassMemberImplementation(comptime function_id: usize, comptime Impl: type) void {
    const Function = FunctionMetadata(function_id, null);
    if (Function.backend != .zig) @compileError("only Zig class members have comptime implementations");
    const implementation_name = Function.implementation;
    if (!@hasDecl(Impl, implementation_name)) {
        @compileError(std.fmt.comptimePrint(
            "class implementation '{s}' is missing {s}",
            .{ @typeName(Impl), implementation_name },
        ));
    }
    const Result = if (Function.is_async)
        void
    else if (Function.member_kind == .constructor)
        *Impl
    else
        Api(Function.result_position);
    const ImplementationArgs = if (Function.is_overloaded) OverloadArgsType(Function) else ArgsType(Function);
    const Expected = switch (Function.member_kind) {
        .constructor, .static_method, .static_getter, .static_setter => fn (FunctionCallContext(function_id), ImplementationArgs) FunctionCallError(Function)!Result,
        .method, .getter, .setter => fn (*Impl, FunctionCallContext(function_id), ImplementationArgs) FunctionCallError(Function)!Result,
    };
    const Actual = @TypeOf(@field(Impl, implementation_name));
    if (Actual != Expected) {
        @compileError(std.fmt.comptimePrint(
            "class implementation '{s}.{s}' has an incompatible signature\nexpected: {s}\nactual:   {s}",
            .{ @typeName(Impl), implementation_name, @typeName(Expected), @typeName(Actual) },
        ));
    }
}

fn ClassMemberAdapter(comptime function_id: usize, comptime Impl: type) type {
    const Function = FunctionMetadata(function_id, null);
    const result_api = Manifest.get(Manifest.get(Function.result_position).api);
    return struct {
        fn invoke(
            context: FunctionCallContext(function_id),
            args: if (Function.is_overloaded) OverloadArgsType(Function) else ArgsType(Function),
        ) FunctionCallError(Function)!(if (Function.is_async) void else Api(Function.result_position)) {
            const implementation = @field(Impl, Function.implementation);
            if (comptime Function.call_plan.receiver != null) {
                const native: *Impl = @ptrCast(@alignCast(context.state().native_receiver orelse
                    @panic("instance binding context has no native receiver")));
                return @call(.auto, implementation, .{ native, context, args });
            }
            if (comptime result_api.representation == .native) {
                const class = result_api.representation.native;
                const finalizer_queue = (try context.globalObject().bunVM().tryRareData()).nativeFinalizerQueue();
                const native = try @call(.auto, implementation, .{ context, args });
                initializeClassState(class.index, Impl, native, finalizer_queue);
                return @ptrCast(native);
            }
            return @call(.auto, implementation, .{ context, args });
        }
    };
}

fn ArgsType(comptime Function: type) type {
    const arguments = Function.invocation_args ++ Function.args;
    var names: [arguments.len][]const u8 = undefined;
    var types: [arguments.len]type = undefined;
    inline for (arguments, 0..) |Argument, index| {
        names[index] = Argument.argument_name;
        const Child = Api(Argument.value_position);
        types[index] = if (Argument.optional) ?Child else Child;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn LazyRestViewType(comptime lazy: ir.ApiType.LazyRest) type {
    const Function = DeferredOwner(lazy.deferred.call);
    const Element = LazyArgumentViewType(true, lazy);
    const Result_ = struct {
        handle: ?*const wire.BindJSValueSliceHandle,
        length: usize,
        token: ViewToken,

        const Self = @This();
        const ConvertedValue = Element.ConvertedValue;
        pub const Forced = Element.Forced;

        fn init(
            value: wire.BindJSValueSlice,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            if (value.len == 0) {
                if (value.handle != null) @panic("binding lazy rest view is not in canonical empty form");
            } else if (value.handle == null) {
                @panic("binding lazy rest view has a null handle");
            }
            if (token.globalObject() != global) @panic("binding lazy rest view has the wrong call realm");
            return .{ .handle = value.handle, .length = value.len, .token = token };
        }

        pub fn len(view: Self) usize {
            view.token.requireActive();
            return view.length;
        }

        pub fn convert(
            view: Self,
            element_index: usize,
            context: Function.Context,
        ) bun.JSError!ConvertedValue {
            return view.element(element_index).convert(context);
        }

        pub fn convertLast(
            view: Self,
            element_index: usize,
            context: Function.Context,
        ) bun.JSError!Forced {
            return view.element(element_index).convertLast(context);
        }

        pub fn discard(view: Self, element_index: usize, context: Function.Context) bun.JSError!void {
            return view.element(element_index).discard(context);
        }

        pub fn discardLast(view: Self, element_index: usize, context: Function.Context) bun.JSError!DeferredLeaseProof {
            return view.element(element_index).discardLast(context);
        }

        fn element(view: Self, element_index: usize) Element {
            view.token.requireActive();
            if (element_index >= view.length) @panic("binding lazy rest index is out of bounds");
            return .{
                .handle = view.handle.?,
                .element_index = element_index,
                .token = view.token,
            };
        }
    };
    return Result_;
}

fn DeferredValue(comptime Value: type) type {
    const Result_ = struct {
        value: Value,
    };
    return Result_;
}

fn LazyArgumentViewType(comptime is_rest: bool, comptime lazy: if (is_rest) ir.ApiType.LazyRest else ir.ApiType.LazyView) type {
    const deferred = lazy.deferred;
    const Function = DeferredOwner(deferred.call);
    const index = deferred.call.argument_index;
    const Argument = Function.args[index];
    const child_position = deferred.value;
    const Result_ = struct {
        handle: if (is_rest) *const wire.BindJSValueSliceHandle else *Api(lazy.forward).Handle,
        element_index: if (is_rest) usize else void,
        token: ViewToken,

        const Self = @This();

        pub const bindgen_lazy_view = {};
        pub const SemanticType = Argument.ArgumentType;
        const ConvertedValue = DeferredValue(Api(child_position));
        pub const Forced = struct {
            converted: ConvertedValue,
            proof: DeferredLeaseProof,
        };

        fn init(
            handle: ?*wire.BindLazyArgumentHandle,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) Self {
            if (token.globalObject() != global) @panic("binding lazy value has the wrong call realm");
            return .{
                .handle = @ptrCast(handle orelse @panic("binding lazy value has a null handle")),
                .element_index = {},
                .token = token,
            };
        }

        pub fn operand(view: Self, context: anytype) Api(lazy.forward) {
            const token = context.viewToken();
            return .init(view.borrowWireForEngine(context.viewToken().globalObject(), token), token.globalObject(), token);
        }

        pub fn convert(
            view: Self,
            context: Function.Context,
        ) bun.JSError!ConvertedValue {
            const result = try view.convertImpl(context, false);
            if (result.proof != null) @panic("non-final lazy conversion returned a lease proof");
            return result.converted;
        }

        pub fn convertLast(
            view: Self,
            context: Function.Context,
        ) bun.JSError!Forced {
            if (comptime !(Function.call_plan.has_lazy_conversion and Function.call_plan.acquires_byte_lease)) {
                @compileError("convertLast is only available to calls with deferred byte leases");
            }
            const result = try view.convertImpl(context, true);
            return .{
                .converted = result.converted,
                .proof = DeferredLeaseProof.init(result.proof, view.token),
            };
        }

        pub fn discard(view: Self, context: Function.Context) bun.JSError!void {
            if (try view.discardImpl(context, false) != null) @panic("non-final deferred discard returned a lease proof");
        }

        pub fn discardLast(view: Self, context: Function.Context) bun.JSError!DeferredLeaseProof {
            return (try view.discardImpl(context, true)) orelse @panic("final deferred discard did not yield a lease proof");
        }

        fn discardImpl(view: Self, context: Function.Context, last: bool) bun.JSError!?DeferredLeaseProof {
            if (comptime !Function.call_plan.acquires_byte_lease) {
                @compileError("discard resolves an unobserved lazy operand before acquiring deferred leases");
            }
            const global = view.engineGlobal();
            view.token.requireSameCall(context.viewToken(), global, "lazy value discarded with an unrelated call context");
            var proof: ?*wire.BindDeferredConversionsHandle = null;
            const source = if (is_rest)
                .{ wire.bun_bindgen_js_value_slice_at(view.handle, view.element_index), view.element_index }
            else
                .{@as(*wire.BindLazyArgumentHandle, @ptrCast(view.handle))};
            const raw_status = @call(.auto, @field(wire, std.fmt.comptimePrint(ir.symbol_formats.lazy_discard, .{lazy.symbol})), .{
                @as(*wire.BindGlobalObjectHandle, @ptrCast(global)),
                view.token.call.lazy_storage orelse @panic("lazy discard has no entry-frame storage"),
                view.token.call.deferred_conversions orelse @panic("lazy discard has no deferred lease set"),
                @as(u8, @intFromBool(last)),
            } ++ source ++ .{&proof});
            try requireCheckedSuccess(global, raw_status);
            return if (proof) |handle| DeferredLeaseProof.init(handle, view.token) else null;
        }

        fn convertImpl(
            view: Self,
            context: Function.Context,
            last: bool,
        ) bun.JSError!struct { converted: ConvertedValue, proof: ?*wire.BindDeferredConversionsHandle } {
            const global = view.engineGlobal();
            view.token.requireSameCall(context.viewToken(), global, "binding lazy value converted with the wrong call context");
            const WireResult = wireType(lazy.result_wire);
            var result: WireResult = std.mem.zeroes(WireResult);
            var proof: ?*wire.BindDeferredConversionsHandle = null;
            const source = if (is_rest)
                .{ wire.bun_bindgen_js_value_slice_at(view.handle, view.element_index), view.element_index }
            else
                .{@as(*wire.BindLazyArgumentHandle, @ptrCast(view.handle))};
            const raw_status = @call(.auto, @field(wire, std.fmt.comptimePrint(ir.symbol_formats.lazy_convert, .{lazy.symbol})), .{
                @as(*wire.BindGlobalObjectHandle, @ptrCast(global)),
                view.token.call.lazy_storage orelse @panic("lazy conversion has no entry-frame storage"),
                view.token.call.deferred_conversions,
                @as(u8, @intFromBool(last)),
            } ++ source ++ .{ &proof, &result });
            try requireCheckedSuccess(global, raw_status);
            return .{
                .converted = .{ .value = try decode(child_position).wire(result.value, .{ .global = global, .token = view.token }) },
                .proof = proof,
            };
        }

        pub fn validate(
            view: Self,
            context: Function.Context,
        ) bun.JSError!void {
            _ = try view.convert(context);
        }

        fn borrowWireForEngine(
            view: Self,
            global: *jsc.JSGlobalObject,
            token: ViewToken,
        ) *wire.BindLazyArgumentHandle {
            view.token.requireSameCall(token, global, "binding lazy value used by an unrelated engine operation");
            return @ptrCast(view.handle);
        }

        fn engineGlobal(view: Self) *jsc.JSGlobalObject {
            return view.token.globalObject();
        }
    };
    return Result_;
}

fn OverloadArgsType(comptime Function: type) type {
    var names: [Function.overload_cases.len][]const u8 = undefined;
    var values: [Function.overload_cases.len]u8 = undefined;
    var types: [Function.overload_cases.len]type = undefined;
    inline for (Function.overload_cases, 0..) |Case, index| {
        names[index] = Case.case_name;
        values[index] = index;
        types[index] = ArgsType(Function.OverloadAt(index));
    }
    const Tag = @Enum(u8, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &types, &@splat(.{}));
}

fn OutboundArgsType(comptime Declaration: type) type {
    const count = Declaration.args.len + @intFromBool(Declaration.call_plan.receiver != null);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    inline for (Declaration.args, 0..) |Argument, index| {
        names[index] = Argument.argument_name;
        types[index] = Api(Argument.value_position);
    }
    if (Declaration.call_plan.receiver) |id| {
        names[Declaration.args.len] = "bindingThis";
        types[Declaration.args.len] = Api(id);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn decodeWirePresence(present: u8) bool {
    return switch (present) {
        0 => false,
        1 => true,
        else => @panic("binding value has an invalid presence byte"),
    };
}

fn destroyArguments(
    comptime Declaration: type,
    args: if (@TypeOf(Declaration.result_position).role == .inbound_result) *ArgsType(Declaration) else *OutboundArgsType(Declaration),
) void {
    if (comptime !Declaration.call_plan.transfers_argument_ownership) return;
    inline for (Declaration.args) |Argument| {
        const position = comptime Argument.value_position;
        if (Manifest.get(position).transfer) {
            destroy(position).api(&@field(args.*, Argument.argument_name));
        }
    }
}

fn SemanticUnionApiType(comptime Type: type, comptime types: [Type.union_members.len]type) type {
    var names: [Type.union_members.len][]const u8 = undefined;
    var values: [Type.union_members.len]u8 = undefined;
    inline for (Type.union_members, 0..) |Member, index| {
        names[index] = Member.member_name;
        values[index] = index + 1;
    }
    const Tag = @Enum(u8, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &types, &@splat(.{}));
}

fn encodeOutboundArgs(
    comptime Declaration: type,
    args: *const OutboundArgsType(Declaration),
    callee: if (Declaration.call_plan.callee) |id| Api(id) else void,
    context: anytype,
) bun.OOM!wireType(Declaration.wire_args) {
    if (Declaration.args.len == 0 and Declaration.call_plan.callee == null and Declaration.call_plan.receiver == null) return .{ ._reserved = 0 };
    var result: wireType(Declaration.wire_args) = undefined;
    if (Declaration.call_plan.callee) |id| result.bindingCallee = try encode(id).wire(&callee, context);
    if (Declaration.call_plan.receiver) |id| result.bindingThis = try encode(id).wire(&args.bindingThis, context);
    inline for (Declaration.args) |Argument| {
        @field(result, Argument.argument_name) = try encode(Argument.value_position).wire(&@field(args.*, Argument.argument_name), context);
    }
    return result;
}

fn outboundArgumentPosition(comptime Declaration: type, comptime name: []const u8) ir.OutboundArgumentPlanId {
    if (std.mem.eql(u8, name, "bindingThis")) return Declaration.call_plan.receiver orelse @compileError("binding call has no receiver");
    for (Declaration.args) |Argument| {
        if (std.mem.eql(u8, Argument.argument_name, name)) return Argument.value_position;
    }
    @compileError("binding call has no argument named '" ++ name ++ "'");
}

fn ForwardedArgument(comptime Declaration: type, comptime name: []const u8) type {
    const position = outboundArgumentPosition(Declaration, name);
    return if (Manifest.get(position).zig.encode_allocates) bun.OOM!Api(position) else Api(position);
}

/// Borrows `source`, a view, owned value, or slice shaped like the argument, as the operand the
/// call declares for `name`. Arrays the operand needs live until the token's call scope ends.
fn forwardArgument(comptime Declaration: type, comptime name: []const u8, token: ViewToken, source: anytype) ForwardedArgument(Declaration, name) {
    token.requireActive();
    const position = comptime outboundArgumentPosition(Declaration, name);
    const context: OperandContext = .{ .token = token };
    if (comptime Manifest.get(position).zig.encode_allocates) return forwardOperand(Manifest.get(position).api, bun.OOM, &context, source);
    return forwardOperand(Manifest.get(position).api, error{}, &context, source) catch |err| switch (err) {};
}

fn forwardOperand(comptime api: ir.ApiTypeId, comptime E: type, context: *const OperandContext, source: anytype) E!Api(api) {
    const Dest = Api(api);
    const description = comptime Manifest.binding().api_types[api.index];
    const Type = Manifest.SemanticType(description.type);
    return switch (description.representation) {
        .optional => |child| if (@typeInfo(@TypeOf(source)) != .optional)
            try forwardOperand(child, E, context, source)
        else if (source) |present|
            try forwardOperand(child, E, context, present)
        else
            null,
        .dictionary => |dictionary| fields: {
            var result: Dest = undefined;
            inline for (Type.dictionary_fields, dictionary.fields) |Field, child| {
                const value = @field(source, Field.field_name);
                @field(result, Field.field_name) = if (Field.storage != .optional)
                    try forwardOperand(child, E, context, value)
                else if (value) |present|
                    try forwardOperand(child, E, context, present)
                else
                    null;
            }
            break :fields result;
        },
        .union_type => |members| switch (source) {
            inline else => |payload, tag| member: {
                const member_index = comptime for (Type.union_members, 0..) |Member, index| {
                    if (std.mem.eql(u8, Member.member_name, @tagName(tag))) break index;
                } else unreachable;
                break :member @unionInit(Dest, @tagName(tag), try forwardOperand(members[member_index], E, context, payload));
            },
        },
        inline .sequence, .record => |collection| try forwardSlice(collection.slice.element, E, context, source),
        .rest => |rest| try forwardSlice(rest.slice.element, E, context, source),
        .record_entry => |entry| .{
            .key = try forwardOperand(entry.key, E, context, source.key),
            .value = try forwardOperand(entry.value, E, context, source.value),
        },
        .scalar, .enumeration, .native_slice, .nominal_borrow, .nominal_owner_borrow => source,
        .string_operand, .bytes_operand => source.operand(),
        .js_value_operand => operand: {
            const value = source.operand(context);
            break :operand if (@TypeOf(value) == Dest) value else value.asAny();
        },
        .callback_view, .class_view, .lazy_operand => source.operand(context),
        .void, .js_value_view, .js_value_result, .string_view, .string_owned, .utf8_owned, .bytes_view, .bytes_owned, .native_slice_view, .byte_lease, .lease_owned, .callback_owned, .class_owned, .external_view, .external_owned, .nominal_owned, .native, .lazy_view, .lazy_rest, .lazy_field => @compileError("binding arguments with this representation cannot be forwarded"),
    };
}

fn forwardSlice(comptime element: ir.ApiTypeId, comptime E: type, context: *const OperandContext, source: anytype) E![]const Api(element) {
    const indexed = comptime @typeInfo(@TypeOf(source)) == .pointer;
    const items = try callScopedSlice(Api(element), context.token, if (indexed) source.len else source.len());
    for (items, 0..) |*item, index| item.* = try forwardOperand(element, E, context, if (indexed) source[index] else source.at(index).?);
    return items;
}

fn callScopedSlice(comptime T: type, token: ViewToken, len: usize) bun.OOM![]T {
    token.requireActive();
    const items = try bun.default_allocator.alloc(T, len);
    if (len == 0) return items;
    const Owner = struct {
        items: []T,

        fn deinit(owner: *@This()) void {
            bun.default_allocator.free(owner.items);
        }
    };
    return (try adoptCallScopedOwner(Owner{ .items = items }, token)).items;
}

fn encode(comptime id: anytype) type {
    if (@TypeOf(id).role != .inbound_result and @TypeOf(id).role != .outbound_argument)
        @compileError("this role does not encode Zig values");
    const position = Manifest.get(id);
    const Shape = @TypeOf(position.representation);
    const Wire = wireType(position.wire);
    const EncodeError = if (position.zig.encode_allocates) bun.OOM else error{};
    return struct {
        fn wire(value: *const Api(id), context: anytype) EncodeError!Wire {
            return switch (position.representation) {
                .converted => |conversion| try encode(conversion.apiValue()).wire(value, context),
                .optional => |child| try optional(child, value, context),
                .dictionary => |fields_id| try dictionary(fields_id, value, context),
                .union_type => |members_id| try unionValue(members_id, value, context),
                .record_entry => |entry| try recordEntry(entry, value, context),
                .leaf => if (@TypeOf(id).role == .inbound_result) switch (position.zig.leaf.?.encode) {
                    .void => {},
                    .scalar => |kind| scalar(kind, value),
                    .enumeration => @backingInt(value.*),
                    .value_result => resultValue(value),
                    .take_wire => transfer: {
                        var owned = value.*;
                        break :transfer owned.takeWire();
                    },
                    .nominal_handle => nominalHandleToWire(Manifest.SemanticType(position.type), value.*),
                    .pointer => @ptrCast(value.*),
                } else switch (position.zig.leaf.?.encode) {
                    .scalar => |kind| scalar(kind, value),
                    .enumeration => @backingInt(value.*),
                    .value_operand, .value_result => value.encodedForEngine(context.global, context.token),
                    .scoped_handle => value.borrowWireForEngine(context.global, context.token),
                    .borrow_wire, .borrow_transfer_handle => value.*.borrowWire(),
                    .nominal_handle => nominalHandleToWire(Manifest.SemanticType(position.type), value.*),
                    .native_slice => .{ .ptr = if (value.len == 0) null else value.ptr, .len = value.len },
                },
                inline else => |child| collection: {
                    if (comptime @TypeOf(id).role == .inbound_result) {
                        var owned = value.*;
                        break :collection owned.takeWire();
                    }
                    if (value.len == 0) break :collection .{ .ptr = null, .len = 0 };
                    const Child = wireType(Manifest.get(child).wire);
                    const items = try context.allocator.alloc(Child, value.len);
                    for (value.*, items) |*item, *encoded| encoded.* = try encode(child).wire(item, context);
                    break :collection .{ .ptr = items.ptr, .len = items.len };
                },
            };
        }

        fn scalar(comptime kind: ir.ScalarKind, value: *const Api(id)) Wire {
            return switch (kind) {
                .boolean => @intFromBool(value.*),
                .discarded => 0,
                .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .f64 => value.*,
                .usize => @intCast(value.*),
            };
        }

        fn resultValue(value: *const Api(id)) Wire {
            var result = value.*;
            return result.takeEncoded();
        }

        fn optional(comptime child: @TypeOf(id), value: *const Api(id), context: anytype) EncodeError!Wire {
            return if (value.*) |*present| .{
                .present = 1,
                .value = try encode(child).wire(present, context),
            } else std.mem.zeroes(Wire);
        }

        fn dictionary(comptime fields_id: @FieldType(Shape, "dictionary"), value: *const Api(id), context: anytype) EncodeError!Wire {
            var result: Wire = std.mem.zeroes(Wire);
            inline for (Manifest.positionFields(fields_id)) |field| {
                if (field.optional) {
                    if (@field(value.*, field.name)) |*present| {
                        @field(result, field.name ++ "_present") = 1;
                        @field(result, field.name) = try encode(field.value).wire(present, context);
                    }
                } else {
                    @field(result, field.name) = try encode(field.value).wire(&@field(value.*, field.name), context);
                }
            }
            return result;
        }

        fn unionValue(comptime members_id: @FieldType(Shape, "union_type"), value: *const Api(id), context: anytype) EncodeError!Wire {
            return switch (value.*) {
                inline else => |*payload, tag| .{
                    .tag = @backingInt(tag),
                    .payload = @unionInit(@FieldType(Wire, "payload"), @tagName(tag), try encode(Manifest.positionMembers(members_id)[@backingInt(tag) - 1].value).wire(payload, context)),
                },
            };
        }

        fn recordEntry(comptime entry: @FieldType(Shape, "record_entry"), value: *const Api(id), context: anytype) EncodeError!Wire {
            return .{
                .key = try encode(entry.key).wire(&value.key, context),
                .value = try encode(entry.value).wire(&value.value, context),
            };
        }

        fn commit(value: *Api(id)) void {
            switch (position.representation) {
                .converted => |conversion| encode(conversion.apiValue()).commit(value),
                .optional => |child| if (value.*) |*present| encode(child).commit(present),
                .dictionary => |fields_id| inline for (Manifest.positionFields(fields_id)) |field| {
                    if (field.optional) {
                        if (@field(value.*, field.name)) |*present| encode(field.value).commit(present);
                    } else {
                        encode(field.value).commit(&@field(value.*, field.name));
                    }
                },
                .union_type => |members_id| switch (value.*) {
                    inline else => |*payload, tag| encode(Manifest.positionMembers(members_id)[@backingInt(tag) - 1].value).commit(payload),
                },
                .record_entry => |entry| {
                    encode(entry.key).commit(&value.key);
                    encode(entry.value).commit(&value.value);
                },
                .leaf => if (comptime @TypeOf(id).role == .outbound_argument) {
                    if (position.zig.leaf.?.encode == .borrow_transfer_handle) value.commitTransfer();
                },
                inline else => |child| if (@TypeOf(id).role != .inbound_result) {
                    for (value.*) |*item| encode(child).commit(item);
                },
            }
        }
    };
}

fn wireSlice(comptime Slice: type, value: anytype) Slice {
    if (value.len == 0) {
        if (value.ptr != null) @panic("binding slice is not in canonical empty form");
        return &.{};
    }
    const Element = @typeInfo(Slice).pointer.child;
    if (@mulWithOverflow(value.len, @as(usize, @sizeOf(Element)))[1] != 0)
        @panic("binding slice byte length overflows");
    const ptr: @TypeOf(@as(Slice, undefined).ptr) = @ptrCast(@alignCast(value.ptr orelse @panic("binding slice has a null data pointer")));
    return ptr[0..value.len];
}

const CollectionStorage = enum { view, owned, scoped };

/// How a decoded collection holds its elements, as its API representation fixes it.
fn collectionStorage(comptime id: anytype) CollectionStorage {
    const api = Manifest.binding().api_types[Manifest.get(id).api.index].representation;
    return switch (api) {
        .sequence, .record => |collection| switch (collection) {
            .view => .view,
            .owned => .owned,
            .scoped => .scoped,
            .slice => @compileError("binding slices are encoded, not decoded"),
        },
        .rest => |rest| switch (rest) {
            .view => .view,
            .slice => @compileError("binding slices are encoded, not decoded"),
        },
        else => @compileError("binding position is not a collection"),
    };
}

fn decode(comptime id: anytype) type {
    if (@TypeOf(id).role == .outbound_argument) @compileError("this role does not decode Zig values");
    const position = Manifest.get(id);
    const Shape = @TypeOf(position.representation);
    const Wire = wireType(position.wire);
    const Type = Manifest.SemanticType(position.type);
    const allocates = @TypeOf(id).role != .inbound_argument and position.zig.decode_allocates;
    const DecodeError = if (allocates) bun.JSError else error{};
    return struct {
        fn wire(value: Wire, context: anytype) DecodeError!Api(id) {
            return switch (position.representation) {
                .converted => |conversion| try decode(conversion.apiValue()).wire(value, context),
                .optional => |child| if (decodeWirePresence(value.present)) try decode(child).wire(value.value, context) else null,
                .dictionary => |fields_id| try dictionary(fields_id, value, context),
                .union_type => |members_id| try unionValue(members_id, value, context),
                .record_entry => |entry| try recordEntry(entry, value, context),
                .leaf => if (@TypeOf(id).role == .inbound_argument) switch (position.zig.leaf.?.decode) {
                    .void => {},
                    .scalar => |kind| scalar(kind, value),
                    .enumeration => decodeEnumeration(Type, value),
                    .scoped_view => Api(id).init(value, context.global, context.token),
                    .token_view => Api(id).init(value, context.token),
                    .adopt_wire => Api(id).adoptWire(value),
                    .pointer => @ptrCast(@alignCast(value orelse @panic("binding value contains a null native handle"))),
                } else if (@TypeOf(id).role == .inbound_result) switch (position.zig.leaf.?.decode) {
                    .void => {},
                    .scalar => |kind| scalar(kind, value),
                    .enumeration => decodeEnumeration(Type, value),
                    .value_result => |kind| resultValue(kind, value, context),
                    .adopt_wire => Api(id).adoptWire(value),
                    .adopt_scoped => try Api(id).adoptWire(value, context.global),
                    .pointer => @ptrCast(@alignCast(value orelse @panic("binding value contains a null native handle"))),
                } else switch (position.zig.leaf.?.decode) {
                    .void => {},
                    .scalar => |kind| scalar(kind, value),
                    .enumeration => decodeEnumeration(Type, value),
                    .value_result => |kind| resultValue(kind, value, context),
                    .adopt_wire => Api(id).adoptWire(value),
                    .borrow_callback => Api(id).init(try adoptCallScopedRoot(RootHandle.adoptWire(value), context.global, context.token), context.global, context.token),
                    .borrow_class => Api(id).init(.{
                        .native = value.native,
                        .wrapper = try adoptCallScopedRoot(RootHandle.adoptWire(value.wrapper), context.global, context.token),
                    }, context.global, context.token),
                    .pointer => @ptrCast(@alignCast(value orelse @panic("binding value contains a null native handle"))),
                },
                inline else => |child| switch (comptime collectionStorage(id)) {
                    .view => Api(id).init(value, context.global, context.token),
                    .owned => Api(id).adoptWire(value, if (comptime Manifest.get(child).zig.requires_realm) context.global else null),
                    .scoped => try Api(id).adoptWire(value, context.token),
                },
            };
        }

        fn scalar(comptime kind: ir.ScalarKind, value: Wire) Api(id) {
            return switch (kind) {
                .boolean => switch (value) {
                    0 => false,
                    1 => true,
                    else => @panic("binding value has an invalid boolean byte"),
                },
                .discarded => if (value == 0) false else @panic("binding value has an invalid discarded-value byte"),
                .usize => @intCast(value),
                .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .f64 => value,
            };
        }

        fn resultValue(comptime kind: ir.JSValueKind, value: Wire, context: anytype) Api(id) {
            const decoded: jsc.JSValue = @fromBackingInt(@intCast(value));
            if (decoded == .zero) @panic("binding decoded an empty JS value without an exception");
            return Api(id).initInline(decoded, context.global, context.token, switch (kind) {
                .any => .any,
                .engine_value => .engine,
                .branded => .branded,
            });
        }

        fn dictionary(comptime fields_id: @FieldType(Shape, "dictionary"), value: Wire, context: anytype) DecodeError!Api(id) {
            const fields = Manifest.positionFields(fields_id);
            var result: Api(id) = undefined;
            var decoded_fields: usize = 0;
            errdefer if (comptime allocates) {
                inline for (fields, 0..) |field, index| {
                    if (index < decoded_fields) {
                        if (field.optional) {
                            destroy(field.value).optionalApi(&@field(result, field.name));
                        } else {
                            destroy(field.value).api(&@field(result, field.name));
                        }
                    } else if (index > decoded_fields and Manifest.get(field.value).zig.destruction.wire) {
                        if (!field.optional or decodeWirePresence(@field(value, field.name ++ "_present"))) {
                            var remaining = @field(value, field.name);
                            destroy(field.value).transfer(&remaining);
                        }
                    }
                }
            };
            // The active child decoder consumes its wire value even on failure.
            inline for (fields) |field| {
                @field(result, field.name) = if (field.optional and !decodeWirePresence(@field(value, field.name ++ "_present")))
                    null
                else
                    try decode(field.value).wire(@field(value, field.name), context);
                decoded_fields += 1;
            }
            return result;
        }

        fn unionValue(comptime members_id: @FieldType(Shape, "union_type"), value: Wire, context: anytype) DecodeError!Api(id) {
            return switch (decodeUnionTag(id, value.tag)) {
                inline else => |tag| @unionInit(Api(id), @tagName(tag), try decode(Manifest.positionMembers(members_id)[@backingInt(tag) - 1].value).wire(@field(value.payload, @tagName(tag)), context)),
            };
        }

        fn recordEntry(comptime entry: @FieldType(Shape, "record_entry"), value: Wire, context: anytype) DecodeError!Api(id) {
            var key = decode(entry.key).wire(value.key, context) catch |err| {
                if (comptime Manifest.get(entry.value).zig.destruction.wire) {
                    var remaining = value.value;
                    destroy(entry.value).transfer(&remaining);
                }
                return err;
            };
            errdefer if (comptime allocates) destroy(entry.key).api(&key);
            return .{ .key = key, .value = try decode(entry.value).wire(value.value, context) };
        }
    };
}

fn decodeUnionTag(comptime id: anytype, value: u8) std.meta.Tag(Api(id)) {
    return std.enums.fromInt(std.meta.Tag(Api(id)), value) orelse @panic("binding value has an invalid union tag");
}

fn decodeEnumeration(comptime Type: type, value: @typeInfo(Type.Native).@"enum".tag_type) Type.Native {
    return std.enums.fromInt(Type.Native, value) orelse @panic("binding enumeration tag is invalid");
}

fn Api(comptime id: anytype) type {
    if (comptime @TypeOf(id) != ir.ApiTypeId) return Api(Manifest.get(id).api);
    const Cached = struct {
        const instantiated = built: {
            @setEvalBranchQuota(api_eval_branch_quota);
            const api = Manifest.binding().api_types[id.index];
            const Type = Manifest.SemanticType(api.type);
            break :built switch (api.representation) {
                .void => void,
                .scalar => |kind| ScalarApiTypeForKind(kind),
                .enumeration => Type.Native,
                .js_value_view => |kind| switch (kind) {
                    .any => AnyView,
                    .engine_value => EngineValueView,
                    .branded => BrandedValueViewType(Type),
                },
                .js_value_operand => |kind| switch (kind) {
                    .any => AnyOperand,
                    .engine_value => EngineOperand,
                    .branded => ValueOperand(.branded, Type.Brand),
                },
                .js_value_result => |kind| switch (kind) {
                    .any => AnyResult,
                    .engine_value => EngineValueResult,
                    .branded => BrandedValueResultType(Type),
                },
                .string_view => BoundStringView(Type.string_kind, Type.string_thread_safe),
                .string_operand => StringOperand(Type.string_kind, Type.string_thread_safe),
                .string_owned => BoundString(Type.string_kind, Type.string_thread_safe),
                .utf8_owned => UTF8String,
                .bytes_view => BytesView,
                .bytes_operand => BytesOperand,
                .bytes_owned => OwnedBytes,
                .native_slice => if (Type.native_slice_access == .read_write) []NativeElement(Type.native_slice_element) else []const NativeElement(Type.native_slice_element),
                .byte_lease => LeaseArgumentType(Type),
                .lease_owned => LeaseResultType(Type),
                .callback_view => CallbackView(Type),
                .callback_owned => Callback(Type),
                .class_view => ClassRefView(Type.ReferencedClass),
                .class_owned => ClassRef(Type.ReferencedClass),
                .external_view => ExternalRefView(Type),
                .external_owned => ExternalRef(Type),
                .nominal_borrow => NominalHandlePointer(Type),
                .nominal_owner_borrow => |owner| *const OwnedNominalHandle(Type, Manifest.get(owner)),
                .nominal_owned => |owner| OwnedNominalHandle(Type, Manifest.get(owner)),
                .native => |class| *NativeClassHandle(class.index),
                .optional => |child| ?Api(child),
                .dictionary => |dictionary| value: {
                    if (dictionary.system_error) break :value SystemError;
                    const children = dictionary.fields;
                    var names: [children.len][]const u8 = undefined;
                    var types: [children.len]type = undefined;
                    var attributes: [children.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
                    for (Type.dictionary_fields, children, 0..) |Field, child, index| {
                        names[index] = Field.field_name;
                        types[index] = if (Field.storage == .optional) ?Api(child) else Api(child);
                        if (Field.storage == .optional) attributes[index].default_value_ptr = &@as(types[index], null);
                    }
                    break :value @Struct(.auto, null, &names, &types, &attributes);
                },
                .union_type => |children| value: {
                    var types: [children.len]type = undefined;
                    for (children, 0..) |child, index| types[index] = Api(child);
                    break :value SemanticUnionApiType(Type, types);
                },
                .record_entry => |entry| struct {
                    key: Api(entry.key),
                    value: Api(entry.value),

                    pub fn deinit(self: *@This()) void {
                        switch (entry.cleanup) {
                            .none => {},
                            inline .owned, .scoped => |owner| destroy(owner).api(self),
                        }
                    }
                },
                .rest => |rest| switch (rest) {
                    .view => AnyRestView,
                    .slice => |slice| if (slice.mutable) []Api(slice.element) else []const Api(slice.element),
                },
                .lazy_operand => |protocol| struct {
                    pub const SemanticType = Type;
                    pub const Handle = Api(protocol).Handle;

                    handle: *Handle,
                    token: ViewToken,

                    fn init(handle: *wire.BindLazyArgumentHandle, global: *jsc.JSGlobalObject, token: ViewToken) @This() {
                        if (token.globalObject() != global) @panic("lazy engine operand has the wrong call realm");
                        return .{ .handle = @ptrCast(handle), .token = token };
                    }

                    fn borrowWireForEngine(view: @This(), global: *jsc.JSGlobalObject, token: ViewToken) *wire.BindLazyArgumentHandle {
                        view.token.requireSameCall(token, global, "lazy binding value used by an unrelated engine operation");
                        return @ptrCast(view.handle);
                    }
                },
                .lazy_view => |deferred| LazyArgumentViewType(false, deferred),
                .lazy_rest => |deferred| LazyRestViewType(deferred),
                .native_slice_view => value: {
                    const Element = NativeElement(Type.native_slice_element);
                    const Access = Type.native_slice_access;
                    const Pointer = if (Access == .read_write) ?[*]Element else ?[*]const Element;
                    const Slice = NativeSlice(Type.native_slice_element, Type.native_slice_access);
                    const Result_ = struct {
                        pointer: Pointer,
                        count: usize,
                        token: ViewToken,

                        const Self = @This();

                        fn init(value: anytype, token: ViewToken) Self {
                            const values = wireSlice(Slice, value);
                            return .{ .pointer = if (values.len == 0) null else values.ptr, .count = values.len, .token = token };
                        }

                        pub fn length(self: Self) usize {
                            self.token.requireActive();
                            return self.count;
                        }

                        pub fn read(self: Self, offset: usize, destination: []Element) bool {
                            const values = self.raw();
                            if (offset > values.len or destination.len > values.len - offset) return false;
                            @memmove(destination, values[offset..][0..destination.len]);
                            return true;
                        }

                        pub fn write(self: Self, offset: usize, source: []const Element) bool {
                            if (comptime Access != .read_write) @compileError("read-only native slices cannot be written");
                            const values: []Element = self.raw();
                            if (offset > values.len or source.len > values.len - offset) return false;
                            @memmove(values[offset..][0..source.len], source);
                            return true;
                        }

                        pub fn unsafePtr(self: Self, comptime reason: []const u8) Slice {
                            if (reason.len == 0) @compileError("unsafePtr requires a non-empty lifetime reason");
                            return self.raw();
                        }

                        fn raw(self: Self) Slice {
                            self.token.requireActive();
                            if (self.count == 0) {
                                return if (comptime Access == .read_write) @constCast(&.{}) else &.{};
                            }
                            return self.pointer.?[0..self.count];
                        }
                    };
                    break :value Result_;
                },
                .lazy_field => |field| value: {
                    const value_position = field.value;
                    const Result_ = struct {
                        pub const Handle = opaque {};

                        handle: *Handle,
                        token: ViewToken,

                        const Self = @This();

                        pub const bindgen_lazy_view = {};
                        pub const SemanticType = Type;
                        const ConvertedValue = DeferredValue(Api(value_position));
                        pub const Forced = struct { converted: ConvertedValue, proof: DeferredLeaseProof };

                        fn init(
                            handle: ?*wire.BindLazyArgumentHandle,
                            global: *jsc.JSGlobalObject,
                            token: ViewToken,
                        ) Self {
                            if (token.globalObject() != global) @panic("lazy field has the wrong call realm");
                            return .{
                                .handle = @ptrCast(handle orelse @panic("lazy field has a null handle")),
                                .token = token,
                            };
                        }

                        pub fn operand(view: Self, context: anytype) Api(field.forward) {
                            const token = context.viewToken();
                            return .init(view.borrowWireForEngine(context.viewToken().globalObject(), token), token.globalObject(), token);
                        }

                        pub fn convert(view: Self, context: anytype) bun.JSError!ConvertedValue {
                            const result = try view.convertImpl(context, false);
                            if (result.proof != null) @panic("non-final lazy field conversion returned a lease proof");
                            return result.converted;
                        }

                        pub fn convertLast(view: Self, context: anytype) bun.JSError!Forced {
                            requireDeferredContext(@TypeOf(context));
                            const result = try view.convertImpl(context, true);
                            return .{ .converted = result.converted, .proof = DeferredLeaseProof.init(result.proof, view.token) };
                        }

                        pub fn validate(view: Self, context: anytype) bun.JSError!void {
                            _ = try view.convert(context);
                        }

                        pub fn discard(view: Self, context: anytype) bun.JSError!void {
                            if (try view.discardImpl(context, false) != null) @panic("non-final lazy field discard returned a lease proof");
                        }

                        pub fn discardLast(view: Self, context: anytype) bun.JSError!DeferredLeaseProof {
                            requireDeferredContext(@TypeOf(context));
                            return (try view.discardImpl(context, true)) orelse @panic("last lazy field discard did not yield a lease proof");
                        }

                        fn requireDeferredContext(comptime Context: type) void {
                            if (!@hasDecl(ContextMetadata(Context), "bindgen_function_id"))
                                @compileError("deferred lease proofs require a host call context");
                        }

                        fn convertImpl(view: Self, context: anytype, last: bool) bun.JSError!struct { converted: ConvertedValue, proof: ?*wire.BindDeferredConversionsHandle } {
                            _ = ContextMetadata(@TypeOf(context));
                            const global = view.token.globalObject();
                            view.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "lazy field converted with an unrelated call context");
                            var result: wireType(Manifest.get(value_position).wire) = std.mem.zeroes(wireType(Manifest.get(value_position).wire));
                            var proof: ?*wire.BindDeferredConversionsHandle = null;
                            const status = @field(wire, std.fmt.comptimePrint(ir.symbol_formats.lazy_field_convert, .{field.symbol}))(
                                @ptrCast(global),
                                @ptrCast(view.handle),
                                view.token.call.deferred_conversions,
                                @intFromBool(last),
                                &proof,
                                &result,
                            );
                            try requireCheckedSuccess(global, status);
                            return .{
                                .converted = .{ .value = try decode(value_position).wire(result, .{ .global = global, .token = view.token }) },
                                .proof = proof,
                            };
                        }

                        fn discardImpl(view: Self, context: anytype, last: bool) bun.JSError!?DeferredLeaseProof {
                            _ = ContextMetadata(@TypeOf(context));
                            const global = view.token.globalObject();
                            view.token.requireSameCall(context.viewToken(), context.viewToken().globalObject(), "lazy field discarded with an unrelated call context");
                            var proof: ?*wire.BindDeferredConversionsHandle = null;
                            const status = @field(wire, std.fmt.comptimePrint(ir.symbol_formats.lazy_field_discard, .{field.symbol}))(
                                @ptrCast(global),
                                @ptrCast(view.handle),
                                view.token.call.deferred_conversions,
                                @intFromBool(last),
                                &proof,
                            );
                            try requireCheckedSuccess(global, status);
                            return if (proof) |handle| DeferredLeaseProof.init(handle, view.token) else null;
                        }

                        fn borrowWireForEngine(
                            view: Self,
                            global: *jsc.JSGlobalObject,
                            token: ViewToken,
                        ) *wire.BindLazyArgumentHandle {
                            view.token.requireSameCall(token, global, "binding lazy value used by an unrelated engine operation");
                            return @ptrCast(view.handle);
                        }
                    };
                    break :value Result_;
                },
                .sequence, .record => |collection| switch (collection) {
                    .view => |view_plan| value: {
                        const element_position = view_plan.element;
                        const is_sequence = api.representation == .sequence;
                        const WireChild = wireType(Manifest.get(element_position).wire);
                        const Result_ = struct {
                            ptr: ?[*]const WireChild,
                            length: usize,
                            token: ViewToken,

                            const Self = @This();
                            pub const SemanticType = Type;
                            pub const ElementView = Api(element_position);
                            pub const Entry = if (is_sequence) void else ElementView;

                            fn init(value: anytype, global: *jsc.JSGlobalObject, token: ViewToken) Self {
                                if (token.globalObject() != global) @panic("binding collection view has the wrong call realm");
                                const values = wireSlice([]const WireChild, value);
                                return .{
                                    .ptr = if (values.len == 0) null else values.ptr,
                                    .length = values.len,
                                    .token = token,
                                };
                            }

                            pub fn len(self: Self) usize {
                                self.token.requireActive();
                                return self.length;
                            }

                            pub fn at(self: Self, index: usize) ?ElementView {
                                self.token.requireActive();
                                if (index >= self.length) return null;
                                return decode(element_position).wire(self.ptr.?[index], .{ .global = self.token.globalObject(), .token = self.token }) catch |err| switch (err) {};
                            }

                            pub const Item = if (is_sequence) struct {
                                value: ElementView,
                            } else ElementView;

                            pub const Iterator = struct {
                                view: Self,
                                index: usize = 0,

                                pub fn next(iter: *@This()) ?Item {
                                    const value = iter.view.at(iter.index) orelse return null;
                                    iter.index += 1;
                                    return if (is_sequence) .{ .value = value } else value;
                                }
                            };

                            pub fn iterator(self: Self) Iterator {
                                self.token.requireActive();
                                return .{ .view = self };
                            }

                            pub fn toSlice(self: Self, allocator: std.mem.Allocator) bun.OOM![]ElementView {
                                self.token.requireActive();
                                const items = try allocator.alloc(ElementView, self.length);
                                for (items, 0..) |*item, index| item.* = self.at(index).?;
                                return items;
                            }

                            pub fn toOwned(self: Self) clone(view_plan.source).Error!Api(clone(view_plan.source).target) {
                                self.token.requireActive();
                                const context = .{ .global = self.token.globalObject(), .token = self.token };
                                const result = try clone(view_plan.source).copy(.{ .ptr = self.ptr, .len = self.length }, context);
                                return decode(clone(view_plan.source).target).wire(result, context) catch |err| switch (err) {};
                            }

                            pub const toFunctionResult = toOwned;
                        };
                        break :value Result_;
                    },
                    .owned => |contract| collection: {
                        const element_id = contract.element;
                        const element = Manifest.get(element_id);
                        const ElementType = Manifest.SemanticType(element.type);
                        const Wire = wireType(contract.wire);
                        const WireElement = wireType(element.wire);
                        const is_sequence = api.representation == .sequence;
                        const Collection = struct {
                            storage: []WireElement,
                            consumed_prefix: usize = 0,
                            realm: ?*StoredRealmHandle = null,

                            const Self = @This();
                            pub const SemanticType = Type;
                            pub const Element = Api(element_id);
                            pub const Entry = if (is_sequence) void else Element;
                            pub const Item = if (is_sequence) struct {
                                value: Element,

                                pub fn deinit(item: *@This()) void {
                                    destroy(element_id).api(&item.value);
                                }
                            } else Element;

                            pub const Builder = struct {
                                storage: []WireElement = &.{},
                                initialized: usize = 0,

                                pub fn init(length: usize) bun.OOM!@This() {
                                    return .{ .storage = if (length == 0) &.{} else try transferAlloc(WireElement, length) };
                                }

                                pub fn appendOwned(builder: *@This(), item: Element) void {
                                    if (builder.initialized == builder.storage.len) @panic("binding collection builder is full");
                                    builder.storage[builder.initialized] = encode(element_id).wire(&item, .{}) catch |err| switch (err) {};
                                    builder.initialized += 1;
                                }

                                pub fn deinit(builder: *@This()) void {
                                    const pending = builder.*;
                                    builder.* = .{};
                                    releaseTransferSlice(element_id, pending.storage, 0, pending.initialized);
                                }

                                pub fn finish(builder: *@This()) Self {
                                    if (builder.initialized != builder.storage.len) @panic("binding collection builder is incomplete");
                                    const storage = builder.storage;
                                    builder.* = .{};
                                    return .{ .storage = storage };
                                }
                            };

                            pub fn deinitElement(item: *Element) void {
                                destroy(element_id).api(item);
                            }

                            pub fn fromOwnedSlice(items: []const Element) bun.OOM!Self {
                                var builder = try Builder.init(items.len);
                                for (items) |item| builder.appendOwned(item);
                                return builder.finish();
                            }

                            pub fn fromMappedSlice(items: anytype, comptime convert: fn (std.meta.Elem(@TypeOf(items))) bun.OOM!Element) bun.OOM!Self {
                                var builder = try Builder.init(items.len);
                                errdefer builder.deinit();
                                for (items) |item| builder.appendOwned(try convert(item));
                                return builder.finish();
                            }

                            pub fn fromUTF8Slices(items: []const []const u8) bun.OOM!Self {
                                if (comptime !is_sequence or (ElementType.kind != .utf8_string and ElementType.kind != .dom_string)) @compileError("fromUTF8Slices requires a sequence of UTF8String or DOMString");
                                return fromMappedSlice(items, if (ElementType.kind == .utf8_string) UTF8String.fromSlice else Element.fromUTF8);
                            }

                            pub fn fromBunStrings(items: []const bun.String) bun.OOM!Self {
                                if (comptime !is_sequence or ElementType.kind != .dom_string) @compileError("fromBunStrings requires a sequence of DOMString");
                                const Converter = struct {
                                    fn convert(item: bun.String) bun.OOM!Element {
                                        return Element.fromBunString(item.dupeRef());
                                    }
                                };
                                return fromMappedSlice(items, Converter.convert);
                            }

                            pub fn fromUTF8Pairs(keys: []const []const u8, values: []const []const u8) bun.OOM!Self {
                                if (comptime is_sequence) @compileError("fromUTF8Pairs requires a record of DOMString keys and values");
                                if (comptime Type.KeyType.kind != .dom_string or Type.ValueType.kind != .dom_string) @compileError("fromUTF8Pairs requires a record of DOMString keys and values");
                                const Key = @FieldType(Element, "key");
                                const Value = @FieldType(Element, "value");
                                if (keys.len != values.len) @panic("binding record key and value counts differ");
                                var builder = try Builder.init(keys.len);
                                errdefer builder.deinit();
                                for (keys, values) |key_bytes, value_bytes| {
                                    var key = try Key.fromUTF8(key_bytes);
                                    errdefer key.deinit();
                                    builder.appendOwned(.{ .key = key, .value = try Value.fromUTF8(value_bytes) });
                                }
                                return builder.finish();
                            }

                            pub fn len(self: *const Self) usize {
                                return self.storage.len - self.consumed_prefix;
                            }

                            pub fn reverse(self: *Self) void {
                                if (self.consumed_prefix != 0) @panic("a partially consumed binding collection cannot be reversed");
                                std.mem.reverse(WireElement, self.storage);
                            }

                            const ReadError = if (element.zig.decode_allocates) bun.JSError else error{};
                            const ReadResult = if (is_sequence and !element.zig.decode_allocates) ?Item else ReadError!?Item;

                            fn takeNextWire(self: *Self) ?WireElement {
                                if (self.consumed_prefix == self.storage.len) return null;
                                const encoded = self.storage[self.consumed_prefix];
                                self.consumed_prefix += 1;
                                return encoded;
                            }

                            fn next(self: *Self) ReadResult {
                                const encoded = self.takeNextWire() orelse return null;
                                const global = if (comptime element.zig.requires_realm)
                                    @as(*jsc.JSGlobalObject, @ptrCast(@alignCast(self.realm orelse @panic("binding collection lost its realm"))))
                                else
                                    null;
                                const item = try decode(element_id).wire(encoded, .{ .global = global });
                                return if (is_sequence) .{ .value = item } else item;
                            }

                            pub const Iterator = struct {
                                collection: *Self,

                                pub fn next(iter: *@This()) ReadResult {
                                    return iter.collection.next();
                                }
                            };

                            pub fn iterator(self: *Self) Iterator {
                                return .{ .collection = self };
                            }

                            pub fn deinit(self: *Self) void {
                                const pending = self.take();
                                releaseTransferSlice(element_id, pending.storage, pending.consumed_prefix, pending.storage.len);
                            }

                            fn adoptWire(encoded: Wire, global: if (element.zig.requires_realm) *jsc.JSGlobalObject else ?*jsc.JSGlobalObject) Self {
                                const storage = wireSlice([]WireElement, encoded);
                                if (storage.len == 0) return empty();
                                return .{
                                    .storage = storage,
                                    .realm = if (element.zig.requires_realm) @ptrCast(global) else null,
                                };
                            }

                            fn take(self: *Self) Self {
                                const owner = self.*;
                                self.* = empty();
                                return owner;
                            }

                            fn takeWire(self: *Self) Wire {
                                if (self.consumed_prefix != 0) @panic("a partially consumed binding collection cannot be transferred");
                                const storage = self.take().storage;
                                return .{ .ptr = if (storage.len == 0) null else storage.ptr, .len = storage.len };
                            }

                            fn empty() Self {
                                return .{ .storage = &.{} };
                            }
                        };
                        break :collection Collection;
                    },
                    .scoped => |contract| collection: {
                        const Wire = wireType(contract.wire);
                        const Collection = struct {
                            handle: ?*Handle,
                            token: ViewToken,

                            const Self = @This();
                            const Handle = opaque {};
                            const Owned = Api(contract.owner);
                            pub const SemanticType = Type;
                            const State = struct {
                                owned: ?Owned,

                                fn deinit(state: *@This()) void {
                                    var owned = bun.take(&state.owned) orelse return;
                                    owned.deinit();
                                }
                            };

                            fn activeState(view: Self) ?*State {
                                view.token.requireActive();
                                const state: *State = @ptrCast(@alignCast(view.handle orelse return null));
                                if (state.owned == null) @panic("binding call-scoped collection was already taken");
                                return state;
                            }

                            fn adoptWire(encoded: Wire, token: ViewToken) bun.OOM!Self {
                                token.requireActive();
                                if (encoded.len == 0) {
                                    if (encoded.ptr != null) @panic("binding collection transfer is not in canonical empty form");
                                    return .{ .handle = null, .token = token };
                                }
                                const state = try adoptCallScopedOwner(State{
                                    .owned = Owned.adoptWire(encoded, token.globalObject()),
                                }, token);
                                return .{ .handle = @ptrCast(state), .token = token };
                            }

                            pub fn len(view: Self) usize {
                                const storage = view.activeState() orelse return 0;
                                return storage.owned.?.len();
                            }

                            pub fn take(view: Self) Api(contract.owner) {
                                const storage = view.activeState() orelse return Owned.adoptWire(std.mem.zeroes(Wire), view.token.globalObject());
                                return bun.take(&storage.owned).?;
                            }
                        };
                        break :collection Collection;
                    },
                    .slice => |slice| if (slice.mutable) []Api(slice.element) else []const Api(slice.element),
                },
            };
        };
    };
    return Cached.instantiated;
}

fn NativeClassHandle(comptime class_id: usize) type {
    return opaque {
        pub const id = class_id;
    };
}

fn DeferredOwner(comptime call: ir.DeferredCall) type {
    const overload_index: ?usize = if (call.overload_index) |index| index else null;
    return switch (call.declaration) {
        .function => |id| FunctionMetadata(id.index, overload_index),
        .native_export => |id| NativeExportMetadata(id.index),
        .class => |id| FunctionMetadata(Manifest.Class(id).Constructor.id, overload_index),
    };
}

fn ScalarApiTypeForKind(comptime kind: ir.ScalarKind) type {
    return switch (kind) {
        .boolean, .discarded => bool,
        .i8 => i8,
        .u8 => u8,
        .i16 => i16,
        .u16 => u16,
        .i32 => i32,
        .u32 => u32,
        .i64 => i64,
        .u64 => u64,
        .usize => usize,
        .f64 => f64,
    };
}

fn destroy(comptime id: anytype) type {
    const position = Manifest.get(id);
    const Shape = @TypeOf(position.representation);
    const Wire = wireType(position.wire);
    return struct {
        fn api(value: *Api(id)) void {
            if (comptime !position.zig.destruction.api) return;
            switch (position.representation) {
                .converted => |conversion| destroy(conversion.apiValue()).api(value),
                .optional => |child| destroy(child).optionalApi(value),
                .dictionary => |fields_id| dictionaryApi(fields_id, value),
                .union_type => |members_id| unionApi(members_id, value),
                .record_entry => |entry| recordApi(entry, value),
                .leaf => if (comptime @TypeOf(id).role == .inbound_result) switch (position.zig.leaf.?.destroy) {
                    .none => {},
                    .deinit => value.deinit(),
                    .native_instance => |class| @field(wire, Manifest.Class(class).destroy_pending_native_symbol)(@ptrCast(value.*)),
                } else switch (position.zig.leaf.?.destroy) {
                    .none => {},
                    .deinit => value.deinit(),
                },
                inline else => |child| if (comptime @TypeOf(id).role == .outbound_argument) {
                    for (value.*) |*item| destroy(child).api(item);
                } else value.deinit(),
            }
        }

        fn optionalApi(value: *?Api(id)) void {
            var present = bun.take(value) orelse return;
            api(&present);
        }

        fn dictionaryApi(comptime fields_id: @FieldType(Shape, "dictionary"), value: *Api(id)) void {
            inline for (Manifest.positionFields(fields_id)) |field| {
                if (field.optional) {
                    destroy(field.value).optionalApi(&@field(value.*, field.name));
                } else {
                    destroy(field.value).api(&@field(value.*, field.name));
                }
            }
        }

        fn unionApi(comptime members_id: @FieldType(Shape, "union_type"), value: *Api(id)) void {
            switch (value.*) {
                inline else => |*payload, tag| destroy(Manifest.positionMembers(members_id)[@backingInt(tag) - 1].value).api(payload),
            }
        }

        fn recordApi(comptime entry: @FieldType(Shape, "record_entry"), value: *Api(id)) void {
            destroy(entry.key).api(&value.key);
            destroy(entry.value).api(&value.value);
        }

        fn transfer(value: *Wire) void {
            if (comptime position.zig.destruction.wire) switch (position.representation) {
                .converted => |conversion| destroy(conversion.apiValue()).transfer(value),
                .optional => |child| if (decodeWirePresence(value.present)) destroy(child).transfer(&value.value),
                .dictionary => |fields_id| dictionaryWire(fields_id, value),
                .union_type => |members_id| unionWire(members_id, value),
                .record_entry => |entry| recordWire(entry, value),
                .leaf => if (comptime @TypeOf(id).role == .inbound_argument or @TypeOf(id).role == .outbound_argument) switch (position.zig.leaf.?.release) {
                    .none => {},
                    .release_handle => |release| if (!releaseHandle(release, value)) return,
                } else switch (position.zig.leaf.?.release) {
                    .none => {},
                    .root => {
                        const handle = value.* orelse @panic("binding root transfer is null");
                        if (isMovedWireHandle(handle)) return;
                        RootHandle.adoptWire(handle).deinit();
                    },
                    .string => if (value.*) |handle| {
                        if (isMovedWireHandle(handle)) return;
                        wire.bun_bindgen_string_release(handle);
                    },
                    .bytes => {
                        var owned = OwnedBytes.adoptWire(value.*);
                        owned.deinit();
                    },
                    .release_handle => |release| if (!releaseHandle(release, value)) return,
                    .class_ref => {
                        const handle = value.wrapper orelse @panic("binding class reference transfer is null");
                        if (isMovedWireHandle(handle)) return;
                        RootHandle.adoptWire(handle).deinit();
                    },
                },
                inline else => |child| collectionWire(child, value),
            };
            value.* = std.mem.zeroes(Wire);
        }

        fn releaseHandle(comptime release: ir.HandleRelease(@TypeOf(id).role), value: *Wire) bool {
            const symbol = comptime if (@TypeOf(id).role == .inbound_result) switch (release) {
                .byte_lease => "bun_bindgen_byte_lease_release",
                .nominal => |owner| Manifest.get(owner).release_symbol,
                .external => |external| Manifest.get(external).release_symbol,
                .native => |class_id| Manifest.Class(class_id).destroy_pending_native_symbol,
            } else Manifest.get(release).release_symbol;
            const handle = value.* orelse @panic("binding owned handle transfer is null");
            if (isMovedWireHandle(handle)) return false;
            @field(wire, symbol)(handle);
            return true;
        }

        fn dictionaryWire(comptime fields_id: @FieldType(Shape, "dictionary"), value: *Wire) void {
            inline for (Manifest.positionFields(fields_id)) |field| {
                if (!field.optional or decodeWirePresence(@field(value.*, field.name ++ "_present"))) destroy(field.value).transfer(&@field(value.*, field.name));
            }
        }

        fn unionWire(comptime members_id: @FieldType(Shape, "union_type"), value: *Wire) void {
            switch (decodeUnionTag(id, value.tag)) {
                inline else => |tag| destroy(Manifest.positionMembers(members_id)[@backingInt(tag) - 1].value).transfer(&@field(value.payload, @tagName(tag))),
            }
        }

        fn collectionWire(comptime child: @TypeOf(id), value: *Wire) void {
            const items = wireSlice([]wireType(Manifest.get(child).wire), value.*);
            for (items) |*item| destroy(child).transfer(item);
            if (comptime @TypeOf(id).role != .outbound_argument) transfer_allocator.free(items);
        }

        fn recordWire(comptime entry: @FieldType(Shape, "record_entry"), value: *Wire) void {
            destroy(entry.key).transfer(&value.key);
            destroy(entry.value).transfer(&value.value);
        }
    };
}

fn releaseTransferSlice(comptime element: anytype, storage: []wireType(Manifest.get(element).wire), start: usize, end: usize) void {
    for (storage[start..end]) |*item| destroy(element).transfer(item);
    transfer_allocator.free(storage);
}

fn clone(comptime id: ir.InboundArgumentPlanId) type {
    const position = Manifest.get(id);
    const plan = if (position.zig.clone) |cloner| cloner else @compileError("binding position cannot be cloned into owning storage");
    const Source = wireType(position.wire);
    const Wire = wireType(Manifest.get(plan.target).wire);
    return struct {
        pub const target = plan.target;
        pub const Error = if (plan.raises_exception) bun.JSError else bun.OOM;

        fn copy(value: Source, context: anytype) Error!Wire {
            return switch (position.representation) {
                .leaf => leaf: {
                    const native = decode(id).wire(value, context) catch |err| switch (err) {};
                    if (comptime plan.leaf.? == .engine_value) break :leaf @backingInt(native.rawValue());
                    const owned = switch (plan.leaf.?) {
                        .value => native,
                        .retain => native.toOwned(),
                        .allocate => try native.toOwned(),
                        .engine_value => unreachable,
                    };
                    break :leaf encode(target).wire(&owned, context) catch |err| switch (err) {};
                },
                .converted => |conversion| try clone(conversion.apiValue()).copy(value, context),
                .optional => |child| if (decodeWirePresence(value.present)) .{
                    .present = 1,
                    .value = try clone(child).copy(value.value, context),
                } else std.mem.zeroes(Wire),
                .dictionary => |fields_id| dictionary: {
                    const fields = Manifest.positionFields(fields_id);
                    var result: Wire = std.mem.zeroes(Wire);
                    var initialized: usize = 0;
                    errdefer inline for (fields, 0..) |field, index| {
                        if (index < initialized and (!field.optional or decodeWirePresence(@field(result, field.name ++ "_present")))) destroy(clone(field.value).target).transfer(&@field(result, field.name));
                    };
                    inline for (fields) |field| {
                        const present = !field.optional or decodeWirePresence(@field(value, field.name ++ "_present"));
                        if (present) @field(result, field.name) = try clone(field.value).copy(@field(value, field.name), context);
                        if (field.optional) @field(result, field.name ++ "_present") = @intFromBool(present);
                        initialized += 1;
                    }
                    break :dictionary result;
                },
                .union_type => |members_id| switch (decodeUnionTag(id, value.tag)) {
                    inline else => |tag| .{
                        .tag = @backingInt(tag),
                        .payload = @unionInit(@FieldType(Wire, "payload"), @tagName(tag), try clone(Manifest.positionMembers(members_id)[@backingInt(tag) - 1].value).copy(@field(value.payload, @tagName(tag)), context)),
                    },
                },
                .record_entry => |entry| record: {
                    var key = try clone(entry.key).copy(value.key, context);
                    errdefer destroy(clone(entry.key).target).transfer(&key);
                    break :record .{ .key = key, .value = try clone(entry.value).copy(value.value, context) };
                },
                inline else => |child| slice: {
                    const source = wireSlice([]const wireType(Manifest.get(child).wire), value);
                    if (source.len == 0) break :slice .{ .ptr = null, .len = 0 };
                    const Child = wireType(Manifest.get(clone(child).target).wire);
                    const items = try transferAlloc(Child, value.len);
                    var initialized: usize = 0;
                    errdefer releaseTransferSlice(clone(child).target, items, 0, initialized);
                    for (items, 0..) |*item, index| {
                        item.* = try clone(child).copy(source[index], context);
                        initialized += 1;
                    }
                    break :slice .{ .ptr = items.ptr, .len = items.len };
                },
            };
        }
    };
}

fn FailureTagType(comptime Function: type) type {
    const Cached = struct {
        const result = value: {
            @setEvalBranchQuota(api_eval_branch_quota);
            if (Function.domain_errors.len == 0) break :value void;
            var names: [Function.domain_errors.len][]const u8 = undefined;
            var values: [Function.domain_errors.len]u8 = undefined;
            for (Function.domain_errors, 0..) |DomainError, i| {
                names[i] = DomainError.error_name;
                values[i] = i + 1;
            }
            break :value @Enum(u8, .exhaustive, &names, &values);
        };
    };
    return Cached.result;
}

fn DomainFailureStorage(comptime Function: type) type {
    const Cached = struct {
        const result = value: {
            @setEvalBranchQuota(api_eval_branch_quota);
            if (Function.domain_errors.len == 0) break :value struct {
                payload: ?void = null,
            };
            const Tag = FailureTagType(Function);
            const names = @typeInfo(Tag).@"enum".field_names;
            var types: [Function.domain_errors.len]type = undefined;
            for (Function.domain_errors, &types) |DomainError, *T| {
                T.* = @FieldType(@FieldType(wireType(Function.wire_result), "payload"), "error_" ++ DomainError.error_name);
            }
            const Payload = @Union(.auto, Tag, names, &types, &@splat(.{}));
            const Result_ = struct {
                payload: ?Payload = null,

                fn commit(
                    failure: *@This(),
                    comptime tag: FailureTagType(Function),
                    payload: FailurePayloadApiType(Function, tag),
                ) DomainFailure {
                    if (failure.payload != null) @panic("binding domain failure was committed twice");
                    const DomainError = domainErrorForTag(Function, tag);
                    const encoded = encodeResultValue(DomainError.position, payload);
                    failure.payload = @unionInit(Payload, DomainError.error_name, encoded);
                    return error.BindgenDomainFailure;
                }
            };
            break :value Result_;
        };
    };
    return Cached.result;
}

fn FailurePayloadApiType(comptime Function: type, comptime tag: FailureTagType(Function)) type {
    return Api(domainErrorForTag(Function, tag).position);
}

fn domainErrorForTag(comptime Function: type, comptime tag: FailureTagType(Function)) type {
    const value = @backingInt(tag);
    if (value == 0 or value > Function.domain_errors.len)
        @compileError("binding domain-error tag is not declared by this function");
    return Function.domain_errors[value - 1];
}

fn wireType(comptime id: ir.WireTypeId) type {
    const description = Manifest.binding().wire_types[id.index];
    return switch (description) {
        .opaque_handle, .forward_structure => |name| @field(wire, name.comptimeName()),
        inline .alias, .structure, .@"union", .function_pointer => |declaration| @field(wire, declaration.name.comptimeName()),
        .function => |function| @TypeOf(@field(wire, function.name.comptimeName())),
        .scalar => |scalar| scalar.zigType(),
        .pointer => |pointer| pointer_type: {
            const Child = wireType(pointer.child);
            const Pointee = if (Child == void) anyopaque else Child;
            const attributes: std.lang.Type.Pointer.Attributes = .{ .@"const" = pointer.is_const };
            break :pointer_type if (@typeInfo(Pointee) == .@"opaque")
                ?@Pointer(.one, attributes, Pointee, null)
            else
                @Pointer(.c, attributes, Pointee, null);
        },
    };
}

fn NativeSlice(comptime element: ir.NativeSliceElement, comptime access: ir.BufferAccess) type {
    const Element = NativeElement(element);
    return if (access == .read_write) []Element else []const Element;
}

fn NativeElement(comptime element: ir.NativeSliceElement) type {
    return switch (element) {
        .uint8 => u8,
        .uint16 => u16,
        .uint32 => u32,
        .uint64 => u64,
    };
}

fn decodeArgs(
    comptime Function: type,
    wire_args: *const wireType(Function.wire_args),
    global: if (Function.call_plan.realm == .current) *jsc.JSGlobalObject else @TypeOf(null),
    token: ViewToken,
) ArgsType(Function) {
    const context = .{ .global = global, .token = token };
    var result: ArgsType(Function) = undefined;
    inline for (Function.invocation_args ++ Function.args) |Argument| {
        const name = Argument.argument_name;
        const id = comptime Argument.value_position;
        @field(result, name) = if (Argument.optional and !decodeWirePresence(@field(wire_args, name ++ "_present")))
            null
        else
            decode(id).wire(@field(wire_args, name), context) catch |err| switch (err) {};
    }
    return result;
}

fn encodeResultValue(comptime position: ir.InboundResultPlanId, value: Api(position)) if (Api(position) == void) u8 else wireType(Manifest.get(position).wire) {
    if (comptime Api(position) == void) return 0;
    return encode(position).wire(&value, .{}) catch |err| switch (err) {};
}

fn encodeResult(comptime Function: type, value: Api(Function.result_position)) wireType(Function.wire_result) {
    const WireResult = wireType(Function.wire_result);
    const Result = Api(Function.result_position);
    const encoded = encodeResultValue(Function.result_position, value);
    if (Function.domain_errors.len == 0) {
        if (comptime Result == void) return .{ ._reserved = 0 };
        return .{ .value = encoded };
    }
    return .{ .tag = 0, .payload = @unionInit(@FieldType(WireResult, "payload"), "value", encoded) };
}

fn encodeFailure(
    comptime Function: type,
    comptime tag: FailureTagType(Function),
    payload: FailurePayloadApiType(Function, tag),
) wireType(Function.wire_result) {
    const DomainError = domainErrorForTag(Function, tag);
    const WireResult = wireType(Function.wire_result);
    const encoded = encodeResultValue(DomainError.position, payload);
    return .{
        .tag = @backingInt(tag),
        .payload = @unionInit(
            @FieldType(WireResult, "payload"),
            "error_" ++ DomainError.error_name,
            encoded,
        ),
    };
}

fn commitDomainFailure(
    comptime Function: type,
    failure: anytype,
) wireType(Function.wire_result) {
    if (comptime Function.domain_errors.len == 0) @panic("binding committed an undeclared domain failure");
    const payload = failure.payload orelse @panic("binding domain failure has no payload");
    return switch (payload) {
        inline else => |value, tag| .{
            .tag = @backingInt(tag),
            .payload = @unionInit(@FieldType(wireType(Function.wire_result), "payload"), "error_" ++ @tagName(tag), value),
        },
    };
}

fn isMovedWireHandle(handle: anytype) bool {
    return @intFromPtr(handle) == 1;
}

fn poisonMovedWire(value: anytype) void {
    if (comptime bun.Environment.allow_assert) {
        @memset(std.mem.asBytes(value), 0xA5);
    } else {
        value.* = std.mem.zeroes(@TypeOf(value.*));
    }
}

fn destroyResultPayload(comptime Function: type, result: *wireType(Function.wire_result)) void {
    const Result = Api(Function.result_position);
    if (Function.domain_errors.len == 0) {
        if (comptime Result != void) destroy(Function.result_position).transfer(&result.value);
    } else if (result.tag == 0) {
        if (comptime Result != void) destroy(Function.result_position).transfer(&result.payload.value);
    } else {
        inline for (Function.domain_errors, 1..) |DomainError, tag| {
            if (result.tag == tag) {
                if (comptime Api(DomainError.position) != void) destroy(DomainError.position).transfer(&@field(result.payload, "error_" ++ DomainError.error_name));
                result.* = std.mem.zeroes(@TypeOf(result.*));
                return;
            }
        }
        @panic("binding result has an unknown domain-error tag");
    }
    result.* = std.mem.zeroes(@TypeOf(result.*));
}

fn LeaseArgumentType(comptime Type: type) type {
    return if (Type.buffer_access == .read_write) ScopedMutableLease(u8) else ScopedLease(u8);
}

fn LeaseResultType(comptime Type: type) type {
    return if (Type.buffer_access == .read_write) OwnedMutableLease(u8) else OwnedLease(u8);
}

fn currentTarget() ir.Target {
    return switch (builtin.cpu.arch) {
        .x86_64 => switch (builtin.os.tag) {
            .linux => .x86_64_linux,
            .macos => .x86_64_macos,
            .windows => .x86_64_windows,
            else => @compileError("unsupported binding target"),
        },
        .aarch64 => switch (builtin.os.tag) {
            .linux => .aarch64_linux,
            .macos => .aarch64_macos,
            .windows => .aarch64_windows,
            else => @compileError("unsupported binding target"),
        },
        else => @compileError("unsupported binding architecture"),
    };
}
