pub const T = enum {
    t_end_of_file,

    t_open_paren,
    t_close_paren,
    t_open_bracket,
    t_close_bracket,

    t_open_brace,
    t_close_brace,

    t_numeric_literal,
    t_date_time_literal,

    t_comma,

    t_string_literal,
    t_dot,

    t_equal,

    t_true,
    t_false,

    t_colon,

    t_identifier,

    t_plus,
    t_minus,

    t_empty_array,
};

pub const Lexer = struct {
    source: logger.Source,
    log: *logger.Log,
    start: usize = 0,
    end: usize = 0,
    current: usize = 0,

    allocator: std.mem.Allocator,

    code_point: CodePoint = -1,
    identifier: []const u8 = "",
    number: f64 = 0.0,
    number_is_integer: bool = false,
    integer_magnitude: u64 = 0,
    integer_magnitude_overflow: bool = false,
    number_error: ?NumberError = null,
    prev_error_loc: logger.Loc = logger.Loc.Empty,
    string_literal_slice: string = "",
    string_literal_is_ascii: bool = true,
    line_number: u32 = 0,
    token: T = T.t_end_of_file,
    scan_date_time_literal_next: bool = false,

    has_newline_before: bool = false,

    should_redact_logs: bool,

    pub inline fn loc(self: *const Lexer) logger.Loc {
        return logger.usize2Loc(self.start);
    }

    pub fn syntaxError(self: *Lexer) !void {
        @branchHint(.cold);

        // Only add this if there is not already an error.
        // It is possible that there is a more descriptive error already emitted.
        if (!self.log.hasErrors())
            self.addError(self.start, "Syntax Error", .{});

        return Error.SyntaxError;
    }

    pub fn addError(self: *Lexer, _loc: usize, comptime format: []const u8, args: anytype) void {
        @branchHint(.cold);

        var __loc = logger.usize2Loc(_loc);
        if (__loc.eql(self.prev_error_loc)) {
            return;
        }

        self.log.addErrorFmtOpts(
            self.log.msgs.allocator,
            format,
            args,
            .{
                .source = &self.source,
                .loc = __loc,
                .redact_sensitive_information = self.should_redact_logs,
            },
        ) catch unreachable;
        self.prev_error_loc = __loc;
    }

    pub fn addDefaultError(self: *Lexer, msg: []const u8) !void {
        @branchHint(.cold);

        self.addError(self.start, "{s}", .{msg});
        return Error.SyntaxError;
    }

    pub fn addSyntaxError(self: *Lexer, _loc: usize, comptime fmt: []const u8, args: anytype) !void {
        @branchHint(.cold);
        self.addError(_loc, fmt, args);
        return Error.SyntaxError;
    }

    pub fn addRangeError(self: *Lexer, r: logger.Range, comptime format: []const u8, args: anytype) !void {
        @branchHint(.cold);

        if (self.prev_error_loc.eql(r.loc)) {
            return;
        }

        const errorMessage = std.fmt.allocPrint(self.log.msgs.allocator, format, args) catch unreachable;
        try self.log.addErrorOpts(errorMessage, .{
            .source = &self.source,
            .loc = r.loc,
            .len = r.len,
            .redact_sensitive_information = self.should_redact_logs,
        });
        self.prev_error_loc = r.loc;
    }

    /// Look ahead at the next n codepoints without advancing the iterator.
    /// If fewer than n codepoints are available, then return the remainder of the string.
    fn peek(it: *Lexer, n: usize) string {
        const original_i = it.current;
        defer it.current = original_i;

        var end_ix = original_i;
        var found: usize = 0;
        while (found < n) : (found += 1) {
            const next_codepoint = it.nextCodepointSlice();
            if (next_codepoint.len == 0) break;
            end_ix += next_codepoint.len;
        }

        return it.source.contents[original_i..end_ix];
    }

    inline fn nextCodepointSlice(it: *Lexer) []const u8 {
        if (it.current >= it.source.contents.len) {
            return "";
        }
        var iterator = std.unicode.Wtf8Iterator{
            .bytes = it.source.contents,
            .i = it.current,
        };
        return iterator.nextCodepointSlice().?;
    }

    inline fn nextCodepoint(it: *Lexer) CodePoint {
        if (it.current >= it.source.contents.len) {
            it.end = it.source.contents.len;
            return -1;
        }

        it.end = it.current;
        var iterator = std.unicode.Wtf8Iterator{
            .bytes = it.source.contents,
            .i = it.current,
        };
        const code_point = iterator.nextCodepoint().?;
        it.current = iterator.i;
        return @intCast(code_point);
    }

    inline fn step(lexer: *Lexer) void {
        lexer.code_point = lexer.nextCodepoint();

        lexer.line_number += @as(u32, @intFromBool(lexer.code_point == '\n'));
    }

    fn consumeQuoteRun(lexer: *Lexer, quote: CodePoint) usize {
        var count: usize = 0;
        while (lexer.code_point == quote) {
            count += 1;
            lexer.step();
        }
        return count;
    }

    pub const Error = error{
        UTF8Fail,
        OutOfMemory,
        SyntaxError,
        UnexpectedSyntax,
        JSONStringsMustUseDoubleQuotes,
        ParserError,
    };

    const NumberError = enum {
        leading_zero,
        underscores,
        invalid,
    };

    const DigitRun = struct {
        count: usize = 0,
        magnitude: u64 = 0,
        overflow: bool = false,
        previous_was_digit: bool = false,
    };

    fn digitValue(code_point: CodePoint, base: u8) ?u8 {
        const value: u8 = switch (code_point) {
            '0'...'9' => @intCast(code_point - '0'),
            'a'...'f' => @intCast(code_point - 'a' + 10),
            'A'...'F' => @intCast(code_point - 'A' + 10),
            else => return null,
        };
        return if (value < base) value else null;
    }

    fn scanDigits(lexer: *Lexer, base: u8, initial: DigitRun) DigitRun {
        var result = initial;
        while (true) {
            if (digitValue(lexer.code_point, base)) |digit| {
                result.count += 1;
                result.previous_was_digit = true;
                if (!result.overflow) {
                    const digit_value: u64 = digit;
                    const radix: u64 = base;
                    if (result.magnitude > (std.math.maxInt(u64) - digit_value) / radix) {
                        result.overflow = true;
                    } else {
                        result.magnitude = result.magnitude * radix + digit_value;
                    }
                }
                lexer.step();
                continue;
            }
            if (lexer.code_point == '_') {
                if (!result.previous_was_digit) lexer.number_error = .underscores;
                result.previous_was_digit = false;
                lexer.step();
                continue;
            }
            break;
        }
        if (result.count > 0 and !result.previous_was_digit) lexer.number_error = .underscores;
        return result;
    }

    fn parseNumericLiteralOrDot(lexer: *Lexer) !void {
        const first = lexer.code_point;
        lexer.step();

        if (first == '.') {
            lexer.token = .t_dot;
            return;
        }

        lexer.token = .t_numeric_literal;
        lexer.number_is_integer = true;
        lexer.integer_magnitude = 0;
        lexer.integer_magnitude_overflow = false;
        lexer.number_error = null;

        if (first == '0') {
            const base: ?u8 = switch (lexer.code_point) {
                'b' => 2,
                'o' => 8,
                'x' => 16,
                else => null,
            };
            if (base) |radix| {
                lexer.step();
                const digits = lexer.scanDigits(radix, .{});
                if (digits.count == 0) lexer.number_error = .invalid;
                lexer.integer_magnitude = digits.magnitude;
                lexer.integer_magnitude_overflow = digits.overflow;
                lexer.number = @floatFromInt(digits.magnitude);
                return;
            }
        }

        const integer = lexer.scanDigits(10, .{
            .count = 1,
            .magnitude = @intCast(first - '0'),
            .previous_was_digit = true,
        });
        if (first == '0' and integer.count > 1) lexer.number_error = .leading_zero;

        if (lexer.code_point == '.') {
            lexer.number_is_integer = false;
            lexer.step();
            const fraction = lexer.scanDigits(10, .{});
            if (fraction.count == 0 and lexer.number_error == null) lexer.number_error = .invalid;
        }

        if (lexer.code_point == 'e' or lexer.code_point == 'E') {
            lexer.number_is_integer = false;
            lexer.step();
            if (lexer.code_point == '+' or lexer.code_point == '-') lexer.step();
            const exponent = lexer.scanDigits(10, .{});
            if (exponent.count == 0 and lexer.number_error == null) lexer.number_error = .invalid;
        }

        lexer.integer_magnitude = integer.magnitude;
        lexer.integer_magnitude_overflow = integer.overflow;
        if (lexer.number_is_integer) {
            lexer.number = @floatFromInt(integer.magnitude);
            return;
        }

        const literal = lexer.raw();
        const underscore_count = std.mem.count(u8, literal, "_");
        const text = if (underscore_count == 0) literal else text: {
            const bytes = try lexer.allocator.alloc(u8, literal.len - underscore_count);
            var index: usize = 0;
            for (literal) |byte| {
                if (byte == '_') continue;
                bytes[index] = byte;
                index += 1;
            }
            break :text bytes;
        };
        lexer.number = std.fmt.parseFloat(f64, text) catch number: {
            lexer.number_error = .invalid;
            break :number 0;
        };
    }

    fn scanDateTimeLiteral(lexer: *Lexer) !bool {
        const input = lexer.source.contents;
        const start = lexer.start;

        const kind: DateTimeScanner.Kind = if (hasDigits(input, start, 4) and byteAt(input, start + 4) == '-')
            .date
        else if (hasDigits(input, start, 2) and byteAt(input, start + 2) == ':')
            .time
        else
            return false;

        var scanner = DateTimeScanner{
            .lexer = lexer,
            .input = input,
            .index = start,
        };
        switch (kind) {
            .date => try scanner.scanDate(),
            .time => try scanner.scanTime(false),
        }
        if (!isValueTerminator(byteAt(input, scanner.index))) {
            return scanner.failUnexpectedAfterValue();
        }

        lexer.current = scanner.index;
        lexer.code_point = lexer.nextCodepoint();
        lexer.token = .t_date_time_literal;
        return true;
    }

    pub inline fn expect(self: *Lexer, comptime token: T) !void {
        if (self.token != token) {
            try self.expected(token);
        }

        try self.next();
    }

    pub inline fn expectAssignment(self: *Lexer) !void {
        switch (self.token) {
            .t_equal, .t_colon => {},
            else => {
                try self.expected(T.t_equal);
            },
        }

        self.scan_date_time_literal_next = true;
        try self.next();
    }

    pub fn atStatementEnd(lexer: *const Lexer) bool {
        return lexer.token == .t_end_of_file or lexer.has_newline_before;
    }

    pub fn next(lexer: *Lexer) !void {
        const scan_date_time_literal = lexer.scan_date_time_literal_next;
        lexer.scan_date_time_literal_next = false;
        lexer.has_newline_before = lexer.end == 0;

        while (true) {
            lexer.start = lexer.end;
            lexer.token = T.t_end_of_file;

            switch (lexer.code_point) {
                -1 => {
                    lexer.token = T.t_end_of_file;
                },

                '\r', '\n', 0x2028, 0x2029 => {
                    lexer.step();
                    lexer.has_newline_before = true;
                    continue;
                },

                '\t', ' ' => {
                    lexer.step();
                    continue;
                },

                '[' => {
                    lexer.step();
                    lexer.token = T.t_open_bracket;
                    if (lexer.code_point == ']') {
                        lexer.step();
                        lexer.token = T.t_empty_array;
                    }
                },
                ']' => {
                    lexer.step();
                    lexer.token = T.t_close_bracket;
                },
                '+' => {
                    lexer.step();
                    lexer.token = T.t_plus;
                },
                '-' => {
                    lexer.step();
                    lexer.token = T.t_minus;
                },

                '{' => {
                    lexer.step();
                    lexer.token = T.t_open_brace;
                },
                '}' => {
                    lexer.step();
                    lexer.token = T.t_close_brace;
                },

                '=' => {
                    lexer.step();
                    lexer.token = T.t_equal;
                },
                ':' => {
                    lexer.step();
                    lexer.token = T.t_colon;
                },
                ',' => {
                    lexer.step();
                    lexer.token = T.t_comma;
                },
                ';' => {
                    if (lexer.has_newline_before) {
                        lexer.step();

                        singleLineComment: while (true) {
                            lexer.step();
                            switch (lexer.code_point) {
                                '\r', '\n', 0x2028, 0x2029 => {
                                    break :singleLineComment;
                                },
                                -1 => {
                                    break :singleLineComment;
                                },
                                else => {},
                            }
                        }
                        continue;
                    }

                    try lexer.addDefaultError("Unexpected semicolon");
                },
                '#' => {
                    lexer.step();

                    singleLineComment: while (true) {
                        lexer.step();
                        switch (lexer.code_point) {
                            '\r', '\n', 0x2028, 0x2029 => {
                                break :singleLineComment;
                            },
                            -1 => {
                                break :singleLineComment;
                            },
                            else => {},
                        }
                    }
                    continue;
                },

                // unescaped string
                '\'' => {
                    lexer.step();
                    lexer.string_literal_is_ascii = true;
                    const start = lexer.end;
                    var is_multiline_string_literal = false;

                    if (lexer.code_point == '\'') {
                        lexer.step();
                        // it's a multiline string literal
                        if (lexer.code_point == '\'') {
                            lexer.step();
                            is_multiline_string_literal = true;
                        } else {
                            // it's an empty string
                            lexer.token = T.t_string_literal;
                            lexer.string_literal_slice = lexer.source.contents[start..start];
                            return;
                        }
                    }

                    if (is_multiline_string_literal) {
                        while (true) {
                            switch (lexer.code_point) {
                                -1 => {
                                    try lexer.addDefaultError("Unterminated string");
                                },
                                '\'' => {
                                    const quote_start = lexer.end;
                                    const quote_count = lexer.consumeQuoteRun('\'');
                                    if (quote_count < 3) continue;
                                    if (quote_count > 5) {
                                        lexer.addError(quote_start, "Too many quotes at the end of a multi-line string", .{});
                                        return error.SyntaxError;
                                    }

                                    const content_end = quote_start + quote_count - 3;
                                    const text = lexer.source.contents[start + 2 .. content_end];
                                    var array_list = try std.array_list.Managed(u8).initCapacity(lexer.allocator, text.len);
                                    try lexer.normalizeMultilineLiteral(start + 2, text, @TypeOf(array_list), &array_list);
                                    lexer.token = T.t_string_literal;
                                    lexer.string_literal_slice = try array_list.toOwnedSlice();
                                    lexer.string_literal_is_ascii = false;
                                    return;
                                },
                                else => {},
                            }
                            lexer.step();
                        }
                    } else {
                        while (true) {
                            switch (lexer.code_point) {
                                '\r' => {
                                    if (lexer.current < lexer.source.contents.len and lexer.source.contents[lexer.current] == '\n') {
                                        lexer.addError(lexer.end, "Unterminated string; literal strings cannot contain newlines", .{});
                                    } else {
                                        lexer.addError(lexer.end, "Bare carriage return is not allowed; use \\r\\n or \\n", .{});
                                    }
                                    return error.SyntaxError;
                                },
                                '\n' => {
                                    lexer.addError(lexer.end, "Unterminated string; literal strings cannot contain newlines", .{});
                                    return error.SyntaxError;
                                },
                                -1 => {
                                    try lexer.addDefaultError("Unterminated string");
                                },
                                '\'' => {
                                    lexer.step();
                                    lexer.token = T.t_string_literal;
                                    lexer.string_literal_slice = lexer.source.contents[start .. lexer.end - 1];
                                    return;
                                },
                                0...8, 11, 12, 14...31, 127 => {
                                    lexer.addError(lexer.end, "Control character is not allowed in a literal string: (0x{X:0>2})", .{lexer.code_point});
                                    return error.SyntaxError;
                                },
                                else => if (lexer.code_point > 0x7f) {
                                    lexer.string_literal_is_ascii = false;
                                },
                            }
                            lexer.step();
                        }
                    }
                },
                '"' => {
                    lexer.step();
                    var needs_slow_pass = false;
                    const start = lexer.end;
                    var is_multiline_string_literal = false;
                    lexer.string_literal_is_ascii = true;

                    if (lexer.code_point == '"') {
                        lexer.step();
                        // it's a multiline basic string
                        if (lexer.code_point == '"') {
                            lexer.step();
                            is_multiline_string_literal = true;
                        } else {
                            // it's an empty string
                            lexer.token = T.t_string_literal;
                            lexer.string_literal_slice = lexer.source.contents[start..start];
                            return;
                        }
                    }

                    if (is_multiline_string_literal) {
                        while (true) {
                            switch (lexer.code_point) {
                                -1 => {
                                    try lexer.addDefaultError("Unterminated basic string");
                                },
                                '\\' => {
                                    lexer.step();
                                    needs_slow_pass = true;
                                    if (lexer.code_point == '"') {
                                        lexer.step();
                                        continue;
                                    }
                                },
                                '"' => {
                                    const quote_start = lexer.end;
                                    const quote_count = lexer.consumeQuoteRun('"');
                                    if (quote_count < 3) continue;
                                    if (quote_count > 5) {
                                        lexer.addError(quote_start, "Too many quotes at the end of a multi-line string", .{});
                                        return error.SyntaxError;
                                    }

                                    lexer.token = T.t_string_literal;
                                    lexer.string_literal_slice = lexer.source.contents[start + 2 .. quote_start + quote_count - 3];
                                    break;
                                },
                                else => if (lexer.code_point > 0x7f) {
                                    lexer.string_literal_is_ascii = false;
                                },
                            }
                            lexer.step();
                        }
                    } else {
                        while (true) {
                            switch (lexer.code_point) {
                                '\r' => {
                                    if (lexer.current < lexer.source.contents.len and lexer.source.contents[lexer.current] == '\n') {
                                        lexer.addError(lexer.end, "Unterminated string; newlines must be escaped in basic strings", .{});
                                    } else {
                                        lexer.addError(lexer.end, "Bare carriage return is not allowed; use \\r\\n or \\n", .{});
                                    }
                                    return error.SyntaxError;
                                },
                                '\n' => {
                                    lexer.addError(lexer.end, "Unterminated string; newlines must be escaped in basic strings", .{});
                                    return error.SyntaxError;
                                },
                                -1 => {
                                    try lexer.addDefaultError("Unterminated string");
                                },
                                '\\' => {
                                    lexer.step();
                                    needs_slow_pass = true;
                                    if (lexer.code_point == '"') {
                                        lexer.step();
                                        continue;
                                    }
                                },
                                '"' => {
                                    lexer.step();

                                    lexer.token = T.t_string_literal;
                                    lexer.string_literal_slice = lexer.source.contents[start .. lexer.end - 1];
                                    if (needs_slow_pass) break;
                                    return;
                                },
                                0...8, 11, 12, 14...31, 127 => {
                                    lexer.addError(lexer.end, "Control character must be escaped in a string: (0x{X:0>2})", .{lexer.code_point});
                                    return error.SyntaxError;
                                },
                                else => if (lexer.code_point > 0x7f) {
                                    lexer.string_literal_is_ascii = false;
                                },
                            }
                            lexer.step();
                        }
                    }

                    if (needs_slow_pass or is_multiline_string_literal) {
                        const text = lexer.string_literal_slice;
                        var array_list = try std.array_list.Managed(u8).initCapacity(lexer.allocator, text.len);
                        if (is_multiline_string_literal) {
                            try lexer.decodeEscapeSequences(start + 2, text, true, @TypeOf(array_list), &array_list);
                        } else {
                            try lexer.decodeEscapeSequences(start, text, false, @TypeOf(array_list), &array_list);
                        }
                        lexer.string_literal_slice = try array_list.toOwnedSlice();
                        lexer.string_literal_is_ascii = false;
                    }

                    lexer.token = T.t_string_literal;
                },

                '.', '0'...'9' => {
                    if (scan_date_time_literal and try lexer.scanDateTimeLiteral()) {
                        return;
                    }
                    try lexer.parseNumericLiteralOrDot();
                },

                '@', 'a'...'z', 'A'...'Z', '$', '_' => {
                    lexer.step();
                    while (isIdentifierPart(lexer.code_point)) {
                        lexer.step();
                    }
                    lexer.identifier = lexer.raw();
                    lexer.token = switch (lexer.identifier.len) {
                        3 => special: {
                            if (strings.eqlComptimeIgnoreLen(lexer.identifier, "inf")) {
                                lexer.number = std.math.inf(f64);
                                lexer.number_is_integer = false;
                                lexer.number_error = null;
                                break :special T.t_numeric_literal;
                            }
                            if (strings.eqlComptimeIgnoreLen(lexer.identifier, "nan")) {
                                lexer.number = std.math.nan(f64);
                                lexer.number_is_integer = false;
                                lexer.number_error = null;
                                break :special T.t_numeric_literal;
                            }
                            break :special T.t_identifier;
                        },
                        4 => if (strings.eqlComptimeIgnoreLen(lexer.identifier, "true")) T.t_true else T.t_identifier,
                        5 => if (strings.eqlComptimeIgnoreLen(lexer.identifier, "false")) T.t_false else T.t_identifier,
                        else => T.t_identifier,
                    };
                },

                else => try lexer.unexpected(),
            }
            return;
        }
    }

    fn normalizeMultilineLiteral(lexer: *Lexer, start: usize, text: string, comptime BufType: type, buf_: *BufType) !void {
        var buf = buf_.*;
        defer buf_.* = buf;

        var index: usize = 0;
        if (std.mem.startsWith(u8, text, "\r\n")) {
            index = 2;
        } else if (std.mem.startsWith(u8, text, "\n")) {
            index = 1;
        }

        while (index < text.len) {
            const byte = text[index];
            switch (byte) {
                '\r' => {
                    if (index + 1 >= text.len or text[index + 1] != '\n') {
                        lexer.addError(start + index, "Bare carriage return is not allowed; use \\r\\n or \\n", .{});
                        return error.SyntaxError;
                    }
                    try buf.append('\n');
                    index += 2;
                },
                0...8, 11, 12, 14...31, 127 => {
                    lexer.addError(start + index, "Control character is not allowed in a literal string: (0x{X:0>2})", .{byte});
                    return error.SyntaxError;
                },
                else => {
                    try buf.append(byte);
                    index += 1;
                },
            }
        }
    }

    pub fn decodeEscapeSequences(lexer: *Lexer, start: usize, text: string, comptime allow_multiline: bool, comptime BufType: type, buf_: *BufType) !void {
        var buf = buf_.*;
        defer buf_.* = buf;

        var index: usize = 0;
        if (comptime allow_multiline) {
            if (std.mem.startsWith(u8, text, "\r\n")) {
                index = 2;
            } else if (std.mem.startsWith(u8, text, "\n")) {
                index = 1;
            }
        }

        while (index < text.len) {
            const byte = text[index];
            switch (byte) {
                '\r' => {
                    if (index + 1 >= text.len or text[index + 1] != '\n') {
                        lexer.addError(start + index, "Bare carriage return is not allowed; use \\r\\n or \\n", .{});
                        return error.SyntaxError;
                    }
                    if (comptime !allow_multiline) {
                        lexer.addError(start + index, "Unterminated string; newlines must be escaped in basic strings", .{});
                        return error.SyntaxError;
                    }
                    try buf.append('\n');
                    index += 2;
                },
                '\n' => {
                    if (comptime !allow_multiline) {
                        lexer.addError(start + index, "Unterminated string; newlines must be escaped in basic strings", .{});
                        return error.SyntaxError;
                    }
                    try buf.append('\n');
                    index += 1;
                },
                '\\' => {
                    const escape_start = index;
                    index += 1;
                    if (index == text.len) {
                        lexer.addError(start + escape_start, "Unterminated string", .{});
                        return error.SyntaxError;
                    }

                    const escaped = text[index];
                    index += 1;
                    switch (escaped) {
                        'b' => try buf.append(0x08),
                        't' => try buf.append(0x09),
                        'n' => try buf.append(0x0a),
                        'f' => try buf.append(0x0c),
                        'r' => try buf.append(0x0d),
                        'e' => try buf.append(0x1b),
                        '"' => try buf.append('"'),
                        '\\' => try buf.append('\\'),
                        'x', 'u', 'U' => {
                            const digit_count: usize = switch (escaped) {
                                'x' => 2,
                                'u' => 4,
                                'U' => 8,
                                else => unreachable,
                            };
                            const invalid_message = switch (escaped) {
                                'x' => "A hex escape must be followed by exactly 2 hex digits",
                                'u' => "A Unicode escape must be followed by exactly 4 hex digits",
                                'U' => "A Unicode escape must be followed by exactly 8 hex digits",
                                else => unreachable,
                            };
                            if (digit_count > text.len - index) {
                                lexer.addError(start + escape_start, "{s}", .{invalid_message});
                                return error.SyntaxError;
                            }

                            var value: u32 = 0;
                            for (text[index..][0..digit_count]) |digit_byte| {
                                const digit = digitValue(@intCast(digit_byte), 16) orelse {
                                    lexer.addError(start + escape_start, "{s}", .{invalid_message});
                                    return error.SyntaxError;
                                };
                                value = value * 16 + @as(u32, digit);
                            }
                            index += digit_count;

                            if (escaped != 'x' and (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff))) {
                                lexer.addError(start + escape_start, "Escaped code point must be a Unicode scalar value", .{});
                                return error.SyntaxError;
                            }

                            var encoded: [4]u8 = undefined;
                            const encoded_len = std.unicode.utf8Encode(@intCast(value), &encoded) catch unreachable;
                            try buf.appendSlice(encoded[0..encoded_len]);
                        },
                        '\r' => {
                            if (comptime !allow_multiline) {
                                lexer.addError(start + escape_start, "Invalid escape sequence: (0x0D)", .{});
                                return error.SyntaxError;
                            }
                            if (index == text.len or text[index] != '\n') {
                                lexer.addError(start + escape_start, "Invalid escape sequence: (0x0D)", .{});
                                return error.SyntaxError;
                            }
                            index += 1;
                            while (index < text.len) {
                                switch (text[index]) {
                                    ' ', '\t', '\n' => index += 1,
                                    '\r' => {
                                        if (index + 1 >= text.len or text[index + 1] != '\n') {
                                            lexer.addError(start + index, "Bare carriage return is not allowed; use \\r\\n or \\n", .{});
                                            return error.SyntaxError;
                                        }
                                        index += 2;
                                    },
                                    else => break,
                                }
                            }
                        },
                        '\n' => {
                            if (comptime !allow_multiline) {
                                lexer.addError(start + escape_start, "Invalid escape sequence: (0x0A)", .{});
                                return error.SyntaxError;
                            }
                            while (index < text.len) {
                                switch (text[index]) {
                                    ' ', '\t', '\n' => index += 1,
                                    '\r' => {
                                        if (index + 1 >= text.len or text[index + 1] != '\n') {
                                            lexer.addError(start + index, "Bare carriage return is not allowed; use \\r\\n or \\n", .{});
                                            return error.SyntaxError;
                                        }
                                        index += 2;
                                    },
                                    else => break,
                                }
                            }
                        },
                        else => {
                            if (escaped >= 0x21 and escaped <= 0x7e) {
                                lexer.addError(start + escape_start, "Invalid escape sequence: '{c}'", .{escaped});
                            } else {
                                lexer.addError(start + escape_start, "Invalid escape sequence: (0x{X:0>2})", .{escaped});
                            }
                            return error.SyntaxError;
                        },
                    }
                },
                0...8, 11, 12, 14...31, 127 => {
                    lexer.addError(start + index, "Control character must be escaped in a string: (0x{X:0>2})", .{byte});
                    return error.SyntaxError;
                },
                else => {
                    try buf.append(byte);
                    index += 1;
                },
            }
        }
    }

    pub fn expected(self: *Lexer, token: T) !void {
        try self.expectedString(@as(string, @tagName(token)));
    }

    pub fn unexpected(lexer: *Lexer) !void {
        const found = finder: {
            lexer.start = @min(lexer.start, lexer.end);

            if (lexer.start == lexer.source.contents.len) {
                break :finder "end of file";
            } else {
                break :finder lexer.raw();
            }
        };

        try lexer.addRangeError(lexer.range(), "Unexpected {s}", .{found});
    }

    pub fn expectedString(self: *Lexer, text: string) !void {
        const found = finder: {
            if (self.source.contents.len != self.start) {
                break :finder self.raw();
            } else {
                break :finder "end of file";
            }
        };

        try self.addRangeError(self.range(), "Expected {s} but found {s}", .{ text, found });
        return error.SyntaxError;
    }

    pub fn range(self: *Lexer) logger.Range {
        return logger.Range{
            .loc = logger.usize2Loc(self.start),
            .len = std.math.lossyCast(i32, self.end - self.start),
        };
    }

    pub fn init(log: *logger.Log, source: logger.Source, allocator: std.mem.Allocator, redact_logs: bool) !Lexer {
        var lex = Lexer{
            .log = log,
            .source = source,
            .prev_error_loc = logger.Loc.Empty,
            .allocator = allocator,
            .should_redact_logs = redact_logs,
        };
        try lex.source.normalizeText(allocator);
        lex.step();
        try lex.next();

        return lex;
    }

    pub inline fn toString(lexer: *Lexer, loc_: logger.Loc) js_ast.Expr {
        if (lexer.string_literal_is_ascii) {
            return js_ast.Expr.init(js_ast.E.String, js_ast.E.String{ .data = lexer.string_literal_slice }, loc_);
        }

        return js_ast.Expr.init(
            js_ast.E.String,
            .{ .data = lexer.string_literal_slice },
            loc_,
        );
    }

    pub fn raw(self: *Lexer) []const u8 {
        return self.source.contents[self.start..self.end];
    }
};

const DateTimeScanner = struct {
    const Kind = enum { date, time };

    lexer: *Lexer,
    input: []const u8,
    index: usize,

    fn fail(scanner: *DateTimeScanner, comptime message: []const u8) Lexer.Error {
        scanner.lexer.addError(scanner.index, "{s}", .{message});
        return error.SyntaxError;
    }

    fn failUnexpectedAfterValue(scanner: *DateTimeScanner) Lexer.Error {
        scanner.lexer.addError(scanner.index, "Unexpected character after a value: '{c}'", .{scanner.input[scanner.index]});
        return error.SyntaxError;
    }

    fn readDigits(scanner: *DateTimeScanner, comptime count: usize, comptime message: []const u8) !u16 {
        if (!hasDigits(scanner.input, scanner.index, count)) {
            return scanner.fail(message);
        }

        var value: u16 = 0;
        for (scanner.input[scanner.index..][0..count]) |digit| {
            value = value * 10 + digit - '0';
        }
        scanner.index += count;
        return value;
    }

    fn expectByte(scanner: *DateTimeScanner, expected: u8, comptime message: []const u8) !void {
        if (byteAt(scanner.input, scanner.index) != expected) {
            return scanner.fail(message);
        }
        scanner.index += 1;
    }

    fn scanDate(scanner: *DateTimeScanner) !void {
        const year = try scanner.readDigits(4, "Invalid date: expected a 4-digit year");
        try scanner.expectByte('-', "Invalid date: expected '-' between year and month");
        const month = try scanner.readDigits(2, "Invalid date: expected a 2-digit month");
        try scanner.expectByte('-', "Invalid date: expected '-' between month and day");
        const day = try scanner.readDigits(2, "Invalid date: expected a 2-digit day");

        if (month < 1 or month > 12) {
            return scanner.fail("Invalid date: month must be between 01 and 12");
        }
        if (day < 1 or day > daysInMonth(year, @intCast(month))) {
            return scanner.fail("Invalid date: day is out of range for the month");
        }

        switch (byteAt(scanner.input, scanner.index) orelse return) {
            'T', 't' => {
                scanner.index += 1;
                try scanner.scanTime(true);
            },
            ' ' => {
                const time_start = scanner.index + 1;
                if (hasDigits(scanner.input, time_start, 2) and byteAt(scanner.input, time_start + 2) == ':') {
                    scanner.index = time_start;
                    try scanner.scanTime(true);
                }
            },
            else => {},
        }
    }

    fn scanTime(scanner: *DateTimeScanner, allow_offset: bool) !void {
        const hour = try scanner.readDigits(2, "Invalid time: expected 2-digit hours");
        try scanner.expectByte(':', "Invalid time: expected ':' between hours and minutes");
        const minute = try scanner.readDigits(2, "Invalid time: expected 2-digit minutes");

        var second: ?u16 = null;
        if (byteAt(scanner.input, scanner.index) == ':') {
            scanner.index += 1;
            second = try scanner.readDigits(2, "Invalid time: expected 2-digit seconds");

            if (byteAt(scanner.input, scanner.index) == '.') {
                scanner.index += 1;
                const fraction_start = scanner.index;
                while (byteAt(scanner.input, scanner.index)) |byte| {
                    if (byte < '0' or byte > '9') break;
                    scanner.index += 1;
                }
                if (scanner.index == fraction_start) {
                    return scanner.fail("Invalid time: expected at least one digit of fractional seconds");
                }
            }
        }

        if (hour > 23) {
            return scanner.fail("Invalid time: hours must be between 00 and 23");
        }
        if (minute > 59) {
            return scanner.fail("Invalid time: minutes must be between 00 and 59");
        }
        if (second) |value| {
            if (value > 60) {
                return scanner.fail("Invalid time: seconds must be between 00 and 60");
            }
        }

        if (!allow_offset) return;
        switch (byteAt(scanner.input, scanner.index) orelse return) {
            'Z', 'z' => scanner.index += 1,
            '+', '-' => {
                scanner.index += 1;
                const offset_hour = try scanner.readDigits(2, "Invalid date-time offset: expected 2-digit hours");
                try scanner.expectByte(':', "Invalid date-time offset: expected ':' between hours and minutes");
                const offset_minute = try scanner.readDigits(2, "Invalid date-time offset: expected 2-digit minutes");
                if (offset_hour > 23) {
                    return scanner.fail("Invalid date-time offset: hours must be between 00 and 23");
                }
                if (offset_minute > 59) {
                    return scanner.fail("Invalid date-time offset: minutes must be between 00 and 59");
                }
            },
            else => {},
        }
    }
};

fn byteAt(input: []const u8, index: usize) ?u8 {
    return if (index < input.len) input[index] else null;
}

fn isValueTerminator(byte: ?u8) bool {
    return switch (byte orelse return true) {
        ' ', '\t', '\r', '\n', '#', ',', ']', '}' => true,
        else => false,
    };
}

fn hasDigits(input: []const u8, start: usize, count: usize) bool {
    if (start > input.len or count > input.len - start) return false;
    for (input[start..][0..count]) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub fn isIdentifierPart(code_point: CodePoint) bool {
    return switch (code_point) {
        '0'...'9',
        'a'...'z',
        'A'...'Z',
        '$',
        '_',
        '-',
        ':',
        => true,
        else => false,
    };
}

pub fn isLatin1Identifier(comptime Buffer: type, name: Buffer) bool {
    if (name.len == 0) return false;

    switch (name[0]) {
        'a'...'z',
        'A'...'Z',
        '$',
        '1'...'9',
        '_',
        '-',
        => {},
        else => return false,
    }

    if (name.len > 0) {
        for (name[1..]) |c| {
            switch (c) {
                '0'...'9',
                'a'...'z',
                'A'...'Z',
                '$',
                '_',
                '-',
                => {},
                else => return false,
            }
        }
    }

    return true;
}

inline fn float64(num: anytype) f64 {
    return @as(f64, @floatFromInt(num));
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const CodePoint = bun.CodePoint;
const js_ast = bun.ast;
const logger = bun.logger;
const strings = bun.strings;
