pub fn verifyErrorInput(this: *const uws.us_bun_verify_error_t) bun.bindgen.SystemError.Init {
    const code = if (this.code == null) "" else this.code[0..bun.len(this.code)];
    const reason = if (this.reason == null) "" else this.reason[0..bun.len(this.reason)];

    return .{ .errno = 0, .code = code, .message = reason };
}

fn socketWriteEncoding(context: anytype, lazy: anytype) bun.JSError!bun.api.node.Encoding {
    const input = lazy orelse return .utf8;
    const converted = try input.convert(context);
    return if (converted.value) |encoding|
        switch (encoding) {
            inline else => |value| @field(bun.api.node.Encoding, @tagName(value)),
        }
    else
        .utf8;
}

fn bindServerSocketWrite(
    context: bun.bindgen.CallContext(ServerSocketWriteSchema),
    args: bun.bindgen.Args(ServerSocketWriteSchema),
) bun.bindgen.CallError(ServerSocketWriteSchema)!bun.bindgen.Return(ServerSocketWriteSchema) {
    const socket = args.bindingThis orelse return .{ .closed = 0 };
    if (!try context.engineIn("NodeHTTP", "serverSocketIsWritable").call(.{ .socket = socket.operand(context) })) return .{ .closed = 0 };
    var input: ?SocketWriteInput = null;
    defer if (input) |*value| value.deinit();
    const data_slice: []const u8 = if (args.data) |lazy| data: {
        const converted = try lazy.convert(context);
        const data = if (converted.value) |*value| value else break :data &.{};
        const encoding = switch (data.*) {
            .string => try socketWriteEncoding(context, args.encoding),
            else => .utf8,
        };
        input = try SocketWriteInput.init(context, data, encoding);
        break :data input.?.bytes;
    } else &.{};
    return context.engineIn("NodeHTTP", "serverSocketWriteBytes").call(.{
        .socket = socket.operand(context),
        .data = bun.bindgen.BytesOperand.fromSlice(data_slice),
    });
}

fn bindSocketBufferedWrite(
    _: bun.bindgen.CallContext(SocketBufferedWriteSchema),
    args: bun.bindgen.Args(SocketBufferedWriteSchema),
) bun.JSError!bun.bindgen.Return(SocketBufferedWriteSchema) {
    const socket: *uws.us_socket_t = @ptrCast(@alignCast(args.socket));
    const buffer = args.buffer;
    const stream_buffer = &buffer.stream;
    const data_slice = args.data.unsafePtr("the generated native-export frame owns the copied bytes until the synchronous socket write and tail buffering finish");
    var total_written: usize = 0;
    defer buffer.wrote(total_written);

    if (stream_buffer.isEmpty()) {
        stream_buffer.list.clearRetainingCapacity();
        stream_buffer.cursor = 0;
    }
    try stream_buffer.ensureUnusedCapacity(data_slice.len);
    if (stream_buffer.isNotEmpty()) {
        const to_flush = stream_buffer.slice();
        const written: u32 = @max(0, socket.write(to_flush));
        stream_buffer.wrote(written);
        total_written +|= written;
        if (written < to_flush.len) {
            if (data_slice.len > 0) {
                stream_buffer.writeAssumeCapacity(data_slice);
            }
            return false;
        }
    }

    if (data_slice.len > 0) {
        const written: u32 = @max(0, socket.write(data_slice));
        total_written +|= written;
        if (written < data_slice.len) {
            stream_buffer.writeAssumeCapacity(data_slice[written..]);
            return false;
        }
    }
    if (args.ended) {
        socket.shutdown();
    }
    return true;
}

fn bindSocketStreamBufferCreate(
    _: bun.bindgen.CallContext(SocketStreamBufferCreateSchema),
    _: bun.bindgen.Args(SocketStreamBufferCreateSchema),
) bun.JSError!bun.bindgen.Return(SocketStreamBufferCreateSchema) {
    return bun.bindgen.Return(SocketStreamBufferCreateSchema).initNative(try bun.tryNew(uws.us_socket_stream_buffer_t, .{}));
}

fn bindSocketStreamBufferDeinit(args: bun.bindgen.Args(SocketStreamBufferDeinitSchema)) void {
    args.buffer.deinit();
}

fn bindSocketStreamBufferSize(args: bun.bindgen.Args(SocketStreamBufferSizeSchema)) usize {
    return args.buffer.stream.size();
}

fn bindSocketStreamBufferTotalWritten(args: bun.bindgen.Args(SocketStreamBufferTotalWrittenSchema)) usize {
    return args.buffer.total_bytes_written;
}

fn bindWarnExtraCALoadFailed(args: bun.bindgen.Args(WarnExtraCALoadFailedSchema)) void {
    const filename = args.filename.unsafePtr("the native certificate loader owns the filename until synchronous warning output finishes");
    const message = args.message.unsafePtr("the native certificate loader keeps its error buffer on the stack until synchronous warning output finishes");
    bun.Output.warn("ignoring extra certs from {s}, load failed: {s}", .{ filename, message });
}

const bun = @import("bun");
const SocketWriteInput = @import("./SocketWriteInput.zig");
const SocketBindings = bun.bindgen.Module("Socket");
const ServerSocketWriteSchema = bun.bindgen.Module("NodeHTTP").function("serverSocketWrite");
const ServerSocketWriteBinding = bun.bindgen.Fn(ServerSocketWriteSchema, bindServerSocketWrite);
const SocketBufferedWriteSchema = SocketBindings.nativeExport("socketBufferedWrite");
const SocketBufferedWriteBinding = bun.bindgen.Fn(SocketBufferedWriteSchema, bindSocketBufferedWrite);
const SocketStreamBufferCreateSchema = SocketBindings.nativeExport("socketStreamBufferCreate");
const SocketStreamBufferCreateBinding = bun.bindgen.Fn(SocketStreamBufferCreateSchema, bindSocketStreamBufferCreate);
const SocketStreamBufferDeinitSchema = SocketBindings.nativeExport("socketStreamBufferDeinit");
const SocketStreamBufferDeinitBinding = bun.bindgen.Fn(SocketStreamBufferDeinitSchema, bindSocketStreamBufferDeinit);
const SocketStreamBufferSizeSchema = SocketBindings.nativeExport("socketStreamBufferSize");
const SocketStreamBufferSizeBinding = bun.bindgen.Fn(SocketStreamBufferSizeSchema, bindSocketStreamBufferSize);
const SocketStreamBufferTotalWrittenSchema = SocketBindings.nativeExport("socketStreamBufferTotalWritten");
const SocketStreamBufferTotalWrittenBinding = bun.bindgen.Fn(SocketStreamBufferTotalWrittenSchema, bindSocketStreamBufferTotalWritten);
const WarnExtraCALoadFailedSchema = SocketBindings.nativeExport("warnExtraCALoadFailed");
const WarnExtraCALoadFailedBinding = bun.bindgen.Fn(WarnExtraCALoadFailedSchema, bindWarnExtraCALoadFailed);

comptime {
    _ = ServerSocketWriteBinding;
    _ = SocketBufferedWriteBinding;
    _ = SocketStreamBufferCreateBinding;
    _ = SocketStreamBufferDeinitBinding;
    _ = SocketStreamBufferSizeBinding;
    _ = SocketStreamBufferTotalWrittenBinding;
    _ = WarnExtraCALoadFailedBinding;
}

const uws = bun.uws;
