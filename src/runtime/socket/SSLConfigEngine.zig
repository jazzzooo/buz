pub const GeneratedField = enum {
    dh_params_file,
    key_file,
    cert_file,
    ca_file,
    ca,
    cert,
    key,

    fn jsName(field: GeneratedField) []const u8 {
        return switch (field) {
            .dh_params_file => "dhParamsFile",
            .key_file => "keyFile",
            .cert_file => "certFile",
            .ca_file => "caFile",
            .ca => "ca",
            .cert => "cert",
            .key => "key",
        };
    }
};

pub const ParseFailure = union(enum) {
    inaccessible_path: GeneratedField,
    empty_file: GeneratedField,
    invalid_blob: GeneratedField,
    system: bun.sys.Error,

    pub fn message(failure: ParseFailure, buffer: []u8) []const u8 {
        return switch (failure) {
            .inaccessible_path => |field| std.fmt.bufPrint(
                buffer,
                "Unable to access {s} path",
                .{field.jsName()},
            ) catch unreachable,
            .empty_file => |field| std.fmt.bufPrint(
                buffer,
                "TLSOptions.{s} is an empty file",
                .{field.jsName()},
            ) catch unreachable,
            .invalid_blob => |field| std.fmt.bufPrint(
                buffer,
                "TLSOptions.{s} is not a valid BunFile (non-BunFile `Blob`s are not supported)",
                .{field.jsName()},
            ) catch unreachable,
            .system => unreachable,
        };
    }
};

pub const ParseResult = union(enum) {
    value: ?SSLConfig,
    failure: ParseFailure,
};

pub fn parse(context: anytype, generated: anytype) bun.bindgen.CallError(@TypeOf(context))!?SSLConfig {
    const reject_unauthorized = bun.current_runtime.tlsRejectUnauthorized();
    return switch (try parseResult(reject_unauthorized, generated)) {
        .value => |value| value,
        .failure => |failure| switch (failure) {
            .system => |system_error| context.fail(
                .tls_system,
                try bun.bindgen.SystemError.fromSysError(system_error),
            ),
            else => {
                var message_buffer: [128]u8 = undefined;
                return context.fail(
                    .tls_invalid_options,
                    try bun.bindgen.ThreadSafeDOMString.fromUTF8(failure.message(&message_buffer)),
                );
            },
        },
    };
}

pub fn parseResult(default_reject_unauthorized: bool, generated: anytype) bun.OOM!ParseResult {
    var result: SSLConfig = SSLConfig.zero;
    var committed = false;
    defer if (!committed) result.deinit();
    var any = false;

    if (generated.passphrase) |*passphrase| {
        result.passphrase = try passphrase.toOwnedSliceZ(bun.default_allocator);
        any = true;
    }
    if (generated.dh_params_file) |*dh_params_file| {
        switch (try handlePath(.dh_params_file, dh_params_file)) {
            .value => |value| result.dh_params_file_name = value,
            .failure => |failure| return .{ .failure = failure },
        }
        any = true;
    }
    if (generated.server_name) |*server_name| {
        result.server_name = try server_name.toOwnedSliceZ(bun.default_allocator);
        result.requires_custom_request_ctx = true;
    }

    result.low_memory_mode = generated.low_memory_mode;
    result.reject_unauthorized = @intFromBool(
        generated.reject_unauthorized orelse default_reject_unauthorized,
    );
    result.request_cert = @intFromBool(generated.request_cert);
    result.secure_options = generated.secure_options;
    any = any or
        result.low_memory_mode or
        generated.reject_unauthorized != null or
        generated.request_cert or
        result.secure_options != 0;

    switch (try handleFile(.ca, &generated.ca)) {
        .value => |value| result.ca = value,
        .failure => |failure| return .{ .failure = failure },
    }
    switch (try handleFile(.cert, &generated.cert)) {
        .value => |value| result.cert = value,
        .failure => |failure| return .{ .failure = failure },
    }
    switch (try handleFile(.key, &generated.key)) {
        .value => |value| result.key = value,
        .failure => |failure| return .{ .failure = failure },
    }
    result.requires_custom_request_ctx = result.requires_custom_request_ctx or
        result.ca != null or
        result.cert != null or
        result.key != null;

    if (generated.key_file) |*key_file| {
        switch (try handlePath(.key_file, key_file)) {
            .value => |value| result.key_file_name = value,
            .failure => |failure| return .{ .failure = failure },
        }
        result.requires_custom_request_ctx = true;
    }
    if (generated.cert_file) |*cert_file| {
        switch (try handlePath(.cert_file, cert_file)) {
            .value => |value| result.cert_file_name = value,
            .failure => |failure| return .{ .failure = failure },
        }
        result.requires_custom_request_ctx = true;
    }
    if (generated.ca_file) |*ca_file| {
        switch (try handlePath(.ca_file, ca_file)) {
            .value => |value| result.ca_file_name = value,
            .failure => |failure| return .{ .failure = failure },
        }
        result.requires_custom_request_ctx = true;
    }

    const protocols = if (generated.alpn_protocols) |*alpn_protocols| switch (alpn_protocols.*) {
        .string => |*val| try val.toOwnedSlice(bun.default_allocator),
        .buffer => |*val| try bun.default_allocator.dupe(u8, val.unsafePtr("the copied ALPN value remains owned by the call frame or converted argument until dupe finishes")),
    } else null;
    if (protocols) |some_protocols| {
        result.protos = some_protocols;
        result.requires_custom_request_ctx = true;
    }
    if (generated.ciphers) |*ciphers| {
        result.ssl_ciphers = try ciphers.toOwnedSliceZ(bun.default_allocator);
        result.is_using_default_ciphers = false;
        result.requires_custom_request_ctx = true;
    }

    result.client_renegotiation_limit = generated.client_renegotiation_limit;
    result.client_renegotiation_window = generated.client_renegotiation_window;
    any = any or
        result.requires_custom_request_ctx or
        result.client_renegotiation_limit != 0 or
        generated.client_renegotiation_window != 0;

    if (!any) return .{ .value = null };
    committed = true;
    return .{ .value = result };
}

fn MaterializationResult(comptime T: type) type {
    return union(enum) {
        value: T,
        failure: ParseFailure,
    };
}

fn handlePath(
    field: GeneratedField,
    string: anytype,
) bun.OOM!MaterializationResult([:0]const u8) {
    const name = try string.toOwnedSliceZ(bun.default_allocator);
    if (std.posix.system.access(name, std.posix.F_OK) != 0) {
        bun.freeSensitive(bun.default_allocator, name);
        return .{ .failure = .{ .inaccessible_path = field } };
    }
    return .{ .value = name };
}

fn handleFile(
    field: GeneratedField,
    file: anytype,
) bun.OOM!MaterializationResult(?SSLConfig.PEMList) {
    const value = if (file.*) |*value| value else return .{ .value = null };
    const materialized = try handleSingleFile(field, value);
    const single = switch (materialized) {
        .value => |single| single,
        .failure => |failure| return .{ .failure = failure },
    } orelse switch (value.*) {
        .array => |*list| return try handleFileArray(field, list),
        else => unreachable,
    };
    errdefer bun.freeSensitive(bun.default_allocator, single);
    var result = try SSLConfig.PEMList.initCapacity(1);
    result.appendAssumeCapacity(single);
    return .{ .value = result };
}

fn handleFileArray(
    field: GeneratedField,
    elements: anytype,
) bun.OOM!MaterializationResult(?SSLConfig.PEMList) {
    const length = elements.len();
    if (length == 0) return .{ .value = null };
    var result = try SSLConfig.PEMList.initCapacity(length);
    var committed = false;
    defer if (!committed) result.deinit();
    if (comptime @hasDecl(@TypeOf(elements.*), "at")) {
        for (0..length) |index| {
            var elem = elements.at(index).?;
            switch (try handleSingleFile(field, &elem)) {
                .value => |value| result.appendAssumeCapacity(value.?),
                .failure => |failure| return .{ .failure = failure },
            }
        }
    } else {
        while (elements.pop()) |converted| {
            var elem = converted;
            defer elem.deinit();
            const string = switch (try handleSingleFile(field, &elem.value)) {
                .value => |value| value.?,
                .failure => |failure| return .{ .failure = failure },
            };
            result.appendAssumeCapacity(string);
        }
        result.reverse();
    }
    bun.assert(result.entries.len == length);
    committed = true;
    return .{ .value = result };
}

fn handleSingleFile(
    field: GeneratedField,
    file: anytype,
) bun.OOM!MaterializationResult(?[:0]const u8) {
    if (comptime @hasField(@TypeOf(file.*), "array")) {
        return switch (file.*) {
            .string => |*string| .{ .value = try handleStringFile(string) },
            .buffer => |*buffer_ref| .{ .value = try handleBufferFile(buffer_ref) },
            .file => |*blob_ref| handleBlobFile(field, blob_ref),
            .array => .{ .value = null },
        };
    }
    return switch (file.*) {
        .string => |*string| .{ .value = try handleStringFile(string) },
        .buffer => |*buffer_ref| .{ .value = try handleBufferFile(buffer_ref) },
        .file => |*blob_ref| handleBlobFile(field, blob_ref),
    };
}

fn handleStringFile(string: anytype) bun.OOM![:0]const u8 {
    return string.toOwnedSliceZ(bun.default_allocator);
}

fn handleBufferFile(buffer_ref: anytype) bun.OOM![:0]const u8 {
    const bytes = buffer_ref.unsafePtr("the call frame or converted argument owns the copied TLS bytes until dupeSentinel finishes");
    return bun.default_allocator.dupeSentinel(u8, bytes, 0);
}

fn handleBlobFile(
    field: GeneratedField,
    blob_ref: anytype,
) MaterializationResult(?[:0]const u8) {
    return switch (readFromBlob(field, blob_ref.get())) {
        .value => |value| .{ .value = value },
        .failure => |failure| .{ .failure = failure },
    };
}

fn readFromBlob(
    field: GeneratedField,
    blob: *bun.webcore.Blob,
) MaterializationResult([:0]const u8) {
    const store = blob.storePtr() orelse return .{ .failure = .{ .invalid_blob = field } };
    const file = switch (store.data) {
        .file => |value| value,
        else => return .{ .failure = .{ .invalid_blob = field } },
    };
    var fs: bun.api.node.fs.NodeFS = .{};
    const maybe = fs.readFileWithOptions(
        .{ .path = file.pathlike },
        .sync,
        .null_terminated,
    );
    const result = switch (maybe) {
        .result => |value| value,
        .err => |err| return .{ .failure = .{ .system = err } },
    };
    // The null-terminated read transfers its default-allocator buffer to this parser.
    if (result.null_terminated.len == 0) {
        bun.freeSensitive(bun.default_allocator, result.null_terminated);
        return .{ .failure = .{ .empty_file = field } };
    }
    return .{ .value = result.null_terminated };
}

const SSLConfig = @import("./SSLConfig.zig");
const std = @import("std");
const bun = @import("bun");
