bytes: []const u8,
holder: Holder = .none,

const Self = @This();

const Holder = union(enum) {
    none,
    blob: bun.bindgen.RefNative(bun.webcore.Blob.Store, .any),
    body: bun.webcore.Blob.Any,
    string_or_buffer: NodeTypes.StringOrBuffer,
};

pub fn init(context: anytype, data: anytype, encoding: NodeTypes.Encoding) bun.bindgen.CallError(@TypeOf(context))!Self {
    var result: Self = switch (data.*) {
        .buffer => |*lease| .{
            .bytes = lease.unsafePtr("the converted socket-write argument remains alive until the synchronous write or copy completes"),
        },
        .string => |*string_value| string: {
            const holder = try NodeTypes.StringOrBuffer.fromBindgenString(string_value, encoding);
            break :string .{
                .bytes = holder.slice(),
                .holder = .{ .string_or_buffer = holder },
            };
        },
        .blob => |*blob_ref| blob: {
            const value = blob_ref.get();
            break :blob .{
                .bytes = value.sharedView(),
                .holder = if (value.store) |store| .{ .blob = store.clone() } else .none,
            };
        },
        .request => |*request_ref| try fromBody(context, request_ref.get(bun.webcore.Request).getBodyValue()),
        .response => |*response_ref| try fromBody(context, response_ref.get(bun.webcore.Response).getBodyValue()),
    };
    errdefer result.deinit();
    if (result.needsToReadFile()) {
        return context.fail(.socket_file_blob_unsupported, {});
    }
    return result;
}

fn fromBody(context: anytype, body: anytype) bun.bindgen.CallError(@TypeOf(context))!Self {
    try body.toBlobIfPossible();
    const value = (try body.tryUseAsAnyBlob()) orelse {
        return context.fail(.socket_body_not_buffered, {});
    };
    return .{
        .bytes = value.slice(),
        .holder = .{ .body = value },
    };
}

fn needsToReadFile(self: *const Self) bool {
    return switch (self.holder) {
        .blob => |store| store.get().data == .file,
        .body => |*body| body.needsToReadFile(),
        .none, .string_or_buffer => false,
    };
}

pub fn deinit(self: *Self) void {
    var holder = self.holder;
    self.* = .{ .bytes = &.{} };
    switch (holder) {
        inline .blob, .string_or_buffer => |*value| value.deinit(),
        .body => |*body| body.detach(),
        .none => {},
    }
}

const bun = @import("bun");
const NodeTypes = @import("../node/types.zig");
