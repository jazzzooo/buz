const BindingEscape = bun.bindgen.Escape(@This());
pub const JSGlobalObject = opaque {
    pub fn allocator(this: *JSGlobalObject) std.mem.Allocator {
        return this.bunVM().allocator;
    }
    pub fn throwStackOverflow(this: *JSGlobalObject) bun.JSError {
        bun.bindgen.Engine(ThrowStackOverflowSchema).call(this, .{}) catch return error.JSError;
        unreachable;
    }
    pub fn throwOutOfMemory(this: *JSGlobalObject) bun.JSError {
        bun.bindgen.Engine(ThrowOutOfMemorySchema).call(this, .{}) catch return error.JSError;
        unreachable;
    }

    /// Raises an out-of-memory exception without returning an error, for
    /// sentinel-based paths that report the exception through other means.
    pub fn reportOutOfMemory(this: *JSGlobalObject) void {
        bun.bindgen.Engine(ThrowOutOfMemorySchema).call(this, .{}) catch {};
    }

    pub fn gregorianDateTimeToMS(this: *jsc.JSGlobalObject, year: i32, month: i32, day: i32, hour: i32, minute: i32, second: i32, millisecond: i32) bun.JSError!f64 {
        return bun.bindgen.Engine(GregorianDateTimeToMSShim).call(this, .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .millisecond = millisecond,
            .localTime = true,
        });
    }

    pub fn throwTODO(this: *JSGlobalObject, msg: []const u8) bun.JSError {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this);
        defer scope.deinit();
        var message = try bun.bindgen.DOMString.fromUTF8(msg);
        defer message.deinit();
        const err = try scope.engineIn("errors", "createError").call(.{ .message = message.operand() });
        var name = try bun.bindgen.DOMString.fromUTF8("TODOError");
        defer name.deinit();
        try scope.engineIn("errors", "errorSetName").call(.{ .errorValue = err.operand(&scope).asEngine(), .name = name.operand() });
        return err.throwException(&scope);
    }

    pub fn clearTerminationException(this: *JSGlobalObject) void {
        bun.bindgen.Engine(GlobalObjectClearTerminationExceptionSchema).call(this, .{});
    }

    pub fn setTimeZone(this: *JSGlobalObject, time_zone: []const u8) bun.JSError!bool {
        var bound_time_zone = try bun.bindgen.DOMString.fromUTF8(time_zone);
        defer bound_time_zone.deinit();
        return bun.bindgen.Engine(SetTimeZoneShim).call(this, .{ .timeZone = bound_time_zone.operand() });
    }

    pub fn throwInvalidArguments(this: *JSGlobalObject, comptime fmt: [:0]const u8, args: anytype) bun.JSError {
        return this.throwNodeError(.ERR_INVALID_ARG_TYPE, fmt, args);
    }

    /// "Expected {field} to be a {typename} for '{name}'."
    pub fn throwInvalidArgumentType(
        this: *JSGlobalObject,
        comptime name_: []const u8,
        comptime field: []const u8,
        comptime typename: []const u8,
    ) bun.JSError {
        return this.throwNodeError(.ERR_INVALID_ARG_TYPE, comptime std.fmt.comptimePrint("Expected {s} to be a {s} for '{s}'.", .{ field, typename, name_ }), .{});
    }

    pub fn determineSpecificType(global: *JSGlobalObject, value: JSValue) JSError!String {
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        var result = try engine_scope.engine(DetermineSpecificTypeShim).call(.{ .value = BindingEscape.borrowEngineValue(&engine_scope, value) });
        defer result.deinit();
        return result.takeBunString();
    }

    /// Not enough arguments passed to function named `name_`
    pub fn throwNotEnoughArguments(
        this: *JSGlobalObject,
        comptime name_: []const u8,
        comptime expected: usize,
        got: usize,
    ) bun.JSError {
        return this.throwNodeError(.ERR_MISSING_ARGS, "Not enough arguments to '" ++ name_ ++ "'. Expected {d}, got {d}.", .{ expected, got });
    }

    pub fn reload(this: *jsc.JSGlobalObject) !void {
        this.vm().drainMicrotasks();
        this.vm().collectAsync();
        try bun.bindgen.Engine(ReloadGlobalObjectShim).call(this, .{});
    }

    pub fn formatErrorMessage(
        this: *JSGlobalObject,
        comptime fmt: []const u8,
        args: anytype,
    ) bun.JSError!bun.bindgen.DOMString {
        switch (this.pendingExceptionKind()) {
            .none => {},
            .other => return error.JSError,
            .termination => return error.JSTerminated,
        }
        if (comptime std.meta.fieldNames(@TypeOf(args)).len == 0) {
            return bun.bindgen.DOMString.fromUTF8(fmt);
        }
        var stack_buffer: [4096]u8 = undefined;
        var message_allocator: std.heap.BufferFirstAllocator = .init(&stack_buffer, this.allocator());
        var output = try std.Io.Writer.Allocating.initCapacity(message_allocator.allocator(), 2048);
        defer output.deinit();
        output.writer.print(fmt, args) catch {
            switch (this.pendingExceptionKind()) {
                .none => return error.OutOfMemory,
                .other => return error.JSError,
                .termination => return error.JSTerminated,
            }
        };
        switch (this.pendingExceptionKind()) {
            .none => {},
            .other => return error.JSError,
            .termination => return error.JSTerminated,
        }
        return bun.bindgen.DOMString.fromUTF8(output.written());
    }

    fn throwFormattedError(
        this: *JSGlobalObject,
        comptime operation: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) bun.JSError {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this);
        defer scope.deinit();
        var message = try this.formatErrorMessage(fmt, args);
        defer message.deinit();
        const result = try scope.engineIn("errors", operation).call(.{ .message = message.operand() });
        return result.throwException(&scope);
    }

    pub const SysErrOptions = struct {
        code: jsc.Node.ErrorCode,
        errno: ?i32 = null,
        name: ?string = null,
    };
    pub fn throwSysError(
        this: *JSGlobalObject,
        opts: SysErrOptions,
        comptime message: [:0]const u8,
        args: anytype,
    ) JSError {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this);
        defer scope.deinit();
        var formatted = try this.formatErrorMessage(message, args);
        defer formatted.deinit();
        const err = try scope.engineIn("errors", "createError").call(.{ .message = formatted.operand() });
        var code = try bun.bindgen.DOMString.fromUTF8(@tagName(opts.code));
        defer code.deinit();
        try scope.engineIn("errors", "errorSetCode").call(.{ .errorValue = err.operand(&scope).asEngine(), .code = code.operand() });
        if (opts.name) |value| {
            var name = try bun.bindgen.DOMString.fromUTF8(value);
            defer name.deinit();
            try scope.engineIn("errors", "errorSetName").call(.{ .errorValue = err.operand(&scope).asEngine(), .name = name.operand() });
        }
        if (opts.errno) |errno| scope.engineIn("errors", "errorSetErrno").call(.{ .errorValue = err.operand(&scope).asEngine(), .errorNumber = errno });
        return err.throwException(&scope);
    }

    /// Throw an Error from a formatted string.
    ///
    pub fn throw(this: *JSGlobalObject, comptime fmt: [:0]const u8, args: anytype) JSError {
        return this.throwFormattedError("createError", fmt, args);
    }

    pub fn throwPretty(this: *JSGlobalObject, comptime fmt: [:0]const u8, args: anytype) bun.JSError {
        return switch (Output.enable_ansi_colors_stderr) {
            inline else => |enabled| this.throw(Output.prettyFmt(fmt, enabled), args),
        };
    }

    pub fn queueMicrotaskTask(this: *JSGlobalObject, task: *jsc.NativeMicrotask) bun.JSError!void {
        const Operation = bun.bindgen.Engine(QueueMicrotaskTaskShim);
        var args: bun.bindgen.Args(QueueMicrotaskTaskShim) = .{ .task = .initNative(task) };
        try Operation.call(this, &args);
    }

    fn bindRunQueuedMicrotask(
        _: bun.bindgen.CallContext(RunQueuedMicrotaskSchema),
        args: bun.bindgen.Args(RunQueuedMicrotaskSchema),
    ) bun.JSError!bun.bindgen.Return(RunQueuedMicrotaskSchema) {
        try args.task.run();
    }

    fn bindDiscardQueuedMicrotask(
        args: *bun.bindgen.Args(DiscardQueuedMicrotaskSchema),
    ) bun.bindgen.Return(DiscardQueuedMicrotaskSchema) {
        args.task.takeNative().destroy();
    }

    pub fn queueMicrotask(this: *JSGlobalObject, function: JSValue, args: []const jsc.JSValue) void {
        this.queueMicrotaskJob(
            function,
            if (args.len > 0) args[0] else null,
            if (args.len > 1) args[1] else null,
        );
    }

    pub fn queueMicrotaskJob(this: *JSGlobalObject, function: JSValue, first: ?JSValue, second: ?JSValue) void {
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(this);
        defer engine_scope.deinit();
        engine_scope.engine(QueueMicrotaskJobShim).call(.{
            .function = BindingEscape.borrowEngineValue(&engine_scope, function),
            .first = first,
            .second = second,
        }) catch unreachable;
    }

    pub fn throwValue(this: *JSGlobalObject, value: jsc.JSValue) JSError {
        switch (this.pendingExceptionKind()) {
            .none => {},
            .other => return error.JSError,
            .termination => return error.JSTerminated,
        }
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(this);
        defer engine_scope.deinit();
        engine_scope.engine(ThrowValueSchema).call(.{ .value = BindingEscape.borrowEngineValue(&engine_scope, value) }) catch |err| return err;
        @panic("throw-value operation returned without an exception");
    }

    pub fn throwTypeError(this: *JSGlobalObject, comptime fmt: [:0]const u8, args: anytype) bun.JSError {
        return this.throwFormattedError("createTypeError", fmt, args);
    }

    pub fn throwError(this: *JSGlobalObject, err: anyerror, comptime fmt: [:0]const u8) bun.JSError {
        switch (err) {
            error.OutOfMemory => return this.throwOutOfMemory(),
            error.JSError => return error.JSError,
            error.JSTerminated => return error.JSTerminated,
            else => {},
        }
        return this.throw(comptime "{s} " ++ fmt, .{@errorName(err)});
    }

    pub fn hasException(this: *JSGlobalObject) bool {
        return bun.bindgen.Engine(GlobalObjectHasExceptionSchema).call(this, .{});
    }

    pub fn hasExceptionIncludingTraps(this: *JSGlobalObject) bool {
        return bun.bindgen.Engine(GlobalObjectHasExceptionIncludingTrapsSchema).call(this, .{});
    }

    pub fn pendingExceptionKind(this: *JSGlobalObject) bun.bindgen.Return(GlobalObjectPendingExceptionKindSchema) {
        return bun.bindgen.Engine(GlobalObjectPendingExceptionKindSchema).call(this, .{});
    }

    pub fn clearException(this: *JSGlobalObject) void {
        bun.bindgen.Engine(GlobalObjectClearExceptionSchema).call(this, .{});
    }

    /// Clear the currently active exception off the VM unless it is a
    /// termination exception.
    ///
    /// Returns `true` if the exception was cleared, `false` if it was a
    /// termination exception. Use `clearException` to unconditionally clear
    /// exceptions.
    ///
    /// It is safe to call this function when no exception is present.
    pub fn clearExceptionExceptTermination(this: *JSGlobalObject) bool {
        return bun.bindgen.Engine(GlobalObjectClearExceptionExceptTerminationSchema).call(this, .{});
    }

    /// Adapts a JavaScript-aware formatter to Zig's `std.Io.Writer` formatter contract.
    /// The pending engine exception preserves the cause through Writer's narrower error set.
    pub fn formatErrorToWriterError(this: *JSGlobalObject, err: bun.JSError) std.Io.Writer.Error {
        bun.bindgen.voidFromJSError(err, this);
        return error.WriteFailed;
    }

    /// This is for the common scenario you are calling into JavaScript, but there is
    /// no logical way to handle a thrown exception other than to treat it as unhandled.
    ///
    /// The pattern:
    ///
    ///     const result = value.call(...) catch |err|
    ///         return global.reportActiveExceptionAsUnhandled(err);
    ///
    pub fn reportActiveExceptionAsUnhandled(this: *JSGlobalObject, err: bun.JSError) void {
        this.reportUncaughtExceptionFromError(err);
    }

    pub fn vm(this: *JSGlobalObject) *VM {
        return @ptrCast(bun.bindgen.Engine(GlobalObjectVMSchema).call(.{ .global = @ptrCast(this) }));
    }

    pub fn deleteModuleRegistryEntry(this: *JSGlobalObject, name_: []const u8) bun.JSError!void {
        var name = try bun.bindgen.DOMString.fromUTF8(name_);
        defer name.deinit();
        return bun.bindgen.Engine(DeleteModuleRegistryEntryShim).call(this, .{ .name = name.operand() });
    }

    fn bunVMUnsafe(this: *JSGlobalObject) *anyopaque {
        return @ptrCast(bun.bindgen.Engine(GlobalObjectBunVMSchema).call(.{ .global = @ptrCast(this) }));
    }

    pub fn bunVM(this: *JSGlobalObject) *jsc.VirtualMachine {
        if (comptime bun.Environment.allow_assert) {
            // if this fails
            // you most likely need to run
            //   make clean-jsc-bindings
            //   make bindings -j10
            if (jsc.VirtualMachine.VMHolder.vm) |vm_| {
                bun.assert(this.bunVMUnsafe() == @as(*anyopaque, @ptrCast(vm_)));
            } else {
                @panic("This thread lacks a Bun VM");
            }
        }
        return @as(*jsc.VirtualMachine, @ptrCast(@alignCast(this.bunVMUnsafe())));
    }

    pub const ThreadKind = enum {
        main,
        other,
    };

    pub fn tryBunVM(this: *JSGlobalObject) struct { *jsc.VirtualMachine, ThreadKind } {
        const vmPtr = @as(*jsc.VirtualMachine, @ptrCast(@alignCast(this.bunVMUnsafe())));

        if (jsc.VirtualMachine.VMHolder.vm) |vm_| {
            if (comptime bun.Environment.allow_assert) {
                bun.assert(this.bunVMUnsafe() == @as(*anyopaque, @ptrCast(vm_)));
            }
        } else {
            return .{ vmPtr, .other };
        }

        return .{ vmPtr, .main };
    }

    /// We can't do the threadlocal check when queued from another thread
    pub fn bunVMConcurrently(this: *JSGlobalObject) *jsc.VirtualMachine {
        return @as(*jsc.VirtualMachine, @ptrCast(@alignCast(this.bunVMUnsafe())));
    }

    pub fn handleRejectedPromises(this: *JSGlobalObject) void {
        bun.bindgen.Engine(HandleRejectedPromisesShim).call(this, .{}) catch return;
    }

    pub fn throwRangeError(this: *JSGlobalObject, value: anytype, options: bun.fmt.OutOfRangeOptions) bun.JSError {
        return this.throwNodeError(.ERR_OUT_OF_RANGE, "{f}", .{bun.fmt.outOfRange(value, options)});
    }

    pub fn createNodeError(global: *JSGlobalObject, code: jsc.NodeError.Code, comptime fmt: []const u8, args: anytype) bun.JSError!JSValue {
        var message = try global.formatErrorMessage(fmt, args);
        defer message.deinit();
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        var result = try jsc.NodeError.create(&scope, code, &message);
        defer result.deinit();
        return BindingEscape.borrowResultValue(&scope, &result);
    }

    pub fn throwNodeError(global: *JSGlobalObject, code: jsc.NodeError.Code, comptime fmt: []const u8, args: anytype) bun.JSError {
        return global.throwValue(try global.createNodeError(code, fmt, args));
    }

    pub fn create(
        v: *jsc.VirtualMachine,
        context_id: i32,
        mini_mode: bool,
        eval_mode: bool,
        worker_ptr: ?*anyopaque,
    ) *JSGlobalObject {
        const trace = bun.perf.trace("JSGlobalObject.create");
        defer trace.end();

        v.eventLoop().ensureWaker();
        const global: *JSGlobalObject = @ptrCast(bun.bindgen.Engine(GlobalObjectCreateSchema).call(.{
            .context_id = context_id,
            .mini_mode = mini_mode,
            .eval_mode = eval_mode,
            .worker = if (worker_ptr) |worker| @ptrCast(worker) else null,
        }));

        // JSC might mess with the stack size.
        bun.StackCheck.configureThread();

        return global;
    }

    pub fn createForTestIsolation(old_global: *JSGlobalObject) *JSGlobalObject {
        return @ptrCast(bun.bindgen.Engine(GlobalObjectCreateForTestIsolationSchema).call(.{
            .old_global = @ptrCast(old_global),
        }));
    }

    fn bindModuleLoaderResolve(
        context: bun.bindgen.CallContext(ModuleLoaderResolveSchema),
        args: bun.bindgen.Args(ModuleLoaderResolveSchema),
    ) bun.JSError!bun.bindgen.Return(ModuleLoaderResolveSchema) {
        var bound_specifier = args.specifier.toOwned();
        defer bound_specifier.deinit();
        const specifier = bound_specifier.takeBunString();
        defer specifier.deref();
        var bound_source = args.source.toOwned();
        defer bound_source.deinit();
        const source = bound_source.takeBunString();
        defer source.deref();

        return bun.bindgen.DOMString.fromBunString(try jsc.VirtualMachine.resolveModuleSpecifier(
            context.viewToken().globalObject(),
            specifier,
            source,
            true,
            true,
            false,
        ));
    }

    pub fn reportUncaughtExceptionFromError(global: *JSGlobalObject, proof: bun.JSError) void {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        _ = scope.reportPendingException(proof) catch return;
    }

    fn bindOnCrash(
        args: bun.bindgen.Args(GlobalObjectOnCrashSchema),
    ) bun.bindgen.Return(GlobalObjectOnCrashSchema) {
        _ = args;
        bun.Output.flush();
        @panic("A C++ exception occurred");
    }

    pub fn getBodyStreamOrBytesForWasmStreaming(
        this: *JSGlobalObject,
        response: *jsc.WebCore.Response,
        streaming_compiler: *jsc.WasmStreamingCompilerHandle,
    ) bun.JSError!?jsc.WebCore.ReadableStream.Owned {
        var content_type_slice: bun.String.Slice = .empty;
        defer content_type_slice.deinit();
        const content_type: bun.TextView = if (try response.getContentType()) |slice| content_type: {
            content_type_slice = slice;
            break :content_type .{ .utf8 = slice.slice() };
        } else .{ .latin1 = "null" };

        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type_slice.slice(), " \t"), "application/wasm")) {
            return this.throwNodeError(.ERR_WEBASSEMBLY_RESPONSE, "WebAssembly response has unsupported MIME type '{f}'", .{content_type});
        }

        if (!response.isOK()) {
            return this.throwNodeError(.ERR_WEBASSEMBLY_RESPONSE, "WebAssembly response has status code {}", .{response.statusCode()});
        }

        if (try response.getBodyUsed(this)) {
            return this.throwNodeError(.ERR_WEBASSEMBLY_RESPONSE, "WebAssembly response body has already been used", .{});
        }

        const body = response.getBodyValue();
        if (body.* == .Error) {
            var reason = try body.Error.toRoot(this);
            defer reason.deinit();
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(this);
            defer scope.deinit();
            return reason.throwException(&scope);
        }

        // We're done validating. From now on, deal with extracting the body.
        try body.toBlobIfPossible();

        if (body.* == .Locked) {
            if (try response.getBodyReadableStream(this)) |stream_value| {
                var stream = stream_value;
                defer stream.deinit();
                return stream.cloneOwned();
            }
        }

        var any_blob = switch (body.*) {
            .Locked => (try body.tryUseAsAnyBlob()) orelse return try body.toReadableStream(this),
            else => try body.useAsAnyBlob(),
        };
        defer any_blob.detach();

        if (any_blob.store()) |store| {
            if (store.data != .bytes) {
                // This is a file or an S3 object, which aren't accessible synchronously.
                // (using any_blob.slice() would return a bogus empty slice)

                // Logic from JSC.WebCore.Body.Value.toReadableStream
                var blob = try any_blob.intoBlob();
                defer blob.deinit();

                blob.resolveSize();
                return try jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(this, &blob, blob.size);
            }
        }

        // Push the blob contents into the streaming compiler by passing a pointer and
        // length, and return null to signify this has been done.
        const slice = any_blob.slice();
        bun.bindgen.Engine(WasmStreamingCompilerAddBytesSchema).call(.{
            .compiler = streaming_compiler,
            .bytes = bun.bindgen.BytesOperand.fromSlice(slice),
        });

        return null;
    }

    fn bindGetBodyStreamOrBytesForWasmStreaming(
        context: bun.bindgen.CallContext(GetBodyStreamOrBytesForWasmStreamingSchema),
        args: bun.bindgen.Args(GetBodyStreamOrBytesForWasmStreamingSchema),
    ) bun.JSError!bun.bindgen.Return(GetBodyStreamOrBytesForWasmStreamingSchema) {
        const global = context.viewToken().globalObject();
        var stream = try global.getBodyStreamOrBytesForWasmStreaming(
            args.source.get(jsc.WebCore.Response),
            args.compiler,
        ) orelse return null;
        defer stream.deinit();
        return stream.toResult(context);
    }

    pub fn scriptExecutionContextIdentifier(global: *jsc.JSGlobalObject) ScriptExecutionContext.Identifier {
        return @fromBackingInt(bun.bindgen.Engine(ScriptExecutionContextIdentifierShim).call(global, .{}) catch unreachable);
    }

    comptime {
        _ = ModuleLoaderResolveBinding;
        _ = GlobalObjectOnCrashBinding;
        _ = GetBodyStreamOrBytesForWasmStreamingBinding;
        _ = RunQueuedMicrotaskBinding;
    }
};

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const ScriptExecutionContext = @import("../runtime/webcore/ScriptExecutionContext.zig");
const JSError = bun.JSError;
const MutableString = bun.MutableString;
const Output = bun.Output;
const String = bun.String;
const strings = bun.strings;

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
const VM = jsc.VM;
const CrashHandlerBindings = bun.bindgen.Module("CrashHandlerBindings");
const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const MicrotasksBindings = bun.bindgen.Module("microtasks");
const ErrorBindings = bun.bindgen.Module("errors");
const JSValueInspectionBindings = bun.bindgen.Module("js_value_inspection");
const DateTimeBindings = bun.bindgen.Module("date_time");
const ProcessHostBindings = bun.bindgen.Module("ProcessHost");
const VirtualMachineBindings = bun.bindgen.Module("virtual_machine");
const GlobalObjectBindings = bun.bindgen.Module("global_objects");
const ThrowValueSchema = GlobalObjectBindings.engineShim("globalObjectThrowValue");
const QueueMicrotaskJobShim = MicrotasksBindings.engineShim("queueMicrotaskJob");
const QueueMicrotaskTaskShim = MicrotasksBindings.engineShim("queueMicrotaskTask");
const DeleteModuleRegistryEntryShim = ModuleLoaderBindings.engineShim("deleteModuleRegistryEntry");
const SetTimeZoneShim = DateTimeBindings.engineShim("setTimeZone");
const ScriptExecutionContextIdentifierShim = GlobalObjectBindings.engineShim("scriptExecutionContextIdentifier");
const HandleRejectedPromisesShim = MicrotasksBindings.engineShim("handleRejectedPromises");
const GlobalObjectVMSchema = VirtualMachineBindings.engineShim("globalObjectVM");
const GlobalObjectBunVMSchema = VirtualMachineBindings.engineShim("globalObjectBunVM");
const ThrowStackOverflowSchema = ErrorBindings.engineShim("throwStackOverflow");
const ThrowOutOfMemorySchema = ErrorBindings.engineShim("throwOutOfMemory");
const ReloadGlobalObjectShim = GlobalObjectBindings.engineShim("reloadGlobalObject");
const GregorianDateTimeToMSShim = DateTimeBindings.engineShim("gregorianDateTimeToMS");
const GlobalObjectHasExceptionSchema = ErrorBindings.engineShim("globalObjectHasException");
const GlobalObjectHasExceptionIncludingTrapsSchema = ErrorBindings.engineShim("globalObjectHasExceptionIncludingTraps");
const GlobalObjectPendingExceptionKindSchema = ErrorBindings.engineShim("globalObjectPendingExceptionKind");
const GlobalObjectClearExceptionSchema = ErrorBindings.engineShim("globalObjectClearException");
const GlobalObjectClearExceptionExceptTerminationSchema = ErrorBindings.engineShim("globalObjectClearExceptionExceptTermination");
const GlobalObjectClearTerminationExceptionSchema = ErrorBindings.engineShim("globalObjectClearTerminationException");
const GlobalObjectCreateSchema = GlobalObjectBindings.engineShim("globalObjectCreate");
const GlobalObjectCreateForTestIsolationSchema = GlobalObjectBindings.engineShim("globalObjectCreateForTestIsolation");
const WasmStreamingEngineBindings = bun.bindgen.Module("WasmStreamingEngine");
const WasmStreamingCompilerAddBytesSchema = WasmStreamingEngineBindings.engineShim("wasmStreamingCompilerAddBytes");
const GetBodyStreamOrBytesForWasmStreamingSchema = WasmStreamingEngineBindings.nativeExport("getBodyStreamOrBytesForWasmStreaming");
const GetBodyStreamOrBytesForWasmStreamingBinding = bun.bindgen.Fn(
    GetBodyStreamOrBytesForWasmStreamingSchema,
    JSGlobalObject.bindGetBodyStreamOrBytesForWasmStreaming,
);
const ModuleLoaderResolveSchema = ModuleLoaderBindings.nativeExport("moduleLoaderResolve");
const ModuleLoaderResolveBinding = bun.bindgen.Fn(ModuleLoaderResolveSchema, JSGlobalObject.bindModuleLoaderResolve);
const GlobalObjectOnCrashSchema = CrashHandlerBindings.nativeExport("globalObjectOnCrash");
const GlobalObjectOnCrashBinding = bun.bindgen.Fn(GlobalObjectOnCrashSchema, JSGlobalObject.bindOnCrash);
const RunQueuedMicrotaskSchema = MicrotasksBindings.nativeExport("runQueuedMicrotask");
const RunQueuedMicrotaskBinding = bun.bindgen.Fn(RunQueuedMicrotaskSchema, JSGlobalObject.bindRunQueuedMicrotask);
const DiscardQueuedMicrotaskSchema = MicrotasksBindings.nativeExport("discardQueuedMicrotask");
const DiscardQueuedMicrotaskBinding = bun.bindgen.Fn(DiscardQueuedMicrotaskSchema, JSGlobalObject.bindDiscardQueuedMicrotask);

comptime {
    _ = GetBodyStreamOrBytesForWasmStreamingBinding;
    _ = ModuleLoaderResolveBinding;
    _ = GlobalObjectOnCrashBinding;
    _ = RunQueuedMicrotaskBinding;
    _ = DiscardQueuedMicrotaskBinding;
}

const DetermineSpecificTypeShim = JSValueInspectionBindings.engineShim("determineSpecificType");
