pub const ACL = @import("../../../s3_signing/acl.zig").ACL;
pub const S3HttpDownloadStreamingTask = @import("./download_stream.zig").S3HttpDownloadStreamingTask(S3Scheduler);
pub const MultiPartUploadOptions = @import("../../../s3_signing/multipart_options.zig").MultiPartUploadOptions;
pub const MultiPartUpload = @import("./multipart.zig").MultiPartUpload(S3Scheduler);
pub const StorageClass = @import("../../../s3_signing/storage_class.zig").StorageClass;

pub const Error = @import("../../../s3_signing/error.zig");

pub const S3Credentials = Credentials.S3Credentials;
pub const S3CredentialsWithOptions = Credentials.S3CredentialsWithOptions;

pub const S3HttpSimpleTask = S3SimpleRequest.S3HttpSimpleTask(S3Scheduler);
pub const S3UploadResult = S3SimpleRequest.S3UploadResult;
pub const S3UploadStreamResult = union(enum) {
    success,
    out_of_memory,
    terminated,
    failure: struct {
        error_value: Error.S3Error,
        path: []const u8,
    },
    stream_error: *const bun.bindgen.Root,
};
pub const S3StatResult = S3SimpleRequest.S3StatResult;
pub const S3DownloadResult = S3SimpleRequest.S3DownloadResult;
pub const RequestFailure = S3SimpleRequest.RequestFailure;
pub const S3DeleteResult = S3SimpleRequest.S3DeleteResult;
pub const S3ListObjectsResult = S3SimpleRequest.S3ListObjectsResult;
pub const S3ListObjectsOptions = @import("./list_objects.zig").S3ListObjectsOptions;
pub const getListObjectsOptionsFromBinding = S3ListObjects.getListObjectsOptionsFromBinding;
pub const S3ListCompletions = S3ListObjects.S3ListCompletions;
pub const S3ListAcceptor = S3ListObjects.Acceptor;

pub const completions = @import("./completions.zig");
pub const S3VoidAcceptor = completions.VoidAcceptor;
pub const S3ExistsAcceptor = completions.ExistsAcceptor;
pub const S3SizeAcceptor = completions.SizeAcceptor;
pub const S3StatAcceptor = completions.StatAcceptor;
pub const S3VoidCompletions = completions.VoidCompletions;
pub const S3SizeCompletions = completions.SizeCompletions;
pub const S3StatCompletions = completions.StatCompletions;
pub const OwnedS3Stat = completions.OwnedS3Stat;

pub fn stat(
    this: *const S3Credentials,
    path: []const u8,
    callback: *const fn (S3StatResult, CallbackContext) void,
    callback_context: CallbackContext,
    proxy_url: ?[]const u8,
    request_payer: bool,
) void {
    S3SimpleRequest.executeSimpleS3Request(S3Scheduler, this, .{
        .path = path,
        .method = .HEAD,
        .proxy_url = proxy_url,
        .body = "",
        .request_payer = request_payer,
    }, .{ .stat = callback }, callback_context);
}

pub fn download(
    this: *const S3Credentials,
    path: []const u8,
    callback: *const fn (S3DownloadResult, CallbackContext) void,
    callback_context: CallbackContext,
    proxy_url: ?[]const u8,
    request_payer: bool,
) void {
    S3SimpleRequest.executeSimpleS3Request(S3Scheduler, this, .{
        .path = path,
        .method = .GET,
        .proxy_url = proxy_url,
        .body = "",
        .request_payer = request_payer,
    }, .{ .download = callback }, callback_context);
}

pub fn downloadSlice(
    this: *const S3Credentials,
    path: []const u8,
    offset: usize,
    size: ?usize,
    callback: *const fn (S3DownloadResult, CallbackContext) void,
    callback_context: CallbackContext,
    proxy_url: ?[]const u8,
    request_payer: bool,
) void {
    const range = createRange(offset, size) catch |err| {
        const completion: S3HttpSimpleTask.Callback = .{ .download = callback };
        completion.failSigning(err, callback_context);
        return;
    };

    S3SimpleRequest.executeSimpleS3Request(S3Scheduler, this, .{
        .path = path,
        .method = .GET,
        .proxy_url = proxy_url,
        .body = "",
        .range = range,
        .request_payer = request_payer,
    }, .{ .download = callback }, callback_context);
}

pub fn delete(
    this: *const S3Credentials,
    path: []const u8,
    callback: *const fn (S3DeleteResult, CallbackContext) void,
    callback_context: CallbackContext,
    proxy_url: ?[]const u8,
    request_payer: bool,
) void {
    S3SimpleRequest.executeSimpleS3Request(S3Scheduler, this, .{
        .path = path,
        .method = .DELETE,
        .proxy_url = proxy_url,
        .body = "",
        .request_payer = request_payer,
    }, .{ .delete = callback }, callback_context);
}

pub fn listObjects(
    this: *const S3Credentials,
    listOptions: S3ListObjectsOptions,
    callback: *const fn (S3ListObjectsResult, CallbackContext) void,
    callback_context: CallbackContext,
    proxy_url: ?[]const u8,
) void {
    var query: std.Io.Writer.Allocating = .init(bun.default_allocator);
    defer query.deinit();
    writeListQuery(&query.writer, listOptions) catch {
        callback(.out_of_memory, callback_context);
        return;
    };
    S3SimpleRequest.executeSimpleS3Request(S3Scheduler, this, .{
        .path = "",
        .method = .GET,
        .search_params = query.written(),
        .proxy_url = proxy_url,
        .body = "",
    }, .{ .listObjects = callback }, callback_context);
}

fn writeQueryKey(writer: *std.Io.Writer, first: *bool, key: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte(if (first.*) '?' else '&');
    try writer.writeAll(key);
    try writer.writeByte('=');
    first.* = false;
}

fn writeListQuery(writer: *std.Io.Writer, options: S3ListObjectsOptions) std.Io.Writer.Error!void {
    var first = true;
    if (options.continuation_token) |value| {
        try writeQueryKey(writer, &first, "continuation-token");
        try S3Credentials.writeURIComponent(value.slice(), writer, true);
    }
    if (options.delimiter) |value| {
        try writeQueryKey(writer, &first, "delimiter");
        try S3Credentials.writeURIComponent(value.slice(), writer, true);
    }
    if (options.url_encoding) {
        try writeQueryKey(writer, &first, "encoding-type");
        try writer.writeAll("url");
    }
    if (options.fetch_owner) |value| {
        try writeQueryKey(writer, &first, "fetch-owner");
        try writer.writeAll(if (value) "true" else "false");
    }
    try writeQueryKey(writer, &first, "list-type");
    try writer.writeByte('2');
    if (options.max_keys) |value| {
        try writeQueryKey(writer, &first, "max-keys");
        try writer.print("{d}", .{value});
    }
    if (options.prefix) |value| {
        try writeQueryKey(writer, &first, "prefix");
        try S3Credentials.writeURIComponent(value.slice(), writer, true);
    }
    if (options.start_after) |value| {
        try writeQueryKey(writer, &first, "start-after");
        try S3Credentials.writeURIComponent(value.slice(), writer, true);
    }
}

fn createRange(offset: usize, size: ?usize) !?[]const u8 {
    if (size) |length| {
        const end = std.math.add(usize, offset, length -| 1) catch return error.InvalidRange;
        return try std.fmt.allocPrint(bun.default_allocator, "bytes={}-{}", .{ offset, end });
    }
    if (offset == 0) return null;
    return try std.fmt.allocPrint(bun.default_allocator, "bytes={}-", .{offset});
}

pub fn upload(
    this: *const S3Credentials,
    path: []const u8,
    content: []const u8,
    content_type: ?[]const u8,
    content_disposition: ?[]const u8,
    content_encoding: ?[]const u8,
    acl: ?ACL,
    proxy_url: ?[]const u8,
    storage_class: ?StorageClass,
    request_payer: bool,
    callback: *const fn (S3UploadResult, CallbackContext) void,
    callback_context: CallbackContext,
) void {
    S3SimpleRequest.executeSimpleS3Request(S3Scheduler, this, .{
        .path = path,
        .method = .PUT,
        .proxy_url = proxy_url,
        .body = content,
        .content_type = content_type,
        .content_disposition = content_disposition,
        .content_encoding = content_encoding,
        .acl = acl,
        .storage_class = storage_class,
        .request_payer = request_payer,
    }, .{ .upload = callback }, callback_context);
}
/// download a file from s3 chunk by chunk aka streaming (used on readableStream)
pub fn downloadStream(
    this: *S3Credentials,
    path: []const u8,
    offset: usize,
    size: ?usize,
    proxy_url: ?[]const u8,
    request_payer: bool,
    callback: *const fn (chunk: bun.MutableString, has_more: bool, err: ?RequestFailure, CallbackContext) void,
    callback_context: CallbackContext,
) void {
    const range = createRange(offset, size) catch |err| {
        callback(.{ .allocator = bun.default_allocator, .list = .empty }, false, RequestFailure.fromError(err), callback_context);
        return;
    };

    var request = S3SimpleRequest.PreparedRequest.create(this, .{
        .path = path,
        .method = .GET,
        .request_payer = request_payer,
        .range = range,
        .proxy_url = proxy_url,
        .body = "",
    }, false) catch |err| {
        callback(.{ .allocator = bun.default_allocator, .list = .empty }, false, RequestFailure.fromError(err), callback_context);
        return;
    };
    const task = bun.default_allocator.create(S3HttpDownloadStreamingTask) catch {
        request.deinit();
        callback(.{ .allocator = bun.default_allocator, .list = .empty }, false, .out_of_memory, callback_context);
        return;
    };
    task.* = .{
        .http = undefined,
        .request = request,
        .callback_context = callback_context,
        .callback = callback,
        .scheduler = S3Scheduler.initCurrent(),
    };
    task.scheduler.ref(&task.poll_ref);

    const url = bun.URL.parse(task.request.sign_result.url);

    task.signals = task.signal_store.to();

    task.http = bun.http.AsyncHTTP.init(
        bun.default_allocator,
        .GET,
        url,
        task.request.headers.entries,
        task.request.headers.buf.items,
        &task.response_buffer,
        "",
        bun.http.HTTPClientResult.Callback.New(
            *S3HttpDownloadStreamingTask,
            S3HttpDownloadStreamingTask.httpCallback,
        ).init(task),
        .follow,
        .{
            .javascript_semantics = task.scheduler.javascriptSemantics(),
            .http_proxy = if (task.request.proxy_url.len > 0) bun.URL.parse(task.request.proxy_url) else null,
            .verbose = task.scheduler.verboseFetch(),
            .signals = task.signals,
            .reject_unauthorized = task.scheduler.rejectUnauthorized(),
        },
    );
    // enable streaming
    task.http.enableResponseBodyStreaming();
    // queue http request
    task.scheduler.startHTTPThread();
    var batch = bun.BackgroundTaskGroup.Batch{};
    task.http.schedule(bun.default_allocator, &batch);
    bun.http.http_thread.schedule(batch);
}

const Credentials = @import("../../../s3_signing/credentials.zig");
const S3ListObjects = @import("./list_objects.zig");
const S3SimpleRequest = @import("./simple_request.zig");
pub const CallbackContext = S3SimpleRequest.CallbackContext;
const std = @import("std");

const bun = @import("bun");
const S3Scheduler = @import("./S3SchedulerEngine.zig").S3Scheduler;
const picohttp = bun.picohttp;
