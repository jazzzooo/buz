pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Formatter = struct {
    text: []const u8,

    pub fn format(this: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var overlay = Overlay.init(this.text);
        try overlay.writeRange(writer, .{ .start = 0, .end = this.text.len });
    }
};

pub const Overlay = struct {
    source: []const u8,
    scanner: Scanner,
    redaction: ?Range,
    written_end: usize = 0,

    pub fn init(source: []const u8) Overlay {
        var overlay = Overlay{
            .source = source,
            .scanner = Scanner.init(source),
            .redaction = null,
        };
        overlay.redaction = overlay.scanner.next();
        return overlay;
    }

    pub fn writeRange(this: *Overlay, writer: *std.Io.Writer, range: Range) std.Io.Writer.Error!void {
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= this.source.len);
        std.debug.assert(range.start >= this.written_end);
        if (range.start == range.end) return;

        var index = range.start;
        while (this.redaction) |redaction| {
            if (redaction.end <= index) {
                this.redaction = this.scanner.next();
                continue;
            }
            if (redaction.start >= range.end) break;

            const visible_end = @min(redaction.start, range.end);
            if (index < visible_end) try writer.writeAll(this.source[index..visible_end]);

            const redacted_start = @max(index, redaction.start);
            const redacted_end = @min(range.end, redaction.end);
            if (redacted_start < redacted_end) {
                try writer.splatByteAll('*', redacted_end - redacted_start);
                index = redacted_end;
            }

            if (index >= redaction.end) this.redaction = this.scanner.next();
            if (index >= range.end) break;
        }

        if (index < range.end) try writer.writeAll(this.source[index..range.end]);
        this.written_end = range.end;
    }
};

const Scanner = struct {
    source: []const u8,
    index: usize = 0,
    pending: ?Range = null,
    url_checked_until: usize = 0,

    const sensitive_identifiers = [_][]const u8{
        "_authToken",
        "_password",
        "_auth",
        "email",
        "token",
    };

    fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    fn next(this: *Scanner) ?Range {
        scan: while (this.index < this.source.len) {
            if (this.pending) |pending| {
                if (pending.end <= this.index) {
                    this.pending = null;
                } else if (pending.start <= this.index) {
                    const range = Range{ .start = this.index, .end = pending.end };
                    this.index = pending.end;
                    this.pending = null;
                    return range;
                }
            }

            const start = this.index;

            if (strings.startsWithUUID(this.source[start..])) {
                const range = Range{ .start = start, .end = start + strings.uuid_len };
                this.index = range.end;
                return range;
            }

            const npm_secret_len: usize = strings.startsWithNpmSecret(this.source[start..]);
            if (npm_secret_len > 0) {
                const range = Range{ .start = start, .end = start + npm_secret_len };
                this.index = range.end;
                return range;
            }

            if (start >= this.url_checked_until) {
                if (this.scanUrl(start)) |url| {
                    this.url_checked_until = url.end;
                    if (url.redaction) |redaction| this.remember(redaction);
                }
            }

            for (sensitive_identifiers) |identifier| {
                const key_end = this.sensitiveKeyEnd(start, identifier) orelse continue;
                if (this.sensitiveValue(key_end)) |value| this.remember(value);
                this.index = key_end;
                continue :scan;
            }

            this.index += 1;
        }

        return null;
    }

    fn sensitiveKeyEnd(this: *const Scanner, start: usize, identifier: []const u8) ?usize {
        const quote = this.source[start];
        if (quote == '\'' or quote == '"') {
            const identifier_start = start + 1;
            if (identifier.len > this.source.len - identifier_start) return null;
            const identifier_end = identifier_start + identifier.len;
            if (!std.mem.eql(u8, this.source[identifier_start..identifier_end], identifier)) return null;
            if (identifier_end == this.source.len or this.source[identifier_end] != quote) return null;
            return identifier_end + 1;
        }

        if (start > 0 and js_lexer.isIdentifierContinue(this.source[start - 1])) return null;
        if (identifier.len > this.source.len - start) return null;
        if (!std.mem.eql(u8, this.source[start .. start + identifier.len], identifier)) return null;
        const end = start + identifier.len;
        if (end < this.source.len and js_lexer.isIdentifierContinue(this.source[end])) return null;
        return end;
    }

    fn sensitiveValue(this: *const Scanner, identifier_end: usize) ?Range {
        var start = identifier_end;
        while (start < this.source.len and std.ascii.isWhitespace(this.source[start])) start += 1;
        if (start == this.source.len) return null;

        if (this.source[start] == '=' or this.source[start] == ':') {
            start += 1;
            while (start < this.source.len and std.ascii.isWhitespace(this.source[start])) start += 1;
            if (start == this.source.len) return null;
        }

        const line_end = if (strings.indexOfChar(this.source[start..], '\n')) |newline| start + newline else this.source.len;
        const quote = this.source[start];
        if (quote != '\'' and quote != '"' and quote != '`') {
            return if (line_end > start) .{ .start = start, .end = line_end } else null;
        }

        var end = start + 1;
        while (end < line_end) {
            if (this.source[end] == quote) {
                return if (end > start + 1) .{ .start = start + 1, .end = end } else null;
            }
            if (this.source[end] == '\\') {
                end += 1;
                if (end < line_end) end += 1;
                continue;
            }
            end += 1;
        }

        return if (line_end > start + 1) .{ .start = start + 1, .end = line_end } else null;
    }

    fn scanUrl(this: *const Scanner, start: usize) ?struct { end: usize, redaction: ?Range } {
        const scheme_end = if (std.mem.startsWith(u8, this.source[start..], "http://"))
            start + "http://".len
        else if (std.mem.startsWith(u8, this.source[start..], "https://"))
            start + "https://".len
        else
            return null;

        var end = scheme_end;
        while (end < this.source.len) : (end += 1) {
            switch (this.source[end]) {
                '\'', '"', '`' => break,
                else => if (std.ascii.isWhitespace(this.source[end])) break,
            }
        }

        var colon: ?usize = null;
        var redaction: ?Range = null;
        for (scheme_end..end) |index| {
            switch (this.source[index]) {
                ':' => colon = index,
                '@' => {
                    if (colon) |password_start| {
                        if (password_start + 1 < index) {
                            const range = Range{ .start = password_start + 1, .end = index };
                            if (redaction) |current| {
                                redaction = .{ .start = @min(current.start, range.start), .end = index };
                            } else {
                                redaction = range;
                            }
                        }
                    }
                    colon = null;
                },
                else => {},
            }
        }

        return .{ .end = end, .redaction = redaction };
    }

    fn remember(this: *Scanner, range: Range) void {
        std.debug.assert(range.end <= this.source.len);
        if (range.start >= range.end) return;
        if (this.pending) |pending| {
            this.pending = .{
                .start = @min(pending.start, range.start),
                .end = @max(pending.end, range.end),
            };
            return;
        }
        this.pending = range;
    }
};

const bun = @import("bun");
const js_lexer = bun.js_lexer;
const strings = bun.strings;
const std = @import("std");
