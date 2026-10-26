/// Fetched when a client-side error happens. This performs two actions
/// - Logs the remapped stack trace to the console.
/// - Replies with the remapped stack trace.
/// Payload:
/// - `u32`: Responding message ID (echoed back)
/// - `u32`: Length of message
/// - `[n]u8`: Message
/// - `u32`: Length of error name
/// - `[n]u8`: Error name
/// - `u32`: Number of stack frames. For each
///   - `u32`: Line number (0 for unavailable)
///   - `u32`: Column number (0 for unavailable)
///   - `u32`: Length of file name (0 for unavailable)
///   - `[n]u8`: File name
///   - `u32`: Length of function name (0 for unavailable)
///   - `[n]u8`: Function name
pub fn WithOwner(comptime DevServer: type) type {
    return struct {
        const ErrorReportRequest = @This();
        const SourceMapStore = DevServer.SourceMapStore;
        const client_prefix = DevServer.client_prefix;

        dev: *DevServer,
        body: uws.BodyReaderMixin(@This(), "body", runWithBody, finalize),

        pub fn run(dev: *DevServer, _: *Request, resp: anytype) void {
            const ctx = bun.tryNew(ErrorReportRequest, .{
                .dev = dev,
                .body = .init(dev.allocator()),
            }) catch {
                AnyResponse.init(resp).forceClose();
                return;
            };
            ctx.dev.server.?.onPendingRequest();
            ctx.body.readBody(resp);
        }

        pub fn finalize(ctx: *ErrorReportRequest) void {
            ctx.dev.server.?.onStaticRequestComplete();
            bun.destroy(ctx);
        }

        pub fn runWithBody(ctx: *ErrorReportRequest, body: []const u8, r: AnyResponse) !void {
            var sfa_general_buffer: [65536]u8 = undefined;
            var sfa_general: std.heap.BufferFirstAllocator = .init(&sfa_general_buffer, ctx.dev.allocator());
            var sfa_sourcemap_buffer: [65536]u8 = undefined;
            var sfa_sourcemap: std.heap.BufferFirstAllocator = .init(&sfa_sourcemap_buffer, ctx.dev.allocator());
            const temp_alloc = sfa_general.allocator();
            var arena = std.heap.ArenaAllocator.init(temp_alloc);
            defer arena.deinit();
            var source_map_arena = std.heap.ArenaAllocator.init(sfa_sourcemap.allocator());
            defer source_map_arena.deinit();

            var payload = try ErrorReport.Payload.parse(body, temp_alloc);
            defer payload.deinit();
            const name = payload.name;
            const message = payload.message;
            const browser_url = payload.browser_url;
            var diagnostic = jsc.Diagnostic.empty;
            defer diagnostic.deinit();
            const frames = &diagnostic.value.frames;
            frames.* = try jsc.Diagnostic.Frames.initCapacity(payload.frames.len);
            for (payload.frames) |input| {
                var function_name = try bun.bindgen.DOMString.fromUTF8(input.function_name);
                errdefer function_name.deinit();
                frames.appendAssumeCapacity(.{
                    .functionName = function_name,
                    .sourceURL = try bun.bindgen.DOMString.fromUTF8(input.file_name),
                    .line = if (input.line > 0) @intCast(input.line - 1) else null,
                    .column = if (input.line > 0 and input.column > 0) @intCast(input.column - 1) else null,
                    .bytePosition = 0,
                    .codeType = .none,
                    .isAsync = false,
                    .remapped = false,
                });
            }

            const runtime_name = "Bun HMR Runtime";

            var origin = try bun.jsc.URL.originFromUTF8(browser_url);
            defer if (origin) |*value| value.deinit();
            const origin_utf8 = if (origin) |*value| try value.toUTF8(temp_alloc) else null;
            defer if (origin_utf8) |value| value.deinit();
            const browser_url_origin = if (origin_utf8) |value| value.slice() else browser_url;

            // All files that DevServer could provide a source map fit the pattern:
            // `/_bun/client/<label>-{u64}.js`
            // Where the u64 is a unique identifier pointing into sourcemaps.
            //
            // HMR chunks use this too, but currently do not host their JS code.
            var parsed_source_maps: AutoArrayHashMap(SourceMapStore.Key, ?SourceMapStore.GetResult) = .empty;
            try parsed_source_maps.ensureTotalCapacity(temp_alloc, 4);
            defer for (parsed_source_maps.values()) |*value| {
                if (value.*) |*v| v.deinit(temp_alloc);
            };

            var runtime_lines: ?[5][]const u8 = null;
            var first_line_of_interest: usize = 0;
            var top_frame_column: ?u32 = null;
            var region_of_interest_line: u32 = 0;
            for (frames.sliceMut()) |*frame| {
                const source_url = try frame.sourceURL.toOwnedSlice(temp_alloc);
                defer temp_alloc.free(source_url);
                // The browser code strips "http://localhost:3000" when the string
                // has /_bun/client. It's done because JS can refer to `location`
                const id = parseId(source_url, browser_url_origin) orelse continue;

                // Get and cache the parsed source map
                const gop = try parsed_source_maps.getOrPut(temp_alloc, id);
                if (!gop.found_existing) {
                    defer _ = source_map_arena.reset(.retain_capacity);
                    const psm = ctx.dev.source_maps.getParsedSourceMap(
                        ctx.dev.vm.io,
                        id,
                        source_map_arena.allocator(), // arena for parsing
                        temp_alloc, // store results into first arena
                    ) orelse {
                        Output.debugWarn("Failed to find mapping for {s}, {d}", .{ source_url, id.get() });
                        gop.value_ptr.* = null;
                        continue;
                    };
                    gop.value_ptr.* = psm;
                }
                const result: *const SourceMapStore.GetResult = &(gop.value_ptr.* orelse continue);

                // When before the first generated line, remap to the HMR runtime.
                //
                // Reminder that the HMR runtime is *not* sourcemapped. And appears
                // first in the bundle. This means that the mappings usually looks like
                // this:
                //
                // AAAA;;;;;;;;;;;ICGA,qCAA4B;
                // ^              ^ generated_mappings[1], actual code
                // ^
                // ^ generated_mappings[0], we always start it with this
                //
                // So we can know if the frame is inside the HMR runtime if
                // `frame.position.line < generated_mappings[1].lines`.
                const query = SourceMap.LineColumnOffset.fromOptional(frame.line, frame.column) orelse continue;
                const generated_mappings = result.mappings.generated();
                if (generated_mappings.len <= 1 or query.lines.zeroBased() < generated_mappings[1].lines.zeroBased()) {
                    frame.sourceURL.deinit();
                    frame.sourceURL = try bun.bindgen.DOMString.fromUTF8(runtime_name); // matches value in source map
                    frame.line = null;
                    frame.column = null;
                    frame.bytePosition = null;
                    continue;
                }

                // Remap the frame
                const remapped = result.mappings.find(
                    query.lines,
                    query.columns,
                );
                if (remapped) |*remapped_position| {
                    frame.line = std.math.cast(u32, remapped_position.originalLine());
                    frame.column = std.math.cast(u32, remapped_position.originalColumn());
                    frame.bytePosition = 0;
                    const index = remapped_position.source_index;
                    if (index >= 1 and (index - 1) < result.file_paths.len) {
                        const abs_path = result.file_paths[@intCast(index - 1)];
                        const replacement = try bun.bindgen.DOMString.fromUTF8(abs_path);
                        frame.sourceURL.deinit();
                        frame.sourceURL = replacement;
                        const rel_path = try ctx.dev.relativePath(temp_alloc, abs_path);
                        defer temp_alloc.free(rel_path);
                        if (frame.functionName.eqlUTF8(rel_path)) {
                            frame.functionName.deinit();
                        }
                        frame.remapped = true;

                        if (runtime_lines == null) {
                            const file = result.entry_files.get(@intCast(index - 1));
                            if (file.get()) |source_map| {
                                const json_encoded_source_code = source_map.quotedContents();
                                // First line of interest is two above the target line.
                                const target_line: usize = frame.line orelse continue;
                                first_line_of_interest = target_line -| 2;
                                region_of_interest_line = @intCast(target_line - first_line_of_interest);
                                runtime_lines = try extractJsonEncodedSourceCode(
                                    json_encoded_source_code,
                                    @intCast(first_line_of_interest),
                                    5,
                                    arena.allocator(),
                                );
                                top_frame_column = frame.column;
                            }
                        }
                    } else if (index == 0) {
                        // Should be picked up by above but just in case.
                        frame.sourceURL.deinit();
                        frame.sourceURL = try bun.bindgen.DOMString.fromUTF8(runtime_name);
                        frame.line = null;
                        frame.column = null;
                        frame.bytePosition = null;
                    }
                }
            }

            // Preserve the stack when every frame belongs to the runtime.
            const visible = struct {
                fn keep(runtime: []const u8, frame: *const jsc.Diagnostic.Frame) bool {
                    return jsc.Diagnostic.hasPosition(frame) or !frame.sourceURL.eqlUTF8(runtime);
                }
            }.keep;
            for (frames.slice()) |*frame| {
                if (visible(runtime_name, frame)) {
                    frames.retain(runtime_name, visible);
                    break;
                }
            }

            const exception = &diagnostic.value;
            exception.details.errorCode = .generic_error;
            exception.details.name = try bun.bindgen.DOMString.fromUTF8(name);
            exception.details.message = try bun.bindgen.DOMString.fromUTF8(message);

            const stderr = Output.errorWriterBuffered();
            defer Output.flush();
            switch (Output.enable_ansi_colors_stderr) {
                inline else => |ansi_colors| ctx.dev.vm.printExternallyRemappedDiagnostic(
                    exception,
                    bun.TextView.fromBytes(browser_url),
                    null,
                    @TypeOf(stderr),
                    stderr,
                    true,
                    ansi_colors,
                ) catch {},
            }

            var out: std.array_list.Managed(u8) = .init(ctx.dev.allocator());
            errdefer out.deinit();
            var out_writer = bun.ManagedWriter.init(&out);
            const w = out_writer.writer();

            try w.writeInt(u32, @intCast(exception.frames.len()), .little);
            for (exception.frames.slice()) |*frame| {
                try w.writeInt(i32, if (frame.line) |line| @as(i32, @intCast(line)) + 1 else 0, .little);
                try w.writeInt(i32, if (frame.column) |column| @as(i32, @intCast(column)) + 1 else 0, .little);

                const function_name = try frame.functionName.toOwnedSlice(temp_alloc);
                defer temp_alloc.free(function_name);
                try w.writeInt(u32, @intCast(function_name.len), .little);
                try w.writeAll(function_name);

                const src_to_write = try frame.sourceURL.toOwnedSlice(temp_alloc);
                defer temp_alloc.free(src_to_write);
                if (bun.strings.hasPrefixComptime(src_to_write, "/")) {
                    const file = try ctx.dev.relativePath(ctx.dev.allocator(), src_to_write);
                    defer ctx.dev.allocator().free(file);
                    try w.writeInt(u32, @intCast(file.len), .little);
                    try w.writeAll(file);
                } else {
                    try w.writeInt(u32, @intCast(src_to_write.len), .little);
                    try w.writeAll(src_to_write);
                }
            }

            if (runtime_lines) |*lines| {
                // trim empty lines
                var adjusted_lines: [][]const u8 = lines;
                while (adjusted_lines.len > 0 and adjusted_lines[0].len == 0) {
                    adjusted_lines = adjusted_lines[1..];
                    region_of_interest_line -|= 1;
                    first_line_of_interest += 1;
                }
                while (adjusted_lines.len > 0 and adjusted_lines[adjusted_lines.len - 1].len == 0) {
                    adjusted_lines.len -= 1;
                }

                try w.writeInt(u8, @intCast(adjusted_lines.len), .little);
                try w.writeInt(u32, @intCast(region_of_interest_line), .little);
                try w.writeInt(u32, @intCast(first_line_of_interest + 1), .little);
                try w.writeInt(u32, if (top_frame_column) |column| column + 1 else 0, .little);

                for (adjusted_lines) |line| {
                    try w.writeInt(u32, @intCast(line.len), .little);
                    try w.writeAll(line);
                }
            } else {
                try w.writeInt(u8, 0, .little);
            }

            out_writer.finish();
            var response_blob = AnyBlob.fromArrayList(out);
            out = .init(ctx.dev.allocator());
            defer response_blob.detach();
            try bun.api.server.StaticRoute.sendBlobThenDeinit(r, &response_blob, .{
                .mime_type = &.other,
                .server = ctx.dev.server.?,
            });
        }

        pub fn parseId(source_url: []const u8, browser_url: []const u8) ?SourceMapStore.Key {
            if (!bun.strings.startsWith(source_url, browser_url))
                return null;
            const after_host = source_url[bun.strings.withoutTrailingSlash(browser_url).len..];
            if (!bun.strings.hasPrefixComptime(after_host, client_prefix ++ "/"))
                return null;
            const after_prefix = after_host[client_prefix.len + 1 ..];
            // Extract the ID
            if (!bun.strings.hasSuffixComptime(after_prefix, ".js"))
                return null;
            const min_len = "00000000FFFFFFFF.js".len;
            if (after_prefix.len < min_len)
                return null;
            const hex = after_prefix[after_prefix.len - min_len ..][0 .. @sizeOf(u64) * 2];
            if (hex.len != @sizeOf(u64) * 2)
                return null;
            return .init(DevServerProtocol.parseHexToInt(u64, hex) orelse
                return null);
        }

        /// Instead of decoding the entire file, just decode the desired section.
        fn extractJsonEncodedSourceCode(contents: []const u8, target_line: u32, comptime n: usize, arena: Allocator) !?[n][]const u8 {
            var line: usize = 0;
            var prev: usize = 0;
            const index_of_first_line = if (target_line == 0)
                0 // no iteration needed
            else while (bun.strings.indexOfCharPos(contents, '\\', prev)) |i| : (prev = i + 2) {
                if (i >= contents.len - 2) return null;
                // Bun's JSON printer will not use a sillier encoding for newline.
                if (contents[i + 1] == 'n') {
                    line += 1;
                    if (line == target_line)
                        break i + 2;
                }
            } else return null;

            var rest = contents[index_of_first_line..];

            // For decoding JSON escapes, the JS Lexer decoding function has
            // `decodeEscapeSequences`, which only supports decoding to UTF-16.
            // Alternatively, it appears the TOML lexer has copied this exact
            // function but for UTF-8. So the decoder can just use that.
            //
            // This function expects but does not assume the escape sequences
            // given are valid, and does not bubble errors up.
            var log = Log.init(arena);
            var l: bun.interchange.toml.Lexer = .{
                .log = &log,
                .source = .initEmptyFile(""),
                .allocator = arena,
                .should_redact_logs = false,
                .prev_error_loc = .Empty,
            };
            defer log.deinit();

            var result: [n][]const u8 = @splat("");
            for (&result) |*decoded_line| {
                var has_extra_escapes = false;
                prev = 0;
                // Locate the line slice
                const end_of_line = while (bun.strings.indexOfCharPos(rest, '\\', prev)) |i| : (prev = i + 2) {
                    if (i >= rest.len - 1) return null;
                    if (rest[i + 1] == 'n') {
                        break i;
                    }
                    has_extra_escapes = true;
                } else rest.len;
                const encoded_line = rest[0..end_of_line];

                // Decode it
                if (has_extra_escapes) {
                    var bytes: std.array_list.Managed(u8) = try .initCapacity(arena, encoded_line.len);
                    try l.decodeEscapeSequences(0, encoded_line, false, std.array_list.Managed(u8), &bytes);
                    decoded_line.* = bytes.items;
                } else {
                    decoded_line.* = encoded_line;
                }

                if (end_of_line + 2 >= rest.len) break;
                rest = rest[end_of_line + 2 ..];
            }

            return result;
        }
    };
}

const bun = @import("bun");
const Output = bun.Output;
const jsc = bun.jsc;
const AnyBlob = jsc.WebCore.Blob.Any;
const Log = bun.logger.Log;
const SourceMap = bun.SourceMap;

const ErrorReport = @import("./ErrorReport.zig");
const DevServerProtocol = @import("../DevServerProtocol.zig");

const uws = bun.uws;
const AnyResponse = bun.uws.AnyResponse;
const Request = uws.Request;

const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMap = std.array_hash_map.Auto;
const Allocator = std.mem.Allocator;
