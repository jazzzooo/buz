fn runtimeFailure(context: anytype, message: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    const payload = bindgen.DOMString.fromUTF8(message) catch return error.OutOfMemory;
    return context.fail(.runtime_failure, payload);
}

fn asyncRuntimeFailure(context: anytype, message: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    const payload = bindgen.ThreadSafeDOMString.fromUTF8(message) catch return error.OutOfMemory;
    return context.fail(.runtime_failure, payload);
}

pub fn add(context: bindgen.CallContext(AddSchema), args: bindgen.Args(AddSchema)) bindgen.CallError(AddSchema)!i32 {
    return std.math.add(i32, args.a, args.b) catch {
        return runtimeFailure(context, "Integer overflow while adding");
    };
}

fn multiplyAdd(args: bindgen.Args(MultiplyAddSchema)) bindgen.Return(MultiplyAddSchema) {
    return args.a *% args.b +% args.bias;
}

fn nativeLazyStringLength(
    context: bindgen.CallContext(NativeLazyStringLengthSchema),
    args: bindgen.Args(NativeLazyStringLengthSchema),
) bun.JSError!usize {
    const first = try context.engineIn("bindgen_test", "forceCoercedLazyString").call(.{ .input = args.input.operand(context) });
    const converted = try args.input.convert(context);
    const second = try context.engineIn("bindgen_test", "forceCoercedLazyString").call(.{ .input = args.input.operand(context) });
    std.debug.assert(first == converted.value.length() and second == first);
    return first;
}

fn nativeStringBufferHandle(
    args: bindgen.Args(NativeStringBufferHandleSchema),
) bindgen.Return(NativeStringBufferHandleSchema) {
    std.mem.doNotOptimizeAway(args.input);
    std.mem.doNotOptimizeAway(args.handle);
    return args.label.toOwned();
}

fn optionalNativeString(
    args: bindgen.Args(OptionalNativeStringSchema),
) bindgen.Return(OptionalNativeStringSchema) {
    return if (args.input) |input| input.toOwned() else null;
}

fn nativeCallbackRecord(
    context: bindgen.CallContext(NativeCallbackRecordSchema),
    args: bindgen.Args(NativeCallbackRecordSchema),
) bun.JSError!bindgen.Return(NativeCallbackRecordSchema) {
    _ = context;
    const Result = bindgen.Return(NativeCallbackRecordSchema);
    var builder = try Result.Builder.init(2);
    errdefer builder.deinit();
    for ([_][]const u8{ "first", "second" }) |label| {
        var key = try bindgen.DOMString.fromUTF8(label);
        errdefer key.deinit();
        var callback = try (try args.factory.call(.{})).toOwned();
        errdefer callback.deinit();
        var bytes = try args.input.toOwned();
        errdefer bytes.deinit();
        builder.appendOwned(.{ .key = key, .value = .{ .callback = callback, .bytes = bytes } });
    }
    return builder.finish();
}

pub fn retainCallbackRecord(
    context: bindgen.CallContext(RetainCallbackRecordSchema),
    args: bindgen.Args(RetainCallbackRecordSchema),
) bun.JSError!bindgen.Return(RetainCallbackRecordSchema) {
    _ = context;
    return (try args.factory.call(.{})).take();
}

pub fn inspectCallbackRecordViews(
    context: bindgen.CallContext(InspectCallbackRecordViewsSchema),
    args: bindgen.Args(InspectCallbackRecordViewsSchema),
) bun.JSError!i32 {
    bindgen.testing.setSnapshotAllocationFailureCountdown(if (args.failAfter) |count| @as(usize, count) else null);
    defer bindgen.testing.setSnapshotAllocationFailureCountdown(null);
    var values = (try args.factory.call(.{})).take();
    defer values.deinit();
    var iterator = values.iterator();
    var result: i32 = 0;
    while (try iterator.next()) |entry| {
        var item = entry;
        defer item.deinit();
        result += try item.value.callback.call(context, .{});
    }
    return result;
}

fn nativeStringSequenceLength(
    context: bindgen.CallContext(NativeStringSequenceLengthSchema),
    args: bindgen.Args(NativeStringSequenceLengthSchema),
) bun.JSError!bindgen.Return(NativeStringSequenceLengthSchema) {
    _ = context;
    return args.values.len();
}

pub fn echoInt8(context: bindgen.CallContext(EchoInt8Schema), args: bindgen.Args(EchoInt8Schema)) bun.JSError!i8 {
    _ = context;
    return args.input;
}

pub fn echoInt16(context: bindgen.CallContext(EchoInt16Schema), args: bindgen.Args(EchoInt16Schema)) bun.JSError!i16 {
    _ = context;
    return args.input;
}

pub fn echoUint16(context: bindgen.CallContext(EchoUint16Schema), args: bindgen.Args(EchoUint16Schema)) bun.JSError!u16 {
    _ = context;
    return args.input;
}

pub fn echoUint32(context: bindgen.CallContext(EchoUint32Schema), args: bindgen.Args(EchoUint32Schema)) bun.JSError!u32 {
    _ = context;
    return args.input;
}

pub fn echoInt64(context: bindgen.CallContext(EchoInt64Schema), args: bindgen.Args(EchoInt64Schema)) bun.JSError!i64 {
    _ = context;
    return args.input;
}

pub fn echoUint64(context: bindgen.CallContext(EchoUint64Schema), args: bindgen.Args(EchoUint64Schema)) bun.JSError!u64 {
    _ = context;
    return args.input;
}

pub fn echoTestOptions(
    context: bindgen.CallContext(EchoTestOptionsSchema),
    args: bindgen.Args(EchoTestOptionsSchema),
) bun.JSError!bindgen.Return(EchoTestOptionsSchema) {
    _ = context;
    return .{
        .count = args.options.count,
        .label = if (args.options.label) |label| label.toOwned() else null,
        .enabled = args.options.enabled,
        .metadata = .{
            .mode = args.options.metadata.mode,
            .note = if (args.options.metadata.note) |note| note.toOwned() else null,
        },
        .bytes = if (args.options.bytes) |bytes| try bytes.toOwned() else null,
    };
}

pub fn echoDictionarySource(
    context: bindgen.CallContext(EchoDictionarySourceSchema),
    args: bindgen.Args(EchoDictionarySourceSchema),
) bun.JSError!bindgen.Return(EchoDictionarySourceSchema) {
    _ = context;
    return args.input.source.toResult();
}

pub fn echoTestScalars(
    context: bindgen.CallContext(EchoTestScalarsSchema),
    args: bindgen.Args(EchoTestScalarsSchema),
) bun.JSError!bindgen.Return(EchoTestScalarsSchema) {
    _ = context;
    return try args.input.toFunctionResult();
}

pub fn roundTripTestBundle(
    context: bindgen.CallContext(RoundTripTestBundleSchema),
    args: bindgen.Args(RoundTripTestBundleSchema),
) bun.JSError!bindgen.Return(RoundTripTestBundleSchema) {
    _ = context;
    var note = if (args.input.metadata.note) |value| value.toOwned() else null;
    errdefer if (note) |*value| value.deinit();
    var scalars = try args.input.scalars.toFunctionResult();
    errdefer scalars.deinit();
    const lookup = try args.input.lookup.toFunctionResult();
    return .{
        .metadata = .{
            .mode = args.input.metadata.mode,
            .note = note,
        },
        .scalars = scalars,
        .lookup = lookup,
    };
}

const TestBundleView = @FieldType(bindgen.Args(RoundTripTestBundleSchema), "input");
const TestBundleOperand = @FieldType(bindgen.Args(bindgen.CallbackSchema("BindgenTestBundleVisitor")), "bundle");

fn testScalarOperand(value: @FieldType(TestBundleView, "scalars").ElementView) std.meta.Elem(@FieldType(TestBundleOperand, "scalars")) {
    return switch (value) {
        .integer => |number| .{ .integer = number },
        .text => |text| .{ .text = text.operand() },
        .flag => |flag| .{ .flag = flag },
    };
}

pub fn visitTestBundle(
    _: bindgen.CallContext(VisitTestBundleSchema),
    args: bindgen.Args(VisitTestBundleSchema),
) bun.JSError!i32 {
    const allocator = bun.default_allocator;
    const scalars = try allocator.alloc(std.meta.Elem(@FieldType(TestBundleOperand, "scalars")), args.input.scalars.len());
    defer allocator.free(scalars);
    for (scalars, 0..) |*value, index| value.* = testScalarOperand(args.input.scalars.at(index).?);
    const entries = try allocator.alloc(std.meta.Elem(@FieldType(TestBundleOperand, "lookup")), args.input.lookup.len());
    defer allocator.free(entries);
    for (entries, 0..) |*entry, index| {
        const input = args.input.lookup.at(index).?;
        entry.* = .{ .key = input.key.operand(), .value = testScalarOperand(input.value) };
    }
    return args.visitor.call(.{ .bundle = .{
        .metadata = .{ .mode = args.input.metadata.mode, .note = if (args.input.metadata.note) |note| note.operand() else null },
        .scalars = scalars,
        .lookup = entries,
    } });
}

pub fn dispatchAdvanced(
    context: bindgen.CallContext(DispatchAdvancedSchema),
    args: bindgen.Args(DispatchAdvancedSchema),
) bun.JSError!i32 {
    return switch (args) {
        .bytes => |values| @intCast(values.input.length() * 100 + values.label.length()),
        .iterable => |values| blk: {
            if (values.trigger) |trigger| try trigger.call(.{});
            const first = try context.engineIn("bindgen_test", "forceLazyIterable").call(.{ .input = values.input.operand(context) });
            const converted = try values.input.convert(context);
            const length = if (converted.value) |items| items.len() else 0;
            const second = try context.engineIn("bindgen_test", "forceLazyIterable").call(.{ .input = values.input.operand(context) });
            std.debug.assert(first == length and second == length);
            break :blk @intCast(length * 100 + values.label.length());
        },
        .options => |values| blk: {
            if (values.trigger) |trigger| try trigger.call(.{});
            break :blk values.input.count * 100 + @as(i32, @intCast(values.label.length()));
        },
    };
}

pub fn inspectNodeConversionOrder(
    context: bindgen.CallContext(InspectNodeConversionOrderSchema),
    args: bindgen.Args(InspectNodeConversionOrderSchema),
) bun.JSError!i32 {
    _ = context;
    return switch (args) {
        .options => |values| values.input.port + @as(i32, @intCast(values.input.hostname.length())),
        .fallback => -1,
    };
}

pub fn inspectCustomConverters(
    context: bindgen.CallContext(InspectCustomConvertersSchema),
    args: bindgen.Args(InspectCustomConvertersSchema),
) bun.JSError!i32 {
    _ = context;
    var result: i32 = 0;
    for (0..args.numbers.len()) |index| result += args.numbers.at(index).? * 10_000;
    if (args.nullableLabel) |label| result += @intCast(label.length() * 1_000);
    if (args.optionalLabel) |label| result += @intCast(label.length() * 100);
    result += @intCast(args.defaultLabel.length());
    return result;
}

pub fn requiredAndOptionalArg(
    context: bindgen.CallContext(RequiredAndOptionalArgSchema),
    args: bindgen.Args(RequiredAndOptionalArgSchema),
) bun.JSError!i32 {
    _ = context;
    const b_nonnull = args.b orelse {
        return (123456 +% args.c) +% (args.d orelse 0);
    };
    var math_result: i32 = @truncate(@as(isize, @as(u53, @truncate(
        (b_nonnull +% @as(usize, @abs(args.c))) *% (args.d orelse 1),
    ))));
    if (args.a) {
        math_result = -math_result;
    }
    return math_result;
}

pub fn domStringLength(
    context: bindgen.CallContext(DOMStringLengthSchema),
    args: bindgen.Args(DOMStringLengthSchema),
) bun.JSError!usize {
    _ = context;
    return args.input.length();
}

pub fn echoDOMString(
    context: bindgen.CallContext(EchoDOMStringSchema),
    args: bindgen.Args(EchoDOMStringSchema),
) bun.JSError!bindgen.DOMString {
    _ = context;
    return args.input.toOwned();
}

pub fn isolateEngineString(
    _: bindgen.CallContext(IsolateEngineStringSchema),
    args: bindgen.Args(IsolateEngineStringSchema),
) bun.JSError!bindgen.DOMString {
    var input = args.input.toOwned();
    defer input.deinit();
    var isolated = try input.toThreadSafe();
    defer isolated.deinit();
    var retained = isolated.clone();
    const source = retained.takeBunString();
    defer source.deref();
    var result = try bindgen.Engine(BindingModule.engineShim("isolatedStringResult")).call(.{
        .input = isolated.operand(),
        .fail = args.fail,
    });
    const output = result.takeBunString();
    if (!source.isEmpty()) {
        std.debug.assert(output.value.WTFStringImpl != source.value.WTFStringImpl);
        std.debug.assert(output.value.WTFStringImpl.isThreadSafe());
    }
    return bindgen.DOMString.fromBunString(output);
}

pub fn echoUSVString(
    context: bindgen.CallContext(EchoUSVStringSchema),
    args: bindgen.Args(EchoUSVStringSchema),
) bun.JSError!bindgen.USVString {
    _ = context;
    return args.input.toOwned();
}

pub fn echoByteString(
    context: bindgen.CallContext(EchoByteStringSchema),
    args: bindgen.Args(EchoByteStringSchema),
) bun.JSError!bindgen.ByteString {
    _ = context;
    return args.input.toOwned();
}

pub fn strictUSVString(
    context: bindgen.CallContext(StrictUSVStringSchema),
    args: bindgen.Args(StrictUSVStringSchema),
) bun.JSError!bindgen.USVString {
    _ = context;
    return args.input.toOwned();
}

pub fn strictByteString(
    context: bindgen.CallContext(StrictByteStringSchema),
    args: bindgen.Args(StrictByteStringSchema),
) bun.JSError!bindgen.ByteString {
    _ = context;
    return args.input.toOwned();
}

pub fn echoBuffer(
    context: bindgen.CallContext(EchoBufferSchema),
    args: bindgen.Args(EchoBufferSchema),
) bun.JSError!bindgen.OwnedBytes {
    _ = context;
    return try args.input.copy();
}

pub fn fillMutableLease(
    context: bindgen.CallContext(FillMutableLeaseSchema),
    args: bindgen.Args(FillMutableLeaseSchema),
) bun.JSError!void {
    _ = context;
    var owned = try args.input.toOwned();
    defer owned.deinit();
    const bytes = owned.unsafeMutPtr("the owned mutable lease remains alive until mutation completes");
    @memset(bytes, args.value);
}

pub fn setMutableLeaseByte(
    context: bindgen.CallContext(SetMutableLeaseByteSchema),
    args: bindgen.Args(SetMutableLeaseByteSchema),
) bun.JSError!void {
    _ = context;
    var owned = try args.input.toOwned();
    defer owned.deinit();
    const bytes = owned.unsafeMutPtr("the owned mutable lease remains alive until mutation completes");
    const index: usize = args.index;
    if (index < bytes.len) bytes[index] = args.value;
}

pub fn inspectInt32FromJS(
    context: bindgen.CallContext(InspectInt32FromJSSchema),
    args: bindgen.Args(InspectInt32FromJSSchema),
) bun.JSError!i32 {
    const converted = try args.input.convert(context);
    return converted.value;
}

pub fn inspectLeaseOptionsFromJS(
    context: bindgen.CallContext(InspectLeaseOptionsFromJSSchema),
    args: bindgen.Args(InspectLeaseOptionsFromJSSchema),
) bun.JSError!i32 {
    const forced = try args.input.convertLast(context);
    try context.lease(forced.proof);
    const length = forced.converted.value.bytes.length();
    if (length == 0) return 0;
    return @as(i32, forced.converted.value.bytes.at(0).?) * 256 + forced.converted.value.bytes.at(length - 1).?;
}

pub fn inspectLazyOptions(
    context: bindgen.CallContext(InspectLazyOptionsSchema),
    args: bindgen.Args(InspectLazyOptionsSchema),
) bun.JSError!i32 {
    if (!args.shouldConvert) return -1;
    const converted = try args.input.convert(context);
    const label_length: usize = if (converted.value.label) |label| label.length() else 0;
    return @intCast(@as(usize, @intCast(converted.value.count)) + label_length);
}

pub fn inspectLazyConvertedLabel(
    context: bindgen.CallContext(InspectLazyConvertedLabelSchema),
    args: bindgen.Args(InspectLazyConvertedLabelSchema),
) bun.JSError!usize {
    const converted = try args.input.convert(context);
    return converted.value.length();
}

pub fn inspectLazyReceiverIndex(
    context: bindgen.CallContext(InspectLazyReceiverIndexSchema),
    args: bindgen.Args(InspectLazyReceiverIndexSchema),
) bun.JSError!usize {
    try args.trigger.call(.{});
    return (try args.index.convert(context)).value;
}

pub fn inspectLazyRestLease(
    context: bindgen.CallContext(InspectLazyRestLeaseSchema),
    args: bindgen.Args(InspectLazyRestLeaseSchema),
) bun.JSError!usize {
    const count = args.values.len();
    if (count == 0) return args.bytes.at(0) orelse 0;
    try args.trigger.call(.{});
    var length: usize = 0;
    for (0..count - 1) |index| {
        const value = try args.values.convert(index, context);
        length += value.value.length();
        _ = try args.values.convert(index, context);
    }
    if (args.discardLast) {
        try context.lease(try args.values.discardLast(count - 1, context));
    } else {
        const last = try args.values.convertLast(count - 1, context);
        length += last.converted.value.length();
        try context.lease(last.proof);
    }
    return length + (args.bytes.at(0) orelse 0);
}

pub fn retryLazyString(
    context: bindgen.CallContext(RetryLazyStringSchema),
    args: bindgen.Args(RetryLazyStringSchema),
) bun.JSError!usize {
    const first = context.engineIn("bindgen_test", "forceLazyString").call(.{ .input = args.input.operand(context) }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (!context.engineIn("errors", "globalObjectClearExceptionExceptTermination").call(.{})) return err;
        return (try args.input.convert(context)).value.length();
    };
    const second = try args.input.convert(context);
    _ = try context.engineIn("bindgen_test", "forceLazyString").call(.{ .input = args.input.operand(context) });
    return first + second.value.length();
}

pub fn callbackIdentityAfterReentry(
    context: bindgen.CallContext(CallbackIdentityAfterReentrySchema),
    args: bindgen.Args(CallbackIdentityAfterReentrySchema),
) bun.JSError!bool {
    var stored = try args.first.toOwned();
    defer stored.deinit();
    try args.changeContext.call(.{});
    const second = try args.second.convert(context);
    const same = stored.sameViewIdentity(second.value);
    try stored.call(context, .{});
    try second.value.call(.{});
    return same;
}

pub fn inspectLeaseAfterCallback(
    context: bindgen.CallContext(InspectLeaseAfterCallbackSchema),
    args: bindgen.Args(InspectLeaseAfterCallbackSchema),
) bun.JSError!i32 {
    _ = context;
    const length = args.input.length();
    try args.callback.call(.{ .value = @intCast(@min(length, std.math.maxInt(i32))) });
    const first = args.input.at(0) orelse 0;
    const last = if (length > 0) args.input.at(length - 1) orelse 0 else 0;
    return @as(i32, first) * 256 + last;
}

pub fn inspectNestedLeaseAfterCallback(
    context: bindgen.CallContext(InspectNestedLeaseAfterCallbackSchema),
    args: bindgen.Args(InspectNestedLeaseAfterCallbackSchema),
) bun.JSError!i32 {
    _ = context;
    return switch (args.input) {
        .bytes => |input| result: {
            const length = input.length();
            try args.callback.call(.{ .value = @intCast(@min(length, std.math.maxInt(i32))) });
            const first = input.at(0) orelse 0;
            const last = if (length > 0) input.at(length - 1) orelse 0 else 0;
            break :result @as(i32, first) * 256 + last;
        },
        .text => |input| result: {
            const length = input.length();
            try args.callback.call(.{ .value = @intCast(@min(length, std.math.maxInt(i32))) });
            break :result @intCast(@min(length, std.math.maxInt(i32)));
        },
    };
}

pub fn echoNullableBuffer(
    context: bindgen.CallContext(EchoNullableBufferSchema),
    args: bindgen.Args(EchoNullableBufferSchema),
) bun.JSError!?bindgen.OwnedBytes {
    _ = context;
    const input = args.input orelse return null;
    return try input.toOwned();
}

pub fn echoAny(
    context: bindgen.CallContext(EchoAnySchema),
    args: bindgen.Args(EchoAnySchema),
) bun.JSError!bindgen.Return(EchoAnySchema) {
    _ = context;
    return args.input.toResult();
}

pub fn preserveTransferredRoot(
    context: bindgen.CallContext(PreserveTransferredRootSchema),
    args: bindgen.Args(PreserveTransferredRootSchema),
) bun.JSError!bindgen.Return(PreserveTransferredRootSchema) {
    var root = try args.input.toRoot();
    defer root.deinit();
    var clone = root.clone();
    defer clone.deinit();
    var handle = try context.engineIn("bindgen_test", "createTransferHandle").call(.{});
    defer handle.deinit();
    const consume = context.engineIn("bindgen_test", "consumeTransferredValue");
    var transferred: @TypeOf(consume).Args = .{ .input = .{
        .handle = handle.take(),
        .value = bindgen.EngineValueResult.fromOwnedRoot(&clone, context),
    } };
    try consume.call(&transferred);
    try args.collect.call(.{});
    return bindgen.EngineValueResult.fromOwnedRoot(&root, context);
}

pub fn snapshotStoredRoots(
    context: bindgen.CallContext(SnapshotStoredRootsSchema),
    args: bindgen.Args(SnapshotStoredRootsSchema),
) bun.JSError!bindgen.Return(SnapshotStoredRootsSchema) {
    bindgen.testing.setSnapshotAllocationFailureCountdown(if (args.failAfter) |count| @as(usize, count) else null);
    defer bindgen.testing.setSnapshotAllocationFailureCountdown(null);
    var root = try args.input.toRoot();
    defer root.deinit();
    const root_view = try root.view(context);
    root.deinit();

    var optional: bindgen.Root.Optional = .empty;
    defer optional.deinit();
    try optional.set(args.input.operand(context));
    const optional_view = (try optional.view(context)).?;
    optional.clear();
    var cleared_clone = optional.clone();
    defer cleared_clone.deinit();

    var engine: bindgen.EngineRoot.Optional = .empty;
    defer engine.deinit();
    try engine.set(args.engine.operand(context));
    const engine_view = (try engine.engineView(context)).?;
    engine.clear();
    var cleared_engine_clone = engine.clone();
    defer cleared_engine_clone.deinit();

    var promise: bindgen.PromiseRoot.Optional = .empty;
    defer promise.deinit();
    try promise.set(args.promise.operand(context).asPromise());
    const promise_view = (try promise.view(context)).?;
    promise.clear();

    const cleared = !optional.has() and !cleared_clone.has() and
        (try optional.view(context)) == null and optional.toResult(context) == null and
        !engine.has() and !cleared_engine_clone.has() and
        (try engine.engineView(context)) == null and engine.toResult(context) == null and
        !promise.has() and (try promise.view(context)) == null and (try promise.toPromiseResult(context)) == null;

    try optional.set(args.replacement.operand(context));
    try engine.set(args.engine.operand(context));
    try promise.set(args.promise.operand(context).asPromise());
    const reused = optional.has() and engine.has() and promise.has();
    const replacement_view = (try optional.view(context)).?;
    optional.deinit();
    engine.deinit();
    promise.deinit();
    var collect = try args.collect.toOwned();
    defer collect.deinit();
    const collect_view = try collect.view(context);
    collect.deinit();
    try collect_view.call(.{});

    return .{
        .root = root_view.toResult(),
        .optional = optional_view.toResult(),
        .engine = engine_view.toResult(),
        .promise = promise_view.toResult(),
        .replacement = replacement_view.toResult(),
        .cleared = cleared,
        .reused = reused,
    };
}

pub fn readIndexViaEngine(
    context: bindgen.CallContext(ReadIndexViaEngineSchema),
    args: bindgen.Args(ReadIndexViaEngineSchema),
) bun.JSError!bindgen.Return(ReadIndexViaEngineSchema) {
    return context.engineIn("bindgen_test", "getIndex").call(.{
        .target = args.target.operand(context),
        .index = args.index,
    });
}

pub fn sumIntegerWidthsViaEngine(
    context: bindgen.CallContext(SumIntegerWidthsViaEngineSchema),
    args: bindgen.Args(SumIntegerWidthsViaEngineSchema),
) bun.JSError!i64 {
    return context.engineIn("bindgen_test", "sumIntegerWidths").call(.{
        .signed8 = args.signed8,
        .signed16 = args.signed16,
        .unsigned16 = args.unsigned16,
        .unsigned32 = args.unsigned32,
        .signed64 = args.signed64,
        .unsigned64 = args.unsigned64,
    });
}

pub fn engineBufferSequenceLengthViaEngine(
    context: bindgen.CallContext(EngineBufferSequenceLengthViaEngineSchema),
    args: bindgen.Args(EngineBufferSequenceLengthViaEngineSchema),
) bun.JSError!usize {
    _ = args;
    var buffers = try context.engineIn("bindgen_test", "bufferSequence").call(.{});
    defer buffers.deinit();
    var total: usize = 0;
    var iterator = buffers.iterator();
    while (iterator.next()) |converted_| {
        var converted = converted_;
        defer converted.deinit();
        total +|= converted.value.length();
    }
    return total;
}

pub fn nodePathLengthViaEngine(
    context: bindgen.CallContext(NodePathLengthViaEngineSchema),
    args: bindgen.Args(NodePathLengthViaEngineSchema),
) bun.JSError!usize {
    return context.engineIn("bindgen_test", "nodePathLength").call(.{
        .input = args.input.operand(),
    });
}

pub fn invocationThis(
    _: bindgen.CallContext(InvocationThisSchema),
    args: bindgen.Args(InvocationThisSchema),
) bun.JSError!bindgen.Return(InvocationThisSchema) {
    return args.bindingThis.toResult();
}

pub fn visitGCEntries(
    context: bindgen.CallContext(VisitGCEntriesSchema),
    args: bindgen.Args(VisitGCEntriesSchema),
) bun.JSError!i32 {
    return visitEntries(context, args.entries);
}

pub fn visitDeferredGCEntries(
    context: bindgen.CallContext(VisitDeferredGCEntriesSchema),
    args: bindgen.Args(VisitDeferredGCEntriesSchema),
) bun.JSError!i32 {
    const first = try args.entries.convert(context);
    if (args.ignored) |ignored| try ignored.discard(context);
    const last = try args.trigger.convertLast(context);
    try context.lease(last.proof);
    const first_result = try visitEntries(context, first.value);
    const second = try args.entries.convert(context);
    return first_result +% try visitEntries(context, second.value);
}

pub fn leaseWithIgnoredOperand(
    context: bindgen.CallContext(LeaseWithIgnoredOperandSchema),
    args: bindgen.Args(LeaseWithIgnoredOperandSchema),
) bun.JSError!u8 {
    if (args.before) |before| {
        _ = try context.engineIn("bindgen_test", "forceCoercedLazyString").call(.{ .input = before.operand(context) });
        _ = try context.engineIn("bindgen_test", "forceCoercedLazyString").call(.{ .input = before.operand(context) });
        _ = try before.convert(context);
    }
    try context.lease(try args.ignored.discardLast(context));
    return args.input.at(0) orelse 0;
}

pub fn inspectNestedLazyFields(
    context: bindgen.CallContext(InspectNestedLazyFieldsSchema),
    args: bindgen.Args(InspectNestedLazyFieldsSchema),
) bun.JSError!i32 {
    try args.trigger.call(.{});
    const input = try args.input.convert(context);
    return inspectLazyFields(context, input.value, args.bytes);
}

pub fn inspectEagerLazyFields(
    context: bindgen.CallContext(InspectEagerLazyFieldsSchema),
    args: bindgen.Args(InspectEagerLazyFieldsSchema),
) bun.JSError!i32 {
    return inspectLazyFields(context, args.input, args.bytes);
}

fn inspectLazyFields(context: anytype, input: anytype, bytes: anytype) bun.JSError!i32 {
    const options = try input.options.convert(context);
    const items = try options.value.items.convert(context);
    const length = context.engineIn("bindgen_test", "forceCoercedLazyString").call(.{ .input = options.value.label.operand(context) }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (!context.engineIn("errors", "globalObjectClearExceptionExceptTermination").call(.{})) return err;
        _ = try options.value.label.convert(context);
        @panic("a failed lazy field conversion was not cached");
    };
    const label = try options.value.label.convert(context);
    std.debug.assert(length == label.value.length());
    _ = try input.options.convert(context);
    _ = try options.value.items.convert(context);
    try context.lease(try options.value.ignored.discardLast(context));
    var result: i32 = @intCast(length + (bytes.at(0) orelse 0));
    for (0..items.value.len()) |index| result +%= items.value.at(index).?;
    return result;
}

pub fn inspectNestedLazyRest(
    context: bindgen.CallContext(InspectNestedLazyRestSchema),
    args: bindgen.Args(InspectNestedLazyRestSchema),
) bun.JSError!i32 {
    var result: i32 = 0;
    for (0..args.values.len()) |index| {
        const input = try args.values.convert(index, context);
        const options = try input.value.options.convert(context);
        const items = try options.value.items.convert(context);
        const label = try options.value.label.convert(context);
        result +%= @intCast(label.value.length());
        for (0..items.value.len()) |item| result +%= items.value.at(item).?;
        _ = try args.values.convert(index, context);
    }
    return result;
}

pub fn forceLazyPath(
    context: bindgen.CallContext(ForceLazyPathSchema),
    args: bindgen.Args(ForceLazyPathSchema),
) bun.JSError!usize {
    if (args.absolute) {
        const leaf = try args.options.absolute.convert(context);
        return leaf.value.text.length();
    }
    const leaf = try args.options.relative.convert(context);
    return leaf.value.text.length();
}

pub fn describePatternValues(
    _: bindgen.CallContext(DescribePatternValuesSchema),
    args: bindgen.Args(DescribePatternValuesSchema),
) bun.JSError!bindgen.DOMString {
    const allocator = bun.default_allocator;
    var description: std.ArrayList(u8) = .empty;
    defer description.deinit(allocator);
    for (0..args.values.len()) |index| {
        if (index != 0) try description.append(allocator, ' ');
        switch (args.values.at(index).?) {
            .flag => |flag| try description.print(allocator, "flag:{s}", .{if (flag) "true" else "false"}),
            .nested => |nested| switch (nested) {
                .text => |text| try description.print(allocator, "text:{d}", .{text.length()}),
                .number => |number| try description.print(allocator, "number:{d}", .{number}),
            },
        }
    }
    return bindgen.DOMString.fromUTF8(description.items);
}

fn visitEntries(context: anytype, entries: anytype) bun.JSError!i32 {
    var result: i32 = 0;
    for (0..entries.len()) |index| {
        const entry = entries.at(index).?;
        result +%= try entry.callback.call(.{ .value = entry.value.operand(context) });
        result +%= @as(i32, entry.bytes.at(0) orelse 0);
    }
    return result;
}

pub fn invokeCallback(
    context: bindgen.CallContext(InvokeCallbackSchema),
    args: bindgen.Args(InvokeCallbackSchema),
) bun.JSError!i32 {
    _ = context;
    var label = args.label.toOwned();
    defer label.deinit();
    return args.callback.call(.{
        .value = args.value,
        .label = label.operand(),
    });
}

pub fn invokeOwnedCallback(
    context: bindgen.CallContext(InvokeOwnedCallbackSchema),
    args: bindgen.Args(InvokeOwnedCallbackSchema),
) bun.JSError!i32 {
    var callback = try args.callback.toOwned();
    defer callback.deinit();
    var label = args.label.toOwned();
    defer label.deinit();
    return callback.call(context, .{
        .value = args.value,
        .label = label.operand(),
    });
}

pub fn echoCallback(
    context: bindgen.CallContext(EchoCallbackSchema),
    args: bindgen.Args(EchoCallbackSchema),
) bun.JSError!bindgen.Return(EchoCallbackSchema) {
    _ = context;
    return args.callback.toOwned();
}

pub fn scheduleCallback(context: bindgen.CallContext(ScheduleCallbackSchema), args: bindgen.Args(ScheduleCallbackSchema)) bun.JSError!void {
    try args.callback.schedule(.{
        .bindingThis = args.receiver.operand(context),
        .value = args.value.operand(context),
    });
}

pub fn invokeStringCallback(
    context: bindgen.CallContext(InvokeStringCallbackSchema),
    args: bindgen.Args(InvokeStringCallbackSchema),
) bun.JSError!bindgen.USVString {
    _ = context;
    var input = args.input.toOwned();
    defer input.deinit();
    return args.callback.call(.{ .input = input.operand() });
}

pub fn invokeNullableStringCallback(
    context: bindgen.CallContext(InvokeNullableStringCallbackSchema),
    args: bindgen.Args(InvokeNullableStringCallbackSchema),
) bun.JSError!?bindgen.DOMString {
    _ = context;
    var input: ?bindgen.DOMString = if (args.input) |value| value.toOwned() else null;
    defer if (input) |*value| value.deinit();
    return args.callback.call(.{ .input = if (input) |*value| value.operand() else null });
}

pub fn invokeBufferCallback(
    context: bindgen.CallContext(InvokeBufferCallbackSchema),
    args: bindgen.Args(InvokeBufferCallbackSchema),
) bun.JSError!bindgen.OwnedBytes {
    _ = context;
    var input = try args.input.toOwned();
    defer input.deinit();
    return args.callback.call(.{ .input = input.operand() });
}

pub fn invokeAnyCallback(
    context: bindgen.CallContext(InvokeAnyCallbackSchema),
    args: bindgen.Args(InvokeAnyCallbackSchema),
) bun.JSError!bindgen.Return(InvokeAnyCallbackSchema) {
    return args.callback.call(.{ .input = args.input.operand(context) });
}

pub fn invokeCompositeCallback(
    context: bindgen.CallContext(InvokeCompositeCallbackSchema),
    args: bindgen.Args(InvokeCompositeCallbackSchema),
) bun.JSError!bindgen.Return(InvokeCompositeCallbackSchema) {
    _ = context;
    var value = try args.callback.call(.{});
    errdefer bindgen.deinitReturn(@TypeOf(args.callback).SemanticType, &value);
    var observer = try value.observer.toOwned();
    errdefer observer.deinit();
    return .{
        .choice = switch (value.choice) {
            .counter => |counter| .{ .counter = try counter.toOwned() },
            .number => |number| .{ .number = number },
        },
        .labels = value.labels,
        .value = value.value,
        .observer = observer,
        .label = value.label,
    };
}

pub fn invokeRestCallback(
    context: bindgen.CallContext(InvokeRestCallbackSchema),
    args: bindgen.Args(InvokeRestCallbackSchema),
) bun.JSError!i32 {
    const values = try bun.default_allocator.alloc(bindgen.AnyOperand, args.values.length());
    defer bun.default_allocator.free(values);
    for (values, 0..) |*value, index| value.* = args.values.at(index).?.operand(context);
    return args.callback.call(.{ .prefix = args.prefix, .values = values });
}

pub fn invokeTypedRestCallback(
    context: bindgen.CallContext(InvokeTypedRestCallbackSchema),
    args: bindgen.Args(InvokeTypedRestCallbackSchema),
) bun.JSError!i32 {
    _ = context;
    const values = try bun.default_allocator.alloc(i32, args.values.len());
    defer bun.default_allocator.free(values);
    for (values, 0..) |*value, index| value.* = args.values.at(index).?;
    return args.callback.call(.{ .prefix = args.prefix, .values = values });
}

pub fn invokeCallbackFactory(
    context: bindgen.CallContext(InvokeCallbackFactorySchema),
    args: bindgen.Args(InvokeCallbackFactorySchema),
) bun.JSError!i32 {
    _ = context;
    const callback = try args.factory.call(.{});
    var label = args.label.toOwned();
    defer label.deinit();
    return callback.call(.{
        .value = args.value,
        .label = label.operand(),
    });
}

pub fn invokeObserver(
    context: bindgen.CallContext(InvokeObserverSchema),
    args: bindgen.Args(InvokeObserverSchema),
) bun.JSError!void {
    _ = context;
    try args.callback.call(.{ .value = args.value });
}

pub fn invokeIntegerCallback(
    context: bindgen.CallContext(InvokeIntegerCallbackSchema),
    args: bindgen.Args(InvokeIntegerCallbackSchema),
) bun.JSError!u64 {
    _ = context;
    return args.callback.call(.{
        .signed8 = args.signed8,
        .signed16 = args.signed16,
        .unsigned16 = args.unsigned16,
        .unsigned32 = args.unsigned32,
        .signed64 = args.signed64,
        .unsigned64 = args.unsigned64,
    });
}

pub fn clampInteger(
    context: bindgen.CallContext(ClampIntegerSchema),
    args: bindgen.Args(ClampIntegerSchema),
) bun.JSError!i32 {
    _ = context;
    return args.input;
}

pub fn validateInteger(
    context: bindgen.CallContext(ValidateIntegerSchema),
    args: bindgen.Args(ValidateIntegerSchema),
) bun.JSError!i32 {
    _ = context;
    return args.input;
}

pub fn validateNodeBoolean(
    context: bindgen.CallContext(ValidateNodeBooleanSchema),
    args: bindgen.Args(ValidateNodeBooleanSchema),
) bun.JSError!bool {
    _ = context;
    return args.input;
}

pub fn validateNodeNumber(
    context: bindgen.CallContext(ValidateNodeNumberSchema),
    args: bindgen.Args(ValidateNodeNumberSchema),
) bun.JSError!f64 {
    _ = context;
    return args.input;
}

pub fn validateNodeString(
    context: bindgen.CallContext(ValidateNodeStringSchema),
    args: bindgen.Args(ValidateNodeStringSchema),
) bun.JSError!usize {
    _ = context;
    return args.input.length();
}

pub fn validateNodeStrings(
    context: bindgen.CallContext(ValidateNodeStringsSchema),
    args: bindgen.Args(ValidateNodeStringsSchema),
) bun.JSError!usize {
    _ = context;
    return args.input.len();
}

pub fn defaultString(
    context: bindgen.CallContext(DefaultStringSchema),
    args: bindgen.Args(DefaultStringSchema),
) bun.JSError!bindgen.DOMString {
    _ = context;
    return args.input.toOwned();
}

pub fn defaultAny(
    context: bindgen.CallContext(DefaultAnySchema),
    args: bindgen.Args(DefaultAnySchema),
) bun.JSError!bindgen.Return(DefaultAnySchema) {
    _ = context;
    return args.input.toResult();
}

pub fn classifyPresence(
    context: bindgen.CallContext(ClassifyPresenceSchema),
    args: bindgen.Args(ClassifyPresenceSchema),
) bun.JSError!bindgen.DOMString {
    _ = context;
    const input = args.input orelse return bindgen.DOMString.fromUTF8("missing");
    return bindgen.DOMString.fromUTF8(switch (input) {
        .undefined => "undefined",
        .nulled => "null",
        .boolean, .other => "value",
    });
}

pub fn inspectRest(
    context: bindgen.CallContext(InspectRestSchema),
    args: bindgen.Args(InspectRestSchema),
) bun.JSError!i32 {
    var result = args.prefix +% (@as(i32, @intCast(args.values.len())) *% 1000);
    if (args.values.len() > 0) {
        const converted = try args.values.convert(0, context);
        if (converted.value == .undefined) result +%= 100;
    }
    if (args.values.len() > 1) {
        const converted = try args.values.convert(1, context);
        if (converted.value == .nulled) result +%= 10;
    }
    if (args.values.len() > 2) {
        const converted = try args.values.convert(2, context);
        if (converted.value == .boolean and converted.value.boolean) result +%= 1;
    }
    return result;
}

pub fn inspectBrandedRest(
    _: bindgen.CallContext(InspectBrandedRestSchema),
    args: bindgen.Args(InspectBrandedRestSchema),
) bun.JSError!usize {
    return args.values.len();
}

pub fn inspectStringRest(
    context: bindgen.CallContext(InspectStringRestSchema),
    args: bindgen.Args(InspectStringRestSchema),
) bun.JSError!usize {
    var length: usize = 0;
    for (0..args.values.len()) |index| {
        const converted = try args.values.convert(index, context);
        length += converted.value.length();
    }
    return length;
}

pub fn echoNullableInt(
    context: bindgen.CallContext(EchoNullableIntSchema),
    args: bindgen.Args(EchoNullableIntSchema),
) bun.JSError!?i32 {
    _ = context;
    return args.input;
}

pub fn echoStringRest(
    _: bindgen.CallContext(EchoStringRestSchema),
    args: bindgen.Args(EchoStringRestSchema),
) bun.JSError!bindgen.Return(EchoStringRestSchema) {
    return try args.values.toFunctionResult();
}

pub fn echoBufferRest(
    _: bindgen.CallContext(EchoBufferRestSchema),
    args: bindgen.Args(EchoBufferRestSchema),
) bun.JSError!bindgen.Return(EchoBufferRestSchema) {
    try args.callback.call(.{});
    return try args.values.toFunctionResult();
}

pub fn echoAggregateRest(
    _: bindgen.CallContext(EchoAggregateRestSchema),
    args: bindgen.Args(EchoAggregateRestSchema),
) bun.JSError!bindgen.Return(EchoAggregateRestSchema) {
    return try args.values.toFunctionResult();
}

pub fn classifyNullablePresence(
    context: bindgen.CallContext(ClassifyNullablePresenceSchema),
    args: bindgen.Args(ClassifyNullablePresenceSchema),
) bun.JSError!i32 {
    _ = context;
    const nullable = args.input orelse return 0;
    const value = nullable orelse return 1;
    return value +% 2;
}

pub fn echoNullableString(
    context: bindgen.CallContext(EchoNullableStringSchema),
    args: bindgen.Args(EchoNullableStringSchema),
) bun.JSError!?bindgen.DOMString {
    _ = context;
    const input = args.input orelse return null;
    return input.toOwned();
}

pub fn echoNullableAny(
    context: bindgen.CallContext(EchoNullableAnySchema),
    args: bindgen.Args(EchoNullableAnySchema),
) bun.JSError!bindgen.Return(EchoNullableAnySchema) {
    _ = context;
    const input = args.input orelse return null;
    return input.toResult();
}

pub fn readCounterValue(
    context: bindgen.CallContext(ReadCounterValueSchema),
    args: bindgen.Args(ReadCounterValueSchema),
) bun.JSError!i32 {
    _ = context;
    return args.value.get(Counter).value;
}

pub fn inspectCounterWrapperHandles(
    context: bindgen.CallContext(InspectCounterWrapperHandlesSchema),
    args: bindgen.Args(InspectCounterWrapperHandlesSchema),
) bun.JSError!bool {
    var strong = try CounterClass.StrongWrapper.initView(args.value);
    defer strong.deinit();
    var weak = try CounterClass.WeakWrapper.initView(args.value);
    defer weak.deinit();
    var activity = try CounterClass.ActivityWrapper.initView(args.value);
    defer activity.deinit();
    var reference: bindgen.WrapperReference(.{CounterSchema}) = .empty();
    defer reference.deinit();
    try reference.setStrongClassView(CounterSchema, args.value);
    if (args.beforeRead) |view| {
        var callback = try view.toOwned();
        defer callback.deinit();
        // The weak read must propagate an exception already pending on entry.
        callback.call(context, .{}) catch |err| switch (err) {
            error.JSError, error.JSTerminated => {},
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    reference.downgrade();
    try reference.upgrade();
    return reference.isStrong() and strong.matchesView(args.value) and
        (try weak.matchesView(args.value)) and
        (try activity.matchesView(args.value));
}

pub fn readSharedCounterValue(
    context: bindgen.CallContext(ReadSharedCounterValueSchema),
    args: bindgen.Args(ReadSharedCounterValueSchema),
) bun.JSError!i32 {
    _ = context;
    return args.value.get(SharedCounter).value;
}

pub fn domainError(
    context: bindgen.CallContext(DomainErrorSchema),
    args: bindgen.Args(DomainErrorSchema),
) bindgen.CallError(DomainErrorSchema)!i32 {
    return switch (args.kind) {
        0 => 42,
        1 => context.fail(.rejected, args.message.toOwned()),
        2 => context.fail(.fixed, {}),
        else => context.fail(.system, try bindgen.SystemError.fromSysError(bindgenTestSystemError())),
    };
}

fn bindgenTestSystemError() bun.sys.Error {
    return bun.sys.Error.fromCode(.NOENT, .open).withPathDest(
        std.mem.sliceTo("/bindgen/missing", 0),
        std.mem.sliceTo("/bindgen/dest", 0),
    );
}

pub fn asyncResult(
    context: bindgen.CallContext(AsyncResultSchema),
    args: bindgen.Args(AsyncResultSchema),
) bindgen.CallError(AsyncResultSchema)!void {
    var completion = context.completion();
    switch (args.kind) {
        0 => completion.resolve(123),
        1 => completion.fail(.rejected, try args.message.toOwned()),
        2 => {},
        3 => {
            var owned = completion.take();
            const thread = std.Thread.spawn(.{}, completeAsyncResult, .{owned}) catch {
                owned.release();
                return asyncRuntimeFailure(context, "Failed to start completion test thread");
            };
            thread.detach();
        },
        5 => {
            var message = try args.message.toOwned();
            errdefer message.deinit();
            var owned = completion.take();
            const thread = std.Thread.spawn(.{}, completeDelayedFailure, .{
                owned,
                message,
                bun.current_runtime.io(),
            }) catch {
                owned.release();
                return asyncRuntimeFailure(context, "Failed to start completion test thread");
            };
            thread.detach();
        },
        6 => {
            completion_test_gate.store(false, .release);
            var message = try args.message.toOwned();
            errdefer message.deinit();
            var owned = completion.take();
            _ = completion_test_pending.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, completeGatedFailure, .{ owned, message }) catch {
                _ = completion_test_pending.fetchSub(1, .release);
                owned.release();
                return asyncRuntimeFailure(context, "Failed to start completion test thread");
            };
            thread.detach();
        },
        7 => {
            completion_test_gate.store(true, .release);
            while (completion_test_pending.load(.acquire) != 0) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
            completion.resolve(789);
        },
        9 => {
            completion_test_gate.store(false, .release);
            var owned = completion.take();
            _ = completion_test_pending.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, releaseGatedCompletion, .{owned}) catch {
                _ = completion_test_pending.fetchSub(1, .release);
                owned.release();
                return asyncRuntimeFailure(context, "Failed to start completion test thread");
            };
            thread.detach();
        },
        10 => {
            var owned = completion.take();
            const thread = std.Thread.spawn(.{}, completeSystemFailure, .{owned}) catch {
                owned.release();
                return asyncRuntimeFailure(context, "Failed to start completion test thread");
            };
            thread.detach();
        },
        else => {
            var owned = completion.take();
            var clone = owned.clone();
            owned.release();
            clone.resolve(456);
        },
    }
}

fn completeAsyncResult(completion: bindgen.OwnedCompletion(AsyncResultSchema)) void {
    var owned = completion;
    owned.resolve(321);
}

fn completeDelayedFailure(
    completion: bindgen.OwnedCompletion(AsyncResultSchema),
    message: bindgen.ThreadSafeDOMString,
    io: std.Io,
) void {
    var owned = completion;
    _ = io.sleep(.fromMilliseconds(100), .awake) catch {};
    owned.fail(.rejected, message);
}

fn completeGatedFailure(
    completion: bindgen.OwnedCompletion(AsyncResultSchema),
    message: bindgen.ThreadSafeDOMString,
) void {
    defer _ = completion_test_pending.fetchSub(1, .release);
    while (!completion_test_gate.load(.acquire)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    var owned = completion;
    owned.fail(.rejected, message);
}

fn releaseGatedCompletion(completion: bindgen.OwnedCompletion(AsyncResultSchema)) void {
    defer _ = completion_test_pending.fetchSub(1, .release);
    while (!completion_test_gate.load(.acquire)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    var owned = completion;
    owned.release();
}

fn completeSystemFailure(completion: bindgen.OwnedCompletion(AsyncResultSchema)) void {
    var owned = completion;
    const system_error = bindgen.SystemError.fromSysError(bindgenTestSystemError()) catch {
        owned.outOfMemory();
        return;
    };
    owned.fail(.system, system_error);
}

var completion_test_gate: std.atomic.Value(bool) = .init(false);
var completion_test_pending: std.atomic.Value(usize) = .init(0);

pub fn asyncEcho(
    context: bindgen.CallContext(AsyncEchoSchema),
    args: bindgen.Args(AsyncEchoSchema),
) bun.JSError!void {
    var completion = context.completion();
    completion.resolve(try args.message.toOwned());
}

pub fn asyncUTF8Strings(
    context: bindgen.CallContext(AsyncUTF8StringsSchema),
    _: bindgen.Args(AsyncUTF8StringsSchema),
) bindgen.CallError(AsyncUTF8StringsSchema)!void {
    var completion = context.completion();
    var owned = completion.take();
    const thread = std.Thread.spawn(.{}, completeUTF8Strings, .{owned}) catch {
        owned.release();
        return asyncRuntimeFailure(context, "Failed to start UTF-8 completion test thread");
    };
    thread.detach();
}

const MaterializedAttachment = struct {
    label: bindgen.Root,
};

const MaterializedTask = struct {
    completion: MaterializedCompletion.Owned,
    value: i32,
};

const MaterializedCompletionOps = struct {
    pub fn materialize(
        comptime _: type,
        context: bindgen.MaterializationContext(AsyncMaterializedSchema),
        attachment: *MaterializedAttachment,
        task: *MaterializedTask,
    ) bindgen.Return(AsyncMaterializedSchema) {
        return .{
            .value = task.value,
            .label = bindgen.AnyResult.fromOwnedRoot(&attachment.label, context),
        };
    }

    pub fn destroyPayload(task: *MaterializedTask) void {
        bun.destroy(task);
    }

    pub fn destroyAttachment(attachment: *MaterializedAttachment) void {
        attachment.label.deinit();
    }
};

const MaterializedCompletion = bindgen.MaterializedCompletion(
    AsyncMaterializedSchema,
    MaterializedTask,
    MaterializedAttachment,
    MaterializedCompletionOps,
);

fn completeMaterialized(task: *MaterializedTask) void {
    if (task.value < 0) {
        _ = std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(100), .awake) catch {};
    }
    task.value = task.value * 2 + 1;
    task.completion.complete(task);
}

pub fn asyncMaterialized(
    context: bindgen.CallContext(AsyncMaterializedSchema),
    args: bindgen.Args(AsyncMaterializedSchema),
) bun.JSError!void {
    var label = try args.label.toRoot();
    defer label.deinit();
    var completion = context.completion();
    const task = bun.default_allocator.create(MaterializedTask) catch {
        completion.outOfMemory();
        return;
    };
    const owned = MaterializedCompletion.take(&completion, .{ .label = label.take() }) catch {
        bun.default_allocator.destroy(task);
        completion.outOfMemory();
        return;
    };
    task.* = .{ .completion = owned, .value = args.value };
    const thread = std.Thread.spawn(.{}, completeMaterialized, .{task}) catch {
        completeMaterialized(task);
        return;
    };
    thread.detach();
}

fn completeUTF8Strings(completion: bindgen.OwnedCompletion(AsyncUTF8StringsSchema)) void {
    var owned = completion;
    const inputs = [_][]const u8{
        "plain",
        "Gr\xc3\xbc\xc3\x9fe",
        &.{ 'f', 0x80 },
    };
    const result = bindgen.Return(AsyncUTF8StringsSchema).fromUTF8Slices(&inputs) catch {
        owned.outOfMemory();
        return;
    };
    owned.resolve(result);
}

pub fn asyncWeakEcho(
    context: bindgen.CallContext(AsyncWeakEchoSchema),
    args: bindgen.Args(AsyncWeakEchoSchema),
) bindgen.CallError(AsyncWeakEchoSchema)!void {
    if (args.kind != 0) completion_test_gate.store(false, .release);
    var message = try args.message.toOwned();
    errdefer message.deinit();
    var completion = context.completion();
    var owned = completion.take();
    if (args.kind != 0) _ = completion_test_pending.fetchAdd(1, .monotonic);
    const thread = std.Thread.spawn(.{}, completeWeakEcho, .{ owned, message, args.kind != 0 }) catch {
        if (args.kind != 0) _ = completion_test_pending.fetchSub(1, .release);
        owned.release();
        return asyncRuntimeFailure(context, "Failed to start weak completion test thread");
    };
    thread.detach();
}

fn completeWeakEcho(
    completion: bindgen.OwnedCompletion(AsyncWeakEchoSchema),
    message: bindgen.ThreadSafeDOMString,
    gated: bool,
) void {
    defer {
        if (gated) _ = completion_test_pending.fetchSub(1, .release);
    }
    if (gated) {
        while (!completion_test_gate.load(.acquire)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
    var owned = completion;
    owned.resolve(message);
}

pub fn asyncPendingEcho(
    context: bindgen.CallContext(AsyncPendingEchoSchema),
    args: bindgen.Args(AsyncPendingEchoSchema),
) bindgen.CallError(AsyncPendingEchoSchema)!void {
    var message = try args.message.toOwned();
    errdefer message.deinit();
    var completion = context.completion();
    var owned = completion.take();
    const thread = std.Thread.spawn(.{}, completePendingEcho, .{ owned, message }) catch {
        owned.release();
        return asyncRuntimeFailure(context, "Failed to start pending completion test thread");
    };
    thread.detach();
}

pub fn setTransferAllocationFailureCountdown(
    context: bindgen.CallContext(SetTransferAllocationFailureCountdownSchema),
    args: bindgen.Args(SetTransferAllocationFailureCountdownSchema),
) bun.JSError!void {
    _ = context;
    bindgen.testing.setTransferAllocationFailureCountdown(if (args.countdown < 0) null else @intCast(args.countdown));
}

pub fn setWeakAllocationFailureCountdown(
    _: bindgen.CallContext(SetWeakAllocationFailureCountdownSchema),
    args: bindgen.Args(SetWeakAllocationFailureCountdownSchema),
) bun.JSError!void {
    bindgen.testing.setWeakAllocationFailureCountdown(if (args.countdown < 0) null else @intCast(args.countdown));
}

pub fn setRootAllocationFailureCountdown(
    context: bindgen.CallContext(SetRootAllocationFailureCountdownSchema),
    args: bindgen.Args(SetRootAllocationFailureCountdownSchema),
) bun.JSError!void {
    context.engineIn("strong_references", "strongRefSetAllocationFailureCountdown").call(.{
        .countdown = args.countdown,
    });
}

fn completePendingEcho(
    completion: bindgen.OwnedCompletion(AsyncPendingEchoSchema),
    message: bindgen.ThreadSafeDOMString,
) void {
    _ = std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(100), .awake) catch {};
    var owned = completion;
    owned.resolve(message);
}

fn runAdoptionCallback(view: anytype) bun.JSError!void {
    // The adoption guard must handle an exception already pending on entry.
    view.call(.{}) catch |err| switch (err) {
        error.JSError, error.JSTerminated => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
}

const Counter = struct {
    bindgen_state: bindgen.ClassState = .{},
    value: i32,
    new_target: bindgen.Root,

    pub fn construct(
        _: bindgen.CallContext(CounterConstructorSchema),
        args: bindgen.Args(CounterConstructorSchema),
    ) bun.JSError!*Counter {
        var new_target = try args.bindingNewTarget.toRoot();
        defer new_target.deinit();
        const counter = try bun.default_allocator.create(Counter);
        counter.* = .{
            .value = args.initial,
            .new_target = new_target.take(),
        };
        return counter;
    }

    pub fn destroy(counter: *Counter) void {
        _ = counter_destroyed_count.fetchAdd(1, .monotonic);
        counter.new_target.deinit();
        bun.default_allocator.destroy(counter);
    }

    pub fn wrapperCreated(_: *Counter, wrapper: bindgen.ClassRefView(CounterSchema)) bun.JSError!void {
        var weak = try CounterClass.WeakWrapper.initView(wrapper);
        defer weak.deinit();
    }

    pub fn adoptAfterCallback(
        context: bindgen.CallContext(CounterAdoptAfterCallbackSchema),
        args: bindgen.Args(CounterAdoptAfterCallbackSchema),
    ) bun.JSError!bindgen.Return(CounterAdoptAfterCallbackSchema) {
        var owner = bindgen.OwnedNative(Counter, .vm).init(bun.new(Counter, .{
            .value = 1,
            .new_target = try bindgen.Root.initNull(context),
        }));
        defer owner.deinit();
        try runAdoptionCallback(args.callback);
        return CounterClass.adoptResult(owner.take(), context);
    }

    pub fn memoryUsage(counter: *const Counter, _: bindgen.MemoryUsageContext(.any)) usize {
        _ = counter;
        return @sizeOf(Counter);
    }

    pub fn hasPendingActivity(counter: *const Counter) bool {
        return counter.value == counter_pending_activity_value;
    }

    pub fn increment(
        counter: *Counter,
        context: bindgen.CallContext(CounterIncrementSchema),
        args: bindgen.Args(CounterIncrementSchema),
    ) bindgen.CallError(CounterIncrementSchema)!i32 {
        return incrementBy(counter, context, args.delta);
    }

    pub fn getInvalidatableValue(
        counter: *Counter,
        context: bindgen.CallContext(CounterInvalidatableValueSchema),
        _: bindgen.Args(CounterInvalidatableValueSchema),
    ) bindgen.CallError(CounterInvalidatableValueSchema)!i32 {
        if (counter.value == std.math.minInt(i32)) {
            return runtimeFailure(context, "Counter eager cache failed");
        }
        return counter.value;
    }

    pub fn invalidateValueCache(
        _: *Counter,
        _: bindgen.CallContext(CounterInvalidateValueCacheSchema),
        args: bindgen.Args(CounterInvalidateValueCacheSchema),
    ) bun.JSError!void {
        CounterInvalidatableValueSlot.clearView(args.bindingThis);
    }

    pub fn setCachedCallback(
        _: *Counter,
        _: bindgen.CallContext(CounterSetCachedCallbackSchema),
        args: bindgen.Args(CounterSetCachedCallbackSchema),
    ) bun.JSError!void {
        CounterClass.CachedSlot("cachedCallback").setView(args.bindingThis, args.callback);
    }

    pub fn invokeCachedCallback(
        _: *Counter,
        _: bindgen.CallContext(CounterInvokeCachedCallbackSchema),
        args: bindgen.Args(CounterInvokeCachedCallbackSchema),
    ) bun.JSError!void {
        const callback = (try CounterClass.CachedSlot("cachedCallback").view(args.bindingThis)) orelse return;
        try callback.call(.{});
    }

    pub fn privateIncrement(
        counter: *Counter,
        context: bindgen.CallContext(CounterPrivateIncrementSchema),
        args: bindgen.Args(CounterPrivateIncrementSchema),
    ) bindgen.CallError(CounterPrivateIncrementSchema)!i32 {
        return incrementBy(counter, context, args.delta);
    }

    fn incrementBy(counter: *Counter, context: anytype, delta: i32) bun.bindgen.CallError(@TypeOf(context))!i32 {
        counter.value = std.math.add(i32, counter.value, delta) catch {
            return runtimeFailure(context, "Integer overflow while incrementing");
        };
        return counter.value;
    }

    pub fn sum(
        counter: *Counter,
        context: bindgen.CallContext(CounterSumSchema),
        args: bindgen.Args(CounterSumSchema),
    ) bindgen.CallError(CounterSumSchema)!i32 {
        return switch (args) {
            .one => |one| std.math.add(i32, counter.value, one.value),
            .two => |two| std.math.add(i32, two.left, two.right),
        } catch {
            return runtimeFailure(context, "Integer overflow while summing");
        };
    }

    pub fn toPrimitive(
        counter: *Counter,
        context: bindgen.CallContext(CounterToPrimitiveSchema),
        args: bindgen.Args(CounterToPrimitiveSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return counter.value;
    }

    pub fn inspectCustom(
        counter: *Counter,
        context: bindgen.CallContext(CounterInspectCustomSchema),
        args: bindgen.Args(CounterInspectCustomSchema),
    ) bun.JSError!bindgen.DOMString {
        _ = counter;
        _ = context;
        _ = args;
        return bindgen.DOMString.fromUTF8("GeneratedCounter");
    }

    pub fn getValue(
        counter: *Counter,
        context: bindgen.CallContext(CounterValueSchema),
        args: bindgen.Args(CounterValueSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return counter.value;
    }

    pub fn setValue(
        counter: *Counter,
        context: bindgen.CallContext(CounterValueSetterSchema),
        args: bindgen.Args(CounterValueSetterSchema),
    ) bun.JSError!void {
        _ = context;
        counter.value = args.value;
    }

    pub fn getNewTarget(
        counter: *Counter,
        context: bindgen.CallContext(CounterNewTargetSchema),
        args: bindgen.Args(CounterNewTargetSchema),
    ) bun.JSError!bindgen.Return(CounterNewTargetSchema) {
        _ = args;
        return bindgen.AnyResult.fromRoot(&counter.new_target, context);
    }

    pub fn kind(
        context: bindgen.CallContext(CounterKindSchema),
        args: bindgen.Args(CounterKindSchema),
    ) bun.JSError!bindgen.DOMString {
        _ = context;
        _ = args;
        return bindgen.DOMString.fromUTF8("Counter");
    }

    pub fn getDefaultValue(
        context: bindgen.CallContext(CounterDefaultValueSchema),
        args: bindgen.Args(CounterDefaultValueSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return counter_default_value;
    }

    pub fn setDefaultValue(
        context: bindgen.CallContext(CounterDefaultValueSetterSchema),
        args: bindgen.Args(CounterDefaultValueSetterSchema),
    ) bun.JSError!void {
        _ = context;
        counter_default_value = args.value;
    }

    pub fn getDestroyedCount(
        context: bindgen.CallContext(CounterDestroyedCountSchema),
        args: bindgen.Args(CounterDestroyedCountSchema),
    ) bun.JSError!usize {
        _ = context;
        _ = args;
        return counter_destroyed_count.load(.monotonic);
    }
};

var counter_default_value: i32 = 11;
var counter_destroyed_count: std.atomic.Value(usize) = .init(0);
const counter_pending_activity_value: i32 = -24_680;

const ScaledCounter = struct {
    bindgen_state: bindgen.ClassState = .{},
    parent: Counter,
    factor: i32,

    pub const Parent = Counter;

    pub fn construct(
        _: bindgen.CallContext(ScaledCounterConstructorSchema),
        args: bindgen.Args(ScaledCounterConstructorSchema),
    ) bun.JSError!*ScaledCounter {
        var new_target = try args.bindingNewTarget.toRoot();
        defer new_target.deinit();
        const counter = try bun.default_allocator.create(ScaledCounter);
        counter.* = .{
            .parent = .{
                .value = args.initial,
                .new_target = new_target.take(),
            },
            .factor = args.factor,
        };
        return counter;
    }

    pub fn destroy(counter: *ScaledCounter) void {
        counter.parent.new_target.deinit();
        bun.default_allocator.destroy(counter);
    }

    pub fn asCounter(counter: *ScaledCounter) *Counter {
        return &counter.parent;
    }

    pub fn memoryUsage(counter: *const ScaledCounter, context: bindgen.MemoryUsageContext(.vm)) usize {
        _ = counter;
        _ = context;
        return @sizeOf(ScaledCounter);
    }

    pub fn scale(
        counter: *ScaledCounter,
        context: bindgen.CallContext(ScaledCounterScaleSchema),
        args: bindgen.Args(ScaledCounterScaleSchema),
    ) bindgen.CallError(ScaledCounterScaleSchema)!i32 {
        _ = args;
        counter.parent.value = std.math.mul(i32, counter.parent.value, counter.factor) catch {
            return runtimeFailure(context, "Integer overflow while scaling");
        };
        return counter.parent.value;
    }

    pub fn getFactor(
        counter: *ScaledCounter,
        context: bindgen.CallContext(ScaledCounterFactorSchema),
        args: bindgen.Args(ScaledCounterFactorSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return counter.factor;
    }
};

const SharedCounter = struct {
    const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", deinit, .{});

    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    value: i32,

    pub fn construct(
        context: bindgen.CallContext(SharedCounterConstructorSchema),
        args: bindgen.Args(SharedCounterConstructorSchema),
    ) bun.JSError!*SharedCounter {
        _ = context;
        const counter = try bun.default_allocator.create(SharedCounter);
        counter.* = .{ .ref_count = .init(), .value = args.initial };
        return counter;
    }

    fn deinit(counter: *SharedCounter) void {
        _ = shared_counter_destroyed_count.fetchAdd(1, .monotonic);
        bun.default_allocator.destroy(counter);
    }

    pub fn adoptAfterCallback(
        context: bindgen.CallContext(SharedCounterAdoptAfterCallbackSchema),
        args: bindgen.Args(SharedCounterAdoptAfterCallbackSchema),
    ) bun.JSError!bindgen.Return(SharedCounterAdoptAfterCallbackSchema) {
        var owner = bindgen.RefNative(SharedCounter, .any).adopt(bun.new(SharedCounter, .{
            .ref_count = .init(),
            .value = 1,
        }));
        defer owner.deinit();
        try runAdoptionCallback(args.callback);
        return SharedCounterClass.adoptResult(owner.take(), context);
    }

    pub fn wrapAfterCallback(
        context: bindgen.CallContext(SharedCounterWrapAfterCallbackSchema),
        args: bindgen.Args(SharedCounterWrapAfterCallbackSchema),
    ) bun.JSError!bindgen.Return(SharedCounterWrapAfterCallbackSchema) {
        var owner = SharedCounterClass.Handle.initView(args.value);
        defer owner.deinit();
        try runAdoptionCallback(args.callback);
        return SharedCounterClass.toRef(&owner, context);
    }

    pub fn increment(
        counter: *SharedCounter,
        context: bindgen.CallContext(SharedCounterIncrementSchema),
        args: bindgen.Args(SharedCounterIncrementSchema),
    ) bindgen.CallError(SharedCounterIncrementSchema)!i32 {
        counter.value = std.math.add(i32, counter.value, args.delta) catch {
            return runtimeFailure(context, "Integer overflow while incrementing");
        };
        return counter.value;
    }

    pub fn incrementAsync(
        counter: *SharedCounter,
        context: bindgen.CallContext(SharedCounterIncrementAsyncSchema),
        args: bindgen.Args(SharedCounterIncrementAsyncSchema),
    ) bindgen.CallError(SharedCounterIncrementAsyncSchema)!void {
        counter.value = std.math.add(i32, counter.value, args.delta) catch {
            return asyncRuntimeFailure(context, "Integer overflow while incrementing");
        };
        var completion = context.completion();
        completion.resolve(counter.value);
    }

    pub fn getValue(
        counter: *SharedCounter,
        context: bindgen.CallContext(SharedCounterValueSchema),
        args: bindgen.Args(SharedCounterValueSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return counter.value;
    }

    pub fn getDestroyedCount(
        context: bindgen.CallContext(SharedCounterDestroyedCountSchema),
        args: bindgen.Args(SharedCounterDestroyedCountSchema),
    ) bun.JSError!usize {
        _ = context;
        _ = args;
        return shared_counter_destroyed_count.load(.monotonic);
    }

    pub fn identity(
        context: bindgen.CallContext(SharedCounterIdentitySchema),
        args: bindgen.Args(SharedCounterIdentitySchema),
    ) bun.JSError!bindgen.Return(SharedCounterIdentitySchema) {
        _ = context;
        return args.value.toOwned();
    }

    pub fn holdForRealmTest(
        context: bindgen.CallContext(SharedCounterHoldForRealmTestSchema),
        args: bindgen.Args(SharedCounterHoldForRealmTestSchema),
    ) bindgen.CallError(SharedCounterHoldForRealmTestSchema)!void {
        if (held_shared_counter != null) {
            return runtimeFailure(context, "A SharedCounter is already held for the realm test");
        }
        const handle = SharedCounterClass.Handle.initView(args.value);
        held_shared_counter = .{
            .vm = context.vmIdentity(),
            .handle = handle,
        };
    }

    pub fn heldForRealmTest(
        context: bindgen.CallContext(SharedCounterHeldForRealmTestSchema),
        args: bindgen.Args(SharedCounterHeldForRealmTestSchema),
    ) bindgen.CallError(SharedCounterHeldForRealmTestSchema)!bindgen.Return(SharedCounterHeldForRealmTestSchema) {
        _ = args;
        const held = held_shared_counter orelse {
            return runtimeFailure(context, "No SharedCounter is held for the realm test");
        };
        if (!held.vm.eql(context.vmIdentity())) {
            return runtimeFailure(context, "The held SharedCounter belongs to another VM");
        }
        var handle = held.handle.clone();
        errdefer handle.deinit();
        return SharedCounterClass.toRef(&handle, context);
    }

    pub fn releaseForRealmTest(
        context: bindgen.CallContext(SharedCounterReleaseForRealmTestSchema),
        args: bindgen.Args(SharedCounterReleaseForRealmTestSchema),
    ) bindgen.CallError(SharedCounterReleaseForRealmTestSchema)!void {
        _ = args;
        var held = held_shared_counter orelse return;
        if (!held.vm.eql(context.vmIdentity())) {
            return runtimeFailure(context, "The held SharedCounter belongs to another VM");
        }
        held_shared_counter = null;
        held.handle.deinit();
    }

    pub fn releaseHeldOffThreadForTest(
        context: bindgen.CallContext(SharedCounterReleaseHeldOffThreadForTestSchema),
        args: bindgen.Args(SharedCounterReleaseHeldOffThreadForTestSchema),
    ) bindgen.CallError(SharedCounterReleaseHeldOffThreadForTestSchema)!void {
        _ = args;
        var held = held_shared_counter orelse {
            return runtimeFailure(context, "No SharedCounter is held for the finalizer test");
        };
        if (!held.vm.eql(context.vmIdentity())) {
            return runtimeFailure(context, "The held SharedCounter belongs to another VM");
        }
        held_shared_counter = null;
        const thread = std.Thread.spawn(.{}, releaseSharedCounterHandle, .{held.handle}) catch {
            held.handle.deinit();
            return runtimeFailure(context, "Could not start finalizer test thread");
        };
        thread.join();
    }
};

const SharedScaledCounter = struct {
    const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", deinit, .{});

    pub const Parent = SharedCounter;
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    parent: SharedCounter,
    factor: i32,

    pub fn bindgenState(counter: *SharedScaledCounter) *bindgen.ClassState {
        return &counter.parent.bindgen_state;
    }

    pub fn construct(
        context: bindgen.CallContext(SharedScaledCounterConstructorSchema),
        args: bindgen.Args(SharedScaledCounterConstructorSchema),
    ) bun.JSError!*SharedScaledCounter {
        _ = context;
        const counter = try bun.default_allocator.create(SharedScaledCounter);
        counter.* = .{
            .ref_count = .init(),
            .parent = .{
                .ref_count = .init(),
                .value = args.initial,
            },
            .factor = args.factor,
        };
        return counter;
    }

    fn deinit(counter: *SharedScaledCounter) void {
        _ = shared_scaled_counter_destroyed_count.fetchAdd(1, .monotonic);
        bun.default_allocator.destroy(counter);
    }

    pub fn asSharedCounter(counter: *SharedScaledCounter) *SharedCounter {
        return &counter.parent;
    }

    pub fn scale(
        counter: *SharedScaledCounter,
        context: bindgen.CallContext(SharedScaledCounterScaleSchema),
        args: bindgen.Args(SharedScaledCounterScaleSchema),
    ) bindgen.CallError(SharedScaledCounterScaleSchema)!i32 {
        _ = args;
        counter.parent.value = std.math.mul(i32, counter.parent.value, counter.factor) catch {
            return runtimeFailure(context, "Integer overflow while scaling");
        };
        return counter.parent.value;
    }

    pub fn getFactor(
        counter: *SharedScaledCounter,
        context: bindgen.CallContext(SharedScaledCounterFactorSchema),
        args: bindgen.Args(SharedScaledCounterFactorSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return counter.factor;
    }

    pub fn getDestroyedCount(
        context: bindgen.CallContext(SharedScaledCounterDestroyedCountSchema),
        args: bindgen.Args(SharedScaledCounterDestroyedCountSchema),
    ) bun.JSError!usize {
        _ = context;
        _ = args;
        return shared_scaled_counter_destroyed_count.load(.monotonic);
    }
};

const CloneBox = struct {
    bindgen_state: bindgen.ClassState = .{},
    value: i32,
    fail_serialization: bool = false,

    pub fn construct(
        context: bindgen.CallContext(CloneBoxConstructorSchema),
        args: bindgen.Args(CloneBoxConstructorSchema),
    ) bun.JSError!*CloneBox {
        _ = context;
        const box = try bun.default_allocator.create(CloneBox);
        box.* = .{ .value = args.value };
        return box;
    }

    pub fn destroy(box: *CloneBox) void {
        bun.default_allocator.destroy(box);
    }

    pub fn getValue(
        box: *CloneBox,
        context: bindgen.CallContext(CloneBoxValueSchema),
        args: bindgen.Args(CloneBoxValueSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return box.value;
    }

    pub fn setValue(
        box: *CloneBox,
        context: bindgen.CallContext(CloneBoxValueSetterSchema),
        args: bindgen.Args(CloneBoxValueSetterSchema),
    ) bun.JSError!void {
        _ = context;
        box.value = args.value;
    }

    pub fn structuredCloneSerialize(box: *const CloneBox, writer: bindgen.StructuredCloneWriter) bun.OOM!void {
        try writer.writeInt(i32, box.value, .little);
        if (box.fail_serialization) return error.OutOfMemory;
    }

    pub fn setSerializationFailure(
        box: *CloneBox,
        _: bindgen.CallContext(CloneBoxSerializationFailureSchema),
        args: bindgen.Args(CloneBoxSerializationFailureSchema),
    ) bun.JSError!void {
        box.fail_serialization = args.enabled;
    }

    pub fn structuredCloneDeserialize(
        context: bindgen.StructuredCloneContext(CloneBoxSchema),
        reader: *bindgen.StructuredCloneReader,
    ) bindgen.StructuredCloneError!*CloneBox {
        _ = context;
        const value = reader.readInt(i32, .little) catch return error.InvalidData;
        const box = try bun.default_allocator.create(CloneBox);
        box.* = .{ .value = value };
        return box;
    }
};

const SweepBox = struct {
    bindgen_state: bindgen.ClassState = .{},

    pub fn construct(
        context: bindgen.CallContext(SweepBoxConstructorSchema),
        args: bindgen.Args(SweepBoxConstructorSchema),
    ) bun.JSError!*SweepBox {
        _ = context;
        _ = args;
        const box = try bun.default_allocator.create(SweepBox);
        box.* = .{};
        return box;
    }

    pub fn call(
        context: bindgen.CallContext(SweepBoxCallSchema),
        args: bindgen.Args(SweepBoxCallSchema),
    ) bun.JSError!i32 {
        _ = context;
        _ = args;
        return 42;
    }

    pub fn destroy(box: *SweepBox, context: bindgen.SweepContext) void {
        _ = context;
        bun.default_allocator.destroy(box);
    }
};

const SweepSharedBox = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});

    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},

    pub fn construct(
        context: bindgen.CallContext(SweepSharedBoxConstructorSchema),
        args: bindgen.Args(SweepSharedBoxConstructorSchema),
    ) bun.JSError!*SweepSharedBox {
        _ = context;
        _ = args;
        const box = try bun.default_allocator.create(SweepSharedBox);
        box.* = .{ .ref_count = .init() };
        return box;
    }

    fn deinit(box: *SweepSharedBox) void {
        bun.default_allocator.destroy(box);
    }
};

fn releaseSharedCounterHandle(handle: SharedCounterClass.Handle) void {
    var owned = handle;
    owned.deinit();
}

const HeldSharedCounter = struct {
    vm: bindgen.VMIdentity,
    handle: SharedCounterClass.Handle,
};

threadlocal var held_shared_counter: ?HeldSharedCounter = null;
var shared_counter_destroyed_count: std.atomic.Value(usize) = .init(0);
var shared_scaled_counter_destroyed_count: std.atomic.Value(usize) = .init(0);

const BindingModule = bindgen.Module("bindgen_test");
const AddSchema = BindingModule.function("add");
const EchoInt8Schema = BindingModule.function("echoInt8");
const EchoInt16Schema = BindingModule.function("echoInt16");
const EchoUint16Schema = BindingModule.function("echoUint16");
const EchoUint32Schema = BindingModule.function("echoUint32");
const EchoInt64Schema = BindingModule.function("echoInt64");
const EchoUint64Schema = BindingModule.function("echoUint64");
const EchoTestOptionsSchema = BindingModule.function("echoTestOptions");
const EchoDictionarySourceSchema = BindingModule.function("echoDictionarySource");
const EchoTestScalarsSchema = BindingModule.function("echoTestScalars");
const RoundTripTestBundleSchema = BindingModule.function("roundTripTestBundle");
const VisitTestBundleSchema = BindingModule.function("visitTestBundle");
const DispatchAdvancedSchema = BindingModule.function("dispatchAdvanced");
const InspectNodeConversionOrderSchema = BindingModule.function("inspectNodeConversionOrder");
const InspectCustomConvertersSchema = BindingModule.function("inspectCustomConverters");
const EchoStringRestSchema = BindingModule.function("echoStringRest");
const EchoBufferRestSchema = BindingModule.function("echoBufferRest");
const EchoAggregateRestSchema = BindingModule.function("echoAggregateRest");
const InspectLazyOptionsSchema = BindingModule.function("inspectLazyOptions");
const InspectLazyConvertedLabelSchema = BindingModule.function("inspectLazyConvertedLabel");
const InspectLazyReceiverIndexSchema = BindingModule.function("inspectLazyReceiverIndex");
const InspectLazyRestLeaseSchema = BindingModule.function("inspectLazyRestLease");
const RetryLazyStringSchema = BindingModule.function("retryLazyString");
const CallbackIdentityAfterReentrySchema = BindingModule.function("callbackIdentityAfterReentry");
const MultiplyAddSchema = BindingModule.nativeExport("multiplyAdd");
const NativeLazyStringLengthSchema = BindingModule.nativeExport("nativeLazyStringLength");
const NativeStringBufferHandleSchema = BindingModule.nativeExport("nativeStringBufferHandle");
const OptionalNativeStringSchema = BindingModule.nativeExport("optionalNativeString");
const NativeStringSequenceLengthSchema = BindingModule.nativeExport("nativeStringSequenceLength");
const NativeCallbackRecordSchema = BindingModule.nativeExport("nativeCallbackRecord");
const RetainCallbackRecordSchema = BindingModule.function("retainCallbackRecord");
const InspectCallbackRecordViewsSchema = BindingModule.function("inspectCallbackRecordViews");
const RequiredAndOptionalArgSchema = BindingModule.function("requiredAndOptionalArg");
const DOMStringLengthSchema = BindingModule.function("domStringLength");
const IsolateEngineStringSchema = BindingModule.function("isolateEngineString");
const EchoDOMStringSchema = BindingModule.function("echoDOMString");
const EchoUSVStringSchema = BindingModule.function("echoUSVString");
const EchoByteStringSchema = BindingModule.function("echoByteString");
const StrictUSVStringSchema = BindingModule.function("strictUSVString");
const StrictByteStringSchema = BindingModule.function("strictByteString");
const EchoBufferSchema = BindingModule.function("echoBuffer");
const FillMutableLeaseSchema = BindingModule.function("fillMutableLease");
const SetMutableLeaseByteSchema = BindingModule.function("setMutableLeaseByte");
const InspectInt32FromJSSchema = BindingModule.function("inspectInt32FromJS");
const InspectLeaseOptionsFromJSSchema = BindingModule.function("inspectLeaseOptionsFromJS");
const InspectLeaseAfterCallbackSchema = BindingModule.function("inspectLeaseAfterCallback");
const InspectNestedLeaseAfterCallbackSchema = BindingModule.function("inspectNestedLeaseAfterCallback");
const EchoNullableBufferSchema = BindingModule.function("echoNullableBuffer");
const EchoAnySchema = BindingModule.function("echoAny");
const SnapshotStoredRootsSchema = BindingModule.function("snapshotStoredRoots");
const PreserveTransferredRootSchema = BindingModule.function("preserveTransferredRoot");
const ReadIndexViaEngineSchema = BindingModule.function("readIndexViaEngine");
const SumIntegerWidthsViaEngineSchema = BindingModule.function("sumIntegerWidthsViaEngine");
const EngineBufferSequenceLengthViaEngineSchema = BindingModule.function("engineBufferSequenceLengthViaEngine");
const NodePathLengthViaEngineSchema = BindingModule.function("nodePathLengthViaEngine");
const InvocationThisSchema = BindingModule.function("invocationThis");
const VisitGCEntriesSchema = BindingModule.function("visitGCEntries");
const VisitDeferredGCEntriesSchema = BindingModule.function("visitDeferredGCEntries");
const LeaseWithIgnoredOperandSchema = BindingModule.function("leaseWithIgnoredOperand");
const InspectNestedLazyFieldsSchema = BindingModule.function("inspectNestedLazyFields");
const InspectEagerLazyFieldsSchema = BindingModule.function("inspectEagerLazyFields");
const InspectNestedLazyRestSchema = BindingModule.function("inspectNestedLazyRest");
const ForceLazyPathSchema = BindingModule.function("forceLazyPath");
const DescribePatternValuesSchema = BindingModule.function("describePatternValues");
const InvokeCallbackSchema = BindingModule.function("invokeCallback");
const InvokeOwnedCallbackSchema = BindingModule.function("invokeOwnedCallback");
const ScheduleCallbackSchema = BindingModule.function("scheduleCallback");
const EchoCallbackSchema = BindingModule.function("echoCallback");
const InvokeStringCallbackSchema = BindingModule.function("invokeStringCallback");
const InvokeNullableStringCallbackSchema = BindingModule.function("invokeNullableStringCallback");
const InvokeBufferCallbackSchema = BindingModule.function("invokeBufferCallback");
const InvokeAnyCallbackSchema = BindingModule.function("invokeAnyCallback");
const InvokeCompositeCallbackSchema = BindingModule.function("invokeCompositeCallback");
const InvokeRestCallbackSchema = BindingModule.function("invokeRestCallback");
const InvokeTypedRestCallbackSchema = BindingModule.function("invokeTypedRestCallback");
const InvokeCallbackFactorySchema = BindingModule.function("invokeCallbackFactory");
const InvokeObserverSchema = BindingModule.function("invokeObserver");
const InvokeIntegerCallbackSchema = BindingModule.function("invokeIntegerCallback");
const ClampIntegerSchema = BindingModule.function("clampInteger");
const ValidateIntegerSchema = BindingModule.function("validateInteger");
const ValidateNodeBooleanSchema = BindingModule.function("validateNodeBoolean");
const ValidateNodeNumberSchema = BindingModule.function("validateNodeNumber");
const ValidateNodeStringSchema = BindingModule.function("validateNodeString");
const ValidateNodeStringsSchema = BindingModule.function("validateNodeStrings");
const DefaultStringSchema = BindingModule.function("defaultString");
const DefaultAnySchema = BindingModule.function("defaultAny");
const ClassifyPresenceSchema = BindingModule.function("classifyPresence");
const InspectRestSchema = BindingModule.function("inspectRest");
const InspectStringRestSchema = BindingModule.function("inspectStringRest");
const InspectBrandedRestSchema = BindingModule.function("inspectBrandedRest");
const EchoNullableIntSchema = BindingModule.function("echoNullableInt");
const ClassifyNullablePresenceSchema = BindingModule.function("classifyNullablePresence");
const EchoNullableStringSchema = BindingModule.function("echoNullableString");
const EchoNullableAnySchema = BindingModule.function("echoNullableAny");
const ReadCounterValueSchema = BindingModule.function("readCounterValue");
const InspectCounterWrapperHandlesSchema = BindingModule.function("inspectCounterWrapperHandles");
const ReadSharedCounterValueSchema = BindingModule.function("readSharedCounterValue");
const DomainErrorSchema = BindingModule.function("domainError");
const AsyncResultSchema = BindingModule.function("asyncResult");
const AsyncEchoSchema = BindingModule.function("asyncEcho");
const AsyncUTF8StringsSchema = BindingModule.function("asyncUTF8Strings");
const AsyncMaterializedSchema = BindingModule.function("asyncMaterialized");
const AsyncWeakEchoSchema = BindingModule.function("asyncWeakEcho");
const AsyncPendingEchoSchema = BindingModule.function("asyncPendingEcho");
const SetTransferAllocationFailureCountdownSchema = BindingModule.function("setTransferAllocationFailureCountdown");
const SetWeakAllocationFailureCountdownSchema = BindingModule.function("setWeakAllocationFailureCountdown");
const SetRootAllocationFailureCountdownSchema = BindingModule.function("setRootAllocationFailureCountdown");
const CounterSchema = BindingModule.class("Counter");
const CounterConstructorSchema = CounterSchema.constructor();
const CounterAdoptAfterCallbackSchema = CounterSchema.member("adoptAfterCallback");
const CounterIncrementSchema = CounterSchema.member("increment");
const CounterInvalidatableValueSchema = CounterSchema.member("invalidatableValue");
const CounterInvalidateValueCacheSchema = CounterSchema.member("invalidateValueCache");
const CounterSetCachedCallbackSchema = CounterSchema.member("setCachedCallback");
const CounterInvokeCachedCallbackSchema = CounterSchema.member("invokeCachedCallback");
const CounterPrivateIncrementSchema = CounterSchema.member("privateIncrement");
const CounterSumSchema = CounterSchema.member("sum");
const CounterToPrimitiveSchema = CounterSchema.member("toPrimitive");
const CounterInspectCustomSchema = CounterSchema.member("inspectCustom");
const CounterValueSchema = CounterSchema.memberKind("value", .getter);
const CounterValueSetterSchema = CounterSchema.memberKind("value", .setter);
const CounterNewTargetSchema = CounterSchema.memberKind("newTarget", .getter);
const CounterKindSchema = CounterSchema.member("kind");
const CounterDefaultValueSchema = CounterSchema.memberKind("defaultValue", .static_getter);
const CounterDefaultValueSetterSchema = CounterSchema.memberKind("defaultValue", .static_setter);
const CounterDestroyedCountSchema = CounterSchema.member("destroyedCount");
const ScaledCounterSchema = BindingModule.class("ScaledCounter");
const ScaledCounterConstructorSchema = ScaledCounterSchema.constructor();
const ScaledCounterScaleSchema = ScaledCounterSchema.member("scale");
const ScaledCounterFactorSchema = ScaledCounterSchema.member("factor");
const SharedCounterSchema = BindingModule.class("SharedCounter");
const SharedCounterConstructorSchema = SharedCounterSchema.constructor();
const SharedCounterAdoptAfterCallbackSchema = SharedCounterSchema.member("adoptAfterCallback");
const SharedCounterWrapAfterCallbackSchema = SharedCounterSchema.member("wrapAfterCallback");
const SharedCounterIncrementSchema = SharedCounterSchema.member("increment");
const SharedCounterIncrementAsyncSchema = SharedCounterSchema.member("incrementAsync");
const SharedCounterValueSchema = SharedCounterSchema.member("value");
const SharedCounterIdentitySchema = SharedCounterSchema.member("identity");
const SharedCounterHoldForRealmTestSchema = SharedCounterSchema.member("holdForRealmTest");
const SharedCounterHeldForRealmTestSchema = SharedCounterSchema.member("heldForRealmTest");
const SharedCounterReleaseForRealmTestSchema = SharedCounterSchema.member("releaseForRealmTest");
const SharedCounterReleaseHeldOffThreadForTestSchema = SharedCounterSchema.member("releaseHeldOffThreadForTest");
const SharedCounterDestroyedCountSchema = SharedCounterSchema.member("destroyedCount");
const SharedScaledCounterSchema = BindingModule.class("SharedScaledCounter");
const SharedScaledCounterConstructorSchema = SharedScaledCounterSchema.constructor();
const SharedScaledCounterScaleSchema = SharedScaledCounterSchema.member("scale");
const SharedScaledCounterFactorSchema = SharedScaledCounterSchema.member("factor");
const SharedScaledCounterDestroyedCountSchema = SharedScaledCounterSchema.member("destroyedCount");
const CloneBoxSchema = BindingModule.class("CloneBox");
const CloneBoxConstructorSchema = CloneBoxSchema.constructor();
const CloneBoxValueSchema = CloneBoxSchema.memberKind("value", .getter);
const CloneBoxValueSetterSchema = CloneBoxSchema.memberKind("value", .setter);
const CloneBoxSerializationFailureSchema = CloneBoxSchema.member("setSerializationFailure");
const SweepBoxSchema = BindingModule.class("SweepBox");
const SweepBoxConstructorSchema = SweepBoxSchema.constructor();
const SweepBoxCallSchema = SweepBoxSchema.constructorCall();
const SweepSharedBoxSchema = BindingModule.class("SweepSharedBox");
const SweepSharedBoxConstructorSchema = SweepSharedBoxSchema.constructor();
const CounterClass = bindgen.Class(CounterSchema, Counter);
const CounterInvalidatableValueSlot = CounterClass.CachedSlotInvalidator("hiddenCached");
const CounterEngineValueSlot = CounterClass.CachedSlot("cachedEngineValue");
const ScaledCounterClass = bindgen.Class(ScaledCounterSchema, ScaledCounter);
const SharedCounterClass = bindgen.Class(SharedCounterSchema, SharedCounter);
const SharedScaledCounterClass = bindgen.Class(SharedScaledCounterSchema, SharedScaledCounter);
const CloneBoxClass = bindgen.Class(CloneBoxSchema, CloneBox);
const SweepBoxClass = bindgen.Class(SweepBoxSchema, SweepBox);
const SweepSharedBoxClass = bindgen.Class(SweepSharedBoxSchema, SweepSharedBox);

comptime {
    @setEvalBranchQuota(10_000);
    _ = bindgen.Fn(AddSchema, add);
    _ = bindgen.Fn(EchoInt8Schema, echoInt8);
    _ = bindgen.Fn(EchoInt16Schema, echoInt16);
    _ = bindgen.Fn(EchoUint16Schema, echoUint16);
    _ = bindgen.Fn(EchoUint32Schema, echoUint32);
    _ = bindgen.Fn(EchoInt64Schema, echoInt64);
    _ = bindgen.Fn(EchoUint64Schema, echoUint64);
    _ = bindgen.Fn(EchoTestOptionsSchema, echoTestOptions);
    _ = bindgen.Fn(EchoDictionarySourceSchema, echoDictionarySource);
    _ = bindgen.Fn(EchoTestScalarsSchema, echoTestScalars);
    _ = bindgen.Fn(RoundTripTestBundleSchema, roundTripTestBundle);
    _ = bindgen.Fn(VisitTestBundleSchema, visitTestBundle);
    _ = bindgen.Fn(DispatchAdvancedSchema, dispatchAdvanced);
    _ = bindgen.Fn(InspectNodeConversionOrderSchema, inspectNodeConversionOrder);
    _ = bindgen.Fn(InspectCustomConvertersSchema, inspectCustomConverters);
    _ = bindgen.Fn(EchoStringRestSchema, echoStringRest);
    _ = bindgen.Fn(EchoBufferRestSchema, echoBufferRest);
    _ = bindgen.Fn(EchoAggregateRestSchema, echoAggregateRest);
    _ = bindgen.Fn(InspectLazyOptionsSchema, inspectLazyOptions);
    _ = bindgen.Fn(InspectLazyConvertedLabelSchema, inspectLazyConvertedLabel);
    _ = bindgen.Fn(InspectLazyReceiverIndexSchema, inspectLazyReceiverIndex);
    _ = bindgen.Fn(InspectLazyRestLeaseSchema, inspectLazyRestLease);
    _ = bindgen.Fn(MultiplyAddSchema, multiplyAdd);
    _ = bindgen.Fn(NativeLazyStringLengthSchema, nativeLazyStringLength);
    _ = bindgen.Fn(NativeStringBufferHandleSchema, nativeStringBufferHandle);
    _ = bindgen.Fn(OptionalNativeStringSchema, optionalNativeString);
    _ = bindgen.Fn(NativeStringSequenceLengthSchema, nativeStringSequenceLength);
    _ = bindgen.Fn(NativeCallbackRecordSchema, nativeCallbackRecord);
    _ = bindgen.Fn(RetainCallbackRecordSchema, retainCallbackRecord);
    _ = bindgen.Fn(InspectCallbackRecordViewsSchema, inspectCallbackRecordViews);
    _ = CounterEngineValueSlot;
    _ = CounterEngineValueSlot.view;
    _ = CounterEngineValueSlot.setView;
    _ = CounterEngineValueSlot.setEngineRootOnOwned;
    _ = bindgen.Fn(RequiredAndOptionalArgSchema, requiredAndOptionalArg);
    _ = bindgen.Fn(DOMStringLengthSchema, domStringLength);
    _ = bindgen.Fn(IsolateEngineStringSchema, isolateEngineString);
    _ = bindgen.Fn(EchoDOMStringSchema, echoDOMString);
    _ = bindgen.Fn(EchoUSVStringSchema, echoUSVString);
    _ = bindgen.Fn(EchoByteStringSchema, echoByteString);
    _ = bindgen.Fn(StrictUSVStringSchema, strictUSVString);
    _ = bindgen.Fn(StrictByteStringSchema, strictByteString);
    _ = bindgen.Fn(EchoBufferSchema, echoBuffer);
    _ = bindgen.Fn(FillMutableLeaseSchema, fillMutableLease);
    _ = bindgen.Fn(SetMutableLeaseByteSchema, setMutableLeaseByte);
    _ = bindgen.Fn(InspectInt32FromJSSchema, inspectInt32FromJS);
    _ = bindgen.Fn(InspectLeaseOptionsFromJSSchema, inspectLeaseOptionsFromJS);
    _ = bindgen.Fn(InspectLeaseAfterCallbackSchema, inspectLeaseAfterCallback);
    _ = bindgen.Fn(InspectNestedLeaseAfterCallbackSchema, inspectNestedLeaseAfterCallback);
    _ = bindgen.Fn(EchoNullableBufferSchema, echoNullableBuffer);
    _ = bindgen.Fn(EchoAnySchema, echoAny);
    _ = bindgen.Fn(SnapshotStoredRootsSchema, snapshotStoredRoots);
    _ = bindgen.Fn(PreserveTransferredRootSchema, preserveTransferredRoot);
    _ = bindgen.Fn(ReadIndexViaEngineSchema, readIndexViaEngine);
    _ = bindgen.Fn(SumIntegerWidthsViaEngineSchema, sumIntegerWidthsViaEngine);
    _ = bindgen.Fn(EngineBufferSequenceLengthViaEngineSchema, engineBufferSequenceLengthViaEngine);
    _ = bindgen.Fn(NodePathLengthViaEngineSchema, nodePathLengthViaEngine);
    _ = bindgen.Fn(InvocationThisSchema, invocationThis);
    _ = bindgen.Fn(VisitGCEntriesSchema, visitGCEntries);
    _ = bindgen.Fn(VisitDeferredGCEntriesSchema, visitDeferredGCEntries);
    _ = bindgen.Fn(LeaseWithIgnoredOperandSchema, leaseWithIgnoredOperand);
    _ = bindgen.Fn(InspectNestedLazyFieldsSchema, inspectNestedLazyFields);
    _ = bindgen.Fn(InspectEagerLazyFieldsSchema, inspectEagerLazyFields);
    _ = bindgen.Fn(InspectNestedLazyRestSchema, inspectNestedLazyRest);
    _ = bindgen.Fn(ForceLazyPathSchema, forceLazyPath);
    _ = bindgen.Fn(DescribePatternValuesSchema, describePatternValues);
    _ = bindgen.Fn(RetryLazyStringSchema, retryLazyString);
    _ = bindgen.Fn(CallbackIdentityAfterReentrySchema, callbackIdentityAfterReentry);
    _ = bindgen.Fn(InvokeCallbackSchema, invokeCallback);
    _ = bindgen.Fn(InvokeOwnedCallbackSchema, invokeOwnedCallback);
    _ = bindgen.Fn(ScheduleCallbackSchema, scheduleCallback);
    _ = bindgen.Fn(EchoCallbackSchema, echoCallback);
    _ = bindgen.Fn(InvokeStringCallbackSchema, invokeStringCallback);
    _ = bindgen.Fn(InvokeNullableStringCallbackSchema, invokeNullableStringCallback);
    _ = bindgen.Fn(InvokeBufferCallbackSchema, invokeBufferCallback);
    _ = bindgen.Fn(InvokeAnyCallbackSchema, invokeAnyCallback);
    _ = bindgen.Fn(InvokeCompositeCallbackSchema, invokeCompositeCallback);
    _ = bindgen.Fn(InvokeRestCallbackSchema, invokeRestCallback);
    _ = bindgen.Fn(InvokeTypedRestCallbackSchema, invokeTypedRestCallback);
    _ = bindgen.Fn(InvokeCallbackFactorySchema, invokeCallbackFactory);
    _ = bindgen.Fn(InvokeObserverSchema, invokeObserver);
    _ = bindgen.Fn(InvokeIntegerCallbackSchema, invokeIntegerCallback);
    _ = bindgen.Fn(ClampIntegerSchema, clampInteger);
    _ = bindgen.Fn(ValidateIntegerSchema, validateInteger);
    _ = bindgen.Fn(ValidateNodeBooleanSchema, validateNodeBoolean);
    _ = bindgen.Fn(ValidateNodeNumberSchema, validateNodeNumber);
    _ = bindgen.Fn(ValidateNodeStringSchema, validateNodeString);
    _ = bindgen.Fn(ValidateNodeStringsSchema, validateNodeStrings);
    _ = bindgen.Fn(DefaultStringSchema, defaultString);
    _ = bindgen.Fn(DefaultAnySchema, defaultAny);
    _ = bindgen.Fn(ClassifyPresenceSchema, classifyPresence);
    _ = bindgen.Fn(InspectRestSchema, inspectRest);
    _ = bindgen.Fn(InspectStringRestSchema, inspectStringRest);
    _ = bindgen.Fn(InspectBrandedRestSchema, inspectBrandedRest);
    _ = bindgen.Fn(EchoNullableIntSchema, echoNullableInt);
    _ = bindgen.Fn(ClassifyNullablePresenceSchema, classifyNullablePresence);
    _ = bindgen.Fn(EchoNullableStringSchema, echoNullableString);
    _ = bindgen.Fn(EchoNullableAnySchema, echoNullableAny);
    _ = bindgen.Fn(ReadCounterValueSchema, readCounterValue);
    _ = bindgen.Fn(InspectCounterWrapperHandlesSchema, inspectCounterWrapperHandles);
    _ = bindgen.Fn(ReadSharedCounterValueSchema, readSharedCounterValue);
    _ = bindgen.Fn(DomainErrorSchema, domainError);
    _ = bindgen.Fn(AsyncResultSchema, asyncResult);
    _ = bindgen.Fn(AsyncEchoSchema, asyncEcho);
    _ = bindgen.Fn(AsyncUTF8StringsSchema, asyncUTF8Strings);
    _ = bindgen.Fn(AsyncMaterializedSchema, asyncMaterialized);
    _ = bindgen.Fn(AsyncWeakEchoSchema, asyncWeakEcho);
    _ = bindgen.Fn(AsyncPendingEchoSchema, asyncPendingEcho);
    _ = bindgen.Fn(SetTransferAllocationFailureCountdownSchema, setTransferAllocationFailureCountdown);
    _ = bindgen.Fn(SetWeakAllocationFailureCountdownSchema, setWeakAllocationFailureCountdown);
    _ = bindgen.Fn(SetRootAllocationFailureCountdownSchema, setRootAllocationFailureCountdown);
    _ = CounterClass;
    _ = ScaledCounterClass;
    _ = SharedCounterClass;
    _ = SharedScaledCounterClass;
    _ = CloneBoxClass;
    _ = SweepBoxClass;
    _ = SweepSharedBoxClass;
}

const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;
