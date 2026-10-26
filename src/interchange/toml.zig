pub const TOML = struct {
    lexer: Lexer,
    log: *logger.Log,
    allocator: std.mem.Allocator,
    stack_check: bun.StackCheck,

    pub fn init(allocator: std.mem.Allocator, source_: logger.Source, log: *logger.Log, redact_logs: bool) !TOML {
        return TOML{
            .lexer = try Lexer.init(log, source_, allocator, redact_logs),
            .allocator = allocator,
            .log = log,
            .stack_check = bun.StackCheck.init(),
        };
    }

    pub inline fn source(p: *const TOML) *const logger.Source {
        return &p.lexer.source;
    }

    pub fn e(_: *TOML, t: anytype, loc: logger.Loc) Expr {
        const Type = @TypeOf(t);
        if (@typeInfo(Type) == .pointer) {
            return Expr.init(std.meta.Child(Type), t.*, loc);
        } else {
            return Expr.init(Type, t, loc);
        }
    }

    const Rope = js_ast.E.Object.Rope;
    const AssignmentContext = enum { document, inline_table };

    pub fn parseKeySegment(p: *TOML) anyerror!?Expr {
        const loc = p.lexer.loc();

        switch (p.lexer.token) {
            .t_string_literal => {
                const str = p.lexer.toString(loc);
                try p.lexer.next();
                return str;
            },
            .t_identifier => {
                const str = E.String{ .data = p.lexer.identifier };
                try p.lexer.next();
                return p.e(str, loc);
            },
            .t_false => {
                try p.lexer.next();
                return p.e(
                    E.String{
                        .data = "false",
                    },
                    loc,
                );
            },
            .t_true => {
                try p.lexer.next();
                return p.e(
                    E.String{
                        .data = "true",
                    },
                    loc,
                );
            },
            // what we see as a number here could actually be a string
            .t_numeric_literal => {
                const literal = p.lexer.raw();
                try p.lexer.next();
                return p.e(E.String{ .data = literal }, loc);
            },

            else => return null,
        }
    }

    pub fn parseKey(p: *TOML, allocator: std.mem.Allocator) anyerror!*Rope {
        var rope = try allocator.create(Rope);
        const head = rope;
        rope.* = .{
            .head = (try p.parseKeySegment()) orelse {
                try p.lexer.expectedString("key");
                return error.SyntaxError;
            },
            .next = null,
        };
        while (p.lexer.token == .t_dot) {
            try p.lexer.next();

            rope = try rope.append((try p.parseKeySegment()) orelse break, allocator);
        }

        return head;
    }

    pub fn parse(source_: *const logger.Source, log: *logger.Log, allocator: std.mem.Allocator, redact_logs: bool) !Expr {
        switch (source_.contents.len) {
            // This is to be consisntent with how disabled JS files are handled
            0 => {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = Expr.init(E.Object, E.Object{}, logger.Loc.Empty).data };
            },
            else => {},
        }

        var parser = try TOML.init(allocator, source_.*, log, redact_logs);

        return try parser.runParser();
    }

    fn runParser(p: *TOML) anyerror!Expr {
        var root = p.e(E.Object{}, p.lexer.loc());
        var head = root.data.e_object;

        var stack_buffer: [6]Rope = undefined;
        var stack: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_buffer), p.allocator);
        const key_allocator = stack.allocator();

        while (true) {
            const loc = p.lexer.loc();
            switch (p.lexer.token) {
                .t_end_of_file => {
                    return root;
                },
                .t_open_bracket => {
                    try p.lexer.next();
                    const is_array_of_tables = p.lexer.token == .t_open_bracket;
                    if (is_array_of_tables) try p.lexer.next();
                    const key = try p.parseKey(key_allocator);

                    try p.lexer.expect(.t_close_bracket);
                    if (is_array_of_tables) try p.lexer.expect(.t_close_bracket);
                    if (!p.lexer.atStatementEnd()) {
                        try p.lexer.expectedString("line break");
                    }

                    if (is_array_of_tables) {
                        var array = root.data.e_object.getOrPutArray(key, p.allocator) catch |err| {
                            switch (err) {
                                error.Clobber => {
                                    try p.lexer.addDefaultError("Cannot overwrite table array");
                                    return error.SyntaxError;
                                },
                                else => return err,
                            }
                        };
                        const new_head = p.e(E.Object{}, loc);
                        try array.data.e_array.push(p.allocator, new_head);
                        head = new_head.data.e_object;
                    } else {
                        const parent_object = root.data.e_object.getOrPutObject(key, p.allocator) catch |err| {
                            switch (err) {
                                error.Clobber => {
                                    try p.lexer.addDefaultError("Table already defined");
                                    return error.SyntaxError;
                                },
                                else => return err,
                            }
                        };
                        head = parent_object.data.e_object;
                    }
                    stack.fixed_buffer_allocator.reset();
                },
                else => {
                    try p.parseAssignment(head, key_allocator, .document);
                    stack.fixed_buffer_allocator.reset();
                },
            }
        }
    }

    pub fn parseAssignment(p: *TOML, obj: *E.Object, allocator: std.mem.Allocator, comptime context: AssignmentContext) anyerror!void {
        const rope = try p.parseKey(allocator);
        const rope_end = p.lexer.start;

        const is_array = p.lexer.token == .t_empty_array;
        if (is_array) {
            try p.lexer.next();
        }

        try p.lexer.expectAssignment();
        if (!is_array) {
            const value = try p.parseValue();
            if (comptime context == .document) {
                if (!p.lexer.atStatementEnd()) {
                    return p.lexer.addDefaultError("Expected a newline or end of file after a key/value pair");
                }
            }
            obj.setRope(rope, p.allocator, value) catch |err| {
                switch (err) {
                    error.Clobber => {
                        const loc = rope.head.loc;
                        assert(loc.start > 0);
                        const start: u32 = @intCast(loc.start);
                        const key_name = std.mem.trimEnd(u8, p.source().contents[start..rope_end], &std.ascii.whitespace);
                        p.lexer.addError(start, "Cannot redefine key '{s}'", .{key_name});
                        return error.SyntaxError;
                    },
                    else => return err,
                }
            };
        }
    }

    pub fn parseValue(p: *TOML) anyerror!Expr {
        if (!p.stack_check.isSafeToRecurse()) {
            try bun.throwStackOverflow();
        }

        const loc = p.lexer.loc();

        switch (p.lexer.token) {
            .t_false => {
                try p.lexer.next();

                return p.e(E.Boolean{
                    .value = false,
                }, loc);
            },
            .t_true => {
                try p.lexer.next();
                return p.e(E.Boolean{
                    .value = true,
                }, loc);
            },
            .t_string_literal => {
                const result = p.lexer.toString(loc);
                try p.lexer.next();
                return result;
            },
            .t_identifier => {
                const str: E.String = E.String{ .data = p.lexer.identifier };

                try p.lexer.next();
                return p.e(str, loc);
            },
            .t_numeric_literal => {
                const value = try p.parseNumber(.positive);
                try p.lexer.next();
                return p.e(E.Number{ .value = value }, loc);
            },
            .t_date_time_literal => {
                const value = p.lexer.raw();
                try p.lexer.next();
                return p.e(E.String{ .data = value }, loc);
            },
            .t_minus => {
                try p.lexer.next();
                if (p.lexer.token != .t_numeric_literal) try p.lexer.expected(.t_numeric_literal);
                const value = try p.parseNumber(.negative);
                try p.lexer.next();
                return p.e(E.Number{ .value = value }, loc);
            },
            .t_plus => {
                try p.lexer.next();
                if (p.lexer.token != .t_numeric_literal) try p.lexer.expected(.t_numeric_literal);
                const value = try p.parseNumber(.positive);
                try p.lexer.next();
                return p.e(E.Number{ .value = value }, loc);
            },
            .t_open_brace => {
                try p.lexer.next();
                var is_single_line = !p.lexer.has_newline_before;
                var stack_buffer: [6]Rope = undefined;
                var stack: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_buffer), p.allocator);
                const key_allocator = stack.allocator();
                const expr = p.e(E.Object{}, loc);
                const obj = expr.data.e_object;

                while (p.lexer.token != .t_close_brace) {
                    if (obj.properties.len > 0) {
                        if (p.lexer.has_newline_before) {
                            is_single_line = false;
                        }
                        if (!try p.parseMaybeTrailingComma(.t_close_brace)) {
                            break;
                        }
                        if (p.lexer.has_newline_before) {
                            is_single_line = false;
                        }
                    }
                    try p.parseAssignment(obj, key_allocator, .inline_table);
                    stack.fixed_buffer_allocator.reset();
                }

                if (p.lexer.has_newline_before) {
                    is_single_line = false;
                }
                try p.lexer.expect(.t_close_brace);
                return expr;
            },
            .t_empty_array => {
                try p.lexer.next();
                return p.e(E.Array{}, loc);
            },
            .t_open_bracket => {
                p.lexer.scan_date_time_literal_next = true;
                try p.lexer.next();
                var is_single_line = !p.lexer.has_newline_before;
                const array_ = p.e(E.Array{}, loc);
                var array = array_.data.e_array;
                const allocator = p.allocator;
                while (p.lexer.token != .t_close_bracket) {
                    if (array.items.len > 0) {
                        if (p.lexer.has_newline_before) {
                            is_single_line = false;
                        }

                        p.lexer.scan_date_time_literal_next = true;
                        if (!try p.parseMaybeTrailingComma(.t_close_bracket)) {
                            break;
                        }

                        if (p.lexer.has_newline_before) {
                            is_single_line = false;
                        }
                    }

                    try array.push(allocator, try p.parseValue());
                }

                if (p.lexer.has_newline_before) {
                    is_single_line = false;
                }
                try p.lexer.expect(.t_close_bracket);
                return array_;
            },
            else => {
                try p.lexer.unexpected();
                return error.SyntaxError;
            },
        }
    }

    const NumberSign = enum { positive, negative };

    fn parseNumber(p: *TOML, sign: NumberSign) anyerror!f64 {
        if (p.lexer.number_error) |number_error| {
            const message = switch (number_error) {
                .leading_zero => "Leading zeros are not allowed in numbers",
                .underscores => "Underscores in numbers must be surrounded by digits",
                .invalid => "Invalid number",
            };
            p.lexer.addError(p.lexer.start, "{s}", .{message});
            return error.SyntaxError;
        }

        if (!p.lexer.number_is_integer) {
            return if (sign == .negative) -p.lexer.number else p.lexer.number;
        }

        const magnitude = p.lexer.integer_magnitude;
        const signed_limit: u64 = if (sign == .negative)
            @as(u64, @intCast(std.math.maxInt(i64))) + 1
        else
            std.math.maxInt(i64);
        if (p.lexer.integer_magnitude_overflow or magnitude > signed_limit) {
            p.lexer.addError(p.lexer.start, "Integer is outside the 64-bit signed range", .{});
            return error.SyntaxError;
        }
        if (magnitude > 9007199254740991) {
            p.lexer.addError(p.lexer.start, "Integer cannot be losslessly represented as a JavaScript number; it must be within +/-(2^53 - 1)", .{});
            return error.SyntaxError;
        }

        if (magnitude == 0) return 0;
        const value: f64 = @floatFromInt(magnitude);
        return if (sign == .negative) -value else value;
    }

    pub fn parseMaybeTrailingComma(p: *TOML, closer: T) !bool {
        try p.lexer.expect(.t_comma);

        if (p.lexer.token == closer) {
            return false;
        }

        return true;
    }
};

pub const lexer = @import("./toml/lexer.zig");
pub const Lexer = lexer.Lexer;
const T = lexer.T;

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const assert = bun.assert;
const logger = bun.logger;

const js_ast = bun.ast;
const E = js_ast.E;
const Expr = js_ast.Expr;
