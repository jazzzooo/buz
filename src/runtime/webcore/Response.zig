const Response = @This();

const ResponseMixin = BodyMixin(@This());

pub const Handle = ResponseClass.Handle;
pub const Ref = bun.bindgen.ClassRef(ResponseSchema);

bindgen_state: bun.bindgen.ClassState = .{},
body: Body,
response_init: Init,
url: bun.bindgen.DOMString = .empty(),
redirected: bool = false,
/// We increment this count in fetch so if JS Response is discarted we can resolve the Body
/// In the server we use a flag response_protected to protect/unprotect the response
ref_count: u32 = 1,
/// Bun.serve's RequestContext holds a weak reference so `onAbort` /
/// `handleResolveStream` / `handleRejectStream` can safely observe that the
/// Response was GC'd (null) instead of dereferencing a freed pointer when
/// backpressure lets GC run between `render()` and the async callback.
weak_ptr_data: WeakRef.Data = .empty,
wrapper: bun.bindgen.WrapperReference(.{ResponseSchema}) = .empty(),

// We must report a consistent value for this
reported_estimated_size: usize = 0,

pub const WeakRef = bun.ptr.WeakPtr(Response, "weak_ptr_data");

pub const getText = ResponseMixin.getText;
pub const getBody = ResponseMixin.getBody;
pub const getBytes = ResponseMixin.getBytes;
pub const getBodyUsed = ResponseMixin.getBodyUsed;
pub const getJSON = ResponseMixin.getJSON;
pub const getArrayBuffer = ResponseMixin.getArrayBuffer;
pub const getBlob = ResponseMixin.getBlob;
pub const getBlobWithoutWrapper = ResponseMixin.getBlobWithoutWrapper;
pub const getFormData = ResponseMixin.getFormData;

pub fn init(response_init: Init, body: Body, url: bun.bindgen.DOMString, redirected: bool) Response {
    return Response{
        .response_init = response_init,
        .body = body,
        .url = url,
        .redirected = redirected,
    };
}

pub fn create(value: Response) bun.OOM!*Response {
    var owned = value;
    errdefer owned.deinit();
    const response = try bun.default_allocator.create(Response);
    response.* = owned;
    return response;
}

pub inline fn setInit(this: *Response, method: Method, status_code: u16, status_text: bun.bindgen.DOMString) void {
    this.response_init.method = method;
    this.response_init.status_code = status_code;
    this.response_init.status_text.deinit();
    this.response_init.status_text = status_text;
}
pub inline fn setInitHeaders(this: *Response, headers: ?FetchHeaders.Owner) void {
    if (this.response_init.headers) |*existing| {
        existing.deinit();
    }
    this.response_init.headers = headers;
}
pub inline fn getInitStatusCode(this: *Response) u16 {
    return this.response_init.status_code;
}
pub inline fn getInitStatusText(this: *const Response) *const bun.bindgen.DOMString {
    return &this.response_init.status_text;
}
pub inline fn setUrl(this: *Response, url: bun.bindgen.DOMString) void {
    this.url.deinit();
    this.url = url;
}
pub inline fn getUTF8Url(this: *Response, allocator: std.mem.Allocator) bun.OOM!bun.String.Slice {
    return this.url.toUTF8(allocator);
}
pub inline fn getUrl(this: *const Response) *const bun.bindgen.DOMString {
    return &this.url;
}
pub inline fn getInitHeaders(this: *Response) ?*FetchHeaders {
    return if (this.response_init.headers) |headers| headers.get() else null;
}
pub fn retainInitHeaders(this: *Response) ?FetchHeaders.Owner {
    return if (this.response_init.headers) |headers| headers.get().retain() else null;
}
pub inline fn getBodyLen(this: *Response) usize {
    return this.body.len();
}
pub inline fn getMethod(this: *Response) Method {
    return this.response_init.method;
}
pub fn getFormDataEncoding(this: *Response) bun.JSError!?bun.FormData.OwnedEncoding {
    var content_type_slice: bun.String.Slice = (try this.getContentType()) orelse return null;
    defer content_type_slice.deinit();
    const encoding = bun.FormData.Encoding.get(content_type_slice.slice()) orelse return null;
    return try bun.FormData.OwnedEncoding.init(encoding);
}

pub fn memoryUsage(this: *const Response, _: bun.bindgen.MemoryUsageContext(.any)) usize {
    return this.reported_estimated_size;
}

pub fn calculateEstimatedByteSize(this: *Response) void {
    this.reported_estimated_size = this.body.value.estimatedSize() +
        this.url.byteLength() +
        this.response_init.status_text.byteLength() +
        @sizeOf(Response);
}

fn checkBodyStreamRef(this: *Response, wrapper: bun.bindgen.ClassRefView(ResponseSchema)) void {
    if (this.body.value == .Locked) {
        if (this.body.value.Locked.readable.cloneOwned()) |owned_stream_value| {
            var owned_stream = owned_stream_value;
            defer owned_stream.deinit();
            ResponseStreamSlot.setOwnedBranded(wrapper, &owned_stream);
            this.body.value.Locked.readable.deinit();
            this.body.value.Locked.readable = .{};
        }
    }
}
pub fn toResult(this: *Response, context: anytype) bun.JSError!Ref {
    this.calculateEstimatedByteSize();
    return ResponseClass.adoptResult(this, context);
}

pub fn toClassRef(this: *Response, global: *jsc.JSGlobalObject) bun.JSError!Ref {
    this.calculateEstimatedByteSize();
    return ResponseClass.adoptNativeRef(this, global);
}

pub inline fn getBodyValue(
    this: *Response,
) *Body.Value {
    return &this.body.value;
}

pub inline fn getBodyReadableStream(
    this: *Response,
    globalObject: *JSGlobalObject,
) bun.JSError!?jsc.WebCore.ReadableStream.Strong {
    _ = this.ref();
    defer this.unref();
    if (try ResponseStreamSlot.ownedBrandedFromReference(&this.wrapper)) |stream_value| {
        _ = globalObject;
        return try jsc.WebCore.ReadableStream.Strong.initOwned(stream_value);
    }
    if (this.body.value == .Locked) {
        const readable = &this.body.value.Locked.readable;
        if (readable.has()) return readable.clone();
    }
    return null;
}
pub inline fn detachReadableStream(this: *Response, globalObject: *jsc.JSGlobalObject) bun.JSError!void {
    _ = globalObject;
    _ = this.ref();
    defer this.unref();
    defer if (this.body.value == .Locked) {
        var old = this.body.value.Locked.detachReadable();
        old.deinit();
    };
    try ResponseStreamSlot.clearOnReference(&this.wrapper);
}
pub inline fn setSizeHint(this: *Response, size_hint: Blob.SizeType) void {
    if (this.body.value == .Locked) {
        this.body.value.Locked.size_hint = size_hint;
        if (this.body.value.Locked.readable.byteStream()) |bytes| bytes.size_hint = size_hint;
    }
}

pub fn requestOrResponseHasBodyValue(
    _: bun.bindgen.CallContext(RequestOrResponseHasBodyValueSchema),
    args: bun.bindgen.Args(RequestOrResponseHasBodyValueSchema),
) bun.JSError!bool {
    return switch (args.value) {
        .response => |response| !response.get(Response).body.value.isDefinitelyEmpty(),
        .request => |request| !request.get(Request).getBodyValue().isDefinitelyEmpty(),
        .ignored => false,
    };
}

pub fn getCompleteRequestOrResponseBodyValueAsArrayBuffer(
    _: bun.bindgen.CallContext(GetCompleteRequestOrResponseBodyValueAsArrayBufferSchema),
    args: bun.bindgen.Args(GetCompleteRequestOrResponseBodyValueAsArrayBufferSchema),
) bun.JSError!?bun.bindgen.OwnedBytes {
    return switch (args.value) {
        .response => |response| completeBodyValueAsArrayBuffer(&response.get(Response).body.value),
        .request => |request| completeBodyValueAsArrayBuffer(request.get(Request).getBodyValue()),
        .ignored => null,
    };
}

fn completeBodyValueAsArrayBuffer(body: *Body.Value) bun.OOM!?bun.bindgen.OwnedBytes {
    switch (body.*) {
        .Used, .Empty, .Null => return null,
        .Blob => |*blob| {
            if (blob.isBunFile()) return null;
        },
        .WTFStringImpl, .InternalBlob => {},
        .Error, .Locked => return null,
    }
    var any_blob = try body.useAsAnyBlob();
    defer any_blob.detach();
    return try bun.bindgen.OwnedBytes.fromSlice(any_blob.slice());
}

pub fn getFetchHeaders(
    this: *Response,
) ?*FetchHeaders {
    return if (this.response_init.headers) |headers| headers.get() else null;
}

pub inline fn statusCode(this: *const Response) u16 {
    return this.response_init.status_code;
}

pub const Props = struct {};

pub fn isOK(this: *const Response) bool {
    return this.response_init.status_code >= 200 and this.response_init.status_code <= 299;
}

pub fn getURL(
    this: *Response,
) bun.OOM!bun.bindgen.DOMString {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/url
    return this.url.clone();
}

pub fn getResponseType(
    this: *Response,
) bun.OOM!bun.bindgen.DOMString {
    if (this.response_init.status_code < 200) {
        return bun.bindgen.DOMString.fromUTF8("error");
    }

    return bun.bindgen.DOMString.fromUTF8("default");
}

pub fn getStatusText(
    this: *Response,
) bun.OOM!bun.bindgen.DOMString {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/statusText
    return this.response_init.status_text.clone();
}

pub fn getRedirected(
    this: *Response,
) bool {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/redirected
    return this.redirected;
}

pub fn getOK(
    this: *Response,
) bool {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/ok
    return this.isOK();
}

pub fn getOrCreateHeaders(this: *Response, globalThis: *jsc.JSGlobalObject) bun.JSError!*FetchHeaders {
    if (this.response_init.headers == null) {
        this.response_init.headers = try FetchHeaders.createEmpty();

        if (this.body.value == .Blob) {
            const content_type = this.body.value.Blob.content_type.slice();
            if (content_type.len > 0) {
                try this.response_init.headers.?.get().put(.ContentType, content_type, globalThis);
            }
        }
    }

    return this.response_init.headers.?.get();
}

pub fn doClone(
    this: *Response,
    globalThis: *jsc.JSGlobalObject,
    this_value: bun.bindgen.ClassRefView(ResponseSchema),
) bun.JSError!bun.bindgen.Return(ResponseCloneMemberSchema) {
    const cloned = try this.clone(globalThis);

    var cloned_ref = try cloned.toClassRef(globalThis);

    // Wrapping moves Locked.readable into the cached stream slot.
    ResponseClass.copyCachedSlotOwned("stream", "body", &cloned_ref);

    // Update the original response's body cache with the new teed stream.
    // At this point, this.body.value.Locked.readable still holds the teed stream
    // because checkBodyStreamRef hasn't been called on the original response yet.
    const update_body_cache = this.body.value == .Locked;
    this.checkBodyStreamRef(this_value);
    if (update_body_cache) {
        ResponseClass.copyCachedSlot("stream", "body", this_value);
    }

    return cloned_ref;
}

fn getBodyFromBinding(
    context: anytype,
    response: *Response,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    var body = (try response.getBody(globalThis)) orelse return null;
    defer body.deinit();
    return body.toResult(context);
}

fn getBodyUsedFromBinding(
    context: anytype,
    response: *Response,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return response.getBodyUsed(globalThis);
}

fn cloneMemberFromBinding(
    context: anytype,
    input: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return input.response.doClone(globalThis, input.args.bindingThis);
}

fn getHeadersFromBinding(
    context: anytype,
    response: *Response,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    const Headers = @import("./Headers.zig");
    const resource = try response.getOrCreateHeaders(globalThis);
    return Headers.Binding.adoptResult(try Headers.create(resource.retain()), context);
}

pub fn bindGetArrayBuffer(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseArrayBufferSchema),
    args: bun.bindgen.Args(ResponseArrayBufferSchema),
) bun.bindgen.CallError(ResponseArrayBufferSchema)!void {
    return try this.getArrayBuffer(context, args.bindingThis);
}

pub fn bindGetBlob(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseBlobSchema),
    args: bun.bindgen.Args(ResponseBlobSchema),
) bun.bindgen.CallError(ResponseBlobSchema)!void {
    return try this.getBlob(context, args.bindingThis);
}

pub fn bindGetBody(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseBodySchema),
    _: bun.bindgen.Args(ResponseBodySchema),
) bun.JSError!bun.bindgen.Return(ResponseBodySchema) {
    return getBodyFromBinding(context, this);
}

pub fn bindGetBodyUsed(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseBodyUsedSchema),
    _: bun.bindgen.Args(ResponseBodyUsedSchema),
) bun.JSError!bool {
    return getBodyUsedFromBinding(context, this);
}

pub fn bindGetBytes(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseBytesSchema),
    args: bun.bindgen.Args(ResponseBytesSchema),
) bun.bindgen.CallError(ResponseBytesSchema)!void {
    return try this.getBytes(context, args.bindingThis);
}

pub fn bindClone(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseCloneMemberSchema),
    args: bun.bindgen.Args(ResponseCloneMemberSchema),
) bun.JSError!bun.bindgen.Return(ResponseCloneMemberSchema) {
    return cloneMemberFromBinding(context, .{ .response = this, .args = args });
}

pub fn bindGetFormData(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseFormDataSchema),
    args: bun.bindgen.Args(ResponseFormDataSchema),
) bun.bindgen.CallError(ResponseFormDataSchema)!void {
    return try this.getFormData(context, args.bindingThis);
}

pub fn inspectCustom(_: *Response, context: bun.bindgen.CallContext(ResponseInspectSchema), args: bun.bindgen.Args(ResponseInspectSchema)) bun.JSError!bun.bindgen.DOMString {
    return @import("./ResponseEngine.zig").inspect(context, args);
}

pub fn bindGetHeaders(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseHeadersSchema),
    _: bun.bindgen.Args(ResponseHeadersSchema),
) bun.JSError!bun.bindgen.Return(ResponseHeadersSchema) {
    return getHeadersFromBinding(context, this);
}

pub fn bindGetJSON(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseJSONSchema),
    args: bun.bindgen.Args(ResponseJSONSchema),
) bun.bindgen.CallError(ResponseJSONSchema)!void {
    return try this.getJSON(context, args.bindingThis);
}

pub fn bindGetOK(
    this: *Response,
    _: bun.bindgen.CallContext(ResponseOKSchema),
    _: bun.bindgen.Args(ResponseOKSchema),
) bun.JSError!bool {
    return this.getOK();
}

pub fn bindGetRedirected(
    this: *Response,
    _: bun.bindgen.CallContext(ResponseRedirectedSchema),
    _: bun.bindgen.Args(ResponseRedirectedSchema),
) bun.JSError!bool {
    return this.getRedirected();
}

pub fn bindGetStatus(
    this: *Response,
    _: bun.bindgen.CallContext(ResponseStatusSchema),
    _: bun.bindgen.Args(ResponseStatusSchema),
) bun.JSError!u16 {
    return this.getStatus();
}

pub fn bindGetStatusText(
    this: *Response,
    _: bun.bindgen.CallContext(ResponseStatusTextSchema),
    _: bun.bindgen.Args(ResponseStatusTextSchema),
) bun.JSError!bun.bindgen.DOMString {
    return this.getStatusText();
}

pub fn bindGetText(
    this: *Response,
    context: bun.bindgen.CallContext(ResponseTextSchema),
    args: bun.bindgen.Args(ResponseTextSchema),
) bun.bindgen.CallError(ResponseTextSchema)!void {
    return try this.getText(context, args.bindingThis);
}

pub fn bindGetResponseType(
    this: *Response,
    _: bun.bindgen.CallContext(ResponseTypeSchema),
    _: bun.bindgen.Args(ResponseTypeSchema),
) bun.JSError!bun.bindgen.DOMString {
    return this.getResponseType();
}

pub fn bindGetURL(
    this: *Response,
    _: bun.bindgen.CallContext(ResponseURLSchema),
    _: bun.bindgen.Args(ResponseURLSchema),
) bun.JSError!bun.bindgen.DOMString {
    return this.getURL();
}

pub fn cloneValue(
    this: *Response,
    globalThis: *JSGlobalObject,
) bun.JSError!Response {
    var body = brk: {
        if (try ResponseStreamSlot.ownedBrandedFromReference(&this.wrapper)) |stream_value| {
            var readable = try jsc.WebCore.ReadableStream.Strong.initOwned(stream_value);
            defer readable.deinit();
            break :brk try this.body.cloneWithReadableStream(globalThis, &readable);
        }

        break :brk try this.body.clone(globalThis);
    };
    errdefer body.deinit(bun.default_allocator);
    var _init = try this.response_init.clone();
    errdefer _init.deinit(bun.default_allocator);
    return Response{
        .body = body,
        .response_init = _init,
        .url = this.url.clone(),
        .redirected = this.redirected,
    };
}

pub fn clone(this: *Response, globalThis: *JSGlobalObject) bun.JSError!*Response {
    return create(try this.cloneValue(globalThis));
}

pub fn getStatus(
    this: *Response,
) u16 {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/status
    return this.response_init.status_code;
}

fn deinit(this: *Response) void {
    this.response_init.deinit(bun.default_allocator);
    this.body.deinit(bun.default_allocator);
    this.url.deinit();
    this.wrapper.deinit();
}

fn destroyAllocation(this: *Response) void {
    this.deinit();
    // Contents are gone; the allocation itself stays until any outstanding
    // WeakRef derefs (RequestContext.response_weakref). WeakRef.get() returns
    // null from here on.
    if (this.weak_ptr_data.onFinalize()) {
        bun.destroy(this);
    }
}

pub fn ref(this: *Response) *Response {
    this.ref_count += 1;
    return this;
}

pub fn unref(this: *Response) void {
    bun.assert(this.ref_count > 0);
    this.ref_count -= 1;
    if (this.ref_count == 0) {
        this.destroyAllocation();
    }
}

pub fn finalize(
    this: *Response,
) callconv(.c) void {
    this.wrapper.finalize();
    this.unref();
}

pub fn destroy(this: *Response) void {
    Response.finalizeAfterSweep(this);
}

fn finalizeAfterSweep(this: *Response) void {
    this.finalize();
}

pub fn wrapperCreated(this: *Response, wrapper: bun.bindgen.ClassRefView(ResponseSchema)) bun.JSError!void {
    try this.wrapper.setWeakClassView(ResponseSchema, wrapper);
    this.checkBodyStreamRef(wrapper);
}

pub fn getContentType(
    this: *Response,
) bun.JSError!?bun.String.Slice {
    if (this.response_init.headers) |headers| {
        if (try headers.get().fastGet(.ContentType)) |owned_value| {
            var value = owned_value;
            defer value.deinit();
            return try value.toUTF8(bun.default_allocator);
        }
    }

    if (this.body.value == .Blob) {
        if (!this.body.value.Blob.content_type.isEmpty())
            return bun.String.Slice.fromUTF8NeverFree(this.body.value.Blob.content_type.slice());
    }

    return null;
}

pub fn constructJSONFromBinding(
    context: anytype,
    value: anytype,
    init_argument: anytype,
) !*Response {
    const globalThis = context.viewToken().globalObject();
    const response = try create(.{
        .body = Body{
            .value = .{ .Empty = {} },
        },
        .response_init = Response.Init{
            .status_code = 200,
        },
        .url = .empty(),
    });
    errdefer response.unref();
    if (value) |json_value| {
        var json = try context.engineIn("Response", "jsonStringify").call(.{ .value = json_value.operand(context).asEngine() });
        defer json.deinit();
        var str = json.takeBunString();
        var release_string = true;
        defer if (release_string) str.deref();
        if (!str.isEmpty()) {
            if (try str.value.WTFStringImpl.toUTF8IfNeeded(bun.default_allocator)) |bytes| {
                response.body.value = .{
                    .InternalBlob = InternalBlob{
                        .bytes = .fromOwnedSlice(bun.default_allocator, @constCast(bytes.slice())),
                        .was_string = true,
                    },
                };
            } else {
                response.body.value = Body.Value{
                    .WTFStringImpl = .adopt(str.value.WTFStringImpl),
                };
                release_string = false;
            }
        }
    }

    if (init_argument) |lazy_init| {
        const converted = try lazy_init.convert(context);
        switch (converted.value) {
            .status => |number| {
                response.response_init.status_code = number;
            },
            .request => |*request_ref| {
                response.response_init = try Init.fromRequest(request_ref.get(Request));
            },
            .response => |*response_ref| {
                response.response_init = try Init.fromResponse(response_ref.get(Response));
            },
            .fields => |*fields| {
                response.response_init = try Init.fromSchemaFields(context, fields);
            },
        }
    }

    var headers_ref = try response.getOrCreateHeaders(globalThis);
    try headers_ref.putDefault(.ContentType, MimeType.json.value, globalThis);
    return response;
}

fn validateRedirectStatusCode(context: anytype, status_code: i32) !u16 {
    return switch (status_code) {
        301, 302, 303, 307, 308 => @intCast(status_code),
        else => context.fail(.invalid_redirect_status, {}),
    };
}

pub fn constructRedirectFromBinding(
    context: anytype,
    url: ?[]const u8,
    init_argument: anytype,
) !*Response {
    const globalThis = context.viewToken().globalObject();
    const response = try create(.{
        .response_init = .{ .status_code = 302 },
        .body = .{ .value = .Empty },
    });
    errdefer response.unref();

    if (init_argument) |converted| {
        switch (converted) {
            .status => |number| {
                response.response_init.status_code = try validateRedirectStatusCode(context, number);
            },
            .request => |*request_ref| {
                response.response_init = try Init.fromRequest(request_ref.get(Request));
            },
            .response => |*response_ref| {
                response.response_init = try Init.fromResponse(response_ref.get(Response));
            },
            .fields => |*fields| {
                response.response_init = try Init.fromSchemaFields(context, fields);
            },
            .ignored => {},
        }
        if (converted != .status and response.response_init.status_code != 200) {
            response.response_init.status_code = try validateRedirectStatusCode(context, response.response_init.status_code);
        }
    }

    const headers_ref = try response.getOrCreateHeaders(globalThis);
    try headers_ref.put(.Location, url orelse "", globalThis);
    return response;
}

pub fn constructError() bun.OOM!*Response {
    return create(.{
        .response_init = .{ .status_code = 0 },
        .body = .{ .value = .Empty },
    });
}

pub fn construct(
    context: bun.bindgen.CallContext(ResponseConstructorSchema),
    args: bun.bindgen.Args(ResponseConstructorSchema),
) bun.bindgen.CallError(ResponseConstructorSchema)!*Response {
    const globalThis = context.viewToken().globalObject();
    if (args.body) |*body_init| switch (body_init.*) {
        .blob => |*blob_view| {
            const blob = blob_view.get();
            if (blob.isS3()) {
                if (args.init != null) {
                    return context.fail(.s3_init_unsupported, {});
                }
                return constructFromS3Blob(globalThis, blob);
            }
        },
        else => {},
    };

    const response = try create(.{
        .response_init = .{ .status_code = 200 },
        .body = .{ .value = .Null },
    });
    errdefer response.unref();
    if (args.init) |lazy_init| {
        const forced = try lazy_init.convertLast(context);
        try context.lease(forced.proof);
        response.response_init = try Init.fromSchema(context, &forced.converted.value);
    }

    if (args.body) |*body_init| {
        response.body.value = try Body.Value.fromGeneratedBodyInit(globalThis, context, body_init);
    }

    if (response.body.value == .Blob and
        response.response_init.headers != null and
        !response.body.value.Blob.content_type.isEmpty() and
        !response.response_init.headers.?.get().fastHas(.ContentType))
    {
        try response.response_init.headers.?.get().put(.ContentType, response.body.value.Blob.content_type.slice(), globalThis);
    }

    response.calculateEstimatedByteSize();
    return response;
}

fn constructFromS3Blob(
    globalThis: *jsc.JSGlobalObject,
    blob: *Blob,
) bun.JSError!*Response {
    const response = try create(.{
        .response_init = Response.Init{
            .status_code = 302,
        },
        .body = Body{
            .value = .{ .Empty = {} },
        },
        .url = .empty(),
    });
    errdefer response.unref();

    const credentials = blob.storePtr().?.data.s3.getCredentials();

    const result = credentials.signRequest(.{
        .path = blob.storePtr().?.data.s3.path(),
        .method = .GET,
    }, false, .{ .expires = 15 * 60 }) catch |sign_err| {
        return S3ErrorEngine.throwSignError(sign_err, globalThis);
    };
    defer result.deinit();
    const headers_ref = try response.getOrCreateHeaders(globalThis);
    response.redirected = true;
    try headers_ref.put(.Location, result.url, globalThis);
    return response;
}

pub fn bindConstructError(
    context: bun.bindgen.CallContext(ResponseErrorSchema),
    _: bun.bindgen.Args(ResponseErrorSchema),
) bun.JSError!bun.bindgen.Return(ResponseErrorSchema) {
    return (try constructError()).toResult(context);
}

pub fn constructJSONForContext(context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!*Response {
    return constructJSONFromBinding(context, args.value, args.init);
}

pub fn constructRedirectForContext(context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!*Response {
    const url_slice = if (args.url) |*value| try value.toUTF8(bun.default_allocator) else null;
    defer if (url_slice) |slice| slice.deinit();
    return constructRedirectFromBinding(
        context,
        if (url_slice) |slice| slice.slice() else null,
        args.init,
    );
}

pub fn bindConstructJSON(
    context: bun.bindgen.CallContext(ResponseStaticJSONSchema),
    args: bun.bindgen.Args(ResponseStaticJSONSchema),
) bun.bindgen.CallError(ResponseStaticJSONSchema)!bun.bindgen.Return(ResponseStaticJSONSchema) {
    const response = try constructJSONForContext(context, args);
    return response.toResult(context);
}

pub fn bindConstructRedirect(
    context: bun.bindgen.CallContext(ResponseStaticRedirectSchema),
    args: bun.bindgen.Args(ResponseStaticRedirectSchema),
) bun.bindgen.CallError(ResponseStaticRedirectSchema)!bun.bindgen.Return(ResponseStaticRedirectSchema) {
    const response = try constructRedirectForContext(context, args);
    return response.toResult(context);
}

pub const Init = struct {
    headers: ?FetchHeaders.Owner = null,
    status_code: u16,
    status_text: bun.bindgen.DOMString = .empty(),
    method: Method = Method.GET,

    pub fn clone(this: Init) bun.OOM!Init {
        var that = this;
        const headers = this.headers;
        if (headers) |head| {
            that.headers = try head.get().cloneThis();
        }
        that.status_text = this.status_text.clone();

        return that;
    }

    pub fn fromSchema(context: anytype, generated: anytype) !Init {
        switch (generated.*) {
            .request => |*request_ref| return fromRequest(request_ref.get(Request)),
            .response => |*response_ref| return fromResponse(response_ref.get(Response)),
            .fields => |*fields| return fromSchemaFields(context, fields),
        }
    }

    pub fn fromRequest(req: *Request) bun.OOM!Init {
        var result = Init{ .status_code = 200 };
        if (try req.getFetchHeadersUnlessEmpty()) |headers| {
            result.headers = try headers.cloneThis();
        }
        result.method = req.method;
        return result;
    }

    pub fn fromResponse(resp: *Response) bun.OOM!Init {
        return resp.response_init.clone();
    }

    pub fn fromSchemaFields(context: anytype, fields: anytype) !Init {
        var result = Init{ .status_code = 200 };
        errdefer result.deinit(bun.default_allocator);

        if (fields.headers) |*field| {
            if (field.*) |*handle| {
                var owned_headers = handle.toOwned();
                result.headers = FetchHeaders.Owner.initNative(owned_headers.takeNative());
            }
        }

        if (fields.status) |number| {
            result.status_code = try checkStatusCode(context, number);
        }

        if (fields.statusText) |*field| {
            if (field.*) |*text| {
                result.status_text = text.toOwned();
            }
        }

        if (fields.method) |field| {
            if (field) |method| result.method = Method.fromBinding(method);
        }

        return result;
    }

    fn checkStatusCode(context: anytype, number: i64) !u16 {
        if ((200 <= number and number < 600) or number == 101) {
            return @truncate(@as(u64, @intCast(number)));
        }
        const message = try std.fmt.allocPrint(
            bun.default_allocator,
            "The status provided ({d}) must be 101 or in the range of [200, 599]",
            .{number},
        );
        defer bun.default_allocator.free(message);
        return context.fail(.invalid_status, try bun.bindgen.DOMString.fromUTF8(message));
    }

    pub fn deinit(this: *Init, _: std.mem.Allocator) void {
        if (this.headers) |*headers| {
            headers.deinit();
            this.headers = null;
        }

        this.status_text.deinit();
    }
};

pub fn @"404"(globalThis: *jsc.JSGlobalObject) Response {
    return emptyWithStatus(globalThis, 404);
}

pub fn @"200"(globalThis: *jsc.JSGlobalObject) Response {
    return emptyWithStatus(globalThis, 200);
}

inline fn emptyWithStatus(_: *jsc.JSGlobalObject, status: u16) Response {
    return .{
        .body = Body{
            .value = Body.Value{ .Null = {} },
        },
        .response_init = Init{
            .status_code = status,
        },
    };
}

/// https://developer.mozilla.org/en-US/docs/Web/API/Headers
// TODO: move to http.zig. this has nothing to do with jsc or WebCore

const std = @import("std");
const Method = @import("../../http_types/Method.zig").Method;

const bun = @import("bun");
const default_allocator = bun.default_allocator;
const s3 = bun.S3;
const S3ErrorEngine = @import("./s3/ErrorEngine.zig");
const FetchHeaders = bun.webcore.FetchHeaders;

const http = bun.http;
const MimeType = bun.http.MimeType;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const Request = jsc.WebCore.Request;

const Blob = jsc.WebCore.Blob;
const InternalBlob = jsc.WebCore.Blob.Internal;

const Body = jsc.WebCore.Body;
const BodyMixin = jsc.WebCore.Body.Mixin;

const ResponseBindings = bun.bindgen.Module("Response");
const RequestResponseBodyBindings = bun.bindgen.Module("RequestResponseBody");
pub const ResponseSchema = ResponseBindings.class("Response");
pub const Binding = bun.bindgen.Class(ResponseSchema, Response);
const ResponseClass = Binding;
pub const BodySlot = ResponseClass.CachedSlot("body");
const ResponseConstructorSchema = ResponseSchema.constructor();
const ResponseInspectSchema = ResponseSchema.member("inspectCustom");
const ResponseArrayBufferSchema = ResponseSchema.member("arrayBuffer");
const ResponseBlobSchema = ResponseSchema.member("blob");
const ResponseBodySchema = ResponseSchema.memberKind("body", .getter);
const ResponseBodyUsedSchema = ResponseSchema.memberKind("bodyUsed", .getter);
const ResponseBytesSchema = ResponseSchema.member("bytes");
const ResponseCloneMemberSchema = ResponseSchema.member("clone");
const ResponseFormDataSchema = ResponseSchema.member("formData");
const ResponseHeadersSchema = ResponseSchema.memberKind("headers", .getter);
const ResponseJSONSchema = ResponseSchema.memberKind("json", .method);
const ResponseOKSchema = ResponseSchema.memberKind("ok", .getter);
const ResponseRedirectedSchema = ResponseSchema.memberKind("redirected", .getter);
const ResponseStatusSchema = ResponseSchema.memberKind("status", .getter);
const ResponseStatusTextSchema = ResponseSchema.memberKind("statusText", .getter);
const ResponseTextSchema = ResponseSchema.member("text");
const ResponseTypeSchema = ResponseSchema.memberKind("type", .getter);
const ResponseURLSchema = ResponseSchema.memberKind("url", .getter);
const ResponseErrorSchema = ResponseSchema.memberKind("error", .static_method);
const ResponseStaticJSONSchema = ResponseSchema.memberKind("json", .static_method);
const ResponseStaticRedirectSchema = ResponseSchema.memberKind("redirect", .static_method);
const ResponseStreamSlot = ResponseClass.CachedSlot("stream");
const RequestOrResponseHasBodyValueSchema = RequestResponseBodyBindings.function("requestOrResponseHasBodyValue");
const GetCompleteRequestOrResponseBodyValueAsArrayBufferSchema = RequestResponseBodyBindings.function("getCompleteRequestOrResponseBodyValueAsArrayBuffer");
const RequestOrResponseHasBodyValueBinding = bun.bindgen.Fn(RequestOrResponseHasBodyValueSchema, requestOrResponseHasBodyValue);
const GetCompleteRequestOrResponseBodyValueAsArrayBufferBinding = bun.bindgen.Fn(GetCompleteRequestOrResponseBodyValueAsArrayBufferSchema, getCompleteRequestOrResponseBodyValueAsArrayBuffer);

comptime {
    _ = Binding;
    _ = ResponseClass;
    _ = RequestOrResponseHasBodyValueBinding;
    _ = GetCompleteRequestOrResponseBodyValueAsArrayBufferBinding;
}
