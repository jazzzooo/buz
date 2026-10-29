const ExpansionVariant = struct {
    start: usize = 0,
    end: usize = 0,
};

const Token = union(enum) {
    open: ExpansionVariants,
    comma,
    text: SmolStr,
    close,
    eof,
    const Tag = @typeInfo(Token).@"union".tag_type.?;

    const ExpansionVariants = struct {
        idx: usize = 0,
        end: usize = 0,
    };

    pub fn toText(self: *Token) SmolStr {
        return switch (self.*) {
            .open => SmolStr.fromChar('{'),
            .comma => SmolStr.fromChar(','),
            .text => |txt| txt,
            .close => SmolStr.fromChar('}'),
            .eof => SmolStr.empty(),
        };
    }
};

pub const AST = struct {
    pub const Atom = union(enum) {
        text: SmolStr,
        expansion: Expansion,
    };

    const Group = struct {
        bubble_up: ?*Group = null,
        bubble_up_next: usize = 0,
        atoms: union(enum) { single: Atom, many: []Atom },
    };

    const Expansion = struct {
        variants: []AST.Group,
    };
};

const inline_brace_capacity = 10;
const max_expansions = 65_536;

pub const Error = bun.OOM || error{
    UnexpectedToken,
    TooManyBraces,
    TooManyExpansions,
};

pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Out of memory while expanding braces",
        error.UnexpectedToken => "Unexpected token while expanding braces",
        error.TooManyBraces => "Too many braces in brace expansion",
        error.TooManyExpansions => "Too many brace expansions",
    };
}

/// `out` is preallocated by using the result from `calculateExpandedAmount`
pub fn expand(
    allocator: Allocator,
    tokens: []Token,
    out: []std.array_list.Managed(u8),
    contains_nested: bool,
) Error!void {
    var expander: Expander = .{ .out = out, .stack_check = bun.StackCheck.init() };
    if (!contains_nested) {
        var expansions_table = std.array_list.Managed(ExpansionVariant).init(allocator);
        defer expansions_table.deinit();
        try buildExpansionTable(tokens, &expansions_table);
        return expander.expandFlat(tokens, expansions_table.items, 0, 0, tokens.len);
    }

    var parser = Parser.init(tokens, allocator);
    var root_node = try parser.parse();
    try expander.expandNested(&root_node, 0, 0);
}

const Expander = struct {
    out: []std.array_list.Managed(u8),
    next_key: usize = 1,
    stack_check: bun.StackCheck,

    fn copyPrefix(this: *Expander, key: usize, length: usize) bun.OOM!usize {
        const next = this.next_key;
        try this.out[next].appendSlice(this.out[key].items[0..length]);
        this.next_key += 1;
        return next;
    }

    fn expandNested(this: *Expander, root: *AST.Group, out_key: usize, start: usize) Error!void {
        if (!this.stack_check.isSafeToRecurse()) return error.TooManyBraces;

        const atoms = switch (root.atoms) {
            .single => |*atom| atom[0..1],
            .many => |atoms| atoms,
        };
        for (atoms[start..], start..) |atom, i| {
            switch (atom) {
                .text => |txt| try this.out[out_key].appendSlice(txt.slice()),
                .expansion => |expansion| {
                    const length = this.out[out_key].items.len;
                    for (expansion.variants, 0..) |*group, j| {
                        group.bubble_up = root;
                        group.bubble_up_next = i + 1;
                        const new_key = if (j == 0) out_key else try this.copyPrefix(out_key, length);
                        try this.expandNested(group, new_key, 0);
                    }
                    return;
                },
            }
        }

        if (root.bubble_up) |parent| {
            return this.expandNested(parent, out_key, root.bubble_up_next);
        }
    }

    fn expandFlat(
        this: *Expander,
        tokens: []const Token,
        expansion_table: []const ExpansionVariant,
        out_key: usize,
        start: usize,
        end: usize,
    ) Error!void {
        if (!this.stack_check.isSafeToRecurse()) return error.TooManyBraces;

        var key = out_key;
        var index = start;
        while (index < end) : (index += 1) {
            switch (tokens[index]) {
                .text => |txt| try this.out[key].appendSlice(txt.slice()),
                .open => |range| {
                    const variants = expansion_table[range.idx..range.end];
                    const close = variants[variants.len - 1].end;
                    const length = this.out[key].items.len;
                    for (variants, 0..) |variant, i| {
                        const new_key = if (i == 0) key else try this.copyPrefix(key, length);
                        for (tokens[variant.start..variant.end]) |token| {
                            try this.out[new_key].appendSlice(token.text.slice());
                        }
                        if (i + 1 == variants.len) {
                            key = new_key;
                            index = close;
                        } else {
                            try this.expandFlat(tokens, expansion_table, new_key, close + 1, end);
                        }
                    }
                },
                else => {},
            }
        }
    }
};

pub const Parser = struct {
    current: usize = 0,
    tokens: []const Token,
    alloc: Allocator,
    stack_check: bun.StackCheck,

    pub fn init(tokens: []const Token, alloc: Allocator) Parser {
        return .{
            .tokens = tokens,
            .alloc = alloc,
            .stack_check = bun.StackCheck.init(),
        };
    }

    pub fn parse(self: *Parser) Error!AST.Group {
        var nodes = std.array_list.Managed(AST.Atom).init(self.alloc);
        while (!self.match(.eof)) {
            try nodes.append(try self.parseAtom() orelse break);
        }

        if (nodes.items.len == 1) {
            return .{ .atoms = .{ .single = nodes.items[0] } };
        } else {
            return .{ .atoms = .{ .many = nodes.items[0..] } };
        }
    }

    fn parseAtom(self: *Parser) Error!?AST.Atom {
        if (!self.stack_check.isSafeToRecurse()) return error.TooManyBraces;
        switch (self.advance()) {
            .open => {
                const expansion_ptr = try self.parseExpansion();
                return .{ .expansion = expansion_ptr };
            },
            .text => |txt| return .{ .text = txt },
            .eof => return null,
            .close, .comma => return error.UnexpectedToken,
        }
    }

    fn parseExpansion(self: *Parser) Error!AST.Expansion {
        var variants = std.array_list.Managed(AST.Group).init(self.alloc);
        while (!self.match_any(&.{ .close, .eof })) {
            if (self.match(.eof)) break;
            var group = std.array_list.Managed(AST.Atom).init(self.alloc);
            var close = false;
            while (!self.match(.eof)) {
                if (self.match(.close)) {
                    close = true;
                    break;
                }
                if (self.match(.comma)) break;
                const group_atom = try self.parseAtom() orelse break;
                try group.append(group_atom);
            }
            if (group.items.len == 1) {
                try variants.append(.{ .atoms = .{ .single = group.items[0] } });
            } else {
                try variants.append(.{ .atoms = .{ .many = group.items[0..] } });
            }
            if (close) break;
        }

        return .{ .variants = variants.items[0..] };
    }

    fn advance(self: *Parser) Token {
        if (!self.is_at_end()) {
            self.current += 1;
        }
        return if (self.current > 0) self.prev() else self.peek();
    }

    fn is_at_end(self: *Parser) bool {
        return self.peek() == .eof;
    }

    /// Consumes token if it matches
    fn match(self: *Parser, toktag: Token.Tag) bool {
        if (@as(Token.Tag, self.peek()) == toktag) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn match_any(self: *Parser, comptime toktags: []const Token.Tag) bool {
        const peeked = @as(Token.Tag, self.peek());
        inline for (toktags) |tag| {
            if (peeked == tag) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }

    fn prev(self: *Parser) Token {
        return self.tokens[self.current - 1];
    }
};

pub fn calculateExpandedAmount(tokens: []const Token) error{TooManyExpansions}!usize {
    const StackEntry = struct {
        segment_product: usize = 1,
        accumulator: usize = 0,
    };
    var nested_brace_stack = bun.SmallList(StackEntry, inline_brace_capacity){};
    defer nested_brace_stack.deinit(bun.default_allocator);
    var current: StackEntry = .{};
    var has_expansion = false;

    for (tokens) |tok| {
        switch (tok) {
            .open => {
                nested_brace_stack.append(bun.default_allocator, current);
                current = .{};
                has_expansion = true;
            },
            .comma => {
                current.accumulator +|= current.segment_product;
                current.segment_product = 1;
            },
            .close => {
                const total = current.accumulator +| current.segment_product;
                current = nested_brace_stack.pop().?;
                current.segment_product *|= total;
            },
            else => continue,
        }
        if (current.accumulator +| current.segment_product > max_expansions) return error.TooManyExpansions;
    }

    return if (has_expansion) current.segment_product else 0;
}

fn buildExpansionTable(tokens: []Token, table: *std.array_list.Managed(ExpansionVariant)) !void {
    const BraceState = struct {
        tok_idx: usize,
        prev_tok_end: usize,
    };
    var brace_stack = bun.SmallList(BraceState, inline_brace_capacity){};
    defer brace_stack.deinit(bun.default_allocator);

    for (tokens, 0..) |*token, i| {
        switch (token.*) {
            .open => {
                token.open.idx = table.items.len;
                brace_stack.append(bun.default_allocator, .{
                    .tok_idx = i,
                    .prev_tok_end = i,
                });
            },
            .close => {
                const top = brace_stack.pop().?;
                try table.append(.{
                    .end = i,
                    .start = top.prev_tok_end + 1,
                });
                tokens[top.tok_idx].open.end = table.items.len;
            },
            .comma => {
                var top = brace_stack.lastMut().?;

                try table.append(.{
                    .end = i,
                    .start = top.prev_tok_end + 1,
                });

                top.prev_tok_end = i;
            },
            else => {},
        }
    }

    if (bun.Environment.allow_assert) {
        for (table.items) |variant| {
            assert(variant.start != 0 and variant.end != 0);
        }
    }
}

pub const Lexer = NewLexer(.ascii);

pub fn NewLexer(comptime encoding: Encoding) type {
    const Chars = NewChars(encoding);
    return struct {
        chars: Chars,
        alloc: Allocator,
        tokens: ArrayList(Token),
        contains_nested: bool = false,

        pub const Output = struct {
            tokens: ArrayList(Token),
            contains_nested: bool,
        };

        pub fn tokenize(alloc: Allocator, src: []const u8) BraceLexerError!Output {
            var this = @This(){
                .chars = Chars.init(src),
                .tokens = ArrayList(Token).init(alloc),
                .alloc = alloc,
            };

            const contains_nested = try this.tokenize_impl();

            return .{
                .tokens = this.tokens,
                .contains_nested = contains_nested,
            };
        }

        // FIXME: implement rollback on invalid brace
        fn tokenize_impl(self: *@This()) BraceLexerError!bool {
            // Unclosed brace expansion algorithm
            // {hi,hey
            // *xx*xxx

            // {hi, hey
            // *xxx$

            // {hi,{a,b} sdkjfs}
            // *xx**x*x*$

            // 00000100000000000010000000000000
            // echo {foo,bar,baz,{hi,hey},oh,no
            // xxxxx*xxx*xxx*xxx**xx*xxx**xx*xx
            //
            // {hi,h{ey }
            // *xx*x*xx$
            //
            // - Replace chars with special tokens
            // - If unclosed or encounter bad token:
            //   - Start at beginning of brace, replacing special tokens back with
            //     chars, skipping over actual closed braces
            var brace_stack = bun.SmallList(usize, inline_brace_capacity){};
            defer brace_stack.deinit(bun.default_allocator);

            while (true) {
                const input = self.eat() orelse break;
                const char = input.char;
                const escaped = input.escaped;

                if (!escaped) {
                    switch (char) {
                        '{' => {
                            brace_stack.append(bun.default_allocator, self.tokens.items.len);
                            try self.tokens.append(.{ .open = .{} });
                            continue;
                        },
                        '}' => {
                            if (brace_stack.len() > 0) {
                                _ = brace_stack.pop();
                                try self.tokens.append(.close);
                                continue;
                            }
                        },
                        ',' => {
                            if (brace_stack.len() > 0) {
                                try self.tokens.append(.comma);
                                continue;
                            }
                        },
                        else => {},
                    }
                }

                // if (char_stack.push(char) == char_stack.Error.StackFull) {
                //     try self.app
                // }
                try self.appendChar(char);
            }

            // Unclosed braces
            while (brace_stack.len() > 0) {
                const top_idx = brace_stack.pop().?;
                self.rollbackBraces(top_idx);
            }

            try self.flattenTokens();
            try self.tokens.append(.eof);

            return self.contains_nested;
        }

        fn flattenTokens(self: *@This()) Allocator.Error!void {
            if (self.tokens.items.len == 0) return;
            var brace_count: usize = if (self.tokens.items[0] == .open) 1 else 0;
            var i: usize = 0;
            var j: usize = 1;
            while (i < self.tokens.items.len and j < self.tokens.items.len) {
                var itok = &self.tokens.items[i];
                var jtok = &self.tokens.items[j];

                if (itok.* == .text and jtok.* == .text) {
                    try itok.text.appendSlice(self.alloc, jtok.toText().slice());
                    _ = self.tokens.orderedRemove(j);
                } else {
                    if (jtok.* == .close) {
                        brace_count -= 1;
                    } else if (jtok.* == .open) {
                        brace_count += 1;
                        if (brace_count > 1) {
                            self.contains_nested = true;
                        }
                    }
                    i += 1;
                    j += 1;
                }
            }
        }

        fn rollbackBraces(self: *@This(), starting_idx: usize) void {
            if (bun.Environment.allow_assert) {
                const first = &self.tokens.items[starting_idx];
                assert(first.* == .open);
            }

            var braces: usize = 0;

            self.replaceTokenWithString(starting_idx);
            var i = starting_idx + 1;
            while (i < self.tokens.items.len) : (i += 1) {
                if (braces > 0) {
                    switch (self.tokens.items[i]) {
                        .open => {
                            braces += 1;
                        },
                        .close => {
                            braces -= 1;
                        },
                        else => {},
                    }
                    continue;
                }

                switch (self.tokens.items[i]) {
                    .open => {
                        braces += 1;
                        continue;
                    },
                    .close, .comma, .text => {
                        self.replaceTokenWithString(i);
                    },
                    .eof => {},
                }
            }
        }

        fn replaceTokenWithString(self: *@This(), token_idx: usize) void {
            var tok = &self.tokens.items[token_idx];
            const tok_text = tok.toText();
            tok.* = .{ .text = tok_text };
        }

        fn appendChar(self: *@This(), char: Chars.CodepointType) Allocator.Error!void {
            if (self.tokens.items.len > 0) {
                var last = &self.tokens.items[self.tokens.items.len - 1];
                if (last.* == .text) {
                    if (comptime encoding == .ascii) {
                        try last.text.appendChar(self.alloc, char);
                        return;
                    }
                    var buf = [4]u8{ 0, 0, 0, 0 };
                    const len = bun.strings.encodeWTF8Rune(&buf, @bitCast(char));
                    try last.text.appendSlice(self.alloc, buf[0..len]);
                    return;
                }
            }

            if (comptime encoding == .ascii) {
                try self.tokens.append(.{
                    .text = try SmolStr.fromSlice(self.alloc, &[_]u8{char}),
                });
            } else {
                var buf = [4]u8{ 0, 0, 0, 0 };
                const len = bun.strings.encodeWTF8Rune(&buf, @bitCast(char));
                try self.tokens.append(.{
                    .text = try SmolStr.fromSlice(self.alloc, buf[0..len]),
                });
            }
        }

        fn eat(self: *@This()) ?Chars.InputChar {
            return self.chars.eat();
        }

        fn read_char(self: *@This()) ?Chars.InputChar {
            return self.chars.read_char();
        }
    };
}

test Lexer {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const TestCase = struct { []const u8, []const Token };
    const test_cases: []const TestCase = &[_]TestCase{
        .{
            "{}",
            &[_]Token{ .{ .open = .{} }, .close, .eof },
        },
        .{
            "{foo}",
            &[_]Token{ .{ .open = .{} }, .{ .text = try SmolStr.fromSlice(arena.allocator(), "foo") }, .close, .eof },
        },
    };

    for (test_cases) |test_case| {
        const src, const expected = test_case;
        // NOTE: don't use arena here so that we can test for memory leaks
        var result = try Lexer.tokenize(t.allocator, src);
        defer result.tokens.deinit();
        try t.expectEqualSlices(
            Token,
            expected,
            result.tokens.items,
        );
    }
}

const SmolStr = @import("../string/string.zig").SmolStr;

const CharIterator = @import("./CharIterator.zig");
const Encoding = CharIterator.StringEncoding;
const NewChars = CharIterator.ShellCharIter;

const bun = @import("bun");
const assert = bun.assert;

const std = @import("std");
const t = std.testing;
const ArrayList = std.array_list.Managed;

const Allocator = std.mem.Allocator;
const BraceLexerError = Allocator.Error;
