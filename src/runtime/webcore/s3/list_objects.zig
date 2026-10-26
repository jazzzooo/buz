pub const S3ListObjectsOptions = struct {
    continuation_token: ?bun.String.Slice = null,
    delimiter: ?bun.String.Slice = null,
    url_encoding: bool = false,
    fetch_owner: ?bool = null,
    max_keys: ?i64 = null,
    prefix: ?bun.String.Slice = null,
    start_after: ?bun.String.Slice = null,

    pub fn take(this: *@This()) @This() {
        const result = this.*;
        this.* = .{};
        return result;
    }

    pub fn deinit(this: *@This()) void {
        const owned = this.take();
        inline for (.{ "continuation_token", "delimiter", "prefix", "start_after" }) |field| {
            if (@field(owned, field)) |slice| slice.deinit();
        }
    }
};

const ObjectOwner = struct {
    id: ?[]const u8,
    display_name: ?[]const u8,
};

const ObjectRestoreStatus = struct {
    is_restore_in_progress: ?bool,
    restore_expiry_date: ?[]const u8,
};

const S3ListObjectsContents = struct {
    key: []const u8,
    etag: ?bun.ptr.OwnedIn([]const u8, bun.allocators.MaybeOwned(bun.DefaultAllocator)),
    checksum_type: ?[]const u8,
    checksum_algorithm: ?[]const u8,
    last_modified: ?[]const u8,
    object_size: ?i64,
    storage_class: ?[]const u8,
    owner: ?ObjectOwner,
    restore_status: ?ObjectRestoreStatus,

    pub fn deinit(self: *S3ListObjectsContents) void {
        if (self.etag) |*etag| etag.deinit();
    }
};

pub const S3ListObjectsV2Result = struct {
    name: ?[]const u8,
    prefix: ?[]const u8,
    key_count: ?i64,
    max_keys: ?i64,
    delimiter: ?[]const u8,
    encoding_type: ?[]const u8,
    is_truncated: ?bool,
    continuation_token: ?[]const u8,
    next_continuation_token: ?[]const u8,
    start_after: ?[]const u8,
    common_prefixes: ?std.array_list.Managed([]const u8),
    contents: ?std.array_list.Managed(S3ListObjectsContents),

    pub fn deinit(this: *const @This()) void {
        if (this.contents) |contents| {
            for (contents.items) |*item| item.deinit();
            contents.deinit();
        }
        if (this.common_prefixes) |common_prefixes| {
            common_prefixes.deinit();
        }
    }

    pub fn toBindingResult(this: *const @This(), comptime FunctionSchema: type) bun.OOM!bun.bindgen.Return(FunctionSchema) {
        const Result = bun.bindgen.Return(FunctionSchema);
        var result: Result = .{
            .key_count = if (this.key_count) |value| @floatFromInt(value) else null,
            .max_keys = if (this.max_keys) |value| @floatFromInt(value) else null,
            .is_truncated = this.is_truncated,
        };
        errdefer bun.bindgen.deinitReturn(FunctionSchema, &result);

        inline for (.{ "name", "prefix", "delimiter", "encoding_type", "continuation_token", "next_continuation_token", "start_after" }) |field| {
            @field(result, field) = try optionalString(@field(this, field));
        }

        if (this.common_prefixes) |prefixes| {
            const Sequence = @typeInfo(@FieldType(Result, "common_prefixes")).optional.child;
            var builder = try Sequence.Builder.init(prefixes.items.len);
            errdefer builder.deinit();
            for (prefixes.items) |prefix| {
                builder.appendOwned(.{ .prefix = try bun.bindgen.DOMString.fromUTF8(prefix) });
            }
            result.common_prefixes = builder.finish();
        }

        if (this.contents) |contents| {
            const Sequence = @typeInfo(@FieldType(Result, "contents")).optional.child;
            var builder = try Sequence.Builder.init(contents.items.len);
            errdefer builder.deinit();
            for (contents.items) |item| {
                var value: Sequence.Element = .{
                    .key = try bun.bindgen.DOMString.fromUTF8(item.key),
                    .size = if (item.object_size) |size| @floatFromInt(size) else null,
                };
                errdefer Sequence.deinitElement(&value);
                value.etag = try optionalString(if (item.etag) |etag| etag.get() else null);
                inline for (.{ "checksum_algorithm", "checksum_type", "last_modified", "storage_class" }) |field| {
                    @field(value, field) = try optionalString(@field(item, field));
                }
                if (item.owner) |owner| {
                    value.owner = .{};
                    value.owner.?.id = try optionalString(owner.id);
                    value.owner.?.display_name = try optionalString(owner.display_name);
                }
                if (item.restore_status) |restore_status| {
                    value.restore_status = .{
                        .is_restore_in_progress = restore_status.is_restore_in_progress,
                    };
                    value.restore_status.?.restore_expiry_date = try optionalString(restore_status.restore_expiry_date);
                }
                builder.appendOwned(value);
            }
            result.contents = builder.finish();
        }

        return result;
    }
};

const optionalString = bun.bindgen.DOMString.fromOptionalUTF8;

const CompletionPayload = struct {
    success: bun.MutableString,

    pub fn deinit(this: *CompletionPayload) void {
        this.success.deinit();
    }
};

const CompletionOps = struct {
    pub fn materialize(
        comptime FunctionSchema: type,
        context: bun.bindgen.MaterializationContext(FunctionSchema),
        payload: *CompletionPayload,
    ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
        _ = context;
        var result = try parseS3ListObjectsResult(payload.success.slice());
        defer result.deinit();
        return try result.toBindingResult(FunctionSchema);
    }

    pub fn destroyPayload(payload: *CompletionPayload) void {
        payload.deinit();
        bun.destroy(payload);
    }

};

const S3ClientClassSchema = bun.bindgen.Module("S3Client").class("S3Client");

pub const S3ListCompletions = bun.bindgen.MaterializedCompletionSet(.{
    S3ClientClassSchema.memberKind("list", .method),
    S3ClientClassSchema.memberKind("list", .static_method),
}, CompletionPayload, CompletionOps);

pub const Acceptor = @import("./completions.zig").ResultAcceptor(CompletionPayload, S3ListCompletions);

pub fn parseS3ListObjectsResult(xml: []const u8) bun.OOM!S3ListObjectsV2Result {
    var result: S3ListObjectsV2Result = .{
        .contents = null,
        .common_prefixes = null,
        .continuation_token = null,
        .delimiter = null,
        .encoding_type = null,
        .is_truncated = null,
        .key_count = null,
        .max_keys = null,
        .name = null,
        .next_continuation_token = null,
        .prefix = null,
        .start_after = null,
    };

    var contents = std.array_list.Managed(S3ListObjectsContents).init(bun.default_allocator);
    var common_prefixes = std.array_list.Managed([]const u8).init(bun.default_allocator);

    // we dont use trailing ">" as it may finish with xmlns=...
    if (strings.indexOf(xml, "<ListBucketResult")) |delete_result_pos| {
        var i: usize = 0;
        while (i < xml[delete_result_pos..].len) {
            if (xml[i] != '<') {
                i += 1;
                continue;
            }

            if (strings.indexOf(xml[i + 1 ..], ">")) |end| {
                i = i + 1;
                const tag_name_end_pos = i + end; // +1 for <

                const tagName = xml[i..tag_name_end_pos];
                i = tag_name_end_pos + 1; // +1 for >

                if (strings.eql(tagName, "Contents")) {
                    var looking_for_end_tag = true;

                    var object_key: ?[]const u8 = null;
                    var last_modified: ?[]const u8 = null;
                    var object_size: ?i64 = null;
                    var storage_class: ?[]const u8 = null;
                    var etag: ?[]const u8 = null;
                    var etag_owned: bool = false;
                    var checksum_type: ?[]const u8 = null;
                    var checksum_algorithm: ?[]const u8 = null;
                    var owner_id: ?[]const u8 = null;
                    var owner_display_name: ?[]const u8 = null;
                    var is_restore_in_progress: ?bool = null;
                    var restore_expiry_date: ?[]const u8 = null;

                    while (looking_for_end_tag) {
                        if (i >= xml.len) {
                            break;
                        }

                        if (xml[i] == '<') {
                            if (strings.indexOf(xml[i + 1 ..], ">")) |__end| {
                                const inner_tag_name_or_tag_end = xml[i + 1 .. i + 1 + __end];

                                i = i + 2 + __end;

                                if (strings.eql(inner_tag_name_or_tag_end, "/Contents")) {
                                    looking_for_end_tag = false;
                                } else if (strings.eql(inner_tag_name_or_tag_end, "Key")) {
                                    if (strings.indexOf(xml[i..], "</Key>")) |__tag_end| {
                                        object_key = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 6;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "LastModified")) {
                                    if (strings.indexOf(xml[i..], "</LastModified>")) |__tag_end| {
                                        last_modified = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 15;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "Size")) {
                                    if (strings.indexOf(xml[i..], "</Size>")) |__tag_end| {
                                        const size = xml[i .. i + __tag_end];

                                        object_size = std.fmt.parseInt(i64, size, 10) catch null;
                                        i = i + __tag_end + 7;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "StorageClass")) {
                                    if (strings.indexOf(xml[i..], "</StorageClass>")) |__tag_end| {
                                        storage_class = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 15;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "ChecksumType")) {
                                    if (strings.indexOf(xml[i..], "</ChecksumType>")) |__tag_end| {
                                        checksum_type = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 15;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "ChecksumAlgorithm")) {
                                    if (strings.indexOf(xml[i..], "</ChecksumAlgorithm>")) |__tag_end| {
                                        checksum_algorithm = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 20;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "ETag")) {
                                    if (strings.indexOf(xml[i..], "</ETag>")) |__tag_end| {
                                        const input = xml[i .. i + __tag_end];

                                        const size = std.mem.replacementSize(u8, input, "&quot;", "\"");
                                        var output = try bun.default_allocator.alloc(u8, size);

                                        const len = std.mem.replace(u8, input, "&quot;", "\"", output);

                                        if (len != 0) {
                                            etag = output[0 .. input.len - len * 5]; // 5 = "&quot;".len - 1 for replacement "
                                            etag_owned = true;
                                        } else {
                                            bun.default_allocator.free(output);
                                            etag = input;
                                        }

                                        i = i + __tag_end + 7;
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "Owner")) {
                                    if (strings.indexOf(xml[i..], "</Owner>")) |__tag_end| {
                                        const owner = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 8;

                                        if (strings.indexOf(owner, "<ID>")) |id_start| {
                                            const id_start_pos = id_start + 4;
                                            if (strings.indexOf(owner, "</ID>")) |id_end| {
                                                const isNotEmpty = id_start_pos < id_end;
                                                if (isNotEmpty) {
                                                    owner_id = owner[id_start_pos..id_end];
                                                }
                                            }
                                        }

                                        if (strings.indexOf(owner, "<DisplayName>")) |id_start| {
                                            const id_start_pos = id_start + 13;
                                            if (strings.indexOf(owner, "</DisplayName>")) |id_end| {
                                                const isNotEmpty = id_start_pos < id_end;
                                                if (isNotEmpty) {
                                                    owner_display_name = owner[id_start_pos..id_end];
                                                }
                                            }
                                        }
                                    }
                                } else if (strings.eql(inner_tag_name_or_tag_end, "RestoreStatus")) {
                                    if (strings.indexOf(xml[i..], "</RestoreStatus>")) |__tag_end| {
                                        const restore_status = xml[i .. i + __tag_end];
                                        i = i + __tag_end + 16;

                                        if (strings.indexOf(restore_status, "<IsRestoreInProgress>")) |start| {
                                            const start_pos = start + 21;
                                            if (strings.indexOf(restore_status, "</IsRestoreInProgress>")) |_end| {
                                                const isNotEmpty = start_pos < _end;
                                                if (isNotEmpty) {
                                                    const is_restore_in_progress_string = restore_status[start_pos.._end];

                                                    if (strings.eql(is_restore_in_progress_string, "true")) {
                                                        is_restore_in_progress = true;
                                                    } else if (strings.eql(is_restore_in_progress_string, "false")) {
                                                        is_restore_in_progress = false;
                                                    }
                                                }
                                            }
                                        }

                                        if (strings.indexOf(restore_status, "<RestoreExpiryDate>")) |start| {
                                            const start_pos = start + 19;
                                            if (strings.indexOf(restore_status, "</RestoreExpiryDate>")) |_end| {
                                                const isNotEmpty = start_pos < _end;
                                                if (isNotEmpty) {
                                                    restore_expiry_date = restore_status[start_pos.._end];
                                                }
                                            }
                                        }
                                    }
                                }
                            } else { // char is not >
                                i += 1;
                            }
                        } else { // char is not <
                            i += 1;
                        }
                    }

                    if (object_key) |object_key_val| {
                        var owner: ?ObjectOwner = null;

                        if (owner_id != null or owner_display_name != null) {
                            owner = .{
                                .id = owner_id,
                                .display_name = owner_display_name,
                            };
                        }

                        var restore_status: ?ObjectRestoreStatus = null;

                        if (is_restore_in_progress != null or restore_expiry_date != null) {
                            restore_status = .{
                                .is_restore_in_progress = is_restore_in_progress,
                                .restore_expiry_date = restore_expiry_date,
                            };
                        }

                        try contents.append(.{
                            .key = object_key_val,
                            .etag = if (etag) |etag_| if (etag_owned) .fromRawIn(etag_, .init()) else .fromRawIn(etag_, .initBorrowed()) else null,
                            .checksum_type = checksum_type,
                            .checksum_algorithm = checksum_algorithm,
                            .last_modified = last_modified,
                            .object_size = object_size,
                            .storage_class = storage_class,
                            .owner = owner,
                            .restore_status = restore_status,
                        });
                    }
                } else if (strings.eql(tagName, "Name")) {
                    if (strings.indexOf(xml[i..], "</Name>")) |_end| {
                        result.name = xml[i .. i + _end];
                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "Delimiter")) {
                    if (strings.indexOf(xml[i..], "</Delimiter>")) |_end| {
                        result.delimiter = xml[i .. i + _end];
                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "NextContinuationToken")) {
                    if (strings.indexOf(xml[i..], "</NextContinuationToken>")) |_end| {
                        result.next_continuation_token = xml[i .. i + _end];
                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "ContinuationToken")) {
                    if (strings.indexOf(xml[i..], "</ContinuationToken>")) |_end| {
                        result.continuation_token = xml[i .. i + _end];
                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "StartAfter")) {
                    if (strings.indexOf(xml[i..], "</StartAfter>")) |_end| {
                        result.start_after = xml[i .. i + _end];
                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "EncodingType")) {
                    if (strings.indexOf(xml[i..], "</EncodingType>")) |_end| {
                        result.encoding_type = xml[i .. i + _end];
                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "KeyCount")) {
                    if (strings.indexOf(xml[i..], "</KeyCount>")) |_end| {
                        const key_count = xml[i .. i + _end];
                        result.key_count = std.fmt.parseInt(i64, key_count, 10) catch null;

                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "MaxKeys")) {
                    if (strings.indexOf(xml[i..], "</MaxKeys>")) |_end| {
                        const max_keys = xml[i .. i + _end];
                        result.max_keys = std.fmt.parseInt(i64, max_keys, 10) catch null;

                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "Prefix")) {
                    if (strings.indexOf(xml[i..], "</Prefix>")) |_end| {
                        const prefix = xml[i .. i + _end];

                        if (prefix.len != 0) {
                            result.prefix = prefix;
                        }

                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "IsTruncated")) {
                    if (strings.indexOf(xml[i..], "</IsTruncated>")) |_end| {
                        const is_truncated = xml[i .. i + _end];

                        if (strings.eql(is_truncated, "true")) {
                            result.is_truncated = true;
                        } else if (strings.eql(is_truncated, "false")) {
                            result.is_truncated = false;
                        }

                        i = i + _end;
                    }
                } else if (strings.eql(tagName, "CommonPrefixes")) {
                    if (strings.indexOf(xml[i..], "</CommonPrefixes>")) |_end| {
                        const common_prefixes_string = xml[i .. i + _end];
                        i = i + _end;

                        var j: usize = 0;
                        while (j < common_prefixes_string.len) {
                            if (strings.indexOf(common_prefixes_string[j..], "<Prefix>")) |start| {
                                j = j + start + 8;

                                if (strings.indexOf(common_prefixes_string[j..], "</Prefix>")) |__end| {
                                    try common_prefixes.append(common_prefixes_string[j .. j + __end]);
                                    j = j + __end;
                                }
                            } else {
                                break;
                            }
                        }
                    }
                }
            } else {
                i += 1;
            }
        }

        if (contents.items.len != 0) {
            result.contents = contents;
        } else {
            for (contents.items) |*item| item.deinit();
            contents.deinit();
        }

        if (common_prefixes.items.len != 0) {
            result.common_prefixes = common_prefixes;
        } else {
            common_prefixes.deinit();
        }
    }

    return result;
}

pub fn getListObjectsOptionsFromBinding(context: anytype, input: anytype) bun.bindgen.CallError(@TypeOf(context))!S3ListObjectsOptions {
    var result: S3ListObjectsOptions = .{};
    errdefer result.deinit();
    if (input) |value| switch (value) {
        .options => |options| try applyListOptions(&result, &options),
        .nulled, .undefined => {},
        .invalid => return context.fail(.invalid_list_options, {}),
    };
    return result;
}

fn applyListOptions(result: *S3ListObjectsOptions, options: anytype) bun.OOM!void {
    result.continuation_token = try listString(&options.continuation_token);
    result.delimiter = try listString(&options.delimiter);
    if (options.encoding_type) |value| result.url_encoding = switch (value) {
        .string => |string| string.length() != 0,
        .ignored => false,
    };
    result.fetch_owner = options.fetch_owner;
    if (options.max_keys) |*value| switch (value.*) {
        .number => |number| result.max_keys = coerceDoubleToInt32(number),
        .ignored => {},
    };
    result.prefix = try listString(&options.prefix);
    result.start_after = try listString(&options.start_after);
}

fn listString(input: anytype) bun.OOM!?bun.String.Slice {
    if (input.*) |*value| switch (value.*) {
        .string => |*string| {
            if (string.length() != 0) return try string.toUTF8(bun.default_allocator);
        },
        .ignored => {},
    };
    return null;
}

fn coerceDoubleToInt32(value: f64) i32 {
    if (std.math.isNan(value)) return 0;
    if (value <= std.math.minInt(i32) or std.math.isNegativeInf(value)) return std.math.minInt(i32);
    if (value >= std.math.maxInt(i32) or std.math.isPositiveInf(value)) return std.math.maxInt(i32);
    return @intFromFloat(value);
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
