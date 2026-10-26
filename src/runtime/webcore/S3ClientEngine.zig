pub const inspect = bun.jsc.ConsoleObject.formatClassRefForBinding;

pub fn writeFormat(client: *S3Client, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    try writer.writeAll(comptime bun.Output.prettyFmt("<r>S3Client<r>", enable_ansi_colors));
    const credentials = client.credentials.get();
    const bucket_name = if (credentials.virtual_hosted_style and credentials.endpoint.len > 0) S3Credentials.guessBucket(credentials.endpoint) orelse credentials.bucket else credentials.bucket;
    if (bucket_name.len > 0) {
        try writer.print(comptime bun.Output.prettyFmt(" (<green>\"{s}\"<r>)<r> {{", enable_ansi_colors), .{bucket_name});
    } else {
        try writer.writeAll(" {");
    }

    try writeFormatCredentials(credentials, client.options, client.acl, Formatter, formatter, writer, enable_ansi_colors);
    try formatter.writeIndent(@TypeOf(writer), writer);
    try writer.writeAll("}");
    formatter.resetLine();
}

pub fn writeFormatCredentials(credentials: *S3Credentials, options: bun.S3.MultiPartUploadOptions, acl: ?bun.S3.ACL, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    try writer.writeAll("\n");
    const Writer = @TypeOf(writer);
    formatter.indent += 1;
    defer formatter.indent -|= 1;

    const endpoint = if (credentials.endpoint.len > 0) credentials.endpoint else (if (credentials.virtual_hosted_style) "https://<bucket>.s3.<region>.amazonaws.com" else "https://s3.<region>.amazonaws.com");
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll(comptime bun.Output.prettyFmt("<r>endpoint<d>:<r> \"", enable_ansi_colors));
    try writer.print(comptime bun.Output.prettyFmt("<r><b>{s}<r>\"", enable_ansi_colors), .{endpoint});
    try formatter.printComma(Writer, writer, enable_ansi_colors);
    try writer.writeAll("\n");

    const region = if (credentials.region.len > 0) credentials.region else S3Credentials.guessRegion(credentials.endpoint);
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll(comptime bun.Output.prettyFmt("<r>region<d>:<r> \"", enable_ansi_colors));
    try writer.print(comptime bun.Output.prettyFmt("<r><b>{s}<r>\"", enable_ansi_colors), .{region});
    try formatter.printComma(Writer, writer, enable_ansi_colors);
    try writer.writeAll("\n");

    if (credentials.accessKeyId.len > 0) {
        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>accessKeyId<d>:<r> \"<r><b>[REDACTED]<r>\"", enable_ansi_colors));
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
    }
    if (credentials.secretAccessKey.len > 0) {
        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>secretAccessKey<d>:<r> \"<r><b>[REDACTED]<r>\"", enable_ansi_colors));
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
    }
    if (credentials.sessionToken.len > 0) {
        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>sessionToken<d>:<r> \"<r><b>[REDACTED]<r>\"", enable_ansi_colors));
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
    }
    if (acl) |acl_value| {
        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>acl<d>:<r> \"", enable_ansi_colors));
        try writer.print(comptime bun.Output.prettyFmt("<r><b>{s}<r>\"", enable_ansi_colors), .{acl_value.toString()});
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
    }

    inline for (.{ .{ "partSize", options.partSize }, .{ "queueSize", options.queueSize }, .{ "retry", options.retry } }, 0..) |field, index| {
        try formatter.writeIndent(Writer, writer);
        try writer.print(comptime bun.Output.prettyFmt("<r>{s}<d>:<r> ", enable_ansi_colors), .{field[0]});
        try formatter.printNumber(writer, @floatFromInt(field[1]), enable_ansi_colors);
        if (index < 2) try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
    }
}

pub const Scope = enum { instance, static };
pub const Action = enum { file, presign, exists, size, stat, delete, list, write };

const Target = struct {
    blob: Blob,
    options: bun.S3.S3CredentialsWithOptions,

    fn deinit(this: *Target) void {
        this.options.deinit();
        this.blob.deinit();
    }

    fn fromPath(client: ?*const S3Client, global: *jsc.JSGlobalObject, path: *PathLike, context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!Target {
        const defaults: bun.S3.S3CredentialsWithOptions = if (client) |value| .{
            .credentials = value.credentials.get().*,
            .options = value.options,
            .acl = value.acl,
            .storage_class = value.storage_class,
            .request_payer = value.request_payer,
        } else .{ .credentials = global.bunVM().transpiler.env.getS3Credentials() };
        var resolved = try Credentials.resolveOptions(context, defaults, options, global);
        errdefer resolved.deinit();
        const blob = try S3File.constructS3FileWithResolvedOptions(global, path, &resolved, if (client) |value| value.credentials.get() else null);
        // Body conversion may invoke JavaScript and mutate environment defaults.
        resolved.credentials = blob.storePtr().?.data.s3.getCredentials().*;
        return .{ .blob = blob, .options = resolved };
    }

    fn fromBlob(comptime action: Action, global: *jsc.JSGlobalObject, blob: *Blob, context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!Target {
        const s3 = &blob.storePtr().?.data.s3;
        const defaults: bun.S3.S3CredentialsWithOptions = .{
            .credentials = s3.getCredentials().*,
            .options = s3.options,
            .acl = s3.acl,
            .storage_class = s3.storage_class,
            .request_payer = s3.request_payer,
        };
        var resolved = switch (action) {
            .exists, .size, .stat => CredentialsOptions.initialize(defaults, global.bunVM().io),
            else => try Credentials.resolveOptions(context, defaults, options, global),
        };
        errdefer resolved.deinit();
        return .{ .blob = try blob.dupe(), .options = resolved };
    }

    fn request(this: *Target, global: *jsc.JSGlobalObject) Operations.Request {
        return .{
            .store = this.blob.storePtr().?,
            .credentials = &this.options.credentials,
            .proxy = if (global.bunVM().transpiler.env.getHttpProxy(true, null, null)) |proxy| proxy.href else null,
            .request_payer = this.options.request_payer,
        };
    }
};

fn resolveTarget(comptime scope: Scope, comptime action: Action, client: ?*const S3Client, global: *jsc.JSGlobalObject, context: anytype, args: anytype) bindgen.CallError(@TypeOf(context))!Target {
    if (comptime action == .list) {
        var path: PathLike = .{ .string = bun.PathString.empty };
        defer path.deinit();
        return Target.fromPath(client, global, &path, context, args.options);
    }
    if (comptime scope == .instance or action == .file) {
        var path = try PathLike.fromBindingView(args.path.?);
        defer path.deinit();
        return Target.fromPath(client, global, &path, context, args.options);
    }
    var target = try PathOrBlobEngine.fromBindgen(args.path.?);
    defer target.deinit();
    switch (target) {
        .path => |*path| {
            if (path.* == .fd) return context.fail(.invalid_path, {});
            return Target.fromPath(null, global, &path.path, context, args.options);
        },
        .blob => |handle| {
            const blob = handle.get();
            if (!blob.isS3()) return context.fail(.invalid_path, {});
            return Target.fromBlob(action, global, blob, context, args.options);
        },
    }
}

fn Acceptor(comptime action: Action) type {
    return switch (action) {
        .file, .presign => void,
        .exists => bun.S3.S3ExistsAcceptor,
        .size => bun.S3.S3SizeAcceptor,
        .stat => bun.S3.S3StatAcceptor,
        .delete => bun.S3.S3VoidAcceptor,
        .list => bun.S3.S3ListAcceptor,
        .write => Blob.write_file.WriteAcceptor,
    };
}

pub fn call(comptime scope: Scope, comptime action: Action, client: ?*const S3Client, context: anytype, args: anytype) bindgen.CallError(@TypeOf(context))!(if (action == .file or action == .presign) bindgen.Return(@TypeOf(context)) else void) {
    const global = context.viewToken().globalObject();
    var acceptor: Acceptor(action) = switch (action) {
        .file, .presign => {},
        .write => blk: {
            var view = context.completion();
            break :blk Blob.write_file.WriteAcceptor.fromCompletion(Blob.write_file.WriteCompletions.takeForContext(context, &view)) orelse return;
        },
        else => Acceptor(action).takeForContext(context),
    };
    defer switch (action) {
        .file, .presign => {},
        .write => acceptor.deinit(),
        else => acceptor.release(),
    };

    if (comptime action != .list) {
        if (args.path == null) return context.fail(if (scope == .static and action == .file) .invalid_path else .missing_path, {});
    }
    const settings = if (comptime action == .presign) try presignSettings(context, args.options) else {};
    var list_options = if (comptime action == .list) try bun.S3.getListObjectsOptionsFromBinding(context, args.objectKeys) else {};
    defer if (comptime action == .list) list_options.deinit();
    var target = try resolveTarget(scope, action, client, global, context, args);
    defer target.deinit();
    switch (action) {
        .file => return (try Blob.new(&target.blob)).toBindingRef(context),
        .presign => return presign(context, &target, settings),
        .exists => try Operations.stat(.exists, target.request(global), &acceptor),
        .size => try Operations.stat(.size, target.request(global), &acceptor),
        .stat => try Operations.stat(.stat, target.request(global), &acceptor),
        .delete => try Operations.delete(target.request(global), &acceptor),
        .list => try Operations.list(target.request(global), &list_options, &acceptor),
        .write => {
            var destination: bun.api.node.PathOrBlob = .{ .blob = .init(&target.blob) };
            try Blob.writeFileWithBindingData(global, &destination, args.data, .{
                .mkdirp_if_not_exists = false,
                .resolved_s3_options = &target.options,
            }, &acceptor);
            acceptor.assertConsumed();
        },
    }
}

const PresignSettings = struct {
    method: bun.http.Method = .GET,
    expires: usize = 86400,
};

fn presignSettings(context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!PresignSettings {
    var result: PresignSettings = .{};
    if (options) |input| switch (input) {
        .nulled, .undefined => {},
        .invalid => return context.fail(.invalid_options, {}),
        .options => |resolved| {
            if (resolved.method) |value| result.method = switch (value) {
                .GET => .GET,
                .PUT => .PUT,
                .DELETE_METHOD => .DELETE,
                .HEAD => .HEAD,
                else => return context.fail(.s3_invalid_method, {}),
            };
            if (resolved.expires_in) |value| {
                if (value <= 0) return context.fail(.invalid_expires_in, {});
                result.expires = @intCast(value);
            }
        },
    };
    return result;
}

fn presign(context: anytype, target: *Target, settings: PresignSettings) bindgen.CallError(@TypeOf(context))!bindgen.DOMString {
    const result = Operations.presign(target.blob.storePtr().?.data.s3.path(), &target.options, settings.method, settings.expires) catch |err| return signingFailure(context, err);
    defer result.deinit();
    return bindgen.DOMString.fromUTF8(result.url);
}

pub fn presignFile(blob: *Blob, context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!bindgen.DOMString {
    if (!blob.isS3()) return context.fail(.invalid_s3_this, {});
    const settings = try presignSettings(context, options);
    const global = context.viewToken().globalObject();
    var target = try Target.fromBlob(.presign, global, blob, context, options);
    defer target.deinit();
    return presign(context, &target, settings);
}

pub fn construct(context: anytype, args: anytype) bindgen.CallError(@TypeOf(context))!*S3Client {
    const global = context.viewToken().globalObject();
    var options = try Credentials.resolveOptions(context, .{ .credentials = global.bunVM().transpiler.env.getS3Credentials() }, args.options, global);
    defer options.deinit();
    return S3Client.create(&options);
}

pub fn default(context: anytype) bun.JSError!bindgen.ClassRef(ClassSchema) {
    const vm = context.viewToken().globalObject().bunVM();
    bun.analytics.Features.s3 += 1;
    var credentials = vm.transpiler.env.getS3Credentials();
    credentials.io = vm.io;
    const client = try S3Client.create(&.{ .credentials = credentials });
    return client.toBindingRef(context);
}

fn signingFailure(context: anytype, err: anyerror) bindgen.CallError(@TypeOf(context)) {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingCredentials => context.fail(.s3_missing_credentials, {}),
        error.InvalidMethod => context.fail(.s3_invalid_method, {}),
        error.InvalidPath => context.fail(.s3_invalid_path, {}),
        error.InvalidEndpoint => context.fail(.s3_invalid_endpoint, {}),
        error.InvalidSessionToken => context.fail(.s3_invalid_session_token, {}),
        else => context.fail(.s3_invalid_signature, {}),
    };
}

const bun = @import("bun");
const S3Client = @import("./S3Client.zig").S3Client;
const S3Credentials = bun.S3.S3Credentials;
const jsc = bun.jsc;
const bindgen = bun.bindgen;
const ClassSchema = bindgen.Module("S3Client").class("S3Client");
const Blob = bun.webcore.Blob;
const PathLike = bun.api.node.PathLike;
const PathOrBlobEngine = @import("../node/PathOrBlobEngine.zig");
const Credentials = @import("./s3/CredentialsEngine.zig");
const S3File = @import("./S3FileEngine.zig");
const Operations = @import("./s3/Operations.zig");
const std = @import("std");
const CredentialsOptions = @import("./s3/CredentialsOptions.zig");
