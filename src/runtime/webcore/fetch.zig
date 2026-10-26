pub const fetch_error_no_args = "fetch() expects a string but received no arguments.";
pub const fetch_error_blank_url = "fetch() URL must not be a blank string.";

pub const FetchTasklet = @import("./fetch/FetchTasklet.zig").FetchTasklet;

fn dataURLResponse(
    data_url: DataURL,
    globalThis: *JSGlobalObject,
    allocator: std.mem.Allocator,
) (bun.JSError || error{InvalidDataURL})!Response.Ref {
    const data = data_url.decodeData(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Base64DecodeError => return error.InvalidDataURL,
    };
    var blob = try Blob.init(data, allocator);
    errdefer blob.deinit();

    const mime_type = bun.http.MimeType.init(if (data_url.mime_type.len == 0) "text/plain" else data_url.mime_type);
    try blob.setContentType(mime_type.value, .explicit);

    var status_text = try bun.bindgen.DOMString.fromUTF8("OK");
    defer status_text.deinit();
    var response_url = try bun.bindgen.DOMString.fromBunString(data_url.url.dupeRef());
    defer response_url.deinit();
    const response = try bun.default_allocator.create(Response);
    response.* = Response.init(
        .{
            .status_code = 200,
            .status_text = status_text.take(),
        },
        Body{
            .value = .{ .Blob = blob.take() },
        },
        response_url.take(),
        false,
    );

    return response.toClassRef(globalThis);
}

pub fn fetchPreconnect(
    context: bun.bindgen.CallContext(FetchPreconnectSchema),
    args: bun.bindgen.Args(FetchPreconnectSchema),
) bun.bindgen.CallError(FetchPreconnectSchema)!void {
    var url_string = try args.url.toUTF8(bun.default_allocator);
    const url = ZigURL.parse(try url_string.intoOwnedSlice(bun.default_allocator));
    if (!url.isHTTP() and !url.isHTTPS() and !url.isS3()) {
        bun.default_allocator.free(url.href);
        return context.fail(.unsupported_protocol, {});
    }

    if (url.hostname.len == 0) {
        bun.default_allocator.free(url.href);
        return context.fail(.missing_hostname, {});
    }

    if (!url.hasValidPort()) {
        bun.default_allocator.free(url.href);
        return context.fail(.invalid_port, {});
    }

    bun.http.AsyncHTTP.preconnect(url, true, jsc.JavaScriptSemanticsEngine.javascript_semantics);
}

fn resolveFetch(completion: *?FetchTasklet.FetchCompletions.Owned, response: Response.Ref) void {
    var owned = completion.*.?;
    completion.* = null;
    FetchTasklet.completeFetch(&owned, .{ .response = response });
}

fn failFetch(completion: *?FetchTasklet.FetchCompletions.Owned, comptime tag: anytype) void {
    var owned = bun.take(completion) orelse @panic("fetch validation failure has no completion");
    owned.fail(tag, {});
}

fn rejectTLSConfig(
    completion: *?FetchTasklet.FetchCompletions.Owned,
    failure: SSLConfigEngine.ParseFailure,
) bun.OOM!void {
    switch (failure) {
        .system => |system_error| {
            const payload = try bun.bindgen.SystemError.fromSysError(system_error);
            var owned = completion.* orelse @panic("fetch TLS failure has no completion");
            completion.* = null;
            owned.fail(.tls_system, payload);
        },
        else => {
            var message_buffer: [128]u8 = undefined;
            const payload = try bun.bindgen.ThreadSafeDOMString.fromUTF8(failure.message(&message_buffer));
            var owned = completion.* orelse @panic("fetch TLS failure has no completion");
            completion.* = null;
            owned.fail(.tls_invalid_options, payload);
        },
    }
}

const Operation = enum {
    standard,
    node_http,
};

fn startFromBinding(
    comptime operation: Operation,
    context: anytype,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    const globalObject = context.viewToken().globalObject();
    var view = context.completion();
    var completion: ?FetchTasklet.FetchCompletions.Owned = FetchTasklet.FetchCompletions.takeForContext(context, &view);
    defer if (completion) |*owned| owned.release();
    fetchImpl(operation == .node_http, globalObject, context, args, &completion) catch |err| {
        if (completion != null) {
            var thrown = try context.takeThrownValue(err);
            defer thrown.deinit();
            var reason = try thrown.toRoot();
            var owned = bun.take(&completion).?;
            FetchTasklet.completeFetch(&owned, .{ .js_error = reason.takeOptional() });
            return;
        }
        return err;
    };
}

/// Public entry point for `Bun.fetch` - validates body on GET/HEAD/OPTIONS
pub fn fetch(
    context: bun.bindgen.CallContext(FetchSchema),
    args: bun.bindgen.Args(FetchSchema),
) bun.bindgen.CallError(FetchSchema)!void {
    return startFromBinding(.standard, context, args);
}

/// Internal entry point for Node.js HTTP client - allows body on GET/HEAD/OPTIONS
pub fn nodeHttpClient(
    context: bun.bindgen.CallContext(NodeHTTPClientSchema),
    args: bun.bindgen.Args(NodeHTTPClientSchema),
) bun.bindgen.CallError(NodeHTTPClientSchema)!void {
    return startFromBinding(.node_http, context, args);
}

fn booleanOrCountValue(field_optional: anytype) ?bool {
    const field = field_optional orelse return null;
    return switch (field) {
        .flag => |flag| flag,
        .count => |count| count != 0,
        .ignored => null,
    };
}

fn fetchOptionValues(comptime Fields: type) type {
    const fields = @typeInfo(Fields).@"struct";
    var names: [fields.field_names.len][]const u8 = undefined;
    var types: [fields.field_names.len]type = undefined;
    for (fields.field_names, fields.field_types, 0..) |name, Field, i| {
        const Conversion = @typeInfo(@TypeOf(Field.convert)).@"fn".return_type.?;
        const Converted = @typeInfo(Conversion).error_union.payload;
        names[i] = name;
        types[i] = @FieldType(Converted, "value");
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn fetchOptionSelected(comptime name: []const u8, value: anytype) bool {
    const field = value orelse return false;
    if (comptime bun.strings.eqlComptime(name, "decompress") or bun.strings.eqlComptime(name, "timeout") or bun.strings.eqlComptime(name, "keepalive")) return field != .ignored;
    if (comptime bun.strings.eqlComptime(name, "tls")) return field == .config;
    if (comptime bun.strings.eqlComptime(name, "unix_path")) return field == .text and field.text.length() > 0;
    if (comptime bun.strings.eqlComptime(name, "protocol")) return field == .name;
    if (comptime bun.strings.eqlComptime(name, "signal")) return field == .signal;
    if (comptime bun.strings.eqlComptime(name, "verbose")) return switch (field) {
        .flag => true,
        .name => |text| text.eqlUTF8("curl"),
        .ignored => false,
    };
    if (comptime bun.strings.eqlComptime(name, "proxy")) return switch (field) {
        .text => |text| text.length() > 0,
        .config => |config| if (config.url) |url| url != null else false,
        .ignored => false,
    };
    return true;
}

fn prepareFetchOptions(
    comptime Fields: type,
    context: anytype,
    init_fields: ?*const Fields,
    input_fields: ?*const Fields,
    request_fields: anytype,
    unused_input_options: anytype,
    is_s3: bool,
    init_values: *fetchOptionValues(Fields),
    input_values: *fetchOptionValues(Fields),
) bun.JSError!bun.bindgen.DeferredLeaseProof {
    var body_source: enum { none, init, input } = .none;
    inline for (@typeInfo(Fields).@"struct".field_names) |name| {
        if (comptime bun.strings.eqlComptime(name, "body")) continue;
        if (comptime bun.strings.eqlComptime(name, "s3")) {
            if (init_fields) |source| {
                if (is_s3) {
                    @field(init_values, name) = (try @field(source, name).convert(context)).value;
                } else try @field(source, name).discard(context);
            }
            if (input_fields) |source| try @field(source, name).discard(context);
            continue;
        }
        if (init_fields) |source| @field(init_values, name) = (try @field(source, name).convert(context)).value;
        const selected_init = fetchOptionSelected(name, @field(init_values, name));
        inline for (.{ request_fields, input_fields }) |fields| {
            if (fields) |source| {
                if (comptime @hasField(@TypeOf(source.*), name)) {
                    if (selected_init) {
                        try @field(source, name).discard(context);
                    } else @field(input_values, name) = (try @field(source, name).convert(context)).value;
                }
            }
        }
        if (comptime bun.strings.eqlComptime(name, "body_presence")) {
            body_source = if (selected_init) .init else if (@field(input_values, name) != null) .input else .none;
        }
    }
    if (init_fields) |source| {
        if (body_source == .init) {
            init_values.body = (try source.body.convert(context)).value;
        } else try source.body.discard(context);
    }
    if (input_fields) |source| {
        if (body_source == .input) {
            const forced = try source.body.convertLast(context);
            input_values.body = forced.converted.value;
            return forced.proof;
        }
        return source.body.discardLast(context);
    }
    return unused_input_options.?.discardLast(context);
}

/// Shared implementation of fetch
fn fetchImpl(
    comptime allow_get_body: bool,
    globalThis: *JSGlobalObject,
    context: anytype,
    args: anytype,
    completion: *?FetchTasklet.FetchCompletions.Owned,
) bun.JSError!void {
    bun.analytics.Features.fetch += 1;
    const vm = globalThis.bunVM();

    var upgraded_connection = false;
    var force_http2 = false;
    var force_http3 = false;
    var force_http1 = false;
    var allocator = bun.default_allocator;

    const input_argument = args.input orelse {
        return failFetch(completion, .missing_input);
    };

    var headers: ?Headers = null;
    var method = Method.GET;

    var url = ZigURL{};

    var body: FetchTasklet.HTTPRequestBody = FetchTasklet.HTTPRequestBody.Empty;

    var disable_timeout = false;
    var disable_keepalive = false;
    var disable_decompression = false;
    var verbose: http.HTTPVerboseLevel = if (vm.log.level.atLeast(.debug)) .headers else .none;
    if (verbose == .none) {
        verbose = vm.getVerboseFetch();
    }

    var proxy: ?ZigURL = null;
    var redirect_type: FetchRedirect = FetchRedirect.follow;
    var signal: ?*jsc.WebCore.AbortSignal = null;
    // Custom Hostname
    var hostname: ?[]u8 = null;
    var range: ?[]u8 = null;
    var unix_socket_path: bun.String.Slice = bun.String.Slice.empty;

    var url_proxy_buffer: []const u8 = "";
    const URLType = enum {
        remote,
        file,
        blob,
    };
    var url_type = URLType.remote;

    var ssl_config: ?SSLConfig.SharedPtr = null;
    var reject_unauthorized = vm.getTLSRejectUnauthorized();
    var check_server_identity: ?FetchCheckServerIdentityCallback = null;
    var tasklet_owns_inputs = false;

    defer {
        if (!tasklet_owns_inputs) {
            if (signal) |sig| {
                signal = null;
                sig.unref();
            }

            unix_socket_path.deinit();

            allocator.free(url_proxy_buffer);
            url_proxy_buffer = "";

            if (headers) |*headers_| {
                headers_.buf.deinit(allocator);
                headers_.entries.deinit(allocator);
                headers = null;
            }

            body.detach();

            if (check_server_identity) |*callback| {
                callback.deinit();
                check_server_identity = null;
            }

            // clean hostname if any
            if (hostname) |hn| {
                bun.default_allocator.free(hn);
                hostname = null;
            }

            if (ssl_config) |*conf| {
                conf.deinit();
                ssl_config = null;
            }
        }
        if (range) |range_| {
            bun.default_allocator.free(range_);
            range = null;
        }
    }

    const converted_input = try input_argument.convert(context);
    const request_properties = if (converted_input.value == .request)
        try args.request_properties.?.convert(context)
    else properties: {
        try args.request_properties.?.discard(context);
        break :properties null;
    };
    var request: ?*Request = null;
    var request_reference: ?*const bun.bindgen.ClassRefView(RequestClassSchema) = null;
    var use_input_options = false;

    var url_str = extract_input: {
        switch (converted_input.value) {
            .url, .primitive_text => |text| {
                var owned = text.toOwned();
                break :extract_input owned.takeBunString();
            },
            .object_text => |text| {
                if (!text.eqlUTF8("[object Object]")) {
                    var owned = text.toOwned();
                    break :extract_input owned.takeBunString();
                }
                use_input_options = true;
                const input_url = try args.input_url.?.convert(context);
                if (input_url.value.url) |url_field| {
                    var owned = url_field.toOwned();
                    break :extract_input owned.takeBunString();
                }
                break :extract_input bun.String.empty;
            },
            .request => |*request_ref| {
                request = request_ref.get(Request);
                request_reference = request_ref;
                var request_url = request_properties.?.value.url.toOwned();
                break :extract_input request_url.takeBunString();
            },
        }
    };
    defer url_str.deref();

    if (!use_input_options) try args.input_url.?.discard(context);

    if (url_str.isEmpty()) {
        return failFetch(completion, .blank_url);
    }

    if (url_str.hasPrefixComptime("data:")) {
        var url_slice = try url_str.toUTF8WithoutRef(allocator);
        defer url_slice.deinit();

        var data_url = DataURL.parseWithoutCheck(url_slice.slice()) catch {
            return failFetch(completion, .invalid_data_url);
        };

        data_url.url = url_str;
        const response = dataURLResponse(data_url, globalThis, allocator) catch |err| switch (err) {
            error.InvalidDataURL => return failFetch(completion, .invalid_data_url),
            else => |js_error| return js_error,
        };
        return resolveFetch(completion, response);
    }

    url = normalizeURL(allocator, url_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidURL => {
            return failFetch(completion, .invalid_url);
        },
    };
    if (url.isFile()) {
        url_type = URLType.file;
    } else if (url.isBlob()) {
        url_type = URLType.blob;
    }
    url_proxy_buffer = url.href;

    const init_converted = if (args.init) |init_argument| try init_argument.convert(context) else null;
    const source_converted = if (use_input_options) try args.input_options.?.convert(context) else null;
    const Fields = @FieldType(@TypeOf(source_converted.?.value), "options");
    const init_fields: ?*const Fields = if (init_converted) |*converted| switch (converted.value) {
        .options => |*options| options,
        .ignored => null,
    } else null;
    const input_fields: ?*const Fields = if (source_converted) |*converted| switch (converted.value) {
        .options => |*options| options,
        .ignored => null,
    } else null;
    var init_values = std.mem.zeroes(fetchOptionValues(Fields));
    var input_values = std.mem.zeroes(fetchOptionValues(Fields));
    const proof = try prepareFetchOptions(Fields, context, init_fields, input_fields, if (request_properties) |*properties| &properties.value else null, if (use_input_options) null else args.input_options, url.isS3(), &init_values, &input_values);
    try context.lease(proof);

    const options_source: ?*const fetchOptionValues(Fields) = if (init_fields != null) &init_values else null;
    const input_source: ?*const fetchOptionValues(Fields) = if (input_fields != null or request_properties != null) &input_values else null;
    const sources = [2]@TypeOf(options_source){ options_source, input_source };

    // "method"
    method = method: {
        if (options_source) |source| {
            if (source.method) |field| {
                if (field) |value| break :method Method.fromBinding(value);
            }
        }

        if (input_source) |source| {
            if (source.method) |field| {
                if (field) |value| break :method Method.fromBinding(value);
            }
        }

        break :method .GET;
    };

    // "decompress: boolean"
    for (sources) |source_optional| {
        const source = source_optional orelse continue;
        if (booleanOrCountValue(source.decompress)) |flag| {
            disable_decompression = !flag;
            break;
        }
    }

    // "tls: TLSConfig"
    tls: for (sources) |source_optional| {
        const source = source_optional orelse continue;
        const field = if (source.tls) |*value| value else continue;
        switch (field.*) {
            .config => |*tls| {
                if (tls.reject_unauthorized) |reject| {
                    reject_unauthorized = reject;
                }
                if (tls.check_server_identity) |*identity_field| switch (identity_field.*) {
                    .callback => |callback| check_server_identity = try callback.toOwned(),
                    .ignored => {},
                };
                const default_reject_unauthorized = bun.current_runtime.tlsRejectUnauthorized();
                switch (try SSLConfigEngine.parseResult(default_reject_unauthorized, tls)) {
                    .value => |config| if (config) |value| {
                        var owned_config = value;
                        defer owned_config.deinit();
                        ssl_config = try SSLConfig.GlobalRegistry.intern(vm.io, &owned_config);
                    },
                    .failure => |failure| return rejectTLSConfig(completion, failure),
                }
                break :tls;
            },
            .ignored => {},
        }
    }

    // unix: string | undefined
    unix: for (sources) |source_optional| {
        const source = source_optional orelse continue;
        const field = if (source.unix_path) |*value| value else continue;
        switch (field.*) {
            .text => |*text| {
                if (text.length() == 0) continue;
                const utf8 = try text.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                unix_socket_path = try bun.TextView.toSliceClone(.{ .utf8 = utf8.slice() }, allocator);
                break :unix;
            },
            .ignored => {},
        }
    }

    // protocol: "http2" | "h2" | "http1.1" | "h1" | undefined.
    protocol: for (sources) |source_optional| {
        const source = source_optional orelse continue;
        const field = source.protocol orelse continue;
        switch (field) {
            .name => |name| {
                switch (name) {
                    .http1 => force_http1 = true,
                    .http2 => force_http2 = true,
                    .http3 => force_http3 = true,
                }
                break :protocol;
            },
            .ignored => {},
        }
    }

    // timeout: false | number | undefined
    for (sources) |source_optional| {
        const source = source_optional orelse continue;
        if (booleanOrCountValue(source.timeout)) |flag| {
            disable_timeout = !flag;
            break;
        }
    }

    // redirect: "follow" | "error" | "manual" | undefined;
    // The Request object supplies the default, which the option objects can
    // override.
    if (request) |req| {
        redirect_type = req.flags.redirect;
    }
    redirect: for (sources) |source_optional| {
        const source = source_optional orelse continue;
        const field = source.redirect orelse continue;
        switch (field) {
            .value => |value| {
                redirect_type = @fromBackingInt(@intCast(@as(u8, @intCast(@backingInt(value)))));
                break :redirect;
            },
            .ignored => {},
        }
    }

    // keepalive: boolean | undefined;
    for (sources) |source_optional| {
        const source = source_optional orelse continue;
        if (booleanOrCountValue(source.keepalive)) |flag| {
            disable_keepalive = !flag;
            break;
        }
    }

    // verbose: boolean | "curl" | undefined;
    verbose: for (sources) |source_optional| {
        const source = source_optional orelse continue;
        const field = if (source.verbose) |*value| value else continue;
        switch (field.*) {
            .flag => |flag| {
                verbose = if (flag) .headers else .none;
                break :verbose;
            },
            .name => |*name| {
                const utf8 = try name.toUTF8(bun.default_allocator);
                defer utf8.deinit();
                if (bun.strings.eqlComptime(utf8.slice(), "curl")) {
                    verbose = .curl;
                    break :verbose;
                }
            },
            .ignored => {},
        }
    }

    // proxy: string | { url: string, headers?: Headers } | undefined;
    var proxy_headers: ?Headers = null;
    defer {
        if (!tasklet_owns_inputs) {
            if (proxy_headers) |*hdrs| hdrs.deinit();
        }
    }
    proxy: for (sources) |source_optional| {
        const source = source_optional orelse continue;
        const field = if (source.proxy) |*value| value else continue;

        var config_headers: ?*FetchHeaders = null;
        var proxy_url: bun.bindgen.DOMString = switch (field.*) {
            .text => |*text| text: {
                if (text.length() == 0) continue :proxy;
                break :text text.toOwned();
            },
            .config => |*config| config: {
                const url_field = if (config.url) |*value| value else continue :proxy;
                if (url_field.*) |*url_value| {
                    switch (url_value.*) {
                        .text => |*text| if (text.length() > 0) {
                            if (config.headers) |*headers_field| {
                                if (headers_field.*) |*handle| {
                                    config_headers = handle.get();
                                }
                            }
                            break :config text.toOwned();
                        },
                        .invalid => {},
                    }
                    return failFetch(completion, .invalid_proxy_field);
                }
                continue :proxy;
            },
            .ignored => continue :proxy,
        };
        defer proxy_url.deinit();

        var proxy_input = try proxy_url.toThreadSafe();
        defer proxy_input.deinit();
        var href = (try bun.bindgen.Engine(bun.bindgen.Module("urls").engineShim("urlHrefFromString")).call(.{ .input = proxy_input.operand() })) orelse
            return failFetch(completion, .invalid_proxy_url);
        defer href.deinit();
        var href_utf8 = try href.toUTF8(allocator);
        defer href_utf8.deinit();
        const buffer = try std.fmt.allocPrint(allocator, "{s}{s}", .{ url_proxy_buffer, href_utf8.slice() });
        url = ZigURL.parse(buffer[0..url.href.len]);
        if (url.isFile()) {
            url_type = URLType.file;
        } else if (url.isBlob()) {
            url_type = URLType.blob;
        }

        proxy = ZigURL.parse(buffer[url.href.len..]);
        allocator.free(url_proxy_buffer);
        url_proxy_buffer = buffer;

        if (config_headers) |fetch_hdrs| {
            proxy_headers = try HeadersEngine.from(fetch_hdrs, allocator, .{});
        }

        break :proxy;
    }

    // signal: AbortSignal | undefined;
    signal = signal: {
        if (options_source) |source| {
            if (source.signal) |*field| switch (field.*) {
                .signal => |*signal_ref| break :signal signal_ref.get().ref(),
                .ignored => {},
            };
        }

        if (request) |req| {
            if (req.signal) |signal_ref| {
                var cloned_signal = signal_ref.clone();
                break :signal cloned_signal.take();
            }
            break :signal null;
        }

        if (input_source) |source| {
            if (source.signal) |*field| switch (field.*) {
                .signal => |*signal_ref| break :signal signal_ref.get().ref(),
                .ignored => {},
            };
        }

        break :signal null;
    };

    // We do this 2nd to last instead of last so that if it's a FormData
    // object, we can still insert the boundary.
    //
    // body: BodyInit | null | undefined;
    //
    body = body: {
        if (options_source) |source| {
            if (source.body) |*body_init| {
                break :body try FetchTasklet.HTTPRequestBody.fromGeneratedBodyInit(globalThis, context, body_init);
            }
        }

        if (request) |req| {
            const bodyValue = req.getBodyValue();
            const request_receiver = request_reference.?.*;
            if (bodyValue.* == .Used or (bodyValue.* == .Locked and (bodyValue.Locked.action != .none or try bodyValue.Locked.isDisturbed(globalThis, Request, context, request_receiver)))) {
                return globalThis.throwNodeError(.ERR_BODY_ALREADY_USED, "Request body already used", .{});
            }

            if (bodyValue.* == .Locked) {
                if (try req.getBodyReadableStream(globalThis)) |readable| {
                    break :body FetchTasklet.HTTPRequestBody{ .ReadableStream = readable };
                }
                if (bodyValue.Locked.readable.has()) {
                    break :body FetchTasklet.HTTPRequestBody{ .ReadableStream = bodyValue.Locked.readable.clone() };
                }
                if (try bodyValue.toReadableStream(globalThis)) |readable| {
                    var owned_readable = readable;
                    owned_readable.deinit();
                }
                if (bodyValue.* == .Locked and bodyValue.Locked.readable.has()) {
                    break :body FetchTasklet.HTTPRequestBody{ .ReadableStream = bodyValue.Locked.readable.clone() };
                }
            }

            break :body FetchTasklet.HTTPRequestBody{ .AnyBlob = try bodyValue.useAsAnyBlob() };
        }

        if (input_source) |source| {
            if (source.body) |*body_init| {
                break :body try FetchTasklet.HTTPRequestBody.fromGeneratedBodyInit(globalThis, context, body_init);
            }
        }

        break :body FetchTasklet.HTTPRequestBody.Empty;
    };

    // headers: Headers | undefined;
    headers = headers: {
        const fetch_headers: *FetchHeaders = brk: {
            if (options_source) |source| {
                if (source.headers) |*field| {
                    if (field.*) |*handle| break :brk handle.get();
                    break :headers headers;
                }
            }

            if (input_source) |source| {
                if (source.headers) |*field| {
                    if (field.*) |*handle| break :brk handle.get();
                    break :headers headers;
                }
            }

            break :headers headers;
        };

        if (try fetch_headers.fastGet(.Host)) |owned_hostname| {
            var _hostname = owned_hostname;
            defer _hostname.deinit();
            if (hostname) |host| {
                hostname = null;
                allocator.free(host);
            }
            hostname = try _hostname.toOwnedSliceZ(allocator);
        }
        if (url.isS3()) {
            if (try fetch_headers.fastGet(.Range)) |owned_range| {
                var _range = owned_range;
                defer _range.deinit();
                if (range) |range_| {
                    range = null;
                    allocator.free(range_);
                }
                range = try _range.toOwnedSliceZ(allocator);
            }
        }

        if (try fetch_headers.fastGet(.Upgrade)) |owned_upgrade| {
            var _upgrade = owned_upgrade;
            defer _upgrade.deinit();
            if (!_upgrade.eqlUTF8("h2") and !_upgrade.eqlUTF8("h2c")) {
                upgraded_connection = true;
            }
        }

        break :headers try HeadersEngine.from(fetch_headers, allocator, .{ .body = body.getAnyBlob() });
    };

    if (proxy != null and unix_socket_path.length() > 0) {
        return failFetch(completion, .proxy_with_unix_socket);
    }

    if (globalThis.hasException()) {
        return error.JSError;
    }

    // This is not 100% correct.
    // We don't pass along headers, we ignore method, we ignore status code...
    // But it's better than status quo.
    if (url_type != .remote) {
        defer unix_socket_path.deinit();
        var path_buf: bun.PathBuffer = undefined;
        const PercentEncoding = @import("../../url/url.zig").PercentEncoding;
        var path_buf2: bun.PathBuffer = undefined;
        var stream = std.Io.Writer.fixed(&path_buf2);
        var url_path_decoded = path_buf2[0 .. PercentEncoding.decode(
            &stream,
            switch (url_type) {
                .file => url.path,
                .blob => url.href["blob:".len..],
                .remote => unreachable,
            },
        ) catch |err| {
            return globalThis.throwError(err, "Failed to decode file url");
        }];
        var url_string: bun.String = bun.String.empty;
        defer url_string.deref();
        // This can be a blob: url or a file: url.
        var blob_to_use = blob: {

            // Support blob: urls
            if (url_type == URLType.blob) {
                if (try jsc.WebCore.ObjectURLRegistry.singleton().resolveAndDupe(globalThis.bunVM().io, url_path_decoded)) |resolved_blob| {
                    var owned_blob = resolved_blob;
                    errdefer owned_blob.deinit();
                    url_string = try bun.String.createFormat("blob:{s}", .{url_path_decoded});
                    break :blob owned_blob;
                } else {
                    const message = try bun.bindgen.ThreadSafeDOMString.fromBunString(try bun.String.createFormat("Failed to resolve blob:{s}", .{url_path_decoded}));
                    var owned = bun.take(completion) orelse @panic("fetch blob failure has no completion");
                    owned.fail(.unresolved_blob_url, message);
                    return;
                }
            }

            const temp_file_path = brk: {
                if (std.fs.path.isAbsolute(url_path_decoded)) {
                    if (Environment.isWindows) {
                        if (url_path_decoded[0] == '/' and std.fs.path.parsePathWindows(u8, url_path_decoded[1..]).kind == .drive_absolute) {
                            url_path_decoded = url_path_decoded[1..];
                        }
                        var cwd_buf: bun.PathBuffer = undefined;
                        const cwd = bun.getcwd(&cwd_buf) catch |err| {
                            return globalThis.throwError(err, "Failed to resolve file url");
                        };
                        break :brk bun.path.joinAbsStringBuf(cwd, &path_buf, &.{url_path_decoded}, .windows);
                    }
                    break :brk url_path_decoded;
                }

                var cwd_buf: bun.PathBuffer = undefined;
                const cwd = if (Environment.isWindows) (bun.getcwd(&cwd_buf) catch |err| {
                    return globalThis.throwError(err, "Failed to resolve file url");
                }) else globalThis.bunVM().transpiler.fs.top_level_dir;

                const fullpath = bun.path.joinAbsStringBuf(
                    cwd,
                    &path_buf,
                    &[_]string{
                        globalThis.bunVM().main,
                        "../",
                        url_path_decoded,
                    },
                    .auto,
                );
                break :brk fullpath;
            };

            const temp_file_path_string = bun.String.cloneUTF8(temp_file_path);
            if (temp_file_path_string.tag == .Dead) return error.OutOfMemory;
            defer temp_file_path_string.deref();
            url_string = try jsc.URL.fileURLFromString(temp_file_path_string);

            var pathlike: bun.api.node.PathOrFileDescriptor = .{
                .path = .{
                    .encoded_slice = bun.String.Slice.init(bun.default_allocator, try bun.default_allocator.dupe(u8, temp_file_path)),
                },
            };

            defer pathlike.deinit();
            break :blob try Blob.findOrCreateFileFromPath(
                &pathlike,
                globalThis,
                true,
            );
        };
        defer blob_to_use.deinit();

        var response_url = try bun.bindgen.DOMString.fromBunString(url_string.dupeRef());
        defer response_url.deinit();
        const response = try bun.default_allocator.create(Response);
        response.* = Response.init(
            Response.Init{
                .status_code = 200,
            },
            Body{
                .value = .{ .Blob = blob_to_use.take() },
            },
            response_url.take(),
            false,
        );

        return resolveFetch(completion, try response.toClassRef(globalThis));
    }

    if (url.protocol.len > 0) {
        if (!(url.isHTTP() or url.isHTTPS() or url.isS3())) {
            return failFetch(completion, .unsupported_protocol);
        }
    }

    if (!allow_get_body and !method.hasRequestBody() and body.hasBody() and !upgraded_connection) {
        return failFetch(completion, .unexpected_body);
    }

    if (headers == null and body.hasBody() and body.hasContentTypeFromUser()) {
        headers = try HeadersEngine.from(
            null,
            allocator,
            .{ .body = body.getAnyBlob() },
        );
    }

    var sendfile_body: ?FetchTasklet.HTTPRequestBody = null;
    defer if (sendfile_body) |*pending| pending.detach();
    if (body.isS3()) {
        prepare_body: {
            const stream = try jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(globalThis, &body.AnyBlob.Blob, s3.MultiPartUploadOptions.DefaultPartSize);
            var old = body;
            defer old.detach();
            body = .{ .ReadableStream = try jsc.WebCore.ReadableStream.Strong.initOwned(stream) };
            break :prepare_body;
        }
    }
    if (body.needsToReadFile()) {
        prepare_body: {
            const opened_fd_res: bun.sys.Maybe(bun.FD) = switch (body.store().?.data.file.pathlike) {
                .fd => |fd| bun.sys.dup(fd),
                .path => |path| bun.sys.open(path.sliceZ(&globalThis.bunVM().nodeFS().sync_error_buf), if (Environment.isWindows) bun.O.RDONLY else bun.O.RDONLY | bun.O.NOCTTY, 0),
            };

            const opened_fd = switch (opened_fd_res) {
                .err => |err| {
                    const payload = try bun.bindgen.SystemError.fromSysError(err);
                    var owned = bun.take(completion) orelse @panic("fetch body failure has no completion");
                    owned.fail(.body_io, payload);
                    return;
                },
                .result => |fd| fd,
            };
            var owns_opened_fd = true;
            defer if (owns_opened_fd) opened_fd.close();

            if (proxy == null and bun.http.SendFile.isEligible(url)) {
                use_sendfile: {
                    const stat: bun.Stat = switch (bun.sys.fstat(opened_fd)) {
                        .result => |result| result,
                        // bail out for any reason
                        .err => break :use_sendfile,
                    };

                    if (Environment.isMac) {
                        // macOS only supports regular files for sendfile()
                        if (!bun.isRegularFile(stat.mode)) {
                            break :use_sendfile;
                        }
                    }

                    // if it's < 32 KB, it's not worth it
                    if (stat.size < 32 * 1024) {
                        break :use_sendfile;
                    }

                    const original_size = body.AnyBlob.Blob.size;
                    const stat_size = @as(Blob.SizeType, @intCast(stat.size));
                    const blob_size = if (bun.isRegularFile(stat.mode))
                        stat_size
                    else
                        @min(original_size, stat_size);

                    sendfile_body = .{
                        .Sendfile = .{
                            .fd = opened_fd,
                            .remain = body.AnyBlob.Blob.offset + original_size,
                            .offset = body.AnyBlob.Blob.offset,
                            .content_size = blob_size,
                        },
                    };

                    if (bun.isRegularFile(stat.mode)) {
                        sendfile_body.?.Sendfile.offset = @min(sendfile_body.?.Sendfile.offset, stat_size);
                        sendfile_body.?.Sendfile.remain = @min(@max(sendfile_body.?.Sendfile.remain, sendfile_body.?.Sendfile.offset), stat_size) -| sendfile_body.?.Sendfile.offset;
                    }
                    owns_opened_fd = false;
                    body.detach();

                    break :prepare_body;
                }
            }

            // TODO: make this async + lazy
            const res = bun.api.node.fs.NodeFS.readFile(
                globalThis.bunVM().nodeFS(),
                .{
                    .encoding = .buffer,
                    .path = .{ .fd = opened_fd },
                    .offset = body.AnyBlob.Blob.offset,
                    .max_size = body.AnyBlob.Blob.size,
                },
                .sync,
            );

            switch (res) {
                .err => |err| {
                    const payload = try bun.bindgen.SystemError.fromSysError(err);
                    body.detach();
                    var owned = bun.take(completion) orelse @panic("fetch body failure has no completion");
                    owned.fail(.body_io, payload);
                    return;
                },
                .result => |result| {
                    var owned_result = result;
                    defer owned_result.deinit();
                    const bytes = switch (owned_result) {
                        .buffer => |*buffer| buffer.takeDefaultOwned() orelse try allocator.dupe(u8, buffer.slice()),
                        else => try allocator.dupe(u8, owned_result.slice()),
                    };
                    body.detach();
                    body = .{ .AnyBlob = .fromOwnedSlice(allocator, bytes) };
                },
            }
        }
    }

    if (url.isS3()) {
        // get ENV config
        var credentialsWithOptions: s3.S3CredentialsWithOptions = .{
            .credentials = globalThis.bunVM().transpiler.env.getS3Credentials(),
            .options = .{},
            .acl = null,
            .storage_class = null,
        };
        defer {
            credentialsWithOptions.deinit();
        }

        if (options_source) |source| {
            if (source.s3 != null and source.s3.? == .options) {
                credentialsWithOptions = try S3CredentialsJSC.getCredentialsWithBindingOptions(credentialsWithOptions.credentials, .{}, source.s3, null, null, false, globalThis);
            }
        }

        if (body == .ReadableStream) {
            // we cannot direct stream to s3 we need to use multi part upload
            defer body.ReadableStream.deinit();
            const Wrapper = struct {
                completion: FetchTasklet.FetchCompletions.Owned,
                url: ZigURL,
                url_proxy_buffer: []const u8,

                fn completeResponse(self: *@This(), failure: ?s3.Error.S3Error) bun.OOM!void {
                    const response = try bun.default_allocator.create(Response);
                    response.* = Response.init(.{ .method = .PUT, .status_code = 200 }, .{ .value = .Empty }, .empty(), false);
                    errdefer response.unref();
                    response.url = try bun.bindgen.DOMString.fromUTF8(self.url.href);
                    if (failure) |err| {
                        response.response_init.status_code = 500;
                        response.response_init.status_text = try bun.bindgen.DOMString.fromUTF8(err.code);
                        response.body.value = .{ .InternalBlob = .{
                            .bytes = .fromOwnedSlice(bun.default_allocator, try bun.default_allocator.dupe(u8, err.message)),
                            .was_string = true,
                        } };
                    }
                    FetchTasklet.completeFetch(&self.completion, .{ .native_response = response });
                }

                pub fn resolve(result: s3.S3UploadStreamResult, opaque_self: bun.bindgen.NativeCallbackContext(.vm)) void {
                    const self = opaque_self.get(*@This());
                    defer bun.destroy(self);
                    defer bun.default_allocator.free(self.url_proxy_buffer);
                    switch (result) {
                        .out_of_memory => self.completion.outOfMemory(),
                        .terminated => self.completion.release(),
                        .success => self.completeResponse(null) catch self.completion.outOfMemory(),
                        .failure => |failure| self.completeResponse(failure.error_value) catch self.completion.outOfMemory(),
                        .stream_error => |reason| {
                            var root = reason.clone();
                            self.completion.reject(&root, .{ .attach_async_stack = true });
                        },
                    }
                }
            };
            if (method != .PUT and method != .POST) {
                return failFetch(completion, .s3_body_method);
            }
            const stream_credentials = try credentialsWithOptions.credentials.dupe();
            defer stream_credentials.deref();
            const s3_stream = try bun.default_allocator.create(Wrapper);
            const taken = completion.*.?;
            completion.* = null;
            s3_stream.* = .{
                .url = url,
                .url_proxy_buffer = url_proxy_buffer,
                .completion = taken,
            };

            const proxy_url = if (proxy) |p| p.href else "";
            S3StreamEngine.uploadStream(
                stream_credentials,
                url.s3Path(),
                &body.ReadableStream,
                globalThis,
                credentialsWithOptions.options,
                credentialsWithOptions.acl,
                credentialsWithOptions.storage_class,
                if (headers) |h| (h.getContentType()) else null,
                if (headers) |h| h.getContentDisposition() else null,
                if (headers) |h| h.getContentEncoding() else null,
                proxy_url,
                credentialsWithOptions.request_payer,
                Wrapper.resolve,
                .init(s3_stream),
            ) catch |err| {
                var owned_completion = s3_stream.completion;
                bun.destroy(s3_stream);
                switch (err) {
                    error.OutOfMemory => owned_completion.outOfMemory(),
                    error.JSError => {
                        var thrown = context.takeThrownValue(err) catch |termination| {
                            owned_completion.release();
                            return termination;
                        };
                        defer thrown.deinit();
                        var error_root = thrown.toRoot() catch |failure| {
                            owned_completion.release();
                            return failure;
                        };
                        owned_completion.reject(&error_root, .{ .attach_async_stack = true });
                    },
                    error.JSTerminated => {
                        owned_completion.release();
                        return error.JSTerminated;
                    },
                }
                return;
            };
            url = .{};
            url_proxy_buffer = "";
            return;
        }
        if (method == .POST) {
            method = .PUT;
        }

        var result = credentialsWithOptions.credentials.signRequest(.{
            .path = url.s3Path(),
            .method = method,
        }, false, null) catch |sign_err| {
            var error_value = try S3ErrorEngine.getSignError(context, sign_err);
            defer error_value.deinit();
            var root = try error_value.toRoot();
            defer root.deinit();
            var owned = completion.*.?;
            completion.* = null;
            FetchTasklet.completeFetch(&owned, .{ .js_error = root.takeOptional() });
            return;
        };
        defer result.deinit();
        if (proxy) |proxy_| {
            const length = std.math.add(usize, result.url.len, proxy_.href.len) catch return error.OutOfMemory;
            const buffer = try allocator.alloc(u8, length);
            @memcpy(buffer[0..result.url.len], result.url);
            @memcpy(buffer[result.url.len..], proxy_.href);
            const old_buffer = url_proxy_buffer;
            url_proxy_buffer = buffer;
            url = ZigURL.parse(url_proxy_buffer[0..result.url.len]);
            proxy = ZigURL.parse(url_proxy_buffer[result.url.len..]);
            allocator.free(old_buffer);
        } else {
            // replace headers and url of the request
            allocator.free(url_proxy_buffer);
            url_proxy_buffer = result.url;
            url = ZigURL.parse(result.url);
            result.url = ""; // fetch now owns this
        }

        const content_type = if (headers) |h| (h.getContentType()) else null;
        var header_buffer: [s3.S3Credentials.SignResult.MAX_HEADERS + 1]picohttp.Header = undefined;

        if (range) |range_| {
            const _headers = result.mixWithHeader(&header_buffer, .{ .name = "range", .value = range_ });
            try setHeaders(&headers, _headers, allocator);
        } else if (content_type) |ct| {
            if (ct.len > 0) {
                const _headers = result.mixWithHeader(&header_buffer, .{ .name = "Content-Type", .value = ct });
                try setHeaders(&headers, _headers, allocator);
            } else {
                try setHeaders(&headers, result.headers(), allocator);
            }
        } else {
            try setHeaders(&headers, result.headers(), allocator);
        }
    }

    var fetch_options: FetchTasklet.FetchOptions = .{
        .method = method,
        .url = url,
        .headers = headers orelse Headers{
            .allocator = allocator,
        },
        .body = if (sendfile_body) |*pending| pending.take() else body.take(),
        .disable_keepalive = disable_keepalive,
        .disable_timeout = disable_timeout,
        .disable_decompression = disable_decompression,
        .reject_unauthorized = reject_unauthorized,
        .redirect_type = redirect_type,
        .verbose = verbose,
        .proxy = proxy,
        .proxy_headers = proxy_headers,
        .url_proxy_buffer = url_proxy_buffer,
        .signal = signal,
        .globalThis = globalThis,
        .ssl_config = ssl_config,
        .hostname = hostname,
        .upgraded_connection = upgraded_connection,
        .force_http2 = force_http2,
        .force_http3 = force_http3,
        .force_http1 = force_http1,
        .check_server_identity = if (check_server_identity) |*identity| identity.take() else null,
        .unix_socket_path = unix_socket_path,
    };
    defer fetch_options.body.detach();
    const queued = FetchTasklet.queue(
        globalThis,
        &fetch_options,
        taken_completion: {
            const taken = completion.*.?;
            completion.* = null;
            break :taken_completion taken;
        },
    );
    tasklet_owns_inputs = true;
    try queued;
}

fn normalizeURL(allocator: std.mem.Allocator, input: bun.String) !ZigURL {
    var href = try jsc.URL.hrefFromString(input);
    if (href.tag == .Dead) return error.InvalidURL;
    defer href.deref();
    return ZigURL.parse(try href.toOwnedSlice(allocator));
}
fn setHeaders(headers: *?Headers, new_headers: []const picohttp.Header, allocator: std.mem.Allocator) bun.OOM!void {
    var old = headers.*;
    headers.* = try Headers.fromPicoHttpHeaders(new_headers, allocator);

    if (old) |*headers_| {
        headers_.deinit();
    }
}

const string = []const u8;

const std = @import("std");
const DataURL = @import("../../resolver/data_url.zig").DataURL;
const Method = @import("../../http_types/Method.zig").Method;
const ZigURL = @import("../../url/url.zig").URL;
const S3CredentialsJSC = @import("./s3/CredentialsEngine.zig");
const S3ErrorEngine = @import("./s3/ErrorEngine.zig");
const S3StreamEngine = @import("./s3/ClientStreamEngine.zig");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const picohttp = bun.picohttp;
const s3 = bun.S3;
const FetchHeaders = bun.webcore.FetchHeaders;
const SSLConfig = bun.api.server.ServerConfig.SSLConfig;
const SSLConfigEngine = bun.api.server.ServerConfig.SSLConfigEngine;

const http = bun.http;
const FetchRedirect = http.FetchRedirect;
const Headers = bun.http.Headers;
const HeadersEngine = bun.api.HTTPHeadersEngine;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
const Body = jsc.WebCore.Body;
const Request = jsc.WebCore.Request;
const Response = jsc.WebCore.Response;

const Blob = jsc.WebCore.Blob;
const AnyBlob = jsc.WebCore.Blob.Any;

const BunObjectBindings = bun.bindgen.Module("BunObject");
const NodeHTTPBindings = bun.bindgen.Module("NodeHTTP");
const RequestClassSchema = bun.bindgen.Module("Request").class("Request");
const FetchCheckServerIdentityCallback = bun.bindgen.Callback(bun.bindgen.CallbackSchema("FetchCheckServerIdentityCallback"));
const FetchSchema = BunObjectBindings.function("fetch");
const FetchPreconnectSchema = BunObjectBindings.function("fetchPreconnect");
const NodeHTTPClientSchema = NodeHTTPBindings.function("client");
const FetchBinding = bun.bindgen.Fn(FetchSchema, fetch);
const FetchPreconnectBinding = bun.bindgen.Fn(FetchPreconnectSchema, fetchPreconnect);
const NodeHTTPClientBinding = bun.bindgen.Fn(NodeHTTPClientSchema, nodeHttpClient);

comptime {
    _ = FetchBinding;
    _ = FetchPreconnectBinding;
    _ = NodeHTTPClientBinding;
}
