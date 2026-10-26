pub const FormData = struct {
    pub const Encoding = union(enum) {
        URLEncoded: void,
        Multipart: []const u8, // boundary

        pub fn get(content_type: []const u8) ?Encoding {
            if (strings.indexOf(content_type, "application/x-www-form-urlencoded") != null)
                return Encoding{ .URLEncoded = {} };

            if (strings.indexOf(content_type, "multipart/form-data") == null) return null;

            const boundary = getBoundary(content_type) orelse return null;
            return .{
                .Multipart = boundary,
            };
        }
    };

    pub const OwnedEncoding = struct {
        kind: enum { url_encoded, multipart },
        boundary: bun.bindgen.OwnedBytes = .empty(),

        pub fn init(encoding: Encoding) bun.OOM!OwnedEncoding {
            return switch (encoding) {
                .URLEncoded => .{ .kind = .url_encoded },
                .Multipart => |boundary| .{
                    .kind = .multipart,
                    .boundary = try bun.bindgen.OwnedBytes.fromSlice(boundary),
                },
            };
        }

        pub fn view(this: *const OwnedEncoding) Encoding {
            return switch (this.kind) {
                .url_encoded => .{ .URLEncoded = {} },
                .multipart => .{ .Multipart = this.boundary.slice() },
            };
        }

        pub fn take(this: *OwnedEncoding) OwnedEncoding {
            const kind = this.kind;
            this.kind = .url_encoded;
            return .{ .kind = kind, .boundary = this.boundary.take() };
        }

        pub fn deinit(this: *OwnedEncoding) void {
            this.boundary.deinit();
            this.* = .{ .kind = .url_encoded };
        }
    };

    pub fn getBoundary(content_type: []const u8) ?[]const u8 {
        const boundary_index = strings.indexOf(content_type, "boundary=") orelse return null;
        const boundary_start = @as(usize, boundary_index) + "boundary=".len;
        const begin = content_type[boundary_start..];
        if (begin.len == 0)
            return null;

        const boundary_end: usize = if (strings.indexOfChar(begin, ';')) |index| index else begin.len;
        if (begin[0] == '"') {
            if (boundary_end > 1 and begin[boundary_end - 1] == '"') {
                return begin[1 .. boundary_end - 1];
            }
            // Opening quote with no matching closing quote — malformed.
            return null;
        }

        return begin[0..boundary_end];
    }

    pub const Field = struct {
        value: []const u8 = "",
        filename: ?[]const u8 = null,
        content_type: []const u8 = "",
    };

    pub const MultipartParseError = error{
        @"boundary is too long",
        @"missing final boundary",
        @"is missing header end",
        @"is missing header line end",
        @"is missing header colon separator",
    };

    pub fn fileContentType(field: Field) []const u8 {
        if (field.content_type.len > 0) return field.content_type;
        if (field.filename) |filename| {
            const extension = std.fs.path.extension(filename);
            if (extension.len > 0) {
                if (bun.http.MimeType.byExtensionNoDefault(extension[1..])) |mime| return mime.value;
            }
        }
        if (bun.http.MimeType.sniff(field.value)) |mime| return mime.value;
        return "";
    }

    pub fn forEachMultipartEntry(
        input: []const u8,
        boundary: []const u8,
        comptime Ctx: type,
        ctx: Ctx,
        comptime iterator: anytype,
    ) (MultipartParseError || bun.JSError)!void {
        var slice = input;

        var buf: [76]u8 = undefined;
        {
            const final_boundary = std.fmt.bufPrint(&buf, "--{s}--", .{boundary}) catch
                return error.@"boundary is too long";
            const final_boundary_index = strings.lastIndexOf(input, final_boundary);
            if (final_boundary_index == null) {
                return error.@"missing final boundary";
            }
            slice = slice[0..final_boundary_index.?];
        }

        const separator = std.fmt.bufPrint(&buf, "--{s}\r\n", .{boundary}) catch
            return error.@"boundary is too long";
        var splitter = strings.split(slice, separator);
        _ = splitter.next(); // skip first boundary

        while (splitter.next()) |chunk| {
            var remain = chunk;
            const header_end = strings.indexOf(remain, "\r\n\r\n") orelse return error.@"is missing header end";
            const header = remain[0 .. header_end + 2];
            remain = remain[header_end + 4 ..];

            var field = Field{};
            var name: ?[]const u8 = null;
            var filename: ?[]const u8 = null;
            var header_chunk = header;
            // File parts infer their MIME type unless Content-Type precedes Content-Disposition.
            while (header_chunk.len > 0 and (filename == null or name == null or name.?.len == 0)) {
                const line_end = strings.indexOf(header_chunk, "\r\n") orelse return error.@"is missing header line end";
                const line = header_chunk[0..line_end];
                header_chunk = header_chunk[line_end + 2 ..];
                const colon = strings.indexOf(line, ":") orelse return error.@"is missing header colon separator";

                const key = line[0..colon];
                var value = if (line.len > colon + 1) line[colon + 1 ..] else "";
                if (strings.eqlCaseInsensitiveASCII(key, "content-disposition", true)) {
                    value = strings.trim(value, " ");
                    if (strings.hasPrefixComptime(value, "form-data;")) {
                        value = value["form-data;".len..];
                        value = strings.trim(value, " ");
                    }

                    while (strings.indexOf(value, "=")) |eql_start| {
                        const eql_key = strings.trim(value[0..eql_start], " ;");
                        value = value[eql_start + 1 ..];
                        if (strings.hasPrefixComptime(value, "\"")) {
                            value = value[1..];
                        }

                        var field_value = value;
                        {
                            var i: usize = 0;
                            while (i < field_value.len) : (i += 1) {
                                switch (field_value[i]) {
                                    '"' => {
                                        field_value = field_value[0..i];
                                        break;
                                    },
                                    '\\' => {
                                        i += @intFromBool(field_value.len > i + 1 and field_value[i + 1] == '"');
                                    },
                                    // the spec requires a end quote, but some browsers don't send it
                                    else => {},
                                }
                            }
                            value = value[@min(i + 1, value.len)..];
                        }

                        if (strings.eqlCaseInsensitiveASCII(eql_key, "name", true)) {
                            name = field_value;
                        } else if (strings.eqlCaseInsensitiveASCII(eql_key, "filename", true)) {
                            filename = field_value;
                        }

                        if (name != null and filename != null) {
                            break;
                        }

                        if (strings.indexOfChar(value, ';')) |semi_start| {
                            value = value[semi_start + 1 ..];
                        } else {
                            break;
                        }
                    }
                } else if (value.len > 0 and field.content_type.len == 0 and strings.eqlCaseInsensitiveASCII(key, "content-type", true)) {
                    field.content_type = strings.trim(value, "; \t");
                }
            }

            const field_name = name orelse continue;

            var body = remain;
            if (strings.endsWithComptime(body, "\r\n")) {
                body = body[0 .. body.len - 2];
            }
            field.value = body;
            field.filename = filename;

            try iterator(ctx, field_name, field);
        }
    }
};

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
