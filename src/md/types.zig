/// Offset into the input document.
pub const OFF = u32;

/// Block types reported via enter_block / leave_block callbacks.
pub const BlockType = enum(u8) {
    doc,
    quote,
    ul,
    ol,
    li,
    hr,
    h,
    code,
    html,
    p,
    table,
    thead,
    tbody,
    tr,
    th,
    td,
};

/// Span (inline) types reported via enter_span / leave_span callbacks.
pub const SpanType = enum(u8) {
    em,
    strong,
    a,
    img,
    code,
    del,
    latexmath,
    latexmath_display,
    wikilink,
    u,
};

/// Text types reported via the text callback.
pub const TextType = enum(u8) {
    normal,
    null_char,
    br,
    softbr,
    entity,
    code,
    html,
    latexmath,
};

/// Table cell alignment.
pub const Align = enum(u8) {
    default,
    left,
    center,
    right,
};

/// Renderer interface. The parser calls these methods to produce output.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        enterBlock: *const fn (ptr: *anyopaque, block_type: BlockType, data: u32, flags: u32) bun.JSError!void,
        leaveBlock: *const fn (ptr: *anyopaque, block_type: BlockType, data: u32) bun.JSError!void,
        enterSpan: *const fn (ptr: *anyopaque, span_type: SpanType, detail: SpanDetail) bun.JSError!void,
        leaveSpan: *const fn (ptr: *anyopaque, span_type: SpanType) bun.JSError!void,
        text: *const fn (ptr: *anyopaque, text_type: TextType, content: []const u8) bun.JSError!void,
    };

    pub inline fn enterBlock(self: Renderer, block_type: BlockType, data: u32, flags: u32) bun.JSError!void {
        return self.vtable.enterBlock(self.ptr, block_type, data, flags);
    }
    pub inline fn leaveBlock(self: Renderer, block_type: BlockType, data: u32) bun.JSError!void {
        return self.vtable.leaveBlock(self.ptr, block_type, data);
    }
    pub inline fn enterSpan(self: Renderer, span_type: SpanType, detail: SpanDetail) bun.JSError!void {
        return self.vtable.enterSpan(self.ptr, span_type, detail);
    }
    pub inline fn leaveSpan(self: Renderer, span_type: SpanType) bun.JSError!void {
        return self.vtable.leaveSpan(self.ptr, span_type);
    }
    pub inline fn text(self: Renderer, text_type: TextType, content: []const u8) bun.JSError!void {
        return self.vtable.text(self.ptr, text_type, content);
    }
};

/// Detail data for span events (links, images, wikilinks).
pub const SpanDetail = struct {
    href: []const u8 = "",
    title: []const u8 = "",
    /// Standard autolink (angle-bracket): use writeUrlEscaped (no entity/escape processing)
    autolink: bool = false,
    /// Standard autolink is an email: prepend "mailto:" to href
    autolink_email: bool = false,
    /// Permissive autolink: use HTML-escaping for href (not URL-escaping)
    permissive_autolink: bool = false,
    /// Permissive www autolink: prepend "http://" to href
    autolink_www: bool = false,
};

// --- Internal types used by the parser ---

/// Line types during block analysis.
pub const LineType = enum(u8) {
    blank,
    hr,
    atxheader,
    setextunderline,
    setextheader,
    indentedcode,
    fencedcode,
    html,
    text,
    table,
    tableunderline,
};

/// A line analysis result.
pub const Line = struct {
    type: LineType = .blank,
    beg: OFF = 0,
    end: OFF = 0,
    indent: u32 = 0,
    data: u32 = 0,
    enforce_new_block: bool = false,
};

/// A verbatim line (stores beg/end offsets plus indent for indented code).
pub const VerbatimLine = extern struct {
    beg: OFF,
    end: OFF,
    indent: u32,
};

/// Container types: blockquote or list item.
pub const Container = struct {
    ch: u8 = 0,
    is_loose: bool = false,
    is_task: bool = false,
    task_mark_off: OFF = 0,
    start: u32 = 0,
    mark_indent: u32 = 0,
    contents_indent: u32 = 0,
    block_byte_off: u32 = 0,
};

pub const BLOCK_CONTAINER_CLOSER: u32 = 0x01;
pub const BLOCK_CONTAINER_OPENER: u32 = 0x02;
pub const BLOCK_LOOSE_LIST: u32 = 0x04;
pub const BLOCK_SETEXT_HEADER: u32 = 0x08;
pub const BLOCK_FENCED_CODE: u32 = 0x10;
pub const BLOCK_REF_DEF_ONLY: u32 = 0x20;

/// Block descriptor stored in block_bytes buffer.
pub const Block = struct {
    type: BlockType,
    flags: u32 = 0,
    data: u32 = 0,
    n_lines: u32 = 0,
};

/// A mark in the inline processing system.
pub const Mark = struct {
    beg: OFF = 0,
    end: OFF = 0,
    prev: i32 = -1,
    next: i32 = -1,
    ch: u8 = 0,
    flags: u16 = 0,
};

/// Parser flags controlling which extensions are enabled.
pub const Flags = struct {
    collapse_whitespace: bool = false,
    permissive_atx_headers: bool = false,
    permissive_url_autolinks: bool = false,
    permissive_www_autolinks: bool = false,
    permissive_email_autolinks: bool = false,
    no_indented_code_blocks: bool = false,
    no_html_blocks: bool = false,
    no_html_spans: bool = false,
    tables: bool = true,
    strikethrough: bool = true,
    tasklists: bool = true,
    latex_math: bool = false,
    wiki_links: bool = false,
    underline: bool = false,
    hard_soft_breaks: bool = false,

    pub const commonmark: Flags = .{
        .tables = false,
        .strikethrough = false,
        .tasklists = false,
    };

    pub const github: Flags = .{
        .tables = true,
        .strikethrough = true,
        .tasklists = true,
        .permissive_url_autolinks = true,
        .permissive_www_autolinks = true,
        .permissive_email_autolinks = true,
    };
};

/// Internal limits matching md4c.
pub const TABLE_MAXCOLCOUNT: u32 = 128;

// ========================================
// Metadata extraction helpers
// ========================================

/// Extract table cell alignment from block data.
pub fn alignmentFromData(data: u32) Align {
    return @fromBackingInt(@intCast(@as(u2, @truncate(data))));
}

/// Get string name for alignment, or null for default.
pub fn alignmentName(alignment: Align) ?[]const u8 {
    return switch (alignment) {
        .left => "left",
        .center => "center",
        .right => "right",
        .default => null,
    };
}

/// Extract task list item mark from block data. Returns 0 for non-task items.
pub fn taskMarkFromData(data: u32) u8 {
    return @truncate(data);
}

/// Check if a task mark indicates a checked box.
pub fn isTaskChecked(task_mark: u8) bool {
    return task_mark != 0 and task_mark != ' ';
}

const bun = @import("bun");
