pub const Reader = struct {
    const U8Schema = FFIBindings.function("readerU8");
    const U16Schema = FFIBindings.function("readerU16");
    const U32Schema = FFIBindings.function("readerU32");
    const ReaderPtrSchema = FFIBindings.function("readerPtr");
    const I8Schema = FFIBindings.function("readerI8");
    const I16Schema = FFIBindings.function("readerI16");
    const I32Schema = FFIBindings.function("readerI32");
    const I64Schema = FFIBindings.function("readerI64");
    const U64Schema = FFIBindings.function("readerU64");
    const IntptrSchema = FFIBindings.function("readerIntptr");
    const F32Schema = FFIBindings.function("readerF32");
    const F64Schema = FFIBindings.function("readerF64");

    pub const bindings = .{
        .u8 = bun.bindgen.Fn(U8Schema, @"u8"),
        .u16 = bun.bindgen.Fn(U16Schema, @"u16"),
        .u32 = bun.bindgen.Fn(U32Schema, @"u32"),
        .ptr = bun.bindgen.Fn(ReaderPtrSchema, @This().ptr),
        .i8 = bun.bindgen.Fn(I8Schema, @"i8"),
        .i16 = bun.bindgen.Fn(I16Schema, @"i16"),
        .i32 = bun.bindgen.Fn(I32Schema, @"i32"),
        .i64 = bun.bindgen.Fn(I64Schema, @"i64"),
        .u64 = bun.bindgen.Fn(U64Schema, @"u64"),
        .intptr = bun.bindgen.Fn(IntptrSchema, intptr),
        .f32 = bun.bindgen.Fn(F32Schema, @"f32"),
        .f64 = bun.bindgen.Fn(F64Schema, @"f64"),
    };

    fn scalarReader(comptime Schema: type, comptime T: type) type {
        return struct {
            fn call(context: bun.bindgen.CallContext(Schema), args: bun.bindgen.Args(Schema)) bun.bindgen.CallError(Schema)!bun.bindgen.Return(Schema) {
                if (args.pointer == 0) return context.fail(.zero_pointer, {});
                const addr = std.math.add(usize, args.pointer, args.byte_offset orelse 0) catch
                    return context.fail(.address_overflow, {});
                _ = std.math.add(usize, addr, @sizeOf(T) - 1) catch
                    return context.fail(.address_overflow, {});
                return @as(*align(1) const T, @ptrFromInt(addr)).*;
            }
        };
    }

    pub const @"u8" = scalarReader(U8Schema, u8).call;
    pub const @"u16" = scalarReader(U16Schema, u16).call;
    pub const @"u32" = scalarReader(U32Schema, u32).call;
    pub const ptr = scalarReader(ReaderPtrSchema, usize).call;
    pub const @"i8" = scalarReader(I8Schema, i8).call;
    pub const @"i16" = scalarReader(I16Schema, i16).call;
    pub const @"i32" = scalarReader(I32Schema, i32).call;
    pub const intptr = scalarReader(IntptrSchema, i64).call;
    pub const @"f32" = scalarReader(F32Schema, f32).call;
    pub const @"f64" = scalarReader(F64Schema, f64).call;
    pub const @"i64" = scalarReader(I64Schema, i64).call;
    pub const @"u64" = scalarReader(U64Schema, u64).call;
};

fn bindPtr(
    context: bun.bindgen.CallContext(PtrSchema),
    args: bun.bindgen.Args(PtrSchema),
) bun.bindgen.CallError(PtrSchema)!?usize {
    const view = args.value orelse return null;
    const length = view.length();
    if (length == 0) return context.fail(.empty_view, {});

    const offset = args.byte_offset orelse 0;
    if (offset > length) return context.fail(.offset_out_of_bounds, {});

    const base = @intFromPtr(view.unsafePtr("FFI.ptr returns the caller's original buffer address; the caller keeps the buffer alive and prevents resize or detachment until all native uses finish").ptr);
    const addr = std.math.add(usize, base, offset) catch return context.fail(.invalid_pointer, {});
    if (addr == 0) return context.fail(.invalid_pointer, {});

    return addr;
}

const PointerViewError = error{
    ZeroPointer,
    ZeroLength,
    LengthTooLarge,
    InvalidPointer,
};

fn getPtrSlice(value: usize, byteOffset: ?i64, byteLength: ?usize) PointerViewError![]u8 {
    if (value == 0) {
        return error.ZeroPointer;
    }
    var addr = value;

    if (byteOffset) |offset| {
        if (offset < 0) {
            addr = std.math.sub(usize, addr, @intCast(@abs(offset))) catch return error.InvalidPointer;
        } else {
            addr = std.math.add(usize, addr, @intCast(offset)) catch return error.InvalidPointer;
        }

        if (addr == 0) {
            return error.ZeroPointer;
        }
    }

    if (byteLength) |length| {
        if (length == 0) {
            return error.ZeroLength;
        }
        _ = std.math.add(usize, addr, length) catch return error.LengthTooLarge;
        return @as([*]u8, @ptrFromInt(addr))[0..length];
    }

    return bun.span(@as([*:0]u8, @ptrFromInt(addr)));
}

fn pointerSlice(
    context: anytype,
    pointer: usize,
    byte_offset: ?i64,
    byte_length: ?usize,
) bun.bindgen.CallError(@TypeOf(context))![]u8 {
    return getPtrSlice(pointer, byte_offset, byte_length) catch |err| switch (err) {
        error.ZeroPointer => context.fail(.zero_pointer, {}),
        error.ZeroLength => context.fail(.zero_length, {}),
        error.LengthTooLarge => context.fail(.length_too_large, {}),
        error.InvalidPointer => context.fail(.invalid_pointer, {}),
    };
}

const Finalizer = struct {
    context: ?usize,
    callback: ?usize,
};

const UnsafeExternalMemory = struct {
    bytes: []u8,

    fn unsafePtr(this: @This(), comptime reason: []const u8) *u8 {
        if (reason.len == 0) @compileError("unsafePtr requires a non-empty lifetime reason");
        return &this.bytes[0];
    }
};

fn parseFinalizer(
    context: anytype,
    context_or_callback: ?usize,
    callback: ?usize,
) bun.bindgen.CallError(@TypeOf(context))!Finalizer {
    if (callback) |callback_address| {
        if (callback_address == 0) return context.fail(.invalid_finalizer, {});
        return .{ .context = if ((context_or_callback orelse 0) != 0) context_or_callback else null, .callback = callback_address };
    }
    if (context_or_callback) |callback_address| {
        if (callback_address == 0) return context.fail(.invalid_finalizer, {});
        return .{ .context = null, .callback = callback_address };
    }
    return .{ .context = null, .callback = null };
}

const CompileSchema = FFIBindings.function("compile");
const ViewSourceSymbolsSchema = FFIBindings.function("viewSourceSymbols");
const ViewSourceCallbackSchema = FFIBindings.function("viewSourceCallback");
const DlopenSchema = FFIBindings.function("dlopen");
const CallbackSchema = FFIBindings.function("callback");
const LinkSymbolsSchema = FFIBindings.function("linkSymbols");
const ToBufferSchema = FFIBindings.function("toBuffer");
const ToArrayBufferSchema = FFIBindings.function("toArrayBuffer");
const CStringSchema = FFIBindings.function("CString");

const CompileBinding = bun.bindgen.Fn(CompileSchema, bindCompile);
const ViewSourceSymbolsBinding = bun.bindgen.Fn(ViewSourceSymbolsSchema, bindViewSourceSymbols);
const ViewSourceCallbackBinding = bun.bindgen.Fn(ViewSourceCallbackSchema, bindViewSourceCallback);
const DlopenBinding = bun.bindgen.Fn(DlopenSchema, bindDlopen);
const CallbackBinding = bun.bindgen.Fn(CallbackSchema, bindCallback);
const LinkSymbolsBinding = bun.bindgen.Fn(LinkSymbolsSchema, bindLinkSymbols);
const ToBufferBinding = bun.bindgen.Fn(ToBufferSchema, bindToBuffer);
const ToArrayBufferBinding = bun.bindgen.Fn(ToArrayBufferSchema, bindToArrayBuffer);
const CStringBinding = bun.bindgen.Fn(CStringSchema, bindCString);

fn bindCompile(
    context: bun.bindgen.CallContext(CompileSchema),
    args: bun.bindgen.Args(CompileSchema),
) bun.bindgen.CallError(CompileSchema)!bun.bindgen.Return(CompileSchema) {
    return bun.api.FFIObjectEngine.compile(context, args);
}

fn bindViewSourceSymbols(
    context: bun.bindgen.CallContext(ViewSourceSymbolsSchema),
    args: bun.bindgen.Args(ViewSourceSymbolsSchema),
) bun.bindgen.CallError(ViewSourceSymbolsSchema)!bun.bindgen.Return(ViewSourceSymbolsSchema) {
    var sources = try FFI.printSymbols(context, &args.symbols);
    defer {
        for (sources.items) |source| bun.default_allocator.free(source);
        sources.deinit(bun.default_allocator);
    }
    return bun.bindgen.Return(ViewSourceSymbolsSchema).fromUTF8Slices(sources.items);
}

fn bindViewSourceCallback(
    context: bun.bindgen.CallContext(ViewSourceCallbackSchema),
    args: bun.bindgen.Args(ViewSourceCallbackSchema),
) bun.bindgen.CallError(ViewSourceCallbackSchema)!bun.bindgen.DOMString {
    const source = try FFI.printCallback(context, &args.definition);
    defer bun.default_allocator.free(source);
    return bun.bindgen.DOMString.fromUTF8(source);
}

fn bindDlopen(
    context: bun.bindgen.CallContext(DlopenSchema),
    args: bun.bindgen.Args(DlopenSchema),
) bun.bindgen.CallError(DlopenSchema)!bun.bindgen.Return(DlopenSchema) {
    return bun.api.FFIObjectEngine.dlopen(context, args);
}

fn bindCallback(
    context: bun.bindgen.CallContext(CallbackSchema),
    args: bun.bindgen.Args(CallbackSchema),
) bun.bindgen.CallError(CallbackSchema)!bun.bindgen.Return(CallbackSchema) {
    return FFI.callback(context, args);
}

fn bindLinkSymbols(
    context: bun.bindgen.CallContext(LinkSymbolsSchema),
    args: bun.bindgen.Args(LinkSymbolsSchema),
) bun.bindgen.CallError(LinkSymbolsSchema)!bun.bindgen.Return(LinkSymbolsSchema) {
    return FFI.linkSymbols(context, &args.symbols);
}

fn bindToBuffer(
    context: bun.bindgen.CallContext(ToBufferSchema),
    args: bun.bindgen.Args(ToBufferSchema),
) bun.bindgen.CallError(ToBufferSchema)!bun.bindgen.Return(ToBufferSchema) {
    const bytes = try pointerSlice(context, args.pointer, args.byteOffset, args.byteLength);
    const finalizer = try parseFinalizer(
        context,
        args.finalizationContextOrCallback,
        args.finalizationCallback,
    );
    if (finalizer.callback) |callback_address| {
        const operation = context.engineIn("array_buffers", "bufferAdoptOwnedBytes");
        const EngineArgs = @TypeOf(operation).Args;
        const Owner = @FieldType(EngineArgs, "owner");
        const deallocator: bun.bindgen.ExternalBytesDeallocator = @ptrFromInt(callback_address);
        const finalizer_context: ?*anyopaque = if (finalizer.context) |address| @ptrFromInt(address) else null;
        var engine_args: EngineArgs = .{
            .owner = Owner.initNative(try bun.bindgen.adoptExternalBytesOwner(bytes.ptr, bytes.len, finalizer_context, deallocator)),
        };
        return operation.call(&engine_args);
    }

    const memory: UnsafeExternalMemory = .{ .bytes = bytes };
    return context.engineIn("array_buffers", "bufferBorrowExternalMemoryUnsafe").call(.{
        .data = memory.unsafePtr("The FFI caller owns this allocation and keeps it alive until all JavaScript views of the returned Buffer are unreachable"),
        .length = bytes.len,
    });
}

fn bindToArrayBuffer(
    context: bun.bindgen.CallContext(ToArrayBufferSchema),
    args: bun.bindgen.Args(ToArrayBufferSchema),
) bun.bindgen.CallError(ToArrayBufferSchema)!bun.bindgen.Return(ToArrayBufferSchema) {
    const slice = try pointerSlice(context, args.pointer, args.byteOffset, args.byteLength);
    const finalizer = try parseFinalizer(
        context,
        args.finalizationContextOrCallback,
        args.finalizationCallback,
    );
    if (finalizer.callback) |callback_address| {
        const operation = context.engineIn("array_buffers", "arrayBufferAdoptOwnedBytes");
        const EngineArgs = @TypeOf(operation).Args;
        const Owner = @FieldType(EngineArgs, "owner");
        const deallocator: bun.bindgen.ExternalBytesDeallocator = @ptrFromInt(callback_address);
        const finalizer_context: ?*anyopaque = if (finalizer.context) |address| @ptrFromInt(address) else null;
        var engine_args: EngineArgs = .{
            .owner = Owner.initNative(try bun.bindgen.adoptExternalBytesOwner(slice.ptr, slice.len, finalizer_context, deallocator)),
        };
        return operation.call(&engine_args);
    }

    const memory: UnsafeExternalMemory = .{ .bytes = slice };
    return context.engineIn("array_buffers", "arrayBufferBorrowExternalMemoryUnsafe").call(.{
        .data = memory.unsafePtr("The FFI caller owns this allocation and keeps it alive until all JavaScript views of the returned ArrayBuffer are unreachable"),
        .length = slice.len,
    });
}

fn bindCString(
    context: bun.bindgen.CallContext(CStringSchema),
    args: bun.bindgen.Args(CStringSchema),
) bun.bindgen.CallError(CStringSchema)!bun.bindgen.DOMString {
    const slice = try pointerSlice(context, args.pointer, args.byteOffset, args.byteLength);
    return bun.bindgen.DOMString.fromUTF8(slice);
}

const std = @import("std");

const bun = @import("bun");
const FFI = @import("./ffi.zig").FFI;

const FFIBindings = bun.bindgen.Module("FFI");
const PtrSchema = FFIBindings.function("ptr");
const PtrBinding = bun.bindgen.Fn(PtrSchema, bindPtr);

comptime {
    _ = CompileBinding;
    _ = PtrBinding;
    _ = ViewSourceSymbolsBinding;
    _ = ViewSourceCallbackBinding;
    _ = DlopenBinding;
    _ = CallbackBinding;
    _ = LinkSymbolsBinding;
    _ = ToBufferBinding;
    _ = ToArrayBufferBinding;
    _ = CStringBinding;
    for (std.meta.fieldNames(@TypeOf(Reader.bindings))) |field| {
        _ = @field(Reader.bindings, field);
    }
}
