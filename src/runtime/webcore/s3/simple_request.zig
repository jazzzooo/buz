pub const CallbackContext = bun.bindgen.NativeCallbackContext(.vm);

pub const S3StatResult = union(enum) {
    out_of_memory,
    success: struct {
        size: usize = 0,
        /// etag is not owned and need to be copied if used after this callback
        etag: []const u8 = "",
        /// format: Mon, 06 Jan 2025 22:40:57 GMT, lastModified is not owned and need to be copied if used after this callback
        lastModified: []const u8 = "",
        /// format: text/plain, contentType is not owned and need to be copied if used after this callback
        contentType: []const u8 = "",
    },
    not_found: S3Error,

    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};
pub const S3DownloadResult = union(enum) {
    out_of_memory,
    success: struct {
        /// etag is not owned and need to be copied if used after this callback
        etag: []const u8 = "",
        /// body is owned and dont need to be copied, but dont forget to free it
        body: bun.MutableString,
    },
    not_found: S3Error,
    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};
pub const S3UploadResult = union(enum) {
    success: void,
    out_of_memory,
    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};
pub const S3DeleteResult = union(enum) {
    out_of_memory,
    success: void,
    not_found: S3Error,

    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};
pub const S3ListObjectsResult = union(enum) {
    out_of_memory,
    success: bun.MutableString,
    not_found: S3Error,

    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};

// commit result also fails if status 200 but with body containing an Error
pub const S3CommitResult = union(enum) {
    out_of_memory,
    success: void,
    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};
// commit result also fails if status 200 but with body containing an Error
pub const S3PartResult = union(enum) {
    out_of_memory,
    etag: []const u8,
    /// failure error is not owned and need to be copied if used after this callback
    failure: S3Error,
};

pub const RequestFailure = union(enum) {
    out_of_memory,
    service: S3Error,

    pub fn fromError(err: anyerror) RequestFailure {
        if (err == error.OutOfMemory) return .out_of_memory;
        if (err == error.InvalidRange) return .{ .service = .{
            .code = "InvalidRange",
            .message = "The requested byte range is too large",
        } };
        const failure = getSignErrorCodeAndMessage(err);
        return .{ .service = .{ .code = failure.code, .message = failure.message } };
    }
};

pub fn S3HttpSimpleTask(comptime Scheduler: type) type {
    return struct {
        http: bun.http.AsyncHTTP,
        scheduler: Scheduler,
        request: PreparedRequest,
        callback_context: CallbackContext,
        callback: Callback,
        response_buffer: bun.MutableString = .{
            .allocator = bun.default_allocator,
            .list = .{
                .items = &.{},
                .capacity = 0,
            },
        },
        result: bun.http.HTTPClientResult = .{},
        poll_ref: bun.Async.KeepAlive = bun.Async.KeepAlive.init(),

        pub const Callback = union(enum) {
            stat: *const fn (S3StatResult, CallbackContext) void,
            download: *const fn (S3DownloadResult, CallbackContext) void,
            upload: *const fn (S3UploadResult, CallbackContext) void,
            delete: *const fn (S3DeleteResult, CallbackContext) void,
            listObjects: *const fn (S3ListObjectsResult, CallbackContext) void,
            commit: *const fn (S3CommitResult, CallbackContext) void,
            part: *const fn (S3PartResult, CallbackContext) void,

            pub fn outOfMemory(this: @This(), context: CallbackContext) void {
                switch (this) {
                    inline else => |callback| callback(.out_of_memory, context),
                }
            }

            pub fn failSigning(this: @This(), err: anyerror, context: CallbackContext) void {
                switch (RequestFailure.fromError(err)) {
                    .out_of_memory => this.outOfMemory(context),
                    .service => |failure| this.fail(failure.code, failure.message, context),
                }
            }

            pub fn fail(this: @This(), code: []const u8, message: []const u8, context: CallbackContext) void {
                switch (this) {
                    inline .upload,
                    .download,
                    .stat,
                    .delete,
                    .listObjects,
                    .commit,
                    .part,
                    => |callback| callback(.{
                        .failure = .{
                            .code = code,
                            .message = message,
                        },
                    }, context),
                }
            }
            pub fn notFound(this: @This(), code: []const u8, message: []const u8, context: CallbackContext) void {
                switch (this) {
                    inline .download,
                    .stat,
                    .delete,
                    .listObjects,
                    => |callback| callback(.{
                        .not_found = .{
                            .code = code,
                            .message = message,
                        },
                    }, context),
                    else => this.fail(code, message, context),
                }
            }
        };

        pub fn deinit(this: *@This()) void {
            if (this.result.certificate_info) |*certificate| {
                certificate.deinit(bun.default_allocator);
            }
            this.scheduler.unref(&this.poll_ref);
            this.response_buffer.deinit();
            this.request.deinit();
            this.http.clearData();
            if (this.result.metadata) |*metadata| {
                metadata.deinit(bun.default_allocator);
            }
            bun.destroy(this);
        }

        const ErrorType = enum {
            not_found,
            failure,
        };
        fn errorWithBody(this: @This(), comptime error_type: ErrorType) void {
            var code: []const u8 = "UnknownError";
            var message: []const u8 = "an unexpected error has occurred";
            var has_error_code = false;
            if (this.result.fail) |err| {
                if (err == error.OutOfMemory) {
                    this.callback.outOfMemory(this.callback_context);
                    return;
                }
                code = @errorName(err);
                has_error_code = true;
            } else if (this.result.body) |body| {
                const bytes = body.list.items;
                if (bytes.len > 0) {
                    message = bytes[0..];
                    if (strings.indexOf(bytes, "<Code>")) |start| {
                        if (strings.indexOf(bytes, "</Code>")) |end| {
                            code = bytes[start + "<Code>".len .. end];
                            has_error_code = true;
                        }
                    }
                    if (strings.indexOf(bytes, "<Message>")) |start| {
                        if (strings.indexOf(bytes, "</Message>")) |end| {
                            message = bytes[start + "<Message>".len .. end];
                        }
                    }
                }
            }

            if (error_type == .not_found) {
                if (!has_error_code) {
                    code = "NoSuchKey";
                    message = "The specified key does not exist.";
                }
                this.callback.notFound(code, message, this.callback_context);
            } else {
                this.callback.fail(code, message, this.callback_context);
            }
        }

        fn failIfContainsError(this: *@This(), status: u32) bool {
            var code: []const u8 = "UnknownError";
            var message: []const u8 = "an unexpected error has occurred";

            if (this.result.fail) |err| {
                code = @errorName(err);
            } else if (this.result.body) |body| {
                const bytes = body.list.items;
                var has_error = false;
                if (bytes.len > 0) {
                    message = bytes[0..];
                    if (strings.indexOf(bytes, "<Error>") != null) {
                        has_error = true;
                        if (strings.indexOf(bytes, "<Code>")) |start| {
                            if (strings.indexOf(bytes, "</Code>")) |end| {
                                code = bytes[start + "<Code>".len .. end];
                            }
                        }
                        if (strings.indexOf(bytes, "<Message>")) |start| {
                            if (strings.indexOf(bytes, "</Message>")) |end| {
                                message = bytes[start + "<Message>".len .. end];
                            }
                        }
                    }
                }
                if (!has_error and status == 200 or status == 206) {
                    return false;
                }
            } else if (status == 200 or status == 206) {
                return false;
            }
            this.callback.fail(code, message, this.callback_context);
            return true;
        }
        /// this is the task callback from the last task result and is always in the main thread
        pub fn onResponse(this: *@This()) void {
            defer this.deinit();
            if (!this.result.isSuccess()) {
                this.errorWithBody(.failure);
                return;
            }
            bun.assert(this.result.metadata != null);
            const response = this.result.metadata.?.response;
            switch (this.callback) {
                .stat => |callback| {
                    switch (response.status_code) {
                        200 => {
                            callback(.{
                                .success = .{
                                    .etag = response.headers.get("etag") orelse "",
                                    .lastModified = response.headers.get("last-modified") orelse "",
                                    .contentType = response.headers.get("content-type") orelse "",
                                    .size = if (response.headers.get("content-length")) |content_len| (std.fmt.parseInt(usize, content_len, 10) catch 0) else 0,
                                },
                            }, this.callback_context);
                        },
                        404 => {
                            this.errorWithBody(.not_found);
                        },
                        else => {
                            this.errorWithBody(.failure);
                        },
                    }
                },
                .delete => |callback| {
                    switch (response.status_code) {
                        200, 204 => {
                            callback(.{ .success = {} }, this.callback_context);
                        },
                        404 => {
                            this.errorWithBody(.not_found);
                        },
                        else => {
                            this.errorWithBody(.failure);
                        },
                    }
                },
                .listObjects => |callback| {
                    switch (response.status_code) {
                        200 => {
                            if (this.result.body != null) {
                                const body = this.response_buffer;
                                this.response_buffer = .{
                                    .allocator = bun.default_allocator,
                                    .list = .{
                                        .items = &.{},
                                        .capacity = 0,
                                    },
                                };
                                callback(.{ .success = body }, this.callback_context);
                            } else {
                                this.errorWithBody(.failure);
                            }
                        },
                        404 => {
                            this.errorWithBody(.not_found);
                        },
                        else => {
                            this.errorWithBody(.failure);
                        },
                    }
                },
                .upload => |callback| {
                    switch (response.status_code) {
                        200 => {
                            callback(.{ .success = {} }, this.callback_context);
                        },
                        else => {
                            this.errorWithBody(.failure);
                        },
                    }
                },
                .download => |callback| {
                    switch (response.status_code) {
                        200, 204, 206 => {
                            const body = this.response_buffer;
                            this.response_buffer = .{
                                .allocator = bun.default_allocator,
                                .list = .{
                                    .items = &.{},
                                    .capacity = 0,
                                },
                            };
                            callback(.{
                                .success = .{
                                    .etag = response.headers.get("etag") orelse "",
                                    .body = body,
                                },
                            }, this.callback_context);
                        },
                        404 => {
                            this.errorWithBody(.not_found);
                        },
                        else => {
                            //error
                            this.errorWithBody(.failure);
                        },
                    }
                },
                .commit => |callback| {
                    // commit multipart upload can fail with status 200
                    if (!this.failIfContainsError(response.status_code)) {
                        callback(.{ .success = {} }, this.callback_context);
                    }
                },
                .part => |callback| {
                    if (!this.failIfContainsError(response.status_code)) {
                        if (response.headers.get("etag")) |etag| {
                            callback(.{ .etag = etag }, this.callback_context);
                        } else {
                            this.errorWithBody(.failure);
                        }
                    }
                },
            }
        }

        /// this is the callback from the http.zig AsyncHTTP is always called from the HTTPThread
        pub fn httpCallback(this: *@This(), async_http: *bun.http.AsyncHTTP, result: bun.http.HTTPClientResult) void {
            const is_done = !result.has_more;
            this.result = result;
            this.http = async_http.*;
            this.response_buffer = async_http.response_buffer.*;
            if (is_done) {
                this.scheduler.enqueue(this);
            }
        }
    };
}

pub const S3SimpleRequestOptions = struct {
    // signing options
    path: []const u8,
    method: bun.http.Method,
    search_params: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,

    // http request options
    body: []const u8,
    proxy_url: ?[]const u8 = null,
    range: ?[]const u8 = null,
    acl: ?ACL = null,
    storage_class: ?StorageClass = null,
    request_payer: bool = false,
};

pub const PreparedRequest = struct {
    sign_result: SignResult,
    headers: bun.http.Headers,
    range: ?[]const u8,
    proxy_url: []const u8,

    /// Takes ownership of options.range on both success and failure.
    pub fn create(credentials: *const S3Credentials, options: S3SimpleRequestOptions, comptime allow_empty_path: bool) !PreparedRequest {
        errdefer if (options.range) |range| bun.default_allocator.free(range);
        var sign_result = try credentials.signRequest(.{
            .path = options.path,
            .method = options.method,
            .search_params = options.search_params,
            .content_disposition = options.content_disposition,
            .content_encoding = options.content_encoding,
            .acl = options.acl,
            .storage_class = options.storage_class,
            .request_payer = options.request_payer,
        }, allow_empty_path, null);
        errdefer sign_result.deinit();

        var header_buffer: [S3Credentials.SignResult.MAX_HEADERS + 1]picohttp.Header = undefined;
        const header_entries = if (options.range) |range|
            sign_result.mixWithHeader(&header_buffer, .{ .name = "range", .value = range })
        else if (options.content_type) |content_type|
            if (content_type.len > 0)
                sign_result.mixWithHeader(&header_buffer, .{ .name = "Content-Type", .value = content_type })
            else
                sign_result.headers()
        else
            sign_result.headers();
        var headers = try bun.http.Headers.fromPicoHttpHeaders(header_entries, bun.default_allocator);
        errdefer headers.deinit();
        const proxy_url = try bun.default_allocator.dupe(u8, options.proxy_url orelse "");
        return .{
            .sign_result = sign_result,
            .headers = headers,
            .range = options.range,
            .proxy_url = proxy_url,
        };
    }

    pub fn deinit(this: *PreparedRequest) void {
        this.headers.deinit();
        this.sign_result.deinit();
        if (this.range) |range| bun.default_allocator.free(range);
        bun.default_allocator.free(this.proxy_url);
    }
};

pub fn executeSimpleS3Request(
    comptime Scheduler: type,
    this: *const S3Credentials,
    options: S3SimpleRequestOptions,
    callback: S3HttpSimpleTask(Scheduler).Callback,
    callback_context: CallbackContext,
) void {
    var request = (if (callback == .listObjects)
        PreparedRequest.create(this, options, true)
    else
        PreparedRequest.create(this, options, false)) catch |err| {
        callback.failSigning(err, callback_context);
        return;
    };
    const Task = S3HttpSimpleTask(Scheduler);
    const task = bun.default_allocator.create(Task) catch {
        request.deinit();
        callback.outOfMemory(callback_context);
        return;
    };
    task.* = .{
        .http = undefined,
        .request = request,
        .callback_context = callback_context,
        .callback = callback,
        .scheduler = Scheduler.initCurrent(),
    };
    task.scheduler.ref(&task.poll_ref);

    const url = bun.URL.parse(task.request.sign_result.url);
    task.http = bun.http.AsyncHTTP.init(
        bun.default_allocator,
        options.method,
        url,
        task.request.headers.entries,
        task.request.headers.buf.items,
        &task.response_buffer,
        options.body,
        bun.http.HTTPClientResult.Callback.New(
            *Task,
            Task.httpCallback,
        ).init(task),
        .follow,
        .{
            .javascript_semantics = task.scheduler.javascriptSemantics(),
            .response_buffer_allocation = .transferable,
            .http_proxy = if (task.request.proxy_url.len > 0) bun.URL.parse(task.request.proxy_url) else null,
            .verbose = task.scheduler.verboseFetch(),
            .reject_unauthorized = task.scheduler.rejectUnauthorized(),
        },
    );
    // queue http request
    task.scheduler.startHTTPThread();
    var batch = bun.BackgroundTaskGroup.Batch{};
    task.http.schedule(bun.default_allocator, &batch);
    bun.http.http_thread.schedule(batch);
}

const std = @import("std");
const ACL = @import("../../../s3_signing/acl.zig").ACL;
const StorageClass = @import("../../../s3_signing/storage_class.zig").StorageClass;

const S3Credentials = @import("../../../s3_signing/credentials.zig").S3Credentials;
const SignResult = @import("../../../s3_signing/credentials.zig").S3Credentials.SignResult;

const S3Error = @import("../../../s3_signing/error.zig").S3Error;
const getSignErrorCodeAndMessage = @import("../../../s3_signing/error.zig").getSignErrorCodeAndMessage;

const bun = @import("bun");
const picohttp = bun.picohttp;
const strings = bun.strings;
