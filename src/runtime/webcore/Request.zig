//! https://developer.mozilla.org/en-US/docs/Web/API/Request

const Request = @This();

bindgen_state: bun.bindgen.ClassState = .{},
url: bun.bindgen.DOMString = .empty(),

headers: ?FetchHeaders.Owner = null,
signal: ?bun.bindgen.RefNative(AbortSignal, .vm) = null,
body: bun.bindgen.RefNative(Body.Value.HiveRef, .vm),
wrapper: bun.bindgen.WrapperReference(.{RequestSchema}) = .empty(),
method: Method = Method.GET,
flags: Flags = .{},
request_context: jsc.API.AnyRequestContext = jsc.API.AnyRequestContext.Null,
weak_ptr_data: WeakRef.Data = .empty,

pub const Flags = packed struct(u8) {
    redirect: FetchRedirect = .follow,
    cache: FetchCacheMode = .default,
    mode: FetchRequestMode = .cors,
    https: bool = false,
};

pub const Handle = RequestClass.Handle;
pub const Ref = bun.bindgen.ClassRef(RequestSchema);
pub const BodySlot = RequestClass.CachedSlot("body");

pub const new = bun.TrivialNew(@This());

const RequestMixin = BodyMixin(@This());
pub const getText = RequestMixin.getText;
pub const getBytes = RequestMixin.getBytes;
pub const getBody = RequestMixin.getBody;
pub const getBodyUsed = RequestMixin.getBodyUsed;
pub const getJSON = RequestMixin.getJSON;
pub const getArrayBuffer = RequestMixin.getArrayBuffer;
pub const getBlob = RequestMixin.getBlob;
pub const getFormData = RequestMixin.getFormData;
pub const getBlobWithoutWrapper = RequestMixin.getBlobWithoutWrapper;
pub const WeakRef = bun.ptr.WeakPtr(Request, "weak_ptr_data");

pub fn memoryUsage(this: *const Request, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
    return @sizeOf(Request) + this.request_context.memoryCost() + this.url.byteLength() + this.body.get().value.memoryCost();
}

fn getUWSRequest(this: *Request) ?*uws.Request {
    return this.request_context.getRequest();
}

pub fn init(
    method: Method,
    request_context: jsc.API.AnyRequestContext,
    https: bool,
    signal: ?*AbortSignal,
    body: *Body.Value.HiveRef,
) Request {
    return Request{
        .request_context = request_context,
        .method = method,
        .flags = .{ .https = https },
        .signal = if (signal) |value| .adopt(value) else null,
        .body = .adopt(body),
    };
}

/// TODO: do we need this?
pub fn init2(
    url: bun.bindgen.DOMString,
    headers: ?FetchHeaders.Owner,
    body: *Body.Value.HiveRef,
    method: Method,
) Request {
    return Request{
        .url = url,
        .headers = headers,
        .body = .adopt(body),
        .method = method,
    };
}

pub fn getContentType(
    this: *Request,
) bun.JSError!?bun.String.Slice {
    if (this.request_context.getRequest()) |req| {
        if (req.header("content-type")) |value| {
            return bun.String.Slice.fromUTF8NeverFree(value);
        }
    }

    if (this.headers) |headers| {
        if (try headers.get().fastGet(.ContentType)) |owned_value| {
            var value = owned_value;
            defer value.deinit();
            return try value.toUTF8(bun.default_allocator);
        }
    }

    if (this.body.get().value == .Blob) {
        if (!this.body.get().value.Blob.content_type.isEmpty())
            return bun.String.Slice.fromUTF8NeverFree(this.body.get().value.Blob.content_type.slice());
    }

    return null;
}

pub fn getFormDataEncoding(this: *Request) bun.JSError!?bun.FormData.OwnedEncoding {
    var content_type_slice: bun.String.Slice = (try this.getContentType()) orelse return null;
    defer content_type_slice.deinit();
    const encoding = bun.FormData.Encoding.get(content_type_slice.slice()) orelse return null;
    return try bun.FormData.OwnedEncoding.init(encoding);
}

pub inline fn getBodyReadableStream(
    this: *Request,
    globalObject: *JSGlobalObject,
) bun.JSError!?jsc.WebCore.ReadableStream.Strong {
    if (try RequestStreamSlot.ownedBrandedFromReference(&this.wrapper)) |stream_value| {
        _ = globalObject;
        return try jsc.WebCore.ReadableStream.Strong.initOwned(stream_value);
    }
    if (this.body.get().value == .Locked) {
        const readable = &this.body.get().value.Locked.readable;
        if (readable.has()) return readable.clone();
    }
    return null;
}
pub inline fn detachReadableStream(this: *Request, globalObject: *jsc.JSGlobalObject) bun.JSError!void {
    _ = globalObject;
    defer if (this.body.get().value == .Locked) {
        var old = this.body.get().value.Locked.readable;
        old.deinit();
        this.body.get().value.Locked.readable = .{};
    };
    try RequestStreamSlot.clearOnReference(&this.wrapper);
}

pub fn toClassRef(this: *Request, globalObject: *JSGlobalObject) bun.JSError!bun.bindgen.ClassRef(RequestSchema) {
    return RequestClass.adoptNativeRef(this, globalObject);
}

pub fn toResult(this: *Request, context: anytype) bun.JSError!Ref {
    return RequestClass.adoptResult(this, context);
}

pub fn toClassRefForBake(this: *Request, globalObject: *JSGlobalObject) bun.JSError!bun.bindgen.ClassRef(RequestSchema) {
    const EngineArgs = bun.bindgen.Args(RequestCreateForBakeSchema);
    var args: EngineArgs = .{
        .request = @FieldType(EngineArgs, "request").initNative(this),
    };
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(globalObject);
    defer scope.deinit();
    return (try scope.engine(RequestCreateForBakeSchema).call(&args)).toOwned();
}

pub fn getCache(this: *Request) bun.bindgen.Return(RequestCacheSchema) {
    return @fromBackingInt(@intCast(@backingInt(this.flags.cache)));
}
pub fn getCredentials() bun.bindgen.Return(RequestCredentialsSchema) {
    return .include;
}
pub fn getDestination() bun.bindgen.Return(RequestDestinationSchema) {
    return .empty;
}

pub fn getIntegrity() bun.OOM!bun.bindgen.DOMString {
    return bun.bindgen.DOMString.fromUTF8("");
}

pub fn getSignal(this: *Request, globalThis: *jsc.JSGlobalObject) *AbortSignal {
    if (this.signal) |signal| {
        return signal.get();
    }
    const signal = AbortSignal.new(globalThis);
    this.signal = .adopt(signal);
    return signal;
}

pub fn getMethod(this: *Request) bun.bindgen.Return(RequestMethodSchema) {
    return this.method.toBinding();
}

pub fn getMode(this: *Request) bun.bindgen.Return(RequestModeSchema) {
    return @fromBackingInt(@intCast(@backingInt(this.flags.mode)));
}

pub fn finalizeWithoutDeinit(this: *Request) void {
    if (this.headers) |*headers| {
        headers.deinit();
        this.headers = null;
    }

    this.url.deinit();

    if (this.signal) |*signal| {
        signal.deinit();
        this.signal = null;
    }
}

pub fn finalize(this: *Request) void {
    this.wrapper.finalize();
    this.finalizeWithoutDeinit();
    this.body.deinit();
    if (this.weak_ptr_data.onFinalize()) {
        bun.destroy(this);
    }
}

pub fn destroy(this: *Request) void {
    Request.finalize(this);
}

pub fn wrapperCreated(this: *Request, wrapper: bun.bindgen.ClassRefView(RequestSchema)) bun.JSError!void {
    try this.wrapper.setWeakClassView(RequestSchema, wrapper);
    this.checkBodyStreamRef(wrapper);
}

pub fn getRedirect(this: *Request) bun.bindgen.Return(RequestRedirectSchema) {
    return @fromBackingInt(@intCast(@backingInt(this.flags.redirect)));
}
pub fn getReferrer(
    this: *Request,
    globalObject: *jsc.JSGlobalObject,
) bun.JSError!bun.bindgen.DOMString {
    if (this.headers) |headers_ref| {
        if (try headers_ref.get().get("referrer", globalObject)) |referrer| {
            defer referrer.deref();
            return bun.bindgen.DOMString.fromBunString(referrer.clone());
        }
    }

    return bun.bindgen.DOMString.fromUTF8("");
}
pub fn getReferrerPolicy() bun.bindgen.Return(RequestReferrerPolicySchema) {
    return .empty;
}
pub fn getUrl(this: *Request) bun.JSError!bun.bindgen.DOMString {
    try this.ensureURL();
    return this.url.clone();
}

pub fn sizeOfURL(this: *const Request) usize {
    if (this.url.length() > 0)
        return this.url.byteLength();

    if (this.request_context.getRequest()) |req| {
        const req_url = req.url();
        if (req_url.len > 0 and req_url[0] == '/') {
            if (req.header("host")) |host| {
                const fmt = bun.fmt.HostFormatter{
                    .is_https = this.flags.https,
                    .host = host,
                };
                return this.getProtocol().len + req_url.len + std.fmt.count("{f}", .{fmt});
            }
        }
        return req_url.len;
    }

    return 0;
}

pub fn getProtocol(this: *const Request) []const u8 {
    if (this.flags.https)
        return "https://";

    return "http://";
}

pub fn ensureURL(this: *Request) bun.OOM!void {
    if (!this.url.isEmpty()) return;

    if (this.request_context.getRequest()) |req| {
        const req_url = req.url();
        if (req_url.len > 0 and req_url[0] == '/') {
            if (req.header("host")) |host| {
                const fmt = bun.fmt.HostFormatter{
                    .is_https = this.flags.https,
                    .host = host,
                };
                const url_bytelength = std.fmt.count("{s}{f}{s}", .{
                    this.getProtocol(),
                    fmt,
                    req_url,
                });

                if (comptime Environment.allow_assert) {
                    bun.assert(this.sizeOfURL() == url_bytelength);
                }

                if (url_bytelength < 128) {
                    var buffer: [128]u8 = undefined;
                    const url = std.fmt.bufPrint(&buffer, "{s}{f}{s}", .{
                        this.getProtocol(),
                        fmt,
                        req_url,
                    }) catch @panic("Unexpected error while printing URL");

                    if (comptime Environment.allow_assert) {
                        bun.assert(this.sizeOfURL() == url.len);
                    }

                    var url_string = try bun.bindgen.DOMString.fromUTF8(url);
                    errdefer url_string.deinit();
                    const href = try bun.jsc.URL.hrefFromDOMString(&url_string);
                    if (!href.isEmpty()) {
                        url_string.deinit();
                        this.url = href;
                    } else {
                        // TODO: what is the right thing to do for invalid URLS?
                        this.url = url_string.take();
                    }

                    return;
                }

                if (strings.isAllASCII(host) and strings.isAllASCII(req_url)) {
                    var url_string: bun.String = undefined;
                    url_string, const bytes = bun.String.createUninitialized(.latin1, url_bytelength);
                    _ = std.fmt.bufPrint(bytes, "{s}{f}{s}", .{
                        this.getProtocol(),
                        fmt,
                        req_url,
                    }) catch |err| switch (err) {
                        error.NoSpaceLeft => unreachable, // exact space should have been counted
                    };
                    this.url = try bun.bindgen.DOMString.fromBunString(url_string);
                } else {
                    // slow path
                    const temp_url = try std.fmt.allocPrint(bun.default_allocator, "{s}{f}{s}", .{
                        this.getProtocol(),
                        fmt,
                        req_url,
                    });
                    defer bun.default_allocator.free(temp_url);
                    this.url = try bun.bindgen.DOMString.fromUTF8(temp_url);
                }

                const href = try bun.jsc.URL.hrefFromDOMString(&this.url);
                // TODO: what is the right thing to do for invalid URLS?
                if (!href.isEmpty()) {
                    this.url.deinit();
                    this.url = href;
                }

                return;
            }
        }

        if (comptime Environment.allow_assert) {
            bun.assert(this.sizeOfURL() == req_url.len);
        }
        this.url = try bun.bindgen.DOMString.fromUTF8(req_url);
    }
}

const Fields = enum {
    method,
    headers,
    body,
    // referrer,
    // referrerPolicy,
    mode,
    // credentials,
    redirect,
    cache,
    // integrity,
    // keepalive,
    signal,
    // proxy,
    // timeout,
    url,
};
fn checkBodyStreamRef(this: *Request, wrapper: bun.bindgen.ClassRefView(RequestSchema)) void {
    if (this.body.get().value == .Locked) {
        if (this.body.get().value.Locked.readable.cloneOwned()) |owned_stream_value| {
            var owned_stream = owned_stream_value;
            defer owned_stream.deinit();
            RequestStreamSlot.setOwnedBranded(wrapper, &owned_stream);
            this.body.get().value.Locked.readable.deinit();
            this.body.get().value.Locked.readable = .{};
        }
    }
}
fn applyRequestSource(
    req: *Request,
    source: *Request,
    fields: *std.enums.EnumSet(Fields),
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!void {
    if (!fields.contains(.method)) {
        req.method = source.method;
        fields.insert(.method);
    }

    if (!fields.contains(.redirect)) {
        req.flags.redirect = source.flags.redirect;
        fields.insert(.redirect);
    }

    if (!fields.contains(.cache)) {
        req.flags.cache = source.flags.cache;
        fields.insert(.cache);
    }

    if (!fields.contains(.mode)) {
        req.flags.mode = source.flags.mode;
        fields.insert(.mode);
    }

    if (!fields.contains(.headers)) {
        if (try source.cloneHeaders()) |headers| {
            req.headers = headers;
            fields.insert(.headers);
        }
    }

    if (!fields.contains(.body)) {
        switch (source.body.get().value) {
            .Null, .Empty, .Used => {},
            else => {
                req.body.get().value = try source.body.get().value.clone(globalThis);
                fields.insert(.body);
            },
        }
    }

    if (!fields.contains(.url)) {
        if (!source.url.isEmpty()) {
            req.url = source.url.clone();
            fields.insert(.url);
        }
    }

    if (!fields.contains(.signal)) {
        if (source.signal) |signal_ref| {
            req.signal = signal_ref.clone();
            fields.insert(.signal);
        }
    }
}

fn applyResponseSource(
    req: *Request,
    source: *Response,
    fields: *std.enums.EnumSet(Fields),
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!void {
    if (!fields.contains(.method)) {
        req.method = source.getMethod();
        fields.insert(.method);
    }

    if (!fields.contains(.headers)) {
        if (source.getInitHeaders()) |headers| {
            req.headers = try headers.cloneThis();
            fields.insert(.headers);
        }
    }

    if (!fields.contains(.url)) {
        const url = source.getUrl();
        if (!url.isEmpty()) {
            req.url = url.clone();
            fields.insert(.url);
        }
    }

    if (!fields.contains(.body)) {
        const body_value = source.getBodyValue();
        switch (body_value.*) {
            .Null, .Empty, .Used => {},
            else => {
                req.body.get().value = try body_value.clone(globalThis);
                fields.insert(.body);
            },
        }
    }
}

fn applyFieldsSource(
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    req: *Request,
    source: anytype,
    fallback_url: ?bun.bindgen.DOMStringView,
    fields: *std.enums.EnumSet(Fields),
) !void {
    if (!fields.contains(.body)) {
        if (source.body) |*field| {
            if (field.*) |*body_init| {
                fields.insert(.body);
                req.body.get().value = try Body.Value.fromGeneratedBodyInit(globalThis, context, body_init);
            }
        }
    }

    if (!fields.contains(.url)) {
        if (source.url) |*url| {
            req.url = url.toOwned();
            if (!req.url.isEmpty())
                fields.insert(.url);
        } else if (fallback_url) |url| {
            req.url = url.toOwned();
            if (!req.url.isEmpty())
                fields.insert(.url);
        }
    }

    if (!fields.contains(.signal)) {
        if (source.signal) |*signal_input| switch (signal_input.*) {
            .signal => |*signal_ref| {
                fields.insert(.signal);
                req.signal = .init(signal_ref.get());
            },
            .ignored => {},
            .invalid => return context.fail(.invalid_signal, {}),
        };
    }

    if (!fields.contains(.headers)) {
        if (source.headers) |*field| {
            if (field.*) |*handle| {
                var headers = handle.toOwned();
                req.headers = FetchHeaders.Owner.initNative(headers.takeNative());
                fields.insert(.headers);
            }
        }
    }

    if (!fields.contains(.method)) {
        if (source.method) |field| {
            if (field) |method| {
                req.method = Method.fromBinding(method);
                fields.insert(.method);
            }
        }
    }

    if (!fields.contains(.redirect)) {
        if (source.redirect) |redirect_input| switch (redirect_input) {
            .value => |value| {
                req.flags.redirect = @fromBackingInt(@intCast(@as(u8, @intCast(@backingInt(value)))));
                fields.insert(.redirect);
            },
            .ignored => {},
        };
    }

    if (!fields.contains(.cache)) {
        if (source.cache) |cache_input| switch (cache_input) {
            .value => |value| {
                req.flags.cache = @fromBackingInt(@intCast(@as(u8, @intCast(@backingInt(value)))));
                fields.insert(.cache);
            },
            .ignored => {},
        };
    }

    if (!fields.contains(.mode)) {
        if (source.mode) |mode_input| switch (mode_input) {
            .value => |value| {
                req.flags.mode = @fromBackingInt(@intCast(@as(u8, @intCast(@backingInt(value)))));
                fields.insert(.mode);
            },
            .ignored => {},
        };
    }
}

fn initSourceHasURL(init_converted: anytype) bool {
    const converted = init_converted orelse return false;
    return switch (converted.value) {
        .request => |reference| !reference.get(Request).url.isEmpty(),
        .response => |reference| !reference.get(Response).getUrl().isEmpty(),
        .fields => |source| if (source.url) |url| url.length() != 0 else false,
        .ignored => false,
    };
}

pub fn construct(
    context: bun.bindgen.CallContext(RequestConstructorSchema),
    args: bun.bindgen.Args(RequestConstructorSchema),
) bun.bindgen.CallError(RequestConstructorSchema)!*Request {
    const globalThis = context.viewToken().globalObject();
    const input_argument = args.input orelse return context.fail(.missing_input, {});

    const init_converted = if (args.init) |init_argument| try init_argument.convert(context) else null;
    const init_is_source = if (init_converted) |*converted| converted.value != .ignored else false;
    const converted_input = try input_argument.convert(context);
    const fallback_argument = args.fallback_url.?;
    var fallback_url: ?bun.bindgen.DOMStringView = null;
    if (converted_input.value == .source and converted_input.value.source.url == null and !initSourceHasURL(init_converted)) {
        const forced = try fallback_argument.convertLast(context);
        try context.lease(forced.proof);
        fallback_url = forced.converted.value;
    } else {
        try context.lease(try fallback_argument.discardLast(context));
    }
    if (!init_is_source and converted_input.value == .request) {
        return converted_input.value.request.get(Request).clone(globalThis);
    }

    const result = try bun.default_allocator.create(Request);
    errdefer bun.default_allocator.destroy(result);
    const vm = globalThis.bunVM();
    const body = try vm.initRequestBodyValue(.{ .Null = {} });
    var req = Request{
        .body = .adopt(body),
    };
    errdefer {
        req.finalizeWithoutDeinit();
        req.body.deinit();
    }

    var fields: std.enums.EnumSet(Fields) = .empty;
    switch (converted_input.value) {
        .response => |*response_ref| {
            try applyInitSource(globalThis, context, &req, &fields, &init_converted);
            try applyResponseSource(&req, response_ref.get(Response), &fields, globalThis);
        },
        .url => |*url| {
            req.url = url.toOwned();
            if (!req.url.isEmpty())
                fields.insert(.url);
            try applyInitSource(globalThis, context, &req, &fields, &init_converted);
        },
        .request => |*request_ref| {
            try applyInitSource(globalThis, context, &req, &fields, &init_converted);
            try applyRequestSource(&req, request_ref.get(Request), &fields, globalThis);
        },
        .source => |*source| {
            try applyInitSource(globalThis, context, &req, &fields, &init_converted);
            try applyFieldsSource(globalThis, context, &req, source, fallback_url, &fields);
        },
    }

    if (req.url.isEmpty()) {
        return context.fail(.missing_url, {});
    }

    const href = try jsc.URL.hrefFromDOMString(&req.url);
    if (href.isEmpty()) {
        const message = try std.fmt.allocPrint(
            bun.default_allocator,
            "Failed to construct 'Request': Invalid URL \"{f}\"",
            .{req.url},
        );
        defer bun.default_allocator.free(message);
        return context.fail(.invalid_url, try bun.bindgen.DOMString.fromUTF8(message));
    }

    req.url.deinit();

    req.url = href;

    if (req.body.get().value == .Blob and
        req.headers != null and
        !req.body.get().value.Blob.content_type.isEmpty() and
        !req.headers.?.get().fastHas(.ContentType))
    {
        try req.headers.?.get().put(.ContentType, req.body.get().value.Blob.content_type.slice(), globalThis);
    }

    result.* = req;
    return result;
}

fn applyInitSource(
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    req: *Request,
    fields: *std.enums.EnumSet(Fields),
    init_converted: anytype,
) !void {
    if (init_converted.*) |*converted| switch (converted.value) {
        .response => |*response_ref| try applyResponseSource(req, response_ref.get(Response), fields, globalThis),
        .request => |*request_ref| try applyRequestSource(req, request_ref.get(Request), fields, globalThis),
        .fields => |*source| try applyFieldsSource(globalThis, context, req, source, null, fields),
        .ignored => {},
    };
}

pub fn getBodyValue(
    this: *Request,
) *Body.Value {
    return &this.body.get().value;
}

pub fn doClone(
    this: *Request,
    globalThis: *jsc.JSGlobalObject,
    this_value: bun.bindgen.ClassRefView(RequestSchema),
) bun.JSError!bun.bindgen.Return(RequestCloneMemberSchema) {
    const cloned = try this.clone(globalThis);

    var cloned_ref = try cloned.toClassRef(globalThis);
    // Wrapping moves Locked.readable into the cached stream slot.
    RequestClass.copyCachedSlotOwned("stream", "body", &cloned_ref);

    // Update the original request's body cache with the new teed stream.
    // At this point, this.body.get().value.Locked.readable still holds the teed stream
    // because checkBodyStreamRef hasn't been called on the original request yet.
    const update_body_cache = this.body.get().value == .Locked;
    this.checkBodyStreamRef(this_value);
    if (update_body_cache) {
        RequestClass.copyCachedSlot("stream", "body", this_value);
    }
    return cloned_ref;
}

fn getBodyFromBinding(
    context: anytype,
    request: *Request,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    var body = (try request.getBody(globalThis)) orelse return null;
    defer body.deinit();
    return body.toResult(context);
}

fn getBodyUsedFromBinding(
    context: anytype,
    request: *Request,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return request.getBodyUsed(globalThis);
}

fn cloneMemberFromBinding(
    context: anytype,
    input: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return input.request.doClone(globalThis, input.args.bindingThis);
}

fn getHeadersFromBinding(
    context: anytype,
    request: *Request,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    const Headers = @import("./Headers.zig");
    const resource = try request.ensureFetchHeaders(globalThis);
    return Headers.Binding.adoptResult(try Headers.create(resource.retain()), context);
}

fn getReferrerFromBinding(
    context: anytype,
    request: *Request,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return request.getReferrer(globalThis);
}

fn getSignalFromBinding(
    context: anytype,
    request: *Request,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    return (try context.engineIn("abort_signals", "abortSignalToClassRef").call(.{ .signal = request.getSignal(globalThis) })).toOwned();
}

fn cloneNativeFromBinding(
    context: anytype,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return cloneFromBinding(context, args);
}

pub fn bindGetArrayBuffer(
    this: *Request,
    context: bun.bindgen.CallContext(RequestArrayBufferSchema),
    args: bun.bindgen.Args(RequestArrayBufferSchema),
) bun.bindgen.CallError(RequestArrayBufferSchema)!void {
    return try this.getArrayBuffer(context, args.bindingThis);
}

pub fn bindGetBlob(
    this: *Request,
    context: bun.bindgen.CallContext(RequestBlobSchema),
    args: bun.bindgen.Args(RequestBlobSchema),
) bun.bindgen.CallError(RequestBlobSchema)!void {
    return try this.getBlob(context, args.bindingThis);
}

pub fn bindGetBody(
    this: *Request,
    context: bun.bindgen.CallContext(RequestBodySchema),
    _: bun.bindgen.Args(RequestBodySchema),
) bun.JSError!bun.bindgen.Return(RequestBodySchema) {
    return getBodyFromBinding(context, this);
}

pub fn bindGetBodyUsed(
    this: *Request,
    context: bun.bindgen.CallContext(RequestBodyUsedSchema),
    _: bun.bindgen.Args(RequestBodyUsedSchema),
) bun.JSError!bool {
    return getBodyUsedFromBinding(context, this);
}

pub fn bindGetBytes(
    this: *Request,
    context: bun.bindgen.CallContext(RequestBytesSchema),
    args: bun.bindgen.Args(RequestBytesSchema),
) bun.bindgen.CallError(RequestBytesSchema)!void {
    return try this.getBytes(context, args.bindingThis);
}

pub fn bindGetCache(
    this: *Request,
    _: bun.bindgen.CallContext(RequestCacheSchema),
    _: bun.bindgen.Args(RequestCacheSchema),
) bun.JSError!bun.bindgen.Return(RequestCacheSchema) {
    return this.getCache();
}

pub fn bindClone(
    this: *Request,
    context: bun.bindgen.CallContext(RequestCloneMemberSchema),
    args: bun.bindgen.Args(RequestCloneMemberSchema),
) bun.JSError!bun.bindgen.Return(RequestCloneMemberSchema) {
    return cloneMemberFromBinding(context, .{ .request = this, .args = args });
}

pub fn bindGetCredentials(
    _: *Request,
    _: bun.bindgen.CallContext(RequestCredentialsSchema),
    _: bun.bindgen.Args(RequestCredentialsSchema),
) bun.JSError!bun.bindgen.Return(RequestCredentialsSchema) {
    return getCredentials();
}

pub fn bindGetDestination(
    _: *Request,
    _: bun.bindgen.CallContext(RequestDestinationSchema),
    _: bun.bindgen.Args(RequestDestinationSchema),
) bun.JSError!bun.bindgen.Return(RequestDestinationSchema) {
    return getDestination();
}

pub fn bindGetFormData(
    this: *Request,
    context: bun.bindgen.CallContext(RequestFormDataSchema),
    args: bun.bindgen.Args(RequestFormDataSchema),
) bun.bindgen.CallError(RequestFormDataSchema)!void {
    return try this.getFormData(context, args.bindingThis);
}

pub fn inspectCustom(_: *Request, context: bun.bindgen.CallContext(RequestInspectSchema), args: bun.bindgen.Args(RequestInspectSchema)) bun.JSError!bun.bindgen.DOMString {
    return @import("./RequestEngine.zig").inspect(context, args);
}

pub fn bindGetHeaders(
    this: *Request,
    context: bun.bindgen.CallContext(RequestHeadersSchema),
    _: bun.bindgen.Args(RequestHeadersSchema),
) bun.JSError!bun.bindgen.Return(RequestHeadersSchema) {
    return getHeadersFromBinding(context, this);
}

pub fn bindGetIntegrity(
    _: *Request,
    _: bun.bindgen.CallContext(RequestIntegritySchema),
    _: bun.bindgen.Args(RequestIntegritySchema),
) bun.JSError!bun.bindgen.DOMString {
    return getIntegrity();
}

pub fn bindGetJSON(
    this: *Request,
    context: bun.bindgen.CallContext(RequestJSONSchema),
    args: bun.bindgen.Args(RequestJSONSchema),
) bun.bindgen.CallError(RequestJSONSchema)!void {
    return try this.getJSON(context, args.bindingThis);
}

pub fn bindGetMethod(
    this: *Request,
    _: bun.bindgen.CallContext(RequestMethodSchema),
    _: bun.bindgen.Args(RequestMethodSchema),
) bun.JSError!bun.bindgen.Return(RequestMethodSchema) {
    return this.getMethod();
}

pub fn bindGetMode(
    this: *Request,
    _: bun.bindgen.CallContext(RequestModeSchema),
    _: bun.bindgen.Args(RequestModeSchema),
) bun.JSError!bun.bindgen.Return(RequestModeSchema) {
    return this.getMode();
}

pub fn bindGetRedirect(
    this: *Request,
    _: bun.bindgen.CallContext(RequestRedirectSchema),
    _: bun.bindgen.Args(RequestRedirectSchema),
) bun.JSError!bun.bindgen.Return(RequestRedirectSchema) {
    return this.getRedirect();
}

pub fn bindGetReferrer(
    this: *Request,
    context: bun.bindgen.CallContext(RequestReferrerSchema),
    _: bun.bindgen.Args(RequestReferrerSchema),
) bun.JSError!bun.bindgen.DOMString {
    return getReferrerFromBinding(context, this);
}

pub fn bindGetReferrerPolicy(
    _: *Request,
    _: bun.bindgen.CallContext(RequestReferrerPolicySchema),
    _: bun.bindgen.Args(RequestReferrerPolicySchema),
) bun.JSError!bun.bindgen.Return(RequestReferrerPolicySchema) {
    return getReferrerPolicy();
}

pub fn bindGetSignal(
    this: *Request,
    context: bun.bindgen.CallContext(RequestSignalSchema),
    _: bun.bindgen.Args(RequestSignalSchema),
) bun.JSError!bun.bindgen.Return(RequestSignalSchema) {
    return getSignalFromBinding(context, this);
}

pub fn bindGetText(
    this: *Request,
    context: bun.bindgen.CallContext(RequestTextSchema),
    args: bun.bindgen.Args(RequestTextSchema),
) bun.bindgen.CallError(RequestTextSchema)!void {
    return try this.getText(context, args.bindingThis);
}

pub fn bindGetURL(
    this: *Request,
    _: bun.bindgen.CallContext(RequestURLSchema),
    _: bun.bindgen.Args(RequestURLSchema),
) bun.JSError!bun.bindgen.DOMString {
    return this.getUrl();
}

// Returns if the request has headers already cached/set.
pub fn hasFetchHeaders(this: *Request) bool {
    return this.headers != null;
}

/// Sets the headers of the request. This will take ownership of the headers.
/// it will deref the previous headers if they exist.
pub fn setFetchHeaders(
    this: *Request,
    headers: ?FetchHeaders.Owner,
) void {
    if (this.headers) |*old_headers| {
        old_headers.deinit();
    }

    this.headers = headers;
}

/// Returns the headers of the request. If the headers are not already cached, it will create a new FetchHeaders object.
/// If the headers are empty, it will look at request_context to get the headers.
/// If the headers are empty and request_context is null, it will create an empty FetchHeaders object.
pub fn ensureFetchHeaders(
    this: *Request,
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!*FetchHeaders {
    if (this.headers) |headers| {
        // headers is already set
        return headers.get();
    }

    if (this.request_context.getRequest()) |req| {
        // we have a request context, so we can get the headers from it
        this.headers = try FetchHeaders.createFromUWS(req);
    } else {
        // we don't have a request context, so we need to create an empty headers object
        this.headers = try FetchHeaders.createEmpty();
        const content_type = switch (this.body.get().value) {
            .Blob => |blob| blob.content_type.slice(),
            .Locked => |locked| if (locked.readable.blobLoader()) |blob| blob.content_type.slice() else null,
            else => null,
        };

        if (content_type) |content_type_| {
            if (content_type_.len > 0) {
                try this.headers.?.get().put(.ContentType, content_type_, globalThis);
            }
        }
    }

    return this.headers.?.get();
}

pub fn getFetchHeadersUnlessEmpty(
    this: *Request,
) bun.OOM!?*FetchHeaders {
    if (this.headers == null) {
        if (this.request_context.getRequest()) |req| {
            // we have a request context, so we can get the headers from it
            this.headers = try FetchHeaders.createFromUWS(req);
        }
    }

    const headers = (this.headers orelse return null).get();
    if (headers.isEmpty()) {
        return null;
    }
    return headers;
}

/// Returns the headers of the request. This will not look at the request contex to get the headers.
pub fn getFetchHeaders(
    this: *Request,
) ?*FetchHeaders {
    return if (this.headers) |headers| headers.get() else null;
}

/// This should only be called by the JS code. use getFetchHeaders to get the current headers or ensureFetchHeaders to get the headers and create them if they don't exist.
pub fn cloneHeaders(this: *Request) bun.OOM!?FetchHeaders.Owner {
    if (this.headers == null) {
        if (this.request_context.getRequest()) |uws_req| {
            this.headers = try FetchHeaders.createFromUWS(uws_req);
        }
    }

    if (this.headers) |head| {
        if (head.get().isEmpty()) {
            return null;
        }

        return try head.get().cloneThis();
    }

    return null;
}

pub fn cloneValue(
    this: *Request,
    globalThis: *JSGlobalObject,
) bun.JSError!Request {
    try this.ensureURL();
    const vm = globalThis.bunVM();
    var body_ = brk: {
        if (try RequestStreamSlot.ownedBrandedFromReference(&this.wrapper)) |stream_value| {
            var readable = try jsc.WebCore.ReadableStream.Strong.initOwned(stream_value);
            defer readable.deinit();
            break :brk try this.body.get().value.cloneWithReadableStream(globalThis, &readable);
        }

        break :brk try this.body.get().value.clone(globalThis);
    };
    errdefer body_.deinit();
    const body = try vm.initRequestBodyValue(body_);
    body_ = .Used;
    errdefer body.deref();
    var url = this.url.clone();
    errdefer url.deinit();
    var headers = try this.cloneHeaders();
    errdefer if (headers) |*value| value.deinit();

    return Request{
        .body = .adopt(body),
        .url = url,
        .method = this.method,
        .flags = this.flags,
        .headers = headers,
        .signal = if (this.signal) |signal| signal.clone() else null,
    };
}

pub fn clone(this: *Request, globalThis: *JSGlobalObject) bun.JSError!*Request {
    const req = try bun.default_allocator.create(Request);
    errdefer bun.destroy(req);
    req.* = try this.cloneValue(globalThis);
    return req;
}

fn bindCloneNative(
    context: bun.bindgen.CallContext(RequestCloneSchema),
    args: bun.bindgen.Args(RequestCloneSchema),
) bun.JSError!bun.bindgen.Return(RequestCloneSchema) {
    return cloneFromBinding(context, args);
}

pub fn cloneFromBinding(
    context: anytype,
    args: bun.bindgen.Args(RequestCloneSchema),
) bun.JSError!bun.bindgen.Return(RequestCloneSchema) {
    const globalObject = context.viewToken().globalObject();
    return args.request.clone(globalObject);
}

fn bindSetCookies(args: bun.bindgen.Args(RequestSetCookiesSchema)) bun.bindgen.Return(RequestSetCookiesSchema) {
    args.request.request_context.setCookies(args.cookieMap);
}

fn bindReleaseNative(args: bun.bindgen.Args(RequestReleaseNativeSchema)) bun.bindgen.Return(RequestReleaseNativeSchema) {
    args.request.finalize();
}

fn bindGetUWSRequest(args: bun.bindgen.Args(RequestGetUWSRequestSchema)) bun.bindgen.Return(RequestGetUWSRequestSchema) {
    return if (args.request.getUWSRequest()) |request| @ptrCast(request) else null;
}

fn bindSetTimeout(
    _: bun.bindgen.CallContext(RequestSetTimeoutSchema),
    args: bun.bindgen.Args(RequestSetTimeoutSchema),
) bun.JSError!bun.bindgen.Return(RequestSetTimeoutSchema) {
    args.request.setTimeout(args.seconds);
}

pub fn setTimeout(
    this: *Request,
    seconds: c_uint,
) void {
    _ = this.request_context.setTimeout(seconds);
}

const string = []const u8;

const Environment = @import("../../bun_core/env.zig");
const std = @import("std");
const FetchCacheMode = @import("../../http_types/FetchCacheMode.zig").FetchCacheMode;
const FetchRedirect = @import("../../http_types/FetchRedirect.zig").FetchRedirect;
const FetchRequestMode = @import("../../http_types/FetchRequestMode.zig").FetchRequestMode;
const Method = @import("../../http_types/Method.zig").Method;

const bun = @import("bun");
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const uws = bun.uws;
const FetchHeaders = bun.webcore.FetchHeaders;
const MimeType = bun.http.MimeType;

const jsc = bun.jsc;
const CookieMap = @import("./CookieMap.zig").CookieMap;
const JSGlobalObject = jsc.JSGlobalObject;

const AbortSignal = jsc.WebCore.AbortSignal;
const Response = jsc.WebCore.Response;

const Blob = jsc.WebCore.Blob;
const InlineBlob = jsc.WebCore.Blob.Inline;
const InternalBlob = jsc.WebCore.Blob.Internal;

const Body = jsc.WebCore.Body;
const BodyMixin = jsc.WebCore.Body.Mixin;
const RequestBindings = bun.bindgen.Module("Request");
pub const RequestSchema = RequestBindings.class("Request");
pub const Binding = bun.bindgen.Class(RequestSchema, Request);
const RequestClass = Binding;

const RequestConstructorSchema = RequestSchema.constructor();
const RequestArrayBufferSchema = RequestSchema.member("arrayBuffer");
const RequestBlobSchema = RequestSchema.member("blob");
const RequestBodySchema = RequestSchema.memberKind("body", .getter);
const RequestBodyUsedSchema = RequestSchema.memberKind("bodyUsed", .getter);
const RequestBytesSchema = RequestSchema.member("bytes");
const RequestCacheSchema = RequestSchema.memberKind("cache", .getter);
const RequestCloneMemberSchema = RequestSchema.member("clone");
const RequestCredentialsSchema = RequestSchema.memberKind("credentials", .getter);
const RequestDestinationSchema = RequestSchema.memberKind("destination", .getter);
const RequestFormDataSchema = RequestSchema.member("formData");
const RequestHeadersSchema = RequestSchema.memberKind("headers", .getter);
const RequestInspectSchema = RequestSchema.member("inspectCustom");
const RequestIntegritySchema = RequestSchema.memberKind("integrity", .getter);
const RequestJSONSchema = RequestSchema.member("json");
const RequestMethodSchema = RequestSchema.memberKind("method", .getter);
const RequestModeSchema = RequestSchema.memberKind("mode", .getter);
const RequestRedirectSchema = RequestSchema.memberKind("redirect", .getter);
const RequestReferrerSchema = RequestSchema.memberKind("referrer", .getter);
const RequestReferrerPolicySchema = RequestSchema.memberKind("referrerPolicy", .getter);
const RequestSignalSchema = RequestSchema.memberKind("signal", .getter);
const RequestTextSchema = RequestSchema.member("text");
const RequestURLSchema = RequestSchema.memberKind("url", .getter);
const RequestStreamSlot = RequestClass.CachedSlot("stream");

const RequestCreateForBakeSchema = RequestBindings.engineShim("requestCreateForBake");
pub const JSValueIsBunRequestSchema = RequestBindings.engineShim("jsValueIsBunRequest");
pub const BunRequestParamsSchema = RequestBindings.engineShim("bunRequestParams");
const RequestCloneSchema = RequestBindings.nativeExport("requestClone");
const RequestSetCookiesSchema = RequestBindings.nativeExport("requestSetCookies");
const RequestReleaseNativeSchema = RequestBindings.nativeExport("requestReleaseNative");
const RequestGetUWSRequestSchema = RequestBindings.nativeExport("requestGetUWSRequest");
const RequestSetTimeoutSchema = RequestBindings.nativeExport("requestSetTimeout");
const RequestCloneBinding = bun.bindgen.Fn(RequestCloneSchema, bindCloneNative);
const RequestSetCookiesBinding = bun.bindgen.Fn(RequestSetCookiesSchema, bindSetCookies);
const RequestReleaseNativeBinding = bun.bindgen.Fn(RequestReleaseNativeSchema, bindReleaseNative);
const RequestGetUWSRequestBinding = bun.bindgen.Fn(RequestGetUWSRequestSchema, bindGetUWSRequest);
const RequestSetTimeoutBinding = bun.bindgen.Fn(RequestSetTimeoutSchema, bindSetTimeout);

comptime {
    _ = Binding;
    _ = RequestClass;
    _ = RequestCloneBinding;
    _ = RequestSetCookiesBinding;
    _ = RequestReleaseNativeBinding;
    _ = RequestGetUWSRequestBinding;
    _ = RequestSetTimeoutBinding;
}
