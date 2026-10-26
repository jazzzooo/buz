const MarkdownInput = union(enum) {
    string: bindgen.DOMString,
    buffer: bindgen.OwnedLease(u8),

    fn fromArgument(value: anytype) bun.OOM!MarkdownInput {
        return switch (value) {
            .string => |string| .{ .string = string.toOwned() },
            .buffer => |buffer| .{ .buffer = try buffer.toOwned() },
        };
    }

    fn deinit(input: *MarkdownInput) void {
        switch (input.*) {
            inline else => |*value| value.deinit(),
        }
    }
};

pub fn renderToAnsi(
    context: bindgen.CallContext(AnsiSchema),
    args: bindgen.Args(AnsiSchema),
) bun.JSError!bindgen.DOMString {
    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();

    var encoded: bun.String.Slice = .empty;
    defer encoded.deinit();
    const input = switch (args.input) {
        .buffer => |buffer| buffer.unsafePtr("the generated entry frame owns the byte lease until synchronous ANSI rendering finishes"),
        .string => |string| input: {
            encoded = try string.toUTF8(arena.allocator());
            break :input encoded.slice();
        },
    };

    var theme: md.AnsiTheme = .{
        .colors = true,
        .hyperlinks = false,
        .kitty_graphics = false,
        .light = md.detectLightBackground(),
        .columns = 80,
    };
    if (args.theme) |options| {
        theme.colors = options.colors;
        theme.hyperlinks = options.hyperlinks;
        theme.kitty_graphics = options.kitty_graphics;
        theme.light = options.light orelse theme.light;
        theme.columns = options.columns;
    }

    const result = (md.renderToAnsi(input, arena.allocator(), .terminal, theme) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StackOverflow => throwStackOverflow(context),
    }) orelse return error.OutOfMemory;
    return bindgen.DOMString.fromUTF8(result);
}

pub fn renderToHTML(
    context: bindgen.CallContext(HTMLSchema),
    args: bindgen.Args(HTMLSchema),
) bun.JSError!bindgen.DOMString {
    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();

    var encoded: bun.String.Slice = .empty;
    defer encoded.deinit();
    const input = switch (args.input) {
        .buffer => |buffer| buffer.unsafePtr("the generated entry frame owns the byte lease until synchronous HTML rendering finishes"),
        .string => |string| input: {
            encoded = try string.toUTF8(arena.allocator());
            break :input encoded.slice();
        },
    };

    const result = md.renderToHtmlWithOptions(input, arena.allocator(), markdownOptions(args.options)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StackOverflow => throwStackOverflow(context),
        error.JSError, error.JSTerminated => unreachable,
    };
    return bindgen.DOMString.fromUTF8(result);
}

fn markdownOptions(input: anytype) md.Options {
    const generated = input orelse return .{};
    var options: md.Options = .{};

    inline for (.{
        "tables",
        "strikethrough",
        "tasklists",
        "hard_soft_breaks",
        "wiki_links",
        "underline",
        "latex_math",
        "collapse_whitespace",
        "permissive_atx_headers",
        "no_indented_code_blocks",
        "no_html_blocks",
        "no_html_spans",
        "tag_filter",
    }) |field_name| {
        @field(options, field_name) = @field(generated, field_name);
    }

    if (generated.autolinks) |autolinks| switch (autolinks) {
        .enabled => |enabled| options.permissive_autolinks = enabled,
        .options => |settings| {
            if (settings.url) |enabled| options.permissive_url_autolinks = enabled;
            if (settings.www) |enabled| options.permissive_www_autolinks = enabled;
            if (settings.email) |enabled| options.permissive_email_autolinks = enabled;
        },
    };

    if (generated.headings) |headings| switch (headings) {
        .enabled => |enabled| {
            options.heading_ids = enabled;
            options.autolink_headings = enabled;
        },
        .options => |settings| {
            if (settings.ids) |enabled| options.heading_ids = enabled;
            if (settings.autolink) |enabled| options.autolink_headings = enabled;
        },
    };

    return options;
}

pub const MarkdownParseSession = struct {
    bindgen_state: bindgen.ClassState = .{},
    input: ?MarkdownInput,

    pub fn construct(
        _: bindgen.CallContext(ParseSessionConstructorSchema),
        args: bindgen.Args(ParseSessionConstructorSchema),
    ) bun.JSError!*MarkdownParseSession {
        var input = try MarkdownInput.fromArgument(args.input);
        errdefer input.deinit();
        const session = try bun.default_allocator.create(MarkdownParseSession);
        session.* = .{ .input = input };
        return session;
    }

    pub fn parse(
        session: *MarkdownParseSession,
        context: bindgen.CallContext(ParseSessionParseSchema),
        args: bindgen.Args(ParseSessionParseSchema),
    ) bindgen.CallError(ParseSessionParseSchema)!ParseOutput {
        var input = session.input orelse return context.fail(.inactive_session, {});
        session.input = null;
        defer input.deinit();

        var arena: bun.ArenaAllocator = .init(bun.default_allocator);
        defer arena.deinit();
        var encoded: bun.String.Slice = .empty;
        defer encoded.deinit();
        const bytes = switch (input) {
            .buffer => |*buffer| buffer.unsafePtr("this parse call owns the input lease until event rendering and its cleanup finish, then releases it before returning"),
            .string => |*string| bytes: {
                encoded = try string.toUTF8(arena.allocator());
                break :bytes encoded.slice();
            },
        };

        const options = markdownOptions(args.options);
        var renderer: EventRenderer = .init(bytes, options.heading_ids);
        defer renderer.deinit();
        md.renderWithRenderer(bytes, arena.allocator(), options, renderer.renderer()) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StackOverflow => throwStackOverflow(context),
            error.JSError, error.JSTerminated => unreachable,
        };

        const events = try ParseEvents.fromOwnedSlice(renderer.events.items);
        renderer.events.items.len = 0;
        const legacy = if (args.options) |settings|
            if (settings.react_version) |version| version <= 18 else false
        else
            false;
        return .{ .events = events, .legacy = legacy };
    }

    pub fn release(
        session: *MarkdownParseSession,
        _: bindgen.CallContext(ParseSessionReleaseSchema),
        _: bindgen.Args(ParseSessionReleaseSchema),
    ) bun.JSError!void {
        session.releaseInput();
    }

    pub fn destroy(session: *MarkdownParseSession) void {
        session.releaseInput();
        bun.default_allocator.destroy(session);
    }

    fn releaseInput(session: *MarkdownParseSession) void {
        if (session.input) |*input| input.deinit();
        session.input = null;
    }
};

const EventRenderer = struct {
    allocator: std.mem.Allocator = bun.default_allocator,
    source: []const u8,
    events: std.ArrayListUnmanaged(ParseEvent) = .empty,
    heading_tracker: md.helpers.HeadingIdTracker,

    fn init(source: []const u8, heading_ids: bool) EventRenderer {
        return .{
            .source = source,
            .heading_tracker = md.helpers.HeadingIdTracker.init(heading_ids),
        };
    }

    fn deinit(renderer_: *EventRenderer) void {
        for (renderer_.events.items) |*event| {
            if (event.primary) |*value| value.deinit();
            if (event.secondary) |*value| value.deinit();
        }
        renderer_.events.deinit(renderer_.allocator);
        renderer_.heading_tracker.deinit(renderer_.allocator);
    }

    fn renderer(renderer_: *EventRenderer) md.Renderer {
        return .{ .ptr = renderer_, .vtable = &vtable };
    }

    fn append(
        renderer_: *EventRenderer,
        phase: EventPhase,
        kind: EventKind,
        data: u32,
        primary: ?[]const u8,
        secondary: ?[]const u8,
        checked: ?bool,
    ) bun.OOM!void {
        var owned_primary: ?bindgen.DOMString = if (primary) |value| try .fromUTF8(value) else null;
        errdefer if (owned_primary) |*value| value.deinit();
        var owned_secondary: ?bindgen.DOMString = if (secondary) |value| try .fromUTF8(value) else null;
        errdefer if (owned_secondary) |*value| value.deinit();
        try renderer_.events.append(renderer_.allocator, .{
            .phase = phase,
            .kind = kind,
            .data = data,
            .primary = owned_primary,
            .secondary = owned_secondary,
            .checked = checked,
        });
    }

    const vtable: md.Renderer.VTable = .{
        .enterBlock = enterBlock,
        .leaveBlock = leaveBlock,
        .enterSpan = enterSpan,
        .leaveSpan = leaveSpan,
        .text = text,
    };

    fn enterBlock(pointer: *anyopaque, block_type: md.BlockType, data: u32, flags: u32) bun.JSError!void {
        const renderer_: *EventRenderer = @ptrCast(@alignCast(pointer));
        if (block_type == .doc) return;
        if (block_type == .h) renderer_.heading_tracker.enterHeading();

        const primary: ?[]const u8 = switch (block_type) {
            .code => if (flags & md.BLOCK_FENCED_CODE != 0) language: {
                const language = extractLanguage(renderer_.source, data);
                break :language if (language.len > 0) language else null;
            } else null,
            .th, .td => md.types.alignmentName(md.types.alignmentFromData(data)),
            else => null,
        };
        const checked: ?bool = if (block_type == .li) checked: {
            const mark = md.types.taskMarkFromData(data);
            break :checked if (mark == 0) null else md.types.isTaskChecked(mark);
        } else null;
        try renderer_.append(.enter, blockKind(block_type), data, primary, null, checked);
    }

    fn leaveBlock(pointer: *anyopaque, block_type: md.BlockType, data: u32) bun.JSError!void {
        const renderer_: *EventRenderer = @ptrCast(@alignCast(pointer));
        if (block_type == .doc) return;
        const heading_id = if (block_type == .h) try renderer_.heading_tracker.leaveHeading(renderer_.allocator) else null;
        try renderer_.append(.leave, blockKind(block_type), data, heading_id, null, null);
        if (block_type == .h) renderer_.heading_tracker.clearAfterHeading();
    }

    fn enterSpan(pointer: *anyopaque, span_type: md.SpanType, detail: md.SpanDetail) bun.JSError!void {
        const renderer_: *EventRenderer = @ptrCast(@alignCast(pointer));
        const has_link = span_type == .a or span_type == .img or span_type == .wikilink;
        const has_title = (span_type == .a or span_type == .img) and detail.title.len > 0;
        try renderer_.append(
            .enter,
            spanKind(span_type),
            0,
            if (has_link) detail.href else null,
            if (has_title) detail.title else null,
            null,
        );
    }

    fn leaveSpan(pointer: *anyopaque, span_type: md.SpanType) bun.JSError!void {
        const renderer_: *EventRenderer = @ptrCast(@alignCast(pointer));
        try renderer_.append(.leave, spanKind(span_type), 0, null, null, null);
    }

    fn text(pointer: *anyopaque, text_type: md.TextType, content: []const u8) bun.JSError!void {
        const renderer_: *EventRenderer = @ptrCast(@alignCast(pointer));
        try renderer_.heading_tracker.trackText(text_type, content, renderer_.allocator);
        switch (text_type) {
            .null_char => try renderer_.append(.raw_text, .none, 0, "\xEF\xBF\xBD", null, null),
            .br => try renderer_.append(.hard_break, .none, 0, null, null, null),
            .softbr => try renderer_.append(.raw_text, .none, 0, "\n", null, null),
            .entity => {
                var buffer: [8]u8 = undefined;
                try renderer_.append(.text, .none, 0, md.helpers.decodeEntityToUtf8(content, &buffer) orelse content, null, null);
            },
            else => try renderer_.append(.text, .none, 0, content, null, null),
        }
    }
};

fn blockKind(block_type: md.BlockType) EventKind {
    return switch (block_type) {
        .doc => .none,
        .h => .heading,
        .p => .paragraph,
        .quote => .blockquote,
        .code => .code,
        .ul => .unordered_list,
        .ol => .ordered_list,
        .li => .list_item,
        .hr => .horizontal_rule,
        .table => .table,
        .thead => .table_head,
        .tbody => .table_body,
        .tr => .table_row,
        .th => .table_header_cell,
        .td => .table_cell,
        .html => .html,
    };
}

fn spanKind(span_type: md.SpanType) EventKind {
    return switch (span_type) {
        .em => .emphasis,
        .strong => .strong,
        .a => .link,
        .img => .image,
        .code => .code_span,
        .del => .strikethrough,
        .latexmath => .math,
        .latexmath_display => .math_display,
        .wikilink => .wiki_link,
        .u => .underline,
    };
}

fn extractLanguage(source: []const u8, start: u32) []const u8 {
    var end = start;
    while (end < source.len) : (end += 1) {
        switch (source[end]) {
            ' ', '\t', '\n', '\r' => break,
            else => {},
        }
    }
    return source[start..end];
}

fn throwStackOverflow(context: anytype) bun.JSError {
    context.engineIn("errors", "throwStackOverflow").call(.{}) catch |err| return err;
    unreachable;
}

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
const md = bun.md;
const Bindings = bindgen.Module("MarkdownObject");
const HTMLSchema = Bindings.function("html");
const AnsiSchema = Bindings.function("ansi");
const ParseSessionSchema = Bindings.class("MarkdownParseSession");
const ParseSessionConstructorSchema = ParseSessionSchema.constructor();
const ParseSessionParseSchema = ParseSessionSchema.member("parse");
const ParseSessionReleaseSchema = ParseSessionSchema.member("release");
const ParseOutput = bindgen.Return(ParseSessionParseSchema);
const ParseEvents = @FieldType(ParseOutput, "events");
const ParseEvent = ParseEvents.Element;
const EventPhase = @FieldType(ParseEvent, "phase");
const EventKind = @FieldType(ParseEvent, "kind");
