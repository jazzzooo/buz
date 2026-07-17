const JavaScriptSyntaxHighlighter = @This();

text: []const u8,
opts: Options,

pub const Options = struct {
    enable_colors: bool,
    max_highlight_bytes: ?usize = 2048,
    redact_sensitive_information: bool = false,
};

pub fn format(this: JavaScriptSyntaxHighlighter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const highlight = this.opts.enable_colors and
        (this.opts.max_highlight_bytes == null or this.text.len <= this.opts.max_highlight_bytes.?);
    var renderer = Renderer.init(this.text, writer, highlight, this.opts.redact_sensitive_information);
    errdefer renderer.finish() catch {};

    if (!highlight) {
        try renderer.writeRange(.{ .start = 0, .end = this.text.len }, .plain);
        return;
    }

    var scanner = SyntaxScanner.init(this.text);
    while (scanner.next()) |token| {
        try renderer.writeToken(token);
    }
    try renderer.finish();
}

const Token = struct {
    tag: Tag,
    range: Range,

    const Tag = enum {
        whitespace,
        identifier,
        number,
        string,
        template_delimiter,
        comment,
        method,
        jsx,
        semicolon,
        brace,
        plain,
    };
};

const SyntaxScanner = struct {
    const max_contexts = 64;

    const CodeContext = struct {
        interpolation: bool = false,
        brace_depth: usize = 0,
    };

    const Context = union(enum) {
        code: CodeContext,
        template,
    };

    source: []const u8,
    index: usize = 0,
    contexts: [max_contexts]Context = undefined,
    context_count: usize = 1,

    fn init(source: []const u8) SyntaxScanner {
        var scanner = SyntaxScanner{ .source = source };
        scanner.contexts[0] = .{ .code = .{} };
        return scanner;
    }

    fn next(this: *SyntaxScanner) ?Token {
        if (this.index >= this.source.len) return null;

        return switch (this.contexts[this.context_count - 1]) {
            .code => this.nextCode(),
            .template => this.nextTemplate(),
        };
    }

    fn nextCode(this: *SyntaxScanner) Token {
        const start = this.index;
        const c = this.source[start];
        const context = &this.contexts[this.context_count - 1].code;

        if (c == '}') {
            if (context.interpolation and context.brace_depth == 0) {
                this.index += 1;
                this.popContext();
                return this.token(.template_delimiter, start);
            }
            context.brace_depth -|= 1;
            this.index += 1;
            return this.token(.brace, start);
        }

        if (c == '{') {
            context.brace_depth += 1;
            this.index += 1;
            return this.token(.brace, start);
        }

        if (std.ascii.isWhitespace(c)) {
            this.index += 1;
            while (this.index < this.source.len and std.ascii.isWhitespace(this.source[this.index])) {
                this.index += 1;
            }
            return this.token(.whitespace, start);
        }

        if (js_lexer.isIdentifierStart(c)) {
            this.index += 1;
            while (this.index < this.source.len and js_lexer.isIdentifierContinue(this.source[this.index])) {
                this.index += 1;
            }
            return this.token(.identifier, start);
        }

        if (c >= '0' and c <= '9') {
            this.scanNumber(c);
            return this.token(.number, start);
        }

        if (c == '\'' or c == '"') {
            this.scanQuoted(c);
            return this.token(.string, start);
        }

        if (c == '`') {
            if (!this.pushContext(.template)) return this.plainRemainder(start);
            this.index += 1;
            return this.token(.string, start);
        }

        if (c == '/') {
            if (this.hasPrefix(start, "//")) {
                this.index += 2;
                while (this.index < this.source.len and this.source[this.index] != '\n') {
                    this.index += 1;
                }
                return this.token(.comment, start);
            }

            if (this.hasPrefix(start, "/*")) {
                this.index += 2;
                while (this.index < this.source.len and !this.hasPrefix(this.index, "*/")) {
                    this.index += 1;
                }
                if (this.hasPrefix(this.index, "*/")) this.index += 2;
                return this.token(.comment, start);
            }
        }

        if (c == '.') {
            var end = start + 1;
            if (end < this.source.len and this.source[end] == '#') end += 1;
            if (end < this.source.len and js_lexer.isIdentifierStart(this.source[end])) {
                end += 1;
                while (end < this.source.len and js_lexer.isIdentifierContinue(this.source[end])) {
                    end += 1;
                }
                if (end < this.source.len and this.source[end] == '(') {
                    this.index = end;
                    return this.token(.method, start);
                }
            }
        }

        if (c == '<') {
            if (this.scanJSXTag()) return this.token(.jsx, start);
        }

        this.index += 1;
        return this.token(switch (c) {
            ';' => .semicolon,
            else => .plain,
        }, start);
    }

    fn nextTemplate(this: *SyntaxScanner) Token {
        const start = this.index;

        if (this.source[start] == '`') {
            this.index += 1;
            this.popContext();
            return this.token(.string, start);
        }

        if (this.hasPrefix(start, "${")) {
            if (!this.pushContext(.{ .code = .{ .interpolation = true } })) return this.plainRemainder(start);
            this.index += 2;
            return this.token(.template_delimiter, start);
        }

        while (this.index < this.source.len) {
            if (this.source[this.index] == '\\') {
                this.index += 1;
                if (this.index < this.source.len) this.index += 1;
                continue;
            }
            if (this.source[this.index] == '`' or this.hasPrefix(this.index, "${")) break;
            this.index += 1;
        }

        return this.token(.string, start);
    }

    fn scanNumber(this: *SyntaxScanner, first: u8) void {
        this.index += 1;
        if (first == '0' and this.index < this.source.len and this.source[this.index] == 'x') {
            this.index += 1;
            while (this.index < this.source.len) {
                switch (this.source[this.index]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => this.index += 1,
                    else => break,
                }
            }
            return;
        }

        while (this.index < this.source.len) {
            switch (this.source[this.index]) {
                '0'...'9', '.', 'e', 'E', 'x', 'X', 'b', 'B', 'o', 'O' => this.index += 1,
                else => break,
            }
        }
    }

    fn scanQuoted(this: *SyntaxScanner, quote: u8) void {
        this.index += 1;
        while (this.index < this.source.len) {
            if (this.source[this.index] == quote) {
                this.index += 1;
                return;
            }
            if (this.source[this.index] == '\\') {
                this.index += 1;
                if (this.index < this.source.len) this.index += 1;
                continue;
            }
            this.index += 1;
        }
    }

    fn scanJSXTag(this: *SyntaxScanner) bool {
        var end = this.index + 1;
        if (end < this.source.len and this.source[end] == '/') end += 1;
        if (end >= this.source.len or !js_lexer.isIdentifierStart(this.source[end])) return false;

        end += 1;
        while (end < this.source.len and js_lexer.isIdentifierContinue(this.source[end])) {
            end += 1;
        }
        while (end < this.source.len and this.source[end] != '>') {
            if (this.source[end] == '<') return false;
            end += 1;
        }
        if (end >= this.source.len) return false;

        this.index = end + 1;
        return true;
    }

    fn hasPrefix(this: *const SyntaxScanner, start: usize, prefix: []const u8) bool {
        return start <= this.source.len and prefix.len <= this.source.len - start and
            std.mem.eql(u8, this.source[start .. start + prefix.len], prefix);
    }

    fn pushContext(this: *SyntaxScanner, context: Context) bool {
        if (this.context_count == this.contexts.len) return false;
        this.contexts[this.context_count] = context;
        this.context_count += 1;
        return true;
    }

    fn popContext(this: *SyntaxScanner) void {
        if (this.context_count > 1) this.context_count -= 1;
    }

    fn token(this: *const SyntaxScanner, tag: Token.Tag, start: usize) Token {
        std.debug.assert(start < this.index);
        std.debug.assert(this.index <= this.source.len);
        return .{ .tag = tag, .range = .{ .start = start, .end = this.index } };
    }

    fn plainRemainder(this: *SyntaxScanner, start: usize) Token {
        this.index = this.source.len;
        return this.token(.plain, start);
    }
};

const Renderer = struct {
    const IdentifierContext = enum {
        none,
        constructor,
        type_name,
        import_from,
    };

    source: []const u8,
    writer: *std.Io.Writer,
    colors: bool,
    redactor: ?SourceRedactor.Overlay,
    identifier_context: IdentifierContext = .none,
    active_style: Style = .plain,

    fn init(source: []const u8, writer: *std.Io.Writer, colors: bool, redact: bool) Renderer {
        return .{
            .source = source,
            .writer = writer,
            .colors = colors,
            .redactor = if (redact) SourceRedactor.Overlay.init(source) else null,
        };
    }

    fn writeToken(this: *Renderer, token: Token) std.Io.Writer.Error!void {
        try this.writeRange(token.range, this.styleForToken(token));
    }

    fn styleForToken(this: *Renderer, token: Token) Style {
        return switch (token.tag) {
            .whitespace => .plain,
            .identifier => this.styleIdentifier(token.range),
            .number => this.resetContext(.yellow),
            .string => this.resetContext(.green),
            .template_delimiter => this.resetContext(.plain),
            .comment => .dim,
            .method => this.resetContext(.method),
            .jsx => this.resetContext(.cyan),
            .semicolon => this.resetContext(.dim),
            .brace => brk: {
                if (this.identifier_context != .import_from) this.identifier_context = .none;
                break :brk .plain;
            },
            .plain => this.resetContext(.plain),
        };
    }

    fn styleIdentifier(this: *Renderer, range: Range) Style {
        const identifier = this.source[range.start..range.end];
        if (Keywords.get(identifier)) |keyword| {
            if (keyword != .as) {
                this.identifier_context = switch (keyword) {
                    .new => .constructor,
                    .abstract, .namespace, .declare, .type, .interface => .type_name,
                    .import => .import_from,
                    else => .none,
                };
            }
            return keyword.style();
        }

        return switch (this.identifier_context) {
            .none => .plain,
            .constructor => brk: {
                this.identifier_context = .none;
                break :brk if (range.end < this.source.len and this.source[range.end] == '(') .bold else .plain;
            },
            .type_name => brk: {
                this.identifier_context = .none;
                break :brk .bold_blue;
            },
            .import_from => if (std.mem.eql(u8, identifier, "from")) brk: {
                this.identifier_context = .none;
                break :brk .magenta;
            } else .plain,
        };
    }

    fn resetContext(this: *Renderer, style: Style) Style {
        this.identifier_context = .none;
        return style;
    }

    fn writeRange(this: *Renderer, range: Range, style: Style) std.Io.Writer.Error!void {
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= this.source.len);
        if (range.start >= range.end) return;
        try this.setStyle(style);

        if (this.redactor) |*redactor| {
            try redactor.writeRange(this.writer, range);
            return;
        }
        try this.writer.writeAll(this.source[range.start..range.end]);
    }

    fn setStyle(this: *Renderer, style: Style) std.Io.Writer.Error!void {
        if (!this.colors or style == this.active_style) return;
        try this.writer.writeAll(if (style == .plain) reset else style.prefix());
        this.active_style = style;
    }

    fn finish(this: *Renderer) std.Io.Writer.Error!void {
        if (!this.colors or this.active_style == .plain) return;
        try this.writer.writeAll(reset);
        this.active_style = .plain;
    }
};

const Style = enum {
    plain,
    magenta,
    blue,
    yellow,
    red,
    green,
    dim,
    bold,
    bold_blue,
    method,
    cyan,

    fn prefix(this: Style) []const u8 {
        return switch (this) {
            .plain => "",
            .magenta => Output.prettyFmt("<r><magenta>", true),
            .blue => Output.prettyFmt("<r><blue>", true),
            .yellow => Output.prettyFmt("<r><yellow>", true),
            .red => Output.prettyFmt("<r><red>", true),
            .green => Output.prettyFmt("<r><green>", true),
            .dim => Output.prettyFmt("<r><d>", true),
            .bold => Output.prettyFmt("<r><b>", true),
            .bold_blue => Output.prettyFmt("<r><b><blue>", true),
            .method => Output.prettyFmt("<r><i><b>", true),
            .cyan => Output.prettyFmt("<r><cyan>", true),
        };
    }
};

const Keyword = enum {
    abstract,
    as,
    async,
    await,
    case,
    @"catch",
    class,
    @"const",
    @"continue",
    debugger,
    default,
    delete,
    do,
    @"else",
    @"enum",
    @"export",
    extends,
    false,
    finally,
    @"for",
    function,
    @"if",
    implements,
    import,
    in,
    instanceof,
    interface,
    let,
    new,
    null,
    package,
    private,
    protected,
    public,
    @"return",
    static,
    super,
    @"switch",
    this,
    throw,
    @"break",
    true,
    @"try",
    type,
    typeof,
    @"var",
    void,
    @"while",
    with,
    yield,
    string,
    number,
    boolean,
    symbol,
    any,
    object,
    unknown,
    never,
    namespace,
    declare,
    readonly,
    undefined,

    fn style(this: Keyword) Style {
        return switch (this) {
            .abstract,
            .as,
            .@"enum",
            .implements,
            .interface,
            .private,
            .protected,
            .public,
            .string,
            .number,
            .boolean,
            .symbol,
            .any,
            .object,
            .unknown,
            .never,
            .namespace,
            .declare,
            .readonly,
            => .blue,
            .undefined, .false, .null, .this, .true => .yellow,
            .delete => .red,
            else => .magenta,
        };
    }
};

const Keywords = bun.ComptimeEnumMap(Keyword);
const reset = Output.prettyFmt("<r>", true);
const Range = SourceRedactor.Range;

const bun = @import("bun");
const js_lexer = bun.js_lexer;
const Output = bun.Output;
const SourceRedactor = @import("SourceRedactor.zig");
const std = @import("std");
